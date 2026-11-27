// 3.2.32 (DIF-29): detector barato de empalmes (pedazo de otra cancion
// pegado). Mismo criterio que `rust/src/anti_splice.rs::splice_scan`:
// ventanas de 250 ms con RMS (dB) y cruces por cero (brillo).
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

const int _winMs = 250;

double _mean(List<double> v) =>
    v.isEmpty ? 0 : v.reduce((double a, double b) => a + b) / v.length;

double _ratio(double a, double b) {
  final double x = math.max(a, 1e-4);
  final double y = math.max(b, 1e-4);
  return x > y ? x / y : y / x;
}

/// - "reinicio" (despues del primer 10 %): hueco >= 1,5 s por debajo de
///   (pico - 35 dB) y luego >= 3 s fuertes (>= pico - 20 dB).
/// - "escalon" (ultimo 45 %): salto brusco entre dos ventanas (>= 6 dB o
///   brillo x1,6) sostenido 3 s a cada lado (>= 9 dB o brillo x1,8).
List<SpliceHit> spliceScan(List<double> mono, int rate) {
  final int n = math.max(1, rate * _winMs ~/ 1000);
  final List<double> db = <double>[];
  final List<double> zc = <double>[];
  for (int o = 0; o + n ~/ 2 <= mono.length && o < mono.length; o += n) {
    final int end = math.min(o + n, mono.length);
    if (end - o < n ~/ 2) break;
    double e = 0;
    int c = 0;
    for (int i = o; i < end; i++) {
      e += mono[i] * mono[i];
      if (i > o && (mono[i] >= 0) != (mono[i - 1] >= 0)) c++;
    }
    final int len = end - o;
    db.add(10 * math.log(e / len + 1e-12) / math.ln10);
    zc.add(c / len);
  }
  final List<SpliceHit> hits = <SpliceHit>[];
  if (db.length < 40) return hits;
  final double peak = db.reduce(math.max);
  final double quiet = peak - 35;
  final double loud = peak - 20;
  const int side = 12;
  int i = db.length ~/ 10;
  while (i < db.length) {
    if (db[i] < quiet) {
      int j = i;
      while (j < db.length && db[j] < quiet) {
        j++;
      }
      if (j - i >= 6 && j + side <= db.length) {
        final List<double> after = db.sublist(j, j + side);
        if (after.where((double d) => d >= loud).length >= side * 3 ~/ 4) {
          hits.add(
            SpliceHit(
              j * _winMs,
              'reinicio',
              'hueco de ${(j - i) * _winMs} ms y luego '
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
  int k = math.max(db.length * 55 ~/ 100, side);
  while (k + side <= db.length) {
    final List<double> bDb = db.sublist(k - side, k);
    final List<double> aDb = db.sublist(k, k + side);
    final List<double> bZc = zc.sublist(k - side, k);
    final List<double> aZc = zc.sublist(k, k + side);
    final bool audible = _mean(bDb) > quiet + 10 && _mean(aDb) > quiet + 10;
    final bool sharp =
        (db[k] - db[k - 1]).abs() >= 6 || _ratio(zc[k], zc[k - 1]) >= 1.6;
    final bool held =
        (_mean(aDb) - _mean(bDb)).abs() >= 9 ||
        _ratio(_mean(aZc), _mean(bZc)) >= 1.8;
    if (audible && sharp && held) {
      hits.add(
        SpliceHit(
          k * _winMs,
          'escalon',
          '${(_mean(aDb) - _mean(bDb)).toStringAsFixed(1)} dB, brillo '
              'x${_ratio(_mean(aZc), _mean(bZc)).toStringAsFixed(2)}',
        ),
      );
      k += side;
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
