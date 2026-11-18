import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// DNA 60–80 % · Phrase 8 · Stealth (entra 5–10 %, cruza ~60 % sin voz).
/// Prohibido: fade suelto, corte seco, cambio al final de la pista.
enum MixFormula { dnaEnergy, phraseGrid, stealthGap }

final mixFormulaProvider = StateProvider<MixFormula>(
  (ref) => MixFormula.dnaEnergy,
);

/// 3.1.71: Mix con Letra (Automix) mezcla solo y siempre en Active
/// Beatmatching; no tiene selector de tipo de mezcla.
const MixFormula kMixConLetraFormula = MixFormula.dnaEnergy;

/// 3.1.71: version del campo `mixFormula` en `liveDj.json`. Las sesiones
/// sin `mixFormulaV` (anteriores) abren en Active Beatmatching, el nuevo
/// valor por defecto de AutomixDj; desde aqui se respeta la eleccion.
const int kMixFormulaSchema = 2;

MixFormula mixFormulaFromSession(Map<dynamic, dynamic> data) {
  final Object? v = data['mixFormulaV'];
  final Object? idx = data['mixFormula'];
  if (v is! int || v < kMixFormulaSchema) return MixFormula.dnaEnergy;
  if (idx is int && idx >= 0 && idx < MixFormula.values.length) {
    return MixFormula.values[idx];
  }
  return MixFormula.dnaEnergy;
}

/// 3.1.71: Phrase 8 y Stealth cruzan en Equal-Power real de 6 a 8 s (antes
/// 8-18 s con la curva DAWN, que en la escala cubica de mpv dejaba el cambio
/// audible en ~2 s: la saliente caia y la entrante subia de golpe).
const int kEqualPowerMinMs = 6000;
const int kEqualPowerMaxMs = 8000;

bool mixFormulaEqualPower(MixFormula f) =>
    f == MixFormula.phraseGrid || f == MixFormula.stealthGap;

int equalPowerFadeMs(int wantedMs) =>
    wantedMs.clamp(kEqualPowerMinMs, kEqualPowerMaxMs);

/// 3.1.73 (orden explicita de Gabriel, solo Phrase 8 y Stealth): ventanas
/// largas. Phrase 8 cruza 12-16 s alineado a una frase de 32 golpes
/// (8 compases de 4/4) segun el BPM; Stealth 10-12 s. Siguen en
/// Equal-Power con la compensacion cubica de mpv en toda la rampa.
const int kPhrase8MinMs = 12000;
const int kPhrase8MaxMs = 16000;
const int kStealthMinMs = 10000;
const int kStealthMaxMs = 12000;

/// Phrase 8: 32 golpes del BPM sonando, acotado a 12-16 s (14 s sin BPM).
int phrase8WindowMs(double bpm) {
  if (bpm < 60 || bpm > 200) return 14000;
  final int span = (60000.0 / bpm * 32).round();
  return span.clamp(kPhrase8MinMs, kPhrase8MaxMs);
}

/// Stealth: 24 golpes (6 compases), acotado a 10-12 s (11 s sin BPM).
int stealthWindowMs(double bpm) {
  if (bpm < 60 || bpm > 200) return 11000;
  final int span = (60000.0 / bpm * 24).round();
  return span.clamp(kStealthMinMs, kStealthMaxMs);
}

/// Margen tras el fin del cruce: A nunca se corta en su final.
const int kMixTailMarginMs = 1500;

/// El punto de mezcla se adelanta lo necesario para que la ventana larga
/// completa ([windowMs]) termine antes del final de A, sin bajar del 50 %
/// de la pista. Si ya cabe no cambia.
int extendedMixOutCap({
  required int durationMs,
  required int mixOutMs,
  required int windowMs,
}) {
  if (durationMs <= 0 || mixOutMs <= 0) return mixOutMs;
  final int latest = durationMs - windowMs - kMixTailMarginMs;
  if (mixOutMs <= latest) return mixOutMs;
  final int floor = durationMs ~/ 2;
  final int capped = latest > floor ? latest : floor;
  return capped < mixOutMs ? capped : mixOutMs;
}

/// 3.1.73: en Phrase 8 la cola no se mueve sola despues del Shuffle (ni el
/// reorden del backfill de BPM al cambiar de pista): suena el orden del
/// Shuffle / estacion; Phrase 8 solo cambia la tecnica de mezcla.
bool mixFormulaMayReorderQueue(MixFormula f) => f != MixFormula.phraseGrid;

