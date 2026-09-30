# =============================================================================
# test_string_column_slot.mojo — the STRING ColumnSink primitive
# =============================================================================
#
# `StringColumnSlot` is the STRING `ColumnSink` conformer, alongside the
# numeric `ColumnSlot[dt]`. The
# `RowTransform -> MultiColumnSink -> MultiColumnBuilder -> ColumnSink` chain
# otherwise carries `Scalar[DType]` values, and no `DType` holds a String, so
# a String-producing transform writes here.
#
# WHAT THESE TESTS ARE FOR, in order of how easy each is to get wrong:
#
#   1. NULL vs EMPTY STRING. They are DIFFERENT rows and Arrow distinguishes
#      them only via the validity bitmap — both write zero data bytes and both
#      push an identical offset, so the `(offsets, data)` buffers of `["", x]`
#      and `[NULL, x]` are byte-identical. A builder that conflated them would
#      pass every value assertion and every row-count assertion.
#
#   2. THE INT32 OFFSET CEILING. Arrow STRING carries Int32 offsets, so the
#      column tops out at 2,147,483,647 data bytes; past that
#      `ArrowStringBuilder._append_offset`'s bare `Int32(len(data))` wraps
#      NEGATIVE while the row count stays right. This slot REFUSES there
#      rather than promoting to LARGE_STRING (rationale in
#      `multi_column_builder.mojo`). Reaching that arm honestly costs
#      2 GiB of payload, so the slot takes its ceiling as a constructor
#      parameter and these tests lower it — the SAME compare, raise and
#      message a 2 GiB append would run.
#
#   3. THE PACK IS HETEROGENEOUS. A `MultiColumnBuilder` must be able to hold
#      a numeric slot AND a string slot in one output pack, because a project
#      of `(Int64, String)` is the common case. That is why `SinkKind` is a
#      comptime discriminator on ONE trait rather than a second trait.
#
# NOT TESTABLE AT RUNTIME, BY DESIGN: `StringColumnSlot.append_value(...)`
# and `MultiColumnBuilder.append_at[k, DT]` aimed at a STRING slot are
# `comptime assert False` COMPILE errors, not raises. There is no way to
# assert on them from a passing test binary; they are named here so a reader
# does not conclude the channel guard is untested — it is unreachable.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.offset_overflow import ARROW_INT32_OFFSET_MAX
from komira_core.collections.multi_column_builder import (
    ColumnSlot,
    MultiColumnBuilder,
    SinkKind,
    StringColumnSlot,
    column_slot,
    string_column_slot,
)


# ---------------------------------------------------------------------------
# §1 — the slot on its own
# ---------------------------------------------------------------------------


def test_string_slot_basic_round_trip() raises:
    """Three values in, three values out, in order, byte-for-byte."""
    var s = string_column_slot(3)
    assert_equal(s.current_length(), 0)
    assert_equal(s.data_byte_length(), 0)

    s.append_string_value(String("gold"))
    s.append_string_value(String("silver"))
    s.append_string_value(String("bronze"))

    assert_equal(s.current_length(), 3)
    assert_equal(s.data_byte_length(), 16)  # 4 + 6 + 6

    var col = s.finalize_column()
    assert_equal(col.arrow_type, ArrowType.STRING)
    assert_equal(col._length, 3)

    var arr = col.as_string()
    assert_equal(arr.get(0), String("gold"))
    assert_equal(arr.get(1), String("silver"))
    assert_equal(arr.get(2), String("bronze"))
    assert_equal(arr.null_count, 0)


def test_string_slot_empty_column() raises:
    """Zero appends still finalizes into a valid empty STRING column."""
    var s = string_column_slot(0)
    var col = s.finalize_column()
    assert_equal(col.arrow_type, ArrowType.STRING)
    assert_equal(col._length, 0)


