import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/audio/tempo_drift.dart';
import 'package:difogo/core/post_mix_tempo_recovery.dart';

// 3.1.99: rampa simetrica al punto medio a 0.5 BPM/s (2 BPM cada 4 s).
// Dart puro, reloj falso: sin decks reales.

class _Rec {
  int clockMs = 0;
  final List<(int, double)> sets = <(int, double)>[];
  Future<void> set(double r) async => sets.add((clockMs, r));
  Future<void> wait(Duration d) async => clockMs += d.inMilliseconds;
}

String _read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

/// A suena a [a], entra [b]. Comprueba pre-rampa, entrada y vuelta.
Future<void> _case(double a, double b, int deltaS) async {
  final SymmetricTempoPlan plan = symmetricTempoPlan(a, b);
  final double m = (a + b) / 2;
  expect(plan.active, isTrue);
  expect(plan.midpoint, m);
  expect(plan.outRate, closeTo(m / a, 1e-12));
  expect(plan.inRate, closeTo(m / b, 1e-12));
  expect(plan.rampMs, deltaS * 1000);
  // Pre-rampa: arranca delta s reales antes de la entrada (en pista,
  // rampMs * (1 + m/a) / 2) y termina en m/a.
  const int entry = 180000;
  final TempoDrift drift = TempoDrift();
  drift.begin(a, 1.0);
  final int start = entry - plan.leadTrackMs;
  expect(
    drift.tick(
      posMs: start - 1,
      durMs: 240000,
      mixOutMs: entry,
      rate: 1.0,
      nextBpm: b,
    ),
    isNull,
  );
  final double? tgt = drift.tick(
    posMs: start,
    durMs: 240000,
    mixOutMs: entry,
    rate: 1.0,
    nextBpm: b,
  );
  expect(tgt, closeTo(m / a, 1e-12));
  expect(drift.rampLinear, isTrue);
  expect(drift.rampMs, closeTo(deltaS * 1000, 1));
  // Pasos de 200 ms a 0.1 BPM (0.5 BPM/s), ultimo = m/a exacto.
  final List<double> up = tempoLinearSchedule(1.0, tgt!, ms: deltaS * 1000);
  expect(up.length, deltaS * 5 + 1);
  for (int i = 1; i < up.length; i++) {
    expect((up[i] - up[i - 1]) * a, closeTo((b - a).sign * 0.1, 1e-9));
  }
  expect(up.last, m / a);
  expect(a * up.last, closeTo(m, 1e-9));
  // Entrada: B a m/b, el mismo BPM_mid que A.
  final MidpointEntry e = symmetricEntry(a, b, outRateNow: m / a);
  expect(e.blocked, isFalse);
  expect(e.incomingRate, closeTo(m / b, 1e-12));
  expect(b * e.incomingRate, closeTo(a * (m / a), 1e-9));
  expect(midpointEntry(a, b).incomingRate, closeTo(m / b, 1e-12));
  // Vuelta: delta s, lineal, 0.1 BPM cada 200 ms, 1.0 exacto.
  expect(postMixRecoveryMs(m / b, bpm: b), deltaS * 1000);
  final _Rec rec = _Rec();
  final bool done = await PostMixTempoRecovery().run(
    fromRate: m / b,
    bpm: b,
    setRate: rec.set,
    alive: () => true,
    paused: () => false,
    wait: rec.wait,
  );
  expect(done, isTrue);
  expect(rec.sets.length, deltaS * 5);
  expect(rec.sets.first.$1, 0);
  expect(rec.sets.last, (deltaS * 1000 - 200, 1.0));
  double prev = m / b;
  for (final (int, double) s in rec.sets) {
    expect((s.$2 - prev) * b, closeTo((b - a).sign * 0.1, 1e-9));
    prev = s.$2;
  }
}

