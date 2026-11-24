# =============================================================================
# SINK_PARTITION_BY in hand-built plans
# =============================================================================
#
# `RealBuilder` serves (SINK_PARTITION_BY, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# from the `PartitionBySinkData` the plan names by `sink_param_id`. The plans
# run through `run_plan` over the sample table (a: row, b: NULL where a % 5 == 2
# else a * 10, s: "s" + a % 4) with ROW_NUMBER (`rn`) and a running SUM(b) over
# RANGE (`run`) partitioned by s and ordered by a. What these tests prove:
#
#   * A resident batch cut into morsels of 16 on three workers, under the
#     in-order and the reverse dispatcher, comes out as the result of a window
#     segment: the rows by s then a, `rn` counting from one in each partition
#     and `run` the running sum of the non-NULL b (NULL until one is seen).
#   * A window segment read by a SOURCE_SINK_OUTPUT segment with a filter and a
#     collect sink gives the filtered rows in the window's key order, on one to
#     four workers.
#   * Two windows chained (the second partitioned by the first's `rn`, ordered
#     by s) number each group of four rows by s, and come out ordered by `rn`
#     then s.
#   * A window over no row gives the output schema with no rows.
#   * A descriptor naming window data the builder does not hold is refused by
#     name, and the builder's pool holds nothing after a refusal, a failed
#     window and a successful one.
#   * A plan run twice on one builder gives equal batches, one after the other.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch, Schema, SchemaBuilder
from async_api.token import CancellationToken
from containers.slab import Slab
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import (
    MorselOp,
    PartitionBySinkData,
    SegmentDescPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch, ReverseDispatch
from pipeline_exec.plan_harness import (
    b_is_null,
    batch_segment,
    chain,
    column_names,
    int64_column,
    null_column,
    output_segment,
    sample_batch,
    string_column,
    with_window_sink,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr import BIN_GT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.partition_expr import (
    PF_SUM,
    PartitionExpr,
    partition_expr_output_field,
)
from plan_expr.partition_frame import PartitionFrame
from plan_expr.scalar_value import ScalarValue


def _names(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a.byte_length() > 0:
        out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def _ascending() -> List[Bool]:
    var out = List[Bool]()
    out.append(False)
    return out^


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _expect(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label)
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ", position " + String(i))


def _with_columns(
    child: Schema, ref exprs: List[PartitionExpr]
) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(child.num_columns()):
        sb.add_field(child.field_at(i))
    for i in range(len(exprs)):
        var f = partition_expr_output_field(exprs[i], child, i)
        if exprs[i].func == PF_SUM:
            f.nullable = True
        sb.add_field(f^)
    return sb.build()


def _first_window() raises -> PartitionBySinkData:
    """Partition by s, order by a: `rn` and the running SUM(b) `run`."""
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number().with_alias("rn"))
    exprs.append(
        PartitionExpr.agg_with_frame(
            PF_SUM, "b", PartitionFrame.running_range()
        ).with_alias("run")
    )
    var schema = _with_columns(sample_batch(0, 0).schema.copy(), exprs)
    return PartitionBySinkData(
        _names("s"), _names("a"), _ascending(), exprs^, schema^
    )


def _second_window(first: PartitionBySinkData) raises -> PartitionBySinkData:
    """Partition by the first window's `rn`, order by s: `rn2` numbers the
    four rows that share an `rn`."""
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number().with_alias("rn2"))
    var schema = _with_columns(first.output_schema.copy(), exprs)
    return PartitionBySinkData(
        _names("rn"), _names("s"), _ascending(), exprs^, schema^
    )


def _window_order(rows: Int) -> List[Int]:
    """The ids of rows 0 .. rows-1 by s, then a."""
    var out = List[Int]()
    for g in range(4):
        for r in range(g, rows, 4):
            out.append(r)
    return out^


