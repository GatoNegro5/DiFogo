import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:difogo/src/rust/api/core_dsp.dart' as rust_dsp;
import 'package:difogo/src/rust/api/whisper_lrc.dart' as rust_whisper;

import '../core/gatomix_store.dart' show saveWhisperLang;
import '../core/library_guard.dart';
import '../core/splice_retry.dart';
import '../core/lyric_ai_align.dart' show parseTimedWordsJson;
import '../core/lyric_match.dart' show lyricMayDownload;
import '../providers/pipeline_provider.dart' show HeavyWorkGate;

/// Karaoke IA 100 % en proceso (Rust + ONNX, modelo MDX-Net/UVR).
/// Sin Python, sin Demucs, sin FFmpeg. Genera `<nombre>_K.mp3` junto a la
/// pista original. El modelo (~64 MB) se descarga la primera vez.
class KaraokeEngine {
  static const String modelFile = 'UVR-MDX-NET-Inst_HQ_3.onnx';
  static const String modelUrl =
      'https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/$modelFile';
  static const int _modelMinBytes = 60 * 1024 * 1024;
  static const String suffix = '_K';

  /// 3.1.93: letra offline (whisper.cpp) en escritorio. Modelo base q5_1
  /// (MIT), 59.707.625 B; menos de 55 MB = descarga cortada.
  static const String whisperModelFile = 'ggml-base-q5_1.bin';
  static const String whisperModelUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$whisperModelFile';
  static const int _whisperMinBytes = 55 * 1024 * 1024;

  /// La cola se detiene al terminar la pista en curso.
  static bool stopQueue = false;
  static bool _busy = false;
  static bool get busy => _busy;

  static String karaokePathFor(String src) {
    final dot = src.lastIndexOf('.');
    return '${src.substring(0, dot)}$suffix.mp3';
  }

  /// Un _K existente solo vale si no está truncado.
  static bool usableInstrumental(String karaoke, String source) {
    final f = File(karaoke);
    if (!f.existsSync()) return false;
    final len = f.lengthSync();
    if (len < 256 * 1024) return false;
    final s = File(source);
    if (s.existsSync()) {
      final srcLen = s.lengthSync();
      if (srcLen > 0 && len < srcLen * 0.45) return false;
    }
    return true;
  }

  /// 3.1.08-3.1.15: tope de RAM del karaoke en Rust: 30:00. Desde 3.1.16
  /// `karaoke_separate` va por ventanas sin tope; queda para los _K viejos.
  static const int capMs = 1800000;

  /// 1800 s a 320 kbps CBR (salida fija de `Mp3Sink`) = 72.000.000 B.
  /// Un _K mas chico no pudo cortarse en el tope: no se mide su duracion.
  static const int capBytes = 1800 * 320000 ~/ 8;

  /// Tolerancia por el delay/padding de LAME entre fuente y _K.
  static const int padToleranceMs = 1000;

  static bool needsDurationCheck(int karaokeBytes) => karaokeBytes >= capBytes;

  /// Decision pura. `kMs` null = sin _K que revisar. `srcMs` null = no se pudo
  /// medir (se encola y la guardia de Rust decide).
  static KaraokeWork karaokeNeedsWork({int? srcMs, int? kMs}) {
    if (srcMs != null && kMs != null && kMs + padToleranceMs >= srcMs) {
      return KaraokeWork.done;
    }
    return KaraokeWork.queue;
  }

  /// 3.1.16: espera maxima de una separacion: 3 veces la duracion (factor sin
  /// medir, se ajusta con un log real), minimo 10 min; sin duracion, 60 min.
  static Duration karaokeTimeout(int? srcMs) {
    if (srcMs == null || srcMs <= 0) return const Duration(minutes: 60);
    final int ms = srcMs * 3;
    return Duration(milliseconds: ms < 600000 ? 600000 : ms);
  }

  static Future<(KaraokeWork, int?)> _decide(String src) async {
    int? srcMs;
    int? kMs;
    try {
      srcMs = (await rust_dsp.exactDurationMs(inputPath: src)).toInt();
      final String k = karaokePathFor(src);
      if (usableInstrumental(k, src) &&
          needsDurationCheck(File(k).lengthSync())) {
        kMs = (await rust_dsp.exactDurationMs(inputPath: k)).toInt();
      }
    } catch (e) {
      debugPrint('[KARAOKE] duracion no medida: $e');
    }
    return (karaokeNeedsWork(srcMs: srcMs, kMs: kMs), srcMs);
  }

