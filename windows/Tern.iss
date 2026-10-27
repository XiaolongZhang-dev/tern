#define MyAppName "Tern"
#define MyAppVersion "1.4.3"
#define MyAppPublisher "Tern contributors"
#define MyAppExeName "Tern.exe"

[Setup]
AppId={{8F2A0C4E-7A4D-4D1F-9B6D-5B3F2A1C7E90}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Tern
DefaultGroupName=Tern
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=Tern-Windows-Setup
SetupIconFile=Assets\tern.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startmenu"; Description: "创建开始菜单快捷方式"; GroupDescription: "快捷方式:"; Flags: checkedonce
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式:"; Flags: unchecked

[Files]
Source: "dist\Tern.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Tern"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu
Name: "{userdesktop}\Tern"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[UninstallRun]
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v Tern /f"; Flags: runhidden; RunOnceId: "RemoveTernStartup"
Filename: "{app}\{#MyAppExeName}"; Parameters: "--uninstall-cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "CleanupCloudFiles"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Tern"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 Tern"; Flags: nowait postinstall skipifsilent
