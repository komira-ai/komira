# =============================================================================
# concat honours each input's slice offset (`Column._offset`)
# =============================================================================
#
# Arrow addresses row `i` of an array with offset `o` at element `o + i` of
# every buffer: the values (or, for var-len types, the offsets entry), the
# validity bit, and for BOOL the value bit. A concat kernel that reads from
# element 0 instead returns the rows BEFORE the slice, with an exactly-right
# row count. Every test below asserts the Arrow-spec answer, computed from the
# fixture's own lists, never from the kernel.
#
# What each fixture is built to catch:
#   * values: the slice window and the rows before it hold DIFFERENT values,
#     so reading from element 0 is visible.
#   * validity: the null pattern inside the window differs from the pattern
#     at `[0, n)`, in both directions (a null that a bit-0 read would miss and
#     a valid row it would report null), at offsets that are not multiples of 8
#     and with nulls on the first and last row of the window.
#   * var-len: the second input's offsets do not start at 0, and the first
#     input's data buffer is longer than its last offset (both legal in Arrow).
#   * empty slices: a zero-row window at a non-zero offset contributes nothing.
#   * long var-len windows (tens of rows, at non-zero offsets): the offsets
#     rebase runs its SIMD body, not only its scalar tail, at Int32 and Int64.
#
# Both the pair-wise kernel (`_concat_columns`) and the N-way kernel
# (`concat_record_batches_nway_ref`) are exercised on the same fixtures.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.concat import _concat_columns, concat_record_batches_nway_ref
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, Field
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab


# -----------------------------------------------------------------------------
# Fixture builders. Each builds the WHOLE buffers, then sets `_offset` and
# `_length` to the requested window, exactly the shape `Column.slice` and the
# Arrow C-data import hand to concat.
# -----------------------------------------------------------------------------


def _no_nulls(n: Int) -> List[Bool]:
    var m = List[Bool](capacity=n)
    for _ in range(n):
        m.append(False)
    return m^


def _validity(nulls: List[Bool]) -> Optional[Bitmap[HeapRegion]]:
    var any_null = False
    for i in range(len(nulls)):
        if nulls[i]:
            any_null = True
    if not any_null:
        return None
    var bm = Bitmap.create_all_valid(len(nulls))
    for i in range(len(nulls)):
        if nulls[i]:
            bm.clear(i)
    return bm^


def _nulls_in(nulls: List[Bool], off: Int, n: Int) -> Int:
    var c = 0
    for i in range(off, off + n):
        if nulls[i]:
            c += 1
    return c


def _i64_col(
    vals: List[Int], nulls: List[Bool], off: Int, n: Int
) raises -> Column[HeapRegion]:
    var total = len(vals)
    var buf = OwnedAlignedBuffer(max(total * 8, 1))
    buf.set_length(Int64(total * 8))
    for i in range(total):
        buf.set_typed[Int64](i, Int64(vals[i]))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=None,
        validity=_validity(nulls),
        length=n,
        null_count=_nulls_in(nulls, off, n),
        offset=off,
    )


def _bool_col(
    vals: List[Bool], nulls: List[Bool], off: Int, n: Int
) raises -> Column[HeapRegion]:
    var total = len(vals)
    var nbytes = (total + 7) >> 3
    var buf = OwnedAlignedBuffer(max(nbytes, 1))
    buf.set_length(Int64(nbytes))
    for i in range(nbytes):
        buf.write_u8_at(i, UInt8(0))
    for i in range(total):
        if vals[i]:
            var cur = buf.read_u8_at(i >> 3)
            buf.write_u8_at(i >> 3, cur | (UInt8(1) << UInt8(i & 7)))
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=buf^,
        offsets=None,
        validity=_validity(nulls),
        length=n,
        null_count=_nulls_in(nulls, off, n),
        offset=off,
    )


