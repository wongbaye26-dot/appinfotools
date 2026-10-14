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
