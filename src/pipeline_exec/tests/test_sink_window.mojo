# =============================================================================
# SINK_PARTITION_BY, driven by hand
# =============================================================================
#
# `WindowSink` is handed morsels of a 40-row table (id, g, o, v, s: `g` is the
# partition key with NULLs, `o` the order key with NULLs and ties, `v` a value
# with NULLs, `s` a STRING) worker by worker, combined once, and read. Every
# window column is compared with a plain-loop oracle that sorts the ids by the
# keys (NULLs last in both directions, ties in source position order), cuts the
# partitions and computes each function row by row. What these tests prove:
#
#   * ROW_NUMBER and RANK equal the oracle over partition keys with NULLs and
#     order keys with NULLs and ties; rows tied on every key are numbered in
#     source position order.
#   * LAG and LEAD, with and without a default, equal the oracle: a NULL value
#     stays NULL, the edge of a partition is the default or NULL.
#   * A running SUM over RANGE UNBOUNDED PRECEDING .. CURRENT ROW gives peers
#     the same sum and skips NULL values; it is NULL while no value was seen.
#   * Whole-partition SUM, COUNT(v), COUNT(*), AVG, MIN and MAX equal the
#     oracle with NULL values.
#   * Descending order, and no partition key (one partition), equal the oracle.
#   * The sorted input columns are the input's, row for row.
#   * The same rows from one worker and from four workers dealt their morsels
#     in reverse order give equal batches, equal to the oracle.
#   * No input gives a batch of no rows under the output schema.
#   * The output columns have the plan's names and types (an alias, the
#     function's default name, INT64 and FLOAT64).
#   * ORDER BY o NULLS FIRST, ascending and descending, puts the NULL-key rows
#     first in source position order and ranks them as one peer group.
#   * A NULL placement list, or a descending list, that does not match the
#     order keys, and an output
#     schema with fewer columns than window expressions, are refused by exact
#     message when the sink is built; a read before combine is refused; a SUM
#     over a STRING column fails in combine with the kernel's message.
#   * The pool is charged while rows are held, holds the output once combined,
#     returns every block when the output is taken, and returns them when the
#     sink is dropped without a combine or after a failed one.
#   * A pool too small for a morsel fails the consume by exact message; one
#     too small for the concatenation and one too small for the sorted copy
#     fail the combine by name.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from column_kernels.compiler_helpers import batch_buffer_bytes
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import PartitionBySinkData
from pipeline_exec.plan_harness import int64_column, null_column
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_window import WindowSink
from plan_expr.partition_expr import (
    PF_AVG,
    PF_COUNT,
    PF_MAX,
    PF_MIN,
    PF_SUM,
    PartitionExpr,
    partition_expr_output_field,
)
from plan_expr.partition_frame import PartitionFrame
from plan_expr.scalar_value import ScalarValue

comptime N = 40
comptime G = 1
comptime O = 2
comptime V = 3
comptime FIRST_WINDOW = 5
comptime NUM_INT_EXPRS = 11


def g_null(r: Int) -> Bool:
    return r % 7 == 3


def g_val(r: Int) -> Int:
    return r % 3


def o_null(r: Int) -> Bool:
    return r % 9 == 4


def o_val(r: Int) -> Int:
    return (r * 5) % 4


def v_null(r: Int) -> Bool:
    return r % 5 == 1


def v_val(r: Int) -> Int:
    return (r * 7) % 11


def table(start: Int, rows: Int) raises -> RecordBatch:
    var ids = ColumnBuilder[DType.int64].with_capacity(rows)
    var g = ColumnBuilder[DType.int64].with_capacity(rows)
    var o = ColumnBuilder[DType.int64].with_capacity(rows)
    var v = ColumnBuilder[DType.int64].with_capacity(rows)
    var s = List[String]()
    var s_valid = List[Bool]()
    for i in range(rows):
        var r = start + i
        ids.append(Int64(r))
        if g_null(r):
            g.append_null()
        else:
            g.append(Int64(g_val(r)))
        if o_null(r):
            o.append_null()
        else:
            o.append(Int64(o_val(r)))
        if v_null(r):
            v.append_null()
        else:
            v.append(Int64(v_val(r)))
        s.append(String("s") + String(r % 3))
        s_valid.append(True)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(ids^.materialize())
    sb.add_field(Field("g", ArrowType.INT64, True))
    rb.add_column(g^.materialize())
    sb.add_field(Field("o", ArrowType.INT64, True))
    rb.add_column(o^.materialize())
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(s, s_valid))
    )
    return rb.build(sb.build())


