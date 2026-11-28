import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:difogo/src/rust/api/core_dsp.dart' show decodeMonoPcm;

import 'audio_path.dart';
import 'bpm_backfill_worker.dart' show fillTrackDnaIfStale;
import 'discovery_dedup_controller.dart' show listLibraryAudioAsync;
import 'gatomix_store.dart';
import 'library_guard.dart';
import 'queue_bpm.dart';

/// 3.2.37: energia 1-10 (compuesto) y Camelot en Dart, sin tocar el FFI.
/// El espejo (folder_cache) es el unico destino de escritura.

const double kEnergyBpmMin = 70;
const double kEnergyBpmSpan = 90;
const int kCamelotPcmRate = 11025;
const double kCamelotStartFrac = 0.30;
const int kCamelotSecs = 18;

/// Peso al menos igual al bonus de ola BPM (+36).
const double kEnergyWaveBonus = 36;
const double kEnergyJumpPenalty = 200;

/// Perfiles Krumhansl-Kessler (C, C#, ..., B).
const List<double> kKrumhanslMajor = <double>[
  6.35,
  2.23,
  3.48,
  2.33,
  4.38,
  4.09,
  2.52,
  5.19,
  2.39,
  3.66,
  2.29,
  2.88,
];
const List<double> kKrumhanslMinor = <double>[
  6.33,
  2.68,
  3.52,
  5.38,
  2.60,
  3.53,
  2.54,
  4.75,
  3.98,
  2.69,
  3.34,
  3.17,
];

/// Indice 0 = C. Mayor: 8B = C. Menor: 8A = Am.
const List<String> kCamelotMajor = <String>[
  '8B',
  '3B',
  '10B',
  '5B',
  '12B',
  '7B',
  '2B',
  '9B',
  '4B',
  '11B',
  '6B',
  '1B',
];
const List<String> kCamelotMinor = <String>[
  '5A',
  '12A',
  '7A',
  '2A',
  '9A',
  '4A',
  '11A',
  '6A',
  '1A',
  '8A',
  '3A',
  '10A',
];

double bpmNormForEnergy(double bpm) {
  if (bpm <= 0) return 0.5;
  return ((bpm - kEnergyBpmMin) / kEnergyBpmSpan).clamp(0.0, 1.0);
}

/// 40% densidad de beat, 15% BPM, 20% brillo, 25% RMS (energy de TrackDna).
/// Valor bruto 0-1; el nivel 1-10 se deriva con [EnergyScale] (deciles).
double compositeEnergyRaw({
  required double rmsEnergy,
  required double beatDensity,
  required double brightness,
  required double bpm,
}) {
  final double e = rmsEnergy.clamp(0.0, 1.0);
  final double d = beatDensity.clamp(0.0, 1.0);
  final double b = brightness.clamp(0.0, 1.0);
  return 0.40 * d + 0.15 * bpmNormForEnergy(bpm) + 0.20 * b + 0.25 * e;
}

/// Mapeo lineal de respaldo (si no hay escala de la biblioteca).
int linearEnergyLevel(double raw) =>
    (raw.clamp(0.0, 1.0) * 9.0).round().clamp(0, 9) + 1;

int compositeEnergyLevel({
  required double rmsEnergy,
  required double beatDensity,
  required double brightness,
  required double bpm,
  EnergyScale? scale,
}) {
  final double raw = compositeEnergyRaw(
    rmsEnergy: rmsEnergy,
    beatDensity: beatDensity,
    brightness: brightness,
    bpm: bpm,
  );
  return scale == null ? linearEnergyLevel(raw) : scale.levelOf(raw);
}

/// Salto de energia entre dos temas. Subir 1 hacia el pico vale tanto
/// como quedarse; un salto de mas de 2 niveles se penaliza fuerte.
double harmonicEnergyScore(
  int? fromLevel,
  int? toLevel, {
  required bool waveUp,
}) {
  if (fromLevel == null || toLevel == null) return 0;
  final int delta = toLevel - fromLevel;
  final int ad = delta.abs();
  if (ad > 2) return -kEnergyJumpPenalty;
  if (ad == 0) return kEnergyWaveBonus;
  final bool along = waveUp ? delta > 0 : delta < 0;
  if (ad == 1) return along ? kEnergyWaveBonus : 12;
  return along ? 6 : 0;
}

