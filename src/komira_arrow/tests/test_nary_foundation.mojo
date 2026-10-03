# =============================================================================
# test_nary_foundation.mojo — n-ary variadic-storage primitive unit tests
# =============================================================================
#
# Covers the two n-ary foundation modules:
#   - variadic_pack.mojo  — VariadicElement / VariadicPack
#   - multi_column_builder.mojo — ColumnSink / ColumnSlot / MultiColumnBuilder
#
# These are the shared variadic-storage primitives that n-ary operators
# (hash aggregate, join build, asof join, sort buffer, project list, stage
# output) build on.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_collections.variadic_pack import (
    VariadicElement,
    VariadicPack,
)
from komira_arrow.multi_column_builder import (
    ColumnSlot,
    MultiColumnBuilder,
    column_slot,
)


# =============================================================================
# §1 — VariadicPack
# =============================================================================
#
# A trivial VariadicElement conformer carrying a comptime tag, used to verify
# per-slot dispatch lands on the correct (distinct) element.
# =============================================================================


@fieldwise_init
struct TaggedMark[tag: Int](VariadicElement):
    def variadic_tag(self) -> Int:
        return Self.tag


def test_variadic_pack_arity() raises:
    """VariadicPack.arity() reports the comptime element count."""
    assert_equal(VariadicPack[TaggedMark[1]].arity(), 1)
    assert_equal(VariadicPack[TaggedMark[1], TaggedMark[2]].arity(), 2)
    assert_equal(
        VariadicPack[
            TaggedMark[1], TaggedMark[2], TaggedMark[3], TaggedMark[4]
        ].arity(),
        4,
    )


def test_variadic_pack_get_dispatches_per_slot() raises:
    """get[k] / get_mut[k] borrow the correct (distinct) element."""
    var pack = VariadicPack[TaggedMark[10], TaggedMark[20], TaggedMark[30]](
        TaggedMark[10](), TaggedMark[20](), TaggedMark[30]()
    )
    assert_equal(pack.get[0]().variadic_tag(), 10)
    assert_equal(pack.get[1]().variadic_tag(), 20)
    assert_equal(pack.get[2]().variadic_tag(), 30)
    assert_equal(pack.get_mut[0]().variadic_tag(), 10)
    assert_equal(pack.get_mut[2]().variadic_tag(), 30)


def test_variadic_pack_arity_one() raises:
    """Arity-1 boundary case — a single-element pack."""
    var pack = VariadicPack[TaggedMark[99]](TaggedMark[99]())
    assert_equal(VariadicPack[TaggedMark[99]].arity(), 1)
    assert_equal(pack.get[0]().variadic_tag(), 99)


def test_variadic_pack_arity_eight() raises:
    """Arity-8 — confirms the @parameter-for fan-out scales (the POC
    verified compile + dispatch through 16/32; 8 here is the unit gate)."""
    var pack = VariadicPack[
        TaggedMark[0], TaggedMark[1], TaggedMark[2], TaggedMark[3],
        TaggedMark[4], TaggedMark[5], TaggedMark[6], TaggedMark[7],
    ](
        TaggedMark[0](), TaggedMark[1](), TaggedMark[2](), TaggedMark[3](),
        TaggedMark[4](), TaggedMark[5](), TaggedMark[6](), TaggedMark[7](),
    )
    var total = 0

    comptime for k in range(8):
        total += pack.get[k]().variadic_tag()
    # 0 + 1 + ... + 7 = 28
    assert_equal(total, 28)


# =============================================================================
# §2 — ColumnSlot
# =============================================================================


def test_column_slot_append_and_length() raises:
    """A ColumnSlot accumulates values; current_length tracks the count."""
    var slot = ColumnSlot[DType.int64].with_capacity(4)
    assert_equal(slot.current_length(), 0)
    slot.append_value(Scalar[DType.int64](7))
    slot.append_value(Scalar[DType.int64](8))
    slot.append_value(Scalar[DType.int64](9))
    assert_equal(slot.current_length(), 3)
    assert_false(slot.is_finalized())


def test_column_slot_factory() raises:
    """The `column_slot[dt]()` free factory builds a ColumnSlot."""
    var slot = column_slot[DType.float64](2)
    slot.append_value(Scalar[DType.float64](1.5))
    assert_equal(slot.current_length(), 1)


def test_column_slot_finalize_emits_column() raises:
    """finalize_column emits a Column with the accumulated rows."""
    var slot = ColumnSlot[DType.int64].with_capacity(3)
    slot.append_value(Scalar[DType.int64](100))
    slot.append_value(Scalar[DType.int64](200))
    var col = slot.finalize_column()
    assert_equal(col.length(), 2)
    assert_true(slot.is_finalized())


def test_column_slot_finalize_twice_raises() raises:
    """finalize_column is one-shot — a second call raises."""
    var slot = ColumnSlot[DType.int64].with_capacity(1)
    slot.append_value(Scalar[DType.int64](1))
    var col = slot.finalize_column()
    assert_equal(col.length(), 1)
    var raised = False
    try:
        var _c2 = slot.finalize_column()
    except:
        raised = True
    assert_true(raised)


def test_column_slot_null_append() raises:
    """append_null_value lands a null slot; the column carries it."""
    var slot = ColumnSlot[DType.int64].with_capacity(3)
    slot.append_value(Scalar[DType.int64](5))
    slot.append_null_value()
    slot.append_value(Scalar[DType.int64](7))
    assert_equal(slot.current_length(), 3)
    var col = slot.finalize_column()
    assert_equal(col.length(), 3)


