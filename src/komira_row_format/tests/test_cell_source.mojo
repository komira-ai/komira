# =============================================================================
# `komira_row_format.cell_source`: the two `CellSource` conformers.
# =============================================================================
#
# WHAT THIS PROVES
# ----------------
# `RowCellSource` reads one typed cell out of a `RowBlock` row, given a
# logical column's (byte offset, CELL_DT_* tag). Its oracle here is the row
# format's documented byte layout, worked out by hand: every fixed cell is
# little-endian at its byte offset within a row of `fixed_row_stride` bytes, a
# var-string cell is the 8-byte descriptor `(length << 32) | offset` into the
# var heap, and the validity bitmap holds bit `col & 7` of byte `col >> 3` (1 =
# NULL). The fixtures write every byte with `write_fixed[uint8]`, never with a
# typed write, so a test passes only if the reader decodes the documented
# layout: a reader and writer that agreed on some other layout would not pass.
#
# The values carry the bits that tell the reads apart: a set top bit (a signed
# read sign-extends it, an unsigned read zero-extends it), distinct bytes (a
# byte-order slip changes the value), a DECIMAL128 whose high word is nonzero
# (a read of the low 8 bytes alone drops it), and cells at odd offsets (an
# aligned 16-, 8- or 4-byte load at offset 23 or 43 would read the wrong
# bytes). Three rows per block, so a row index that ignored the stride is
# caught.
#
# `ColumnCellSource` resolves a logical column by NAME through the batch's
# schema; its fixture stores the columns in an order different from the
# logical one, so a position-based lookup reads the wrong column.
#
# `_collect_i64` / `_collect_f64` are generic over `CellSource`: the same
# function run over both conformers on the same values must agree.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_row_format.cell_source import (
    CELL_DT_BOOL,
    CELL_DT_DECIMAL128,
    CELL_DT_F32,
    CELL_DT_F64,
    CELL_DT_I16,
    CELL_DT_I32,
    CELL_DT_I64,
    CELL_DT_I8,
    CELL_DT_STRING,
    CELL_DT_U16,
    CELL_DT_U32,
    CELL_DT_U64,
    CELL_DT_U8,
    CellSource,
    ColumnCellSource,
    RowCellSource,
)
from komira_row_format.row_block import RowBlock


# -----------------------------------------------------------------------------
# The row fixture: 13 logical columns, packed at their byte widths with no
# padding, so most cells sit at unaligned offsets.
#
#   col  cell        offset width     col  cell        offset width
#    0   i64            0     8         7   bool          22     1
#    1   i32            8     4         8   f32           23     4
#    2   i16           12     2         9   f64           27     8
#    3   i8            14     1        10   u64           35     8
#    4   u8            15     1        11   decimal128    43    16
#    5   u16           16     2        12   string desc   59     8
#    6   u32           18     4        validity bitmap    67     2 (13 cols)
#
# stride = 69 bytes.
# -----------------------------------------------------------------------------

comptime _STRIDE = 69
comptime _VALIDITY = 67
comptime _N_COLS = 13
comptime _STR = 12


def _offsets() -> List[Int]:
    return [0, 8, 12, 14, 15, 16, 18, 22, 23, 27, 35, 43, 59]


def _dtypes() -> List[UInt8]:
    return [
        CELL_DT_I64,
        CELL_DT_I32,
        CELL_DT_I16,
        CELL_DT_I8,
        CELL_DT_U8,
        CELL_DT_U16,
        CELL_DT_U32,
        CELL_DT_BOOL,
        CELL_DT_F32,
        CELL_DT_F64,
        CELL_DT_U64,
        CELL_DT_DECIMAL128,
        CELL_DT_STRING,
    ]


def _put_le(mut rb: RowBlock, row: Int, off: Int, v: UInt64, n: Int):
    """Write the low `n` bytes of `v`, least significant first, one byte at a
    time: the little-endian cell layout written without a typed store."""
    for i in range(n):
        rb.write_fixed[DType.uint8](
            row, off + i, UInt8((v >> UInt64(8 * i)) & 0xFF)
        )


