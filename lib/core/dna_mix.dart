import 'livedj_order.dart';
import 'phrase_grid.dart';

/// Cómo cruza DNA. El nombre en la UI no cambia.
enum DnaKind {
  /// Sin perfil: salida base 60 %, cue de 15 s (3.2.22), fundido de 18 s.
  legacy,
  longBlend,
  shortBlend,
  echoOut,
  filterSweep,
  /// (c) sin eco ni ecualizador en este libmpv: fundido de volumen, sin tempo.
  blendFallback,
}

class DnaDecision {
  final DnaKind kind;
  final int mixOutMs;
  final int cueInMs;
  final int fadeMs;
  final bool lockTempo;
  final bool bassSwap;

  /// Un golpe de la saliente. 0 si no hay eco.
  final int echoDelayMs;
  final double echoFeedback;

  /// De dónde salió el punto: outro, hueco o frase.
  final String mixSource;

  const DnaDecision({
    required this.kind,
    required this.mixOutMs,
    required this.cueInMs,
    required this.fadeMs,
    required this.lockTempo,
    required this.bassSwap,
    required this.echoDelayMs,
    required this.echoFeedback,
    this.mixSource = '',
  });

  bool get legacy => kind == DnaKind.legacy;
}

/// 3.2.22: salida base 60 % y techo 80 % con el fundido incluido, para
/// todos los generos y todas las rutas de AutomixDj.
const double kDnaMixBase = 0.60;
const double kDnaMixTop = 0.80;

/// 3.2.22: piso del cue de entrada en pistas >= 90 s y tope de la busqueda
/// del primer punto limpio. Pistas cortas: min(10 s, 10 % de la duracion).
const int kDnaCueFloorMs = 15000;
const int kDnaCueMaxMs = 25000;
const int kDnaShortTrackMs = 90000;
const int kDnaShortCueMaxMs = 10000;

/// Piso del cue: 15 s (>= 90 s) o min(10 s, 10 %) en pistas cortas.
/// Sin duracion medida devuelve 0 (no se inventa un cue).
int dnaCueFloorMs(int durationMs) {
  if (durationMs <= 0) return 0;
  if (durationMs < kDnaShortTrackMs) {
    final int tenth = durationMs ~/ 10;
    return tenth < kDnaShortCueMaxMs ? tenth : kDnaShortCueMaxMs;
  }
  return kDnaCueFloorMs;
}

/// Cue sin perfil: el silencio inicial medido si pasa del piso (no recorta
/// voz), si no el piso. En pistas cortas el silencio solo vale bajo 1/3.
int dnaFallbackCueMs(int durationMs, int leadMs) {
  if (durationMs <= 0) return 0;
  final int floor = dnaCueFloorMs(durationMs);
  if (durationMs >= kDnaShortTrackMs) return leadMs > floor ? leadMs : floor;
  return leadMs > floor && leadMs < durationMs ~/ 3 ? leadMs : floor;
}

/// 3.2.22: punto y fundido dentro de la ventana: mixOut >= 60 % y
/// mixOut + fade <= 80 %. Si no cabe (pistas cortas) la salida queda en
/// 60 % y el fundido se acorta hasta el minimo de 8 s; nunca pasa del final.
/// Con [locked] (cruce ya fijado) solo se acorta el fundido.
({int mixOutMs, int fadeMs}) dnaFitWindow({
  required int durationMs,
  required int mixOutMs,
  required int fadeMs,
  bool locked = false,
}) {
  var m = mixOutMs;
  var f = fadeMs < 0 ? 0 : fadeMs;
  if (durationMs <= 0) return (mixOutMs: m, fadeMs: f);
  final int lo = (durationMs * kDnaMixBase).round();
  final int top = (durationMs * kDnaMixTop).round();
  if (!locked) {
    final int hi = top - f;
    if (hi < lo) {
      m = lo;
    } else if (m < lo) {
      m = lo;
    } else if (m > hi) {
      m = hi;
    }
  }
  if (m + f > top) {
    final int room = top - m;
    final int minFade = f < phraseFadeMinMs ? f : phraseFadeMinMs;
    f = room > minFade ? room : minFade;
  }
  if (m + f > durationMs) {
    f = durationMs - m;
    if (f < 0) f = 0;
  }
  return (mixOutMs: m, fadeMs: f);
}

/// 3.2.22: clamp unico de la salida de AutomixDj (DNA, Phrase 8, Stealth,
/// Mix largo y analisis fallido): [mixOutMs] en [60 %, 80 % - fadeMs].
/// Sin punto (0 o negativo) queda en la base 60 %.
int dnaCapMixOut({
  required int durationMs,
  required int mixOutMs,
  required int fadeMs,
}) {
  if (durationMs <= 0) return mixOutMs;
  return dnaFitWindow(
    durationMs: durationMs,
    mixOutMs: mixOutMs,
    fadeMs: fadeMs,
  ).mixOutMs;
}

