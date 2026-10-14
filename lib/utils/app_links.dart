/// 项目的对外链接。
///
/// 集中在这里而不是散在页面里：README、关于对话框、发布说明都会引用，
/// 改一次仓库地址不应该需要全局搜索替换。
library;

/// GitHub 仓库地址。
const String kRepositoryUrl = 'https://github.com/wongbaye26-dot/appinfotools';

/// 发布页（下载最新版）。
const String kReleasesUrl = '$kRepositoryUrl/releases/latest';

/// 问题反馈。
const String kIssuesUrl = '$kRepositoryUrl/issues';
