import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/queue_bpm.dart';
import 'package:gatomix/services/track_tags.dart';
import 'package:gatomix/src/rust/frb_generated.dart';

// 3.1.46: sin (N BPM) en el nombre y sin .gatomix.json, knownBpm da 0 hasta
// que TrackTags.load lee el TBPM (Rust); luego lo resuelve por peek.
// Archivo sintetico en %TEMP%, nunca en la biblioteca.
List<int> _id3Tbpm(String bpm) {
  final List<int> body = <int>[0, ...bpm.codeUnits];
  final List<int> frame = <int>[
    ...'TBPM'.codeUnits,
    0,
    0,
    0,
    body.length,
    0,
    0,
    ...body,
  ];
  final int s = frame.length;
  return <int>[
    ...'ID3'.codeUnits,
    3,
    0,
    0,
    (s >> 21) & 0x7f,
    (s >> 14) & 0x7f,
    (s >> 7) & 0x7f,
    s & 0x7f,
    ...frame,
  ];
}

void main() {
  late Directory tmp;
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        'rust/target/release/rust_lib_gatomix_player.dll',
      ),
    );
    tmp = Directory.systemTemp.createTempSync('gmx3146_');
  });
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('knownBpm 0 -> TrackTags.load -> TBPM sin nombre ni JSON', () async {
    final File f = File(
      '${tmp.path}${Platform.pathSeparator}Cancion Sin Token.mp3',
    )..writeAsBytesSync(<int>[..._id3Tbpm('124'), ...List<int>.filled(512, 0)]);
    expect(knownBpm(f.path), 0);
    final TrackTags t = await TrackTags.load(f.path);
    expect(t.bpm, 124);
    expect(knownBpm(f.path), 124);
  });
}
