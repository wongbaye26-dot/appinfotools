import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/java_runtime.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:archive_safety/archive_safety.dart' show ZipBudget;
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
// 只为 `visibleForTesting`：校验和这条链是安全控制，必须有回归测试，
// 但它不该成为对外的公共 API。`@visibleForTesting` 由分析器强制 ——
// 非测试代码调用它会报 `invalid_use_of_visible_for_testing_member`，
// 而本项目的门禁带 `--fatal-warnings`，所以它**不会**被生产代码用上。
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as path;

class ToolDownloadResult {
  final String installDir;
  final String platformToolsVersion;
  final String buildToolsVersion;

  /// 下载的 JRE 版本（如 `17.0.20+101`）；没下载时为 `null`。
  final String? jreVersion;

  ToolDownloadResult({
    required this.installDir,
    required this.platformToolsVersion,
    required this.buildToolsVersion,
    this.jreVersion,
  });
}

/// 下载并安装 Android 平台工具（platform-tools / build-tools）。
///
/// ## 为什么有几个成员是 `@visibleForTesting` 的公开名
///
/// 校验和这条链是**安全控制**（下载的 adb/aapt2 会被本进程直接执行），
/// 必须有回归测试；但 `@visibleForTesting` **只放宽 lint，不改变 Dart 的
/// 库级私有性** —— 测试在另一个库里，`_foo` 这种名字它根本看不到。
/// 因此这几个成员改成公开名 + `@visibleForTesting`：
/// 分析器会对**非测试代码**报 `invalid_use_of_visible_for_testing_member`，
/// 而门禁带 `--fatal-warnings`，所以它们实际上只对 `test/` 可见。
class ToolDownloader {
  static const String repositoryIndexUrl =
      'https://dl.google.com/android/repository/repository2-3.xml';
  static const String mirrorRepositoryIndexUrl =
      'https://github.com/huanfeng/apk_info_tool_binary/releases/download/latest/repository2-3.xml';

  /// Eclipse Temurin（Adoptium）的资产 API。
  ///
  /// **为什么不用 Google 那套仓库索引**：Android SDK 仓库里没有 JRE。
  /// `apksigner` 是 java 的壳，没有 java 它起不来，而 Windows 的安装器默认
  /// 不把 `bin` 写进 PATH —— 所以这里必须自己提供一个「装了就能用」的选项。
  ///
  /// 选 Adoptium 是因为它给出**稳定的 API + SHA-256**：一次请求就拿到下载
  /// 直链与校验和，不用自己维护版本号与镜像。这与 `repository2-3.xml` 是
  /// 同一套思路（先拿清单、再下包、下完校验）。
  static const String adoptiumAssetsUrl =
      'https://api.adoptium.net/v3/assets/latest/17/hotspot';

  /// 测试注入用的 `HttpClient` 工厂。
  ///
  /// **生产代码从不设置它。** 它的存在是为了让「404 / 302 / 响应体截断」这些
  /// HTTP 失败面能被真的测到 —— 那些行为只发生在真实 `HttpClient` 上，
  /// 用 mock 替身测等于测替身。它同时是 [isAllowedScheme] 里唯一放开明文
  /// `http` 的条件（且只对回环地址），所以生产路径的「不许明文传输」不受影响。
  @visibleForTesting
  static HttpClient Function()? httpClientFactory;

  /// 下载地址的协议白名单。
  ///
  /// 生产路径只有 `https` 与 `file`（后者用于内网镜像/本地缓存）。
  /// 明文 `http` **只在测试注入 client 且目标是回环地址**时放行 ——
  /// 否则下载来的 adb/aapt2 在传输途中就能被替换，而它们会被直接执行。
  static bool isAllowedScheme(Uri uri) {
    if (uri.scheme == 'https' || uri.scheme == 'file') return true;
    if (uri.scheme != 'http') return false;
    if (httpClientFactory == null) return false;
    return uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        uri.host == '::1' ||
        uri.host == '0:0:0:0:0:0:0:1';
  }

  static HttpClient _newClient() => (httpClientFactory ?? HttpClient.new)();

