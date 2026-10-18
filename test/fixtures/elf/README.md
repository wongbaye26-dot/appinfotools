# ELF（Android `lib/**.so`）样本

由 **Android NDK 25.1.8937393** 的 clang **真实编译**出来的最小 `.so`。
用真实产物而不是手拼字节：ELF 头与节表都是**按偏移访问**的二进制结构，
偏移写错不会报错，只会读出一个看起来合理的错值。

```sh
NDK=~/Library/Android/sdk/ndk/25.1.8937393
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin

$BIN/aarch64-linux-android21-clang -shared -fPIC -O1 -o arm64-v8a-libnative.so native.c
$BIN/armv7a-linux-androideabi21-clang -shared -fPIC -O1 -o armeabi-v7a-libnative.so native.c
cp arm64-v8a-libnative.so stripped.so && $BIN/llvm-strip --strip-all stripped.so
```

源码 `native.c` 刻意**导入**一批有安全含义的 libc 符号（它们会出现在
`.dynsym` 的 UND 段里），并导出几个自己的函数：

| 能力 | 导入的符号 |
|---|---|
| 命令执行 | `system` `popen` `pclose` |
| 进程派生 | `fork` `execl` |
| 动态加载 | `dlopen` `dlsym` |
| 反调试 | `ptrace` |
| 网络 | `socket` `connect` |
| 环境探测 | `getenv` |
| 日志 | `__android_log_print` |

## 期望值（用 NDK 自带的 `llvm-readelf` / `llvm-nm` 独立核对）

**不是**从本项目解析器取的 —— 那样等于自证。

```
$ llvm-readelf -h arm64-v8a-libnative.so
  Class ELF64 / Machine AArch64 / Type DYN
  Start of section headers 6256 / Size 64 / Number 23 / shstrndx 21

$ llvm-readelf -S arm64-v8a-libnative.so
  [ 2] .dynsym  DYNSYM  0002d0 0002d0 000228 18  A  7  1  8
  [ 7] .dynstr  STRTAB  0003cc 000670 0000ec 00  A  0  0  1

$ llvm-nm -D --undefined-only arm64-v8a-libnative.so
  U __android_log_print / __cxa_atexit / __cxa_finalize / connect / dlopen /
    dlsym / execl / fork / getenv / pclose / popen / ptrace / socket / system
  （14 条；`llvm-nm` 会补 `@LIBC` 版本后缀，ELF 的 st_name 本来不带）

$ llvm-nm -D --defined-only arm64-v8a-libnative.so
  T do_ptrace / exported_helper / exported_name / load_plugin /
    make_socket / probe_env / run_command / spawn   （8 条）
```

`llvm-readelf --dyn-syms` 显示 **23** 项，含第 0 项那个**空名占位符号** ——
它是 `UND`，但**不是**一个真实导入。把它算进「导入了什么」会凭空多出一条
空名字。

## 畸变样本

**手工改的**：没有工具会产出「节表越界」的 ELF，而那正是要防的形态。
每个都先用 `llvm-readelf` 核对过它的判断。

| 文件 | 改动 | `llvm-readelf` 的结论 | 本项目记下的 code |
|---|---|---|---|
| `truncated.so` | 截到一半 | `section header table goes past the end of the file` | `elf.section_table_out_of_range`（阻断） |
| `section-table-out-of-range.so` | `e_shoff`(0x28)=0xFFFFFF | `... e_shoff = 0xffffff` | `elf.section_table_out_of_range`（阻断） |
| `bad-magic.so` | magic 改成 `ELF\x7f` | `not recognized as a valid object file` | `elf.bad_magic`（阻断） |
| `no-section-headers.so` | `e_shnum`(0x3C)=0 | `There are 0 section headers`（**合法**） | `elf.no_section_headers`（**非**阻断） |
| `bad-section-name-index.so` | `e_shstrndx`(0x3E)=0xFF | `section header string table index 255 does not exist` | `elf.section_name_table_unavailable`（**非**阻断） |

### 两点值得记下

1. **`no-section-headers` 是合法文件**：运行只需要程序头，节表可以完全剥离。
   因此它记的是**非阻断**异常 —— 只是我们无法读符号表。
2. **`bad-section-name-index` 的节名读不出来，但节的类型与偏移仍然有效**。
   所以符号表按**节类型**（`SHT_DYNSYM`=11）找，不按节名找 —— 有测试钉住
   这个文件仍然能解出全部导入符号。

## ELF 头字段偏移（实测核对）

```
0x00 e_ident[16]（0x04 EI_CLASS、0x05 EI_DATA）
0x10 e_type u16   0x12 e_machine u16   0x14 e_version u32
0x18 e_entry      0x20 e_phoff         0x28 e_shoff
0x30 e_flags u32  0x34 e_ehsize u16    0x36 e_phentsize u16
0x38 e_phnum u16  0x3A e_shentsize u16 0x3C e_shnum u16  0x3E e_shstrndx u16
```
ELF32 的 `e_shoff` 在 0x20、`e_shentsize/shnum/shstrndx` 在 0x2E/0x30/0x32。

