import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/bpm_backfill_worker.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/gatomix_radio.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/theme_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/startup_vibe_dialog.dart';
import 'package:difogo/ui/vibe_hub_view.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';

// 3.1.72: Play/Pausa a la izquierda de cada estacion (Hub y modal), Radio
// Descubrimiento, Spotify Pro (NOW PLAYING, badge, NEXT MIX) y blindaje de
// solo lectura de la biblioteca. Todo en %TEMP%, sin red ni audio.

class _Live extends LiveDjNotifier {
  _Live(this.seed);
  final LiveDjState seed;
  @override
  LiveDjState build() => seed;
}

final String _sep = Platform.pathSeparator;

double? _bpm(Object? v) => v is num
    ? v.toDouble()
    : (v is Map && v['bpm'] is num ? (v['bpm'] as num).toDouble() : null);

/// Foto de la biblioteca: ruta -> (bytes, mtime).
Map<String, String> _snap(String root) {
  final Map<String, String> out = <String, String>{};
  for (final FileSystemEntity e in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final FileStat st = e.statSync();
    out[e.path] = '${st.size}:${st.modified.millisecondsSinceEpoch}';
  }
  return out;
}

void main() {
  late Directory tmp;
  late String root;
  final List<StationPlan> plans = <StationPlan>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3172_');
    root = '${tmp.path}${_sep}ReGenial';
    for (final String g in <String>['Salsa', 'Reggaetón']) {
      for (final String n in <String>['a', 'b']) {
        File('$root$_sep$g$_sep$g $n.mp3')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0, 1, 2]);
      }
    }
    final String state = '${tmp.path}${_sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugVibeHubScan = (String r) async => const <VibeGenre>[
      VibeGenre('Salsa', 2),
      VibeGenre('Reggaetón', 2),
    ];
    debugStationSessionsPath = '${tmp.path}${_sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}$_sep$kTrackGenreIndexName';
    debugLibraryRoots = <String>[root];
    debugLibraryCacheRoot = '${tmp.path}${_sep}LocalAppData${_sep}cache';
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
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugStationPlay = null;
    debugStationFeed = null;
    debugStationLive = null;
    debugStationToggle = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Finder k(String key) => find.byKey(Key(key));
  IconData? iconOf(WidgetTester t, String key) => t
      .widget<Icon>(find.descendant(of: k(key), matching: find.byType(Icon)))
      .icon;

  String keyWith(List<GenreStation> st, String sub) =>
      st.firstWhere((GenreStation s) => s.subGenres.contains(sub)).key;

  testWidgets('3172 Hub: Play/Pausa a la izquierda, una sola estacion y '
      'guarda la anterior', (WidgetTester t) async {
    t.view.physicalSize = const Size(420, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    int toggles = 0;
    debugStationToggle = () async => toggles++;
    debugStationLive = () => StationLive(
      '$root${_sep}Salsa${_sep}Salsa a.mp3',
      42000,
      <String>['$root${_sep}Salsa${_sep}Salsa b.mp3'],
    );
    final ProviderContainer c = ProviderContainer(
      overrides: [
        liveDjProvider.overrideWith(() => _Live(LiveDjState(isPlaying: true))),
      ],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: VibeHubView(onPlayed: () {})),
        ),
      ),
    );
    for (int i = 0; i < 30; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump();
      if (c.read(vibeHubProvider).stations.length > 1) break;
    }
    final List<GenreStation> st = c.read(vibeHubProvider).stations;
    final String a = keyWith(st, 'Salsa');
    final String b = keyWith(st, 'Reggaetón');
    expect(a, isNot(b));
    // Cada estacion: Play redondo a la IZQUIERDA del titulo; sin radio.
    for (final GenreStation s in st) {
      expect(k('vibe-hub-play-${s.key}'), findsOneWidget);
      expect(iconOf(t, 'vibe-hub-play-${s.key}'), Icons.play_arrow_rounded);
    }
    expect(find.byIcon(Icons.radio), findsNothing);
    final Finder titleA = find.text(stationTitleOf(a));
    expect(
      t.getCenter(k('vibe-hub-play-$a')).dx,
      lessThan(t.getTopLeft(titleA).dx),
    );
    // Un toque: suena SOLO esa estacion en Shuffle.
    await t.tap(k('vibe-hub-play-$a'));
    for (int i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump();
    }
    expect(plans, hasLength(1));
    expect(c.read(vibeHubProvider).activeStation, a);
    expect(iconOf(t, 'vibe-hub-play-$a'), Icons.pause_rounded);
    expect(iconOf(t, 'vibe-hub-play-$b'), Icons.play_arrow_rounded);
    // Otra estacion: la anterior queda guardada donde iba.
    await t.tap(k('vibe-hub-play-$b'));
    for (int i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump();
    }
    expect(plans, hasLength(2));
    expect(c.read(vibeHubProvider).activeStation, b);
    final GenreSession? saved = c
        .read(vibeHubProvider.notifier)
        .stationSession(a);
    expect(saved?.currentTrackPath, endsWith('Salsa a.mp3'));
    expect(saved?.positionMs, 42000);
    expect(iconOf(t, 'vibe-hub-play-$a'), Icons.play_arrow_rounded);
    expect(iconOf(t, 'vibe-hub-play-$b'), Icons.pause_rounded);
    // ⏸ de la que suena: pausa/reanuda sin volver a armar la cola.
    await t.tap(k('vibe-hub-play-$b'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump();
    expect(toggles, 1);
    expect(plans, hasLength(2));
    expect(t.takeException(), isNull);
  });

  testWidgets('3172 modal Escoge Tus Generos: Play/Pausa a la izquierda', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final List<GenreStation> st = groupStations(const <MapEntry<String, int>>[
      MapEntry<String, int>('Salsa', 2),
      MapEntry<String, int>('Reggaetón', 2),
    ]);
    final String a = keyWith(st, 'Salsa');
    final String b = keyWith(st, 'Reggaetón');
    int toggles = 0;
    final List<Object?> got = <Object?>[];
    await t.pumpWidget(
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
                    activeStation: a,
                    playing: true,
                    onTogglePause: () async => toggles++,
                  ),
                ),
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.radio), findsNothing);
    expect(iconOf(t, 'station-play-$a'), Icons.pause_rounded);
    expect(iconOf(t, 'station-play-$b'), Icons.play_arrow_rounded);
    expect(
      t.getCenter(k('station-play-$a')).dx,
      lessThan(t.getTopLeft(find.text(stationTitleOf(a))).dx),
    );
    // ⏸ de la que suena: pausa sin cerrar el selector.
    await t.tap(k('station-play-$a'));
    await t.pumpAndSettle();
    expect(toggles, 1);
    expect(iconOf(t, 'station-play-$a'), Icons.play_arrow_rounded);
    expect(got, isEmpty);
    // ▶ de otra: suena esa estacion (una sola) en Shuffle.
    await t.tap(k('station-play-$b'));
    await t.pumpAndSettle();
    expect(got, hasLength(1));
    final StationPick pick = got.single! as StationPick;
    expect(pick.key, b);
    expect(pick.subGenres, isNotEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('3172 RADIO DESCUBRIMIENTO: intercala temas nuevos del '
      'curador sin escribir en la biblioteca', (WidgetTester t) async {
    final String inbox = '${tmp.path}${_sep}Inbox';
    final List<String> news = <String>[
      for (final String n in <String>['n1', 'n2'])
        (File('$inbox$_sep$n.mp3')
              ..createSync(recursive: true)
              ..writeAsBytesSync(<int>[9]))
            .path,
    ];
    debugStationFeed = (String key, StationFeed f, int n) async => news;
    final List<File> local = <File>[
      for (final String n in <String>['a', 'b'])
        File('$root${_sep}Salsa${_sep}Salsa $n.mp3'),
      for (final String n in <String>['a', 'b'])
        File('$root${_sep}Reggaetón${_sep}Reggaetón $n.mp3'),
    ];
    final Map<String, String> before = _snap(root);
    final ProviderContainer c = ProviderContainer(
      overrides: [
        liveDjProvider.overrideWith(
          () => _Live(LiveDjState(queue: local, isPlaying: true)),
        ),
      ],
    );
    addTearDown(c.dispose);
    await t.runAsync(() async {
      await c.read(vibeHubProvider.notifier).refresh();
    });
    final List<GenreStation> st = c.read(vibeHubProvider).stations;
    final String a = keyWith(st, 'Salsa');
    await t.runAsync(
      () => c.read(vibeHubProvider.notifier).playStation(a, <String>['Salsa']),
    );
    // 3.1.84: chip compacto.
    expect(kRadioDiscoveryLabel, 'Radio');
    expect(radioDiscoveryTooltip(false), contains('solo suena tu biblioteca'));
    expect(radioDiscoveryTooltip(true), contains('Aceptar'));
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: RadioDiscoveryButton(compact: true)),
          ),
        ),
      ),
    );
    expect(find.text(kRadioDiscoveryLabel), findsOneWidget);
    expect(find.text('PRENDE MODO RADIO'), findsNothing);
    await t.tap(k('radio-discovery-toggle'));
    for (int i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump();
    }
    expect(c.read(vibeHubProvider).discoveryOn, isTrue);
    final List<String> q = <String>[
      for (final File f in c.read(liveDjProvider).queue) f.path,
    ];
    // 2 locales y 1 nueva, en la cola de la estacion activa.
    expect(q, hasLength(6));
    expect(q[2], news[0]);
    expect(q[5], news[1]);
    expect(q.where((String p) => p.startsWith(root)), hasLength(4));
    expect(c.read(liveDjProvider).radioOn, isFalse);
    // Nada se escribio en la biblioteca: los temas siguen en la bandeja.
    expect(_snap(root), before);
    expect(File(news[0]).existsSync(), isTrue);
    await t.tap(k('radio-discovery-toggle'));
    await t.pump();
    expect(c.read(vibeHubProvider).discoveryOn, isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('3172 Spotify Pro: NOW PLAYING, badge y NEXT MIX', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final LiveDjState s = LiveDjState(
      currentTrackPath: '$root${_sep}Uno - Besame.mp3',
      queue: <File>[File('$root${_sep}Dos - Provenza.mp3')],
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 200),
      customMixOutMs: 90000,
    );
    expect(spotifyNextMixLabel(s), 'NEXT MIX en 01:00 · Provenza');
    expect(spotifyStationBadge(null), 'BIBLIOTECA LOCAL');
    expect(
      spotifyStationBadge('tropical'),
      stationTitleOf('tropical').toUpperCase(),
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [liveDjProvider.overrideWith(() => _Live(s))],
        child: const MaterialApp(
          home: Scaffold(body: LiveDjSpotifyPanel(compact: false)),
        ),
      ),
    );
    await t.pump();
    expect(find.text('NOW PLAYING'), findsOneWidget);
    // 3.1.84 Consumer Clean Mode: badge, chip de mezcla y NEXT MIX viven
    // en la hoja Modo DJ, no en la pantalla principal.
    expect(k('spotify-station-badge'), findsNothing);
    expect(k('spotify-mix-chip'), findsNothing);
    expect(find.text('NEXT MIX en 01:00 · Provenza'), findsNothing);
    expect(k('spotify-play'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('3172 blindaje: nada se escribe dentro de la biblioteca; el cache va '
      'al espejo local', () async {
    final String dir = '$root${_sep}Salsa';
    final String song = '$dir${_sep}Salsa a.mp3';
    // .gatomix.json viejo de la carpeta: se LEE, no se borra ni se reescribe.
    final File legacy = File('$dir$_sep$gatomixOldStoreName')
      ..writeAsStringSync(
        '{"schema":1,"djMetadata":{"$song":101.0}}'.replaceAll(r'\', r'\\'),
      );
    File('$dir${_sep}_dj_timestamps.json').writeAsStringSync('{}');
    final Map<String, String> before = _snap(root);
    final String legacyText = legacy.readAsStringSync();
    GatomixStore.forget(<String>[dir]);
    expect(isLibraryPath(song), isTrue);
    expect(isLibraryPath('$root${_sep}DjPlaylists${_sep}x.json'), isFalse);
    expect(_bpm(readDjMetadata(dir)[song]), 101.0);
    final int blocked = libraryGuardBlocked;
    saveTrackMusic(song, bpm: 124);
    stampBackfill(song, 124);
    GatomixStore.migrate(dir);
    GatomixLog.append(dir, 'prueba 3172');
    GatomixRadio.save(root, RadioMemory.empty);
    final File lrc = lrcWriteFile(song, '$dir${_sep}Salsa a.lrc');
    lrc.writeAsStringSync('[00:01.00]hola');
    expect(libraryWriteBlocked(song, what: 'TBPM'), isTrue);
    expect(libraryGuardBlocked, greaterThan(blocked));
    GatomixStore.forget(<String>[dir]);
    // Lo nuevo se lee del espejo (con lo viejo de la carpeta adentro).
    final Map<String, dynamic> meta = readDjMetadata(dir);
    expect(_bpm(meta[song]), 124.0);
    expect(lrcReadFile(song, '$dir${_sep}Salsa a.lrc').path, lrc.path);
    // Cero escritura en la biblioteca falsa.
    expect(_snap(root), before);
    expect(legacy.readAsStringSync(), legacyText);
    expect(File('$dir${_sep}_dj_timestamps.json').existsSync(), isTrue);
    expect(File('$dir$_sep$gatomixLogName').existsSync(), isFalse);
    expect(File('$root$_sep$gatomixRadioName').existsSync(), isFalse);
    // El espejo vive en la ruta local sobrescrita.
    final String cache = libraryCacheRoot();
    expect(GatomixStore.fileOf(dir).path, startsWith(cache));
    expect(GatomixStore.fileOf(dir).existsSync(), isTrue);
    expect(GatomixRadio.fileIn(root).path, startsWith(cache));
    expect(lrc.path, startsWith(cache));
    expect(libraryMirrorKey(dir), libraryMirrorKey(dir));
    // 3.1.75: %LOCALAPPDATA%\DiFogo\folder_cache\<hash_de_carpeta>.difogo.json
    final String key = libraryMirrorKey(dir);
    expect(key, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(GatomixStore.fileOf(dir).path, '$cache$_sep$key$kMirrorStoreSuffix');
    final String? over = debugLibraryCacheRoot;
    debugLibraryCacheRoot = null;
    final String real = libraryCacheRoot();
    debugLibraryCacheRoot = over;
    expect(
      real.replaceAll('\\', '/'),
      endsWith(Platform.isWindows ? 'DiFogo/folder_cache' : 'folder_cache'),
    );
    if (Platform.isWindows) {
      expect(
        real.toLowerCase(),
        startsWith(Platform.environment['LOCALAPPDATA']!.toLowerCase()),
      );
    }
    // Fuera de la biblioteca todo sigue como antes (junto a la carpeta).
    final String outside = '${tmp.path}${_sep}Otra';
    Directory(outside).createSync();
    saveTrackMusic('$outside${_sep}x.mp3', bpm: 99);
    expect(File('$outside$_sep$gatomixStoreName').existsSync(), isTrue);
  });
}
