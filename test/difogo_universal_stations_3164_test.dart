import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/genre_stations.dart';
import 'package:gatomix/providers/vibe_hub_provider.dart';
import 'package:gatomix/providers/session_provider.dart';
import 'package:gatomix/ui/vibe_hub_view.dart';

// 3.1.64 Catalogo universal de 7 estaciones: sub-generos canonicos (nunca
// nombres de carpeta), visto/descartado y mapeo interno de carpetas.
// Todo en %TEMP%, sin Live DJ real ni biblioteca.
const List<VibeGenre> _lib = <VibeGenre>[
  VibeGenre('Actualidad Espanol', 3),
  VibeGenre('Actualidad Ingles', 5),
  VibeGenre('Salsa', 2),
  VibeGenre('Merengue', 1),
  VibeGenre('Rock Ingles', 2),
  VibeGenre('80s Ingles', 2),
];

void main() {
  late Directory tmp;
  final List<StationPlan> plays = <StationPlan>[];
  final List<List<String>> asked = <List<String>>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_universal_3164_');
    final String sep = Platform.pathSeparator;
    final String state = '${tmp.path}${sep}state.json';
    debugVibeRootOverride = '${tmp.path}${sep}R';
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugVibeHubScan = (String r) async => _lib;
    debugStationSessionsPath = '${tmp.path}${sep}sessions.json';
    debugStationRng = Random(3);
    debugStationCollect = (List<String> folders) async {
      asked.add(List<String>.from(folders));
      return <String>[
        for (final String f in folders) ...<String>[
          '/m/$f/1.mp3',
          '/m/$f/2.mp3',
        ],
      ];
    };
    debugStationPlay = (StationPlan p) async => plays.add(p);
    debugStationLive = () => const StationLive(null, 0, <String>[]);
    plays.clear();
    asked.clear();
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugStationSessionsPath = null;
    debugStationRng = null;
    debugStationCollect = null;
    debugStationPlay = null;
    debugStationLive = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3164 exactamente 7 estaciones universales en orden', () {
    final List<GenreStation> st = groupStations(<MapEntry<String, int>>[
      for (final VibeGenre g in _lib) MapEntry<String, int>(g.name, g.count),
      const MapEntry<String, int>('Karaoke Kids', 4),
    ]);
    expect(
      <String>[for (final GenreStation s in st) s.title],
      <String>[
        'Música del Momento',
        'Ochenteras',
        'Tropical',
        'Fiesta MIX',
        'Rock',
        'Baladas',
        'Música Nacional Bailable',
      ],
    );
    expect(st[0].subGenres, <String>[
      'Pop',
      'Reggaetón',
      'HipHop',
      'Electrónica',
      'R&B',
      'Todas las Demás Nuevas',
    ]);
    expect(st[2].subGenres, <String>[
      'Salsa',
      'Cumbia',
      'Merengue',
      'Bachatas',
      'Vallenatos',
      'Todas',
    ]);
    expect(st[5].subGenres, <String>['En Inglés', 'En Español', 'Todas']);
    // Las carpetas solo viven en el mapa interno.
    expect(st[0].folders['Pop'], <String>[
      'Actualidad Espanol',
      'Actualidad Ingles',
    ]);
    expect(st[0].count, 8);
    expect(st[4].folders['Rock Clásico en Inglés'], <String>['Rock Ingles']);
    for (final GenreStation s in st) {
      expect(
        s.subGenres.where((String g) => g.contains('Actualidad')),
        isEmpty,
      );
      expect(s.subGenres, isNot(contains('Karaoke Kids')));
    }
  });

  test('3164 mapeo semantico de carpetas y terminos del Auto-Curador', () {
    final Map<String, String> want = <String, String>{
      'Actualidad Ingles': 'momento/Pop',
      'Reggaeton': 'momento/Reggaetón',
      '80s Espanol': 'ochenteras/Pop',
      'Dance 80s': 'ochenteras/Eurodance',
      'Bachatas': 'tropical/Bachatas',
      'Cumbias': 'tropical/Cumbia',
      'Salsa Romantica y Clasicos': 'tropical/Salsa',
      'Guaracha': 'fiesta/Electro Fiesta & Guaracha',
      'Fiesta': 'fiesta/Todas',
      'Rock Espanol': 'rock/Rock Clásico Español',
      'Española': 'rock/Rock Clásico Español',
      'Baladas Ingles': 'baladas/En Inglés',
      'Baladas Espanol': 'baladas/En Español',
      'Nacional': 'nacional/Todas',
    };
    for (final MapEntry<String, String> e in want.entries) {
      final MapEntry<String, String>? m = stationSubOf(e.key);
      expect('${m?.key}/${m?.value}', e.value, reason: e.key);
    }
    final StationFeed f = stationFeedFor(
      'momento',
      <String>['Pop'],
      <String, int>{for (final VibeGenre g in _lib) g.name: g.count},
    )!;
    expect(f.query, 'Pop Rock Pop Latino Pop Inglés hits');
    expect(f.folder, 'Actualidad Ingles');
  });

  testWidgets('3164 Hub: visto fuego, descartado con X y cola filtrada', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: VibeHubView(onPlayed: () {})),
        ),
      ),
    );
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.text('Tropical').evaluate().isNotEmpty) break;
    }
    expect(find.text('Música del Momento'), findsOneWidget);
    expect(find.text('Actualidad Espanol'), findsNothing);
    expect(find.text('Actualidad Ingles'), findsNothing);
    await tester.tap(find.byKey(const Key('vibe-hub-st-momento')));
    await tester.pump();
    // 3.1.69: visto maestro de Momento + sus 6 sub-generos.
    expect(find.byIcon(Icons.check_box), findsNWidgets(7));
    expect(find.text('Actualidad Espanol'), findsNothing);
    expect(find.text('Actualidad Ingles'), findsNothing);
    final Finder pop = find.byKey(const Key('vibe-hub-cat-Pop'));
    await tester.tap(pop);
    await tester.pump();
    expect(
      find.descendant(of: pop, matching: find.byIcon(Icons.close)),
      findsOneWidget,
    );
    await tester.tap(pop);
    await tester.pump();
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: pop, matching: find.byIcon(Icons.check_box)),
          )
          .color,
      const Color(0xFFFF5722),
    );
    await tester.tap(find.byKey(const Key('vibe-hub-st-tropical')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('vibe-hub-master-tropical')));
    await tester.pump();
    expect(find.byIcon(Icons.check_box), findsNWidgets(8));
    final Finder mer = find.byKey(const Key('vibe-hub-cat-Merengue'));
    await tester.tap(mer);
    await tester.pump();
    expect(
      find.descendant(of: mer, matching: find.byIcon(Icons.close)),
      findsOneWidget,
    );
    await tester.tap(find.text('Reproducir Estación en Shuffle'));
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (plays.isNotEmpty &&
          File(debugStationSessionsPath!).existsSync() &&
          File(
            debugStationSessionsPath!,
          ).readAsStringSync().contains('"active":"tropical"')) {
        break;
      }
    }
    expect(asked.single, <String>['Salsa']);
    final List<String> all = <String>[
      plays.single.currentTrackPath!,
      ...plays.single.queue,
    ];
    expect(all.length, 2);
    expect(all.every((String p) => p.contains('/Salsa/')), isTrue);
    final Map<String, dynamic> doc =
        jsonDecode(File(debugStationSessionsPath!).readAsStringSync())
            as Map<String, dynamic>;
    expect(
      ((doc['stations'] as Map)['tropical'] as Map)['subGenresChecked'],
      <String>['Salsa', 'Cumbia', 'Bachatas', 'Vallenatos', 'Todas'],
    );
    expect(tester.takeException(), isNull);
  });
}
