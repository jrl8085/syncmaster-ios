#define MyAppName "SyncMaster"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "SyncMaster"
#define MyAppExeName "SyncMaster.exe"
#define MyAppPort "8443"

[Setup]
AppId={{A7B3C2D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=installer_output
OutputBaseFilename=SyncMasterSetup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
; Require admin so we can write firewall rules
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupicon"; Description: "Start SyncMaster automatically when Windows starts"; GroupDescription: "Startup:"

[Files]
Source: "dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{commonstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
; Add Windows Firewall inbound rule for port 8443
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""{#MyAppName} Server"" dir=in action=allow program=""{app}\{#MyAppExeName}"" enable=yes protocol=TCP localport={#MyAppPort}"; \
    Flags: runhidden waituntilterminated; StatusMsg: "Configuring Windows Firewall..."

; Launch after install (optional, user can uncheck)
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove the firewall rule on uninstall
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""{#MyAppName} Server"""; \
    Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"
