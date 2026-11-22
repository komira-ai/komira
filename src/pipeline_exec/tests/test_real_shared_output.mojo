# =============================================================================
# One segment's output read by several segments: a shared subplan
# =============================================================================
#
# Lowering cuts a shared subplan once and makes every reference read that
# segment's output, so one producer can have several readers: two
# SOURCE_SINK_OUTPUT segments, or a SOURCE_CONCAT that names it twice.
# Hand-built plans run through `run_plan` and `RealBuilder` on a dispatcher
# that runs the workers one after another, over resident batches of the sample
# table (`plan_harness.sample_batch`: a = r, b = r * 10 with NULL where
# r % 5 == 2, s = "s" + r % 4). What these tests prove:
#
#   * Two segments that read one producer each get all of its rows, and the
#     operators each runs see them; no output of the producer is left after.
#   * A concatenation that names one producer twice has its rows twice.
#   * A producer read by two segments, one of them a concatenation that also
#     names a second producer, gives each reader its rows.
#   * `PublishedOutputs` built from a plan gives every reader but the last a
#     copy and keeps the batch, and the last reader takes it; a take after
#     that is refused. Built from a segment count, the first take moves the
#     batch out. A spec naming a segment outside the plan counts no reader.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.schema import RecordBatch
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
    SOURCE_SINK_OUTPUT,
    SourceSpecPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    batch_segment,
    chain,
    int64_column,
    sample_batch,
)
from pipeline_exec.published_outputs import PublishedOutputs
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr import BIN_GT, BIN_LT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(
        op, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v))
    )


def _e3(var deps: List[Int]) -> List[UInt8]:
    var tags = List[UInt8]()
    for _ in range(len(deps)):
        tags.append(EDGE_E3_PUBLISH_WAIT)
    return tags^


def _one(a: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    return out^


def _two(a: Int, b: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    return out^


def _read_segment(
    seg_id: Int, producer: Int, var ops: Slab[MorselOp] = Slab[MorselOp]()
) -> SegmentDescPod:
    """A segment that reads the output of `producer` and collects."""
    return SegmentDescPod(
        seg_id, SOURCE_SINK_OUTPUT, SourceSpecPod.from_sink_output(producer),
        ops^, SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, seg_id,
        _one(producer), _e3(_one(producer)),
    )


def _concat_segment(seg_id: Int, var producers: List[Int]) -> SegmentDescPod:
    """A segment that concatenates `producers` in that order, with one E3
    edge per entry, and collects."""
    var deps = producers.copy()
    var tags = _e3(producers.copy())
    return SegmentDescPod(
        seg_id, SOURCE_CONCAT, SourceSpecPod.concat(producers^),
        Slab[MorselOp](), SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR,
        -1, seg_id, deps^, tags^,
    )


def _run(
    var descs: List[SegmentDescPod], var first: RecordBatch, var second: RecordBatch
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
    var out = run_plan(descs, builder, dispatch, 1, CancellationToken.new())
    for i in range(last):
        assert_false(out.has(i), "the output of segment " + String(i) + " is left")
    return out.take(last)


def _range(start: Int, stop: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(start, stop):
        out.append(r)
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


# =============================================================================
# Plans whose producer has several readers
# =============================================================================


def test_two_segments_that_read_one_producer_each_get_all_its_rows() raises:
    # 0: rows 0..5. 1: a < 2 over them. 2: a > 3 over them. 3: 1 then 2.
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(_read_segment(1, 0, chain(MorselOp.filter(_cmp(BIN_LT, "a", 2)))))
    descs.append(_read_segment(2, 0, chain(MorselOp.filter(_cmp(BIN_GT, "a", 3)))))
    descs.append(_concat_segment(3, _two(1, 2)))
    var batch = _run(descs^, sample_batch(0, 6), sample_batch(100, 1))
    var want = List[Int]()
    want.append(0)
    want.append(1)
    want.append(4)
    want.append(5)
    _expect(int64_column(batch, 0), want)


def test_a_concatenation_that_names_one_producer_twice_has_its_rows_twice() raises:
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(_concat_segment(1, _two(0, 0)))
    var batch = _run(descs^, sample_batch(0, 4), sample_batch(100, 1))
    var want = _range(0, 4)
    want.extend(_range(0, 4))
    _expect(int64_column(batch, 0), want)
    # Column b keeps its NULL at row 2 in both copies.
    assert_true(batch.column_at(1).is_null_at(2))
    assert_true(batch.column_at(1).is_null_at(6))
    assert_false(batch.column_at(1).is_null_at(3))


def test_a_producer_read_by_a_segment_and_a_concatenation_feeds_both() raises:
    # 0: rows 0..2. 1: rows 10..11. 2: a > 0 over 0. 3: 0 then 1.
    # 4: 2 then 3.
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(batch_segment(1, 1))
    descs.append(_read_segment(2, 0, chain(MorselOp.filter(_cmp(BIN_GT, "a", 0)))))
    descs.append(_concat_segment(3, _two(0, 1)))
    descs.append(_concat_segment(4, _two(2, 3)))
    var batch = _run(descs^, sample_batch(0, 3), sample_batch(10, 2))
    var want = _range(1, 3)
    want.extend(_range(0, 3))
    want.extend(_range(10, 12))
    _expect(int64_column(batch, 0), want)


# =============================================================================
# PublishedOutputs
# =============================================================================


def _shared_plan() -> List[SegmentDescPod]:
    """Segment 0 read by segments 1 and 2; nothing reads 1 or 2."""
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(_read_segment(1, 0))
    descs.append(_read_segment(2, 0))
    return descs^


def test_every_reader_but_the_last_gets_a_copy_and_the_last_takes_it() raises:
    var descs = _shared_plan()
    var published = PublishedOutputs(descs)
    published.publish(0, sample_batch(0, 3))
    var first = published.take(0)
    assert_true(published.has(0), "the batch left with the first of two readers")
    var second = published.take(0)
    assert_false(published.has(0), "the last reader left the batch behind")
    _expect(int64_column(first, 0), _range(0, 3))
    _expect(int64_column(second, 0), _range(0, 3))
    with assert_raises(contains="no output of segment 0 is available"):
        _ = published.take(0)


def test_an_output_nothing_reads_stays_until_taken() raises:
    var descs = _shared_plan()
    var published = PublishedOutputs(descs)
    published.publish(1, sample_batch(5, 2))
    assert_true(published.has(1))
    var out = published.take(1)
    assert_false(published.has(1))
    _expect(int64_column(out, 0), _range(5, 7))


def test_outputs_built_from_a_count_move_the_batch_on_the_first_take() raises:
    var published = PublishedOutputs(2)
    assert_equal(published.num_segments(), 2)
    published.publish(0, sample_batch(0, 2))
    var out = published.take(0)
    assert_false(published.has(0))
    _expect(int64_column(out, 0), _range(0, 2))


def test_a_spec_naming_a_segment_outside_the_plan_counts_no_reader() raises:
    # Two specs name -1 and one names 7: were any of them counted, the last
    # segment (or one past it) would count readers and keep its batch after
    # its first take.
    var descs = List[SegmentDescPod]()
    descs.append(batch_segment(0, 0))
    descs.append(_read_segment(1, -1))
    descs.append(_read_segment(2, -1))
    descs.append(_read_segment(3, 7))
    var published = PublishedOutputs(descs)
    assert_equal(published.num_segments(), 4)
    for seg in range(4):
        published.publish(seg, sample_batch(seg, 2))
        _ = published.take(seg)
        assert_false(
            published.has(seg),
            "segment " + String(seg) + " counted a reader it does not have",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
