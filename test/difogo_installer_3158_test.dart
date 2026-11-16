import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 3.1.58: instalador y release DiFogo. Solo lectura de fuentes.
String _read(String p) => File(p).readAsStringSync();

void main() {
  test('3.1.58 windows_setup.iss DiFogo con AppId heredado', () {
    final String iss = _read('windows_setup.iss');
    expect(
      RegExp(r'^AppId=GatoMix\s*$', multiLine: true).hasMatch(iss),
      isTrue,
    );
    expect(
      RegExp(r'^AppName=DiFogo\s*$', multiLine: true).hasMatch(iss),
      isTrue,
    );
    expect(iss.contains(r'DefaultDirName={autopf}\DiFogo'), isTrue);
    expect(iss.contains('DefaultGroupName=DiFogo'), isTrue);
    expect(iss.contains('OutputBaseFilename=DiFogo-Installer'), isTrue);
    expect(iss.contains('[InstallDelete]'), isTrue);
    expect(iss.contains(r'Type: files; Name: "{group}\GatoMix.lnk"'), isTrue);
    expect(
      iss.contains(r'Type: files; Name: "{autodesktop}\GatoMix.lnk"'),
      isTrue,
    );
    expect(
      iss.contains(
        r'Name: "{group}\DiFogo"; Filename: "{app}\gatomix_player.exe"',
      ),
      isTrue,
    );
    expect(
      iss.contains(
        r'Name: "{autodesktop}\DiFogo"; Filename: "{app}\gatomix_player.exe"',
      ),
      isTrue,
    );
    expect(iss.contains('AppName=GatoMix'), isFalse);
    expect(iss.contains('GatoMix-Installer'), isFalse);
  });

  test('3.1.58 release.yml publica DiFogo y conserva TV y firma', () {
    final String yml = _read('.github/workflows/release.yml');
    expect(yml.contains('GatoMix-Installer'), isFalse);
    expect(yml.contains('GatoMix-MacOS'), isFalse);
    expect(yml.contains(r'name: GatoMix ${{'), isFalse);
    expect('DiFogo-Installer.exe'.allMatches(yml).length, 3);
    expect('DiFogo-MacOS.zip'.allMatches(yml).length, 4);
    expect(r'name: DiFogo ${{ github.ref_name }}'.allMatches(yml).length, 3);
    expect(yml.contains('gatomix-tv.apk'), isTrue);
    expect(yml.contains('gatomix-release.jks'), isTrue);
    expect(yml.contains('working-directory: gatomix_tv'), isTrue);
    expect(yml.contains('ISCC.exe'), isTrue);
    expect(yml.contains('windows_setup.iss'), isTrue);
  });
}