def _var_col(
    at: ArrowType,
    data: String,
    offs: List[Int],
    nulls: List[Bool],
    off: Int,
    n: Int,
) raises -> Column[HeapRegion]:
    """A STRING/BINARY (Int32 offsets) or LARGE_* (Int64 offsets) column whose
    offsets entries are `offs` verbatim (they need not start at 0) and whose
    data buffer is `data` verbatim (it may run past the last offset)."""
    var wide = at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY
    var ow = 8 if wide else 4
    var bytes = data.as_bytes()
    var dlen = len(bytes)
    var dbuf = OwnedAlignedBuffer(max(dlen, 1))
    dbuf.set_length(Int64(dlen))
    for i in range(dlen):
        dbuf.write_u8_at(i, bytes[i])
    var obuf = OwnedAlignedBuffer(len(offs) * ow)
    obuf.set_length(Int64(len(offs) * ow))
    for i in range(len(offs)):
        if wide:
            obuf.set_typed[Int64](i, Int64(offs[i]))
        else:
            obuf.set_typed[Int32](i, Int32(offs[i]))
    return Column[HeapRegion](
        arrow_type=at,
        data=dbuf^,
        offsets=Optional(obuf^),
        validity=_validity(nulls),
        length=n,
        null_count=_nulls_in(nulls, off, n),
        offset=off,
    )


# -----------------------------------------------------------------------------
# Readers. They honour `_offset` themselves, so they read any column, sliced or
# not, the way Arrow defines it.
# -----------------------------------------------------------------------------


def _is_null(col: Column[HeapRegion], r: Int) -> Bool:
    if not col._validity:
        return False
    return not col._validity.value().test(col._offset + r)


def _i64_at(col: Column[HeapRegion], r: Int) -> Int:
    return Int(col._data.get_typed[Int64](col._offset + r))


def _bool_at(col: Column[HeapRegion], r: Int) -> Bool:
    var b = col._offset + r
    return ((col._data.read_u8_at(b >> 3) >> UInt8(b & 7)) & UInt8(1)) == 1


def _str_at(col: Column[HeapRegion], r: Int) -> String:
    var wide = (
        col.arrow_type == ArrowType.LARGE_STRING
        or col.arrow_type == ArrowType.LARGE_BINARY
    )
    var s: Int
    var e: Int
    if wide:
        s = Int(col._offsets.value().get_typed[Int64](col._offset + r))
        e = Int(col._offsets.value().get_typed[Int64](col._offset + r + 1))
    else:
        s = Int(col._offsets.value().get_typed[Int32](col._offset + r))
        e = Int(col._offsets.value().get_typed[Int32](col._offset + r + 1))
    var out = String()
    for i in range(s, e):
        out += chr(Int(col._data.read_u8_at(i)))
    return out^


# -----------------------------------------------------------------------------
# Expectation checkers.
# -----------------------------------------------------------------------------


def _check_i64(
    col: Column[HeapRegion],
    want: List[Int],
    want_null: List[Bool],
    label: String,
) raises:
    assert_equal(col._length, len(want), label + ": length")
    assert_equal(
        col._null_count,
        _nulls_in(want_null, 0, len(want_null)),
        label + ": null_count",
    )
    for r in range(len(want)):
        assert_equal(
            _is_null(col, r), want_null[r], label + ": null flag at " + String(r)
        )
        if not want_null[r]:
            assert_equal(
                _i64_at(col, r), want[r], label + ": value at " + String(r)
            )


def _check_str(
    col: Column[HeapRegion],
    want: List[String],
    want_null: List[Bool],
    label: String,
) raises:
    assert_equal(col._length, len(want), label + ": length")
    assert_equal(
        col._null_count,
        _nulls_in(want_null, 0, len(want_null)),
        label + ": null_count",
    )
    for r in range(len(want)):
        assert_equal(
            _is_null(col, r), want_null[r], label + ": null flag at " + String(r)
        )
        if not want_null[r]:
            assert_equal(_str_at(col, r), want[r], label + ": value at " + String(r))


def _batch(var col: Column[HeapRegion]) raises -> RecordBatch:
    var at = col.arrow_type
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(col^)
    return b.build(Schema.from_fields_1(Field("c", at, True)))


# -----------------------------------------------------------------------------
# Fixed-width values
# -----------------------------------------------------------------------------


def test_pairwise_fixed_sliced_first_input() raises:
    """Issue repro: `[10,20,30,40,50].slice(2,2) ++ [60]` is `[30,40,60]`.
    Reading `a` from element 0 returns `[10,20,60]`."""
    var a = _i64_col([10, 20, 30, 40, 50], _no_nulls(5), 2, 2)
    var b = _i64_col([60], _no_nulls(1), 0, 1)
    var out = _concat_columns(a, b)
    _check_i64(out, [30, 40, 60], _no_nulls(3), "pair fixed a-sliced")