  static Future<ToolDownloadResult> downloadDependencies(
      ToolDownloadOptions options) async {
    final installDir = options.installDir;
    await Directory(installDir).create(recursive: true);

    // 下载产物落在系统临时目录里，**用完必须删**。
    // 以前是「建了就不管」—— 每成功下载一次就留一份几十 MB 的 platform-tools
    // 压缩包在 /var/folders 里，谁也不清。
    final tempDirs = <Directory>[];

    try {
      final indexUrls = options.sourceUrls.isEmpty
          ? buildRepositoryIndexUrls()
          : options.sourceUrls;

      // **只在真的要 Android 工具时才去拉仓库索引。**
      // 索引来自 dl.google.com，和 JRE 的来源（Adoptium）毫无关系；
      // 用户如果只勾了「Java 运行时」，却因为连不上 Google 而整条下载失败，
      // 那是把两件独立的事绑死了。
      final needsAndroidTools =
          options.downloadPlatformTools || options.downloadBuildTools;
      final xmlContent = needsAndroidTools
          ? await _downloadTextWithFallback(indexUrls, options.onProgress)
          : null;
      final platformArchive = options.downloadPlatformTools
          ? _selectPlatformTools(xmlContent!)
          : null;
      final buildTools =
          options.downloadBuildTools ? _selectBuildTools(xmlContent!) : null;

      final baseUris = indexUrls.map((url) {
        final uri = _toUri(url);
        return uri.resolve('.');
      }).toList();

      if (platformArchive != null) {
        final platformTemp = await _downloadArchiveToTemp(
          baseUris,
          platformArchive.url,
          'platform-tools',
          options.onProgress,
        );
        tempDirs.add(platformTemp.parent);
        // 解包前必须校验：这些二进制随后会被本进程直接执行。
        await verifyArchiveChecksum(
          platformTemp,
          ArchiveInfo(
            url: platformArchive.url,
            checksums: platformArchive.checksums,
          ),
        );
        await extractPlatformTools(platformTemp, installDir);
      }

      if (buildTools != null) {
        final buildToolsTemp = await _downloadArchiveToTemp(
          baseUris,
          buildTools.archive.url,
          'build-tools',
          options.onProgress,
        );
        tempDirs.add(buildToolsTemp.parent);
        await verifyArchiveChecksum(buildToolsTemp, buildTools.archive);
        await extractBuildTools(
          buildToolsTemp,
          installDir,
          buildTools.version,
        );
      }

      String? jreVersion;
      if (options.downloadJre) {
        // 与上面两项不同：JRE 不在 Google 的仓库索引里，先向 Adoptium 要
        // 「直链 + SHA-256」，再下包。校验和是硬要求 —— 这个 java 会被本进程
        // 直接执行，和 adb/aapt2 同一个信任级别。
        final jre = await _resolveJre();
        final jreTemp = await _downloadToTemp(
          _toUri(jre.url),
          'jre',
          options.onProgress == null
              ? null
              : (received, total) => options.onProgress!(
                    ToolDownloadProgress(
                      task: 'jre',
                      received: received,
                      total: total,
                    ),
                  ),
        );
        tempDirs.add(jreTemp.parent);
        await verifyArchiveChecksum(
          jreTemp,
          ArchiveInfo(url: jre.url, checksums: {'sha256': jre.checksum}),
        );
        await extractJre(jreTemp, installDir);
        await _ensureExecutable(
            ToolPaths.getDownloadedJavaPath(baseDir: installDir) ?? '');
        jreVersion = jre.version;
      }

      await _ensureExecutable(
          ToolPaths.getDownloadedAdbPath(baseDir: installDir) ?? '');
      await _ensureExecutable(
          ToolPaths.getDownloadedAapt2Path(baseDir: installDir) ?? '');
      await _ensureExecutable(
          ToolPaths.getDownloadedApksignerPath(baseDir: installDir) ?? '');

      return ToolDownloadResult(
        installDir: installDir,
        platformToolsVersion: platformArchive?.version ?? '',
        buildToolsVersion: buildTools?.version ?? '',
        jreVersion: jreVersion,
      );
    } finally {
      // 成功与失败都要清 —— 校验失败时那个压缩包同样不该留在磁盘上。
      for (final dir in tempDirs) {
        await _deleteQuietly(dir);
      }
    }
  }

