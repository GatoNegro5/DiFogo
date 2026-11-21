import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 3.1.57: rebranding visible GatoMix -> DiFogo; 3.2.18: vuelve a GatoMix.
// Solo lectura de fuentes.
String _read(String p) => File(p).readAsStringSync();

void main() {
  test('3.2.18 textos visibles Dart dicen GatoMix', () {
    const List<String> files = <String>[
      'lib/core/audio/cue_preview.dart',
      'lib/services/tv_adb_deployment_service.dart',
      'lib/ui/workspaces/karaoke_workspace.dart',
      'lib/ui/workspaces/lan_sync_workspace.dart',
    ];
    // Identificadores internos que se conservan a proposito.
    const List<String> allowed = <String>[
      'DiFogo TV Sync',
      'DiFogo REST Server',
      'GatoNegro5/DiFogo/releases',
    ];
    for (final String f in files) {
      String src = _read(f);
      for (final String a in allowed) {
        src = src.replaceAll(a, '');
      }
      final Iterable<String> left = src
          .split('\n')
          .where((String l) => l.contains('DiFogo'))
          .where((String l) => !l.trim().startsWith('//'));
      expect(left, isEmpty, reason: f);
    }
    expect(_read(files[0]).contains("'GatoMix CUE'"), isTrue);
    expect(
      'GatoMix Karaoke'.allMatches(_read(files[1])).length,
      greaterThanOrEqualTo(3),
    );
    expect(_read(files[2]).contains('abre GatoMix Karaoke'), isTrue);
    expect(_read(files[3]).contains('<title>GatoMix Karaoke</title>'), isTrue);
    // 3.2.18: titulo de la app y textos de UI.
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
      'lib/core/audio/dj_audio_handler.dart',
      'lib/ui/workspaces/livedj_workspace.dart',
      'lib/ui/workspaces/dsp_workspace.dart',
    ]) {
      final Iterable<String> left = _read(f)
          .split('\n')
          .where((String l) => l.contains("'DiFogo") || l.contains('"DiFogo'))
          .where((String l) => !l.trim().startsWith('//'));
      expect(left, isEmpty, reason: f);
    }
    expect(_read('lib/main.dart').contains("title: 'GatoMix',"), isTrue);
    expect(_read('lib/djiphone/main.dart').contains("title: 'GatoMix',"), isTrue);
    // Recursos e imports internos que se conservan. 3.2.23: desde 3.2.21 el
    // sidebar usa el wordmark GatoMix restaurado del historial.
    expect(
      _read('lib/main.dart').contains('assets/branding/gatomix_wordmark.png'),
      isTrue,
    );
    expect(_read('pubspec.yaml').contains('name: difogo'), isTrue);
  });

  test('3.1.57 se conservan firewall, protocolo y URL del APK', () {
    // 3.1.76: reglas DiFogo; las GatoMix quedan solo para borrarlas.
    final String kw = _read('lib/ui/workspaces/karaoke_workspace.dart');
    expect(kw.contains("'DiFogo TV Sync'"), isTrue);
    expect(kw.contains("'GatoMix TV Sync'"), isTrue);
    final String lw = _read('lib/ui/workspaces/lan_sync_workspace.dart');
    expect(lw.contains("'DiFogo REST Server'"), isTrue);
    expect(lw.contains("'GatoMix REST Server'"), isTrue);
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

  test('3.2.18 nombres nativos visibles Win, Mac, Android e iPhone', () {
    final String rc = _read('windows/runner/Runner.rc');
    expect(rc.contains('VALUE "ProductName", "GatoMix"'), isTrue);
    expect(rc.contains('VALUE "FileDescription", "GatoMix"'), isTrue);
    // 3.1.76: el exe de Windows sigue siendo difogo.exe.
    expect(rc.contains('VALUE "OriginalFilename", "difogo.exe"'), isTrue);
    expect(rc.contains('VALUE "InternalName", "difogo"'), isTrue);
    expect(rc.contains('gatomix_player'), isFalse);
    expect(
      _read('windows/runner/main.cpp').contains('window.Create(L"GatoMix"'),
      isTrue,
    );
    for (final String p in <String>[
      'macos/Runner/Info.plist',
      'ios/Runner/Info.plist',
    ]) {
      final String plist = _read(p);
      expect(
        RegExp(
          r'<key>CFBundleName</key>\s*<string>GatoMix</string>',
        ).hasMatch(plist),
        isTrue,
        reason: p,
      );
      expect(
        RegExp(
          r'<key>CFBundleDisplayName</key>\s*<string>GatoMix</string>',
        ).hasMatch(plist),
        isTrue,
        reason: p,
      );
      expect(plist.contains('DiFogo'), isFalse, reason: p);
    }
    final String xc = _read('macos/Runner/Configs/AppInfo.xcconfig');
    expect(xc.contains('PRODUCT_NAME = GatoMix'), isTrue);
    expect(
      xc.contains('PRODUCT_BUNDLE_IDENTIFIER = com.gatonegro5.gatomix'),
      isTrue,
    );
    // El proyecto Xcode sigue al PRODUCT_NAME (GatoMix.app).
    final String pbx = _read('macos/Runner.xcodeproj/project.pbxproj');
    expect(pbx.contains('DiFogo'), isFalse);
    expect('GatoMix.app'.allMatches(pbx).length, 7);
    expect(
      _read(
        'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
      ).contains('DiFogo'),
      isFalse,
    );
    expect(
      _read(
        'android/app/src/main/AndroidManifest.xml',
      ).contains('android:label="GatoMix"'),
      isTrue,
    );
  });
}
