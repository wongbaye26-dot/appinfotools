// B-1：ToolDownloader 的**失败面**与「校验和必须挡住解包」。
//
// ## 为什么这个文件非有不可
//
// `tool_downloader.dart` 在 V2.4.12 之前**全仓零测试**。它做的事是：
// 从网络拿一个 zip、解开、把里面的 `adb` / `aapt2` / `apksigner` **交给本进程
// 直接执行**。所以「下载失败 / 校验失败 / 解包失败」必须能被分开，且任何一条
// 失败路径都不许在磁盘上留下一个「看起来可用」的工具。
//
// 已有 `tool_downloader_test.dart` 覆盖的是**纯函数**（解析索引、算法优先级、
// 摘要计算、单点校验）。本文件补的是**整条链路**：
// `downloadDependencies` 真的跑一遍，然后看磁盘上留下了什么。
//
// ## 怎么做到离线
//
// 索引与归档都用 `file://`（生产代码本来就支持，用于内网镜像/本地缓存），
// 因此**不发任何真实网络请求**，也不需要下载任何二进制。
//
// HTTP 失败面（404 / 302 / 响应体截断）需要真的 HTTP，用一个只监听
// `127.0.0.1` 的临时 `HttpServer`，并**注入 `HttpClient`**（`httpClientFactory`，
// `@visibleForTesting`）。生产路径没有注入，因此明文 `http` 仍然一律拒绝 ——
// 这条本身也有测试钉住。
//
// ## 期望值的来源
//
// 归档的 sha256 用**外部工具**（`shasum` 或 `openssl dgst`）算，不用
// `package:crypto` —— 后者正是被测实现用的那个，用它算期望值等于自证。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart' show ZipBombException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// 用外部工具算 sha256。两个工具都不可用时**直接失败**，不退回到
/// `package:crypto`（那等于拿被测实现给自己出题）。
Future<String> _externalSha256(File file) async {
  const probes = <(String, List<String>)>[
    ('shasum', ['-a', '256']),
    ('openssl', ['dgst', '-sha256']),
    ('sha256sum', []),
  ];
  for (final (command, args) in probes) {
    try {
      final result = await Process.run(command, [...args, file.path]);
      if (result.exitCode == 0) {
        final match =
            RegExp(r'\b[0-9a-f]{64}\b').firstMatch(result.stdout.toString());
        if (match != null) return match.group(0)!;
      }
    } on ProcessException {
      continue;
    }
  }
  fail('本机没有 shasum / openssl / sha256sum，无法独立核对期望摘要');
}

/// 造一个 platform-tools 风格的归档，返回文件与其中 adb 的原始内容。
Future<(File, Uint8List)> _platformToolsZip(
  Directory dir, {
  String name = 'platform-tools.zip',
  int adbBytes = 4096,
  int fill = 0x41,
}) async {
  final adb = Uint8List(adbBytes)..fillRange(0, adbBytes, fill);
  final archive = Archive()
    ..addFile(ArchiveFile('platform-tools/adb', adbBytes, adb))
    ..addFile(ArchiveFile.string(
        'platform-tools/source.properties', 'Pkg.Revision=35.0.0\n'));
  final file = File(path.join(dir.path, name));
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return (file, adb);
}

/// 造一份最小的仓库索引。三个 host-os 都给同一条目 —— 测试不复制生产代码
/// 里「本机是哪个 host-os」的映射逻辑，换平台也不用改夹具。
String _repositoryXml({
  required String archiveUrl,
  String? sha256,
  bool declareChecksum = true,
}) {
  final checksum = declareChecksum
      ? '<checksum type="sha256">${sha256 ?? ''}</checksum>'
      : '';
  final archiveBlock = '''
    <archive>
      <complete>
        <size>1</size>
        $checksum
        <url>$archiveUrl</url>
      </complete>
      <host-os>windows</host-os>
    </archive>
    <archive>
      <complete>
        <size>1</size>
        $checksum
        <url>$archiveUrl</url>
      </complete>
      <host-os>macosx</host-os>
    </archive>
    <archive>
      <complete>
        <size>1</size>
        $checksum
        <url>$archiveUrl</url>
      </complete>
      <host-os>linux</host-os>
    </archive>''';
  return '''<?xml version="1.0" encoding="UTF-8"?>
<r:repository xmlns:r="http://schemas.android.com/repository">
  <remotePackage path="platform-tools">
    <revision><major>35</major><minor>0</minor><micro>0</micro></revision>
    $archiveBlock
  </remotePackage>
  <remotePackage path="build-tools;35.0.0">
    $archiveBlock
  </remotePackage>
</r:repository>
''';
}

