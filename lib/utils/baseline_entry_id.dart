/// 官方基线条目的稳定 id。
///
/// 只依赖 platform + packageId，保证同一包重复导入得到同一个 id；不把
/// 时间戳/文件名/来源混进来，否则同一官方包会产生多条看似不同的条目。
String buildBaselineEntryId({
  required String platform,
  required String packageId,
}) {
  final slug = packageId
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  final id = '$platform.$slug';
  return id.length <= 64 ? id : id.substring(0, 64);
}
