import 'dart:math';

/// 3.1.90: retorno al BPM natural (rate 1.0) despues del handoff.
///
/// Durante el cruce el master lock no se toca. Cuando la saliente ya salio
/// y la entrante queda sola, su rate vuelve a 1.0 en una rampa ease-in-out
/// de 4 a 8 s (proporcional a la diferencia), en pasos de 200 ms, cada uno
/// de 0.02 como maximo, y termina en 1.0 exacto. mpv conserva el tono
/// (`audio-pitch-correction`), igual que en el resto de los cambios de rate.

/// Diferencia con 1.0 por debajo de la cual no hay rampa.
const double kPostMixRateEpsilon = 0.003;

/// Piso y techo de la rampa.
const int kPostMixMinMs = 4000;
const int kPostMixMaxMs = 8000;

/// Un micro-paso cada 200 ms.
const int kPostMixStepMs = 200;

/// Paso maximo permitido entre dos rates seguidos.
const double kPostMixMaxStep = 0.02;

/// Milisegundos por unidad de rate: 0.16 (0.84x) da 8 s, 0.08 da 4 s.
const int kPostMixMsPerUnit = 50000;

/// Duracion de la rampa desde [fromRate]; 0 = no hace falta.
int postMixRecoveryMs(double fromRate) {
  if (!fromRate.isFinite || fromRate <= 0) return 0;
  final double d = (fromRate - 1.0).abs();
  if (d <= kPostMixRateEpsilon) return 0;
  final int ms = (d * kPostMixMsPerUnit).round();
  if (ms < kPostMixMinMs) return kPostMixMinMs;
  if (ms > kPostMixMaxMs) return kPostMixMaxMs;
  return ms;
}

/// Curva ease-in-out (medio coseno) de [from] a 1.0; [t] en 0..1.
double postMixRateAt(double from, double t) {
  final double u = t.clamp(0.0, 1.0).toDouble();
  return from + (1.0 - from) * (1 - cos(u * pi)) / 2;
}

/// Rates de cada micro-paso; el ultimo es 1.0 exacto. Vacio si no hay
/// rampa.
List<double> postMixRecoverySchedule(
  double fromRate, {
  int stepMs = kPostMixStepMs,
}) {
  final int ms = postMixRecoveryMs(fromRate);
  if (ms == 0 || stepMs <= 0) return const <double>[];
  final int n = (ms / stepMs).ceil();
  return <double>[
    for (int i = 1; i < n; i++) postMixRateAt(fromRate, i / n),
    1.0,
  ];
}

/// Corre la rampa con su propio reloj (no depende del tick de posicion).
/// Un solo recorrido a la vez: [run] o [cancel] sueltan el anterior.
class PostMixTempoRecovery {
  int _gen = 0;
  bool _running = false;

  bool get running => _running;

  /// Suelta la rampa en curso sin tocar el rate.
  void cancel() {
    _gen++;
    _running = false;
  }

  /// true si llego a 1.0 por la rampa. [alive] false (cruce nuevo, salto,
  /// otra pista) suelta sin tocar; [paused] true deja 1.0 en silencio
  /// (el deck esta parado) y termina. [wait] solo lo cambian las pruebas.
  Future<bool> run({
    required double fromRate,
    required Future<void> Function(double rate) setRate,
    required bool Function() alive,
    required bool Function() paused,
    Future<void> Function(Duration step)? wait,
    int stepMs = kPostMixStepMs,
  }) async {
    final int g = ++_gen;
    final List<double> steps = postMixRecoverySchedule(
      fromRate,
      stepMs: stepMs,
    );
    if (steps.isEmpty) {
      _running = false;
      // Diferencia minima (<= 0.003): 1.0 directo, inaudible.
      if (fromRate.isFinite && fromRate > 0 && fromRate != 1.0) {
        try {
          await setRate(1.0);
        } catch (_) {}
      }
      return false;
    }
    final Future<void> Function(Duration) delay =
        wait ?? ((Duration d) => Future<void>.delayed(d));
    _running = true;
    try {
      for (int i = 0; i < steps.length; i++) {
        if (g != _gen || !alive()) return false;
        if (paused()) {
          await setRate(1.0);
          return false;
        }
        await setRate(steps[i]);
        if (i < steps.length - 1) {
          await delay(Duration(milliseconds: stepMs));
        }
      }
      return g == _gen;
    } catch (_) {
      return false;
    } finally {
      if (g == _gen) _running = false;
    }
  }
}
