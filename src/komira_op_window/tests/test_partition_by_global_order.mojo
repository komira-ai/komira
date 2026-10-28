# =============================================================================
# test_partition_by_global_order -- every window driver emits one order
# =============================================================================
#
# The plan's window rewrite drops a Sort above a window when the Sort's keys
# are a prefix of (partition keys ++ order keys), because every window driver
# emits its rows in that order (`komira_exec_types.partition_by_output_contract`
# declares it). A driver that emitted another order would make that ORDER BY a
# no-op. This file checks the declaration against the drivers:
#
#   * the production entry (`_execute_partition_by_sink_parallel`) below the
#     scatter threshold (the control) and above it (the scatter driver);
#   * the scatter driver called directly, its buckets checked to be monotone
#     in the key and never to split a partition;
#   * byte identity of the parallel output with the single-thread kernel, for
#     one key, two keys and signed / extreme INT64 keys (no re-sort first);
#   * NULL partition keys above the threshold: they take the range driver
#     (the scatter compares raw values) and come out last;
#   * NULL order keys under the scatter driver: last inside each partition;
#   * a DESC order key on the scatter route and on the range route;
#   * no partition keys above the threshold: not the scatter route;
#   * `PartitionBySink` through consume / combine / finalize: 100k rows on the
#     scatter route, NULL keys, no rows at all (the output schema is kept) and
#     tied order keys (rows keep worker order).
#
# Fixture keys are `(r * 7919) % P`, so consecutive input rows belong to
# different partitions: an input already grouped by key cannot pass by
# accident. `val` is distinct per row, so (key, val) is a strict order.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab
from komira_column_kernels.batch_slice import _slice_batch_range
from komira_column_kernels.compiler_helpers import copy_batch
from komira_exec_types.partition_by_output_contract import (
    PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER,
)
from komira_operator_api.memory_reservation import MemoryReservation
from komira_physical_plan.physical_plan import PartitionBySinkData
from komira_plan_expr.partition_expr import PartitionExpr

from komira_op_window.partition_by_sink import PartitionBySink, PartitionBySinkLocal
from komira_op_window.partition_scan_sink import _execute_partition_by_sink
from komira_op_window.partition_scan_sink_hash_scatter import (
    _HASH_SCATTER_MIN_ROWS,
    _all_int64_partition_keys,
    _execute_partition_by_sink_hash_scatter,
    _scatter_rows_to_buckets_int64,
)
from komira_op_window.partition_scan_sink_parallel import (
    _compute_bucket_partition_ranges,
    _execute_partition_by_sink_parallel,
)


comptime _WORKERS: Int = 8
comptime _KEY_STRIDE: Int = 7919


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Fixtures
# =============================================================================


def _make_batch(
    num_rows: Int, num_partitions: Int, signed_extremes: Bool = False,
    null_key_every: Int = 0, null_val_every: Int = 0,
) raises -> RecordBatch:
    """`grp` = (r * 7919) % P (shifted to negative and with INT64 extremes
    when `signed_extremes`), `val` = r. Every `null_key_every`-th row has a
    NULL `grp` (its slot holds 0, a real key); every `null_val_every`-th row a
    NULL `val` (its slot holds r)."""
    var g = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var v = PrimitiveArray[DType.float64].allocate_nullable(num_rows)
    var half = num_partitions // 2
    for r in range(num_rows):
        var key = (r * _KEY_STRIDE) % num_partitions
        if signed_extremes:
            key -= half
            if r % 997 == 0:
                key = -9_000_000_000_000_000
            elif r % 991 == 0:
                key = 9_000_000_000_000_000
        g.store[1](r, Int64(key))
        v.store[1](r, Float64(r))
        if null_key_every > 0 and r % null_key_every == 3:
            g.store[1](r, Int64(0))
            g._set_null(r)
        if null_val_every > 0 and r % null_val_every == 5:
            v._set_null(r)
    var sb = SchemaBuilder()
    sb.add_field(Field("grp", ArrowType.INT64, True))
    sb.add_field(Field("val", ArrowType.FLOAT64, True))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](g^))
    bb.add_column(Column.from_primitive[DType.float64](v^))
    return bb.build(sb.build())


