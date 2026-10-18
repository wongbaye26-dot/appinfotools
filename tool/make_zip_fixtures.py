#!/usr/bin/env python3
"""生成 ZIP 结构夹具（Zip64 / data descriptor / 中心目录撒谎 / deflate 损坏）。

    python3 tool/make_zip_fixtures.py

输出到 `test/fixtures/zip/`，每个文件 < 4 KiB，可以入库。

## 为什么要有这批夹具

`archive` 在本项目里是 **git 依赖**（`ref cb3a07c`），它对 Zip64 与 data
descriptor 的支持只能**实测**。更要紧的是：即使解析器支持这两种格式，也
不能推出「我们的有界解压在这两种格式上仍然有界」—— 那正是这批样本要证明的。

## 字节从哪来

- 主体一律由 Python 标准库 `zipfile` 生成（外部实现，不是手拼整个 ZIP）。
- `zip64_cd` / `zip64_eocd` / `cd_lie_*` / `garbage_deflate` 是在 `zipfile`
  产物上**按格式规范改指定字段**得到的。改动点逐条写在下面的函数里，没有
  任何一处是「照着我们解析器的实现改的」——否则就成了自证。
- `data_descriptor` 由 `zipfile` 写进**不可 seek** 的流得到：这种情形下
  Python 会置 flag bit 3 并在数据之后追加 descriptor，不是手工补的。
"""

import io
import os
import struct
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, '..', 'test', 'fixtures', 'zip'))

FIXED_DATE = (2020, 1, 1, 0, 0, 0)

EOCD_SIG = b'PK\x05\x06'
CD_SIG = b'PK\x01\x02'
ZIP64_EOCD_SIG = b'PK\x06\x06'
ZIP64_LOCATOR_SIG = b'PK\x06\x07'


def _zip_one(name, data, *, compress=zipfile.ZIP_DEFLATED):
    """用 zipfile 生成只含一个条目的归档，时间戳固定以保证可重现。"""
    buf = io.BytesIO()
    info = zipfile.ZipInfo(name, date_time=FIXED_DATE)
    info.compress_type = compress
    info.external_attr = 0o644 << 16
    with zipfile.ZipFile(buf, 'w') as zf:
        zf.writestr(info, data)
    return bytearray(buf.getvalue())


def _eocd_offset(data):
    pos = data.rfind(EOCD_SIG)
    assert pos >= 0, 'EOCD not found'
    return pos


def _cd_range(data):
    eocd = _eocd_offset(data)
    cd_size, cd_offset = struct.unpack('<II', data[eocd + 12:eocd + 20])
    assert data[cd_offset:cd_offset + 4] == CD_SIG
    return eocd, cd_offset, cd_size


def _rebuild(data, new_cd):
    """把中央目录换成 new_cd，并同步 EOCD 里的目录大小。"""
    eocd, cd_offset, _ = _cd_range(data)
    head = data[:cd_offset]
    tail = bytearray(data[eocd:])
    struct.pack_into('<I', tail, 12, len(new_cd))       # size of central directory
    struct.pack_into('<I', tail, 16, len(head))         # offset of central directory
    return head + new_cd + tail


def make_zip64_cd():
    """Zip64：中央目录里的三个 32 位字段置 0xFFFFFFFF，真实值放进 extra(0x0001)。

    规范（APPNOTE 4.5.3）：当某个 32 位字段放不下时，把它置 0xFFFFFFFF，
    并在 zip64 extra 里按「原始大小 / 压缩后大小 / 本地头偏移 / 起始磁盘号」
    的固定顺序补齐。这里三个都置位，extra 长度 24。
    """
    data = _zip_one('payload.bin', bytes(range(256)) * 2)
    _, cd_offset, cd_size = _cd_range(data)
    cd = bytearray(data[cd_offset:cd_offset + cd_size])
    assert len(cd) == cd_size and cd[0:4] == CD_SIG

    crc, csize, usize = struct.unpack('<III', cd[16:28])
    name_len, extra_len = struct.unpack('<HH', cd[28:32])
    lho = struct.unpack('<I', cd[42:46])[0]
    name = bytes(cd[46:46 + name_len])
    extra = bytes(cd[46 + name_len:46 + name_len + extra_len])
    comment = bytes(cd[46 + name_len + extra_len:])

    zip64_extra = struct.pack('<HHQQQ', 0x0001, 24, usize, csize, lho)
    new = bytearray(cd[0:16])                            # 到 date 为止
    new += struct.pack('<I', crc)                        # 16: crc32 保持真实
    new += struct.pack('<II', 0xFFFFFFFF, 0xFFFFFFFF)    # 20/24: csize / usize 哨兵
    new += struct.pack('<HHH', name_len, len(extra) + len(zip64_extra),
                       len(comment))
    new += cd[34:42]                                     # disk / attrs
    new += struct.pack('<I', 0xFFFFFFFF)                 # lho -> 哨兵
    new += name + extra + zip64_extra + comment
    return bytes(_rebuild(data, new))


