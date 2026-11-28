import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/audio/tempo_drift.dart';
import 'package:difogo/providers/livedj_provider.dart'
    show liveDjLockedPrefix, liveDjTriggerIndex;

// 3.2.0: la siguiente queda congelada desde que se compromete la rampa
// previa de A; una pareja nueva sin plan devuelve A a 1.0 y B iguala el BPM
// real de A. Dart puro, sin decks.

String _read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

List<File> _q(List<String> p) => <File>[for (final String s in p) File(s)];

/// A 120 -> 128: rampa de 8 s, arranque 8133 ms de pista antes de 180000.
TempoDrift _rampedDrift() {
  final TempoDrift d = TempoDrift()..begin(120, 1.0);
  final double? t = d.tick(
    posMs: 180000 - 8133,
    durMs: 240000,
    mixOutMs: 180000,
    rate: 1.0,
    nextBpm: 128,
  );
  expect(t, closeTo(124 / 120, 1e-12));
  return d;
}

void main() {
  test('3200 preRollActive: se compromete 1 s antes del arranque', () {
    final TempoDrift d = TempoDrift()..begin(120, 1.0);
    const int start = 180000 - 8133;
    double? tick(int pos) => d.tick(
      posMs: pos,
      durMs: 240000,
      mixOutMs: 180000,
      rate: 1.0,
      nextBpm: 128,
    );
    expect(tick(start - kPreRollLockLeadMs - 1), isNull);
    expect(d.preRollActive, isFalse);
    expect(tick(start - kPreRollLockLeadMs), isNull);
    expect(d.preRollActive, isTrue, reason: 'comprometida antes de moverse');
    expect(tick(start), closeTo(124 / 120, 1e-12));
    expect(d.preRollActive, isTrue);
    // Live DJ precarga a mas tardar ahi: max(10 s, lead + 1 s).
    expect(d.preRollArmLeadMs(128), 10000);
    final TempoDrift wide = TempoDrift()..begin(120, 1.0);
    expect(wide.preRollArmLeadMs(132), 12300 + kPreRollLockLeadMs);
    expect(wide.preRollArmLeadMs(121), 10000);
    // El cruce (begin) suelta el candado.
    d.begin(128, 124 / 128);
    expect(d.preRollActive, isFalse);
  });

  test('3200 (a) Automix: la siguiente fijada no se mueve', () {
    const List<String> q = <String>[
      'cur.mp3',
      'nueva.mp3',
      'next.mp3',
      'y.mp3',
    ];
    final List<String> out = pinNextTrack(
      q,
      current: 'cur.mp3',
      pinned: 'next.mp3',
    );
    expect(out, <String>['cur.mp3', 'next.mp3', 'nueva.mp3', 'y.mp3']);
    // Ya en su lugar, quitada por el usuario o igual a la actual: misma lista.
    final List<String> ok = <String>['cur.mp3', 'next.mp3', 'y.mp3'];
    expect(
      identical(pinNextTrack(ok, current: 'cur.mp3', pinned: 'next.mp3'), ok),
      isTrue,
    );
    final List<String> gone = <String>['cur.mp3', 'y.mp3'];
    expect(
      identical(
        pinNextTrack(gone, current: 'cur.mp3', pinned: 'next.mp3'),
        gone,
      ),
      isTrue,
    );
    expect(
      identical(pinNextTrack(ok, current: 'cur.mp3', pinned: 'cur.mp3'), ok),
      isTrue,
    );
    final String am = _read('lib/providers/automix_provider.dart');
    expect(
      am.contains(
        'bool get nextTrackLocked => _isCrossfading || _drift.preRollActive;',
      ),
      isTrue,
    );
    expect(
      am.contains('if (nextTrackLocked && state.nextTrackPath != null) {'),
      isTrue,
    );
    expect(
      am.contains('pinned: nextTrackLocked ? state.nextTrackPath : null,'),
      isTrue,
    );
    expect(
      am.contains(
        '    _pinLockedNext();\n    final nextIdx = _calculateNextIndex();',
      ),
      isTrue,
    );
    expect(
      am.contains('await _stopAbortedIncoming(incomingPlayer, nextTrack);'),
      isTrue,
    );
  });

  test('3200 (a) Live DJ: cabeza protegida y precargada en el disparo', () {
    final List<File> q = _q(<String>['next.mp3', 'b.mp3', 'c.mp3']);
    expect(liveDjLockedPrefix(queue: q, crossfading: false, preRoll: false), 0);
    expect(
      liveDjLockedPrefix(queue: q, crossfading: false, preRoll: true),
      1,
      reason: 'rampa comprometida: la cabeza no se toca',
    );
    expect(
      liveDjLockedPrefix(
        queue: q,
        crossfading: false,
        preRoll: true,
        driftNext: 'b.mp3',
      ),
      2,
    );
    expect(
      liveDjLockedPrefix(
        queue: q,
        crossfading: false,
        preRoll: false,
        armed: 'c.mp3',
      ),
      3,
    );
    expect(liveDjLockedPrefix(queue: q, crossfading: true, preRoll: false), 1);
    // Disparo: la precargada manda aunque la cabeza cambie.
    final List<File> moved = _q(<String>['otra.mp3', 'next.mp3', 'b.mp3']);
    expect(
      liveDjTriggerIndex(queue: moved, current: 'cur.mp3', armed: 'next.mp3'),
      1,
    );
    // Quitada por el usuario: la fijada por la rampa, si no la cabeza.
    expect(
      liveDjTriggerIndex(
        queue: moved,
        current: 'cur.mp3',
        armed: 'quitada.mp3',
        pinned: 'b.mp3',
      ),
      2,
    );
    expect(
      liveDjTriggerIndex(
        queue: moved,
        current: 'cur.mp3',
        armed: 'quitada.mp3',
      ),
      0,
    );
    final String ld = _read('lib/providers/livedj_provider.dart');
    expect(ld.contains('preRoll: _drift.preRollActive,'), isTrue);
    expect(ld.contains('posMs >= (barMixOut - armLeadMs) &&'), isTrue);
    // 3.2.39: Fiesta pasa floorMs; Automix/Radio siguen en 10000.
    expect(ld.contains('_drift.preRollArmLeadMs('), isTrue);
    expect(
      ld.contains('floorMs: _isFiestaMix() ? kFiestaPreRollFloorMs : 10000'),
      isTrue,
    );
    expect(
      ld.contains('liveDjTriggerIndex(\n            queue: state.queue,'),
      isTrue,
    );
    expect(
      ld.contains('await _stopAbortedIncoming(incomingPlayer, nextTrack);'),
      isTrue,
    );
    expect(ld.contains('posMs >= (barMixOut - 10000)'), isFalse);
  });

  test('3200 (b) pareja nueva < 2 %: A vuelve a 1.0 y B iguala a A', () {
    final TempoDrift d = _rampedDrift();
    expect(d.preRollActive, isTrue);
    // A va por 1.02 (122.4 BPM) y la siguiente pasa a 121 (< 2 %).
    final double? back = d.tick(
      posMs: 176000,
      durMs: 240000,
      mixOutMs: 180000,
      rate: 1.02,
      nextBpm: 121,
    );
    expect(back, 1.0);
    expect(d.rampLinear, isTrue);
    // 0.5 BPM/s: 2.4 BPM -> 4.8 s.
    expect(d.rampMs, 4800);
    expect(d.preRollActive, isFalse);
    // Una sola vez.
    expect(
      d.tick(
        posMs: 176200,
        durMs: 240000,
        mixOutMs: 180000,
        rate: 1.019,
        nextBpm: 121,
      ),
      isNull,
    );
    // B iguala el BPM real de A mientras siga desplazado.
    final MidpointEntry e = symmetricEntry(120, 121, outRateNow: 1.02);
    expect(e.blocked, isFalse);
    expect(e.incomingRate, closeTo(120 * 1.02 / 121, 1e-12));
    // A ya en 1.0: regla < 2 % intacta.
    expect(symmetricEntry(120, 121, outRateNow: 1.0).incomingRate, 1.0);
    expect(midpointEntry(120, 121).incomingRate, 1.0);
    // Fuera de 0.88-1.12 al igualar: 1.0.
    final MidpointEntry far = symmetricEntry(100, 130, outRateNow: 1.02);
    expect(far.blocked, isTrue);
    expect(far.incomingRate, 1.0);
  });

  test('3200 (b) siguiente quitada (sin BPM) o fuera de rango: A vuelve', () {
    final TempoDrift d = _rampedDrift();
    expect(
      d.tick(
        posMs: 175000,
        durMs: 240000,
        mixOutMs: 180000,
        rate: 1.01,
        nextBpm: 0,
      ),
      1.0,
    );
    expect(d.rampMs, 2400);
    final TempoDrift f = _rampedDrift();
    expect(
      f.tick(
        posMs: 175000,
        durMs: 240000,
        mixOutMs: 180000,
        rate: 1.01,
        nextBpm: 165,
      ),
      1.0,
    );
    expect(f.midpointBlocked, isTrue);
    // Comprometida sin moverse y pareja sin plan: solo se suelta.
    final TempoDrift c = TempoDrift()..begin(120, 1.0);
    c.tick(
      posMs: 180000 - 9133,
      durMs: 240000,
      mixOutMs: 180000,
      rate: 1.0,
      nextBpm: 128,
    );
    expect(c.preRollActive, isTrue);
    expect(
      c.tick(
        posMs: 171000,
        durMs: 240000,
        mixOutMs: 180000,
        rate: 1.0,
        nextBpm: 121,
      ),
      isNull,
    );
    expect(c.preRollActive, isFalse);
  });
}