def _make_batch_2key(num_rows: Int, num_a: Int, num_b: Int) raises -> RecordBatch:
    var a = List[Scalar[DType.int64]](capacity=num_rows)
    var b = List[Scalar[DType.int64]](capacity=num_rows)
    var v = List[Scalar[DType.float64]](capacity=num_rows)
    for r in range(num_rows):
        a.append(Int64((r * _KEY_STRIDE) % num_a))
        b.append(Int64((r * 104729) % num_b))
        v.append(Float64(r))
    var sb = SchemaBuilder()
    sb.add_field(Field("ga", ArrowType.INT64, False))
    sb.add_field(Field("gb", ArrowType.INT64, False))
    sb.add_field(Field("val", ArrowType.FLOAT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(a)))
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(b)))
    bb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(v)))
    return bb.build(sb.build())


def _spec(
    input_schema: Schema, pk: List[String], val_desc: Bool = False
) raises -> PartitionBySinkData:
    """Running SUM(val) OVER (PARTITION BY pk ORDER BY val), val DESC when
    `val_desc`."""
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.running_sum("val"))
    var sb = SchemaBuilder()
    for i in range(input_schema.num_columns()):
        sb.add_field(input_schema.field_at(i))
    sb.add_field(Field("_w0_sum", ArrowType.FLOAT64, True))
    var ok: List[String] = ["val"]
    var desc: List[Bool] = [val_desc]
    return PartitionBySinkData(pk.copy(), ok^, desc^, exprs^, sb.build())


# =============================================================================
# Order checks (nothing here re-sorts)
# =============================================================================


def _i64_at(batch: RecordBatch, col: Int, row: Int) -> Int:
    ref c = batch.column_at(col)
    return Int(c._data.get_typed[Scalar[DType.int64]](c._offset + row))


def _f64_at(batch: RecordBatch, col: Int, row: Int) -> Float64:
    ref c = batch.column_at(col)
    return c._data.get_typed[Scalar[DType.float64]](c._offset + row)


@always_inline
def _key_rank(batch: RecordBatch, col: Int, row: Int) -> Tuple[Int, Int]:
    """A NULL key sorts after every value (NULLs last)."""
    if batch.column_at(col).is_null_at(row):
        return (1, 0)
    return (0, _i64_at(batch, col, row))


def _first_violation(
    batch: RecordBatch, num_keys: Int, val_desc: Bool = False
) -> Int:
    """First row that sorts before the row above it under (keys ASC NULLS
    LAST ++ val per `val_desc`, NULLs last), else -1. `val` is the column
    after the keys."""
    for r in range(1, batch.num_rows()):
        var decided = False
        for k in range(num_keys):
            var p = _key_rank(batch, k, r - 1)
            var c = _key_rank(batch, k, r)
            if c[0] != p[0]:
                if c[0] < p[0]:
                    return r
                decided = True
                break
            if c[1] != p[1]:
                if c[1] < p[1]:
                    return r
                decided = True
                break
        if decided:
            continue
        var vp_null = batch.column_at(num_keys).is_null_at(r - 1)
        var vc_null = batch.column_at(num_keys).is_null_at(r)
        if vp_null and not vc_null:
            return r
        if not vp_null and not vc_null:
            var vp = _f64_at(batch, num_keys, r - 1)
            var vc = _f64_at(batch, num_keys, r)
            if (vc > vp) if val_desc else (vc < vp):
                return r
    return -1


def _assert_ordered(
    label: String, batch: RecordBatch, num_keys: Int, val_desc: Bool = False
) raises:
    var v = _first_violation(batch, num_keys, val_desc)
    assert_equal(v, -1, label + ": rows not in (keys ++ val) order; first descent at row " + String(v))


def _assert_byte_identical(a: RecordBatch, b: RecordBatch, label: String) raises:
    assert_equal(a.num_rows(), b.num_rows(), label + ": num_rows")
    assert_equal(a.num_columns(), b.num_columns(), label + ": num_columns")
    for c in range(a.num_columns()):
        ref ca = a.column_at(c)
        ref cb = b.column_at(c)
        for r in range(a.num_rows()):
            if ca.is_null_at(r) != cb.is_null_at(r):
                raise Error(label + ": validity col " + String(c) + " row " + String(r))
            if ca.is_null_at(r):
                continue
            var av = ca._data.get_typed[Scalar[DType.int64]](ca._offset + r)
            var bv = cb._data.get_typed[Scalar[DType.int64]](cb._offset + r)
            if av != bv:
                raise Error(label + ": col " + String(c) + " row " + String(r))