def _whole() -> PartitionFrame:
    return PartitionFrame.default_unordered()


def _exprs() raises -> List[PartitionExpr]:
    """The window columns, in the order the oracle computes them."""
    var out = List[PartitionExpr]()
    out.append(PartitionExpr.row_number().with_alias("rn"))
    out.append(PartitionExpr.rank())
    out.append(PartitionExpr.lag("v", 1))
    out.append(PartitionExpr.lag_default("v", 1, ScalarValue.from_int(-1)))
    out.append(PartitionExpr.lead_default("v", 2, ScalarValue.from_int(99)))
    out.append(
        PartitionExpr.agg_with_frame(
            PF_SUM, "v", PartitionFrame.running_range()
        )
    )
    out.append(PartitionExpr.agg_with_frame(PF_SUM, "v", _whole()))
    out.append(PartitionExpr.agg_with_frame(PF_COUNT, "v", _whole()))
    out.append(PartitionExpr.agg_with_frame(PF_COUNT, "", _whole()))
    out.append(PartitionExpr.agg_with_frame(PF_MIN, "v", _whole()))
    out.append(PartitionExpr.agg_with_frame(PF_MAX, "v", _whole()))
    out.append(PartitionExpr.agg_with_frame(PF_AVG, "v", _whole()))
    return out^


def _out_schema(
    child: Schema, ref exprs: List[PartitionExpr]
) raises -> Schema:
    """The child's fields and one per expression, a SUM, AVG, MIN or MAX over a
    nullable column nullable as the plan declares it."""
    var sb = SchemaBuilder()
    for i in range(child.num_columns()):
        sb.add_field(child.field_at(i))
    for i in range(len(exprs)):
        var f = partition_expr_output_field(exprs[i], child, i)
        var agg = (
            exprs[i].func == PF_SUM
            or exprs[i].func == PF_AVG
            or exprs[i].func == PF_MIN
            or exprs[i].func == PF_MAX
        )
        if agg and exprs[i].column != "":
            f.nullable = child.field_nullable(
                child.column_index(exprs[i].column)
            )
        sb.add_field(f^)
    return sb.build()


def _data(
    has_g: Bool, desc: Bool, var exprs: List[PartitionExpr]
) raises -> PartitionBySinkData:
    var pkeys = List[String]()
    if has_g:
        pkeys.append("g")
    var okeys = List[String]()
    okeys.append("o")
    var dirs = List[Bool]()
    dirs.append(desc)
    var schema = _out_schema(table(0, 0).schema.copy(), exprs)
    return PartitionBySinkData(pkeys^, okeys^, dirs^, exprs^, schema^)


def _sink(
    ref data: PartitionBySinkData, pool: SegmentPool, workers: Int
) raises -> WindowSink:
    var sink = WindowSink(data, pool.share(), 7)
    sink.resize_worker_state(workers)
    return sink^


