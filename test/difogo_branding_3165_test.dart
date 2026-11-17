import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// 3.1.65: sidebar solo con el escudo logo3 a 120 px (sin wordmark debajo) e
// icono nativo recortado a la cara del gato con las llamas. Solo lectura.
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
  // El arte (cabeza + llamas) es mas alto que ancho (0,85): el lado mayor
  // llena >= 90 % y el menor conserva la proporcion sin deformar (>= 75 %).
  final double big = fw > fh ? fw : fh;
  final double small = fw > fh ? fh : fw;
  expect(big, greaterThanOrEqualTo(0.90), reason: '$name lado mayor $big');
  expect(big, lessThanOrEqualTo(0.97), reason: '$name margen $big');
  expect(small, greaterThanOrEqualTo(0.75), reason: '$name lado menor $small');
  // Margen simetrico (diferencia <= 2 px a 256 o su equivalente).
  final int tol = (p.w / 128).ceil();
  expect((x0 - (p.w - 1 - x1)).abs(), lessThanOrEqualTo(tol), reason: name);
  expect((y0 - (p.h - 1 - y1)).abs(), lessThanOrEqualTo(tol), reason: name);
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

  testWidgets('3165 difogo_logo.png e icono .ico llenan el lienzo', (
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
