import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// 3.1.65: sidebar solo con el escudo logo3 a 120 px (sin wordmark debajo).
// 3.1.66: icono nativo acercado 1,46x a la cara del gato. Solo lectura.
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

// Imagen PNG de la entrada 256 del .ico (Pillow guarda cada tamano como PNG).
Uint8List _ico256(Uint8List b) {
  final ByteData d = ByteData.sublistView(b);
  final int n = d.getUint16(4, Endian.little);
  for (int k = 0; k < n; k++) {
    final int e = 6 + 16 * k;
    if (b[e] == 0) {
      final int len = d.getUint32(e + 8, Endian.little);
      final int off = d.getUint32(e + 12, Endian.little);
      return Uint8List.sublistView(b, off, off + len);
    }
  }
  throw StateError('sin entrada 256');
}

void _checkFill(_Px p, String name) {
  int x0 = p.w, y0 = p.h, x1 = -1, y1 = -1;
  for (int y = 0; y < p.h; y++) {
    for (int x = 0; x < p.w; x++) {
      if (p.alpha(x, y) > 32) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  final double fw = (x1 - x0 + 1) / p.w;
  final double fh = (y1 - y0 + 1) / p.h;
  // 3.1.66: acercamiento 1,46x a la cabeza con audifonos; el arte llega a los
  // cuatro bordes (llamas recortadas) y cubre la mayor parte del lienzo.
  expect(fw, greaterThanOrEqualTo(0.99), reason: '$name ancho $fw');
  expect(fh, greaterThanOrEqualTo(0.99), reason: '$name alto $fh');
  int opaque = 0;
  for (int y = 0; y < p.h; y++) {
    for (int x = 0; x < p.w; x++) {
      if (p.alpha(x, y) > 32) opaque++;
    }
  }
  final double cover = opaque / (p.w * p.h);
  expect(cover, greaterThanOrEqualTo(0.75), reason: '$name cobertura $cover');
  // Esquinas transparentes: parche de 1/32 del lado en cada esquina.
  final int n = p.w ~/ 32;
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      expect(p.alpha(x, y), 0, reason: '$name esquina sup-izq');
      expect(p.alpha(p.w - 1 - x, y), 0, reason: '$name esquina sup-der');
      expect(p.alpha(x, p.h - 1 - y), 0, reason: '$name esquina inf-izq');
      expect(p.alpha(p.w - 1 - x, p.h - 1 - y), 0, reason: name);
    }
  }
  for (final List<int> c in <List<int>>[
    <int>[0, 0],
    <int>[p.w - 1, 0],
    <int>[0, p.h - 1],
    <int>[p.w - 1, p.h - 1],
  ]) {
    expect(p.alpha(c[0], c[1]), 0, reason: '$name esquina $c');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('3165 sidebar: solo logo3 a 120 px y luego la version', () {
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
    ]) {
      final String src = File(f).readAsStringSync();
      expect(src.contains('difogo_wordmark'), isFalse, reason: f);
      final int at = src.indexOf("Key('sidebar-logo')");
      expect(at, greaterThan(0), reason: f);
      final String before = src.substring(at - 120, at);
      expect(before.contains("'assets/branding/difogo_logo3.png'"), isTrue);
      final String after = src.substring(at, at + 120);
      expect(after.contains('height: 120,'), isTrue, reason: f);
      expect(after.contains('fit: BoxFit.contain'), isTrue, reason: f);
      final int ver = src.indexOf('const AppVersionLabel()', at);
      expect(ver, greaterThan(at), reason: f);
      expect(src.substring(at, ver).contains('Image.asset'), isFalse);
    }
  });

  testWidgets('3165/3166 difogo_logo.png e icono .ico acercados al gato', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final _Px logo = await _decode(
        File('assets/branding/difogo_logo.png').readAsBytesSync(),
      );
      expect(logo.w, 1024);
      expect(logo.h, 1024);
      _checkFill(logo, 'difogo_logo.png');
      final Uint8List ico = File(
        'windows/runner/resources/app_icon.ico',
      ).readAsBytesSync();
      final _Px i256 = await _decode(_ico256(ico));
      expect(i256.w, 256);
      _checkFill(i256, 'app_icon.ico 256');
    });
  });
}