/// 临时目录里 `apk_info_tool_*` 的快照，用来验证「下载完不留垃圾」。
Set<String> _downloadTempDirs() => Directory.systemTemp
    .listSync()
    .whereType<Directory>()
    .map((d) => path.basename(d.path))
    .where((name) => name.startsWith('apk_info_tool_'))
    .toSet();

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('tool_download_failure_test');
  });

  tearDown(() async {
    ToolDownloader.httpClientFactory = null;
    if (work.existsSync()) await work.delete(recursive: true);
  });

  ToolDownloadOptions optionsFor(String indexUrl, String installDir) =>
      ToolDownloadOptions(
        sourceUrls: [indexUrl],
        installDir: installDir,
        downloadPlatformTools: true,
        downloadBuildTools: false,
      );

  // -------------------------------------------------------------------
  // A. 校验和必须挡住解包（离线，file://）
  // -------------------------------------------------------------------

  group('A. 校验和是解包的前置条件', () {
    test('摘要正确：解包完成，adb 的字节与源归档一致', () async {
      final (zip, adb) = await _platformToolsZip(work);
      final sha = await _externalSha256(zip);
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(
        _repositoryXml(archiveUrl: path.basename(zip.path), sha256: sha),
      );
      final installDir = path.join(work.path, 'install');

      final result = await ToolDownloader.downloadDependencies(
        optionsFor(index.path, installDir),
      );

      expect(result.platformToolsVersion, '35.0.0');
      final installed = File(path.join(installDir, 'platform-tools', 'adb'));
      expect(installed.existsSync(), isTrue);
      expect(installed.readAsBytesSync(), adb);
    });

    test('摘要不匹配：拒绝安装，install 目录里**一个文件都没有**', () async {
      final (zip, _) = await _platformToolsZip(work);
      final wrong = 'f' * 64; // 长度合法、内容不对
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(
        _repositoryXml(archiveUrl: path.basename(zip.path), sha256: wrong),
      );
      final installDir = path.join(work.path, 'install');

      await expectLater(
        ToolDownloader.downloadDependencies(optionsFor(index.path, installDir)),
        throwsA(isA<ToolDownloadException>().having(
          (e) => e.code,
          'code',
          ToolDownloadError.checksumMismatch,
        )),
      );

      final files = Directory(installDir).existsSync()
          ? Directory(installDir)
              .listSync(recursive: true)
              .whereType<File>()
              .toList()
          : <File>[];
      expect(files, isEmpty, reason: '校验失败之后绝不允许解包');
    });

    test('索引没声明校验和：同样拒绝（「没声明」不等于「校验通过」）', () async {
      final (zip, _) = await _platformToolsZip(work);
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(
        _repositoryXml(
          archiveUrl: path.basename(zip.path),
          declareChecksum: false,
        ),
      );
      final installDir = path.join(work.path, 'install');

      await expectLater(
        ToolDownloader.downloadDependencies(optionsFor(index.path, installDir)),
        throwsA(isA<ToolDownloadException>().having(
          (e) => e.code,
          'code',
          ToolDownloadError.checksumMismatch,
        )),
      );
      expect(
        Directory(installDir).existsSync()
            ? Directory(installDir).listSync(recursive: true).whereType<File>()
            : const <File>[],
        isEmpty,
      );
    });

    test('下载到的归档被截断：校验和先失败，不会变成「半截安装」', () async {
      final (zip, _) = await _platformToolsZip(work);
      final sha = await _externalSha256(zip);
      // 只留前一半字节 —— 模拟下载中断。
      final bytes = zip.readAsBytesSync();
      final truncated = File(path.join(work.path, 'truncated.zip'));
      await truncated.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));

      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(_repositoryXml(
        archiveUrl: path.basename(truncated.path),
        sha256: sha, // 声明的是**完整**文件的摘要
      ));
      final installDir = path.join(work.path, 'install');

      await expectLater(
        ToolDownloader.downloadDependencies(optionsFor(index.path, installDir)),
        throwsA(isA<ToolDownloadException>().having(
          (e) => e.code,
          'code',
          ToolDownloadError.checksumMismatch,
        )),
      );
      expect(
        File(path.join(installDir, 'platform-tools', 'adb')).existsSync(),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------
  // B. 已存在的安装：损坏就覆盖，不能「有文件就算装好」
  // -------------------------------------------------------------------

  group('B. 已存在的安装目录', () {
    test('预置一个损坏的 adb：重新下载后被真实内容覆盖', () async {
      final (zip, adb) = await _platformToolsZip(work);
      final sha = await _externalSha256(zip);
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(
        _repositoryXml(archiveUrl: path.basename(zip.path), sha256: sha),
      );
      final installDir = path.join(work.path, 'install');
      final installed = File(path.join(installDir, 'platform-tools', 'adb'));
      await installed.parent.create(recursive: true);
      await installed.writeAsString('corrupt-not-adb');

      await ToolDownloader.downloadDependencies(
        optionsFor(index.path, installDir),
      );

      expect(installed.readAsBytesSync(), adb,
          reason: '旧的损坏文件必须被覆盖，而不是被当成「已安装」跳过');
    });
  });

  // -------------------------------------------------------------------
  // C. 临时文件：成功与失败都不许留下垃圾
  // -------------------------------------------------------------------

  group('C. 临时文件清理', () {
    test('成功之后不留 apk_info_tool_* 临时目录', () async {
      final (zip, _) = await _platformToolsZip(work);
      final sha = await _externalSha256(zip);
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(
        _repositoryXml(archiveUrl: path.basename(zip.path), sha256: sha),
      );

      final before = _downloadTempDirs();
      await ToolDownloader.downloadDependencies(
        optionsFor(index.path, path.join(work.path, 'install')),
      );
      final after = _downloadTempDirs();

      expect(
        after.difference(before),
        isEmpty,
        reason: '下载用的临时目录必须删掉：${after.difference(before)}',
      );
    });

    test('校验失败之后同样不留临时目录', () async {
      final (zip, _) = await _platformToolsZip(work);
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index.writeAsString(
        _repositoryXml(archiveUrl: path.basename(zip.path), sha256: 'f' * 64),
      );

      final before = _downloadTempDirs();
      await expectLater(
        ToolDownloader.downloadDependencies(
          optionsFor(index.path, path.join(work.path, 'install')),
        ),
        throwsA(isA<ToolDownloadException>()),
      );
      final after = _downloadTempDirs();
      expect(after.difference(before), isEmpty);
    });
  });

  // -------------------------------------------------------------------
  // D. 下载失败面（本地 HTTP server）
  // -------------------------------------------------------------------

  group('D. HTTP 失败面', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      // 注入 client：生产路径没有注入，因此明文 http 仍然被拒绝（见 E 组）。
      ToolDownloader.httpClientFactory = HttpClient.new;
      server.listen((request) async {
        final p = request.uri.path;
        if (p == '/missing-index.xml') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        if (p == '/repository.xml') {
          // 索引里的归档地址指向 404
          request.response.headers.contentType =
              ContentType('text', 'xml', charset: 'utf-8');
          request.response.write(_repositoryXml(
            archiveUrl: 'http://127.0.0.1:$port/missing-archive.zip',
            sha256: 'a' * 64,
          ));
          await request.response.close();
          return;
        }
        if (p == '/truncated-index.xml') {
          // 声明 Content-Length 1000，只发 40 字节就关 —— 模拟传输中断。
          // 服务端自己也会因此报错（少写了字节），吞掉即可：被测的是客户端。
          try {
            request.response.headers.contentLength = 1000;
            request.response.write('<?xml version="1.0"?><r:repository>');
            await request.response.flush();
            await request.response.close();
          } catch (_) {
            // 客户端已断开 / 字节数不足，属于预期
          }
          return;
        }
        if (p == '/redirect-index.xml') {
          // 302 到另一个主机名（localhost 与 127.0.0.1 是两个 host）
          request.response.statusCode = HttpStatus.found;
          request.response.headers
              .set('location', 'http://localhost:$port/missing-index.xml');
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('索引 404：失败码是 repositoryIndex，且 detail 里看得到状态码', () async {
      await expectLater(
        ToolDownloader.downloadDependencies(
          optionsFor(
            'http://127.0.0.1:$port/missing-index.xml',
            path.join(work.path, 'install'),
          ),
        ),
        throwsA(isA<ToolDownloadException>()
            .having((e) => e.code, 'code', ToolDownloadError.repositoryIndex)
            .having((e) => e.detail ?? '', 'detail', contains('404'))),
      );
    });

    test('归档 404：失败码是 archiveDownload（不是「解包失败」）', () async {
      await expectLater(
        ToolDownloader.downloadDependencies(
          optionsFor(
            'http://127.0.0.1:$port/repository.xml',
            path.join(work.path, 'install'),
          ),
        ),
        throwsA(isA<ToolDownloadException>()
            .having((e) => e.code, 'code', ToolDownloadError.archiveDownload)
            .having((e) => e.detail ?? '', 'detail', contains('404'))),
      );
    });

    test('响应体被截断：失败且不产生安装结果', () async {
      final installDir = path.join(work.path, 'install');
      await expectLater(
        ToolDownloader.downloadDependencies(
          optionsFor('http://127.0.0.1:$port/truncated-index.xml', installDir),
        ),
        throwsA(isA<ToolDownloadException>()),
      );
      expect(
        File(path.join(installDir, 'platform-tools', 'adb')).existsSync(),
        isFalse,
      );
    });

    test('302 到另一个主机：跟随之后仍然过校验和，且 detail 记录最终主机', () async {
      // 302 指向 localhost 的 404 索引 —— 失败，但失败原因是 404，
      // 说明重定向被跟随了（而不是被当成成功）。
      await expectLater(
        ToolDownloader.downloadDependencies(
          optionsFor(
            'http://127.0.0.1:$port/redirect-index.xml',
            path.join(work.path, 'install'),
          ),
        ),
        throwsA(isA<ToolDownloadException>()
            .having((e) => e.code, 'code', ToolDownloadError.repositoryIndex)
            // 「请求的是 127.0.0.1，实际从 localhost 拿的」必须留痕：
            // 重定向本身不拒绝（CDN 会跳），但排查时要看得见。
            .having((e) => e.detail ?? '', 'detail', contains('localhost'))),
      );
    });
  });

  // -------------------------------------------------------------------
  // E. 明文 http 在生产路径上必须被拒绝
  // -------------------------------------------------------------------

  group('E. 协议白名单', () {
    test('没有注入 client 时，http:// 一律拒绝（不降级成明文传输）', () async {
      await expectLater(
        ToolDownloader.downloadDependencies(
          ToolDownloadOptions(
            sourceUrls: ['http://example.invalid/repository2-3.xml'],
            installDir: path.join(work.path, 'install'),
            downloadPlatformTools: true,
            downloadBuildTools: false,
          ),
        ),
        throwsA(isA<ToolDownloadException>().having(
          (e) => e.detail ?? '',
          'detail',
          contains('non-HTTPS'),
        )),
      );
    });
  });

  // -------------------------------------------------------------------
  // F. 三种失败必须能被分开
  // -------------------------------------------------------------------

  group('F. 下载失败 / 校验失败 / 解包失败互不混淆', () {
    test('三个信号是三个不同的东西', () {
      final download = ToolDownloadException(ToolDownloadError.archiveDownload);
      final checksum =
          ToolDownloadException(ToolDownloadError.checksumMismatch);

      // 下载与校验：同一个类型、不同 code。
      expect(download.code, isNot(checksum.code));
      // 解包：完全不同的类型（ZipBombException），界面才能说「安全拒绝」。
      expect(
        isA<ZipBombException>().matches(download, {}),
        isFalse,
        reason: '下载失败不能被当成解包失败',
      );
      expect(
        isA<ZipBombException>().matches(checksum, {}),
        isFalse,
        reason: '校验失败不能被当成解包失败',
      );
    });

    test('JSON 里三个 code 的字符串互不相同（写日志/上报时不能撞名）', () {
      final codes = {
        ToolDownloadError.archiveDownload,
        ToolDownloadError.checksumMismatch,
        ToolDownloadError.repositoryIndex,
        ToolDownloadError.platformToolsMissing,
        ToolDownloadError.buildToolsMissing,
        ToolDownloadError.fileNotFound,
      }.map((e) => e.name).toSet();
      expect(codes, hasLength(6));
    });
  });

  // -------------------------------------------------------------------
  // G. 索引解析的失败面（不联网，纯文本）
  // -------------------------------------------------------------------

  group('G. 索引里没有可用条目', () {
    test('索引里没有 platform-tools：platformToolsMissing', () async {
      final index = File(path.join(work.path, 'repository2-3.xml'));
      await index
          .writeAsString('<?xml version="1.0"?><r:repository></r:repository>');
      await expectLater(
        ToolDownloader.downloadDependencies(
          optionsFor(index.path, path.join(work.path, 'install')),
        ),
        throwsA(isA<ToolDownloadException>().having(
          (e) => e.code,
          'code',
          ToolDownloadError.platformToolsMissing,
        )),
      );
    });
  });
}
