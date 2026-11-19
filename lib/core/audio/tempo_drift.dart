import 'dart:math';

import 'package:media_kit/media_kit.dart';

import '../audio_path.dart' show sameAudioPath;
import '../genre_mix_fx.dart' show bpmNoStretch;
import 'mix_pause.dart';

/// 3.1.99 Rampa simetrica al punto medio: 0.5 BPM/s (2 BPM cada 4 s).
const double kTempoRampBpmPerSec = 0.5;

/// 3.1.99: un micro-paso de rate cada 200 ms (antes y despues del cruce).
const int kTempoRampStepMs = 200;

/// 3.1.99: A ya esta en m/a si su rate difiere menos que esto.
const double kTempoRampRateEpsilon = 0.003;

/// 3.2.0: la rampa previa queda comprometida (siguiente congelada) este
/// margen antes de su arranque; Live DJ precarga a mas tardar ahi.
const int kPreRollLockLeadMs = 1000;

/// 3.2.0: con la rampa previa comprometida la siguiente no cambia: si
/// [pinned] sigue en [queue] queda justo despues de [current] (al frente si
/// [current] no esta en la cola). Si el usuario la quito, o es la que suena,
/// la cola vuelve igual (misma instancia).
List<String> pinNextTrack(
  List<String> queue, {
  String? current,
  String? pinned,
}) {
  if (pinned == null || pinned.isEmpty) return queue;
  if (current != null && sameAudioPath(pinned, current)) return queue;
  final int at = queue.indexWhere((String p) => sameAudioPath(p, pinned));
  if (at < 0) return queue;
  final int cur = current == null
      ? -1
      : queue.indexWhere((String p) => sameAudioPath(p, current));
  if (at == cur + 1) return queue;
  final List<String> out = List<String>.from(queue);
  final String keep = out.removeAt(at);
  final int cur2 = current == null
      ? -1
      : out.indexWhere((String p) => sameAudioPath(p, current));
  out.insert(cur2 + 1, keep);
  return out;
}

/// 3.2.0: true si [deck] tiene abierta exactamente [path] (sin exigir
/// duracion: sirve para soltar un deck que acaba de arrancar).
bool deckHoldsAudioPath(Player deck, String path) {
  try {
    final List<Media> medias = deck.state.playlist.medias;
    final int idx = deck.state.playlist.index;
    if (idx < 0 || idx >= medias.length) return false;
    String norm(String s) {
      var t = s;
      try {
        t = Uri.decodeFull(s);
      } catch (_) {}
      return t.replaceAll('\\', '/').replaceFirst('file:///', '').toLowerCase();
    }

    final String loaded = norm(medias[idx].uri);
    final String want = norm(path);
    return loaded == want || loaded.endsWith(want) || want.endsWith(loaded);
  } catch (_) {
    return false;
  }
}

/// 3.1.99: plan simetrico. A (saliente) va de 1.0 a m/a antes del cruce y B
/// (entrante) entra a m/b y vuelve a 1.0 despues; cada mitad mueve
/// delta/2 BPM a [kTempoRampBpmPerSec], o sea delta segundos.
class SymmetricTempoPlan {
  const SymmetricTempoPlan({
    required this.a,
    required this.b,
    required this.midpoint,
    required this.delta,
    required this.outRate,
    required this.inRate,
    required this.active,
    required this.blocked,
    required this.noStretch,
  });

  final double a;
  final double b;
  final double midpoint;
  final double delta;
  final double outRate;
  final double inRate;

  /// true: hay que igualar (BPM conocidos, >= 2 % y las dos mitades en rango).
  final bool active;

  /// m/a o m/b fuera de 0.88-1.12: ninguno se iguala (los dos a 1.0x).
  final bool blocked;

  /// Diferencia < 2 % (3.1.97): ninguno se mueve.
  final bool noStretch;

  /// 3.2.0: texto armado solo al pedirlo (el plan se consulta en cada tick).
  String get note =>
      'mid a=${a.toStringAsFixed(3)} b=${b.toStringAsFixed(3)} '
      'm=${midpoint.toStringAsFixed(3)} rateA=${outRate.toStringAsFixed(4)} '
      'rateB=${inRate.toStringAsFixed(4)}';

