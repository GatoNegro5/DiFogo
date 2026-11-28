import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/audio/tempo_drift.dart';
import 'package:difogo/core/exact_mix.dart';
import 'package:difogo/core/genre_mix_fx.dart';
import 'package:difogo/core/livedj_next.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/mix_formula.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/workspaces/livedj_dj_sheet.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';

// 3.1.73: Phrase 8 sin secuencial ni segundo reorden, ventanas largas
// (Phrase 8 12-16 s, Stealth 10-12 s) con compensacion cubica de mpv y
// selector de curva + FX por genero / dBPM con badge. Sin red ni audio.

class _Live extends LiveDjNotifier {
  _Live(this.seed);
  final LiveDjState seed;
  @override
  LiveDjState build() => seed;
}

final String _sep = Platform.pathSeparator;

String _read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

String _slice(String src, String from, String to) {
  final int a = src.indexOf(from);
  final int b = src.indexOf(to, a < 0 ? 0 : a);
  if (a < 0 || b < 0) return '';
  return src.substring(a, b);
}

/// Cruce simulado en ticks de 32 ms con la curva Equal-Power pasada a la
/// escala cubica de mpv (como el motor). Devuelve (solape ms, min potencia,
/// max potencia) con la amplitud real que sale de cada deck.
({int overlapMs, double minPow, double maxPow}) _simulate(int fadeMs) {
  int overlap = 0;
  double minPow = 9, maxPow = 0;
  for (int t = 0; t < fadeMs; t += 32) {
    final double p = (t / fadeMs).clamp(0.0, 1.0);
    final double gIn = mpvGainForVolume(mpvVolumeForGain(equalPowerInGain(p)));
    final double gOut = mpvGainForVolume(
      mpvVolumeForGain(equalPowerOutGain(p)),
    );
    final double pow2 = gIn * gIn + gOut * gOut;
    minPow = min(minPow, pow2);
    maxPow = max(maxPow, pow2);
    // A suena desde el inicio; B desde el primer tick. Solape = mientras
    // A tiene ganancia y B ya entro.
    if (gOut > 0 && (gIn > 0 || t == 0)) overlap += min(32, fadeMs - t);
  }
  return (overlapMs: overlap, minPow: minPow, maxPow: maxPow);
}

