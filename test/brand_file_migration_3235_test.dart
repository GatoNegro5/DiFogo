// 3.2.35 (DIF-33 fase 1): archivos difogo_* pasan a gatomix_*.
// Si solo existe el nombre viejo se copia (el origen no se borra).
// Arbol sintetico en %TEMP%, sin red ni escritura en ReGenial.
import 'dart:io';

import 'package:difogo/core/brand_paths.dart';
import 'package:difogo/core/dj_trace.dart';
import 'package:difogo/core/library_guard.dart' show kOldMirrorStoreSuffix;
import 'package:difogo/core/splice_retry.dart';
import 'package:difogo/providers/curator_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  final String sep = Platform.pathSeparator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_brandfile_3235_');
  });

  tearDown(() {
    debugStationSessionsPath = null;
    debugTrackGenreIndexPath = null;
    debugDiscoveryDiscardPath = null;
    djTraceFileOverride = null;
    spliceLogOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3235 a) solo el nombre viejo: copia y no borra el origen', () {
    final File old = File('${tmp.path}${sep}difogo_genre_sessions.json')
      ..writeAsStringSync('{"active":"salsa"}');
    final String path = migrateBrandFile(
      tmp.path,
      kOldGenreSessionsName,
      kGenreSessionsName,
    );
    expect(path, '${tmp.path}$sep$kGenreSessionsName');
    expect(File(path).readAsStringSync(), '{"active":"salsa"}');
    expect(old.existsSync(), isTrue);
    expect(old.readAsStringSync(), '{"active":"salsa"}');
  });

  test('3235 b) si ya esta el nuevo, no se pisa; el viejo queda', () {
    File('${tmp.path}$sep$kOldGenreSessionsName').writeAsStringSync('old');
    File('${tmp.path}$sep$kGenreSessionsName').writeAsStringSync('new');
    final String path = migrateBrandFile(
      tmp.path,
      kOldGenreSessionsName,
      kGenreSessionsName,
    );
    expect(File(path).readAsStringSync(), 'new');
    expect(
      File('${tmp.path}$sep$kOldGenreSessionsName').readAsStringSync(),
      'old',
    );
  });

  test('3235 c) sin ninguno: ruta nueva, no crea el archivo', () {
    final String path = migrateBrandFile(
      tmp.path,
      kOldEmpalmesLogName,
      kEmpalmesLogName,
    );
    expect(path, '${tmp.path}$sep$kEmpalmesLogName');
    expect(File(path).existsSync(), isFalse);
  });

  test('3235 d) indice, descartes, trace y empalmes migran igual', () {
    for (final List<String> pair in <List<String>>[
      <String>[kOldTrackGenreIndexName, kTrackGenreIndexName],
      <String>[kOldDiscoveryDiscardsName, kDiscoveryDiscardsName],
      <String>[kOldLivedjTraceName, kLivedjTraceName],
      <String>[kOldEmpalmesLogName, kEmpalmesLogName],
    ]) {
      final Directory d = Directory('${tmp.path}$sep${pair[1]}.d')
        ..createSync();
      File('${d.path}$sep${pair[0]}').writeAsStringSync('v-${pair[0]}');
      final String path = migrateBrandFile(d.path, pair[0], pair[1]);
      expect(path, '${d.path}$sep${pair[1]}', reason: pair[1]);
      expect(File(path).readAsStringSync(), 'v-${pair[0]}');
      expect(File('${d.path}$sep${pair[0]}').existsSync(), isTrue);
    }
  });

  test('3235 e) overrides de sesion no tocan el %TEMP% real; kOld se conserva', () {
    debugStationSessionsPath = '${tmp.path}${sep}sess.json';
    debugTrackGenreIndexPath = '${tmp.path}${sep}idx.json';
    debugDiscoveryDiscardPath = '${tmp.path}${sep}disc.json';
    expect(genreSessionsPath(), debugStationSessionsPath);
    expect(trackGenreIndexPath(), debugTrackGenreIndexPath);
    expect(discoveryDiscardPath(), debugDiscoveryDiscardPath);
    expect(kOldGenreSessionsName, 'difogo_genre_sessions.json');
    expect(kOldTrackGenreIndexName, 'difogo_track_genre_index.json');
    expect(kOldDiscoveryDiscardsName, 'difogo_discovery_discards.json');
    expect(kOldLivedjTraceName, 'difogo_livedj_trace.txt');
    expect(kOldEmpalmesLogName, 'difogo_empalmes.log');
    expect(kOldOriginalDirName, '.difogo_original');
    expect(kOldMirrorStoreSuffix, '.difogo.json');
    expect(kGenreSessionsName, 'gatomix_genre_sessions.json');
    expect(kTrackGenreIndexName, 'gatomix_track_genre_index.json');
    expect(kEmpalmesLogName, 'gatomix_empalmes.log');
  });

  test('3235 f) mensajes de UI citan gatomix_empalmes.log', () {
    final String master = File(
      'lib/services/master_track.dart',
    ).readAsStringSync();
    final String yt = File(
      'lib/ui/workspaces/yt_workspace.dart',
    ).readAsStringSync();
    expect(master.contains('gatomix_empalmes.log'), isTrue);
    expect(master.contains('difogo_empalmes.log'), isFalse);
    expect(yt.contains('gatomix_empalmes.log'), isTrue);
    expect(yt.contains('ver difogo_empalmes.log'), isFalse);
    // El nombre viejo sigue en la constante de migracion.
    expect(kOldEmpalmesLogName, 'difogo_empalmes.log');
  });

  test('3235 g) djTrace y spliceLog con override no migran fuera de %TEMP%', () {
    djTraceFileOverride = '${tmp.path}${sep}t.txt';
    spliceLogOverride = '${tmp.path}${sep}e.log';
    djTrace('hola');
    logSpliceEvent('x', 'e');
    expect(File(djTraceFileOverride!).existsSync(), isTrue);
    expect(File(spliceLogOverride!).readAsStringSync(), contains('x'));
    expect(File('${tmp.path}$sep$kLivedjTraceName').existsSync(), isFalse);
    expect(File('${tmp.path}$sep$kEmpalmesLogName').existsSync(), isFalse);
  });
}
