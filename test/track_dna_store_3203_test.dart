// 3.2.3: seccion `dna` del documento por carpeta. Lectura/escritura en el
// espejo para la biblioteca protegida, mezcla idioma/metricas sin perder
// datos y cero escrituras junto al audio protegido. Sin Rust ni red.
import 'dart:io';
import 'dart:typed_data';

import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/providers/nlp_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const String _lrc = '[00:01.00] hola mundo\n';
String _words(String lang) =>
    '{"dur": 4.0, "lang": "$lang", "model": "base", '
    '"words": [[1.0, 1.4, " hola"], [1.5, 2.0, " mundo"]]}';

void main() {
  final String sep = Platform.pathSeparator;
  late Directory root;
  late String libDir;
  late String cacheDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('difogo_dna3203_');
    libDir = '${root.path}${sep}Biblioteca';
    cacheDir = '${root.path}${sep}cache';
    Directory('$libDir${sep}Salsa').createSync(recursive: true);
    debugLibraryRoots = <String>[libDir];
    debugLibraryCacheRoot = cacheDir;
  });

  tearDown(() {
    GatomixStore.forget(<String>['$libDir${sep}Salsa', '${root.path}${sep}dl']);
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugLocalLyricsDeps = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  String mk(String dir, String name) {
    final File f = File('$dir$sep$name');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(32, 7));
    return f.path;
  }

  List<String> libFiles() => Directory(libDir)
      .listSync(recursive: true)
      .whereType<File>()
      .map((File f) => f.path)
      .toList();

  test('3203 a) dna en el espejo; idioma y metricas se mezclan', () async {
    final String audio = mk('$libDir${sep}Salsa', 'Artista - Tema.mp3');
    final List<String> before = libFiles();
    final int blocked = libraryGuardBlocked;

    expect(readTrackDna(audio), isNull);
    expect(
      await saveTrackDna(
        audio,
        const TrackDnaEntry(
          energy: 0.8,
          bassRatio: 0.3,
          brightness: 0.6,
          beatDensity: 0.5,
          genre: 'Salsa',
          year: 1998,
          mtimeMs: 123456,
        ),
      ),
      isTrue,
    );
    // Guardar el idioma no borra las metricas.
    expect(await saveWhisperLang(audio, _words(' ES ')), isTrue);
    TrackDnaEntry? d = readTrackDna(audio);
    expect(d, isNotNull);
    expect(
      (d!.energy, d.bassRatio, d.brightness, d.beatDensity),
      (0.8, 0.3, 0.6, 0.5),
    );
    expect((d.genre, d.year, d.mtimeMs, d.lang), ('Salsa', 1998, 123456, 'es'));

    // Guardar metricas nuevas no borra el idioma.
    await saveTrackDna(
      audio,
      const TrackDnaEntry(energy: 0.2, beatDensity: 0.9, mtimeMs: 999),
    );
    GatomixStore.forget(<String>['$libDir${sep}Salsa']);
    d = readTrackDna(audio);
    expect((d!.energy, d.beatDensity, d.mtimeMs), (0.2, 0.9, 999));
    expect((d.bassRatio, d.brightness, d.lang), (0.3, 0.6, 'es'));

    // Cero escrituras en la biblioteca protegida; el espejo existe.
    expect(libFiles(), before);
    final File mirror = GatomixStore.fileOf('$libDir${sep}Salsa');
    expect(mirror.path.startsWith(cacheDir), isTrue);
    expect(mirror.existsSync(), isTrue);
    expect(mirror.readAsStringSync(), contains('"dna"'));
    expect(libraryGuardBlocked, blocked);
  });

  test(
    '3203 b) idioma invalido no escribe; valores fuera de 0-1 se recortan',
    () async {
      final String audio = mk('$libDir${sep}Salsa', 'Otra.mp3');
      for (final String w in <String>[
        _words('auto'),
        _words(''),
        _words('espanol'),
        _words('e1'),
        '{"words": []}',
        'no es json',
      ]) {
        expect(await saveWhisperLang(audio, w), isFalse);
      }
      expect(GatomixStore.fileOf('$libDir${sep}Salsa').existsSync(), isFalse);
      expect(whisperLangCode('pt'), 'pt');
      expect(whisperLangCode('yue'), 'yue');

      await saveTrackDna(
        audio,
        const TrackDnaEntry(energy: 1.7, bassRatio: -0.4, brightness: 0.5),
      );
      final TrackDnaEntry d = readTrackDna(audio)!;
      expect((d.energy, d.bassRatio, d.brightness), (1.0, 0.0, 0.5));
      expect(d.lang, isNull);
      expect(libFiles().where((String p) => p.endsWith('.json')), isEmpty);
    },
  );

  test(
    '3203 c) Whisper offline guarda dna.lang en el espejo, nada al lado',
    () async {
      final String audio = mk('$libDir${sep}Salsa', 'Cancion.mp3');
      final List<String> before = libFiles();
      final LocalLyricsDeps deps = LocalLyricsDeps(
        desktop: true,
        tempDir: root.path,
        fetchModel: () async => '${root.path}${sep}fake.bin',
        transcribe: (String wav, String model) async =>
            (wordsJson: _words('pt'), lrcText: _lrc),
        decode: (String a, int maxSecs) async => Uint8List(16000 * 2 * 2),
        durationMs: (String a) async => 4000,
        gate: (String label, Future<String?> Function() job) => job(),
      );
      final String? out = await generateLocalLyricsOfflineWith(
        audio,
        deps: deps,
      );
      expect(out, isNotNull);
      expect(out!.startsWith(cacheDir), isTrue);
      expect(readTrackDna(audio)?.lang, 'pt');
      expect(libFiles(), before);
    },
  );

  test(
    '3203 d) fuera de la biblioteca usa el documento de la carpeta',
    () async {
      final String audio = mk('${root.path}${sep}dl', 'Tema.mp3');
      await saveTrackDna(audio, const TrackDnaEntry(lang: 'en', year: 2001));
      final File doc = File('${root.path}${sep}dl$sep$gatomixStoreName');
      expect(doc.existsSync(), isTrue);
      expect(readTrackDna(audio)?.lang, 'en');
      expect(readTrackDna(audio)?.year, 2001);
    },
  );

  test('3203 e) karaoke y nlp persisten el idioma (fuente)', () {
    final String k = File(
      'lib/services/karaoke_engine.dart',
    ).readAsStringSync();
    final String n = File('lib/providers/nlp_provider.dart').readAsStringSync();
    expect(k, contains('await saveWhisperLang(src, t.wordsJson);'));
    expect(n, contains('await saveWhisperLang(audioPath, t.wordsJson);'));
  });
}
