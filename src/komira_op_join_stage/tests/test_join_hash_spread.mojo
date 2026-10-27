# =============================================================================
# test_join_hash_spread -- the home slot spreads keys whose scrambled hash has
# constant low bits, a composite hash tells column order and repeated columns
# apart, and the batch-row path compares every key column
# =============================================================================
#
# What each test proves:
#   * `test_integral_f64_keys_spread`: 3000 FLOAT64 keys 1.0, 2.0, ... (their
#     low mantissa bits are all zero) do not pile into one run of occupied
#     slots; the longest run stays at or below a quarter of the capacity.
#   * `test_small_integral_f32_keys_spread`: the same for FLOAT32 keys.
#   * `test_power_of_two_multiple_int_keys_spread`: the same for INT64 keys
#     that are multiples of 2^20.
#   * `test_equal_column_pairs_spread`: (x, x) float pairs do not pile up.
#   * `test_equal_columns_and_swapped_columns_hash_apart`: the composite hash
#     of (x, x) is not 0, and (a, b) and (b, a) hash differently.
#   * `test_batch_probe_compares_every_key_column_*`: a probe row equal to a
#     build row in the leading columns and different in a later column finds
#     nothing, through `probe_batch_row_first` and `probe_batch_row` (with and
#     without the duplicate-key walk), on a full table so that every probe
#     visits every slot.
# The spread bound is a count of occupied slots, not a time.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_buffer.heap_region import HeapRegion

from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_build_table_fns import (
    join_build_insert_slot_1,
    join_build_insert_slot_2,
)
from komira_op_join_stage.join_key_bundle import (
    KeyBundle,
    KeyBundle1,
    KeyBundle2,
    KeyBundle3,
    make_key_bundle_1,
    make_key_bundle_2,
    make_key_bundle_3,
)
from komira_op_join_stage.join_payload_column import (
    PayloadBlock,
    PayloadColumn,
    PayloadSlot,
    payload_slot,
)

comptime I64 = DType.int64
comptime N_KEYS = 3000


def _longest_run[
    KB: KeyBundle, *P: PayloadColumn
](t: JoinBuildTable[KB, *P]) -> Int:
    """The longest run of consecutive occupied slots, wrapping around."""
    var cap = t.capacity()
    var best = 0
    var run = 0
    for i in range(2 * cap):
        if t.keys.slot_is_empty(i % cap):
            run = 0
        else:
            run += 1
            if run > best:
                best = run
    return min(best, cap)


def test_integral_f64_keys_spread() raises:
    comptime F64 = DType.float64
    var t = JoinBuildTable[KeyBundle1[F64], PayloadSlot[I64]](
        make_key_bundle_1[F64](64),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](64)),
        64,
    )
    for i in range(N_KEYS):
        _ = join_build_insert_slot_1(t, Float64(i + 1))
    assert_equal(t.n_rows(), N_KEYS)
    assert_true(
        _longest_run(t) <= t.capacity() // 4,
        "integral FLOAT64 keys must not form one run of occupied slots",
    )


def test_small_integral_f32_keys_spread() raises:
    comptime F32 = DType.float32
    var t = JoinBuildTable[KeyBundle1[F32], PayloadSlot[I64]](
        make_key_bundle_1[F32](64),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](64)),
        64,
    )
    for i in range(N_KEYS):
        _ = join_build_insert_slot_1(t, Float32(i + 1))
    assert_true(
        _longest_run(t) <= t.capacity() // 4,
        "integral FLOAT32 keys must not form one run of occupied slots",
    )


def test_power_of_two_multiple_int_keys_spread() raises:
    var t = JoinBuildTable[KeyBundle1[I64], PayloadSlot[I64]](
        make_key_bundle_1[I64](64),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](64)),
        64,
    )
    for i in range(N_KEYS):
        _ = join_build_insert_slot_1(t, Int64(i + 1) * Int64(1048576))
    assert_true(
        _longest_run(t) <= t.capacity() // 4,
        "INT64 multiples of 2^20 must not form one run of occupied slots",
    )


def test_equal_column_pairs_spread() raises:
    comptime F64 = DType.float64
    var t = JoinBuildTable[KeyBundle2[F64, F64], PayloadSlot[I64]](
        make_key_bundle_2[F64, F64](64),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](64)),
        64,
    )
    for i in range(N_KEYS):
        var x = Float64(i + 1) + 0.5
        _ = join_build_insert_slot_2(t, x, x)
    assert_true(
        _longest_run(t) <= t.capacity() // 4,
        "(x, x) keys must not form one run of occupied slots",
    )


def test_equal_columns_and_swapped_columns_hash_apart() raises:
    var same = make_key_bundle_2[I64, I64](16)
    same.cols[0].write_value(3, Int64(12345))
    same.cols[1].write_value(3, Int64(12345))
    assert_true(same.slot_hash(3) != 0, "(x, x) must not hash to 0")

    var ab = make_key_bundle_2[I64, I64](16)
    ab.cols[0].write_value(1, Int64(7))
    ab.cols[1].write_value(1, Int64(9))
    var ba = make_key_bundle_2[I64, I64](16)
    ba.cols[0].write_value(1, Int64(9))
    ba.cols[1].write_value(1, Int64(7))
    assert_true(ab.slot_hash(1) != ba.slot_hash(1), "(a, b) != (b, a)")


# -----------------------------------------------------------------------------
# The batch-row path compares every key column
# -----------------------------------------------------------------------------


