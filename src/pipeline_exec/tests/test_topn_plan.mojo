# =============================================================================
# SINK_TOPN in hand-built plans
# =============================================================================
#
# `RealBuilder` serves (SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR) from
# the `TopNSinkData` the plan names by `sink_param_id`. The plans run through
# `run_plan` over the sample table (a: row, b: NULL where a % 5 == 2 else
# a * 10, s: "s" + a % 4). What these tests prove:
#
#   * A resident batch cut into morsels and read by three workers, b
#     descending NULLS FIRST, rows [5, 17) of the order: the NULL rows and
#     then the largest b, in input order among the NULLs; the same ids when
#     the morsels are dealt in reverse and on one worker.
#   * A Parquet scan with a pushed filter and a projection, two keys (s
#     descending, b ascending NULLS FIRST), rows [3, 12) of the order the
#     scan's rows give, with the projected columns.
#   * A segment takes the top-N of the output of another.
#   * A top-N of no row returns the projected schema with no rows, and so does
#     a range that starts past the last row.
#   * A pool too small for the rows kept fails the query with the sink's own
#     message, and the builder's pool holds nothing after a failed and after a
#     successful run.
#   * A descriptor naming top-n data the builder does not hold, a top-N with a
#     negative count or offset, and a top-N over a column the rows do not have
#     are refused by name.

from std.testing import TestSuite, assert_equal, assert_raises

from async_api.token import CancellationToken
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.physical_plan import SegmentDescPod, TopNSinkData
from pipeline_exec.fake_dispatch import InlineDispatch, ReverseDispatch
from pipeline_exec.plan_harness import (
    b_is_null,
    batch_segment,
    chain,
    column_names,
    int64_column,
    output_segment,
    parquet_segment,
    project_columns,
    sample_batch,
    string_column,
    with_topn_sink,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr import BIN_GE, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    if c != "":
        out.append(c)
    return out^


def _flags(a: Bool, b: Bool = False, n: Int = 1) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    if n > 1:
        out.append(b)
    return out^


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "position " + String(i))


def _write(name: String, rows: Int, rows_per_group: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        sample_batch(0, rows), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def test_a_resident_batch_cut_to_a_range_on_three_workers() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_topn_sink(
        TopNSinkData(_names("b"), _flags(True), 12, _flags(True), 5)
    )
    var order = List[Int]()
    for r in range(100):
        if b_is_null(r):
            order.append(r)
    for r in range(99, -1, -1):
        if not b_is_null(r):
            order.append(r)
    var want = List[Int]()
    for i in range(5, 17):
        want.append(order[i])
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(with_topn_sink(batch_segment(0, handle, morsel_rows=16), id)),
        builder,
        dispatch,
        3,
        CancellationToken.new(),
    )
    _expect(int64_column(out.take(0), 0), want)
    var rev = ReverseDispatch()
    var again = run_plan(
        _one(with_topn_sink(batch_segment(0, handle, morsel_rows=16), id)),
        builder,
        rev,
        3,
        CancellationToken.new(),
    )
    _expect(int64_column(again.take(0), 0), want)
    var single = run_plan(
        _one(with_topn_sink(batch_segment(0, handle, morsel_rows=7), id)),
        builder,
        dispatch,
        1,
        CancellationToken.new(),
    )
    _expect(int64_column(single.take(0), 0), want)
    assert_equal(builder.pool_granted(), 0)


def test_a_parquet_scan_cut_to_a_range_by_two_keys() raises:
    var path = _write("topn_scan", 100, 25)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var id = builder.add_topn_sink(
        TopNSinkData(
            _names("s", "b"), _flags(True, False, 2), 9, _flags(False, True, 2), 3
        )
    )
    var ops = chain(project_columns(_names("a", "s", "b")))
    var pushed = Expr.binary(
        BIN_GE, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(20))
    )
    var desc = with_topn_sink(
        parquet_segment(0, path, None, Optional(pushed^), ops^, 16), id
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(desc^), builder, dispatch, 3, CancellationToken.new()
    )
    var batch = out.take(0)
    var order = List[Int]()
    for g in range(3, -1, -1):
        for r in range(20, 100):
            if r % 4 == g and b_is_null(r):
                order.append(r)
        for r in range(20, 100):
            if r % 4 == g and not b_is_null(r):
                order.append(r)
    var want = List[Int]()
    for i in range(3, 12):
        want.append(order[i])
    _expect(int64_column(batch, 0), want)
    var names = column_names(batch)
    assert_equal(len(names), 3)
    assert_equal(names[0], "a")
    assert_equal(names[2], "b")
    var s = string_column(batch, 1)
    for i in range(len(want)):
        assert_equal(s[i], "s" + String(want[i] % 4))
    assert_equal(builder.pool_granted(), 0)


