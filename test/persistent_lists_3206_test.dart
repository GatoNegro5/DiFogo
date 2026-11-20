import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/automix_genre_session.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/persistent_lists.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';

// 3.2.6: motor de listas persistentes completas (genre: y folder:).
// Todo en %TEMP%; nunca la biblioteca real ni Music/DjPlaylists real.

String get _sep => Platform.pathSeparator;

String _src(String rel) =>
    File(rel).readAsStringSync().replaceAll('\r\n', '\n');

String _body(String src, String from, String to) {
  final int a = src.indexOf(from);
  expect(a, greaterThanOrEqualTo(0), reason: from);
  final int b = src.indexOf(to, a + from.length);
  expect(b, greaterThan(a), reason: to);
  return src.substring(a, b);
}

List<String> _tracks(String dir, int n) => <String>[
  for (int i = 0; i < n; i++)
    '$dir${_sep}Tema ${i.toString().padLeft(2, '0')}.mp3',
];

PersistentBuildOrder _seeded(int seed) =>
    (List<String> xs) => List<String>.from(xs)..shuffle(Random(seed));

/// Suena la actual hasta el final [n] veces; devuelve lo que sono.
List<String> _playThrough(PersistentLists lists, String key, int n) {
  final List<String> sounded = <String>[];
  for (int i = 0; i < n; i++) {
    final String? cur = lists.get(key)?.currentPath;
    if (cur == null) break;
    sounded.add(cur);
    expect(lists.markPlayed(key, cur), isTrue);
  }
  return sounded;
}

