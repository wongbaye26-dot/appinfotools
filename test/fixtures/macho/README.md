# Mach-O 测试样本

由 macOS 的 clang 从一个 4 行 C 源文件编译而来，用于验证 Mach-O 解析器：

```sh
cat > x.c <<'SRC'
int probe_value(void) { return 42; }
SRC
clang -dynamiclib -arch arm64                -o thin-arm64.dylib          x.c
clang -dynamiclib -arch arm64 -arch x86_64   -o fat-x86_64-arm64.dylib    x.c
```

| 文件 | 大小 | 内容 |
|---|---|---|
| `thin-arm64.dylib` | 16800 | MH_MAGIC_64，arm64，DYLIB，14 条 load command |
| `fat-x86_64-arm64.dylib` | 33184 | FAT_MAGIC，2 个切片（x86_64 @4096/4224、arm64 @16384/16800） |

用真实产物而不是手工拼字节：手工拼的样本会带着与解析器相同的错误假设。
期望值取自 `otool -hv` / `otool -l`，是独立于本项目的参照物。

## libnative-fixture-*.dylib

clang 编译的 dylib，用来验证 `LC_SYMTAB` 的解析。三个变体覆盖三种形态：

```sh
clang -dynamiclib -O1 -o libnative-fixture-arm64.dylib native.c
clang -dynamiclib -O1 -arch arm64  -o s-arm64.dylib native.c
clang -dynamiclib -O1 -arch x86_64 -o s-x86.dylib   native.c
lipo -create s-arm64.dylib s-x86.dylib -output libnative-fixture-fat.dylib
cp libnative-fixture-arm64.dylib libnative-fixture-stripped.dylib
strip -x libnative-fixture-stripped.dylib
```

`native.c` 与 ELF 夹具同源：导入 `system` / `popen` / `execl` / `fork` /
`dlopen` / `dlsym` / `ptrace` / `socket` / `connect`，导出几个自己的函数。

### 期望值（用 `otool -l` / `nm` 独立核对）

```
$ otool -l libnative-fixture-arm64.dylib | grep -A 6 LC_SYMTAB
  cmd LC_SYMTAB / cmdsize 24
  symoff 33112 / nsyms 17 / stroff 33464 / strsize 168

$ nm -u libnative-fixture-arm64.dylib     → 10 条（带前导下划线）
  _connect _dlopen _dlsym _execl _fork _pclose _popen _ptrace _socket _system

$ nm -gU libnative-fixture-arm64.dylib    → 7 条
  _do_ptrace _exported_helper _exported_name _load_plugin
  _make_socket _run_command _spawn
```

### fat 的偏移基准（最容易写错的地方）

```
$ lipo -detailed_info libnative-fixture-fat.dylib
  architecture x86_64 → offset 4096  size 9056
  architecture arm64  → offset 16384
```

**`symoff` / `stroff` 是相对「本切片起始」的，不是相对整个文件。**
证据：fat 里 arm64 切片的 `symoff` 与 **thin arm64** 完全相同（都是 33112），
而它在文件里的起点是 16384。按「文件绝对偏移」解释会落到切片内的别处，
解出来的名字不可能与 `nm` 一致。

有一条测试专门钉住这件事（把 `base + symoff` 改成 `symoff` 会让它失败）。

### 关于 `-stripped`

对**共享库**来说，`strip` 只能去掉局部符号：导入符号是链接期必需的、
导出符号是对外接口，都不能去。因此这个变体的外部符号与未剥离版**完全一样**
—— 测试记录的是这个事实，而不是「strip 后符号变少」。
