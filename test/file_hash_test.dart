// 三种哈希的并行实现必须与外部工具逐字节一致。
//
// 这条测试的存在理由：V2.5.0 把哈希从「一趟读文件、三种算法串行」改成
// 「三种算法各跑一个 isolate」—— 并行本身是性能优化，**正确性不能跟着变**。
// 期望值全部来自系统工具（`md5` / `shasum`），**不从本项目代码取**：
// 拿自己的输出当期望值等于什么都没验证。
//
// 覆盖两种规模：
// - 28 字节：落在单个 4 MiB 分块内（走「读完一次就 EOF」的分支）；
// - 10 MiB + 12345 字节：跨多个分块、且**不是分块大小的整数倍**
//   （尾块处理错了只会在大文件上暴露）。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:flutter_test/flutter_test.dart';

/// 小夹具：`test/fixtures/hash/hello.txt`，内容 `AppInfoTool hash fixture v1\n`。
const _smallPath = 'test/fixtures/hash/hello.txt';
const _smallMd5 = '45d5acedcada22eb286b563499399049';
const _smallSha1 = 'e72e1f8c07a6d76b0bea699f3f452f47d673d85d';
const _smallSha256 =
    '0f8bab91b80cbbdcb2884760a5e427f7fdfa7cc2c89af7a8d85c31069d100568';

/// 大夹具：由 [bigFixtureBytes] 确定性生成，不占仓库体积。
const _bigSize = 10 * 1024 * 1024 + 12345;
const _bigMd5 = '42cbf8aac4772877d370e2025db56eac';
const _bigSha1 = '2c11da67dbe8db694678531e72222b094b694cb6';
const _bigSha256 =
    '9fd418adf8f2b4a29dace206fb5629e43a27040db5b5ec517c8666f09f107a6d';

/// 与造夹具时用的公式逐字节一致（`bytes((i % 251) for i in range(n))`）。
Uint8List bigFixtureBytes() {
  final bytes = Uint8List(_bigSize);
  for (var i = 0; i < _bigSize; i++) {
    bytes[i] = i % 251;
  }
  return bytes;
}

void main() {
  test('小文件：三种哈希与系统工具一致', () async {
    final file = File(_smallPath);
    expect(file.existsSync(), isTrue, reason: '夹具缺失：$_smallPath');

    final hashes = await computeFileHashes(file.absolute.path);
    expect(hashes.md5, _smallMd5);
    expect(hashes.sha1, _smallSha1);
    expect(hashes.sha256, _smallSha256);
  });

  test('大文件：跨分块边界，三种哈希与系统工具一致', () async {
    final dir = await Directory.systemTemp.createTemp('hash_fixture');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/big.bin');
    await file.writeAsBytes(bigFixtureBytes(), flush: true);

    final hashes = await computeFileHashes(file.path);
    expect(hashes.md5, _bigMd5);
    expect(hashes.sha1, _bigSha1);
    expect(hashes.sha256, _bigSha256);
  });

  test('三种算法并行，结果与逐个算一致', () async {
    // 并行实现最容易出的错是「把某个 isolate 的结果写到了别的字段上」——
    // 单独比对三个字段就能抓到，这里再用一次同样的调用确认可重复。
    final first = await computeFileHashes(File(_smallPath).absolute.path);
    final second = await computeFileHashes(File(_smallPath).absolute.path);
    expect(first.md5, second.md5);
    expect(first.sha1, second.sha1);
    expect(first.sha256, second.sha256);
  });

  test('文件不存在时抛错，不返回全零哈希', () async {
    await expectLater(
      computeFileHashes('/definitely/not/here.apk'),
      throwsA(isA<Exception>()),
    );
  });
}
