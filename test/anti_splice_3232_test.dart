// 3.2.32 (DIF-29): blindaje anti-empalme. Detector, temporal unico de
// Descargas YT y entrada del Laboratorio (sin cambiar su layout).
import 'dart:io';
import 'dart:math' as math;

import 'package:difogo/core/splice_detector.dart';
import 'package:difogo/ui/workspaces/yt_workspace.dart' show ytRawTempPath;
import 'package:flutter_test/flutter_test.dart';

List<double> _tone(double hz, double secs, int rate, [double amp = 0.5]) =>
    List<double>.generate(
      (secs * rate).round(),
      (int i) => amp * math.sin(2 * math.pi * hz * i / rate),
    );

void main() {
  const int r = 8000;

  test('detector: pedazo de otra cancion tras el final (reinicio)', () {
    final List<double> s = <double>[
      ..._tone(440, 40, r),
      ...List<double>.filled((1.5 * r).round(), 0),
      ..._tone(1200, 8, r),
    ];
    final List<SpliceHit> hits = spliceScan(s, r);
    expect(hits.any((SpliceHit h) => h.kind == 'reinicio'), isTrue);
    expect(hits.first.atMs, inInclusiveRange(41000, 42000));
  });

  // 3.2.33: el "escalon" de brillo ya no marca (falsos positivos).
  test('detector: solo cambio de brillo ya no marca', () {
    final List<double> s = <double>[..._tone(300, 40, r), ..._tone(1500, 8, r)];
    expect(spliceScan(s, r), isEmpty);
  });

  test('detector: pista limpia y pista corta sin marcas', () {
    expect(spliceScan(_tone(440, 48, r), r), isEmpty);
    expect(spliceScan(_tone(440, 5, r), r), isEmpty);
    expect(const SpliceReport(185000, <SpliceHit>[]).text, contains('3:05'));
  });

  test('YT: temporal crudo unico por video, nunca raw_vr_audio', () {
    final String a = ytRawTempPath('T', '-EVyF_2DSdo');
    final String b = ytRawTempPath('T', 'W1LsRShUPtY');
    expect(a, isNot(b));
    expect(a, endsWith('raw_-EVyF_2DSdo.m4a'));
    expect(ytRawTempPath('T', 'a/b'), endsWith('raw_a_b.m4a'));
    final String src = File(
      'lib/ui/workspaces/yt_workspace.dart',
    ).readAsStringSync();
    expect(src, isNot(contains("raw_vr_audio.m4a'")));
    expect(src, contains('rawToClean = tempRawPath;'));
    expect(
      File('lib/yt_workspace.dart').readAsStringSync(),
      isNot(contains("raw_vr_audio.m4a'")),
    );
  });

  test('Laboratorio: "Detectar empalme" en el menu de la pista', () {
    final String lab = File(
      'lib/ui/workspaces/lab_workspace.dart',
    ).readAsStringSync();
    expect(lab, contains("value: 'splice'"));
    expect(lab, contains("if (value == 'splice') _detectSplice(fileName);"));
    expect(lab, contains('detectSpliceFile(path)'));
  });

  test('Rust: temporales unicos, una salida por trabajo y verificacion', () {
    final String dsp = File('rust/src/api/core_dsp.rs').readAsStringSync();
    expect(dsp, isNot(contains('format!("{input_path}.gmxpart")')));
    expect(dsp, isNot(contains('format!("{output_path}.part")')));
    expect(dsp, isNot(contains('format!("{output}.part")')));
    expect(dsp, contains('verify_part(&tmp, part_expect_ms, kbps)'));
    expect(
      RegExp(r'claim_output\(').allMatches(dsp).length,
      greaterThanOrEqualTo(3),
    );
    final String guard = File('rust/src/anti_splice.rs').readAsStringSync();
    expect(guard, contains('.create_new(true)'));
  });
}