  /// Duracion real de cada mitad: (delta / 2) / 0.5 BPM/s = delta segundos.
  int get rampMs =>
      active ? (delta / 2 / kTempoRampBpmPerSec * 1000).round() : 0;

  /// Milisegundos de pista que recorre A durante su rampa lineal (rate de
  /// 1.0 a m/a): la rampa arranca a esta distancia antes de la entrada de B.
  int get leadTrackMs => active ? (rampMs * (1 + outRate) / 2).round() : 0;
}

SymmetricTempoPlan symmetricTempoPlan(double a, double b) {
  final double m = (a + b) / 2;
  final double outRate = a > 0 ? m / a : 1;
  final double inRate = b > 0 ? m / b : 1;
  final bool musical = _musicalBpm(a) && _musicalBpm(b);
  final bool noStretch = musical && bpmNoStretch(a, b);
  bool outside(double r) => r < TempoDrift.minRate || r > TempoDrift.maxRate;
  final bool blocked =
      musical && !noStretch && (outside(outRate) || outside(inRate));
  final double delta = (a - b).abs();
  return SymmetricTempoPlan(
    a: a,
    b: b,
    midpoint: m,
    delta: delta,
    outRate: outRate,
    inRate: inRate,
    active: musical && !noStretch && !blocked && delta > 1e-9,
    blocked: blocked,
    noStretch: noStretch,
  );
}

/// 3.1.99: rate de B al entrar. Con A ya en m/a ([outRateNow]) es m/b. Si
/// A no llego (cruce adelantado, BPM conocido tarde) B iguala el BPM real
/// de A (a * rate / b), si cabe en 0.88-1.12. Sin plan activo: 1.0.
MidpointEntry symmetricEntry(double a, double b, {double outRateNow = 1.0}) {
  final SymmetricTempoPlan plan = symmetricTempoPlan(a, b);
  if (!plan.active) {
    // 3.2.0: sin plan pero A desplazado (rampa vieja o volviendo a 1.0): B
    // iguala el BPM real de A si cabe en 0.88-1.12; si no, 1.0.
    if (_musicalBpm(a) &&
        _musicalBpm(b) &&
        (outRateNow - 1.0).abs() > kTempoRampRateEpsilon) {
      final double matched = a * outRateNow / b;
      final String note =
          'sin plan matchA=${outRateNow.toStringAsFixed(4)} '
          'rateB=${matched.toStringAsFixed(4)}';
      if (matched < TempoDrift.minRate || matched > TempoDrift.maxRate) {
        return MidpointEntry(incomingRate: 1, blocked: true, note: note);
      }
      return MidpointEntry(incomingRate: matched, blocked: false, note: note);
    }
    return MidpointEntry(
      incomingRate: 1,
      blocked: plan.blocked,
      note: plan.noStretch ? 'sin stretch (<2%)' : plan.note,
    );
  }
  if ((outRateNow - plan.outRate).abs() <= kTempoRampRateEpsilon) {
    return MidpointEntry(
      incomingRate: plan.inRate,
      blocked: false,
      note: plan.note,
    );
  }
  final double matched = a * outRateNow / b;
  final String note =
      '${plan.note} matchA=${outRateNow.toStringAsFixed(4)} '
      'rateB=${matched.toStringAsFixed(4)}';
  if (matched < TempoDrift.minRate || matched > TempoDrift.maxRate) {
    return MidpointEntry(incomingRate: 1, blocked: true, note: note);
  }
  return MidpointEntry(incomingRate: matched, blocked: false, note: note);
}

/// 3.1.99: rates de la rampa lineal de [from] a [to] en [ms], un valor cada
/// [stepMs] (el primero es [from], el ultimo [to] exacto).
List<double> tempoLinearSchedule(
  double from,
  double to, {
  required int ms,
  int stepMs = kTempoRampStepMs,
}) {
  if (ms <= 0 || stepMs <= 0) return <double>[to];
  final List<double> out = <double>[];
  for (int elapsed = 0; elapsed < ms; elapsed += stepMs) {
    out.add(from + (to - from) * (elapsed / ms));
  }
  out.add(to);
  return out;
}

