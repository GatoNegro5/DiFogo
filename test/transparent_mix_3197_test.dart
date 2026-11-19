import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_mix_fx.dart';
import 'package:difogo/core/post_mix_tempo_recovery.dart';
import 'package:difogo/providers/mix_formula.dart';

// 3.1.97 Mezcla transparente: sin efecto "hueco/telefono" en el cruce.

String _read(String p) => File(p).readAsStringSync();

String _bassKill(String src) {
  final RegExpMatch? m = RegExp(
    r"const String _bassKillFilter =\s*'([^']+)';",
  ).firstMatch(src);
  expect(m, isNotNull);
  return m!.group(1)!;
}

void main() {
  test('3197 (a) _bassKillFilter suave en automix y livedj (>= -12 dB)', () {
    const String want =
        'equalizer=f=45:width_type=o:w=2.5:g=-10,equalizer=f=110:width_type=o:w=1.6:g=-6';
    for (final String f in <String>[
      'lib/providers/automix_provider.dart',
      'lib/providers/livedj_provider.dart',
    ]) {
      final String kill = _bassKill(_read(f));
      expect(kill, want, reason: f);
      final Iterable<RegExpMatch> gains = RegExp(
        r'g=(-?\d+(?:\.\d+)?)',
      ).allMatches(kill);
      expect(gains.length, 2, reason: f);
      for (final RegExpMatch g in gains) {
        expect(double.parse(g.group(1)!), greaterThanOrEqualTo(-12), reason: f);
      }
    }
    final String ld = _read('lib/providers/livedj_provider.dart');
    expect(ld.contains("chain.contains('g=-24')"), isFalse);
  });

  test('3197 (b) sin time-stretch con menos de 2 % de diferencia de BPM', () {
    expect(kNoStretchBpmDiff, 0.02);
    expect(transparentLockRate(128, 129.5, 128 / 129.5), 1.0);
    expect(transparentLockRate(128, 128, 1.0), 1.0);
    expect(transparentLockRate(100, 101.9, 100 / 101.9), 1.0);
    // 2 % o mas: el master lock manda sin cambios.
    expect(transparentLockRate(100, 102, 100 / 102), closeTo(100 / 102, 1e-12));
    expect(transparentLockRate(128, 134, 128 / 134), closeTo(128 / 134, 1e-12));
    // BPM desconocido: no se fuerza nada.
    expect(transparentLockRate(0, 128, 1.0), 1.0);
    expect(bpmNoStretch(0, 128), isFalse);
    // A 1.0x la recuperacion post-mezcla no hace rampa.
    expect(postMixRecoveryMs(1.0), 0);
    final String am = _read('lib/providers/automix_provider.dart');
    final String ld = _read('lib/providers/livedj_provider.dart');
    expect(am.contains('transparentLockRate('), isTrue);
    expect(ld.contains('transparentLockRate('), isTrue);
    // El master lock y su ventana siguen intactos.
    expect(am.contains('masterLockEntry(fadingBpm, incomingBpm)'), isTrue);
    expect(ld.contains('masterLockEntry(fadingBpm, incomingBpm)'), isTrue);
  });

  test('3197 (c) modo normal: sin highpass / low-pass / echo', () {
    const List<String?> stations = <String?>[
      'ochenteras',
      'rock',
      'baladas',
      'tropical',
      null,
    ];
    for (final String? st in stations) {
      final GenreMixPlan plan = genrePlanForPaths(
        current: MixFormula.dnaEnergy,
        stationKey: st,
        outPath: '/m/Electronica/Uno.mp3',
        inPath: '/m/Electronica/Dos.mp3',
      );
      expect(plan.fx, GenreMixFx.none, reason: '$st');
    }
    for (final GenreMixFx fx in GenreMixFx.values) {
      expect(cleanGenreFx(fx, djFx: false), GenreMixFx.none);
      expect(cleanGenreFx(fx, djFx: true), fx);
    }
    // Con Modo DJ (FIJO) los FX agresivos siguen disponibles.
    final GenreMixPlan dj = genrePlanForPaths(
      current: MixFormula.phraseGrid,
      stationKey: 'rock',
      locked: true,
    );
    expect(dj.fx, GenreMixFx.highpassSweep);
    // Livedj: filtros DNA de la saliente y de Long Blend solo con djFx.
    final String ld = _read('lib/providers/livedj_provider.dart');
    expect(ld.contains('final String? dnaOutExtra = !djFx'), isTrue);
    expect(ld.contains('djFx && dnaKind == DnaKind.filterSweep'), isTrue);
    expect(ld.contains('if (djFx) dnaHighShelfCut,'), isTrue);
    expect(ld.contains('djFx: genrePlan.locked,'), isTrue);
  });
}
