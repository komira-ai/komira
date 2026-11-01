# =============================================================================
# test_join_stage_key_model -- the keys of the stage join build table follow
# the query semantics (docs/design/query_semantics.md): every value of the key
# type is a key, float keys follow the float model (3.9 and 2.6: every NaN
# equals every NaN, -0.0 equals +0.0), and a NULL key matches nothing, as in
# DuckDB. The batch-row path and the free functions agree, before and after
# the table grows and across `combine`.
# =============================================================================
#
# What each test proves:
#   * `test_minus_one_is_a_key`: a -1 build row is found by a probe of -1, and
#     a second -1 takes its own slot (no key value stands for an empty slot).
#   * `test_unsigned_max_and_bool_true_are_keys`: the same holds for
#     UInt64.MAX as an unsigned key and True as a BOOL key.
#   * `test_f64_nan_keys_match` / `test_f32_nan_keys_match`: NaNs of different
#     sign or payload are one key.
#   * `test_signed_zero_keys_match`: -0.0 and +0.0 are one key.
#   * `test_null_probe_key_matches_nothing`: a NULL probe cell carries value
#     bits (0 here) that do not match the build key 0.
#   * `test_free_functions_and_batch_path_share_the_hash`: the free functions
#     and the batch-row path hash a key the same way: 4.25 and 4.75 stay
#     distinct, a free-function probe finds its rows after the table grows,
#     and a batch-path probe finds a free-function insert.
#   * `test_combine_merges_equal_nan_keys`: `combine` sets
#     `has_duplicate_keys` for two NaN rows, so a probe walks every match.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_buffer.heap_region import HeapRegion

from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_build_table_fns import (
    join_build_insert_slot_1,
    join_build_probe_1,
    join_build_probe_all_slots_1,
)
from komira_op_join_stage.join_key_bundle import (
    KeyBundle1,
    KeyBundleVar,
    make_key_bundle_1,
)
from komira_op_join_stage.join_key_slot import KeySlot
from komira_op_join_stage.join_payload_column import (
    PayloadBlock,
    PayloadSlot,
    payload_slot,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _col[
    dt: DType
](values: List[Scalar[dt]], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[dt].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
        if i < len(nulls) and nulls[i]:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _batch[
    dt: DType
](values: List[Scalar[dt]], nulls: List[Bool] = []) raises -> RecordBatch:
    """A one-column batch `k` of `values`; `nulls[i]` makes row i NULL."""
    return RecordBatch.from_typed_columns_1(
        Schema.from_fields_1(Field("k", dt, True)), _col[dt](values, nulls)
    )


def _insert_all[
    K: DType, bo: Origin[mut=False]
](
    mut bundle: KeyBundleVar[KeySlot[K]],
    bv: BatchView[bo],
    mut n_used: Int,
    mut saw_dup: Bool,
) raises:
    """Insert every row of `bv` into a 64-slot bundle."""
    for r in range(bv.n_rows()):
        _ = bundle.build_insert_row[bo, 0, 0, 0, 0](bv, r, n_used, 63, saw_dup)


def _first[
    K: DType, bo: Origin[mut=False]
](bundle: KeyBundleVar[KeySlot[K]], bv: BatchView[bo], row: Int) raises -> Int:
    return bundle.probe_batch_row_first[bo, 0, 0, 0, 0](bv, row, 63)


def _all[
    K: DType, bo: Origin[mut=False]
](bundle: KeyBundleVar[KeySlot[K]], bv: BatchView[bo], row: Int) raises -> Int:
    """How many slots match probe row `row` (the M:N walk)."""
    var out = List[Int]()
    bundle.probe_batch_row[bo, 0, 0, 0, 0](bv, row, 63, True, out)
    return len(out)


def _first_in_table[
    bo: Origin[mut=False]
](
    t: JoinBuildTable[KeyBundle1[DType.float64], PayloadSlot[DType.int64]],
    bv: BatchView[bo],
    row: Int,
) raises -> Int:
    return t.keys.probe_batch_row_first[bo, 0, 0, 0, 0](
        bv, row, t.capacity_mask
    )


def _f64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _f32(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


# -----------------------------------------------------------------------------
# Every value is a key
# -----------------------------------------------------------------------------


def test_minus_one_is_a_key() raises:
    comptime I64 = DType.int64
    var bundle = make_key_bundle_1[I64](64)
    var build = _batch[I64]([-1, 7, -1])
    var bv = batch_view_over(build)
    var n_used = 0
    var saw_dup = False
    _insert_all[I64](bundle, bv, n_used, saw_dup)
    assert_equal(n_used, 3)
    assert_true(saw_dup, "the second -1 sees the first")

    var probe = _batch[I64]([-1, 7, 8])
    var pv = batch_view_over(probe)
    assert_equal(_all[I64](bundle, pv, 0), 2, "both -1 rows match -1")
    assert_true(_first[I64](bundle, pv, 1) >= 0, "7 matches")
    assert_equal(_first[I64](bundle, pv, 2), -1, "8 misses")

    # The free functions: -1 inserted twice, found twice.
    var t = JoinBuildTable[KeyBundle1[I64], PayloadSlot[I64]](
        make_key_bundle_1[I64](8),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](8)),
        8,
    )
    _ = join_build_insert_slot_1(t, Int64(-1))
    _ = join_build_insert_slot_1(t, Int64(-1))
    assert_true(t.has_duplicate_keys)
    var hits = List[Int]()
    join_build_probe_all_slots_1(t, Int64(-1), hits)
    assert_equal(len(hits), 2)


def test_unsigned_max_and_bool_true_are_keys() raises:
    comptime U64 = DType.uint64
    var tu = JoinBuildTable[KeyBundle1[U64], PayloadSlot[U64]](
        make_key_bundle_1[U64](8),
        PayloadBlock[PayloadSlot[U64]](payload_slot[U64](8)),
        8,
    )
    _ = join_build_insert_slot_1(tu, UInt64.MAX)
    _ = join_build_insert_slot_1(tu, UInt64(3))
    assert_true(join_build_probe_1(tu, UInt64.MAX) >= 0, "UInt64.MAX found")
    assert_true(join_build_probe_1(tu, UInt64(3)) >= 0)
    assert_false(tu.has_duplicate_keys)

    comptime B = DType.bool
    var tb = JoinBuildTable[KeyBundle1[B], PayloadSlot[DType.int64]](
        make_key_bundle_1[B](8),
        PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](8)),
        8,
    )
    _ = join_build_insert_slot_1(tb, Scalar[B](True))
    _ = join_build_insert_slot_1(tb, Scalar[B](False))
    assert_true(join_build_probe_1(tb, Scalar[B](True)) >= 0, "True found")
    assert_true(join_build_probe_1(tb, Scalar[B](False)) >= 0, "False found")
    assert_false(tb.has_duplicate_keys, "True and False are two keys")