def _finish(mut sink: WindowSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _run(
    workers: Int, has_g: Bool = True, desc: Bool = False
) raises -> RecordBatch:
    """Rows 0 .. N-1 cut into `workers` morsels handed to the workers in
    reverse order."""
    var pool = SegmentPool()
    var data = _data(has_g, desc, _exprs())
    var sink = _sink(data, pool, workers)
    var per = N // workers
    for k in range(workers):
        var w = workers - 1 - k
        sink.consume(w, Morsel(table(w * per, per), w, w))
    var out = _finish(sink, workers)
    assert_equal(pool.granted(), 0)
    _ = sink^
    return out^


# -----------------------------------------------------------------------------
# The oracle
# -----------------------------------------------------------------------------


def _lt(an: Bool, av: Int, bn: Bool, bv: Int, desc: Bool) -> Bool:
    """Whether a sorts strictly before b, NULLs last in both directions."""
    if an:
        return False
    if bn:
        return True
    if desc:
        return av > bv
    return av < bv


def _o_before(a: Int, b: Int, desc: Bool) -> Bool:
    return _lt(o_null(a), o_val(a), o_null(b), o_val(b), desc)


def _same_g(a: Int, b: Int, has_g: Bool) -> Bool:
    if not has_g:
        return True
    if g_null(a) or g_null(b):
        return g_null(a) and g_null(b)
    return g_val(a) == g_val(b)


def _before(a: Int, b: Int, has_g: Bool, desc: Bool) -> Bool:
    if has_g and not _same_g(a, b, True):
        return _lt(g_null(a), g_val(a), g_null(b), g_val(b), False)
    return _o_before(a, b, desc)


def _sorted(has_g: Bool, desc: Bool) -> List[Int]:
    """The ids sorted by the keys, ties in id order (an insertion sort that
    places a row after every row not greater than it)."""
    var order = List[Int]()
    for r in range(N):
        var at = len(order)
        while at > 0 and _before(r, order[at - 1], has_g, desc):
            at -= 1
        order.insert(at, r)
    return order^


struct Expected(Movable):
    var ids: List[Int]
    var vals: List[List[Int]]
    var nulls: List[List[Bool]]
    var avg: List[Float64]

    def __init__(out self, var ids: List[Int]):
        self.ids = ids^
        self.vals = List[List[Int]]()
        self.nulls = List[List[Bool]]()
        for _ in range(NUM_INT_EXPRS):
            self.vals.append(List[Int]())
            self.nulls.append(List[Bool]())
        self.avg = List[Float64]()

    def put(mut self, k: Int, value: Int, is_null: Bool = False):
        self.vals[k].append(value)
        self.nulls[k].append(is_null)


def _expected(has_g: Bool, desc: Bool) -> Expected:
    var order = _sorted(has_g, desc)
    var e = Expected(order.copy())
    for p in range(N):
        var r = order[p]
        var lo = p
        while lo > 0 and _same_g(order[lo - 1], r, has_g):
            lo -= 1
        var hi = p + 1
        while hi < N and _same_g(order[hi], r, has_g):
            hi += 1
        e.put(0, p - lo + 1)
        var rank = 1
        for q in range(lo, hi):
            if _o_before(order[q], r, desc):
                rank += 1
        e.put(1, rank)
        # LAG(v, 1): the previous row's value, NULL at the edge.
        if p > lo:
            e.put(2, v_val(order[p - 1]), v_null(order[p - 1]))
        else:
            e.put(2, 0, True)
        # LAG(v, 1, -1) and LEAD(v, 2, 99).
        if p > lo:
            e.put(3, v_val(order[p - 1]), v_null(order[p - 1]))
        else:
            e.put(3, -1)
        if p + 2 < hi:
            e.put(4, v_val(order[p + 2]), v_null(order[p + 2]))
        else:
            e.put(4, 99)
        # Running SUM over the rows up to and including the last peer.
        var run = 0
        var seen = False
        for q in range(lo, hi):
            if not _o_before(r, order[q], desc) and not v_null(order[q]):
                run += v_val(order[q])
                seen = True
        e.put(5, run, not seen)
        # The whole partition.
        var total = 0
        var count = 0
        var lowest = 0
        var highest = 0
        for q in range(lo, hi):
            if v_null(order[q]):
                continue
            var x = v_val(order[q])
            if count == 0 or x < lowest:
                lowest = x
            if count == 0 or x > highest:
                highest = x
            total += x
            count += 1
        e.put(6, total, count == 0)
        e.put(7, count)
        e.put(8, hi - lo)
        e.put(9, lowest, count == 0)
        e.put(10, highest, count == 0)
        e.avg.append(Float64(total) / Float64(count) if count > 0 else 0.0)
    return e^


def _expect_columns(
    ref out: RecordBatch,
    ref e: Expected,
    first: Int,
    last: Int,
    label: String,
) raises:
    assert_equal(out.num_rows(), N, label)
    var ids = int64_column(out, 0)
    for p in range(N):
        assert_equal(ids[p], e.ids[p], label + ", id at " + String(p))
    for k in range(first, last + 1):
        var nulls = null_column(out, FIRST_WINDOW + k)
        if k == NUM_INT_EXPRS:
            var col = out.column_at(FIRST_WINDOW + k).as_primitive[
                DType.float64
            ]()
            for p in range(N):
                var want_null = e.nulls[6][p]
                assert_equal(nulls[p], want_null, label + ", AVG null")
                if not want_null:
                    var diff = col.get(p) - e.avg[p]
                    assert_true(
                        diff < 1e-9 and diff > -1e-9,
                        label + ", AVG at " + String(p),
                    )
            continue
        var got = int64_column(out, FIRST_WINDOW + k)
        for p in range(N):
            var at = label + ", column " + String(k) + " at " + String(p)
            assert_equal(nulls[p], e.nulls[k][p], at + " null")
            if not e.nulls[k][p]:
                assert_equal(got[p], e.vals[k][p], at)


def _same_batch(ref a: RecordBatch, ref b: RecordBatch, label: String) raises:
    assert_equal(a.num_rows(), b.num_rows(), label)
    assert_equal(a.num_columns(), b.num_columns(), label)
    for c in range(a.num_columns()):
        assert_equal(
            a.schema.field_at(c).name, b.schema.field_at(c).name, label
        )
        var an = null_column(a, c)
        var bn = null_column(b, c)
        var t = a.schema.field_at(c).arrow_type
        for i in range(a.num_rows()):
            var at = label + ", column " + String(c) + " row " + String(i)
            assert_equal(an[i], bn[i], at + " null")
            if an[i]:
                continue
            if t == ArrowType.INT64:
                var x = a.column_at(c).as_primitive[DType.int64]()
                var y = b.column_at(c).as_primitive[DType.int64]()
                assert_equal(x.get(i), y.get(i), at)
            elif t == ArrowType.FLOAT64:
                var x = a.column_at(c).as_primitive[DType.float64]()
                var y = b.column_at(c).as_primitive[DType.float64]()
                assert_true(x.get(i) == y.get(i), at)
            else:
                assert_equal(
                    a.column_at(c).as_string().get(i),
                    b.column_at(c).as_string().get(i),
                    at,
                )


def _nulls_first_run(desc: Bool) raises -> RecordBatch:
    var pool = SegmentPool()
    var data = _data(False, desc, _exprs())
    data.nulls_first = [True]
    var sink = _sink(data, pool, 1)
    sink.consume(0, Morsel(table(0, N), 0, 0))
    var out = _finish(sink, 1)
    _ = sink^
    return out^


def _check_nulls_first(ref out: RecordBatch, desc: Bool) raises:
    var n_null = 0
    for r in range(N):
        if o_null(r):
            n_null += 1
    assert_equal(out.num_rows(), N)
    var ids = int64_column(out, 0)
    var o = int64_column(out, 2)
    var o_nulls = null_column(out, 2)
    var rank = int64_column(out, FIRST_WINDOW + 1)
    for p in range(N):
        assert_equal(o_nulls[p], p < n_null, "o null flag at " + String(p))
    for p in range(1, n_null):
        assert_true(ids[p - 1] < ids[p], "NULL rows keep source order")
    for p in range(n_null):
        assert_equal(rank[p], 1, "NULL peers are rank 1 at " + String(p))
    assert_equal(rank[n_null], n_null + 1)
    for p in range(n_null + 1, N):
        if desc:
            assert_true(o[p - 1] >= o[p], "o is non-increasing at " + String(p))
        else:
            assert_true(o[p - 1] <= o[p], "o is non-decreasing at " + String(p))


def test_nulls_first_ascending_leads_with_the_null_keys_as_one_peer_group() raises:
    _check_nulls_first(_nulls_first_run(False), False)


def test_nulls_first_descending_leads_with_the_null_keys_as_one_peer_group() raises:
    _check_nulls_first(_nulls_first_run(True), True)


def test_row_number_and_rank_equal_the_oracle_with_null_keys_and_ties() raises:
    var out = _run(1)
    _expect_columns(out, _expected(True, False), 0, 1, "row number and rank")


def test_lag_and_lead_with_and_without_a_default_equal_the_oracle() raises:
    var out = _run(1)
    _expect_columns(out, _expected(True, False), 2, 4, "lag and lead")


def test_a_running_sum_over_range_gives_peers_one_sum() raises:
    var out = _run(1)
    var e = _expected(True, False)
    _expect_columns(out, e, 5, 5, "running sum")
    # Peers exist: two neighbours of one partition tie on o and agree.
    var tied = 0
    var sums = int64_column(out, FIRST_WINDOW + 5)
    for p in range(1, N):
        var a = e.ids[p - 1]
        var b = e.ids[p]
        if _same_g(a, b, True) and not _o_before(a, b, False) and not _o_before(b, a, False):
            tied += 1
            assert_equal(sums[p - 1], sums[p], "peers share the running sum")
    assert_true(tied > 0, "the table has peers")


def test_whole_partition_aggregates_equal_the_oracle_with_null_values() raises:
    var out = _run(1)
    _expect_columns(
        out, _expected(True, False), 6, NUM_INT_EXPRS, "whole partition"
    )


def test_descending_order_and_no_partition_key_equal_the_oracle() raises:
    _expect_columns(
        _run(1, True, True),
        _expected(True, True),
        0,
        NUM_INT_EXPRS,
        "descending",
    )
    _expect_columns(
        _run(1, False, False),
        _expected(False, False),
        0,
        NUM_INT_EXPRS,
        "one partition",
    )
    _expect_columns(
        _run(1, False, True),
        _expected(False, True),
        0,
        NUM_INT_EXPRS,
        "one partition, descending",
    )


def test_the_sorted_input_columns_are_the_inputs() raises:
    var out = _run(1)
    var ids = int64_column(out, 0)
    var g = int64_column(out, G)
    var o = int64_column(out, O)
    var v = int64_column(out, V)
    var gn = null_column(out, G)
    var on = null_column(out, O)
    var vn = null_column(out, V)
    var s = out.column_at(4).as_string()
    for p in range(N):
        var r = ids[p]
        assert_equal(gn[p], g_null(r))
        assert_equal(on[p], o_null(r))
        assert_equal(vn[p], v_null(r))
        if not g_null(r):
            assert_equal(g[p], g_val(r))
        if not o_null(r):
            assert_equal(o[p], o_val(r))
        if not v_null(r):
            assert_equal(v[p], v_val(r))
        assert_equal(s.get(p), String("s") + String(r % 3))


def test_four_workers_dealt_in_reverse_equal_one_worker() raises:
    var one = _run(1)
    var four = _run(4)
    _same_batch(one, four, "one worker against four")
    _expect_columns(four, _expected(True, False), 0, NUM_INT_EXPRS, "four")
    var two_desc = _run(2, True, True)
    _same_batch(_run(1, True, True), two_desc, "descending, one against two")
    # One worker given several morsels in order is the same batch too.
    var pool = SegmentPool()
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 1)
    for k in range(4):
        sink.consume(0, Morsel(table(k * 10, 10), k, k))
    _same_batch(one, _finish(sink, 1), "one worker, four morsels")


