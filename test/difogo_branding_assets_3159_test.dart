import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.1.59: logos oficiales DiFogo. Solo lectura de fuentes y assets.
const List<String> _assets = <String>[
  'assets/branding/difogo_logo.png',
  'assets/branding/difogo_wordmark.png',
  'assets/branding/difogo_banner.png',
];

bool _isPng(List<int> b) =>
    b.length > 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('3.1.59 los 3 PNG DiFogo existen y son PNG reales', () {
    for (final String a in _assets) {
      final File f = File(a);
      expect(f.existsSync(), isTrue, reason: a);
      expect(f.lengthSync(), greaterThan(1024), reason: a);
      expect(_isPng(f.readAsBytesSync().sublist(0, 16)), isTrue, reason: a);
    }
  });

  test('3.1.59 los 3 PNG cargan via rootBundle', () async {
    for (final String a in _assets) {
      final ByteData d = await rootBundle.load(a);
      expect(d.lengthInBytes, File(a).lengthSync(), reason: a);
      expect(_isPng(d.buffer.asUint8List(0, 16)), isTrue, reason: a);
    }
  });

  test('3.1.59 sin JPG sueltos en assets/branding', () {
    final Iterable<String> jpg = Directory('assets/branding')
        .listSync()
        .whereType<File>()
        .map((File f) => f.path.toLowerCase())
        .where((String p) => p.endsWith('.jpg') || p.endsWith('.jpeg'));
    expect(jpg, isEmpty);
  });

  test('3.1.59 laptop e iPhone usan los logos DiFogo', () {
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
    ]) {
      final String src = File(f).readAsStringSync();
      expect(src.contains('gatomix_logo.png'), isFalse, reason: f);
      expect(src.contains('gatomix_wordmark.png'), isFalse, reason: f);
      expect(
        src.contains("'assets/branding/difogo_logo.png'"),
        isTrue,
        reason: f,
      );
      expect(
        src.contains("'assets/branding/difogo_wordmark.png'"),
        isTrue,
        reason: f,
      );
    }
    final String pub = File('pubspec.yaml').readAsStringSync();
    for (final String a in _assets) {
      expect(pub.contains('- $a'), isTrue, reason: a);
    }
  });
}