# -----------------------------------------------------------------------------
# The float model
# -----------------------------------------------------------------------------


def test_f64_nan_keys_match() raises:
    comptime F64 = DType.float64
    var bundle = make_key_bundle_1[F64](64)
    var build = _batch[F64]([_f64(0x7FF8000000000000), Float64(1.0)])
    var bv = batch_view_over(build)
    var n_used = 0
    var saw_dup = False
    _insert_all[F64](bundle, bv, n_used, saw_dup)

    # A negative NaN with a payload, and the quiet NaN itself.
    var probe = _batch[F64](
        [_f64(0xFFF8000000000001), _f64(0x7FF8000000000000), _f64(0x7FF0000000000001)]
    )
    var pv = batch_view_over(probe)
    assert_true(_first[F64](bundle, pv, 0) >= 0, "-NaN(1) matches NaN")
    assert_true(_first[F64](bundle, pv, 1) >= 0, "NaN matches NaN")
    assert_true(_first[F64](bundle, pv, 2) >= 0, "signalling NaN matches NaN")


def test_f32_nan_keys_match() raises:
    comptime F32 = DType.float32
    var bundle = make_key_bundle_1[F32](64)
    var build = _batch[F32]([_f32(0x7FC00000), Float32(2.0)])
    var bv = batch_view_over(build)
    var n_used = 0
    var saw_dup = False
    _insert_all[F32](bundle, bv, n_used, saw_dup)
    var probe = _batch[F32]([_f32(0xFFC00007), Float32(2.0), Float32(3.0)])
    var pv = batch_view_over(probe)
    assert_true(_first[F32](bundle, pv, 0) >= 0, "-NaN(7) matches NaN")
    assert_true(_first[F32](bundle, pv, 1) >= 0)
    assert_equal(_first[F32](bundle, pv, 2), -1)