# =============================================================================
# Drivers
# =============================================================================


def _run_entry(var batch: RecordBatch, spec: PartitionBySinkData) raises -> RecordBatch:
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    return _execute_partition_by_sink_parallel(batch^, spec, disp, ct.clone())


def _run_scatter(var batch: RecordBatch, spec: PartitionBySinkData) raises -> RecordBatch:
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    return _execute_partition_by_sink_hash_scatter(batch^, spec, disp, ct.clone())


def _entry_vs_serial(
    var batch: RecordBatch, pk: List[String], label: String,
    val_desc: Bool = False,
) raises -> RecordBatch:
    var par = _run_entry(copy_batch(batch), _spec(batch.schema, pk, val_desc))
    var ref_out = _execute_partition_by_sink(
        copy_batch(batch), _spec(batch.schema, pk, val_desc)
    )
    _ = batch^
    _assert_ordered(label, par, len(pk), val_desc)
    _assert_byte_identical(par, ref_out, label)
    return par^


# =============================================================================
# Tests
# =============================================================================


def test_entry_below_threshold_is_ordered() raises:
    # The control: below the scatter threshold the range driver runs.
    assert_true(50_000 < _HASH_SCATTER_MIN_ROWS)
    var pk: List[String] = ["grp"]
    _ = _entry_vs_serial(_make_batch(50_000, 500), pk, "below_threshold")


def test_entry_above_threshold_is_ordered_and_identical() raises:
    assert_true(100_000 > _HASH_SCATTER_MIN_ROWS)
    var pk: List[String] = ["grp"]
    var out = _entry_vs_serial(_make_batch(100_000, 1000), pk, "above_threshold")
    assert_equal(_i64_at(out, 0, 0), 0)


def test_scatter_driver_directly_is_ordered() raises:
    var batch = _make_batch(100_000, 1000)
    var pk: List[String] = ["grp"]
    var spec = _spec(batch.schema, pk)
    _assert_ordered("scatter_direct", _run_scatter(batch^, spec), 1)


def test_two_keys_and_signed_extremes() raises:
    var pk2: List[String] = ["ga", "gb"]
    _ = _entry_vs_serial(_make_batch_2key(100_000, 200, 30), pk2, "two_keys")
    var pk: List[String] = ["grp"]
    var out = _entry_vs_serial(_make_batch(100_000, 1000, signed_extremes=True), pk, "signed_extremes")
    assert_equal(_i64_at(out, 0, 0), -9_000_000_000_000_000)


def test_null_partition_keys_above_threshold() raises:
    # Every 50th row has a NULL key whose slot holds 0 (a real key). The
    # NULL rows form one partition, after every value; the running sum of
    # the NULL partition is computed over those rows only.
    var pk: List[String] = ["grp"]
    var out = _entry_vs_serial(_make_batch(100_000, 1000, null_key_every=50), pk, "null_keys")
    var n = out.num_rows()
    assert_true(out.column_at(0).is_null_at(n - 1))
    assert_false(out.column_at(0).is_null_at(0))
    # The first NULL-key row starts its own partition: its running sum is
    # its own val.
    var first_null = -1
    for r in range(n):
        if out.column_at(0).is_null_at(r):
            first_null = r
            break
    assert_equal(n - first_null, 2_000)
    assert_equal(_f64_at(out, 2, first_null), _f64_at(out, 1, first_null))


def test_null_order_keys_under_scatter() raises:
    # NULL `val` (the order key) in every 40th row: last inside each
    # partition, on the scatter route.
    var batch = _make_batch(100_000, 1000, null_val_every=40)
    var pk: List[String] = ["grp"]
    var spec = _spec(batch.schema, pk)
    var out = _run_scatter(copy_batch(batch), spec)
    _assert_ordered("null_val_scatter", out, 1)
    var spec2 = _spec(batch.schema, pk)
    var ref_out = _execute_partition_by_sink(batch^, spec2)
    _assert_byte_identical(out, ref_out, "null_val_scatter")


