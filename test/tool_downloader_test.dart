// ToolDownloader 的**校验和链路** —— T0-2 安全修复的回归测试。
//
// ## 背景
//
// 2026-10-13 的安全审计给出 T0-2：工具归档（platform-tools / build-tools）
// 下载后会被**本进程直接执行**，而当时是「零校验就执行」。修复是两件事：
//
// 1. 官方 Google 仓库排在最前，个人 GitHub 镜像只作兜底
//    （`buildRepositoryIndexUrls`）—— 镜像排在首位时，该账号一旦被接管，
//    所有用户拿到的都是攻击者投放的 adb/aapt2；
// 2. 解析索引里的 `<checksum>` 并在**解包之前**强制比对；索引未声明校验和
//    即**拒绝安装**（`parseChecksums` / `ArchiveInfo.preferredAlgorithm` /
//    `verifyArchiveChecksum`）。
//
// 本文件钉住这两条。**这两条一旦回归，编译通过、界面无异常、也没有别的测试会红。**
//
// ## 本测试的边界
//
// - **不发任何网络请求**（只调纯函数与本地临时文件）；
// - **不下载、不解包、不执行**任何二进制；
// - 期望摘要由 `shasum` 与 `openssl dgst` **两个独立工具**算过并交叉一致，
//   不是从本实现反推的（见 `_fixtureSha256` 上方注释）。

import 'dart:io';

import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定的夹具内容。
const _fixtureText = 'AppInfoTool checksum fixture v1\n';

// 期望摘要的来源（两个独立工具，结果一致）：
//
//   printf 'AppInfoTool checksum fixture v1\n' > f        # 32 字节
//   shasum -a 256 f      → 86f55567c2126c3fa6cd42184f2d4fb04c18e39711fc854e31a8d053ff98fa43
//   openssl dgst -sha256 f → 86f55567c2126c3fa6cd42184f2d4fb04c18e39711fc854e31a8d053ff98fa43
//   shasum -a 1 f        → 0452591fb2b65205eae00164e2cbc291540569f5
//   openssl dgst -sha1 f   → 0452591fb2b65205eae00164e2cbc291540569f5
//   md5 -q f             → 065054a450d05107588633851336f38b
//   openssl dgst -md5 f    → 065054a450d05107588633851336f38b
const _fixtureSha256 =
    '86f55567c2126c3fa6cd42184f2d4fb04c18e39711fc854e31a8d053ff98fa43';
const _fixtureSha1 = '0452591fb2b65205eae00164e2cbc291540569f5';
const _fixtureMd5 = '065054a450d05107588633851336f38b';

/// 与夹具内容**不匹配**的摘要（改一个字符即可，长度与形态保持合法）。
const _wrongSha256 =
    '86f55567c2126c3fa6cd42184f2d4fb04c18e39711fc854e31a8d053ff98fa44';

/// 构造一个形如仓库索引 `<complete>` 片段的 XML。
String _completeBody(String checksumXml) =>
    '<url>https://dl.google.com/android/repository/x.zip</url>\n'
    '<size>12345</size>\n'
    '$checksumXml';

