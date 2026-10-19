import 'dart:typed_data';

import 'dex_instruction.dart';
import 'dex_method_table.dart';
import 'dex_structure.dart';
import 'dex_tables.dart';

/// 一条被遍历到的指令。
///
/// [offset] 是**代码单元**偏移，与 `dexdump -d` 输出里的 `|0002:` 一致 ——
/// 这个对应关系是测试用来核对宽度表的抓手。
class DexInstruction {
  final int offset;
  final int opcode;
  final int width;

  const DexInstruction(this.offset, this.opcode, this.width);

  @override
  String toString() =>
      'DexInstruction(@$offset, op=0x${opcode.toRadixString(16)}, w=$width)';
}

/// 一个调用点。
///
/// 与 [DexMethodReference] 的区别是它多带了**在哪里被调用**：调用者方法、
/// 调用者类、以及指令偏移。`method_ids` 只说明「引用存在」，
/// 调用点说明「这个方法的某处指令引用了它」—— 仍然不等于「运行时会执行到」，
/// 但已经能把「哪个方法里出现了这个调用」说清楚。
class DexCallSite {
  /// 调用者所属类的描述符。
  final String callerClassDescriptor;

  /// 调用者方法名。
  final String callerMethodName;

  /// 调用者方法的原型描述符。
  final String? callerProtoDescriptor;

  /// 被引用的方法。
  final DexMethodReference target;

  /// 调用者方法的 `method_idx`。
  ///
  /// 调用图要用**整数下标**建边：字符串键在千万级调用点上会吃掉几百 MB，
  /// 而且每次插入都要拼串。`null` 表示调用者身份读不出来（畸形文件）。
  final int? callerMethodIndex;

  /// `invoke-*` 指令在 `insns` 里的代码单元偏移。
  final int instructionOffset;

  /// `invoke-*` 的 opcode。
  final int opcode;

  const DexCallSite({
    required this.callerClassDescriptor,
    required this.callerMethodName,
    required this.target,
    required this.instructionOffset,
    required this.opcode,
    this.callerProtoDescriptor,
    this.callerMethodIndex,
  });

  /// 调用者的完整描述，例如
  /// `Lcom/example/fixture/NetProbe;.open(Ljava/lang/String;)Ljava/io/InputStream;`
  String get callerDisplayName => '$callerClassDescriptor.'
      '$callerMethodName${callerProtoDescriptor ?? ''}';

  /// 被调用方的完整描述。
  String get targetDisplayName => target.displayName;

  @override
  String toString() =>
      'DexCallSite($callerDisplayName @$instructionOffset → $targetDisplayName)';
}

/// 一条 `invoke-*` 指令的位置与操作数。
class DexInvoke {
  /// 指令在 `insns` 里的代码单元偏移。
  final int offset;

  /// `invoke-*` 的 opcode。
  final int opcode;

  /// 第二代码单元：`invoke-*` 是 `method_idx`，`invoke-custom` 是
  /// `call_site_idx`。
  final int operand;

  /// 是否是 `invoke-custom`。
  ///
  /// 它的操作数是 `call_site_ids` 的索引，**不是** `method_ids` ——
  /// 混用会解出一个完全无关的方法。因此单独标记。
  final bool isCustom;

  const DexInvoke({
    required this.offset,
    required this.opcode,
    required this.operand,
    required this.isCustom,
  });

  @override
  String toString() => 'DexInvoke(@$offset, op=0x${opcode.toRadixString(16)}, '
      'operand=$operand${isCustom ? ', custom' : ''})';
}

/// 一段裸指令序列的遍历结果。
class DexInsnWalkResult {
  /// 输入的代码单元总数。
  final int insnsLength;

  /// 遍历到的指令数（含载荷）。
  final int instructionCount;

  /// 遍历结束时落到的位置。
  final int endIndex;

  /// `invoke-*` 指令。
  final List<DexInvoke> invokes;

  const DexInsnWalkResult({
    required this.insnsLength,
    required this.instructionCount,
    required this.endIndex,
    this.invokes = const [],
  });

  /// 遍历是否**正好**落在末尾。
  ///
  /// 为 `false` 说明宽度表或载荷长度有偏差，此时读到的指令边界与调用点
  /// **都不可信** —— 必须记入覆盖范围说明，不能当作正常结果。
  bool get reachedEnd => endIndex == insnsLength;

  @override
  String toString() => 'DexInsnWalkResult(insns=$insnsLength, '
      'count=$instructionCount, end=$endIndex, '
      'reachedEnd=$reachedEnd, invokes=${invokes.length})';
}

