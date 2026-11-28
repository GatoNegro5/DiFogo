import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/dna_mix.dart';
import 'package:difogo/core/fiesta_set_mix.dart';
import 'package:difogo/core/genre_mix_fx.dart';
import 'package:difogo/core/phrase_grid.dart';
import 'package:difogo/providers/mix_formula.dart';

PhraseTrack _grid({
  required double bpm,
  required int durationMs,
  required int introEndMs,
  int outroMs = -1,
  required List<PhrasePhrase> phrases,
  double bodyRms = 0.15,
}) {
  return PhraseTrack(
    bpm: bpm,
    beatMs: 0,
    durationMs: durationMs,
    outroMs: outroMs,
    introEndMs: introEndMs,
    bodyRms: bodyRms,
    phrases: phrases,
  );
}

List<PhrasePhrase> _everyPhrase(
  int durationMs,
  int phraseMs, {
  int hookAt = -1,
}) {
  final List<PhrasePhrase> out = <PhrasePhrase>[];
  for (int t = 0; t + phraseMs <= durationMs; t += phraseMs) {
    final bool hook = hookAt >= 0 && t == hookAt;
    out.add(
      PhrasePhrase(
        startMs: t,
        rms: hook ? 0.28 : 0.12,
        vocal: hook || t >= hookAt && hookAt >= 0 ? 0.6 : 0.2,
      ),
    );
  }
  return out;
}

void main() {
  test('Fiesta: duracion por tema entre 60 y 120 s y corte en frase', () {
    const double bpm = 128;
    const int dur = 240000;
    final int phrase = fiestaPhraseMs(128, bars: 8);
    expect(phrase, 15000);
    final int intro = phrase * 2; // 30 s
    final int hook = phrase * 2; // primer coro al fin de intro
    final PhraseTrack track = _grid(
      bpm: bpm,
      durationMs: dur,
      introEndMs: intro,
      phrases: _everyPhrase(dur, phrase, hookAt: hook),
    );
    final FiestaPlayWindow w = planFiestaWindow(
      durationMs: dur,
      bpm: bpm,
      track: track,
      energyLevel: 5,
    );
    expect(w.cueInMs, hook);
    expect(w.playMs, inInclusiveRange(kFiestaMinPlayMs, kFiestaMaxPlayMs));
    expect(w.mixOutMs, lessThan(dur));
    expect((w.mixOutMs - w.cueInMs) % phrase, 0);
    expect(track.hitsDownbeat(w.mixOutMs), isTrue);
    expect(w.mixOutMs, greaterThan(w.cueInMs));
  });

  test('Fiesta: lyrStartMs de marca GMX si no hay hook de frase', () {
    const double bpm = 120;
    const int dur = 200000;
    final int phrase = fiestaPhraseMs(120, bars: 8);
    final PhraseTrack track = _grid(
      bpm: bpm,
      durationMs: dur,
      introEndMs: -1,
      phrases: _everyPhrase(dur, phrase, hookAt: -1),
    );
    final FiestaPlayWindow w = planFiestaWindow(
      durationMs: dur,
      bpm: bpm,
      track: track,
      lyrStartMs: phrase * 2,
      energyLevel: 8,
    );
    expect(w.cueInMs, phrase * 2);
    expect(w.playMs, inInclusiveRange(kFiestaMinPlayMs, kFiestaMaxPlayMs));
    expect((w.mixOutMs - 0) % phrase, 0);
  });

  test('Fiesta: variedad de FX en un set de 8 cruces', () {
    final List<GenreMixFx> fx = <GenreMixFx>[
      pickFiestaFx(outBpm: 100, inBpm: 128), // salto BPM -> echo
      pickFiestaFx(outEnergy: 4, inEnergy: 8), // subida -> HP
      pickFiestaFx(outEnergy: 8, inEnergy: 3), // bajada -> LP
      pickFiestaFx(
        subgenreChange: true,
        outEnergy: 5,
        inEnergy: 5,
      ), // bass swap
      pickFiestaFx(outBpm: 126, inBpm: 128, outEnergy: 6, inEnergy: 6),
      pickFiestaFx(
        outBpm: 90,
        inBpm: 120,
        subgenreChange: true,
        outEnergy: 7,
        inEnergy: 4,
      ),
      pickFiestaFx(outBpm: 122, inBpm: 120, outEnergy: 3, inEnergy: 7),
      pickFiestaFx(
        outBpm: 110,
        inBpm: 112,
        subgenreChange: true,
        outEnergy: 4,
        inEnergy: 7,
      ),
    ];
    expect(fx.toSet().length, greaterThanOrEqualTo(3), reason: 'fx=$fx');
    expect(fx.contains(GenreMixFx.filterDropEcho), isTrue);
    expect(fx.contains(GenreMixFx.highpassSweep), isTrue);
    expect(
      fx.contains(GenreMixFx.bassSwapAir) ||
          fx.contains(GenreMixFx.warmLowPassSilk),
      isTrue,
    );
    expect(fiestaBpmCompatible(128, 124), isTrue);
    expect(fiestaBpmCompatible(128, 100), isFalse);
  });

  test('Guardian: Automix y Radio no cambian curva ni FX AUTO', () {
    // AUTO (locked false) sigue limpiando FX DJ, como 3.1.97.
    final GenreMixPlan auto = genrePlanForPaths(
      current: MixFormula.dnaEnergy,
      stationKey: 'rock',
      outPath: r'C:\Musica\ReGenial\Rock\A.mp3',
      inPath: r'C:\Musica\ReGenial\Rock\B.mp3',
      locked: false,
    );
    expect(auto.fx, GenreMixFx.none);
    expect(auto.locked, isFalse);

    final GenreMixPlan radio = genrePlanForPaths(
      current: MixFormula.dnaEnergy,
      stationKey: 'tropical',
      outPath: r'C:\Musica\ReGenial\Salsa\A.mp3',
      inPath: r'C:\Musica\ReGenial\Salsa\B.mp3',
      locked: false,
    );
    expect(radio.fx, GenreMixFx.none);

    // El techo 60-80 % de Automix/Radio sigue igual.
    expect(
      dnaCapMixOut(durationMs: 200000, mixOutMs: 180000, fadeMs: 16000),
      144000,
    );
    expect(
      dnaCapMixOut(durationMs: 200000, mixOutMs: 120000, fadeMs: 16000),
      120000,
    );

    // Phrase 8 sin perfil conserva el fallback (salida larga, no 60-120 s).
    final PhrasePlan p = planPhrase8(
      outDurationMs: 240000,
      inDurationMs: 240000,
      fallbackMixOutMs: 144000,
      fallbackCueMs: 15000,
      incomingBpm: 128,
      incomingRate: 1,
    );
    expect(p.mixOutMs, 144000);
    expect(p.cueInMs, 15000);
  });
}