  /// 删目录，失败只记日志（清理不该盖住真正的错误）。
  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      log.warning('failed to clean temp dir ${dir.path}: $e');
    }
  }

  /// 构建仓库索引候选地址。
  ///
  /// 顺序很重要：**官方 Google 仓库排在最前**。历史实现把个人 GitHub 镜像
  /// 放在首位，一旦该账号被接管，所有用户拿到的都是攻击者投放的 adb/aapt2，
  /// 且这些二进制会被直接执行。镜像只能作为官方源不可达时的降级选项。
  ///
  /// `@visibleForTesting`：「官方源必须排在镜像之前」这条顺序是安全约束，
  /// 有回归测试逐位钉住，但它不该对外暴露。
  @visibleForTesting
  static List<String> buildRepositoryIndexUrls() {
    final extraUrls = ToolPaths.loadExtraRepositoryUrls();
    return <String>[
      // 官方源优先。
      repositoryIndexUrl,
      // 用户显式配置的源（通常是有鉴权的内网镜像）。
      ...extraUrls,
      // 公共镜像仅作为兜底。
      mirrorRepositoryIndexUrl,
    ];
  }

  static Future<String> _downloadTextWithFallback(
    List<String> urls,
    ToolDownloadProgressCallback? onProgress,
  ) async {
    Object? lastError;
    for (final url in urls) {
      try {
        final content = await _downloadText(
          _toUri(url),
          onProgress == null
              ? null
              : (received, total) => onProgress(
                    ToolDownloadProgress(
                      task: 'repository',
                      received: received,
                      total: total,
                    ),
                  ),
        );
        log.info('download repository index ok: $url');
        return content;
      } catch (e) {
        lastError = e;
        log.warning('download repository index failed: $url, error=$e');
      }
    }
    throw ToolDownloadException(
      ToolDownloadError.repositoryIndex,
      detail: lastError?.toString(),
    );
  }

  static Future<String> _downloadText(
    Uri uri,
    void Function(int received, int total)? onProgress,
  ) async {
    if (uri.scheme == 'file') {
      final file = File(uri.toFilePath());
      if (!file.existsSync()) {
        throw ToolDownloadException(
          ToolDownloadError.fileNotFound,
          detail: uri.toFilePath(),
        );
      }
      return file.readAsString();
    }
    if (!isAllowedScheme(uri)) {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'non-HTTPS scheme: $uri',
      );
    }
    final client = _newClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception(_describeHttpFailure(uri, response));
      }
      final bytes = await _readResponseBytes(response, onProgress);
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }

  /// 把 HTTP 失败写清楚：状态码、最终地址、以及**重定向跳到了哪个主机**。
  ///
  /// 重定向本身不拒绝（Google 的下载域名会跳到 CDN），但必须留痕 ——
  /// 「请求的是 dl.google.com，实际从别处拿的」这件事在排查时是关键信息。
  /// 真正的防线仍然是校验和，不是主机名。
  static String _describeHttpFailure(
      Uri requested, HttpClientResponse response) {
    final hops = response.redirects;
    final finalUri = hops.isEmpty ? requested : hops.last.location;
    final redirectNote = finalUri.host == requested.host
        ? ''
        : ' (redirected to ${finalUri.host})';
    return 'HTTP ${response.statusCode}$redirectNote for $requested';
  }

  static Future<File> _downloadArchiveToTemp(
    List<Uri> baseUris,
    String url,
    String prefix,
    ToolDownloadProgressCallback? onProgress,
  ) async {
    final uri = Uri.parse(url);
    final candidates = uri.hasScheme
        ? [uri]
        : baseUris.map((base) => base.resolve(url)).toList();
    Object? lastError;
    for (final candidate in candidates) {
      try {
        final file = await _downloadToTemp(
          candidate,
          prefix,
          onProgress == null
              ? null
              : (received, total) => onProgress(
                    ToolDownloadProgress(
                      task: prefix,
                      received: received,
                      total: total,
                    ),
                  ),
        );
        log.info('download archive ok: $candidate');
        return file;
      } catch (e) {
        lastError = e;
        log.warning('download archive failed: $candidate, error=$e');
      }
    }
    throw ToolDownloadException(
      ToolDownloadError.archiveDownload,
      detail: lastError?.toString(),
    );
  }

  static Future<File> _downloadToTemp(
    Uri uri,
    String prefix,
    void Function(int received, int total)? onProgress,
  ) async {
    if (uri.scheme == 'file') {
      final source = File(uri.toFilePath());
      if (!source.existsSync()) {
        throw ToolDownloadException(
          ToolDownloadError.fileNotFound,
          detail: uri.toFilePath(),
        );
      }
      final dir =
          await Directory.systemTemp.createTemp('apk_info_tool_$prefix');
      final target = File(path.join(dir.path, path.basename(uri.path)));
      try {
        await source.copy(target.path);
        return target;
      } catch (e) {
        await _deleteQuietly(dir);
        rethrow;
      }
    }
    if (!isAllowedScheme(uri)) {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'non-HTTPS scheme: $uri',
      );
    }
    final client = _newClient();
    Directory? dir;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception(_describeHttpFailure(uri, response));
      }
      dir = await Directory.systemTemp.createTemp('apk_info_tool_$prefix');
      final file = File(path.join(dir.path, path.basename(uri.path)));

      // **边收边写**，不先把整个归档攒进内存：platform-tools 有几十 MB，
      // build-tools 上百 MB，先 `BytesBuilder` 再落盘等于把峰值内存翻倍。
      //
      // 进度分母只在**未编码**时可信（见下面完整性检查的注释）：内容编码过
      // 时 `contentLength` 是编码后长度，拿它当分母会算出 >100% 的进度。
      final declared = response.contentLength;
      final decoded = response.compressionState !=
          HttpClientResponseCompressionState.notCompressed;
      final total = (!decoded && declared > 0) ? declared : 0;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (onProgress != null && total > 0) {
            onProgress(received, total);
          }
        }
      } finally {
        await sink.close();
      }

      // `Content-Length` 声明了却没收到那么多 = 传输中断。此时磁盘上是一个
      // **半截归档**：不删掉的话，后面的解包会读到它，或者被误当成缓存复用。
      //
      // **但只在响应没有被内容编码时才能这么比。** `HttpClient` 默认
      // `autoUncompress: true`，此时 `contentLength` 是**编码后**的字节数，
      // 而流里给的是解码后的 —— 两者本来就不相等。实测（2026-10-18）：
      // dl.google.com 的 build-tools 归档走 gzip，解码后比声明值多 265,753
      // 字节，于是每一次真实下载都被判成「传输中断」，整条下载链 100% 失败，
      // 而单元测试因为用本地 `file://` 从不触发这条分支，一直是绿的。
      //
      // 字节数相等只是个**廉价的**一致性检查；真正的完整性由
      // `verifyArchiveChecksum`（sha1）保证，那才是不可绕过的。
      if (!decoded && declared > 0 && received != declared) {
        throw ToolDownloadException(
          ToolDownloadError.archiveDownload,
          detail: 'incomplete download: got $received of $declared bytes '
              'from $uri',
        );
      }
      return file;
    } catch (e) {
      if (dir != null) await _deleteQuietly(dir);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>> _readResponseBytes(
    HttpClientResponse response,
    void Function(int received, int total)? onProgress,
  ) async {
    final builder = BytesBuilder(copy: false);
    // 同 `_downloadToTemp`：内容编码过的响应里 `contentLength` 是编码后长度，
    // 拿它当分母会算出 946% 这种数字（实测 repository2-3.xml：44,547 vs
    // 421,568）。编码过就报「总量未知」（0），界面按不定长进度显示。
    final decoded = response.compressionState !=
        HttpClientResponseCompressionState.notCompressed;
    final total =
        (!decoded && response.contentLength > 0) ? response.contentLength : 0;
    var received = 0;
    await for (final chunk in response) {
      builder.add(chunk);
      received += chunk.length;
      if (onProgress != null && total > 0) {
        onProgress(received, total);
      }
    }
    return builder.takeBytes();
  }

  static PlatformArchive _selectPlatformTools(String xmlContent) {
    final package = _findPackage(xmlContent, 'platform-tools');
    if (package == null) {
      throw ToolDownloadException(ToolDownloadError.platformToolsMissing);
    }
    final hostOs = _currentHostOs();
    final archive = _findArchive(package, hostOs) ??
        _findArchiveByUrlHint(package, _platformToolsUrlHints());
    if (archive == null) {
      throw ToolDownloadException(
        ToolDownloadError.platformToolsMissing,
        detail: hostOs,
      );
    }
    return PlatformArchive(
      url: archive.url,
      version: package.version ?? 'unknown',
      checksums: archive.checksums,
    );
  }

  static BuildToolsArchive _selectBuildTools(String xmlContent) {
    final packages = _findPackages(xmlContent, 'build-tools;');
    if (packages.isEmpty) {
      throw ToolDownloadException(ToolDownloadError.buildToolsMissing);
    }
    packages.sort((a, b) =>
        ToolPaths.compareVersionDescending(a.version ?? '', b.version ?? ''));
    final selected = packages.first;
    final hostOs = _currentHostOs();
    final archive = _findArchive(selected, hostOs) ??
        _findArchiveByUrlHint(selected, _buildToolsUrlHints());
    if (archive == null) {
      throw ToolDownloadException(
        ToolDownloadError.buildToolsMissing,
        detail: hostOs,
      );
    }
    return BuildToolsArchive(
      version: selected.version ?? '',
      archive: archive,
    );
  }

  /// 解包 platform-tools。
  ///
  /// `@visibleForTesting`：测试要能在**不联网**的前提下验证「声明级预算 +
  /// 逐条目有界解包」这两道闸真的串在这条链上（`_downloadPlatformTools` 会先
  /// 联网下载，测试无法走完）。
  ///
  /// [maxSessionBytes] 供测试注入小预算；生产调用不传。
  @visibleForTesting
  static Future<void> extractPlatformTools(
    File zipFile,
    String installDir, {
    int? maxSessionBytes,
  }) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    ZipBudget.ensureWithin(archive, source: 'platform-tools');
    await ZipGuard.extractToDirectory(
      archive,
      path.join(installDir, 'platform-tools'),
      stripPrefix: 'platform-tools/',
      maxSessionBytes: maxSessionBytes,
    );
  }

  /// 解包 build-tools。`@visibleForTesting` 的理由同 [extractPlatformTools]。
  @visibleForTesting
  static Future<void> extractBuildTools(
    File zipFile,
    String installDir,
    String version, {
    int? maxSessionBytes,
  }) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    ZipBudget.ensureWithin(archive, source: 'build-tools $version');
    final outputRoot = path.join(installDir, 'build-tools', version);
    final prefix = 'build-tools/$version/';
    var rootPrefix = '';
    final hasPrefix = archive.files.any((file) => file.name.startsWith(prefix));
    if (hasPrefix) {
      rootPrefix = prefix;
    } else {
      rootPrefix = _findBuildToolsRootPrefix(archive) ?? '';
    }

    await ZipGuard.extractToDirectory(
      archive,
      outputRoot,
      stripPrefix: rootPrefix,
      maxSessionBytes: maxSessionBytes,
    );
  }

  /// 解包 JRE。`@visibleForTesting` 的理由同 [extractPlatformTools]。
  ///
  /// Adoptium 的 zip 只有一个顶层目录（`jdk-17.0.20.1+1-jre/`），剥掉它，
  /// 让 `java` 正好落在 `<installDir>/jre/bin/java` —— 与
  /// [ToolPaths.getDownloadedJavaPath] 的约定一致。
  @visibleForTesting
  static Future<void> extractJre(
    File zipFile,
    String installDir, {
    int? maxSessionBytes,
  }) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    ZipBudget.ensureWithin(archive, source: 'jre');
    await ZipGuard.extractToDirectory(
      archive,
      path.join(installDir, 'jre'),
      stripPrefix: _singleTopLevelPrefix(archive),
      maxSessionBytes: maxSessionBytes,
    );
  }

  /// 归档里唯一的顶层目录（带尾斜杠）；没有或不止一个时返回空串。
  static String _singleTopLevelPrefix(Archive archive) {
    final tops = <String>{};
    for (final file in archive.files) {
      final name = file.name.replaceAll('\\', '/');
      final slash = name.indexOf('/');
      if (slash <= 0) return '';
      tops.add(name.substring(0, slash));
      if (tops.length > 1) return '';
    }
    return tops.isEmpty ? '' : '${tops.first}/';
  }

  /// 向 Adoptium 要一份 JRE 的下载直链与 SHA-256。
  ///
  /// 用 `assets/latest` 而不是拼一个「猜出来的」GitHub Release 地址：版本号
  /// 变了链接就失效，而**校验和是安全控制**，不能靠猜。
  static Future<AdoptiumJre> _resolveJre() async {
    if (!JavaRuntime.supportsDownload) {
      // 只有 Windows 支持：macOS / Linux 的 JRE 只有 `.tar.gz`，而
      // `ZipGuard` 是 zip 专用的。**宁可直接报错，也不要给用户下错平台
      // 的包** —— 解出来是一堆用不了的 `.exe`。
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'JRE 下载仅支持 Windows',
      );
    }
    final uri = Uri.parse(adoptiumAssetsUrl).replace(queryParameters: {
      'os': 'windows',
      'architecture': JavaRuntime.adoptiumArchitecture,
      'image_type': 'jre',
      'vendor': 'eclipse',
    });

    final text = await _downloadText(uri, null);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'Adoptium 返回的不是 JSON: $e',
      );
    }
    if (decoded is! List || decoded.isEmpty) {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'Adoptium 没有返回可用的 JRE',
      );
    }

    final first = decoded.first;
    final binary = first is Map ? first['binary'] : null;
    final package = binary is Map ? binary['package'] : null;
    if (package is! Map) {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'Adoptium 响应里缺少 binary.package',
      );
    }
    final link = package['link'];
    final checksum = package['checksum'];
    if (link is! String || link.isEmpty) {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'Adoptium 响应里缺少下载地址',
      );
    }
    if (checksum is! String || checksum.isEmpty) {
      // 与 `verifyArchiveChecksum` 同一个立场：没有校验和就不装。
      throw ToolDownloadException(
        ToolDownloadError.checksumMismatch,
        detail: 'Adoptium 未提供 SHA-256，拒绝安装未经验证的 JRE: $link',
      );
    }

    final version = first is Map
        ? (first['version'] is Map
            ? '${(first['version'] as Map)['semver']}'
            : '')
        : '';
    return AdoptiumJre(url: link, checksum: checksum, version: version);
  }

  static Future<void> _ensureExecutable(String filePath) async {
    if (filePath.isEmpty || Platform.isWindows) {
      return;
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      return;
    }
    await Process.run('chmod', ['+x', filePath]);
  }

  static String _currentHostOs() {
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'macosx';
    }
    return 'linux';
  }

  static List<String> _platformToolsUrlHints() {
    if (Platform.isWindows) {
      return ['-win'];
    }
    if (Platform.isMacOS) {
      return ['-darwin', '-macosx'];
    }
    return ['-linux'];
  }

  static List<String> _buildToolsUrlHints() {
    if (Platform.isWindows) {
      return ['_windows'];
    }
    if (Platform.isMacOS) {
      return ['_macosx'];
    }
    return ['_linux'];
  }

  static String? _findBuildToolsRootPrefix(Archive archive) {
    for (final file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      final name = path.basename(file.name).toLowerCase();
      if (name == 'aapt2' ||
          name == 'aapt2.exe' ||
          name == 'apksigner' ||
          name == 'apksigner.bat') {
        final dir = path.dirname(file.name);
        if (dir == '.' || dir.isEmpty) {
          return '';
        }
        return '$dir/';
      }
    }
    return null;
  }

  static Uri _toUri(String value) {
    final file = File(value);
    if (file.existsSync()) {
      return file.absolute.uri;
    }
    return Uri.parse(value);
  }

  static RemotePackage? _findPackage(String xmlContent, String pathValue) {
    final matches = _findPackages(xmlContent, pathValue);
    return matches.isEmpty ? null : matches.first;
  }

  static List<RemotePackage> _findPackages(
    String xmlContent,
    String pathPrefix,
  ) {
    final results = <RemotePackage>[];
    final packageRegex = RegExp(
        r'<remotePackage[^>]*path="([^"]+)"[^>]*>([\s\S]*?)</remotePackage>');
    for (final match in packageRegex.allMatches(xmlContent)) {
      final pathValue = match.group(1) ?? '';
      if (!pathValue.startsWith(pathPrefix)) {
        continue;
      }
      final body = match.group(2) ?? '';
      results.add(RemotePackage(
        path: pathValue,
        body: body,
        version: _extractVersion(pathValue, body),
      ));
    }
    return results;
  }

  static String? _extractVersion(String pathValue, String body) {
    if (pathValue.contains(';')) {
      return pathValue.split(';').last;
    }
    final versionMatch = RegExp(
            r'<revision>\s*<major>(\d+)</major>\s*<minor>(\d+)</minor>\s*<micro>(\d+)</micro>')
        .firstMatch(body);
    if (versionMatch == null) {
      return null;
    }
    return [versionMatch.group(1), versionMatch.group(2), versionMatch.group(3)]
        .join('.');
  }

  /// 从 `<complete>` 片段中解析出全部 `<checksum type="...">value</checksum>`。
  ///
  /// `@visibleForTesting`：这是 T0-2 安全修复的一半（索引声明的校验和必须被
  /// 真的读出来，否则后面那道比对形同虚设），但不需要对外暴露。
  @visibleForTesting
  static Map<String, String> parseChecksums(String completeBody) {
    final result = <String, String>{};
    final regex = RegExp(
        r'<checksum[^>]*type="([^"]+)"[^>]*>\s*([0-9a-fA-F]+)\s*</checksum>');
    for (final match in regex.allMatches(completeBody)) {
      final algo = (match.group(1) ?? '').toLowerCase().trim();
      final value = (match.group(2) ?? '').toLowerCase().trim();
      if (algo.isNotEmpty && value.isNotEmpty) {
        result[algo] = value;
      }
    }
    return result;
  }

  static ArchiveInfo? _findArchive(RemotePackage package, String hostOs) {
    final archiveRegex = RegExp(r'<archive>([\s\S]*?)</archive>');
    for (final match in archiveRegex.allMatches(package.body)) {
      final archiveBody = match.group(1) ?? '';
      final hostMatch =
          RegExp(r'<host-os>([^<]+)</host-os>').firstMatch(archiveBody);
      if (hostMatch == null || hostMatch.group(1) != hostOs) {
        continue;
      }
      final completeMatch =
          RegExp(r'<complete>([\s\S]*?)</complete>').firstMatch(archiveBody);
      if (completeMatch == null) {
        continue;
      }
      final completeBody = completeMatch.group(1) ?? '';
      final urlMatch = RegExp(r'<url>([^<]+)</url>').firstMatch(completeBody);
      if (urlMatch == null) {
        continue;
      }
      return ArchiveInfo(
        url: urlMatch.group(1) ?? '',
        checksums: parseChecksums(completeBody),
      );
    }
    return null;
  }

  static ArchiveInfo? _findArchiveByUrlHint(
    RemotePackage package,
    List<String> hints,
  ) {
    final archiveRegex = RegExp(r'<archive>([\s\S]*?)</archive>');
    for (final match in archiveRegex.allMatches(package.body)) {
      final archiveBody = match.group(1) ?? '';
      final completeMatch =
          RegExp(r'<complete>([\s\S]*?)</complete>').firstMatch(archiveBody);
      if (completeMatch == null) {
        continue;
      }
      final completeBody = completeMatch.group(1) ?? '';
      final urlMatch = RegExp(r'<url>([^<]+)</url>').firstMatch(completeBody);
      if (urlMatch == null) {
        continue;
      }
      final url = (urlMatch.group(1) ?? '').toLowerCase();
      for (final hint in hints) {
        if (url.contains(hint)) {
          return ArchiveInfo(
            url: urlMatch.group(1) ?? '',
            checksums: parseChecksums(completeBody),
          );
        }
      }
    }
    return null;
  }

  /// 计算文件摘要。
  ///
  /// `@visibleForTesting`：期望值在测试里用 `shasum` / `openssl` 独立核对，
  /// 不从本实现反推。
  @visibleForTesting
  static Future<String> digestFile(File file, String algorithm) async {
    final bytes = await file.readAsBytes();
    switch (algorithm) {
      case 'sha256':
        return sha256.convert(bytes).toString();
      case 'sha1':
        return sha1.convert(bytes).toString();
      case 'md5':
        return md5.convert(bytes).toString();
      default:
        throw ArgumentError('unsupported digest algorithm: $algorithm');
    }
  }

  /// 在解包/执行之前校验下载产物与仓库索引声明的校验和一致。
  ///
  /// 索引未提供任何校验和时**拒绝安装**，而不是放行——这些归档最终会成为
  /// 被本进程直接执行的 adb/aapt2/apksigner。
  ///
  /// `@visibleForTesting`：这是 T0-2 的**执行点**，两条拒绝路径（不匹配 /
  /// 未声明）都必须有回归测试钉住。
  @visibleForTesting
  static Future<void> verifyArchiveChecksum(File file, ArchiveInfo info) async {
    final expected = info.preferredDigest;
    if (expected == null || expected.isEmpty) {
      throw ToolDownloadException(
        ToolDownloadError.checksumMismatch,
        detail: '仓库索引未提供校验和，拒绝安装未经验证的归档: ${info.url}',
      );
    }
    final algorithm = info.preferredAlgorithm!;
    final actual = await digestFile(file, algorithm);
    if (actual.toLowerCase() != expected.toLowerCase()) {
      throw ToolDownloadException(
        ToolDownloadError.checksumMismatch,
        detail: '校验和不匹配 (${algorithm.toUpperCase()}): '
            '${info.url}\n  expected=$expected\n  actual  =$actual',
      );
    }
    log.info('checksum verified (${algorithm.toUpperCase()}): ${info.url}');
  }
}

