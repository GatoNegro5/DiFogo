import 'dart:async';
import 'dart:io';

import 'package:difogo/src/rust/api/core_dsp.dart' as rust_dsp;

import '../providers/pipeline_provider.dart' show HeavyWorkGate;

import 'analysis_window.dart';
import 'audio_path.dart';
import 'bpm_range.dart';
import 'gatomix_store.dart';
import 'library_guard.dart';
import '../services/track_tags.dart';

/// 3.1.14: BPM de las pistas sin medir de la cola, de una en una, mientras
/// suena la sesion. Se pausa solo durante el cruce entre los 2 decks; el
/// BPM entra a la cache al momento y el orden se rehace por lotes.

/// Pistas sin BPM desde [from] (index + 2 en adelante), sin `_K` ni repetidas.
List<String> backfillCandidates(
  List<String> queue,
  int from,
  double Function(String path) bpmOf,
) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (var i = from < 0 ? 0 : from; i < queue.length; i++) {
    final String p = queue[i];
    if (p.isEmpty || isKaraokeAudioPath(p)) continue;
    if (bpmOf(p) > 0) continue;
    if (seen.add(audioPathKey(p))) out.add(p);
  }
  return out;
}

/// queueEpoch: la cola es una lista inmutable; cualquier agregar, mover o
/// quitar crea otra. Si no es la misma del ultimo orden, no se reordena.
bool sameQueueEpoch(Object? epoch, Object queue) =>
    epoch != null && identical(epoch, queue);

/// Rehace solo `queue[fixed..]` con [order]. Las primeras [fixed] (actual y
/// siguiente) no se tocan y ninguna pista se pierde ni se duplica.
/// Null si no hay al menos 2 pistas que mover.
List<String>? reorderQueueTail(
  List<String> queue,
  int fixed,
  List<String> Function(List<String> tail, String? continueFrom) order,
) {
  final int head = fixed < 0 ? 0 : fixed;
  if (queue.length - head < 2) return null;
  final List<String> tail = queue.sublist(head);
  final List<String> out = queue.sublist(0, head);
  final Map<String, int> left = <String, int>{};
  for (final String p in tail) {
    final String k = audioPathKey(p);
    left[k] = (left[k] ?? 0) + 1;
  }
  final List<String> built = order(tail, head == 0 ? null : queue[head - 1]);
  for (final String p in <String>[...built, ...tail]) {
    final String k = audioPathKey(p);
    final int n = left[k] ?? 0;
    if (n <= 0) continue;
    left[k] = n - 1;
    out.add(p);
  }
  return out;
}

class BpmBackfillWorker {
  BpmBackfillWorker({
    required this.measure,
    required this.isPaused,
    required this.onBatch,
    this.batchSize = 5,
    this.gap = const Duration(milliseconds: 250),
    this.fillDna = fillTrackDnaIfStale,
  });

  final Future<double> Function(String path) measure;
  final bool Function() isPaused;
  final void Function(int measured) onBatch;
  final int batchSize;
  final Duration gap;

  /// 3.2.4: ADN acustico + tags en `dna[path]` tras el BPM de cada pista
  /// (null = apagado). Entra al `HeavyWorkGate` solo si falta o cambio.
  final Future<bool> Function(String path)? fillDna;

  final List<String> _pending = <String>[];
  final Set<String> _queued = <String>{};
  // 3.2.4: pistas solo para ADN (ya tienen BPM) y las ya intentadas.
  final List<String> _dnaPending = <String>[];
  final Set<String> _dnaQueued = <String>{};
  final Set<String> _dnaDone = <String>{};
  // Medida o fallida: no se vuelve a intentar en esta sesion.
  final Set<String> _done = <String>{};
  int _gen = 0;
  int? _runningGen;
  int _unapplied = 0;

  bool get isRunning => _runningGen == _gen;
  int get pendingCount => _pending.length;

  void enqueue(Iterable<String> paths) {
    for (final String p in paths) {
      final String k = audioPathKey(p);
      if (_done.contains(k) || !_queued.add(k)) continue;
      _pending.add(p);
    }
    if (_runningGen != _gen && _pending.isNotEmpty) unawaited(_run(_gen));
  }

