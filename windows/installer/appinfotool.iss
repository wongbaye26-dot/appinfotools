; AppInfoTool 的 Inno Setup 安装脚本。
;
; ## 为什么不再用 `inno_bundle` 生成
;
; `inno_bundle` 的 `script_builder.dart` 把这几件事写死了，改配置改不出来：
;
;   - `DisableDirPage=auto` —— 安装目录页在多数情况下**不显示**；
;   - `[Languages]` 只认它自己枚举的那几个，**没有简体中文**
;     （pubspec 里那行 `# - chinesesimplified` 是注释掉的，而且枚举里
;     根本没有这个值，打开就会报错）；
;   - **不生成 `[Registry]` 段** —— 装完没有任何文件关联。
;
; 于是「安装时选语言 / 选目录 / 装完双击 .apk 就能用」三件事一个都做不到。
; 脚本放在仓库里自己维护，改一行就能改行为。
;
; ## 编译方式
;
; ```
; set APPINFOTOOL_VERSION=2.7.0
; set APPINFOTOOL_SOURCE_ROOT=C:\path\to\repo
; ISCC.exe windows\installer\appinfotool.iss
; ```
;
; **为什么用环境变量而不是 `ISCC /Dname=value`**：`/D` 把值当成 `#define` 的
; 表达式，`/DAppVersion=2.6.1` 会被读成 `2.6` 后面跟 `.1` —— 语法错误。
; 环境变量经 `GetEnv()` 取到的就是字符串，没有这层解析。
;
; 两个变量都必须设置（下面有 `#error` 兜着）。CI 见
; `.github/workflows/build.yml` 的 "Create Installer" 一步。
;
; ## 语言文件
;
; 简体中文用的是 `languages/ChineseSimplified.isl`，来自社区翻译
; （kira-96/Inno-Setup-Chinese-Simplified-Translation，对应 Inno 6.5.0+）。
; Inno 官方只带 20 多种语言、**没有中文**，所以必须自带一份。
;
; **该文件必须保持 UTF-8 with BOM**。Inno 6 靠 BOM 判断「这是 Unicode」，
; 去掉 BOM 它就会按 ANSI/代码页 936 读，中文全变乱码 —— 而且编译不报错，
; 只有装的时候才看得出来。本文件（.iss）同理。

#define AppName "AppInfoTool"
#define AppExeName "apk_info_tool.exe"
#define AppPublisher "Feng"
#define AppUrl "https://github.com/wongbaye26-dot/appinfotools"

; **必须与 inno_bundle 时期写进注册表的 AppId 逐字符一致**（不带花括号）。
; 换了就等于另一个产品：老用户升级会装出第二份 AppInfoTool，
; 「应用与功能」里也会出现两条。
#define AppId "8cdac933-dde4-5d06-985d-4c99f7247903"

#define AppVersion GetEnv("APPINFOTOOL_VERSION")
#define SourceRoot GetEnv("APPINFOTOOL_SOURCE_ROOT")

; 编译期错误信息用 ASCII：ISCC 的输出编码跟着控制台代码页走，
; 中文在这条路径上会变成乱码，反而看不出问题。
#if AppVersion == ""
  #error APPINFOTOOL_VERSION is not set (CI reads it from pubspec.yaml)
#endif
#if SourceRoot == ""
  #error APPINFOTOOL_SOURCE_ROOT is not set (CI passes the repo root)
#endif

