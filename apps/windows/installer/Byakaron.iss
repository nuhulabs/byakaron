; Byakaron Windows installer (Inno Setup 6)
; Built by `zig build windows` (addWindows in build.zig).
;
; Defines (passed by the build):
;   PublishDir  - published app folder (Byakaron.exe, ime\, native\, …)
;   OutputDir   - where Byakaron-Setup.exe is written
;   AppVersion  - e.g. 1.0.0 (-Dwindows-version; else $BYAKARON_VERSION, else 1.0.0)
;
; Zig passes those as package-root-relative paths. Inno resolves relative Source
; / OutputDir paths against this script's directory, so rewrite them against
; the repo root (three levels up from apps/windows/installer/).

#ifndef PublishDir
  #error "PublishDir must be defined (/DPublishDir=...)"
#endif
#ifndef OutputDir
  #define OutputDir ".."
#endif
#ifndef AppVersion
  #define AppVersion GetEnv("BYAKARON_VERSION")
  #if AppVersion == ""
    #undef AppVersion
    #define AppVersion "1.0.0"
  #endif
#endif

#define RepoRoot RemoveBackslash(AddBackslash(SourcePath) + "..\..\..")
#if Copy(PublishDir, 2, 1) == ":" || Copy(PublishDir, 1, 2) == "\\" || Copy(PublishDir, 1, 1) == "/"
  #define PublishRoot PublishDir
#else
  #define PublishRoot AddBackslash(RepoRoot) + PublishDir
#endif
#if Copy(OutputDir, 2, 1) == ":" || Copy(OutputDir, 1, 2) == "\\" || Copy(OutputDir, 1, 1) == "/"
  #define OutputRoot OutputDir
#else
  #define OutputRoot AddBackslash(RepoRoot) + OutputDir
#endif

#define MyAppName "Byakaron"
#define MyAppPublisher "Nuhu Labs"
#define MyAppURL "https://github.com/nuhu-labs/byakaron"
#define MyAppExeName "Byakaron.exe"

[Setup]
AppId={{B1A7C0DE-5E11-4B00-9A10-B1A7C0DE5E11}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName={#MyAppName} {#AppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputRoot}
OutputBaseFilename=Byakaron-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
RestartApplications=no
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "installkeyboard"; Description: "Install Byakaron Phonetic keyboard (Bangla — Bangladesh)"; GroupDescription: "Input method:"; Flags: checkedonce

[Files]
; Full self-contained WinUI payload (includes ime\ for TIP registration)
Source: "{#PublishRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Register TSF TIP from the installed app tree (stable Program Files path)
Filename: "{sys}\regsvr32.exe"; Parameters: "/s ""{app}\ime\ByakaronIME.dll"""; StatusMsg: "Registering Bangla keyboard..."; Flags: runhidden waituntilterminated; Tasks: installkeyboard
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\regsvr32.exe"; Parameters: "/u /s ""{app}\ime\ByakaronIME.dll"""; RunOnceId: "UnregisterByakaronIME"; Flags: runhidden waituntilterminated
