import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

class ToolDownloadResult {
  final String installDir;
  final String platformToolsVersion;
  final String buildToolsVersion;

  ToolDownloadResult({
    required this.installDir,
    required this.platformToolsVersion,
    required this.buildToolsVersion,
  });
}

class ToolDownloader {
  static const String repositoryIndexUrl =
      'https://dl.google.com/android/repository/repository2-3.xml';
  static const String mirrorRepositoryIndexUrl =
      'https://github.com/huanfeng/apk_info_tool_binary/releases/download/latest/repository2-3.xml';

  static Future<ToolDownloadResult> downloadDependencies(
      ToolDownloadOptions options) async {
    final installDir = options.installDir;
    await Directory(installDir).create(recursive: true);

    final indexUrls = options.sourceUrls.isEmpty
        ? _buildRepositoryIndexUrls()
        : options.sourceUrls;
    final xmlContent = await _downloadTextWithFallback(
      indexUrls,
      options.onProgress,
    );
    final platformArchive =
        options.downloadPlatformTools ? _selectPlatformTools(xmlContent) : null;
    final buildTools =
        options.downloadBuildTools ? _selectBuildTools(xmlContent) : null;

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
      // 解包前必须校验：这些二进制随后会被本进程直接执行。
      await _verifyArchiveChecksum(
        platformTemp,
        ArchiveInfo(
          url: platformArchive.url,
          checksums: platformArchive.checksums,
        ),
      );
      await _extractPlatformTools(platformTemp, installDir);
    }

    if (buildTools != null) {
      final buildToolsTemp = await _downloadArchiveToTemp(
        baseUris,
        buildTools.archive.url,
        'build-tools',
        options.onProgress,
      );
      await _verifyArchiveChecksum(buildToolsTemp, buildTools.archive);
      await _extractBuildTools(
        buildToolsTemp,
        installDir,
        buildTools.version,
      );
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
    );
  }

  /// 构建仓库索引候选地址。
  ///
  /// 顺序很重要：**官方 Google 仓库排在最前**。历史实现把个人 GitHub 镜像
  /// 放在首位，一旦该账号被接管，所有用户拿到的都是攻击者投放的 adb/aapt2，
  /// 且这些二进制会被直接执行。镜像只能作为官方源不可达时的降级选项。
  static List<String> _buildRepositoryIndexUrls() {
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
    if (uri.scheme != 'https' && uri.scheme != 'file') {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'non-HTTPS scheme: $uri',
      );
    }
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final bytes = await _readResponseBytes(response, onProgress);
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
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
      await source.copy(target.path);
      return target;
    }
    if (uri.scheme != 'https' && uri.scheme != 'file') {
      throw ToolDownloadException(
        ToolDownloadError.archiveDownload,
        detail: 'non-HTTPS scheme: $uri',
      );
    }
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final bytes = await _readResponseBytes(response, onProgress);
      final dir =
          await Directory.systemTemp.createTemp('apk_info_tool_$prefix');
      final file = File(path.join(dir.path, path.basename(uri.path)));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>> _readResponseBytes(
    HttpClientResponse response,
    void Function(int received, int total)? onProgress,
  ) async {
    final builder = BytesBuilder(copy: false);
    final total = response.contentLength > 0 ? response.contentLength : 0;
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

  static Future<void> _extractPlatformTools(
      File zipFile, String installDir) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    ZipGuard.ensureNotBomb(archive, source: 'platform-tools');
    await ZipGuard.extractToDirectory(
      archive,
      path.join(installDir, 'platform-tools'),
      stripPrefix: 'platform-tools/',
    );
  }

  static Future<void> _extractBuildTools(
    File zipFile,
    String installDir,
    String version,
  ) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    ZipGuard.ensureNotBomb(archive, source: 'build-tools $version');
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
    );
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
  static Map<String, String> _parseChecksums(String completeBody) {
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
        checksums: _parseChecksums(completeBody),
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
            checksums: _parseChecksums(completeBody),
          );
        }
      }
    }
    return null;
  }

  /// 计算文件摘要。
  static Future<String> _digestFile(File file, String algorithm) async {
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
  static Future<void> _verifyArchiveChecksum(
      File file, ArchiveInfo info) async {
    final expected = info.preferredDigest;
    if (expected == null || expected.isEmpty) {
      throw ToolDownloadException(
        ToolDownloadError.checksumMismatch,
        detail: '仓库索引未提供校验和，拒绝安装未经验证的归档: ${info.url}',
      );
    }
    final algorithm = info.preferredAlgorithm!;
    final actual = await _digestFile(file, algorithm);
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
  final ToolDownloadProgressCallback? onProgress;

  ToolDownloadOptions({
    required this.sourceUrls,
    required this.installDir,
    required this.downloadPlatformTools,
    required this.downloadBuildTools,
    this.onProgress,
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
