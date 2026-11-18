import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/startup_vibe_dialog.dart';

// 3.1.67 (la orden pedia 3166): una carpeta "shampoo" con canciones
// revueltas se clasifica cancion por cancion, las nuevas van a la ruta
// canonica <Estacion>/<Sub> y salir del selector deja Live DJ sonando.
// Todo en %TEMP%, sin red, sin motor de audio y sin tocar la biblioteca.

const Map<String, String> _want = <String, String>{
  'Marc Anthony - Vivir Mi Vida.mp3': 'tropical/Salsa',
  'Michael Jackson - Billie Jean (1982).mp3': 'ochenteras/Pop',
  'Soda Stereo - De Musica Ligera.mp3': 'rock/Rock Clásico Español',
  'Camilo Sesto - Perdóname.mp3': 'baladas/En Español',
  'Romeo Santos - Propuesta Indecente.mp3': 'tropical/Bachatas',
  'Metallica - Enter Sandman.mp3': 'rock/Heavy Metal',
  'Karol G - Si Antes Te Hubiera Conocido.mp3': 'momento/Reggaetón',
  'Los Angeles Azules - Nunca Es Suficiente.mp3': 'tropical/Cumbia',
  'Juan Luis Guerra - La Bilirrubina.mp3': 'tropical/Merengue',
  'Sharon La Hechicera - Tu Juguete.mp3': 'nacional/Tecnocumbia',
};

/// Live DJ falso: loadStation deja la cola y "suena" sin motor de audio.
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
}