def _row_block() raises -> RowBlock:
    """Three rows over the 13-column layout above, every byte hand-placed.

    Row 0 sets the top bit of every integer cell; row 1 holds distinct bytes
    and values a sign error cannot reach; row 2 is all zero bytes."""
    var rb = RowBlock.with_capacity(3, 0, _STRIDE)
    rb.set_n_rows(3)
    for r in range(3):
        _put_le(rb, r, 0, 0, 8)
        for off in range(8, _STRIDE):
            rb.write_fixed[DType.uint8](r, off, 0)

    # Row 0.
    _put_le(rb, 0, 0, 0xFFFFFFFFFFFFFFFE, 8)  # i64 -2
    _put_le(rb, 0, 8, 0xFFFFFFFE, 4)  # i32 -2
    _put_le(rb, 0, 12, 0x8001, 2)  # i16 -32767
    _put_le(rb, 0, 14, 0x81, 1)  # i8 -127
    _put_le(rb, 0, 15, 0xFF, 1)  # u8 255
    _put_le(rb, 0, 16, 0xFFFE, 2)  # u16 65534
    _put_le(rb, 0, 18, 0xFFFFFFFE, 4)  # u32 4294967294
    _put_le(rb, 0, 22, 0x01, 1)  # bool true
    _put_le(rb, 0, 23, 0xBFC00000, 4)  # f32 -1.5
    _put_le(rb, 0, 27, 0x4002000000000000, 8)  # f64 2.25
    _put_le(rb, 0, 35, 0xFFFFFFFFFFFFFFFF, 8)  # u64 max
    # decimal128 -12345: two's complement, low word then high word.
    _put_le(rb, 0, 43, 0xFFFFFFFFFFFFCFC7, 8)
    _put_le(rb, 0, 51, 0xFFFFFFFFFFFFFFFF, 8)

    # Row 1.
    _put_le(rb, 1, 0, 0x0102030405060708, 8)  # i64
    _put_le(rb, 1, 8, 0x01020304, 4)  # i32 16909060
    _put_le(rb, 1, 12, 0x0102, 2)  # i16 258
    _put_le(rb, 1, 14, 0x7F, 1)  # i8 127
    _put_le(rb, 1, 15, 0x01, 1)  # u8 1
    _put_le(rb, 1, 16, 0x0102, 2)  # u16 258
    _put_le(rb, 1, 18, 0x01020304, 4)  # u32 16909060
    _put_le(rb, 1, 22, 0x00, 1)  # bool false
    _put_le(rb, 1, 23, 0x3F000000, 4)  # f32 0.5
    _put_le(rb, 1, 27, 0xC00C000000000000, 8)  # f64 -3.5
    _put_le(rb, 1, 35, 0x8000000000000000, 8)  # u64 2^63
    # decimal128 2^64 + 5: low word 5, high word 1.
    _put_le(rb, 1, 43, 5, 8)
    _put_le(rb, 1, 51, 1, 8)

    # Strings. Row 0 through the block's own cell writer: "h\xc3\xa9llo"
    # (6 bytes) lands at heap offset 0. Rows 1 and 2 get hand-built
    # descriptors into that payload: offset 1 length 4 is "\xc3\xa9ll", offset
    # 6 length 0 is the empty string.
    rb.write_var_string_cell(0, 59, String("héllo").as_bytes())
    _put_le(rb, 1, 59, (UInt64(4) << 32) | 1, 8)
    _put_le(rb, 2, 59, (UInt64(0) << 32) | 6, 8)

    # Validity (1 = NULL): row 0 nulls cols {0, 7, 8, 12}; row 1 nulls
    # {1, 9, 11}; row 2 none.
    _put_le(rb, 0, _VALIDITY, 0x81, 1)
    _put_le(rb, 0, _VALIDITY + 1, 0x11, 1)
    _put_le(rb, 1, _VALIDITY, 0x02, 1)
    _put_le(rb, 1, _VALIDITY + 1, 0x0A, 1)
    return rb^


