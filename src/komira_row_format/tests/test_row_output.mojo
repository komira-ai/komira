# =============================================================================
# `komira_row_format.row_output` and `row_sink`: the RowBlocks -> RecordBatch
# bridge, and `RowSink.accept_row_blocks`'s default body.
# =============================================================================
#
# WHAT THIS PROVES
# ----------------
# `bridge_row_output_to_record_batch` turns the rows of one or more RowBlocks
# into one Arrow column per output column, in block order. Its oracle is the
# row format's documented layout, placed by hand: fixed cells little-endian at
# their offsets, a string cell an 8-byte `(length << 32) | offset` descriptor
# into the block's own var heap (written by `write_var_string_cell`), and the
# validity bitmap bit `col & 7` of byte `col >> 3`, 1 = NULL. The bridge must
# turn a set bit into a CLEARED Arrow validity bit (Arrow: 1 = valid) at the
# row's position in the whole output, not within its block.
#
# The fixture has two blocks (2 rows, then 7: 9 rows in all, one past a byte
# of the Arrow bitmap) with nulls only in the second block, among them its last
# row (output row 8, the ninth bit), so a row index that restarts per block or
# a bitmap one bit short reads a different row. Each block's var heap starts
# at offset 0, so a bridge that read the strings of block B from block A's heap
# returns block A's bytes. Columns without a null must come out with no
# validity bitmap at all.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_row_format.row_block import (
    DT_F32,
    DT_F64,
    DT_I32,
    DT_I64,
    DT_STRING,
    DT_U8,
    RowBlock,
)
from komira_row_format.row_output import (
    RowOutput,
    RowOutputLayout,
    bridge_row_output_to_record_batch,
)
from komira_row_format.row_sink import RowSink


# Row layout: i64 @0 (8), i32 @8 (4), f64 @12 (8, unaligned), f32 @20 (4),
# string descriptor @24 (8), validity @32 (1 byte: 5 columns). Stride 33.
comptime _STRIDE = 33
comptime _VALIDITY = 32


def _put_le(mut rb: RowBlock, row: Int, off: Int, v: UInt64, n: Int):
    """The low `n` bytes of `v`, least significant first, one byte at a time."""
    for i in range(n):
        rb.write_fixed[DType.uint8](
            row, off + i, UInt8((v >> UInt64(8 * i)) & 0xFF)
        )


def _zero_rows(mut rb: RowBlock, n: Int, stride: Int):
    for r in range(n):
        for off in range(stride):
            rb.write_fixed[DType.uint8](r, off, 0)


def _set_null(mut rb: RowBlock, row: Int, col: Int):
    """Set the NULL bit by hand: bit `col & 7` of byte `col >> 3`."""
    var off = _VALIDITY + (col >> 3)
    var cur = rb.read_fixed[DType.uint8](row, off)
    rb.write_fixed[DType.uint8](row, off, cur | (UInt8(1) << UInt8(col & 7)))


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _layout(has_validity: Bool) -> RowOutputLayout:
    var offs: List[Int] = [0, 8, 12, 20, 24]
    var tags: List[UInt8] = [DT_I64, DT_I32, DT_F64, DT_F32, DT_STRING]
    return RowOutputLayout(offs^, tags^, _VALIDITY, has_validity)


# The 9 output rows. Block A holds rows 0-1, block B rows 2-8.
def _i64_vals() -> List[Int64]:
    return [-2, 0x0102030405060708, 3, 4, 5, -6, 7, 8, Int64.MIN]


def _i32_vals() -> List[Int32]:
    return [-2, 0x01020304, 30, 40, 50, -60, 70, 80, Int32.MAX]


def _f64_bits() -> List[UInt64]:
    # IEEE-754 binary64 bit patterns of `_f64_vals`, all exact.
    return [
        0x4002000000000000,  # 2.25
        0xC00C000000000000,  # -3.5
        0x3FE0000000000000,  # 0.5
        0x3FF0000000000000,  # 1.0
        0x8000000000000000,  # -0.0
        0x4000000000000000,  # 2.0
        0x4010000000000000,  # 4.0
        0x4020000000000000,  # 8.0
        0xC000000000000000,  # -2.0 (NULL below)
    ]


def _f64_vals() -> List[Float64]:
    return [2.25, -3.5, 0.5, 1.0, -0.0, 2.0, 4.0, 8.0, -2.0]


def _f32_bits() -> List[UInt64]:
    return [
        0xBFC00000,  # -1.5
        0x3F000000,  # 0.5
        0x40000000,  # 2.0
        0x40400000,  # 3.0
        0x40800000,  # 4.0
        0x40A00000,  # 5.0
        0x40C00000,  # 6.0
        0x40E00000,  # 7.0
        0x41000000,  # 8.0
    ]


def _f32_vals() -> List[Float32]:
    return [-1.5, 0.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]


