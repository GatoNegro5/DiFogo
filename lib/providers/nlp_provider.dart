import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pipeline_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:difogo/src/rust/api/core_dsp.dart' as rust_dsp;
import 'package:difogo/src/rust/api/whisper_lrc.dart' as rust_whisper;

import '../core/brand_paths.dart';
import '../core/library_guard.dart';
import '../core/gatomix_store.dart';
import '../core/lrc_timeline.dart';
import '../core/lyric_files.dart';
import '../core/lyric_ai_align.dart' show parseTimedWordsJson;
import '../core/lyric_match.dart';
import '../core/vocal_bounds.dart';
import '../services/id3_title_artist.dart';
import '../services/karaoke_engine.dart' show KaraokeEngine;
import 'db_provider.dart'; // 🛠️ Requerido para inyectar Cues a la BD

bool _enCarpetaOriginal(String path) => pathInOriginalDir(path);

final nlpWorkerProvider = Provider((ref) => NlpWorker(ref));

// ---------------------------------------------------------------------------
// 3.1.94: letras 100 % locales. Ninguna descarga de letras (LRCLIB,
// subtitulos de YouTube ni otra API): en Windows/macOS las genera Whisper
// (whisper.cpp por FRB); en Android/iOS no hay letra automatica.
// ---------------------------------------------------------------------------

/// Transcriptor: WAV PCM16 mono 16 kHz + modelo -> palabras y LRC.
typedef LocalLyricsTranscriber =
    Future<({String wordsJson, String lrcText})> Function(
      String wavPath,
      String modelPath,
    );

/// Dependencias inyectables (pruebas sin Rust, sin modelo y sin red).
class LocalLyricsDeps {
  final bool desktop;
  final Future<String> Function() fetchModel;
  final LocalLyricsTranscriber transcribe;

  /// PCM s16le mono 16 kHz de los primeros [maxSecs] segundos.
  final Future<Uint8List> Function(String audioPath, int maxSecs) decode;
  final Future<int> Function(String audioPath) durationMs;

  /// Candado termico: un solo trabajo pesado a la vez.
  final Future<String?> Function(String label, Future<String?> Function() job)
  gate;
  final String? tempDir;

  const LocalLyricsDeps({
    required this.desktop,
    required this.fetchModel,
    required this.transcribe,
    required this.decode,
    required this.durationMs,
    required this.gate,
    this.tempDir,
  });

  static LocalLyricsDeps real() => LocalLyricsDeps(
    desktop: Platform.isWindows || Platform.isMacOS,
    fetchModel: () => KaraokeEngine.ensureWhisperModel(),
    transcribe: (String wav, String model) async {
      final rust_whisper.WhisperTranscript t = await rust_whisper
          .transcribeVocalsWav(wavPath: wav, modelPath: model, language: null);
      return (wordsJson: t.wordsJson, lrcText: t.lrcText);
    },
    decode: (String audio, int maxSecs) => rust_dsp.decodeMonoPcm(
      inputPath: audio,
      startSecs: 0,
      lengthSecs: maxSecs,
      targetRate: 16000,
    ),
    durationMs: (String audio) async =>
        (await rust_dsp.exactDurationMs(inputPath: audio)).toInt(),
    gate: (String label, Future<String?> Function() job) =>
        HeavyWorkGate.run<String?>(label, job),
  );
}

/// Solo pruebas: dependencias falsas de [NlpWorker.generateLocalLyricsOffline].
@visibleForTesting
LocalLyricsDeps? debugLocalLyricsDeps;

/// Tope de la decodificacion completa (sin pista vocal): 10 min. Mas largo
/// (megamix) no lleva letra y la RAM del decodificador crece con la duracion.
const int kLocalLyricsMaxMs = 10 * 60 * 1000;

/// `cancion.mp3|webm|m4a` -> `cancion.lrc` (igual que el NLP de siempre).
String localLyricsLrcPath(String audioPath) => audioPath.replaceAll(
  RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
  '.lrc',
);