int snapPhraseGridMixOut({
  required int durationMs,
  required int dnaMixOutMs,
  required double bpm,
}) {
  if (durationMs <= 0 || dnaMixOutMs <= 0) return dnaMixOutMs;
  if (bpm < 60 || bpm > 200) return dnaMixOutMs;

  final int barMs = ((60000.0 / bpm) * 4).round();
  if (barMs <= 0) return dnaMixOutMs;
  final int phraseMs = barMs * 8;
  final int minMs = (durationMs * 0.60).round();
  final int maxMs = dnaMixOutMs < durationMs ? dnaMixOutMs : durationMs;
  if (maxMs <= minMs) {
    return dnaMixOutMs < durationMs ? dnaMixOutMs : minMs;
  }

  int snapped = (maxMs ~/ phraseMs) * phraseMs;
  if (snapped < minMs) {
    snapped = ((minMs + phraseMs - 1) ~/ phraseMs) * phraseMs;
  }
  if (snapped < minMs || snapped > maxMs || snapped >= durationMs) {
    return dnaMixOutMs < durationMs ? dnaMixOutMs : minMs;
  }
  return snapped;
}

int phraseFadeMs({
  required double incomingBpm,
  required int incomingDurationMs,
}) {
  if (incomingBpm >= 60 && incomingBpm <= 200) {
    final double barMs = (60000.0 / incomingBpm) * 4;
    for (final int bars in const [16, 8]) {
      final int span = (barMs * bars).round();
      if (span >= 8000 && span <= 18000) return span;
    }
  }
  if (incomingDurationMs > 0) {
    return (incomingDurationMs * 0.06).round().clamp(8000, 18000);
  }
  return 12000;
}

/// Entra entre el 5 % y el 10 % de la pista (cuerpo, no intro muerta).
int stealthCueInMs(int durationMs, List<int> lyricMs) {
  if (durationMs <= 0) return 0;
  final int minIn = (durationMs * 0.05).round();
  final int maxIn = (durationMs * 0.10).round();
  if (durationMs < 30000) return minIn.clamp(0, durationMs ~/ 5);
  for (final int t in lyricMs) {
    if (t >= minIn && t <= maxIn) return t;
  }
  return ((minIn + maxIn) ~/ 2).clamp(minIn, maxIn);
}

/// Desde el 60 % busca hacia adelante el hueco instrumental; no corta tajante al 60.
int stealthMixOutMs({
  required int durationMs,
  required List<int> lyricMs,
  required double bpm,
}) {
  if (durationMs <= 0) return 0;
  final int lo = (durationMs * 0.60).round();
  final int hi = (durationMs * 0.80).round();
  if (hi <= lo) return lo.clamp(0, durationMs);

  int bestAt = -1;
  int bestGap = 0;
  for (int i = 0; i < lyricMs.length - 1; i++) {
    final int gapStart = lyricMs[i];
    final int gapEnd = lyricMs[i + 1];
    if (gapEnd <= lo) continue;
    final int overlapLo = max(gapStart, lo);
    final int overlapHi = min(gapEnd, hi);
    final int gap = overlapHi - overlapLo;
    if (gap >= 2500 && gap > bestGap) {
      bestGap = gap;
      bestAt = overlapLo + (gap * 0.25).round();
    }
  }

  int mixOut;
  if (bestGap >= 2500 && bestAt >= lo) {
    mixOut = bestAt;
  } else if (bpm >= 60 && bpm <= 200) {
    final int barMs = ((60000.0 / bpm) * 4).round();
    final int phraseMs = barMs * 8;
    if (phraseMs > 0) {
      mixOut = ((lo + phraseMs - 1) ~/ phraseMs) * phraseMs;
      if (mixOut < lo) mixOut = lo;
    } else {
      mixOut = lo;
    }
  } else {
    mixOut = lo;
  }

  if (mixOut > hi) mixOut = hi;
  if (mixOut >= durationMs) mixOut = hi < durationMs ? hi : lo;
  if (hi < lo) return lo.clamp(0, durationMs);
  return mixOut.clamp(lo, hi);
}

/// Empata BPM si el ratio cabe en ±12 % (mezcla casi imperceptible).
double matchBpmRate(double fadingBpm, double incomingBpm) {
  if (fadingBpm < 60 || incomingBpm < 60) return 1.0;
  final double ratio = fadingBpm / incomingBpm;
  if (ratio >= 0.88 && ratio <= 1.12) return ratio;
  return 1.0;
}

/// 3.1.32 (Automix): lleva la entrada al golpe de la rejilla de la entrante
/// (primer golpe [beatMs], tempo [bpm]). Set In manual: golpe mas cercano
/// (nunca mas de medio golpe). Automatica: golpe siguiente (ceil). Sin BPM
/// fiable devuelve [cueMs] tal cual.
int snapCueToBeat({
  required int cueMs,
  required double beatMs,
  required double bpm,
  required bool manual,
}) {
  if (!bpm.isFinite || bpm <= 0 || !beatMs.isFinite) return cueMs;
  final double p = 60000.0 / bpm;
  final double k = (cueMs - beatMs) / p;
  final double kk = manual ? k.roundToDouble() : k.ceilToDouble();
  var s = (beatMs + kk * p).round();
  while (s < 0) {
    s = (s + p).round();
  }
  return s;
}
