import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.1.60: escudo logo3 en splash, fondos transparentes e icono .ico DiFogo.
int _w = 0;
int _h = 0;

Future<ByteData> _rgba(String asset) async {
  final ByteData raw = await rootBundle.load(asset);
  final ui.Codec codec = await ui.instantiateImageCodec(
    raw.buffer.asUint8List(),
  );
  final ui.Image img = (await codec.getNextFrame()).image;
  final ByteData? px = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  _w = img.width;
  _h = img.height;
  return px!;
}

int _alpha(ByteData px, int x, int y) => px.getUint8((y * _w + x) * 4 + 3);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('3.1.60 logo, logo3 y wordmark cargan via rootBundle', () async {
    for (final String a in <String>[
      'assets/branding/difogo_logo.png',
      'assets/branding/difogo_logo3.png',
      'assets/branding/difogo_wordmark.png',
    ]) {
      final ByteData d = await rootBundle.load(a);
      expect(d.lengthInBytes, File(a).lengthSync(), reason: a);
      expect(d.getUint32(0), 0x89504E47, reason: a);
    }
  });

  testWidgets('3.1.60 logo3 y wordmark con esquinas transparentes', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      for (final String a in <String>[
        'assets/branding/difogo_logo3.png',
        'assets/branding/difogo_wordmark.png',
      ]) {
        final ByteData px = await _rgba(a);
        for (final List<int> c in <List<int>>[
          <int>[0, 0],
          <int>[_w - 1, 0],
          <int>[0, _h - 1],
          <int>[_w - 1, _h - 1],
        ]) {
          expect(_alpha(px, c[0], c[1]), 0, reason: '$a $c');
        }
        // El centro sigue opaco: se quito el fondo sin comer el dibujo.
        expect(_alpha(px, _w ~/ 2, _h ~/ 2), 255, reason: a);
      }
    });
  });

  test('3.1.60 app_icon.ico multi-resolucion valido', () {
    final Uint8List b = File(
      'windows/runner/resources/app_icon.ico',
    ).readAsBytesSync();
    final ByteData d = ByteData.sublistView(b);
    expect(d.getUint16(0, Endian.little), 0);
    expect(d.getUint16(2, Endian.little), 1);
    final int n = d.getUint16(4, Endian.little);
    final Set<int> sizes = <int>{};
    for (int k = 0; k < n; k++) {
      final int e = 6 + 16 * k;
      final int s = b[e] == 0 ? 256 : b[e];
      sizes.add(s);
      final int len = d.getUint32(e + 8, Endian.little);
      final int off = d.getUint32(e + 12, Endian.little);
      expect(off + len, lessThanOrEqualTo(b.length), reason: '$s');
      expect(len, greaterThan(40), reason: '$s');
    }
    expect(sizes, <int>{16, 32, 48, 64, 128, 256});
  });

  test('3.1.60 splash usa logo3 y no queda banner', () {
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
    ]) {
      final String src = File(f).readAsStringSync();
      expect(
        src.contains("'assets/branding/difogo_logo3.png'"),
        isTrue,
        reason: f,
      );
      expect(
        src.contains("'assets/branding/difogo_wordmark.png'"),
        isFalse, // 3.1.65: wordmark fuera del sidebar
        reason: f,
      );
      expect(src.contains('gatomix_logo.png'), isFalse, reason: f);
    }
    expect(File('assets/branding/difogo_banner.png').existsSync(), isFalse);
    expect(
      File('pubspec.yaml').readAsStringSync().contains('difogo_banner'),
      isFalse,
    );
  });
}
