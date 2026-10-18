import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/apkparser/parse_task.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';

/// 超限被拒时，**用户到底能看到什么**。
///
/// 用户报过的原话是「提示这个」—— 截图里只有一句「已拒绝打开：归档超出安全
/// 解压上限」。这句话回答了「为什么打不开」，却回答不了用户真正会问的三件事：
///
/// 1. 是**哪个条目**超的？我的包里到底有什么？
/// 2. 超了多少、上限是多少？差一点点还是差一个数量级？
/// 3. 这是不是意味着「这个包有毒」？
///
/// 第 3 点尤其要紧：把「拒绝解压」说成「签名失败」或「已确认恶意」，等于用
/// 一句含糊的话把一个正常的大包判死。本文件守的就是这三件事 ——
/// **不是守「有没有提示」，是守「提示里有没有能用的信息」**。
void main() {
  // 语言包是 deferred：切语言只能用 `setLocaleRaw`（直接读 `AppLocale.xx.build()`
  // 拿到的是 Future）。全局 `t` 跟着 `LocaleSettings` 走。
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  /// 构造一个「声明值就超单条目上限」的归档：一条 300 MiB 的条目。
  ///
  /// 用 `ZipEncoder` 生成而不是手拼字节 —— 只需要中心目录合法即可，
  /// 内容本身永远不会被解压（闸 1 就拦下了）。
  Uint8List oversizedArchive() {
    final archive = Archive();
    archive.add(ArchiveFile('classes.dex', 300 * 1024 * 1024, Uint8List(0)));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  group('打开阶段被预算拒绝时，原因必须带上条目与字节数', () {
    test('ApkReader.openBytes 记下 ZipBudgetViolation 的完整描述', () {
      final reader = ApkReader();
      final result = reader.openBytes(oversizedArchive());

      expect(result, ArchiveOpenResult.resourceBudgetExceeded);
      final detail = reader.budgetFailure;
      expect(detail, isNotNull, reason: '只有枚举值等于什么都没说');
      // 三项：哪个条目、声明多少、上限多少。
      expect(detail, contains('classes.dex'));
      expect(detail, contains('${300 * 1024 * 1024}'));
      expect(
        detail,
        contains('${ZipBudget.maxSingleEntryUncompressed}'),
        reason: '上限值必须出现，否则用户不知道差多少',
      );
    });

    test('没命中预算时 budgetFailure 是 null（不是空串、不是残留值）', () {
      final reader = ApkReader();
      final archive = Archive();
      archive.add(ArchiveFile('a.txt', 3, Uint8List.fromList([1, 2, 3])));
      final ok =
          reader.openBytes(Uint8List.fromList(ZipEncoder().encode(archive)));
      expect(ok, ArchiveOpenResult.ok);
      expect(reader.budgetFailure, isNull);

      // 再打开一个超限的，然后打开一个正常的 —— 不能把上一次的原因留下来。
      reader.openBytes(oversizedArchive());
      expect(reader.budgetFailure, isNotNull);
      reader.openBytes(Uint8List.fromList(ZipEncoder().encode(archive)));
      expect(reader.budgetFailure, isNull, reason: '重开必须清掉旧原因');
    });
  });

  group('这条原因能一路走到界面文案', () {
    test('有 detail：摘要 + 详情两行，详情里是条目与字节数', () {
      final text = DetailRenderer.openFailure(
        ArchiveOpenResult.resourceBudgetExceeded,
        t,
        detail: 'classes.dex: declares 314572800 bytes, over the per-entry '
            'limit of 268435456',
      );

      final lines = text.split('\n');
      expect(lines, hasLength(2), reason: '摘要一行、详情一行：$text');
      expect(lines.first, t.parse.open_failure_budget);
      expect(lines.last, startsWith('详情：'));
      expect(text, contains('classes.dex'));
      expect(text, contains('314572800'));
    });

    test('没有 detail：只给摘要，不留一个空的「详情：」', () {
      final text = DetailRenderer.openFailure(
        ArchiveOpenResult.resourceBudgetExceeded,
        t,
      );
      expect(text, t.parse.open_failure_budget);
      expect(text, isNot(contains('详情：')));
    });

    test('其余三种失败原因不会被这条详情污染', () {
      for (final r in [
        ArchiveOpenResult.notArchive,
        ArchiveOpenResult.corrupt,
        ArchiveOpenResult.ioError,
      ]) {
        expect(
          DetailRenderer.openFailure(r, t),
          isNot(contains('详情：')),
          reason: '$r',
        );
      }
    });
  });

  group('文案本身不能误导', () {
    // `late`：这段在 group 声明期就会被求值，而 `setUpAll` 还没跑，
    // 那时全局 `t` 还是默认语言。延迟到用例执行时才取文案。
    late String text;
    setUp(() {
      text = DetailRenderer.openFailure(
        ArchiveOpenResult.resourceBudgetExceeded,
        t,
        detail: 'classes.dex: declares 314572800 bytes',
      );
    });

    test('说清「什么都没解析」—— 用户据此知道结果不可用', () {
      expect(text, contains('未解析任何内容'));
    });

    test('不把拒绝解压说成签名失败', () {
      expect(
        text,
        contains('不是签名验证失败'),
        reason: '「签名状态未知」必须显式说出来，否则用户会当成验证没过',
      );
    });

    test('不把拒绝解压说成「已确认恶意」', () {
      expect(text, contains('不代表已确认恶意'));
      // 只出现「恶意」一词还不够 —— 必须是被否定的形态。
      expect(RegExp(r'已确认恶意').allMatches(text), hasLength(1));
    });

    test('四个维护中的语言包都改到了（不能只改 zh-CN）', () async {
      // 只按 zh-CN 改文案是本项目踩过的坑：ja/ko 漏改时界面整片英文，
      // 而这里四个是「维护中」的，必须同进同退。
      const locales = ['en', 'zh-CN', 'zh-HK', 'zh-TW'];
      final messages = <String, String>{};
      for (final locale in locales) {
        await LocaleSettings.setLocaleRaw(locale);
        final message = DetailRenderer.openFailure(
          ArchiveOpenResult.resourceBudgetExceeded,
          t,
        );
        messages[locale] = message;
        // 旧文案只有一句话（zh 16 字 / en 65 字符）。改过之后必须明显更长 ——
        // 这里不写死长度，只要求「不再是一句话带过」。
        expect(
          message.length,
          greaterThan(40),
          reason: '$locale 的文案还是旧的一句话说到底：$message',
        );
        expect(
          message,
          isNot(contains('**')),
          reason: '$locale：界面是纯 Text，Markdown 会原样显示',
        );
      }
      // 每种语言都不能是英文回退 —— 全量回退成英文也是一种「漏改」。
      // （zh-HK / zh-TW 措辞可以相同，所以这里逐条比，不比集合大小。）
      final english = messages['en']!;
      for (final locale in ['zh-CN', 'zh-HK', 'zh-TW']) {
        expect(
          messages[locale],
          isNot(english),
          reason: '$locale 退回了英文',
        );
        expect(
          RegExp(r'[\u4e00-\u9fff]').hasMatch(messages[locale]!),
          isTrue,
          reason: '$locale 的文案里没有中文',
        );
      }
      await LocaleSettings.setLocaleRaw('zh-CN');
    });
  });

  group('原因通过事件与异常传出去', () {
    test('ParseOpenFailed 带上 detail（worker → 主 isolate）', () {
      const event = ParseOpenFailed(
        ArchiveOpenResult.resourceBudgetExceeded,
        detail: 'classes.dex: declares 314572800 bytes',
      );
      expect(event.result, ArchiveOpenResult.resourceBudgetExceeded);
      expect(event.detail, contains('classes.dex'));

      // 不带 detail 时字段是 null，而不是空串 —— UI 据此决定要不要加第二行。
      const withoutDetail = ParseOpenFailed(ArchiveOpenResult.corrupt);
      expect(withoutDetail.detail, isNull);
    });

    test('IpaOpenFailed 同样带 detail', () {
      const event = IpaOpenFailed(
        ArchiveOpenResult.resourceBudgetExceeded,
        detail: 'Payload/App.app/App: declares 300000000 bytes',
      );
      expect(event.detail, contains('Payload/App.app/App'));
      const withoutDetail = IpaOpenFailed(ArchiveOpenResult.notArchive);
      expect(withoutDetail.detail, isNull);
    });

    test('ApkOpenException.toString() 带上 detail，日志里能直接定位', () {
      final e = ApkOpenException(
        ArchiveOpenResult.resourceBudgetExceeded,
        '/tmp/x.apk',
        detail: 'classes.dex: declares 314572800 bytes',
      );
      expect(e.toString(), contains('/tmp/x.apk'));
      expect(e.toString(), contains('classes.dex'));

      final plain = ApkOpenException(ArchiveOpenResult.corrupt, '/tmp/x.apk');
      expect(plain.toString(), isNot(contains(' — ')));
    });
  });
}
