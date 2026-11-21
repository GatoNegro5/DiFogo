import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/audio_path.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/services/track_tags.dart';
import 'package:difogo/ui/workspaces/lan_sync_workspace.dart';

// 3.2.17: filtro en vivo de sub-generos en la cola de Live DJ, guarda del
// callback de duracion tras el await y wishlist LAN por library_guard.
// Rutas sinteticas en %TEMP%; nunca la biblioteca real.

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

void main() {
  late Directory tmp;
  late String trop;

  String p(String sub, String name) => '$trop$_sep$sub$_sep$name.mp3';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_subfilter_3217_');
    trop = '${tmp.path}${_sep}Music${_sep}Tropical';
  });

  tearDown(() {
    debugLibraryRoots = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a) desmarcar un sub-genero saca sus pendientes sin tocar la actual '
      'ni las demas', () {
    final String cur = p('Vallenatos', 'Suena');
    final String v1 = p('Vallenatos', 'V1');
    final String v2 = p('Vallenatos', 'V2');
    final String c1 = p('Cumbias', 'C1');
    final String c2 = p('Cumbias', 'C2');
    final String m1 = p('Merengues', 'M1');
    final List<String> queue = <String>[c1, v1, m1, v2, c2];
    final StationSubFilter plan = stationSubFilterPlan(
      queue: queue,
      current: cur,
      played: const <String>[],
      offPool: <String>[cur, v1, v2],
      onPool: const <String>[],
      keptPool: <String>[c1, c2, m1],
    );
    expect(plan.drop, <String>[v1, v2]);
    expect(plan.add, isEmpty);
    expect(plan.drop.contains(cur), isFalse);

    // Live DJ: la cola queda en el mismo orden sin el sub-genero.
    final List<File> q = <File>[for (final String x in queue) File(x)];
    final Set<String> drop = <String>{
      for (final String x in plan.drop) audioPathKey(x),
    };
    final List<File> after = liveDjQueueWithout(q, drop);
    expect(after.map((File f) => f.path).toList(), <String>[c1, m1, c2]);
    expect(identical(after.first, q.first), isTrue);

    // En pleno cruce la cabeza (entrante) se conserva aunque sea del
    // sub-genero desmarcado.
    final List<File> q2 = <File>[File(v1), File(c1), File(v2)];
    final List<File> cross = liveDjQueueWithout(
      q2,
      drop,
      keep: <String>{audioPathKey(v1)},
    );
    expect(cross.map((File f) => f.path).toList(), <String>[v1, c1]);

    // Una pista que otro sub-genero en visto sigue pidiendo no sale.
    final StationSubFilter shared = stationSubFilterPlan(
      queue: <String>[v1, c1],
      current: null,
      played: const <String>[],
      offPool: <String>[v1],
      onPool: const <String>[],
      keptPool: <String>[v1, c1],
    );
    expect(shared.drop, isEmpty);
  });

  test('b) volver a marcarlo reinyecta solo las no reproducidas', () {
    final String cur = p('Cumbias', 'Suena');
    final String c1 = p('Cumbias', 'C1');
    final String v1 = p('Vallenatos', 'V1');
    final String v2 = p('Vallenatos', 'V2');
    final String v3 = p('Vallenatos', 'V3');
    final String v4 = p('Vallenatos', 'V4');
    final StationSubFilter plan = stationSubFilterPlan(
      queue: <String>[c1, v4],
      current: cur,
      played: <String>[v2],
      offPool: const <String>[],
      onPool: <String>[v1, v2, v3, v4, v1],
      keptPool: <String>[c1, cur],
    );
    // v2 ya sono; v4 ya esta en la cola; v1 sin repetir.
    expect(plan.add, <String>[v1, v3]);
    expect(plan.drop, isEmpty);

    final String src = _src('lib/providers/vibe_hub_provider.dart');
    final String body = _body(
      src,
      'Future<int> _applyLiveSubFilter(',
      'void _dropFromPersistentList(',
    );
    // Sin reiniciar la lista: ni playStation ni loadStation ni reset.
    expect(body.contains('playStation('), isFalse);
    expect(body.contains('loadStation('), isFalse);
    expect(body.contains('reset('), isFalse);
    expect(body.contains('dj.dropTracksLive(plan.drop)'), isTrue);
    expect(body.contains('dj.addAllTracks('), isTrue);
    expect(body.contains('_dropFromPersistentList('), isTrue);
    expect(body.contains('await _saveStations(key);'), isTrue);

    final String view = _src('lib/ui/vibe_hub_view.dart');
    expect(view.contains('_liveFilter(st, n, checks, s);'), isTrue);
    expect(
      _body(view, 'void _liveFilter(', 'void _change(')
          .contains('if (st.key != s.activeStation) return;'),
      isTrue,
    );

    final String dj = _src('lib/providers/livedj_provider.dart');
    final String drop = _body(dj, 'int dropTracksLive(', 'void removeTrack(');
    expect(drop.contains('_isCrossfading || _drift.preRollActive'), isTrue);
    expect(
      drop.contains('if (!busy && armed != null && drop.contains('),
      isTrue,
    );
    expect(drop.contains('_standbyArmedPath = null;'), isTrue);
  });

  test('c) el callback de duracion tras el await no pisa customMixOutMs si '
      'cambio la pista o el deck', () {
    final String src = _src('lib/providers/livedj_provider.dart');
    final String body = _body(
      src,
      '_durationSub = player.stream.duration.listen(',
      '_playingSub = player.stream.playing.listen(',
    );
    final int aw = body.indexOf('await _calculateSmartCueIn(');
    final int guard = body.indexOf(
      'if (state.currentTrackPath != durPath || player != _activePlayer) '
      'return;',
    );
    final int write = body.indexOf('customMixOutMs: triggerMs');
    expect(aw, greaterThan(0));
    expect(guard, greaterThan(aw));
    expect(write, greaterThan(guard));
    // La guarda va antes de cue-in, marca roja y modo.
    final String tail = body.substring(guard);
    expect(tail.contains('customCueInMs: cueInMs'), isTrue);
    expect(tail.contains('currentMixMode: mode'), isTrue);
    // Sin controladores ni topes nuevos.
    expect(body.contains('StreamController'), isFalse);
    expect(body.contains('Timer('), isFalse);

    // _exactDurCache se suelta con TrackTags.forget.
    expect(
      src.contains('TrackTags.addForgetListener(_forgetExactDuration);'),
      isTrue,
    );
    expect(
      src.contains('TrackTags.removeForgetListener(_forgetExactDuration);'),
      isTrue,
    );
    final List<String> got = <String>[];
    void hook(String x) => got.add(x);
    TrackTags.addForgetListener(hook);
    TrackTags.forget(p('Salsa', 'Masterizada'));
    TrackTags.removeForgetListener(hook);
    TrackTags.forget(p('Salsa', 'Otra'));
    expect(got, <String>[p('Salsa', 'Masterizada')]);
  });

  test('d) wishlist_pedidos.txt bloqueado si apunta a ReGenial', () {
    final String music = '${tmp.path}${_sep}Music';
    debugLibraryRoots = <String>[music];
    final String regenial = '$music${_sep}ReGenial';
    final int before = libraryGuardBlocked;
    expect(appendWishlistLine(regenial, 'Tema pedido'), isFalse);
    expect(
      File('$regenial${_sep}wishlist_pedidos.txt').existsSync(),
      isFalse,
    );
    expect(Directory(regenial).existsSync(), isFalse);
    expect(libraryGuardBlocked, before + 1);

    // Fuera de la biblioteca si escribe (append).
    final String lab = '${tmp.path}${_sep}Lab';
    final DateTime t = DateTime(2026, 11, 21, 9, 40, 5);
    expect(appendWishlistLine(lab, 'Uno', now: t), isTrue);
    expect(appendWishlistLine(lab, 'Dos', now: t), isTrue);
    expect(
      File('$lab${_sep}wishlist_pedidos.txt').readAsStringSync(),
      '[2026-11-21 09:40:05] - Uno\n[2026-11-21 09:40:05] - Dos\n',
    );

    final String ws = _src('lib/ui/workspaces/lan_sync_workspace.dart');
    final String ep = _body(ws, "path == '/api/wishlist'", 'return;');
    expect(ep.contains('appendWishlistLine(targetPath, song)'), isTrue);
    expect(ep.contains('FileMode.append'), isFalse);
  });
}