/// Un paso de la rampa: [offsetMs] desde el punto de mezcla (negativo = antes)
/// y el BPM con el que la pista queda sonando al completar el paso.
class TempoMark {
  final int offsetMs;
  final double bpm;

  const TempoMark(this.offsetMs, this.bpm);
}

/// Rampa al punto medio. A (saliente) llega a [midpoint] en el cruce.
/// B (entrante) arranca en [midpoint] y vuelve a su BPM.
class MidpointTempoPlan {
  final double a;
  final double b;
  final double midpoint;
  final double span;
  final List<TempoMark> outgoing;
  final List<TempoMark> incoming;

  /// El rate `m/natural` de A o de B cae fuera de 0.88–1.12.
  final bool rateLimited;
  final double outgoingRate;
  final double incomingRate;
  final String note;

  const MidpointTempoPlan({
    required this.a,
    required this.b,
    required this.midpoint,
    required this.span,
    required this.outgoing,
    required this.incoming,
    required this.rateLimited,
    required this.outgoingRate,
    required this.incomingRate,
    required this.note,
  });
}

/// Pasos de A antes del cruce y de B después.
///
/// d ≤ 8: mitad en 2 pasos iguales (−10 s, −5 s y +5 s, +10 s).
/// 8 < d ≤ 12: 4 pasos antes (12/9/6/3 s, pesos 1-1-2-2) y 3 después
/// (+5/+10/+14). d > 12: los mismos pesos y el mismo espaciado, con más
/// pasos. Si B > A el signo se invierte. La fracción se reparte igual.
MidpointTempoPlan midpointTempoPlan(double a, double b) {
  final double m = (a + b) / 2;
  final double d = (a - b).abs();
  final double outRate = a.abs() < 1e-9 ? 1 : m / a;
  final double inRate = b.abs() < 1e-9 ? 1 : m / b;
  final bool limited =
      a > 0 &&
      b > 0 &&
      (outRate < TempoDrift.minRate ||
          outRate > TempoDrift.maxRate ||
          inRate < TempoDrift.minRate ||
          inRate > TempoDrift.maxRate);
  final String note =
      'a=${a.toStringAsFixed(3)} b=${b.toStringAsFixed(3)} '
      'm=${m.toStringAsFixed(3)} '
      'rateA=${outRate.toStringAsFixed(4)} rateB=${inRate.toStringAsFixed(4)}';
  if (d < 1e-9 || a <= 0 || b <= 0) {
    return MidpointTempoPlan(
      a: a,
      b: b,
      midpoint: m,
      span: d,
      outgoing: const <TempoMark>[],
      incoming: const <TempoMark>[],
      rateLimited: limited,
      outgoingRate: outRate,
      incomingRate: inRate,
      note: note,
    );
  }
  final double half = d / 2;
  final bool wide = d > 8;
  final int nOut = wide ? 2 + 2 * ((d - 8) / 4).ceil() : 2;
  final int nIn = (d / 4).ceil() < 2 ? 2 : (d / 4).ceil();
  final List<double> outPortions = _portions(nOut, half, weighted: wide);
  final List<double> inPortions = _portions(nIn, half, weighted: false);
  return MidpointTempoPlan(
    a: a,
    b: b,
    midpoint: m,
    span: d,
    outgoing: _walk(
      start: a,
      end: m,
      offsets: _outgoingOffsets(nOut),
      portions: outPortions,
    ),
    incoming: _walk(
      start: m,
      end: b,
      offsets: _incomingOffsets(nIn),
      portions: inPortions,
    ),
    rateLimited: limited,
    outgoingRate: outRate,
    incomingRate: inRate,
    note: note,
  );
}

/// Rate de B en el cruce. Si el punto medio no cabe en 0.88–1.12, [blocked]
/// y el rate queda en 1: no se recorta a la frontera.
class MidpointEntry {
  final double incomingRate;
  final bool blocked;
  final String note;

  const MidpointEntry({
    required this.incomingRate,
    required this.blocked,
    required this.note,
  });
}

bool _musicalBpm(double bpm) => bpm >= 40 && bpm <= 250;