def _expect_first_window(batch: RecordBatch, rows: Int, label: String) raises:
    var order = _window_order(rows)
    _expect(int64_column(batch, 0), order, label + ", a")
    var rn = int64_column(batch, 3)
    var run = int64_column(batch, 4)
    var run_null = null_column(batch, 4)
    var s = string_column(batch, 2)
    var total = 0
    var seen = False
    for p in range(len(order)):
        var r = order[p]
        if r < 4:
            total = 0
            seen = False
        if not b_is_null(r):
            total += r * 10
            seen = True
        var at = label + ", position " + String(p)
        assert_equal(s[p], "s" + String(r % 4), at)
        assert_equal(rn[p], r // 4 + 1, at + " rn")
        assert_equal(run_null[p], not seen, at + " run null")
        if seen:
            assert_equal(run[p], total, at + " run")


def test_a_resident_batch_is_the_result_of_a_window_segment() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_window_sink(_first_window())
    var inline = InlineDispatch()
    var out = run_plan(
        _one(with_window_sink(batch_segment(0, handle, morsel_rows=16), id)),
        builder,
        inline,
        3,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    var names = column_names(batch)
    assert_equal(len(names), 5)
    assert_equal(names[3], "rn")
    assert_equal(names[4], "run")
    _expect_first_window(batch, 100, "in order")
    var rev = ReverseDispatch()
    var again = run_plan(
        _one(with_window_sink(batch_segment(0, handle, morsel_rows=16), id)),
        builder,
        rev,
        3,
        CancellationToken.new(),
    )
    _expect_first_window(again.take(0), 100, "reverse")
    assert_equal(builder.pool_granted(), 0)


def _filtered_collect(
    mut builder: RealBuilder, handle: Int, id: Int, workers: Int
) raises -> RecordBatch:
    var descs = List[SegmentDescPod]()
    descs.append(
        with_window_sink(batch_segment(0, handle, morsel_rows=9), id)
    )
    descs.append(
        output_segment(
            1,
            0,
            chain(
                MorselOp.filter(
                    Expr.binary(
                        BIN_GT,
                        Expr.col_ref("rn"),
                        Expr.literal(ScalarValue.from_int(3)),
                    )
                )
            ),
            7,
        )
    )
    var dispatch = ReverseDispatch()
    var out = run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )
    return out.take(1)


def test_a_filtered_collect_keeps_the_window_key_order_on_one_to_four_workers() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_window_sink(_first_window())
    var want = List[Int]()
    for r in _window_order(100):
        if r // 4 + 1 > 3:
            want.append(r)
    for workers in range(1, 5):
        var batch = _filtered_collect(builder, handle, id, workers)
        var label = String(workers) + " workers"
        _expect(int64_column(batch, 0), want, label)
        var rn = int64_column(batch, 3)
        for i in range(len(want)):
            assert_equal(rn[i], want[i] // 4 + 1, label + ", rn")
    assert_equal(builder.pool_granted(), 0)


def test_two_windows_chained_number_each_group_by_the_second_key() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var first = _first_window()
    var second = _second_window(first)
    var first_id = builder.add_window_sink(first^)
    var second_id = builder.add_window_sink(second^)
    var descs = List[SegmentDescPod]()
    descs.append(
        with_window_sink(batch_segment(0, handle, morsel_rows=11), first_id)
    )
    descs.append(
        with_window_sink(output_segment(1, 0, morsel_rows=6), second_id)
    )
    var dispatch = ReverseDispatch()
    var out = run_plan(descs, builder, dispatch, 3, CancellationToken.new())
    var batch = out.take(1)
    var want = List[Int]()
    for k in range(25):
        for g in range(4):
            want.append(4 * k + g)
    _expect(int64_column(batch, 0), want, "ordered by rn then s")
    var rn2 = int64_column(batch, 5)
    var rn = int64_column(batch, 3)
    for i in range(len(want)):
        assert_equal(rn[i], want[i] // 4 + 1)
        assert_equal(rn2[i], want[i] % 4 + 1, "rn2 at " + String(i))
    assert_equal(column_names(batch)[5], "rn2")
    assert_equal(builder.pool_granted(), 0)


def test_a_window_over_no_row_returns_the_output_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 0))
    var id = builder.add_window_sink(_first_window())
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(with_window_sink(batch_segment(0, handle), id)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 5)
    assert_equal(names[0], "a")
    assert_equal(names[3], "rn")
    assert_equal(names[4], "run")
    assert_true(batch.schema.field_at(3).arrow_type == ArrowType.INT64)


def test_window_data_the_builder_does_not_hold_is_refused_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 10))
    var dispatch = InlineDispatch()
    with assert_raises(
        contains="segment 0 names window sink data 4, and the builder holds 0"
    ):
        _ = run_plan(
            _one(with_window_sink(batch_segment(0, handle), 4)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)
    # A pool too small for the rows fails the query by name and holds nothing.
    var id = builder.add_window_sink(_first_window())
    builder.set_memory_budget(200)
    with assert_raises(contains="the window sink of segment 0 was denied"):
        _ = run_plan(
            _one(with_window_sink(batch_segment(0, handle, morsel_rows=4), id)),
            builder,
            dispatch,
            2,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)


def test_a_plan_run_twice_gives_equal_batches() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 60))
    var id = builder.add_window_sink(_first_window())
    var inline = InlineDispatch()
    var out1 = run_plan(
        _one(with_window_sink(batch_segment(0, handle, morsel_rows=8), id)),
        builder,
        inline,
        4,
        CancellationToken.new(),
    )
    var first = out1.take(0)
    var out2 = run_plan(
        _one(with_window_sink(batch_segment(0, handle, morsel_rows=8), id)),
        builder,
        inline,
        4,
        CancellationToken.new(),
    )
    var second = out2.take(0)
    assert_equal(first.num_rows(), second.num_rows())
    for c in range(first.num_columns()):
        var a = null_column(first, c)
        var b = null_column(second, c)
        for i in range(first.num_rows()):
            assert_equal(a[i], b[i])
    _expect(int64_column(first, 0), int64_column(second, 0), "a")
    _expect(int64_column(first, 3), int64_column(second, 3), "rn")
    _expect_first_window(first, 60, "first run")
    _expect_first_window(second, 60, "second run")
    assert_equal(builder.pool_granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_resident_batch_is_the_result_of_a_window_segment]()
    suite.test[test_a_filtered_collect_keeps_the_window_key_order_on_one_to_four_workers]()
    suite.test[test_two_windows_chained_number_each_group_by_the_second_key]()
    suite.test[test_a_window_over_no_row_returns_the_output_schema]()
    suite.test[test_window_data_the_builder_does_not_hold_is_refused_by_name]()
    suite.test[test_a_plan_run_twice_gives_equal_batches]()
    suite^.run()