def test_string_slot_null_and_empty_string_are_different_rows() raises:
    """THE ONE THAT MATTERS. `""` is VALID; NULL is not.

    Both write zero data bytes and push an identical offset, so the
    `(offsets, data)` buffers cannot tell them apart — only the validity
    bitmap can. A builder that treated `append_null_value()` as
    `append_string_value("")` would produce the identical payload, the
    identical row count, and `is_null(i) == False` everywhere.

    Row layout: ["a", "", NULL, "b"] — the empty string sits IMMEDIATELY
    BEFORE the null so a bitmap that was off by one row would flip both.
    """
    var s = string_column_slot(4)
    s.append_string_value(String("a"))
    s.append_string_value(String(""))
    s.append_null_value()
    s.append_string_value(String("b"))

    assert_equal(s.current_length(), 4)
    assert_equal(s.data_byte_length(), 2)  # "a" + "b"; "" and NULL add zero

    var col = s.finalize_column()
    assert_equal(col._length, 4)
    assert_equal(col._null_count, 1)

    var arr = col.as_string()
    assert_equal(arr.null_count, 1)

    assert_false(arr.is_null(0), "row 0 is a value")
    assert_equal(arr.get(0), String("a"))

    assert_false(arr.is_null(1), "row 1 is the EMPTY STRING, not a null")
    assert_equal(arr.get(1), String(""))

    assert_true(arr.is_null(2), "row 2 is NULL, not the empty string")

    assert_false(arr.is_null(3), "row 3 is a value")
    assert_equal(arr.get(3), String("b"))


def test_string_slot_leading_null_backfills_validity() raises:
    """A null as row 0 must not mark the LATER rows null.

    `ArrowStringBuilder.push_null` lazily allocates the validity list on the
    first null and back-fills the prior rows as present. Row 0 exercises the
    zero-prior-rows edge of that back-fill.
    """
    var s = string_column_slot(3)
    s.append_null_value()
    s.append_string_value(String("x"))
    s.append_string_value(String("yz"))

    var col = s.finalize_column()
    var arr = col.as_string()
    assert_equal(arr.null_count, 1)
    assert_true(arr.is_null(0), "row 0 NULL")
    assert_false(arr.is_null(1), "row 1 present")
    assert_equal(arr.get(1), String("x"))
    assert_false(arr.is_null(2), "row 2 present")
    assert_equal(arr.get(2), String("yz"))


def test_string_slot_trailing_null_after_values() raises:
    """A null AFTER values back-fills the earlier rows as present."""
    var s = string_column_slot(3)
    s.append_string_value(String("p"))
    s.append_string_value(String("qq"))
    s.append_null_value()

    var col = s.finalize_column()
    var arr = col.as_string()
    assert_equal(arr.null_count, 1)
    assert_false(arr.is_null(0), "row 0 present")
    assert_equal(arr.get(0), String("p"))
    assert_false(arr.is_null(1), "row 1 present")
    assert_equal(arr.get(1), String("qq"))
    assert_true(arr.is_null(2), "row 2 NULL")


def test_string_slot_non_ascii_bytes_survive() raises:
    """Multi-byte UTF-8 is copied as bytes; offsets are BYTE offsets.

    A slot that pushed CHARACTER counts instead of byte counts would return
    truncated strings for exactly these values and correct ones for ASCII.
    """
    var s = string_column_slot(2)
    s.append_string_value(String("héllo"))  # 6 bytes, 5 codepoints
    s.append_string_value(String("naïve"))  # 6 bytes, 5 codepoints
    assert_equal(s.data_byte_length(), 12)

    var col = s.finalize_column()
    var arr = col.as_string()
    assert_equal(arr.get(0), String("héllo"))
    assert_equal(arr.get(1), String("naïve"))


def test_string_slot_finalize_twice_raises() raises:
    """One-shot consume — the second `finalize_column` raises, it does not
    return an empty column."""
    var s = string_column_slot(1)
    s.append_string_value(String("only"))
    assert_false(s.is_finalized())
    var col = s.finalize_column()
    _ = col^
    assert_true(s.is_finalized())
    with assert_raises(contains="already finalized"):
        _ = s.finalize_column()


# ---------------------------------------------------------------------------
# §2 — the Int32 offset ceiling: REFUSE, do not corrupt
# ---------------------------------------------------------------------------


