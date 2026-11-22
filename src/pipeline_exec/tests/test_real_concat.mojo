# =============================================================================
# SOURCE_CONCAT over the real members: a UNION ALL's concatenation
# =============================================================================
#
# Hand-built plans whose last segment reads the outputs of several producer
# segments (`SourceSpecPod.concat`) run through `run_plan` and `RealBuilder`
# on a dispatcher that runs the workers one after another. The producers read
# resident batches of the sample table (`plan_harness.sample_batch`: a = r,
# b = r * 10 with NULL where r % 5 == 2, s = "s" + r % 4). What these tests
# prove:
#
#   * The concatenation is the producers' rows in the spec's order (branch 1
#     first), whatever the segment ids, also cut into small morsels shared by
#     several workers; each producer's output is taken, so only the
#     concatenation's output is returned.
#   * A producer with no rows adds none, and producers that all have no rows
#     give no rows with the producers' schema.
#   * Operators on the concatenating segment run over the concatenated rows,
#     NULLs included.
#   * A column is nullable in the concatenation when it is nullable in any
#     producer, not only when the first producer says so.
#   * A producer that is not among the segment's dependencies is refused by
#     name before any producer's output is taken.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column_builder import ColumnBuilder
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from async_api.token import CancellationToken
from containers.slab import Slab
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_NONE,
    MorselOp,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_CONCAT,
    SourceSpecPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    b_is_null,
    batch_segment,
    chain,
    column_names,
    int64_column,
    null_column,
    sample_batch,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr import BIN_GT, BIN_LT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), _lit(v))


def _ids(a: Int, b: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    return out^


def _concat_segment(
    seg_id: Int,
    var producers: List[Int],
    var deps: List[Int],
    var ops: Slab[MorselOp] = Slab[MorselOp](),
    morsel_rows: Int = 0,
) -> SegmentDescPod:
    """A segment that concatenates the outputs of `producers` (in that order),
    waits for each of `deps` over an E3 edge, and collects."""
    var tags = List[UInt8]()
    for _ in range(len(deps)):
        tags.append(EDGE_E3_PUBLISH_WAIT)
    var desc = SegmentDescPod(
        seg_id, SOURCE_CONCAT, SourceSpecPod.concat(producers^), ops^,
        SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, seg_id,
        deps^, tags^,
    )
    desc.morsel_rows = morsel_rows
    return desc^


def _run(
    var descs: List[SegmentDescPod],
    var first: RecordBatch,
    var second: RecordBatch,
    num_workers: Int,
) raises -> RecordBatch:
    """Run `descs` with `first` and `second` resident (handles 0 and 1) and
    return the output of the last segment, after checking it is the only
    output left."""
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    _ = builder.add_resident(first^)
    _ = builder.add_resident(second^)
    var last = len(descs) - 1
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, num_workers, CancellationToken.new())
    for i in range(last):
        assert_false(out.has(i), "the output of producer " + String(i) + " is left")
    return out.take(last)


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def _range(start: Int, stop: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(start, stop):
        out.append(r)
    return out^


def test_the_concatenation_is_the_producers_rows_in_order() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(batch_segment(1, 1))
    descs.append(_concat_segment(2, _ids(0, 1), _ids(0, 1)))
    var batch = _run(descs^, sample_batch(0, 5), sample_batch(100, 3), 1)
    var names = column_names(batch)
    assert_equal(len(names), 3)
    assert_equal(names[0], "a")
    assert_equal(names[1], "b")
    assert_equal(names[2], "s")
    var want = _range(0, 5)
    want.extend(_range(100, 103))
    _expect(int64_column(batch, 0), want)
    var nulls = null_column(batch, 1)
    for i in range(len(want)):
        assert_equal(nulls[i], b_is_null(want[i]), "row " + String(i))
    var s = string_column(batch, 2)
    assert_equal(s[0], "s0")
    assert_equal(s[5], "s0")
    assert_equal(s[7], "s2")


def test_the_spec_order_decides_not_the_segment_ids() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(batch_segment(1, 1))
    descs.append(_concat_segment(2, _ids(1, 0), _ids(0, 1)))
    var batch = _run(descs^, sample_batch(0, 4), sample_batch(50, 2), 1)
    var want = _range(50, 52)
    want.extend(_range(0, 4))
    _expect(int64_column(batch, 0), want)


def test_small_morsels_on_several_workers_keep_the_order() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0, morsel_rows=3))
    descs.append(batch_segment(1, 1, morsel_rows=3))
    descs.append(_concat_segment(2, _ids(0, 1), _ids(0, 1), morsel_rows=2))
    var batch = _run(descs^, sample_batch(0, 11), sample_batch(200, 7), 3)
    var want = _range(0, 11)
    want.extend(_range(200, 207))
    _expect(int64_column(batch, 0), want)