void main() {
  late Directory tmp;
  late String listsPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_lists_3206_');
    listsPath = '${tmp.path}${_sep}DjPlaylists$_sep$kPersistentListsName';
    PersistentListsStore.debugForgetAll();
    int clock = 1000;
    debugPersistentNow = () => clock += 10;
  });

  tearDown(() {
    debugPersistentNow = null;
    debugLibraryRoots = null;
    PersistentListsStore.debugForgetAll();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  PersistentLists open(String space) =>
      PersistentLists(PersistentListsStore.at(listsPath), space);

  test('claves estables genre: y folder: en Win/Mac/Android', () {
    expect(persistentGenreKey(' Tropical '), 'genre:tropical');
    expect(
      persistentFolderKey(r'C:\Users\ASUS\Music\Salsa\'),
      'folder:c:/users/asus/music/salsa',
    );
    expect(
      persistentFolderKey('/Users/gabriel/Music//Salsa/'),
      'folder:/users/gabriel/music/salsa',
    );
    expect(
      persistentFolderKey('/storage/emulated/0/Music/Salsa'),
      'folder:/storage/emulated/0/music/salsa',
    );
    expect(
      persistentListsPathNear('${tmp.path}${_sep}automix.json'),
      '${tmp.path}$_sep$kPersistentListsName',
    );
  });

  test('a) genre: y folder: completas retoman donde quedaron sin repetir '
      'hasta el 100 %', () async {
    final List<String> salsa = _tracks('${tmp.path}${_sep}Salsa', 60);
    final List<String> folder = _tracks('${tmp.path}${_sep}Mix', 9);
    final String g = persistentGenreKey('tropical');
    final String f = persistentFolderKey('${tmp.path}${_sep}Mix');
    PersistentLists lists = open(kPersistentSpaceAutomix);
    final PersistentPlan p1 = lists.planOrResume(g, salsa, _seeded(1));
    expect(p1.fresh, isTrue);
    // Lista COMPLETA: 60 pistas, no la ventana de 48.
    expect(p1.queue.length, 60);
    expect(lists.get(g)!.order.length, 60);
    final PersistentPlan f1 = lists.planOrResume(f, folder, _seeded(2));
    expect(f1.queue.length, 9);
    final List<String> sounded = _playThrough(lists, g, 50);
    final List<String> fs = _playThrough(lists, f, 4);
    expect(
      lists.noteState(g, current: lists.get(g)!.currentPath, positionMs: 45000),
      isTrue,
    );
    await lists.flush();

    // Otro arranque: se lee del disco.
    PersistentListsStore.debugForgetAll();
    lists = open(kPersistentSpaceAutomix);
    await lists.store.load();
    final PersistentPlan p2 = lists.planOrResume(g, salsa, _seeded(9));
    expect(p2.resumed, isTrue);
    expect(p2.current, p1.queue[50]);
    expect(p2.positionMs, 45000);
    expect(p2.queue.length, 10);
    expect(p2.queue.any(sounded.contains), isFalse);
    final PersistentPlan f2 = lists.planOrResume(f, folder, _seeded(9));
    expect(f2.current, f1.queue[4]);
    expect(f2.queue.any(fs.contains), isFalse);
    sounded.addAll(_playThrough(lists, g, 10));
    expect(sounded.length, 60);
    expect(sounded.toSet().length, 60);
    expect(lists.get(g)!.currentPath, isNull);
    // Ya sono el 100 %: lista nueva completa y lo sonado en cero.
    final PersistentPlan p3 = lists.planOrResume(g, salsa, _seeded(3));
    expect(p3.fresh, isTrue);
    expect(p3.queue.length, 60);
    expect(lists.get(g)!.played, isEmpty);
  });

  test('b) playAt a mitad de cola: no repite y termina con las pendientes '
      'anteriores', () {
    final List<String> all = _tracks('${tmp.path}${_sep}Rock', 10);
    final String k = persistentFolderKey('${tmp.path}${_sep}Rock');
    final PersistentLists lists = open(kPersistentSpaceLiveDj);
    final PersistentPlan p = lists.planOrResume(k, all, (List<String> x) => x);
    final List<String> q = p.queue;
    // Suena la 0 y la 1; toca Play en la fila 5.
    final List<String> sounded = _playThrough(lists, k, 1);
    expect(lists.playAt(k, q[5]), isTrue);
    sounded.addAll(_playThrough(lists, k, 20));
    expect(sounded, <String>[
      q[0],
      q[5],
      q[6],
      q[7],
      q[8],
      q[9],
      q[2],
      q[3],
      q[4],
    ]);
    // q[1] era la actual al tocar la fila: cuenta como sonada.
    expect(lists.get(k)!.played.contains(q[1]), isTrue);
    expect(sounded.toSet().length, sounded.length);
    expect(lists.get(k)!.exhausted, isTrue);
    // Pura: una pista ajena no toca la lista.
    expect(lists.playAt(k, '/otra/cancion.mp3'), isFalse);
  });

  test(
    'c) clearQueue conserva la lista y el progreso (puro + Live DJ)',
    () async {
      final List<String> all = _tracks('${tmp.path}${_sep}Pop', 8);
      final String k = persistentGenreKey('ochenteras');
      final PersistentLists lists = open(kPersistentSpaceAutomix);
      final PersistentPlan p = lists.planOrResume(
        k,
        all,
        (List<String> x) => x,
      );
      _playThrough(lists, k, 2);
      final List<String> before = lists.get(k)!.pending;
      // Cola vaciada: lo que suena sigue y lo que viene llega vacio.
      lists.noteState(k, current: p.queue[2], positionMs: 9000);
      expect(lists.get(k)!.pending, before);
      expect(lists.get(k)!.played, <String>[p.queue[0], p.queue[1]]);
      // Musica ajena despues del vaciado no la toca.
      expect(lists.noteState(k, current: '/otra.mp3'), isFalse);

      // Live DJ: Hub con la estacion; fin sin siguiente tras vaciar la cola.
      debugStationSessionsPath =
          '${tmp.path}$_sep${'sessions'}${_sep}difogo_genre_sessions.json';
      debugStationRng = Random(7);
      final List<String> lib = _tracks('${tmp.path}${_sep}Cumbias', 6);
      debugStationCollect = (List<String> subs) async => lib;
      final List<StationPlan> plays = <StationPlan>[];
      debugStationPlay = (StationPlan s) async => plays.add(s);
      debugStationLive = () => const StationLive(null, 0, <String>[]);
      addTearDown(() {
        debugStationSessionsPath = null;
        debugStationRng = null;
        debugStationCollect = null;
        debugStationPlay = null;
        debugStationLive = null;
      });
      ProviderContainer c = ProviderContainer();
      VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      expect(await hub.playStation('tropical', <String>['Cumbias']), 6);
      expect(hub.activePersistentListKey, 'genre:tropical');
      final StationPlan first = plays.last;
      final String s1 = first.currentTrackPath!;
      final String s2 = first.queue.first;
      final List<String> rest = first.queue.sublist(1);
      await hub.noteTrackChange(s1, s2, rest);
      // clearQueue: la cola llega vacia y la pista termina sin siguiente.
      await hub.notePlaybackTick(s2, 30000, const <String>[], force: true);
      await hub.noteTrackChange(s2, null, const <String>[]);
      await hub.stationsSettled;
      expect(hub.stationSession('tropical')!.remainingQueuePaths, rest);
      c.dispose();
      final String near = persistentListsPathNear(debugStationSessionsPath!);
      expect(File(near).existsSync(), isTrue);

      c = ProviderContainer();
      addTearDown(c.dispose);
      hub = c.read(vibeHubProvider.notifier);
      await hub.playStation('tropical', <String>['Cumbias']);
      final StationPlan back = plays.last;
      expect(<String>[back.currentTrackPath!, ...back.queue], rest);
      expect(back.played, <String>[s1, s2]);
      await hub.stationsSettled;

      // Fuente: Live DJ ya no borra la pista actual al vaciar y Automix no
      // toca la lista; sin siguiente se detiene al final de la pista.
      final String dj = _src('lib/providers/livedj_provider.dart');
      final String clear = _body(
        dj,
        '  void clearQueue() {',
        'Future<bool> loadStation(',
      );
      expect(clear.contains('clearCurrentTrackPath: true'), isFalse);
      expect(clear.contains('_queueRestart = true'), isFalse);
      expect(clear.contains('reset('), isFalse);
      final String am = _src('lib/providers/automix_provider.dart');
      final String drop = _body(am, '  void dropPersistedQueue() {', '  }\n');
      expect(drop.contains('_isCrossfading || _drift.preRollActive'), isTrue);
      final String drop2 = _body(
        am,
        '  void dropPersistedQueue() {',
        'void releaseQueueHold()',
      );
      expect(drop2.contains('clearNextTrackPath: !keepNext'), isTrue);
      final String aclear = _body(
        am,
        '  void clearQueue() {',
        '  void restoreQueue(',
      );
      expect(aclear.contains('reset('), isFalse);
    },
  );

  test('d) reset borra solo esa clave y genera orden nuevo', () async {
    final List<String> a = _tracks('${tmp.path}${_sep}A', 12);
    final List<String> b = _tracks('${tmp.path}${_sep}B', 5);
    final String ka = persistentGenreKey('a');
    final String kb = persistentFolderKey('${tmp.path}${_sep}B');
    final PersistentLists lists = open(kPersistentSpaceLiveDj);
    final List<String> oa = lists.planOrResume(ka, a, _seeded(1)).queue;
    lists.planOrResume(kb, b, _seeded(2));
    _playThrough(lists, ka, 3);
    _playThrough(lists, kb, 2);
    final PersistentList keepB = lists.get(kb)!;
    lists.activeKey = ka;
    expect(lists.reset(ka), isTrue);
    expect(lists.has(ka), isFalse);
    expect(lists.get(kb)!.order, keepB.order);
    expect(lists.get(kb)!.played, keepB.played);
    await lists.flush();
    final PersistentPlan again = lists.planOrResume(ka, a, _seeded(5));
    expect(again.fresh, isTrue);
    expect(again.list.played, isEmpty);
    expect(again.queue.length, 12);
    expect(again.queue, isNot(oa));
  });

  test('e) pistas nuevas y borradas se mezclan sin reiniciar el progreso', () {
    final List<String> all = _tracks('${tmp.path}${_sep}Merengue', 6);
    final String k = persistentGenreKey('tropical');
    final PersistentLists lists = open(kPersistentSpaceAutomix);
    final List<String> q = lists
        .planOrResume(k, all, (List<String> x) => x)
        .queue;
    _playThrough(lists, k, 2);
    lists.noteState(k, current: q[2], positionMs: 7000);
    final List<String> news = _tracks('${tmp.path}${_sep}Nuevas', 2);
    final List<String> now = <String>[
      for (final String p in all)
        if (p != q[4]) p,
      ...news,
    ];
    final PersistentPlan p = lists.planOrResume(
      k,
      now,
      (List<String> x) => x.reversed.toList(),
    );
    expect(p.resumed, isTrue);
    expect(p.fresh, isFalse);
    expect(p.current, q[2]);
    expect(p.positionMs, 7000);
    expect(p.list.played, <String>[q[0], q[1]]);
    expect(p.queue, <String>[q[2], q[3], q[5], news[1], news[0]]);
    expect(p.queue.contains(q[4]), isFalse);
  });

  test('guardia: cero escrituras en la biblioteca; DjPlaylists si', () async {
    final String root = '${tmp.path}${_sep}Music';
    debugLibraryRoots = <String>[root];
    final int blocked0 = libraryGuardBlocked;
    final String bad = '$root${_sep}Salsa$_sep$kPersistentListsName';
    final PersistentLists inLib = PersistentLists(
      PersistentListsStore.at(bad),
      kPersistentSpaceAutomix,
    );
    inLib.planOrResume('genre:x', _tracks('$root${_sep}Salsa', 3), (x) => x);
    await inLib.flush();
    expect(File(bad).existsSync(), isFalse);
    expect(Directory('$root${_sep}Salsa').existsSync(), isFalse);
    expect(libraryGuardBlocked, greaterThan(blocked0));
    final String ok = '$root${_sep}DjPlaylists$_sep$kPersistentListsName';
    final PersistentLists app = PersistentLists(
      PersistentListsStore.at(ok),
      kPersistentSpaceAutomix,
    );
    app.planOrResume('genre:x', _tracks('$root${_sep}Salsa', 3), (x) => x);
    await app.flush();
    expect(File(ok).existsSync(), isTrue);
  });

  test('LRU de 40 listas (la activa nunca sale) y debounce sin timers', () {
    int clock = 10000;
    debugPersistentNow = () => clock += 10;
    final PersistentLists lists = open(kPersistentSpaceAutomix);
    lists.planOrResume('genre:0', _tracks('${tmp.path}${_sep}g0', 2), (x) => x);
    lists.activeKey = 'genre:0';
    for (int i = 1; i <= 45; i++) {
      lists.planOrResume(
        'genre:$i',
        _tracks('${tmp.path}${_sep}g$i', 2),
        (x) => x,
      );
    }
    expect(lists.lists.length, kPersistentListCap);
    expect(lists.has('genre:0'), isTrue);
    expect(lists.has('genre:1'), isFalse);
    expect(lists.has('genre:45'), isTrue);
    lists.saveSoon();
    expect(lists.store.isDirty, isFalse);
    lists.saveSoon();
    expect(lists.store.isDirty, isTrue);
  });

  test('migracion suave: automix_genres.json y sin pisar claves', () {
    final List<String> all = _tracks('${tmp.path}${_sep}Pop', 70);
    final Map<String, AutomixGenreSessionState> old =
        <String, AutomixGenreSessionState>{
          'ochenteras|pop': AutomixGenreSessionState(
            window: all.sublist(10, 58),
            positionMs: 45000,
            played: all.sublist(0, 10),
            savedAtMs: 5,
          ),
          'ochenteras|': AutomixGenreSessionState(
            window: all.sublist(0, 48),
            positionMs: 1,
            played: const <String>[],
            savedAtMs: 1,
          ),
        };
    final Map<String, PersistentList> m = persistentListsFromAutomixSessions(
      old,
    );
    expect(m.keys, <String>['genre:ochenteras']);
    final PersistentLists lists = open(kPersistentSpaceAutomix);
    lists.importLegacyOnce(() => m);
    final PersistentPlan p = lists.planOrResume(
      'genre:ochenteras',
      all,
      (List<String> x) => x,
    );
    expect(p.resumed, isTrue);
    expect(p.current, all[10]);
    expect(p.positionMs, 45000);
    // Ventana de 48 + las 12 de fuera como nuevas: el 100 % pendiente.
    expect(p.queue.length, 60);
    expect(p.queue.any(all.sublist(0, 10).contains), isFalse);
    // Una sola vez: no vuelve a importar ni pisa la clave.
    _playThrough(lists, 'genre:ochenteras', 3);
    lists.importLegacyOnce(() => m);
    expect(lists.get('genre:ochenteras')!.played.length, 13);
  });

  test('cableado en providers (fuente)', () {
    final String am = _src('lib/providers/automix_provider.dart');
    final String load = _body(
      am,
      'Future<void> _loadPersistentQueue(',
      'Future<Map<String, AutomixGenreSessionState>> _genreSessionMap()',
    );
    expect(
      load.indexOf('_syncActiveList();'),
      lessThan(load.indexOf('.clearQueue()')),
    );
    expect(load.contains('lists.planOrResume('), isTrue);
    expect(load.contains('kRollingWindowSize'), isFalse);
    expect(am.contains('Future<void> loadFolderList('), isTrue);
    expect(am.contains('String? get activePersistentListKey'), isTrue);
    expect(am.contains('Future<bool> resetActivePersistentList()'), isTrue);
    final String ctx = _body(
      am,
      'Future<void> loadContextAndPlay(',
      'if (_isCrossfading && !_deckHot) _releaseMix();',
    );
    expect(ctx.contains('_persistentPlayAt(nextTrack);'), isTrue);
    final String dj = _src('lib/providers/livedj_provider.dart');
    expect(dj.contains('Future<int> playFolderList('), isTrue);
    expect(dj.contains('String? get activePersistentListKey'), isTrue);
    expect(dj.contains('Future<bool> resetActivePersistentList()'), isTrue);
    final String hub = _src('lib/providers/vibe_hub_provider.dart');
    expect(hub.contains('lists.upsertStation(k, s)'), isTrue);
    expect(hub.contains('String? get activePersistentListKey'), isTrue);
    expect(hub.contains('Future<bool> resetActivePersistentList()'), isTrue);
    final String core = _src('lib/core/persistent_lists.dart');
    expect(
      core.contains("libraryWriteBlocked(p, what: 'persistent_lists')"),
      isTrue,
    );
    expect(
      core.contains('Isolate.run(() => SessionStore.writeJsonSync(p, data))'),
      isTrue,
    );
  });
}
