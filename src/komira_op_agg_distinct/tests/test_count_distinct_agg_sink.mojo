# =============================================================================
# CountDistinctAggSink — the MorselSink driven directly
# =============================================================================
#
# Builds the Locals by hand, calls `consume(wid, local, sink_global, batch^)`
# per worker, then `combine` and `finalize` exactly as an executor does. Each
# result is compared, group by group and row count included, with a reference
# count computed in the test from the same batches.
#
# Covers:
#   1. one worker, grouped COUNT(DISTINCT);
#   2. four workers, several batches each (the cross-worker merge);
#   3. many groups over four workers (the across-groups radix arm);
#   4. empty input -> an empty batch (grouped) / one row of 0 (ungrouped);
#   5. ungrouped, one and four workers, and wide values (the radix union).
# =============================================================================

from std.memory import OwnedPointer, Pointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_operator_api.memory_reservation import MemoryReservation
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)
from komira_op_agg_distinct.agg_sink_count_distinct import (
    CountDistinctAggSink,
    CountDistinctAggLocal,
)
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_column_kernels.compiler_helpers import copy_batch
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray


def _engine_tier_noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))



# =============================================================================
# Helpers
# =============================================================================


def _build_kv_batch(var keys: List[Int64], var vals: List[Int64]) raises -> RecordBatch:
    var n = len(keys)
    var k_arr = PrimitiveArray[DType.int64].allocate(n)
    var v_arr = PrimitiveArray[DType.int64].allocate(n)
    var kp = k_arr._typed_ptr_mut()
    var vp = v_arr._typed_ptr_mut()
    for i in range(n):
        (kp + i)[] = keys[i]
        (vp + i)[] = vals[i]
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](k_arr^))
    b.add_column(Column.from_primitive[DType.int64](v_arr^))
    return b.build(sb.build())