def _i128(lo: UInt64, hi: UInt64) -> SIMD[DType.int128, 1]:
    return (SIMD[DType.uint128, 1](hi) << 64 | SIMD[DType.uint128, 1](lo)).cast[
        DType.int128
    ]()


def _collect_i64[CS: CellSource](src: CS, col: Int) raises -> List[Int64]:
    var out = List[Int64]()
    for r in range(src.num_rows()):
        out.append(src.read_i64(r, col))
    return out^


def _collect_f64[CS: CellSource](src: CS, col: Int) raises -> List[Float64]:
    var out = List[Float64]()
    for r in range(src.num_rows()):
        out.append(src.read_f64(r, col))
    return out^


# -----------------------------------------------------------------------------
# RowCellSource
# -----------------------------------------------------------------------------


def test_row_read_i64_widens_each_storage_width() raises:
    """read_i64 per CELL_DT tag: signed storage sign-extends, U8/U16/U32 and
    BOOL zero-extend, I64 reads all 8 bytes. Row 0's top bits tell the two
    extensions apart; row 1's distinct bytes pin byte order."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_equal(src.num_rows(), 3)
    # Row 0.
    assert_equal(src.read_i64(0, 0), -2)
    assert_equal(src.read_i64(0, 1), -2)
    assert_equal(src.read_i64(0, 2), -32767)
    assert_equal(src.read_i64(0, 3), -127)
    assert_equal(src.read_i64(0, 4), 255)
    assert_equal(src.read_i64(0, 5), 65534)
    assert_equal(src.read_i64(0, 6), 4294967294)
    assert_equal(src.read_i64(0, 7), 1)
    # Row 1.
    assert_equal(src.read_i64(1, 0), 0x0102030405060708)
    assert_equal(src.read_i64(1, 1), 16909060)
    assert_equal(src.read_i64(1, 2), 258)
    assert_equal(src.read_i64(1, 3), 127)
    assert_equal(src.read_i64(1, 4), 1)
    assert_equal(src.read_i64(1, 5), 258)
    assert_equal(src.read_i64(1, 6), 16909060)
    assert_equal(src.read_i64(1, 7), 0)
    # Row 2: zero bytes read as zero under every tag.
    for c in range(8):
        assert_equal(src.read_i64(2, c), 0)


def test_row_read_u64_zero_extends_unsigned_cells() raises:
    """read_u64: U8/BOOL/U16/U32 zero-extend (row 0's 0xFF.. stays positive),
    U64 reads all 64 bits, so 2^63 and 2^64-1 survive (both are past
    Int64.MAX)."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_equal(src.read_u64(0, 4), 255)
    assert_equal(src.read_u64(0, 7), 1)
    assert_equal(src.read_u64(0, 5), 65534)
    assert_equal(src.read_u64(0, 6), 4294967294)
    assert_equal(src.read_u64(0, 10), UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(src.read_u64(1, 4), 1)
    assert_equal(src.read_u64(1, 7), 0)
    assert_equal(src.read_u64(1, 5), 258)
    assert_equal(src.read_u64(1, 6), 16909060)
    assert_equal(src.read_u64(1, 10), UInt64(0x8000000000000000))
    assert_equal(src.read_u64(2, 10), 0)


def test_row_read_f64_widens_ints_and_f32() raises:
    """read_f64 per tag: I64/I32/BOOL convert the integer value, F32 widens
    the float, F64 reads the 8 IEEE bytes at an odd offset."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_equal(src.read_f64(0, 0), -2.0)
    assert_equal(src.read_f64(0, 1), -2.0)
    assert_equal(src.read_f64(0, 7), 1.0)
    assert_equal(src.read_f64(0, 8), -1.5)
    assert_equal(src.read_f64(0, 9), 2.25)
    assert_equal(src.read_f64(1, 0), Float64(0x0102030405060708))
    assert_equal(src.read_f64(1, 1), 16909060.0)
    assert_equal(src.read_f64(1, 7), 0.0)
    assert_equal(src.read_f64(1, 8), 0.5)
    assert_equal(src.read_f64(1, 9), -3.5)
    assert_equal(src.read_f64(2, 9), 0.0)


def test_row_read_f64_widens_narrow_and_unsigned_ints() raises:
    """read_f64 on I16/I8/U8/U16/U32/U64 cells converts the integer value
    (the trait's contract: conformers widen int storage to f64): signed
    cells sign-extend (row 0's set top bits give negatives), unsigned cells
    stay positive (u64 2^64-1 and 2^63 survive). A raw 8-byte float read of
    these cells gives some unrelated float or NaN."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    var cols: List[Int] = [2, 3, 4, 5, 6, 10]
    var row0: List[Float64] = [
        -32767.0, -127.0, 255.0, 65534.0, 4294967294.0, 18446744073709551615.0
    ]
    var row1: List[Float64] = [
        258.0, 127.0, 1.0, 258.0, 16909060.0, 9223372036854775808.0
    ]
    for i in range(len(cols)):
        assert_equal(src.read_f64(0, cols[i]), row0[i], "row 0 col " + String(cols[i]))
        assert_equal(src.read_f64(1, cols[i]), row1[i], "row 1 col " + String(cols[i]))
        assert_equal(src.read_f64(2, cols[i]), 0.0, "row 2 col " + String(cols[i]))


def test_row_read_i32_and_f32_read_their_width() raises:
    """read_i32 / read_f32 read 4 bytes at the cell's offset (f32 at 23,
    unaligned)."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_equal(src.read_i32(0, 1), -2)
    assert_equal(src.read_i32(1, 1), 16909060)
    assert_equal(src.read_f32(0, 8), -1.5)
    assert_equal(src.read_f32(1, 8), 0.5)
    assert_equal(src.read_f32(2, 8), 0.0)


def test_row_read_i128_reads_both_words() raises:
    """read_i128 reads the 16-byte cell at offset 43: -12345 needs the high
    word's sign bits, 2^64 + 5 needs the high word's 1."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_true(src.read_i128(0, 11) == SIMD[DType.int128, 1](-12345))
    assert_true(src.read_i128(1, 11) == _i128(5, 1))
    assert_false(src.read_i128(1, 11) == SIMD[DType.int128, 1](5))
    assert_true(src.read_i128(2, 11) == SIMD[DType.int128, 1](0))


def test_row_decimal_scale_of_side_table() raises:
    """decimal_scale_of reads the col_scales entry when it exists and is 0
    for an index at or past the table's end, or with no table."""
    var rb = _row_block()
    var scales: List[Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4]
    var src = RowCellSource(rb, _offsets(), _dtypes(), scales^)
    assert_equal(src.decimal_scale_of(11), 4)
    assert_equal(src.decimal_scale_of(10), 0)
    assert_equal(src.decimal_scale_of(12), 0)  # == len(col_scales)
    assert_equal(src.decimal_scale_of(40), 0)
    var bare = RowCellSource(rb, _offsets(), _dtypes())
    assert_equal(bare.decimal_scale_of(0), 0)
    assert_equal(bare.decimal_scale_of(11), 0)


def test_row_read_string_follows_descriptor() raises:
    """read_string decodes the (offset, length) descriptor: row 0's was
    written by `write_var_string_cell` (and its bytes are checked against the
    documented layout), rows 1 and 2 were built by hand to point inside row
    0's payload, one with length 0."""
    var rb = _row_block()
    assert_equal(
        rb.read_fixed[DType.uint64](0, 59), (UInt64(6) << 32) | UInt64(0)
    )
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_equal(src.read_string(0, _STR), String("héllo"))
    assert_equal(src.read_string(1, _STR), String("éll"))
    assert_equal(src.read_string(2, _STR), String(""))
    var raised = False
    try:
        _ = src.read_string(3, _STR)
    except:
        raised = True
    assert_true(raised, "a row past n_rows must raise")


def test_row_read_string_long_length_high_bytes() raises:
    """A 70003-byte payload at heap offset 2: the descriptor's length half is
    0x00011173 (a nonzero third byte) and its offset half is 2."""
    var rb = RowBlock.with_capacity(2, 0, 8)
    rb.set_n_rows(2)
    rb.write_var_string_cell(0, 0, String("ab").as_bytes())
    var long_s = String("")
    for _ in range(70000):
        long_s += "x"
    long_s += "end"
    rb.write_var_string_cell(1, 0, long_s.as_bytes())
    assert_equal(
        rb.read_fixed[DType.uint64](1, 0), (UInt64(70003) << 32) | UInt64(2)
    )
    var offs: List[Int] = [0]
    var dts: List[UInt8] = [CELL_DT_STRING]
    var src = RowCellSource(rb, offs^, dts^)
    assert_equal(src.read_string(0, 0), String("ab"))
    var got = src.read_string(1, 0)
    assert_equal(got.byte_length(), 70003)
    assert_true(got == long_s)


def test_row_is_null_reads_validity_bits() raises:
    """With validity, is_null is bit `col & 7` of byte `col >> 3` at the
    validity offset, per row. Cols 7 and 8 sit either side of the byte
    boundary; col 12 is in the second byte's middle."""
    var rb = _row_block()
    var src = RowCellSource(
        rb,
        _offsets(),
        _dtypes(),
        has_validity=True,
        validity_offset=_VALIDITY,
    )
    assert_true(src.has_validity())
    var null0: List[Int] = [0, 7, 8, 12]
    var null1: List[Int] = [1, 9, 11]
    for c in range(_N_COLS):
        var want0 = c in null0
        var want1 = c in null1
        assert_equal(src.is_null(0, c), want0, "row 0 col " + String(c))
        assert_equal(src.is_null(1, c), want1, "row 1 col " + String(c))
        assert_false(src.is_null(2, c), "row 2 col " + String(c))


def test_row_is_null_without_validity_is_false() raises:
    """Without validity, every cell is present whatever the bytes at the
    bitmap's place hold (row 0's are 0x81 0x11, and offset 0 holds 0xFE)."""
    var rb = _row_block()
    var src = RowCellSource(rb, _offsets(), _dtypes())
    assert_false(src.has_validity())
    for c in range(_N_COLS):
        assert_false(src.is_null(0, c))
        assert_false(src.is_null(1, c))


def test_row_validity_bytes_match_set_cell_null() raises:
    """The hand-placed bitmap bytes are what the block's own `set_cell_null`
    writes for the same cells, so the fixture's layout is the block's."""
    var rb = RowBlock.with_capacity(2, 0, _STRIDE)
    rb.set_n_rows(2)
    for r in range(2):
        for off in range(_STRIDE):
            rb.write_fixed[DType.uint8](r, off, 0)
    for c in [0, 7, 8, 12]:
        rb.set_cell_null(0, _VALIDITY, c)
    for c in [1, 9, 11]:
        rb.set_cell_null(1, _VALIDITY, c)
    assert_equal(rb.read_fixed[DType.uint8](0, _VALIDITY), 0x81)
    assert_equal(rb.read_fixed[DType.uint8](0, _VALIDITY + 1), 0x11)
    assert_equal(rb.read_fixed[DType.uint8](1, _VALIDITY), 0x02)
    assert_equal(rb.read_fixed[DType.uint8](1, _VALIDITY + 1), 0x0A)


# -----------------------------------------------------------------------------
# ColumnCellSource
# -----------------------------------------------------------------------------


def _batch() raises -> RecordBatch:
    """Seven columns stored in the order s, f32, dec, i32, f64, i64, ls; the
    logical names (see `_names`) list them in another order."""
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, False))
    sb.add_field(Field("dec", ArrowType.DECIMAL128, False))
    sb.add_field(Field("i32", ArrowType.INT32, False))
    sb.add_field(Field("f64", ArrowType.FLOAT64, False))
    sb.add_field(Field("i64", ArrowType.INT64, False))
    sb.add_field(Field("ls", ArrowType.LARGE_STRING, True))

    var s_vals: List[String] = ["ab", "", "xyz"]
    var s_valid: List[Bool] = [True, False, True]
    var f32s: List[Float32] = [-1.5, 0.5, 0.0]
    var dec = Decimal128Array.allocate(3, precision=38, scale=3)
    dec.set_i128(0, SIMD[DType.int128, 1](-12345))
    dec.set_i128(1, _i128(5, 1))
    dec.set_i128(2, SIMD[DType.int128, 1](0))
    var i32s: List[Int32] = [-2, 16909060, 0]
    var f64s: List[Float64] = [2.25, -3.5, 0.0]
    var i64s: List[Int64] = [-2, 0x0102030405060708, 0]
    var ls_vals: List[String] = ["", "q", ""]
    var ls_valid: List[Bool] = [False, True, True]

    var rbb = RecordBatchBuilder.with_capacity(7)
    rbb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(s_vals, s_valid))
    )
    rbb.add_column(
        Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].from_list(f32s)
        )
    )
    rbb.add_column(Column.from_decimal128(dec^))
    rbb.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(i32s)
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(f64s)
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s)
        )
    )
    rbb.add_column(
        Column.from_large_string(
            LargeStringArray.from_strings_with_validity(ls_vals, ls_valid)
        )
    )
    return rbb.build(sb.build())


