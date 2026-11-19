// 3.1.94: letras 100 % locales (Whisper). Sin HTTP de letras, respeta el
// .lrc existente y en la biblioteca protegida escribe solo en el espejo.
import 'dart:io';
import 'dart:typed_data';

import 'package:difogo/core/library_guard.dart';
import 'package:difogo/providers/nlp_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingHttp extends HttpOverrides {
  int created = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}

const String _lrc = '[00:01.00] hola mundo\n[00:03.50] otra linea\n';
const String _words =
    '{"dur": 4.0, "lang": "es", "model": "base", '
    '"words": [[1.0, 1.4, " hola"], [1.5, 2.0, " mundo"]]}';

void main() {
  late Directory root;
  late List<String> calls;
  late List<String> gates;
  late List<String> wavsSeen;
  late _CountingHttp http;

  LocalLyricsDeps deps({
    bool desktop = true,
    bool throwOnTranscribe = false,
    int durMs = 4000,
  }) => LocalLyricsDeps(
    desktop: desktop,
    tempDir: root.path,
    fetchModel: () async {
      calls.add('model');
      return '${root.path}${Platform.pathSeparator}fake.bin';
    },
    transcribe: (String wav, String model) async {
      calls.add('transcribe');
      wavsSeen.add(wav);
      expect(File(wav).existsSync(), isTrue);
      if (throwOnTranscribe) throw StateError('boom');
      return (wordsJson: _words, lrcText: _lrc);
    },
    decode: (String audio, int maxSecs) async {
      calls.add('decode');
      return Uint8List(16000 * 2 * 2);
    },
    durationMs: (String audio) async => durMs,
    gate: (String label, Future<String?> Function() job) {
      gates.add(label);
      return job();
    },
  );

  String mk(String rel, [String body = 'x']) {
    final File f = File('${root.path}${Platform.pathSeparator}$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
    return f.path;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('difogo_lyr3194_');
    calls = <String>[];
    gates = <String>[];
    wavsSeen = <String>[];
    http = _CountingHttp();
    debugLibraryRoots = <String>[];
    debugLibraryCacheRoot = '${root.path}${Platform.pathSeparator}cache';
  });

  tearDown(() {
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugLocalLyricsDeps = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<String?> run(String audio, LocalLyricsDeps d, {bool Function()? s}) =>
      HttpOverrides.runZoned(
        () => generateLocalLyricsOfflineWith(audio, deps: d, shouldRun: s),
        createHttpClient: http.createHttpClient,
      );

  test('(a) genera local sin ninguna peticion HTTP y borra el wav', () async {
    final String a = mk('dl/cancion.mp3');
    final String? out = await run(a, deps());
    expect(out, localLyricsLrcPath(a));
    expect(File(out!).readAsStringSync(), _lrc);
    expect(File(a.replaceAll('.mp3', '.gmx_words.json')).existsSync(), isTrue);
    expect(http.created, 0);
    expect(gates, <String>['whisper-lyrics']);
    expect(calls, <String>['decode', 'model', 'transcribe']);
    expect(wavsSeen.single.startsWith(root.path), isTrue);
    expect(File(wavsSeen.single).existsSync(), isFalse);
  });

  test('(b) respeta .lrc existente junto al audio y en el espejo', () async {
    final String a = mk('dl/tiene.mp3');
    mk('dl/tiene.lrc', 'MIO');
    expect(await run(a, deps()), isNull);
    expect(File(localLyricsLrcPath(a)).readAsStringSync(), 'MIO');

    final String lib = '${root.path}${Platform.pathSeparator}lib';
    debugLibraryRoots = <String>[lib];
    final String b = mk('lib/protegida.mp3');
    final File m = libraryLrcMirror(b);
    m.parent.createSync(recursive: true);
    m.writeAsStringSync('ESPEJO');
    expect(await run(b, deps()), isNull);
    expect(m.readAsStringSync(), 'ESPEJO');
    expect(calls, isEmpty);
    expect(http.created, 0);
  });

  test('(c) biblioteca protegida: solo espejo via lrcWriteFile', () async {
    final String lib = '${root.path}${Platform.pathSeparator}lib';
    debugLibraryRoots = <String>[lib];
    final String a = mk('lib/artista/tema.mp3');
    final String lrc = localLyricsLrcPath(a);
    final String? out = await run(a, deps());
    expect(out, lrcWriteFile(a, lrc).path);
    expect(out, libraryLrcMirror(a).path);
    expect(out!.startsWith(debugLibraryCacheRoot!), isTrue);
    expect(File(out).readAsStringSync(), _lrc);
    expect(File(lrc).existsSync(), isFalse);
    expect(File(a.replaceAll('.mp3', '.gmx_words.json')).existsSync(), isFalse);
    expect(http.created, 0);
  });

  test('movil, pista cambiada y error: nada, wav borrado', () async {
    final String a = mk('dl/otra.mp3');
    expect(await run(a, deps(desktop: false)), isNull);
    expect(await run(a, deps(), s: () => false), isNull);
    expect(calls, isEmpty);
    expect(await run(a, deps(throwOnTranscribe: true)), isNull);
    expect(File(wavsSeen.single).existsSync(), isFalse);
    expect(File(localLyricsLrcPath(a)).existsSync(), isFalse);
    expect(await run(a, deps(durMs: kLocalLyricsMaxMs + 1)), isNull);
    expect(http.created, 0);
  });

  test('fuente: flujos de YT, Masterizar y Radio sin LRCLIB ni subtitulos', () {
    for (final String p in <String>[
      'lib/providers/nlp_provider.dart',
      'lib/services/master_track.dart',
      'lib/ui/workspaces/yt_workspace.dart',
      'lib/providers/curator_provider.dart',
      'lib/providers/automix_provider.dart',
    ]) {
      final String s = File(p).readAsStringSync();
      expect(s.contains('lrclib.net'), isFalse, reason: p);
      expect(s.contains('closedCaptions'), isFalse, reason: p);
      expect(s.contains('http.get'), isFalse, reason: p);
      expect(s.contains('lookupSafeLyric'), isFalse, reason: p);
      expect(s.contains("package:http/http.dart"), isFalse, reason: p);
    }
  });
}