def _str_vals() -> List[String]:
    # Row 2 is NULL (its payload is still written: the bridge must not read
    # it). Row 0 and row 2 both start at heap offset 0 of their own block.
    return ["héllo", "", "BBBBB", "c", "dd", "", "eee", "f", "gg"]


def _fill(mut rb: RowBlock, first: Int, n: Int) raises:
    var i64s = _i64_vals()
    var i32s = _i32_vals()
    var f64b = _f64_bits()
    var f32b = _f32_bits()
    var strs = _str_vals()
    for r in range(n):
        var g = first + r
        _put_le(rb, r, 0, UInt64(i64s[g]), 8)
        _put_le(rb, r, 8, UInt64(i32s[g].cast[DType.uint32]()), 4)
        _put_le(rb, r, 12, f64b[g], 8)
        _put_le(rb, r, 20, f32b[g], 4)
        rb.write_var_string_cell(r, 24, strs[g].as_bytes())


def _two_blocks(with_nulls: Bool) raises -> Slab[RowBlock]:
    var a = RowBlock.with_capacity(2, 0, _STRIDE)
    a.set_n_rows(2)
    _zero_rows(a, 2, _STRIDE)
    _fill(a, 0, 2)
    var b = RowBlock.with_capacity(7, 0, _STRIDE)
    b.set_n_rows(7)
    _zero_rows(b, 7, _STRIDE)
    _fill(b, 2, 7)
    if with_nulls:
        # Output rows: 2 = B row 0, 3 = B row 1, 8 = B row 6.
        _set_null(b, 1, 0)  # i64 NULL at output row 3
        _set_null(b, 0, 4)  # string NULL at output row 2
        _set_null(b, 6, 2)  # f64 NULL at output row 8
        _set_null(b, 6, 0)  # i64 NULL at output row 8
    var blocks = Slab[RowBlock]()
    blocks.append(a^)
    blocks.append(b^)
    return blocks^


def test_layout_and_total_rows() raises:
    """RowOutputLayout keeps what it was given; total_rows sums every
    block's n_rows (2 + 7), and is 0 for no block."""
    var lay = _layout(True)
    assert_equal(lay.n_cols(), 5)
    assert_equal(lay.validity_offset, _VALIDITY)
    assert_true(lay.has_validity)
    var ro = RowOutput(_two_blocks(False), _layout(False), _schema())
    assert_equal(ro.total_rows(), 9)
    var empty = RowOutput(Slab[RowBlock](), _layout(False), _schema())
    assert_equal(empty.total_rows(), 0)


def test_bridge_values_across_blocks() raises:
    """Every value of every row comes out in block order, at the right row,
    with no validity bitmap when the layout has none."""
    var rb = bridge_row_output_to_record_batch(
        RowOutput(_two_blocks(False), _layout(False), _schema())
    )
    assert_equal(rb.num_rows(), 9)
    assert_equal(rb.num_columns(), 5)
    assert_equal(rb.schema.field_name(0), String("i64"))
    assert_equal(rb.schema.field_name(4), String("s"))
    var c0 = rb.column_as_primitive_int64(0)
    var c1 = rb.column_as_primitive_int32(1)
    var c2 = rb.column_as_primitive_float64(2)
    var c3 = rb.column_as_primitive_float32(3)
    var c4 = rb.column_as_string(4)
    var i64s = _i64_vals()
    var i32s = _i32_vals()
    var f64s = _f64_vals()
    var f32s = _f32_vals()
    var strs = _str_vals()
    for r in range(9):
        assert_equal(c0.get(r), i64s[r], "i64 row " + String(r))
        assert_equal(c1.get(r), i32s[r], "i32 row " + String(r))
        assert_equal(c2.get(r), f64s[r], "f64 row " + String(r))
        assert_equal(c3.get(r), f32s[r], "f32 row " + String(r))
        assert_equal(c4.get(r), strs[r], "string row " + String(r))
    assert_false(Bool(c0.validity))
    assert_false(Bool(c2.validity))
    assert_equal(c0.null_count, 0)
    # -0.0 keeps its sign bit through the bridge.
    assert_equal(c2.get(4).to_bits[DType.uint64](), 0x8000000000000000)


