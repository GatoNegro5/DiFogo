import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/audio_path.dart';
import 'package:difogo/core/automix_genre_session.dart';
import 'package:difogo/core/mode_session.dart';

// 3.1.86: ANR "DiFogo no responde" en Mix con Letra (877 pistas) y
// reanudacion exacta por genero. Solo carpetas temporales (nunca ReGenial).

String _read(String p) =>
    File(p).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  late Directory tmp;
  final String sep = Platform.pathSeparator;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3186_');
  });
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<String> makeTracks(String folder, int n) {
    final Directory d = Directory('${tmp.path}$sep$folder')
      ..createSync(recursive: true);
    return <String>[
      for (var i = 0; i < n; i++)
        (File('${d.path}${sep}Artista $i - Tema $i (${90 + i % 40} BPM).mp3')
              ..writeAsBytesSync(const <int>[0]))
            .path,
    ];
  }

  test('Prueba 1: 900 pistas, pista 1 en < 200 ms sin bloquear el event '
      'loop', () async {
    final List<String> paths = makeTracks('Mix900', 900);
    var ticks = 0;
    var done = false;
    void tick() {
      if (done) return;
      ticks++;
      Timer.run(tick);
    }

    Timer.run(tick);
    final Stopwatch sw = Stopwatch()..start();
    int firstMs = -1;
    String? first;
    final List<String> all = await automixLoadInChunks(
      paths,
      onFirst: (String p) {
        firstMs = sw.elapsedMilliseconds;
        first = p;
      },
    );
    final int totalMs = sw.elapsedMilliseconds;
    expect(first, paths.first);
    expect(firstMs, lessThan(200), reason: 'pista 1 en ${firstMs}ms');
    expect(all, hasLength(900));
    // El loader cedio el event loop entre lotes (900 / 128 = 7 lotes).
    expect(ticks, greaterThanOrEqualTo(6), reason: 'ticks=$ticks');

    // La restauracion de la sesion (existsSync + resolveSymbolicLinks por
    // pista) corre en otro isolate: el event loop sigue vivo mientras tanto.
    final int before = ticks;
    final AutomixPlaylistRestore r = await restoreAutomixPlaylistAsync(
      <String, dynamic>{
        'playlist': paths,
        'currentIndex': 4,
        'positionMs': 45000,
      },
      2,
    );
    done = true;
    expect(r.playlist, hasLength(900));
    expect(r.index, 4);
    expect(r.restored.positionMs, 45000);
    expect(ticks, greaterThan(before));

    // Pertenencia de la cola por Set de claves (lo que hacen ahora
    // syncDynamicPlaylist, el panel y Mezclar carpeta): 900 x 900 rapido.
    final Stopwatch sw2 = Stopwatch()..start();
    final Set<String> keys = audioKeySet(paths);
    var hits = 0;
    for (final String p in paths.reversed) {
      if (keys.contains(audioPathKey(p))) hits++;
    }
    expect(hits, 900);
    expect(sw2.elapsedMilliseconds, lessThan(200));
    expect(totalMs, lessThan(2000));
    // La clave memorizada es la misma que la calculada.
    expect(audioPathKey(paths[3]), audioPathKey(paths[3]));
    expect(sameAudioPath(paths[3], paths[3].replaceAll('/', '/')), isTrue);
  });

  test('Prueba 2: Ochenteras en la #4 a 45000 ms se reanuda; Tropical borra '
      'y arma la nueva', () async {
    final String session = '${tmp.path}${sep}automix_state.json';
    final List<String> ochenteras = makeTracks('Ochenteras', 12);
    final List<String> tropical = makeTracks('Tropical', 9);
    final String sig80 = automixGenreSignature('ochenteras', <String>['Pop']);
    final String sigTrop = automixGenreSignature('tropical', <String>[
      'Salsa',
      'Merengue',
    ]);
    expect(sig80, 'ochenteras|pop');
    expect(
      sigTrop,
      automixGenreSignature('tropical', <String>['merengue', 'Salsa']),
    );

    // Cola vacia con generos elegidos: se arma por default.
    expect(
      automixGenreAction(
        savedSignature: null,
        currentSignature: sig80,
        hasQueue: false,
      ),
      AutomixGenreAction.build,
    );
    await patchModeDoc(
      session,
      automixGenreSessionPatch(signature: sig80, playlist: ochenteras),
    );
    // Suena hasta la #4 y el segundo 45 (lo que guarda _saveSnapshot).
    await patchModeDoc(session, <String, dynamic>{
      'currentIndex': 4,
      'positionMs': 45000,
      'genreSignature': sig80,
    });

    // Salir y volver a entrar: misma firma -> restaura tal cual.
    final Map<String, dynamic> doc = readModeDoc(session);
    expect(
      automixGenreAction(
        savedSignature: doc['genreSignature'] as String?,
        currentSignature: sig80,
        hasQueue: true,
      ),
      AutomixGenreAction.restore,
    );
    final AutomixPlaylistRestore again = restoreAutomixPlaylist(doc, 2);
    expect(again.index, 4);
    expect(again.restored.positionMs, 45000);
    expect(
      <String>[for (final String p in again.playlist) audioPathKey(p)],
      <String>[for (final String p in ochenteras) audioPathKey(p)],
    );

    // Cambio a Tropical: firma distinta -> borra Ochenteras y arma Tropical.
    expect(
      automixGenreAction(
        savedSignature: doc['genreSignature'] as String?,
        currentSignature: sigTrop,
        hasQueue: true,
      ),
      AutomixGenreAction.build,
    );
    final List<String> built = await automixLoadInChunks(tropical);
    await patchModeDoc(
      session,
      automixGenreSessionPatch(signature: sigTrop, playlist: built),
    );
    final Map<String, dynamic> now = readModeDoc(session);
    expect(now['genreSignature'], sigTrop);
    expect(now['playlist'], tropical);
    expect(now['queue'], tropical);
    expect(now['currentIndex'], 0);
    expect(now['positionMs'], 0);
    final String text = File(session).readAsStringSync();
    expect(text.contains('Ochenteras'), isFalse);

    // Cola armada a mano (sin firma) no se borra; sin estacion no se toca.
    expect(
      automixGenreAction(
        savedSignature: null,
        currentSignature: sigTrop,
        hasQueue: true,
      ),
      AutomixGenreAction.keepManual,
    );
    expect(
      automixGenreAction(
        savedSignature: sig80,
        currentSignature: '',
        hasQueue: true,
      ),
      AutomixGenreAction.none,
    );
  });

  test('blindaje de fuente: sin N^2 ni I/O por pista en el hilo de UI', () {
    final String ap = _read('lib/providers/automix_provider.dart');
    final String ws = _read('lib/ui/workspaces/automix_workspace.dart');
    expect(ap.contains('xs.any((e) => sameAudioPath(e, p))'), isFalse);
    expect(ap.contains('!rest.any((r) => sameAudioPath(r, path))'), isFalse);
    expect(ap.contains('restoreAutomixPlaylistAsync(doc, strategies)'), isTrue);
    expect(ap.contains("'genreSignature': _genreSignature"), isTrue);
    expect(ap.contains('Future<AutomixGenreAction> ensureGenreQueue('), isTrue);
    expect(ap.contains('void _scheduleSnapshot()'), isTrue);
    expect(ws.contains('playedTracks.any((p) => sameAudioPath'), isFalse);
    expect(ws.contains('paths.any((String path) => sameAudioPath'), isFalse);
    expect(ws.contains(".split('/')\n                                            .last,"),
        isFalse);
    expect(ws.contains('cleanNextTrackLabel('), isTrue);
  });
}