def test_no_input_gives_no_rows_under_the_output_schema() raises:
    var pool = SegmentPool()
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 3)
    var out = _finish(sink, 3)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), data.output_schema.num_columns())
    for c in range(out.num_columns()):
        assert_equal(
            out.schema.field_at(c).name, data.output_schema.field_at(c).name
        )
        assert_true(
            out.schema.field_at(c).arrow_type
            == data.output_schema.field_at(c).arrow_type
        )
    assert_equal(pool.granted(), 0)


def test_the_output_columns_have_the_plans_names_and_types() raises:
    var out = _run(2)
    assert_equal(out.num_columns(), FIRST_WINDOW + NUM_INT_EXPRS + 1)
    var names = List[String]()
    names.append("id")
    names.append("g")
    names.append("o")
    names.append("v")
    names.append("s")
    names.append("rn")
    names.append("_w1_rank")
    for c in range(len(names)):
        assert_equal(out.schema.field_at(c).name, names[c])
    for k in range(NUM_INT_EXPRS):
        assert_true(
            out.schema.field_at(FIRST_WINDOW + k).arrow_type
            == ArrowType.INT64,
            "column " + String(k) + " is INT64",
        )
    assert_true(
        out.schema.field_at(FIRST_WINDOW + NUM_INT_EXPRS).arrow_type
        == ArrowType.FLOAT64,
        "AVG is FLOAT64",
    )
    assert_true(out.schema.field_at(FIRST_WINDOW + 6).nullable)
    assert_true(not out.schema.field_at(FIRST_WINDOW + 7).nullable)


