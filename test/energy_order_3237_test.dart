import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/livedj_order.dart';

void main() {
  test('secuencia armonico no salta mas de 2 niveles', () {
    const List<int> levels = <int>[
      3,
      3,
      4,
      4,
      5,
      5,
      6,
      6,
      7,
      7,
      8,
      8,
      7,
      6,
      5,
      4,
      3,
      4,
      5,
      6,
    ];
    final List<String> paths = <String>[
      for (int i = 0; i < levels.length; i++) 't$i.mp3',
    ];
    int levelOf(String p) {
      final int i = int.parse(p.substring(1, p.indexOf('.')));
      return levels[i];
    }

    double bpmOf(String p) {
      final int i = int.parse(p.substring(1, p.indexOf('.')));
      return 118 + (i % 6).toDouble();
    }

    HarmonicDna? dnaOf(String p) => HarmonicDna(
      energy: 0.5,
      brightness: 0.5,
      beatDensity: 0.5,
      energyLevel: levelOf(p),
    );

    final List<int> jumps = <int>[];
    for (int seed = 0; seed < 12; seed++) {
      final HarmonicOrder got = buildHarmonicShuffle(
        paths,
        bpmOf,
        dnaOf: dnaOf,
        rng: Random(seed),
        waveLength: 8,
      );
      final List<String> order = got.tracks;
      expect(order.length, paths.length);
      for (int i = 1; i < order.length; i++) {
        final int a = levelOf(order[i - 1]);
        final int b = levelOf(order[i]);
        final int d = (b - a).abs();
        jumps.add(d);
        expect(
          d,
          lessThanOrEqualTo(2),
          reason: 'seed=$seed ${order[i - 1]}($a) -> ${order[i]}($b)',
        );
      }
    }
    expect(jumps.any((int d) => d <= 1), isTrue);
  });

  test('sin DNA no se prefiere a ciegas si hay candidatas con nivel', () {
    final List<String> paths = <String>['a.mp3', 'b.mp3', 'c.mp3', 'd.mp3'];
    double bpmOf(String p) => 120;
    HarmonicDna? dnaOf(String p) {
      if (p == 'd.mp3') return null;
      const Map<String, int> lv = <String, int>{
        'a.mp3': 5,
        'b.mp3': 6,
        'c.mp3': 5,
      };
      return HarmonicDna(energyLevel: lv[p]);
    }

    for (int seed = 0; seed < 8; seed++) {
      final HarmonicOrder got = buildHarmonicShuffle(
        paths,
        bpmOf,
        dnaOf: dnaOf,
        rng: Random(seed),
      );
      // d.mp3 queda al final o no se inserta entre las que tienen nivel
      // de forma ciega: si aparece, sus vecinos con nivel no rompen el tope
      // porque se descarta del pool con nivel. Puede ir al final del known
      // set si el recorte no la dejo. Comprobamos que nunca es el 2o si
      // a queda de ancla y hay b/c.
      expect(got.tracks.contains('d.mp3'), isTrue);
      final int i = got.tracks.indexOf('d.mp3');
      // Preferimos que no quede entre las primeras 3 si hay 3 con nivel.
      if (got.tracks.first != 'd.mp3') {
        expect(i, greaterThanOrEqualTo(2), reason: '${got.tracks} seed=$seed');
      }
    }
  });

  test('pickHarmonicNext evita un salto de 4 niveles', () {
    HarmonicDna? dnaOf(String p) {
      const Map<String, int> lv = <String, int>{
        'cur.mp3': 5,
        'near.mp3': 6,
        'far.mp3': 9,
      };
      final int? n = lv[p];
      return n == null ? null : HarmonicDna(energyLevel: n);
    }

    double bpmOf(String p) => p == 'far.mp3' ? 121 : 120;
    final String? next = pickHarmonicNext(
      <String>['near.mp3', 'far.mp3'],
      bpmOf,
      dnaOf: dnaOf,
      anchor: 'cur.mp3',
      waveUp: true,
      rng: Random(1),
    );
    expect(next, 'near.mp3');
  });
}
