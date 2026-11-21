import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.1.60: escudo logo3 en splash e icono .ico DiFogo.
// 3.2.21: splash con gatomix_logo.png y app_icon.ico GatoMix restaurado
// desde 06fec95 (arte previo a 3.1.60).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('3.2.21 logo y wordmark GatoMix cargan via rootBundle', () async {
    for (final String a in <String>[
      'assets/branding/gatomix_logo.png',
      'assets/branding/gatomix_wordmark.png',
    ]) {
      final ByteData d = await rootBundle.load(a);
      expect(d.lengthInBytes, File(a).lengthSync(), reason: a);
      expect(d.getUint32(0), 0x89504E47, reason: a);
    }
  });

  test('3.2.21 app_icon.ico GatoMix multi-resolucion valido', () {
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
    expect(sizes, <int>{16, 24, 32, 48, 64, 128, 256});
  });

  test('3.2.21 splash usa gatomix_logo y no queda banner', () {
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
    ]) {
      final String src = File(f).readAsStringSync();
      expect(
        src.contains("'assets/branding/gatomix_logo.png'"),
        isTrue,
        reason: f,
      );
      expect(src.contains('difogo_logo3'), isFalse, reason: f);
    }
    expect(File('assets/branding/difogo_banner.png').existsSync(), isFalse);
    expect(
      File('pubspec.yaml').readAsStringSync().contains('difogo_banner'),
      isFalse,
    );
  });
}
