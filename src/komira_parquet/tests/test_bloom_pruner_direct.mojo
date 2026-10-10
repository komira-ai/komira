# =============================================================================
# can_prune_row_group_by_bloom.
#
# A file holds one bloom filter per column, built with komira_dynamic_filter
# the way parquet-format's BloomFilter.md defines the hash input: an INT64 as
# its 8 little-endian bytes, an INT32 as its 4 little-endian bytes, a
# BYTE_ARRAY as its bytes. The footer metadata is built as structs.
#
# What each test proves:
#   * an EQ literal absent from the column's filter prunes; a present one
#     does not; so do AND (either side absent) and OR (both absent);
#   * INT32 is probed with the hash of its 4 bytes. The probe hashed the
#     8-byte widening, which a spec writer never inserts, so a row group
#     holding the value was pruned;
#   * the column is found among the leaves only: in a schema with a group,
#     the name of a later top-level leaf resolved to the wrong column (its
#     schema position, not its leaf position), and that column's filter
#     pruned a row group holding the value. A group's name and a nested
#     leaf's name match nothing;
#   * everything else is conservative (no prune): another operator, a
#     literal of the wrong type or out of INT32 range, a column with no
#     filter or of a type with no probe, a name not in the schema, a filter
#     that cannot be read or decoded.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily
from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    RowGroup,
    SchemaElement,
)
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_plan_expr.expr import BIN_AND, BIN_EQ, BIN_NE, BIN_OR, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.bloom_pruner import can_prune_row_group_by_bloom

comptime _Fs = LocalFs[NoopSink]


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _header(num_bytes: Int, algorithm: Int = 1) -> List[UInt8]:
    var out: List[UInt8] = [0x15]
    _uleb(out, num_bytes << 1)
    for f in range(3):
        out.append(0x1C)
        out.append(UInt8(((algorithm if f == 0 else 1) << 4) | 12))
        out.append(0x00)
        out.append(0x00)
    out.append(0x00)
    return out^


def _le(v: Int64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(width):
        out.append(UInt8((v >> Int64(8 * i)) & 0xFF))
    return out^


def _filter_bytes(var bf: BloomFilter, algorithm: Int = 1) -> List[UInt8]:
    var out = _header(bf.num_bytes, algorithm)
    var bits = bf.data.view_range_ro(0, bf.num_bytes).into_span()
    for i in range(len(bits)):
        out.append(bits[i])
    return out^


def _int64_filter(values: List[Int64]) -> List[UInt8]:
    var bf = BloomFilter.create(1024, HashFamily.xxhash64())
    for i in range(len(values)):
        var le = _le(values[i], 8)
        bf.insert_bytes(Span(le))
    return _filter_bytes(bf^)


def _int32_filter(values: List[Int64]) -> List[UInt8]:
    var bf = BloomFilter.create(1024, HashFamily.xxhash64())
    for i in range(len(values)):
        var le = _le(values[i], 4)
        bf.insert_bytes(Span(le))
    return _filter_bytes(bf^)


def _string_filter(values: List[String]) -> List[UInt8]:
    var bf = BloomFilter.create(1024, HashFamily.xxhash64())
    for i in range(len(values)):
        var s = values[i].copy()
        bf.insert_bytes(s.as_bytes())
    return _filter_bytes(bf^)


struct _Fixture(Movable):
    var path: String
    var offsets: List[Int]
    var lengths: List[Int]

    def __init__(out self, var path: String, var offsets: List[Int], var lengths: List[Int]):
        self.path = path^
        self.offsets = offsets^
        self.lengths = lengths^


def _write(name: String, blocks: List[List[UInt8]]) raises -> _Fixture:
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
    return _Fixture(path^, offsets^, lengths^)


def _chunk(t: ParquetType, offset: Optional[Int], length: Optional[Int]) -> ColumnChunk:
    var meta = ColumnMetaData(
        type=t,
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
    return ColumnChunk(file_offset=0, meta_data=meta^)


def _leaf(name: String, t: ParquetType) -> SchemaElement:
    return SchemaElement(name=name, type=t)


def _group(name: String, children: Int) -> SchemaElement:
    return SchemaElement(name=name, num_children=children)


def _eq(col: String, var lit: ScalarValue) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(col), Expr.literal(lit^))


def _footer(var schema: List[SchemaElement], var columns: List[ColumnChunk]) -> FileMetaData:
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=columns^, total_byte_size=0, num_rows=1))
    return FileMetaData(version=2, schema=schema^, num_rows=1, row_groups=groups^)


