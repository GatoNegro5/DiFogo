import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/brand_paths.dart';
import 'package:difogo/core/discovery_dedup_controller.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/persistent_lists.dart';
import 'package:difogo/core/radio_one_click.dart';
import 'package:difogo/providers/automix_provider.dart';
import 'package:difogo/providers/curator_provider.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/services/smart_discovery_service.dart';
import 'package:difogo/ui/curator_inbox_dialog.dart';
import 'package:difogo/ui/vibe_hub_view.dart';

// 3.2.10: carpeta /DESCUBRE de la Radio, parche ReGenial en Aceptar,
// anti-duplicados con DESCUBRE, inyeccion en listas persistentes sin
// reiniciar progreso, migracion suave de la bandeja vieja y tarjeta fija
// del Hub. Todo en %TEMP% (Musica, ReGenial, DESCUBRE y listas falsas):
// nunca la biblioteca real, sin red ni audio.

final String _sep = Platform.pathSeparator;

class _FakeQueue extends AutomixQueueNotifier {
  @override
  List<File> build() => <File>[];

  @override
  void addTrack(File file) => state = <File>[...state, file];
}

final List<String> _playedFolders = <String>[];

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();

  @override
  Future<int> playFolderList(String folderPath, List<File> files) async {
    _playedFolders.add('$folderPath|${files.length}');
    return files.length;
  }
}

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

String _flat(String path) =>
    File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), '');

CuratorEntry _entry(String id, String file) => CuratorEntry(
  id: id,
  title: id,
  genre: 'Salsa',
  file: file,
  status: CuratorStatus.pending,
  addedAt: '2026-11-20',
  stationId: 'tropical',
  subGenreId: 'Salsa',
);

const Duration _four = Duration(minutes: 4);