def _names() -> List[String]:
    """Logical col_idx -> name: 0 i64, 1 i32, 2 f64, 3 f32, 4 dec, 5 s, 6 ls."""
    return ["i64", "i32", "f64", "f32", "dec", "s", "ls"]


def test_column_reads_resolve_by_name() raises:
    """Each typed read resolves col_idx through the name, not the batch
    position (col_idx 0 is "i64", stored at position 5)."""
    var batch = _batch()
    var src = ColumnCellSource(BatchView(batch), _names())
    assert_equal(src.num_rows(), 3)
    assert_false(src.has_validity())
    assert_equal(src.read_i64(0, 0), -2)
    assert_equal(src.read_i64(1, 0), 0x0102030405060708)
    assert_equal(src.read_i32(0, 1), -2)
    assert_equal(src.read_i32(1, 1), 16909060)
    assert_equal(src.read_f64(0, 2), 2.25)
    assert_equal(src.read_f64(1, 2), -3.5)
    assert_equal(src.read_f32(0, 3), -1.5)
    assert_equal(src.read_f32(1, 3), 0.5)
    assert_equal(src.read_string(0, 5), String("ab"))
    assert_equal(src.read_string(2, 5), String("xyz"))


def test_column_read_u64_reinterprets_i64_bits() raises:
    """read_u64 over the i64 column is the same 64 bits read unsigned: -2 is
    2^64 - 2."""
    var batch = _batch()
    var src = ColumnCellSource(BatchView(batch), _names())
    assert_equal(src.read_u64(0, 0), UInt64(0xFFFFFFFFFFFFFFFE))
    assert_equal(src.read_u64(1, 0), UInt64(0x0102030405060708))
    assert_equal(src.read_u64(2, 0), 0)


