import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// 3.1.82: iconos nativos de Windows, Android, iOS y macOS con la cara del
// gato a sangre (sin margenes vacios), recortada de
// assets/branding/difogo_logo.png: cuadro de 800 px en (112,160)-(912,960)
// con audifonos completos; los huecos del arte se tapan con su azul #0E152A.
// Solo lectura de archivos del repo.

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

int _fnv(Uint8List b) {
  int h = 0x811c9dc5;
  for (final int x in b) {
    h ^= x;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

class _Px {
  _Px(this.w, this.h, this.data);
  final int w;
  final int h;
  final ByteData data;
  int alpha(int x, int y) => data.getUint8((y * w + x) * 4 + 3);
}

Future<_Px> _decode(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.Image img = (await codec.getNextFrame()).image;
  final ByteData? px = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return _Px(img.width, img.height, px!);
}

Future<_Px> _load(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  expect(_oldHashes.contains(_fnv(bytes)), isFalse, reason: '$path viejo');
  return _decode(bytes);
}

// Cobertura opaca y caja del arte (alfa > 32) en fraccion del lienzo.
void _fills(_Px p, String name, {double minCover = 0.95}) {
  int x0 = p.w, y0 = p.h, x1 = -1, y1 = -1, n = 0;
  for (int y = 0; y < p.h; y++) {
    for (int x = 0; x < p.w; x++) {
      if (p.alpha(x, y) > 32) {
        n++;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  expect((x1 - x0 + 1) / p.w, greaterThanOrEqualTo(0.95), reason: name);
  expect((y1 - y0 + 1) / p.h, greaterThanOrEqualTo(0.95), reason: name);
  expect(n / (p.w * p.h), greaterThanOrEqualTo(minCover), reason: name);
}

void _opaque(_Px p, String name) {
  for (int y = 0; y < p.h; y++) {
    for (int x = 0; x < p.w; x++) {
      if (p.alpha(x, y) != 255) fail('$name con alfa en $x,$y');
    }
  }
}

// Entradas del .ico: tamano -> PNG o DIB de esa entrada.
Map<int, Uint8List> _icoEntries(Uint8List b) {
  final ByteData d = ByteData.sublistView(b);
  final Map<int, Uint8List> out = <int, Uint8List>{};
  for (int k = 0; k < d.getUint16(4, Endian.little); k++) {
    final int e = 6 + 16 * k;
    final int len = d.getUint32(e + 8, Endian.little);
    final int off = d.getUint32(e + 12, Endian.little);
    out[b[e] == 0 ? 256 : b[e]] = Uint8List.sublistView(b, off, off + len);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('3182 Windows: app_icon.ico a sangre en sus 6 tamanos', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Map<int, Uint8List> e = _icoEntries(
        File('windows/runner/resources/app_icon.ico').readAsBytesSync(),
      );
      expect(e.keys.toSet(), <int>{16, 32, 48, 64, 128, 256});
      final _Px p = await _decode(e[256]!);
      expect(p.w, 256);
      _opaque(p, 'ico 256');
      _fills(p, 'ico 256', minCover: 1);
    });
  });

  testWidgets('3182 Android: heredado y adaptativo a sangre', (
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
        final _Px leg = await _load('$_res${d.key}/ic_launcher.png');
        expect(leg.w, d.value[0], reason: d.key);
        expect(leg.h, d.value[0], reason: d.key);
        _opaque(leg, 'ic_launcher ${d.key}');
        final _Px fg = await _load('$_res${d.key}/ic_launcher_foreground.png');
        expect(fg.w, d.value[1], reason: d.key);
        expect(fg.h, d.value[1], reason: d.key);
        // Sin margen transparente: el arte llena los 108dp y la mascara del
        // launcher recorta; lo visible (72dp) es el mismo cuadro de la cara.
        _opaque(fg, 'ic_launcher_foreground ${d.key}');
      }
      final String colors = File(
        'android/app/src/main/res/values/colors.xml',
      ).readAsStringSync();
      expect(colors.contains('#0E152A'), isTrue);
      final String adaptive = File(
        'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
      ).readAsStringSync();
      expect(adaptive.contains('@mipmap/ic_launcher_foreground'), isTrue);
    });
  });

  testWidgets('3182 iOS: tamanos de Contents.json, opaco a sangre', (
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
        final _Px p = await _load('$_ios$file');
        expect(p.w, (pt * scale).round(), reason: file);
        expect(p.h, (pt * scale).round(), reason: file);
        _opaque(p, file);
      }
      expect(seen.contains('Icon-App-1024x1024@1x.png'), isTrue);
    });
  });

  testWidgets('3182 macOS: cara llenando el cuadro redondeado', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      for (final int s in <int>[16, 32, 64, 128, 256, 512, 1024]) {
        final _Px p = await _load('${_mac}app_icon_$s.png');
        expect(p.w, s);
        expect(p.h, s);
        _fills(p, 'mac $s');
        expect(p.alpha(s ~/ 2, 0), 255, reason: '$s borde superior');
        expect(p.alpha(0, s ~/ 2), 255, reason: '$s borde izquierdo');
      }
    });
  });
}