# Columns: a INT64 {5, 6}, b INT32 {7}, s BYTE_ARRAY {"apple", ""},
# f FLOAT (a filter it cannot probe), n INT64 without a filter, d INT64 whose
# filter header names another algorithm, e INT64 whose range runs past the
# file.
def _flat() raises -> Tuple[_Fixture, FileMetaData]:
    var blocks: List[List[UInt8]] = [
        _int64_filter([Int64(5), Int64(6)]),
        _int32_filter([Int64(7)]),
        _string_filter([String("apple"), String("")]),
        _int64_filter([Int64(1)]),
        _filter_bytes(BloomFilter.create(1024, HashFamily.xxhash64()), algorithm=2),
    ]
    var fx = _write("prune_flat.parquet", blocks)
    var schema: List[SchemaElement] = [
        _group("schema", 8),
        _leaf("a", ParquetType.INT64),
        _leaf("b", ParquetType.INT32),
        _leaf("s", ParquetType.BYTE_ARRAY),
        _leaf("f", ParquetType.FLOAT),
        _leaf("n", ParquetType.INT64),
        _leaf("d", ParquetType.INT64),
        _leaf("e", ParquetType.INT64),
        _leaf("ghost", ParquetType.INT64),  # a leaf with no column chunk
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, fx.offsets[0], fx.lengths[0]),
        _chunk(ParquetType.INT32, fx.offsets[1], fx.lengths[1]),
        _chunk(ParquetType.BYTE_ARRAY, fx.offsets[2], fx.lengths[2]),
        _chunk(ParquetType.FLOAT, fx.offsets[3], fx.lengths[3]),
        _chunk(ParquetType.INT64, None, None),
        _chunk(ParquetType.INT64, fx.offsets[4], fx.lengths[4]),
        _chunk(ParquetType.INT64, fx.offsets[0], 1 << 30),
    ]
    var md = _footer(schema^, columns^)
    return (fx^, md^)


def _prunes(fx: _Fixture, md: FileMetaData, var e: Expr) raises -> Bool:
    var reader = ParquetFileReader[_Fs].open(fx.path)
    return can_prune_row_group_by_bloom(reader, md.row_groups[0], md, e)


def test_eq_on_int64_strings_and_both_operand_orders() raises:
    var t = _flat()
    ref fx = t[0]
    ref md = t[1]
    assert_true(_prunes(fx, md, _eq("a", ScalarValue.from_int64(99))))
    assert_false(_prunes(fx, md, _eq("a", ScalarValue.from_int64(5))))
    var reversed = Expr.binary(BIN_EQ, Expr.literal(ScalarValue.from_int64(99)), Expr.col_ref("a"))
    assert_true(_prunes(fx, md, reversed^))
    assert_true(_prunes(fx, md, _eq("s", ScalarValue.from_string("pear"))))
    assert_false(_prunes(fx, md, _eq("s", ScalarValue.from_string("apple"))))
    assert_false(_prunes(fx, md, _eq("s", ScalarValue.from_string(""))))


def test_int32_is_probed_with_its_four_byte_hash() raises:
    var t = _flat()
    ref fx = t[0]
    ref md = t[1]
    # 7 is in the INT32 filter as 4 bytes: probing its 8-byte widening found
    # nothing and pruned this row group.
    assert_false(_prunes(fx, md, _eq("b", ScalarValue.from_int64(7))))
    assert_true(_prunes(fx, md, _eq("b", ScalarValue.from_int64(8))))
    assert_false(_prunes(fx, md, _eq("b", ScalarValue.from_int64(Int64(1) << 40))))
    assert_false(_prunes(fx, md, _eq("b", ScalarValue.from_int64(-(Int64(1) << 40)))))


def test_wrong_literal_types_and_unprobed_columns_are_conservative() raises:
    var t = _flat()
    ref fx = t[0]
    ref md = t[1]
    assert_false(_prunes(fx, md, _eq("a", ScalarValue.from_string("x"))))
    assert_false(_prunes(fx, md, _eq("b", ScalarValue.from_string("x"))))
    assert_false(_prunes(fx, md, _eq("s", ScalarValue.from_int64(1))))
    assert_false(_prunes(fx, md, _eq("f", ScalarValue.from_float(2.0))))
    assert_false(_prunes(fx, md, _eq("n", ScalarValue.from_int64(99))))
    assert_false(_prunes(fx, md, _eq("d", ScalarValue.from_int64(99))))
    assert_false(_prunes(fx, md, _eq("e", ScalarValue.from_int64(99))))
    assert_false(_prunes(fx, md, _eq("ghost", ScalarValue.from_int64(99))))
    assert_false(_prunes(fx, md, _eq("missing", ScalarValue.from_int64(99))))