typedef ToolDownloadProgressCallback = void Function(
    ToolDownloadProgress progress);

class ToolDownloadProgress {
  final String task;
  final int received;
  final int total;

  ToolDownloadProgress({
    required this.task,
    required this.received,
    required this.total,
  });

  double? get percent =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
}

class ToolDownloadOptions {
  final List<String> sourceUrls;
  final String installDir;
  final bool downloadPlatformTools;
  final bool downloadBuildTools;

  /// 是否下载 JRE（`apksigner` 的运行时依赖）。
  ///
  /// 只在 Windows 上提供，见 [JavaRuntime.supportsDownload]。
  final bool downloadJre;

  final ToolDownloadProgressCallback? onProgress;

  ToolDownloadOptions({
    required this.sourceUrls,
    required this.installDir,
    required this.downloadPlatformTools,
    required this.downloadBuildTools,
    this.downloadJre = false,
    this.onProgress,
  });
}

/// Adoptium 提供的一份 JRE 资产。
class AdoptiumJre {
  final String url;

  /// SHA-256（十六进制，无前缀）。
  final String checksum;

  /// 如 `17.0.20+101`。
  final String version;

  const AdoptiumJre({
    required this.url,
    required this.checksum,
    required this.version,
  });
}

enum ToolDownloadError {
  repositoryIndex,
  platformToolsMissing,
  buildToolsMissing,
  archiveDownload,
  fileNotFound,