def _col(values: List[Int64]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[I64].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
    return Column.from_primitive[I64](a^)


def _batch2(c0: List[Int64], c1: List[Int64]) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_2(
        Schema.from_fields_2(Field("a", I64, True), Field("b", I64, True)),
        _col(c0),
        _col(c1),
    )


def _batch3(
    c0: List[Int64], c1: List[Int64], c2: List[Int64]
) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_3(
        Schema.from_fields_3(
            Field("a", I64, True), Field("b", I64, True), Field("c", I64, True)
        ),
        _col(c0),
        _col(c1),
        _col(c2),
    )


def _insert2[
    bo: Origin[mut=False]
](mut bundle: KeyBundle2[I64, I64], bv: BatchView[bo]) raises -> Bool:
    """Insert every row of `bv` (columns 0 and 1); True iff a key repeated."""
    var n_used = 0
    var saw_dup = False
    for r in range(bv.n_rows()):
        _ = bundle.build_insert_row[bo, 0, 1, 0, 0](bv, r, n_used, 3, saw_dup)
    return saw_dup


def _first2[
    bo: Origin[mut=False]
](bundle: KeyBundle2[I64, I64], bv: BatchView[bo], row: Int) raises -> Int:
    return bundle.probe_batch_row_first[bo, 0, 1, 0, 0](bv, row, 3)


def _insert3[
    bo: Origin[mut=False]
](mut bundle: KeyBundle3[I64, I64, I64], bv: BatchView[bo]) raises:
    var n_used = 0
    var saw_dup = False
    for r in range(bv.n_rows()):
        _ = bundle.build_insert_row[bo, 0, 1, 2, 0](bv, r, n_used, 3, saw_dup)


def _first3[
    bo: Origin[mut=False]
](
    bundle: KeyBundle3[I64, I64, I64], bv: BatchView[bo], row: Int
) raises -> Int:
    return bundle.probe_batch_row_first[bo, 0, 1, 2, 0](bv, row, 3)


def _hits3[
    bo: Origin[mut=False]
](
    bundle: KeyBundle3[I64, I64, I64], bv: BatchView[bo], row: Int
) raises -> Int:
    var out = List[Int]()
    bundle.probe_batch_row[bo, 0, 1, 2, 0](bv, row, 3, True, out)
    return len(out)


def _hits2[
    bo: Origin[mut=False]
](
    bundle: KeyBundle2[I64, I64], bv: BatchView[bo], row: Int, has_dups: Bool
) raises -> Int:
    var out = List[Int]()
    bundle.probe_batch_row[bo, 0, 1, 0, 0](bv, row, 3, has_dups, out)
    return len(out)


def test_batch_probe_compares_every_key_column_arity2() raises:
    # Four rows fill a four-slot table: every probe walks every slot, so a
    # probe is decided by the comparison and not by where it starts.
    var build = _batch2([1, 2, 3, 4], [10, 20, 30, 40])
    var bv = batch_view_over(build)
    var bundle = make_key_bundle_2[I64, I64](4)
    assert_false(_insert2(bundle, bv))

    # Rows 0..3 agree with a build row in column 0 only; rows 4 and 5 agree in
    # column 1 only; rows 6 and 7 equal build rows.
    var probe = _batch2(
        [1, 2, 3, 4, 9, 9, 1, 4], [11, 99, 31, 0, 10, 20, 10, 40]
    )
    var pv = batch_view_over(probe)
    for r in range(6):
        assert_equal(
            _first2(bundle, pv, r),
            -1,
            "first: a key differing in column 1 misses",
        )
        assert_equal(_hits2(bundle, pv, r, False), 0, "all: misses")
        assert_equal(_hits2(bundle, pv, r, True), 0, "all with dups: misses")
    for r in range(6, 8):
        assert_true(_first2(bundle, pv, r) >= 0)
        assert_equal(_hits2(bundle, pv, r, False), 1)
        assert_equal(_hits2(bundle, pv, r, True), 1)


def test_batch_probe_compares_every_key_column_duplicates() raises:
    var build = _batch2([1, 1, 2, 2], [10, 10, 20, 21])
    var bv = batch_view_over(build)
    var bundle = make_key_bundle_2[I64, I64](4)
    assert_true(_insert2(bundle, bv), "(1, 10) twice is a duplicate key")

    var probe = _batch2([1, 1, 2, 2, 2], [10, 11, 20, 21, 22])
    var pv = batch_view_over(probe)
    assert_equal(_hits2(bundle, pv, 0, True), 2, "(1, 10) matches both rows")
    assert_equal(_hits2(bundle, pv, 1, True), 0, "(1, 11) matches none")
    assert_equal(_hits2(bundle, pv, 2, True), 1)
    assert_equal(_hits2(bundle, pv, 3, True), 1)
    assert_equal(_hits2(bundle, pv, 4, True), 0, "(2, 22) matches none")


def test_batch_probe_compares_every_key_column_arity3() raises:
    var build = _batch3([1, 2, 3, 4], [10, 20, 30, 40], [100, 200, 300, 400])
    var bv = batch_view_over(build)
    var bundle = make_key_bundle_3[I64, I64, I64](4)
    _insert3(bundle, bv)

    # Row 0 differs from a build row in column 1 only, row 1 in column 2 only,
    # row 2 in columns 1 and 2, row 3 equals a build row.
    var probe = _batch3([1, 2, 3, 4], [11, 20, 31, 40], [100, 201, 301, 400])
    var pv = batch_view_over(probe)
    for r in range(3):
        assert_equal(_first3(bundle, pv, r), -1)
        assert_equal(_hits3(bundle, pv, r), 0)
    assert_true(_first3(bundle, pv, 3) >= 0)
    assert_equal(_hits3(bundle, pv, 3), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