def test_declared_contract_matches_the_drivers() raises:
    # The declaration is checked in both directions: declared True over
    # unordered output drops a Sort nothing replaces; declared False over
    # ordered output keeps a Sort nobody needs.
    var pk: List[String] = ["grp"]
    var batch = _make_batch(100_000, 1000)
    var spec = _spec(batch.schema, pk)
    var out = _run_entry(batch^, spec)
    var observed = _first_violation(out, 1) < 0
    assert_equal(PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER, observed)


def test_scatter_buckets_are_monotone_and_whole() raises:
    var nparts = 400
    var batch = _make_batch(20_000, nparts)
    var pk: List[String] = ["grp"]
    var k = 8
    var buckets = _scatter_rows_to_buckets_int64(batch, pk, k)
    assert_equal(len(buckets), k)
    var key_to_bucket = List[Int]()
    for _ in range(nparts):
        key_to_bucket.append(-1)
    var total = 0
    var last_max = -1
    for b in range(k):
        var prev_row = -1
        var lo = -1
        var hi = -1
        for i in range(len(buckets[b])):
            var row = buckets[b][i]
            assert_true(row > prev_row, "bucket rows ascend")
            prev_row = row
            var key = _i64_at(batch, 0, row)
            if key_to_bucket[key] == -1:
                key_to_bucket[key] = b
            assert_equal(key_to_bucket[key], b, "a partition split across buckets")
            if lo == -1 or key < lo:
                lo = key
            if key > hi:
                hi = key
        total += len(buckets[b])
        if lo == -1:
            continue
        assert_true(lo > last_max, "bucket key ranges overlap")
        last_max = hi
    assert_equal(total, 20_000)


def test_bucket_ranges_are_whole_partitions() raises:
    # Partitions start at 0, 10, 20, 50, 90 of 100 rows; 3 buckets with a
    # target of 33 rows each: a bucket ends where the partition that crosses
    # its cumulative target (33, then 66) begins: [0, 20), [20, 50), [50, 100).
    var bounds: List[Int] = [0, 10, 20, 50, 90]
    var r = _compute_bucket_partition_ranges(bounds, 100, 3)
    var want: List[Int] = [0, 20, 50, 100]
    assert_equal(len(r), 4)
    for i in range(4):
        assert_equal(r[i], want[i])


def _make_tie_batch(num_rows: Int) raises -> RecordBatch:
    """`grp` = r % 3, `val` = 1.0 for every row (all order keys tie), `tag` =
    r. Within one partition the tag tells the input position of each row."""
    var g = List[Scalar[DType.int64]](capacity=num_rows)
    var v = List[Scalar[DType.float64]](capacity=num_rows)
    var t = List[Scalar[DType.int64]](capacity=num_rows)
    for r in range(num_rows):
        g.append(Int64(r % 3))
        v.append(Float64(1.0))
        t.append(Int64(r))
    var sb = SchemaBuilder()
    sb.add_field(Field("grp", ArrowType.INT64, False))
    sb.add_field(Field("val", ArrowType.FLOAT64, False))
    sb.add_field(Field("tag", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(g)))
    bb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(v)))
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(t)))
    return bb.build(sb.build())


def _run_sink(
    var spec: PartitionBySinkData, full: RecordBatch, cuts: List[Int]
) raises -> RecordBatch:
    """`PartitionBySink` through consume / combine / finalize: worker `w`
    consumes rows `[cuts[w], cuts[w + 1])` of `full` (none when the range is
    empty), and the states are combined in worker order."""
    var sink = PartitionBySink(spec^)
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var g = sink.init_global()
    var workers = len(cuts) - 1
    var states = Slab[OwnedPointer[PartitionBySinkLocal]].create(workers)
    for w in range(workers):
        var local = sink.init_local()
        if cuts[w + 1] > cuts[w]:
            sink.consume(w, local, g, _slice_batch_range(full, cuts[w], cuts[w + 1] - cuts[w]))
        states.append(OwnedPointer[PartitionBySinkLocal](local^))
    var reservation = MemoryReservation()
    sink.combine(g, states^, reservation)
    var fo = sink.finalize(g^, Pointer(to=disp), ct.clone())
    var out = fo.output.take_slot_unchecked(0)
    fo.output.set_len_unchecked(0)
    _ = fo^
    return out^


