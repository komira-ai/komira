# =============================================================================
# SOURCE_GENERATE_SERIES: the rows of generate_series / range, computed lazily
# =============================================================================
#
# The source is drained by workers claiming in turn, the way the driver's
# workers do, and run through RealBuilder and run_plan. What these tests prove:
#
#   * test_integer_series_comes_back_in_order_in_morsels: generate_series(1, 7)
#     in morsels of three rows is 1..7 in partition order, no morsel longer
#     than three rows, on the column the spec names, INT64.
#   * test_exclusive_range_stops_before_the_bound: range(1, 7) ends at 6.
#   * test_a_negative_step_counts_down: generate_series(10, 1, -3) is 10, 7,
#     4, 1.
#   * test_an_hourly_timestamp_series_is_timestamp_typed: five hourly values,
#     the column and the schema TIMESTAMP in microseconds.
#   * test_a_monthly_series_clamps_to_the_end_of_the_month: from 31 January 2024
#     by one month: 31 Jan, 29 Feb, 29 Mar, 29 Apr, across morsels of two rows.
#   * test_an_empty_series_is_one_empty_batch_at_the_schema: a step pointing
#     away from the bound gives one batch of no row at the spec's schema, then
#     None, so the collect sink's output has the column.
#   * test_a_series_of_two_to_the_62_rows_is_not_materialized: the first claim
#     returns one morsel of morsel_rows rows from the start.
#   * test_hints_follow_the_row_count: morsels rounded up and at least one,
#     the partition hint clamped, the row count saturating at the largest Int,
#     a month series hinting one morsel.
#   * test_a_morsel_size_of_zero_and_a_spec_with_no_step_are_refused: each is
#     an error naming the cause.
#   * test_a_plan_over_a_series_collects_every_row_in_order: run_plan on one
#     and on three workers gives the whole series in order, an empty series
#     gives no row at the column's name.
#   * test_a_limit_over_a_huge_series_ends_the_run: a LIMIT 3 over
#     generate_series(1, 2^62) returns exactly 1, 2, 3.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from async_api.token import CancellationToken
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import MorselOp, SegmentDescPod, SourceSpecPod
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    chain,
    column_names,
    generate_series_segment,
    int64_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.source_generate_series import (
    GenerateSeriesSource,
    build_generate_series_source,
)
from plan_expr.expr_pool import ExprPool
from scan_source.series_scan import SeriesSpec, US_PER_DAY

comptime NW = 3
comptime HOUR_US: Int64 = 3_600_000_000
comptime TWO_62: Int64 = 4611686018427387904


def _ints(
    var column: String, start: Int64, stop: Int64, step: Int64, inclusive: Bool
) -> SeriesSpec:
    return SeriesSpec(column^, False, start, stop, step, 0, inclusive)


def _drain[S: MorselSourceImpl](src: S) raises -> Slab[Morsel]:
    """Every morsel, the workers claiming in turn until each has been told
    the input ended."""
    var out = Slab[Morsel]()
    var live = List[Bool](length=NW, fill=True)
    var n_live = NW
    while n_live > 0:
        for w in range(NW):
            if not live[w]:
                continue
            var m = src.next_morsel(w)
            if m:
                out.append(m.take())
            else:
                live[w] = False
                n_live -= 1
    return out^


def _values(ref morsels: Slab[Morsel]) raises -> List[Int]:
    """The values in partition order."""
    var out = List[Int]()
    for p in range(len(morsels)):
        for k in range(len(morsels)):
            if morsels[k].partition_id == p:
                var v = int64_column(morsels[k].batch, 0)
                for i in range(len(v)):
                    out.append(v[i])
    return out^


def _drain_values(var spec: SeriesSpec, morsel_rows: Int) raises -> List[Int]:
    var morsels = _drain(GenerateSeriesSource(spec^, morsel_rows))
    for i in range(len(morsels)):
        assert_true(morsels[i].batch.num_rows() <= morsel_rows)
    return _values(morsels)