/// Cierto si el salto es legal (falta un nivel, o hay a lo sumo 2 de diferencia).
bool energyJumpOk(int? fromLevel, int? toLevel) {
  if (fromLevel == null || toLevel == null) return true;
  return (toLevel - fromLevel).abs() <= 2;
}

bool isCamelotKey(String? s) {
  if (s == null) return false;
  final String t = s.trim().toUpperCase();
  return RegExp(r'^(?:[1-9]|1[0-2])[AB]$').hasMatch(t);
}

String? normalizeCamelot(String? s) {
  if (!isCamelotKey(s)) return null;
  return s!.trim().toUpperCase();
}

/// Tokens "8A" / "11b" en el nombre del archivo, si existen.
String? camelotFromFileName(String path) {
  final RegExp re = RegExp(
    r'(?:^|[^0-9A-Za-z])((?:[1-9]|1[0-2])[ABab])(?![0-9A-Za-z])',
  );
  final String name = path.replaceAll(r'\', '/').split('/').last;
  final Iterable<RegExpMatch> all = re.allMatches(name);
  if (all.isEmpty) return null;
  return all.last.group(1)!.toUpperCase();
}

/// Marca de "se intento y no se pudo": no rehacer el decode.
const String kCamelotUnknown = '-';

/// Necesita relleno (posible decode) si falta el compuesto bruto o el mtime.
/// Con [energyRaw] fresco no se vuelve a decodificar; el nivel se reasigna
/// con [relevelLibraryEnergy].
bool trackEnergyNeedsFill(TrackDnaEntry? cur, int mtimeMs) {
  if (cur == null || cur.energyRaw == null) return true;
  if (mtimeMs > 0 && cur.mtimeMs != null && cur.mtimeMs != mtimeMs) {
    return true;
  }
  return false;
}

bool trackCamelotNeedsFill(TrackDnaEntry? cur) {
  if (cur == null) return true;
  if (isCamelotKey(cur.camelot)) return false;
  if (cur.camelot == kCamelotUnknown) return false;
  return true;
}

double? rawFromStored(TrackDnaEntry? cur, double bpm) {
  if (cur == null) return null;
  if (cur.energyRaw != null) return cur.energyRaw!.clamp(0.0, 1.0);
  if (cur.energy == null || cur.beatDensity == null || cur.brightness == null) {
    return null;
  }
  return compositeEnergyRaw(
    rmsEnergy: cur.energy!,
    beatDensity: cur.beatDensity!,
    brightness: cur.brightness!,
    bpm: bpm,
  );
}

int? levelFromStored(TrackDnaEntry? cur, double bpm, {EnergyScale? scale}) {
  final double? raw = rawFromStored(cur, bpm);
  if (raw == null) return null;
  return scale == null ? linearEnergyLevel(raw) : scale.levelOf(raw);
}

/// PCM s16le mono -> 12 bins de clase de altura (C..B).
List<double> chromaFromPcm(Uint8List pcm, int sampleRate) {
  final int nSamp = pcm.length ~/ 2;
  final List<double> chroma = List<double>.filled(12, 0);
  if (nSamp < 2048 || sampleRate <= 0) return chroma;
  const int win = 4096;
  const int hop = 2048;
  final int use = math.min(nSamp, sampleRate * 22);
  final List<double> frame = List<double>.filled(win, 0);
  for (int start = 0; start + win <= use; start += hop) {
    for (int i = 0; i < win; i++) {
      final int o = (start + i) * 2;
      final int lo = pcm[o];
      final int hi = pcm[o + 1];
      int s = lo | (hi << 8);
      if (s >= 0x8000) s -= 0x10000;
      final double w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1));
      frame[i] = s / 32768.0 * w;
    }
    // MIDI 36 (C2) a 84 (C6): 4 octavas.
    for (int midi = 36; midi <= 84; midi++) {
      final double freq = 440.0 * math.pow(2.0, (midi - 69) / 12.0);
      final double mag = _goertzel(frame, freq, sampleRate);
      chroma[midi % 12] += mag;
    }
  }
  double peak = 0;
  for (final double v in chroma) {
    if (v > peak) peak = v;
  }
  if (peak > 0) {
    for (int i = 0; i < 12; i++) {
      chroma[i] /= peak;
    }
  }
  return chroma;
}