# =============================================================================
# §3 — MultiColumnBuilder
# =============================================================================


def test_mcb_arity() raises:
    """MultiColumnBuilder.arity() reports the output-column count."""
    assert_equal(
        MultiColumnBuilder[ColumnSlot[DType.int64]].arity(), 1
    )
    assert_equal(
        MultiColumnBuilder[
            ColumnSlot[DType.int64], ColumnSlot[DType.float64]
        ].arity(),
        2,
    )


def test_mcb_append_at_per_slot() raises:
    """append_at[k, DT] lands values in the correct output slot;
    length_at[k] tracks per-slot counts independently."""
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = ColumnSlot[DType.float64]
    var mcb = MultiColumnBuilder[S0, S1](
        column_slot[DType.int64](4), column_slot[DType.float64](4)
    )
    mcb.append_at[0, DType.int64](Scalar[DType.int64](11))
    mcb.append_at[0, DType.int64](Scalar[DType.int64](22))
    mcb.append_at[1, DType.float64](Scalar[DType.float64](3.5))
    assert_equal(mcb.length_at[0](), 2)
    assert_equal(mcb.length_at[1](), 1)


def test_mcb_finalize_at() raises:
    """finalize_at[k] emits one output column with the accumulated rows."""
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = ColumnSlot[DType.int32]
    var mcb = MultiColumnBuilder[S0, S1](
        column_slot[DType.int64](2), column_slot[DType.int32](2)
    )
    mcb.append_at[0, DType.int64](Scalar[DType.int64](7))
    mcb.append_at[0, DType.int64](Scalar[DType.int64](8))
    mcb.append_at[0, DType.int64](Scalar[DType.int64](9))
    mcb.append_at[1, DType.int32](Scalar[DType.int32](100))
    var c0 = mcb.finalize_at[0]()
    var c1 = mcb.finalize_at[1]()
    assert_equal(c0.length(), 3)
    assert_equal(c1.length(), 1)


def test_mcb_finalize_columns_all_slots() raises:
    """finalize_columns one-shot consumes EVERY slot, in slot order."""
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = ColumnSlot[DType.float64]
    comptime S2 = ColumnSlot[DType.int32]
    var mcb = MultiColumnBuilder[S0, S1, S2](
        column_slot[DType.int64](2),
        column_slot[DType.float64](2),
        column_slot[DType.int32](2),
    )
    mcb.append_at[0, DType.int64](Scalar[DType.int64](1))
    mcb.append_at[0, DType.int64](Scalar[DType.int64](2))
    mcb.append_at[1, DType.float64](Scalar[DType.float64](9.9))
    mcb.append_at[1, DType.float64](Scalar[DType.float64](8.8))
    mcb.append_at[2, DType.int32](Scalar[DType.int32](42))
    mcb.append_at[2, DType.int32](Scalar[DType.int32](43))
    var cols = mcb.finalize_columns()
    assert_equal(len(cols), 3)
    assert_equal(cols[0].length(), 2)
    assert_equal(cols[1].length(), 2)
    assert_equal(cols[2].length(), 2)


def test_mcb_null_aware() raises:
    """append_null_at lands nulls in the correct slot."""
    comptime S0 = ColumnSlot[DType.int64]
    var mcb = MultiColumnBuilder[S0](column_slot[DType.int64](3))
    mcb.append_at[0, DType.int64](Scalar[DType.int64](5))
    mcb.append_null_at[0]()
    mcb.append_at[0, DType.int64](Scalar[DType.int64](7))
    assert_equal(mcb.length_at[0](), 3)
    var col = mcb.finalize_at[0]()
    assert_equal(col.length(), 3)


def test_mcb_arity_four() raises:
    """Arity-4 MultiColumnBuilder — the bench-parity / objdump arity."""
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = ColumnSlot[DType.int64]
    comptime S2 = ColumnSlot[DType.int64]
    comptime S3 = ColumnSlot[DType.int64]
    var mcb = MultiColumnBuilder[S0, S1, S2, S3](
        column_slot[DType.int64](1),
        column_slot[DType.int64](1),
        column_slot[DType.int64](1),
        column_slot[DType.int64](1),
    )
    assert_equal(MultiColumnBuilder[S0, S1, S2, S3].arity(), 4)

    comptime for k in range(4):
        mcb.append_at[k, DType.int64](Scalar[DType.int64](Int64(k * 10)))
    assert_equal(mcb.length_at[0](), 1)
    assert_equal(mcb.length_at[3](), 1)
    var cols = mcb.finalize_columns()
    assert_equal(len(cols), 4)


# =============================================================================
# TestSuite registration
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_variadic_pack_arity]()
    suite.test[test_variadic_pack_get_dispatches_per_slot]()
    suite.test[test_variadic_pack_arity_one]()
    suite.test[test_variadic_pack_arity_eight]()
    suite.test[test_column_slot_append_and_length]()
    suite.test[test_column_slot_factory]()
    suite.test[test_column_slot_finalize_emits_column]()
    suite.test[test_column_slot_finalize_twice_raises]()
    suite.test[test_column_slot_null_append]()
    suite.test[test_mcb_arity]()
    suite.test[test_mcb_append_at_per_slot]()
    suite.test[test_mcb_finalize_at]()
    suite.test[test_mcb_finalize_columns_all_slots]()
    suite.test[test_mcb_null_aware]()
    suite.test[test_mcb_arity_four]()
    suite^.run()