def _assert_ints(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def test_integer_series_comes_back_in_order_in_morsels() raises:
    var morsels = _drain(
        GenerateSeriesSource(_ints("generate_series", 1, 7, 1, True), 3)
    )
    assert_equal(len(morsels), 3)
    for i in range(len(morsels)):
        assert_true(morsels[i].batch.num_rows() <= 3)
        assert_equal(morsels[i].batch.num_columns(), 1)
        assert_true(morsels[i].batch.column_at(0).arrow_type == ArrowType.INT64)
    assert_equal(column_names(morsels[0].batch)[0], "generate_series")
    _assert_ints(_values(morsels), [1, 2, 3, 4, 5, 6, 7])


def test_exclusive_range_stops_before_the_bound() raises:
    _assert_ints(
        _drain_values(_ints("range", 1, 7, 1, False), 4), [1, 2, 3, 4, 5, 6]
    )


def test_a_negative_step_counts_down() raises:
    _assert_ints(
        _drain_values(_ints("generate_series", 10, 1, -3, True), 2),
        [10, 7, 4, 1],
    )


def test_an_hourly_timestamp_series_is_timestamp_typed() raises:
    var spec = SeriesSpec("t", True, 0, 4 * HOUR_US, HOUR_US, 0, True)
    var src = GenerateSeriesSource(spec^, 2)
    assert_true(
        src.output_schema().field_arrow_type(0) == ArrowType.TIMESTAMP_US
    )
    var morsels = _drain(src^)
    assert_equal(len(morsels), 3)
    for i in range(len(morsels)):
        assert_true(
            morsels[i].batch.column_at(0).arrow_type == ArrowType.TIMESTAMP_US
        )
    _assert_ints(
        _values(morsels),
        [0, 3_600_000_000, 7_200_000_000, 10_800_000_000, 14_400_000_000],
    )


def test_a_monthly_series_clamps_to_the_end_of_the_month() raises:
    # Days since the epoch: 31 Jan 2024 is 19753, 29 Feb 19782, 29 Mar 19811,
    # 29 Apr 19842.
    var day = Int(US_PER_DAY)
    var spec = SeriesSpec(
        "t", True, 19753 * US_PER_DAY, 19842 * US_PER_DAY, 0, 1, True
    )
    _assert_ints(
        _drain_values(spec^, 2),
        [19753 * day, 19782 * day, 19811 * day, 19842 * day],
    )


def test_an_empty_series_is_one_empty_batch_at_the_schema() raises:
    var src = GenerateSeriesSource(_ints("generate_series", 5, 1, 1, True), 4)
    var first = src.next_morsel(0)
    assert_true(Bool(first))
    var m = first.take()
    assert_equal(m.batch.num_rows(), 0)
    assert_equal(m.batch.num_columns(), 1)
    assert_equal(column_names(m.batch)[0], "generate_series")
    assert_true(m.batch.column_at(0).arrow_type == ArrowType.INT64)
    assert_true(not src.next_morsel(0))
    assert_true(not src.next_morsel(1))
    var ts = GenerateSeriesSource(SeriesSpec.empty("t", True), 4)
    var tm = ts.next_morsel(0).take()
    assert_equal(tm.batch.num_rows(), 0)
    assert_true(tm.batch.column_at(0).arrow_type == ArrowType.TIMESTAMP_US)


def test_a_series_of_two_to_the_62_rows_is_not_materialized() raises:
    var src = GenerateSeriesSource(
        _ints("generate_series", 1, TWO_62, 1, True), 5
    )
    var m = src.next_morsel(0).take()
    assert_equal(m.batch.num_rows(), 5)
    _assert_ints(int64_column(m.batch, 0), [1, 2, 3, 4, 5])
    var second = src.next_morsel(1).take()
    assert_equal(second.partition_id, 1)
    _assert_ints(int64_column(second.batch, 0), [6, 7, 8, 9, 10])


def test_hints_follow_the_row_count() raises:
    var five = GenerateSeriesSource(_ints("c", 1, 5, 1, True), 2)
    assert_equal(five.row_count_hint(), 5)
    assert_equal(five.partition_hint(), 3)
    var four = GenerateSeriesSource(_ints("c", 1, 4, 1, True), 2)
    assert_equal(four.partition_hint(), 2)
    var none = GenerateSeriesSource(_ints("c", 5, 1, 1, True), 2)
    assert_equal(none.row_count_hint(), 0)
    assert_equal(none.partition_hint(), 1)
    var huge = GenerateSeriesSource(_ints("c", 1, TWO_62, 1, True), 2)
    assert_equal(huge.row_count_hint(), Int(TWO_62))
    assert_equal(huge.partition_hint(), 1 << 30)
    var every = GenerateSeriesSource(
        _ints("c", (-Int64.MAX - 1), Int64.MAX, 1, True), 2
    )
    assert_equal(every.row_count_hint(), Int.MAX)
    var months = GenerateSeriesSource(
        SeriesSpec("t", True, 0, 400 * US_PER_DAY, 0, 1, True), 7
    )
    assert_equal(months.partition_hint(), 1)
    assert_equal(months.row_count_hint(), 7)


def test_a_morsel_size_of_zero_and_a_spec_with_no_step_are_refused() raises:
    with assert_raises(contains="needs a positive morsel size, not 0"):
        _ = GenerateSeriesSource(_ints("c", 1, 5, 1, True), 0)
    with assert_raises(contains="exactly one non-zero step"):
        _ = GenerateSeriesSource(_ints("c", 1, 5, 0, True), 2)
    var spec = SourceSpecPod.generate_series(_ints("c", 1, 3, 1, True))
    _assert_ints(
        _values(_drain(build_generate_series_source(spec, 2))), [1, 2, 3]
    )


def _run(
    var spec: SeriesSpec, var ops: Slab[MorselOp], workers: Int, morsel_rows: Int
) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var dispatch = InlineDispatch()
    var descs = List[SegmentDescPod]()
    descs.append(
        generate_series_segment(
            0, SourceSpecPod.generate_series(spec^), ops^, morsel_rows
        )
    )
    var out = run_plan(descs, builder, dispatch, workers, CancellationToken.new())
    return out.take(0)


def test_a_plan_over_a_series_collects_every_row_in_order() raises:
    for workers in range(1, 4, 2):
        var batch = _run(
            _ints("generate_series", 1, 25, 1, True),
            Slab[MorselOp](),
            workers,
            4,
        )
        assert_equal(column_names(batch)[0], "generate_series")
        var got = int64_column(batch, 0)
        assert_equal(len(got), 25)
        for i in range(25):
            assert_equal(got[i], i + 1)
        var empty = _run(
            _ints("range", 3, 1, 1, False), Slab[MorselOp](), workers, 4
        )
        assert_equal(empty.num_rows(), 0)
        assert_equal(column_names(empty)[0], "range")


def test_a_limit_over_a_huge_series_ends_the_run() raises:
    var batch = _run(
        _ints("generate_series", 1, TWO_62, 1, True),
        chain(MorselOp.limit(3)),
        1,
        0,
    )
    _assert_ints(int64_column(batch, 0), [1, 2, 3])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
