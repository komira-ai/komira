# =============================================================================
# Tests for AosAccKernel + sum_count_f64_aos_thunk (Session 5 atom 1)
# =============================================================================
#
# Verifies:
# 1. The thunk writes exactly two fields per row (sum @+0, count @+8).
# 2. AosAccKernel.call dispatches through the fn-pointer correctly.
# 3. Running the kernel N times with different agg_slot_offsets folds
#    values into disjoint slots of a single entry buffer.
# 4. After `n=num_rows` calls, sum and count agree with a hand-rolled
#    scalar aggregation.
# =============================================================================

from std.memory import alloc
from std.testing import assert_equal, assert_true

from komira_op_agg_state.accumulator_set import (
    AosAccKernel,
    sum_count_f64_aos_thunk,
)
from komira_core.agg_layout import (
    ACC_SUM_COUNT_F64,
    AggLayout,
    acc_slot_width,
)


def test_thunk_writes_sum_and_count() raises:
    """The thunk writes [sum:f64 @+0][count:i64 @+8] for each row."""
    print("test_thunk_writes_sum_and_count...")
    # One synthetic entry region: 16 bytes, zero-initialised.
    # The thunk will read the row's entry pointer, land at
    # (entry + agg_slot_offset), and write sum / count.
    var entry_bytes = alloc[UInt8](16)
    for b in range(16):
        (entry_bytes + b).unsafe_write(UInt8(0))

    # One "row" whose EntryHandle points at entry_bytes. The thunk reads
    # an Int from entries_raw + row*8. EntryHandle is TrivialRegisterPassable
    # over a single pointer, so storing the pointer address as an Int is
    # the byte-identical shape.
    var num_rows = 3
    var entries = alloc[Int](num_rows)
    var entry_addr = Int(entry_bytes)
    for r in range(num_rows):
        (entries + r).unsafe_write(entry_addr)

    # Values to accumulate: [10.0, 20.0, 30.0] -> sum=60.0, count=3.
    var values = alloc[Float64](num_rows)
    (values + 0).unsafe_write(Float64(10.0))
    (values + 1).unsafe_write(Float64(20.0))
    (values + 2).unsafe_write(Float64(30.0))

    # Drive the thunk directly (no kernel wrapper yet).
    sum_count_f64_aos_thunk(
        Int(entries),
        Int(values.bitcast[UInt8]()),
        0,
        0,
        num_rows,
    )

    # Read back: sum at +0 (Float64), count at +8 (Int64).
    var sum_p = entry_bytes.bitcast[Float64]()
    var count_p = (entry_bytes + 8).bitcast[Int64]()
    assert_equal(sum_p[], Float64(60.0))
    assert_equal(count_p[], Int64(3))

    entry_bytes.free()
    entries.free()
    values.free()
    print("  ok")


def test_kernel_wrapper_dispatches() raises:
    """AosAccKernel.call with sum_count_f64_aos_thunk dispatches correctly."""
    print("test_kernel_wrapper_dispatches...")
    var entry_bytes = alloc[UInt8](16)
    for b in range(16):
        (entry_bytes + b).unsafe_write(UInt8(0))

    var num_rows = 4
    var entries = alloc[Int](num_rows)
    var entry_addr = Int(entry_bytes)
    for r in range(num_rows):
        (entries + r).unsafe_write(entry_addr)

    var values = alloc[Float64](num_rows)
    (values + 0).unsafe_write(Float64(1.0))
    (values + 1).unsafe_write(Float64(2.0))
    (values + 2).unsafe_write(Float64(3.0))
    (values + 3).unsafe_write(Float64(4.0))

    var kernel = AosAccKernel(
        _fn=sum_count_f64_aos_thunk,
        _agg_slot_offset=0,
        _value_col_index=0,
    )
    kernel.call(
        Int(entries),
        Int(values.bitcast[UInt8]()),
        0,
        num_rows,
    )

    var sum_p = entry_bytes.bitcast[Float64]()
    var count_p = (entry_bytes + 8).bitcast[Int64]()
    assert_equal(sum_p[], Float64(10.0))
    assert_equal(count_p[], Int64(4))

    entry_bytes.free()
    entries.free()
    values.free()
    print("  ok")