void main() {
  test('3199 delta 8 (120 -> 128): 8 s pre, 124 BPM, 8 s post', () async {
    await _case(120, 128, 8);
    final SymmetricTempoPlan p = symmetricTempoPlan(120, 128);
    expect(p.leadTrackMs, 8133);
  });

  test('3199 delta 12 (120 -> 132): 12 s pre, 126 BPM, 12 s post', () async {
    await _case(120, 132, 12);
    final SymmetricTempoPlan p = symmetricTempoPlan(120, 132);
    expect(p.outRate, closeTo(1.05, 1e-12));
    expect(p.leadTrackMs, 12300);
  });

  test('3199 bajada (128 -> 120) es simetrica', () async {
    await _case(128, 120, 8);
  });

  test('3199 diferencia < 2 %: ninguno se mueve', () {
    final SymmetricTempoPlan p = symmetricTempoPlan(128, 129.5);
    expect(p.noStretch, isTrue);
    expect(p.active, isFalse);
    expect(p.rampMs, 0);
    expect(midpointEntry(128, 129.5).incomingRate, 1.0);
    expect(midpointEntry(128, 129.5).blocked, isFalse);
    final TempoDrift d = TempoDrift()..begin(128, 1.0);
    for (int pos = 160000; pos <= 180000; pos += 100) {
      expect(
        d.tick(
          posMs: pos,
          durMs: 240000,
          mixOutMs: 180000,
          rate: 1.0,
          nextBpm: 129.5,
        ),
        isNull,
      );
    }
    expect(postMixRecoveryMs(1.0, bpm: 129.5), 0);
  });

  test('3199 una mitad fuera de 0.88-1.12: los dos a 1.0x', () {
    // 100 -> 130: m = 115, m/a = 1.15.
    final SymmetricTempoPlan p = symmetricTempoPlan(100, 130);
    expect(p.blocked, isTrue);
    expect(p.active, isFalse);
    final MidpointEntry e = midpointEntry(100, 130);
    expect(e.blocked, isTrue);
    expect(e.incomingRate, 1.0);
    final TempoDrift d = TempoDrift()..begin(100, 1.0);
    expect(
      d.tick(
        posMs: 179000,
        durMs: 240000,
        mixOutMs: 180000,
        rate: 1.0,
        nextBpm: 130,
      ),
      isNull,
    );
    expect(d.midpointBlocked, isTrue);
  });

  test('3199 tarde (menos de delta s): se comprime, B iguala a A', () {
    final TempoDrift d = TempoDrift()..begin(120, 1.0);
    final double? t = d.tick(
      posMs: 176000,
      durMs: 240000,
      mixOutMs: 180000,
      rate: 1.0,
      nextBpm: 128,
    );
    expect(t, closeTo(124 / 120, 1e-12));
    expect(d.rampMs, lessThan(4000));
    // Cruce sin rampa de A (rate 1.0): B toma el BPM real de A (a/b).
    final MidpointEntry e = symmetricEntry(120, 128, outRateNow: 1.0);
    expect(e.incomingRate, closeTo(120 / 128, 1e-12));
    // Menos de 200 ms: no se mueve.
    final TempoDrift late = TempoDrift()..begin(120, 1.0);
    expect(
      late.tick(
        posMs: 179900,
        durMs: 240000,
        mixOutMs: 180000,
        rate: 1.0,
        nextBpm: 128,
      ),
      isNull,
    );
  });

  test('3199 fuentes: dos motores con punto medio y vuelta por BPM', () {
    final String am = _read('lib/providers/automix_provider.dart');
    final String ld = _read('lib/providers/livedj_provider.dart');
    for (final String src in <String>[am, ld]) {
      expect(src.contains('symmetricEntry('), isTrue);
      expect(src.contains('_drift.cancelRamp();'), isTrue);
      expect(src.contains('postMixRecoveryMs(from, bpm: bpm)'), isTrue);
      expect(src.contains('!_postMix.running'), isTrue);
      expect(src.contains('masterLockEntry(fadingBpm, incomingBpm)'), isFalse);
    }
    expect(am.contains('state.customMixOutMs - kDawnLeadMs'), isTrue);
    expect(ld.contains('bpm: _incomingNatBpm'), isTrue);
  });
}