def test_pairwise_fixed_sliced_second_input() raises:
    var a = _i64_col([1, 2], _no_nulls(2), 0, 2)
    var b = _i64_col([7, 8, 9, 10, 11, 12], _no_nulls(6), 3, 2)
    var out = _concat_columns(a, b)
    _check_i64(out, [1, 2, 10, 11], _no_nulls(4), "pair fixed b-sliced")


def test_nway_fixed_sliced_inputs() raises:
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_i64_col([1, 2, 3, 4], _no_nulls(4), 1, 2)))
    batches.append(_batch(_i64_col([5, 6, 7], _no_nulls(3), 0, 3)))
    batches.append(_batch(_i64_col([8, 9, 10, 11, 12], _no_nulls(5), 4, 1)))
    var out = concat_record_batches_nway_ref(batches)
    _check_i64(
        out.column_at(0), [2, 3, 5, 6, 7, 12], _no_nulls(6), "nway fixed sliced"
    )


# -----------------------------------------------------------------------------
# Validity
# -----------------------------------------------------------------------------


def test_pairwise_validity_of_sliced_input() raises:
    """Issue repro: `[1,null,3,4].slice(1,3) ++ [7]` is `[null,3,4,7]`. A
    bit-0 read reports slot 0 valid and slot 1 null — the reverse."""
    var a = _i64_col([1, 0, 3, 4], [False, True, False, False], 1, 3)
    var b = _i64_col([7], _no_nulls(1), 0, 1)
    var out = _concat_columns(a, b)
    _check_i64(
        out,
        [0, 3, 4, 7],
        [True, False, False, False],
        "pair validity a-sliced",
    )


def _mask20() -> List[Bool]:
    """20 rows; nulls at 0, 2, 5, 11, 15, 17, 19. Window [5, 16) begins and
    ends on a null (rows 5 and 15) and differs from the pattern at [0, 11)."""
    var m = _no_nulls(20)
    m[0] = True
    m[2] = True
    m[5] = True
    m[11] = True
    m[15] = True
    m[17] = True
    m[19] = True
    return m^


def _vals20() -> List[Int]:
    var v = List[Int]()
    for i in range(20):
        v.append(100 + i)
    return v^


def _expect_window(
    vals: List[Int],
    mask: List[Bool],
    off: Int,
    n: Int,
    mut want: List[Int],
    mut want_null: List[Bool],
):
    for i in range(off, off + n):
        want.append(vals[i])
        want_null.append(mask[i])


def test_pairwise_validity_unaligned_offsets_both_sides() raises:
    """Offsets 5 and 13 (not multiples of 8), nulls on the window edges."""
    var want = List[Int]()
    var want_null = List[Bool]()
    _expect_window(_vals20(), _mask20(), 5, 11, want, want_null)
    _expect_window(_vals20(), _mask20(), 13, 6, want, want_null)
    var a = _i64_col(_vals20(), _mask20(), 5, 11)
    var b = _i64_col(_vals20(), _mask20(), 13, 6)
    var out = _concat_columns(a, b)
    _check_i64(out, want, want_null, "pair validity unaligned")


def test_nway_validity_unaligned_offsets() raises:
    var want = List[Int]()
    var want_null = List[Bool]()
    _expect_window(_vals20(), _mask20(), 5, 11, want, want_null)
    _expect_window(_vals20(), _mask20(), 0, 3, want, want_null)
    _expect_window(_vals20(), _mask20(), 13, 6, want, want_null)
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_i64_col(_vals20(), _mask20(), 5, 11)))
    batches.append(_batch(_i64_col(_vals20(), _mask20(), 0, 3)))
    batches.append(_batch(_i64_col(_vals20(), _mask20(), 13, 6)))
    var out = concat_record_batches_nway_ref(batches)
    _check_i64(out.column_at(0), want, want_null, "nway validity unaligned")


# -----------------------------------------------------------------------------
# STRING / BINARY / LARGE_*
# -----------------------------------------------------------------------------


def test_pairwise_string_offsets_not_starting_at_zero() raises:
    """Issue items 5 and 6. `a` = "pq" with offsets [0,1] is the one row "p"
    (its data runs past its last offset); `b` has offsets [2,3,5] over
    "zzqrs", i.e. rows "q" and "rs". Spec answer: ["p", "q", "rs"]."""
    var a = _var_col(ArrowType.STRING, "pq", [0, 1], _no_nulls(1), 0, 1)
    var b = _var_col(ArrowType.STRING, "zzqrs", [2, 3, 5], _no_nulls(2), 0, 2)
    var out = _concat_columns(a, b)
    _check_str(out, [String("p"), String("q"), String("rs")], _no_nulls(3), "pair string rebased")