def test_two_kernels_disjoint_slots() raises:
    """Two kernels at different agg_slot_offsets hit disjoint 16B slots."""
    print("test_two_kernels_disjoint_slots...")
    # Two 16B slots back-to-back inside one 32B entry buffer.
    var entry_bytes = alloc[UInt8](32)
    for b in range(32):
        (entry_bytes + b).unsafe_write(UInt8(0))

    var num_rows = 2
    var entries = alloc[Int](num_rows)
    var entry_addr = Int(entry_bytes)
    for r in range(num_rows):
        (entries + r).unsafe_write(entry_addr)

    # Values column A: [5.0, 15.0]  -> slot0 sum=20 count=2
    var values_a = alloc[Float64](num_rows)
    (values_a + 0).unsafe_write(Float64(5.0))
    (values_a + 1).unsafe_write(Float64(15.0))

    # Values column B: [1000.0, 2000.0]  -> slot1 sum=3000 count=2
    var values_b = alloc[Float64](num_rows)
    (values_b + 0).unsafe_write(Float64(1000.0))
    (values_b + 1).unsafe_write(Float64(2000.0))

    var k0 = AosAccKernel(
        _fn=sum_count_f64_aos_thunk,
        _agg_slot_offset=0,
        _value_col_index=0,
    )
    var k1 = AosAccKernel(
        _fn=sum_count_f64_aos_thunk,
        _agg_slot_offset=16,
        _value_col_index=1,
    )
    k0.call(Int(entries), Int(values_a.bitcast[UInt8]()), 0, num_rows)
    k1.call(Int(entries), Int(values_b.bitcast[UInt8]()), 0, num_rows)

    # Slot 0: sum=20, count=2
    assert_equal(entry_bytes.bitcast[Float64]()[], Float64(20.0))
    assert_equal((entry_bytes + 8).bitcast[Int64]()[], Int64(2))
    # Slot 1: sum=3000, count=2
    assert_equal((entry_bytes + 16).bitcast[Float64]()[], Float64(3000.0))
    assert_equal((entry_bytes + 24).bitcast[Int64]()[], Int64(2))

    entry_bytes.free()
    entries.free()
    values_a.free()
    values_b.free()
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
    var entry_bytes = alloc[UInt8](48)
    for b in range(48):
        (entry_bytes + b).unsafe_write(UInt8(0))

    var num_rows = 3
    var entries = alloc[Int](num_rows)
    var entry_addr = Int(entry_bytes)
    for r in range(num_rows):
        (entries + r).unsafe_write(entry_addr)

    var values = alloc[Float64](num_rows)
    (values + 0).unsafe_write(Float64(1.0))
    (values + 1).unsafe_write(Float64(2.0))
    (values + 2).unsafe_write(Float64(4.0))

    for a in range(layout.num_aggs):
        var k = AosAccKernel(
            _fn=sum_count_f64_aos_thunk,
            _agg_slot_offset=layout.offsets[a],
            _value_col_index=a,
        )
        k.call(Int(entries), Int(values.bitcast[UInt8]()), 0, num_rows)

    # Every slot reads the SAME values column here (a=0..2 all point at
    # `values`); they should all carry sum=7, count=3.
    for a in range(layout.num_aggs):
        var base = entry_bytes + layout.offsets[a]
        assert_equal(base.bitcast[Float64]()[], Float64(7.0))
        assert_equal((base + 8).bitcast[Int64]()[], Int64(3))

    entry_bytes.free()
    entries.free()
    values.free()
    print("  ok")


def main() raises:
    test_thunk_writes_sum_and_count()
    test_kernel_wrapper_dispatches()
    test_two_kernels_disjoint_slots()
    test_layout_integration()
    print("All AosAccKernel tests passed!")
