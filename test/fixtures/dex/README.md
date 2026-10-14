# DEX 结构样本

## real-netprobe.dex

由 `javac` + `d8` **真实产出**的最小 DEX（1624 字节）。用真实产物而不是手拼
字节：DEX 头是一段**按偏移访问的二进制结构**，偏移写错不会报错，只会读出一个
看起来合理的错值。

源码（生成命令见下）：

```java
package com.example.fixture;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

public class NetProbe {
    /** 只是字符串常量：字符串扫描会命中，但没有任何代码引用 okhttp3 这个类型。 */
    public static String decoy() {
        return "okhttp3 is mentioned here but never used as a type";
    }

    /** 真实的方法调用点：产出 java.net.HttpURLConnection 的类型与方法引用。 */
    public InputStream open(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestMethod("POST");
        return conn.getInputStream();
    }

    public static int helper(int a) { return a + 1; }
}
```

```java
package com.example.fixture;

public class Caller extends NetProbe {
    public int call() { return NetProbe.helper(41); }
}
```

这个样本刻意让**字符串常量**与**真实代码引用**分离：`okhttp3` 只出现在一个
字符串字面量里，而 `java.net.HttpURLConnection` 出现在可执行代码的调用点上。
字符串扫描器对两者一视同仁，结构分析能区分 —— 这就是第二层取证的增量。

### 生成命令（macOS，Android SDK build-tools 36.1.0）

```sh
BT=~/Library/Android/sdk/build-tools/36.1.0
javac -nowarn -source 8 -target 8 -d classes $(find src -name '*.java')
mkdir -p dexout
"$BT/d8" --min-api 21 --output dexout $(find classes -name '*.class')
cp dexout/classes.dex real-netprobe.dex
```

### 期望值（用 `dexdump -f` 独立核对，**不是**从本项目解析器取的）

```
magic               : 'dex\n035\0'
checksum            : 6bee065c
file_size           : 1624
header_size         : 112
string_ids_size     : 30    string_ids_off  : 112  (0x000070)
type_ids_size       : 12    type_ids_off    : 232  (0x0000e8)
proto_ids_size      : 8     proto_ids_off   : 280  (0x000118)
field_ids_size      : 0     field_ids_off   : 0
method_ids_size     : 11    method_ids_off  : 376  (0x000178)
class_defs_size     : 2     class_defs_off  : 464  (0x0001d0)
```

调用点（`dexdump -d`）：

```
000290: invoke-virtual {v2}, Ljava/net/HttpURLConnection;.getInputStream:()Ljava/io/InputStream;
00028a: invoke-virtual {v2, v0}, Ljava/net/HttpURLConnection;.setRequestMethod:(Ljava/lang/String;)V
000224: invoke-static {v0}, Lcom/example/fixture/NetProbe;.helper:(I)I
```

`checksum` 另用 Python 的 `zlib.adler32(raw[12:])` 交叉核对，同样得到
`0x6bee065c` —— 与 `dexdump`、与本项目解析器都无关。

## 畸变样本

**手工改的**：没有工具会产出「声明尺寸与实际不符」的 DEX，而这正是要防的形态。
每个都先用 `dexdump` 核对过它的判断，期望值抄在下面。

| 文件 | 改动 | `dexdump` 的结论 | 本项目记下的 code |
|---|---|---|---|
| `truncated.dex` | 截到 800 字节 | `File size is 800 but the header expects 1624` | `dex.file_size_mismatch` |
| `header-file-size-mismatch.dex` | `file_size`(0x20)=999999 | `File size is 1624 but the header expects 999999` | `dex.file_size_mismatch` |
| `bad-magic.dex` | magic 改成 `DEX\0` | `Expected valid zip or dex file` | `dex.bad_magic` |
| `header-size-not-standard.dex` | `header_size`(0x24)=64 | `Header size is 64 but 112 was expected` | `dex.header_size_not_standard` |
| `method-ids-off-out-of-range.dex` | `method_ids_off`(0x5C)=0xFFFFFF | `Offset(16777215) should be within file size(1624) for method-ids` | `dex.section_out_of_range` |
| `method-ids-size-absurd.dex` | `method_ids_size`(0x58)=0xFFFFFF | `Section end(16777591) should be within file size(1624) for method-ids` | `dex.section_out_of_range` |
| `string-ids-off-in-header.dex` | `string_ids_off`(0x3C)=0 | `Bad offset for section: got 70, expected 0` | `dex.section_overlaps_header` |
| `multiple-anomalies.dex` | `file_size` + `header_size` + `checksum` 同时改坏 | 只报第一条：`Header size is 64 but 112 was expected` | 三条**全部**报告 |
| `checksum-zeroed.dex` | `checksum`(0x08)=0 | `Bad checksum (6bee065c, expected 00000000)` | `dex.checksum_mismatch`（**非**阻断） |

