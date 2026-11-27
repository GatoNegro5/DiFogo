import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/folder_sets.dart';
import 'package:difogo/core/persistent_lists.dart';

// 3.2.29 Modo Fiesta: una estacion con varios generos suena por sets de 8 de
// un genero y rota sola; cada genero con su cursor persistente sin repetir.
// Todo en %TEMP%.

String get _sep => Platform.pathSeparator;

String _src(String rel) =>
    File(rel).readAsStringSync().replaceAll('\r\n', '\n');

PersistentBuildOrder _seeded(int seed) =>
    (List<String> xs) => List<String>.from(xs)..shuffle(Random(seed));

void main() {
  late Directory tmp;
  late String listsPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_fiesta_3229_');
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

  Map<String, List<String>> groups() => <String, List<String>>{
    'salsa': <String>[for (int i = 0; i < 100; i++) 'C:/b/salsa/s$i.mp3'],
    'merengue': <String>[for (int i = 0; i < 50; i++) 'C:/b/merengue/m$i.mp3'],
    'cumbia': <String>[for (int i = 0; i < 40; i++) 'C:/b/cumbia/c$i.mp3'],
  };

  /// Simula la fiesta: pide el set, lo "suena" entero y pide el siguiente.
  List<TrackSet> party(PersistentLists lists, int sets) {
    final Map<String, List<String>> g = groups();
    final List<TrackSet> out = <TrackSet>[];
    String? sub;
    String? last;
    for (int i = 0; i < sets; i++) {
      final TrackSet s = fiestaNextSet(
        lists,
        'bailables',
        g,
        buildOrder: _seeded(3),
        current: sub,
        exclude: <String>[?last],
      );
      expect(s.isEmpty, isFalse);
      out.add(s);
      sub = fiestaSubOfKey(s.owner);
      for (final String p in s.paths) {
        expect(lists.markPlayed(s.owner, p), isTrue);
      }
      last = s.paths.last;
    }
    return out;
  }

  test('claves por estacion y genero', () {
    expect(fiestaListKey('Bailables', 'Salsa'), 'fiesta:bailables/salsa');
    expect(fiestaSubOfKey('fiesta:bailables/salsa'), 'salsa');
    expect(fiestaSubOfKey('folder:C:/x'), isNull);
  });

  test('rota de genero cada 8 y pasa por todos', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final List<TrackSet> sets = party(lists, 6);
    final List<String?> subs = <String?>[
      for (final TrackSet s in sets) fiestaSubOfKey(s.owner),
    ];
    for (final TrackSet s in sets) {
      expect(s.paths, hasLength(kFolderSetSize));
      final String sub = fiestaSubOfKey(s.owner)!;
      expect(s.paths.every((String p) => p.contains('/$sub/')), isTrue);
    }
    for (int i = 1; i < subs.length; i++) {
      expect(subs[i], isNot(subs[i - 1]), reason: 'set $i repite genero');
    }
    expect(subs.take(3).toSet(), <String>{'salsa', 'merengue', 'cumbia'});
    expect(subs.sublist(3, 6), subs.sublist(0, 3));
  });

  test('cada genero sigue su cursor sin repetir (2a vuelta = 9-16)', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final Map<String, List<String>> g = groups();
    final List<TrackSet> sets = party(lists, 6);
    for (int i = 0; i < 3; i++) {
      final TrackSet a = sets[i];
      final TrackSet b = sets[i + 3];
      expect(b.owner, a.owner);
      final String sub = fiestaSubOfKey(a.owner)!;
      final List<String> order = _seeded(3)(g[sub]!);
      expect(a.paths, order.sublist(0, 8));
      expect(b.paths, order.sublist(8, 16));
    }
    final List<String> all = <String>[
      for (final TrackSet s in sets) ...s.paths,
    ];
    expect(all.toSet(), hasLength(all.length));
  });

  test('genero agotado: ciclo nuevo solo de ese genero', () async {
    final PersistentLists lists = open();
    await lists.store.load();
    final Map<String, List<String>> g = <String, List<String>>{
      'a': <String>[for (int i = 0; i < 8; i++) 'C:/f/a/a$i.mp3'],
      'b': <String>[for (int i = 0; i < 24; i++) 'C:/f/b/b$i.mp3'],
    };
    String? sub;
    final List<TrackSet> got = <TrackSet>[];
    for (int i = 0; i < 4; i++) {
      final TrackSet s = fiestaNextSet(
        lists,
        'tropical',
        g,
        buildOrder: _seeded(1),
        current: sub,
      );
      got.add(s);
      sub = fiestaSubOfKey(s.owner);
      for (final String p in s.paths) {
        lists.markPlayed(s.owner, p);
      }
    }
    expect(got.map((TrackSet s) => fiestaSubOfKey(s.owner)).toList(), <String>[
      'a',
      'b',
      'a',
      'b',
    ]);
    expect(got[2].paths.toSet(), got[0].paths.toSet());
    expect(got[3].paths.toSet().intersection(got[1].paths.toSet()), isEmpty);
  });

  test('grupos por sub-genero; las generales en "otros"', () {
    final Map<String, List<String>> g = fiestaGroups(
      <String>['C:/x/s1.mp3', 'C:/x/m1.mp3', 'C:/x/z.mp3', 'C:/x/s2.mp3'],
      subOf: (String p) => p.contains('/s')
          ? 'bailables|salsa'
          : p.contains('/m')
          ? 'bailables|merengue'
          : null,
    );
    expect(g.keys.toSet(), <String>{'salsa', 'merengue', kFiestaOtherSub});
    expect(g['salsa'], hasLength(2));
  });

  test('siguiente genero: el que hace mas que no suena, nunca el actual', () {
    expect(
      fiestaNextSub(<String, int>{'a': 50, 'b': 10, 'c': 30}, current: 'b'),
      'c',
    );
    expect(fiestaNextSub(<String, int>{'a': 0}, current: 'a'), 'a');
  });

  test('Hub: interruptor Modo Fiesta persistente y rama de sets', () {
    final String hub = _src('lib/providers/vibe_hub_provider.dart');
    expect(hub, contains('final bool fiestaMode;'));
    expect(hub, contains("'fiesta': state.fiestaMode"));
    expect(hub, contains("v['fiesta'] == true"));
    expect(hub, contains('Future<void> setFiestaMode(bool on)'));
    expect(hub, contains('fiestaGroups(all)'));
    expect(hub, contains('fiestaSetFor('));
    expect(hub, contains('dj.playSet('));
    final String view = _src('lib/ui/vibe_hub_view.dart');
    expect(view, contains('class FiestaModeButton'));
    expect(view, contains('GatoMixTheme.fire'));
    // 3.2.30: en la cabecera de Dj, Fiesta es un segmento de DjModeBar.
    expect(
      _src('lib/ui/workspaces/livedj_workspace.dart'),
      contains('DjModeBar('),
    );
    expect(
      _src('lib/providers/dj_ui_provider.dart'),
      contains('await hub.setFiestaMode(true);'),
    );
  });
}
