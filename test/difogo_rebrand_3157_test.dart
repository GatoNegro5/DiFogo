import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 3.1.57: rebranding visible GatoMix -> DiFogo. Solo lectura de fuentes.
String _read(String p) => File(p).readAsStringSync();

void main() {
  test('3.1.57 textos visibles Dart dicen DiFogo', () {
    const List<String> files = <String>[
      'lib/core/audio/cue_preview.dart',
      'lib/services/tv_adb_deployment_service.dart',
      'lib/ui/workspaces/karaoke_workspace.dart',
      'lib/ui/workspaces/lan_sync_workspace.dart',
    ];
    // Identificadores internos que se conservan a proposito.
    const List<String> allowed = <String>[
      'GatoMix TV Sync',
      'GatoMix REST Server',
      'GatoNegro5/GatoMix/releases',
    ];
    for (final String f in files) {
      String src = _read(f);
      for (final String a in allowed) {
        src = src.replaceAll(a, '');
      }
      final Iterable<String> left = src
          .split('\n')
          .where((String l) => l.contains('GatoMix'))
          .where((String l) => !l.trim().startsWith('//'))
          .where((String l) => !l.contains('GatoMixTheme'))
          .where((String l) => !l.contains('GatoMixMobileModeBar'));
      expect(left, isEmpty, reason: f);
    }
    expect(_read(files[0]).contains("'DiFogo CUE'"), isTrue);
    expect(
      'DiFogo Karaoke'.allMatches(_read(files[1])).length,
      greaterThanOrEqualTo(3),
    );
    expect(_read(files[2]).contains('abre DiFogo Karaoke'), isTrue);
    expect(_read(files[3]).contains('<title>DiFogo Karaoke</title>'), isTrue);
  });

  test('3.1.57 se conservan firewall, protocolo y URL del APK', () {
    expect(
      _read(
        'lib/ui/workspaces/karaoke_workspace.dart',
      ).contains("'GatoMix TV Sync'"),
      isTrue,
    );
    expect(
      _read(
        'lib/ui/workspaces/lan_sync_workspace.dart',
      ).contains("'GatoMix REST Server'"),
      isTrue,
    );
    expect(
      _read('lib/services/tv_sync_server.dart').contains("'gatomix-karaoke'"),
      isTrue,
    );
    expect(
      _read(
        'lib/services/tv_adb_deployment_service.dart',
      ).contains('download/gatomix-tv.apk'),
      isTrue,
    );
  });

  test('3.1.57 nombres nativos visibles Win y Mac', () {
    final String rc = _read('windows/runner/Runner.rc');
    expect(rc.contains('VALUE "ProductName", "DiFogo"'), isTrue);
    expect(rc.contains('"gatomix_player.exe"'), isTrue);
    final String plist = _read('macos/Runner/Info.plist');
    expect(
      RegExp(
        r'<key>CFBundleName</key>\s*<string>DiFogo</string>',
      ).hasMatch(plist),
      isTrue,
    );
    expect(
      RegExp(
        r'<key>CFBundleDisplayName</key>\s*<string>DiFogo</string>',
      ).hasMatch(plist),
      isTrue,
    );
    expect(
      _read(
        'macos/Runner/Configs/AppInfo.xcconfig',
      ).contains('PRODUCT_NAME = GatoMix'),
      isTrue,
    );
  });
}
