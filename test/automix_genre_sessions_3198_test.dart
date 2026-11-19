import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/automix_genre_session.dart';
import 'package:difogo/core/genre_track_pool.dart' show kRollingWindowSize;

// 3.1.98: sesion de Mix con Letra independiente por firma de genero.
// Fixtures solo en %TEMP% (nunca la biblioteca).

String get _sep => Platform.pathSeparator;

List<String> _tracks(Directory dir, String genre, int n) {
  final Directory g = Directory('${dir.path}$_sep$genre')
    ..createSync(recursive: true);
  return <String>[
    for (var i = 1; i <= n; i++)
      (File('${g.path}$_sep$genre ${i.toString().padLeft(2, '0')}.mp3')
            ..writeAsBytesSync(const <int>[0]))
          .path,
  ];
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('amx_3198_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3198 (a) A en pista 3 / 45 s -> B -> A retoma pista 3 / 45 s', () {
    final List<String> a = _tracks(tmp, 'Rock', 10);
    final List<String> b = _tracks(tmp, 'Salsa', 6);
    final String automixPath = '${tmp.path}${_sep}automix.json';
    // Pistas 1 y 2 sonaron con la vista cerrada: solo la 3 esta marcada.
    final AutomixGenreSessionState? outA = freezeAutomixGenreSession(
      playlist: a,
      currentIndex: 2,
      positionMs: 45000,
      played: <String>[a[2]],
      savedAtMs: 1,
    );
    expect(outA, isNotNull);
    expect(outA!.current, a[2]);
    var sessions = putAutomixGenreSession(
      const <String, AutomixGenreSessionState>{},
      'rock|',
      outA,
    );
    // En B suenan dos pistas; luego se vuelve a A.
    final AutomixGenreSessionState? outB = freezeAutomixGenreSession(
      playlist: b,
      currentIndex: 1,
      positionMs: 12000,
      played: <String>[b[0], b[1]],
      savedAtMs: 2,
    );
    sessions = putAutomixGenreSession(sessions, 'salsa|', outB!);
    // Ida y vuelta por el archivo real (en %TEMP%).
    final File file = File(automixGenreSessionsPathFor(automixPath));
    file.writeAsStringSync(jsonEncode(automixGenreSessionsToJson(sessions)));
    expect(file.parent.path, tmp.path);
    final Map<String, AutomixGenreSessionState> back =
        readAutomixGenreSessions(automixPath);
    expect(back.keys.toList(), <String>['rock|', 'salsa|']);
    final AutomixGenreResume? r = resumeAutomixGenreSession(
      back['rock|']!,
      a,
    );
    expect(r, isNotNull);
    expect(r!.sameTrack, isTrue);
    expect(r.playlist.first, a[2]);
    expect(r.positionMs, 45000);
    expect(r.playlist, isNot(contains(a[0])));
    expect(r.playlist, isNot(contains(a[1])));
    expect(r.playlist, a.sublist(2));
    // B tambien retoma su pista 2 en 12 s sin repetir la 1.
    final AutomixGenreResume? rb = resumeAutomixGenreSession(back['salsa|']!, b);
    expect(rb!.playlist.first, b[1]);
    expect(rb.positionMs, 12000);
    expect(rb.playlist, isNot(contains(b[0])));
    // La pista guardada ya no existe: sigue la siguiente no sonada, desde 0.
    File(a[2]).deleteSync();
    final AutomixGenreResume? gone = resumeAutomixGenreSession(
      back['rock|']!,
      a.where((String p) => p != a[2]).toList(),
    );
    expect(gone!.sameTrack, isFalse);
    expect(gone.positionMs, 0);
    expect(gone.playlist.first, a[3]);
    // Genero agotado: null (cola nueva desde 0 y sonadas en cero).
    final AutomixGenreSessionState done = AutomixGenreSessionState(
      window: <String>['${tmp.path}${_sep}borrada.mp3'],
      positionMs: 5000,
      played: a,
    );
    expect(resumeAutomixGenreSession(done, a), isNull);
  });

  test('3198 (b) migracion desde automix.json de sesion unica', () {
    final List<String> a = _tracks(tmp, 'Baladas', 5);
    final String automixPath = '${tmp.path}${_sep}automix.json';
    final String legacy = jsonEncode(<String, dynamic>{
      'schema': 1,
      'genreSignature': 'baladas|',
      'playlist': a,
      'queue': a,
      'currentIndex': 2,
      'positionMs': 45000,
      'played': <String>[a[0], a[1], a[2]],
      'mixStrategy': 0,
    });
    File(automixPath).writeAsStringSync(legacy);
    expect(File(automixGenreSessionsPathFor(automixPath)).existsSync(), false);
    final Map<String, AutomixGenreSessionState> m = readAutomixGenreSessions(
      automixPath,
    );
    expect(m.keys.toList(), <String>['baladas|']);
    expect(m['baladas|']!.window, a.sublist(2));
    expect(m['baladas|']!.positionMs, 45000);
    expect(m['baladas|']!.played, <String>[a[0], a[1], a[2]]);
    // automix.json queda intacto (el estado actual no se pierde).
    expect(File(automixPath).readAsStringSync(), legacy);
    final AutomixGenreResume? r = resumeAutomixGenreSession(
      m['baladas|']!,
      a,
    );
    expect(r!.playlist.first, a[2]);
    expect(r.positionMs, 45000);
    // Sin firma (cola a mano) o sin lista: nada que migrar.
    expect(
      migrateAutomixGenreSessions(<String, dynamic>{'playlist': a}),
      isEmpty,
    );
    expect(
      migrateAutomixGenreSessions(<String, dynamic>{
        'genreSignature': 'rock|',
        'playlist': <String>[],
        'currentIndex': -1,
      }),
      isEmpty,
    );
    // Con el archivo nuevo presente, manda el archivo nuevo.
    File(automixGenreSessionsPathFor(automixPath)).writeAsStringSync(
      jsonEncode(
        automixGenreSessionsToJson(<String, AutomixGenreSessionState>{
          'rock|': AutomixGenreSessionState(
            window: <String>[a[4]],
            positionMs: 1000,
            played: const <String>[],
          ),
        }),
      ),
    );
    expect(readAutomixGenreSessions(automixPath).keys.toList(), <String>[
      'rock|',
    ]);
  });

  test('3198 (c) LRU de 20 firmas y topes de ventana / sonadas', () {
    AutomixGenreSessionState s(int i) => AutomixGenreSessionState(
      window: <String>['/m/g$i/a.mp3'],
      positionMs: i,
      played: const <String>[],
    );
    var m = const <String, AutomixGenreSessionState>{};
    for (var i = 0; i < 25; i++) {
      m = putAutomixGenreSession(m, 'g$i|', s(i));
    }
    expect(kAutomixGenreSessionCap, 20);
    expect(m.length, 20);
    expect(m.containsKey('g0|'), isFalse);
    expect(m.containsKey('g4|'), isFalse);
    expect(m.keys.first, 'g5|');
    // Volver a g5 la deja como la mas reciente: sale g6 al entrar otra.
    m = putAutomixGenreSession(m, 'g5|', s(5));
    m = putAutomixGenreSession(m, 'g99|', s(99));
    expect(m.length, 20);
    expect(m.containsKey('g5|'), isTrue);
    expect(m.containsKey('g6|'), isFalse);
    // Archivo con mas de 20 entradas: se acota al leer.
    final Map<String, dynamic> big = <String, dynamic>{
      kAutomixGenreSessionsKey: <String, dynamic>{
        for (var i = 0; i < 30; i++) 'x$i|': s(i).toJson(),
      },
    };
    final Map<String, AutomixGenreSessionState> read =
        automixGenreSessionsFromJson(big);
    expect(read.length, 20);
    expect(read.keys.first, 'x10|');
    // Ventana de 48 y sonadas acotadas (las mas recientes).
    final List<String> long = <String>[
      for (var i = 0; i < 1000; i++) '/m/l/$i.mp3',
    ];
    final AutomixGenreSessionState f = freezeAutomixGenreSession(
      playlist: long,
      currentIndex: 600,
      positionMs: 1,
      played: long.take(10),
    )!;
    expect(kRollingWindowSize, 48);
    expect(f.window.length, 48);
    expect(f.window.first, long[600]);
    expect(kAutomixGenrePlayedCap, 256);
    expect(f.played.length, 256);
    expect(f.played.last, long[9]);
    expect(f.played, contains(long[599]));
    final String json = jsonEncode(automixGenreSessionsToJson(m));
    expect(json.length, lessThan(20 * 1024));
  });

  test('3198 provider: congela antes de vaciar y retoma sin sonadas', () {
    final String src = File(
      'lib/providers/automix_provider.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> loadGenreQueue(');
    final int end = src.indexOf('Future<void> applyManualLyrics(');
    expect(start, greaterThan(0));
    final String body = src.substring(start, end);
    final int freeze = body.indexOf('freezeAutomixGenreSession(');
    final int read = body.indexOf('await _genreSessionMap()');
    final int clear = body.indexOf('.clearQueue()');
    expect(freeze, greaterThan(0));
    expect(read, greaterThan(freeze));
    expect(clear, greaterThan(read));
    expect(body.contains('resumeAutomixGenreSessionAsync(saved, clean)'), true);
    expect(body.contains('replaceAll(resume.played)'), isTrue);
    expect(body.contains('removeAutomixGenreSession(sessions, signature)'), true);
    expect(body.contains('_sessionPositionMs = posMs;'), isTrue);
    expect(body.contains('automixGenreSessionsPathFor(_getSessionFilePath())'), true);
  });
}