/// 3.2.22: seek de la primera pista en un arranque en frio (estacion o
/// shuffle). Con una posicion elegida (estacion retomada, sesion) no se
/// mueve; sin cue o con cue fuera de la pista tampoco.
int dnaColdStartSeekMs({
  required int startPositionMs,
  required int cueInMs,
  required int durationMs,
}) {
  if (startPositionMs > 0) return 0;
  if (cueInMs <= 0) return 0;
  if (durationMs > 0 && cueInMs >= durationMs) return 0;
  return cueInMs;
}

int _baseCue(int inDurationMs, int fallbackCueMs) {
  final int floor = dnaCueFloorMs(inDurationMs);
  return fallbackCueMs > floor ? fallbackCueMs : floor;
}

/// DNA de un par saliente → entrante. No toca Phrase 8 ni Stealth.
///
/// (a) BPM ±12 %, Camelot compatible (o tonalidad desconocida) y sin voz en
/// el outro y la intro: 16 compases, bass swap y corte de agudos.
/// (b) Compatible, con voz cerca: 8 compases y las frases vocales no coinciden.
/// (c) BPM fuera de ±12 % o tonalidades incompatibles: eco al beat o barrido
/// pasa-altos. El tempo igual se encuentra en el punto medio. Si el libmpv no
/// tiene esos filtros, [DnaKind.blendFallback].
DnaDecision decideDna({
  required int outDurationMs,
  required int inDurationMs,
  required int genreMixOutMs,
  required int fallbackCueMs,
  required double outBpm,
  required double inBpm,
  double outRate = 1,
  String? outKey,
  String? inKey,
  PhraseTrack? outgoing,
  PhraseTrack? incoming,
  required bool echoSupported,
  required bool eqSupported,
  bool exitLocked = false,
}) {
  if (outgoing == null && incoming == null) {
    // 3.2.22: sin perfil (analisis fallido) tambien 60 % .. 80 % - fundido.
    final fit = dnaFitWindow(
      durationMs: outDurationMs,
      mixOutMs: genreMixOutMs,
      fadeMs: 18000,
      locked: exitLocked,
    );
    return DnaDecision(
      kind: DnaKind.legacy,
      mixOutMs: fit.mixOutMs,
      cueInMs: _baseCue(inDurationMs, fallbackCueMs),
      fadeMs: fit.fadeMs,
      lockTempo: true,
      bassSwap: true,
      echoDelayMs: 0,
      echoFeedback: 0,
      mixSource: 'frase',
    );
  }

  final int winLo = (outDurationMs * kDnaMixBase).round();
  final int winHi = (outDurationMs * kDnaMixTop).round();
  var source = 'frase';
  var mixOut = _clampWindow(genreMixOutMs, winLo, winHi);
  if (!exitLocked && outgoing != null) {
    if (_outroFits(outgoing.outroMs, outDurationMs)) {
      mixOut = outgoing.outroMs;
      source = 'outro';
    } else {
      final int? quiet = _nearestQuiet(outgoing, mixOut, winLo, winHi);
      if (quiet != null) {
        mixOut = quiet;
        source = 'hueco';
      } else {
        final int? phrase = _nearestDownbeat(outgoing, mixOut, winLo, winHi);
        if (phrase != null) mixOut = phrase;
      }
    }
  }

  final double entryBpm = inBpm >= 60 && inBpm <= 200
      ? inBpm
      : (incoming?.bpm ?? 0);
  // 3.2.22: el cue nunca baja del piso (15 s, o min(10 s, 10 %) en cortas).
  // Un silencio inicial mayor que el piso manda tal cual.
  final int cueFloor = dnaCueFloorMs(inDurationMs);
  final int baseCue = _baseCue(inDurationMs, fallbackCueMs);
  final bool floorCue = baseCue <= cueFloor;
  var cue = baseCue;
  if (incoming != null && floorCue && inDurationMs > 30000 && entryBpm >= 60) {
    final int? snapped = _entryPoint(incoming, entryBpm, inDurationMs);
    if (snapped != null) cue = snapped;
  }

  final bool voice = _hasVoice(outgoing, mixOut) || _hasVoice(incoming, cue);
  if (outgoing != null &&
      incoming != null &&
      floorCue &&
      inDurationMs >= kDnaShortTrackMs) {
    if (_phraseVocal(outgoing, mixOut) && _phraseVocal(incoming, cue)) {
      final int? movedIn = _nearestQuiet(
        incoming,
        cue,
        cueFloor,
        kDnaCueMaxMs,
      );
      if (movedIn != null && movedIn != cue) cue = movedIn;
    }
  }

  final bool tempo = _bpmClose(outBpm, inBpm, outRate);
  final bool clash = _keysClash(outKey, inKey);
  final double sounded = tempo
      ? phraseSoundingBpm(
          incomingBpm: entryBpm >= 60 ? entryBpm : inBpm,
          incomingRate: _matchRate(outBpm, inBpm, outRate),
        )
      : (entryBpm >= 60 ? entryBpm : inBpm);

  DnaDecision seal({
    required DnaKind kind,
    required int cueIn,
    required int fade,
    required bool lock,
    required bool bass,
    required int echoDelay,
    required double echoFb,
  }) {
    // 3.2.22: la mezcla perfecta se busca en 60-80 %, pero el fundido
    // tambien termina antes del 80 % (outro tardio incluido).
    final fit = dnaFitWindow(
      durationMs: outDurationMs,
      mixOutMs: mixOut,
      fadeMs: fade,
      locked: exitLocked,
    );
    return DnaDecision(
      kind: kind,
      mixOutMs: fit.mixOutMs,
      cueInMs: cueIn,
      fadeMs: fit.fadeMs,
      lockTempo: lock,
      bassSwap: bass,
      echoDelayMs: echoDelay,
      echoFeedback: echoFb,
      mixSource: source,
    );
  }

  if (!tempo || clash) {
    final int delay = _beatMs(outBpm >= 60 ? outBpm : inBpm);
    if (echoSupported) {
      return seal(
        kind: DnaKind.echoOut,
        cueIn: cue,
        fade: _bars(outBpm >= 60 ? outBpm : sounded, 8),
        lock: false,
        bass: false,
        echoDelay: delay,
        echoFb: 0.45,
      );
    }
    if (eqSupported) {
      return seal(
        kind: DnaKind.filterSweep,
        cueIn: cue,
        fade: _bars(outBpm >= 60 ? outBpm : sounded, 8),
        lock: false,
        bass: false,
        echoDelay: 0,
        echoFb: 0,
      );
    }
    return seal(
      kind: DnaKind.blendFallback,
      cueIn: cue,
      fade: _bars(sounded, voice ? 8 : 16),
      lock: false,
      bass: false,
      echoDelay: 0,
      echoFb: 0,
    );
  }

  if (!voice) {
    return seal(
      kind: DnaKind.longBlend,
      cueIn: cue,
      fade: _bars(sounded, 16),
      lock: true,
      bass: true,
      echoDelay: 0,
      echoFb: 0,
    );
  }
  return seal(
    kind: DnaKind.shortBlend,
    cueIn: cue,
    fade: _bars(sounded, 8),
    lock: true,
    bass: false,
    echoDelay: 0,
    echoFb: 0,
  );
}