def test_bridge_validity_positions_across_blocks() raises:
    """A NULL bit at block B row k is output row 2 + k: rows 3 and 8 of the
    i64 column, row 2 of the string column, row 8 of the f64 column. Columns
    with no NULL get no bitmap."""
    var rb = bridge_row_output_to_record_batch(
        RowOutput(_two_blocks(True), _layout(True), _schema())
    )
    assert_equal(rb.num_rows(), 9)
    var c0 = rb.column_as_primitive_int64(0)
    var c1 = rb.column_as_primitive_int32(1)
    var c2 = rb.column_as_primitive_float64(2)
    var c3 = rb.column_as_primitive_float32(3)
    var c4 = rb.column_as_string(4)
    assert_true(Bool(c0.validity))
    assert_equal(c0.null_count, 2)
    assert_true(Bool(c2.validity))
    assert_equal(c2.null_count, 1)
    assert_false(Bool(c1.validity))
    assert_false(Bool(c3.validity))
    assert_equal(c1.null_count, 0)
    # The Column keeps the count the bridge computed (the typed accessors
    # above recount it from the bitmap).
    assert_equal(rb.column_at(0).null_count(), 2)
    assert_equal(rb.column_at(1).null_count(), 0)
    assert_equal(rb.column_at(2).null_count(), 1)
    assert_equal(rb.column_at(4).null_count(), 1)
    var null0: List[Int] = [3, 8]
    for r in range(9):
        assert_equal(c0.is_null(r), r in null0, "i64 row " + String(r))
        assert_equal(c2.is_null(r), r == 8, "f64 row " + String(r))
        assert_equal(c4.is_null(r), r == 2, "string row " + String(r))
    # The non-NULL values are still the right ones.
    assert_equal(c0.get(2), 3)
    assert_equal(c0.get(4), 5)
    assert_equal(c4.get(3), String("c"))
    assert_equal(c4.get(8), String("gg"))
    assert_equal(c2.get(7), 8.0)


def test_bridge_ignores_bitmap_bytes_without_validity() raises:
    """With `has_validity` False the bridge reads no bitmap: the same blocks,
    NULL bits set, give no nulls and every stored value."""
    var rb = bridge_row_output_to_record_batch(
        RowOutput(_two_blocks(True), _layout(False), _schema())
    )
    var c0 = rb.column_as_primitive_int64(0)
    var c4 = rb.column_as_string(4)
    assert_false(Bool(c0.validity))
    assert_equal(c0.get(3), 4)
    assert_equal(c0.get(8), Int64.MIN)
    for r in range(9):
        assert_false(c4.is_null(r))
    assert_equal(c4.get(2), String("BBBBB"))


def test_bridge_refuses_other_tags() raises:
    """A DT tag outside {I64, I32, F64, F32, STRING} is refused by number."""
    var offs: List[Int] = [0, 8]
    var tags: List[UInt8] = [DT_I64, DT_U8]
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, False))
    sb.add_field(Field("u8", ArrowType.UINT8, False))
    var msg = String("")
    try:
        _ = bridge_row_output_to_record_batch(
            RowOutput(
                _two_blocks(False),
                RowOutputLayout(offs^, tags^, 0, False),
                sb.build(),
            )
        )
    except e:
        msg = String(e)
    assert_true("output DType tag 7 outside" in msg, msg)


def test_bridge_no_blocks() raises:
    """No block: every column comes out empty, under the given schema."""
    var rb = bridge_row_output_to_record_batch(
        RowOutput(Slab[RowBlock](), _layout(True), _schema())
    )
    assert_equal(rb.num_rows(), 0)
    assert_equal(rb.num_columns(), 5)
    assert_equal(len(rb.column_as_string(4)), 0)


# -----------------------------------------------------------------------------
# RowSink's default accept_row_blocks
# -----------------------------------------------------------------------------


struct _CaptureSink(RowSink):
    """A RowSink that keeps the default `accept_row_blocks` and records what
    `accept_batch` receives."""

    var batches: Int
    var rows: Int
    var last_i64: Int64
    var last_s: String

    def __init__(out self):
        self.batches = 0
        self.rows = 0
        self.last_i64 = 0
        self.last_s = String("")

    def init_sink(mut self, schema: Schema) raises:
        pass

    def accept_batch(mut self, var rb: RecordBatch) raises:
        self.batches += 1
        self.rows += rb.num_rows()
        self.last_i64 = rb.column_as_primitive_int64(0).get(rb.num_rows() - 1)
        self.last_s = rb.column_as_string(4).get(rb.num_rows() - 1)

    def finish(mut self) raises:
        pass


def test_row_sink_default_bridges_then_accepts() raises:
    """The default `accept_row_blocks` hands `accept_batch` one batch holding
    every row of every block."""
    var sink = _CaptureSink()
    sink.accept_row_blocks(
        RowOutput(_two_blocks(False), _layout(False), _schema())
    )
    assert_equal(sink.batches, 1)
    assert_equal(sink.rows, 9)
    assert_equal(sink.last_i64, Int64.MIN)
    assert_equal(sink.last_s, String("gg"))
    assert_false(sink.is_text_output_sink())


def main() raises:
    var s = TestSuite()
    s.test[test_layout_and_total_rows]()
    s.test[test_bridge_values_across_blocks]()
    s.test[test_bridge_validity_positions_across_blocks]()
    s.test[test_bridge_ignores_bitmap_bytes_without_validity]()
    s.test[test_bridge_refuses_other_tags]()
    s.test[test_bridge_no_blocks]()
    s.test[test_row_sink_default_bridges_then_accepts]()
    s^.run()
