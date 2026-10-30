# =============================================================================
# SINK_SORT in hand-built plans
# =============================================================================
#
# `RealBuilder` serves (SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR) from
# the `SortSinkData` the plan names by `sink_param_id`. The plans run through
# `run_plan` over the sample table (a: row, b: NULL where a % 5 == 2 else
# a * 10, s: "s" + a % 4). What these tests prove:
#
#   * A resident batch sorted by b descending NULLS FIRST on three workers and
#     cut morsels: the NULL rows first in input order, then the rest by b
#     descending.
#   * A Parquet scan with a pushed filter and a projection, sorted by two keys
#     (s descending, b ascending NULLS FIRST), equals the order computed by
#     hand from the rows the scan keeps.
#   * A key computed by a projection (b - a), whose NULL slots hold whatever the
#     arithmetic left, orders its NULLs by the next key only.
#   * A segment sorts the output of another (the Q1 shape: a producer segment,
#     then a sort over what it published).
#   * A sort of no row returns the projected schema with no rows.
#   * A pool too small for the input fails the query with the sink's own
#     message, and the builder's pool holds nothing after a failed and after a
#     successful run.
#   * A descriptor naming sort data the builder does not hold, and a sort over
#     a column the rows do not have, are refused by name.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import (
    MorselOp,
    SegmentDescPod,
    SortSinkData,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch, ReverseDispatch
from komira_pipeline_exec.plan_harness import (
    b_is_null,
    batch_segment,
    chain,
    column_names,
    int64_column,
    null_column,
    output_segment,
    parquet_segment,
    project_columns,
    sample_batch,
    string_column,
    with_sort_sink,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_collections.slab import Slab
from komira_plan_expr.expr import BIN_GE, BIN_SUB, Expr
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir


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


def test_a_resident_batch_sorted_descending_nulls_first_on_three_workers() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_sort_sink(
        SortSinkData(_names("b"), _flags(True), 0, _flags(True))
    )
    var want = List[Int]()
    for r in range(100):
        if b_is_null(r):
            want.append(r)
    for r in range(99, -1, -1):
        if not b_is_null(r):
            want.append(r)
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(with_sort_sink(batch_segment(0, handle, morsel_rows=16), id)),
        builder,
        dispatch,
        3,
        CancellationToken.new(),
    )
    var batch = out.take(0)
    _expect(int64_column(batch, 0), want)
    var nulls = null_column(batch, 1)
    for i in range(100):
        assert_equal(nulls[i], b_is_null(want[i]))
    var rev = ReverseDispatch()
    var again = run_plan(
        _one(with_sort_sink(batch_segment(0, handle, morsel_rows=16), id)),
        builder,
        rev,
        3,
        CancellationToken.new(),
    )
    _expect(int64_column(again.take(0), 0), want)
    assert_equal(builder.pool_granted(), 0)


def test_a_parquet_scan_sorted_by_two_keys() raises:
    var path = _write("sort_scan", 100, 25)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var id = builder.add_sort_sink(
        SortSinkData(
            _names("s", "b"), _flags(True, False, 2), 0, _flags(False, True, 2)
        )
    )
    var ops = chain(project_columns(_names("a", "s", "b")))
    var pushed = Expr.binary(
        BIN_GE, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(20))
    )
    var desc = with_sort_sink(
        parquet_segment(0, path, None, Optional(pushed^), ops^, 16), id
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(desc^), builder, dispatch, 3, CancellationToken.new()
    )
    var batch = out.take(0)
    var want = List[Int]()
    for g in range(3, -1, -1):
        for r in range(20, 100):
            if r % 4 == g and b_is_null(r):
                want.append(r)
        for r in range(20, 100):
            if r % 4 == g and not b_is_null(r):
                want.append(r)
    _expect(int64_column(batch, 0), want)
    var names = column_names(batch)
    assert_equal(names[0], "a")
    assert_equal(names[2], "b")
    var s = string_column(batch, 1)
    for i in range(len(want)):
        assert_equal(s[i], "s" + String(want[i] % 4))
    assert_equal(builder.pool_granted(), 0)


def test_a_segment_sorts_the_output_of_another() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 30))
    var id = builder.add_sort_sink(
        SortSinkData(_names("a"), _flags(True), 0, List[Bool]())
    )
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, handle, morsel_rows=7))
    descs.append(with_sort_sink(output_segment(1, 0, morsel_rows=5), id))
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
    var want = List[Int]()
    for r in range(29, -1, -1):
        want.append(r)
    _expect(int64_column(out.take(1), 0), want)


