#ifndef AppVer
  #define AppVer "1.0.0"
#endif
[Setup]
; AppId fijo: actualiza la instalacion GatoMix existente
; 3.2.35: carpeta {autopf}\GatoMix; el exe sigue siendo difogo.exe
AppId=GatoMix
AppName=GatoMix
AppVersion={#AppVer}
DefaultDirName={autopf}\GatoMix
DefaultGroupName=GatoMix
; Si la previa (registro GatoMix_is1) apunta a ...\Programs\DiFogo,
; InitializeWizard fuerza GatoMix. UsePreviousAppDir sigue en yes para
; no perder una ruta personalizada que no sea DiFogo.
UsePreviousAppDir=yes
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
; Accesos directos DiFogo de 3.1.58 a 3.2.34
Type: files; Name: "{group}\DiFogo.lnk"
Type: files; Name: "{autodesktop}\DiFogo.lnk"
; 3.1.76: el exe paso a difogo.exe; borra el exe viejo huerfano al actualizar
Type: files; Name: "{app}\gatomix_player.exe"
; La carpeta huerfana {localappdata}\Programs\DiFogo se limpia en [Code]

[Icons]
Name: "{group}\GatoMix"; Filename: "{app}\difogo.exe"
Name: "{autodesktop}\GatoMix"; Filename: "{app}\difogo.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Iconos adicionales:"

[Code]
function IsLegacyDiFogoDir(const P: String): Boolean;
var
  Clean, Leaf, Parent: String;
begin
  Clean := RemoveBackslash(P);
  Leaf := ExtractFileName(Clean);
  Parent := ExtractFileName(ExtractFileDir(Clean));
  Result := (CompareText(Leaf, 'DiFogo') = 0) and
            (CompareText(Parent, 'Programs') = 0);
end;

procedure ForceGatoMixDir;
begin
  if IsLegacyDiFogoDir(WizardDirValue) then
    WizardForm.DirEdit.Text := ExpandConstant('{autopf}\GatoMix');
end;

procedure InitializeWizard;
begin
  ForceGatoMixDir;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then
    ForceGatoMixDir;
end;

{ Nuestra carpeta huerfana: hay difogo.exe (y tipicamente DLLs).
  Si hay unins000.exe SIN difogo.exe, es otra app: no se toca. }
function DirIsOurOrphan(const Dir: String): Boolean;
begin
  Result := False;
  if not DirExists(Dir) then
    Exit;
  if not FileExists(Dir + '\difogo.exe') then
    Exit;
  Result := True;
end;

procedure DelTreeSafe(const Dir: String);
begin
  if DirIsOurOrphan(Dir) then
    DelTree(Dir, True, True, True);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Orphan, AppDir: String;
begin
  if CurStep = ssPostInstall then
  begin
    AppDir := RemoveBackslash(ExpandConstant('{app}'));
    Orphan := RemoveBackslash(ExpandConstant('{localappdata}\Programs\DiFogo'));
    if CompareText(Orphan, AppDir) <> 0 then
      DelTreeSafe(Orphan);
  end;
end;
