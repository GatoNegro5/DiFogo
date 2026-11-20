import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

// 3.1.70: Shuffle real (Smart Shuffle sin artistas seguidos), escaneo
// recursivo multi-idioma, sesion por genero que reanuda pista y segundo,
// menu renombrado y Modo Spotify por defecto. Todo en %TEMP%, sin red.

String _sep = Platform.pathSeparator;

class _Live extends LiveDjNotifier {
  final LiveDjState seed;
  _Live(this.seed);

  @override
  LiveDjState build() => seed;
}

void _touch(String path) {
  final File f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(32, 1));
}

void _noAdjacentArtist(List<String> order, String reason) {
  for (int i = 1; i < order.length; i++) {
    final String a = stationArtistKey(order[i - 1]);
    final String b = stationArtistKey(order[i]);
    expect(
      a.isNotEmpty && a == b,
      isFalse,
      reason: '$reason: ${order[i - 1]} -> ${order[i]}',
    );
  }
}

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3170_');
    root = '${tmp.path}${_sep}R';
    Directory(root).createSync(recursive: true);
    final String state = '${tmp.path}${_sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugStationSessionsPath = '${tmp.path}${_sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}$_sep$kTrackGenreIndexName';
    debugStationFeed = (String k, StationFeed f, int n) async =>
        const <String>[];
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugStationSessionsPath = null;
    debugTrackGenreIndexPath = null;
    debugStationRng = null;
    debugStationPlay = null;
    debugStationFeed = null;
    debugLiveDjForceMobile = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3170 Smart Shuffle: nunca dos del mismo artista seguidas', () {
    final List<String> tracks = <String>[
      '/m/Manuel Turizo - Besame.mp3',
      '/m/Manuel Turizo - El Merengue.mp3',
      '/m/Manuel Turizo - La Bachata.mp3',
      '/m/Manuel Turizo feat. Ozuna - Vaina Loca.mp3',
      '/m/Karol G - Provenza.mp3',
      '/m/Karol G - Bichota.mp3',
      '/m/Bad Bunny - Titi Me Pregunto.mp3',
      '/m/Bad Bunny - Moscow Mule.mp3',
      '/m/Shakira - Hips Dont Lie.mp3',
      '/m/sin artista.mp3',
    ];
    expect(stationArtistKey(tracks[3]), 'manuel turizo');
    expect(stationArtistKey(tracks.last), '');
    final List<String> sorted = List<String>.from(tracks)..sort();
    int differs = 0;
    for (int seed = 0; seed < 300; seed++) {
      final List<String> o = stationSmartShuffle(tracks, Random(seed));
      expect(o.toSet(), tracks.toSet());
      _noAdjacentArtist(o, 'seed $seed');
      if (o.join() != sorted.join()) differs++;
    }
    expect(differs, 300, reason: 'nunca queda en orden alfabetico');
    // planStation: la cola nueva respeta tambien la pista que suena.
    final StationPlan p = planStation(
      tracks,
      GenreSession(
        subGenresChecked: const <String>['Reggaetón'],
        currentTrackPath: tracks[0],
        positionMs: 0,
        remainingQueuePaths: const <String>[],
        playedPaths: const <String>[],
      ),
      rng: Random(5),
    );
    _noAdjacentArtist(<String>[p.currentTrackPath!, ...p.queue], 'plan');
  });

  test(
    '3170 escaneo recursivo: subcarpetas en espanol e ingles a cualquier nivel',
    () async {
      final String g = '$root${_sep}ReGenial';
      final Map<String, String> want = <String, String>{
        '$g${_sep}Español${_sep}Baladas${_sep}Viejitas${_sep}Lote 2$_sep'
                'Camilo Sesto - Perdoname.mp3':
            'baladas/En Español',
        '$g${_sep}Ingles${_sep}Baladas${_sep}Lionel Richie - Hello.mp3':
            'baladas/En Inglés',
        '$g${_sep}English${_sep}Rock Clasico${_sep}80s$_sep'
                'Queen - Under Pressure.mp3':
            'rock/Rock Clásico en Inglés',
        '$g${_sep}Español${_sep}Rock Clasico${_sep}Soda Stereo - Persiana.mp3':
            'rock/Rock Clásico Español',
      };
      want.keys.forEach(_touch);
      for (final MapEntry<String, String> e in want.entries) {
        final TrackGenre t = TrackGenreClassifier.classify(e.key, root: root);
        expect('${t.stationId}/${t.subGenreId}', e.value, reason: e.key);
      }
      final List<StationPlan> plans = <StationPlan>[];
      debugStationPlay = (StationPlan p) async => plans.add(p);
      final ProviderContainer c = ProviderContainer(
        overrides: [liveDjProvider.overrideWith(() => _Live(LiveDjState()))],
      );
      addTearDown(c.dispose);
      final VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      await hub.refresh();
      expect(await hub.playStation('baladas', <String>['En Inglés']), 1);
      expect(plans.last.currentTrackPath, contains('Lionel Richie'));
      expect(await hub.playStation('baladas', <String>['En Español']), 1);
      expect(plans.last.currentTrackPath, contains('Camilo Sesto'));
      expect(
        await hub.playStation('rock', <String>[
          'Rock Clásico en Inglés',
          'Rock Clásico Español',
        ]),
        2,
      );
      await hub.stationsSettled;
    },
  );

  test(
    '3170 sesion por genero: vuelve a la misma pista, segundo y cola',
    () async {
      final List<String> tracks = <String>[
        for (int i = 0; i < 8; i++)
          '$root${_sep}Salsa${_sep}Artista $i - Tema $i.mp3',
      ];
      tracks.forEach(_touch);
      debugStationCollect = (List<String> subs) async => tracks;
      addTearDown(() => debugStationCollect = null);
      debugStationRng = Random(7);
      final List<StationPlan> plans = <StationPlan>[];
      debugStationPlay = (StationPlan p) async => plans.add(p);
      ProviderContainer c = ProviderContainer(
        overrides: [liveDjProvider.overrideWith(() => _Live(LiveDjState()))],
      );
      VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      expect(await hub.playStation('tropical', <String>['Salsa']), 8);
      final StationPlan first = plans.last;
      // Suena la siguiente y se pausa en el segundo 83.
      await hub.noteTrackChange(
        first.currentTrackPath,
        first.queue.first,
        first.queue.sublist(1),
      );
      await hub.notePlaybackTick(
        first.queue.first,
        83000,
        first.queue.sublist(1),
        force: true,
      );
      // Un tick sin forzar dentro de los 5 s no pisa lo guardado.
      await hub.notePlaybackTick(
        first.queue.first,
        84000,
        first.queue.sublist(1),
      );
      // Musica ajena a la estacion no toca la sesion.
      await hub.notePlaybackTick('/otra/cancion.mp3', 1, const <String>[]);
      await hub.stationsSettled;
      c.dispose();
      // App reabierta: nuevo contenedor lee la sesion del disco.
      debugStationRng = Random(99);
      c = ProviderContainer(
        overrides: [liveDjProvider.overrideWith(() => _Live(LiveDjState()))],
      );
      addTearDown(c.dispose);
      hub = c.read(vibeHubProvider.notifier);
      await hub.playStation('tropical', <String>['Salsa']);
      final StationPlan again = plans.last;
      expect(again.resumed, isTrue);
      expect(again.currentTrackPath, first.queue.first);
      expect(again.positionMs, 83000);
      expect(again.queue, first.queue.sublist(1));
      expect(again.queue.contains(first.currentTrackPath), isFalse);
      await hub.stationsSettled;
    },
  );

  test('3170 loadStation deja la cola en Shuffle', () {
    final String src = File(
      'lib/providers/livedj_provider.dart',
    ).readAsStringSync();
    final int at = src.indexOf('Future<bool> loadStation(');
    final String body = src.substring(
      at,
      src.indexOf('Future<void> savePlaylist', at),
    );
    expect(body.contains('mixStrategy: LiveDjMixStrategy.random'), isTrue);
    expect(body.contains('LiveDjMixStrategy.sequential'), isFalse);
  });

  test(
    '3170 menu lateral: AutomixDj primero, Mix con Letra, Comparte Musica',
    () {
      for (final String f in <String>[
        'lib/main.dart',
        'lib/djiphone/main.dart',
      ]) {
        final String src = File(f).readAsStringSync().replaceAll("'", '"');
        final int dj = src.indexOf('label: "AutomixDj"');
        final int letra = src.indexOf('label: "Mix con Letra"');
        final int lan = src.indexOf('label: "Comparte Música"');
        expect(dj, greaterThan(0), reason: f);
        expect(letra, greaterThan(dj), reason: f);
        expect(lan, greaterThan(letra), reason: f);
        expect(src.contains('label: "Live DJ"'), isFalse, reason: f);
        expect(src.contains('label: "Automix"'), isFalse, reason: f);
        expect(src.contains('label: "LAN Sync"'), isFalse, reason: f);
        // Rutas internas intactas.
        final String tileDj = src.substring(dj, dj + 60);
        expect(tileDj.contains('route: 5'), isTrue, reason: f);
        expect(src.substring(letra, letra + 60).contains('route: 0'), isTrue);
        expect(src.substring(lan, lan + 60).contains('route: 4'), isTrue);
      }
      expect(
        File('lib/main.dart').readAsStringSync().contains('kStartRoute = 5'),
        isTrue,
      );
      expect(
        File(
          'lib/djiphone/main.dart',
        ).readAsStringSync().contains('int build() => 5;'),
        isTrue,
      );
    },
  );

  Future<void> pumpSpotify(WidgetTester tester, Size size, bool mobile) async {
    debugLiveDjForceMobile = mobile;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<File> q = <File>[
      File('$root${_sep}Karol G - Provenza.mp3'),
      File('$root${_sep}Bad Bunny - Moscow Mule.mp3'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveDjProvider.overrideWith(
            () => _Live(
              LiveDjState(
                queue: q,
                currentTrackPath: '$root${_sep}Manuel Turizo - Besame.mp3',
                mixStrategy: LiveDjMixStrategy.random,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: LiveDjWorkspace()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final (String name, Size size, bool mobile) v in <(String, Size, bool)>[
    ('escritorio', const Size(1400, 900), false),
    ('telefono', const Size(360, 640), true),
    ('telefono acostado', const Size(780, 360), true),
  ]) {
    testWidgets('3170 Modo Spotify por defecto y COLA DE REPRODUCCIÓN: '
        '${v.$1}', (WidgetTester tester) async {
      await pumpSpotify(tester, v.$2, v.$3);
      expect(find.byKey(const Key('livedj-spotify-panel')), findsOneWidget);
      expect(find.byKey(const Key('spotify-cover')), findsWidgets);
      expect(find.text('Besame'), findsOneWidget);
      expect(find.text('Manuel Turizo'), findsOneWidget);
      // 3.1.84 Clean Mode: el chip de la formula salio de la pantalla
      // principal (vive en la hoja Modo DJ).
      expect(find.byKey(const Key('spotify-mix-chip')), findsNothing);
      expect(find.text('ACTIVE BEATMATCHING'), findsNothing);
      final Icon shuffle = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('spotify-shuffle')),
          matching: find.byType(Icon),
        ),
      );
      expect(shuffle.icon, Icons.shuffle_rounded);
      // 3.1.84: en telefono la cabecera dice COLA (n) (Clean Mode).
      expect(
        find.textContaining(v.$3 ? 'COLA (2)' : 'COLA DE REPRODUCCIÓN (2)'),
        findsOneWidget,
      );
      expect(find.textContaining('CARTRIDGE'), findsNothing);
      expect(tester.takeException(), isNull);
      // 3.2.9: Spotify Pro es la vista unica: sin conmutador en la barra y
      // la Radio vive junto a Modo DJ.
      expect(find.byKey(const Key('livedj-spotify-toggle')), findsNothing);
      expect(find.byKey(const Key('livedj-spotify-panel')), findsOneWidget);
      expect(find.byKey(const Key('livedj-mode-dj-button')), findsOneWidget);
      expect(find.byKey(const Key('radio-discovery-toggle')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('3170 Modo Spotify es el valor por defecto', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(liveDjSpotifyModeProvider), isTrue);
    expect(spotifyTrackLabels('/x/Karol G - Provenza.mp3').artist, 'Karol G');
  });
}
