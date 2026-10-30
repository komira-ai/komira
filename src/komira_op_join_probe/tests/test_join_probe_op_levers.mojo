# The two levers `JoinProbeOp` records in `join_probe_levers`, through the
# operator, with literal answers:
#   * the probe-key SHARE: a key column without a validity bitmap is shared
#     (one count per acquisition), one with a bitmap is copied (a validity
#     decline, even when all valid), and a non-INT64 key counts a type decline
#     and then raises (the copy cannot serve it either);
#   * chunk-BUFFER reuse: off, nothing is counted; on, the resumable and the
#     deferred arms take their chunk buffers from the worker slot (counted)
#     and answer the same; an operator with no slot counts a fresh buffer;
#   * `ensure_chunk_scratch` sizes a slot list once and never reallocates it.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_INNER

from komira_op_join_build.join import HashJoinBuilder, PROBE_CHUNK_SIZE
from komira_op_join_probe.join_deferred import (
    JoinDeferredState,
    build_join_deferred_state,
)
from komira_op_join_probe.join_probe_levers import (
    join_key_share_declined_type_count,
    join_key_share_declined_validity_count,
    join_key_share_shared_count,
    join_probe_buf_fresh_count,
    join_probe_buf_reuse_configure,
    join_probe_buf_reuse_count,
    join_probe_buf_reuse_reset_config,
    reset_join_probe_lever_counters,
)
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    ColumnarProbeSharedState,
    build_shared_probe_state,
    ensure_chunk_scratch,
)


def _key(vals: List[Int64], bitmap: Bool = False, f64: Bool = False) raises -> Column[HeapRegion]:
    if f64:
        var a = PrimitiveArray[DType.float64].allocate(len(vals))
        for i in range(len(vals)):
            a._typed_ptr_mut()[i] = Float64(Int(vals[i]))
        return Column.from_primitive[DType.float64](a^)
    if not bitmap:
        return Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals))
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        a._typed_ptr_mut()[i] = vals[i]
    return Column.from_primitive[DType.int64](a^)


def _probe(bitmap: Bool = False, f64: Bool = False) raises -> RecordBatch:
    """pk 30, 99, 20, 30, 50; pv 0..4."""
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.FLOAT64 if f64 else ArrowType.INT64, True))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_key([30, 99, 20, 30, 50], bitmap, f64))
    rb.add_column(_key([0, 1, 2, 3, 4]))
    return rb.build(sb.build())


def _op(slot: Bool, deferred: Bool = False) raises -> JoinProbeOp:
    var bk: List[Int64] = [10, 20, 30, 40, 50]
    var sb = SchemaBuilder()
    sb.add_field(Field("bk", ArrowType.INT64, False))
    sb.add_field(Field("bv", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_key(bk))
    rb.add_column(_key([100, 200, 300, 400, 500]))
    var out = SchemaBuilder()
    out.add_field(Field("pk", ArrowType.INT64, True))
    out.add_field(Field("pv", ArrowType.INT64, False))
    out.add_field(Field("bk", ArrowType.INT64, False))
    out.add_field(Field("bv", ArrowType.INT64, False))
    var shared = Optional[ArcPointer[ColumnarProbeSharedState]](None)
    if slot:
        shared = build_shared_probe_state(1)
    var dstate = Optional[ArcPointer[JoinDeferredState]](None)
    if deferred:
        dstate = build_join_deferred_state(1, 32, 4, force_defer=True)
    return JoinProbeOp(
        ArcPointer[HashJoinBuilder](HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(bk))),
        ArcPointer[RecordBatch](rb.build(sb.build())),
        "pk", "bk",
        ArcPointer[Schema](out.build()),
        JOIN_INNER,
        shared=shared^,
        local_id=0 if slot or deferred else -1,
        deferred=dstate^,
    )


def _bv_sum(var probe: RecordBatch, mut op: JoinProbeOp) raises -> Int:
    var m = Morsel(probe^, 0, 0, 0)
    _ = op.execute(m)
    var s = 0
    if m.batch.num_columns() == 4:
        var bv = m.batch.column_at(3).as_primitive[DType.int64]()
        for i in range(bv.length):
            s += Int(bv.get(i))
    return s


def test_the_key_is_shared_without_a_bitmap() raises:
    reset_join_probe_lever_counters()
    var op = _op(False)
    assert_equal(_bv_sum(_probe(), op), 300 + 200 + 300 + 500, "rows")
    assert_equal(join_key_share_shared_count(), 1, "shared once")
    assert_equal(join_key_share_declined_validity_count(), 0)


def test_a_bitmap_key_is_copied() raises:
    """All valid, but a bitmap: the copy, counted as a validity decline."""
    reset_join_probe_lever_counters()
    var op = _op(False)
    assert_equal(_bv_sum(_probe(bitmap=True), op), 1300, "rows")
    assert_equal(join_key_share_shared_count(), 0)
    assert_equal(join_key_share_declined_validity_count(), 1, "validity decline")


def test_a_float_key_declines_for_its_type_then_raises() raises:
    reset_join_probe_lever_counters()
    var op = _op(False)
    var raised = False
    try:
        _ = _bv_sum(_probe(f64=True), op)
    except:
        raised = True
    assert_true(raised, "an INT64 probe of a FLOAT64 column")
    assert_equal(join_key_share_declined_type_count(), 1, "type decline")


def test_reuse_off_counts_nothing() raises:
    join_probe_buf_reuse_reset_config()
    reset_join_probe_lever_counters()
    var op = _op(True)
    assert_equal(_bv_sum(_probe(), op), 1300, "rows")
    assert_equal(join_probe_buf_reuse_count(), 0)
    assert_equal(join_probe_buf_fresh_count(), 0)


def test_reuse_on_both_chained_arms() raises:
    join_probe_buf_reuse_configure(True)
    reset_join_probe_lever_counters()
    var resumable = _op(True)
    assert_equal(_bv_sum(_probe(), resumable), 1300, "resumable rows")
    assert_equal(join_probe_buf_reuse_count(), 1, "resumable from the slot")
    var deferred = _op(True, deferred=True)
    _ = _bv_sum(_probe(), deferred)
    assert_equal(join_probe_buf_reuse_count(), 2, "deferred from the slot")
    assert_equal(join_probe_buf_fresh_count(), 0, "no fresh buffers")
    var no_slot = _op(False, deferred=True)
    _ = _bv_sum(_probe(), no_slot)
    assert_equal(join_probe_buf_fresh_count(), 1, "no slot: a fresh buffer, counted")
    join_probe_buf_reuse_reset_config()


def test_scratch_is_sized_once() raises:
    var lst = List[Int](capacity=PROBE_CHUNK_SIZE)
    ensure_chunk_scratch(lst)
    assert_equal(len(lst), PROBE_CHUNK_SIZE, "sized")
    var p = Int(lst.unsafe_ptr())
    lst[0] = 7
    ensure_chunk_scratch(lst)
    assert_equal(Int(lst.unsafe_ptr()), p, "not reallocated")
    assert_equal(lst[0], 7, "contents kept")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
