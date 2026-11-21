import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 3.1.58: instalador y release DiFogo. Solo lectura de fuentes.
String _read(String p) => File(p).readAsStringSync();

void main() {
  // 3.2.18: AppName y accesos directos vuelven a GatoMix; carpeta, exe e
  // instalador conservan DiFogo (CI y firmas).
  test('3.2.18 windows_setup.iss GatoMix con AppId heredado', () {
    final String iss = _read('windows_setup.iss');
    expect(
      RegExp(r'^AppId=GatoMix\s*$', multiLine: true).hasMatch(iss),
      isTrue,
    );
    expect(
      RegExp(r'^AppName=GatoMix\s*$', multiLine: true).hasMatch(iss),
      isTrue,
    );
    expect(iss.contains(r'DefaultDirName={autopf}\DiFogo'), isTrue);
    expect(iss.contains('DefaultGroupName=GatoMix'), isTrue);
    expect(iss.contains('OutputBaseFilename=DiFogo-Installer'), isTrue);
    expect(iss.contains('[InstallDelete]'), isTrue);
    expect(iss.contains(r'Type: files; Name: "{group}\GatoMix.lnk"'), isTrue);
    expect(
      iss.contains(r'Type: files; Name: "{autodesktop}\GatoMix.lnk"'),
      isTrue,
    );
    expect(iss.contains(r'Type: files; Name: "{group}\DiFogo.lnk"'), isTrue);
    expect(
      iss.contains(r'Type: files; Name: "{autodesktop}\DiFogo.lnk"'),
      isTrue,
    );
    expect(
      iss.contains(r'Name: "{group}\GatoMix"; Filename: "{app}\difogo.exe"'),
      isTrue,
    );
    expect(
      iss.contains(
        r'Name: "{autodesktop}\GatoMix"; Filename: "{app}\difogo.exe"',
      ),
      isTrue,
    );
    // 3.1.76: exe difogo.exe; el gatomix_player.exe viejo se borra al actualizar.
    expect(
      iss.contains(r'Type: files; Name: "{app}\gatomix_player.exe"'),
      isTrue,
    );
    expect('gatomix_player.exe'.allMatches(iss).length, 1);
    expect(iss.contains('AppName=DiFogo'), isFalse);
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
    // 3.1.77: keystore temporal difogo-release.jks; el apk de TV no cambia.
    expect(yml.contains('difogo-release.jks'), isTrue);
    expect(yml.contains('gatomix-release.jks'), isFalse);
    expect(yml.contains('shared-key: "gatomix'), isFalse);
    expect(yml.contains('working-directory: gatomix_tv'), isTrue);
    expect(yml.contains('ISCC.exe'), isTrue);
    expect(yml.contains('windows_setup.iss'), isTrue);
  });
}
