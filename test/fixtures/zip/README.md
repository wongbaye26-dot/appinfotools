# ZIP 结构样本

生成命令（在仓库根目录）：

```
python3 tool/make_zip_fixtures.py
```

主体由 Python 标准库 `zipfile` 产出，再按 ZIP 规范改指定字段。**没有手拼整个
ZIP** —— 手拼的样本带着与解析器相同的错误假设，测的是「两边一起错」。

## 期望值的独立来源

每个样本都用两个**外部实现**核对过，期望值不从本项目的解析器取：

```
unzip -t <file>            # Info-ZIP
python3 -c "import zipfile; ..."   # CPython 的 zipfile
```

## 合法样本

| 文件 | 结构 | 独立核对结果 |
|---|---|---|
| `zip64_cd.zip` | 中央目录的 `compressedSize` / `uncompressedSize` / `localHeaderOffset` 全置 `0xFFFFFFFF`，真实值放进 Zip64 extra field（id `0x0001`，24 字节） | `unzip -t` OK；`zipfile` 读出 `payload.bin` 512 字节；`flag_bits=0x0000` |
| `zip64_eocd.zip` | 中央目录后追加 Zip64 EOCD 记录（56 字节）+ 定位器（20 字节），普通 EOCD 的条目数/偏移置哨兵 | `unzip -t` OK；`zipfile` 读出 `payload.bin` 136 字节 |
| `data_descriptor.zip` | 写进**不可 seek** 的流，于是 Python 置 flag bit 3 并在数据后追加 descriptor；本地头的 CRC/尺寸是 0 | `unzip -t` OK；`zipfile` 读出 `streamed.bin` 4096 字节；`flag_bits=0x0008` |
| `zeros_1m.zip` | 1 MiB 全零、deflate、中心目录诚实 | `unzip -t` OK；`zipfile` 读出 1,048,576 字节 |

## 故意损坏的样本

| 文件 | 损坏点 | 外部核对结果 |
|---|---|---|
| `cd_lie_uncompressed.zip` | 中央目录 `uncompressedSize` 改成 1024（真实 1 MiB）。CRC 与压缩后大小不动 —— 解压能成功，唯一异常是声明与实际不符 | `unzip -t` 认为 OK（损坏点在「声明」而不是数据） |
| `cd_lie_compressed.zip` | 中央目录 `compressedSize` 改成真值的一半 —— 按 CD 取字节，deflate 流被截断 | `unzip -t` 认为 OK（它按 CD 取字节，不看内容长度） |
| `garbage_deflate.zip` | 压缩数据整段替换成等长的 `0x5A`，尺寸与 CRC 声明不变 | `unzip -t` 报 `invalid compressed data to inflate` |
| `truncated_tail.zip` | 砍掉末尾 10 字节，EOCD 不完整 | `unzip -t` 报 `cannot find zipfile directory` |

## 这批样本要证明什么

**「解析器支持某种格式」不能推出「我们的有界读取在那种格式上仍然有界」。**
Zip64 与 data descriptor 恰好都改动了「尺寸从哪来」：

- Zip64 把真实尺寸挪进 extra field，中央目录里只剩哨兵；
- data descriptor 把真实尺寸挪到数据之后，本地头里是 0。

有界读取的三道闸全都依赖 `ArchiveFile.size` 与 `ZipFile.compressedSize`。如果
这两个字段在某种形态下变成 0 或哨兵，闸 1、闸 2 就会失效，只剩闸 3（真实产出）
兜底 —— 那就必须证明闸 3 真的兜住了。对应断言见
`test/zip_format_support_test.dart`。