def test_a_sink_the_plan_cannot_describe_is_refused_by_name() raises:
    var pool = SegmentPool()
    var bad = _data(True, False, _exprs())
    bad.descending = List[Bool]()
    try:
        _ = WindowSink(bad, pool.share(), 7)
        assert_true(False, "a missing direction must be refused")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink of segment 7 lists 0 directions"
            " for 1 order keys",
        )
    var placed = _data(True, False, _exprs())
    placed.nulls_first = [True, False]
    try:
        _ = WindowSink(placed, pool.share(), 7)
        assert_true(False, "a NULL placement list of the wrong length must be refused")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink of segment 7 lists 2 NULL"
            " placements for 1 order keys",
        )
    var short = _data(True, False, _exprs())
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    short.output_schema = sb.build()
    try:
        _ = WindowSink(short, pool.share(), 7)
        assert_true(False, "a short output schema must be refused")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink of segment 7 has an output schema"
            " of 1 columns for 12 window expressions",
        )


def test_a_read_before_combine_is_refused() raises:
    var pool = SegmentPool()
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 1)
    try:
        _ = sink.take_output()
        assert_true(False, "a read before combine must be refused")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink was read before it was combined",
        )
    _ = _finish(sink, 1)
    try:
        _ = sink.take_output()
        assert_true(False, "a second read must be refused")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink was read before it was combined",
        )