double _goertzel(List<double> x, double freq, int rate) {
  final double w = 2 * math.pi * freq / rate;
  final double coeff = 2 * math.cos(w);
  double s1 = 0;
  double s2 = 0;
  for (final double v in x) {
    final double s0 = v + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

double _corrShift(List<double> chroma, List<double> profile, int shift) {
  double s = 0;
  for (int i = 0; i < 12; i++) {
    s += chroma[i] * profile[(i - shift) % 12];
  }
  return s;
}

/// Mejor Camelot a partir de un cromagrama.
String? camelotFromChroma(List<double> chroma) {
  if (chroma.length != 12) return null;
  double best = double.negativeInfinity;
  String? key;
  for (int k = 0; k < 12; k++) {
    final double maj = _corrShift(chroma, kKrumhanslMajor, k);
    if (maj > best) {
      best = maj;
      key = kCamelotMajor[k];
    }
    final double minv = _corrShift(chroma, kKrumhanslMinor, k);
    if (minv > best) {
      best = minv;
      key = kCamelotMinor[k];
    }
  }
  return key;
}

String? camelotFromPcm(Uint8List pcm, int sampleRate) {
  final List<double> ch = chromaFromPcm(pcm, sampleRate);
  double sum = 0;
  for (final double v in ch) {
    sum += v;
  }
  if (sum <= 0) return null;
  return camelotFromChroma(ch);
}

Future<String?> detectCamelotFromAudio(
  String path, {
  double durationSec = 0,
}) async {
  try {
    final int start = durationSec > 60
        ? (durationSec * kCamelotStartFrac).round()
        : 0;
    final Uint8List pcm = await decodeMonoPcm(
      inputPath: path,
      startSecs: start,
      lengthSecs: kCamelotSecs,
      targetRate: kCamelotPcmRate,
    );
    return camelotFromPcm(pcm, kCamelotPcmRate);
  } catch (_) {
    return null;
  }
}

/// Rellena energyLevel y camelot en el espejo. Nunca escribe junto al audio.
/// Si las metricas Rust ya estan frescas, no vuelve a llamar track_dna.
/// Escala 1-10 por deciles del compuesto bruto de la biblioteca.
class EnergyScale {
  const EnergyScale(this.cuts);

  /// Cortes en los percentiles 10, 20, ..., 90 (9 valores, ordenados).
  final List<double> cuts;

  static EnergyScale? _mem;

  bool get isValid => cuts.length == 9 && cuts.every((double c) => c.isFinite);

  int levelOf(double raw) {
    if (!isValid) return linearEnergyLevel(raw);
    final double r = raw.clamp(0.0, 1.0);
    for (int i = 0; i < cuts.length; i++) {
      if (r <= cuts[i]) return i + 1;
    }
    return 10;
  }

  static EnergyScale fitDeciles(Iterable<double> raws) {
    final List<double> xs = <double>[
      for (final double v in raws)
        if (v.isFinite) v.clamp(0.0, 1.0),
    ]..sort();
    if (xs.length < 10) {
      return const EnergyScale(<double>[
        0.1,
        0.2,
        0.3,
        0.4,
        0.5,
        0.6,
        0.7,
        0.8,
        0.9,
      ]);
    }
    final List<double> cuts = <double>[
      for (int p = 10; p <= 90; p += 10) _percentile(xs, p / 100.0),
    ];
    return EnergyScale(cuts);
  }

  static double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    final double x = q * (sorted.length - 1);
    final int lo = x.floor().clamp(0, sorted.length - 1);
    final int hi = x.ceil().clamp(0, sorted.length - 1);
    if (lo == hi) return sorted[lo];
    final double t = x - lo;
    return sorted[lo] * (1 - t) + sorted[hi] * t;
  }

  static File scaleFile() => File(
    '${libraryCacheRoot()}${Platform.pathSeparator}energy_scale.gatomix.json',
  );

  static EnergyScale? peek() => _mem;

  static EnergyScale? load() {
    if (_mem != null) return _mem;
    try {
      final File f = scaleFile();
      if (!f.existsSync()) return null;
      _mem = fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {}
    return _mem;
  }

  static Future<void> save(EnergyScale scale, {int count = 0}) async {
    _mem = scale;
    final File f = scaleFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'count': count,
        'cuts': scale.cuts,
      }),
    );
  }

  static EnergyScale? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? c = raw['cuts'];
    if (c is! List) return null;
    final List<double> cuts = <double>[
      for (final Object? v in c)
        if (v is num && v.isFinite) v.toDouble(),
    ];
    final EnergyScale s = EnergyScale(cuts);
    return s.isValid ? s : null;
  }

  /// Solo pruebas.
  static void debugReset() => _mem = null;
}

