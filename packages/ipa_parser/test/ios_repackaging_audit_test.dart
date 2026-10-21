// 重打包 / 注入识别（`IOS-REPACKAGED`）与它的输入 `IpaLayoutFacts`。
//
// ## 判据是**布局**，不是内容
//
// 注入的 dylib 是一个「多出来的文件」，不是某段可疑字节。因此这条规则的
// 输入是归档条目名，而测试也是拿真实样本的**条目形状**来构造的。
//
// ## 期望值来自真实样本，不是来自本项目
//
// 下面这些文件名取自 `/Users/wangbaye/Projects/ipa` 里的真实 IPA（用 `unzip -Z1`
// 独立核对过）：
//
// - 重打包样本：`Ptv_signed_v3.ipa` → `Payload/JpoALFZUs.app/kKipwwl.dylib`
// - 干净样本：`33-v8.5.5.ipa` → 只有
//   `Payload/Runner.app/Frameworks/libswift_Concurrency.dylib`
//
// ## 被否掉的判据
//
// 「bundle 目录名与 `CFBundleName` 不一致」在**全部** 10 个样本上都成立，
// 包括干净的（`33-v8.5.5.ipa` 目录 `Runner.app` / 名称 `33`）。用它等于
// 100% 误报 —— 所以这里也钉一条测试，防止有人再把它加回来。
import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

ArchiveFile _file(String name) => ArchiveFile(name, 0, <int>[]);

Archive _archive(List<String> paths) {
  final archive = Archive();
  for (final path in paths) {
    archive.addFile(_file(path));
  }
  return archive;
}

IosBundle _mainApp(Archive archive) =>
    IpaContainerReader.read(archive).mainApp!;

IpaLayoutFacts _facts(List<String> paths) {
  final archive = _archive(paths);
  return IpaLayoutReader.read(archive, _mainApp(archive));
}

void main() {
  group('IpaLayoutReader：根目录 dylib', () {
    test('干净布局（dylib 全在 Frameworks/）→ 不命中', () {
      // 真实样本 33-v8.5.5.ipa 的形状。
      final facts = _facts([
        'Payload/Runner.app/Info.plist',
        'Payload/Runner.app/Runner',
        'Payload/Runner.app/Frameworks/libswift_Concurrency.dylib',
      ]);

      expect(facts.dylibsAtBundleRoot, isEmpty);
      expect(facts.hasDylibInjection, isFalse);
    });

    test('根目录多一个 dylib → 命中，并给出完整路径', () {
      // 真实样本 Ptv_signed_v3.ipa 的形状。
      final facts = _facts([
        'Payload/JpoALFZUs.app/Info.plist',
        'Payload/JpoALFZUs.app/JpoALFZUs',
        'Payload/JpoALFZUs.app/Frameworks/libswift_Concurrency.dylib',
        'Payload/JpoALFZUs.app/kKipwwl.dylib',
      ]);

      expect(facts.hasDylibInjection, isTrue);
      expect(facts.dylibsAtBundleRoot, ['Payload/JpoALFZUs.app/kKipwwl.dylib']);
    });

    test('Frameworks 的子目录里的 dylib 不算（真实样本 皇冠 的形状）', () {
      final facts = _facts([
        'Payload/SjYTiEFUyV.app/SjYTiEFUyV',
        'Payload/SjYTiEFUyV.app/Frameworks/AppRuntime/ATHelper.dylib',
        'Payload/SjYTiEFUyV.app/Frameworks/Partner/libutils.dylib',
        'Payload/SjYTiEFUyV.app/Frameworks/libswift_Concurrency.dylib',
      ]);

      expect(facts.dylibsAtBundleRoot, isEmpty);
    });

    test('嵌套 bundle 里的 dylib 不算（只看主 .app 根目录）', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/App.app/PlugIns/Share.appex/Share',
        'Payload/App.app/PlugIns/Share.appex/Injected.dylib',
      ]);

      expect(facts.dylibsAtBundleRoot, isEmpty);
    });

    test('反斜杠分隔的条目名同样识别', () {
      final facts = _facts([
        'Payload\\App.app\\App',
        'Payload\\App.app\\Evil.dylib',
      ]);

      expect(facts.dylibsAtBundleRoot, ['Payload/App.app/Evil.dylib']);
    });

    test('大小写混写的扩展名也认', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/App.app/Evil.DYLIB',
      ]);

      expect(facts.hasDylibInjection, isTrue);
    });

    test('多个根目录 dylib 全部列出并排序（结果稳定）', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/App.app/zzz.dylib',
        'Payload/App.app/aaa.dylib',
      ]);

      expect(facts.dylibsAtBundleRoot, [
        'Payload/App.app/aaa.dylib',
        'Payload/App.app/zzz.dylib',
      ]);
    });

    test('其它 bundle 的根目录 dylib 不会算到主应用头上', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/Other.app/Other',
        'Payload/Other.app/Evil.dylib',
      ]);

      expect(facts.dylibsAtBundleRoot, isEmpty);
    });
  });

  group('IosRepackagingAudit：发现项', () {
    SecurityFinding? finding(IpaLayoutFacts layout) {
      final findings = IosRepackagingAudit.audit(layout: layout);
      return findings.isEmpty ? null : findings.single;
    }

    test('干净布局不产出发现项', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/App.app/Frameworks/libswift_Concurrency.dylib',
      ]);

      expect(finding(facts), isNull);
    });

    test('根目录 dylib → P2，正文带路径，证据指到条目', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/App.app/kKipwwl.dylib',
      ]);
      final f = finding(facts);

      expect(f, isNotNull);
      expect(f!.ruleId, 'IOS-REPACKAGED');
      expect(f.severity, SecuritySeverity.p2);
      expect(f.messageCode, 'ios.repackaged');
      expect(f.recommendationCode, 'ios.repackaged.review');
      expect(f.limitationCode, 'ios.repackaged.limitation');
      expect(f.messageArgs['dylibs'], ['Payload/App.app/kKipwwl.dylib']);
      expect(f.messageArgs['count'], 1);
      expect(
        f.evidence.map((e) => e.location),
        contains('Payload/App.app/kKipwwl.dylib'),
      );
    });

    test('空布局（没算过）不产出发现项', () {
      expect(finding(IpaLayoutFacts.empty), isNull);
    });

    test('局限里必须写明「只改名的重打包看不到」', () {
      final facts = _facts([
        'Payload/App.app/App',
        'Payload/App.app/kKipwwl.dylib',
      ]);
      final f = finding(facts)!;

      // 这是这条规则最容易被误读的地方：没报不等于没被改过。
      expect(f.limitation, contains('renames the bundle'));
      expect(f.limitation, contains('signature'));
    });
  });

  group('被否掉的判据：bundle 目录名 vs CFBundleName', () {
    test('干净样本的目录名与 CFBundleName 本来就不一致', () {
      // 真实样本 33-v8.5.5.ipa：目录 `Runner.app`，`CFBundleName` 是 `33`。
      // 这条判据在全部 10 个真实样本上都成立（含干净的），用它等于 100% 误报。
      // 这里不做行为断言（规则本来就没实现它），只把事实钉住：
      // 若有人想加回来，先看一眼这个用例的名字。
      const dirName = 'Runner';
      const cfBundleName = '33';
      expect(dirName, isNot(cfBundleName));
    });
  });
}
