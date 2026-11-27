// 3.2.32 (DIF-29) / 3.2.33 (DIF-30): detector barato de empalmes (pedazo de
// otra cancion pegado). Mismo criterio que `rust/src/anti_splice.rs`
// (`scan_frames`): ventanas de 500 ms con RMS (dB). El "escalon" de brillo
// de 3.2.32 se quito (falsos positivos en musica limpia y en las _K).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:difogo/src/rust/api/core_dsp.dart' as rust_dsp;

class SpliceHit {
  const SpliceHit(this.atMs, this.kind, this.detail);
  final int atMs;
  final String kind;
  final String detail;

  @override
  String toString() => '$kind ${fmtSpliceMs(atMs)} ($detail)';
}

String fmtSpliceMs(int ms) {
  final int s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

const int spliceWinMs = 500;
const int _side = 6; // 3 s
const int _gapMin = 3; // 1,5 s
const double _quietDb = 35;
const double _loudDb = 20;
const double _dipDb = 18;
const double _jumpDb = 12;

double _mean(List<double> v) =>
    v.isEmpty ? 0 : v.reduce((double a, double b) => a + b) / v.length;

/// RMS (dB) por ventana de 500 ms.
List<double> spliceFrames(List<double> mono, int rate) {
  final int n = math.max(1, rate * spliceWinMs ~/ 1000);
  final List<double> db = <double>[];
  for (int o = 0; o < mono.length; o += n) {
    final int end = math.min(o + n, mono.length);
    if (end - o < n ~/ 2) break;
    double e = 0;
    for (int i = o; i < end; i++) {
      e += mono[i] * mono[i];
    }
    db.add(10 * math.log(e / (end - o) + 1e-12) / math.ln10);
  }
  return db;
}

List<SpliceHit> spliceScan(List<double> mono, int rate) =>
    spliceScanFrames(spliceFrames(mono, rate));

/// - "reinicio" (despues del 10 %): hueco >= 1,5 s por debajo de
///   (pico - 35 dB) y luego >= 3 s fuertes (>= pico - 20 dB).
/// - "corte" (despues del 50 %): 3 s con media <= pico - 18 dB y salto de
///   >= 12 dB en una ventana a >= 3 s fuertes.
List<SpliceHit> spliceScanFrames(List<double> db) {
  final List<SpliceHit> hits = <SpliceHit>[];
  if (db.length < 20) return hits;
  final double peak = db.reduce(math.max);
  final double quiet = peak - _quietDb;
  final double loud = peak - _loudDb;
  bool strong(List<double> v) =>
      v.where((double d) => d >= loud).length >= _side * 3 ~/ 4;
  int i = db.length ~/ 10;
  while (i < db.length) {
    if (db[i] < quiet) {
      int j = i;
      while (j < db.length && db[j] < quiet) {
        j++;
      }
      if (j - i >= _gapMin && j + _side <= db.length) {
        final List<double> after = db.sublist(j, j + _side);
        if (strong(after)) {
          hits.add(
            SpliceHit(
              j * spliceWinMs,
              'reinicio',
              'hueco de ${(j - i) * spliceWinMs} ms y luego '
                  '${(_mean(after) - peak).toStringAsFixed(1)} dB',
            ),
          );
        }
      }
      i = math.max(j, i + 1);
    } else {
      i++;
    }
  }
  int k = math.max(db.length ~/ 2, _side);
  while (k + _side <= db.length) {
    final double before = _mean(db.sublist(k - _side, k));
    final double jump = db[k] - db[k - 1];
    final int at = k * spliceWinMs;
    final bool near = hits.any(
      (SpliceHit h) => (h.atMs - at).abs() <= _side * spliceWinMs,
    );
    if (!near &&
        before <= peak - _dipDb &&
        jump >= _jumpDb &&
        strong(db.sublist(k, k + _side))) {
      hits.add(
        SpliceHit(
          at,
          'corte',
          'final a ${(before - peak).toStringAsFixed(1)} dB y salto de '
              '+${jump.toStringAsFixed(1)} dB',
        ),
      );
      k += _side;
    } else {
      k++;
    }
  }
  return hits;
}

/// PCM s16le mono (lo que devuelve `decodeMonoPcm`) a muestras -1..1.
List<double> pcm16ToDouble(Uint8List bytes) {
  final ByteData b = ByteData.sublistView(bytes);
  return List<double>.generate(
    bytes.length ~/ 2,
    (int i) => b.getInt16(i * 2, Endian.little) / 32768.0,
  );
}

class SpliceReport {
  const SpliceReport(this.durationMs, this.hits);
  final int durationMs;
  final List<SpliceHit> hits;
  bool get clean => hits.isEmpty;

  String get text => clean
      ? 'Sin empalmes (${fmtSpliceMs(durationMs)})'
      : 'Posible empalme (${fmtSpliceMs(durationMs)}): ${hits.join('; ')}';
}

/// Lee el audio completo a 16 kHz mono con el motor (solo lectura).
Future<SpliceReport> detectSpliceFile(String path) async {
  final int ms = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
  const int rate = 16000;
  final Uint8List pcm = await rust_dsp.decodeMonoPcm(
    inputPath: path,
    startSecs: 0,
    lengthSecs: ms ~/ 1000 + 2,
    targetRate: rate,
  );
  return SpliceReport(ms, spliceScan(pcm16ToDouble(pcm), rate));
}