/// 方法体遍历的结果。
class DexBodyScanResult {
  /// 成功解析并遍历的 `code_item` 数。
  final int methodBodyCount;

  /// 遍历到的指令总数（含载荷）。
  final int instructionCount;

  /// 找到的 `invoke-*` 指令数（含 `invoke-custom`）。
  final int callSiteCount;

  /// `invoke-custom` 的数量。
  ///
  /// 单独计数：它引用的是 `call_site_ids` 而不是 `method_ids`，
  /// 因此**不会**产出 [DexCallSite] —— 不说清楚就会被当成「没有调用」。
  final int invokeCustomCount;

  /// 没有正好走到 `insns_size` 末尾的方法体（`调用者` 描述）。
  ///
  /// 非空说明宽度表或解析有偏差 —— 这种情况下读到的调用点**不可信**，
  /// 必须出现在报告的覆盖范围说明里。
  final List<String> desyncedBodies;

  /// `class_data_off` 为 0（没有类数据）而跳过的类数。
  final int classesWithoutData;

  /// `code_off` 为 0（抽象方法 / 无实现）而跳过的方法数。
  final int methodsWithoutCode;

  /// 结构读不出来而跳过的类数。
  final int skippedClasses;

  /// 是否因为预算上限而提前停止。
  final bool truncated;

  const DexBodyScanResult({
    this.methodBodyCount = 0,
    this.instructionCount = 0,
    this.callSiteCount = 0,
    this.invokeCustomCount = 0,
    this.desyncedBodies = const [],
    this.classesWithoutData = 0,
    this.methodsWithoutCode = 0,
    this.skippedClasses = 0,
    this.truncated = false,
  });

  @override
  String toString() => 'DexBodyScanResult(bodies=$methodBodyCount, '
      'insns=$instructionCount, callSites=$callSiteCount, '
      'desynced=${desyncedBodies.length}, truncated=$truncated)';
}

/// `class_defs → class_data_item → code_item` 的遍历。
///
/// 第三层取证：把「引用了」推进到「在哪里被调用」。指令遍历**必须**按
/// [DexInstructionTable] 的宽度走，否则会在指令中间错位读出假的方法索引。
///
/// 三道防线，强度不同：
/// 1. **主力**：`test/dex_instruction_test.dart` 在真实 DEX 上把每条指令的
///    偏移与 `dexdump -d` 逐个对照（101 条、53 种助记符）—— 任何一格宽度
///    写错都会在那里立刻暴露；
/// 2. [DexBodyScanResult.desyncedBodies]：每个方法体的遍历必须**正好**走到
///    `insns_size` 末尾。这是**必要但非充分**条件 —— 宽度偏大若恰好重新对齐
///    （例如从 1 跨到 3 而长度正好是 3），遍历仍会落在末尾，只是漏读了一条
///    指令。它抓得到越界，抓不到「恰好对齐的漏读」；
/// 3. 载荷单独识别 —— 它们的首单元低字节是 `0x00`，按 opcode 读会被当成
///    `nop`（宽度 1），于是遍历走进数据里把跳转目标当成指令。
class DexMethodBodies {
  DexMethodBodies._();

  /// 一次遍历最多处理多少个类。
  static const int maxClasses = 200000;

  /// 一次遍历最多处理多少条指令。
  ///
  /// 正常 `classes.dex` 在十万条量级；这个上限是为了兜住畸形文件，
  /// 截断时如实报告。
  static const int maxInstructions = 20000000;

