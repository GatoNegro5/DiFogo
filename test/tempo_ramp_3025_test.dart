import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/audio/tempo_drift.dart';

/// 128 sonando, 134 la que entra. Live DJ, Automix y Radio usan el mismo
/// [midpointTempoPlan]: la radio mezcla por el motor de Live DJ.
void _expectMidpoint(String mode) {
  const double outBpm = 128;
  const double inBpm = 134;
  final MidpointTempoPlan plan = midpointTempoPlan(outBpm, inBpm);
  expect(plan.rateLimited, isFalse, reason: mode);
  expect(plan.midpoint, 131);
  expect(plan.incomingRate, closeTo(131 / 134, 1e-12), reason: mode);

  final TempoDrift before = TempoDrift();
  // 3.1.99: rampa simetrica lineal (delta 6 -> 6 s reales antes de la
  // entrada, 6070 ms de pista) hasta m/a = 131/128.
  expect(before.outgoingRamp, isTrue);
  before.begin(outBpm, 1.0);
  final double? early = before.tick(
    posMs: 170000,
    durMs: 200000,
    mixOutMs: 180000,
    rate: 1.0,
    nextBpm: inBpm,
  );
  expect(early, isNull, reason: '$mode: 10 s antes todavia no');
  final double? toward = before.tick(
    posMs: 180000 - 6070,
    durMs: 200000,
    mixOutMs: 180000,
    rate: 1.0,
    nextBpm: inBpm,
  );
  expect(toward, isNotNull, reason: '$mode arranca delta s antes');
  expect(toward!, closeTo(131 / 128, 1e-9));
  expect(before.rampMs, 6000);
  expect(before.rampLinear, isTrue);
  final List<double> up = tempoRampSchedule(1.0, toward);
  expect(up.length, greaterThanOrEqualTo(50));
  expect(up.first, 1.0);
  expect(up.last, toward);

  final TempoDrift after = TempoDrift();
  after.begin(inBpm, plan.incomingRate);
  expect(after.active, isTrue, reason: '$mode no suelta el rate de golpe');
  after.tick(
    posMs: 10000,
    durMs: 200000,
    mixOutMs: 180000,
    rate: plan.incomingRate,
    nextBpm: 0,
  );
  final double? back = after.tick(
    posMs: 15000,
    durMs: 200000,
    mixOutMs: 180000,
    rate: plan.incomingRate,
    nextBpm: 0,
  );
  expect(back, isNotNull, reason: '$mode vuelve 5 s después del cruce');
  expect(back!, greaterThan(plan.incomingRate));
  expect(back, lessThan(1.0));
}

void main() {
  test('Live DJ: 128 y 134 se encuentran en 131', () {
    _expectMidpoint('Live DJ');
  });

  test('Automix: 128 y 134 se encuentran en 131', () {
    _expectMidpoint('Automix');
  });

  test('Radio: 128 y 134 se encuentran en 131', () {
    _expectMidpoint('Radio');
  });

  test('el golpe espera al siguiente beat, menos la latencia medida', () {
    expect(
      beatPhaseWaitMs(
        nowOutMs: 1000,
        beatMs: 0,
        bpm: 120,
        outRate: 1,
        startupMs: 20,
      ),
      480,
    );
    expect(
      beatPhaseWaitMs(
        nowOutMs: 1000,
        beatMs: 0,
        bpm: 120,
        outRate: 1.25,
        startupMs: 20,
      ),
      ((1500 - 1000) / 1.25).round() - 20,
    );
    expect(
      beatPhaseWaitMs(
        nowOutMs: 1000,
        beatMs: 0,
        bpm: 0,
        outRate: 1,
        startupMs: 20,
      ),
      0,
    );
    expect(
      beatPhaseWaitMs(
        nowOutMs: 1000,
        beatMs: 0,
        bpm: 120,
        outRate: 1,
        startupMs: 0,
      ),
      500,
    );
  });

  test('la vuelta de B no se salta con el reloj de 250 ms', () {
    final MidpointTempoPlan plan = midpointTempoPlan(128, 134);
    final TempoDrift drift = TempoDrift();
    drift.begin(134, plan.incomingRate);
    const int origin = 0;
    final List<double> rates = <double>[];
    double rate = plan.incomingRate;
    for (int pos = origin; pos <= 12000; pos += 250) {
      final double? next = drift.tick(
        posMs: pos,
        durMs: 240000,
        mixOutMs: 200000,
        rate: rate,
        nextBpm: 0,
      );
      if (next != null) {
        rates.add(next);
        rate = next;
      }
    }
    expect(rates, hasLength(2));
    expect(rates.last, closeTo(1.0, 1e-9));
  });
}