void main() {
  late Directory tmp;
  late String music;
  late String root;
  late String inbox;
  late String lists;
  final List<String> lyricJobs = <String>[];
  List<DiscoveryCandidate> found = const <DiscoveryCandidate>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_descubre_3210_');
    music = '${tmp.path}${_sep}Music';
    root = '$music${_sep}ReGenial';
    inbox = '$music$_sep$kDescubreName';
    lists = '${tmp.path}${_sep}DjPlaylists${_sep}persistent_lists.json';
    File('$root${_sep}Salsa${_sep}Ya Esta.mp3')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
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
    debugDescubreMusicRoot = music;
    debugCuratorInboxDir = inbox;
    debugCuratorListsPaths = <String>[lists];
    debugDisableCuratorWorker = true;
    debugCuratorRegister = (String p, String g) async {};
    lyricJobs.clear();
    _playedFolders.clear();
    CuratorNotifier.debugLyricFetcher = (String a) async => lyricJobs.add(a);
    found = const <DiscoveryCandidate>[];
    debugCuratorService = SmartDiscoveryService(
      search: (String q) async => found,
      download: (DiscoveryCandidate c, String mp3) async =>
          File(mp3).writeAsStringSync('mp3:${c.id}'),
      inboxDir: inbox,
      now: () => DateTime(2026, 11, 20, 11),
    );
    PersistentListsStore.debugForgetAll();
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
    debugRadioFallbackRoot = null;
    debugDiscoveryDiscardPath = null;
    debugDescubreMusicRoot = null;
    debugCuratorInboxDir = null;
    debugCuratorListsPaths = null;
    debugCuratorService = null;
    debugCuratorRegister = null;
    CuratorNotifier.debugLyricFetcher = null;
    PersistentListsStore.debugForgetAll();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProviderContainer make() => ProviderContainer(
    overrides: [automixQueueProvider.overrideWith(_FakeQueue.new)],
  );

  test(
    '3234 Aceptar coloca en la carpeta real de ReGenial (sin pisar nada), '
    'sale de DESCUBRE y lanza la letra; sin ReGenial y con respaldo '
    'protegido no mueve nada',
    () async {
      found = const <DiscoveryCandidate>[
        DiscoveryCandidate(id: 'v1', title: 'Tema Uno', duration: _four),
        DiscoveryCandidate(id: 'v2', title: 'Tema Dos', duration: _four),
      ];
      final ProviderContainer c = make();
      addTearDown(c.dispose);
      final CuratorNotifier cur = c.read(curatorProvider.notifier);
      expect(cur.inboxDir, inbox);
      expect(await cur.discover(genre: 'Salsa', count: 2), 2);
      final List<CuratorEntry> pend = c.read(curatorProvider).pending;
      expect(File(pend.first.file).parent.path, inbox);
      expect(isLibraryPath(pend.first.file), isFalse);
      expect(isLibraryPath('$root${_sep}Salsa'), isTrue);
      final Map<String, String> before = _snap(root);

      final String? dst = await cur.accept('v1');
      expect(dst, '$root${_sep}Salsa${_sep}Tema Uno.mp3');
      expect(isLibraryPath(dst!), isTrue);
      expect(File(dst).readAsStringSync(), 'mp3:v1');
      expect(File(pend.first.file).existsSync(), isFalse);
      // Lo que ya estaba en ReGenial sigue igual (solo se agrega).
      final Map<String, String> after = _snap(root);
      for (final MapEntry<String, String> e in before.entries) {
        expect(after[e.key], e.value, reason: e.key);
      }
      expect(after.length, before.length + 1);
      final Map<String, String> placed = _snap(root);
      await cur.lastAcceptLyrics;
      expect(lyricJobs, <String>[dst]);
      expect(c.read(automixQueueProvider).map((File f) => f.path), <String>[
        dst,
      ]);

      // Sin ReGenial y respaldo dentro de la biblioteca: libraryWriteBlocked
      // lo frena.
      debugVibeRootOverride = '$music${_sep}NoHay';
      debugRadioFallbackRoot = '$root${_sep}Otra';
      final int blocked = libraryGuardBlocked;
      expect(await cur.accept('v2'), isNull);
      expect(libraryGuardBlocked, blocked + 1);
      expect(File(pend[1].file).existsSync(), isTrue);
      expect(_snap(root), placed);
      expect(Directory('$root${_sep}Otra').existsSync(), isFalse);
    },
  );

  test('3210 DESCUBRE entra al anti-duplicados (sin bloquear lo recien '
      'bajado) junto con biblioteca y pendientes', () async {
    File('$inbox${_sep}Marc Anthony - Vivir Mi Vida.mp3')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    found = const <DiscoveryCandidate>[
      DiscoveryCandidate(
        id: 'dup',
        title: 'Marc Anthony - Vivir Mi Vida (Official Video)',
        duration: _four,
      ),
      DiscoveryCandidate(id: 'v2', title: 'Tema Dos', duration: _four),
    ];
    final ProviderContainer c = make();
    addTearDown(c.dispose);
    final CuratorNotifier cur = c.read(curatorProvider.notifier);
    expect(await cur.discover(genre: 'Salsa', count: 2), 1);
    final CuratorEntry got = c.read(curatorProvider).pending.single;
    expect(got.id, 'v2');
    final DiscoveryDedupController d = c.read(discoveryDedupProvider);
    expect(d.blocksCandidate(filename: 'Vivir Mi Vida - Marc Anthony'), isTrue);
    // Lo recien bajado sigue sonando en la Radio (no se bloquea a si mismo).
    expect(d.blocksCandidate(filename: got.file), isFalse);
    // Otro video con el titulo de un pendiente tampoco se baja.
    found = const <DiscoveryCandidate>[
      DiscoveryCandidate(
        id: 'v2b',
        title: 'Tema Dos (Official Audio)',
        duration: _four,
      ),
    ];
    expect(await cur.discover(genre: 'Salsa'), 0);
    // Biblioteca: tampoco.
    found = const <DiscoveryCandidate>[
      DiscoveryCandidate(id: 'have', title: 'Ya Esta', duration: _four),
    ];
    expect(await cur.discover(genre: 'Salsa'), 0);
    expect(
      c.read(curatorProvider).pending.map((CuratorEntry e) => e.id),
      <String>['v2'],
    );
  });

  test('3210 Guardar y Aceptar se inyectan en PersistentLists sin reiniciar '
      'progreso (genre:<estacion> y folder: que la contiene)', () async {
    final String a = '$root${_sep}Salsa${_sep}a.mp3';
    final String b = '$root${_sep}Salsa${_sep}b.mp3';
    final String x = '$root${_sep}Pop${_sep}x.mp3';
    final String y = '$music${_sep}Descargas${_sep}y.mp3';
    final String z = '$inbox${_sep}z.mp3';
    final PersistentListsStore store = PersistentListsStore.at(lists);
    store.put(
      kPersistentSpaceLiveDj,
      persistentGenreKey('tropical'),
      PersistentList(
        order: <String>[a, b, x],
        played: <String>[a],
        currentPath: b,
        positionMs: 4000,
        updatedAtMs: 7,
      ),
    );
    store.put(
      kPersistentSpaceAutomix,
      persistentGenreKey('tropical'),
      PersistentList(
        order: <String>[a, b],
        played: <String>[a, b],
        currentPath: b,
        positionMs: 1000,
      ),
    );
    store.put(
      kPersistentSpaceLiveDj,
      persistentGenreKey('momento'),
      PersistentList(order: <String>[x]),
    );
    store.put(
      kPersistentSpaceLiveDj,
      persistentFolderKey('$music${_sep}Descargas'),
      PersistentList(order: <String>[y]),
    );
    store.put(
      kPersistentSpaceLiveDj,
      persistentFolderKey(inbox),
      PersistentList(order: <String>[z]),
    );
    await store.flush();

    found = const <DiscoveryCandidate>[
      DiscoveryCandidate(
        id: 's1',
        title: 'Grupo Niche - Cali Pachanguero',
        duration: _four,
      ),
      DiscoveryCandidate(
        id: 's2',
        title: 'Joe Arroyo - La Rebelion',
        duration: _four,
      ),
    ];
    final ProviderContainer c = make();
    addTearDown(c.dispose);
    final CuratorNotifier cur = c.read(curatorProvider.notifier);
    expect(
      await cur.discover(
        count: 2,
        genre: stationCanonicalRel('tropical', 'Salsa'),
        stationId: 'tropical',
        subGenreId: 'Salsa',
      ),
      2,
    );
    final String? saved = await cur.saveFromRadio('s1');
    final String? acc = await cur.accept('s2');
    expect(saved, isNotNull);
    expect(acc, isNotNull);
    // 3.2.34: a la carpeta real de ReGenial (Salsa).
    for (final String p in <String>[saved!, acc!]) {
      expect(p.startsWith('$root${_sep}Salsa$_sep'), isTrue, reason: p);
      expect(isLibraryPath(p), isTrue);
    }

    final PersistentList live = store.get(
      kPersistentSpaceLiveDj,
      persistentGenreKey('tropical'),
    )!;
    expect(live.order, <String>[a, b, x, saved, acc]);
    expect(live.played, <String>[a]);
    expect(live.currentPath, b);
    expect(live.positionMs, 4000);
    final PersistentList auto = store.get(
      kPersistentSpaceAutomix,
      persistentGenreKey('tropical'),
    )!;
    expect(auto.order, <String>[a, b, saved, acc]);
    expect(auto.played, <String>[a, b]);
    expect(auto.currentPath, b);
    expect(auto.positionMs, 1000);
    expect(
      store.get(kPersistentSpaceLiveDj, persistentGenreKey('momento'))!.order,
      <String>[x],
    );
    expect(
      store
          .get(
            kPersistentSpaceLiveDj,
            persistentFolderKey('$music${_sep}Descargas'),
          )!
          .order,
      <String>[y],
    );
    expect(
      store.get(kPersistentSpaceLiveDj, persistentFolderKey(inbox))!.order,
      <String>[z],
    );

    // Quedo en disco y no se duplica.
    await store.settled;
    PersistentListsStore.debugForgetAll();
    final PersistentListsStore again = PersistentListsStore.at(lists);
    await again.load();
    expect(
      again.get(kPersistentSpaceLiveDj, persistentGenreKey('tropical'))!.order,
      <String>[a, b, x, saved, acc],
    );
    expect(persistentInjectTrack(again, saved, stationId: 'tropical'), isEmpty);
  });

  test('3210 migracion suave Downloads/DiFogo_Inbox -> Musica/DESCUBRE: '
      'mueve, salta conflictos, no borra originales y no duplica', () {
    final String old = '${tmp.path}${_sep}Downloads$_sep$kInboxName';
    final String a = '$old${_sep}Tema A.mp3';
    final String b = '$old${_sep}Tema B.mp3';
    File(a)
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2]);
    File(b).writeAsBytesSync(<int>[3]);
    File('$inbox${_sep}Tema B.mp3')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[9, 9]);
    CuratorInboxStore(old).save(
      CuratorInboxData(
        entries: <CuratorEntry>[_entry('a', a), _entry('b', b)],
        lastRun: const <String, String>{'Salsa': '2026-11-19'},
      ),
    );

    final InboxMigration m = migrateLegacyInbox(old, inbox);
    expect(m.moved, <String, String>{a: '$inbox${_sep}Tema A.mp3'});
    expect(m.skipped, 1);
    expect(m.failed, 0);
    expect(File(a).existsSync(), isFalse);
    expect(File('$inbox${_sep}Tema A.mp3').readAsBytesSync(), <int>[1, 2]);
    expect(File(b).readAsBytesSync(), <int>[3]);
    expect(File('$inbox${_sep}Tema B.mp3').readAsBytesSync(), <int>[9, 9]);
    expect(File('$old${_sep}curator_inbox.json').existsSync(), isTrue);
    final CuratorInboxData d = CuratorInboxStore(inbox).load();
    expect(d.entries.map((CuratorEntry e) => e.id), <String>['a', 'b']);
    expect(d.entries.first.file, '$inbox${_sep}Tema A.mp3');
    expect(d.entries.last.file, b);
    expect(d.lastRun, <String, String>{'Salsa': '2026-11-19'});

    final InboxMigration again = migrateLegacyInbox(old, inbox);
    expect(again.moved, isEmpty);
    expect(CuratorInboxStore(inbox).load().entries, hasLength(2));

    // Nunca dentro de la biblioteca protegida.
    final InboxMigration prot = migrateInboxFiles(old, '$root${_sep}X');
    expect(prot.moved, isEmpty);
    expect(Directory('$root${_sep}X').existsSync(), isFalse);
    expect(File(b).existsSync(), isTrue);

    // DESCUBRE: carpeta propia de la app fuera de ReGenial.
    expect(isLibraryPath('$inbox${_sep}x.mp3'), isFalse);
    expect(libraryWriteBlocked('$inbox${_sep}x.mp3'), isFalse);
    expect(isLibraryPath('$music$_sep$kInboxName${_sep}x.mp3'), isFalse);
    expect(descubreDir(), inbox);
    debugCuratorInboxDir = null;
    expect(discoveryInboxDir(), inbox);
    expect(radioSaveDir(libraryDir: inbox, fallbackDir: 'f'), inbox);
  });

  for (final double w in <double>[240, 360]) {
    testWidgets('3210 tarjeta fija /DESCUBRE en el Hub (ancho $w): contador, '
        'Play de la carpeta y bandeja; sin chip Nuevas', (
      WidgetTester t,
    ) async {
      final String f1 = '$inbox${_sep}Uno.mp3';
      final String f2 = '$inbox${_sep}Dos.mp3';
      for (final String p in <String>[f1, f2]) {
        File(p)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1]);
      }
      CuratorInboxStore(inbox).save(
        CuratorInboxData(
          entries: <CuratorEntry>[_entry('u', f1), _entry('d', f2)],
          lastRun: const <String, String>{},
        ),
      );
      debugVibeHubScan = (String r) async => const <VibeGenre>[
        VibeGenre('Salsa', 1),
      ];
      t.view.physicalSize = Size(w, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            liveDjProvider.overrideWith(_FakeLiveDj.new),
            automixQueueProvider.overrideWith(_FakeQueue.new),
          ],
          child: const MaterialApp(home: Scaffold(body: VibeHubView())),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('vibe-hub-descubre-card')), findsOneWidget);
      expect(find.text('/DESCUBRE'), findsOneWidget);
      expect(find.text('2 canciones por revisar'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('curator-inbox-button')),
        findsNothing,
      );
      expect(find.text('ESTACIONES & GÉNEROS'), findsOneWidget);
      final Finder st = find.byKey(const Key('vibe-hub-st-tropical'));
      expect(st, findsOneWidget);
      expect(
        t.getTopLeft(find.byKey(const Key('vibe-hub-descubre-card'))).dy,
        lessThan(t.getTopLeft(st).dy),
      );
      expect(t.takeException(), isNull);

      await t.tap(find.byKey(const Key('vibe-hub-descubre-play')));
      for (int i = 0; i < 40 && _playedFolders.isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
      expect(_playedFolders, <String>['$inbox|2']);

      await t.tap(find.byKey(const Key('vibe-hub-descubre-inbox')));
      await t.pumpAndSettle();
      expect(find.byType(CuratorInboxDialog), findsOneWidget);
      await t.tap(find.byKey(const ValueKey<String>('curator-later')));
      await t.pumpAndSettle();
      expect(find.byType(CuratorInboxDialog), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  test('3210 fuente: Aceptar pasa por radioSaveDir y libraryWriteBlocked '
      'antes de mover; descubre en _appFolders; sin chip en el Hub', () {
    final String cp = _flat('lib/providers/curator_provider.dart');
    final int s = cp.indexOf('Future<String?>accept(Stringid)async{');
    final int e = cp.indexOf('String_fallbackOf(');
    expect(s, greaterThan(0));
    expect(e, greaterThan(s));
    final String body = cp.substring(s, e);
    final int mv = body.indexOf('moveFile(');
    expect(body.indexOf('radioSaveDir('), inInclusiveRange(0, mv));
    expect(body.indexOf('libraryWriteBlocked('), inInclusiveRange(0, mv));
    expect(body.contains('_injectPersistent('), isTrue);
    expect(body.contains('radioStartLyrics('), isTrue);
    final String lg = _flat('lib/core/library_guard.dart');
    expect(lg.contains("'descubre',"), isTrue);
    expect(lg.contains("'difogo_inbox',"), isTrue);
    final String hv = _flat('lib/ui/vibe_hub_view.dart');
    expect(hv.contains('CuratorInboxButton('), isFalse);
    expect(
      hv.contains('DescubreStationCard(onPlayed:widget.onPlayed)'),
      isTrue,
    );
    expect(descubreCountLabel(1), '1 canción por revisar');
  });
}
