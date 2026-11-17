import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/genre_stations.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/curator_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/session_provider.dart';
import 'package:gatomix/providers/theme_provider.dart';
import 'package:gatomix/providers/vibe_hub_provider.dart';
import 'package:gatomix/services/smart_discovery_service.dart';
import 'package:gatomix/ui/curator_inbox_dialog.dart';
import 'package:gatomix/ui/startup_vibe_dialog.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

// 3.1.68: sub-genero "Todas" en Ochenteras, Tropical y Baladas, boton
// "Acepta Nueva Musica" con conteo y caja agrupada por estacion/sub-genero.
// Todo en %TEMP%, sin red, sin motor de audio y sin tocar la biblioteca.

class _FakeQueue extends AutomixQueueNotifier {
  @override
  List<File> build() => <File>[];

  @override
  void addTrack(File file) => state = <File>[...state, file];
}

/// Live DJ falso: carga, suena y suma a la cola sin motor ni disco.
class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();

  @override
  Future<bool> loadStation({
    String? currentPath,
    int positionMs = 0,
    required List<File> queue,
    bool autoPlay = true,
  }) async {
    final List<File> q = List<File>.from(queue);
    final String? cur = currentPath ?? (q.isEmpty ? null : q.removeAt(0).path);
    state = state.copyWith(
      queue: q,
      currentTrackPath: cur,
      isPlaying: autoPlay && cur != null,
    );
    return true;
  }

  @override
  void addAllTracks(List<File> files) =>
      state = state.copyWith(queue: <File>[...state.queue, ...files]);
}

