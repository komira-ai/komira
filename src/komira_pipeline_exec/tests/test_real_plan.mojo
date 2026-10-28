# =============================================================================
# Hand-built plans over the real members, end to end
# =============================================================================
#
# Plans written as segment descriptors (`plan_harness`) run through `run_plan`
# and `RealBuilder` on a dispatcher that runs the workers one after another.
# The Parquet files are written by `komira_parquet_writer` from the sample table
# (a = r, b = r * 10 with NULL where r % 5 == 2, s = "s" + r % 4). What these
# tests prove:
#
#   * A scan with a pushed filter, then a filter, a projection that reorders and
#     drops columns, and a limit, returns the rows a row-at-a-time evaluation of
#     the same plan gives, in file order, with the projected columns.
#   * A limit across morsel boundaries returns exactly its row count: with one
#     worker the first rows, with several workers rows that are distinct and
#     satisfy the plan; limit 0 returns no row and the full output schema.
#   * A plan whose filter rejects every row, over a resident batch and over a
#     Parquet file, returns no rows and the schema the projection gives.
#   * A segment that reads the output of another (SOURCE_SINK_OUTPUT) sees what
#     the producer collected, a third segment sees the second's, and a published
#     output nobody reads is returned.
#   * Sources, operators and sinks the builder does not serve are refused by
#     name, a resident batch the builder does not hold is refused, and a
#     predicate the evaluator cannot scope fails the query with the refusal.

from std.memory import Pointer
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.schema import RecordBatch
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_NONE,
    MorselOp,
    ORDER_NONE,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SINK_SORT,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_SINK_OUTPUT,
    SourceSpecPod,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.plan_harness import (
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
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_GE,
    BIN_GT,
    BIN_LT,
    Expr,
    MATH_SQRT,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), _lit(v))


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def _write(name: String, rows: Int, rows_per_group: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        sample_batch(0, rows), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _seq(n: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(n):
        out.append(r)
    return out^


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _scan_plan(path: String, morsel_rows: Int) -> SegmentDescPod:
    """Scan with a pushed a >= 60; filter b > 500 (a > 50, and a NULL b is
    dropped); project (s, a), dropping b; limit ten rows."""
    var ops = chain(
        MorselOp.filter(_cmp(BIN_GT, "b", 500)),
        project_columns(_names("s", "a")),
        MorselOp.limit(10),
    )
    return parquet_segment(
        0, path, None, Optional(_cmp(BIN_GE, "a", 60)), ops^, morsel_rows
    )


def test_scan_filter_project_limit_end_to_end() raises:
    var path = _write("e2e", 100, 25)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var dispatch = InlineDispatch()
    # One worker and a row group a morsel: the rows are the first ten in file
    # order that satisfy the whole plan.
    var out = run_plan(
        _one(_scan_plan(path, 0)), builder, dispatch, 1, CancellationToken.new()
    )
    var batch = out.take(0)
    var want = List[Int]()
    for r in range(100):
        if r >= 60 and not b_is_null(r) and r * 10 > 500 and len(want) < 10:
            want.append(r)
    assert_equal(len(want), 10)
    var names = column_names(batch)
    assert_equal(len(names), 2)
    assert_equal(names[0], "s")
    assert_equal(names[1], "a")
    _expect(int64_column(batch, 1), want)
    var s = string_column(batch, 0)
    for i in range(len(want)):
        assert_equal(s[i], "s" + String(want[i] % 4))


def test_the_same_plan_on_three_workers_and_cut_morsels() raises:
    var path = _write("e2e_workers", 100, 25)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        _one(_scan_plan(path, 16)), builder, dispatch, 3, CancellationToken.new()
    )
    var batch = out.take(0)
    # Which ten rows depends on the order the workers claimed; each satisfies
    # the plan and none is repeated.
    var got = int64_column(batch, 1)
    var s = string_column(batch, 0)
    assert_equal(len(got), 10)
    var seen = List[Bool](length=100, fill=False)
    for i in range(len(got)):
        var r = got[i]
        assert_true(r >= 60 and r * 10 > 500 and not b_is_null(r), "row " + String(r))
        assert_false(seen[r], "row " + String(r) + " twice")
        seen[r] = True
        assert_equal(s[i], "s" + String(r % 4))


def test_a_limit_across_morsel_boundaries_returns_its_row_count() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 95))
    # With one worker the rows are the first 25 in claim order; the morsels
    # hold 10 rows, so the limit cuts the third.
    var one = _one(batch_segment(0, handle, chain(MorselOp.limit(25)), 10))
    var dispatch = InlineDispatch()
    var out = run_plan(one, builder, dispatch, 1, CancellationToken.new())
    var first = int64_column(out.take(0), 0)
    _expect(first, _seq(25))

    # With four workers the rows are distinct and the count is the limit.
    var four = _one(batch_segment(0, handle, chain(MorselOp.limit(25)), 10))
    var out4 = run_plan(four, builder, dispatch, 4, CancellationToken.new())
    var got = int64_column(out4.take(0), 0)
    assert_equal(len(got), 25)
    var seen = List[Bool](length=95, fill=False)
    for i in range(len(got)):
        assert_true(got[i] >= 0 and got[i] < 95)
        assert_false(seen[got[i]], "row " + String(got[i]) + " twice")
        seen[got[i]] = True