### 两点值得记下

1. **`method-ids-off-out-of-range` / `method-ids-size-absurd` /
   `string-ids-off-in-header` 的 checksum 是重算过的。**
   不重算的话 `dexdump` 只会报 `Bad checksum`，测到的就是校验和而不是边界
   校验 —— 那样等于没测到我们要测的东西。重算方式：
   `signature = SHA1(raw[32:])`、`checksum = adler32(raw[12:])`。

2. **`dexdump` 对 `multiple-anomalies.dex` 只报第一条，本项目报告全部。**
   排查时「还有哪些地方对不上」比「第一个对不上的」有用得多，这是有意的差异，
   不是不一致。

## DEX 头字段偏移（实测核对，别照抄博客）

```
0x00 magic[8]            0x08 checksum u32      0x0C signature[20]
0x20 file_size u32       0x24 header_size u32   0x28 endian_tag u32
0x2C link_size u32       0x30 link_off u32      0x34 map_off u32
0x38 string_ids_size     0x3C string_ids_off
0x40 type_ids_size       0x44 type_ids_off
0x48 proto_ids_size      0x4C proto_ids_off
0x50 field_ids_size      0x54 field_ids_off
0x58 method_ids_size     0x5C method_ids_off
0x60 class_defs_size     0x64 class_defs_off
0x68 data_size u32       0x6C data_off u32
```

写夹具时把 `0x58` / `0x5C` 记反过一次，是 `dexdump` 的报错（
`... for method-ids` 指向的是 off 而不是 size）纠正的 —— 所以每个畸变样本都
必须先过一遍 `dexdump` 再写期望值。

## `method_ids` 的完整基准

`dexdump` 没有直接 dump 整张 `method_ids` 的选项（`-d` 只显示被 `invoke-*`
引用到的那些，共 7 条）。整张表有 11 条，逐条都能从 Java 源码推出 ——
构造器、被调用的方法、以及 `Caller` 继承链上的调用：

| # | 引用 |
|---|---|
| 0 | `Lcom/example/fixture/Caller;.<init>()V` |
| 1 | `Lcom/example/fixture/Caller;.call()I` |
| 2 | `Lcom/example/fixture/NetProbe;.<init>()V` |
| 3 | `Lcom/example/fixture/NetProbe;.decoy()Ljava/lang/String;` |
| 4 | `Lcom/example/fixture/NetProbe;.helper(I)I` |
| 5 | `Lcom/example/fixture/NetProbe;.open(Ljava/lang/String;)Ljava/io/InputStream;` |
| 6 | `Ljava/lang/Object;.<init>()V` |
| 7 | `Ljava/net/HttpURLConnection;.getInputStream()Ljava/io/InputStream;` |
| 8 | `Ljava/net/HttpURLConnection;.setRequestMethod(Ljava/lang/String;)V` |
| 9 | `Ljava/net/URL;.<init>(Ljava/lang/String;)V` |
| 10 | `Ljava/net/URL;.openConnection()Ljava/net/URLConnection;` |

其中 #2/#4/#6/#7/#8/#9/#10 七条能在 `dexdump -d` 的 `invoke-*` 行里逐字对上
（见上面的调用点），这是测试里逐个断言的那批。#0/#1/#3/#5 是定义在样本里的
方法自身（`method_ids` 同时收录被引用与被定义的方法）。

**`okhttp3` 不在这张表里** —— 它只出现在 `string_ids` 的
`string[000024]`。这一条正是「字符串提到了」与「代码引用了」的分界，也是
`test/dex_method_scanner_test.dart` 要钉住的东西。