/// 3.1.71 Master lock (Active Beatmatching): A (saliente) no cambia de
/// tempo; B entra al BPM de A con rate a/b, puesto en silencio antes de que
/// su fader suba. Fuera de 0.88-1.12 B entra a su tempo (rate 1, blocked).
MidpointEntry masterLockEntry(double a, double b) {
  if (!_musicalBpm(a) || !_musicalBpm(b)) {
    return const MidpointEntry(incomingRate: 1, blocked: false, note: '');
  }
  final double rate = a / b;
  final String note =
      'lock a=${a.toStringAsFixed(3)} b=${b.toStringAsFixed(3)} '
      'rateB=${rate.toStringAsFixed(4)}';
  if (rate < TempoDrift.minRate || rate > TempoDrift.maxRate) {
    return MidpointEntry(incomingRate: 1, blocked: true, note: note);
  }
  return MidpointEntry(incomingRate: rate, blocked: false, note: note);
}

/// 3.1.99: B al punto medio (m/b) con la regla < 2 % y el rango de las dos
/// mitades (m/a y m/b); fuera de eso 1.0.
MidpointEntry midpointEntry(double a, double b) {
  if (!_musicalBpm(a) || !_musicalBpm(b)) {
    return const MidpointEntry(incomingRate: 1, blocked: false, note: '');
  }
  final SymmetricTempoPlan plan = symmetricTempoPlan(a, b);
  return symmetricEntry(a, b, outRateNow: plan.active ? plan.outRate : 1.0);
}

List<int> _outgoingOffsets(int n) {
  if (n <= 2) return const <int>[-10000, -5000];
  return <int>[for (int i = 0; i < n; i++) -3000 * (n - i)];
}

List<int> _incomingOffsets(int n) {
  if (n <= 2) return const <int>[5000, 10000];
  return <int>[5000, 10000, for (int i = 2; i < n; i++) 14000 + (i - 2) * 4000];
}

List<double> _portions(int n, double half, {required bool weighted}) {
  if (n <= 0) return const <double>[];
  if (!weighted) {
    final double s = half / n;
    return List<double>.filled(n, s);
  }
  final int h = n ~/ 2;
  final List<int> w = <int>[for (int i = 0; i < n; i++) i < h ? 1 : 2];
  final int sum = w.fold<int>(0, (int a, int b) => a + b);
  return <double>[for (final int x in w) half * x / sum];
}

List<TempoMark> _walk({
  required double start,
  required double end,
  required List<int> offsets,
  required List<double> portions,
}) {
  final List<TempoMark> out = <TempoMark>[];
  double cursor = start;
  final double dir = end >= start ? 1.0 : -1.0;
  for (int i = 0; i < offsets.length; i++) {
    if (i == offsets.length - 1) {
      cursor = end;
    } else {
      cursor += dir * portions[i].abs();
    }
    out.add(TempoMark(offsets[i], cursor));
  }
  return out;
}

/// Ganancia del cruce (curva `pow`). No recibe el rate: `setRate` no mueve el nivel.
double dawnCrossfadeGain(double progress) {
  final double x = (progress * 1.8).clamp(0.0, 1.0);
  return pow(x, 1.2).toDouble();
}

/// 3.1.71 Equal-Power: amplitud de la entrante, sin(p * pi / 2).
double equalPowerInGain(double progress) =>
    sin(progress.clamp(0.0, 1.0) * pi / 2);

/// 3.1.71 Equal-Power: amplitud de la saliente, cos(p * pi / 2). La suma de
/// potencias de las dos es 1 en todo el cruce: sin hueco ni bajon.
double equalPowerOutGain(double progress) =>
    cos(progress.clamp(0.0, 1.0) * pi / 2);

/// 3.1.71: mpv aplica el volumen en escala cubica (ganancia = (v/100)^3).
/// Volumen 0-100 que da la amplitud [gain] real.
double mpvVolumeForGain(double gain) {
  if (gain <= 0) return 0.0;
  return 100.0 * pow(gain.clamp(0.0, 1.0), 1 / 3).toDouble();
}

