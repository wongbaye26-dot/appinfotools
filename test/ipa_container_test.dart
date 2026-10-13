// IPA 容器结构解析测试（规范 5.1）。
//
// 这一层只读条目名与声明尺寸，所以测试样本可以直接用 `ArchiveFile` 构造 ——
// 不需要真实 IPA，也不需要解压任何东西。真正需要真实样本的是 plist 字段提取
// 与 Mach-O 解析，那是另外的测试。

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

ArchiveFile _file(String name, [int size = 16]) =>
    ArchiveFile(name, size, List.filled(size.clamp(0, 8), 0));

ArchiveFile _dir(String name) => ArchiveFile(name, 0, [])..isFile = false;

/// 一个结构完整的标准 IPA。
Archive _standardIpa() => Archive()
  ..addFile(_dir('Payload/'))
  ..addFile(_dir('Payload/MyApp.app/'))
  ..addFile(_file('Payload/MyApp.app/Info.plist', 800))
  ..addFile(_file('Payload/MyApp.app/MyApp', 4096))
  ..addFile(_file('Payload/MyApp.app/_CodeSignature/CodeResources', 200))
  ..addFile(_file('Payload/MyApp.app/embedded.mobileprovision', 300))
  ..addFile(_file('Payload/MyApp.app/Assets.car', 1024))
  ..addFile(_dir('Payload/MyApp.app/PlugIns/'))
  ..addFile(_file('Payload/MyApp.app/PlugIns/Share.appex/Info.plist', 400))
  ..addFile(_file('Payload/MyApp.app/PlugIns/Share.appex/Share', 2048))
  ..addFile(_dir('Payload/MyApp.app/Watch/'))
  ..addFile(_file('Payload/MyApp.app/Watch/Companion.app/Info.plist', 300))
  ..addFile(_file('Payload/MyApp.app/Watch/Companion.app/Companion', 1024))
  ..addFile(_dir('Payload/MyApp.app/Frameworks/'))
  ..addFile(_file('Payload/MyApp.app/Frameworks/Alamofire.framework/Alamofire',
      8192))
  ..addFile(_file('Payload/MyApp.app/Frameworks/Alamofire.framework/Info.plist',
      300));