def _sub_ba() -> MorselOp:
    """Project (a, c = b - a): a NULL c is a computed NULL, and the value an
    arithmetic kernel leaves under it may differ from row to row."""
    var exprs = Slab[Expr]()
    exprs.append(Expr.col_ref("a"))
    exprs.append(Expr.binary(BIN_SUB, Expr.col_ref("b"), Expr.col_ref("a")))
    return MorselOp.project(exprs^, _names("a", "c"))


def test_what_lies_under_a_computed_null_does_not_order_the_nulls() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 50))
    # c ascending NULLS LAST, then a: the valid rows by a (c = 9a), then the
    # NULL rows by a, whatever the kernel stored under their slots.
    var first = builder.add_sort_sink(
        SortSinkData(_names("c", "a"), _flags(False, False, 2), 0, _flags(False, False, 2))
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(with_sort_sink(batch_segment(0, handle, chain(_sub_ba())), first)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var want = List[Int]()
    for r in range(50):
        if not b_is_null(r):
            want.append(r)
    for r in range(50):
        if b_is_null(r):
            want.append(r)
    _expect(int64_column(out.take(0), 0), want)
    # c descending NULLS FIRST, then a ascending.
    var second = builder.add_sort_sink(
        SortSinkData(_names("c", "a"), _flags(True, False, 2), 0, _flags(True, False, 2))
    )
    var again = run_plan(
        _one(with_sort_sink(batch_segment(0, handle, chain(_sub_ba())), second)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    var want2 = List[Int]()
    for r in range(50):
        if b_is_null(r):
            want2.append(r)
    for r in range(49, -1, -1):
        if not b_is_null(r):
            want2.append(r)
    _expect(int64_column(again.take(0), 0), want2)


def test_a_sort_of_no_row_returns_the_projected_schema() raises:
    var path = _write("sort_none", 40, 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var id = builder.add_sort_sink(
        SortSinkData(_names("b"), _flags(False), 0, List[Bool]())
    )
    var pushed = Expr.binary(
        BIN_GE, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1000))
    )
    var ops = chain(project_columns(_names("s", "b")))
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(
            with_sort_sink(
                parquet_segment(0, path, None, Optional(pushed^), ops^), id
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


def test_a_pool_too_small_fails_the_query_and_leaves_nothing() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_sort_sink(
        SortSinkData(_names("a"), _flags(False), 0, List[Bool]())
    )
    builder.set_memory_budget(200)
    var dispatch = InlineDispatch()
    with assert_raises(contains="the sort sink of segment 0 was denied"):
        _ = run_plan(
            _one(with_sort_sink(batch_segment(0, handle, morsel_rows=16), id)),
            builder,
            dispatch,
            2,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)
    # A budget that holds the rows but not the sorted copy.
    builder.set_memory_budget(3000)
    with assert_raises(contains="concatenation and the sorted copy"):
        _ = run_plan(
            _one(with_sort_sink(batch_segment(0, handle), id)),
            builder,
            dispatch,
            2,
            CancellationToken.new(),
        )
    assert_equal(builder.pool_granted(), 0)
    builder.set_memory_budget(-1)
    var out = run_plan(
        _one(with_sort_sink(batch_segment(0, handle), id)),
        builder,
        dispatch,
        2,
        CancellationToken.new(),
    )
    assert_equal(out.take(0).num_rows(), 100)
    assert_equal(builder.pool_granted(), 0)


def test_sort_data_the_builder_does_not_hold_is_refused_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 10))
    var dispatch = InlineDispatch()
    with assert_raises(contains="names sort sink data 4, and the builder holds 0"):
        _ = run_plan(
            _one(with_sort_sink(batch_segment(0, handle), 4)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )
    var id = builder.add_sort_sink(
        SortSinkData(_names("nope"), _flags(False), 0, List[Bool]())
    )
    with assert_raises(contains="sorts by 'nope', which is not a column"):
        _ = run_plan(
            _one(with_sort_sink(batch_segment(0, handle), id)),
            builder,
            dispatch,
            1,
            CancellationToken.new(),
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_resident_batch_sorted_descending_nulls_first_on_three_workers]()
    suite.test[test_a_parquet_scan_sorted_by_two_keys]()
    suite.test[test_a_segment_sorts_the_output_of_another]()
    suite.test[test_what_lies_under_a_computed_null_does_not_order_the_nulls]()
    suite.test[test_a_sort_of_no_row_returns_the_projected_schema]()
    suite.test[test_a_pool_too_small_fails_the_query_and_leaves_nothing]()
    suite.test[test_sort_data_the_builder_does_not_hold_is_refused_by_name]()
    suite^.run()
