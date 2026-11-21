import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// 3.1.82/3.1.83: iconos nativos con la cara DiFogo.
// 3.2.21: Android, iOS y macOS vuelven al icono GatoMix previo, restaurado
// tal cual desde 8dda273 (padre de 12213f8): cada PNG debe ser uno de los 29
// del icono viejo (v1.0.0 GatoMix / 3.0.22) y ninguno de 3.1.82. El .ico de
// Windows vuelve al GatoMix de 06fec95. Solo lectura de archivos del repo.

const String _res = 'android/app/src/main/res/mipmap-';
const String _ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset/';
const String _mac = 'macos/Runner/Assets.xcassets/AppIcon.appiconset/';

// FNV-1a 32 de los 29 PNG distintos del icono viejo (v1.0.0 GatoMix / 3.0.22).
const Set<int> _oldHashes = <int>{
  0x0061e24f,
  0x01ff723b,
  0x05fe693a,
  0x1d320cbb,
  0x2470dd98,
  0x31a9c9da,
  0x35c4ef4f,
  0x3b43d0a4,
  0x41a34baa,
  0x43350d16,
  0x4fc79945,
  0x82d9672b,
  0x8d57dac8,
  0x92ae9c0d,
  0x952030f4,
  0xa106b179,
  0xb773e43f,
  0xb89aaf84,
  0xbe283a8f,
  0xc69f1e28,
  0xc8db7641,
  0xc9e03ad7,
  0xca2cabdc,
  0xd63a952b,
  0xda561999,
  0xe944bc68,
  0xf16b101a,
  0xf1976012,
  0xfced017d,
};

// 3.1.83: FNV-1a 32 de los 30 PNG distintos de 3.1.82 (huecos en azul).
const Set<int> _navy3182 = <int>{
  0x17e02f95,
  0x271efa83,
  0x2d4c9718,
  0x2d4f2a77,
  0x382d57b2,
  0x40a3f806,
  0x4dcd0cef,
  0x50c5c42c,
  0x50e3d686,
  0x52954573,
  0x585f9a49,
  0x624a07b9,
  0x62a88131,
  0x6652542b,
  0x6939d5ae,
  0x6ccd6d4f,
  0x76989be6,
  0x92de452b,
  0xad51afac,
  0xae964467,
  0xbd1fb639,
  0xcbac1573,
  0xcc86a0fc,
  0xd5776e54,
  0xd7795359,
  0xf4f3e903,
  0xf755d568,
  0xfa648f5b,
  0xfd21a1d3,
  0xffac3094,
};

int _fnv(Uint8List b) {
  int h = 0x811c9dc5;
  for (final int x in b) {
    h ^= x;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

Future<List<int>> _size(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.Image img = (await codec.getNextFrame()).image;
  return <int>[img.width, img.height];
}

// PNG GatoMix restaurado: hash del set viejo y no del set DiFogo 3.1.82.
Future<List<int>> _load(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  expect(_oldHashes.contains(_fnv(bytes)), isTrue, reason: '$path GatoMix');
  expect(_navy3182.contains(_fnv(bytes)), isFalse, reason: '$path 3.1.82');
  return _size(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('3.2.21 Windows: app_icon.ico GatoMix multi-resolucion', () {
    final Uint8List b = File(
      'windows/runner/resources/app_icon.ico',
    ).readAsBytesSync();
    final ByteData d = ByteData.sublistView(b);
    final Set<int> sizes = <int>{};
    for (int k = 0; k < d.getUint16(4, Endian.little); k++) {
      final int e = 6 + 16 * k;
      sizes.add(b[e] == 0 ? 256 : b[e]);
    }
    expect(sizes, <int>{16, 24, 32, 48, 64, 128, 256});
  });

  testWidgets('3.2.21 Android: icono GatoMix heredado y adaptativo', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      const Map<String, List<int>> dens = <String, List<int>>{
        'mdpi': <int>[48, 108],
        'hdpi': <int>[72, 162],
        'xhdpi': <int>[96, 216],
        'xxhdpi': <int>[144, 324],
        'xxxhdpi': <int>[192, 432],
      };
      for (final MapEntry<String, List<int>> d in dens.entries) {
        final List<int> leg = await _load('$_res${d.key}/ic_launcher.png');
        expect(leg, <int>[d.value[0], d.value[0]], reason: d.key);
        final List<int> fg = await _load(
          '$_res${d.key}/ic_launcher_foreground.png',
        );
        expect(fg, <int>[d.value[1], d.value[1]], reason: d.key);
      }
      final String colors = File(
        'android/app/src/main/res/values/colors.xml',
      ).readAsStringSync();
      expect(colors.contains('#1C1C1E'), isTrue);
      final String adaptive = File(
        'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
      ).readAsStringSync();
      expect(adaptive.contains('@mipmap/ic_launcher_foreground'), isTrue);
    });
  });

  testWidgets('3.2.21 iOS: tamanos de Contents.json con icono GatoMix', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Map<String, dynamic> c =
          jsonDecode(File('${_ios}Contents.json').readAsStringSync())
              as Map<String, dynamic>;
      final Set<String> seen = <String>{};
      for (final dynamic i in c['images'] as List<dynamic>) {
        final Map<String, dynamic> m = i as Map<String, dynamic>;
        final String file = m['filename'] as String;
        if (!seen.add(file)) continue;
        final double pt = double.parse((m['size'] as String).split('x').first);
        final int scale = int.parse((m['scale'] as String).substring(0, 1));
        final List<int> p = await _load('$_ios$file');
        expect(p, <int>[(pt * scale).round(), (pt * scale).round()]);
      }
      expect(seen.contains('Icon-App-1024x1024@1x.png'), isTrue);
    });
  });

  testWidgets('3.2.21 macOS: icono GatoMix en los 7 tamanos', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      for (final int s in <int>[16, 32, 64, 128, 256, 512, 1024]) {
        final List<int> p = await _load('${_mac}app_icon_$s.png');
        expect(p, <int>[s, s]);
      }
    });
  });
}
