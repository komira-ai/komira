# =============================================================================
# `union_compute._hash_one_row` must not fold BOOL into the INT8/UINT8 arm:
# that reads BYTE `row` OF A BIT-PACKED BITMAP. NO RAISE. WRONG GROUPS.
# =============================================================================
#
# The same defect as a `_bytes_for` that answers 1 for BOOL, in a different
# spelling:
#
#     if at == ArrowType.INT8 or at == ArrowType.UINT8 or at == ArrowType.BOOL:
#         return UInt64(UInt8(col._data.get_typed[UInt8](col._offset + row)))
#
# For INT8/UINT8 that IS row `row`. For BOOL it is BYTE `row` of a buffer that
# holds `(n + 7) >> 3` bytes, whose `_offset` is a BIT index — so
#
#   * row 0 hashes to the whole first BYTE (all eight rows' bits at once),
#   * rows 0..7 hash to eight DIFFERENT bytes even when their bits are equal,
#   * every row past `(n + 7) >> 3` reads off the end of the logical bitmap.
#
# ⚠ THIS IS THE SILENT REGIME. Nothing raises and nothing crashes; the hash is
# simply a different number than the value it is supposed to summarise. A test
# that asserts "it did not throw" passes against the defect, so every assertion
# below is on a VALUE.
#
# ★ THE USER-VISIBLE FAILURE IS A SPLIT GROUP. `hash_struct_column` is the
# public surface `agg_struct` uses for `GROUP BY <struct>`, and it delegates
# straight to `_hash_one_row` per child. Two rows whose struct values are EQUAL
# hash differently whenever their bool bits sit in different bytes — so
# `GROUP BY <struct with a bool field>` scatters one group across up to eight.
# `eq_struct_at` cannot repair it: rows that hash apart never meet.
#
# THE FIX IS THE SHARED PRIMITIVE, not another hand-rolled bit ladder:
# `bitmap.read_bit_aligned_buffer(buf, bit_index)` — the single-bit sibling of
# `copy_bits_aligned_buffer` (contiguous run) and `gather_bits_aligned_buffer`
# (indexed run), which the take path rides. `_eq_at`'s BOOL arm uses it too
# rather than inlining the same `>> 3` / `& 7` arithmetic by hand.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_not_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.struct_array import StructArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.union_compute import _hash_one_row, hash_struct_column


def _expected_flag(i: Int) -> Bool:
    """Period 3 — the bit pattern differs in every byte, so a hash that reads
    byte `i` instead of bit `i` cannot coincidentally agree.

    Over 24 bits the packed bytes are 0b01001001 (73), 0b10010010 (146) and
    0b00100100 (36); the correct per-row answers are only ever 0 or 1.
    """
    return i % 3 == 0


def _bool_column(n: Int) raises -> Column[HeapRegion]:
    var flags = BooleanArray.allocate(n)
    for i in range(n):
        flags.set(i, _expected_flag(i))
    return Column.from_boolean(flags)


def test_hash_one_row_bool_hashes_the_BIT_not_the_BYTE() raises:
    """The defect, stated as a value.

    A bit-packed BOOL row can only hash to 0 or 1 under the convention the rest
    of this dispatch uses (a UINT8 column holding 0/1 hashes to 0/1). Byte 0 of
    this column is 73.
    """
    comptime N = 24
    var col = _bool_column(N)
    for r in range(N):
        var want = UInt64(1) if _expected_flag(r) else UInt64(0)
        assert_equal(
            _hash_one_row(col, r),
            want,
            "row "
            + String(r)
            + ": hashed BYTE "
            + String(r)
            + " of a bit-packed bitmap where row "
            + String(r)
            + " is a BIT",
        )


def test_hash_one_row_bool_is_stable_across_byte_boundaries() raises:
    """The property GROUP BY actually depends on: equal value => equal hash.

    Rows 0, 3, 6, 9, ... all carry `true`, and they straddle every byte of the
    bitmap. Reading byte `row` gives them 73, 73, 73, 146, ... — i.e. rows that
    are EQUAL hash APART, which is the split-group failure. This assertion
    holds even if a future change alters the null/true/false hash constants,
    because it compares rows to each other rather than to a literal.
    """
    comptime N = 24
    var col = _bool_column(N)
    var h_true = _hash_one_row(col, 0)
    var h_false = _hash_one_row(col, 1)
    assert_not_equal(
        h_true, h_false, "true and false must not hash to the same value"
    )
    for r in range(N):
        var want = h_true if _expected_flag(r) else h_false
        assert_equal(
            _hash_one_row(col, r),
            want,
            "row " + String(r) + " hashes apart from an EQUAL row",
        )


