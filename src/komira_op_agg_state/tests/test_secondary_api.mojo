# =============================================================================
# test_secondary_api.mojo — the Int32 / Float32 table variants and the less
# used entry points of the accumulators and sets
# =============================================================================
#
#   ByteHashAggTableI32 / F32, HashAggTableI32 / F32
#       groups keyed by bytes or Int64 fold Int32 / Float32 values per group;
#       a key seen twice is one group; key_at returns the key.
#   ByteHashSet.row_bytes            a COPY of a stored row's bytes.
#   GrowableHashSetI64.new / into_keys
#       the drained key list is the distinct keys in first-insert order.
#   PercentileAcc.append_batch       the same fold as update_batch (NaN skipped).
#   CountDistinctAcc finalize_to_column / flush_partial / num_groups
#       the per-group distinct count.
#   ColumnarAccumulator.merge_at     tag mismatch refused; MIN/MAX utf8 fold
#       a seen source and skip an unseen or out-of-range one; SUM/COUNT add.
#   AggFnAcc.flush_partial_to_column is its finalize.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.byte_hash_agg_table import (
    ByteHashAggTableI32, ByteHashAggTableF32,
)
from komira_op_agg_state.hash_agg_table import HashAggTableI32, HashAggTableF32
from komira_op_agg_state.agg_state_slab import SumI32, MaxI32, SumF32, MinF32
from komira_op_agg_state.byte_hashset import ByteHashSet
from komira_op_agg_state.growable_hash_set_i64 import GrowableHashSetI64
from komira_op_agg_state.columnar_acc_agg import PercentileAcc, CountDistinctAcc
from komira_op_agg_state.columnar_agg_accumulator import ColumnarAccumulator
from komira_op_agg_state.agg_fn_acc import AggFnAcc
from komira_agg.builtin_agg_fns_sum import SumF64 as UdfSumF64
from komira_collections.dyn_value import DynValue
from komira_op_agg_state.dyn_accumulator import MAX_ACC_SIZE
from komira_op_agg_state.accumulator_factory import (
    _fin_int64_count_distinct,
    _merge_at_count_distinct,
    _merge_aligned_count_distinct,
)


def _bytes_of(s: String) -> List[UInt8]:
    var sb = s.as_bytes()
    var out = List[UInt8](capacity=len(sb))
    for k in range(len(sb)):
        out.append(sb[k])
    return out^


# =============================================================================
# Int32 / Float32 tables
# =============================================================================


def test_byte_hash_agg_table_i32_and_f32() raises:
    var ka = _bytes_of("alpha")
    var kb = _bytes_of("beta")
    var ti = ByteHashAggTableI32[SumI32]()
    ti.update_scalar(Span(ka), Int32(5))
    ti.update_scalar(Span(kb), Int32(-2))
    ti.update_scalar(Span(ka), Int32(7))
    assert_equal(ti.size(), 2)
    assert_equal(ti.finalize_at(0), Int32(12))
    assert_equal(ti.finalize_at(1), Int32(-2))
    assert_equal(len(ti.key_at(1)), 4)
    assert_equal(ti.key_at(0)[0], UInt8(ord("a")))
    assert_equal(ti.lookup_or_insert(Span(kb)), 1)

    var tf = ByteHashAggTableF32[MinF32]()
    tf.update_scalar(Span(kb), Float32(1.5))
    tf.update_scalar(Span(kb), Float32(-0.5))
    tf.update_scalar(Span(ka), Float32(3.0))
    assert_equal(tf.size(), 2)
    assert_equal(tf.finalize_at(0), Float32(-0.5))
    assert_equal(tf.finalize_at(1), Float32(3.0))
    assert_equal(len(tf.key_at(0)), 4)
    assert_equal(tf.lookup_or_insert(Span(ka)), 1)


def test_hash_agg_table_i32_and_f32() raises:
    var ti = HashAggTableI32[MaxI32]()
    ti.update_scalar(Int64(10), Int32(-4))
    ti.update_scalar(Int64(20), Int32(9))
    ti.update_scalar(Int64(10), Int32(-1))
    assert_equal(ti.size(), 2)
    assert_equal(ti.finalize_at(0), Int32(-1))
    assert_equal(ti.key_at(1), Int64(20))

    var tf = HashAggTableF32[SumF32]()
    tf.update_scalar(Int64(-3), Float32(0.25))
    tf.update_scalar(Int64(-3), Float32(0.5))
    assert_equal(tf.size(), 1)
    assert_equal(tf.finalize_at(0), Float32(0.75))
    assert_equal(tf.key_at(0), Int64(-3))


# =============================================================================
# Sets
# =============================================================================


