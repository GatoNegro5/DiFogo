import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/tempo_drift.dart';
import 'package:gatomix/providers/mix_formula.dart';
import 'package:gatomix/ui/workspaces/livedj_spotify_panel.dart';

// 3.1.71: Active Beatmatching sin cambio de sonido antes de la mezcla,
// AutomixDj por defecto en Active Beatmatching, Phrase 8/Stealth en
// Equal-Power real de 6-8 s y Mix con Letra solo en Active Beatmatching.
// Dart puro: sin motor de audio, sin red, nada fuera de %TEMP%.

String _read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

/// Cuerpo de una funcion del archivo, desde [head] hasta la siguiente
/// declaracion [until].
String _slice(String src, String head, String until) {
  final int a = src.indexOf(head);
  expect(a, greaterThanOrEqualTo(0), reason: head);
  final int b = src.indexOf(until, a + head.length);
  return src.substring(a, b < 0 ? src.length : b);
}

/// Fraccion del cruce en que las dos suenan a -12 dB o mas (amplitud real).
double _bothAudible(double Function(double) vin, double Function(double) vout) {
  int n = 0;
  const int steps = 1000;
  for (int i = 0; i <= steps; i++) {
    final double p = i / steps;
    final double gi = mpvGainForVolume(vin(p));
    final double go = mpvGainForVolume(vout(p));
    if (gi >= 0.25 && go >= 0.25) n++;
  }
  return n / (steps + 1);
}

