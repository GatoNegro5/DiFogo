import 'dart:math' as math;

import 'genre_mix_fx.dart';
import 'phrase_grid.dart';
import '../providers/mix_formula.dart';

/// 3.2.39 DIF-38: ventana corta de Fiesta (60-120 s) y FX del cruce.
/// Automix y Radio no usan este modulo.

const int kFiestaMinPlayMs = 60000;
const int kFiestaMaxPlayMs = 120000;

/// PreRoll mas corto: el tema suena poco y hay que armar el cruce antes.
const int kFiestaPreRollFloorMs = 8000;

class FiestaPlayWindow {
  const FiestaPlayWindow({
    required this.cueInMs,
    required this.mixOutMs,
    required this.playMs,
    required this.phraseBars,
  });

  final int cueInMs;
  final int mixOutMs;
  final int playMs;
  final int phraseBars;
}

/// Compas 4/4 en ms. Sin BPM musical se asume 120.
int fiestaBarMs(double bpm) {
  final double b = (bpm >= 60 && bpm <= 200) ? bpm : 120;
  return ((60000.0 / b) * 4).round();
}

/// 8 o 16 compases, segun el BPM: 16 si un bloque de 8 queda bajo 10 s.
int fiestaPhraseBars(double bpm) {
  final int eight = fiestaBarMs(bpm) * 8;
  return eight < 10000 ? 16 : 8;
}

int fiestaPhraseMs(double bpm, {int? bars}) =>
    fiestaBarMs(bpm) * (bars ?? fiestaPhraseBars(bpm));

/// Fundido del cruce de Fiesta: el de Phrase 8 ya existente (8-18 s).
int fiestaFadeMs(double bpm, {int durationMs = 0}) => phraseGridFadeMs(
  bpm: (bpm >= 60 && bpm <= 200) ? bpm : 120,
  instrumental: false,
  durationMs: durationMs,
);

/// Duracion objetivo 60-120 s: mas energia, corte mas corto (set de DJ).
int fiestaTargetPlayMs({required double bpm, int? energyLevel}) {
  final int bar8 = fiestaBarMs(bpm) * 8;
  final int e = (energyLevel ?? 5).clamp(1, 10);
  final int raw =
      (kFiestaMaxPlayMs - (e - 1) * (kFiestaMaxPlayMs - kFiestaMinPlayMs) / 9)
          .round();
  if (bar8 <= 0) return raw.clamp(kFiestaMinPlayMs, kFiestaMaxPlayMs);
  int n = math.max(1, (raw / bar8).round());
  int ms = n * bar8;
  while (ms < kFiestaMinPlayMs) {
    n++;
    ms = n * bar8;
  }
  while (ms > kFiestaMaxPlayMs && n > 1) {
    n--;
    ms = n * bar8;
  }
  return ms.clamp(kFiestaMinPlayMs, kFiestaMaxPlayMs);
}

/// Ajusta [raw] hacia abajo a un limite de frase (inicio de frase o rejilla
/// de 8/16 compases) dentro de [lo, hi].
int fiestaSnapExit({
  required int raw,
  required double bpm,
  required int lo,
  required int hi,
  PhraseTrack? track,
  int? bars,
}) {
  final int low = lo <= hi ? lo : hi;
  final int high = lo <= hi ? hi : lo;
  final int phraseBars = bars ?? fiestaPhraseBars(bpm);
  if (track != null && track.phrases.isNotEmpty) {
    int? best;
    for (final PhrasePhrase p in track.phrases) {
      if (p.startMs >= low && p.startMs <= high && p.startMs <= raw) {
        best = p.startMs;
      }
    }
    if (best != null) return best;
  }
  final int grid = fiestaBarMs(bpm) * phraseBars;
  if (grid <= 0) return raw.clamp(low, high);
  final int origin = (track != null && track.beatMs >= 0) ? track.beatMs : 0;
  int snapped = origin + ((raw - origin) ~/ grid) * grid;
  if (snapped < low) {
    snapped = origin + ((low - origin + grid - 1) ~/ grid) * grid;
  }
  if (snapped > high) {
    snapped = origin + ((high - origin) ~/ grid) * grid;
  }
  return snapped.clamp(low, high);
}

/// Entra cerca del primer coro/hook: frase vocal con energia tras la intro,
/// o el fin de intro, o [lyrStartMs] (marca GMX de letra), o 16 compases.
int fiestaCueInMs({
  required int durationMs,
  required double bpm,
  PhraseTrack? track,
  int? lyrStartMs,
  int fadeMs = 8000,
}) {
  if (durationMs <= 0) return 0;
  final int need = kFiestaMinPlayMs + fadeMs;
  final int latest = durationMs - need;
  if (latest <= 0) return 0;

  final int intro = track?.introEndMs ?? -1;
  final int after = intro > 0 ? intro : 0;
  if (track != null && track.phrases.isNotEmpty) {
    PhrasePhrase? hook;
    for (final PhrasePhrase p in track.phrases) {
      if (p.startMs < after || p.startMs > latest) continue;
      if (p.vocalOn && p.rms >= track.bodyRms * 0.9) {
        hook = p;
        break;
      }
    }
    hook ??= () {
      for (final PhrasePhrase p in track.phrases) {
        if (p.startMs >= after && p.startMs <= latest && p.vocalOn) {
          return p;
        }
      }
      return null;
    }();
    if (hook != null) return hook.startMs;
  }
  if (intro > 0 && intro <= latest) {
    return fiestaSnapExit(
      raw: intro,
      bpm: bpm,
      lo: 0,
      hi: latest,
      track: track,
    );
  }
  if (lyrStartMs != null && lyrStartMs > 0 && lyrStartMs <= latest) {
    return fiestaSnapExit(
      raw: lyrStartMs,
      bpm: bpm,
      lo: 0,
      hi: latest,
      track: track,
    );
  }
  final int fb = fiestaPhraseMs(bpm, bars: 16);
  return fb.clamp(0, latest);
}

