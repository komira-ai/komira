# =============================================================================
# SINK_PARTITION_TOPN in hand-built plans
# =============================================================================
#
# `RealBuilder` serves (SINK_PARTITION_TOPN, KEY_DTYPE_NONE,
# SINK_ORIENT_COLUMNAR) from the `PartitionTopNSinkData` the plan names by
# `sink_param_id`. The plans run through `run_plan` over the sample table (a:
# row, b: NULL where a % 5 == 2 else a * 10, s: "s" + a % 4). What these tests
# prove:
#
#   * A resident batch cut into morsels of 7 on three workers, under the
#     in-order and the reverse dispatcher, keeps per partition of s the three
#     rows of largest a (ROW_NUMBER over a DESC), and nothing else.
#   * RANK over s with no partition keeps every row tied at rank 1 (25 rows
#     for k = 1, more than its over_fetch_k of 17), and the named rank column
#     holds 1 on each; a SOURCE_SINK_OUTPUT segment reads it.
#   * RANK over b ascending puts the NULL b last: with k past the non-NULL
#     rows of a partition, the NULL rows are kept and share one rank.
#   * k = 0, and a batch of no row, give the output schema with no rows (the
#     rank column included).
#   * Refused by name: data the builder does not hold, a pool too small for
#     the rows (the pool holds nothing afterwards), a direction list of
#     another length and a function other than ROW_NUMBER or RANK when the
#     sink is built, a worker id outside the sink's slots, and a read before
#     the combine.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from async_api.token import CancellationToken
from parquet.runtime_footer_cache import ParquetMetadataCache
from morsel.morsel import Morsel
from physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    PartitionTopNSinkData,
    SegmentDescPod,
    SINK_ORIENT_COLUMNAR,
    SINK_PARTITION_TOPN,
)
from pipeline_exec.fake_dispatch import InlineDispatch, ReverseDispatch
from pipeline_exec.plan_harness import (
    b_is_null,
    batch_segment,
    column_names,
    int64_column,
    output_segment,
    sample_batch,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_partition_topn import PartitionTopNPipelineSink
from plan_expr.expr_pool import ExprPool
from plan_expr.partition_expr import PF_DENSE_RANK, PF_RANK, PF_ROW_NUMBER


def _names(a: String = "") -> List[String]:
    var out = List[String]()
    if a.byte_length() > 0:
        out.append(a)
    return out^


def _flag(descending: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(descending)
    return out^


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _with_ptopn(var desc: SegmentDescPod, param_id: Int) -> SegmentDescPod:
    desc.sink_kind = SINK_PARTITION_TOPN
    desc.sink_key_dtype = KEY_DTYPE_NONE
    desc.sink_orientation = SINK_ORIENT_COLUMNAR
    desc.sink_param_id = param_id
    return desc^


def _schema(rank_col: String = "") raises -> Schema:
    """The sample table's columns, and an INT64 `rank_col` when named."""
    var sb = SchemaBuilder()
    var child = sample_batch(0, 0)
    for i in range(child.schema.num_columns()):
        sb.add_field(child.schema.field_at(i))
    if rank_col.byte_length() > 0:
        sb.add_field(Field(rank_col, ArrowType.INT64, False))
    return sb.build()


def _data(
    partition: String,
    order: String,
    descending: Bool,
    k: Int,
    func: UInt8 = PF_ROW_NUMBER,
    rank_col: String = "",
    over_fetch_k: Int = -1,
) raises -> PartitionTopNSinkData:
    var name: Optional[String] = None
    if rank_col.byte_length() > 0:
        name = String(rank_col)
    return PartitionTopNSinkData(
        _names(partition),
        _names(order),
        _flag(descending),
        k,
        _schema(rank_col),
        func=func,
        over_fetch_k=over_fetch_k,
        output_rank_col_name=name^,
    )


def _sorted(var xs: List[Int]) -> List[Int]:
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            var t = xs[j]
            xs[j] = xs[j - 1]
            xs[j - 1] = t
            j -= 1
    return xs^


def _expect(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label)
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ", position " + String(i))


def test_row_number_keeps_the_top_three_of_each_partition() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_partition_topn_sink(_data("s", "a", True, 3))
    # Per s = a % 4, the three largest a: 96..99, 92..95, 88..91.
    var want = List[Int]()
    for a in range(88, 100):
        want.append(a)
    var inline = InlineDispatch()
    var out = run_plan(
        _one(_with_ptopn(batch_segment(0, handle, morsel_rows=7), id)),
        builder,
        inline,
        3,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    assert_equal(len(column_names(batch)), 3)
    _expect(_sorted(int64_column(batch, 0)), want, "in order")
    var rev = ReverseDispatch()
    var again = run_plan(
        _one(_with_ptopn(batch_segment(0, handle, morsel_rows=7), id)),
        builder,
        rev,
        3,
        CancellationToken.new(),
    )
    _expect(_sorted(int64_column(again.take(0), 0)), want, "reverse")
    assert_equal(builder.pool_granted(), 0)


def test_rank_keeps_every_tie_and_names_its_column() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_partition_topn_sink(
        _data("", "s", False, 1, PF_RANK, "rk", over_fetch_k=17)
    )
    var descs = List[SegmentDescPod]()
    descs.append(_with_ptopn(batch_segment(0, handle, morsel_rows=9), id))
    descs.append(output_segment(1, 0, morsel_rows=5))
    var dispatch = ReverseDispatch()
    var out = run_plan(descs, builder, dispatch, 3, CancellationToken.new())
    var batch = out.take(1)
    var names = column_names(batch)
    assert_equal(len(names), 4)
    assert_equal(names[3], "rk")
    var want = List[Int]()
    for a in range(0, 100, 4):
        want.append(a)
    _expect(_sorted(int64_column(batch, 0)), want, "every s0 row")
    var rk = int64_column(batch, 3)
    for i in range(len(rk)):
        assert_equal(rk[i], 1, "rank at " + String(i))
    var s = string_column(batch, 2)
    for i in range(len(s)):
        assert_equal(s[i], "s0")
    assert_equal(builder.pool_granted(), 0)


def test_rank_puts_null_order_keys_last_as_peers() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    # 40 rows: each s holds 10, two of them with a NULL b (a % 5 == 2).
    var handle = builder.add_resident(sample_batch(0, 40))
    var id = builder.add_partition_topn_sink(
        _data("s", "b", False, 9, PF_RANK, "rk")
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(_with_ptopn(batch_segment(0, handle, morsel_rows=6), id)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    # Eight non-NULL b rank 1 .. 8 and the two NULL b share rank 9: all 40.
    assert_equal(batch.num_rows(), 40)
    var a = int64_column(batch, 0)
    var rk = int64_column(batch, 3)
    for i in range(len(a)):
        if b_is_null(a[i]):
            assert_equal(rk[i], 9, "a NULL b at a = " + String(a[i]))
        else:
            assert_true(rk[i] <= 8, "a = " + String(a[i]))
    assert_equal(builder.pool_granted(), 0)


def test_no_row_kept_gives_the_output_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var rows = builder.add_resident(sample_batch(0, 30))
    var empty = builder.add_resident(sample_batch(0, 0))
    var zero = builder.add_partition_topn_sink(
        _data("s", "a", True, 0, PF_ROW_NUMBER, "rn")
    )
    var any = builder.add_partition_topn_sink(_data("s", "a", True, 2))
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(_with_ptopn(batch_segment(0, rows), zero)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 4)
    assert_equal(names[0], "a")
    assert_equal(names[3], "rn")
    assert_true(batch.schema.field_at(3).arrow_type == ArrowType.INT64)
    var none = run_plan(
        _one(_with_ptopn(batch_segment(0, empty), any)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var no_rows = none.take(0)
    assert_equal(no_rows.num_rows(), 0)
    assert_equal(len(column_names(no_rows)), 3)
    assert_equal(builder.pool_granted(), 0)


def test_what_the_sink_does_not_serve_is_refused_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 40))
    var dispatch = InlineDispatch()
    with assert_raises(
        contains="segment 0 names partition top-n sink data 2, and the"
        " builder holds 0"
    ):
        _ = run_plan(
            _one(_with_ptopn(batch_segment(0, handle), 2)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    var mismatched = _data("s", "a", True, 2)
    mismatched.descending.append(False)
    var bad_dirs = builder.add_partition_topn_sink(mismatched^)
    with assert_raises(
        contains="the partition top-n sink of segment 0 lists 2 directions"
        " for 1 sort keys"
    ):
        _ = run_plan(
            _one(_with_ptopn(batch_segment(0, handle), bad_dirs)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    var bad_fn = builder.add_partition_topn_sink(
        _data("s", "a", True, 2, PF_DENSE_RANK)
    )
    with assert_raises(
        contains="numbers its rows with function "
        + String(Int(PF_DENSE_RANK))
        + "; only ROW_NUMBER and RANK are served"
    ):
        _ = run_plan(
            _one(_with_ptopn(batch_segment(0, handle), bad_fn)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)
    # A pool too small for the rows fails the query by name and holds nothing.
    var id = builder.add_partition_topn_sink(_data("s", "a", True, 2))
    builder.set_memory_budget(200)
    with assert_raises(
        contains="the partition top-n sink of segment 0 was denied"
    ):
        _ = run_plan(
            _one(_with_ptopn(batch_segment(0, handle, morsel_rows=4), id)),
            builder,
            dispatch,
            2,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)


def test_a_worker_outside_the_slots_and_a_read_before_combine_are_refused() raises:
    var data = _data("s", "a", True, 2)
    var sink = PartitionTopNPipelineSink(data, SegmentPool(), 3)
    sink.resize_worker_state(1)
    with assert_raises(
        contains="the partition top-n sink holds 1 worker slots, got worker 4"
    ):
        sink.consume(4, Morsel(sample_batch(0, 3), 0, 0))
    with assert_raises(
        contains="the partition top-n sink was read before it was combined"
    ):
        _ = sink.take_output()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
