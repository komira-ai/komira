# =============================================================================
# test_agg_cd_group_topk_null_order -- the bounded top-k drain places NULLs as
# the hint says
# =============================================================================
#
# `SELECT k, COUNT(DISTINCT v), MAX(w) GROUP BY k ORDER BY MAX(w) DESC LIMIT
# 10`, where five of 200 groups hold only NULL `w` (their MAX is NULL), with
# the hint carrying `nulls_first = True` and then `False`. The oracle is the
# declined drain (every group) followed by the top-N sink under the same
# comparator, as in `test_agg_cd_group_topk_bounded_drain`; the bounded arm
# must give the same rows in the same order, NULL groups included, for either
# placement the caller names. A bounded arm that places NULL groups on its own
# disagrees with the oracle as soon as the top-N sink honours the placement.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_op_sort.sort_topn_sink import _execute_topn_sink
from komira_physical_plan.physical_plan import AggSinkData, TopNSinkData
from komira_plan_expr.agg_expr import count_distinct, max
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_cd_group_topk import CdGroupTopKHint
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
)

comptime _ROWS: Int = 70_000
comptime _WORKERS: Int = 4
comptime _GROUPS: Int = 200
comptime _K: Int = 10


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _is_null_group(g: Int) -> Bool:
    return g % 40 == 0


def _batch() raises -> RecordBatch:
    var keys = List[String]()
    var vs = PrimitiveArray[DType.int64].allocate(_ROWS)
    var ws = PrimitiveArray[DType.int64].allocate_nullable(_ROWS)
    for i in range(_ROWS):
        var g = i % _GROUPS
        keys.append(String("group-") + String(g))
        vs.set(i, Int64((i // _GROUPS) % 7))
        ws.set(i, Int64(g))
        if _is_null_group(g):
            ws._set_null(i)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(Column.from_string(StringArray.from_strings(keys)))
    b.add_column(Column.from_primitive[DType.int64](vs))
    b.add_column(Column.from_primitive[DType.int64](ws))
    return b.build(sb.build())


def _run_with(nulls_first: Bool, bounded: Bool) raises -> RecordBatch:
    """The driver over `_batch()`. With `bounded`, the hint is passed; without,
    every group is emitted."""
    var batch = _batch()
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    aggs.append(max(col("w")))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.STRING, False))
    osb.add_field(Field("n", ArrowType.INT64, False))
    osb.add_field(Field("m", ArrowType.INT64, True))
    var sink = AggSinkData(group_by^, aggs^, osb.build())
    var hint = Optional[CdGroupTopKHint]()
    if bounded:
        var cols = List[String]()
        cols.append(String("m"))
        var d = List[Bool]()
        d.append(True)
        var nf = List[Bool]()
        nf.append(nulls_first)
        hint = Optional(CdGroupTopKHint(cols^, d^, _K, nf^))
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, 1, 2, _ROWS, hint^
    )


def _assert_agrees_with_full_drain_plus_topn(nulls_first: Bool) raises:
    var got = _run_with(nulls_first, True)
    var full = _run_with(nulls_first, False)
    assert_equal(full.num_rows(), _GROUPS, "the declined drain emits every group")
    var cols = List[String]()
    cols.append(String("m"))
    var d = List[Bool]()
    d.append(True)
    var nf = List[Bool]()
    nf.append(nulls_first)
    var want = _execute_topn_sink(full^, TopNSinkData(cols^, d^, _K, nf^))
    assert_equal(got.num_rows(), _K, "the bounded arm emits k rows")
    assert_equal(want.num_rows(), _K, "the oracle emits k rows")
    var gk = got.column_at(0).as_string()
    var wk = want.column_at(0).as_string()
    var gn = got.column_at(1).as_primitive[DType.int64]()
    var wn = want.column_at(1).as_primitive[DType.int64]()
    var gm = got.column_at(2).as_primitive[DType.int64]()
    var wm = want.column_at(2).as_primitive[DType.int64]()
    for r in range(_K):
        var what = "row " + String(r) + " (nulls_first " + String(nulls_first) + ")"
        assert_equal(gk.get(r), wk.get(r), what + ": key")
        assert_equal(Int(gn.get(r)), Int(wn.get(r)), what + ": count")
        var gnull = got.column_at(2).is_null_at(r)
        assert_equal(gnull, want.column_at(2).is_null_at(r), what + ": NULL max")
        if not gnull:
            assert_equal(Int(gm.get(r)), Int(wm.get(r)), what + ": max")


def test_nulls_first_hint_agrees_with_the_full_drain_plus_topn() raises:
    _assert_agrees_with_full_drain_plus_topn(True)


def test_nulls_last_hint_agrees_with_the_full_drain_plus_topn() raises:
    _assert_agrees_with_full_drain_plus_topn(False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
