// 内容编码（`Content-Encoding: gzip`）下的下载 —— 真实网络暴露出来的缺陷。
//
// ## 这个文件为什么存在
//
// 2026-10-18 第一次**真的**联网跑 `downloadDependencies`，build-tools 下载
// 100% 失败：
//
// ```
// incomplete download: got 81933386 of 81667633 bytes
//   from https://dl.google.com/android/repository/build-tools_r37_macosx.zip
// ```
//
// 收到的比声明的**多** 265,753 字节。原因是 `HttpClient` 默认
// `autoUncompress: true`：`Content-Length` 是**编码后**的长度，而响应流给的
// 是**解码后**的字节。于是「收到的 != 声明的」这条完整性检查把每一次正常
// 下载都判成了传输中断。
//
// 同一件事还让索引下载的进度变成 **946%**（`repository2-3.xml`：
// 声明 44,547，实际 421,568）。
//
// 此前所有下载测试都用本地 `file://`，这条分支一次都没被走到 ——
// 这是「测试全绿但功能是坏的」的又一个实例。
//
// ## 期望值的来源
//
// 归档的 sha256 用**外部工具**（`shasum` / `openssl`）算，不用
// `package:crypto` —— 后者正是被测实现用的那个。
//
// 只监听 `127.0.0.1`，并注入 `HttpClient`（生产路径没有注入，明文 `http`
// 仍然一律拒绝，那条另有测试钉住）。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

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

/// 一个 platform-tools 风格的归档（`platform-tools/adb` + `source.properties`）。
Uint8List _platformToolsZip() {
  final adb = Uint8List(4096)..fillRange(0, 4096, 0x42);
  final archive = Archive()
    ..addFile(ArchiveFile('platform-tools/adb', 4096, adb))
    ..addFile(ArchiveFile.string(
        'platform-tools/source.properties', 'Pkg.Revision=35.0.0\n'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _repositoryXml({required String archiveUrl, required String sha256}) {
  final archiveBlock = '''
    <archive>
      <complete>
        <size>1</size>
        <checksum type="sha256">$sha256</checksum>
        <url>$archiveUrl</url>
      </complete>
      <host-os>windows</host-os>
    </archive>
    <archive>
      <complete>
        <size>1</size>
        <checksum type="sha256">$sha256</checksum>
        <url>$archiveUrl</url>
      </complete>
      <host-os>macosx</host-os>
    </archive>
    <archive>
      <complete>
        <size>1</size>
        <checksum type="sha256">$sha256</checksum>
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

void main() {
  late Directory work;
  late HttpServer server;
  late int port;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('tool_download_gzip_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    ToolDownloader.httpClientFactory = HttpClient.new;
  });

  tearDown(() async {
    ToolDownloader.httpClientFactory = null;
    await server.close(force: true);
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('归档走 gzip 编码时下载仍然成功（旧实现会判成「传输中断」）', () async {
    // 归档落盘后是**解码后**的 zip —— 校验和针对的也是它。
    final zipBytes = _platformToolsZip();
    final zipFile = File(path.join(work.path, 'platform-tools.zip'));
    await zipFile.writeAsBytes(zipBytes);
    final sha = await _externalSha256(zipFile);
    final gzipped = Uint8List.fromList(gzip.encode(zipBytes));

    server.listen((request) async {
      final p = request.uri.path;
      if (p == '/repository.xml') {
        request.response.headers.contentType =
            ContentType('text', 'xml', charset: 'utf-8');
        request.response.write(_repositoryXml(
          archiveUrl: 'http://127.0.0.1:$port/platform-tools.zip',
          sha256: sha,
        ));
        await request.response.close();
        return;
      }
      if (p == '/platform-tools.zip') {
        // **关键**：声明的是压缩后长度，发出去的也是压缩后的字节，
        // 但客户端会解码 —— 于是「收到的字节数」永远大于这个值。
        request.response.headers.set('content-encoding', 'gzip');
        request.response.headers.contentLength = gzipped.length;
        request.response.add(gzipped);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final installDir = path.join(work.path, 'installed');
    final result = await ToolDownloader.downloadDependencies(
      ToolDownloadOptions(
        sourceUrls: ['http://127.0.0.1:$port/repository.xml'],
        installDir: installDir,
        downloadPlatformTools: true,
        downloadBuildTools: false,
      ),
    );

    expect(result.platformToolsVersion, isNotEmpty,
        reason: '下载应当成功 —— 旧实现会在这里抛 archiveDownload');
    final adb = File(path.join(installDir, 'platform-tools', 'adb'));
    expect(adb.existsSync(), isTrue, reason: '解包后应当有 adb');
    // 解出来的是**解码后**的内容，与原始 zip 里的 adb 一致。
    expect(adb.lengthSync(), 4096);
  });

  test('编码过的索引不会报出 >100% 的进度', () async {
    final zipBytes = _platformToolsZip();
    final zipFile = File(path.join(work.path, 'platform-tools.zip'));
    await zipFile.writeAsBytes(zipBytes);
    final sha = await _externalSha256(zipFile);
    final xml = _repositoryXml(
      archiveUrl: 'http://127.0.0.1:$port/platform-tools.zip',
      sha256: sha,
    );
    final gzippedXml = Uint8List.fromList(gzip.encode(xml.codeUnits));

    server.listen((request) async {
      final p = request.uri.path;
      if (p == '/repository.xml') {
        request.response.headers.set('content-encoding', 'gzip');
        request.response.headers.contentLength = gzippedXml.length;
        request.response.add(gzippedXml);
        await request.response.close();
        return;
      }
      if (p == '/platform-tools.zip') {
        request.response.headers.contentLength = zipBytes.length;
        request.response.add(zipBytes);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final violations = <String>[];
    await ToolDownloader.downloadDependencies(
      ToolDownloadOptions(
        sourceUrls: ['http://127.0.0.1:$port/repository.xml'],
        installDir: path.join(work.path, 'installed2'),
        downloadPlatformTools: true,
        downloadBuildTools: false,
        onProgress: (p) {
          if (p.total > 0 && p.received > p.total) {
            violations.add('${p.task}: ${p.received}/${p.total}');
          }
        },
      ),
    );

    expect(violations, isEmpty,
        reason: '进度不能超过 100% —— 编码过的响应里 contentLength 是编码后'
            '长度，不能拿它当分母（实测真实索引会算出 946%）：$violations');
  });
}
