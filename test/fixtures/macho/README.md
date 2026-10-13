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