void main() {
  final String sep = Platform.pathSeparator;
  late Directory tmp;
  late String root;
  late String inbox;
  final List<String> feeds = <String>[];

  /// Bandeja con temas de 3 generos (curator_inbox.json real en %TEMP%).
  void seedInbox(List<List<String>> rows) {
    Directory(inbox).createSync(recursive: true);
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    for (final List<String> r in rows) {
      final String file = '$inbox$sep${r[1]}.mp3';
      File(file).writeAsStringSync('mp3:${r[0]}');
      entries.add(<String, dynamic>{
        'id': r[0],
        'title': r[1],
        'genre': stationCanonicalRel(r[2], r[3]),
        'file': file,
        'status': 'pending',
        'addedAt': '2026-11-17T12:00:00',
        'stationId': r[2],
        'subGenreId': r[3],
        'durationMs': 215000,
      });
    }
    File('$inbox${sep}curator_inbox.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'lastRun': <String, String>{},
        'entries': entries,
      }),
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_accept_3168_');
    root = '${tmp.path}${sep}R';
    inbox = '${tmp.path}${sep}Inbox';
    final String mix = '$root${sep}Carpeta_Shampoo_Mix';
    Directory(mix).createSync(recursive: true);
    for (final String n in <String>[
      'Grupo Desconocido - Tema Raro.mp3',
      'Banda Ignota - Otra Cancion.mp3',
      'Marc Anthony - Vivir Mi Vida.mp3',
    ]) {
      File('$mix$sep$n').writeAsBytesSync(List<int>.filled(32, 1));
    }
    final String state = '${tmp.path}${sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugStationSessionsPath = '${tmp.path}${sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}$sep$kTrackGenreIndexName';
    debugStationRng = Random(3);
    debugDisableCuratorWorker = true;
    debugCuratorRegister = (String p, String g) async {};
    debugCuratorService = SmartDiscoveryService(
      search: (String q) async => const <DiscoveryCandidate>[],
      download: (DiscoveryCandidate c, String mp3) async {},
      inboxDir: inbox,
      now: () => DateTime(2026, 11, 17, 12),
    );
    debugStationFeed = (String k, StationFeed f, int n) async {
      feeds.add('$k|${f.sub}|$n');
      return const <String>[];
    };
    feeds.clear();
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugStationSessionsPath = null;
    debugTrackGenreIndexPath = null;
    debugStationRng = null;
    debugCuratorService = null;
    debugCuratorRegister = null;
    debugStationFeed = null;
    debugLiveDjForceMobile = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets(
    '3168 Todas al final de Ochenteras, Tropical y Baladas en visto',
    (WidgetTester tester) async {
      for (final String k in kTodasAddedIn3168) {
        expect(universalStation(k)!.subs.last.label, 'Todas', reason: k);
        expect(stationFallbackSub(k), 'Todas', reason: k);
      }
      for (final UniversalStation u in kUniversalStations) {
        expect(stationFallbackSub(u.key), isNotNull, reason: u.key);
      }
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<GenreStation> st = groupStations(const <MapEntry<String, int>>[
        MapEntry<String, int>('80s Ingles', 3),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) => TextButton(
              onPressed: () => showDialog<StationPick>(
                context: ctx,
                builder: (_) => StationPickerDialog(stations: st),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      final Finder list = find.descendant(
        of: find.byKey(const ValueKey<String>('station-list')),
        matching: find.byType(Scrollable),
      );
      for (final String t in <String>['Ochenteras', 'Tropical', 'Baladas']) {
        // 3.1.69: el visto maestro enciende todos sus sub-generos y el
        // titulo solo despliega (y al final minimiza).
        final Finder master = find.byKey(
          Key('station-master-${t.toLowerCase()}'),
        );
        await tester.ensureVisible(master);
        await tester.pumpAndSettle();
        await tester.tap(master);
        await tester.pumpAndSettle();
        await tester.tap(find.text(t));
        await tester.pumpAndSettle();
        final Finder todas = find.byKey(const Key('station-sub-Todas'));
        await tester.scrollUntilVisible(todas, 60, scrollable: list);
        expect(todas, findsOneWidget, reason: t);
        expect(
          find.descendant(of: todas, matching: find.byIcon(Icons.check_box)),
          findsOneWidget,
          reason: t,
        );
        await tester.ensureVisible(find.text(t));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t));
        await tester.pumpAndSettle();
        expect(todas, findsNothing, reason: t);
      }
      expect(tester.takeException(), isNull);
    },
  );

  test(
    '3168 canciones shampoo sin match caen en Todas de cada estacion',
    () async {
      final ProviderContainer c = ProviderContainer(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
      );
      addTearDown(c.dispose);
      final VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      await hub.refresh();
      for (final String k in kTodasAddedIn3168) {
        expect(await hub.playStation(k, <String>['Todas']), 2, reason: k);
        final LiveDjState dj = c.read(liveDjProvider);
        final List<String> all = <String>[
          dj.currentTrackPath!,
          for (final File f in dj.queue) f.path,
        ];
        expect(
          all.every((String p) => p.contains('Carpeta_Shampoo_Mix')),
          isTrue,
        );
        expect(all.any((String p) => p.contains('Marc Anthony')), isFalse);
        expect(dj.isPlaying, isTrue);
      }
      // Con Salsa + Todas, Tropical suma la de Marc Anthony.
      expect(await hub.playStation('tropical', <String>['Salsa', 'Todas']), 3);
      await hub.stationsSettled;
      // Sesion de antes (schema 1): "Todas" entra en visto sin perder lo demas.
      final String old = '${tmp.path}${sep}old_sessions.json';
      File(old).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'schema': 1,
          'active': 'tropical',
          'stations': <String, dynamic>{
            'tropical': <String, dynamic>{
              'subGenresChecked': <String>['Salsa', 'Cumbia'],
              'currentTrackPath': '/m/Salsa/a.mp3',
              'positionMs': 4000,
            },
            'momento': <String, dynamic>{
              'subGenresChecked': <String>['Pop'],
            },
          },
        }),
      );
      final GenreSessionDoc d = GenreSessionDoc.read(old);
      expect(d.stations['tropical']!.subGenresChecked, <String>[
        'Salsa',
        'Cumbia',
        'Todas',
      ]);
      expect(d.stations['tropical']!.positionMs, 4000);
      expect(d.stations['momento']!.subGenresChecked, <String>['Pop']);
    },
  );

  testWidgets('3168 Live DJ muestra el boton Acepta Nueva Musica con conteo', (
    WidgetTester tester,
  ) async {
    seedInbox(<List<String>>[
      <String>['s1', 'Salsa Uno', 'tropical', 'Salsa'],
      <String>['p1', 'Pop Ochentero', 'ochenteras', 'Pop'],
      <String>['r1', 'Reggaeton Nuevo', 'momento', 'Reggaetón'],
    ]);
    debugLiveDjForceMobile = false;
    debugVibeHubScan = (String r) async => const <VibeGenre>[
      VibeGenre('Salsa', 1),
    ];
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveDjProvider.overrideWith(_FakeLiveDj.new),
          automixQueueProvider.overrideWith(_FakeQueue.new),
        ],
        child: MaterialApp(
          theme: GatoMixTheme.darkTheme,
          home: const LiveDjWorkspace(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('✨ Acepta Nueva Música (3)'), findsOneWidget);
    expect(find.text('ESTACIONES & GÉNEROS'), findsOneWidget);
    expect(find.text('SMART VIBE'), findsNothing);
    final OutlinedButton b = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('curator-inbox-button')),
    );
    expect(b.style!.side!.resolve(<WidgetState>{})!.color, GatoMixTheme.fire);
    expect(GatoMixTheme.fire, const Color(0xFFFF5722));
    expect(tester.takeException(), isNull);
  });

  testWidgets('3168 caja agrupada: encabezados, aceptar, aceptar todo y buscar', (
    WidgetTester tester,
  ) async {
    seedInbox(<List<String>>[
      <String>['s1', 'Salsa Uno', 'tropical', 'Salsa'],
      <String>['s2', 'Salsa Dos', 'tropical', 'Salsa'],
      <String>['p1', 'Pop Ochentero', 'ochenteras', 'Pop'],
      <String>['r1', 'Reggaeton Nuevo', 'momento', 'Reggaetón'],
    ]);
    // Tropical (Salsa en visto) es la estacion que suena.
    File(debugStationSessionsPath!).writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 2,
        'active': 'tropical',
        'stations': <String, dynamic>{
          'tropical': <String, dynamic>{
            'subGenresChecked': <String>['Salsa', 'Todas'],
          },
        },
      }),
    );
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveDjProvider.overrideWith(_FakeLiveDj.new),
          automixQueueProvider.overrideWith(_FakeQueue.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Center(child: CuratorInboxButton())),
        ),
      ),
    );
    final ProviderContainer c = ProviderScope.containerOf(
      tester.element(find.byType(CuratorInboxButton)),
    );
    expect(find.text('✨ Acepta Nueva Música (4)'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('curator-inbox-button')),
    );
    await tester.pumpAndSettle();
    const String hTrop = 'TROPICAL • Salsa (2 canciones)';
    const String hOch = 'OCHENTERAS • Pop (1 canción)';
    const String hMom = 'MÚSICA DEL MOMENTO • Reggaetón (1 canción)';
    for (final String h in <String>[hTrop, hOch, hMom]) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    double y(Finder f) => tester.getTopLeft(f).dy;
    Finder card(String id) => find.byKey(ValueKey<String>('curator-card-$id'));
    // Orden del catalogo; cada encabezado va arriba de sus canciones y
    // antes del grupo siguiente.
    expect(y(find.text(hMom)), lessThan(y(card('r1'))));
    expect(y(card('r1')), lessThan(y(find.text(hOch))));
    expect(y(find.text(hOch)), lessThan(y(card('p1'))));
    expect(y(card('p1')), lessThan(y(find.text(hTrop))));
    expect(find.text('Aceptar todo este género'), findsNWidgets(3));
    // La lista es perezosa: se desplaza hasta cada tarjeta antes de medir.
    final Finder box = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Scrollable))
        .first;
    Future<void> show(Finder f) async {
      tester.state<ScrollableState>(box).position.jumpTo(0);
      await tester.pump();
      await tester.scrollUntilVisible(f, 80, scrollable: box);
      await tester.pump();
    }

    for (final String id in <String>['r1', 'p1', 's1', 's2']) {
      await show(card(id));
      expect(
        find.descendant(of: card(id), matching: find.textContaining('3:35')),
        findsOneWidget,
        reason: id,
      );
    }
    expect(y(find.text(hTrop)), lessThan(y(card('s1'))));
    expect(y(card('s1')), lessThan(y(card('s2'))));

    Future<void> settle(bool Function() done) async {
      for (int i = 0; i < 60 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
    }

    // Aceptar una de Salsa: carpeta canonica, indice y cola de Tropical.
    final String salsa = '$root${sep}Tropical${sep}Salsa${sep}Salsa Uno.mp3';
    await show(find.byKey(const ValueKey<String>('curator-accept-s1')));
    await tester.tap(find.byKey(const ValueKey<String>('curator-accept-s1')));
    await settle(
      () => File(salsa).existsSync() && card('s1').evaluate().isEmpty,
    );
    expect(File(salsa).readAsStringSync(), 'mp3:s1');
    expect(File('$inbox${sep}Salsa Uno.mp3').existsSync(), isFalse);
    await settle(
      () => c.read(liveDjProvider).queue.any((File f) => f.path == salsa),
    );
    expect(c.read(liveDjProvider).queue.map((File f) => f.path), <String>[
      salsa,
    ]);
    // Aceptar todo Ochenteras > Pop.
    final String pop = '$root${sep}Ochenteras${sep}Pop${sep}Pop Ochentero.mp3';
    await show(
      find.byKey(const ValueKey<String>('curator-accept-all-ochenteras-Pop')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('curator-accept-all-ochenteras-Pop')),
    );
    await settle(() => File(pop).existsSync() && card('p1').evaluate().isEmpty);
    expect(File(pop).existsSync(), isTrue);
    expect(find.text(hOch), findsNothing);
    // Aceptar todo Momento > Reggaeton (otra estacion: no entra a la cola).
    final String reg =
        '$root${sep}Musica_del_Momento${sep}Reggaeton${sep}Reggaeton Nuevo.mp3';
    await show(
      find.byKey(
        const ValueKey<String>('curator-accept-all-momento-Reggaetón'),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('curator-accept-all-momento-Reggaetón'),
      ),
    );
    await settle(() => File(reg).existsSync() && card('r1').evaluate().isEmpty);
    expect(File(reg).existsSync(), isTrue);
    expect(c.read(liveDjProvider).queue.length, 1);
    // Indice por cancion con estacion y sub-genero.
    final Map<String, dynamic> tracks =
        (jsonDecode(File(debugTrackGenreIndexPath!).readAsStringSync())
                as Map<String, dynamic>)['tracks']
            as Map<String, dynamic>;
    for (final MapEntry<String, String> e in <String, String>{
      salsa: 'tropical/Salsa',
      pop: 'ochenteras/Pop',
      reg: 'momento/Reggaetón',
    }.entries) {
      final Map<String, dynamic> t =
          tracks[stationPathKey(e.key)] as Map<String, dynamic>;
      expect('${t['stationId']}/${t['subGenreId']}', e.value);
    }
    // Descartar la ultima: bandeja vacia y buscar en los generos en visto.
    await show(find.byKey(const ValueKey<String>('curator-reject-s2')));
    await tester.tap(find.byKey(const ValueKey<String>('curator-reject-s2')));
    await tester.pumpAndSettle();
    expect(c.read(curatorProvider).pending, isEmpty);
    final Finder search = find.text(
      '🔍 Buscar Nueva Música para mis Géneros Activos',
    );
    expect(search, findsOneWidget);
    await tester.tap(search);
    await settle(() => feeds.length >= 2);
    expect(feeds.toSet(), <String>{'tropical|Salsa|2', 'tropical|Todas|2'});
    expect(tester.takeException(), isNull);
  });
}