def test_partition_by_sink_end_to_end_on_scatter_route() raises:
    # Three workers' batches (one sends nothing), 100k rows with INT64 keys
    # and no NULL: finalize takes the scatter driver. The output equals the
    # single-thread kernel over the batches concatenated, and is ordered.
    assert_true(100_000 >= _HASH_SCATTER_MIN_ROWS)
    var pk: List[String] = ["grp"]
    var full = _make_batch(100_000, 1000)
    var cuts: List[Int] = [0, 30_000, 30_000, 100_000]
    var out = _run_sink(_spec(full.schema, pk), full, cuts)
    var ref_out = _execute_partition_by_sink(copy_batch(full), _spec(full.schema, pk))
    _assert_ordered("sink_scatter", out, 1)
    _assert_byte_identical(out, ref_out, "sink_scatter")


def test_partition_by_sink_end_to_end_with_null_keys() raises:
    # NULL partition keys: finalize runs the serial kernel on a small input.
    var pk: List[String] = ["grp"]
    var full = _make_batch(30_000, 300, null_key_every=37)
    var cuts: List[Int] = [0, 10_000, 10_000, 30_000]
    var out = _run_sink(_spec(full.schema, pk), full, cuts)
    var ref_out = _execute_partition_by_sink(copy_batch(full), _spec(full.schema, pk))
    _assert_ordered("sink_null_keys", out, 1)
    _assert_byte_identical(out, ref_out, "sink_null_keys")


def test_partition_by_sink_with_no_rows_keeps_the_output_schema() raises:
    # Nothing consumed: the output is a zero-row batch with the window's
    # output columns, not a batch without a schema.
    var pk: List[String] = ["grp"]
    var full = _make_batch(10, 5)
    var spec = _spec(full.schema, pk)
    var want_columns = spec.output_schema.num_columns()
    var cuts: List[Int] = [0, 0]
    var out = _run_sink(spec^, full, cuts)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), want_columns)
    assert_equal(out.num_columns(), 3)


def test_partition_by_sink_ties_keep_worker_order() raises:
    # Every order key ties, so a partition's rows keep the order they reach
    # the window in: worker 0's rows, then worker 1's, then worker 2's, each
    # in input order. The tag is the input row, so it ascends in a partition.
    var pk: List[String] = ["grp"]
    var full = _make_tie_batch(3_000)
    var cuts: List[Int] = [0, 1_000, 2_000, 3_000]
    var out = _run_sink(_spec(full.schema, pk), full, cuts)
    assert_equal(out.num_rows(), 3_000)
    for r in range(1, 3_000):
        if _i64_at(out, 0, r) == _i64_at(out, 0, r - 1):
            assert_true(
                _i64_at(out, 2, r) > _i64_at(out, 2, r - 1),
                "tied rows left input order at row " + String(r),
            )


def test_descending_order_key_on_scatter_route() raises:
    var pk: List[String] = ["grp"]
    var out = _entry_vs_serial(_make_batch(100_000, 1000), pk, "desc_scatter", val_desc=True)
    # Within the first partition `val` falls from its largest value.
    assert_true(_f64_at(out, 1, 0) > _f64_at(out, 1, 1))


def test_descending_order_key_on_range_route() raises:
    # NULL partition keys send 100k rows to the range driver.
    var pk: List[String] = ["grp"]
    var batch = _make_batch(100_000, 1000, null_key_every=50)
    var out = _entry_vs_serial(batch^, pk, "desc_range", val_desc=True)
    assert_true(_f64_at(out, 1, 0) > _f64_at(out, 1, 1))


def test_no_partition_keys_does_not_take_the_scatter_route() raises:
    # With no PARTITION BY the scatter would put every row in one bucket,
    # copy the batch and sort it on one worker.
    var batch = _make_batch(100_000, 1000)
    var none = List[String]()
    assert_false(_all_int64_partition_keys(batch, none))
    var pk: List[String] = ["grp"]
    assert_true(_all_int64_partition_keys(batch, pk))
    var par = _run_entry(copy_batch(batch), _spec(batch.schema, none))
    var ref_out = _execute_partition_by_sink(copy_batch(batch), _spec(batch.schema, none))
    assert_equal(par.num_rows(), 100_000)
    _assert_byte_identical(par, ref_out, "no_keys")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