def test_pairwise_string_sliced_with_nulls() raises:
    # Rows: "xx", "a", null, "bc", "de"; window [1, 4) = "a", null, "bc".
    var a = _var_col(
        ArrowType.STRING,
        "xxabcde",
        [0, 2, 3, 3, 5, 7],
        [False, False, True, False, False],
        1,
        3,
    )
    # Rows: "k", "lm", "n"; window [2, 3) = "n".
    var b = _var_col(
        ArrowType.STRING, "klmn", [0, 1, 3, 4], _no_nulls(3), 2, 1
    )
    var out = _concat_columns(a, b)
    _check_str(
        out,
        [String("a"), String(""), String("bc"), String("n")],
        [False, True, False, False],
        "pair string sliced",
    )


def test_nway_string_sliced_and_rebased() raises:
    var batches = Slab[RecordBatch]()
    batches.append(
        _batch(_var_col(ArrowType.STRING, "pq", [0, 1], _no_nulls(1), 0, 1))
    )
    batches.append(
        _batch(
            _var_col(
                ArrowType.STRING,
                "xxabcde",
                [0, 2, 3, 3, 5, 7],
                [False, False, True, False, False],
                1,
                3,
            )
        )
    )
    batches.append(
        _batch(
            _var_col(ArrowType.STRING, "zzqrs", [2, 3, 5], _no_nulls(2), 0, 2)
        )
    )
    var out = concat_record_batches_nway_ref(batches)
    _check_str(
        out.column_at(0),
        [String("p"), String("a"), String(""), String("bc"), String("q"), String("rs")],
        [False, False, True, False, False, False],
        "nway string",
    )


def test_pairwise_large_string_sliced() raises:
    var a = _var_col(
        ArrowType.LARGE_STRING, "xxabcde", [0, 2, 3, 5, 7], _no_nulls(4), 1, 2
    )
    var b = _var_col(
        ArrowType.LARGE_STRING, "zzqrs", [2, 3, 5], _no_nulls(2), 1, 1
    )
    var out = _concat_columns(a, b)
    _check_str(out, [String("a"), String("bc"), String("rs")], _no_nulls(3), "pair large_string")


def test_nway_large_string_sliced() raises:
    var batches = Slab[RecordBatch]()
    batches.append(
        _batch(
            _var_col(
                ArrowType.LARGE_STRING,
                "xxabcde",
                [0, 2, 3, 5, 7],
                [True, False, False, True],
                1,
                3,
            )
        )
    )
    batches.append(
        _batch(
            _var_col(
                ArrowType.LARGE_STRING, "zzqrs", [2, 3, 5], _no_nulls(2), 0, 2
            )
        )
    )
    var out = concat_record_batches_nway_ref(batches)
    _check_str(
        out.column_at(0),
        [String("a"), String("bc"), String(""), String("q"), String("rs")],
        [False, False, True, False, False],
        "nway large_string",
    )


def _long_rows(n: Int) -> List[String]:
    """`n` rows of 0..3 bytes each, every one differing from its neighbours."""
    var rows = List[String](capacity=n)
    for i in range(n):
        var r = String()
        for k in range(i % 4):
            r += chr(65 + (i * 7 + k) % 26)
        rows.append(r^)
    return rows^


def _long_var_col(at: ArrowType, rows: List[String], off: Int, n: Int) raises -> Column[HeapRegion]:
    """`rows` packed after a 3-byte prefix (so offsets start at 3) and before
    a trailing byte, viewing rows [off, off + n)."""
    var data = String("###")
    var offs: List[Int] = [3]
    for i in range(len(rows)):
        data += rows[i]
        offs.append(data.byte_length())
    data += "#"
    return _var_col(at, data, offs, _no_nulls(len(rows)), off, n)


def _window(rows: List[String], off: Int, n: Int) -> List[String]:
    var out = List[String](capacity=n)
    for i in range(off, off + n):
        out.append(rows[i])
    return out^


