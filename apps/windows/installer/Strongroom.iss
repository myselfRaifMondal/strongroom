; Strongroom for Windows - Inno Setup 6 script (needs 6.3 or newer).
;
; Built by .github/workflows/windows-installer.yml:
;   ISCC.exe /DAppVersion=0.1.0 /DAppVersionNumeric=0.1.0.0 /DArch=x64 ^
;            /DSourceDir=<publish folder> /DIconFile=<Strongroom.ico> ^
;            /DOutputDir=<folder> apps\windows\installer\Strongroom.iss
;
; Design rules:
;  * Per-user install by default (no admin): %LOCALAPPDATA%\Programs\Strongroom.
;    "Install for all users" is offered on the first page (needs admin).
;  * The vault lives in %LOCALAPPDATA%\Strongroom, a different folder. Neither
;    the installer nor the uninstaller ever touches it: the uninstaller removes
;    only the files listed under [Files] (and the folder if it is then empty).
;  * No .vtf file association: the app does not open files passed on its
;    command line, so an association would only start the app.
;  * Unsigned for now. See the disabled signing step in the workflow.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef AppVersionNumeric
  #define AppVersionNumeric "0.1.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\out\publish-" + Arch
#endif
#ifndef IconFile
  #define IconFile "..\src\Strongroom.App\Assets\Strongroom.ico"
#endif
#ifndef OutputDir
  #define OutputDir "out"
#endif

#if Arch == "x64"
  ; x64compatible = x64 Windows, plus Windows 11 on ARM (x64 emulation).
  #define ArchAllowed "x64compatible"
#elif Arch == "arm64"
  #define ArchAllowed "arm64"
#else
  #error Arch must be x64 or arm64
#endif

#define AppName "Strongroom"
#define AppExe "Strongroom.exe"

[Setup]
; Never change AppId: it is how upgrades and the uninstaller find this app.
AppId={{6B0F3C1E-5E7A-4C55-9A6E-1D2F0B9C7A41}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Strongroom contributors
AppPublisherURL=https://github.com/myselfRaifMondal/strongroom
AppSupportURL=https://github.com/myselfRaifMondal/strongroom/issues
AppUpdatesURL=https://github.com/myselfRaifMondal/strongroom/releases
AppComments=Local-only password manager. Your vault stays on this PC.
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductVersion={#AppVersionNumeric}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup

; Per-user by default; the user may pick "all users" (admin) in a dialog or
; with /ALLUSERS. {autopf} is %LOCALAPPDATA%\Programs for a per-user install
; and Program Files for an all-users install.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
UsePreviousAppDir=yes

ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#ArchAllowed}
; Windows 10 version 1809 (build 17763) is the oldest Windows App SDK supports.
MinVersion=10.0.17763

SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=Strongroom-Setup-{#AppVersion}-{#Arch}
; Close a running Strongroom before replacing its files (upgrade/uninstall).
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#IconFile}"; DestDir: "{app}"; DestName: "Strongroom.ico"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; IconFilename: "{app}\Strongroom.ico"; Comment: "Open your Strongroom vault"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; IconFilename: "{app}\Strongroom.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Deliberately no [UninstallDelete] section: nothing outside the installed
; files is removed, so the vault folder can never be deleted by uninstall.

[Code]
function VaultFolder(): String;
begin
  Result := ExpandConstant('{localappdata}\Strongroom');
end;

function IsSameOrInside(const Path, Folder: String): Boolean;
var
  P, F: String;
begin
  P := AddBackslash(Lowercase(ExpandFileName(Path)));
  F := AddBackslash(Lowercase(ExpandFileName(Folder)));
  Result := Copy(P, 1, Length(F)) = F;
end;

// Refuse an install folder that is (or is inside) the vault folder, so the
// program files and the user's data can never end up mixed together.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and IsSameOrInside(WizardDirValue, VaultFolder()) then
  begin
    MsgBox('Please choose a different folder. ' + VaultFolder() +
      ' is where Strongroom keeps your vault, so the program cannot be installed there.',
      mbError, MB_OK);
    Result := False;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
      'Your vault will be kept in ' + VaultFolder() + '. Updating or uninstalling Strongroom never deletes it.';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Msg: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Msg := 'Strongroom has been removed. Your vault was NOT deleted.' + #13#10#13#10 +
      'It is still in:' + #13#10 + '    ' + VaultFolder() + #13#10#13#10 +
      'If you install Strongroom again it will find it. If you want to remove it ' +
      'for good, first make sure you have an export or no longer need the passwords, ' +
      'then delete that folder yourself.';
    Log(Msg);
    if not UninstallSilent then
      MsgBox(Msg, mbInformation, MB_OK);
  end;
end;