def test_a_producer_without_rows_adds_none() raises:
    var descs = List[SegmentDescPod]()
    # Producer 0 keeps no row (a < 0).
    descs.append(batch_segment(0, 0, chain(MorselOp.filter(_cmp(BIN_LT, "a", 0)))))
    descs.append(batch_segment(1, 1))
    descs.append(_concat_segment(2, _ids(0, 1), _ids(0, 1)))
    var batch = _run(descs^, sample_batch(0, 6), sample_batch(30, 4), 1)
    _expect(int64_column(batch, 0), _range(30, 34))
    assert_equal(batch.num_columns(), 3)


def test_producers_that_all_have_no_rows_give_no_rows_and_the_schema() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0, chain(MorselOp.filter(_cmp(BIN_LT, "a", 0)))))
    descs.append(batch_segment(1, 1, chain(MorselOp.filter(_cmp(BIN_LT, "a", 0)))))
    descs.append(_concat_segment(2, _ids(0, 1), _ids(0, 1)))
    var batch = _run(descs^, sample_batch(0, 6), sample_batch(30, 4), 1)
    assert_equal(batch.num_rows(), 0)
    var names = column_names(batch)
    assert_equal(len(names), 3)
    assert_equal(names[0], "a")
    assert_equal(names[2], "s")


def test_operators_on_the_concatenation_see_every_producer_row() raises:
    # b > 30 over rows 0..5 (b = 40, 50; row 2 is NULL) and 10..13 (b = 100,
    # 110, 130; row 12 is NULL), then the first four rows.
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(batch_segment(1, 1))
    descs.append(
        _concat_segment(
            2,
            _ids(0, 1),
            _ids(0, 1),
            chain(MorselOp.filter(_cmp(BIN_GT, "b", 30)), MorselOp.limit(4)),
        )
    )
    var batch = _run(descs^, sample_batch(0, 6), sample_batch(10, 4), 1)
    var want = List[Int]()
    want.append(4)
    want.append(5)
    want.append(10)
    want.append(11)
    _expect(int64_column(batch, 0), want)


def _v_batch(nullable: Bool, with_null: Bool) raises -> RecordBatch:
    """One INT64 column `v` of two rows (7, then NULL or 8), declared
    `nullable`."""
    var v = ColumnBuilder[DType.int64].with_capacity(2)
    v.append(Int64(7))
    if with_null:
        v.append_null()
    else:
        v.append(Int64(8))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("v", ArrowType.INT64, nullable))
    rb.add_column(v^.materialize())
    return rb.build(sb.build())


def test_a_column_nullable_in_a_later_producer_is_nullable() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(batch_segment(1, 1))
    descs.append(_concat_segment(2, _ids(0, 1), _ids(0, 1)))
    var batch = _run(descs^, _v_batch(False, False), _v_batch(True, True), 1)
    assert_equal(batch.num_rows(), 4)
    assert_true(batch.schema.field_nullable(0), "v is not declared nullable")
    assert_true(batch.column_at(0).is_null_at(3))
    assert_false(batch.column_at(0).is_null_at(0))


def test_a_producer_that_is_not_a_dependency_is_refused() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(batch_segment(1, 1))
    # Reads 0 and 1 but waits only for 0.
    var deps = List[Int]()
    deps.append(0)
    descs.append(_concat_segment(2, _ids(0, 1), deps^))
    with assert_raises(
        contains="segment 2 reads the output of segment 1, which is not among"
        " its dependencies"
    ):
        _ = _run(descs^, sample_batch(0, 3), sample_batch(10, 3), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