def test_byte_hashset_row_bytes_is_a_copy() raises:
    var s = ByteHashSet()
    var a = _bytes_of("xyz")
    var b = _bytes_of("")
    var c = _bytes_of("pq")
    _ = s.insert_serialized(UInt64(1), Span(a))
    _ = s.insert_serialized(UInt64(2), Span(b))
    _ = s.insert_serialized(UInt64(3), Span(c))
    var r = s.row_bytes(0)
    assert_equal(len(r), 3)
    assert_equal(r[0], UInt8(ord("x")))
    assert_equal(r[2], UInt8(ord("z")))
    r[0] = UInt8(0)
    assert_equal(s.row_bytes(0)[0], UInt8(ord("x")), "row_bytes must copy")
    assert_equal(len(s.row_bytes(1)), 0)
    var r2 = s.row_bytes(2)
    assert_equal(len(r2), 2)
    assert_equal(r2[0], UInt8(ord("p")))
    assert_equal(r2[1], UInt8(ord("q")))


def test_growable_set_new_and_into_keys() raises:
    var s = GrowableHashSetI64.new(4)
    var ins: List[Int64] = [Int64(5), Int64(-9), Int64(5), Int64(100), Int64(-9), Int64(0)]
    for i in range(len(ins)):
        _ = s.insert(ins[i])
    assert_equal(s.size(), 4)
    var keys = s^.into_keys()
    assert_equal(len(keys), 4)
    assert_equal(keys[0], Int64(5))
    assert_equal(keys[1], Int64(-9))
    assert_equal(keys[2], Int64(100))
    assert_equal(keys[3], Int64(0))


# =============================================================================
# PercentileAcc.append_batch, CountDistinctAcc column readback
# =============================================================================


def test_percentile_append_batch_is_update_batch() raises:
    var a = PercentileAcc.new(0.5)
    a.ensure_capacity(2)
    var nan = Float64(0.0) / Float64(0.0)
    var g: List[UInt32] = [UInt32(0), UInt32(1), UInt32(0), UInt32(1)]
    var v: List[Float64] = [Float64(1.0), nan, Float64(3.0), Float64(8.0)]
    a.append_batch(Span(g), Span(v), 4)
    assert_equal(len(a.values[0]), 2)
    assert_equal(len(a.values[1]), 1, "NaN is not appended")
    assert_equal(a._finalize_one(0).value(), Float64(2.0))
    assert_equal(a._finalize_one(1).value(), Float64(8.0))


def test_count_distinct_column_readback() raises:
    var a = CountDistinctAcc.new()
    a.ensure_capacity(3)
    assert_equal(a.num_groups(), 3)
    var g: List[UInt32] = [UInt32(0), UInt32(0), UInt32(0), UInt32(1), UInt32(0)]
    var v: List[Int64] = [Int64(4), Int64(-1), Int64(4), Int64(9), Int64(7)]
    a.update_batch(Span(g), Span(v), 5)
    var col = a.finalize_to_column()
    var p = col._data.view_typed_ro[DType.int64]()
    assert_equal(col.length(), 3)
    assert_equal(p[0], Int64(3))
    assert_equal(p[1], Int64(1))
    assert_equal(p[2], Int64(0))
    var fl = a.flush_partial_to_column()
    assert_equal(fl._data.view_typed_ro[DType.int64]()[0], Int64(3))


# =============================================================================
# ColumnarAccumulator.merge_at
# =============================================================================


def test_columnar_accumulator_merge_at() raises:
    var a = ColumnarAccumulator.new_min_utf8()
    var b = ColumnarAccumulator.new_min_utf8()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    a.update_utf8(0, "m")
    b.update_utf8(0, "c")
    a.merge_at(0, b, 0)
    assert_equal(a.finalize_utf8(0).value(), "c")
    # Unseen source gid 1 and out-of-range source gid 5: no-ops.
    a.merge_at(1, b, 1)
    a.merge_at(1, b, 5)
    assert_false(Bool(a.finalize_utf8(1)))

    var mx = ColumnarAccumulator.new_max_utf8()
    var mx2 = ColumnarAccumulator.new_max_utf8()
    mx.ensure_capacity(1)
    mx2.ensure_capacity(1)
    mx.update_utf8(0, "m")
    mx2.update_utf8(0, "z")
    mx.merge_at(0, mx2, 0)
    assert_equal(mx.finalize_utf8(0).value(), "z")

    var s = ColumnarAccumulator.new_sum_int64()
    var t = ColumnarAccumulator.new_sum_int64()
    s.ensure_capacity(2)
    t.ensure_capacity(1)
    s.update_int64(1, 5)
    t.update_int64(0, 37)
    s.merge_at(1, t, 0)
    assert_equal(s.finalize_int64(1), Int64(42))
    s.merge_at(0, t, 3)
    assert_equal(s.finalize_int64(0), Int64(0))

    var c = ColumnarAccumulator.new_count_int64()
    var msg = String("")
    var raised = False
    try:
        s.merge_at(0, c, 0)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_equal(msg, "ColumnarAccumulator.merge_at: tag mismatch")


