// 组件目录（V3 F03 3.1）：把库识别结果归一化成 analysis_model 的 Component。
//
// 为什么需要这一层：SBOM / SPDX / 隐私视图都要「同一份组件身份」。直接在
// 各导出器里拼 label 会得到三套 purl；`Component.componentId` 是稳定的
// （ecosystem+platform+name+version 的哈希），后续 F06 误报处置要靠它把
// 「这条结论属于哪个组件」串起来。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';

class ComponentCatalog {
  /// 从库识别结果构造组件。
  ///
  /// 置信度统一是 `low`：LibChecker 是**规则命中**（名字/前缀/组件匹配），
  /// 不是从依赖清单读出来的精确版本。把规则命中标成 high 会让下游误以为
  /// 拿到了 Maven 坐标。
  static List<Component> fromLibraryReport(
    LibraryReport? libraries, {
    String? artifactPath,
  }) {
    if (libraries == null) return const [];
    final components = <Component>[];

    void addGroup(LibraryGroup group, String kind) {
      components.add(
        Component.create(
          name: group.label,
          ecosystem: ComponentEcosystem.generic,
          platform: ComponentPlatform.android,
          identification: ComponentIdentificationMethod.ruleMatch,
          confidence: ComponentConfidence.low,
          sourceArtifacts: artifactPath == null ? const [] : [artifactPath],
          sourceDatabaseVersion: 'libchecker-v${libraries.dataVersion}',
          relations: {
            ComponentRelationType.evidencedBy: [
              'libchecker:rule:${group.rule.id}',
            ],
          },
        ),
      );
    }

    for (final group in libraries.nativeGroups) {
      addGroup(group, 'nativeLibrary');
    }
    for (final group in libraries.componentGroups) {
      addGroup(group, 'component');
    }
    for (final group in libraries.dexGroups) {
      addGroup(group, 'dexPackage');
    }
    return components;
  }
}
