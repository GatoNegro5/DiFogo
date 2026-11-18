import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mix_formula.dart';
import 'dna_mix.dart' show dnaHighShelfCut, dnaHighpassHard, dnaHighpassMild;
import 'livedj_order.dart' show camelotCompatible, camelotFromPath;
import 'queue_bpm.dart' show knownBpm;

/// 3.1.73: efecto DJ del cruce elegido por genero / perfil acustico.
/// Todos usan las mismas cadenas `af` de mpv que ya existian (equalizer y
/// aecho) y solo tocan la saliente (A) despues de que B ya suena.
enum GenreMixFx {
  none,
  bassSwapAir,
  highpassSweep,
  warmLowPassSilk,
  filterDropEcho,
}

/// Perfil del cruce: la curva (tipo de mezcla) y el efecto.
class GenreMixPlan {
  const GenreMixPlan({
    required this.formula,
    required this.fx,
    required this.reason,
    this.locked = false,
  });

  final MixFormula formula;
  final GenreMixFx fx;

  /// Por que se eligio (genero, dBPM, armonia): solo informativo.
  final String reason;

  /// true: el usuario fijo el tipo de mezcla; el selector no lo cambia.
  final bool locked;
}

/// Diferencia de BPM desde la que se usa Filter Drop / Echo Tail.
const double kGenreFxBpmJump = 18;

/// 3.1.73: true cuando el usuario eligio a mano el tipo de mezcla. El
/// selector automatico respeta esa curva (solo pone el efecto) hasta que se
/// vuelve a encender AUTO tocando el badge FX.
final mixFormulaLockedProvider = StateProvider<bool>((ref) => false);

const List<String> _urbanWords = <String>[
  'urbano',
  'reggaeton',
  'regueton',
  'reguetón',
  'reggaetón',
  'perreo',
  'dembow',
  'trap',
  'tropical',
  'salsa',
  'cumbia',
  'merengue',
  'bachata',
  'fiesta',
  'chicha',
  'tecnocumbia',
];
const List<String> _phraseWords = <String>[
  'ochenta',
  '80s',
  "80's",
  'electronica',
  'electrónica',
  'house',
  'techno',
  'edm',
  'pop dance',
  'dance',
  'rock',
  'disco',
];
const List<String> _softWords = <String>[
  'balada',
  'romantic',
  'acustic',
  'acoustic',
  'unplugged',
  'bolero',
  'lento',
];

String _lower(String? s) => (s ?? '').toLowerCase().replaceAll('\\', '/');

bool _hasAny(String text, List<String> words) {
  for (final String w in words) {
    if (text.contains(w)) return true;
  }
  return false;
}

/// Grupo de genero del cruce: estacion activa primero, luego el texto de la
/// ruta de las dos pistas (carpeta y nombre).
String genreMixGroup({String? stationKey, String? outPath, String? inPath}) {
  switch (stationKey) {
    case 'tropical':
    case 'fiesta':
    case 'nacional':
      return 'urbano';
    case 'ochenteras':
    case 'rock':
      return 'phrase';
    case 'baladas':
      return 'soft';
  }
  final String text = '${_lower(outPath)} ${_lower(inPath)}';
  if (_hasAny(text, _softWords)) return 'soft';
  if (_hasAny(text, _urbanWords)) return 'urbano';
  if (_hasAny(text, _phraseWords)) return 'phrase';
  if (stationKey == 'momento') return 'urbano';
  return '';
}

/// 3.1.73 Selector de transicion: curva + efecto por genero / dBPM / armonia.
///
/// - dBPM > 18: Stealth + Filter Drop / Echo Tail.
/// - Baladas, finales suaves o armonia lejana: Stealth + Warm Low-Pass Silk.
/// - Urbano / Reggaeton / Tropical / Fiesta: Active Beatmatching + Bass-Swap + Air.
/// - Ochenteras / Electronica / Pop Dance / Rock: Phrase 8 + barrido pasa-altos.
/// - Sin perfil: la curva actual, sin efecto.
/// Con [locked] la curva es siempre [current]; solo cambia el efecto.
GenreMixPlan pickGenreMix({
  required MixFormula current,
  String? stationKey,
  String? outPath,
  String? inPath,
  double outBpm = 0,
  double inBpm = 0,
  bool harmonicClash = false,
  bool locked = false,
}) {
  final bool bpmKnown = outBpm >= 60 && inBpm >= 60;
  final double delta = bpmKnown ? (outBpm - inBpm).abs() : 0;
  MixFormula formula = current;
  GenreMixFx fx = GenreMixFx.none;
  String reason = '';
  final String group = genreMixGroup(
    stationKey: stationKey,
    outPath: outPath,
    inPath: inPath,
  );
  if (bpmKnown && delta > kGenreFxBpmJump) {
    formula = MixFormula.stealthGap;
    fx = GenreMixFx.filterDropEcho;
    reason = 'ΔBPM ${delta.round()}';
  } else if (group == 'soft' || harmonicClash) {
    formula = MixFormula.stealthGap;
    fx = GenreMixFx.warmLowPassSilk;
    reason = group == 'soft' ? 'suave' : 'armonia';
  } else if (group == 'urbano') {
    formula = MixFormula.dnaEnergy;
    fx = GenreMixFx.bassSwapAir;
    reason = 'urbano';
  } else if (group == 'phrase') {
    formula = MixFormula.phraseGrid;
    fx = GenreMixFx.highpassSweep;
    reason = 'phrase';
  }
  return GenreMixPlan(
    formula: locked ? current : formula,
    fx: fx,
    reason: reason,
    locked: locked,
  );
}