int _clampWindow(int ms, int lo, int hi) {
  if (hi < lo) return ms;
  if (ms < lo) return lo;
  if (ms > hi) return hi;
  return ms;
}

bool _outroFits(int outroMs, int durationMs) {
  if (outroMs < 0 || durationMs <= 0) return false;
  final int lo = (durationMs * 0.60).round();
  final int hi = (durationMs * 0.80).round();
  return outroMs >= lo && outroMs <= hi;
}

bool _bpmClose(double outBpm, double inBpm, double outRate) {
  if (outBpm < 60 || inBpm < 60) return false;
  final double rate = outRate > 0 ? outRate : 1;
  final double ratio = (outBpm * rate) / inBpm;
  return ratio >= 0.88 && ratio <= 1.12;
}

double _matchRate(double outBpm, double inBpm, double outRate) {
  if (!_bpmClose(outBpm, inBpm, outRate)) return 1;
  final double rate = outRate > 0 ? outRate : 1;
  return (outBpm * rate) / inBpm;
}

/// Chocan solo si las dos tonalidades se conocen y no son compatibles.
bool _keysClash(String? a, String? b) {
  if (a == null || b == null) return false;
  final String aa = a.trim();
  final String bb = b.trim();
  if (aa.isEmpty || bb.isEmpty) return false;
  return !camelotCompatible(aa, bb);
}

bool _phraseVocal(PhraseTrack? track, int ms) {
  final PhrasePhrase? p = track?.phraseAt(ms);
  if (p == null) return false;
  return p.vocalOn;
}

/// Sin perfil, o con una frase vocal: hay voz cerca (no se hace el blend largo).
bool _hasVoice(PhraseTrack? track, int ms) {
  if (track == null) return true;
  return _phraseVocal(track, ms);
}

