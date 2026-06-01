; Inno Setup script for the JawnRemote PC server.
; Build with:  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\JawnRemote.iss
; Produces:    installer\Output\JawnRemote-Server-Setup.exe
;
; The installer runs elevated (one UAC prompt), so it can open the firewall on
; ALL network profiles (incl. Public) -- the thing that breaks UnifiedRemote.

#define MyAppName "JawnRemote"
#define MyAppVersion "1.3.0"
#define MyAppPublisher "Jawnston Inc."
#define MyAppExeName "JawnRemoteServer.exe"
#define Port "8770"

[Setup]
AppId={{A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=Output
OutputBaseFilename=JawnRemote-Server-Setup
SetupIconFile=..\server\JawnRemoteServer.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "..\server\dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

; Note: "start at login" is offered inside the app itself (it writes the
; current user's HKCU Run key at runtime -- unambiguous and user-controlled).

[Run]
; Remove any stale rules, then allow inbound on ALL profiles (incl. Public).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#MyAppName}"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#MyAppName} (discovery)"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#MyAppName}"" dir=in action=allow protocol=TCP localport={#Port} profile=any"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#MyAppName} (discovery)"" dir=in action=allow protocol=UDP localport={#Port} profile=any"; Flags: runhidden
; Launch after install.
Filename: "{app}\{#MyAppExeName}"; Description: "Start {#MyAppName} now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#MyAppName}"""; Flags: runhidden; RunOnceId: "DelFwTcp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#MyAppName} (discovery)"""; Flags: runhidden; RunOnceId: "DelFwUdp"