/// Ganancia real (amplitud) de un volumen mpv 0-100.
double mpvGainForVolume(double volume) {
  final double v = (volume / 100.0).clamp(0.0, 1.0);
  return v * v * v;
}

/// Rampa de tempo al punto medio (Live DJ, incluido Stealth, y Automix).
///
/// Antes del cruce A camina hacia el punto medio. B arranca ahí, en fase,
/// y después vuelve a su BPM. Los cambios van en rampa senoidal.
class TempoDrift {
  static const double minRate = 0.88;
  static const double maxRate = 1.12;

  double natural = 0.0;
  bool active = false;
  int rampMs = 5000;
  bool midpointBlocked = false;
  String midpointNote = '';

  /// 3.1.99: true = la saliente camina en linea recta (0.5 BPM/s) hasta el
  /// punto medio antes del cruce (se levanta el veto de 3.1.71).
  bool outgoingRamp = true;

  /// 3.1.99: la rampa armada es lineal en pasos de [kTempoRampStepMs].
  bool rampLinear = false;

  int _gen = 0;
  int _rampGen = 0;
  bool _phaseIn = false;
  bool _originSet = false;
  int _originMs = 0;
  int _inStep = 0;
  MidpointTempoPlan? _inPlan;
  double _outNext = 0;
  bool _outFired = false;
  bool _outCommitted = false;
  bool _outRamped = false;

  /// 3.2.0: true desde que la rampa previa de A queda comprometida
  /// ([kPreRollLockLeadMs] antes de su arranque) y mientras A camina o
  /// espera en m/a, hasta el cruce ([begin]) o una pareja sin plan.
  bool get preRollActive => _outCommitted || _outRamped;

  /// 3.2.0: cuanto antes del punto de mezcla hay que tener la siguiente
  /// precargada: el mayor entre [floorMs] y el arranque comprometido.
  int preRollArmLeadMs(double nextBpm, {int floorMs = 10000}) {
    final SymmetricTempoPlan plan = symmetricTempoPlan(natural, nextBpm);
    if (!plan.active) return floorMs;
    return max(floorMs, plan.leadTrackMs + kPreRollLockLeadMs);
  }
  bool _reported = false;

  /// Pista que acaba de quedar sonando. [rate] es el tempo con el que entró
  /// (m/b si el cruce igualó en el punto medio).
  void begin(double naturalBpm, double rate) {
    _gen++;
    _rampGen++;
    natural = naturalBpm;
    _inStep = 0;
    _originSet = false;
    _outFired = false;
    _outNext = 0;
    _outCommitted = false;
    _outRamped = false;
    _reported = false;
    midpointBlocked = false;
    midpointNote = '';
    final bool musical = _musicalBpm(naturalBpm);
    final double entry = musical && rate > 0 ? naturalBpm * rate : 0;
    if (musical && (entry - naturalBpm).abs() >= 0.05) {
      _inPlan = midpointTempoPlan(entry * 2 - naturalBpm, naturalBpm);
      _phaseIn = true;
      active = _inPlan!.incoming.isNotEmpty && !_inPlan!.rateLimited;
      if (_inPlan!.rateLimited) {
        midpointBlocked = true;
        midpointNote = _inPlan!.note;
        active = false;
        _phaseIn = false;
        _inPlan = null;
      }
    } else {
      _inPlan = null;
      _phaseIn = false;
      active = false;
    }
  }

  void stop() {
    _gen++;
    _rampGen++;
    active = false;
    natural = 0.0;
    _phaseIn = false;
    _inPlan = null;
    _outFired = false;
    _outNext = 0;
    _outCommitted = false;
    _outRamped = false;
    _inStep = 99;
    midpointBlocked = false;
    midpointNote = '';
  }

  /// Nota de un punto medio fuera de rango, una sola vez.
  String? takeBlockedReport() {
    if (!midpointBlocked || _reported) return null;
    _reported = true;
    return midpointNote;
  }

  double _clamp(double r) => r.clamp(minRate, maxRate).toDouble();

  double? _arm(double rate, int ms) {
    _rampGen++;
    rampLinear = false;
    rampMs = ms < 400 ? 400 : (ms > 8000 ? 8000 : ms);
    return _clamp(rate);
  }