def _make_agg_data() raises -> AggSinkData:
    """SELECT k, COUNT(DISTINCT v) GROUP BY k. Single INT64 key."""
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, False))
    osb.add_field(Field("dv", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _make_ungrouped_agg_data() raises -> AggSinkData:
    """SELECT COUNT(DISTINCT v). num_keys==0 (CB-04 shape)."""
    var group_by = ExprArray()  # empty
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    var osb = SchemaBuilder()
    osb.add_field(Field("dv", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _empty_pq_data() raises -> ParquetSourceData:
    return ParquetSourceData(
        String(""),
        Optional[List[String]](None),
        Optional[Expr](None),
    )


# =============================================================================
# Direct-sink driver — _drive_sink builds Locals + consume + combine + finalize
# =============================================================================
#
# `batches_per_worker` is `Slab[Slab[RecordBatch]]`: outer slab =
# workers, inner slab = batches assigned to that worker.


def _drive_sink(
    var sink: CountDistinctAggSink,
    var batches_per_worker: Slab[Slab[RecordBatch]],
    mut ctx: PerCoreAsyncRuntime[NoopSink],
) raises -> RecordBatch:
    """Drive the count-distinct sink end to end: one Local per worker,
    `consume` per assigned batch, then `combine` and `finalize`."""
    var sink_owned = sink^
    var n_workers = len(batches_per_worker)
    var sink_global = sink_owned.init_global()

    var locals = Slab[OwnedPointer[CountDistinctAggLocal]].create(n_workers)
    for _ in range(n_workers):
        locals.append(
            OwnedPointer[CountDistinctAggLocal](sink_owned.init_local())
        )

    # Per-worker push: drain each worker's batches into its Local.
    var bpw = batches_per_worker^
    for wid in range(n_workers):
        ref local = locals[wid][]
        ref slot = bpw.get_mut_interior(wid)
        var n_batches = len(slot)
        for _ in range(n_batches):
            var maybe = slot.pop()
            if maybe:
                sink_owned.consume(
                    wid, local, sink_global, maybe.take()^,
                )
    _ = bpw^

    # The executor's barrier: combine every Local, then finalize on the
    # runtime's dispatcher.
    var reservation = MemoryReservation()
    sink_owned.combine(sink_global, locals^, reservation)
    ref disp = ctx.dispatcher()
    var out = sink_owned.finalize(
        sink_global^, Pointer(to=disp), CancellationToken.new()
    )
    assert_equal(len(out.output), 1, "finalize emits one batch")
    var batch = out.output.pop()
    _ = out^
    return batch.take()


def _round_robin_batches(
    var batches: Slab[RecordBatch], num_workers: Int
) raises -> Slab[Slab[RecordBatch]]:
    """Distribute `batches` across `num_workers` slots, round-robin."""
    var bpw = Slab[Slab[RecordBatch]].create(num_workers)
    for _ in range(num_workers):
        bpw.append(Slab[RecordBatch]())
    var owned = batches^
    var i = 0
    while len(owned) > 0:
        var maybe = owned.pop()
        if maybe:
            ref slot = bpw.get_mut_interior(i % num_workers)
            slot.append(maybe.take())
            i += 1
    _ = owned^
    return bpw^


# =============================================================================
# Reference (single-threaded Dict[key -> Dict[val -> True]] count)
# =============================================================================


def _reference_grouped_cd(
    var batches: Slab[RecordBatch],
) raises -> Dict[Int, Int]:
    """Return {key -> distinct count} computed sequentially over all
    batches. Used as the oracle against CountDistinctAggSink output.
    """
    var per_group = Dict[Int, Dict[Int, Bool]]()
    var scratch = Slab[RecordBatch]()
    while len(batches) > 0:
        var maybe = batches.pop()
        if maybe:
            scratch.append(maybe.take())
    while len(scratch) > 0:
        var maybe2 = scratch.pop()
        if maybe2:
            var batch = maybe2.take()
            var n = batch.num_rows()
            ref kc = batch.column_at(0)
            ref vc = batch.column_at(1)
            var kp = kc._data.view_typed_ro[DType.int64]()
            var vp = vc._data.view_typed_ro[DType.int64]()
            for i in range(n):
                var k = Int((kp + kc._offset + i)[])
                var v = Int((vp + vc._offset + i)[])
                if k not in per_group:
                    per_group[k] = Dict[Int, Bool]()
                per_group[k][v] = True
            _ = batch^

    var out = Dict[Int, Int]()
    for entry in per_group.items():
        out[entry.key] = len(entry.value)
    return out^


def _extract_group_map(batch: RecordBatch) raises -> Dict[Int, Int]:
    """Pull {key -> distinct count} out of the sink's output batch."""
    var out = Dict[Int, Int]()
    var n = batch.num_rows()
    if n == 0:
        return out^
    ref kc = batch.column_at(0)
    ref vc = batch.column_at(1)
    var kp = kc._data.view_typed_ro[DType.int64]()
    var vp = vc._data.view_typed_ro[DType.int64]()
    for i in range(n):
        var k = Int((kp + kc._offset + i)[])
        var cnt = Int((vp + vc._offset + i)[])
        out[k] = cnt
    return out^


def _assert_same(actual: Dict[Int, Int], expected: Dict[Int, Int]) raises:
    if len(actual) != len(expected):
        raise Error(
            "group count mismatch: actual=" + String(len(actual))
            + " expected=" + String(len(expected))
        )
    for entry in expected.items():
        if entry.key not in actual:
            raise Error("missing key " + String(entry.key))
        if actual[entry.key] != entry.value:
            raise Error(
                "count mismatch @ k=" + String(entry.key)
                + ": actual=" + String(actual[entry.key])
                + " expected=" + String(entry.value)
            )


# =============================================================================
# Data builders
# =============================================================================


def _synth_batches(
    num_batches: Int, rows_per_batch: Int, num_keys: Int, distinct_per_key: Int
) raises -> Slab[RecordBatch]:
    """Each key gets `distinct_per_key` candidate values drawn in a fixed
    pattern so the reference is deterministic regardless of morsel order.
    """
    var out = Slab[RecordBatch]()
    var row = 0
    for _ in range(num_batches):
        var ks = List[Int64]()
        var vs = List[Int64]()
        for _ in range(rows_per_batch):
            var k = row % num_keys
            var v = (row // num_keys) % distinct_per_key
            ks.append(Int64(k))
            vs.append(Int64(v))
            row += 1
        out.append(_build_kv_batch(ks^, vs^))
    return out^


def _clone_batches(
    ref src: Slab[RecordBatch],
) raises -> Slab[RecordBatch]:
    var out = Slab[RecordBatch]()
    for i in range(len(src)):
        out.append(copy_batch(src[i]))
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_single_worker() raises:
    # 3 batches * 30 rows, 3 keys, 5 distinct vals per key
    var batches = _synth_batches(3, 30, 3, 5)
    var batches_for_ref = _clone_batches(batches)

    var sink = CountDistinctAggSink.new(
        _make_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 1)
    var result = _drive_sink(sink^, bpw^, ctx)

    var expected = _reference_grouped_cd(batches_for_ref^)
    var actual = _extract_group_map(result)
    _assert_same(actual, expected)
    print("test_single_worker OK (3 batches, 3 keys, 5 distinct/key, 1 worker)")


def test_multi_worker() raises:
    # 16 batches * 200 rows, 10 keys, 15 distinct vals per key
    # Values overlap across batches so dedup across workers must merge.
    var batches = _synth_batches(16, 200, 10, 15)
    var batches_for_ref = _clone_batches(batches)

    var sink = CountDistinctAggSink.new(
        _make_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 4)
    var result = _drive_sink(sink^, bpw^, ctx)

    var expected = _reference_grouped_cd(batches_for_ref^)
    var actual = _extract_group_map(result)
    _assert_same(actual, expected)
    print("test_multi_worker OK (16 batches, 10 keys, 15 distinct/key, 4 workers)")


def test_empty_source() raises:
    var batches = Slab[RecordBatch]()
    var sink = CountDistinctAggSink.new(
        _make_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 2)
    var result = _drive_sink(sink^, bpw^, ctx)
    if result.num_rows() != 0:
        raise Error(
            "empty source produced " + String(result.num_rows())
            + " rows, expected 0"
        )
    print("test_empty_source OK (0 rows, 2 workers)")


def test_multi_worker_many_groups_across_group() raises:
    """PERF-CD-GROUPED-STREAM regression: the grouped finalize now
    builds a global group directory and MOVES each worker's per-group buffer
    directly into `radix_distinct_count_grouped` (no serial bulk-extend fold).

    This drives the cb13-shape "many groups" across-group path: 300 groups (>=
    the driver's across-group group-count gate), ~450 distinct values per group,
    with values overlapping across batches/workers so the cross-worker dedup +
    the global-directory local->global group remap + the O(1) buffer MOVE must
    all be correct. Verified against the independent Dict[key->Dict[val]] oracle
    (`_reference_grouped_cd`) — a hash-free count that shares NO code with the
    sink's radix driver, so a partition/remap bug cannot hide behind a shared
    path. 60 batches * 5000 rows = 300K total values (> the across-group total
    gate) across 8 workers."""
    var batches = _synth_batches(60, 5000, 300, 450)
    var batches_for_ref = _clone_batches(batches)

    var sink = CountDistinctAggSink.new(
        _make_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 8)
    var result = _drive_sink(sink^, bpw^, ctx)

    if result.num_rows() != 300:
        raise Error(
            "many-groups grouped CD expected 300 rows, got "
            + String(result.num_rows())
        )
    var expected = _reference_grouped_cd(batches_for_ref^)
    var actual = _extract_group_map(result)
    _assert_same(actual, expected)
    print(
        "test_multi_worker_many_groups_across_group OK (300 groups, 450"
        " distinct/group, 8 workers, across-group driver)"
    )


def _total_distinct_values(var batches_ref: Slab[RecordBatch]) raises -> Int:
    """Oracle: pour all `v` columns into a Dict and return the key count."""
    var seen = Dict[Int, Bool]()
    var scratch = Slab[RecordBatch]()
    while len(batches_ref) > 0:
        var maybe = batches_ref.pop()
        if maybe:
            scratch.append(maybe.take())
    while len(scratch) > 0:
        var maybe2 = scratch.pop()
        if maybe2:
            var batch = maybe2.take()
            var n = batch.num_rows()
            ref vc = batch.column_at(1)
            var vp = vc._data.view_typed_ro[DType.int64]()
            for i in range(n):
                seen[Int((vp + vc._offset + i)[])] = True
            _ = batch^
    return len(seen)


def test_ungrouped_single_worker() raises:
    """CB-04 shape: 3 batches, 100 rows each, 50 distinct values total."""
    var batches = _synth_batches(3, 100, 5, 50)  # keys ignored by ungrouped sink
    var batches_for_ref = _clone_batches(batches)

    var sink = CountDistinctAggSink.new(
        _make_ungrouped_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 1)
    var result = _drive_sink(sink^, bpw^, ctx)

    if result.num_rows() != 1:
        raise Error(
            "ungrouped CD must emit exactly 1 row, got "
            + String(result.num_rows())
        )
    ref vc = result.column_at(0)
    var vp = vc._data.view_typed_ro[DType.int64]()
    var actual = Int((vp + vc._offset)[])
    var expected = _total_distinct_values(batches_for_ref^)
    if actual != expected:
        raise Error(
            "ungrouped CD count mismatch: actual="
            + String(actual) + " expected=" + String(expected)
        )
    print("test_ungrouped_single_worker OK (count=" + String(actual) + ")")


def test_ungrouped_multi_worker() raises:
    """CB-04 shape with concurrent merge: 16 batches * 250 rows, workers=4,
    values overlap across batches so merge + dedup correctness both matter.
    """
    var batches = _synth_batches(16, 250, 8, 100)
    var batches_for_ref = _clone_batches(batches)

    var sink = CountDistinctAggSink.new(
        _make_ungrouped_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 4)
    var result = _drive_sink(sink^, bpw^, ctx)

    if result.num_rows() != 1:
        raise Error(
            "ungrouped multi-worker CD must emit exactly 1 row, got "
            + String(result.num_rows())
        )
    ref vc = result.column_at(0)
    var vp = vc._data.view_typed_ro[DType.int64]()
    var actual = Int((vp + vc._offset)[])
    var expected = _total_distinct_values(batches_for_ref^)
    if actual != expected:
        raise Error(
            "ungrouped multi-worker CD mismatch: actual="
            + String(actual) + " expected=" + String(expected)
        )
    print("test_ungrouped_multi_worker OK (count=" + String(actual) + ", 4 workers)")


def _synth_wide_value_batches(
    num_batches: Int, rows_per_batch: Int, distinct_total: Int
) raises -> Slab[RecordBatch]:
    """Ungrouped CD stress data with WIDE, spread-out values so the CD-v2
    radix-on-value partitioning fills all 8 value partitions and the
    cross-worker per-partition union is exercised under skew.

    Each row's value is `(row % distinct_total) * 2654435761 + 7` — a large
    multiplicative stride scatters the values across the full Int64 space
    (and thus across all partition buckets), while the `% distinct_total`
    wrap guarantees exactly `distinct_total` distinct values regardless of
    morsel boundaries / worker assignment. Key column is a fixed dummy
    (ignored by the ungrouped sink).
    """
    var out = Slab[RecordBatch]()
    var row = 0
    for _ in range(num_batches):
        var ks = List[Int64]()
        var vs = List[Int64]()
        for _ in range(rows_per_batch):
            var d = row % distinct_total
            var v = Int64(d) * Int64(2654435761) + Int64(7)
            ks.append(Int64(0))
            vs.append(v)
            row += 1
        out.append(_build_kv_batch(ks^, vs^))
    return out^


def test_ungrouped_wide_value_radix_multi_worker() raises:
    """CD-v2 regression: high-cardinality, wide-value-range
    ungrouped COUNT(DISTINCT) across 8 workers. Stresses the per-worker
    dedup-on-insert + per-partition cross-worker UNION finalize that
    replaced the CD-v1 append-all + bulk-extend + radix-dedup pipeline.

    32 batches * 500 rows = 16000 rows, 3000 distinct values spread across
    the full hash space so every one of the 8 value partitions is populated
    and every worker contributes to multiple partitions (the union must
    merge them losslessly). Verified against the independent
    `_total_distinct_values` oracle.
    """
    var batches = _synth_wide_value_batches(32, 500, 3000)
    var batches_for_ref = _clone_batches(batches)

    var sink = CountDistinctAggSink.new(
        _make_ungrouped_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 8)
    var result = _drive_sink(sink^, bpw^, ctx)

    if result.num_rows() != 1:
        raise Error(
            "wide-value ungrouped CD must emit exactly 1 row, got "
            + String(result.num_rows())
        )
    ref vc = result.column_at(0)
    var vp = vc._data.view_typed_ro[DType.int64]()
    var actual = Int((vp + vc._offset)[])
    var expected = _total_distinct_values(batches_for_ref^)
    if actual != expected:
        raise Error(
            "wide-value ungrouped CD mismatch: actual="
            + String(actual) + " expected=" + String(expected)
        )
    if actual != 3000:
        raise Error(
            "wide-value ungrouped CD expected 3000 distinct, got "
            + String(actual)
        )
    print(
        "test_ungrouped_wide_value_radix_multi_worker OK (count="
        + String(actual) + ", 8 workers, 8 partitions)"
    )


def test_ungrouped_empty_source() raises:
    """SQL standard: ungrouped COUNT(DISTINCT) over empty input returns 0
    (not NULL) in exactly 1 row.
    """
    var batches = Slab[RecordBatch]()
    var sink = CountDistinctAggSink.new(
        _make_ungrouped_agg_data(),
        _empty_pq_data(),
        Slab[MorselOp](),
    )
    var ctx = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_engine_tier_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var bpw = _round_robin_batches(batches^, 2)
    var result = _drive_sink(sink^, bpw^, ctx)
    if result.num_rows() != 1:
        raise Error(
            "ungrouped empty source must emit 1 row, got "
            + String(result.num_rows())
        )
    ref vc = result.column_at(0)
    var vp = vc._data.view_typed_ro[DType.int64]()
    var actual = Int((vp + vc._offset)[])
    if actual != 0:
        raise Error(
            "ungrouped CD on empty input must return 0, got "
            + String(actual)
        )
    print("test_ungrouped_empty_source OK (count=0)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
