; Inno Setup script for Quick desktop.
; Build with:  iscc installer\quick-desktop.iss /DAppVersion=1.2.3
; Output:      dist\quick-desktop-v{AppVersion}-windows-x64.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName       "Quick"
#define AppPublisher  "Quick"
#define AppExeName    "quick_desktop.exe"
#define BuildDir      "..\build\windows\x64\runner\Release"
#define OutputDir     "..\dist"
#define OutputBase    "quick-desktop-v" + AppVersion + "-windows-x64"

[Setup]
AppId={{8B7B0A6E-2C7E-4F39-9C1E-7D2E0F3C9A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Per-user install so the silent updater never triggers UAC.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Critical for silent in-place updates: terminate the running Quick instance,
; then restart it after files are overwritten.
CloseApplications=yes
RestartApplications=yes
CloseApplicationsFilter=*.exe,*.dll
SetupLogging=yes
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; postinstall+skipifsilent ensures interactive installs offer the checkbox while
; the silent updater path auto-relaunches via RestartApplications.
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
