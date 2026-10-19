// Android 组合规则表（阶段 3.1 的验收测试）。
//
// 抽表的目的不只是「好看」：抽表前 `hasImageInput` 是在**规则 B 里**算出来、
// 再由 C / D / E 读的 —— 规则的书写顺序成了语义的一部分，调换两段就会
// 改变结论，而读代码看不出来。
//
// 现在每条规则只从 `AndroidRuleFacts` 取输入，因此可以**逐条驱动**：
// 给一份只命中某一条的输入，断言结果里恰好出现那一条。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

import 'support/minimal_dex.dart';

/// 造一份最小的 DEX 字节（内容只是可打印字符串，供字符串扫描命中）。
Uint8List _blob(List<String> strings) {
  final bytes = <int>[];
  for (final s in strings) {
    bytes.addAll(s.codeUnits);
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

ApkMeta _meta({
  int? targetSdk,
  bool? usesCleartextTraffic,
  List<AndroidPermissionRequest> permissions = const [],
  List<AndroidComponent> components = const [],
}) {
  final meta = ApkMeta()
    ..permissionRequests = List.of(permissions)
    ..permissions = permissions.map((p) => p.name).toList()
    ..targetSdkVersion = targetSdk
    ..applicationUsesCleartextTraffic = usesCleartextTraffic
    ..components = List.of(components);
  return meta;
}

AndroidPermissionRequest _perm(String name, {int? maxSdk}) =>
    AndroidPermissionRequest(name, maxSdkVersion: maxSdk);

SecurityAnalysisResult _audit({
  ApkMeta? meta,
  List<String> strings = const [],
}) =>
    AndroidSecurityAudit.audit(
      meta: meta ?? _meta(targetSdk: 34),
      dexEntries: strings.isEmpty
          ? const []
          : [DexBytes('classes.dex', _blob(strings))],
    );

/// 真实带可执行栈的 `.so`：NDK 用 `-Wl,-z,execstack` 编出来的。
///
/// 路径相对**包目录**（`dart test` 的 cwd 是 `packages/apk_parser`），
/// 指回仓库根的共享夹具 —— 不在包里再放一份，免得两份漂移。
final _execStackBytes =
    File('../../test/fixtures/elf/hardening-execstack.so').readAsBytesSync();

/// 用一份真实的原生库跑审计（加固规则需要真实字节才立得住）。
SecurityAnalysisResult _auditWithNativeBytes(List<int> bytes) =>
    AndroidSecurityAudit.audit(
      meta: _meta(targetSdk: 34),
      dexEntries: const [],
      nativeEntries: [
        NativeLibraryBytes('lib/arm64-v8a/libx.so', Uint8List.fromList(bytes))
      ],
    );

/// 用一份真实 DEX 字节跑审计（SDK 盘点走 `string_ids`，必须真 DEX）。
SecurityAnalysisResult _auditWithDex(List<int> dexBytes) =>
    AndroidSecurityAudit.audit(
      meta: _meta(targetSdk: 34),
      dexEntries: [DexBytes('classes.dex', Uint8List.fromList(dexBytes))],
    );

List<String> _ids(SecurityAnalysisResult r) =>
    r.findings.map((f) => f.ruleId).toList();

void main() {
  group('组合规则表的结构', () {
    test('id 唯一、以 ANDROID- 开头，且每条都写了说明', () {
      final ids = androidSecurityRules.map((r) => r.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: '规则 id 必须唯一');
      for (final rule in androidSecurityRules) {
        // 组合规则用 `ANDROID-RULE-X`；`ANDROID-SPECIAL-ACCESS` 是**能力事实**
        // 而不是组合线索，因此不套 RULE- 前缀 —— 名字要说清它是什么。
        expect(rule.id, startsWith('ANDROID-'));
        expect(
          rule.summary.trim(),
          isNotEmpty,
          reason: '${rule.id} 没有说明 —— 抽表后说明是数据，不该只活在注释里',
        );
      }
    });

    test('表里的顺序就是报告里的输出顺序', () {
      // A → G → F：先具体（广泛访问、组合线索），再兜底（「未发现」）。
      // **F 必须最后** —— 它是「没有上传线索」的否定结论，排在具体发现前面
      // 会让读者先看到「没发现」再看「发现了什么」。
      expect(
        androidSecurityRules.map((r) => r.id).toList(),
        [
          // 清单配置类缺陷排在最前（完全可判定、后果最直接）。
          'ANDROID-DEBUGGABLE',
          'ANDROID-EXPORTED-COMPONENT',
          'ANDROID-ALLOW-BACKUP',
          'ANDROID-SHARED-USER-ID',
          'ANDROID-NATIVE-EXEC-STACK',
          'ANDROID-V1-ONLY-SIGNING',
          'ANDROID-UNSIGNED',
          'ANDROID-WEBVIEW-BRIDGE',
          // 恶意代码组合能力：证据强度高，排在清单配置类之后。
          'ANDROID-MALWARE-INDICATORS',
          // provider 直接暴露数据，排在「声明了权限但没用」之前。
          'ANDROID-PROVIDER-EXPOSED',
          'ANDROID-PERMISSION-WITHOUT-API',
          'ANDROID-RULE-A',
          'ANDROID-RULE-B',
          'ANDROID-RULE-C',
          'ANDROID-RULE-D',
          'ANDROID-RULE-E',
          'ANDROID-RULE-G',
          'ANDROID-SPECIAL-ACCESS',
          // 链接入口是事实清单（info），排在风险规则之后。
          'ANDROID-DEEPLINK',
          // SDK 盘点在 info 级，排在所有风险规则之后、兜底的 F 之前。
          'ANDROID-THIRD-PARTY-SDK',
          'ANDROID-RULE-F',
        ],
      );
    });
  });

  group('逐条驱动：每条规则都能被单独触发', () {
    /// 规则 → 只命中它的输入。
    final cases = <String, SecurityAnalysisResult Function()>{
      // 只有广泛存储权限、没有图片业务线索。
      'ANDROID-RULE-A': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [
                _perm('android.permission.MANAGE_EXTERNAL_STORAGE')
              ],
            ),
          ),
      // 相册权限 + OCR 线索，**没有**上传线索（否则会一并命中 C）。
      'ANDROID-RULE-B': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
            ),
            strings: ['Lcom/google/mlkit/vision/text/TextRecognizer;'],
          ),
      // 相册 + OCR + 上传三段齐备。
      'ANDROID-RULE-C': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
            ),
            strings: [
              'Lcom/google/mlkit/vision/text/TextRecognizer;',
              'multipart/form-data',
            ],
          ),
      // 只开明文流量，没有任何敏感线索 → 非升级版。
      'ANDROID-RULE-D': () => _audit(
            meta: _meta(targetSdk: 34, usesCleartextTraffic: true),
          ),
      // 后台入口 + 敏感数据 + 上传。
      'ANDROID-RULE-E': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [
                _perm('android.permission.READ_MEDIA_IMAGES'),
                _perm('android.permission.RECEIVE_BOOT_COMPLETED'),
              ],
            ),
            strings: ['multipart/form-data'],
          ),
      // 设备标识 + 上传（非图片类来源；没有相册/OCR，所以不会命中 B/C）。
      'ANDROID-RULE-G': () => _audit(
            strings: [
              'Landroid/telephony/TelephonyManager;',
              'multipart/form-data',
            ],
          ),
      // 清单配置类缺陷：完全可判定，不需要代码线索。
      'ANDROID-DEBUGGABLE': () => _audit(
            meta: _meta(targetSdk: 34)..applicationDebuggable = true,
          ),
      'ANDROID-EXPORTED-COMPONENT': () => _audit(
            meta: _meta(
              targetSdk: 34,
              components: const [
                AndroidComponent(
                  type: ComponentType.activity,
                  name: 'com.example.Exported',
                  exported: true,
                ),
              ],
            ),
          ),
      'ANDROID-ALLOW-BACKUP': () => _audit(
            meta: _meta(targetSdk: 34)..applicationAllowBackup = true,
          ),
      'ANDROID-SHARED-USER-ID': () => _audit(
            meta: _meta(targetSdk: 34)..sharedUserId = 'com.example.shared',
          ),
      // 栈可执行的库：手搓一个 ElfHardening 记录即可 —— 这一条不依赖
      // 真文件，解析由 elf_hardening_test.dart 单独钉住。
      'ANDROID-NATIVE-EXEC-STACK': () => _auditWithNativeBytes(_execStackBytes),
      // 只有 v1 签名：签名块解析成功但里面没有 v2/v3，**且归档里确实有
      // `META-INF/*.SF` 与同名签名块**。少了后半句，「完全没签名」会被
      // 报成「只有 v1 签名」—— 见下一条用例。
      'ANDROID-V1-ONLY-SIGNING': () => _audit(
            meta: _meta(targetSdk: 34)
              ..signingSchemes = const ApkSigningSchemes()
              ..hasV1Signature = true,
          ),
      // 完全没有签名材料：没有 v2+ 块，META-INF 里也没有 v1 两件套。
      'ANDROID-UNSIGNED': () => _audit(
            meta: _meta(targetSdk: 34)
              ..signingSchemes = const ApkSigningSchemes()
              ..hasV1Signature = false,
          ),
      // JS 桥暴露给网页内容。
      'ANDROID-WEBVIEW-BRIDGE': () => _audit(
            meta: _meta(targetSdk: 34),
            strings: ['addJavascriptInterface'],
          ),
      // 命令执行 + 动态加载：恶意代码常见组合。
      'ANDROID-MALWARE-INDICATORS': () => _audit(
            meta: _meta(targetSdk: 34),
            strings: ['Runtime.exec', 'DexClassLoader'],
          ),
      // 导出组件上声明了链接 scheme。
      'ANDROID-DEEPLINK': () => _audit(
            meta: _meta(targetSdk: 34)
              ..components = [
                const AndroidComponent(
                  type: ComponentType.activity,
                  name: 'com.example.Login',
                  exported: true,
                  hasIntentFilter: true,
                  intentFilters: [
                    IntentFilterInfo(
                      actions: ['android.intent.action.VIEW'],
                      schemes: ['myapp'],
                    ),
                  ],
                ),
              ],
          ),
      // 导出且无权限的 ContentProvider。
      'ANDROID-PROVIDER-EXPOSED': () => _audit(
            meta: _meta(targetSdk: 34)
              ..components = [
                const AndroidComponent(
                  type: ComponentType.provider,
                  name: 'com.example.LeakyProvider',
                  exported: true,
                  authorities: 'com.example.leaky',
                ),
              ],
          ),
      // 声明了通讯录权限但代码里没有 ContactsContract。
      'ANDROID-PERMISSION-WITHOUT-API': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [_perm('android.permission.READ_CONTACTS')],
            ),
            strings: ['unrelated'],
          ),
      // 特殊访问能力：**清单层的组件权限**才是判据（不需要上传）。
      // 用 DEX 字面量判会误伤 Material 的 `AccessibilityServiceInfo` 查询。
      'ANDROID-SPECIAL-ACCESS': () => _audit(
            meta: _meta(
              targetSdk: 34,
              components: const [
                AndroidComponent(
                  type: ComponentType.service,
                  name: 'com.example.A11y',
                  permission: 'android.permission.BIND_ACCESSIBILITY_SERVICE',
                ),
              ],
            ),
          ),
      // SDK 盘点：需要 DEX 里出现 `L<prefix>/` 且过引用数下限（20）。
      // 用最小 DEX 构造器（`test/support/minimal_dex.dart`）造 25 个真实
      // 类名 —— 传一段纸条不行：扫描器走 `string_ids` 精确索引，
      // 非 DEX 字节会直接判成「不是 DEX」。
      'ANDROID-THIRD-PARTY-SDK': () => _auditWithDex(
            buildDexWithClassPrefix('com/adjust/sdk', 25),
          ),
      // 没有任何上传线索 → 显式「未发现」。
      'ANDROID-RULE-F': () => _audit(strings: ['unrelated']),
    };

    test('表里的每一条都在这里有覆盖（新加规则时会红）', () {
      expect(
        cases.keys.toSet(),
        androidSecurityRules.map((r) => r.id).toSet(),
        reason: '新增规则却忘了在这里给它一个输入 —— 那就等于没被逐条驱动过',
      );
    });

    for (final entry in cases.entries) {
      test('${entry.key} 能被单独触发', () {
        final result = entry.value();
        expect(
          _ids(result),
          contains(entry.key),
          reason: '实际产出：${_ids(result)}',
        );
      });
    }

    test('规则 D 的升级变体：有敏感线索时 ruleId 加 -ESCALATED 并升到 P1', () {
      final plain = _audit(
        meta: _meta(targetSdk: 34, usesCleartextTraffic: true),
      );
      final escalated = _audit(
        meta: _meta(
          targetSdk: 34,
          usesCleartextTraffic: true,
          permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
        ),
        strings: ['Lcom/google/mlkit/vision/text/TextRecognizer;'],
      );

      expect(_ids(plain), contains('ANDROID-RULE-D'));
      expect(_ids(escalated), contains('ANDROID-RULE-D-ESCALATED'));
      expect(
        plain.findings.firstWhere((f) => f.ruleId == 'ANDROID-RULE-D').severity,
        SecuritySeverity.p2,
      );
      expect(
        escalated.findings
            .firstWhere((f) => f.ruleId == 'ANDROID-RULE-D-ESCALATED')
            .severity,
        SecuritySeverity.p1,
      );
    });
  });

  group('签名方案判据：v1-only 与未签名必须分开', () {
    SecurityAnalysisResult auditSigning({required bool? hasV1}) => _audit(
          meta: _meta(targetSdk: 34)
            ..signingSchemes = const ApkSigningSchemes()
            ..hasV1Signature = hasV1,
        );

    test('有 v1 材料 → V1-ONLY，不报 UNSIGNED', () {
      final ids = _ids(auditSigning(hasV1: true));
      expect(ids, contains('ANDROID-V1-ONLY-SIGNING'));
      expect(ids, isNot(contains('ANDROID-UNSIGNED')));
    });

    test('没有任何签名材料 → UNSIGNED，不报 V1-ONLY', () {
      final ids = _ids(auditSigning(hasV1: false));
      expect(ids, contains('ANDROID-UNSIGNED'));
      expect(
        ids,
        isNot(contains('ANDROID-V1-ONLY-SIGNING')),
        reason: '旧判据只看「没有 v2+ 块」，会把未签名包说成「只有 v1 签名」',
      );
    });

    test('v1 是否存在未判定（null）→ 两条都不报', () {
      // 从 aapt2 文本输出构造的 meta 就是这一态：不猜「没有」，也不猜「有」。
      final ids = _ids(auditSigning(hasV1: null));
      expect(ids, isNot(contains('ANDROID-V1-ONLY-SIGNING')));
      expect(ids, isNot(contains('ANDROID-UNSIGNED')));
    });

    test('签名块读不出来 → 两条都不报（「读不出」不能折成结论）', () {
      final ids = _ids(_audit(
        meta: _meta(targetSdk: 34)
          ..signingSchemes =
              const ApkSigningSchemes.unreadable('truncated block')
          ..hasV1Signature = false,
      ));
      expect(ids, isNot(contains('ANDROID-UNSIGNED')));
      expect(ids, isNot(contains('ANDROID-V1-ONLY-SIGNING')));
    });
  });

  group('不回归：规则集合与等级与抽表前一致', () {
    test('一份「什么都沾一点」的输入产出确定的有序结论', () {
      final result = _audit(
        meta: _meta(
          targetSdk: 34,
          usesCleartextTraffic: true,
          permissions: [
            _perm('android.permission.MANAGE_EXTERNAL_STORAGE'),
            _perm('android.permission.READ_MEDIA_IMAGES'),
            _perm('android.permission.RECEIVE_BOOT_COMPLETED'),
          ],
        ),
        strings: [
          'Lcom/google/mlkit/vision/text/TextRecognizer;',
          'multipart/form-data',
          'okhttp3.OkHttpClient',
          'https://cdn.example.com/api',
        ],
      );

      // 只断言**组合规则**这一段（权限逐条审计与能力发现不在这张表里）。
      final combos = result.findings
          .where((f) => f.ruleId.startsWith('ANDROID-RULE-'))
          .map((f) => '${f.ruleId}:${f.severity.name}')
          .toList();

      expect(combos, [
        'ANDROID-RULE-A:p2',
        'ANDROID-RULE-B:p2',
        // 这份输入只有字符串线索、没有调用点 → C 停在整包层面 → P2。
        'ANDROID-RULE-C:p2',
        'ANDROID-RULE-D-ESCALATED:p1',
        'ANDROID-RULE-E:p1',
      ]);
      // 有上传线索 → 不该出现「未发现」。
      expect(_ids(result), isNot(contains('ANDROID-RULE-F')));
    });

    test('没有任何线索时只产出规则 F，且置信度是 unknown', () {
      final result = _audit();
      final combos = result.findings
          .where((f) => f.ruleId.startsWith('ANDROID-RULE-'))
          .toList();
      expect(combos.map((f) => f.ruleId), ['ANDROID-RULE-F']);
      expect(combos.single.confidence, SecurityConfidence.unknown);
    });
  });
}
