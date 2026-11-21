#ifndef AppVer
  #define AppVer "1.0.0"
#endif
[Setup]
; AppId fijo: actualiza la instalacion GatoMix existente
; 3.2.18: AppName vuelve a GatoMix; carpeta, exe e instalador siguen DiFogo
AppId=GatoMix
AppName=GatoMix
AppVersion={#AppVer}
DefaultDirName={autopf}\DiFogo
DefaultGroupName=GatoMix
OutputDir=.\
OutputBaseFilename=GatoMix-Installer
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
SetupIconFile=windows\runner\resources\app_icon.ico

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Accesos directos viejos de GatoMix: evita iconos duplicados al actualizar
Type: files; Name: "{group}\GatoMix.lnk"
Type: files; Name: "{autodesktop}\GatoMix.lnk"
; 3.2.18: accesos directos DiFogo de 3.1.58 a 3.2.17
Type: files; Name: "{group}\DiFogo.lnk"
Type: files; Name: "{autodesktop}\DiFogo.lnk"
; 3.1.76: el exe paso a difogo.exe; borra el exe viejo huerfano al actualizar
Type: files; Name: "{app}\gatomix_player.exe"

[Icons]
Name: "{group}\GatoMix"; Filename: "{app}\difogo.exe"
Name: "{autodesktop}\GatoMix"; Filename: "{app}\difogo.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Iconos adicionales:"