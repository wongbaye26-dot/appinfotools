# LZFSE 夹具

每个 `.lzfse` 都是 macOS 系统库 `libcompression`（`COMPRESSION_LZFSE`）
**真实压缩**的产物；同名的 `.bin` 是压缩前的原始字节。

所以「解码 `.lzfse` 得到 `.bin`」这条断言实际上在说：
**我们的纯 Dart 实现与 Apple 自己的实现逐字节一致**。

## 生成命令

`make_fixtures.c` 是一个 40 行的 CLI，只调 `compression_encode_buffer`：

```sh
# 1) 编出参考编码器（macOS 自带 libcompression，无需额外依赖）
clang -O2 -o comp make_fixtures.c -lcompression

# 2) 生成夹具（各 .bin 的内容见 make_fixtures.c 对应的 Python 脚本；
#    随机数据用固定种子 20261019，可复现）
./comp 2 zeros.bin zeros.lzfse
./comp 2 repeated-text.bin repeated-text.lzfse
./comp 2 incompressible.bin incompressible.lzfse
./comp 2 pixel-like.bin pixel-like.lzfse
./comp 2 multi-block.bin multi-block.lzfse
./comp 2 empty.bin empty.lzfse
```

| 夹具 | 原始字节 | 压缩后 | 覆盖什么 |
|---|---:|---:|---|
| `empty` | 0 | 12 | 只有 `bvx$` 结束块 |
| `zeros` | 8,192 | 151 | 极高压缩比（54:1）、M 值取到上限 2359 |
| `repeated-text` | 9,000 | 213 | 文本重复 |
| `incompressible` | 4,096 | 4,327 | 压不小（输出比输入还大） |
| `pixel-like` | 16,896 | 13,940 | 类 BGRA 像素：渐变 + 少量噪声 |
| `multi-block` | 95,105 | 11,982 | **跨多个块**，且回溯跨块 |

## 已被证明到什么程度

除了这 6 个夹具，同一套解码器还解过 `Chess.app` 的 1024×1024 图标
（3 个 LZFSE 块、**2,086,192 字节**），并与 Apple 参考实现
（[lzfse](https://github.com/lzfse/lzfse) 开源库编译成 CLI）的输出做了
逐字节比对：**IDENTICAL**。

那个样本 2 MB，不适合入库，所以这里放小夹具。

## 不支持的块类型

| 块 | 处理 |
|---|---|
| `bvx1` | 明确报 `block.unsupported_v1` —— 没有工具产出它，也没有样本可验证 |
| `bvxn`（LZVN） | 明确报 `block.unsupported_lzvn` —— 实测 951 张真实光栅图里 0 张用它 |

不猜实现：凭猜写出来的解码器会「能跑但结果错」，那是最坏的一类 bug。

## 顺带记下的两个格式事实

1. **`packed_fields` 在偏移 8**（`u32 magic` + `u32 n_raw_bytes` 之后，结构体是
   packed）。我一开始按 12 算，读出 `header_size=1095911234` 这种值 —— 用
   「`header_size + litpay + lmdpay` 必须等于块长」这条约束反解才确认。
2. **`bvx$` 只有 4 字节**，没有附加的长度字段。把它当 8 字节会让所有末尾块
   的对齐判断错位。
