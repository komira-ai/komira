# =============================================================================
# split_record_batch: the copy arms (1- and 2-byte, nullable BOOL, DICTIONARY),
# the selection-mask slicing, the empty batch, the trace switch, and
# MorselArray(count).
# =============================================================================
#
# What these tests prove (oracles from the docstrings of `morsel.mojo`,
# worked out by hand from the input the test builds):
#
#   * Morsel `m` holds rows [m*M, min((m+1)*M, N)) of the input: N rows and
#     morsel size M give ceil(N / M) morsels, ids 0, 1, 2, ... and partition
#     0; tried at N a multiple of M, one past, one short, M = 1 and M > N.
#   * A NULLABLE column takes the copy slice: the output column has
#     `_offset == 0`, its bytes are the window's bytes, its validity is
#     rebased to bit 0, and its null count is the nulls in the window. Every
#     input is itself a view at a non-zero `_offset` (3 rows of other values
#     in front), so a slice that forgot the source offset reads the wrong
#     rows, and 3 keeps the bit offsets off byte boundaries.
#   * Width per type: INT8/UINT8 copy 1 byte a row, INT16/UINT16 2 bytes (a
#     wrong stride lands on another row's bytes; values chosen so every byte
#     differs).
#   * Nullable BOOL: data and validity bits both come from bit
#     `_offset + start + i`.
#   * DICTIONARY (string and numeric codes, int32 and int64 code widths): the
#     codes are the window's codes, the whole dictionary is carried, the
#     code width and value type are kept; a string dictionary missing its
#     offsets, or any dictionary missing its values, is refused.
#   * A selection mask on the input is cut into each morsel's window.
#   * A batch with no rows gives one empty morsel; `trace_phases` changes
#     nothing in the result; `MorselArray(count)` holds `count` empty morsels
#     with ids 0..count-1 (none for 0 or a negative count).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_morsel.morsel import MorselArray, split_record_batch


comptime LEAD = 3
"""Rows in front of every input view: the source column's `_offset`."""


def _is_null(i: Int) -> Bool:
    """Window-row null pattern: rows 1, 4, 5, 9 (and 13, 17, ...) are null."""
    return i % 4 == 1 or i == 4


def _validity(n: Int) -> Bitmap[HeapRegion]:
    """LEAD lead bits that are the OPPOSITE of what a misplaced window would
    need (all null), then the window pattern."""
    var bm = Bitmap.create(LEAD + n)
    for i in range(n):
        if not _is_null(i):
            bm.set(LEAD + i)
    return bm^


def _nulls(n: Int) -> Int:
    var c = 0
    for i in range(n):
        if _is_null(i):
            c += 1
    return c


def _one_col_batch(var col: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("c", at, True))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


def _fixed_col(at: ArrowType, width: Int, n: Int) -> Column[HeapRegion]:
    """Row r (window-relative) holds bytes (r*16 + k + 1) for k in 0..width;
    the LEAD rows in front hold 0xEE."""
    var buf = OwnedAlignedBuffer((LEAD + n) * width)
    for r in range(LEAD):
        for k in range(width):
            buf.write_u8_at(r * width + k, UInt8(0xEE))
    for r in range(n):
        for k in range(width):
            buf.write_u8_at((LEAD + r) * width + k, UInt8((r * 16 + k + 1) & 0xFF))
    buf.set_length(Int64((LEAD + n) * width))
    return Column[HeapRegion](
        arrow_type=at,
        data=buf^,
        offsets=None,
        validity=Optional(_validity(n)),
        length=n,
        null_count=_nulls(n),
        offset=LEAD,
    )


def _check_fixed(ma: MorselArray, width: Int, n: Int, m_size: Int) raises:
    var want_morsels = (n + m_size - 1) // m_size
    assert_equal(len(ma), want_morsels, "morsel count")
    assert_equal(ma.total_rows(), n, "total rows")
    for m in range(len(ma)):
        var start = m * m_size
        var rows = min(m_size, n - start)
        assert_equal(ma[m].morsel_id, m)
        assert_equal(ma[m].partition_id, 0)
        assert_equal(ma.num_rows_at(m), rows)
        ref c = ma[m].column_at(0)
        assert_equal(c._offset, 0, "copy slice rebases to offset 0")
        assert_equal(c._length, rows)
        var want_nulls = 0
        for i in range(rows):
            var src = start + i
            if _is_null(src):
                want_nulls += 1
            assert_equal(
                c._validity.value().test(i),
                not _is_null(src),
                "validity m=" + String(m) + " i=" + String(i),
            )
            for k in range(width):
                assert_equal(
                    Int(c._data.read_u8_at(i * width + k)),
                    (src * 16 + k + 1) & 0xFF,
                    "byte m=" + String(m) + " i=" + String(i) + " k=" + String(k),
                )
        assert_equal(c.null_count(), want_nulls, "null count m=" + String(m))