def test_signed_zero_keys_match() raises:
    comptime F64 = DType.float64
    var bundle = make_key_bundle_1[F64](64)
    var build = _batch[F64]([Float64(-0.0), Float64(-0.0)])
    var bv = batch_view_over(build)
    var n_used = 0
    var saw_dup = False
    _insert_all[F64](bundle, bv, n_used, saw_dup)
    assert_true(saw_dup, "-0.0 twice is a duplicate")
    var probe = _batch[F64]([Float64(0.0)])
    var pv = batch_view_over(probe)
    assert_equal(_all[F64](bundle, pv, 0), 2, "+0.0 matches both -0.0 rows")
    # The stored key keeps its own sign (what a build-key emit reads back).
    var slot = _first[F64](bundle, pv, 0)
    assert_equal(bundle.key_bits_at_slot[0](slot), UInt64(0x8000000000000000))


def test_null_probe_key_matches_nothing() raises:
    comptime I64 = DType.int64
    var bundle = make_key_bundle_1[I64](64)
    var build = _batch[I64]([0])
    var bv = batch_view_over(build)
    var n_used = 0
    var saw_dup = False
    _insert_all[I64](bundle, bv, n_used, saw_dup)
    var probe = _batch[I64]([0, 0], [True, False])
    var pv = batch_view_over(probe)
    assert_equal(_first[I64](bundle, pv, 0), -1, "NULL matches nothing")
    assert_equal(_all[I64](bundle, pv, 0), 0, "nor on the M:N walk")
    assert_true(_first[I64](bundle, pv, 1) >= 0, "a real 0 matches")


# -----------------------------------------------------------------------------
# One hash for every path
# -----------------------------------------------------------------------------


def test_free_functions_and_batch_path_share_the_hash() raises:
    comptime F64 = DType.float64
    var t = JoinBuildTable[KeyBundle1[F64], PayloadSlot[DType.int64]](
        make_key_bundle_1[F64](8),
        PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](8)),
        8,
    )
    # 100 fractional keys through the free function: the table grows (8 ->
    # 256 slots) and rehashes with the slot hash.
    for i in range(100):
        _ = join_build_insert_slot_1(t, Float64(i) + 0.25)
    assert_true(t.capacity() >= 128)
    assert_false(t.has_duplicate_keys)
    for i in range(100):
        assert_true(
            join_build_probe_1(t, Float64(i) + 0.25) >= 0,
            "a free-function insert is found by the free-function probe",
        )
    assert_equal(join_build_probe_1(t, Float64(4.75)), -1)

    # The batch path probes the same table.
    var vals = List[Float64]()
    for i in range(100):
        vals.append(Float64(i) + 0.25)
    var probe = _batch[F64](vals)
    var pv = batch_view_over(probe)
    for r in range(100):
        assert_true(
            _first_in_table(t, pv, r) >= 0,
            "a free-function insert is found by the batch path",
        )


def test_combine_merges_equal_nan_keys() raises:
    comptime F64 = DType.float64
    comptime I64 = DType.int64
    var a = JoinBuildTable[KeyBundle1[F64], PayloadSlot[I64]](
        make_key_bundle_1[F64](8),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](8)),
        8,
    )
    var b = JoinBuildTable[KeyBundle1[F64], PayloadSlot[I64]](
        make_key_bundle_1[F64](8),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](8)),
        8,
    )
    var sa = join_build_insert_slot_1(a, _f64(0x7FF8000000000000))
    a.payload[0].write_slot(sa, Int64(1))
    var sb = join_build_insert_slot_1(b, _f64(0xFFF8000000000002))
    b.payload[0].write_slot(sb, Int64(2))
    assert_false(a.has_duplicate_keys)
    assert_false(b.has_duplicate_keys)
    a.combine(b^)
    assert_equal(a.n_rows(), 2)
    assert_true(a.has_duplicate_keys, "two NaN rows are a duplicate key")
    var hits = List[Int]()
    join_build_probe_all_slots_1(a, _f64(0x7FF8000000000000), hits)
    assert_equal(len(hits), 2)
    var total = Int64(0)
    for i in range(len(hits)):
        total += a.payload[0].read_slot(hits[i])
    assert_equal(total, 3, "both payloads came across")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