void main() {
  late Directory tempDir;
  late File fixture;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tool_downloader_test');
    fixture = File('${tempDir.path}/archive.zip');
    await fixture.writeAsString(_fixtureText);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // -------------------------------------------------------------------
  // parseChecksums
  // -------------------------------------------------------------------

  group('parseChecksums：索引里声明的校验和必须被真的读出来', () {
    test('解析单个 sha256', () {
      final result = ToolDownloader.parseChecksums(
        _completeBody('<checksum type="sha256">$_fixtureSha256</checksum>'),
      );
      expect(result, {'sha256': _fixtureSha256});
    });

    test('多种类型同时出现时全部取出（不是只取第一个）', () {
      final result = ToolDownloader.parseChecksums(
        _completeBody(
          '<checksum type="sha1">$_fixtureSha1</checksum>\n'
          '<checksum type="sha256">$_fixtureSha256</checksum>\n'
          '<checksum type="md5">$_fixtureMd5</checksum>',
        ),
      );
      expect(result.keys.toSet(), {'sha1', 'sha256', 'md5'});
      expect(result['sha256'], _fixtureSha256);
      expect(result['sha1'], _fixtureSha1);
      expect(result['md5'], _fixtureMd5);
    });

    test('算法名与十六进制值都归一化成小写', () {
      final result = ToolDownloader.parseChecksums(
        _completeBody(
          '<checksum type="SHA256">${_fixtureSha256.toUpperCase()}</checksum>',
        ),
      );
      expect(result, {'sha256': _fixtureSha256});
    });

    test('值为空的校验和条目被忽略（不能当成「校验通过」）', () {
      final result = ToolDownloader.parseChecksums(
        _completeBody('<checksum type="sha256"></checksum>'),
      );
      expect(result, isEmpty);
    });

    test('没有 type 属性的条目被忽略', () {
      final result = ToolDownloader.parseChecksums(
        _completeBody('<checksum>$_fixtureSha256</checksum>'),
      );
      expect(result, isEmpty);
    });

    test('片段里没有校验和时返回空表（而不是抛异常）', () {
      final result = ToolDownloader.parseChecksums(_completeBody(''));
      expect(result, isEmpty);
    });
  });

  // -------------------------------------------------------------------
  // ArchiveInfo.preferredAlgorithm / preferredDigest
  // -------------------------------------------------------------------

  group('算法优先级：SHA-256 优先、SHA-1 回退', () {
    test('三种都在时选 sha256', () {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {
          'sha256': _fixtureSha256,
          'sha1': _fixtureSha1,
          'md5': _fixtureMd5
        },
      );
      expect(info.preferredAlgorithm, 'sha256');
      expect(info.preferredDigest, _fixtureSha256);
    });

    test('没有 sha256 时回退 sha1（Google 官方索引只发 SHA-1 的情形）', () {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha1': _fixtureSha1, 'md5': _fixtureMd5},
      );
      expect(info.preferredAlgorithm, 'sha1');
      expect(info.preferredDigest, _fixtureSha1);
    });

    test('只有 md5 时才用 md5（最弱的一档）', () {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'md5': _fixtureMd5},
      );
      expect(info.preferredAlgorithm, 'md5');
      expect(info.preferredDigest, _fixtureMd5);
    });

    test('一个校验和都没有时返回 null —— 不能凭空选出一个算法', () {
      final info = ArchiveInfo(url: 'https://example.invalid/x.zip');
      expect(info.checksums, isEmpty);
      expect(info.preferredAlgorithm, isNull);
      expect(info.preferredDigest, isNull);
    });

    test('某个算法「存在但值为空」时不算数，继续往下选', () {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': '', 'sha1': _fixtureSha1},
      );
      expect(info.preferredAlgorithm, 'sha1');
      expect(info.preferredDigest, _fixtureSha1);
    });
  });

  // -------------------------------------------------------------------
  // digestFile
  // -------------------------------------------------------------------

  group('digestFile：摘要与外部工具一致', () {
    test('sha256', () async {
      expect(
          await ToolDownloader.digestFile(fixture, 'sha256'), _fixtureSha256);
    });

    test('sha1', () async {
      expect(await ToolDownloader.digestFile(fixture, 'sha1'), _fixtureSha1);
    });

    test('md5', () async {
      expect(await ToolDownloader.digestFile(fixture, 'md5'), _fixtureMd5);
    });

    test('不支持的算法抛 ArgumentError（而不是静默返回空串）', () async {
      await expectLater(
        ToolDownloader.digestFile(fixture, 'sha512'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // -------------------------------------------------------------------
  // verifyArchiveChecksum —— T0-2 的执行点
  // -------------------------------------------------------------------

  group('verifyArchiveChecksum：不匹配或未声明都必须拒绝', () {
    test('摘要一致时放行', () async {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': _fixtureSha256},
      );
      await expectLater(
        ToolDownloader.verifyArchiveChecksum(fixture, info),
        completes,
      );
    });

    test('摘要不匹配时抛 checksumMismatch', () async {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': _wrongSha256},
      );
      await expectLater(
        ToolDownloader.verifyArchiveChecksum(fixture, info),
        throwsA(
          isA<ToolDownloadException>().having(
              (e) => e.code, 'code', ToolDownloadError.checksumMismatch),
        ),
      );
    });

    test('索引**未声明**校验和时同样拒绝（「没声明」不等于「校验通过」）', () async {
      final info = ArchiveInfo(url: 'https://example.invalid/x.zip');
      await expectLater(
        ToolDownloader.verifyArchiveChecksum(fixture, info),
        throwsA(
          isA<ToolDownloadException>().having(
              (e) => e.code, 'code', ToolDownloadError.checksumMismatch),
        ),
      );
    });

    test('两种拒绝的理由可区分（调用方能分别给出提示）', () async {
      final missing = ArchiveInfo(url: 'https://example.invalid/x.zip');
      final wrong = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': _wrongSha256},
      );

      String detailOf(Object e) => (e as ToolDownloadException).detail ?? '';
      Object? caughtMissing;
      Object? caughtWrong;
      try {
        await ToolDownloader.verifyArchiveChecksum(fixture, missing);
      } catch (e) {
        caughtMissing = e;
      }
      try {
        await ToolDownloader.verifyArchiveChecksum(fixture, wrong);
      } catch (e) {
        caughtWrong = e;
      }

      expect(caughtMissing, isA<ToolDownloadException>());
      expect(caughtWrong, isA<ToolDownloadException>());
      expect(detailOf(caughtMissing!), isNotEmpty);
      expect(detailOf(caughtWrong!), isNotEmpty);
      expect(
        detailOf(caughtMissing),
        isNot(detailOf(caughtWrong)),
        reason: '「未声明」与「不匹配」必须是两句不同的说明',
      );
    });

    test('索引里声明的是大写摘要时也能通过（比较不区分大小写）', () async {
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': _fixtureSha256.toUpperCase()},
      );
      await expectLater(
        ToolDownloader.verifyArchiveChecksum(fixture, info),
        completes,
      );
    });

    test('同时声明 sha256 与 sha1 时，按 sha256 判定 —— 不能因为 sha1 对就放行', () async {
      // sha1 是对的、sha256 是错的：若实现「任意一个匹配即通过」就会漏掉篡改。
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': _wrongSha256, 'sha1': _fixtureSha1},
      );
      await expectLater(
        ToolDownloader.verifyArchiveChecksum(fixture, info),
        throwsA(
          isA<ToolDownloadException>().having(
              (e) => e.code, 'code', ToolDownloadError.checksumMismatch),
        ),
      );
    });
  });

  // -------------------------------------------------------------------
  // buildRepositoryIndexUrls —— T0-2 的另一半：源优先级
  // -------------------------------------------------------------------

  group('仓库索引源优先级：官方源必须在镜像之前', () {
    test('官方 Google 仓库排在第一', () {
      final urls = ToolDownloader.buildRepositoryIndexUrls();
      expect(urls, isNotEmpty);
      expect(urls.first, ToolDownloader.repositoryIndexUrl);
    });

    test('个人镜像只作兜底，排在官方源之后', () {
      final urls = ToolDownloader.buildRepositoryIndexUrls();
      final official = urls.indexOf(ToolDownloader.repositoryIndexUrl);
      final mirror = urls.indexOf(ToolDownloader.mirrorRepositoryIndexUrl);

      expect(official, isNonNegative);
      expect(
        mirror,
        isNonNegative,
        reason: '镜像仍应保留 —— 官方源不可达时需要降级选项',
      );
      expect(
        official,
        lessThan(mirror),
        reason: '镜像排在官方源之前时，该账号被接管即等于供应链投毒',
      );
    });
  });
}