  static Future<String> ensureModel({void Function(double)? onProgress}) =>
      _ensureDownload(modelFile, modelUrl, _modelMinBytes, onProgress);

  /// 3.1.93: el modelo de Whisper va a la misma carpeta `models` que el
  /// `.onnx`, una sola vez, con `.part` y rename (mismo patron).
  static Future<String> ensureWhisperModel({
    void Function(double)? onProgress,
  }) => _ensureDownload(
    whisperModelFile,
    whisperModelUrl,
    _whisperMinBytes,
    onProgress,
  );

  static Future<String> _ensureDownload(
    String file,
    String url,
    int minBytes,
    void Function(double)? onProgress,
  ) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = '${dir.path}${Platform.pathSeparator}$file';
    final f = File(path);
    if (f.existsSync() && f.lengthSync() >= minBytes) return path;

    final tmp = File('$path.part');
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        throw Exception('Descarga del modelo falló (HTTP ${resp.statusCode})');
      }
      final total = resp.contentLength ?? 0;
      var got = 0;
      final sink = tmp.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
      await sink.close();
      if (tmp.lengthSync() < minBytes) {
        throw Exception('Modelo incompleto');
      }
      if (f.existsSync()) f.deleteSync();
      await tmp.rename(path);
      return path;
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  static bool get offlineLyricsPlatform =>
      Platform.isWindows || Platform.isMacOS;

  /// Mismo nombre que lee `MasterTrack.aiAlignFromSidecar` (cambia `.mp3`).
  static String gmxWordsPathFor(String src) => src.replaceAll(
    RegExp(r'\.mp3$', caseSensitive: false),
    '.gmx_words.json',
  );

  /// Mismo nombre que usa Automix para la letra de la pista.
  static String lrcPathFor(String src) =>
      src.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc');

  /// 3.1.93: pedir la voz solo en escritorio, para un mp3 fuera de la
  /// biblioteca protegida y si falta el `.gmx_words.json` o el `.lrc`.
  static bool wantsOfflineLyrics(String src, {required bool desktop}) {
    if (!desktop || !src.toLowerCase().endsWith('.mp3')) return false;
    if (isLibraryPath(src)) return false;
    final bool haveWords = File(gmxWordsPathFor(src)).existsSync();
    final bool haveLrc = lrcReadFile(src, lrcPathFor(src)).existsSync();
    return !(haveWords && haveLrc);
  }

  /// Voz temporal: siempre en la carpeta temporal del sistema.
  static String vocalsTempPath({String? tempDir}) {
    final String dir = tempDir ?? Directory.systemTemp.path;
    return '$dir${Platform.pathSeparator}gatomix_${pid}_'
        '${DateTime.now().microsecondsSinceEpoch}.vocals.wav';
  }

  static void deleteVocalsTemp(String vocals) {
    for (final String p in <String>[vocals, '$vocals.part']) {
      try {
        final File f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        debugPrint('[KARAOKE] no se pudo borrar $p: $e');
      }
    }
  }

  static void _writeAtomic(File f, String text) {
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

  /// 3.1.93: un pase de karaoke con letra offline (best effort). Separa con
  /// la voz a un temporal si hace falta, y tras el `_K` (si salio bien y no
  /// cancelaron) baja el modelo y transcribe dentro de [gate]. Un error de la
  /// letra solo se anota: el `_K` queda. El `.vocals.wav` (y su `.part`) se
  /// borra SIEMPRE en el finally. Un error de [separate] se propaga.
  static Future<OfflineLyricsOutcome> separateWithOfflineLyrics({
    required String src,
    required bool desktop,
    required Future<bool> Function(String? vocalsPath) separate,
    required OfflineModelFetcher fetchModel,
    required OfflineTranscriber transcribe,
    void Function()? onSeparated,
    bool Function()? cancelled,
    Future<void> Function(Future<void> Function() job)? gate,
    String? tempDir,
  }) async {
    final String? vocals = wantsOfflineLyrics(src, desktop: desktop)
        ? vocalsTempPath(tempDir: tempDir)
        : null;
    bool kOk = false;
    bool words = false;
    bool lrc = false;
    String? error;
    try {
      kOk = await separate(vocals);
      if (kOk) onSeparated?.call();
      if (kOk && vocals != null && !(cancelled?.call() ?? false)) {
        Future<void> job() async {
          try {
            final (bool w, bool l) = await _writeOfflineLyrics(
              src: src,
              vocalsPath: vocals,
              fetchModel: fetchModel,
              transcribe: transcribe,
            );
            words = w;
            lrc = l;
          } catch (e) {
            error = '$e';
            debugPrint('[KARAOKE] letra offline omitida: $e');
          }
        }

        if (gate != null) {
          await gate(job);
        } else {
          await job();
        }
      }
    } finally {
      if (vocals != null) deleteVocalsTemp(vocals);
    }
    return OfflineLyricsOutcome(
      kOk: kOk,
      wroteWords: words,
      wroteLrc: lrc,
      error: error,
    );
  }

  static Future<(bool, bool)> _writeOfflineLyrics({
    required String src,
    required String vocalsPath,
    required OfflineModelFetcher fetchModel,
    required OfflineTranscriber transcribe,
  }) async {
    final File wav = File(vocalsPath);
    if (!wav.existsSync() || wav.lengthSync() <= 44) {
      throw StateError('sin pista vocal');
    }
    final String wordsPath = gmxWordsPathFor(src);
    final String lrcPath = lrcPathFor(src);
    // 3.1.72: nada junto al audio de la biblioteca protegida.
    if (libraryWriteBlocked(wordsPath, what: 'Letra offline')) {
      return (false, false);
    }
    final String model = await fetchModel();
    final ({String wordsJson, String lrcText}) t = await transcribe(
      vocalsPath,
      model,
    );
    // 3.2.3: idioma detectado por Whisper -> dna[src].lang.
    await saveWhisperLang(src, t.wordsJson);
    bool wroteWords = false;
    bool wroteLrc = false;
    final File wordsFile = File(wordsPath);
    // Mismo lector que Masterizar; sin palabras no se escribe nada.
    if (!wordsFile.existsSync() &&
        parseTimedWordsJson(t.wordsJson).isNotEmpty) {
      _writeAtomic(wordsFile, t.wordsJson);
      wroteWords = true;
    }
    // Un .lrc que ya existe (del usuario o bajado) nunca se pisa.
    if (t.lrcText.trim().isNotEmpty &&
        lyricMayDownload(lrcExists: lrcReadFile(src, lrcPath).existsSync())) {
      final File out = lrcWriteFile(src, lrcPath);
      if (!out.existsSync()) {
        _writeAtomic(out, t.lrcText);
        wroteLrc = true;
      }
    }
    return (wroteWords, wroteLrc);
  }

  static Future<({String wordsJson, String lrcText})> _rustTranscribe(
    String wavPath,
    String modelPath,
  ) async {
    final rust_whisper.WhisperTranscript t = await rust_whisper
        .transcribeVocalsWav(
          wavPath: wavPath,
          modelPath: modelPath,
          language: null,
        );
    debugPrint('[KARAOKE] letra offline: idioma ${t.detectedLang}');
    return (wordsJson: t.wordsJson, lrcText: t.lrcText);
  }

  static List<String> _collect(String path) {
    if (File(path).existsSync()) return [path];
    final out = <String>[];
    for (final e in Directory(
      path,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final p = e.path;
      final low = p.toLowerCase();
      if (!low.endsWith('.mp3') ||
          low.endsWith('${suffix.toLowerCase()}.mp3')) {
        continue;
      }
      final String k = karaokePathFor(p);
      // 3.1.08: un _K que llega al tope de 30:00 se revisa por duracion en run().
      if (usableInstrumental(k, p) &&
          !needsDurationCheck(File(k).lengthSync())) {
        continue;
      }
      out.add(p);
    }
    out.sort();
    return out;
  }

  static String _name(String p) => p
      .split(Platform.pathSeparator)
      .last
      .replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '');

  /// Procesa un archivo o una carpeta, de a una pista. `onStatus` recibe texto
  /// de avance para la UI. Devuelve cuántas pistas quedaron listas.
  static Future<int> run(String path, {void Function(String)? onStatus}) async {
    if (_busy) return 0;
    _busy = true;
    stopQueue = false;
    var done = 0;
    try {
      onStatus?.call('Preparando modelo de IA…');
      final model = await ensureModel(
        onProgress: (p) => onStatus?.call(
          'Descargando modelo de IA (solo la 1.ª vez): ${(p * 100).round()}%',
        ),
      );

      final files = _collect(path);
      if (files.isEmpty) onStatus?.call('No hay pistas pendientes.');
      for (var i = 0; i < files.length; i++) {
        if (stopQueue) {
          onStatus?.call('Cola cancelada. Última pista cerrada.');
          break;
        }
        final src = files[i];
        final name = _name(src);
        final label = files.length > 1
            ? '(${i + 1}/${files.length}) $name'
            : name;
        // 3.1.72: el _K iria junto al audio: nunca en la biblioteca.
        if (libraryWriteBlocked(src, what: 'Karaoke')) continue;
        final (KaraokeWork work, int? srcMs) = await _decide(src);
        if (work == KaraokeWork.done) continue;
        onStatus?.call('Analizando: $label');
        final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
          try {
            final p = await rust_dsp.karaokeProgress();
            onStatus?.call('Aislando Voces: ${(p * 100).round()}% - $label');
          } catch (_) {}
        });
        try {
          // 3.1.93: en escritorio la voz sale en el mismo pase a un temporal y,
          // tras el _K, la letra offline corre en su propio turno del candado.
          final OfflineLyricsOutcome res = await separateWithOfflineLyrics(
            src: src,
            desktop: offlineLyricsPlatform,
            // 3.1.19: candado termico global; si cancelan mientras espera
            // turno, no arranca la separacion.
            separate: (String? vocals) => HeavyWorkGate.run(
              'karaoke',
              () async {
                if (stopQueue) return false;
                final Future<bool> sep = vocals == null
                    ? rust_dsp.karaokeSeparate(
                        inputPath: src,
                        modelPath: model,
                        outputPath: karaokePathFor(src),
                      )
                    : rust_dsp.karaokeSeparateWith(
                        inputPath: src,
                        modelPath: model,
                        outputPath: karaokePathFor(src),
                        vocalsOutPath: vocals,
                      );
                try {
                  await sep.timeout(karaokeTimeout(srcMs));
                } on TimeoutException {
                  // 3.1.16: el timeout de Dart no frena a Rust: se cancela y se
                  // espera a que cierre el bloque en curso (borra su .part).
                  await rust_dsp.karaokeCancel();
                  await sep.then((_) => true, onError: (_) => false);
                  rethrow;
                }
                return true;
              },
            ),
            onSeparated: () {
              timer.cancel();
              done++;
              onStatus?.call('¡Instrumental Listo!: $label');
            },
            cancelled: () => stopQueue,
            gate: (Future<void> Function() job) =>
                HeavyWorkGate.run<void>('whisper', job),
            fetchModel: () => ensureWhisperModel(
              onProgress: (p) => onStatus?.call(
                'Descargando modelo de letra (solo la 1.ª vez): '
                '${(p * 100).round()}%',
              ),
            ),
            transcribe: (String wav, String m) {
              onStatus?.call('Transcribiendo letra: $label');
              return _rustTranscribe(wav, m);
            },
          );
          if (!res.kOk) break;
          if (res.wroteWords || res.wroteLrc) {
            onStatus?.call('Letra offline lista: $label');
          }
        } catch (e) {
          debugPrint('🔴 [KARAOKE] $name: $e');
          // 3.2.33: la _K solo nace de un mp3 que pasa el detector.
          if (isSpliceError(e)) {
            logSpliceEvent('K $src', e);
            onStatus?.call('Sin _K (empalme en el mp3): $label');
          } else {
            onStatus?.call('Falló: $label');
          }
        } finally {
          timer.cancel();
        }
      }
    } catch (e) {
      debugPrint('🔴 [KARAOKE FATAL] $e');
      onStatus?.call('Error: $e');
    } finally {
      _busy = false;
    }
    return done;
  }
}

/// 3.1.93: transcriptor y descargador inyectables (pruebas sin Rust ni red).
typedef OfflineTranscriber =
    Future<({String wordsJson, String lrcText})> Function(
      String wavPath,
      String modelPath,
    );
typedef OfflineModelFetcher = Future<String> Function();

/// 3.1.93: resultado de un pase con letra offline (log y pruebas).
class OfflineLyricsOutcome {
  final bool kOk;
  final bool wroteWords;
  final bool wroteLrc;
  final String? error;
  const OfflineLyricsOutcome({
    required this.kOk,
    required this.wroteWords,
    required this.wroteLrc,
    this.error,
  });
}

/// 3.1.08: decision por pista antes de separar.
/// queue = separar, done = _K completo. 3.1.16: sin tooLong (streaming).
enum KaraokeWork { queue, done }
