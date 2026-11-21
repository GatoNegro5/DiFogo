import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/startup_vibe_dialog.dart';

// 3.1.61 Estaciones DiFogo: macro-generos con vistos y sesion persistente
// por genero. Todo en %TEMP%, sin Live DJ real ni biblioteca.
void main() {
  late Directory tmp;
  final Map<String, List<String>> lib = <String, List<String>>{
    '80s Espanol': <String>['/m/80s Espanol/e1.mp3', '/m/80s Espanol/e2.mp3'],
    '80s Ingles': <String>['/m/80s Ingles/i1.mp3', '/m/80s Ingles/i2.mp3'],
    'Dance 80s': <String>['/m/Dance 80s/d1.mp3'],
    'Cumbias': <String>['/m/Cumbias/c1.mp3', '/m/Cumbias/c2.mp3'],
  };
  final List<StationPlan> plays = <StationPlan>[];
  StationLive live = const StationLive(null, 0, <String>[]);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_station_3161_');
    debugStationSessionsPath =
        '${tmp.path}${Platform.pathSeparator}difogo_genre_sessions.json';
    debugStationRng = Random(7);
    debugStationCollect = (List<String> subs) async => <String>[
      for (final String s in subs) ...?lib[s],
    ];
    debugStationPlay = (StationPlan p) async => plays.add(p);
    debugStationLive = () => live;
    plays.clear();
  });

  tearDown(() {
    debugStationSessionsPath = null;
    debugStationRng = null;
    debugStationCollect = null;
    debugStationPlay = null;
    debugStationLive = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3161/3164 carpetas a sub-generos canonicos', () {
    final List<GenreStation> st = groupStations(<MapEntry<String, int>>[
      const MapEntry<String, int>('80s Espanol', 23),
      const MapEntry<String, int>('80s Ingles', 195),
      const MapEntry<String, int>('Dance 80s', 40),
      const MapEntry<String, int>('Baladas Espanol', 77),
      const MapEntry<String, int>('Bachatas', 15),
      const MapEntry<String, int>('Guaracha', 1),
      const MapEntry<String, int>('Rock Ingles', 61),
      const MapEntry<String, int>('Nacional', 14),
      const MapEntry<String, int>('Actualidad Español', 70),
      const MapEntry<String, int>('Karaoke Kids', 3),
    ]);
    final Map<String, GenreStation> by = <String, GenreStation>{
      for (final GenreStation s in st) s.title: s,
    };
    expect(st.length, 7);
    expect(by['Ochenteras']!.folders['Pop'], <String>[
      '80s Espanol',
      '80s Ingles',
    ]);
    expect(by['Ochenteras']!.folders['Eurodance'], <String>['Dance 80s']);
    expect(by['Baladas']!.folders['En Español'], <String>['Baladas Espanol']);
    expect(by['Tropical']!.folders['Bachatas'], <String>['Bachatas']);
    expect(by['Fiesta MIX']!.folders['Electro Fiesta & Guaracha'], <String>[
      'Guaracha',
    ]);
    expect(by['Rock']!.folders['Rock Clásico en Inglés'], <String>[
      'Rock Ingles',
    ]);
    expect(by['Música Nacional Bailable']!.folders['Todas'], <String>[
      'Nacional',
    ]);
    expect(by['Música del Momento']!.folders['Pop'], <String>[
      'Actualidad Español',
    ]);
    expect(by.containsKey('Karaoke Kids'), isFalse);
    expect(by['Ochenteras']!.count, 258);
  });

  testWidgets('3161 selector: sin Icons.folder y sub-generos en visto', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<GenreStation> st = groupStations(<MapEntry<String, int>>[
      for (final MapEntry<String, List<String>> e in lib.entries)
        MapEntry<String, int>(e.key, e.value.length),
    ]);
    Object? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () async {
              got = await showDialog<StationPick>(
                context: ctx,
                builder: (_) => StationPickerDialog(stations: st),
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder), findsNothing);
    expect(find.text('80s Espanol'), findsNothing);
    await tester.tap(find.text('Ochenteras'));
    await tester.pumpAndSettle();
    // 3.1.69: desplegar no marca; el visto maestro enciende los 7.
    await tester.tap(find.byKey(const Key('station-master-ochenteras')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_box), findsNWidgets(9));
    expect(find.text('Dance 80s'), findsNothing);
    await tester.tap(find.text('Eurodance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reproducir Estación en Shuffle'));
    await tester.pumpAndSettle();
    final StationPick pick = got! as StationPick;
    expect(pick.key, 'ochenteras');
    expect(pick.subGenres, <String>[
      'Disco',
      'Punk',
      'Pop',
      'Rock',
      'HipHop',
      'Todas',
    ]);
    expect(tester.takeException(), isNull);
  });

  test(
    '3161 persistencia multi-genero: A -> B -> A retoma cancion 2 en 45 s',
    () async {
      final ProviderContainer c = ProviderContainer();
      final VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      final List<String> a = <String>['80s Espanol', '80s Ingles'];
      expect(await hub.playStation('ochenteras', a), 4);
      final StationPlan first = plays.last;
      final String song1 = first.currentTrackPath!;
      final String song2 = first.queue.first;
      expect(first.queue.contains(song1), isFalse);
      // Live DJ pasa a la cancion 2 y llega al segundo 45.
      final List<String> rest = first.queue.sublist(1);
      await hub.noteTrackChange(song1, song2, rest);
      live = StationLive(song2, 45000, rest);
      // Cambio a Tropical: se congela Ochenteras.
      expect(await hub.playStation('tropical', <String>['Cumbias']), 2);
      expect(plays.last.queue.length + 1, 2);
      live = StationLive(plays.last.currentTrackPath, 3000, plays.last.queue);
      await hub.stationsSettled;
      c.dispose();

      // Al dia siguiente (otro arranque) vuelve a Ochenteras.
      final ProviderContainer c2 = ProviderContainer();
      final VibeHubNotifier hub2 = c2.read(vibeHubProvider.notifier);
      expect(await hub2.playStation('ochenteras', a), 4);
      final StationPlan back = plays.last;
      expect(back.resumed, isTrue);
      expect(back.currentTrackPath, song2);
      expect(back.positionMs, 45000);
      expect(back.queue, rest);
      expect(back.queue.contains(song1), isFalse);
      expect(back.played, <String>[song1]);
      await hub2.stationsSettled;
      final String json = File(debugStationSessionsPath!).readAsStringSync();
      for (final String k in <String>[
        'subGenresChecked',
        'currentTrackPath',
        'positionMs',
        'remainingQueuePaths',
        'playedPaths',
        'shuffleEnabled',
        'updatedAt',
      ]) {
        expect(json.contains('"$k"'), isTrue, reason: k);
      }
      c2.dispose();
    },
  );

  test(
    '3161 reingreso: "Estabas escuchando" y reinicio al agotar el 100 %',
    () async {
      final ProviderContainer c = ProviderContainer();
      final VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      await hub.playStation('tropical', <String>['Cumbias']);
      final StationPlan p = plays.last;
      live = StationLive(p.currentTrackPath, 61000, p.queue);
      final StationResumeInfo info = hub.resumeInfo()!;
      expect(info.title, 'Tropical');
      expect(info.clock, '1:01');
      expect(info.trackPath, p.currentTrackPath);
      // Suenan las 2 de Cumbias: la estacion se agota y se reinicia.
      await hub.noteTrackChange(p.currentTrackPath, p.queue.first, <String>[]);
      await hub.noteTrackChange(p.queue.first, null, <String>[]);
      live = const StationLive(null, 0, <String>[]);
      await hub.playStation('tropical', <String>['Cumbias']);
      expect(plays.last.played, isEmpty);
      expect(plays.last.queue.length + 1, 2);
      await hub.stationsSettled;
      c.dispose();
    },
  );

  // 3.1.62/3.1.65: solo el escudo en la barra lateral (escritorio y djiphone).
  test(
    '3162/3165 sidebar: solo logo3 a 120 px en cabecera de 130 y barra de 196',
    () {
      for (final String f in <String>[
        'lib/main.dart',
        'lib/djiphone/main.dart',
      ]) {
        final String src = File(f).readAsStringSync();
        final int at = src.indexOf("Key('sidebar-logo')");
        expect(at, greaterThan(0), reason: f);
        final String around = src.substring(at - 260, at + 160);
        // 3.2.21: el logo del sidebar vuelve al wordmark GatoMix.
        expect(around.contains("'assets/branding/gatomix_wordmark.png'"), isTrue);
        expect(around.contains('height: 130'), isTrue, reason: f);
        final RegExpMatch m = RegExp(
          r'height: (\d+)',
        ).allMatches(src.substring(at, at + 160)).first;
        expect(int.parse(m.group(1)!), 120, reason: f);
        // 3.1.65: tras el escudo viene directo la version, sin otra imagen.
        final int ver = src.indexOf('const AppVersionLabel()', at);
        expect(ver, greaterThan(at), reason: f);
        expect(
          src.substring(at, ver).contains('Image.asset'),
          isFalse,
          reason: f,
        );
        expect(src.contains('difogo_wordmark'), isFalse, reason: f);
        expect(
          src.contains('int build() => 5;') || src.contains('kStartRoute = 5'),
          isTrue,
          reason: f,
        );
      }
      expect(
        File('lib/main.dart').readAsStringSync().contains('width: 196'),
        isTrue,
      );
    },
  );
}
