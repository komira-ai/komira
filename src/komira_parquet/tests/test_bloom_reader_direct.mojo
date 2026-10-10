# =============================================================================
# parse_bloom_filter_header, load_bloom_filter and the hash-family detection.
#
# Bloom filters are built with komira_dynamic_filter's BloomFilter (the
# spec's split-block filter, xxHash64), and written into a file after a
# BloomFilterHeader encoded here from parquet-format's BloomFilter.md:
# 1 numBytes (i32), 2 algorithm (union, SPLIT_BLOCK = field 1), 3 hash
# (union, XXHASH = field 1), 4 compression (union, UNCOMPRESSED = field 1).
#
# What each test proves: the header is decoded field by field and the
# bitset starts where it ends; a filter is loaded only when the column chunk
# names its range, the algorithm is split-block, the bitset is uncompressed,
# numBytes is positive and the bitset fits the range; the loaded filter
# answers membership for what was inserted; every writer is read with
# xxHash64.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.byte_view import ByteView
from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily
from komira_parquet_api.metadata import ColumnMetaData
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet.thrift_compact import ThriftCompactReader
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.bloom_reader import (
    BloomFilterHeaderInfo,
    detect_hash_family,
    detect_hash_family_optional,
    load_bloom_filter,
    parse_bloom_filter_header,
)

comptime _Fs = LocalFs[NoopSink]


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _union(mut out: List[UInt8], delta: Int, variant: Int):
    """Field `prev + delta`: a union struct whose member `variant` is set
    (0: no member)."""
    out.append(UInt8((delta << 4) | 12))
    if variant > 0:
        out.append(UInt8((variant << 4) | 12))
        out.append(0x00)
    out.append(0x00)


def _header(
    num_bytes: Int,
    algorithm: Int = 1,
    hash: Int = 1,
    compression: Int = 1,
    num_bytes_type: Int = 5,
) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8((1 << 4) | num_bytes_type))
    _zz(out, num_bytes)
    _union(out, 1, algorithm)
    _union(out, 1, hash)
    _union(out, 1, compression)
    out.append(UInt8((1 << 4) | 5))  # field 5: unknown, skipped
    _zz(out, 1)
    out.append(0x00)
    return out^


def _bitset(values: List[Int64]) -> List[UInt8]:
    var bf = BloomFilter.create(1024, HashFamily.xxhash64())
    for i in range(len(values)):
        bf.insert_int64(values[i])
    var bits = bf.data.view_range_ro(0, bf.num_bytes).into_span()
    var out = List[UInt8](capacity=len(bits))
    for i in range(len(bits)):
        out.append(bits[i])
    return out^


struct _Bloomed(Movable):
    var path: String
    var offsets: List[Int]
    var lengths: List[Int]

    def __init__(out self, var path: String, var offsets: List[Int], var lengths: List[Int]):
        self.path = path^
        self.offsets = offsets^
        self.lengths = lengths^


def _file(name: String, blocks: List[List[UInt8]]) raises -> _Bloomed:
    """PAR1, each block at a recorded offset, an 8-byte footer, PAR1."""
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    var offsets = List[Int]()
    var lengths = List[Int]()
    for b in range(len(blocks)):
        offsets.append(len(out))
        lengths.append(len(blocks[b]))
        for i in range(len(blocks[b])):
            out.append(blocks[b][i])
    for _ in range(8):
        out.append(0x00)
    out.append(8)
    out.append(0)
    out.append(0)
    out.append(0)
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()
    return _Bloomed(path^, offsets^, lengths^)


def _meta(offset: Optional[Int], length: Optional[Int]) -> ColumnMetaData:
    return ColumnMetaData(
        type=ParquetType.INT64,
        encodings=List[Encoding](),
        path_in_schema=List[String](),
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=0,
        total_uncompressed_size=0,
        total_compressed_size=0,
        data_page_offset=0,
        bloom_filter_offset=offset,
        bloom_filter_length=length,
    )


def _block(var header: List[UInt8], bits: List[UInt8]) -> List[UInt8]:
    for i in range(len(bits)):
        header.append(bits[i])
    return header^


# ---- the header ------------------------------------------------------------------


def test_header_fields_and_where_the_bitset_starts() raises:
    var h = _header(1024)
    h.append(0xEE)  # the bitset's first byte
    var r = ThriftCompactReader(_view(Span(h)))
    r.prev_field_id = 4
    var info = parse_bloom_filter_header(r)
    assert_equal(info.num_bytes, 1024)
    assert_true(info.algorithm_ok)
    assert_true(info.hash_ok)
    assert_true(info.compression_ok)
    assert_equal(info.header_byte_length, len(h) - 1)
    assert_equal(r.pos, len(h) - 1)
    assert_equal(r.prev_field_id, 4)