def make_zip64_eocd():
    """Zip64：追加 Zip64 EOCD 记录 + 定位器，普通 EOCD 字段置哨兵。

    规范（APPNOTE 4.3.14 / 4.3.15）：Zip64 EOCD 记录紧接在中央目录之后，
    定位器固定 20 字节、紧接在普通 EOCD 之前，普通 EOCD 的条目数与目录
    偏移置 0xFFFF / 0xFFFFFFFF。
    """
    data = _zip_one('payload.bin', b'zip64-eocd-sample' * 8)
    eocd, cd_offset, cd_size = _cd_range(data)

    record = bytearray()
    record += ZIP64_EOCD_SIG
    record += struct.pack('<Q', 44)          # size of remaining record
    record += struct.pack('<HH', 45, 45)     # version made by / needed
    record += struct.pack('<II', 0, 0)       # disk / cd start disk
    record += struct.pack('<QQ', 1, 1)       # entries on disk / total
    record += struct.pack('<QQ', cd_size, cd_offset)

    head = data[:eocd]
    locator = bytearray()
    locator += ZIP64_LOCATOR_SIG
    locator += struct.pack('<I', 0)                  # disk with zip64 EOCD
    locator += struct.pack('<Q', len(head))          # offset of zip64 EOCD
    locator += struct.pack('<I', 1)                  # total disks

    tail = bytearray(data[eocd:])
    struct.pack_into('<HH', tail, 8, 0xFFFF, 0xFFFF)  # entries on disk / total
    struct.pack_into('<II', tail, 12, 0xFFFFFFFF, 0xFFFFFFFF)

    return bytes(head) + bytes(record) + bytes(locator) + bytes(tail)


class _UnseekableSink:
    """不可 seek 的输出流 —— zipfile 见到它就会改用 data descriptor。"""

    def __init__(self):
        self._buf = bytearray()

    def write(self, b):
        self._buf.extend(b)
        return len(b)

    def flush(self):
        pass

    def tell(self):
        return len(self._buf)

    def seekable(self):
        return False

    def getvalue(self):
        return bytes(self._buf)


def make_data_descriptor():
    """flag bit 3 + 数据后追加 descriptor（CRC / 压缩后大小 / 原始大小）。

    不可 seek 时写头的时候还不知道尺寸，所以本地头里这三个字段是 0，
    真实值只能写在数据之后的 descriptor 里 —— 中央目录仍然有权威值。
    """
    sink = _UnseekableSink()
    info = zipfile.ZipInfo('streamed.bin', date_time=FIXED_DATE)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    with zipfile.ZipFile(sink, 'w') as zf:
        zf.writestr(info, bytes(range(256)) * 16)
    data = sink.getvalue()
    _, cd_offset, cd_size = _cd_range(bytearray(data))
    flags = struct.unpack('<H', data[cd_offset + 8:cd_offset + 10])[0]
    assert flags & 0x08, 'zipfile 没有置 data descriptor 标志'
    return data


def make_zeros_1m():
    """1 MiB 全零、正常中心目录 —— 用来证明「上限是它拦下来的」。"""
    return bytes(_zip_one('zeros.bin', b'\x00' * (1024 * 1024)))


def make_cd_lie_uncompressed():
    """中心目录谎报原始大小：真实 1 MiB，声明 1024。

    只改 `uncompressedSize`（偏移 24），CRC 与压缩后大小保持真实 —— 这样
    解压仍然能成功，唯一异常就是「声明值和实际产出不符」。审计 P1-1 的
    伪造样本正是这个形态。
    """
    data = bytearray(make_zeros_1m())
    _, cd_offset, _ = _cd_range(data)
    struct.pack_into('<I', data, cd_offset + 24, 1024)
    return bytes(data)


def make_cd_lie_compressed():
    """中心目录谎报压缩后大小（真值的一半）。

    `ZipFile.read` 按中心目录的 compressedSize 取字节，于是 deflate 流被
    截断 —— 必须表现为「解压失败」，而不是悄悄返回半截数据。
    """
    data = bytearray(make_zeros_1m())
    _, cd_offset, _ = _cd_range(data)
    csize = struct.unpack('<I', data[cd_offset + 20:cd_offset + 24])[0]
    struct.pack_into('<I', data, cd_offset + 20, csize // 2)
    return bytes(data)


def make_garbage_deflate():
    """压缩数据被替换成等长的垃圾字节（尺寸与 CRC 声明都不变）。"""
    data = bytearray(make_zeros_1m())
    _, cd_offset, _ = _cd_range(data)
    csize = struct.unpack('<I', data[cd_offset + 20:cd_offset + 24])[0]
    local = 30  # 本地头固定部分长度；文件名 `zeros.bin` 9 字节
    name_len, extra_len = struct.unpack('<HH', data[26:30])
    start = local + name_len + extra_len
    assert csize == struct.unpack('<I', data[18:22])[0]
    data[start:start + csize] = bytes([0x5A] * csize)
    return bytes(data)


def make_truncated_tail():
    """砍掉 EOCD 尾部：归档结构不完整，连中央目录都读不到。"""
    data = make_zeros_1m()
    return data[:len(data) - 10]


FIXTURES = {
    'zip64_cd.zip': make_zip64_cd,
    'zip64_eocd.zip': make_zip64_eocd,
    'data_descriptor.zip': make_data_descriptor,
    'zeros_1m.zip': make_zeros_1m,
    'cd_lie_uncompressed.zip': make_cd_lie_uncompressed,
    'cd_lie_compressed.zip': make_cd_lie_compressed,
    'garbage_deflate.zip': make_garbage_deflate,
    'truncated_tail.zip': make_truncated_tail,
}


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, builder in FIXTURES.items():
        payload = builder()
        path = os.path.join(OUT_DIR, name)
        with open(path, 'wb') as fp:
            fp.write(payload)
        print(f'{name:28s} {len(payload):7d} bytes')


if __name__ == '__main__':
    main()