#define InstallerDir SourceRoot + "\windows\installer"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
; 安装目录页**总是显示**。这是用户明确要求的：装到哪个盘由用户决定，
; 不要替他决定。`auto`（inno_bundle 的取值）会在升级时藏掉这一页。
DisableDirPage=no
; 开始菜单组只有一个程序，不值得占一页。
DisableProgramGroupPage=yes
; 语言选择页总是显示。默认 `auto` 会在「系统语言正好匹配」时跳过它 ——
; 而用户要的就是**能自己选**。
ShowLanguageDialog=yes
; 有多个语言时，用系统语言预选；匹配不上时用列表里第一个（简体中文）。
; 安装界面用的是 Inno 自己的向导，不是自绘窗口 —— 系统 DPI / 高对比度 /
; 键盘导航都跟着系统走。
WizardStyle=modern
; 改过文件关联，装完让资源管理器刷新一次（否则「打开方式」要等重新登录）。
ChangesAssociations=yes
; 应用运行时不允许安装/卸载：那两个动作会覆盖或删除正在被加载的 DLL。
; 名字必须与 `windows/runner/single_instance.cpp` 的 `kMutexName` 一致。
AppMutex=Local\AppInfoTool.SingleInstance
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
Compression=lzma2/max
SolidCompression=yes
SetupIconFile={#SourceRoot}\windows\runner\resources\app_icon.ico
OutputDir={#SourceRoot}\build\windows\x64\installer\Release
OutputBaseFilename={#AppName}-{#AppVersion}-Windows-x86_64-Setup

[Languages]
; 顺序有意义：系统语言匹配不上时，Inno 用**第一个**作为默认。
Name: "chinesesimplified"; MessagesFile: "{#InstallerDir}\languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[CustomMessages]
; 自定义文案必须**每种语言各写一份**，否则该语言下显示英文（或空白）。
chinesesimplified.AssocTask=将 .apk / .ipa 等文件关联到本程序
english.AssocTask=Associate .apk / .ipa files with this app
japanese.AssocTask=.apk / .ipa ファイルをこのアプリに関連付ける
korean.AssocTask=.apk / .ipa 파일을 이 앱과 연결

chinesesimplified.AssocGroup=集成
english.AssocGroup=Integration
japanese.AssocGroup=統合
korean.AssocGroup=통합

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
; 默认勾选：装完双击 .apk 就该能用。用户仍然可以取消。
Name: "associate"; Description: "{cm:AssocTask}"; GroupDescription: "{cm:AssocGroup}"; Flags: checkedonce

[InstallDelete]
; 升级时先清空安装目录：Flutter 的产物里 dll / data 文件名固定，
; 残留旧文件会让「新旧混装」这种问题极难查。
Type: filesandordirs; Name: "{app}\*"

[Files]
; 整个 runner/Release 目录：exe、flutter_windows.dll、data\、缩略图 DLL、
; app_icon_extractor.exe，以及 CI 补进来的 VC 运行库。
Source: "{#SourceRoot}\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

; 文件关联。
;
; ProgID 与 `windows/runner/file_association_channel.cpp` 里应用自己登记的
; **完全一致**（`AppInfoTool.<ext>`）：否则同一台机器上会出现两套互相看不见
; 的关联，用户看到的「默认程序」会莫名其妙地变。
;
; `HKA` = 管理员安装时写 HKLM（对所有用户生效），非管理员写 HKCU。
[Registry]
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apk"; ValueType: string; ValueName: ""; ValueData: "Android Package"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apk\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apk\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.apk\OpenWithProgids"; ValueType: string; ValueName: "AppInfoTool.apk"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.apk"; ValueType: string; ValueName: ""; ValueData: "AppInfoTool.apk"; Flags: uninsdeletevalue; Tasks: associate

Root: HKA; Subkey: "Software\Classes\AppInfoTool.ipa"; ValueType: string; ValueName: ""; ValueData: "iOS App Package"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.ipa\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.ipa\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.ipa\OpenWithProgids"; ValueType: string; ValueName: "AppInfoTool.ipa"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.ipa"; ValueType: string; ValueName: ""; ValueData: "AppInfoTool.ipa"; Flags: uninsdeletevalue; Tasks: associate

Root: HKA; Subkey: "Software\Classes\AppInfoTool.xapk"; ValueType: string; ValueName: ""; ValueData: "Android Package (XAPK)"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.xapk\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.xapk\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.xapk\OpenWithProgids"; ValueType: string; ValueName: "AppInfoTool.xapk"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.xapk"; ValueType: string; ValueName: ""; ValueData: "AppInfoTool.xapk"; Flags: uninsdeletevalue; Tasks: associate

Root: HKA; Subkey: "Software\Classes\AppInfoTool.apks"; ValueType: string; ValueName: ""; ValueData: "Android Package Set"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apks\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apks\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.apks\OpenWithProgids"; ValueType: string; ValueName: "AppInfoTool.apks"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.apks"; ValueType: string; ValueName: ""; ValueData: "AppInfoTool.apks"; Flags: uninsdeletevalue; Tasks: associate

Root: HKA; Subkey: "Software\Classes\AppInfoTool.apkm"; ValueType: string; ValueName: ""; ValueData: "Android App Bundle (APKM)"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apkm\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AppInfoTool.apkm\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.apkm\OpenWithProgids"; ValueType: string; ValueName: "AppInfoTool.apkm"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.apkm"; ValueType: string; ValueName: ""; ValueData: "AppInfoTool.apkm"; Flags: uninsdeletevalue; Tasks: associate

; 缩略图处理器（`IThumbnailProvider`）。
;
; **没有这一段，资源管理器只会用上面写的 `DefaultIcon`** —— 也就是应用自己的
; 图标，于是所有 .apk / .ipa 长得一模一样。注册了处理器，Explorer 才会去问
; `appinfotool_thumbnail.dll` 要「这个包自己的图标」。
;
; CLSID 必须与 `windows/thumbnail/thumbnail_provider.cpp` 的
; `kThumbnailProviderClsid` 一致；ShellEx 下的那个 GUID 是
; `IID_IThumbnailProvider`（`{E357FCCD-…-234630154E96}`）。
; 应用自己也会在启动时写一份 HKCU（便携版靠它），两边指向同一个 DLL。
Root: HKA; Subkey: "Software\Classes\CLSID\{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}"; ValueType: string; ValueName: ""; ValueData: "AppInfoTool thumbnail provider"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\CLSID\{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\appinfotool_thumbnail.dll"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\CLSID\{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Apartment"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.apk\ShellEx\{E357FCCD-A995-4576-B01F-234630154E96}"; ValueType: string; ValueName: ""; ValueData: "{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.ipa\ShellEx\{E357FCCD-A995-4576-B01F-234630154E96}"; ValueType: string; ValueName: ""; ValueData: "{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