条目尺寸：`Elf32_Sym` 16 / `Elf64_Sym` 24；`Elf32_Shdr` 40 / `Elf64_Shdr` 64。

## 加固属性夹具（`hardening-*.so`）

七个由 **NDK 25.1** 的 clang 真实编译的 `.so`，用来钉住原生库的**二进制加固属性**。
源码见 `hardening-native.c`。

```sh
NDK=~/Library/Android/sdk/ndk/25.1.8937393
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
CC=$BIN/aarch64-linux-android21-clang

$CC -shared -fPIC -O1 -o hardening-default.so        native.c
$CC -shared -fPIC -O1 -Wl,-z,execstack     -o hardening-execstack.so     native.c
$CC -shared -fPIC -O1 -Wl,-z,norelro       -o hardening-norelro.so       native.c
$CC -shared -fPIC -O1 -Wl,-z,relro,-z,lazy -o hardening-partial-relro.so native.c
$CC -shared -fPIC -O1 -fno-stack-protector -o hardening-no-canary.so     native.c
$CC -shared -fPIC -O1 -fstack-protector-all -o hardening-canary.so       native.c
$CC -shared -fPIC -O1 -fstack-protector-all -o hardening-canary-stripped.so native.c
$BIN/llvm-strip --strip-all hardening-canary-stripped.so
```

### 期望值（用 `llvm-readelf` / `llvm-nm` 独立核对）

| 夹具 | `GNU_STACK` | `GNU_RELRO` | `BIND_NOW` | `__stack_chk_fail` | `.symtab` |
|---|---|---|---|---|---|
| `hardening-default` | `RW` | ✓ | ✓ | ✗ | ✓ |
| `hardening-execstack` | **`RWE`** | ✓ | ✓ | ✗ | ✓ |
| `hardening-norelro` | `RW` | **✗** | ✓ | ✗ | ✓ |
| `hardening-partial-relro` | `RW` | ✓ | **✗** | ✗ | ✓ |
| `hardening-no-canary` | `RW` | ✓ | ✓ | **✗** | ✓ |
| `hardening-canary` | `RW` | ✓ | ✓ | **✓** | ✓ |
| `hardening-canary-stripped` | `RW` | ✓ | ✓ | **✓** | **✗** |

```sh
$ llvm-readelf -l hardening-execstack.so | grep GNU_STACK
  GNU_STACK  0x000000 0x0 0x0 0x000000 0x000000 RWE 0x0
$ llvm-readelf -d hardening-default.so | grep -E "BIND_NOW|\(NOW\)"
  0x000000000000001e (FLAGS)   BIND_NOW
  0x000000006ffffffb (FLAGS_1) NOW
$ llvm-nm -D --undefined-only hardening-canary.so | grep stack_chk
  U __stack_chk_fail@LIBC
```

### 三个容易踩的坑（都踩过）

1. **`llvm-readelf -l` 的行末是 `Flg Align`**，所以 `RWE` / `RW` 要按**倒数
   第二列**取。用 `awk '{print $NF}'` 会拿到对齐值 `0x0` —— 于是「可执行栈」
   与「NX 栈」看起来一模一样。
2. **`p_flags` 的位置在 32/64 位下不同**：64 位在 `p_type` 之后（偏移 4），
   32 位在 `p_offset…p_memsz` 之后（偏移 24）。用错位置读到的是 `p_offset`，
   一个看起来完全合理的地址值 —— 不报错，只是错。
3. **`hardening-default` 没有 `__stack_chk_fail`**：同样的源码、同样的默认
   flags，它就是没触发 canary。所以「没有这个符号」**不能**读成「没开栈保护」。

## 真实样本上的分布（决定「该报哪几条」）

4 个真实包的 **386 个** arm64 `.so`（用 `llvm-readelf` 逐个数）：

| 属性 | 不满足的库数 |
|---|---|
| 可执行栈 | **0** |
| 缺 RELRO | **1**（Flutter 的 `libapp.so`） |
| 缺 BIND_NOW | **1**（同一个） |
| 未 strip | **0** |

**结论：这一维在真实包上几乎全绿。** 所以本项目**只**对「可执行栈」产出
发现项；缺 RELRO 写进覆盖率的说明里（`android.native_hardening.some_without_relro`），
因为它是合法构建选择，逐库报会命中**所有** Flutter 应用。

### 顺带发现：`lib/` 下藏着 DEX

抖音的 `lib/arm64-v8a/libsm_impl.so`（162,912 字节）头部是 `dex\n035` ——
**不是 ELF，是一段 DEX 字节码**。文件名完全合规，只看名字的检查永远发现不了。
已加信号 `HardeningSignal.dexDisguisedAsNativeLibrary`（`strong` 级）。
