// 界面文案必须真的随语言切换。
//
// 背景：概览页曾经整页都是硬编码英文 —— 中文界面下照样显示英文，而当时
// 没有任何测试覆盖到它。分析页的 Tab 名、导出对话框、安全卡片的置信度
// 标签同理。
//
// 注意语言包是 **deferred（懒加载）** 的：只能用异步的 `setLocaleRaw` 并
// await。`setLocaleRawSync` 会直接抛「Deferred library l_zh_CN was not
// loaded」，不 await 则拿到的还是上一个语言 —— 两种情况都会让这类断言
// 变成假通过或假失败。

import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/diff_labels.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _use(String locale) => LocaleSettings.setLocaleRaw(locale);

void main() {
  group('文案随语言切换', () {
    test('概览页', () async {
      await _use('en');
      expect(t.overview.statistics, 'Statistics');
      expect(t.overview.quick_actions, 'Quick Actions');
      expect(t.overview.release_to_analyze, 'Release to Analyze');

      await _use('zh-CN');
      expect(t.overview.statistics, '统计');
      expect(t.overview.quick_actions, '快捷操作');
      expect(t.overview.release_to_analyze, '松开以分析');

      await _use('ja');
      expect(t.overview.statistics, '統計');
    });

    test('详情页 Tab 名', () async {
      await _use('en');
      expect(t.detail_tab.overview, 'Overview');
      expect(t.detail_tab.security, 'Security');

      await _use('zh-CN');
      expect(t.detail_tab.overview, '概览');
      expect(t.detail_tab.security, '安全');
    });

    test('导出对话框', () async {
      await _use('en');
      expect(t.report.full_report, 'Full Report');
      expect(t.report.security_only, 'Security Only');

      await _use('zh-CN');
      expect(t.report.full_report, '完整报告');
      expect(t.report.security_only, '仅安全检测');
    });

    test('安全发现项的置信度标签', () async {
      await _use('en');
      expect(t.security.confidence_capability, 'Capability only');

      await _use('zh-CN');
      expect(t.security.confidence_capability, '仅具备能力');
    });

    test('报告里的「未执行安全检测」与图标导出错误', () async {
      await _use('en');
      expect(
        t.report.limitation_security,
        'Security audit was not performed for this package.',
      );
      expect(t.icon.error_svg_conversion, 'SVG conversion failed');

      await _use('zh-CN');
      expect(t.report.limitation_security, '未对该应用包执行安全检测。');
      expect(t.icon.error_svg_conversion, 'SVG 转换失败');
    });

    test('设置页的标题宽度示例文案', () async {
      await _use('en');
      expect(t.settings.title_width_sample, contains('sample'));

      await _use('zh-CN');
      expect(t.settings.title_width_sample, contains('示例'));
    });

    test('带占位符的文案两种语言都能取到', () async {
      await _use('en');
      expect(
        t.overview.last_analyzed(name: 'demo.apk'),
        'Last analyzed: demo.apk',
      );

      await _use('zh-CN');
      expect(
        t.overview.last_analyzed(name: 'demo.apk'),
        '最近分析：demo.apk',
      );
    });
  });

  // 覆盖维度名（阶段 1.3 / 阶段 3.3 的验收条件）。
  //
  // 引擎产出的是**机器 id**（`android.dex.strings` 这类，JSON 里保留它给程序读），
  // 但 UI 与 Markdown 必须显示可读文案。两个引擎合计 15 个维度。
  group('覆盖维度名', () {
    /// 引擎产出的全部维度 id。新增维度时**必须**同步这里 ——
    /// 这条测试的意义正是「新增了维度却忘了补文案」会红。
    const ids = [
      'android.manifest',
      'android.permissions',
      'android.dex.structure',
      'android.dex.strings',
      'android.dex.methodReferences',
      'android.dex.callSites',
      'android.nativeSymbols',
      'android.arsc',
      'ios.infoPlist',
      'ios.usageDescriptions',
      'ios.executables',
      'ios.macho.strings',
      'ios.nativeSymbols',
      'ios.signature',
      'ios.privacyManifest',
    ];

    test('每个维度在四个维护中的语言包里都有名字，且不留占位符', () async {
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final id in ids) {
          final label = AnalysisReport.coverageDimensionLabel(id, t);
          expect(
            label,
            isNot(id),
            reason: '$locale 下 $id 没有本地化名字，回退成了机器 id',
          );
          expect(label, isNot(contains('{')), reason: '$locale / $id');
          expect(label.trim(), isNotEmpty, reason: '$locale / $id');
        }
      }
      await _use('en');
    });

    test('中文语言包里是中文，英文语言包里没有中文', () async {
      const cjk = r'[\u4e00-\u9fff]';

      await _use('zh-CN');
      final zhLabels = ids
          .map((id) => AnalysisReport.coverageDimensionLabel(id, t))
          .toList();
      // **允许**个别维度不翻译：`ios.infoPlist` 的名字就是 `Info.plist`，
      // 那是文件名而不是术语，硬翻反而对不上原文。
      final zhChinese = zhLabels.where((l) => RegExp(cjk).hasMatch(l)).length;
      expect(
        zhChinese,
        greaterThanOrEqualTo(ids.length - 1),
        reason: 'zh-CN 下只有 $zhChinese/${ids.length} 个维度是中文：'
            '${zhLabels.join(' / ')}',
      );

      await _use('en');
      for (final id in ids) {
        final label = AnalysisReport.coverageDimensionLabel(id, t);
        expect(
          RegExp(cjk).hasMatch(label),
          isFalse,
          reason: 'en 下 $id 混进了中文：$label',
        );
      }
    });

    test('认不出的维度 id 原样返回，不显示空白', () {
      expect(
        AnalysisReport.coverageDimensionLabel('future.dimension', t),
        'future.dimension',
      );
    });
  });

  // 差异页 / 差异报告的字段名与集合名（阶段 5.2 的验收条件）。
  //
  // 与覆盖维度同一套做法：差异模型里保留**机器 id**（`android.minSdkVersion`），
  // 界面与报告必须显示本地化名字。这里刻意**不写死 id 清单**，而是从适配层
  // 实际产出的 id 里取 —— 适配层加了字段却忘了补文案，这条就会红。
  group('差异的字段名与集合名', () {
    /// 两个平台的 `DiffSubject`，覆盖全部 id（Android 专属 + iOS 专属 + 通用）。
    List<DiffSubject> subjects() => [
          diffSubjectOf(
            AnalysisBuilder.buildAndroid(
              filePath: '/tmp/a.apk',
              fileSize: 1024,
              manifestSource: FieldSource.builtinParser,
              // 带上安全结果，让 `network.*` 两个集合也出现在清单里。
              security: SecurityAnalysisResult(
                engineVersion: 'e',
                rulesVersion: 'r',
                network: NetworkFacts(domains: ['a.example']),
              ),
            ),
          ),
          diffSubjectOf(
            AnalysisBuilder.buildIos(
              filePath: '/tmp/a.ipa',
              fileSize: 1024,
            ),
          ),
        ];

    test('适配层产出的每个 id 在四个语言包里都有名字，且不留占位符', () async {
      final ids = {
        for (final s in subjects()) ...s.fields.map((f) => 'field:${f.id}'),
        for (final s in subjects()) ...s.sets.keys.map((k) => 'set:$k'),
      };
      expect(ids.length, greaterThanOrEqualTo(25), reason: 'id 清单不该缩水');

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final entry in ids) {
          final isField = entry.startsWith('field:');
          final id = entry.substring(entry.indexOf(':') + 1);
          final label =
              isField ? DiffLabels.field(id, t) : DiffLabels.set(id, t);
          expect(
            label,
            isNot(id),
            reason: '$locale 下 $id 没有本地化名字，回退成了机器 id',
          );
          expect(label, isNot(contains('{')), reason: '$locale / $id');
          expect(label.trim(), isNotEmpty, reason: '$locale / $id');
        }
      }
      await _use('en');
    });

    test('中文语言包里是中文，英文语言包里没有中文', () async {
      const cjk = r'[\u4e00-\u9fff]';
      // 字段与集合分开取：id 空间是两套，混在一起会让「集合 id 拿去查字段名」
      // 落到「认不出就原样返回」那条分支上，断言随即失去意义（第一版就是这么错的）。
      final fieldIds = {
        for (final s in subjects()) ...s.fields.map((f) => f.id),
      };
      final setIds = {
        for (final s in subjects()) ...s.sets.keys,
      };

      await _use('zh-CN');
      final zhLabels = [
        for (final id in fieldIds) DiffLabels.field(id, t),
        for (final id in setIds) DiffLabels.set(id, t),
      ];
      // 允许**个别**名字不翻：`SHA-256` 是哈希名、`Bundle ID` 与 `ABI` 是
      // 通用技术缩写，硬翻反而对不上原文。但**允许清单是写死的** ——
      // 新冒出一个没翻的名字会立刻失败，而不是被「允许个别不翻」放过去。
      const untranslated = {'SHA-256', 'Bundle ID', 'ABI'};
      expect(
        zhLabels.where((l) => !RegExp(cjk).hasMatch(l)).toSet(),
        untranslated,
        reason: 'zh-CN 下未翻译的名字应当**只有**这几个公认缩写：'
            '${zhLabels.join(' / ')}',
      );

      await _use('en');
      for (final id in fieldIds) {
        final label = DiffLabels.field(id, t);
        expect(
          RegExp(cjk).hasMatch(label),
          isFalse,
          reason: 'en 下字段 $id 混进了中文：$label',
        );
      }
      for (final id in setIds) {
        final label = DiffLabels.set(id, t);
        expect(
          RegExp(cjk).hasMatch(label),
          isFalse,
          reason: 'en 下集合 $id 混进了中文：$label',
        );
      }
    });

    test('三态标签与页面文案确实随语言切换', () async {
      await _use('en');
      expect(t.diff.kind_added, 'Added');
      expect(t.diff.kind_removed, 'Removed');
      expect(t.diff.kind_changed, 'Changed');
      expect(DiffLabels.kind(DiffKind.unknown, t), 'Cannot compare');

      await _use('zh-CN');
      expect(t.diff.kind_added, '新增');
      expect(t.diff.kind_removed, '删除');
      expect(t.diff.kind_changed, '变更');
      expect(DiffLabels.kind(DiffKind.unknown, t), '无法比较');
      // 「没读到」与「文件里没有」在文案上必须分开 —— 这是本页的核心口径。
      expect(t.diff.value_absent, isNot(t.diff.kind_added));
    });

    test('认不出的 id 原样返回，不显示空白', () {
      expect(DiffLabels.field('future.field', t), 'future.field');
      expect(DiffLabels.set('future.set', t), 'future.set');
    });

    test('报告的页面文案随语言切换', () async {
      await _use('en');
      expect(t.diff.report_title, 'Version comparison report');
      expect(t.diff.section_scope, 'Scope');
      expect(t.diff.export_action, 'Export comparison report');

      await _use('zh-CN');
      expect(t.diff.report_title, '版本差异报告');
      expect(t.diff.section_scope, '范围说明');
      expect(t.diff.export_action, '导出对比报告');
    });

    test('四个语言包的 diff 分组键集完全一致', () {
      // slang 在缺键时**静默回退到 base locale** —— 也就是说「补了 en、
      // 忘了 zh-CN」在运行时不报任何错，只是那一句变成英文。
      // 这条直接读文件比对键集，把这种漂移挡在提交前。
      //
      // ja / ko 按先例整段省略（走 base_locale 回退），因此**不在**比对范围内；
      // 只有 `nav.diff` 是六个语言都补的，单独核对。
      final locales = ['en', 'zh-CN', 'zh-HK', 'zh-TW'];
      final keys = <String, Set<String>>{};
      for (final locale in locales) {
        final file = File('assets/i18n/$locale.json');
        expect(file.existsSync(), isTrue, reason: '缺少语言包 $locale');
        final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final diff = map['diff'] as Map<String, dynamic>;
        keys[locale] = {
          ...diff.keys,
          for (final k in (diff['fields'] as Map).keys) 'fields.$k',
          for (final k in (diff['sets'] as Map).keys) 'sets.$k',
        }..removeAll({'fields', 'sets'});
      }

      final base = keys['en']!;
      for (final locale in locales) {
        expect(
          keys[locale],
          base,
          reason: '$locale 的 diff 键集与 en 不一致：'
              '${keys[locale]!.difference(base)} / ${base.difference(keys[locale]!)}',
        );
      }

      // 导航项是常驻界面元素，六个语言都必须有 —— 缺了会直接看见英文。
      for (final locale in ['en', 'ja', 'ko', 'zh-CN', 'zh-HK', 'zh-TW']) {
        final map = jsonDecode(
          File('assets/i18n/$locale.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(
          (map['nav'] as Map<String, dynamic>)['diff'],
          isNotNull,
          reason: '$locale 缺少 nav.diff',
        );
      }
    });
  });

  // V2.4.2 任务 5.2：ja / ko **已补齐**的分组。
  //
  // 这三组此前在 ja / ko 里整组缺失（回退成英文）。本轮的补法是逐条翻译，
  // 这里把它们钉住：键集与 en 一致、不得是英文复制、占位符必须保留。
  //
  // **范围说明（重要）**：只覆盖**已补齐**的四组。`security` / `report` /
  // `field_diagnostic` / `analysis_diagnostic` 等组仍未补齐（见
  // `docs/plans/V2.4.2_PROGRESS.md` §14），因此这里**不**断言「六个语言键集全等」——
  // 那样会立刻变红，而那是「还没做」而不是「做错了」。等那些组补齐后再扩这张表。
  group('ja / ko 已补齐的分组', () {
    const migratedGroups = ['coverage', 'diff', 'ios_info', 'security'];

    /// 本就不该翻译的项（文件名 / 算法名 / Apple 产品名 / 平台标识 /
    /// 纯占位符模板 / 目标语言本来就用 ASCII 标点）。
    /// **逐个列出理由**，避免「懒得翻就丢进白名单」。
    const allowSameAsEnglish = {
      'coverage.dimensions.ios_infoPlist': 'Info.plist 是文件名，不是术语',
      'coverage.summary_join:ko': '韩文用 ASCII 分号，与 en 相同是正常结果',
      'diff.fields.file_sha256': 'SHA-256 是算法名',
      'ios_info.code_signature_dir': '目录名 _CodeSignature',
      'ios_info.codesign_cdhash': 'Apple 的技术标识 CDHash',
      'ios_info.device_ipad': 'Apple 产品名',
      'ios_info.device_iphone': 'Apple 产品名',
      'ios_info.device_tv': 'Apple 产品名 Apple TV',
      'ios_info.device_watch': 'Apple 产品名 Apple Watch',
      'ios_info.platform_badge': '平台标识 iOS (.ipa)',
      'ios_info.uuid': '技术缩写 UUID',
      'security.list_join:ko': '韩文用 ASCII 逗号，与 en 相同是正常结果',
      'security.parts.join:ko': '韩文用 ASCII 分号，与 en 相同是正常结果',
      'security.native_symbols.line:ko': '韩文用 ASCII 括号，与 en 相同是正常结果',
      // 下面四个是**纯占位符模板**：整句就是 `{name}: {note}` 这种，
      // 没有可翻译的自然语言，日韩文与 en 逐字节相同是唯一正确的结果。
      'security.finding_texts.android_permission_expired':
          '纯占位符模板 {name}: {note}',
      'security.finding_texts.android_permission_inert':
          '纯占位符模板 {name}: {note}',
      'security.finding_texts.android_permission_rule': '纯占位符模板 {description}',
      'security.finding_texts.android_permission_rule_risk_note':
          '纯占位符模板 {riskNote}',
      'security.finding_texts.android_permission_rule_with_note:ko':
          '纯占位符模板 {description} ({note})，韩文用 ASCII 括号',
      'diff.sets.android_nativeCodes': 'ABI 是技术缩写，不翻译',
      'ios_info.bundle_kind_app_extension:ja': 'Apple 的官方日文写法就是 App Extension',
    };

    /// ja 必须出现非 ASCII 字符；ko 必须出现谚文。
    ///
    /// **这一条比「逐字节不等于 en」强得多**：后者只抓得住「原样抄英文」，
    /// 抓不住「把一句**别的**英文写进非英文语言包」。实测：把 ko 的一条安全
    /// 说明换成一句截短的英文，逐字节比对是绿的（它确实不等于 en 原文），
    /// 而这条判据立刻变红。
    ///
    /// 白名单里那些（`Info.plist` / `SHA-256` / `{name}: {note}` / 韩文的 ASCII
    /// 分隔符）本来就不含假名或谚文，逐个给了理由。
    final hangul = RegExp(r'[\uac00-\ud7af\u1100-\u11ff]');
    bool looksLocalised(String locale, String value) {
      if (locale == 'ko') return hangul.hasMatch(value);
      // ja：允许纯汉字词（如「数量」「権限」），只要求出现非 ASCII 字符。
      return value.runes.any((r) => r > 0x7f);
    }

    Map<String, String> localeOf(String locale) {
      final out = <String, String>{};
      void walk(Map<String, dynamic> node, String prefix) {
        node.forEach((key, value) {
          final path = prefix.isEmpty ? key : '$prefix.$key';
          if (value is Map<String, dynamic>) {
            walk(value, path);
          } else {
            out[path] = value as String;
          }
        });
      }

      walk(
        jsonDecode(File('assets/i18n/$locale.json').readAsStringSync())
            as Map<String, dynamic>,
        '',
      );
      return out;
    }

    Iterable<String> groupKeys(Map<String, String> map, String group) =>
        map.keys.where((k) => k.startsWith('$group.'));

    test('四组在 ja / ko 里键集与 en 一致（逐键比对，不是只看总数）', () {
      final en = localeOf('en');
      for (final locale in ['ja', 'ko']) {
        final other = localeOf(locale);
        for (final group in migratedGroups) {
          final expected = groupKeys(en, group).toSet();
          final actual = groupKeys(other, group).toSet();
          expect(expected, isNotEmpty, reason: '$group 在 en 里一个键都没有？');
          expect(actual.difference(expected), isEmpty,
              reason: '$locale 的 $group 有多余键');
          final missing = expected.difference(actual);
          expect(missing, isEmpty,
              reason: '$locale 的 $group 缺 ${missing.length} 个键：'
                  '${missing.take(5).join(', ')}');
        }
      }
    });

    test('译文不是英文复制（白名单除外，白名单逐条给了理由）', () {
      final en = localeOf('en');
      for (final locale in ['ja', 'ko']) {
        final other = localeOf(locale);
        for (final group in migratedGroups) {
          for (final key in groupKeys(en, group)) {
            final value = other[key];
            if (value == null) continue; // 上一条测试负责报缺键
            if (value != en[key]) continue;
            if (allowSameAsEnglish.containsKey(key) ||
                allowSameAsEnglish.containsKey('$key:$locale')) {
              continue;
            }
            fail('$locale 的 $key 与英文完全相同，疑似英文复制充数：$value');
          }
        }
      }
    });

    test('占位符与 en 完全一致（名称与个数都要一致）', () {
      final pattern = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
      Set<String> placeholdersOf(String s) =>
          pattern.allMatches(s).map((m) => m.group(1)!).toSet();

      final en = localeOf('en');
      for (final locale in ['ja', 'ko']) {
        final other = localeOf(locale);
        for (final group in migratedGroups) {
          for (final key in groupKeys(en, group)) {
            final value = other[key];
            if (value == null) continue;
            expect(placeholdersOf(value), placeholdersOf(en[key]!),
                reason: '$locale 的 $key 占位符不一致');
          }
        }
      }
    });

    test('没有空串、没有未替换的插值对象', () {
      for (final locale in ['ja', 'ko']) {
        final other = localeOf(locale);
        for (final group in migratedGroups) {
          for (final key in groupKeys(other, group)) {
            final value = other[key]!;
            expect(value.trim(), isNotEmpty, reason: '$locale/$key 是空串');
            expect(value, isNot(contains('Instance of')),
                reason: '$locale/$key');
            expect(value, isNot(contains('Closure:')), reason: '$locale/$key');
          }
        }
      }
    });

    test('译文确实是该语言（ja 含非 ASCII / ko 含谚文），白名单除外', () {
      for (final locale in ['ja', 'ko']) {
        final other = localeOf(locale);
        for (final group in migratedGroups) {
          for (final key in groupKeys(other, group)) {
            if (allowSameAsEnglish.containsKey(key) ||
                allowSameAsEnglish.containsKey('$key:$locale')) {
              continue;
            }
            final value = other[key]!;
            expect(
              looksLocalised(locale, value),
              isTrue,
              reason: '$locale 的 $key 看起来不是 $locale 的译文：$value',
            );
          }
        }
      }
    });
  });
}