# =============================================================================
# AggFnAcc.flush_partial_to_column
# =============================================================================


def test_agg_fn_acc_flush_partial_is_finalize() raises:
    var a = AggFnAcc[UdfSumF64](UdfSumF64())
    a.ensure_capacity(2)
    var g: List[Int] = [1, 0, 1]
    var v: List[Float64] = [Float64(2.5), Float64(-1.0), Float64(4.0)]
    var bytes = Span[UInt8, origin_of(v)](
        unsafe_ptr=v.unsafe_ptr().bitcast[UInt8](), length=len(v) * 8
    )
    a.update_batch(Span(g), bytes, 0, 3)
    var col = a.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.float64]()
    assert_equal(col.length(), 2)
    assert_equal(p[0], Float64(-1.0))
    assert_equal(p[1], Float64(6.5))


def test_agg_fn_acc_update_batch_refuses_an_out_of_range_gid() raises:
    var a = AggFnAcc[UdfSumF64](UdfSumF64())
    a.ensure_capacity(1)
    var g: List[Int] = [0, 1]
    var v: List[Float64] = [Float64(2.0), Float64(3.0)]
    var bytes = Span[UInt8, origin_of(v)](
        unsafe_ptr=v.unsafe_ptr().bitcast[UInt8](), length=len(v) * 8
    )
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g), bytes, 0, 2)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_equal(msg, "AggFnAcc.update_batch: gid out of range — caller must ensure_capacity first")


# =============================================================================
# Displacement audit (diagnostic)
# =============================================================================


def test_audit_displacement_zero_alone_and_bounded_when_corrupt() raises:
    var one = GrowableHashSetI64.new(8)
    _ = one.insert(Int64(42))
    assert_equal(one.audit_displacement(), 0, "a lone key sits in its home slot")
    var many = GrowableHashSetI64.new(16)
    for k in range(10):
        _ = many.insert(Int64(k * 31337))
    var d = many.audit_displacement()
    assert_true(d >= 0)
    # Corrupt the directory (no word names any group): the walk for each of
    # the 10 groups gives up after capacity + 1 steps instead of spinning.
    var cap = many.dir.capacity
    for i in range(len(many.dir.directory)):
        many.dir.directory[i] = UInt64(0)
    assert_equal(many.audit_displacement(), 10 * (cap + 1))


# =============================================================================
# COUNT(DISTINCT) vtable thunks (no ACC_* tag routes to them today)
# =============================================================================


def _cd(vals: List[Int64], gids: List[UInt32], n_groups: Int) raises -> DynValue[MAX_ACC_SIZE]:
    var acc = CountDistinctAcc.new()
    acc.ensure_capacity(n_groups)
    acc.update_batch(Span(gids), Span(vals), len(vals))
    return DynValue[MAX_ACC_SIZE].create[CountDistinctAcc](acc^)


def test_count_distinct_thunks() raises:
    var a = _cd([Int64(5), Int64(-2), Int64(5), Int64(9), Int64(-2)], [UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(1)], 3)
    # g0 = {5, -2, 5, 9}: 3 distinct, unsorted input; g1 = {-2}; g2 empty.
    assert_equal(_fin_int64_count_distinct(a, 0), Int64(3))
    assert_equal(_fin_int64_count_distinct(a, 1), Int64(1))
    assert_equal(_fin_int64_count_distinct(a, 2), Int64(0))
    assert_equal(_fin_int64_count_distinct(a, 3), Int64(0), "out of range gid")
    # Reading twice does not change the answer (the thunk sorts a copy).
    assert_equal(_fin_int64_count_distinct(a, 0), Int64(3))
    var b = _cd([Int64(9), Int64(1), Int64(7)], [UInt32(2), UInt32(0), UInt32(1)], 3)
    _merge_at_count_distinct(a, 2, b, 0)
    assert_equal(_fin_int64_count_distinct(a, 2), Int64(1))
    _merge_aligned_count_distinct(a, b)
    # g0 += {1}: 4; g1 += {7}: 2; g2 = {1} + {9}: 2.
    assert_equal(_fin_int64_count_distinct(a, 0), Int64(4))
    assert_equal(_fin_int64_count_distinct(a, 1), Int64(2))
    assert_equal(_fin_int64_count_distinct(a, 2), Int64(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
