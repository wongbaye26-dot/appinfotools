/// 一个字段的解析状态。
///
/// 这五态是规范 4.2 明确要求的区分。把它们压成「有值 / 无值」会掩盖三种对
/// 用户含义完全不同的情况：文件里**根本没有**这个字段、解析器**还不支持**
/// 这个字段、以及文件**可能被加固**因而读不到原始内容。
///
/// 尤其不能把后两者当成「不存在」—— 那会把「读不到」说成「没有」，
/// 是最容易误导用户的一种错误。
enum FieldStatus {
  /// 成功提取到值。
  extracted,

  /// 文件中确实不存在该字段（例如应用没有声明 `maxSdkVersion`）。
  absent,

  /// 当前解析器不支持该字段（尚未实现，或该容器格式没有这个概念）。
  unsupported,

  /// 文件损坏或解析失败，无法取值。
  failed,

  /// 可能经过加固，无法确认原始内容。
  ///
  /// 与 [failed] 的区别：这里容器本身是好的、解析过程也没有报错，只是内容
  /// 看起来被改写或加密了 —— 结论是「读不到」，不是「读坏了」。
  hardenedUnknown;

  /// 是否拿到了可用值。
  bool get hasValue => this == FieldStatus.extracted;

  /// 该状态是否意味着「我们无法给出结论」。
  ///
  /// UI 应据此避免把空值渲染成「无」，而要说明为什么没有。
  bool get isInconclusive =>
      this == FieldStatus.unsupported ||
      this == FieldStatus.failed ||
      this == FieldStatus.hardenedUnknown;
}

/// 字段值的来源。
///
/// 保留来源是为了让「这个值是谁给的」可追溯 —— 不同来源的可信度不同，
/// 排查问题时也需要知道该怀疑哪一环。
enum FieldSource {
  /// 内置纯 Dart 解析器（AXML / ARSC）。
  builtinParser,

  /// `aapt2 dump badging`。
  aapt2,

  /// ZIP 目录结构（只读条目名，不解压内容）。
  zipDirectory,

  /// `apksigner verify`。
  apksigner,

  /// 文件系统本身（文件大小、文件哈希）。
  fileSystem,

  /// 外部容器清单（XAPK / APKM 的 `manifest.json`）。
  archiveManifest,

  /// 未能确定来源。
  unknown,
}

/// 带**值 + 状态 + 来源 + 诊断**的字段。
///
/// 规范第六步要求「每个重要字段应保留：字段值、解析状态、数据来源、
/// 错误或诊断说明」，这就是那个容器。
///
/// 用泛型而不是「值 + 一堆旁路标记」，是为了让类型系统帮忙：拿到
/// `FieldValue<int>` 就不必再猜这个 int 是不是某个字符串硬转来的。
class FieldValue<T> {
  /// 字段值。仅当 [status] 为 [FieldStatus.extracted] 时非空。
  final T? value;

  final FieldStatus status;

  final FieldSource source;

  /// 面向诊断的补充说明：为什么没取到、来自哪一步、有什么异常。
  final String? diagnostic;

  /// 成功提取。
  ///
  /// 刻意不写 `assert(value != null)`：const 构造器里的断言只在 const 上下文
  /// 求值，非 const 用法下形同虚设。取值方一律走 [hasValue]。
  const FieldValue.extracted(
    this.value, {
    required this.source,
    this.diagnostic,
  }) : status = FieldStatus.extracted;

  /// 文件中不存在。
  const FieldValue.absent({
    this.source = FieldSource.unknown,
    this.diagnostic,
  })  : value = null,
        status = FieldStatus.absent;

  /// 当前解析器不支持。
  const FieldValue.unsupported({this.diagnostic})
      : value = null,
        status = FieldStatus.unsupported,
        source = FieldSource.unknown;

  /// 解析失败。
  const FieldValue.failed({
    required this.diagnostic,
    this.source = FieldSource.unknown,
  })  : value = null,
        status = FieldStatus.failed;

  /// 可能经过加固，无法确认。
  const FieldValue.hardenedUnknown({
    this.diagnostic,
    this.source = FieldSource.unknown,
  })  : value = null,
        status = FieldStatus.hardenedUnknown;

  /// 是否有可用值。
  bool get hasValue => status.hasValue && value != null;

  /// 供 UI 直接展示的文本；无值时为空串（**不**伪造占位内容）。
  String get display => hasValue ? '${value!}' : '';

  /// 同一字段用更高可信度的来源覆盖当前值。
  ///
  /// 用于「分层、可回退」的解析策略：内置解析器先给出结果，aapt2 若可用
  /// 再覆盖。只接受 [FieldStatus.extracted] 的候选值 —— 一个空的候选值
  /// 不该抹掉已有的好结果。
  FieldValue<T> overriddenBy(FieldValue<T> candidate) =>
      candidate.hasValue ? candidate : this;

  @override
  String toString() => 'FieldValue<$T>(status: $status, source: $source, '
      'value: $value${diagnostic == null ? '' : ', diagnostic: $diagnostic'})';
}
