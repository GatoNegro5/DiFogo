import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/lyric_ai_align.dart';
import 'package:difogo/services/karaoke_engine.dart';

// 3.1.93 (Fase 2B): letra offline tras el _K. Solo %TEMP%, sin Rust, sin red:
// transcriptor y descargador falsos.

const String _words =
    '{"dur": 12.0, "lang": "es", "model": "base-q5_1", "words": '
    '[[1.5, 1.9, " Hola"], [2.0, 2.4, " mundo"]]}';
const String _lrc = '[00:01.50] Hola mundo\n';

void main() {
  late Directory tmp;
  late String src;
  final String sep = Platform.pathSeparator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('whisper_lyrics_3193_');
    src = '${tmp.path}${sep}Artista - Tema.mp3';
    File(src).writeAsBytesSync(List<int>.filled(16, 1));
    debugLibraryRoots = <String>['${tmp.path}${sep}Biblioteca'];
    debugLibraryCacheRoot = '${tmp.path}${sep}cache';
  });

  tearDown(() {
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    tmp.deleteSync(recursive: true);
  });

  List<String> vocalsLeft() => tmp
      .listSync(recursive: true)
      .map((FileSystemEntity e) => e.path)
      .where((String p) => p.contains('.vocals.wav'))
      .toList();

  // Simula a Rust: escribe la voz (y un .part viejo) y el _K sale bien.
  Future<bool> Function(String?) fakeSeparate(List<String?> seen) =>
      (String? vocals) async {
        seen.add(vocals);
        if (vocals != null) {
          File(vocals).writeAsBytesSync(List<int>.filled(4000, 0));
          File('$vocals.part').writeAsBytesSync(<int>[1, 2, 3]);
        }
        return true;
      };

  test(
    '3193 a) no pisa un .lrc existente; escribe el .gmx_words.json',
    () async {
      final File lrc = File(KaraokeEngine.lrcPathFor(src))
        ..writeAsStringSync('[00:05.00] letra del usuario\n');
      final List<String?> seen = <String?>[];
      int calls = 0;
      final OfflineLyricsOutcome r =
          await KaraokeEngine.separateWithOfflineLyrics(
            src: src,
            desktop: true,
            tempDir: tmp.path,
            separate: fakeSeparate(seen),
            fetchModel: () async => 'modelo.bin',
            transcribe: (String wav, String m) async {
              calls++;
              expect(File(wav).existsSync(), isTrue);
              expect(m, 'modelo.bin');
              return (wordsJson: _words, lrcText: _lrc);
            },
          );
      expect(r.kOk, isTrue);
      expect(calls, 1);
      expect(seen.single, isNotNull);
      expect(seen.single!.startsWith(tmp.path), isTrue);
      expect(r.wroteWords, isTrue);
      expect(r.wroteLrc, isFalse);
      expect(lrc.readAsStringSync(), '[00:05.00] letra del usuario\n');
      expect(
        File(KaraokeEngine.gmxWordsPathFor(src)).readAsStringSync(),
        _words,
      );
      expect(vocalsLeft(), isEmpty);
    },
  );

  test(
    '3193 b) sin .lrc escribe .gmx_words.json y .lrc (forma de Dart)',
    () async {
      final OfflineLyricsOutcome r =
          await KaraokeEngine.separateWithOfflineLyrics(
            src: src,
            desktop: true,
            tempDir: tmp.path,
            separate: fakeSeparate(<String?>[]),
            fetchModel: () async => 'm',
            transcribe: (String wav, String m) async =>
                (wordsJson: _words, lrcText: _lrc),
          );
      expect(
        (r.kOk, r.wroteWords, r.wroteLrc, r.error),
        (true, true, true, null),
      );
      final String jsonPath = KaraokeEngine.gmxWordsPathFor(src);
      expect(jsonPath, '${tmp.path}${sep}Artista - Tema.gmx_words.json');
      final List<TimedWord> w = parseTimedWordsJson(
        File(jsonPath).readAsStringSync(),
      );
      expect(w.map((TimedWord x) => x.startMs).toList(), <int>[1500, 2000]);
      expect(w.first.text, ' Hola');
      expect(
        File('${tmp.path}${sep}Artista - Tema.lrc').readAsStringSync(),
        _lrc,
      );
      expect(File('$jsonPath.part').existsSync(), isFalse);
      expect(vocalsLeft(), isEmpty);

      // Con las dos letras ya hechas no se pide voz ni se transcribe.
      final List<String?> seen = <String?>[];
      final OfflineLyricsOutcome again =
          await KaraokeEngine.separateWithOfflineLyrics(
            src: src,
            desktop: true,
            tempDir: tmp.path,
            separate: fakeSeparate(seen),
            fetchModel: () async => fail('no debe bajar'),
            transcribe: (String wav, String m) async => fail('no debe llamar'),
          );
      expect(again.kOk, isTrue);
      expect(seen, <String?>[null]);
    },
  );

  test('3193 c) error de la transcripcion: _K OK y la voz se borra', () async {
    final OfflineLyricsOutcome r =
        await KaraokeEngine.separateWithOfflineLyrics(
          src: src,
          desktop: true,
          tempDir: tmp.path,
          separate: fakeSeparate(<String?>[]),
          fetchModel: () async => 'm',
          transcribe: (String wav, String m) async =>
              throw StateError('whisper fallo'),
        );
    expect(r.kOk, isTrue);
    expect(r.error, contains('whisper fallo'));
    expect((r.wroteWords, r.wroteLrc), (false, false));
    expect(vocalsLeft(), isEmpty);
    expect(File(KaraokeEngine.gmxWordsPathFor(src)).existsSync(), isFalse);
    expect(File(KaraokeEngine.lrcPathFor(src)).existsSync(), isFalse);

    // Sin internet (falla la descarga): igual, _K OK y sin temporales.
    final OfflineLyricsOutcome r2 =
        await KaraokeEngine.separateWithOfflineLyrics(
          src: src,
          desktop: true,
          tempDir: tmp.path,
          separate: fakeSeparate(<String?>[]),
          fetchModel: () async => throw const SocketException('sin red'),
          transcribe: (String wav, String m) async => fail('no debe llamar'),
        );
    expect((r2.kOk, r2.error != null), (true, true));
    expect(vocalsLeft(), isEmpty);

    // Si la separacion falla, el error sube y la voz tambien se borra.
    await expectLater(
      KaraokeEngine.separateWithOfflineLyrics(
        src: src,
        desktop: true,
        tempDir: tmp.path,
        separate: (String? v) async {
          File(v!).writeAsBytesSync(<int>[0]);
          throw StateError('rust fallo');
        },
        fetchModel: () async => fail('no debe bajar'),
        transcribe: (String wav, String m) async => fail('no debe llamar'),
      ),
      throwsStateError,
    );
    expect(vocalsLeft(), isEmpty);
  });

  test(
    '3193 d) movil y biblioteca: sin voz, sin descarga, sin escrituras',
    () async {
      for (final (bool desktop, String path) in <(bool, String)>[
        (false, src),
        (true, '${tmp.path}${sep}Biblioteca${sep}Otro - Tema.mp3'),
      ]) {
        final List<String?> seen = <String?>[];
        final OfflineLyricsOutcome r =
            await KaraokeEngine.separateWithOfflineLyrics(
              src: path,
              desktop: desktop,
              tempDir: tmp.path,
              separate: fakeSeparate(seen),
              fetchModel: () async => fail('no debe bajar'),
              transcribe: (String wav, String m) async =>
                  fail('no debe llamar'),
            );
        expect(r.kOk, isTrue);
        expect(seen, <String?>[null]);
        expect(File(KaraokeEngine.gmxWordsPathFor(path)).existsSync(), isFalse);
        expect(File(KaraokeEngine.lrcPathFor(path)).existsSync(), isFalse);
      }
      expect(KaraokeEngine.wantsOfflineLyrics(src, desktop: false), isFalse);
      expect(vocalsLeft(), isEmpty);
    },
  );
}