def test_column_decimal_value_and_scale() raises:
    """read_i128 returns the unscaled 128-bit value (the high word included)
    and decimal_scale_of the array's scale."""
    var batch = _batch()
    var src = ColumnCellSource(BatchView(batch), _names())
    assert_true(src.read_i128(0, 4) == SIMD[DType.int128, 1](-12345))
    assert_true(src.read_i128(1, 4) == _i128(5, 1))
    assert_true(src.read_i128(2, 4) == SIMD[DType.int128, 1](0))
    assert_equal(src.decimal_scale_of(4), 3)


def test_column_is_null_string_and_large_string() raises:
    """is_null answers for STRING and LARGE_STRING columns from their
    validity, per row."""
    var batch = _batch()
    var src = ColumnCellSource(BatchView(batch), _names())
    assert_false(src.is_null(0, 5))
    assert_true(src.is_null(1, 5))
    assert_false(src.is_null(2, 5))
    assert_true(src.is_null(0, 6))
    assert_false(src.is_null(1, 6))
    assert_false(src.is_null(2, 6))
    assert_equal(src.read_string(1, 6), String("q"))


def test_column_is_null_refuses_other_types() raises:
    """is_null on a non-string column raises and names the column index."""
    var batch = _batch()
    var src = ColumnCellSource(BatchView(batch), _names())
    for c in [0, 2, 4]:
        var msg = String("")
        try:
            _ = src.is_null(0, c)
        except e:
            msg = String(e)
        assert_true(
            "only STRING is supported" in msg, "col " + String(c) + ": " + msg
        )
        assert_true("col_idx=" + String(c) + ")" in msg, msg)