  /// 3.2.4: pistas que ya tienen BPM pero quiza no ADN. Van despues de las
  /// de BPM, con la misma pausa en los cruces y el mismo candado.
  void enqueueDna(Iterable<String> paths) {
    if (fillDna == null) return;
    for (final String p in paths) {
      if (p.isEmpty || isKaraokeAudioPath(p)) continue;
      final String k = audioPathKey(p);
      if (_dnaDone.contains(k) || !_dnaQueued.add(k)) continue;
      _dnaPending.add(p);
    }
    if (_runningGen != _gen && _dnaPending.isNotEmpty) unawaited(_run(_gen));
  }

  void cancel() {
    _gen++;
    _pending.clear();
    _queued.clear();
    _dnaPending.clear();
    _dnaQueued.clear();
    _unapplied = 0;
  }

  Future<void> _dnaStep(String path, int gen) async {
    final Future<bool> Function(String path)? fill = fillDna;
    if (fill == null || gen != _gen) return;
    if (!_dnaDone.add(audioPathKey(path))) return;
    while (gen == _gen && isPaused()) {
      await Future<void>.delayed(gap);
    }
    if (gen != _gen) return;
    try {
      await fill(path);
    } catch (_) {}
  }

  /// Medidas que aun no entraron al orden (para el cambio de cancion).
  int takeUnapplied() {
    final int n = _unapplied;
    _unapplied = 0;
    return n;
  }

  Future<void> _run(int gen) async {
    _runningGen = gen;
    try {
      while (gen == _gen && (_pending.isNotEmpty || _dnaPending.isNotEmpty)) {
        while (gen == _gen && isPaused()) {
          await Future<void>.delayed(gap);
        }
        if (gen != _gen) break;
        if (_pending.isEmpty) {
          if (_dnaPending.isEmpty) break;
          final String only = _dnaPending.removeAt(0);
          _dnaQueued.remove(audioPathKey(only));
          await _dnaStep(only, gen);
          if (_pending.isNotEmpty || _dnaPending.isNotEmpty) {
            await Future<void>.delayed(gap);
          }
          continue;
        }
        final String path = _pending.removeAt(0);
        final String key = audioPathKey(path);
        _queued.remove(key);
        _done.add(key);
        double bpm = 0;
        try {
          // 3.1.19: candado termico global (un solo trabajo pesado a la vez).
          bpm = TrackTags.musicalBpm(
            await HeavyWorkGate.run(
              'bpm-backfill',
              () async => gen == _gen ? await measure(path) : 0.0,
            ),
          );
        } catch (_) {
          bpm = 0;
        }
        if (gen != _gen) break;
        if (bpm > 0) {
          TrackTags.rememberBpm(path, bpm);
          _unapplied++;
        }
        if (_unapplied >= batchSize || (_pending.isEmpty && _unapplied > 0)) {
          final int n = _unapplied;
          _unapplied = 0;
          onBatch(n);
        }
        await _dnaStep(path, gen);
        if (gen != _gen) break;
        if (_pending.isNotEmpty || _dnaPending.isNotEmpty) {
          await Future<void>.delayed(gap);
        }
      }
    } finally {
      if (_runningGen == gen) _runningGen = null;
    }
  }
}

/// Mide con Rust y deja en el `.gatomix.json` de la carpeta el BPM y el
/// mtime (como dsp_provider 3.1.11), para que el escaneo de la carpeta no la
/// vuelva a medir.
///
/// 3.1.72: dentro de la biblioteca protegida (ReGenial) mide en SOLO
/// LECTURA (beatGrid, sin escribir TBPM) y el sello va al espejo local.
/// Fuera de la biblioteca sigue escribiendo TBPM como antes.
Future<double> measureAndStampBpm(String path) async {
  int durMs = 0;
  try {
    durMs = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
  } catch (_) {}
  if (!canAnalyzeFull(durMs)) return 0;
  if (libraryWriteBlocked(path, what: 'TBPM')) {
    final double bpm = await measureBpmReadOnly(path, durMs);
    if (bpm > 0) TrackTags.rememberBpm(path, bpm);
    stampBackfill(path, bpm);
    return bpm;
  }
  final double raw = await rust_dsp
      .autoDetectAndInjectBpm(inputPath: path)
      .timeout(analysisTimeout(durMs, const Duration(seconds: 45)));
  final double bpm = fixBpmRange(raw) ?? 0;
  stampBackfill(path, bpm);
  return bpm;
}

