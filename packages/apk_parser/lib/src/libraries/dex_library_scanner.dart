import 'dart:typed_data';

import '../dex/dex_structure.dart';
import '../dex/dex_tables.dart';

/// 从 DEX 里抽出的「库识别」信号。
///
/// 为什么不是「类名集合」：LibChecker 的 DEX 规则匹配的是**包名前缀**，只保留
/// 包名能把内存从「十万条类名」降到「几千条包名」；而加固库旁证只需要几个
/// 固定前缀的布尔量。反过来，把类名全留下也不会多识别出一个 SDK。
class DexLibrarySignals {
  const DexLibrarySignals({
    required this.packages,
    required this.classCount,
    required this.truncated,
    required this.kotlinMetadata,
    required this.kotlinClasses,
    required this.composeClasses,
    required this.flutterInjector,
    required this.qihooShell,
    required this.secneoShell,
  });

  /// 有类定义的包名（`com.foo.bar`；无包的类记为空串，不参与 DEX 匹配）。
  final Set<String> packages;
  final int classCount;

  /// 类数超过上限时为 true：`packages` 只覆盖前 [DexLibraryScanner.maxClasses]
  /// 个类，匹配结果可能不全。调用方必须把这个事实显示出来。
  final bool truncated;

  /// 含 `Lkotlin/Metadata;` —— Kotlin 编译产物的最硬标记。
  final bool kotlinMetadata;
  final bool kotlinClasses;
  final bool composeClasses;

  /// `Lio/flutter/FlutterInjector;`（libapp.so 的旁证之一）。
  final bool flutterInjector;

  /// 加固壳类：`com.qihoo.util.*` / `com.tianyu.util.*`、`com.secneo.apkwrapper.*`。
  final bool qihooShell;
  final bool secneoShell;

  static const empty = DexLibrarySignals(
    packages: {},
    classCount: 0,
    truncated: false,
    kotlinMetadata: false,
    kotlinClasses: false,
    composeClasses: false,
    flutterInjector: false,
    qihooShell: false,
    secneoShell: false,
  );

  /// 「有 DEX 没扫完」的标记：调用方主动截断时 merge 进结果，
  /// 让 `truncated` 为真，同时不引入任何伪造的包名。
  static const truncatedMarker = DexLibrarySignals(
    packages: {},
    classCount: 0,
    truncated: true,
    kotlinMetadata: false,
    kotlinClasses: false,
    composeClasses: false,
    flutterInjector: false,
    qihooShell: false,
    secneoShell: false,
  );

  DexLibrarySignals merge(DexLibrarySignals other) {
    return DexLibrarySignals(
      packages: {...packages, ...other.packages},
      classCount: classCount + other.classCount,
      truncated: truncated || other.truncated,
      kotlinMetadata: kotlinMetadata || other.kotlinMetadata,
      kotlinClasses: kotlinClasses || other.kotlinClasses,
      composeClasses: composeClasses || other.composeClasses,
      flutterInjector: flutterInjector || other.flutterInjector,
      qihooShell: qihooShell || other.qihooShell,
      secneoShell: secneoShell || other.secneoShell,
    );
  }
}

/// DEX 的 `class_defs` 扫描：只读类型描述符，不碰方法体与字符串表内容。
class DexLibraryScanner {
  /// 类数上限。真实应用通常 1–5 万；上限只是防止畸形 DEX 把耗时拖到不可控。
  static const maxClasses = 400000;

  /// 扫描一个 DEX。读不了结构时返回 [DexLibrarySignals.empty]（调用方据
  /// `classCount == 0` 判断「没扫到」，不要把它说成「没有库」）。
  static DexLibrarySignals scan(Uint8List bytes) {
    if (bytes.length < 0x70) return DexLibrarySignals.empty;
    // 与 `DexStructure.read` 相同的魔数前置检查：`dex\n` 之后是版本号。
    if (bytes[0] != 0x64 ||
        bytes[1] != 0x65 ||
        bytes[2] != 0x78 ||
        bytes[3] != 0x0a) {
      return DexLibrarySignals.empty;
    }
    final structure = DexStructure.read('classes.dex', bytes);
    final classDefs = structure.section('class_defs');
    final typeIds = structure.section('type_ids');
    if (classDefs == null || typeIds == null) return DexLibrarySignals.empty;

    final tables = DexTables(bytes, structure);
    final total = classDefs.size;
    final limit = total > maxClasses ? maxClasses : total;
    final truncated = total > limit;

    final packages = <String>{};
    var classCount = 0;
    var kotlinMetadata = false;
    var kotlinClasses = false;
    var composeClasses = false;
    var flutterInjector = false;
    var qihooShell = false;
    var secneoShell = false;

    for (var i = 0; i < limit; i++) {
      final itemOffset = classDefs.offset + i * classDefs.itemSize;
      if (itemOffset + 4 > bytes.length) break;
      final classIdx = tables.uint32(itemOffset);
      final descriptor = tables.typeDescriptor(classIdx);
      if (descriptor == null || !descriptor.startsWith('L')) continue;
      classCount++;

      // 加固壳 / Flutter 的标记按**完整描述符前缀**判断：这些类名是固定的，
      // 不会因为应用自己的包名而变。
      if (descriptor == 'Lkotlin/Metadata;') kotlinMetadata = true;
      if (descriptor.startsWith('Lkotlin/')) kotlinClasses = true;
      if (descriptor.startsWith('Landroidx/compose/')) composeClasses = true;
      if (descriptor == 'Lio/flutter/FlutterInjector;') flutterInjector = true;
      if (descriptor.startsWith('Lcom/qihoo/util/') ||
          descriptor.startsWith('Lcom/tianyu/util/')) {
        qihooShell = true;
      }
      if (descriptor.startsWith('Lcom/secneo/apkwrapper/')) secneoShell = true;

      final package = _packageOf(descriptor);
      if (package.isNotEmpty) packages.add(package);
    }

    return DexLibrarySignals(
      packages: packages,
      classCount: classCount,
      truncated: truncated,
      kotlinMetadata: kotlinMetadata,
      kotlinClasses: kotlinClasses,
      composeClasses: composeClasses,
      flutterInjector: flutterInjector,
      qihooShell: qihooShell,
      secneoShell: secneoShell,
    );
  }

  /// `Lcom/foo/Bar;` → `com.foo`；无包（`LBar;`）返回空串。
  static String _packageOf(String descriptor) {
    final body = descriptor.substring(1, descriptor.endsWith(';')
        ? descriptor.length - 1
        : descriptor.length);
    final slash = body.lastIndexOf('/');
    if (slash <= 0) return '';
    return body.substring(0, slash).replaceAll('/', '.');
  }
}
