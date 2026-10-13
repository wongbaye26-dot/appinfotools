import 'dart:io';

import 'package:archive/archive.dart';

/// 打开归档容器的结果。
///
/// 历史上 [ApkReader.open] / `ZipHelper.open` 只返回 `bool`，调用方无法区分
/// 「不是归档」「归档损坏」「命中解压预算」「IO 失败」—— 这四种情况对用户的
/// 含义完全不同，全部退化成「解析失败」既掩盖了真实原因，也让安全拒绝
/// （命中解压预算）无法被单独呈现。
///
/// 这一区分是 V2.0 要求「成功提取 / 文件中不存在 / 当前解析器不支持 /
/// 文件损坏或解析失败 / 可能经过加固」五态的基础。
enum ArchiveOpenResult {
  /// 归档已成功打开。
  ok,

  /// 输入不是 ZIP 归档（缺少 ZIP 魔数）。
  ///
  /// 典型场景：文件后缀是 .apk 但内容不是归档。
  notArchive,

  /// 有 ZIP 魔数，但结构损坏导致解码失败。
  corrupt,

  /// 声明的解压体积 / 条目数 / 压缩比超出安全预算，已被主动拒绝。
  resourceBudgetExceeded,

  /// 文件不存在、无权限或其他 IO 层失败。
  ioError;

  /// 是否成功打开。
  bool get isOk => this == ArchiveOpenResult.ok;

  /// 面向诊断的简短原因，供日志与 UI 诊断区展示。
  String get description => switch (this) {
        ArchiveOpenResult.ok => 'archive opened',
        ArchiveOpenResult.notArchive => 'not a ZIP archive',
        ArchiveOpenResult.corrupt => 'archive is corrupt',
        ArchiveOpenResult.resourceBudgetExceeded =>
          'archive exceeds the decompression budget',
        ArchiveOpenResult.ioError => 'cannot read the file',
      };
}

/// 判断字节前缀是否像 ZIP 归档。
///
/// 覆盖三种合法起始签名：
/// - `PK\x03\x04` 普通本地文件头
/// - `PK\x05\x06` 空归档的中央目录结束记录
/// - `PK\x07\x08` 分卷归档
///
/// 只做魔数判断，不代表归档结构完整 —— 后者交由解码器报错。
bool looksLikeZip(List<int> header) {
  if (header.length < 4) return false;
  if (header[0] != 0x50 || header[1] != 0x4B) return false; // 'P' 'K'
  final b2 = header[2];
  final b3 = header[3];
  return (b2 == 0x03 && b3 == 0x04) ||
      (b2 == 0x05 && b3 == 0x06) ||
      (b2 == 0x07 && b3 == 0x08);
}

/// 读取文件前 4 字节，用于归档魔数判断。
///
/// 文件不存在或无权限时抛出 [FileSystemException]，调用方据此归类为
/// [ArchiveOpenResult.ioError]。
Future<List<int>> readArchiveHeader(String filePath) async {
  final raf = await File(filePath).open();
  try {
    return await raf.read(4);
  } finally {
    await raf.close();
  }
}

/// 一条最小 ZIP EOCD 记录的长度（不含注释）。
const int minimalZipLength = 22;

/// 判断「解码器宽容地返回了空归档」这一情况。
///
/// 本项目使用的 archive fork 在遇到「有 ZIP 魔数但结构损坏」的输入时**不会抛异常**，
/// 而是返回一个空归档。若不额外判断，损坏文件会被归类为
/// [ArchiveOpenResult.ok]，直到后续找不到 `AndroidManifest.xml` / `Info.plist`
/// 才失败，用户只能看到笼统的「解析失败」。
///
/// 判定依据：解码结果没有任何条目，但输入长度明显超过一条最小 EOCD。
///
/// 已知局限：一个「合法为空、且带注释」的 ZIP 会被误判为损坏。对 APK / IPA 而言
/// 空归档无论如何都无法解析出内容，因此该误判不影响实际结论。
bool looksStructurallyBroken(Archive archive, int inputLength) {
  if (archive.files.isNotEmpty) return false;
  return inputLength > minimalZipLength;
}
