import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/discovery_dedup_controller.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/genre_track_pool.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/radio_one_click.dart';
import 'package:difogo/core/track_name_clean.dart';
import 'package:difogo/providers/curator_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/services/smart_discovery_service.dart';

// 3.1.87: anti-duplicados de la Radio Descubrimiento, Auto-Radio con 0
// canciones locales, Guardar / Descartar en 1 clic y ventana acotada de
// hidratacion. Todo en %TEMP%, sin red, sin audio y sin abrir la app.

final String _sep = Platform.pathSeparator;

Map<String, String> _snap(String root) {
  final Map<String, String> out = <String, String>{};
  if (!Directory(root).existsSync()) return out;
  for (final FileSystemEntity e in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    out[e.path] = '${e.lengthSync()}';
  }
  return out;
}

void main() {
  late Directory tmp;
  late String music;
  late String root;
  late String inbox;
  final List<StationPlan> plans = <StationPlan>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3187_');
    music = '${tmp.path}${_sep}Music';
    root = '$music${_sep}ReGenial';
    inbox = '${tmp.path}${_sep}Inbox';
    Directory(root).createSync(recursive: true);
    final String state = '${tmp.path}${_sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugStationSessionsPath = '${tmp.path}${_sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}$_sep$kTrackGenreIndexName';
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = '${tmp.path}${_sep}cache';
    debugRadioFallbackRoot = '$music${_sep}Descargas';
    debugDiscoveryDiscardPath = '${tmp.path}${_sep}discards.json';
    plans.clear();
    debugStationPlay = (StationPlan p) async => plans.add(p);
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugStationSessionsPath = null;
    debugStationCollect = null;
    debugStationFeed = null;
    debugStationPlay = null;
    debugTrackGenreIndexPath = null;
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugRadioFallbackRoot = null;
    debugDiscoveryDiscardPath = null;
    debugCuratorService = null;
    debugCuratorRegister = null;
    CuratorNotifier.debugLyricFetcher = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('Prueba 1: anti-duplicados bloquea lo que ya esta en la biblioteca '
      '(O(1), sin importar orden, BPM, ano ni official audio)', () async {
    final String have = '$root${_sep}Baladas${_sep}Emmanuel (102) - La Chica De Humo.mp3';
    File(have)
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    final DiscoveryDedupController d = DiscoveryDedupController();
    await d.ensureLibrary(() => listLibraryAudioAsync(<String>[root]));
    expect(d.libraryReady, isTrue);
    expect(d.librarySize, 1);
    expect(
      d.blocksCandidate(filename: 'Emmanuel - La Chica de Humo (Official Audio)'),
      isTrue,
    );
    expect(
      d.blocksCandidate(filename: 'La Chica De Humo - Emmanuel (102 BPM)'),
      isTrue,
    );
    expect(
      d.blocksCandidate(artist: 'EMMANUEL', title: 'La Chica de Humo (1990)'),
      isTrue,
    );
    expect(
      d.blocksCandidate(filename: 'Emmanuel - Toda La Vida (Official Video)'),
      isFalse,
    );
    expect(
      normalizeTrackFingerprint(filename: 'Canción Única [Video Oficial].m4a.mp3'),
      normalizeTrackFingerprint(filename: 'cancion unica'),
    );
    // El buscador salta el duplicado antes de bajarlo.
    int downloads = 0;
    final SmartDiscoveryService svc = SmartDiscoveryService(
      inboxDir: inbox,
      search: (String q) async => const <DiscoveryCandidate>[
        DiscoveryCandidate(
          id: 'dup',
          title: 'La Chica De Humo - Emmanuel (102 BPM)',
        ),
        DiscoveryCandidate(id: 'new', title: 'Emmanuel - Toda La Vida'),
      ],
      download: (DiscoveryCandidate c, String path) async {
        downloads++;
        File(path)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[7]);
      },
    );
    final List<CuratorEntry> got = await svc.discover(
      genre: 'Baladas',
      count: 2,
      knownIds: const <String>{},
      skipTitle: (String t) => d.blocksCandidate(filename: t),
    );
    expect(got.map((CuratorEntry e) => e.id), <String>['new']);
    expect(downloads, 1);
  });

  test('Prueba 2: Tropical con 0 canciones locales enciende la Radio '
      'Descubrimiento de Tropical y suena lo nuevo', () async {
    final String radio = '$inbox${_sep}Grupo Niche - Cali Pachanguero.mp3';
    File(radio)
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[5]);
    debugVibeHubScan = (String r) async => const <VibeGenre>[];
    debugStationCollect = (List<String> subs) async => const <String>[];
    debugStationFeed = (String key, StationFeed f, int n) async =>
        <String>[radio];
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(vibeHubProvider).discoveryOn, isFalse);
    final int n = await c
        .read(vibeHubProvider.notifier)
        .playStation('tropical', <String>['Salsa']);
    expect(n, 0);
    final VibeHubState s = c.read(vibeHubProvider);
    expect(s.discoveryOn, isTrue);
    expect(s.activeStation, 'tropical');
    for (int i = 0; i < 50 && plans.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(plans, isNotEmpty);
    expect(plans.first.currentTrackPath, radio);
  });

  test('Prueba 3: Guardar en 1 clic (carpeta del genero fuera de ReGenial + '
      '.lrc en 2do plano) y Descartar en 1 clic (borra, avanza, bloquea)', () async {
    final String a = '$inbox${_sep}Grupo Niche - Cali Pachanguero.mp3';
    final String b = '$inbox${_sep}Joe Arroyo - La Rebelion.mp3';
    for (final String p in <String>[a, b]) {
      File(p)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);
    }
    CuratorInboxStore(inbox).save(
      CuratorInboxData(
        entries: <CuratorEntry>[
          CuratorEntry(
            id: 'a',
            title: 'Grupo Niche - Cali Pachanguero',
            genre: 'Salsa',
            file: a,
            status: CuratorStatus.pending,
            addedAt: '2026-11-18',
            stationId: 'tropical',
            subGenreId: 'Salsa',
          ),
          CuratorEntry(
            id: 'b',
            title: 'Joe Arroyo - La Rebelion',
            genre: 'Salsa',
            file: b,
            status: CuratorStatus.pending,
            addedAt: '2026-11-18',
            stationId: 'tropical',
            subGenreId: 'Salsa',
          ),
        ],
        lastRun: const <String, String>{},
      ),
    );
    debugCuratorService = SmartDiscoveryService(
      inboxDir: inbox,
      search: (String q) async => const <DiscoveryCandidate>[],
      download: (DiscoveryCandidate c, String p) async {},
    );
    debugCuratorRegister = (String path, String genre) async {};
    final List<String> lyricJobs = <String>[];
    CuratorNotifier.debugLyricFetcher = (String audio) async {
      lyricJobs.add(audio);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await File(audio.replaceAll(RegExp(r'\.mp3$'), '.lrc'))
          .writeAsString('[00:01.00] Cali pachanguero');
    };
    final Map<String, String> regenialBefore = _snap(root);
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    final CuratorNotifier cur = c.read(curatorProvider.notifier);
    expect(cur.radioEntryFor(a)?.id, 'a');

    final String? saved = await cur.saveFromRadio('a');
    expect(saved, isNotNull);
    // Nunca en ReGenial (biblioteca protegida): Musica/Descargas/<Estacion>/<Sub>.
    expect(isLibraryPath(saved!), isFalse);
    expect(
      saved.startsWith('$music${_sep}Descargas$_sep${stationCanonicalRel('tropical', 'Salsa').replaceAll('/', _sep)}'),
      isTrue,
    );
    expect(File(saved).readAsBytesSync(), <int>[1, 2, 3]);
    expect(_snap(root), regenialBefore);
    // La letra va en 2do plano: se lanzo y termina sola junto al audio.
    for (int i = 0; i < 50; i++) {
      if (File(saved.replaceAll(RegExp(r'\.mp3$'), '.lrc')).existsSync()) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(File(saved.replaceAll(RegExp(r'\.mp3$'), '.lrc')).existsSync(), isTrue);
    expect(lyricJobs, <String>[saved]);
    expect(cur.radioEntryFor(a), isNull);
    final DiscoveryDedupController d = c.read(discoveryDedupProvider);
    expect(d.blocksCandidate(filename: 'Cali Pachanguero - Grupo Niche (Official Video)'), isTrue);

    // Descartar: siguiente por el camino normal (fake), temporal borrado,
    // huella bloqueada y guardada en disco.
    final List<String> queue = <String>[b, '$root${_sep}Salsa${_sep}otra.mp3'];
    int index = 0;
    final bool gone = await cur.discardFromRadio(
      'b',
      skip: () async {
        index++;
      },
    );
    expect(gone, isTrue);
    expect(index, 1);
    expect(queue[index], isNot(b));
    expect(File(b).existsSync(), isFalse);
    expect(d.blocksCandidate(filename: 'La Rebelion - Joe Arroyo (125 BPM)'), isTrue);
    final Object? doc = jsonDecode(File(debugDiscoveryDiscardPath!).readAsStringSync());
    expect((doc as Map)['discarded'], contains(normalizeTrackFingerprint(filename: 'Joe Arroyo - La Rebelion')));
    final DiscoveryDedupController again = DiscoveryDedupController(
      discardPath: debugDiscoveryDiscardPath,
    );
    await again.loadDiscards();
    expect(again.blocksCandidate(title: 'Joe Arroyo - La Rebelion'), isTrue);
    // Escribir en la biblioteca protegida se niega.
    await expectLater(
      radioSaveTrack(
        tempPath: saved,
        targetDir: '$root${_sep}Tropical',
        stem: 'x',
      ),
      throwsStateError,
    );
  });

  test('ventana acotada: misma hidratacion con 100 o 5000 pistas y rotulo '
      'limpio de la siguiente', () {
    int calls(int n) {
      final List<String> q = <String>[
        for (int i = 0; i < n; i++) '/m/Salsa/t$i.mp3',
      ];
      int c = 0;
      backfillWindow(q, 2, (String p) {
        c++;
        return 0;
      });
      return c;
    }

    expect(calls(100), kAutomixHydrateWindow);
    expect(calls(5000), kAutomixHydrateWindow);
    expect(calls(20), lessThanOrEqualTo(kAutomixHydrateWindow));
    final List<String> big = <String>[
      for (int i = 0; i < 5000; i++) '/m/Salsa/t$i.mp3',
    ];
    int seen = 0;
    final List<String>? out = reorderQueueWindow(big, 2, (
      List<String> tail,
      String? from,
    ) {
      seen = tail.length;
      return tail.reversed.toList();
    });
    expect(seen, kAutomixHydrateWindow);
    expect(out, hasLength(5000));
    expect(out!.sublist(2 + kAutomixHydrateWindow), big.sublist(2 + kAutomixHydrateWindow));
    expect(out.toSet().length, 5000);
    expect(
      cleanNextTrackLabel('C:/M/Emmanuel - La Chica De Humo (1990) (115 BPM).mp3'),
      'Emmanuel - La Chica De Humo',
    );
    expect(cleanNextTrackLabel('/m/Tema (2).m4a.mp3'), 'Tema');
    expect(cleanNextTrackLabel('/m/Hits Vol.2 - Mix.mp3'), 'Hits Vol.2 - Mix');
  });
}
