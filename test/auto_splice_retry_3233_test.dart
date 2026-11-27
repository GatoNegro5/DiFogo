// 3.2.33 (DIF-30): arreglo automatico de empalmes. Reintentos sin avisos,
// registro al agotarse, detector sin "escalon" y fixture estatico de las 9
// canciones de DIF-29 (no reabre audio).
import 'dart:io';
import 'dart:math' as math;

import 'package:difogo/core/splice_detector.dart';
import 'package:difogo/core/splice_retry.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> _tone(double hz, double secs, int rate, [double amp = 0.5]) =>
    List<double>.generate(
      (secs * rate).round(),
      (int i) => amp * math.sin(2 * math.pi * hz * i / rate),
    );

Map<String, List<double>> _fixture() {
  final Map<String, List<double>> out = <String, List<double>>{};
  for (final String l in File(
    'test/fixtures/splice_frames_3233.txt',
  ).readAsLinesSync()) {
    final int t = l.indexOf('\t');
    if (t <= 0) continue;
    out[l.substring(0, t)] = l
        .substring(t + 1)
        .codeUnits
        .map((int c) => -(c - 33).toDouble())
        .toList();
  }
  return out;
}

void main() {
  test('reintento: empalme se rehace 2 veces y luego sale', () async {
    int runs = 0;
    final List<int> redos = <int>[];
    await expectLater(
      retryOnSplice<void>(
        run: () async {
          runs++;
          throw 'Empalme evitado: detector corte en 1 ms';
        },
        redo: (int n) async => redos.add(n),
      ),
      throwsA(predicate((Object e) => isSpliceError(e))),
    );
    expect(runs, 3);
    expect(redos, <int>[1, 2]);
  });

  test('reintento: pasa al segundo intento', () async {
    int runs = 0;
    final int v = await retryOnSplice<int>(
      run: () async {
        runs++;
        if (runs == 1) throw 'Empalme evitado: el temporal dura 9 ms';
        return 7;
      },
      redo: (_) async {},
    );
    expect(v, 7);
    expect(runs, 2);
  });

  test('reintento: otros errores y "sin reintento" no se rehacen', () async {
    int redo = 0;
    await expectLater(
      retryOnSplice<void>(
        run: () async => throw 'Fallo LAME',
        redo: (_) async => redo++,
      ),
      throwsA('Fallo LAME'),
    );
    await expectLater(
      retryOnSplice<void>(
        run: () async => throw 'Empalme evitado: x, sin _K, sin reintento',
        redo: (_) async => redo++,
      ),
      throwsA(predicate((Object e) => isSpliceNoRetry(e))),
    );
    expect(redo, 0);
  });

  test('registro: una linea por caso agotado', () {
    final Directory d = Directory.systemTemp.createTempSync('gmx3233');
    spliceLogOverride = '${d.path}${Platform.pathSeparator}e.log';
    logSpliceEvent('YT abc Cancion', 'Empalme evitado: detector corte');
    final List<String> lines = File(spliceLogOverride!).readAsLinesSync();
    expect(lines, hasLength(1));
    expect(lines.single, contains('YT abc Cancion\tEmpalme evitado'));
    spliceLogOverride = null;
    d.deleteSync(recursive: true);
  });

  test('detector: corte (se apaga y entra otra de golpe)', () {
    const int r = 8000;
    final List<double> s = <double>[
      ..._tone(440, 40, r),
      ..._tone(440, 3.5, r, 0.05),
      ..._tone(1200, 8, r),
    ];
    expect(spliceScan(s, r).any((SpliceHit h) => h.kind == 'corte'), isTrue);
  });

  test('fixture DIF-29: las 9 limpias sin marcas (igual que Rust)', () {
    final Map<String, List<double>> f = _fixture();
    expect(f, hasLength(18));
    for (final MapEntry<String, List<double>> e in f.entries) {
      expect(spliceScanFrames(e.value), isEmpty, reason: e.key);
    }
  });

  test('cableado: YT, Master, _K y Rust', () {
    final String yt = File(
      'lib/ui/workspaces/yt_workspace.dart',
    ).readAsStringSync();
    expect(yt, contains('retryOnSplice<void>('));
    expect(yt, contains('sourceKbps = await fetchRaw();'));
    expect(yt, contains("logSpliceEvent('YT"));
    final String mt = File('lib/services/master_track.dart').readAsStringSync();
    expect(mt, contains("logSpliceEvent('Master"));
    final String ke = File(
      'lib/services/karaoke_engine.dart',
    ).readAsStringSync();
    expect(ke, contains("logSpliceEvent('K"));
    final String dsp = File('rust/src/api/core_dsp.rs').readAsStringSync();
    expect(dsp, contains('splice_gate(&tmp, Some(&input_path))'));
    expect(dsp, contains('splice_gate(&input_path, None)'));
    expect(dsp, contains('crate::anti_splice::splice_retryable(e)'));
    final String g = File('rust/src/anti_splice.rs').readAsStringSync();
    expect(g, contains('SPLICE_RETRIES: u32 = 2'));
    expect(g, isNot(contains('kind: "escalon"')));
  });
}