String genreMixFxLabel(GenreMixFx fx) {
  switch (fx) {
    case GenreMixFx.none:
      return 'SIN FX';
    case GenreMixFx.bassSwapAir:
      return 'BASS-SWAP + AIR';
    case GenreMixFx.highpassSweep:
      return 'HIGHPASS SWEEP';
    case GenreMixFx.warmLowPassSilk:
      return 'WARM LOW-PASS SILK';
    case GenreMixFx.filterDropEcho:
      return 'FILTER DROP / ECHO TAIL';
  }
}

/// Texto del badge en AutomixDj, p. ej. FX PHRASE 8 + HIGHPASS SWEEP AUTO.
String genreMixBadge(GenreMixPlan plan, String formulaLabel) =>
    'FX · $formulaLabel + ${genreMixFxLabel(plan.fx)}'
    ' · ${plan.locked ? 'FIJO' : 'AUTO'}';

/// Pasa-bajos calido aproximado (sin filtro nuevo): recorta agudos en dos
/// bandas, mas fuerte que [dnaHighShelfCut].
const String genreWarmLowPassHard =
    'equalizer=f=3500:width_type=o:w=1.4:g=-10,'
    'equalizer=f=7000:width_type=o:w=1.2:g=-16,'
    'equalizer=f=11000:width_type=o:w=1:g=-12';

/// Momento (progreso 0-1 del cruce) de cada etapa del efecto. La etapa 1
/// nunca empieza antes del 25 %: B ya suena y A no cambia antes de la
/// ventana real.
double genreFxStageAt(GenreMixFx fx, int stage) {
  if (fx == GenreMixFx.none) return 2;
  if (stage <= 1) return 0.25;
  switch (fx) {
    case GenreMixFx.bassSwapAir:
    case GenreMixFx.filterDropEcho:
      return 0.5;
    case GenreMixFx.highpassSweep:
    case GenreMixFx.warmLowPassSilk:
      return 0.6;
    case GenreMixFx.none:
      return 2;
  }
}

/// Cadena extra (sin la base del ecualizador) de la saliente en cada etapa.
/// [bassKill] es el corte de graves del Bass-Swap y [echo] el `aecho` ya
/// validado (vacio si mpv no trae aecho).
String genreFxChain(
  GenreMixFx fx,
  int stage, {
  required String bassKill,
  String echo = '',
}) {
  String join(List<String> parts) =>
      parts.where((String s) => s.isNotEmpty).join(',');
  switch (fx) {
    case GenreMixFx.none:
      return '';
    case GenreMixFx.bassSwapAir:
      return stage <= 1
          ? dnaHighpassMild
          : join(<String>[bassKill, dnaHighpassMild]);
    case GenreMixFx.highpassSweep:
      return stage <= 1 ? dnaHighpassMild : dnaHighpassHard;
    case GenreMixFx.warmLowPassSilk:
      return stage <= 1 ? dnaHighShelfCut : genreWarmLowPassHard;
    case GenreMixFx.filterDropEcho:
      return stage <= 1
          ? dnaHighpassMild
          : join(<String>[dnaHighpassHard, echo]);
  }
}

/// Retardo del Echo Tail: un golpe de la saliente (o 375 ms sin BPM).
int genreEchoDelayMs(double outBpm) =>
    outBpm >= 60 && outBpm <= 200 ? (60000.0 / outBpm).round() : 375;

/// Plan del cruce [outPath] -> [inPath] con el BPM conocido y la clave
/// Camelot del nombre. Lo usan el motor (al mezclar) y el badge (antes).
GenreMixPlan genrePlanForPaths({
  required MixFormula current,
  String? stationKey,
  String? outPath,
  String? inPath,
  bool locked = false,
}) {
  final String? ka = outPath == null ? null : camelotFromPath(outPath);
  final String? kb = inPath == null ? null : camelotFromPath(inPath);
  return pickGenreMix(
    current: current,
    stationKey: stationKey,
    outPath: outPath,
    inPath: inPath,
    outBpm: outPath == null ? 0 : knownBpm(outPath),
    inBpm: inPath == null ? 0 : knownBpm(inPath),
    harmonicClash: ka != null && kb != null && !camelotCompatible(ka, kb),
    locked: locked,
  );
}

/// 3.1.84: minimo de juego que debe quedar antes del punto de mezcla que
/// recalcula el selector AUTO al terminar un cruce. Sin esto el punto podia
/// quedar 1,5 s por delante y disparar un segundo cruce a los 10-15 s.
const int kAutoCurveMinLeadMs = 30000;

/// 3.1.84: punto de mezcla tras el recalculo AUTO de la curva. Solo se
/// acepta [recalculatedMs] si deja al menos [kAutoCurveMinLeadMs] de juego;
/// si no, se conserva [currentMixOutMs] (el que fijo el cruce).
int autoCurveMixOutMs({
  required int recalculatedMs,
  required int positionMs,
  required int currentMixOutMs,
}) {
  if (recalculatedMs > 10000 &&
      recalculatedMs >= positionMs + kAutoCurveMinLeadMs) {
    return recalculatedMs;
  }
  return currentMixOutMs;
}
