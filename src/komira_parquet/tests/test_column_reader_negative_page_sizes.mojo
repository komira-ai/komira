# `_read_and_decompress` (column_reader): a page whose declared compressed or
# decoded size is negative is refused before any read, under either codec; the
# header parser keeps a real chunk from reaching it, so it is called as the
# page reader would call it with such a header.
from std.testing import TestSuite, assert_equal, assert_raises

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet_api.types import CompressionCodec
from komira_parquet_codec.compression import compress, compress_bound
from komira_runtime_paths import test_tmpdir

from komira_parquet.column_reader import _read_and_decompress
from komira_parquet.file_reader import ParquetFileReader

comptime _Fs = LocalFs[NoopSink]


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


struct _Layout(Movable):
    var path: String
    var plain_at: Int
    var plain_len: Int
    var snappy_at: Int
    var snappy_len: Int

    def __init__(out self, path: String, a: Int, al: Int, b: Int, bl: Int):
        self.path = path
        self.plain_at = a
        self.plain_len = al
        self.snappy_at = b
        self.snappy_len = bl


def _file(name: String, values: List[UInt8]) raises -> _Layout:
    """Write the file: magic, the values as stored, the values SNAPPY, a
    footer of 16 bytes, its length, magic."""
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    var a = len(out)
    out.extend(values.copy())
    var comp = List[UInt8](length=compress_bound(CompressionCodec.SNAPPY, len(values)), fill=UInt8(0))
    comp.resize(compress(CompressionCodec.SNAPPY, Span(values), Span(comp)), UInt8(0))
    var b = len(out)
    out.extend(comp.copy())
    for i in range(16):
        out.append(UInt8(i))
    _le(out, 16, 4)
    out.extend([UInt8(0x50), UInt8(0x41), UInt8(0x52), UInt8(0x31)])
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()
    return _Layout(path, a, len(values), b, len(comp))


def _ints(n: Int, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        _le(out, i * 1000 - 7, width)
    return out^



def test_a_negative_page_size_is_refused() raises:
    var f = _file("negative_sizes.parquet", List[UInt8](length=40, fill=UInt8(3)))
    var reader = ParquetFileReader[_Fs].open(f.path)
    with assert_raises(contains="negative page size (compressed -1, uncompressed 40)"):
        _ = _read_and_decompress(reader, f.plain_at, CompressionCodec.UNCOMPRESSED, -1, 40)
    with assert_raises(contains="negative page size (compressed 40, uncompressed -5)"):
        _ = _read_and_decompress(reader, f.snappy_at, CompressionCodec.SNAPPY, 40, -5)


def test_a_page_of_sane_sizes_is_read_stored_and_decompressed() raises:
    var f = _file("sane_sizes.parquet", List[UInt8](length=40, fill=UInt8(3)))
    var reader = ParquetFileReader[_Fs].open(f.path)
    var stored = _read_and_decompress(reader, f.plain_at, CompressionCodec.UNCOMPRESSED, 40, 40)
    assert_equal(stored.len(), 40)
    assert_equal(Int(stored.read_u8_at(39)), 3)
    var inflated = _read_and_decompress(reader, f.snappy_at, CompressionCodec.SNAPPY, f.snappy_len, 40)
    assert_equal(inflated.len(), 40)
    assert_equal(Int(inflated.read_u8_at(0)), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
