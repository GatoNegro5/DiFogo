import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/dna_mix.dart';
import 'package:difogo/core/phrase_grid.dart';
import 'package:difogo/providers/mix_formula.dart';

// 3.2.22: cue de entrada >= 15 s (<= ~25 s), salida 60 % y techo 80 % con el
// fundido incluido para todos los generos y rutas de AutomixDj.

/// Perfil tipo salsa del folder_cache real: intro=-1, outro=-1, primer golpe
/// a 1,34 s y frases de 8 compases a 93 BPM (~20,6 s).
PhraseTrack _salsa({int durationMs = 240000, int outro = -1}) {
  const double bpm = 93;
  final int phraseMs = ((60000.0 / bpm) * 4).round() * 8;
  return PhraseTrack(
    bpm: bpm,
    beatMs: 1340,
    durationMs: durationMs,
    outroMs: outro,
    introEndMs: -1,
    bodyRms: 0.15,
    phrases: <PhrasePhrase>[
      for (int t = 1340; t < durationMs; t += phraseMs)
        PhrasePhrase(startMs: t, rms: 0.15, vocal: 0.5),
    ],
  );
}

DnaDecision _decide({
  required int outDur,
  required int inDur,
  PhraseTrack? outgoing,
  PhraseTrack? incoming,
  int lead = 0,
  bool locked = false,
  int? genre,
  double bpm = 93,
}) {
  return decideDna(
    outDurationMs: outDur,
    inDurationMs: inDur,
    genreMixOutMs: genre ?? (outDur * kDnaMixBase).toInt(),
    fallbackCueMs: dnaFallbackCueMs(inDur, lead),
    outBpm: bpm,
    inBpm: bpm,
    outKey: '8A',
    inKey: '8A',
    outgoing: outgoing,
    incoming: incoming,
    echoSupported: true,
    eqSupported: true,
    exitLocked: locked,
  );
}

