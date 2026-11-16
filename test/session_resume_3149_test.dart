// 3.1.49: Live DJ reabre en el segundo exacto aunque la ruta guardada sea
// otra (4 = LAN) y la posicion se guarda cada 5 s. Solo %TEMP%.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/session_restore.dart';
import 'package:gatomix/core/session_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('gmx3149_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('ruta 4: deck en 26264 ms, en pausa, sin arrancar en 0', () {
    final String track =
        '${tmp.path}${Platform.pathSeparator}Barrabas - On The Road Again.mp3';
    File(track).writeAsBytesSync(List<int>.filled(512, 0));
    final File live = File('${tmp.path}${Platform.pathSeparator}liveDj.json')
      ..writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'schema': 2,
          'queue': <String>[],
          'currentTrackPath': track,
          'positionMs': 26264,
          'mixMode': 0,
          'mixStrategy': 0,
          'wasPlaying': true,
          'radioOn': false,
        }),
      );
    final File route = File(
      '${tmp.path}${Platform.pathSeparator}_ui_route.json',
    )..writeAsStringSync('{"route":4}');

    final LiveDjSessionRestore r = restoreLiveDjSession(
      jsonDecode(live.readAsStringSync()) as Map,
    );
    final int? saved = sessionUiRouteFromJson(
      jsonDecode(route.readAsStringSync()),
    );
    expect(r.currentTrackPath, isNotNull);
    expect(r.positionMs, 26264);
    expect(saved, 4);
    // El deck se carga siempre; no suena solo fuera de Live DJ.
    expect(
      sessionRestoreAutoPlay(
        wasPlaying: r.wasPlaying,
        savedRoute: saved,
        moduleRoute: 5,
      ),
      isFalse,
    );
    expect(
      sessionRestoreAutoPlay(wasPlaying: true, savedRoute: 5, moduleRoute: 5),
      isTrue,
    );
    // Play con el deck vacio: vuelve al segundo exacto.
    expect(sessionResumeSeekMs(r.positionMs, 240000), 26264);
    expect(sessionResumeSeekMs(r.positionMs, 0), 26264);
    expect(sessionResumeSeekMs(0, 240000), 0);
    expect(sessionResumeSeekMs(250000, 240000), 0);
  });

  test('las 8 rutas del router son validas', () {
    expect(sessionUiRouteFromJson(<String, dynamic>{'route': 7}), 7);
    expect(sessionUiRouteFromJson(<String, dynamic>{'route': 8}), isNull);
    expect(sessionUiRouteFromJson(<String, dynamic>{'route': -1}), isNull);
    expect(sessionUiRouteFromJson('x'), isNull);
  });

  test('umbral de autoguardado: 5000 ms', () {
    expect(sessionPositionShouldSave(5001, 0), isTrue);
    expect(sessionPositionShouldSave(5000, 0), isFalse);
    expect(sessionPositionShouldSave(31264, 26264), isFalse);
    expect(sessionPositionShouldSave(31265, 26264), isTrue);
    // seek real hacia atras guarda; glitch a 0 no.
    expect(sessionPositionShouldSave(10000, 26264), isTrue);
    expect(sessionPositionShouldSave(0, 26264), isFalse);
  });
}