void main() {
  test('3173 Phrase 8 no fuerza secuencial ni reordena dos veces', () {
    expect(mixFormulaMayReorderQueue(MixFormula.phraseGrid), isFalse);
    expect(mixFormulaMayReorderQueue(MixFormula.dnaEnergy), isTrue);
    expect(mixFormulaMayReorderQueue(MixFormula.stealthGap), isTrue);
    // Phrase 8 toma la cabeza de la cola del Shuffle tal cual.
    final List<String> shuffled = <String>['c.mp3', 'a.mp3', 'b.mp3'];
    expect(offAirNextIndex(paths: shuffled, currentPath: 'x.mp3'), 0);
    final String ld = _read('lib/providers/livedj_provider.dart');
    final String reorder = _slice(
      ld,
      'void _backfillReorder() {',
      'final List<File>? ordered',
    );
    expect(
      reorder.contains(
        'if (!mixFormulaMayReorderQueue(ref.read(mixFormulaProvider))) return;',
      ),
      isTrue,
    );
    // Cambiar a Phrase 8 no toca el modo ni la cola.
    final String listen = _slice(
      ld,
      'ref.listen<MixFormula>(mixFormulaProvider',
      'ref.onDispose(',
    );
    expect(listen, isNotEmpty);
    for (final String bad in <String>[
      'sequential',
      'shuffle',
      'mixStrategy',
      'queue:',
      '_applySort',
    ]) {
      expect(listen.contains(bad), isFalse, reason: bad);
    }
  });

  test('3173 ventanas: Phrase 8 12-16 s en 32 golpes, Stealth 10-12 s, '
      'potencia sumada sin bajon', () {
    expect(phrase8WindowMs(128), 15000); // 32 golpes exactos
    expect(phrase8WindowMs(140), (60000 / 140 * 32).round());
    expect(phrase8WindowMs(0), 14000);
    for (double bpm = 60; bpm <= 200; bpm += 1) {
      final int ph = phrase8WindowMs(bpm);
      final int st = stealthWindowMs(bpm);
      expect(ph, inInclusiveRange(12000, 16000));
      expect(st, inInclusiveRange(10000, 12000));
    }
    for (final (int fade, int minOverlap) in <(int, int)>[
      (phrase8WindowMs(200), 12000),
      (phrase8WindowMs(128), 12000),
      (stealthWindowMs(200), 10000),
      (stealthWindowMs(90), 10000),
    ]) {
      final r = _simulate(fade);
      expect(r.overlapMs, greaterThanOrEqualTo(minOverlap), reason: '$fade');
      expect(r.minPow, greaterThan(0.99), reason: 'sin bajon $fade');
      expect(r.maxPow, lessThan(1.01), reason: 'sin pico $fade');
    }
    // La ventana larga cabe entera: el punto de mezcla se adelanta y el
    // fundido no se recorta (A no se corta al final).
    const int dur = 200000;
    final int capped = extendedMixOutCap(
      durationMs: dur,
      mixOutMs: 195000,
      windowMs: kPhrase8MaxMs,
    );
    expect(capped, dur - kPhrase8MaxMs - kMixTailMarginMs);
    final FittedFade ok = fitMixFade(
      exactDurationMs: dur,
      mixOutMs: capped,
      wantedFadeMs: phrase8WindowMs(128),
    );
    expect(ok.shortened, isFalse);
    expect(ok.fadeMs, 15000);
    expect(
      fitMixFade(
        exactDurationMs: dur,
        mixOutMs: 195000,
        wantedFadeMs: 15000,
      ).shortened,
      isTrue,
    );
    expect(
      extendedMixOutCap(durationMs: dur, mixOutMs: 120000, windowMs: 16000),
      120000,
    );
    expect(
      extendedMixOutCap(durationMs: 30000, mixOutMs: 29000, windowMs: 16000),
      15000,
    );
    // Fuentes: Phrase 8 / Stealth con su ventana larga y la curva cubica en
    // toda la rampa; DAWN de Active Beatmatching sin cambio.
    final String ld = _read('lib/providers/livedj_provider.dart');
    // 3.2.39: Fiesta usa fiestaFadeMs; Phrase 8 de Automix/Radio sigue igual.
    expect(ld.contains('phrase8WindowMs('), isTrue);
    expect(ld.contains('_isFiestaMix()'), isTrue);
    expect(ld.contains('fiestaFadeMs('), isTrue);
    expect(ld.contains('? stealthWindowMs('), isTrue);
    expect(ld.contains('wantedFadeMs: fadeOutDurationMs,'), isTrue);
    expect(ld.contains('equalPowerFadeMs(fadeOutDurationMs)'), isFalse);
    expect(ld.contains('mpvVolumeForGain(equalPowerInGain(progress))'), isTrue);
    expect(
      ld.contains('mpvVolumeForGain(equalPowerOutGain(progress))'),
      isTrue,
    );
    expect(ld.contains(': dawnCrossfadeGain(progress) * 100.0'), isTrue);
    expect(ld.contains(': dawnCrossfadeGain(1.0 - progress) * 100.0'), isTrue);
    expect(ld.contains('windowMs: kPhrase8MaxMs'), isTrue);
    expect(ld.contains('windowMs: kStealthMaxMs'), isTrue);
  });

  test('3173 selector: curva + FX por genero / dBPM / armonia', () {
    GenreMixPlan p(String? st, {double a = 0, double b = 0, String? o}) =>
        pickGenreMix(
          current: MixFormula.dnaEnergy,
          stationKey: st,
          outPath: o,
          outBpm: a,
          inBpm: b,
        );
    expect(p('tropical').formula, MixFormula.dnaEnergy);
    expect(p('tropical').fx, GenreMixFx.bassSwapAir);
    expect(p('fiesta').fx, GenreMixFx.bassSwapAir);
    expect(p(null, o: '/m/Reggaeton/x.mp3').fx, GenreMixFx.bassSwapAir);
    expect(p('ochenteras').formula, MixFormula.phraseGrid);
    expect(p('ochenteras').fx, GenreMixFx.highpassSweep);
    expect(p('rock').fx, GenreMixFx.highpassSweep);
    expect(p(null, o: '/m/Electronica/x.mp3').fx, GenreMixFx.highpassSweep);
    expect(p('baladas').formula, MixFormula.stealthGap);
    expect(p('baladas').fx, GenreMixFx.warmLowPassSilk);
    final GenreMixPlan clash = pickGenreMix(
      current: MixFormula.dnaEnergy,
      harmonicClash: true,
    );
    expect(clash.fx, GenreMixFx.warmLowPassSilk);
    // dBPM > 18 manda sobre el genero.
    final GenreMixPlan jump = p('tropical', a: 100, b: 125);
    expect(jump.formula, MixFormula.stealthGap);
    expect(jump.fx, GenreMixFx.filterDropEcho);
    expect(p('tropical', a: 100, b: 110).fx, GenreMixFx.bassSwapAir);
    // Sin perfil: curva actual y sin efecto.
    final GenreMixPlan none = p(null, o: '/m/Varios/x.mp3');
    expect(none.formula, MixFormula.dnaEnergy);
    expect(none.fx, GenreMixFx.none);
    // Curva fijada por el usuario: solo cambia el efecto.
    final GenreMixPlan locked = pickGenreMix(
      current: MixFormula.phraseGrid,
      stationKey: 'baladas',
      locked: true,
    );
    expect(locked.formula, MixFormula.phraseGrid);
    expect(locked.fx, GenreMixFx.warmLowPassSilk);
    expect(locked.locked, isTrue);
    // Etapas: nunca antes del 25 % (B ya suena); solo cadenas mpv conocidas.
    for (final GenreMixFx fx in GenreMixFx.values) {
      if (fx == GenreMixFx.none) {
        expect(genreFxChain(fx, 1, bassKill: 'k'), isEmpty);
        continue;
      }
      expect(genreFxStageAt(fx, 1), greaterThanOrEqualTo(0.25));
      expect(genreFxStageAt(fx, 2), greaterThan(genreFxStageAt(fx, 1)));
      for (final int st in <int>[1, 2]) {
        final String chain = genreFxChain(
          fx,
          st,
          bassKill: 'equalizer=f=45:width_type=o:w=2.5:g=-24',
          echo: 'aecho=0.8:0.88:469:0.35',
        );
        expect(chain, isNotEmpty);
        for (final String part in chain.split(',')) {
          expect(
            part.startsWith('equalizer=') || part.startsWith('aecho='),
            isTrue,
            reason: part,
          );
        }
      }
    }
    expect(genreEchoDelayMs(128), 469);
    expect(
      genreMixBadge(p('ochenteras'), 'PHRASE 8'),
      'FX · PHRASE 8 + HIGHPASS SWEEP · AUTO',
    );
    expect(genreMixBadge(locked, 'PHRASE 8'), contains('FIJO'));
    // Motor: el FX solo toca la saliente, tras el 25 % y si no hay DNA.
    final String ld = _read('lib/providers/livedj_provider.dart');
    final String fxBlock = _slice(
      ld,
      'if (genreFx != GenreMixFx.none &&',
      '// 3.1.20: respeta la rampa',
    );
    expect(fxBlock.contains('dnaOutExtra == null'), isTrue);
    expect(fxBlock.contains('volIn > 0'), isTrue);
    expect(fxBlock.contains('platformIn'), isFalse);
    expect(fxBlock.contains('setRate'), isFalse);
  });

  testWidgets('3173 badge FX en AutomixDj (hoja Modo DJ, 3.1.84)', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final Directory tmp = Directory.systemTemp.createTempSync('gmx_3173_');
    addTearDown(() {
      debugVibeRootOverride = null;
      debugVibeHubScan = null;
      debugTrackGenreIndexPath = null;
      debugVibeStatePath = null;
      debugVibeHubStatePath = null;
      debugStationSessionsPath = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    debugVibeStatePath = '${tmp.path}${_sep}state.json';
    debugVibeHubStatePath = debugVibeStatePath;
    debugStationSessionsPath = '${tmp.path}${_sep}sessions.json';
    final String root = '${tmp.path}${_sep}Musica';
    Directory(root).createSync(recursive: true);
    debugVibeRootOverride = root;
    debugVibeHubScan = (String r) async => const <VibeGenre>[];
    debugTrackGenreIndexPath = '${tmp.path}${_sep}genre_index.json';
    final LiveDjState s = LiveDjState(
      currentTrackPath: '$root${_sep}Electronica${_sep}Uno - Pulso.mp3',
      queue: <File>[File('$root${_sep}Electronica${_sep}Dos - Laser.mp3')],
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 200),
      customMixOutMs: 90000,
    );
    final GenreMixPlan plan = spotifyMixFxPlan(s, MixFormula.dnaEnergy, null);
    expect(plan.formula, MixFormula.phraseGrid);
    // 3.1.97: en AUTO el cruce es limpio; el FX DJ queda para FIJO.
    expect(plan.fx, GenreMixFx.none);
    expect(
      spotifyMixFxPlan(s, MixFormula.dnaEnergy, null, locked: true).fx,
      GenreMixFx.highpassSweep,
    );
    final ProviderContainer c = ProviderContainer(
      overrides: [liveDjProvider.overrideWith(() => _Live(s))],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: LiveDjModeDjPanel())),
      ),
    );
    await t.pump();
    final Finder badge = find.byKey(const Key('dj-fx-badge'));
    expect(badge, findsOneWidget);
    expect(find.text('FX · PHRASE 8 + SIN FX · AUTO'), findsOneWidget);
    await t.tap(badge);
    await t.pump();
    expect(c.read(mixFormulaLockedProvider), isTrue);
    expect(
      find.text('FX · ACTIVE BEATMATCHING + HIGHPASS SWEEP · FIJO'),
      findsOneWidget,
    );
    // Elegir a mano el tipo de mezcla fija la curva.
    c.read(mixFormulaLockedProvider.notifier).state = false;
    await t.tap(find.byKey(const Key('dj-mix-type')));
    await t.pump();
    expect(c.read(mixFormulaLockedProvider), isTrue);
    expect(c.read(mixFormulaProvider), MixFormula.phraseGrid);
    expect(t.takeException(), isNull);
  });
}