Future<TrackDnaEntry?> fillTrackEnergyIfStale(String path) async {
  if (path.isEmpty || isKaraokeAudioPath(path)) return peekTrackDna(path);
  if (!isLibraryPath(path)) return peekTrackDna(path);
  try {
    final FileStat st = await File(path).stat();
    if (st.type != FileSystemEntityType.file) return peekTrackDna(path);
    final int mtimeMs = st.modified.millisecondsSinceEpoch;
    await warmTrackDnaDir(File(path).parent.path);
    TrackDnaEntry? cur = peekTrackDna(path);
    final bool needLevel = trackEnergyNeedsFill(cur, mtimeMs);
    final bool needKey = trackCamelotNeedsFill(cur);
    if (!needLevel && !needKey) return cur;

    if (needLevel &&
        (cur == null ||
            cur.energy == null ||
            cur.beatDensity == null ||
            cur.brightness == null ||
            (mtimeMs > 0 && cur.mtimeMs != null && cur.mtimeMs != mtimeMs))) {
      await fillTrackDnaIfStale(path);
      cur = peekTrackDna(path);
    }

    final double bpm = memoryBpm(path);
    final double? raw = rawFromStored(cur, bpm);
    final EnergyScale? scale = EnergyScale.load();
    final int? level = raw == null
        ? null
        : (scale == null ? linearEnergyLevel(raw) : scale.levelOf(raw));

    String? camelot = normalizeCamelot(cur?.camelot);
    camelot ??= normalizeCamelot(camelotFromFileName(path));
    if (camelot == null && needKey) {
      camelot = await detectCamelotFromAudio(path);
      camelot = normalizeCamelot(camelot);
    }
    // Si se intento y no hay clave, sellar para no re-decodear.
    final String? camelotStamp =
        camelot ?? (needKey ? kCamelotUnknown : cur?.camelot);

    if (level == null && raw == null && camelotStamp == null) return cur;

    final TrackDnaEntry next = (cur ?? const TrackDnaEntry()).mergedWith(
      TrackDnaEntry(
        energyLevel: level,
        energyRaw: raw,
        camelot: camelotStamp,
        mtimeMs: mtimeMs > 0 ? mtimeMs : cur?.mtimeMs,
      ),
    );
    await saveTrackDna(path, next);
    return peekTrackDna(path);
  } catch (_) {
    return peekTrackDna(path);
  }
}

class EnergyBackfillReport {
  int scanned = 0;
  int skipped = 0;
  int filled = 0;
  int failed = 0;
  int withLevel = 0;
  int withCamelot = 0;

  @override
  String toString() =>
      'scanned=$scanned skipped=$skipped filled=$filled failed=$failed '
      'withLevel=$withLevel withCamelot=$withCamelot';
}