def test_nullable_one_and_two_byte_columns() raises:
    # (type, width) x (rows, morsel size): a multiple, one past, one short,
    # a morsel of 1 and a morsel larger than the batch.
    var types: List[ArrowType] = [
        ArrowType.INT8, ArrowType.UINT8, ArrowType.INT16, ArrowType.UINT16
    ]
    var widths: List[Int] = [1, 1, 2, 2]
    var shapes: List[Int] = [8, 4, 9, 4, 7, 4, 3, 1, 5, 64]
    for t in range(len(types)):
        for s in range(0, len(shapes), 2):
            var n = shapes[s]
            var m_size = shapes[s + 1]
            var batch = _one_col_batch(_fixed_col(types[t], widths[t], n), types[t])
            var ma = split_record_batch(batch^, m_size)
            _check_fixed(ma, widths[t], n, m_size)


def _bool_col(n: Int) -> Column[HeapRegion]:
    """Window row r is True iff r % 3 == 0; the LEAD bits are True too, so a
    read that drops the offset sees the wrong value at rows 1 and 2."""
    var bits = Bitmap.create(LEAD + n)
    for r in range(LEAD):
        bits.set(r)
    for r in range(n):
        if r % 3 == 0:
            bits.set(LEAD + r)
    var nbytes = (LEAD + n + 7) >> 3
    var buf = OwnedAlignedBuffer(nbytes)
    for b in range(nbytes):
        buf.write_u8_at(b, bits.buffer.read_u8_at(b))
    buf.set_length(Int64(nbytes))
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=buf^,
        offsets=None,
        validity=Optional(_validity(n)),
        length=n,
        null_count=_nulls(n),
        offset=LEAD,
    )


def test_nullable_bool_column() raises:
    var n = 21
    var m_size = 8
    var batch = _one_col_batch(_bool_col(n), ArrowType.BOOL)
    var ma = split_record_batch(batch^, m_size)
    assert_equal(len(ma), 3)
    for m in range(3):
        var start = m * m_size
        var rows = min(m_size, n - start)
        ref c = ma[m].column_at(0)
        assert_equal(c._offset, 0)
        assert_equal(c._length, rows)
        var want_nulls = 0
        for i in range(rows):
            var src = start + i
            if _is_null(src):
                want_nulls += 1
            var byte = c._data.read_u8_at(i >> 3)
            var bit = (Int(byte) >> (i & 7)) & 1
            assert_equal(bit == 1, src % 3 == 0, "bool bit m=" + String(m) + " i=" + String(i))
            assert_equal(c._validity.value().test(i), not _is_null(src))
        assert_equal(c.null_count(), want_nulls)


def _string_dict_col(n: Int, dict_vals: List[String]) raises -> Column[HeapRegion]:
    """Codes: lead rows code 0, window row r code (r % len(dict)); nulls per
    `_is_null`. Viewed at offset LEAD via the zero-copy slice."""
    var codes = PrimitiveArray[DType.int32].allocate_nullable(LEAD + n)
    for r in range(LEAD):
        codes.set(r, Int32(0))
    for r in range(n):
        codes.set(LEAD + r, Int32(r % len(dict_vals)))
    for r in range(LEAD):
        codes._set_null(r)
    for r in range(n):
        if _is_null(r):
            codes._set_null(LEAD + r)
    var d = StringArray.from_strings(dict_vals)
    var full = Column.from_dictionary(StringDictionaryArray.from_parts(codes^, d^))
    return full.slice(LEAD, n)


