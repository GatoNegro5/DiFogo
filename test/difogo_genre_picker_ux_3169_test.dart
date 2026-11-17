import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/genre_stations.dart';
import 'package:gatomix/providers/curator_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/session_provider.dart';
import 'package:gatomix/providers/theme_provider.dart';
import 'package:gatomix/providers/vibe_hub_provider.dart';
import 'package:gatomix/services/smart_discovery_service.dart';
import 'package:gatomix/ui/startup_vibe_dialog.dart';
import 'package:gatomix/ui/vibe_hub_view.dart';

// 3.1.69: modal "Escoge Tus Generos Preferidos" con Play al lado, visto
// maestro por estacion en cascada, flecha que minimiza y aviso sin vistos.
// Todo en %TEMP%, sin red ni motor de audio.

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

const List<String> _momento = <String>[
  'Pop',
  'Reggaetón',
  'HipHop',
  'Electrónica',
  'R&B',
  'Todas las Demás Nuevas',
];

void main() {
  final String sep = Platform.pathSeparator;
  late Directory tmp;
  final List<StationPlan> plans = <StationPlan>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_picker_3169_');
    final String root = '${tmp.path}${sep}R';
    File('$root${sep}Salsa${sep}a.mp3')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[0]);
    final String state = '${tmp.path}${sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugVibeHubScan = (String r) async => const <VibeGenre>[
      VibeGenre('Salsa', 1),
    ];
    debugStationSessionsPath = '${tmp.path}${sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}$sep$kTrackGenreIndexName';
    debugDisableCuratorWorker = true;
    debugCuratorService = SmartDiscoveryService(
      search: (String q) async => const <DiscoveryCandidate>[],
      download: (DiscoveryCandidate c, String mp3) async {},
      inboxDir: '${tmp.path}${sep}Inbox',
      now: () => DateTime(2026, 11, 17, 16),
    );
    plans.clear();
    debugStationPlay = (StationPlan p) async => plans.add(p);
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugStationSessionsPath = null;
    debugTrackGenreIndexPath = null;
    debugCuratorService = null;
    debugStationPlay = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  final List<GenreStation> st = groupStations(const <MapEntry<String, int>>[
    MapEntry<String, int>('Salsa', 2),
  ]);

  Finder k(String key) => find.byKey(Key(key));
  bool on(WidgetTester t, String key) => find
      .descendant(of: k(key), matching: find.byIcon(Icons.check_box))
      .evaluate()
      .isNotEmpty;
  bool off(WidgetTester t, String key) => find
      .descendant(of: k(key), matching: find.byIcon(Icons.close))
      .evaluate()
      .isNotEmpty;

  /// Abre el selector; [got] guarda lo que devuelve al cerrarse.
  Future<List<Object?>> open(
    WidgetTester tester, {
    String? initial,
    List<String>? Function(String)? saved,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<Object?> got = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: GatoMixTheme.darkTheme,
        home: Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () async {
              got.add(
                await showDialog<StationPick>(
                  context: ctx,
                  builder: (_) => StationPickerDialog(
                    stations: st,
                    initialStation: initial,
                    savedChecked: saved,
                  ),
                ),
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return got;
  }

  testWidgets('3169 titulo con Play fuego al lado', (WidgetTester t) async {
    await open(t);
    final Finder title = find.text('Escoge Tus Géneros Preferidos');
    expect(title, findsOneWidget);
    expect(find.text('¿Qué estación suena hoy?'), findsNothing);
    final Finder play = k('station-play-top');
    expect(play, findsOneWidget);
    final Icon icon = t.widget<Icon>(
      find.descendant(of: play, matching: find.byType(Icon)),
    );
    expect(icon.icon, Icons.play_arrow_rounded);
    expect(icon.color, const Color(0xFFFF5722));
    // Justo a la derecha del titulo y en la misma fila.
    final double gap = t.getTopLeft(play).dx - t.getTopRight(title).dx;
    expect(gap, inInclusiveRange(0, 24));
    expect((t.getCenter(play).dy - t.getCenter(title).dy).abs(), lessThan(12));
    expect(t.takeException(), isNull);
  });

  testWidgets('3169 Momento inicia en visto y el maestro va en cascada', (
    WidgetTester t,
  ) async {
    await open(t);
    expect(on(t, 'station-master-momento'), isTrue);
    for (final GenreStation s in st.skip(1)) {
      expect(off(t, 'station-master-${s.key}'), isTrue, reason: s.key);
    }
    // Maestro al lado del chevron, a la derecha de la fila.
    expect(
      t.getTopLeft(k('station-chevron-momento')).dx,
      greaterThan(t.getTopLeft(k('station-master-momento')).dx),
    );
    await t.tap(k('station-chevron-momento'));
    await t.pumpAndSettle();
    for (final String g in _momento) {
      expect(on(t, 'station-sub-$g'), isTrue, reason: g);
    }
    // a) quitar el maestro deshabilita los 6.
    await t.tap(k('station-master-momento'));
    await t.pumpAndSettle();
    expect(off(t, 'station-master-momento'), isTrue);
    for (final String g in _momento) {
      expect(off(t, 'station-sub-$g'), isTrue, reason: g);
    }
    // b) ponerlo habilita los 6.
    await t.tap(k('station-master-momento'));
    await t.pumpAndSettle();
    expect(on(t, 'station-master-momento'), isTrue);
    for (final String g in _momento) {
      expect(on(t, 'station-sub-$g'), isTrue, reason: g);
    }
    // c) quitar uno por uno deja el maestro en X.
    for (final String g in _momento) {
      expect(on(t, 'station-master-momento'), isTrue, reason: g);
      await t.tap(k('station-sub-$g'));
      await t.pumpAndSettle();
    }
    expect(off(t, 'station-master-momento'), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('3169 la flecha arriba minimiza sin quitar los vistos', (
    WidgetTester t,
  ) async {
    await open(t);
    await t.tap(k('station-chevron-momento'));
    await t.pumpAndSettle();
    expect(k('station-sub-Pop'), findsOneWidget);
    expect(
      find.descendant(
        of: k('station-chevron-momento'),
        matching: find.byIcon(Icons.expand_less),
      ),
      findsOneWidget,
    );
    await t.tap(k('station-sub-Pop'));
    await t.pumpAndSettle();
    // ^ minimiza.
    await t.tap(k('station-chevron-momento'));
    await t.pumpAndSettle();
    expect(k('station-sub-Pop'), findsNothing);
    expect(k('station-sub-HipHop'), findsNothing);
    expect(on(t, 'station-master-momento'), isTrue);
    // El titulo tambien alterna, y los vistos siguen como estaban.
    await t.tap(find.text('Música del Momento'));
    await t.pumpAndSettle();
    expect(off(t, 'station-sub-Pop'), isTrue);
    expect(on(t, 'station-sub-HipHop'), isTrue);
    await t.tap(find.text('Música del Momento'));
    await t.pumpAndSettle();
    expect(k('station-sub-Pop'), findsNothing);
    // El visto maestro no despliega ni bloquea el minimizar.
    await t.tap(k('station-master-tropical'));
    await t.pumpAndSettle();
    expect(k('station-sub-Salsa'), findsNothing);
    expect(on(t, 'station-master-tropical'), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('3169 Play sin vistos avisa y el modal sigue abierto', (
    WidgetTester t,
  ) async {
    final List<Object?> got = await open(t);
    await t.tap(k('station-master-momento'));
    await t.pumpAndSettle();
    expect(find.text('Tiene que escoger su Género Favorito...'), findsNothing);
    await t.tap(k('station-play-top'));
    await t.pumpAndSettle();
    expect(
      find.text('Tiene que escoger su Género Favorito...'),
      findsOneWidget,
    );
    expect(find.text('Escoge Tus Géneros Preferidos'), findsOneWidget);
    expect(got, isEmpty);
    await t.tap(k('station-play'));
    await t.pumpAndSettle();
    expect(
      find.text('Tiene que escoger su Género Favorito...'),
      findsOneWidget,
    );
    expect(find.byType(StationPickerDialog), findsOneWidget);
    expect(got, isEmpty);
    // Con Tropical en visto, el Play de arriba suena lo marcado.
    await t.tap(k('station-master-tropical'));
    await t.pumpAndSettle();
    expect(find.text('Tiene que escoger su Género Favorito...'), findsNothing);
    await t.tap(k('station-play-top'));
    await t.pumpAndSettle();
    expect(find.byType(StationPickerDialog), findsNothing);
    final StationPick p = got.single! as StationPick;
    expect(p.key, 'tropical');
    expect(p.subGenres, universalStation('tropical')!.subs.map((s) => s.label));
    expect(t.takeException(), isNull);
  });

  testWidgets('3169 seleccion guardada: su estacion abre en visto', (
    WidgetTester t,
  ) async {
    final List<Object?> got = await open(
      t,
      initial: 'tropical',
      saved: (String key) =>
          key == 'tropical' ? <String>['Salsa', 'Cumbia'] : null,
    );
    expect(on(t, 'station-master-tropical'), isTrue);
    expect(off(t, 'station-master-momento'), isTrue);
    await t.tap(k('station-play-top'));
    await t.pumpAndSettle();
    final StationPick p = got.single! as StationPick;
    expect(p.key, 'tropical');
    expect(p.subGenres, <String>['Salsa', 'Cumbia']);
  });

  testWidgets('3169 panel de estaciones: maestro, flecha y aviso', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(420, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
        child: const MaterialApp(home: Scaffold(body: VibeHubView())),
      ),
    );
    for (int i = 0; i < 30; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await t.pump();
      if (k('vibe-hub-master-momento').evaluate().isNotEmpty) break;
    }
    expect(on(t, 'vibe-hub-master-momento'), isTrue);
    expect(off(t, 'vibe-hub-master-tropical'), isTrue);
    await t.tap(k('vibe-hub-st-momento'));
    await t.pump();
    expect(on(t, 'vibe-hub-cat-Pop'), isTrue);
    await t.tap(k('vibe-hub-chevron-momento'));
    await t.pump();
    expect(k('vibe-hub-cat-Pop'), findsNothing);
    await t.tap(k('vibe-hub-master-momento'));
    await t.pump();
    expect(off(t, 'vibe-hub-master-momento'), isTrue);
    await t.tap(k('vibe-hub-play'));
    await t.pump();
    expect(
      find.text('Tiene que escoger su Género Favorito...'),
      findsOneWidget,
    );
    expect(plans, isEmpty);
    expect(t.takeException(), isNull);
  });
}
