# =============================================================================
# Tests for the AoS commit kernels and the row thunks
# =============================================================================
#
# Verifies:
# 1. The sum+count kernel writes exactly two fields per row (sum @+0,
#    count @+8) of the entry the row's offset names, and nothing beside it.
# 2. AosAccKernel.call dispatches each kind to its kernel.
# 3. Running the kernel with different agg_slot_offsets folds values into
#    disjoint slots of a single entry buffer.
# 4. Rows scatter across several entries of one table by their offsets.
# 5. A batch that does not fit its spans is refused, not read past.
# 6. The row thunks (AosRowThunk) apply one value to one slot.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_op_agg_state.accumulator_set import (
    AosAccKernel,
    AOS_KERNEL_SUM_COUNT_F64,
    AOS_KERNEL_SUM_F64,
    AOS_KERNEL_COUNT_STAR,
    sum_count_f64_aos_thunk,
    resolve_row_thunk,
)
from komira_agg_api.agg_layout import (
    ACC_SUM_COUNT_MIN_MAX_F64,
    ACC_SUM_COUNT_F64,
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    AggLayout,
    acc_slot_width,
)


def _zeroed(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(UInt8(0))
    return out^


def _f64_at(mut table: List[UInt8], byte_off: Int) -> Float64:
    return (table.unsafe_ptr() + byte_off).bitcast[Float64]()[]


def _i64_at(mut table: List[UInt8], byte_off: Int) -> Int64:
    return (table.unsafe_ptr() + byte_off).bitcast[Int64]()[]


def _col(mut values: List[Float64]) -> Span[UInt8, origin_of(values)]:
    return Span[UInt8, origin_of(values)](
        unsafe_ptr=values.unsafe_ptr().bitcast[UInt8](), length=len(values) * 8
    )


def _offsets(*offs: Int) -> List[Int]:
    var out = List[Int]()
    for o in offs:
        out.append(o)
    return out^


def _floats(*vs: Float64) -> List[Float64]:
    var out = List[Float64]()
    for v in vs:
        out.append(v)
    return out^


def test_thunk_writes_sum_and_count() raises:
    """The kernel writes [sum:f64 @+0][count:i64 @+8] for each row."""
    print("test_thunk_writes_sum_and_count...")
    # One synthetic entry region: 16 bytes, zero-initialised, with a sentinel
    # 16 bytes after it that the kernel must not touch.
    var table = _zeroed(32)
    (table.unsafe_ptr() + 16).bitcast[Int64]()[] = Int64(0x5EED)
    var offs = _offsets(0, 0, 0)
    var values = _floats(10.0, 20.0, 30.0)

    # Drive the kernel directly (no wrapper).
    sum_count_f64_aos_thunk(Span(table), Span(offs), _col(values), 0, 0, 3)

    assert_equal(_f64_at(table, 0), Float64(60.0))
    assert_equal(_i64_at(table, 8), Int64(3))
    assert_equal(_i64_at(table, 16), Int64(0x5EED))
    print("  ok")


def test_kernel_wrapper_dispatches() raises:
    """AosAccKernel.call dispatches each kind to its kernel."""
    print("test_kernel_wrapper_dispatches...")
    var table = _zeroed(16)
    var offs = _offsets(0, 0, 0, 0)
    var values = _floats(1.0, 2.0, 3.0, 4.0)

    var kernel = AosAccKernel(
        kind=AOS_KERNEL_SUM_COUNT_F64, agg_slot_offset=0, value_col_index=0
    )
    kernel.call(Span(table), Span(offs), _col(values), 0, 4)
    assert_equal(_f64_at(table, 0), Float64(10.0))
    assert_equal(_i64_at(table, 8), Int64(4))

    # SUM only: an 8-byte slot at +0 of a fresh entry.
    var t2 = _zeroed(8)
    AosAccKernel(AOS_KERNEL_SUM_F64, 0, 0).call(
        Span(t2), Span(offs), _col(values), 0, 4
    )
    assert_equal(_f64_at(t2, 0), Float64(10.0))

    # COUNT(*): the value column is never read, so it may be empty.
    var t3 = _zeroed(8)
    var empty = List[UInt8]()
    AosAccKernel(AOS_KERNEL_COUNT_STAR, 0, 0).call(
        Span(t3), Span(offs), Span(empty), 0, 4
    )
    assert_equal(_i64_at(t3, 0), Int64(4))
    print("  ok")


def test_two_kernels_disjoint_slots() raises:
    """Two kernels at different agg_slot_offsets hit disjoint 16B slots."""
    print("test_two_kernels_disjoint_slots...")
    # Two 16B slots back-to-back inside one 32B entry buffer.
    var table = _zeroed(32)
    var offs = _offsets(0, 0)
    var values_a = _floats(5.0, 15.0)  # -> slot0 sum=20 count=2
    var values_b = _floats(1000.0, 2000.0)  # -> slot1 sum=3000 count=2

    var k0 = AosAccKernel(AOS_KERNEL_SUM_COUNT_F64, 0, 0)
    var k1 = AosAccKernel(AOS_KERNEL_SUM_COUNT_F64, 16, 1)
    k0.call(Span(table), Span(offs), _col(values_a), 0, 2)
    k1.call(Span(table), Span(offs), _col(values_b), 0, 2)

    assert_equal(_f64_at(table, 0), Float64(20.0))
    assert_equal(_i64_at(table, 8), Int64(2))
    assert_equal(_f64_at(table, 16), Float64(3000.0))
    assert_equal(_i64_at(table, 24), Int64(2))
    print("  ok")


def test_rows_scatter_by_offset() raises:
    """Rows land in the entry their offset names; col_offset skips values."""
    print("test_rows_scatter_by_offset...")
    # Three 16B entries; rows 0..4 hit entries 2,0,2,1,2.
    var table = _zeroed(48)
    var offs = _offsets(32, 0, 32, 16, 32)
    # The column carries two leading values the kernel must skip.
    var values = _floats(999.0, 999.0, 1.0, 2.0, 4.0, 8.0, 16.0)
    AosAccKernel(AOS_KERNEL_SUM_COUNT_F64, 0, 0).call(
        Span(table), Span(offs), _col(values), 2, 5
    )
    # entry0: row1 (2.0); entry1: row3 (8.0); entry2: rows 0,2,4 (1+4+16).
    assert_equal(_f64_at(table, 0), Float64(2.0))
    assert_equal(_i64_at(table, 8), Int64(1))
    assert_equal(_f64_at(table, 16), Float64(8.0))
    assert_equal(_i64_at(table, 24), Int64(1))
    assert_equal(_f64_at(table, 32), Float64(21.0))
    assert_equal(_i64_at(table, 40), Int64(3))
    print("  ok")


def test_oversized_batch_is_refused() raises:
    """n beyond the offsets span, or a column shorter than col_offset + n,
    raises and writes nothing."""
    print("test_oversized_batch_is_refused...")
    var table = _zeroed(16)
    var offs = _offsets(0, 0)
    var values = _floats(1.0, 2.0)
    var k = AosAccKernel(AOS_KERNEL_SUM_COUNT_F64, 0, 0)

    var raised = False
    try:
        k.call(Span(table), Span(offs), _col(values), 0, 3)
    except:
        raised = True
    assert_true(raised, "n > len(entry_offsets) must raise")

    raised = False
    try:
        k.call(Span(table), Span(offs), _col(values), 1, 2)
    except:
        raised = True
    assert_true(raised, "col_offset + n past the column must raise")
    assert_equal(_f64_at(table, 0), Float64(0.0))
    assert_equal(_i64_at(table, 8), Int64(0))

    raised = False
    try:
        AosAccKernel(UInt8(99), 0, 0).call(Span(table), Span(offs), _col(values), 0, 2)
    except:
        raised = True
    assert_true(raised, "an unknown kernel kind must raise")
    print("  ok")


def test_layout_integration() raises:
    """AggLayout.sum_count_f64(n) offsets align with kernel agg_slot_offsets."""
    print("test_layout_integration...")
    var layout = AggLayout.sum_count_f64(3)
    assert_equal(layout.num_aggs, 3)
    assert_equal(layout.total_width, 48)  # 3 * 16
    assert_equal(acc_slot_width(ACC_SUM_COUNT_F64), 16)
    assert_equal(layout.offsets[0], 0)
    assert_equal(layout.offsets[1], 16)
    assert_equal(layout.offsets[2], 32)

    # Drive three kernels at the three offsets. One entry, three rows.
    var table = _zeroed(48)
    var offs = _offsets(0, 0, 0)
    var values = _floats(1.0, 2.0, 4.0)

    for a in range(layout.num_aggs):
        var k = AosAccKernel(
            AOS_KERNEL_SUM_COUNT_F64, layout.offsets[a], a
        )
        k.call(Span(table), Span(offs), _col(values), 0, 3)

    # Every slot reads the SAME values column here (a=0..2 all point at
    # `values`); they should all carry sum=7, count=3.
    for a in range(layout.num_aggs):
        assert_equal(_f64_at(table, layout.offsets[a]), Float64(7.0))
        assert_equal(_i64_at(table, layout.offsets[a] + 8), Int64(3))
    print("  ok")


def test_row_thunks_apply_one_value() raises:
    """AosRowThunk: one value, one slot, per tag; neighbours untouched."""
    print("test_row_thunks_apply_one_value...")
    # Quartet: sum, count, min, max at +0/+8/+16/+24, started at identity.
    var q = _zeroed(40)
    (q.unsafe_ptr() + 16).bitcast[Float64]()[] = Float64(1.0e300)
    (q.unsafe_ptr() + 24).bitcast[Float64]()[] = Float64(-1.0e300)
    (q.unsafe_ptr() + 32).bitcast[Int64]()[] = Int64(0x5EED)
    var quartet = resolve_row_thunk(ACC_SUM_COUNT_MIN_MAX_F64)
    quartet.call(Span(q), 0, 5.0)
    quartet.call(Span(q), 0, 2.0)
    assert_equal(_f64_at(q, 0), Float64(7.0))
    assert_equal(_i64_at(q, 8), Int64(2))
    assert_equal(_f64_at(q, 16), Float64(2.0))
    assert_equal(_f64_at(q, 24), Float64(5.0))
    assert_equal(_i64_at(q, 32), Int64(0x5EED))

    # sum+count at a non-zero slot offset.
    var sc = _zeroed(32)
    var sum_count = resolve_row_thunk(ACC_SUM_COUNT_F64)
    sum_count.call(Span(sc), 16, 3.0)
    sum_count.call(Span(sc), 16, 4.0)
    assert_equal(_f64_at(sc, 16), Float64(7.0))
    assert_equal(_i64_at(sc, 24), Int64(2))
    assert_equal(_i64_at(sc, 0), Int64(0))

    var s = _zeroed(8)
    resolve_row_thunk(ACC_SUM_F64).call(Span(s), 0, 1.5)
    resolve_row_thunk(ACC_SUM_F64).call(Span(s), 0, 2.0)
    assert_equal(_f64_at(s, 0), Float64(3.5))

    var c = _zeroed(8)
    resolve_row_thunk(ACC_COUNT_STAR).call(Span(c), 0, 0.0)
    resolve_row_thunk(ACC_COUNT_STAR).call(Span(c), 0, 123.0)
    assert_equal(_i64_at(c, 0), Int64(2))
    print("  ok")


def main() raises:
    test_thunk_writes_sum_and_count()
    test_kernel_wrapper_dispatches()
    test_two_kernels_disjoint_slots()
    test_rows_scatter_by_offset()
    test_oversized_batch_is_refused()
    test_layout_integration()
    test_row_thunks_apply_one_value()
    print("All AosAccKernel tests passed!")