FiestaPlayWindow planFiestaWindow({
  required int durationMs,
  required double bpm,
  PhraseTrack? track,
  int? energyLevel,
  int? lyrStartMs,
}) {
  final int fade = fiestaFadeMs(bpm, durationMs: durationMs);
  var cue = fiestaCueInMs(
    durationMs: durationMs,
    bpm: bpm,
    track: track,
    lyrStartMs: lyrStartMs,
    fadeMs: fade,
  );
  final int target = fiestaTargetPlayMs(bpm: bpm, energyLevel: energyLevel);
  final int phraseBars = fiestaPhraseBars(bpm);
  if (durationMs <= 0) {
    return FiestaPlayWindow(
      cueInMs: 0,
      mixOutMs: target,
      playMs: target,
      phraseBars: phraseBars,
    );
  }

  final int latestOut = math.max(0, durationMs - fade);
  // Si no cabe el minimo despues del cue, se adelanta la entrada.
  if (cue + kFiestaMinPlayMs > latestOut) {
    cue = math.max(0, latestOut - kFiestaMinPlayMs);
  }

  int lo = cue + kFiestaMinPlayMs;
  int hi = math.min(cue + kFiestaMaxPlayMs, latestOut);
  if (lo > hi) {
    lo = math.min(cue + math.max(8000, fiestaPhraseMs(bpm)), latestOut);
    hi = latestOut;
    if (lo > hi) lo = hi;
  }

  int raw = cue + target;
  final int outro = track?.outroMs ?? -1;
  if (outro >= lo && outro <= hi) raw = outro;
  final int mixOut = fiestaSnapExit(
    raw: raw,
    bpm: bpm,
    lo: lo,
    hi: hi,
    track: track,
    bars: phraseBars,
  );
  return FiestaPlayWindow(
    cueInMs: cue,
    mixOutMs: mixOut,
    playMs: math.max(0, mixOut - cue),
    phraseBars: phraseBars,
  );
}

/// BPM lo bastante cerca para beatmatch (8 % relativo).
bool fiestaBpmCompatible(double outBpm, double inBpm) {
  if (outBpm < 60 || inBpm < 60) return false;
  final double lo = outBpm < inBpm ? outBpm : inBpm;
  return (outBpm - inBpm).abs() / lo <= 0.08;
}

/// Efecto del cruce de Fiesta. Reutiliza [GenreMixFx] (HP/LP, eco, bass-swap).
/// No hay riser ni backspin en el DSP actual: no se toca el FFI.
GenreMixFx pickFiestaFx({
  double outBpm = 0,
  double inBpm = 0,
  int? outEnergy,
  int? inEnergy,
  bool subgenreChange = false,
}) {
  final bool bpmKnown = outBpm >= 60 && inBpm >= 60;
  final double dBpm = bpmKnown ? (outBpm - inBpm).abs() : 0;
  final int outE = outEnergy ?? 5;
  final int inE = inEnergy ?? 5;
  final int dE = (outE - inE).abs();
  final bool energyUp = inE > outE;
  if (bpmKnown && dBpm > kGenreFxBpmJump) {
    return GenreMixFx.filterDropEcho;
  }
  if (subgenreChange && dE >= 2) {
    return energyUp ? GenreMixFx.highpassSweep : GenreMixFx.filterDropEcho;
  }
  if (dE >= 3) {
    return energyUp ? GenreMixFx.highpassSweep : GenreMixFx.warmLowPassSilk;
  }
  if (subgenreChange) return GenreMixFx.bassSwapAir;
  if (energyUp) return GenreMixFx.highpassSweep;
  if (inE < outE) return GenreMixFx.warmLowPassSilk;
  return GenreMixFx.bassSwapAir;
}

/// Curva + FX de Fiesta. [locked] queda en false: el motor pasa djFx: true
/// solo en este modo, sin fijar la curva del usuario.
GenreMixPlan fiestaMixPlan({
  required MixFormula current,
  double outBpm = 0,
  double inBpm = 0,
  int? outEnergy,
  int? inEnergy,
  bool subgenreChange = false,
}) {
  final GenreMixFx fx = pickFiestaFx(
    outBpm: outBpm,
    inBpm: inBpm,
    outEnergy: outEnergy,
    inEnergy: inEnergy,
    subgenreChange: subgenreChange,
  );
  final MixFormula formula = fiestaBpmCompatible(outBpm, inBpm)
      ? MixFormula.dnaEnergy
      : MixFormula.phraseGrid;
  return GenreMixPlan(
    formula: formula,
    fx: fx,
    reason: subgenreChange ? 'fiesta-sub' : 'fiesta',
    locked: false,
  );
}

/// Cambio de subgenero aproximado: distinta carpeta padre.
bool fiestaSubgenreChanged(String? outPath, String? inPath) {
  if (outPath == null || inPath == null) return false;
  if (outPath.isEmpty || inPath.isEmpty) return false;
  final int a = outPath.replaceAll('/', '\\').lastIndexOf('\\');
  final int b = inPath.replaceAll('/', '\\').lastIndexOf('\\');
  if (a <= 0 || b <= 0) return false;
  final String da = outPath.substring(0, a).toLowerCase();
  final String db = inPath.substring(0, b).toLowerCase();
  return da != db;
}