String _src(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

String _body(String src, String from, String to) {
  final int a = src.indexOf(from);
  expect(a, greaterThanOrEqualTo(0), reason: from);
  final int b = src.indexOf(to, a + from.length);
  expect(b, greaterThan(a), reason: to);
  return src.substring(a, b);
}

void main() {
  test('3222 a) 240 s intro=-1 outro=-1: cue 15-25 s, salida 60 %, fin <= 80 %',
      () {
    final PhraseTrack t = _salsa();
    final DnaDecision d = _decide(
      outDur: 240000,
      inDur: 240000,
      outgoing: t,
      incoming: t,
    );
    expect(d.cueInMs, inInclusiveRange(15000, 25000));
    expect(d.cueInMs, isNot(1340));
    expect(d.mixOutMs, greaterThanOrEqualTo(144000));
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(192000));
  });

  test('3222 b) sin perfil: cue 15 s, salida exacta 60 % y 18 s dentro del 80 %',
      () {
    expect(dnaFallbackCueMs(240000, 0), 15000);
    expect(dnaFallbackCueMs(240000, 9000), 15000);
    final DnaDecision d = _decide(outDur: 240000, inDur: 240000);
    expect(d.kind, DnaKind.legacy);
    expect(d.cueInMs, 15000);
    expect(d.mixOutMs, 144000);
    expect(d.fadeMs, 18000);
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(192000));
  });

  test('3222 c) pista corta 75 s: piso proporcional <= 7,5 s', () {
    expect(dnaCueFloorMs(75000), 7500);
    expect(dnaCueFloorMs(200000), 15000);
    expect(dnaCueFloorMs(0), 0);
    expect(dnaFallbackCueMs(75000, 0), 7500);
    final DnaDecision legacy = _decide(outDur: 75000, inDur: 75000);
    expect(legacy.cueInMs, lessThanOrEqualTo(7500));
    final PhraseTrack short = _salsa(durationMs: 75000);
    final DnaDecision d = _decide(
      outDur: 75000,
      inDur: 75000,
      outgoing: short,
      incoming: short,
    );
    expect(d.cueInMs, lessThanOrEqualTo(7500));
    expect(d.cueInMs, greaterThan(0));
    expect(d.mixOutMs, 45000);
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(75000));
  });

  test('3222 d) con beatGrid y sin frase en [15, 25] s el cue cae en compas', () {
    const PhraseTrack grid = PhraseTrack(
      bpm: 120,
      beatMs: 500,
      durationMs: 200000,
      outroMs: -1,
      introEndMs: -1,
      bodyRms: 0.2,
      phrases: <PhrasePhrase>[
        PhrasePhrase(startMs: 500, rms: 0.2, vocal: 0.1),
        PhrasePhrase(startMs: 40500, rms: 0.2, vocal: 0.1),
      ],
    );
    final DnaDecision d = _decide(
      outDur: 200000,
      inDur: 200000,
      outgoing: grid,
      incoming: grid,
      bpm: 120,
    );
    expect(d.cueInMs, 16500);
    expect((d.cueInMs - 500) % 2000, 0);
  });

  test('3222 e) intro en [15, 25] s se respeta; intro corta aplica el piso', () {
    PhraseTrack withIntro(int intro) => PhraseTrack(
      bpm: 120,
      beatMs: 0,
      durationMs: 200000,
      outroMs: -1,
      introEndMs: intro,
      bodyRms: 0.2,
      phrases: const <PhrasePhrase>[
        PhrasePhrase(startMs: 0, rms: 0.05, vocal: 0.1),
        PhrasePhrase(startMs: 48000, rms: 0.2, vocal: 0.1),
      ],
    );
    expect(
      _decide(
        outDur: 200000,
        inDur: 200000,
        incoming: withIntro(18000),
        bpm: 120,
      )
          .cueInMs,
      18000,
    );
    final int short = _decide(
      outDur: 200000,
      inDur: 200000,
      incoming: withIntro(8000),
      bpm: 120,
    ).cueInMs;
    expect(short, inInclusiveRange(15000, 25000));
  });

  test('3222 f) silencio inicial > 15 s se usa tal cual', () {
    expect(dnaFallbackCueMs(240000, 21000), 21000);
    final PhraseTrack t = _salsa();
    final DnaDecision d = _decide(
      outDur: 240000,
      inDur: 240000,
      outgoing: t,
      incoming: t,
      lead: 21000,
    );
    expect(d.cueInMs, 21000);
  });

  test('3222 g) rock 420 s con outro al 95 %: techo 80 % con fundido', () {
    final PhraseTrack rock = _salsa(durationMs: 420000, outro: 399000);
    final DnaDecision d = _decide(
      outDur: 420000,
      inDur: 420000,
      outgoing: rock,
      incoming: rock,
    );
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(336000));
    expect(d.mixOutMs, greaterThanOrEqualTo(252000));

    // Causa del ~98 %: Phrase 8 (ruta de Rock) acepta el outro hasta el 100 %.
    final PhrasePlan plan = planPhrase8(
      outDurationMs: 420000,
      inDurationMs: 420000,
      fallbackMixOutMs: 252000,
      fallbackCueMs: 15000,
      incomingBpm: 93,
      incomingRate: 1,
      outgoing: rock,
      incoming: rock,
    );
    expect(plan.mixOutMs, 399000);
    final int capped = dnaCapMixOut(
      durationMs: 420000,
      mixOutMs: extendedMixOutCap(
        durationMs: 420000,
        mixOutMs: plan.mixOutMs,
        windowMs: kPhrase8MaxMs,
      ),
      fadeMs: kPhrase8MaxMs,
    );
    expect(capped + kPhrase8MaxMs, lessThanOrEqualTo(336000));
    expect(capped, 320000);
  });

  test('3222 h) analisis fallido (sin grid ni punto): igual 60-80 %', () {
    final DnaDecision d = _decide(outDur: 420000, inDur: 0, genre: 0);
    expect(d.kind, DnaKind.legacy);
    expect(d.mixOutMs, 252000);
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(336000));
    expect(dnaCapMixOut(durationMs: 420000, mixOutMs: 0, fadeMs: 18000), 252000);
    expect(
      dnaCapMixOut(durationMs: 420000, mixOutMs: 411000, fadeMs: 18000),
      318000,
    );
    // Mix largo (> 10 min, fundido 4 s): tambien bajo el 80 %.
    expect(
      dnaCapMixOut(durationMs: 720000, mixOutMs: 690000, fadeMs: 4000),
      572000,
    );
    // Sin duracion no se inventa nada.
    expect(dnaCapMixOut(durationMs: 0, mixOutMs: 0, fadeMs: 18000), 0);
  });

  test('3222 i) cruce ya fijado: solo se acorta el fundido hasta el 80 %', () {
    final fit = dnaFitWindow(
      durationMs: 240000,
      mixOutMs: 180000,
      fadeMs: 18000,
      locked: true,
    );
    expect(fit.mixOutMs, 180000);
    expect(fit.fadeMs, 12000);
  });

  test('3222 j) primera pista: seek a customCueInMs solo sin posicion elegida',
      () {
    expect(
      dnaColdStartSeekMs(startPositionMs: 0, cueInMs: 16500, durationMs: 240000),
      16500,
    );
    expect(
      dnaColdStartSeekMs(
        startPositionMs: 45000,
        cueInMs: 16500,
        durationMs: 240000,
      ),
      0,
    );
    expect(
      dnaColdStartSeekMs(startPositionMs: 0, cueInMs: 0, durationMs: 240000),
      0,
    );
    expect(
      dnaColdStartSeekMs(startPositionMs: 0, cueInMs: 9000, durationMs: 8000),
      0,
    );
  });

  test('3222 k) cableado: arranque en frio, clamp unico y base 60 %', () {
    final String ld = _src('lib/providers/livedj_provider.dart');
    final String toggle = _body(
      ld,
      'Future<void> togglePlayPause() async {',
      'Future<void> seek(Duration position) async {',
    );
    expect(toggle.contains('await _coldStartCue(path);'), isTrue);
    final String cold = _body(
      ld,
      'Future<void> _coldStartCue(String path) async {',
      'Future<void> seek(Duration position) async {',
    );
    expect(cold.contains('identical(deck, _activePlayer)'), isTrue);
    expect(cold.contains('dnaColdStartSeekMs('), isTrue);
    expect('deck.seek('.allMatches(cold).length, 1);
    final String raw = _body(
      ld,
      'int _calculateRadioMixOutRaw(int durationMs, String? path) {',
      'DnaDecision _dnaPair({',
    );
    expect(raw.contains('0.80'), isFalse);
    expect(raw.contains('0.75'), isFalse);
    expect(raw.contains('0.65'), isFalse);
    expect(raw.contains('kDnaMixBase'), isTrue);
    expect('dnaCapMixOut('.allMatches(raw).length, 4);
    expect(MixFormula.values.length, 3);
  });
}