  /// 遍历每个方法体的指令。
  ///
  /// [onInstruction] 与 [onCallSite] 都是可选的：测试用前者核对宽度表，
  /// 安全层用后者收调用点。
  static DexBodyScanResult walk(
    Uint8List bytes,
    DexStructure structure, {
    void Function(DexInstruction instruction)? onInstruction,
    void Function(DexCallSite callSite)? onCallSite,
    int maxClasses = maxClasses,
    int maxInstructions = maxInstructions,
  }) {
    final classDefs = structure.section('class_defs');
    if (classDefs == null || classDefs.size == 0) {
      return const DexBodyScanResult();
    }

    final tables = DexTables(bytes, structure);
    final desynced = <String>[];
    var methodBodyCount = 0;
    var instructionCount = 0;
    var callSiteCount = 0;
    var invokeCustomCount = 0;
    var classesWithoutData = 0;
    var methodsWithoutCode = 0;
    var skippedClasses = 0;
    var truncated = false;

    final classLimit =
        classDefs.size < maxClasses ? classDefs.size : maxClasses;
    if (classLimit < classDefs.size) truncated = true;

    for (var i = 0; i < classLimit; i++) {
      final base = classDefs.offset + i * classDefs.itemSize;
      if (base + classDefs.itemSize > bytes.length) {
        skippedClasses++;
        continue;
      }
      final classIdx = tables.uint32(base);
      final classDataOff = tables.uint32(base + 24);
      final classDescriptor = tables.typeDescriptor(classIdx);

      if (classDataOff == 0) {
        classesWithoutData++;
        continue;
      }

      final parsed = _readClassData(tables, classDataOff);
      if (parsed == null) {
        skippedClasses++;
        continue;
      }

      for (final method in parsed) {
        if (instructionCount >= maxInstructions) {
          truncated = true;
          break;
        }
        if (method.codeOff == 0) {
          methodsWithoutCode++;
          continue;
        }
        final caller = tables.methodReference(method.methodIdx);
        if (caller == null) continue;

        final body = _walkBody(
          bytes: bytes,
          tables: tables,
          codeOff: method.codeOff,
          callerClassDescriptor: classDescriptor ?? caller.$1,
          callerMethodName: caller.$2,
          callerProtoDescriptor: caller.$3,
          callerMethodIndex: method.methodIdx,
          onInstruction: onInstruction,
          onCallSite: onCallSite,
          onCallSiteCount: () => callSiteCount++,
          onInvokeCustom: () => invokeCustomCount++,
        );
        if (body == null) continue;

        methodBodyCount++;
        instructionCount += body.instructionCount;
        if (body.desynced) {
          desynced.add('${caller.$1}.${caller.$2}${caller.$3 ?? ''}');
        }
      }
    }

    return DexBodyScanResult(
      methodBodyCount: methodBodyCount,
      instructionCount: instructionCount,
      callSiteCount: callSiteCount,
      invokeCustomCount: invokeCustomCount,
      desyncedBodies: desynced,
      classesWithoutData: classesWithoutData,
      methodsWithoutCode: methodsWithoutCode,
      skippedClasses: skippedClasses,
      truncated: truncated,
    );
  }

  /// 遍历一段**裸的**指令序列。
  ///
  /// 公开是为了可测试：宽度表与载荷识别是这一层最容易出错的地方，而它们
  /// 只依赖这段字节，与 `class_defs` / `code_item` 的读取无关。测试因此可以
  /// 直接构造一段字节来验证「宽度错位会被发现」，而不必伪造整个 DEX。
  ///
  /// 规则：
  /// - 载荷（`0x0100` / `0x0200` / `0x0300`）按其内部声明的长度跳过 ——
  ///   它们的首单元低字节是 `0x00`，按 opcode 读会被当成 `nop`（宽度 1），
  ///   于是遍历会走进数据里把跳转目标当成指令；
  /// - 载荷长度读不出来时**立即停下**，不猜长度（宁可不同步，也不产出
  ///   看起来正常的错结果）。
  static DexInsnWalkResult walkInsns(
    Uint16List insns, {
    void Function(DexInstruction instruction)? onInstruction,
  }) {
    final invokes = <DexInvoke>[];
    var index = 0;
    var count = 0;

    while (index < insns.length) {
      final unit = insns[index];

      if (DexInstructionTable.isPayloadHeader(unit)) {
        final width = DexInstructionTable.payloadWidth(insns, index);
        if (width == null || width <= 0) {
          // 载荷长度读不出来：停下，把当前位置交回去让调用方判定不同步。
          return DexInsnWalkResult(
            insnsLength: insns.length,
            instructionCount: count,
            endIndex: index,
            invokes: invokes,
          );
        }
        onInstruction?.call(DexInstruction(index, unit >> 8, width));
        index += width;
        count++;
        continue;
      }

      final opcode = unit & 0xFF;
      final width = DexInstructionTable.widthOf(opcode);
      onInstruction?.call(DexInstruction(index, opcode, width));

      if (DexInstructionTable.invokeOpcodes.contains(opcode)) {
        // 所有 invoke 形式的第二单元都是操作数：
        //   35c / 3rc / 45cc / 4rcc 的布局都是 [op|AA][BBBB][…]。
        final operand = index + 1 < insns.length ? insns[index + 1] : 0;
        invokes.add(DexInvoke(
          offset: index,
          opcode: opcode,
          operand: operand,
          isCustom: opcode == 0xfc || opcode == 0xfd,
        ));
      }

      index += width;
      count++;
    }

    return DexInsnWalkResult(
      insnsLength: insns.length,
      instructionCount: count,
      endIndex: index,
      invokes: invokes,
    );
  }

