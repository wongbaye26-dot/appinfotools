# XAPK 夹具

## xapk-fixture.xapk

一个按 **XAPK 规范**（APKPure 的容器格式）打包的样本：`manifest.json` +
根目录下的 APK。

### 内层 APK 是真实产物

`com.example.xapkfixture.apk`（base）与 `config.fr.apk`（config split）都由
`aapt2` 编译链接而来：

```sh
AAPT2=~/Library/Android/sdk/build-tools/34.0.0/aapt2
JAR=~/Library/Android/sdk/platforms/android-34/android.jar

$AAPT2 compile --dir res -o compiled.zip
# base + 一个语言 split（--split 的第二个参数是 config 限定符）
$AAPT2 link -o base.apk -I "$JAR" \
  --manifest AndroidManifest.xml --split split-fr.apk:fr compiled.zip
```

源清单见 `AndroidManifest.xml`。

### 容器刻意做了一件「真实打包器会做的事」

`split_apks` 里把 `config.fr.apk` **列了两次**：

```json
"split_apks": [
  {"file": "com.example.xapkfixture.apk", "id": "base"},
  {"file": "config.fr.apk", "id": "config.fr"},
  {"file": "config.fr.apk", "id": "config.fr"}
]
```

合并脚本时这很常见。不去重的话同一个条目会被解两次、路径被传给
`adb install-multiple` 两次，adb 直接报错退出。`getSplitApks` 按出现顺序去重，
返回 **2** 个条目。

### 期望值

`getSplitApks` 返回的是**归档条目名**（不是解包后的路径）。两个条目在归档里
都真实存在，都能被 `ApkReader` 解析成包：

| 条目 | package | versionCode | 启动页 |
|---|---|---|---|
| `com.example.xapkfixture.apk` | `com.example.xapkfixture` | 12 | 有 |
| `config.fr.apk` | `com.example.xapkfixture` | — | 无（config split） |

### 一个没能做到的地方

原计划直接下载一个线上 XAPK，但 **APKPure 的下载端点对非浏览器客户端返回
403**（带浏览器 UA 也一样）。所以这个夹具的容器是按公开规范自己打的，
内层 APK 来自真实构建工具 —— 它能验证「清单解析 + 去重 + 条目真的可解析」，
但**不能**替代「下载一个线上 XAPK 再装」这一步。
