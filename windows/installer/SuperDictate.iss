; Inno Setup script for SuperDictate (Windows).
;
; Builds a per-user installer: the app writes only to %LOCALAPPDATA% and
; needs no driver or service, so requiring an admin prompt would buy
; nothing and would break installing on a locked-down work machine.
;
; Compile after `build.ps1` has produced dist\SuperDictate\:
;   & "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer\SuperDictate.iss

#define AppName        "SuperDictate"
#define AppVersion     "0.8.2"
#define AppPublisher   "SuperDictate Next"
#define AppURL         "https://github.com/shohart/SuperDictate-Next"
#define AppExeName     "SuperDictate.exe"
; Must match superdictate.system.APP_USER_MODEL_ID, or the taskbar treats a
; pinned shortcut and the running window as two different applications.
#define AppUserModelID "local.SuperDictate"

[Setup]
AppId={{2271EBB1-D4F4-4FCA-949C-F03C760A700A}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; A NEW AppId, deliberately: this is a different product from a different
; publisher than the "Dictation" fork this port grew out of, and reusing
; that AppId would have our installer silently overwrite somebody else's
; application. The cost is that a machine with both installed lists both —
; correct, if untidy. The app's own data directory does migrate: see
; LEGACY_APP_NAMES in superdictate/paths.py.
;
; Directory and Start-menu group are taken from this script rather than
; from whatever a previous install recorded, and the leftovers are removed
; after the files are in place (see CurStepChanged).
UsePreviousAppDir=no
UsePreviousGroup=no
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=SuperDictate-{#AppVersion}-setup
SetupIconFile=..\assets\SuperDictate.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Per-user: nothing here touches HKLM, Program Files or a service.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; The speech model is ~640 MB and is downloaded on first run, so the
; installer itself stays small.
MinVersion=10.0.17763

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "{cm:AutoStartDescription}"; \
    GroupDescription: "{cm:AutoStartGroup}"

[CustomMessages]
russian.AutoStartGroup=Автозапуск:
russian.AutoStartDescription=Запускать SuperDictate при входе в Windows
russian.LaunchApp=Запустить SuperDictate
english.AutoStartGroup=Startup:
english.AutoStartDescription=Start SuperDictate when I sign in to Windows
english.LaunchApp=Launch SuperDictate

[Files]
Source: "..\dist\SuperDictate\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; The executable and the shortcuts were named D1CT until 1.8.0. Upgrading
; in place would otherwise leave a second, stale copy of the app behind
; and two entries in the Start menu.
Type: files; Name: "{app}\D1CT.exe"
Type: files; Name: "{group}\D1CT.lnk"
Type: files; Name: "{autodesktop}\D1CT.lnk"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; \
    AppUserModelID: "{#AppUserModelID}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; \
    AppUserModelID: "{#AppUserModelID}"; Tasks: desktopicon

[Registry]
; --minimized so an autostarted copy goes straight to the tray instead of
; throwing its control panel at you every login.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "{#AppName}"; \
    ValueData: """{app}\{#AppExeName}"" --minimized"; \
    Flags: uninsdeletevalue; Tasks: autostart
; The app was called D1CT before 1.8.0 and SuperDictate before 1.5.0. Those
; autostart entries point at executables this installer no longer ships, so
; they would fail silently at every login if left in place.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: none; ValueName: "D1CT"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: none; ValueName: "SuperDictate"; Flags: deletevalue

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchApp}"; \
    Flags: nowait postinstall skipifsilent

[UninstallRun]
; The app lives in the tray; a running copy would keep its files locked.
Filename: "{cmd}"; Parameters: "/C taskkill /IM {#AppExeName} /F"; \
    Flags: runhidden; RunOnceId: "StopSuperDictate"

[Code]
const
  SHCNE_ASSOCCHANGED = $08000000;
  SHCNF_IDLIST       = $0000;

procedure SHChangeNotify(EventId: LongInt; Flags: Cardinal;
                         Item1, Item2: LongInt);
  external 'SHChangeNotify@shell32.dll stdcall';

// A copy running in the tray holds its own files open, so an upgrade
// either fails to replace them or defers the replacement to a reboot.
// Uninstall already does this; installing had been relying on the user
// having quit first.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/C taskkill /IM {#AppExeName} /F', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/C taskkill /IM D1CT.exe /F', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

// Explorer caches the icon it has seen for an executable, so after the
// artwork changed the taskbar and the Start menu kept drawing the old one
// until something told the shell to look again.
procedure CurStepChanged(CurStep: TSetupStep);
var
  LegacyDir: String;
  LegacyGroup: String;
begin
  if CurStep = ssPostInstall then
  begin
    // Anyone who installed back when the app was called D1CT has been
    // upgrading into a folder of that name ever since. The files are in
    // the right place by now, so the old one can go — carefully, since
    // a custom install directory could in principle be that very path.
    LegacyDir := ExpandConstant('{localappdata}\Programs\D1CT');
    if DirExists(LegacyDir) and
       (CompareText(LegacyDir, ExpandConstant('{app}')) <> 0) then
      DelTree(LegacyDir, True, True, True);

    LegacyGroup := ExpandConstant('{userprograms}\D1CT');
    if DirExists(LegacyGroup) and
       (CompareText(LegacyGroup, ExpandConstant('{group}')) <> 0) then
      DelTree(LegacyGroup, True, True, True);

    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0);
  end;
end;

// Settings, history and the 640 MB model cache live outside the install
// directory. Leaving them behind by default means a reinstall does not
// re-download the model; the user is asked, so a real uninstall can be
// complete. (Braces are Pascal comments here, and a brace comment cannot
// contain an Inno constant like the app-directory one.)
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{localappdata}\Dictation');
    if DirExists(DataDir) then
      if MsgBox('Удалить настройки, историю и загруженную модель распознавания (~640 МБ)?'#13#10 +
                'Remove settings, history and the downloaded speech model (~640 MB)?',
                mbConfirmation, MB_YESNO) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