  /// 下载产物与仓库索引声明的校验和不匹配，或索引未提供校验和。
  checksumMismatch,
  unknown,
}

class ToolDownloadException implements Exception {
  final ToolDownloadError code;
  final String? detail;

  ToolDownloadException(this.code, {this.detail});

  @override
  String toString() {
    return 'ToolDownloadException($code, detail: $detail)';
  }
}

class RemotePackage {
  final String path;
  final String body;
  final String? version;

  RemotePackage({required this.path, required this.body, this.version});
}

class ArchiveInfo {
  final String url;

  /// 仓库索引中声明的校验和，形如 `{'sha256': 'ab12...', 'sha1': 'cd34...'}`。
  /// 解包前会强制比对，防止下载到被篡改的可执行文件。
  final Map<String, String> checksums;

  ArchiveInfo({required this.url, Map<String, String>? checksums})
      : checksums = checksums ?? const {};

  /// 取出校验强度最高的可用摘要算法。
  ///
  /// 优先 SHA-256，其次 SHA-1（Google 官方索引仅发布 SHA-1 时）。
  String? get preferredAlgorithm {
    for (final algo in const ['sha256', 'sha1', 'md5']) {
      final value = checksums[algo];
      if (value != null && value.isNotEmpty) return algo;
    }
    return null;
  }

  String? get preferredDigest => checksums[preferredAlgorithm];
}

class PlatformArchive {
  final String url;
  final String version;

  /// 仓库索引中声明的校验和，用于解包前校验下载产物。
  final Map<String, String> checksums;

  PlatformArchive({
    required this.url,
    required this.version,
    Map<String, String>? checksums,
  }) : checksums = checksums ?? const {};
}

class BuildToolsArchive {
  final String version;
  final ArchiveInfo archive;

  BuildToolsArchive({required this.version, required this.archive});
}