## real-opcodes.dex

由 `javac` + `d8` 产出的**指令格式覆盖样本**（1920 字节，8 个方法体、
101 条指令、53 种助记符），专门用来验证指令宽度表。

```java
package com.example.fixture;

public class Opcodes {
    static int[] arr = new int[8];
    static long counter = 7L;
    int field;

    public static int arith(int a, int b) { /* 各类算术、位运算、类型转换 */ }
    public int fields(int x) { /* iget/iput、sget/sput、aget */ }
    public String switchOn(int x) { /* sparse-switch + 载荷 */ }
    public String loop(int n) { /* StringBuilder、循环、if */ }
    public int caught(int x) { /* try/catch/finally */ }
    public int cast(Object o) { /* instance-of、check-cast */ }
}
```

（完整源码见提交历史；要点是它覆盖了 1/2/3/4/5 个代码单元的各类格式，
并且**含一个 `sparse-switch-data` 载荷**。）

### 为什么需要它

指令长度是 1–5 个 16 位代码单元，宽度表错一格就会在指令中间错位，把别的指令
的操作数当成方法索引 —— 结果看起来完全正常，却是错的。所以要有一个能把
「每一步落在哪」逐条核对出来的样本。

### 期望值（`dexdump -d` 的 `|XXXX:` 列，十六进制转十进制，共 101 条）

```
0,2,4,6,8,10, 0,3, 0,2,3,4,6,8,10,12,14,16,18,20,22,23,28,29,30,32,34,35,36,37,38,39,40,41,
0,2,4,6,9,10,11,12, 0,2,3,5,7,9,10,11,13,15,17,18,19,20,22,24,26,27,
0,2,4,5,6,8,10,12,14,16,17, 0,2,5,6,8,10,12,15,16,18,21,23,24,27,28,
0,3,5,6,8,9,11,12,14,15,17,18,20,21,22
```

（这些值原样内嵌在 `test/dex_instruction_test.dart` 的 `_dexdumpOpcodeOffsets`
里 —— CI 上跑不了 `dexdump`，所以基准必须内嵌。）

## real-cooccurrence.dex / real-separate.dex

一对用来验证**「调用点是否在同一个方法体内」**的样本。

```java
// 两个类的方法名刻意带上标记字面量
public class FakeOcr    { public static void recognizeText(String s) {...} }
public class FakeUpload { public static void uploadImage(String path) {...} }

// real-cooccurrence.dex：同一个方法里既有识别又有上传
public class Pipeline {
    public static void run(String path) {
        FakeOcr.recognizeText(path);
        FakeUpload.uploadImage(path);
    }
    public static void onlyOcr(String path) { FakeOcr.recognizeText(path); }
}

// real-separate.dex：识别与上传在不同方法里
public class Separate {
    public static void doOcr(String path)    { FakeOcr.recognizeText(path); }
    public static void doUpload(String path) { FakeUpload.uploadImage(path); }
}
```

### 期望值（`dexdump -d`）

```
real-cooccurrence.dex
  00023c: invoke-static {v0}, Lcom/example/fixture/FakeOcr;.recognizeText:(Ljava/lang/String;)V
  000254: invoke-static {v0}, Lcom/example/fixture/FakeOcr;.recognizeText:(Ljava/lang/String;)V
  00025a: invoke-static {v0}, Lcom/example/fixture/FakeUpload;.uploadImage:(Ljava/lang/String;)V
  → 0x254 与 0x25a 相邻，同属 Pipeline.run → **同现**
  → 0x23c 单独属于 Pipeline.onlyOcr → **不同现**

real-separate.dex
  00023c: invoke-static {v0}, Lcom/example/fixture/FakeOcr;.recognizeText:(Ljava/lang/String;)V
  000254: invoke-static {v0}, Lcom/example/fixture/FakeUpload;.uploadImage:(Ljava/lang/String;)V
  → 分别在 Separate.doOcr 与 Separate.doUpload → **不同现**
```

两个都要留：只留同现的那个，「同现检测」直接 `return true` 也能通过。