def test_string_slot_refuses_at_the_offset_ceiling() raises:
    """The append that would cross the ceiling RAISES; it does not wrap.

    Seam: the slot's ceiling is a constructor parameter whose production
    value is `ARROW_INT32_OFFSET_MAX`. Lowering it runs the identical
    compare / raise / message a 2 GiB append would run — see the
    `_ceiling` docstring for why that seam exists and what it may never do.

    The error is the `ArrowOffsetOverflow` class and it names the ROW that
    was refused, which the finalize-time check in
    `StringArray.from_buffers` structurally cannot know (by then every
    offset has already been narrowed).
    """
    var s = StringColumnSlot.with_capacity(4, 10)
    s.append_string_value(String("12345"))  # 5 bytes, total 5
    s.append_string_value(String("678"))  # 3 bytes, total 8
    assert_equal(s.data_byte_length(), 8)

    # 8 + 3 == 11 > 10 -> refused.
    with assert_raises(contains="ArrowOffsetOverflow"):
        s.append_string_value(String("9ab"))

    # And the message names the refused row (row index 2, i.e. the third).
    with assert_raises(contains="refused row 2"):
        s.append_string_value(String("9ab"))


def test_string_slot_ceiling_boundary_is_inclusive() raises:
    """Exactly AT the ceiling is accepted; one byte past is refused.

    An off-by-one here is the difference between a column that fills its
    last addressable byte and one that wraps on it.
    """
    var s = StringColumnSlot.with_capacity(2, 8)
    s.append_string_value(String("1234"))  # total 4
    s.append_string_value(String("5678"))  # total 8 == ceiling: OK
    assert_equal(s.data_byte_length(), 8)
    with assert_raises(contains="ArrowOffsetOverflow"):
        s.append_string_value(String("9"))  # total 9 > 8


def test_string_slot_refusal_leaves_the_column_intact() raises:
    """A refused append adds NO row. The column finalizes to what it had.

    A guard that raised AFTER pushing the bytes would leave a column whose
    row count included a value the caller was told was rejected.
    """
    var s = StringColumnSlot.with_capacity(4, 6)
    s.append_string_value(String("abc"))
    s.append_string_value(String("de"))
    assert_equal(s.current_length(), 2)
    with assert_raises(contains="ArrowOffsetOverflow"):
        s.append_string_value(String("fgh"))
    assert_equal(s.current_length(), 2)
    assert_equal(s.data_byte_length(), 5)

    var col = s.finalize_column()
    assert_equal(col._length, 2)
    var arr = col.as_string()
    assert_equal(arr.get(0), String("abc"))
    assert_equal(arr.get(1), String("de"))


def test_string_slot_ceiling_fails_closed_on_a_bad_seam_value() raises:
    """A ceiling above the real Int32 limit, or <= 0, collapses to the limit.

    The seam may only ever make the slot STRICTER. If a bad value WIDENED
    the ceiling it would re-arm the silent wrap this guard exists to
    abolish, so both bad directions clamp to `ARROW_INT32_OFFSET_MAX` —
    which these appends are nowhere near, so they all succeed.
    """
    var over = StringColumnSlot.with_capacity(1, ARROW_INT32_OFFSET_MAX + 1000)
    over.append_string_value(String("still fine"))
    assert_equal(over.current_length(), 1)

    var zero = StringColumnSlot.with_capacity(1, 0)
    zero.append_string_value(String("still fine"))
    assert_equal(zero.current_length(), 1)

    var neg = StringColumnSlot.with_capacity(1, -5)
    neg.append_string_value(String("still fine"))
    assert_equal(neg.current_length(), 1)


# ---------------------------------------------------------------------------
# §3 — through a MultiColumnBuilder, mixed with a numeric slot
# ---------------------------------------------------------------------------