Uint8List _wavHeader16kMono(int dataBytes) {
  final ByteData h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, 16000, Endian.little);
  h.setUint32(28, 32000, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, dataBytes, Endian.little);
  return h.buffer.asUint8List();
}

void _writeTextAtomic(File f, String text) {
  final File tmp = File('${f.path}.part');
  try {
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// 3.1.94: genera la letra de [audioPath] en local y devuelve la ruta del
/// `.lrc` escrito (null si no hizo nada). Nunca pisa un `.lrc` (junto al
/// audio o en el espejo); en la biblioteca protegida escribe solo en el
/// espejo via `lrcWriteFile` y no escribe `.gmx_words.json`. Corre dentro de
/// [LocalLyricsDeps.gate]; [shouldRun] se consulta al tocar el turno (p. ej.
/// la pista ya cambio). Sin [vocalsWavPath] decodifica la pista a un WAV
/// 16 kHz mono en la carpeta temporal y lo borra en el finally.
Future<String?> generateLocalLyricsOfflineWith(
  String audioPath, {
  required LocalLyricsDeps deps,
  String? vocalsWavPath,
  String? lrcPath,
  bool Function()? shouldRun,
}) async {
  if (!deps.desktop) return null;
  final String lrc = lrcPath ?? localLyricsLrcPath(audioPath);
  if (lrc == audioPath) return null;
  if (lrcReadFile(audioPath, lrc).existsSync()) return null;
  return deps.gate('whisper-lyrics', () async {
    if (!(shouldRun?.call() ?? true)) return null;
    if (lrcReadFile(audioPath, lrc).existsSync()) return null;
    if (!File(audioPath).existsSync()) return null;
    String? temp;
    try {
      String wav;
      if (vocalsWavPath != null) {
        wav = vocalsWavPath;
      } else {
        final int ms = await deps.durationMs(audioPath);
        if (ms <= 0 || ms > kLocalLyricsMaxMs) return null;
        final String dir = deps.tempDir ?? Directory.systemTemp.path;
        temp =
            '$dir${Platform.pathSeparator}gatomix_lyr_${pid}_'
            '${DateTime.now().microsecondsSinceEpoch}.wav';
        final Uint8List pcm = await deps.decode(audioPath, ms ~/ 1000 + 1);
        final int even = pcm.length & ~1;
        if (even < 32000) return null;
        final BytesBuilder b = BytesBuilder(copy: false)
          ..add(_wavHeader16kMono(even))
          ..add(Uint8List.sublistView(pcm, 0, even));
        File(temp).writeAsBytesSync(b.takeBytes(), flush: true);
        wav = temp;
      }
      final String model = await deps.fetchModel();
      final ({String wordsJson, String lrcText}) t = await deps.transcribe(
        wav,
        model,
      );
      // 3.2.3: idioma detectado por Whisper -> dna[path].lang (espejo en la
      // biblioteca protegida; no borra las metricas del ADN).
      await saveWhisperLang(audioPath, t.wordsJson);
      if (t.lrcText.trim().isEmpty) return null;
      // Biblioteca protegida: lrcWriteFile da el espejo, nunca junto al audio.
      final File out = lrcWriteFile(audioPath, lrc);
      if (out.existsSync()) return null;
      _writeTextAtomic(out, t.lrcText);
      if (!isLibraryPath(audioPath) &&
          audioPath.toLowerCase().endsWith('.mp3')) {
        final File words = File(
          audioPath.replaceAll(
            RegExp(r'\.mp3$', caseSensitive: false),
            '.gmx_words.json',
          ),
        );
        if (!words.existsSync() &&
            parseTimedWordsJson(t.wordsJson).isNotEmpty) {
          _writeTextAtomic(words, t.wordsJson);
        }
      }
      return out.path;
    } catch (e) {
      debugPrint('[NLP] letra local omitida: $e');
      return null;
    } finally {
      if (temp != null) {
        for (final String p in <String>[temp, '$temp.part']) {
          try {
            final File f = File(p);
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
      }
    }
  });
}

class NlpWorker {
  final Ref ref;

  NlpWorker(this.ref);

  /// Último detalle para mostrarlo en pantalla (servidor caído, sin coincidencia).
  String lastDetail = '';

  // 🛠️ MÓDULO V4.1: CÁLCULO DE COLISIÓN VOCAL CON ESCUDO ANTI-BASURA
  // 🛠️ MÓDULO V4.2: CÁLCULO DE COLISIÓN VOCAL (BLINDADO CONTRA CUES MANUALES)
  Future<void> _processVocalBoundingBox(
    String audioPath,
    String syncedLyrics,
    int durationMs,
  ) async {
    try {
      final db = ref.read(dbServiceProvider);
      final existingMeta = await db.getTrackMetadata(audioPath);

      // 🛡️ REGLA MAESTRA: Si el usuario ya fijó puntos en el Laboratorio, el NLP retrocede.
      if (existingMeta != null && existingMeta.isManualCue) {
        debugPrint(
          "⏭️ [AUTO-MASTER] NLP Evadido. Cues manuales detectados para: $audioPath",
        );
        return;
      }

      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      int? firstMs;
      int? lastMs;

      final lines = syncedLyrics.split('\n');
      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final text = match.group(4)!.trim().toLowerCase();

          bool isGarbage =
              text.isEmpty ||
              text.startsWith('by:') ||
              text.startsWith('artist:') ||
              text.startsWith('title:') ||
              text.contains('synced') ||
              text.contains('lyric') ||
              text.contains('www.') ||
              text.length < 3;

          if (!isGarbage) {
            final min = int.parse(match.group(1)!);
            final sec = int.parse(match.group(2)!);
            int ms = int.parse(match.group(3)!);
            if (match.group(3)!.length == 2) ms *= 10;
            final totalMs = (min * 60000) + (sec * 1000) + ms;

            firstMs ??= totalMs;
            lastMs = totalMs;
          }
        }
      }

      if (firstMs != null && lastMs != null) {
        // 3.1.02: reglas en core/vocal_bounds.dart, contra la duración exacta en ms.
        final VocalBounds? bounds = vocalBounds(
          firstMs: firstMs,
          lastMs: lastMs,
          exactMs: durationMs,
        );
        if (bounds == null) {
          debugPrint(
            "[AUTO-MASTER] Letra desfasada (last=${lastMs}ms >= audio=${durationMs}ms): no se escriben cues -> $audioPath",
          );
          return;
        }
        final int cueIn = bounds.cueInMs;
        final int mixOut = bounds.mixOutMs;

        try {
          await db.saveTrackMetadata(
            path: audioPath,
            cueInMs: cueIn,
            mixOutMs: mixOut,
            isManualCue: false,
          );
          debugPrint(
            "🎛️ [AUTO-MASTER] Cues IN: ${cueIn}ms | OUT: ${mixOut}ms -> $audioPath",
          );
        } catch (e) {
          debugPrint("🔴 Error guardando metadata en BD: $e");
        }
      }
    } catch (e) {
      debugPrint("🔴 [AUTO-MASTER] Error calculando Bounding Box: $e");
    }
  }

  Future<void> processDirectory(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .where((f) => !_enCarpetaOriginal(f.path))
        .toList();

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [NLP Worker] Scraping abortado por el usuario.");
        break;
      }

      final file = files[i];
      if (_enCarpetaOriginal(file.path)) continue;
      final filename = file.uri.pathSegments.last;

      final lrcPath = file.path.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      final lrcFile = File(lrcPath);

      if (lrcFile.existsSync()) {
        final content = await lrcFile.readAsString();
        if (lrcIsProtected(content)) continue;
        if (!content.contains('Letra no encontrada') &&
            !content.contains('Error de conexión') &&
            !content.contains('Error Auto-Healing') &&
            lrcFile.lengthSync() > 20) {
          // 🛠️ DESTRUCCIÓN DEL BYPASS:
          // Si el CueIn está en cero (o no existe) y no es manual, FORZAMOS el recálculo
          // ignorando si el MixOut ya estaba lleno.
          final meta = await ref
              .read(dbServiceProvider)
              .getTrackMetadata(file.path);
          if (meta == null || (!meta.isManualCue && meta.cueInMs == 0)) {
            final localMs = await _getLocalDurationMs(file.path);
            await _processVocalBoundingBox(file.path, content, localMs);
          }
          continue;
        }
      }

      pipe.updateProgress(i + 1, total, filename, "Scraping LRC");

      await processSingleFile(file.path);

      await Future.delayed(const Duration(milliseconds: 150));
    }
    pipe.reset();
  }

  // Duración EXACTA con Rust (sin ffprobe), igual en las 4 plataformas.
  Future<int> _getLocalDurationSec(String filePath) async {
    try {
      final ms = await rust_dsp.exactDurationMs(inputPath: filePath);
      return (ms.toInt() / 1000).round();
    } catch (_) {}
    return 0;
  }

  // 3.1.02: duración exacta en ms, sin redondear, para los cues automáticos.
  Future<int> _getLocalDurationMs(String filePath) async {
    try {
      return (await rust_dsp.exactDurationMs(inputPath: filePath)).toInt();
    } catch (_) {}
    return 0;
  }

  Future<void> writeManualLyric(String audioPath, String syncedLyrics) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    // 3.1.72: en la biblioteca protegida la letra va al espejo local.
    await lrcWriteFile(audioPath, lrcPath).writeAsString(syncedLyrics);
    await _unmarkAuto(lrcPath); // letra fijada a mano: ya no es automática

    // Inyectar el Bounding Box al forzar letra manual
    final localMs = await _getLocalDurationMs(audioPath);
    await _processVocalBoundingBox(audioPath, syncedLyrics, localMs);

    debugPrint(
      "🟢 [NLP Tracker] LRC manual sobreescrito con éxito y Cues calculados.",
    );
  }

  /// 3.1.94: la busqueda manual del Laboratorio ya no consulta LRCLIB ni
  /// ninguna API (cero peticiones de letras): siempre "no disponible", sin
  /// filas. La firma queda para `lab_lyric_search.dart`.
  Future<
    ({List<LyricCandidate> rows, bool unavailable, LyricIdentity? fallback})
  >
  searchManualLyrics({
    required String artist,
    required String title,
    required int durationSec,
    String query = '',
    bool medley = false,
    String audioPath = '',
  }) async {
    lastDetail = 'Descarga de letras desactivada: solo Whisper local';
    return (rows: const <LyricCandidate>[], unavailable: true, fallback: null);
  }

  /// Energía y onset de la voz en los primeros 40 s. Null si no se puede medir.
  /// Inicio de voz (primeros 40 s). Público para el chequeo de Masterizar.
  Future<int?> probeVoiceOnsetMs(String audioPath) =>
      _probeVoiceOnsetMs(audioPath);

  Future<int?> _probeVoiceOnsetMs(String audioPath) async {
    if (audioPath.isEmpty) return null;
    try {
      final Uint8List pcm = await rust_dsp.decodeMonoPcm(
        inputPath: audioPath,
        startSecs: 0,
        lengthSecs: 40,
        targetRate: 8000,
      );
      final int n = pcm.length ~/ 2;
      if (n < 8000) return null;
      final ByteData data = ByteData.sublistView(pcm);
      final List<double> samples = List<double>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
      }
      return lyricVoiceOnsetMs(samples, 8000);
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberManualLyric(String lrcPath, {int? lrclibId}) async {
    try {
      final File f = File(lrcPath);
      final String folder = f.parent.path;
      final Map<String, dynamic> reg = _readAuto(folder);
      reg[f.uri.pathSegments.last] = <String, dynamic>{
        'bytes': f.existsSync() ? f.lengthSync() : 0,
        'id': lrclibId,
        'manual': true,
      };
      writeLyricsAuto(folder, reg);
    } catch (_) {}
  }

  /// 3.1.94: letra local (Whisper en escritorio). Sin red. No pisa un `.lrc`
  /// que ya existe. ok = letra nueva; noMatch = sin letra (movil, sin voz,
  /// error del modelo o pista larga).
  Future<LyricStatus> _fetchAndSaveLrc(String audioPath, String lrcPath) async {
    if (!lyricMayDownload(
      lrcExists: lrcReadFile(audioPath, lrcPath).existsSync(),
    )) {
      return LyricStatus.kept;
    }
    final String? wrote = await generateLocalLyricsOffline(
      audioPath,
      lrcPath: lrcPath,
    );
    if (wrote == null) {
      lastDetail = 'Sin letra local (Whisper)';
      return LyricStatus.noMatch;
    }
    if (wrote == lrcPath) await _markAuto(lrcPath);
    try {
      final String text = await File(wrote).readAsString();
      await _processVocalBoundingBox(
        audioPath,
        text,
        await _getLocalDurationMs(audioPath),
      );
    } catch (_) {}
    lastDetail = 'Letra local (Whisper)';
    debugPrint('[NLP] letra local: $wrote');
    return LyricStatus.ok;
  }

  /// 3.1.94: punto unico de letra automatica (YT, Masterizar, Radio,
  /// Automix). Ver [generateLocalLyricsOfflineWith].
  Future<String?> generateLocalLyricsOffline(
    String audioPath, {
    String? vocalsWavPath,
    String? lrcPath,
    bool Function()? shouldRun,
  }) => generateLocalLyricsOfflineWith(
    audioPath,
    deps: debugLocalLyricsDeps ?? LocalLyricsDeps.real(),
    vocalsWavPath: vocalsWavPath,
    lrcPath: lrcPath,
    shouldRun: shouldRun,
  );

  // ------------------------------------------- registro de letras AUTOMÁTICAS
  // Solo las letras que descargó esta app se anotan aquí. Las que tú arreglaste
  // (o cualquier .lrc que no esté en la lista) nunca se tocan ni se borran.

  Map<String, dynamic> _readAuto(String folder) {
    try {
      return readLyricsAuto(folder);
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _markAuto(String lrcPath) async {
    try {
      final f = File(lrcPath);
      final folder = f.parent.path;
      final reg = _readAuto(folder);
      reg[f.uri.pathSegments.last] = f.lengthSync();
      writeLyricsAuto(folder, reg);
    } catch (_) {}
  }

  Future<void> forgetLyricMark(String lrcPath) => _unmarkAuto(lrcPath);

  Future<void> _unmarkAuto(String lrcPath) async {
    try {
      final f = File(lrcPath);
      final folder = f.parent.path;
      final reg = _readAuto(folder);
      if (reg.remove(f.uri.pathSegments.last) != null) {
        writeLyricsAuto(folder, reg);
      }
    } catch (_) {}
  }

  /// RESET DE LETRAS: borra solo los .lrc descargados por la app que siguen
  /// SIN cambios (mismo tamaño). Nunca borra una letra fija o editada.
  /// Devuelve cuántas borró.
  Future<int> resetAutoLyrics(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return 0;
    int removed = 0;
    final folders = <String>{directoryPath};
    try {
      for (final e in dir.listSync(recursive: true)) {
        if (e is Directory) folders.add(e.path);
      }
    } catch (_) {}
    for (final folder in folders) {
      if (isCancelled != null && isCancelled()) break;
      if (_enCarpetaOriginal(folder)) continue;
      final reg = _readAuto(folder);
      if (reg.isEmpty) continue;
      final keep = <String, dynamic>{};
      reg.forEach((name, size) {
        final f = File('$folder${Platform.pathSeparator}$name');
        try {
          if (_autoIsManual(size)) {
            keep[name] = size;
            return;
          }
          final int? bytes = _autoBytes(size);
          if (f.existsSync() && bytes != null && f.lengthSync() == bytes) {
            final String text = f.readAsStringSync();
            if (lrcIsProtected(text) || lrcIsNoRetry(text)) {
              keep[name] = size;
            } else {
              f.deleteSync();
              removed++;
            }
          } else if (f.existsSync()) {
            keep[name] = size; // editada: ya no es automática, se respeta
          }
        } catch (_) {
          keep[name] = size;
        }
      });
      try {
        writeLyricsAuto(folder, keep);
      } catch (_) {}
    }
    return removed;
  }

  /// Resultado de intentar la letra de una pista.
  /// found = letra nueva o ya válida · notFound = sin coincidencia ·
  /// serverDown = tras 3 intentos sigue 429/5xx/timeout.
  /// La lógica de descarga no cambia: el detalle sigue en [processSingleFileStatus].
  Future<LyricFetchOutcome> processSingleFile(String filePath) async {
    return lyricFetchOutcomeFor(await processSingleFileStatus(filePath));
  }

  /// ok = letra nueva · kept = ya tenía una letra válida (no se toca) ·
  /// noMatch = sin coincidencia segura · failed = error / pista inexistente ·
  /// retry = servidor caído (429/5xx/timeout tras los intentos).
  Future<LyricStatus> processSingleFileStatus(String filePath) async {
    if (_enCarpetaOriginal(filePath)) return LyricStatus.kept;
    final file = File(filePath);
    if (!file.existsSync()) return LyricStatus.failed;

    final lrcPath = filePath.replaceAll(
      RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);

    if (lrcFile.existsSync()) {
      try {
        final content = await lrcFile.readAsString();
        if (lrcIsNoRetry(content) || lrcIsManual(content)) {
          return LyricStatus.kept;
        }
        final bool residual =
            content.contains('Letra no encontrada') ||
            content.contains('Error de conexión') ||
            content.contains('Error Auto-Healing') ||
            (lrcFile.lengthSync() <= 20 && !lrcIsDoubtful(content));
        if (residual) {
          debugPrint(
            "♻️ [NLP Auto-Healing] Letra residual/inválida detectada. Purgando para reintento: $lrcPath",
          );
          await lrcFile.delete();
        } else if (!pathIsLab(filePath)) {
          // Fuera del Laboratorio la letra que ya existe no se toca.
          return LyricStatus.kept;
        } else {
          return await _reviewLabLrc(filePath, lrcPath, content);
        }
      } catch (e) {
        debugPrint(
          "⚠️ [NLP I/O] Imposible leer .lrc existente, no se toca: $e",
        );
        return LyricStatus.failed;
      }
    }

    try {
      return await _fetchAndSaveLrc(filePath, lrcPath);
    } catch (e) {
      debugPrint("🔴 [NLP Scraper Fatal Error]: $e");
      return LyricStatus.failed;
    }
  }

  List<String> _siblingLrcs(String lrcPath) {
    final File self = File(lrcPath);
    final Directory dir = self.parent;
    if (!dir.existsSync()) return const <String>[];
    final String name = self.uri.pathSegments.last.toLowerCase();
    final List<String> out = <String>[];
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File) continue;
      final String n = e.uri.pathSegments.last.toLowerCase();
      if (!n.endsWith('.lrc') || n.endsWith('.bak') || n == name) continue;
      try {
        out.add(e.readAsStringSync());
      } catch (_) {}
    }
    return out;
  }

  /// En GatoMix_LAB: si la letra no cuadra y hay una mejor, la vieja queda
  /// en `.lrc.bak`. Si no hay mejor, se marca dudosa y se deja.
  Future<LyricStatus> _reviewLabLrc(
    String audioPath,
    String lrcPath,
    String content,
  ) async {
    final id3 = await loadId3TitleArtist(audioPath);
    final int localSec = await _getLocalDurationSec(audioPath);
    final List<LyricIdentity> ids = lyricIdentities(
      path: audioPath,
      id3Artist: id3.artist,
      id3Title: id3.title,
      id3Album: id3.album,
      durationSec: localSec,
    );
    final LyricIdentity id = ids.first;
    final List<String> siblings = _siblingLrcs(lrcPath);
    final LyricFileVerdict verdict = assessLabLyric(
      lrc: content,
      artist: id.artist,
      title: id.title,
      durationSec: localSec,
      siblingLrcs: siblings,
    );
    if (verdict.fits) return LyricStatus.kept;
    // 3.1.94: sin descarga de letras no hay candidata mejor.
    const LyricChoice choice = LyricChoice.none();
    final bool same =
        choice.hasText && lyricTextsMatch(choice.fileText, content);
    final bool better =
        choice.hasText && !same && !lyricDuplicates(choice.fileText, siblings);
    final LabLyricAction action = decideLabLyric(
      verdict: verdict,
      serverDown: choice.serverDown,
      hasBetter: better,
      sameText: same,
    );
    switch (action) {
      case LabLyricAction.keep:
        return LyricStatus.kept;
      case LabLyricAction.retry:
        return LyricStatus.retry;
      case LabLyricAction.replace:
        await writeLrcKeepingBak(lrcPath, choice.fileText);
        await _markAuto(lrcPath);
        if (choice.kind == LyricKind.synced) {
          await _processVocalBoundingBox(
            audioPath,
            choice.body,
            await _getLocalDurationMs(audioPath),
          );
          lastDetail = '';
          return LyricStatus.ok;
        }
        lastDetail = 'Letra plana (sin tiempos)';
        return LyricStatus.plain;
      case LabLyricAction.doubt:
        if (!lrcIsDoubtful(content)) {
          await File(lrcPath).writeAsString(markLrcDoubtful(content));
        }
        lastDetail = 'Letra dudosa';
        return LyricStatus.doubt;
    }
  }

  /// Descarga las letras de una carpeta y devuelve el conteo por resultado.
  Future<Map<LyricStatus, int>> downloadForDirectory(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final counts = <LyricStatus, int>{for (final s in LyricStatus.values) s: 0};
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return counts;
    final files = dir.listSync(recursive: true).whereType<File>().where((f) {
      if (_enCarpetaOriginal(f.path)) return false;
      final p = f.path.toLowerCase();
      return p.endsWith('.mp3') && !p.endsWith('_k.mp3');
    }).toList();
    final pipe = ref.read(pipelineProvider.notifier);
    final total = files.length;
    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) break;
      final f = files[i];
      if (_enCarpetaOriginal(f.path)) continue;
      final name = f.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, name, "📝 Letras");
      // Mix pesado (> 16 MB): no tiene letra.
      if (f.lengthSync() / (1024 * 1024) > 16.0) {
        counts[LyricStatus.kept] = counts[LyricStatus.kept]! + 1;
        continue;
      }
      final st = await processSingleFileStatus(f.path);
      counts[st] = counts[st]! + 1;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return counts;
  }
}

enum LyricStatus { ok, kept, noMatch, failed, retry, plain, doubt }

/// serverDown solo si el estado es el reintento tras 429/5xx/timeout.
LyricFetchOutcome lyricFetchOutcomeFor(LyricStatus status) {
  switch (status) {
    case LyricStatus.retry:
      return LyricFetchOutcome.serverDown;
    case LyricStatus.noMatch:
    case LyricStatus.failed:
      return LyricFetchOutcome.notFound;
    case LyricStatus.ok:
    case LyricStatus.kept:
    case LyricStatus.plain:
    case LyricStatus.doubt:
      return LyricFetchOutcome.found;
  }
}

int? _autoBytes(dynamic size) {
  if (size is num) return size.toInt();
  if (size is Map && size['bytes'] is num)
    return (size['bytes'] as num).toInt();
  return null;
}

bool _autoIsManual(dynamic size) => size is Map && size['manual'] == true;