def test_limit_zero_returns_no_row_and_the_full_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 40))
    var descs = _one(batch_segment(0, handle, chain(MorselOp.limit(0)), 8))
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 3, CancellationToken.new())
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 3)
    assert_equal(names[2], "s")


def test_a_filter_that_rejects_every_row_leaves_the_projected_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 40))
    var ops = chain(
        MorselOp.filter(_cmp(BIN_GT, "a", 1000)),
        project_columns(_names("s", "a")),
    )
    var descs = _one(batch_segment(0, handle, ops^, 8))
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 2)
    assert_equal(names[0], "s")
    assert_equal(names[1], "a")


def test_a_scan_whose_filter_rejects_every_row_returns_the_schema() raises:
    var path = _write("rejects_all", 60, 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var descs = _one(
        parquet_segment(
            0,
            path^,
            Optional(_names("a", "s")),
            Optional(_cmp(BIN_GT, "a", 1000)),
        )
    )
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 2)
    assert_equal(names[0], "a")
    assert_equal(names[1], "s")


def test_a_segment_reads_the_output_of_another() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 50))
    var descs = List[SegmentDescPod]()
    # 0: the rows with a >= 10, as the batch source gives them.
    descs.append(batch_segment(0, handle, chain(MorselOp.filter(_cmp(BIN_GE, "a", 10))), 7))
    # 1: reads 0, keeps a < 30, projects (a, s).
    descs.append(
        output_segment(
            1,
            0,
            chain(
                MorselOp.filter(_cmp(BIN_LT, "a", 30)),
                project_columns(_names("a", "s")),
            ),
            6,
        )
    )
    # 2: reads 1 and keeps the first five rows.
    descs.append(output_segment(2, 1, chain(MorselOp.limit(5)), 4))
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 1, CancellationToken.new())
    assert_false(out.has(0))
    assert_false(out.has(1))
    var batch = out.take(2)
    assert_equal(batch.num_columns(), 2)
    _expect(int64_column(batch, 0), [10, 11, 12, 13, 14])
    var s = string_column(batch, 1)
    assert_equal(s[0], "s2")
    assert_equal(s[4], "s2")


def test_an_output_nobody_reads_is_returned() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 12))
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, handle))
    descs.append(output_segment(1, 0, chain(MorselOp.limit(3))))
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
    assert_false(out.has(0))
    assert_equal(out.take(1).num_rows(), 3)


# ---- what the builder does not serve ----------------------------------------


def test_what_the_builder_does_not_serve_is_refused_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 12))
    var dispatch = InlineDispatch()

    var concat = SegmentDescPod(
        0, SOURCE_CONCAT, SourceSpecPod(), Slab[MorselOp](), SINK_COLLECT, KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR, -1, 0, List[Int](), List[UInt8](),
    )
    with assert_raises(contains="source kind 3 of segment 0 is not served"):
        _ = run_plan(_one(concat^), builder, dispatch, 1, CancellationToken.new())

    var probe = batch_segment(
        0, handle, chain(MorselOp.join_probe(1, _names("a"), _names("a"), 0))
    )
    with assert_raises(contains="operator tag 3 of segment 0 is not served"):
        _ = run_plan(_one(probe^), builder, dispatch, 1, CancellationToken.new())

    var sorted = SegmentDescPod(
        0, SOURCE_BATCH, SourceSpecPod.batch(handle), Slab[MorselOp](), SINK_SORT,
        KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, 0, List[Int](), List[UInt8](),
    )
    with assert_raises(contains="the sink of segment 0 is not served"):
        _ = run_plan(_one(sorted^), builder, dispatch, 1, CancellationToken.new())

    with assert_raises(contains="reads resident batch 5, and the builder holds 1"):
        _ = run_plan(
            _one(batch_segment(0, 5)), builder, dispatch, 1, CancellationToken.new()
        )


def test_a_sink_output_source_must_read_a_dependency() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 12))
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, handle))
    # Segment 1 depends on 0 but names segment 2 as its source.
    var deps = List[Int]()
    deps.append(0)
    var tags = List[UInt8]()
    tags.append(EDGE_E3_PUBLISH_WAIT)
    descs.append(
        SegmentDescPod(
            1, SOURCE_SINK_OUTPUT, SourceSpecPod.from_sink_output(2),
            Slab[MorselOp](), SINK_COLLECT,
            KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, 1, deps^, tags^,
        )
    )
    var dispatch = InlineDispatch()
    with assert_raises(contains="which is not among its dependencies"):
        _ = run_plan(descs, builder, dispatch, 1, CancellationToken.new())


def test_a_predicate_without_a_null_scope_fails_the_query() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        Pointer(to=cache), Pointer(to=pool)
    )
    var handle = builder.add_resident(sample_batch(0, 12))
    var pred = Expr.binary(BIN_GT, Expr.math_fn(MATH_SQRT, Expr.col_ref("a")), _lit(1))
    var descs = _one(batch_segment(0, handle, chain(MorselOp.filter(pred^))))
    var dispatch = InlineDispatch()
    with assert_raises(contains="OP_FILTER refuses its predicate"):
        _ = run_plan(descs, builder, dispatch, 2, CancellationToken.new())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
