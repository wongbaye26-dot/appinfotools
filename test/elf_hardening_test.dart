// 原生库的**二进制加固属性**：NX 栈 / RELRO / BIND_NOW / 栈保护 / strip。
//
// ## 期望值来源
//
// 七个夹具都由 **NDK 25.1** 的 clang 真实编译（源码见
// `test/fixtures/elf/hardening-native.c`），并用 NDK 自带的
// `llvm-readelf` / `llvm-nm` 独立核对 —— **不是**从本项目解析器取的。
//
// ```sh
// CC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang
// $CC -shared -fPIC -O1 -o hardening-default.so native.c
// $CC -shared -fPIC -O1 -Wl,-z,execstack     -o hardening-execstack.so native.c
// $CC -shared -fPIC -O1 -Wl,-z,norelro       -o hardening-norelro.so native.c
// $CC -shared -fPIC -O1 -Wl,-z,relro,-z,lazy -o hardening-partial-relro.so native.c
// $CC -shared -fPIC -O1 -fno-stack-protector -o hardening-no-canary.so native.c
// $CC -shared -fPIC -O1 -fstack-protector-all -o hardening-canary.so native.c
// $CC -shared -fPIC -O1 -fstack-protector-all -o hardening-canary-stripped.so native.c
// $NDK/.../llvm-strip --strip-all hardening-canary-stripped.so
// ```
//
// `llvm-readelf -l` 的 `GNU_STACK` 行末三分量是 `Flg Align`，
// 所以 **`RWE` / `RW` 要按倒数第二列取** —— 按 `$NF` 取会拿到对齐值 0x0，
// 于是「可执行栈」与「NX 栈」看起来一模一样（我第一次就这么读错了）。
//
// ## 为什么这组测试值得存在
//
// 加固属性是**按偏移读的二进制结构**，偏移写错不会报错，只会读出一个
// 看起来合理的错值。三条最容易错的：
//
// 1. **`p_flags` 的位置在 32/64 位下不同**：64 位在 `p_type` 之后（偏移 4），
//    32 位在 `p_offset…p_memsz` 之后（偏移 24）；
// 2. `DT_FLAGS`(30) 与 `DT_FLAGS_1`(0x6ffffffb) **两个都要查**；
// 3. 栈保护只能证明「用了」—— `hardening-default` 就是反例：同样的源码、
//    同样的默认 flags，它**没有**导入 `__stack_chk_fail`，而显式加
//    `-fstack-protector-all` 的才有。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'test/fixtures/elf';

ElfHardening _read(String name) => readElfHardening(
      name,
      File('$_dir/$name').readAsBytesSync(),
    );