  /// 3.1.99: rampa lineal sin techo (delta s; hasta ~30 s dentro del rango).
  double? _armLinear(double rate, int ms) {
    _rampGen++;
    rampLinear = true;
    rampMs = ms < kTempoRampStepMs ? kTempoRampStepMs : ms;
    return _clamp(rate);
  }

  /// 3.1.99: suelta la rampa en curso sin tocar el rate (el cruce toma a A
  /// con el rate que tenga y B se iguala a ese).
  void cancelRamp() {
    _rampGen++;
  }

  /// 3.2.0: A vuelve a 1.0 en linea recta a 0.5 BPM/s si una rampa previa
  /// lo movio; suelta el compromiso. Null si A nunca se movio.
  double? _returnHome(double rate) {
    final bool moved = _outRamped;
    _outRamped = false;
    _outCommitted = false;
    if (!moved) return null;
    final double off = (rate - 1.0).abs();
    final int ms = _musicalBpm(natural)
        ? (natural * off / kTempoRampBpmPerSec * 1000).round()
        : kTempoRampStepMs;
    return _armLinear(1.0, ms);
  }

  int _gap(
    List<TempoMark> steps,
    int index,
    int rel, {
    required bool untilMix,
  }) {
    if (index + 1 < steps.length) {
      return steps[index + 1].offsetMs - rel;
    }
    if (untilMix) return -rel;
    final int prev = index > 0
        ? steps[index].offsetMs - steps[index - 1].offsetMs
        : 5000;
    return prev;
  }

  /// El último paso ya vencido, o null si todavía no toca.
  int? _due(List<TempoMark> steps, int from, int rel) {
    int last = -1;
    for (int i = from; i < steps.length; i++) {
      if (rel >= steps[i].offsetMs) {
        last = i;
      } else {
        break;
      }
    }
    return last < 0 ? null : last;
  }

  /// Nuevo rate, o null si no toca. [mixOutMs] es el punto de mezcla de la
  /// pista que suena. [nextBpm] es el BPM real de la que entra.
  double? tick({
    required int posMs,
    required int durMs,
    required int mixOutMs,
    required double rate,
    required double nextBpm,
  }) {
    if (!_musicalBpm(natural) || durMs <= 0) return null;
    if (_phaseIn && _inPlan != null && !_inPlan!.rateLimited) {
      if (!_originSet) {
        _originMs = posMs;
        _originSet = true;
      }
      final int rel = posMs - _originMs;
      final int? due = _due(_inPlan!.incoming, _inStep, rel);
      if (due != null) {
        _inStep = due + 1;
        if (_inStep >= _inPlan!.incoming.length) {
          active = false;
          _phaseIn = false;
        }
        final double target = _inPlan!.incoming[due].bpm / natural;
        final int gap = _gap(_inPlan!.incoming, due, rel, untilMix: false);
        if ((target - rate).abs() >= 0.002 &&
            target >= minRate &&
            target <= maxRate) {
          return _arm(target, gap);
        }
      }
      if (_phaseIn) return null;
    }

    // 3.1.99: rampa simetrica. A va de su rate a m/a en linea recta a
    // 0.5 BPM/s y llega a BPM_mid justo en [mixOutMs] (entrada de B). El
    // arranque queda delta s (reales) antes. Si queda menos (salto, cola
    // nueva, BPM conocido tarde) la rampa se comprime al tiempo que queda;
    // con menos de 200 ms no se mueve y B iguala el rate real de A.
    if (!outgoingRamp) return null;
    // 3.2.0: sin siguiente conocida (quitada a mano, cola vacia, mezcla
    // desarmada) A no se queda en el m/a viejo: vuelve a 1.0.
    if (!_musicalBpm(nextBpm) || mixOutMs <= 0) return _returnHome(rate);
    if (_outFired && (_outNext - nextBpm).abs() <= 0.05) return null;
    final SymmetricTempoPlan plan = symmetricTempoPlan(natural, nextBpm);
    if (!plan.active) {
      _outFired = true;
      _outNext = nextBpm;
      if (plan.blocked) {
        midpointBlocked = true;
        midpointNote = plan.note;
      }
      // 3.2.0: pareja nueva sin plan (< 2 % o fuera de rango): A vuelve
      // suave a 1.0 en vez de quedar en el m/a viejo.
      return _returnHome(rate);
    }
    final int start = mixOutMs - plan.leadTrackMs;
    // 3.2.0: la pareja cambio y su arranque aun no llega: si A ya se habia
    // movido vuelve a 1.0 y la rampa nueva arranca a su hora.
    if (posMs < start - kPreRollLockLeadMs) return _returnHome(rate);
    _outCommitted = true;
    if (posMs < start) return null;
    _outFired = true;
    _outNext = nextBpm;
    _outRamped = true;
    final int remain = mixOutMs - posMs;
    if (remain < kTempoRampStepMs) return null;
    if ((plan.outRate - rate).abs() < 0.002) return null;
    final double avg = (rate + plan.outRate) / 2;
    final int realMs = avg > 0 ? (remain / avg).round() : remain;
    return _armLinear(plan.outRate, realMs);
  }