def test_header_other_union_members_and_an_i64_num_bytes() raises:
    var h = _header(64, algorithm=2, hash=0, compression=3, num_bytes_type=6)
    var r = ThriftCompactReader(_view(Span(h)))
    var info = parse_bloom_filter_header(r)
    assert_equal(info.num_bytes, 64)
    assert_false(info.algorithm_ok)
    assert_false(info.hash_ok)
    assert_false(info.compression_ok)
    var default = BloomFilterHeaderInfo()
    assert_equal(default.num_bytes, 0)
    assert_false(default.algorithm_ok)


def test_header_loops_stop_after_64_fields() raises:
    # A union of 70 bool members and a header of 70 bool fields: each loop
    # reads at most 64 fields and returns.
    var u = List[UInt8]()
    u.append(UInt8((2 << 4) | 12))  # field 2: the algorithm union
    for _ in range(70):
        u.append(0x11)
    u.append(0x00)
    var r = ThriftCompactReader(_view(Span(u)))
    var info = parse_bloom_filter_header(r)
    assert_true(info.algorithm_ok)
    var many = List[UInt8](length=70, fill=0x51)
    var r2 = ThriftCompactReader(_view(Span(many)))
    _ = parse_bloom_filter_header(r2)
    assert_equal(r2.pos, 64)


# ---- load_bloom_filter -------------------------------------------------------------


def test_load_reads_the_filter_and_answers_membership() raises:
    var values: List[Int64] = [5, 6, 1000000007]
    var f = _file("bloom_ok.parquet", [_block(_header(1024), _bitset(values))])
    var reader = ParquetFileReader[_Fs].open(f.path)
    var bf = load_bloom_filter(reader, _meta(f.offsets[0], f.lengths[0]))
    assert_true(Bool(bf))
    assert_equal(bf.value().num_bytes, 1024)
    for i in range(len(values)):
        assert_true(bf.value().might_contain_int64(values[i]))
    assert_false(bf.value().might_contain_int64(424242))
    var fnv = load_bloom_filter(reader, _meta(f.offsets[0], f.lengths[0]), HashFamily.fnv1a())
    assert_true(fnv.value().hash_family.is_fnv1a())


def test_load_returns_none_for_every_unusable_filter() raises:
    var bits = _bitset([Int64(1)])
    var blocks: List[List[UInt8]] = [
        _block(_header(1024, algorithm=2), bits),
        _block(_header(1024, compression=2), bits),
        _block(_header(0), bits),
        _block(_header(-4), bits),
        _block(_header(4096), bits),  # more bytes than the range holds
        _block(_header(1024, hash=2), bits),  # hash not XXHASH: still loads
    ]
    var f = _file("bloom_bad.parquet", blocks)
    var reader = ParquetFileReader[_Fs].open(f.path)
    for i in range(5):
        var bf = load_bloom_filter(reader, _meta(f.offsets[i], f.lengths[i]))
        assert_false(Bool(bf), "block " + String(i))
    assert_true(Bool(load_bloom_filter(reader, _meta(f.offsets[5], f.lengths[5]))))
    # No range, half a range, or a range that is not positive: no filter.
    assert_false(Bool(load_bloom_filter(reader, _meta(None, None))))
    assert_false(Bool(load_bloom_filter(reader, _meta(f.offsets[0], None))))
    assert_false(Bool(load_bloom_filter(reader, _meta(None, f.lengths[0]))))
    assert_false(Bool(load_bloom_filter(reader, _meta(0, f.lengths[0]))))
    assert_false(Bool(load_bloom_filter(reader, _meta(f.offsets[0], 0))))
    # A range past the end of the file raises (the caller decides).
    var raised = False
    try:
        _ = load_bloom_filter(reader, _meta(f.offsets[0], 1 << 30))
    except e:
        raised = String(e).find("out of bounds") >= 0
    assert_true(raised)


def test_every_writer_is_read_with_xxhash64() raises:
    assert_true(detect_hash_family("parquet-cpp-arrow version 17.0.0").is_xxhash64())
    assert_true(detect_hash_family("").is_xxhash64())
    assert_true(detect_hash_family_optional(None).is_xxhash64())
    assert_true(detect_hash_family_optional(String("DuckDB")).is_xxhash64())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