void main() {
  test('3171 Deck A: rate, ganancia y EQ quietos en los 7 s previos', () {
    for (final (double a, double b) pair in <(double, double)>[
      (128, 134),
      (128, 140),
      (100, 96),
      (124, 124.5),
    ]) {
      final TempoDrift drift = TempoDrift();
      drift.begin(pair.$1, 1.0);
      double rate = 1.0;
      const int mixOut = 180000;
      for (int pos = mixOut - 7000; pos < mixOut; pos += 100) {
        final double? next = drift.tick(
          posMs: pos,
          durMs: 240000,
          mixOutMs: mixOut,
          rate: rate,
          nextBpm: pair.$2,
        );
        if (next != null) rate = next;
      }
      expect(rate, 1.0, reason: 'A no cambia de rate: $pair');
      // B se ajusta en silencio al BPM de A.
      final MidpointEntry e = masterLockEntry(pair.$1, pair.$2);
      expect(e.blocked, isFalse);
      expect(e.incomingRate, closeTo(pair.$1 / pair.$2, 1e-12));
    }
    // Fuera de +-12 %: B entra a su tempo, A tampoco se toca.
    final MidpointEntry far = masterLockEntry(128, 150);
    expect(far.blocked, isTrue);
    expect(far.incomingRate, 1.0);
    // Ganancia de A al abrir el cruce: 1.0 con las dos curvas.
    expect(equalPowerOutGain(0), 1.0);
    expect(mpvVolumeForGain(equalPowerOutGain(0)), closeTo(100, 1e-9));
    expect(dawnCrossfadeGain(1.0), 1.0);
    expect(equalPowerInGain(0), 0.0);
    // B converge a su BPM solo con su fader ya arriba (despues del cruce):
    // el primer paso llega 5 s despues de terminar el cruce.
    final TempoDrift back = TempoDrift();
    back.begin(134, 128 / 134);
    double r = 128 / 134;
    final List<int> at = <int>[];
    for (int pos = 0; pos <= 20000; pos += 250) {
      final double? next = back.tick(
        posMs: pos,
        durMs: 240000,
        mixOutMs: 200000,
        rate: r,
        nextBpm: 0,
      );
      if (next != null) {
        at.add(pos);
        r = next;
      }
    }
    expect(at, isNotEmpty);
    expect(at.first, greaterThanOrEqualTo(5000));
    expect(r, closeTo(1.0, 1e-9));
    // Fuentes: el motor no toca a A al abrir el cruce y fija el rate de B
    // antes de subir su fader.
    final String ld = _read('lib/providers/livedj_provider.dart');
    final String engine = _slice(
      ld,
      'Future<void> _executeMixEngine({',
      'final MixRunClock fadeClock',
    );
    expect(
      engine.contains("platformOut?.setProperty('audio-pitch-correction'"),
      isFalse,
    );
    expect(engine.contains('if (dnaOutExtra != null) {'), isTrue);
    expect(ld.contains('masterLockEntry(fadingBpm, incomingBpm)'), isTrue);
    expect(ld.contains('midpointEntry(fadingBpm, incomingBpm)'), isFalse);
    final int setRate = ld.indexOf(
      'await incomingPlayer.setRate(incomingRate);',
    );
    final int mute = ld.indexOf(
      'await incomingPlayer.setVolume(0',
      setRate - 400,
    );
    expect(setRate, greaterThan(0));
    expect(mute, greaterThan(0));
    expect(
      ld.indexOf('await _executeMixEngine(', setRate),
      greaterThan(setRate),
    );
  });

  test('3171 AutomixDj abre en Active Beatmatching; Phrase 8/Stealth '
      'Equal-Power >= 6 s sin bajon', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(mixFormulaProvider), MixFormula.dnaEnergy);
    expect(spotifyMixLabel(c.read(mixFormulaProvider)), 'ACTIVE BEATMATCHING');
    // Sesion vieja guardada en Phrase 8: migra a Active Beatmatching.
    expect(
      mixFormulaFromSession(<String, dynamic>{'mixFormula': 1}),
      MixFormula.dnaEnergy,
    );
    expect(mixFormulaFromSession(<String, dynamic>{}), MixFormula.dnaEnergy);
    // Desde 3.1.71 se respeta lo elegido.
    expect(
      mixFormulaFromSession(<String, dynamic>{
        'mixFormula': 1,
        'mixFormulaV': kMixFormulaSchema,
      }),
      MixFormula.phraseGrid,
    );
    expect(
      mixFormulaFromSession(<String, dynamic>{
        'mixFormula': 2,
        'mixFormulaV': kMixFormulaSchema,
      }),
      MixFormula.stealthGap,
    );
    expect(mixFormulaEqualPower(MixFormula.phraseGrid), isTrue);
    expect(mixFormulaEqualPower(MixFormula.stealthGap), isTrue);
    expect(mixFormulaEqualPower(MixFormula.dnaEnergy), isFalse);
    for (final int want in <int>[3000, 6000, 8000, 12000, 18000]) {
      final int f = equalPowerFadeMs(want);
      expect(f, inInclusiveRange(6000, 8000), reason: '$want');
    }
    // Suma de potencias = 1 en todo el cruce (amplitud real tras la escala
    // cubica de mpv): ni hueco ni bajon.
    for (int i = 0; i <= 200; i++) {
      final double p = i / 200;
      final double gi = mpvGainForVolume(mpvVolumeForGain(equalPowerInGain(p)));
      final double go = mpvGainForVolume(
        mpvVolumeForGain(equalPowerOutGain(p)),
      );
      expect(gi * gi + go * go, closeTo(1.0, 1e-6), reason: 'p=$p');
      if (p > 0 && p < 1) {
        expect(gi, greaterThan(0));
        expect(go, greaterThan(0));
      }
    }
    // La entrante ya suena (-6 dB) antes de que la saliente baje de -3 dB.
    final double half = equalPowerInGain(1 / 3);
    expect(half, closeTo(0.5, 1e-9));
    expect(equalPowerOutGain(1 / 3), greaterThan(0.707));
    // Antes: la curva DAWN en la escala cubica dejaba a las dos audibles
    // (>= -12 dB) menos de un cuarto del cruce (~2 s en 8 s); ahora > 60 %
    // del cruce (>= 4 s en 6 s).
    final double oldFrac = _bothAudible(
      (double p) => dawnCrossfadeGain(p) * 100,
      (double p) => dawnCrossfadeGain(1 - p) * 100,
    );
    final double newFrac = _bothAudible(
      (double p) => mpvVolumeForGain(equalPowerInGain(p)),
      (double p) => mpvVolumeForGain(equalPowerOutGain(p)),
    );
    expect(oldFrac * 8000, lessThan(2100));
    expect(newFrac, greaterThan(0.6));
    expect(newFrac * kEqualPowerMinMs, greaterThan(4000));
    // El motor de Live DJ usa la ventana y la curva en Phrase 8 y Stealth.
    final String ld = _read('lib/providers/livedj_provider.dart');
    // 3.1.73 (orden de Gabriel): la ventana ya no se acota a 6-8 s; Phrase 8
    // 12-16 s y Stealth 10-12 s, misma curva cubica.
    expect(ld.contains('wantedFadeMs: fadeOutDurationMs,'), isTrue);
    expect(ld.contains('mpvVolumeForGain(equalPowerInGain(progress))'), isTrue);
    expect(
      ld.contains('mpvVolumeForGain(equalPowerOutGain(progress))'),
      isTrue,
    );
    expect(ld.contains("'mixFormulaV': kMixFormulaSchema"), isTrue);
  });

  test('3171 Mix con Letra: solo Active Beatmatching', () {
    expect(kMixConLetraFormula, MixFormula.dnaEnergy);
    final String am = _read('lib/providers/automix_provider.dart');
    expect(
      am.contains('MixFormula get mixFormula => kMixConLetraFormula;'),
      isTrue,
    );
    expect(am.contains('mixFormulaProvider'), isFalse);
    expect(am.contains('phraseGrid'), isFalse);
    expect(am.contains('stealthGap'), isFalse);
    expect(am.contains('masterLockEntry(fadingBpm, incomingBpm)'), isTrue);
    expect(am.contains('midpointEntry('), isFalse);
    final String engine = _slice(
      am,
      'Future<void> _executeMixEngine({',
      'final MixRunClock fadeClock',
    );
    expect(
      engine.contains("platformOut?.setProperty('audio-pitch-correction'"),
      isFalse,
    );
    expect(
      engine.contains("platformOut?.setProperty('af', outBase());"),
      isFalse,
    );
    final String ui = _read('lib/ui/workspaces/automix_workspace.dart');
    for (final String gone in <String>[
      'PHRASE 8',
      'Phrase 8',
      'STEALTH',
      'Stealth',
      'mixFormulaProvider',
    ]) {
      expect(ui.contains(gone), isFalse, reason: gone);
    }
  });
}