def test_long_var_len_windows_run_the_simd_rebase() raises:
    """Windows of 40 and 37 rows (more than 2 SIMD vectors of Int32 or Int64
    offsets on any target) at offsets 5 and 11. A rebase whose vector loads
    ignore the source element reads the wrong offsets for every row it
    vectorises; a short window only reaches the scalar tail."""
    var rows = _long_rows(80)
    for wi in range(2):
        var at = ArrowType.STRING if wi == 0 else ArrowType.LARGE_STRING
        var label = String("int32 offsets") if wi == 0 else String("int64 offsets")
        var want = _window(rows, 5, 40)
        want.extend(_window(rows, 11, 37))
        var out = _concat_columns(
            _long_var_col(at, rows, 5, 40), _long_var_col(at, rows, 11, 37)
        )
        _check_str(out, want, _no_nulls(77), "pair long " + label)
        var batches = Slab[RecordBatch]()
        batches.append(_batch(_long_var_col(at, rows, 5, 40)))
        batches.append(_batch(_long_var_col(at, rows, 11, 37)))
        batches.append(_batch(_long_var_col(at, rows, 2, 33)))
        var want3 = want.copy()
        want3.extend(_window(rows, 2, 33))
        var out3 = concat_record_batches_nway_ref(batches)
        _check_str(out3.column_at(0), want3, _no_nulls(110), "nway long " + label)


# -----------------------------------------------------------------------------
# BOOL
# -----------------------------------------------------------------------------


def test_pairwise_bool_sliced_with_nulls() raises:
    var av: List[Bool] = [True, True, True, False, True, False, False, True, True, False, True]
    var am: List[Bool] = [False, False, False, True, False, False, False, False, False, True, False]
    var bv: List[Bool] = [False, False, False, False, False, True, True, False, True]
    var a = _bool_col(av, am, 3, 7)  # rows 3..9
    var b = _bool_col(bv, _no_nulls(9), 5, 4)  # rows 5..8
    var out = _concat_columns(a, b)
    assert_equal(out._length, 11, "bool: length")
    assert_equal(out._null_count, 2, "bool: null_count")
    for r in range(7):
        assert_equal(_is_null(out, r), am[3 + r], "bool a null at " + String(r))
        if not am[3 + r]:
            assert_equal(_bool_at(out, r), av[3 + r], "bool a val at " + String(r))
    for r in range(4):
        assert_false(_is_null(out, 7 + r), "bool b null at " + String(r))
        assert_equal(_bool_at(out, 7 + r), bv[5 + r], "bool b val at " + String(r))


# -----------------------------------------------------------------------------
# Empty slices
# -----------------------------------------------------------------------------


def test_empty_slices_contribute_nothing() raises:
    var a = _i64_col(_vals20(), _mask20(), 7, 0)
    var b = _i64_col(_vals20(), _mask20(), 15, 2)
    var out = _concat_columns(a, b)
    _check_i64(out, [115, 116], [True, False], "pair empty a")
    var c = _var_col(ArrowType.STRING, "xxab", [0, 2, 3, 4], _no_nulls(3), 2, 1)
    var d = _var_col(ArrowType.STRING, "xxab", [0, 2, 3, 4], _no_nulls(3), 3, 0)
    var out2 = _concat_columns(c, d)
    _check_str(out2, [String("b")], _no_nulls(1), "pair empty b string")
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_i64_col(_vals20(), _mask20(), 9, 0)))
    batches.append(_batch(_i64_col(_vals20(), _mask20(), 1, 2)))
    batches.append(_batch(_i64_col(_vals20(), _mask20(), 20, 0)))
    var out3 = concat_record_batches_nway_ref(batches)
    _check_i64(out3.column_at(0), [101, 0], [False, True], "nway empty")


def main() raises:
    var t = TestSuite()
    t.test[test_pairwise_fixed_sliced_first_input]()
    t.test[test_pairwise_fixed_sliced_second_input]()
    t.test[test_nway_fixed_sliced_inputs]()
    t.test[test_pairwise_validity_of_sliced_input]()
    t.test[test_pairwise_validity_unaligned_offsets_both_sides]()
    t.test[test_nway_validity_unaligned_offsets]()
    t.test[test_pairwise_string_offsets_not_starting_at_zero]()
    t.test[test_pairwise_string_sliced_with_nulls]()
    t.test[test_nway_string_sliced_and_rebased]()
    t.test[test_pairwise_large_string_sliced]()
    t.test[test_nway_large_string_sliced]()
    t.test[test_long_var_len_windows_run_the_simd_rebase]()
    t.test[test_pairwise_bool_sliced_with_nulls]()
    t.test[test_empty_slices_contribute_nothing]()
    t^.run()
