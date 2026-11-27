import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/folder_sets.dart';
import 'package:difogo/core/persistent_lists.dart';

// 3.2.29 Sets por carpeta: elegir carpeta sonando no corta; la cola pasa a
// las proximas 8 de la carpeta nueva (nada de la anterior); cada carpeta
// retoma donde quedo sin repetir y reinicia el ciclo al agotarse.
// Todo en %TEMP%; nunca la biblioteca real.

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

List<String> _folder(String dir, String name, int n) => <String>[
  for (int i = 0; i < n; i++)
    '$dir$_sep$name$_sep$name ${i.toString().padLeft(3, '0')}.mp3',
];

PersistentBuildOrder _seeded(int seed) =>
    (List<String> xs) => List<String>.from(xs)..shuffle(Random(seed));

String _key(String dir, String name) => 'folder:$dir$_sep$name';

void main() {
  late Directory tmp;
  late String listsPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_sets_3229_');
    listsPath = '${tmp.path}${_sep}DjPlaylists$_sep$kPersistentListsName';
    PersistentListsStore.debugForgetAll();
    int clock = 1000;
    debugPersistentNow = () => clock += 10;
  });

  tearDown(() {
    debugPersistentNow = null;
    PersistentListsStore.debugForgetAll();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  PersistentLists open() =>
      PersistentLists(PersistentListsStore.at(listsPath), 'livedj');

  Future<TrackSet> take(
    PersistentLists lists,
    String key,
    List<String> all, {
    List<String> exclude = const <String>[],
    int seed = 7,
  }) => folderSetFor(
    lists,
    key,
    all,
    exclude: exclude,
    warm: false,
    buildOrder: _seeded(seed),
  );

  void playAll(PersistentLists lists, String key, List<String> set) {
    for (final String p in set) {
      expect(lists.markPlayed(key, p), isTrue);
    }
  }

  test('kFolderSetSize es 8', () {
    expect(kFolderSetSize, 8);
  });

  test('cambio de carpeta sonando: cola = 8 de la nueva, nada de la '
      'anterior; la que suena sigue', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final List<String> salsa = _folder(tmp.path, 'Salsa', 100);
    final List<String> merengue = _folder(tmp.path, 'Merengue', 50);
    final TrackSet s1 = await take(lists, _key(tmp.path, 'Salsa'), salsa);
    expect(s1.paths, hasLength(8));
    expect(s1.paths.every(salsa.contains), isTrue);
    // Suenan 3 de salsa; con la 4a sonando el DJ elige Merengue.
    playAll(lists, _key(tmp.path, 'Salsa'), s1.paths.take(3).toList());
    final String now = s1.paths[3];
    final TrackSet m1 = await take(
      lists,
      _key(tmp.path, 'Merengue'),
      merengue,
      exclude: <String>[now],
    );
    final List<String> q = folderSetQueue(set: m1.paths, current: now);
    expect(q, hasLength(8));
    expect(q.every(merengue.contains), isTrue);
    expect(q.any(salsa.contains), isFalse);
    expect(q.contains(now), isFalse);
  });

  test('preRoll comprometido: la fijada va primera y luego el set', () {
    const String pinned = 'C:/m/Salsa/fijada.mp3';
    final List<String> set = <String>[
      for (int i = 0; i < 8; i++) 'C:/m/Merengue/m$i.mp3',
    ];
    final List<String> q = folderSetQueue(
      set: <String>[...set, pinned],
      current: 'C:/m/Salsa/actual.mp3',
      pinned: <String>[pinned],
    );
    expect(q.first, pinned);
    expect(q, hasLength(9));
    expect(q.where((String p) => p == pinned), hasLength(1));
  });

  test('volver a una carpeta retoma en la 9-16 sin repetir', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final List<String> merengue = _folder(tmp.path, 'Merengue', 50);
    final List<String> salsa = _folder(tmp.path, 'Salsa', 100);
    final String km = _key(tmp.path, 'Merengue');
    final List<String> order = _seeded(7)(merengue);
    final TrackSet m1 = await take(lists, km, merengue);
    expect(m1.paths, order.sublist(0, 8));
    playAll(lists, km, m1.paths);
    // Pasa por Salsa y vuelve.
    final TrackSet s1 = await take(lists, _key(tmp.path, 'Salsa'), salsa);
    playAll(lists, _key(tmp.path, 'Salsa'), s1.paths);
    final TrackSet m2 = await take(lists, km, merengue);
    expect(m2.paths, order.sublist(8, 16));
    expect(m2.paths.toSet().intersection(m1.paths.toSet()), isEmpty);
  });

  test('el cursor por carpeta persiste entre sesiones', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final List<String> cumbia = _folder(tmp.path, 'Cumbia', 40);
    final String kc = _key(tmp.path, 'Cumbia');
    final TrackSet c1 = await take(lists, kc, cumbia);
    playAll(lists, kc, c1.paths);
    await lists.flush();
    PersistentListsStore.debugForgetAll();
    final PersistentLists again = open();
    await again.store.load();
    final TrackSet c2 = await take(again, kc, cumbia, seed: 99);
    expect(c2.paths, hasLength(8));
    expect(c2.paths.toSet().intersection(c1.paths.toSet()), isEmpty);
    expect(c2.paths, _seeded(7)(cumbia).sublist(8, 16));
  });

  test('sin repetir hasta agotar; agotada, ciclo nuevo', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final List<String> f = _folder(tmp.path, 'Bachata', 20);
    final String k = _key(tmp.path, 'Bachata');
    final Set<String> heard = <String>{};
    for (int i = 0; i < 3; i++) {
      final TrackSet s = await take(lists, k, f);
      expect(s.paths, isNotEmpty);
      for (final String p in s.paths) {
        expect(heard.add(p), isTrue, reason: 'repetida $p');
      }
      playAll(lists, k, s.paths);
    }
    expect(heard, hasLength(20));
    final TrackSet again = await take(lists, k, f);
    expect(again.paths, hasLength(8));
    expect(again.paths.every(f.contains), isTrue);
  });

  test('al terminar un set sigue el siguiente de la misma carpeta', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final List<String> f = _folder(tmp.path, 'Salsa', 30);
    final String k = _key(tmp.path, 'Salsa');
    final TrackSet s1 = await take(lists, k, f);
    playAll(lists, k, s1.paths.take(7).toList());
    // La ultima del set suena: se pide el siguiente sin ella.
    final TrackSet s2 = await take(lists, k, f, exclude: <String>[s1.paths[7]]);
    expect(s2.paths, hasLength(8));
    expect(s2.paths.toSet().intersection(s1.paths.toSet()), isEmpty);
  });

  test('Live DJ: loadStation sonando no para decks ni arranca en frio', () {
    final String src = _src('lib/providers/livedj_provider.dart');
    final String head = _body(
      src,
      'Future<bool> loadStation({',
      'await _stopWhenNoNext();',
    );
    expect(head, contains('return _loadStationLive('));
    final String live = _body(
      src,
      'Future<bool> _loadStationLive({',
      'Future<void> savePlaylist()',
    );
    for (final String bad in <String>[
      '_stopWhenNoNext',
      'stop(',
      '.open(',
      'togglePlayPause',
      'parkIdleDecks',
      'currentTrackPath:',
      'isPlaying:',
    ]) {
      expect(live.contains(bad), isFalse, reason: bad);
    }
    expect(live, contains('folderSetQueue('));
    expect(live, contains('_drift.preRollActive'));
    expect(src, contains('return _loadStationLive('));
  });

  test('Live DJ: playFolderList usa sets de 8 y sigue con el siguiente', () {
    final String src = _src('lib/providers/livedj_provider.dart');
    final String body = _body(src, 'Future<int> playFolderList(', '\n  }\n');
    expect(body, contains('folderSetFor('));
    expect(body, contains('playSet('));
    expect(src, contains('Future<void> _topUpSet()'));
    expect(src, contains('_setTick();'));
  });

  test('Automix: cambiar de lista sonando no aparca decks', () {
    final String src = _src('lib/providers/automix_provider.dart');
    final String sw = _body(
      src,
      'Future<bool> _switchPersistentQueue(',
      '\n  }\n',
    );
    final int live = sw.indexOf('return _switchToSetLive(');
    expect(live, greaterThan(0));
    expect(sw.contains('parkIdleDecks'), isFalse);
    expect(sw.substring(0, live).contains('togglePlayPause'), isFalse);
    final String body = _body(
      src,
      'Future<bool> _switchToSetLive(',
      'void _setTick()',
    );
    for (final String bad in <String>[
      'parkIdleDecks',
      'togglePlayPause',
      'stop(',
      '_loadPersistentQueue',
    ]) {
      expect(body.contains(bad), isFalse, reason: bad);
    }
    expect(body, contains('folderSetFor('));
    expect(body, contains('nextTrackLocked'));
  });

  test('botones dicen lo que hacen (sin "+ Mezclar todo")', () {
    final String picker = _src('lib/ui/mobile/music_picker_screen.dart');
    expect(picker, contains("'Poner este set (8) a continuación'"));
    expect(picker.contains("Text('Mezclar todo'"), isFalse);
    expect(
      _src('lib/ui/workspaces/livedj_workspace.dart'),
      contains('"Poner set (8)"'),
    );
    expect(
      _src('lib/ui/workspaces/automix_workspace.dart'),
      contains('"Cargar carpeta (sin cortar)"'),
    );
  });
}