  /// Rampa lenta (senoidal) del rate. El temporizador es propio: no depende
  /// del reloj de la UI (250 ms) ni de los rebuilds de la carátula.
  /// [hold] congela ese reloj si el usuario pausa; la curva no cambia.
  Future<void> ramp(
    Player p,
    double from,
    double to, {
    int? ms,
    MixPause? hold,
  }) async {
    final int g = _gen;
    final int r = _rampGen;
    final int dur = ms ?? rampMs;
    // 3.1.99: lineal en pasos de 200 ms (rampa simetrica); senoidal en 100 ms.
    final bool linear = rampLinear;
    final int stepMs = linear ? kTempoRampStepMs : 100;
    final int epoch = hold?.epoch ?? 0;
    final MixRunClock clock = hold?.clock() ?? MixRunClock();
    try {
      while (clock.elapsedMilliseconds < dur) {
        if (g != _gen || r != _rampGen) return;
        if (hold != null && hold.epoch != epoch) return;
        if (hold != null && hold.paused) {
          await hold.untilRunning();
          continue;
        }
        final double t = clock.elapsedMilliseconds / dur;
        await p.setRate(
          linear
              ? from + (to - from) * t.clamp(0.0, 1.0)
              : tempoRampValue(from, to, t),
        );
        if (hold != null) {
          await hold.slice(stepMs, clock);
        } else {
          await Future<void>.delayed(Duration(milliseconds: stepMs));
        }
      }
      if (g == _gen && r == _rampGen) await p.setRate(to);
    } catch (_) {}
  }
}

/// Curva de la rampa: seno de cuarto de ciclo, de [from] a [to].
/// Espera hasta el próximo golpe del saliente, menos la latencia de arranque
/// medida ([startupMs]). El saliente avanza [outRate] ms de pista por cada ms
/// real. Cero si no hay que esperar. El llamador solo demora si queda entre
/// 0 y 1500.
int beatPhaseWaitMs({
  required double nowOutMs,
  required double beatMs,
  required double bpm,
  required double outRate,
  required int startupMs,
}) {
  if (bpm <= 0 || outRate <= 0) return 0;
  final double period = 60000.0 / bpm;
  final double k = ((nowOutMs + 60 - beatMs) / period).ceilToDouble();
  final double nextBeat = beatMs + k * period;
  return ((nextBeat - nowOutMs) / outRate).round() - startupMs;
}

double tempoRampValue(double from, double to, double t) {
  final double u = t.clamp(0.0, 1.0);
  return from + (to - from) * sin(u * pi / 2);
}

/// Pasos de la rampa con su propio reloj. 5 s / 100 ms: el mismo recorrido
/// aunque la UI publique la posición solo cada 250 ms.
List<double> tempoRampSchedule(
  double from,
  double to, {
  int ms = 5000,
  int stepMs = 100,
}) {
  if (ms <= 0 || stepMs <= 0) return <double>[to];
  final List<double> out = <double>[];
  for (int elapsed = 0; elapsed < ms; elapsed += stepMs) {
    out.add(tempoRampValue(from, to, elapsed / ms));
  }
  out.add(to);
  return out;
}