def test_hash_struct_column_does_not_split_a_group_on_a_bool_field() raises:
    """The public GROUP BY surface, end to end.

    STRUCT<flag: BOOL, tag: INT32> with `tag` held constant, so the ONLY thing
    that may distinguish two rows is the bool. There are exactly two distinct
    struct values in this column, therefore exactly two distinct hashes.
    """
    comptime N = 24
    var flags = BooleanArray.allocate(N)
    for i in range(N):
        flags.set(i, _expected_flag(i))
    var flag_col = Column.from_boolean(flags)

    var tags = PrimitiveArray[DType.int32].allocate(N)
    for i in range(N):
        tags.set(i, Int32(7))
    var tag_col = Column.from_primitive(tags)

    var field_names = List[String]()
    field_names.append(String("flag"))
    field_names.append(String("tag"))
    var sa = StructArray.from_columns_2(field_names, flag_col^, tag_col^)
    var col = sa.to_column()

    var hashes = hash_struct_column(col)
    assert_equal(len(hashes), N)

    var distinct = List[UInt64]()
    for r in range(N):
        var seen = False
        for k in range(len(distinct)):
            if distinct[k] == hashes[r]:
                seen = True
        if not seen:
            distinct.append(hashes[r])
    assert_equal(
        len(distinct),
        2,
        "STRUCT<bool, const int32> over "
        + String(N)
        + " rows holds exactly TWO distinct values, so GROUP BY must see two"
        " hash classes; more means the bool field split one group across"
        " bitmap bytes",
    )

    # And the two classes must be the flag's own partition, not some other cut.
    for r in range(N):
        var want = hashes[0] if _expected_flag(r) else hashes[1]
        assert_equal(hashes[r], want, "row " + String(r) + " landed in the wrong class")


def test_hash_one_row_bool_over_an_already_offset_window() raises:
    """`col._offset` is a BIT index for BOOL, not a byte address.

    A fix that indexes the bit correctly but treats `_offset` as bytes passes
    every test above (whose `_offset` is 0) and fails here. Same composition
    pin the take path carries.
    """
    comptime N = 40
    comptime SKIP = 5
    var base = _bool_column(N)
    var win = base.share()
    win._offset = SKIP
    win._length = N - SKIP

    for r in range(N - SKIP):
        var want = UInt64(1) if _expected_flag(r + SKIP) else UInt64(0)
        assert_equal(
            _hash_one_row(win, r),
            want,
            "windowed bool hashed wrong at row " + String(r),
        )


def test_hash_one_row_bool_edges_and_the_negation() raises:
    """The empty-adjacent and all-one-value shapes, plus the arm this fix
    shares a branch with.

    The negation matters: BOOL was folded INTO the INT8/UINT8 arm, so pulling
    it out must not disturb what that arm answers for a real byte column.
    """
    # Single row, both polarities.
    var one_true = BooleanArray.allocate(1)
    one_true.set(0, True)
    assert_equal(_hash_one_row(Column.from_boolean(one_true), 0), UInt64(1))
    var one_false = BooleanArray.allocate(1)
    one_false.set(0, False)
    assert_equal(_hash_one_row(Column.from_boolean(one_false), 0), UInt64(0))

    # All-true across a byte boundary: byte 0 is 255, so a byte read would
    # answer 255 for every row.
    var all_true = BooleanArray.allocate(12)
    for i in range(12):
        all_true.set(i, True)
    var at_col = Column.from_boolean(all_true)
    for r in range(12):
        assert_equal(_hash_one_row(at_col, r), UInt64(1), "all-true row " + String(r))

    # THE NEGATION — the INT8 arm still hashes byte `row`.
    var i8 = PrimitiveArray[DType.int8].allocate(8)
    for i in range(8):
        i8.set(i, Int8(i * 3))
    var i8_col = Column.from_primitive(i8)
    for r in range(8):
        assert_equal(
            _hash_one_row(i8_col, r),
            UInt64(UInt8(r * 3)),
            "INT8 arm disturbed at row " + String(r),
        )

    var i32 = PrimitiveArray[DType.int32].allocate(4)
    for i in range(4):
        i32.set(i, Int32(100000 + i))
    var i32_col = Column.from_primitive(i32)
    for r in range(4):
        assert_equal(_hash_one_row(i32_col, r), UInt64(100000 + r))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