def test_a_segment_cuts_the_output_of_another() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 30))
    var id = builder.add_topn_sink(
        TopNSinkData(_names("a"), _flags(True), 6, List[Bool](), 4)
    )
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, handle, morsel_rows=7))
    descs.append(with_topn_sink(output_segment(1, 0, morsel_rows=5), id))
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
    _expect(int64_column(out.take(1), 0), [25, 24, 23, 22, 21, 20])


def test_a_top_n_of_no_row_returns_the_projected_schema() raises:
    var path = _write("topn_none", 40, 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var none = builder.add_topn_sink(
        TopNSinkData(_names("b"), _flags(False), 5, List[Bool]())
    )
    var past = builder.add_topn_sink(
        TopNSinkData(_names("b"), _flags(False), 5, List[Bool](), 100)
    )
    var pushed = Expr.binary(
        BIN_GE, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1000))
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(
            with_topn_sink(
                parquet_segment(
                    0,
                    path,
                    None,
                    Optional(pushed^),
                    chain(project_columns(_names("s", "b"))),
                ),
                none,
            )
        ),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 2)
    assert_equal(names[0], "s")
    assert_equal(names[1], "b")
    var handle = builder.add_resident(sample_batch(0, 40))
    var beyond = run_plan(
        _one(with_topn_sink(batch_segment(0, handle, morsel_rows=9), past)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var empty = beyond.take(0)
    assert_equal(empty.num_rows(), 0)
    assert_equal(len(column_names(empty)), 3)


def test_a_pool_too_small_fails_the_query_and_leaves_nothing() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_topn_sink(
        TopNSinkData(_names("a"), _flags(False), 5, List[Bool](), 2)
    )
    builder.set_memory_budget(200)
    var dispatch = InlineDispatch()
    with assert_raises(contains="the sort sink of segment 0 was denied"):
        _ = run_plan(
            _one(with_topn_sink(batch_segment(0, handle, morsel_rows=16), id)),
            builder,
            dispatch,
            2,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)
    builder.set_memory_budget(-1)
    var out = run_plan(
        _one(with_topn_sink(batch_segment(0, handle), id)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    _expect(int64_column(out.take(0), 0), [2, 3, 4, 5, 6])
    assert_equal(builder.pool_granted(), 0)


def test_top_n_data_the_plan_cannot_run_is_refused_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 10))
    var dispatch = InlineDispatch()
    with assert_raises(
        contains="names top-n sink data 4, and the builder holds 0"
    ):
        _ = run_plan(
            _one(with_topn_sink(batch_segment(0, handle), 4)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    var negative = builder.add_topn_sink(
        TopNSinkData(_names("a"), _flags(False), -1)
    )
    with assert_raises(
        contains=(
            "the top-n sink of segment 0 keeps -1 rows after 0; neither may"
            " be negative"
        )
    ):
        _ = run_plan(
            _one(with_topn_sink(batch_segment(0, handle), negative)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    var before = builder.add_topn_sink(
        TopNSinkData(_names("a"), _flags(False), 3, List[Bool](), -2)
    )
    with assert_raises(
        contains=(
            "the top-n sink of segment 0 keeps 3 rows after -2; neither may"
            " be negative"
        )
    ):
        _ = run_plan(
            _one(with_topn_sink(batch_segment(0, handle), before)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    var id = builder.add_topn_sink(
        TopNSinkData(_names("nope"), _flags(False), 3)
    )
    with assert_raises(contains="sorts by 'nope', which is not a column"):
        _ = run_plan(
            _one(with_topn_sink(batch_segment(0, handle), id)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_resident_batch_cut_to_a_range_on_three_workers]()
    suite.test[test_a_parquet_scan_cut_to_a_range_by_two_keys]()
    suite.test[test_a_segment_cuts_the_output_of_another]()
    suite.test[test_a_top_n_of_no_row_returns_the_projected_schema]()
    suite.test[test_a_pool_too_small_fails_the_query_and_leaves_nothing]()
    suite.test[test_top_n_data_the_plan_cannot_run_is_refused_by_name]()
    suite^.run()