/// Recorre [root] (ReGenial), escribe solo el espejo, y se puede retomar:
/// lo que ya tiene nivel + mtime fresco se salta. Camelot ausente se
/// intenta una vez (nombre o decode); si falla, no se reintenta el decode
/// en la siguiente pasada si el nivel ya esta sellado.
Future<EnergyBackfillReport> backfillLibraryEnergy({
  required String root,
  required void Function(String line) log,
  int blockSize = 40,
  bool Function()? shouldStop,
}) async {
  final EnergyBackfillReport r = EnergyBackfillReport();
  if (root.isEmpty) return r;
  final List<String> paths = await listLibraryAudioAsync(<String>[root]);
  paths.sort();
  log('backfill: ${paths.length} audios bajo $root');
  int inBlock = 0;
  for (final String path in paths) {
    if (shouldStop != null && shouldStop()) break;
    if (isKaraokeAudioPath(path) || !isLibraryPath(path)) continue;
    r.scanned++;
    try {
      final FileStat st = await File(path).stat();
      final int mtimeMs = st.modified.millisecondsSinceEpoch;
      await warmTrackDnaDir(File(path).parent.path);
      final TrackDnaEntry? before = peekTrackDna(path);
      final bool need =
          trackEnergyNeedsFill(before, mtimeMs) ||
          trackCamelotNeedsFill(before);
      if (!need) {
        r.skipped++;
        if (before?.energyLevel != null) r.withLevel++;
        if (isCamelotKey(before?.camelot)) r.withCamelot++;
        continue;
      }
      final TrackDnaEntry? after = await fillTrackEnergyIfStale(path);
      if (after?.energyLevel != null || isCamelotKey(after?.camelot)) {
        r.filled++;
        if (after?.energyLevel != null) r.withLevel++;
        if (isCamelotKey(after?.camelot)) r.withCamelot++;
      } else {
        r.failed++;
      }
    } catch (e) {
      r.failed++;
      log('fail: $path $e');
    }
    inBlock++;
    if (inBlock >= blockSize) {
      inBlock = 0;
      log('progreso: ${r.toString()}');
    }
  }
  log('listo: ${r.toString()}');
  return r;
}

class EnergyRelevelReport {
  int scanned = 0;
  int withRaw = 0;
  int updated = 0;
  int missing = 0;
  final List<int> histogram = List<int>.filled(10, 0);
  List<double> cuts = const <double>[];

  String histogramLine() {
    final StringBuffer b = StringBuffer('dist');
    for (int i = 0; i < 10; i++) {
      b.write(' E${i + 1}=${histogram[i]}');
    }
    return b.toString();
  }

  @override
  String toString() =>
      'scanned=$scanned withRaw=$withRaw updated=$updated missing=$missing '
      '${histogramLine()}';
}

/// Recorre el espejo (sin decodificar audio): completa [energyRaw] barato
/// desde metricas + BPM, ajusta deciles y reescribe [energyLevel].
Future<EnergyRelevelReport> relevelLibraryEnergy({
  required String root,
  required void Function(String line) log,
}) async {
  final EnergyRelevelReport r = EnergyRelevelReport();
  EnergyScale.debugReset();
  if (root.isEmpty) return r;
  final List<String> paths = await listLibraryAudioAsync(<String>[root]);
  paths.sort();
  log('relevel: ${paths.length} audios bajo $root');
  final List<(String, double, int?)> pending = <(String, double, int?)>[];
  for (final String path in paths) {
    if (isKaraokeAudioPath(path) || !isLibraryPath(path)) continue;
    r.scanned++;
    try {
      await warmTrackDnaDir(File(path).parent.path);
      final TrackDnaEntry? cur = peekTrackDna(path);
      final double bpm = memoryBpm(path);
      final double? raw = rawFromStored(cur, bpm);
      if (raw == null) {
        r.missing++;
        continue;
      }
      r.withRaw++;
      pending.add((path, raw, cur?.mtimeMs));
      if (cur?.energyRaw == null) {
        await saveTrackDna(
          path,
          TrackDnaEntry(energyRaw: raw, mtimeMs: cur?.mtimeMs),
        );
      }
    } catch (e) {
      r.missing++;
      log('relevel fail: $path $e');
    }
  }
  final EnergyScale scale = EnergyScale.fitDeciles(<double>[
    for (final (String, double, int?) e in pending) e.$2,
  ]);
  await EnergyScale.save(scale, count: pending.length);
  r.cuts = scale.cuts;
  log('escala cortes=${scale.cuts}');
  for (final (String path, double raw, int? mtime) in pending) {
    final int level = scale.levelOf(raw);
    r.histogram[level - 1]++;
    await saveTrackDna(
      path,
      TrackDnaEntry(energyRaw: raw, energyLevel: level, mtimeMs: mtime),
    );
    r.updated++;
  }
  log('listo: ${r.toString()}');
  return r;
}