/// 3.2.22: entrada >= 15 s y <= ~25 s en pistas >= 90 s: fin de intro si cae
/// en [15, 25] s; si no, la primera frase limpia (sin voz), luego cualquier
/// frase, luego el primer compas y luego el primer golpe en esa franja; si
/// nada cae ahi, 15 s exactos. Nunca el primer golpe de 1-2 s.
/// Pistas cortas: el ultimo golpe en o antes del piso proporcional.
int? _entryPoint(PhraseTrack track, double bpm, int durationMs) {
  final int floor = dnaCueFloorMs(durationMs);
  final int beatLen = bpm > 0 ? (60000.0 / bpm).round() : 0;
  final int b0 = track.beatMs < 0 ? 0 : track.beatMs;
  if (durationMs < kDnaShortTrackMs) {
    if (beatLen <= 0 || b0 >= floor) return floor;
    return b0 + ((floor - b0) ~/ beatLen) * beatLen;
  }
  const int cap = kDnaCueMaxMs;
  final int intro = track.introEndMs;
  if (intro >= floor && intro <= cap) return intro;
  int? firstPhrase;
  for (final PhrasePhrase p in track.phrases) {
    if (p.startMs < floor || p.startMs > cap) continue;
    if (!p.vocalOn) return p.startMs;
    firstPhrase ??= p.startMs;
  }
  if (firstPhrase != null) return firstPhrase;
  if (beatLen > 0) {
    int up(int step) =>
        b0 >= floor ? b0 : b0 + ((floor - b0 + step - 1) ~/ step) * step;
    final int bar = up(beatLen * 4);
    if (bar <= cap) return bar;
    final int beat = up(beatLen);
    if (beat <= cap) return beat;
  }
  return floor;
}

int? _nearestQuiet(PhraseTrack track, int fromMs, int lo, int hi) {
  if (hi < lo) return null;
  int? best;
  var bestDist = 1 << 62;
  for (final PhrasePhrase p in track.phrases) {
    if (p.startMs < lo || p.startMs > hi || p.vocalOn) continue;
    final int d = (p.startMs - fromMs).abs();
    if (best == null || d < bestDist || (d == bestDist && p.startMs < best)) {
      bestDist = d;
      best = p.startMs;
    }
  }
  return best;
}

int? _nearestDownbeat(PhraseTrack track, int fromMs, int lo, int hi) {
  if (hi < lo) return null;
  int? best;
  var bestDist = 1 << 62;
  for (final PhrasePhrase p in track.phrases) {
    if (p.startMs < lo || p.startMs > hi) continue;
    final int d = (p.startMs - fromMs).abs();
    if (best == null || d < bestDist || (d == bestDist && p.startMs < best)) {
      bestDist = d;
      best = p.startMs;
    }
  }
  return best;
}

/// Punto de género ya dentro del 60–80 % de la duración efectiva.
int dnaPercentPoint(int effectiveMs, double fraction) {
  if (effectiveMs <= 0) return 0;
  final int lo = (effectiveMs * 0.60).round();
  final int hi = (effectiveMs * 0.80).round();
  return _clampWindow((effectiveMs * fraction).round(), lo, hi);
}

int _bars(double bpm, int bars) {
  if (bpm >= 60 && bpm <= 200) {
    final int span = ((60000.0 / bpm) * 4).round() * bars;
    if (span > 0) return span.clamp(8000, 18000);
  }
  return bars >= 16 ? 18000 : 8000;
}

int _beatMs(double bpm) {
  if (bpm < 60 || bpm > 200) return 500;
  return (60000.0 / bpm).round().clamp(250, 1000);
}

/// Corte de agudos con `equalizer` (el filtro que sí trae el libmpv).
const String dnaHighShelfCut =
    'equalizer=f=6500:width_type=o:w=1.2:g=-12,equalizer=f=10000:width_type=o:w=1:g=-8';

/// Pasa-altos aproximado: dos pasos, no un `af` nuevo en cada tick.
const String dnaHighpassMild =
    'equalizer=f=90:width_type=o:w=2.2:g=-18,equalizer=f=220:width_type=o:w=1.6:g=-10';

const String dnaHighpassHard =
    'equalizer=f=90:width_type=o:w=2.2:g=-26,equalizer=f=240:width_type=o:w=1.8:g=-16,equalizer=f=480:width_type=o:w=1.2:g=-8';

String dnaEchoChain(int delayMs, double feedback) {
  final int delay = delayMs.clamp(20, 2000);
  final String fb = feedback.clamp(0.05, 0.85).toStringAsFixed(2);
  return 'aecho=0.8:0.88:$delay:$fb';
}