/// 3.1.72: BPM medido en solo lectura (ventana de 30 s desde el 30 %),
/// sin escribir TBPM. 0 si no se pudo medir.
Future<double> measureBpmReadOnly(String path, int durMs) async {
  final int from = durMs > 90000 ? durMs * 3 ~/ 10 : 0;
  final rust_dsp.BeatGrid g = await rust_dsp
      .beatGrid(inputPath: path, fromMs: BigInt.from(from), spanSecs: 30)
      .timeout(const Duration(seconds: 45));
  return g.ok ? (fixBpmRange(g.bpm) ?? 0) : 0;
}

void stampBackfill(String path, double bpm) {
  final File file = File(path);
  final String dir = file.parent.path;
  // 3.1.42: sin `.gatomix.json` se crea, pero solo si hay BPM que guardar.
  if (bpm <= 0 && !GatomixStore.hasDocument(dir)) {
    return;
  }
  final int mtime;
  try {
    mtime = file.lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {
    return;
  }
  final Map<String, dynamic> stamps = Map<String, dynamic>.from(
    readDjTimestamps(dir),
  )..[path] = mtime;
  writeDjTimestamps(dir, stamps);
  if (bpm > 0) {
    writeDjMetadata(
      dir,
      bpmIndexPreservingKeys(readDjMetadata(dir), <String, double>{path: bpm}),
    );
  }
}

/// 3.2.4: cierto si `dna[path]` falta, no tiene metricas o su `mtimeMs` ya
/// no es el del archivo.
bool trackDnaNeedsFill(TrackDnaEntry? cur, int mtimeMs) =>
    cur == null || cur.energy == null || cur.mtimeMs != mtimeMs;

/// 3.2.4: llena `dna[path]` con `read_track_meta` + `track_dna` (Rust, solo
/// lectura del audio) si falta o cambio el mtime. Lo barato (stat y cache en
/// memoria) va fuera del candado; Rust corre en el turno `dna-backfill` del
/// `HeavyWorkGate` (`track_dna` entra con `PriorityGuard`). Escribe con
/// [saveTrackDna]: mezcla (el `lang` de Whisper se conserva) y, en la
/// biblioteca protegida, solo en el espejo. Nunca lanza.
Future<bool> fillTrackDnaIfStale(
  String path, {
  Future<rust_dsp.TrackMeta> Function(String path)? readMeta,
  Future<rust_dsp.TrackDna> Function(String path)? measure,
}) async {
  if (path.isEmpty || isKaraokeAudioPath(path)) return false;
  try {
    final FileStat st = await File(path).stat();
    if (st.type != FileSystemEntityType.file) return false;
    final int mtime = st.modified.millisecondsSinceEpoch;
    await warmTrackDnaDir(File(path).parent.path);
    if (!trackDnaNeedsFill(peekTrackDna(path), mtime)) return false;
    final Future<rust_dsp.TrackMeta> Function(String) rm =
        readMeta ?? (String p) => rust_dsp.readTrackMeta(inputPath: p);
    final Future<rust_dsp.TrackDna> Function(String) ms =
        measure ?? (String p) => rust_dsp.trackDna(inputPath: p);
    final (rust_dsp.TrackMeta, rust_dsp.TrackDna) got = await HeavyWorkGate.run(
      'dna-backfill',
      () async {
        final rust_dsp.TrackMeta meta = await rm(path);
        final rust_dsp.TrackDna dna = await ms(
          path,
        ).timeout(const Duration(seconds: 45));
        return (meta, dna);
      },
    );
    final rust_dsp.TrackMeta meta = got.$1;
    final rust_dsp.TrackDna dna = got.$2;
    final String genre = meta.genre.trim();
    return await saveTrackDna(
      path,
      TrackDnaEntry(
        energy: dna.ok ? dna.energy : null,
        bassRatio: dna.ok ? dna.bassRatio : null,
        brightness: dna.ok ? dna.brightness : null,
        beatDensity: dna.ok ? dna.beatDensity : null,
        genre: genre.isEmpty ? null : genre,
        year: meta.year > 0 ? meta.year : null,
        // Sin metricas no se sella: otra sesion lo vuelve a intentar.
        mtimeMs: dna.ok ? mtime : null,
      ),
    );
  } catch (_) {
    return false;
  }
}
