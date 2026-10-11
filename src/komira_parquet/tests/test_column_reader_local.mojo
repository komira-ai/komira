# Tests of `column_reader` over a file on the local file system: a PLAIN page
# of INT32, INT64, FLOAT and DOUBLE values read from its byte range, stored
# UNCOMPRESSED (the read buffer aliased as the array) and SNAPPY (decompressed
# into the array's buffer); a non-PLAIN encoding refused; the raw bytes of a
# range returned as stored; and a range that holds fewer values than asked
# refused. The file is the four magic bytes, the pages, an arbitrary footer,
# its length and the magic again: the reader opens it without parsing the
# footer.
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet_api.types import CompressionCodec, Encoding
from komira_parquet_codec.compression import compress, compress_bound
from komira_runtime_paths import test_tmpdir

from komira_parquet.column_reader import (
    read_column_float32,
    read_column_float64,
    read_column_int32,
    read_column_int64,
    read_column_int64_direct,
    read_raw_page_data,
)
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


def test_int32_and_int64_stored_and_snappy() raises:
    var f32 = _file("i32.parquet", _ints(50, 4))
    var r = ParquetFileReader[_Fs].open(f32.path)
    var a = read_column_int32(r, f32.plain_at, 50, Encoding.PLAIN, CompressionCodec.UNCOMPRESSED, f32.plain_len, f32.plain_len)
    var b = read_column_int32(r, f32.snappy_at, 50, Encoding.PLAIN, CompressionCodec.SNAPPY, f32.snappy_len, f32.plain_len)
    assert_equal(a.length, 50)
    assert_equal(b.length, 50)
    for i in range(50):
        assert_equal(Int(a.get_typed[Int32](i)), i * 1000 - 7)
        assert_equal(Int(b.get_typed[Int32](i)), i * 1000 - 7)
    var f64 = _file("i64.parquet", _ints(33, 8))
    var r64 = ParquetFileReader[_Fs].open(f64.path)
    var c = read_column_int64(r64, f64.snappy_at, 33, Encoding.PLAIN, CompressionCodec.SNAPPY, f64.snappy_len, f64.plain_len)
    var d = read_column_int64_direct(r64, f64.plain_at, 33, CompressionCodec.UNCOMPRESSED, f64.plain_len, f64.plain_len)
    assert_equal(Int(c.get_typed[Int64](32)), 32 * 1000 - 7)
    assert_equal(Int(d.get_typed[Int64](1)), 993)


def test_float_and_double() raises:
    var fb = List[UInt8]()
    var db = List[UInt8]()
    for i in range(10):
        _le(fb, Int(bitcast[DType.uint32](Float32(i) * 0.5)), 4)
        _le(db, Int(bitcast[DType.uint64](Float64(i) * -0.25)), 8)
    var ff = _file("f32.parquet", fb)
    var rf = ParquetFileReader[_Fs].open(ff.path)
    var x = read_column_float32(rf, ff.snappy_at, 10, Encoding.PLAIN, CompressionCodec.SNAPPY, ff.snappy_len, ff.plain_len)
    assert_equal(x.get_typed[Float32](3), Float32(1.5))
    var fd = _file("f64.parquet", db)
    var rd = ParquetFileReader[_Fs].open(fd.path)
    var y = read_column_float64(rd, fd.plain_at, 10, Encoding.PLAIN, CompressionCodec.UNCOMPRESSED, fd.plain_len, fd.plain_len)
    assert_equal(y.get_typed[Float64](9), -2.25)


def test_raw_bytes_and_refusals() raises:
    var f = _file("raw.parquet", _ints(8, 4))
    var r = ParquetFileReader[_Fs].open(f.path)
    var raw = read_raw_page_data(r, f.snappy_at, f.snappy_len)
    assert_equal(raw.len(), f.snappy_len, "as stored, not decompressed")
    with assert_raises(contains="only PLAIN encoding supported"):
        _ = read_column_int32(r, f.plain_at, 8, Encoding.RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED, 32, 32)
    with assert_raises(contains="but the page buffer holds only 32 bytes"):
        _ = read_column_int32(r, f.plain_at, 9, Encoding.PLAIN, CompressionCodec.UNCOMPRESSED, 32, 32)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