def test_a_sum_over_a_string_column_fails_with_the_kernels_message() raises:
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.agg_with_frame(
            PF_SUM, "s", PartitionFrame.running_range()
        )
    )
    var pool = SegmentPool()
    var data = _data(True, False, exprs^)
    var sink = _sink(data, pool, 1)
    sink.consume(0, Morsel(table(0, N), 0, 0))
    var pipeline = PipelineExecution(1, 0)
    try:
        sink.combine(pipeline)
        assert_true(False, "a SUM over a STRING column must fail")
    except e:
        assert_equal(
            String(e),
            "partition_scan_sink: running aggregate unsupported type "
            + String(ArrowType.STRING),
        )
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_the_pool_is_charged_while_rows_are_held_and_repaid() raises:
    var kept = batch_buffer_bytes(table(0, N // 2)) + batch_buffer_bytes(
        table(N // 2, N // 2)
    )
    var pool = SegmentPool()
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 2)
    sink.consume(1, Morsel(table(N // 2, N // 2), 1, 1))
    sink.consume(0, Morsel(table(0, N // 2), 0, 0))
    assert_true(pool.granted() >= kept, "the morsels are drawn")
    var pipeline = PipelineExecution(2, 0)
    sink.combine(pipeline)
    assert_true(pool.granted() > 0, "the output is held")
    sink.finalize()
    var out = sink.take_output()
    assert_equal(out.num_rows(), N)
    # The sink is still alive: take_output repaid the pool, not the drop.
    assert_equal(pool.granted(), 0)
    _ = sink^


def test_a_sink_dropped_without_a_combine_repays_the_pool() raises:
    var pool = SegmentPool()
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 2)
    sink.consume(0, Morsel(table(0, N // 2), 0, 0))
    sink.consume(1, Morsel(table(N // 2, N // 2), 1, 1))
    assert_true(pool.granted() > 0)
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_a_pool_too_small_for_a_morsel_fails_the_consume() raises:
    var batch = table(0, N)
    var bytes = batch_buffer_bytes(batch)
    var pool = SegmentPool(100)
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 1)
    try:
        sink.consume(0, Morsel(batch^, 0, 0))
        assert_true(False, "a denied morsel must fail")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink of segment 7 was denied "
            + String(bytes)
            + " bytes for a morsel it keeps (segment pool budget 100,"
            " granted 0); window functions do not spill",
        )
    assert_equal(pool.granted(), 0)


def test_a_pool_too_small_for_the_concatenation_fails_the_combine() raises:
    var batch = table(0, N)
    var kept = batch_buffer_bytes(batch)
    var pool = SegmentPool(kept + kept // 2)
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 1)
    sink.consume(0, Morsel(batch^, 0, 0))
    assert_equal(pool.granted(), kept)
    var pipeline = PipelineExecution(1, 0)
    try:
        sink.combine(pipeline)
        assert_true(False, "a denied concatenation must fail")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the window sink of segment 7 was denied "
            + String(kept)
            + " bytes for the concatenation (segment pool budget "
            + String(kept + kept // 2)
            + ", granted "
            + String(kept)
            + "); window functions do not spill",
        )
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_a_pool_too_small_for_the_sorted_copy_fails_the_combine() raises:
    # Room for the rows and their concatenation, not for the sorted copy and
    # the window columns.
    var batch = table(0, N)
    var kept = batch_buffer_bytes(batch)
    var pool = SegmentPool(2 * kept + 8)
    var data = _data(True, False, _exprs())
    var sink = _sink(data, pool, 1)
    sink.consume(0, Morsel(batch^, 0, 0))
    var pipeline = PipelineExecution(1, 0)
    try:
        sink.combine(pipeline)
        assert_true(False, "a denied sorted copy must fail")
    except e:
        assert_true(
            "bytes for the sorted copy and the window columns (segment pool"
            " budget " + String(2 * kept + 8) + ", granted " + String(kept)
            in String(e),
            String(e),
        )
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_row_number_and_rank_equal_the_oracle_with_null_keys_and_ties]()
    suite.test[test_lag_and_lead_with_and_without_a_default_equal_the_oracle]()
    suite.test[test_nulls_first_ascending_leads_with_the_null_keys_as_one_peer_group]()
    suite.test[test_nulls_first_descending_leads_with_the_null_keys_as_one_peer_group]()
    suite.test[test_a_running_sum_over_range_gives_peers_one_sum]()
    suite.test[test_whole_partition_aggregates_equal_the_oracle_with_null_values]()
    suite.test[test_descending_order_and_no_partition_key_equal_the_oracle]()
    suite.test[test_the_sorted_input_columns_are_the_inputs]()
    suite.test[test_four_workers_dealt_in_reverse_equal_one_worker]()
    suite.test[test_no_input_gives_no_rows_under_the_output_schema]()
    suite.test[test_the_output_columns_have_the_plans_names_and_types]()
    suite.test[test_a_sink_the_plan_cannot_describe_is_refused_by_name]()
    suite.test[test_a_read_before_combine_is_refused]()
    suite.test[test_a_sum_over_a_string_column_fails_with_the_kernels_message]()
    suite.test[test_the_pool_is_charged_while_rows_are_held_and_repaid]()
    suite.test[test_a_sink_dropped_without_a_combine_repays_the_pool]()
    suite.test[test_a_pool_too_small_for_a_morsel_fails_the_consume]()
    suite.test[test_a_pool_too_small_for_the_concatenation_fails_the_combine]()
    suite.test[test_a_pool_too_small_for_the_sorted_copy_fails_the_combine]()
    suite^.run()
