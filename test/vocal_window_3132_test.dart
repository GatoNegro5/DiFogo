import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/providers/mix_formula.dart';

// 3.1.45: la ventana activa y el hueco sin voz de Live DJ (3.1.31/3.1.32)
// se retiraron; queda solo el golpe exacto del Set In de Automix.
// Puro: sin Player, sin archivos, sin ReGenial.
void main() {
  test('Set In manual de Automix al golpe mas cercano (<= medio golpe)', () {
    for (final double bpm in <double>[90, 117, 128, 174]) {
      final double p = 60000.0 / bpm;
      for (var cue = 0; cue <= 60000; cue += 37) {
        final int m = snapCueToBeat(
          cueMs: cue,
          beatMs: 123.4,
          bpm: bpm,
          manual: true,
        );
        expect(
          (m - cue).abs(),
          lessThanOrEqualTo(p / 2 + 1),
          reason: '$bpm $cue',
        );
        final double k = (m - 123.4) / p;
        expect((k - k.round()).abs() * p, lessThanOrEqualTo(0.5 + 1e-9));
        final int a = snapCueToBeat(
          cueMs: cue,
          beatMs: 123.4,
          bpm: bpm,
          manual: false,
        );
        expect(a, greaterThanOrEqualTo(cue - 1));
        expect(a - cue, lessThan(p + 1));
      }
    }
    expect(snapCueToBeat(cueMs: 9876, beatMs: 10, bpm: 0, manual: true), 9876);
  });
}