void main() {
  group('NX 栈', () {
    test('默认构建 → 栈不可执行', () {
      final h = _read('hardening-default.so');
      expect(h.parsed, isTrue, reason: h.failure);
      expect(h.stackExecutable, isFalse,
          reason: 'llvm-readelf 显示 GNU_STACK 是 RW');
    });

    test('-z execstack → 栈可执行（这是真缺陷）', () {
      final h = _read('hardening-execstack.so');
      expect(h.stackExecutable, isTrue,
          reason: 'llvm-readelf 显示 GNU_STACK 是 RWE');
    });
  });

  group('RELRO 与 BIND_NOW', () {
    test('默认构建 → Full RELRO（RELRO + BIND_NOW）', () {
      final h = _read('hardening-default.so');
      expect(h.relro, isTrue);
      expect(h.bindNow, isTrue);
      expect(h.fullRelro, isTrue);
    });

    test('-z norelro → 没有 RELRO', () {
      final h = _read('hardening-norelro.so');
      expect(h.relro, isFalse);
      expect(h.fullRelro, isFalse);
    });

    test('-z relro,-z lazy → 有 RELRO 但没有立即绑定（Partial）', () {
      final h = _read('hardening-partial-relro.so');
      expect(h.relro, isTrue, reason: 'llvm-readelf 有 GNU_RELRO');
      expect(h.bindNow, isFalse, reason: 'llvm-readelf 没有 BIND_NOW / NOW');
      expect(h.fullRelro, isFalse,
          reason: 'Partial RELRO 不等于 Full —— 只查 RELRO 会误判成 Full');
    });
  });

  group('栈保护', () {
    test('-fstack-protector-all → 导入 __stack_chk_fail', () {
      final h = _read('hardening-canary.so');
      expect(h.stackCanary, isTrue);
    });

    test('-fno-stack-protector → 不导入', () {
      final h = _read('hardening-no-canary.so');
      expect(h.stackCanary, isFalse);
    });

    test('**默认构建也可能不导入** —— 所以 false 不能读成「没开保护」', () {
      // 这条是这组测试里最重要的一个断言：同样源码、同样默认 flags，
      // hardening-default 就是没有 __stack_chk_fail。没有函数触发 canary 时
      // 这个符号根本不会出现在 .dynsym 里。
      final h = _read('hardening-default.so');
      expect(h.stackCanary, isFalse);
      // 但它仍然是 Full RELRO + NX 栈 —— 加固并不差。
      expect(h.fullRelro, isTrue);
      expect(h.stackExecutable, isFalse);
    });
  });

  group('strip', () {
    test('未 strip → 有 .symtab', () {
      expect(_read('hardening-canary.so').stripped, isFalse);
    });

    test('strip --strip-all → 没有 .symtab', () {
      expect(_read('hardening-canary-stripped.so').stripped, isTrue);
    });

    test('strip 之后动态符号仍在（所以 .dynsym 才是可靠的判据）', () {
      // 这条钉住「为什么读 .dynsym 而不是 .symtab」。
      expect(
        _read('hardening-canary-stripped.so').stackCanary,
        isTrue,
        reason: '.symtab 被剥掉了，但 .dynsym 里的 __stack_chk_fail 还在',
      );
    });
  });

  group('32 位（p_flags 在偏移 24，不是 4）', () {
    test('armeabi-v7a 的库也能读对加固属性', () {
      final h = readElfHardening(
        'armeabi-v7a-libnative.so',
        File('$_dir/armeabi-v7a-libnative.so').readAsBytesSync(),
      );
      expect(h.parsed, isTrue, reason: h.failure);
      // 32 位的 p_flags 在偏移 24；用 64 位的偏移 4 会读到 p_offset，
      // 那是一个看起来合理的地址值 —— 不报错，只是错。
      expect(h.stackExecutable, isFalse,
          reason: 'llvm-readelf 显示这个库的 GNU_STACK 是 RW');
      expect(h.relro, isTrue);
    });
  });

  group('读不出 ≠ 不满足', () {
    test('不是 ELF → unreadable，各字段都是 null', () {
      final h = readElfHardening(
        'junk',
        File('test/fixtures/apk/attr-fixture.apk').readAsBytesSync(),
      );
      expect(h.parsed, isFalse);
      expect(h.stackExecutable, isNull);
      expect(h.relro, isNull);
      expect(h.fullRelro, isFalse, reason: 'null 不构成 Full RELRO，但也不是「缺 RELRO」');
    });

    test('截断的文件 → unreadable', () {
      final bytes = File('$_dir/hardening-default.so').readAsBytesSync();
      final h = readElfHardening(
        'truncated',
        Uint8List.fromList(bytes.sublist(0, 40)),
      );
      expect(h.parsed, isFalse);
    });

    test('程序头越界 → unreadable（不可信长度不能决定读多少）', () {
      final bytes = File('$_dir/hardening-default.so').readAsBytesSync();
      final patched = Uint8List.fromList(bytes);
      // e_phoff 在 0x20（64 位）—— 改成远超文件长度的值。
      patched[0x20] = 0xff;
      patched[0x21] = 0xff;
      patched[0x22] = 0xff;
      patched[0x23] = 0x7f;
      final h = readElfHardening('patched', patched);
      expect(h.parsed, isFalse);
      expect(h.failure, contains('out of range'));
    });
  });
}