  /// 读 `class_data_item`，返回其中的方法（direct + virtual）。
  ///
  /// 返回 `null` 表示读不出来（越界或 uleb128 畸形）。
  static List<_EncodedMethod>? _readClassData(DexTables tables, int offset) {
    var cursor = offset;

    final counts = <int>[];
    for (var i = 0; i < 4; i++) {
      final read = tables.uleb128(cursor);
      if (read == null) return null;
      counts.add(read.$1);
      cursor = read.$2;
    }
    final staticFields = counts[0];
    final instanceFields = counts[1];
    final directMethods = counts[2];
    final virtualMethods = counts[3];

    // 跳过字段表（encoded_field = field_idx_diff + access_flags）。
    for (var i = 0; i < staticFields + instanceFields; i++) {
      for (var j = 0; j < 2; j++) {
        final read = tables.uleb128(cursor);
        if (read == null) return null;
        cursor = read.$2;
      }
    }

    final methods = <_EncodedMethod>[];
    // encoded_method = method_idx_diff + access_flags + code_off。
    // 每个列表的**第一个**元素是绝对索引，其后是相对前一个的差值。
    for (final count in [directMethods, virtualMethods]) {
      var methodIdx = 0;
      for (var i = 0; i < count; i++) {
        final diff = tables.uleb128(cursor);
        if (diff == null) return null;
        cursor = diff.$2;
        final accessFlags = tables.uleb128(cursor);
        if (accessFlags == null) return null;
        cursor = accessFlags.$2;
        final codeOff = tables.uleb128(cursor);
        if (codeOff == null) return null;
        cursor = codeOff.$2;

        methodIdx = i == 0 ? diff.$1 : methodIdx + diff.$1;
        methods.add(_EncodedMethod(methodIdx, codeOff.$1));
      }
    }
    return methods;
  }

  /// 遍历一个 `code_item` 的指令。
  static _BodyWalk? _walkBody({
    required Uint8List bytes,
    required DexTables tables,
    required int codeOff,
    required String callerClassDescriptor,
    required String callerMethodName,
    required String? callerProtoDescriptor,
    int? callerMethodIndex,
    void Function(DexInstruction)? onInstruction,
    void Function(DexCallSite)? onCallSite,
    required void Function() onCallSiteCount,
    required void Function() onInvokeCustom,
  }) {
    // code_item 固定部分 16 字节：registers/ins/outs/tries(各 u16) +
    // debug_info_off(u32) + insns_size(u32)。
    if (codeOff < 0 || codeOff + 16 > bytes.length) return null;
    final insnsSize = tables.uint32(codeOff + 12);
    final insnsOff = codeOff + 16;
    // 先验边界：insns_size 是文件里声明的任意 u32，乘 2 之前必须确认读得到。
    if (insnsSize == 0 || insnsSize > (bytes.length - insnsOff) ~/ 2) {
      return null;
    }

    final insns =
        Uint16List.sublistView(bytes, insnsOff, insnsOff + insnsSize * 2);
    final walked = walkInsns(insns, onInstruction: onInstruction);

    for (final invoke in walked.invokes) {
      if (invoke.isCustom) {
        // invoke-custom 引用 call_site_ids，不是 method_ids。
        onInvokeCustom();
        continue;
      }
      final resolved = tables.methodReference(invoke.operand);
      if (resolved == null) continue;
      onCallSite?.call(DexCallSite(
        callerClassDescriptor: callerClassDescriptor,
        callerMethodName: callerMethodName,
        callerProtoDescriptor: callerProtoDescriptor,
        callerMethodIndex: callerMethodIndex,
        target: DexMethodReference(
          classDescriptor: resolved.$1,
          name: resolved.$2,
          protoDescriptor: resolved.$3,
          // `invoke-*` 的第二代码单元就是 method_idx（`invoke-custom` 是
          // call_site_idx，走的是另一条分支，不会到这里）。
          index: invoke.operand,
        ),
        instructionOffset: invoke.offset,
        opcode: invoke.opcode,
      ));
      onCallSiteCount();
    }

    // 自检：宽度表若有偏差，走位不会正好落在末尾。这是抓「表写错」的第二道
    // 防线（第一道是测试里与 dexdump 的偏移逐个对照）。
    return _BodyWalk(
      instructionCount: walked.instructionCount,
      desynced: !walked.reachedEnd,
    );
  }
}

class _EncodedMethod {
  final int methodIdx;
  final int codeOff;

  const _EncodedMethod(this.methodIdx, this.codeOff);
}

class _BodyWalk {
  final int instructionCount;
  final bool desynced;

  const _BodyWalk({required this.instructionCount, required this.desynced});
}