def test_nullable_string_dictionary() raises:
    var dict_vals: List[String] = ["red", "green", "blue"]
    var n = 10
    var m_size = 4
    var batch = _one_col_batch(_string_dict_col(n, dict_vals), ArrowType.DICTIONARY)
    var ma = split_record_batch(batch^, m_size)
    assert_equal(len(ma), 3)
    for m in range(3):
        var start = m * m_size
        var rows = min(m_size, n - start)
        ref c = ma[m].column_at(0)
        assert_true(c.arrow_type == ArrowType.DICTIONARY)
        assert_equal(c._offset, 0)
        assert_equal(c._length, rows)
        assert_false(c.is_numeric_dict())
        assert_equal(c.dict_size(), 3)
        assert_equal(c._dict_index_byte_width, 4)
        var arr = c.as_dictionary()
        var want_nulls = 0
        for i in range(rows):
            var src = start + i
            assert_equal(c._validity.value().test(i), not _is_null(src))
            if _is_null(src):
                want_nulls += 1
                continue
            assert_equal(Int(c._data.get_typed[Int32](i)), src % 3)
            assert_equal(arr.get(i), dict_vals[src % 3])
        assert_equal(c.null_count(), want_nulls)
        # The whole dictionary travels with every morsel.
        assert_equal(arr.dictionary.get(0), "red")
        assert_equal(arr.dictionary.get(2), "blue")


def test_string_dictionary_of_empty_strings() raises:
    # A dictionary whose only entry is "" has no value bytes at all.
    var dict_vals: List[String] = [""]
    var batch = _one_col_batch(_string_dict_col(6, dict_vals), ArrowType.DICTIONARY)
    var ma = split_record_batch(batch^, 4)
    assert_equal(len(ma), 2)
    ref c = ma[1].column_at(0)
    assert_equal(c._length, 2)
    assert_equal(c.dict_size(), 1)
    var arr = c.as_dictionary()
    # Window rows 4 (null) and 5 (null): both null by `_is_null`.
    assert_false(c._validity.value().test(0))
    assert_false(c._validity.value().test(1))
    assert_equal(c.null_count(), 2)
    assert_equal(arr.dictionary.get(0), "")
    ref c0 = ma[0].column_at(0)
    assert_equal(c0.as_dictionary().get(0), "")
    assert_equal(c0.null_count(), 1)


def _numeric_dict_col[code_dt: DType](n: Int) raises -> Column[HeapRegion]:
    """Values [-5, 7, 1000000000000]; window row r code (2 - r % 3)."""
    var codes = PrimitiveArray[code_dt].allocate_nullable(LEAD + n)
    for r in range(LEAD):
        codes.set(r, Scalar[code_dt](0))
        codes._set_null(r)
    for r in range(n):
        codes.set(LEAD + r, Scalar[code_dt](2 - r % 3))
        if _is_null(r):
            codes._set_null(LEAD + r)
    var vals: List[Int64] = [Int64(-5), Int64(7), Int64(1000000000000)]
    var full = Column.from_numeric_dict[code_dt, DType.int64](codes^, vals^)
    return full.slice(LEAD, n)


def _check_numeric_dict(ma: MorselArray, n: Int, m_size: Int, code_w: Int) raises:
    var vals: List[Int64] = [Int64(-5), Int64(7), Int64(1000000000000)]
    for m in range(len(ma)):
        var start = m * m_size
        var rows = min(m_size, n - start)
        ref c = ma[m].column_at(0)
        assert_true(c.is_numeric_dict(), "numeric identity kept")
        assert_equal(c._dict_index_byte_width, code_w)
        assert_true(c.dict_value_dtype() == DType.int64)
        assert_equal(c.dict_size(), 3)
        assert_false(Bool(c._offsets), "numeric dict carries no offsets")
        assert_equal(c._offset, 0)
        assert_equal(c._length, rows)
        var want_nulls = 0
        for i in range(rows):
            var src = start + i
            assert_equal(c._validity.value().test(i), not _is_null(src))
            if _is_null(src):
                want_nulls += 1
                continue
            var code = c.dict_code_at(i)
            assert_equal(code, 2 - src % 3)
            assert_equal(c.dict_value_i64(code), vals[2 - src % 3])
        assert_equal(c.null_count(), want_nulls)


def test_nullable_numeric_dictionary_int32_codes() raises:
    var batch = _one_col_batch(_numeric_dict_col[DType.int32](11), ArrowType.DICTIONARY)
    var ma = split_record_batch(batch^, 4)
    assert_equal(len(ma), 3)
    _check_numeric_dict(ma, 11, 4, 4)


def test_nullable_numeric_dictionary_int64_codes() raises:
    var batch = _one_col_batch(_numeric_dict_col[DType.int64](8), ArrowType.DICTIONARY)
    var ma = split_record_batch(batch^, 4)
    assert_equal(len(ma), 2)
    _check_numeric_dict(ma, 8, 4, 8)