def test_column_unknown_name_raises() raises:
    """A name the schema does not hold is refused, not read from some other
    column."""
    var batch = _batch()
    var names: List[String] = ["nope"]
    var src = ColumnCellSource(BatchView(batch), names^)
    var raised = False
    try:
        _ = src.read_i64(0, 0)
    except:
        raised = True
    assert_true(raised)


def test_conformers_agree_through_the_trait() raises:
    """The generic readers give the same values over the row fixture and the
    column fixture, which hold the same i64 and f64 values."""
    var rb = _row_block()
    var row_src = RowCellSource(rb, _offsets(), _dtypes())
    var batch = _batch()
    var col_src = ColumnCellSource(BatchView(batch), _names())
    var row_i = _collect_i64(row_src, 0)
    var col_i = _collect_i64(col_src, 0)
    assert_equal(len(row_i), 3)
    assert_equal(row_i, col_i)
    assert_equal(row_i, [Int64(-2), Int64(0x0102030405060708), Int64(0)])
    var row_f = _collect_f64(row_src, 9)
    var col_f = _collect_f64(col_src, 2)
    assert_equal(row_f, col_f)
    assert_equal(row_f, [2.25, -3.5, 0.0])


def main() raises:
    var s = TestSuite()
    s.test[test_row_read_i64_widens_each_storage_width]()
    s.test[test_row_read_u64_zero_extends_unsigned_cells]()
    s.test[test_row_read_f64_widens_ints_and_f32]()
    s.test[test_row_read_f64_widens_narrow_and_unsigned_ints]()
    s.test[test_row_read_i32_and_f32_read_their_width]()
    s.test[test_row_read_i128_reads_both_words]()
    s.test[test_row_decimal_scale_of_side_table]()
    s.test[test_row_read_string_follows_descriptor]()
    s.test[test_row_read_string_long_length_high_bytes]()
    s.test[test_row_is_null_reads_validity_bits]()
    s.test[test_row_is_null_without_validity_is_false]()
    s.test[test_row_validity_bytes_match_set_cell_null]()
    s.test[test_column_reads_resolve_by_name]()
    s.test[test_column_read_u64_reinterprets_i64_bits]()
    s.test[test_column_decimal_value_and_scale]()
    s.test[test_column_is_null_string_and_large_string]()
    s.test[test_column_is_null_refuses_other_types]()
    s.test[test_column_unknown_name_raises]()
    s.test[test_conformers_agree_through_the_trait]()
    s^.run()
