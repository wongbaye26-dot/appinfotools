# hash 夹具

`file_hash_test.dart` 用的哈希夹具。期望值全部来自**系统工具**，不从本项目
代码取 —— 拿自己的输出当期望值等于什么都没验证。

## `hello.txt`

28 字节，内容（注意结尾有换行）：

```
AppInfoTool hash fixture v1
```

生成命令：

```sh
printf 'AppInfoTool hash fixture v1\n' > hello.txt
```

独立核对的期望值（macOS / BSD 工具）：

```sh
md5 -q hello.txt                  # 45d5acedcada22eb286b563499399049
shasum -a 1 hello.txt             # e72e1f8c07a6d76b0bea699f3f452f47d673d85d
shasum -a 256 hello.txt           # 0f8bab91b80cbbdcb2884760a5e427f7fdfa7cc2c89af7a8d85c31069d100568
```

## 大文件（不入库）

10 MiB + 12345 字节（10498105 字节），由测试用同一个公式**确定性生成**到临时
目录，不占仓库体积：

```python
n = 10 * 1024 * 1024 + 12345   # 跨过 4 MiB 分块边界，且不是分块整数倍
data = bytes((i % 251) for i in range(n))
```

Dart 侧的等价实现见 `file_hash_test.dart` 的 `bigFixtureBytes()`。

独立核对的期望值：

```sh
md5 -q big.bin        # 42cbf8aac4772877d370e2025db56eac
shasum -a 1 big.bin   # 2c11da67dbe8db694678531e72222b094b694cb6
shasum -a 256 big.bin # 9fd418adf8f2b4a29dace206fb5629e43a27040db5b5ec517c8666f09f107a6d
```

为什么要两种规模：小文件落在单个 4 MiB 分块内，大文件跨分块且**不是分块大小
的整数倍** —— 尾块处理错了只会在大文件上暴露。
