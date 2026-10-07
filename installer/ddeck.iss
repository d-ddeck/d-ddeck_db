; d-ddeck 클라이언트 - Windows 설치 프로그램 (Inno Setup 6)
;
; 직접 컴파일하지 말고 build.ps1 을 사용하세요. Flutter 빌드와 버전 주입을
; 함께 처리합니다.
;
;   .\installer\build.ps1 -ServerUrl "https://192.168.121.6"

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\app\build\windows\x64\runner\Release"
#endif
#ifndef DefaultServerUrl
  #define DefaultServerUrl "https://192.168.121.6"
#endif

#define AppName "d-ddeck"
#define AppPublisher "d-ddeck"
#define AppExeName "ddeck_app.exe"

[Setup]
AppId={{8F3A2B14-6C7D-4E59-9A1B-2D4E6F8A0C13}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=ddeck-setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; 관리자 권한을 요구하지 않는다. 사내 PC에서 일반 사용자도 설치할 수 있도록
; Program Files 가 안 되면 사용자 폴더에 설치된다.
PrivilegesRequiredOverridesAllowed=dialog commandline
PrivilegesRequired=lowest

UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
SetupLogging=yes
CloseApplications=yes
RestartApplications=yes

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
korean.ServerPageTitle=서버 주소 설정
korean.ServerPageSubtitle=이 프로그램이 접속할 사내 서버 주소를 입력하세요.
korean.ServerPageLabel=사내 서버 주소를 입력하세요. 모르시면 관리자에게 문의하세요.%n%n예) https://192.168.121.6  또는  https://192.168.121.6
korean.ServerPageHint=나중에 프로그램의 로그인 화면에서도 변경할 수 있습니다.
korean.ServerInvalid=서버 주소를 입력해 주세요.
korean.LaunchApp={#AppName} 실행
english.ServerPageTitle=Server address
english.ServerPageSubtitle=Enter the address of your company server.
english.ServerPageLabel=Enter the company server address. Ask your administrator if unsure.%n%ne.g. https://192.168.121.6
english.ServerPageHint=You can change this later on the app's login screen.
english.ServerInvalid=Please enter a server address.
english.LaunchApp=Launch {#AppName}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Release 폴더 전체. exe 하나만으로는 실행되지 않는다.
Source: "{#SourceDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*.dll";        DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\data\*";       DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; 존재할 때만 복사 (Flutter 버전에 따라 없을 수 있다)
Source: "{#SourceDir}\native_assets.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 설치 중 생성한 설정 파일은 제거 시 같이 지운다.
Type: files; Name: "{app}\ddeck.config.json"

[Code]
var
  ServerPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  ServerPage := CreateInputQueryPage(
    wpSelectTasks,
    ExpandConstant('{cm:ServerPageTitle}'),
    ExpandConstant('{cm:ServerPageSubtitle}'),
    ExpandConstant('{cm:ServerPageLabel}'));
  ServerPage.Add(ExpandConstant('{cm:ServerPageTitle}') + ':', False);

  // /SERVERURL="..." 로 무인 설치할 때도 값을 받을 수 있게 한다.
  if ExpandConstant('{param:SERVERURL|}') <> '' then
    ServerPage.Values[0] := ExpandConstant('{param:SERVERURL}')
  else
    ServerPage.Values[0] := '{#DefaultServerUrl}';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (ServerPage <> nil) and (CurPageID = ServerPage.ID) then
  begin
    if Trim(ServerPage.Values[0]) = '' then
    begin
      MsgBox(ExpandConstant('{cm:ServerInvalid}'), mbError, MB_OK);
      Result := False;
    end;
  end;
end;

/// 사용자가 입력한 주소를 정규화한다. 앱의 normalizeServerUrl 과 같은 규칙:
/// 스킴이 없으면 http:// 를 붙이고, 끝의 슬래시를 떼어낸다.
function NormalizeUrl(S: String): String;
begin
  S := Trim(S);
  if (Pos('http://', LowerCase(S)) <> 1) and (Pos('https://', LowerCase(S)) <> 1) then
    S := 'http://' + S;
  while (Length(S) > 0) and (S[Length(S)] = '/') do
    S := Copy(S, 1, Length(S) - 1);
  Result := S;
end;

function GetServerUrl(Param: String): String;
begin
  if ServerPage <> nil then
    Result := NormalizeUrl(ServerPage.Values[0])
  else if ExpandConstant('{param:SERVERURL|}') <> '' then
    Result := NormalizeUrl(ExpandConstant('{param:SERVERURL}'))
  else
    Result := '{#DefaultServerUrl}';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigPath: String;
  Json: String;
begin
  if CurStep = ssPostInstall then
  begin
    // 앱이 실행 파일과 같은 폴더에서 읽는 파일. 서버가 옮겨가면 이 파일만
    // 고치면 되고, 프로그램을 다시 빌드할 필요가 없다.
    ConfigPath := ExpandConstant('{app}\ddeck.config.json');
    // 수동 덮어쓰기 설치에서도 기존 서버 설정을 유지한다.
    if FileExists(ConfigPath) and (ExpandConstant('{param:SERVERURL|}') = '') then
      Exit;
    Json := '{' + #13#10 +
            '  "server_url": "' + GetServerUrl('') + '"' + #13#10 +
            '}' + #13#10;
    if not SaveStringToFile(ConfigPath, Json, False) then
      MsgBox('설정 파일을 저장하지 못했습니다: ' + ConfigPath + #13#10 +
             '프로그램 실행 후 로그인 화면에서 서버 주소를 직접 입력해 주세요.',
             mbInformation, MB_OK);
  end;
end;