def test_other_shapes_are_conservative() raises:
    var t = _flat()
    ref fx = t[0]
    ref md = t[1]
    var ne = Expr.binary(BIN_NE, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(99)))
    assert_false(_prunes(fx, md, ne^))
    assert_false(_prunes(fx, md, Expr.col_ref("a")))
    var cols = Expr.binary(BIN_EQ, Expr.col_ref("a"), Expr.col_ref("n"))
    assert_false(_prunes(fx, md, cols^))
    var lits = Expr.binary(
        BIN_EQ, Expr.literal(ScalarValue.from_int64(1)), Expr.literal(ScalarValue.from_int64(2))
    )
    assert_false(_prunes(fx, md, lits^))


def test_and_and_or() raises:
    var t = _flat()
    ref fx = t[0]
    ref md = t[1]
    var hit = ScalarValue.from_int64(5)
    var miss = ScalarValue.from_int64(99)
    assert_true(_prunes(fx, md, Expr.binary(BIN_AND, _eq("a", miss.copy()), _eq("a", hit.copy()))))
    assert_true(_prunes(fx, md, Expr.binary(BIN_AND, _eq("a", hit.copy()), _eq("a", miss.copy()))))
    assert_false(_prunes(fx, md, Expr.binary(BIN_AND, _eq("a", hit.copy()), _eq("a", hit.copy()))))
    assert_true(_prunes(fx, md, Expr.binary(BIN_OR, _eq("a", miss.copy()), _eq("a", miss.copy()))))
    assert_false(_prunes(fx, md, Expr.binary(BIN_OR, _eq("a", hit.copy()), _eq("a", miss.copy()))))
    assert_false(_prunes(fx, md, Expr.binary(BIN_OR, _eq("a", miss.copy()), _eq("a", hit.copy()))))


def test_columns_are_resolved_among_leaves() raises:
    # schema: root(3) -> g(1) -> x; b; c. Leaves in chunk order: g.x, b, c.
    # 7 is in b's filter and not in c's: a lookup by schema position took
    # "b" (position 3) for leaf 2, c, and pruned on c's filter.
    var blocks: List[List[UInt8]] = [
        _int64_filter([Int64(1)]),
        _int64_filter([Int64(7)]),
        _int64_filter([Int64(9)]),
    ]
    var fx = _write("prune_nested.parquet", blocks)
    var schema: List[SchemaElement] = [
        _group("schema", 3),
        _group("g", 1),
        _leaf("x", ParquetType.INT64),
        _leaf("b", ParquetType.INT64),
        _leaf("c", ParquetType.INT64),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, fx.offsets[0], fx.lengths[0]),
        _chunk(ParquetType.INT64, fx.offsets[1], fx.lengths[1]),
        _chunk(ParquetType.INT64, fx.offsets[2], fx.lengths[2]),
    ]
    var md = _footer(schema^, columns^)
    assert_false(_prunes(fx, md, _eq("b", ScalarValue.from_int64(7))))
    assert_true(_prunes(fx, md, _eq("b", ScalarValue.from_int64(9))))
    assert_true(_prunes(fx, md, _eq("c", ScalarValue.from_int64(7))))
    # A group's name and a nested leaf's name are not top-level columns.
    assert_false(_prunes(fx, md, _eq("g", ScalarValue.from_int64(5))))
    assert_false(_prunes(fx, md, _eq("x", ScalarValue.from_int64(5))))
    var empty = _footer(List[SchemaElement](), List[ColumnChunk]())
    assert_false(_prunes(fx, empty, _eq("b", ScalarValue.from_int64(9))))
    # A root that declares fewer children than follow it: elements after its
    # last child belong to no group and are not top-level columns.
    var short_root: List[SchemaElement] = [
        _group("schema", 1),
        _leaf("a", ParquetType.INT64),
        _leaf("b", ParquetType.INT64),
    ]
    var two: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, fx.offsets[1], fx.lengths[1]),
        _chunk(ParquetType.INT64, fx.offsets[2], fx.lengths[2]),
    ]
    var malformed = _footer(short_root^, two^)
    assert_true(_prunes(fx, malformed, _eq("a", ScalarValue.from_int64(9))))
    assert_false(_prunes(fx, malformed, _eq("b", ScalarValue.from_int64(1))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
