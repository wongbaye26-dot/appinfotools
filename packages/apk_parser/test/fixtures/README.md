# `apk_parser` 包内夹具

这个目录放**只有本包测试用**的夹具。跨包共用的包级夹具在仓库根的
`test/fixtures/`，不要往这里镜像一份。

## `loader-api.dex`

- 大小：1,224 字节
- sha256：`0260bde7d5c5bfd2d358f78d9645aa010b5b0a4a69e5e113e9011d4dcf241c0b`
- 用途：`android_load_graph_test.dart` 的加载链夹具（Android Phase B 事实层）。
- 性质：**不是恶意样本**，只是把 `System.loadLibrary` / `System.load` /
  `DexClassLoader` 三种加载 API 各放一条调用指令的最小 DEX。

### 内容（用 `dexdump -d` 独立核对，不取自本项目解析器）

```
Class descriptor  : 'Ltest/Loader;'
  name: 'main'
  |0000: const-string v3, "foo"
  |0002: invoke-static {v3}, Ljava/lang/System;.loadLibrary:(Ljava/lang/String;)V
  |0005: const-string v3, "/data/local/tmp/libbar.so"
  |0007: invoke-static {v3}, Ljava/lang/System;.load:(Ljava/lang/String;)V
  |000c: const-string v0, "/data/local/tmp"
  |000f: const-string v2, "payload.dex"
  |0011: invoke-direct {v3, v2, v0, v1, v1},
         Ldalvik/system/DexClassLoader;.<init>:(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V
```

`string_ids` 里另有 `loadLibrary` / `load` / `DexClassLoader` / `payload.dex`
等字面量。

核对命令：

```bash
"$ANDROID_HOME"/build-tools/"$BUILD_TOOLS"/dexdump -d test/fixtures/loader-api.dex
```

### 生成方式（可复现「等价夹具」，不保证字节一致）

用 d8（Android SDK build-tools 36.1.0，`--debug --min-api 21`）从下面的 Java
源码编译：

```java
package test;

import dalvik.system.DexClassLoader;

public class Loader {
    public static void main(String[] args) {
        System.loadLibrary("foo");
        System.load("/data/local/tmp/libbar.so");
        try {
            new DexClassLoader("payload.dex", "/data/local/tmp", null, null);
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
```

```bash
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export BUILD_TOOLS=36.1.0
mkdir -p /tmp/loader-api/out
javac -classpath "$ANDROID_HOME/platforms/android-34/android.jar" \
  -source 8 -target 8 -d /tmp/loader-api/out /tmp/loader-api/Loader.java
"$ANDROID_HOME"/build-tools/"$BUILD_TOOLS"/d8 \
  --debug --min-api 21 \
  --lib "$ANDROID_HOME/platforms/android-34/android.jar" \
  --output /tmp/loader-api/out /tmp/loader-api/out/test/Loader.class
# 产物：/tmp/loader-api/out/classes.dex
```

注意：

- `dalvik.system.DexClassLoader` 不在 JDK 里，`javac` 必须带
  `android.jar`（只用来编译，不参与运行）；
- **不要指望字节完全一致**：d8 会把自身版本写进 `string_ids`（本夹具里是
  `~~D8{…"version":"9.0.3-dev"…}`），javac 的调试信息（行号/局部变量表）也会
  随版本变化。夹具的用途是「三种加载调用各一条」，不是校验某版编译器输出；
- 换夹具后要同步更新 `android_load_graph_test.dart` 里对偏移（`@0x2` 等）与
  字符串的断言。
