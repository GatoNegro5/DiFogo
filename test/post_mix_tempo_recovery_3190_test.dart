import 'dart:io';

import 'package:difogo/core/post_mix_tempo_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.1.90: retorno a 1.0x tras el handoff, 4-8 s en pasos de 200 ms, sin
// decks reales (reloj falso inyectado).

class _Rec {
  int clockMs = 0;
  final List<(int, double)> sets = <(int, double)>[];
  Future<void> set(double r) async => sets.add((clockMs, r));
  Future<void> wait(Duration d) async => clockMs += d.inMilliseconds;
}

String _read(String p) => File(p).readAsStringSync();

void main() {
  // 125 BPM igualada a 105 BPM: rate 105 / 125 = 0.84.
  const double entry = 105 / 125;

  test('duracion: 0.84x -> 8 s, piso 4 s, techo 8 s, nada si <= 0.003', () {
    expect(entry, closeTo(0.84, 1e-9));
    expect(postMixRecoveryMs(entry), 8000);
    expect(postMixRecoveryMs(0.85), 7500);
    expect(postMixRecoveryMs(0.88), 6000);
    expect(postMixRecoveryMs(0.97), 4000);
    expect(postMixRecoveryMs(1.12), 6000);
    expect(postMixRecoveryMs(0.70), 8000);
    expect(postMixRecoveryMs(0.998), 0);
    expect(postMixRecoveryMs(1.0), 0);
  });

  test('0.84x: arranca en el handoff, pasos <= 0.02, 1.00 exacto en <= 8 s',
      () async {
    final _Rec rec = _Rec();
    final bool done = await PostMixTempoRecovery().run(
      fromRate: entry,
      setRate: rec.set,
      alive: () => true,
      paused: () => false,
      wait: rec.wait,
    );
    expect(done, isTrue);
    // a) el primer paso sale en el instante del handoff (t = 0).
    expect(rec.sets.first.$1, 0);
    expect(rec.sets.first.$2, greaterThan(entry));
    // b) pasos suaves y monotonicos.
    double prev = entry;
    double maxStep = 0;
    for (final (int, double) s in rec.sets) {
      final double step = s.$2 - prev;
      expect(step, greaterThan(0));
      expect(step, lessThanOrEqualTo(kPostMixMaxStep));
      if (step > maxStep) maxStep = step;
      prev = s.$2;
    }
    // Micro-pasos de 200 ms.
    for (int i = 1; i < rec.sets.length; i++) {
      expect(rec.sets[i].$1 - rec.sets[i - 1].$1, kPostMixStepMs);
    }
    // c) 1.0 exacto en <= 8 s.
    expect(rec.sets.last.$2, 1.0);
    expect(rec.sets.last.$1, lessThanOrEqualTo(kPostMixMaxMs));
    expect(rec.sets.length, 40);
    expect(maxStep, lessThan(0.0065));
  });

  test('la otra direccion (1.12x) tambien llega a 1.0 exacto', () async {
    final List<double> s = postMixRecoverySchedule(1.12);
    expect(s.length, 30);
    expect(s.last, 1.0);
    double prev = 1.12;
    for (final double r in s) {
      expect((r - prev).abs(), lessThanOrEqualTo(kPostMixMaxStep));
      expect(r, lessThanOrEqualTo(prev));
      prev = r;
    }
  });

  test('pausa: corta la rampa y deja 1.0 en silencio', () async {
    final _Rec rec = _Rec();
    final bool done = await PostMixTempoRecovery().run(
      fromRate: entry,
      setRate: rec.set,
      alive: () => true,
      paused: () => rec.clockMs >= 1000,
      wait: rec.wait,
    );
    expect(done, isFalse);
    expect(rec.sets.last, (1000, 1.0));
    expect(rec.sets.length, 6);
  });

  test('salto o cruce nuevo: suelta la rampa sin tocar el rate', () async {
    final _Rec rec = _Rec();
    final bool done = await PostMixTempoRecovery().run(
      fromRate: entry,
      setRate: rec.set,
      alive: () => rec.clockMs < 1000,
      paused: () => false,
      wait: rec.wait,
    );
    expect(done, isFalse);
    expect(rec.sets.length, 5);
    expect(rec.sets.last.$2, lessThan(1.0));
  });

  test('cancel(): un cruce nuevo detiene la rampa en curso', () async {
    final PostMixTempoRecovery rec = PostMixTempoRecovery();
    final _Rec log = _Rec();
    final bool done = await rec.run(
      fromRate: entry,
      setRate: log.set,
      alive: () => true,
      paused: () => false,
      wait: (Duration d) async {
        log.clockMs += d.inMilliseconds;
        if (log.clockMs == 600) rec.cancel();
      },
    );
    expect(done, isFalse);
    expect(rec.running, isFalse);
    expect(log.sets.length, 3);
  });

  test('blindaje de fuente: los dos motores usan la rampa tras el handoff',
      () {
    for (final String f in <String>[
      'lib/providers/livedj_provider.dart',
      'lib/providers/automix_provider.dart',
    ]) {
      final String src = _read(f);
      expect(src.contains('final PostMixTempoRecovery _postMix'), isTrue,
          reason: f);
      // Arranca justo despues de soltar el cruce.
      final int rel = src.indexOf('_releaseMix();\r\n      _startPostMixRecovery(');
      final int relLf = src.indexOf('_releaseMix();\n      _startPostMixRecovery(');
      expect(rel >= 0 || relLf >= 0, isTrue, reason: f);
      // TempoDrift ya no lleva la entrante (antes 15-34 s o colgada).
      expect(src.contains('matched ?? incomingRate'), isFalse, reason: f);
      // Cruce nuevo o pista nueva: la rampa se suelta.
      expect(src.contains('alive: () => !_isCrossfading'), isTrue, reason: f);
      expect('_postMix.cancel();'.allMatches(src).length,
          greaterThanOrEqualTo(3), reason: f);
    }
  });
}
