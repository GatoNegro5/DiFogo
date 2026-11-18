import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/queue_bpm.dart';
import 'package:difogo/services/track_tags.dart';
import 'package:difogo/src/rust/frb_generated.dart';

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

// 3.1.50: la libreria Rust compilada depende de la plataforma; en CI
// (Linux) los tests de Flutter corren antes de compilar Rust y no existe:
// el test se salta en vez de tumbar el release.
String _rustLib() {
  const String dir = 'rust/target/release';
  if (Platform.isWindows) return '$dir/rust_lib_gatomix_player.dll';
  if (Platform.isMacOS) return '$dir/librust_lib_gatomix_player.dylib';
  return '$dir/librust_lib_gatomix_player.so';
}

void main() {
  final String lib = _rustLib();
  final bool hasLib = File(lib).existsSync();
  late Directory tmp;
  setUpAll(() async {
    if (!hasLib) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(lib));
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
  }, skip: hasLib ? false : 'sin libreria Rust compilada: $lib');
}