def _malformed_dict(with_offsets: Bool) -> Column[HeapRegion]:
    """A nullable string-dictionary column (so it takes the copy slice) with
    no dictionary offsets, or with offsets but no dictionary values."""
    var codes = OwnedAlignedBuffer(8)
    codes.write_u32_le_at(0, UInt32(0))
    codes.write_u32_le_at(4, UInt32(0))
    codes.set_length(Int64(8))
    var offs = Optional[OwnedAlignedBuffer](None)
    if with_offsets:
        var o = OwnedAlignedBuffer(8)
        o.write_u32_le_at(0, UInt32(0))
        o.write_u32_le_at(4, UInt32(1))
        o.set_length(Int64(8))
        offs = o^
    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=codes^,
        offsets=offs^,
        validity=Optional(Bitmap.create_all_valid(2)),
        length=2,
        null_count=0,
        offset=0,
    )
    col._dict_size = 1
    col._dict_index_byte_width = 4
    return col^


def _split_error(var col: Column[HeapRegion]) raises -> String:
    var batch = _one_col_batch(col^, ArrowType.DICTIONARY)
    try:
        _ = split_record_batch(batch^, 1)
    except e:
        return String(e)
    return String("no error")


def test_malformed_dictionary_is_refused() raises:
    assert_equal(
        _split_error(_malformed_dict(False)),
        "_slice_dictionary: string DICTIONARY column missing dict offsets",
    )
    assert_equal(
        _split_error(_malformed_dict(True)),
        "_slice_dictionary: DICTIONARY column missing dict data",
    )


def _int64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](100 + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals^)))
    return b.build(sb.build())


def test_selection_mask_is_cut_per_morsel() raises:
    var n = 10
    var batch = _int64_batch(n)
    var mask = BooleanArray.allocate(n)
    for i in range(n):
        if i % 3 == 0 or i == 7:
            mask.set(i, True)
    batch.set_selection_mask(mask^)
    var ma = split_record_batch(batch^, 4)
    assert_equal(len(ma), 3)
    var seen = String("")
    for m in range(3):
        assert_true(ma[m].batch.has_selection_mask(), "mask carried")
        for i in range(ma[m].num_rows()):
            seen += "1" if ma[m].batch.selection_mask_get(i) else "0"
        seen += "|"
    # Rows 0..9 selected at 0, 3, 6, 7, 9.
    assert_equal(seen, "1001|0011|01|")
    # Values are untouched by the mask (it is deferred, not applied).
    ref c = ma[2].column_at(0)
    assert_equal(c.as_primitive[DType.int64]().get(1), Int64(109))


def test_all_false_mask_and_no_mask() raises:
    var batch = _int64_batch(5)
    batch.set_selection_mask(BooleanArray.allocate(5))
    var ma = split_record_batch(batch^, 2)
    assert_equal(len(ma), 3)
    for m in range(3):
        assert_true(ma[m].batch.has_selection_mask())
        assert_equal(ma[m].batch.selection_mask_true_count(), 0)
    var plain = split_record_batch(_int64_batch(5), 2)
    for m in range(3):
        assert_false(plain[m].batch.has_selection_mask())


def test_empty_batch_gives_one_empty_morsel() raises:
    var ma = split_record_batch(RecordBatch(), 4)
    assert_equal(len(ma), 1)
    assert_equal(ma.num_rows_at(0), 0)
    assert_equal(ma[0].morsel_id, 0)
    var zero_rows = split_record_batch(_int64_batch(0), 4)
    assert_equal(len(zero_rows), 1)
    assert_equal(zero_rows.total_rows(), 0)


def test_trace_phases_changes_nothing() raises:
    var a = split_record_batch(_int64_batch(9), 4, trace_phases=True)
    var b = split_record_batch(_int64_batch(9), 4)
    assert_equal(len(a), len(b))
    for m in range(len(a)):
        assert_equal(a.num_rows_at(m), b.num_rows_at(m))
        var av = a[m].column_at(0).as_primitive[DType.int64]()
        var bv = b[m].column_at(0).as_primitive[DType.int64]()
        for i in range(a.num_rows_at(m)):
            assert_equal(av.get(i), bv.get(i))
            assert_equal(av.get(i), Int64(100 + m * 4 + i))


def test_morsel_array_count() raises:
    var three = MorselArray(3)
    assert_equal(len(three), 3)
    for i in range(3):
        assert_equal(three[i].morsel_id, i)
        assert_equal(three[i].partition_id, 0)
        assert_equal(three.num_rows_at(i), 0)
    assert_equal(len(MorselArray(1)), 1)
    assert_equal(len(MorselArray(0)), 0)
    assert_equal(len(MorselArray(-2)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