void main() {
  late Directory tmp;
  late String root;
  late String mix;
  final String sep = Platform.pathSeparator;
  final List<String> feeds = <String>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_shampoo_3167_');
    root = '${tmp.path}${sep}R';
    mix = '$root${sep}Carpeta_Shampoo_Mix';
    Directory(mix).createSync(recursive: true);
    for (final String n in _want.keys) {
      File('$mix$sep$n').writeAsBytesSync(List<int>.filled(32, 1));
    }
    final String state = '${tmp.path}${sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugStationSessionsPath = '${tmp.path}${sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}$sep$kTrackGenreIndexName';
    debugStationRng = Random(11);
    debugStationFeed = (String k, StationFeed f, int n) async {
      feeds.add('$k|${f.folder}|$n');
      return const <String>[];
    };
    feeds.clear();
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugStationSessionsPath = null;
    debugTrackGenreIndexPath = null;
    debugStationRng = null;
    debugStationFeed = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    '3167 carpeta shampoo: cada cancion a su estacion y sub-genero',
    () async {
      expect(isGenericMusicFolder('Carpeta_Shampoo_Mix'), isTrue);
      expect(stationSubOf('Carpeta_Shampoo_Mix'), isNull);
      for (final String g in <String>[
        'Descargas',
        'Mi Música',
        'Nueva carpeta',
      ]) {
        expect(stationSubOf(g), isNull, reason: g);
      }
      final List<String> paths = <String>[
        for (final String n in _want.keys) '$mix$sep$n',
      ];
      final TrackGenreIndex idx = TrackGenreIndex.read(
        debugTrackGenreIndexPath!,
      );
      final TrackGenreBuckets b = await classifyTracks(
        paths,
        root: root,
        index: idx,
      );
      await idx.write();
      for (final MapEntry<String, String> e in _want.entries) {
        final TrackGenre g = TrackGenreClassifier.classify(
          '$mix$sep${e.key}',
          root: root,
        );
        expect('${g.stationId}/${g.subGenreId}', e.value, reason: e.key);
        expect(isStationSub(g.stationId!, g.subGenreId!), isTrue);
        // Mismo resultado en otra carpeta generica y suelta en la raiz.
        for (final String other in <String>[
          '$root${sep}Descargas$sep${e.key}',
          '$root$sep${e.key}',
        ]) {
          final TrackGenre o = TrackGenreClassifier.classify(other, root: root);
          expect('${o.stationId}/${o.subGenreId}', e.value, reason: other);
        }
      }
      expect(b.unknown, isEmpty);
      expect(b.tracksFor('tropical', <String>['Salsa', 'Bachatas']).length, 2);
      final Map<String, dynamic> doc =
          jsonDecode(File(debugTrackGenreIndexPath!).readAsStringSync())
              as Map<String, dynamic>;
      final Map<String, dynamic> tracks = doc['tracks'] as Map<String, dynamic>;
      expect(tracks.length, 10);
      for (final String p in paths) {
        final Map<String, dynamic> t =
            tracks[stationPathKey(p)] as Map<String, dynamic>;
        expect(t['mtime'], File(p).statSync().modified.millisecondsSinceEpoch);
        expect(
          '${t['stationId']}/${t['subGenreId']}',
          _want[p.split(sep).last],
        );
      }
      // Segunda pasada: sale del indice por path + mtime.
      final TrackGenreIndex again = TrackGenreIndex.read(
        debugTrackGenreIndexPath!,
      );
      final String marc = paths.first;
      expect(
        again.lookup(
          marc,
          File(marc).statSync().modified.millisecondsSinceEpoch,
        ),
        isNotNull,
      );
      expect(again.lookup(marc, 1), isNull);
    },
  );

  test(
    '3167 cancion nueva de Tropical > Salsa: ruta canonica e indice',
    () async {
      final String dir = stationSaveDir(root, 'tropical', 'Salsa');
      expect(dir, '$root${sep}Tropical${sep}Salsa');
      expect(
        stationCanonicalRel('momento', 'Reggaetón'),
        'Musica_del_Momento/Reggaeton',
      );
      expect(
        stationFeedFor('tropical', <String>[
          'Salsa',
        ], const <String, int>{})!.folder,
        'Tropical/Salsa',
      );
      // Si ya hay una carpeta de Salsa, se sigue usando esa.
      expect(
        stationSaveDir(
          root,
          'tropical',
          'Salsa',
          library: const <String, int>{'Salsa Brava': 4},
        ),
        '$root${sep}Salsa Brava',
      );
      Directory(dir).createSync(recursive: true);
      final String dst = '$dir${sep}Tema Nuevo Del Curador.mp3';
      File(dst).writeAsBytesSync(List<int>.filled(32, 2));
      final TrackGenre g = (await registerSavedTrack(
        debugTrackGenreIndexPath!,
        root,
        dst,
      ))!;
      expect('${g.stationId}/${g.subGenreId}', 'tropical/Salsa');
      final Map<String, dynamic> t =
          ((jsonDecode(File(debugTrackGenreIndexPath!).readAsStringSync())
                      as Map<String, dynamic>)['tracks']
                  as Map<String, dynamic>)[stationPathKey(dst)]
              as Map<String, dynamic>;
      expect(t['stationId'], 'tropical');
      expect(t['subGenreId'], 'Salsa');
      expect(t['level'], 0);
      // Y la estacion la encuentra aunque el indice se pierda (carpeta).
      expect(TrackGenreClassifier.classify(dst, root: root).level, 0);
    },
  );

  testWidgets('3167 salir del selector tras tocar Tropical: Live DJ suena', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext ctx, WidgetRef ref, _) => TextButton(
              onPressed: () => showStartupVibeFlow(ctx, ref),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    final ProviderContainer c = ProviderScope.containerOf(
      tester.element(find.text('abrir')),
    );
    await tester.tap(find.text('abrir'));
    for (int i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.text('Escoge Tus Géneros Preferidos').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text('Escoge Tus Géneros Preferidos'), findsOneWidget);
    // Tropical muestra las 4 canciones sacadas de la carpeta shampoo.
    expect(find.textContaining('4 canciones'), findsOneWidget);
    await tester.tap(find.byKey(const Key('station-master-tropical')));
    await tester.pump();
    // Sale tocando fuera del cuadro, sin el boton de reproducir.
    final Stopwatch sw = Stopwatch()..start();
    await tester.tapAt(const Offset(8, 8));
    for (int i = 0; i < 60; i++) {
      await tester.pump();
      if (c.read(liveDjProvider).isPlaying) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    sw.stop();
    final LiveDjState dj = c.read(liveDjProvider);
    expect(dj.isPlaying, isTrue);
    final List<String> order = <String>[
      dj.currentTrackPath!,
      for (final File f in dj.queue) f.path,
    ];
    final List<String> sorted = List<String>.from(order)..sort();
    expect(order.length, 4);
    expect(
      order.every((String p) => p.contains('Carpeta_Shampoo_Mix')),
      isTrue,
    );
    expect(order, isNot(sorted));
    // ignore: avoid_print
    print('3167 selector -> isPlaying en ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(c.read(vibeHubProvider).activeStation, 'tropical');
    expect(tester.takeException(), isNull);
  });

  test(
    '3167 estacion sin canciones locales: el curador la arranca sola',
    () async {
      final String inbox = '${tmp.path}${sep}inbox${sep}Nuevo Hit Bailable.mp3';
      File(inbox)
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(32, 3));
      debugStationFeed = (String k, StationFeed f, int n) async {
        feeds.add('$k|${f.folder}|$n');
        return n == 1 ? <String>[inbox] : const <String>[];
      };
      final ProviderContainer c = ProviderContainer(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
      );
      addTearDown(c.dispose);
      final VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      await hub.refresh();
      expect(await hub.playStation('fiesta', <String>['Hits Bailables']), 0);
      for (int i = 0; i < 100 && !c.read(liveDjProvider).isPlaying; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(c.read(liveDjProvider).isPlaying, isTrue);
      expect(c.read(liveDjProvider).currentTrackPath, inbox);
      expect(feeds.first, 'fiesta|Fiesta_MIX/Hits_Bailables|1');
      await hub.stationsSettled;
    },
  );
}