void main() {
  group('IpaContainerReader — 标准 IPA', () {
    test('主应用被正确定位', () {
      final container = IpaContainerReader.read(_standardIpa());

      expect(container.hasPayloadDirectory, isTrue);
      expect(container.mainApp, isNotNull);
      expect(container.mainApp!.path, 'Payload/MyApp.app');
      expect(container.mainApp!.name, 'MyApp.app');
      expect(container.mainApp!.kind, IosBundleKind.mainApp);
      expect(container.hasMultipleMainApps, isFalse);
    });

    test('扩展 / Watch / 框架都被识别，且按路径位置而非名字判断', () {
      final container = IpaContainerReader.read(_standardIpa());

      expect(container.appExtensions.map((b) => b.path).toList(),
          ['Payload/MyApp.app/PlugIns/Share.appex']);
      expect(container.watchApps.map((b) => b.path).toList(),
          ['Payload/MyApp.app/Watch/Companion.app']);
      expect(container.frameworks.map((b) => b.path).toList(),
          ['Payload/MyApp.app/Frameworks/Alamofire.framework']);
      expect(container.nestedApps, isEmpty);
    });

    test('主应用排在最前，其余按路径排序（顺序稳定）', () {
      final container = IpaContainerReader.read(_standardIpa());

      expect(container.bundles.first.kind, IosBundleKind.mainApp);
      final rest = container.bundles.skip(1).map((b) => b.path).toList();
      expect(rest, List.of(rest)..sort());
    });

    test('Info.plist 的路径与大小被记录', () {
      final container = IpaContainerReader.read(_standardIpa());
      final main = container.mainApp!;

      expect(main.infoPlistPath, 'Payload/MyApp.app/Info.plist');
      expect(main.infoPlistSize, 800);
    });

    test('签名材料存在性被记录 —— 但只表示「存在」', () {
      final container = IpaContainerReader.read(_standardIpa());
      final main = container.mainApp!;

      expect(main.hasCodeSignatureDirectory, isTrue);
      expect(main.hasEmbeddedProvision, isTrue);
      expect(main.hasSignatureMaterials, isTrue);
      expect(container.hasAnySignatureMaterials, isTrue);
    });

    test('嵌套 bundle 的条目计入外层 bundle（体积不失真）', () {
      final container = IpaContainerReader.read(_standardIpa());
      final main = container.mainApp!;
      final extension_ = container.appExtensions.single;

      // 主应用：5 个直属文件 + 扩展 2 + Watch 2 + 框架 2 = 11
      expect(main.fileCount, 11);
      expect(extension_.fileCount, 2);
      expect(main.uncompressedBytes,
          greaterThan(extension_.uncompressedBytes));
    });

    test('目录条目不计入文件数', () {
      final archive = Archive()
        ..addFile(_dir('Payload/'))
        ..addFile(_dir('Payload/A.app/'))
        ..addFile(_file('Payload/A.app/Info.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.fileEntryCount, 1);
      expect(container.mainApp!.fileCount, 1);
    });
  });

  group('IpaContainerReader — 不假设只有一个 app', () {
    test('多个 Payload/*.app 时全部保留，并标记异常', () {
      final archive = Archive()
        ..addFile(_file('Payload/Bravo.app/Info.plist'))
        ..addFile(_file('Payload/Alpha.app/Info.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.payloadApps, hasLength(2));
      expect(container.hasMultipleMainApps, isTrue);
      // 多个候选时取路径排序第一个，且**不猜测**哪个才是真的
      expect(container.mainApp!.path, 'Payload/Alpha.app');
      expect(container.payloadApps.map((b) => b.path).toList(),
          ['Payload/Alpha.app', 'Payload/Bravo.app']);
    });

    test('缺少 Payload/ 时不崩溃，只是如实记录', () {
      final archive = Archive()
        ..addFile(_file('MyApp.app/Info.plist'))
        ..addFile(_file('MyApp.app/MyApp'));

      final container = IpaContainerReader.read(archive);

      expect(container.hasPayloadDirectory, isFalse);
      expect(container.payloadApps, isEmpty);
      expect(container.mainApp, isNull);
      // 仍然被识别成一个 bundle，只是不是主应用
      expect(container.bundles, hasLength(1));
      expect(container.bundles.single.kind, IosBundleKind.nestedApp);
    });
  });

  group('IpaContainerReader — 分类边界', () {
    test('PlugIns/ 下以 .app 结尾的按扩展处理（老包写法）', () {
      final archive = Archive()
        ..addFile(_file('Payload/A.app/Info.plist'))
        ..addFile(_file('Payload/A.app/PlugIns/Old.app/Info.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.appExtensions.map((b) => b.path).toList(),
          ['Payload/A.app/PlugIns/Old.app']);
      expect(container.nestedApps, isEmpty);
    });

    test('不在 PlugIns/Watch 下的嵌套 .app 归为 nestedApp', () {
      final archive = Archive()
        ..addFile(_file('Payload/A.app/Info.plist'))
        ..addFile(_file('Payload/A.app/Resources/Helper.app/Info.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.nestedApps.map((b) => b.path).toList(),
          ['Payload/A.app/Resources/Helper.app']);
    });

    test('没有 Info.plist 的 bundle 仍被列出，字段为 null', () {
      final archive = Archive()..addFile(_file('Payload/A.app/MyApp'));

      final container = IpaContainerReader.read(archive);

      expect(container.mainApp, isNotNull);
      expect(container.mainApp!.infoPlistPath, isNull);
      expect(container.mainApp!.infoPlistSize, isNull);
    });

    test('_CodeSignature 只在直接属于该 bundle 时才算', () {
      final archive = Archive()
        ..addFile(_file('Payload/A.app/Info.plist'))
        ..addFile(_file('Payload/A.app/PlugIns/B.appex/Info.plist'))
        ..addFile(_file('Payload/A.app/PlugIns/B.appex/_CodeSignature/R'));

      final container = IpaContainerReader.read(archive);

      expect(container.mainApp!.hasCodeSignatureDirectory, isFalse,
          reason: '外层 bundle 自己并没有 _CodeSignature');
      expect(container.appExtensions.single.hasCodeSignatureDirectory, isTrue);
    });
  });

  group('IpaContainerReader — 条目名规范化', () {
    test('反斜杠分隔符被当作目录分隔符', () {
      final archive = Archive()
        ..addFile(_file(r'Payload\MyApp.app\Info.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.hasPayloadDirectory, isTrue);
      expect(container.mainApp!.path, 'Payload/MyApp.app');
    });

    test('重复分隔符被折叠', () {
      final archive = Archive()
        ..addFile(_file('Payload//MyApp.app//Info.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.mainApp!.path, 'Payload/MyApp.app');
      expect(container.mainApp!.infoPlistPath, 'Payload/MyApp.app/Info.plist');
    });
  });

  group('IpaContainerReader — 边界', () {
    test('空归档返回空容器', () {
      final container = IpaContainerReader.read(Archive());

      expect(container.bundles, isEmpty);
      expect(container.payloadApps, isEmpty);
      expect(container.mainApp, isNull);
      expect(container.hasPayloadDirectory, isFalse);
      expect(container.fileEntryCount, 0);
      expect(container.totalUncompressedBytes, 0);
      expect(container.hasAnySignatureMaterials, isFalse);
    });

    test('没有任何 bundle 的归档不报错', () {
      final archive = Archive()
        ..addFile(_file('readme.txt'))
        ..addFile(_file('Payload/loose.plist'));

      final container = IpaContainerReader.read(archive);

      expect(container.bundles, isEmpty);
      expect(container.fileEntryCount, 2);
      expect(container.hasPayloadDirectory, isTrue);
    });

    test('总解压字节数是全部文件条目之和', () {
      final archive = Archive()
        ..addFile(_file('Payload/A.app/Info.plist', 100))
        ..addFile(_file('Payload/A.app/A', 200))
        ..addFile(_file('other.txt', 50));

      expect(IpaContainerReader.read(archive).totalUncompressedBytes, 350);
    });
  });
}
