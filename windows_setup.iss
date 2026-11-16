#ifndef AppVer
  #define AppVer "1.0.0"
#endif
[Setup]
; AppId fijo = AppName anterior: actualiza la instalacion GatoMix existente
AppId=GatoMix
AppName=DiFogo
AppVersion={#AppVer}
DefaultDirName={autopf}\DiFogo
DefaultGroupName=DiFogo
OutputDir=.\
OutputBaseFilename=DiFogo-Installer
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

[Icons]
Name: "{group}\DiFogo"; Filename: "{app}\gatomix_player.exe"
Name: "{autodesktop}\DiFogo"; Filename: "{app}\gatomix_player.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Iconos adicionales:"