import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// 3.1.65: sidebar solo con el escudo logo3 a 120 px (sin wordmark debajo).
// 3.2.21: el sidebar vuelve al wordmark GatoMix (arte previo a 3.1.59) en la
// misma cabecera de 120 px; el .ico vuelve al GatoMix previo. Solo lectura.
class _Px {
  _Px(this.w, this.h);
  final int w;
  final int h;
}

Future<_Px> _decode(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.Image img = (await codec.getNextFrame()).image;
  return _Px(img.width, img.height);
}

// Imagen PNG de la entrada 256 del .ico.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('3.2.21 sidebar: wordmark GatoMix a 120 px y luego la version', () {
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
    ]) {
      final String src = File(f).readAsStringSync();
      expect(src.contains('difogo_wordmark'), isFalse, reason: f);
      expect(src.contains('difogo_logo3'), isFalse, reason: f);
      final int at = src.indexOf("Key('sidebar-logo')");
      expect(at, greaterThan(0), reason: f);
      final String before = src.substring(at - 120, at);
      expect(
        before.contains("'assets/branding/gatomix_wordmark.png'"),
        isTrue,
        reason: f,
      );
      final String after = src.substring(at, at + 120);
      expect(after.contains('height: 120,'), isTrue, reason: f);
      expect(after.contains('fit: BoxFit.contain'), isTrue, reason: f);
      final int ver = src.indexOf('const AppVersionLabel()', at);
      expect(ver, greaterThan(at), reason: f);
      expect(src.substring(at, ver).contains('Image.asset'), isFalse);
    }
  });

  testWidgets('3.2.21 app_icon.ico GatoMix con entrada 256 decodificable', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Uint8List ico = File(
        'windows/runner/resources/app_icon.ico',
      ).readAsBytesSync();
      final _Px i256 = await _decode(_ico256(ico));
      expect(i256.w, 256);
      expect(i256.h, 256);
    });
  });
}
