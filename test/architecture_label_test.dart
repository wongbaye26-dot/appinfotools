// 「架构位数」标签的判定。
//
// 这一项是 V2.4.6 从概览页的 Hero 抽出来、并在分析页的应用信息卡里也显示
// 的。抽出来的理由正是**要有个地方钉住它** —— 它此前内联在概览页的一个
// build 方法里，没有任何测试能碰到。
//
// 判定的依据是文件里的**真实结构**（Mach-O 镜像的段位数 / 容器里的 ABI 名），
// 因此这里两边都走真实解析器：
// - iOS 用 `test/fixtures/macho/` 里的真实产物（clang 编译，期望值取自
//   `otool -hv`，见该目录的 README）；
// - Android 用 `ContainerStructure`（它的 abis 本来就来自容器里的
//   `lib/<abi>/` 条目名）。
//
// **四种结局都要覆盖**：只 64 位、只 32 位、两者都有、以及**取不到**。
// 最后一种最容易做错 —— 把「不知道」渲染成「32 位」会让用户按错的架构分发。

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/architecture_label.dart';
import 'package:apk_parser/apk_parser.dart' show ContainerStructure;
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart' show IpaContainer, MachOParser;

/// 造一个只带 `structure.abis` 的 Android 结果。
PackageAnalysisResult androidWithAbis(List<String> abis) =>
    AnalysisBuilder.buildAndroid(
      filePath: '/tmp/demo.apk',
      fileSize: 1024,
      manifestSource: FieldSource.builtinParser,
      structure: ContainerStructure(abis: abis),
    );

/// 造一个只带主可执行文件的 iOS 结果。
PackageAnalysisResult iosWithExecutable(String fixturePath) {
  final bytes = File(fixturePath).readAsBytesSync();
  final macho = MachOParser.parse(bytes);
  expect(macho.isMachO, isTrue, reason: '$fixturePath 应当是 Mach-O');
  return AnalysisBuilder.buildIos(
    filePath: '/tmp/demo.ipa',
    fileSize: 1024,
    analysis: IpaAnalysis(
      container: const IpaContainer(),
      executable: macho,
    ),
  );
}

void main() {
  group('Android：从 ABI 名推断', () {
    test('只带 arm64-v8a → 64-bit', () {
      expect(architectureLabelOf(androidWithAbis(['arm64-v8a'])), '64-bit');
    });

    test('只带 armeabi-v7a → 32-bit', () {
      expect(architectureLabelOf(androidWithAbis(['armeabi-v7a'])), '32-bit');
    });

    test('同时带 64 位与 32 位 → 64/32-bit', () {
      expect(
        architectureLabelOf(androidWithAbis(['arm64-v8a', 'armeabi-v7a'])),
        '64/32-bit',
        reason: '两者都有是「能装在老设备上」的答案，不能被简化成 64-bit',
      );
    });

    test('x86 / x86_64 同样按名字里的 64 判断', () {
      expect(architectureLabelOf(androidWithAbis(['x86_64'])), '64-bit');
      expect(architectureLabelOf(androidWithAbis(['x86'])), '32-bit');
      expect(
        architectureLabelOf(androidWithAbis(['x86_64', 'x86'])),
        '64/32-bit',
      );
    });

    test('没有原生库（abis 为空）→ 不猜，返回 null', () {
      expect(architectureLabelOf(androidWithAbis(const [])), isNull);
    });

    test('structure 整体缺失 → 不猜，返回 null', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/demo.apk',
        fileSize: 1024,
        manifestSource: FieldSource.builtinParser,
      );
      expect(architectureLabelOf(result), isNull);
    });
  });

  group('iOS：从 Mach-O 镜像推断', () {
    // 真实产物：arm64 的 thin dylib（`file` 报「Mach-O 64-bit」）。
    test('arm64 主可执行文件 → 64-bit', () {
      expect(
        architectureLabelOf(
          iosWithExecutable('test/fixtures/macho/thin-arm64.dylib'),
        ),
        '64-bit',
      );
    });

    test('fat（x86_64 + arm64，两个切片都是 64 位）→ 64-bit', () {
      expect(
        architectureLabelOf(
          iosWithExecutable('test/fixtures/macho/fat-x86_64-arm64.dylib'),
        ),
        '64-bit',
      );
    });

    test('没有主可执行文件 → 不猜，返回 null', () {
      final result = AnalysisBuilder.buildIos(
        filePath: '/tmp/demo.ipa',
        fileSize: 1024,
        analysis: IpaAnalysis(container: const IpaContainer()),
      );
      expect(architectureLabelOf(result), isNull);
    });
  });

  test('完全没有解析结果 → null', () {
    expect(architectureLabelOf(null), isNull);
  });
}