def test_multi_column_builder_mixed_numeric_and_string_pack() raises:
    """A `(Int64, String)` output pack in ONE builder.

    This is the shape that forced `SinkKind` to be a comptime discriminator
    on ONE `ColumnSink` trait rather than a second sibling trait: a sibling
    trait could not appear in the same `Tuple[*Bs]` pack, so a two-output
    project of `(Int64, String)` would have been inexpressible.
    """
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = StringColumnSlot

    var mcb = MultiColumnBuilder[S0, S1](
        column_slot[DType.int64](3), string_column_slot(3)
    )
    assert_equal(MultiColumnBuilder[S0, S1].arity(), 2)

    mcb.append_at[0, DType.int64](Scalar[DType.int64](10))
    mcb.append_string_at[1](String("ten"))

    mcb.append_at[0, DType.int64](Scalar[DType.int64](20))
    mcb.append_string_at[1](String(""))

    mcb.append_null_at[0]()
    mcb.append_null_at[1]()

    assert_equal(mcb.length_at[0](), 3)
    assert_equal(mcb.length_at[1](), 3)

    var c0 = mcb.finalize_at[0]()
    assert_equal(c0.arrow_type, ArrowType.INT64)
    assert_equal(c0._length, 3)
    assert_equal(c0._null_count, 1)

    var c1 = mcb.finalize_at[1]()
    assert_equal(c1.arrow_type, ArrowType.STRING)
    assert_equal(c1._length, 3)
    assert_equal(c1._null_count, 1)

    var sarr = c1.as_string()
    assert_equal(sarr.get(0), String("ten"))
    assert_false(sarr.is_null(1), "row 1 is the EMPTY STRING")
    assert_equal(sarr.get(1), String(""))
    assert_true(sarr.is_null(2), "row 2 is NULL")


def test_multi_column_builder_finalize_columns_over_mixed_pack() raises:
    """`finalize_columns()` fans out over a mixed pack in slot order."""
    comptime S0 = StringColumnSlot
    comptime S1 = ColumnSlot[DType.float64]

    var mcb = MultiColumnBuilder[S0, S1](
        string_column_slot(2), column_slot[DType.float64](2)
    )
    mcb.append_string_at[0](String("alpha"))
    mcb.append_at[1, DType.float64](Scalar[DType.float64](1.5))
    mcb.append_string_at[0](String("beta"))
    mcb.append_at[1, DType.float64](Scalar[DType.float64](2.5))

    var cols = mcb.finalize_columns()
    assert_equal(cols.len(), 2)
    assert_equal(cols[0].arrow_type, ArrowType.STRING)
    assert_equal(cols[1].arrow_type, ArrowType.FLOAT64)
    assert_equal(cols[0].as_string().get(1), String("beta"))


def test_sink_kind_discriminates() raises:
    """The comptime KIND on each conformer is what every dispatcher reads."""
    assert_true(
        ColumnSlot[DType.int64].KIND == SinkKind.NUMERIC,
        "a numeric slot is NUMERIC",
    )
    assert_true(
        StringColumnSlot.KIND == SinkKind.STRING, "a string slot is STRING"
    )
    assert_true(
        SinkKind.NUMERIC != SinkKind.STRING, "the two kinds are distinct"
    )


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_slot_basic_round_trip]()
    suite.test[test_string_slot_empty_column]()
    suite.test[test_string_slot_null_and_empty_string_are_different_rows]()
    suite.test[test_string_slot_leading_null_backfills_validity]()
    suite.test[test_string_slot_trailing_null_after_values]()
    suite.test[test_string_slot_non_ascii_bytes_survive]()
    suite.test[test_string_slot_finalize_twice_raises]()
    suite.test[test_string_slot_refuses_at_the_offset_ceiling]()
    suite.test[test_string_slot_ceiling_boundary_is_inclusive]()
    suite.test[test_string_slot_refusal_leaves_the_column_intact]()
    suite.test[test_string_slot_ceiling_fails_closed_on_a_bad_seam_value]()
    suite.test[test_multi_column_builder_mixed_numeric_and_string_pack]()
    suite.test[test_multi_column_builder_finalize_columns_over_mixed_pack]()
    suite.test[test_sink_kind_discriminates]()
    suite^.run()
