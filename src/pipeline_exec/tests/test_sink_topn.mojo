# =============================================================================
# SINK_TOPN, driven by hand
# =============================================================================
#
# `SortSink` built from a `TopNSinkData` answers rows [offset, offset + n) of
# the full sort's order, and holds about `offset + n` rows per worker. It is
# handed morsels of the sort table (`sort_harness`) worker by worker, combined
# once and read, and each answer is compared with the oracle's order sliced to
# the range. What these tests prove:
#
#   * One key, ascending and descending, with NULLs first and last, over
#     INT64, STRING and FLOAT64: ranges that start and end inside a group of
#     tied rows and inside the NULL group equal the oracle's slice, tied rows
#     in input order.
#   * Two and three keys with mixed directions and placements equal the
#     oracle's slice.
#   * An empty placement list asks for the default, NULLS LAST in both
#     directions.
#   * 1, 2, 4 and 7 workers, with the morsels dealt forward, in reverse,
#     interleaved and in contiguous blocks, answer exactly the ids of one
#     worker, tied rows included.
#   * A large input (60000 rows in morsels of 250) that makes each worker sort
#     and cut what it holds many times answers the oracle's slice, on one
#     worker and on several, in every dealing, when almost every row ties.
#   * That input's memory stays bounded: while consuming, the pool's grant
#     stays far below the input's buffer bytes; the grant is zero once the
#     output is taken.
#   * A count of zero, or an offset at or past the last row, answers no row
#     under the input's schema (the sink's own, or the first morsel's when it
#     was built with none); a range that ends past the last row is clamped; a
#     count and an offset of Int.MAX do not overflow.
#   * A morsel with a selection mask counts only its selected rows.
#   * An input that has columns named like the sink's hidden position columns
#     keeps them, answers them unchanged, and can be sorted by them.
#   * A negative count, a negative offset, no key, a direction or placement
#     list of the wrong length and a key the input does not have are refused
#     by name when the sink is built; a sink that is handed no row and knows
#     no schema is refused by name at combine; one read before combine is
#     refused.
#   * A morsel the pool denies fails by name. Across a range of pool budgets,
#     a worker's cut and the sink's combine each fail by name where the pool
#     cannot hold the concatenation, and where it cannot hold the sorted copy
#     and key batch, and the pool holds nothing afterwards; a roomy pool
#     answers the oracle's slice.
#   * The pool is charged while rows are held and returns every block when the
#     output is taken and when the sink is dropped with rows in it.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from column_kernels.compiler_helpers import batch_buffer_bytes
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import TopNSinkData
from pipeline_exec.plan_harness import int64_column
from pipeline_exec.segment_pool import POOL_DEFAULT_BLOCK, SegmentPool
from pipeline_exec.sink_sort import SortSink
from pipeline_exec.sort_range import TAG_COLUMNS, compact_at, rows_to_keep
from pipeline_exec.sort_harness import (
    F,
    T,
    X,
    col_name,
    oracle_first,
    oracle_order,
    table,
)

comptime N = 40
comptime BIG = 60000

comptime FORWARD = 0
comptime REVERSE = 1
comptime INTERLEAVED = 2
comptime BLOCKS = 3


def _data(
    cols: List[Int],
    desc: List[Bool],
    nf: List[Bool],
    offset: Int,
    n: Int,
) -> TopNSinkData:
    var names = List[String]()
    for i in range(len(cols)):
        names.append(col_name(cols[i]))
    return TopNSinkData(names^, desc.copy(), n, nf.copy(), offset)


def _keys(a: Int, b: Int = -1, c: Int = -1) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    if b >= 0:
        out.append(b)
    if c >= 0:
        out.append(c)
    return out^


def _flags(a: Bool, b: Bool = False, c: Bool = False, n: Int = 1) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    if n > 1:
        out.append(b)
    if n > 2:
        out.append(c)
    return out^


def _sink(
    ref data: TopNSinkData, pool: SegmentPool, workers: Int
) raises -> SortSink:
    var sink = SortSink(data, pool.share(), 7, table(0, 0).schema.copy())
    sink.resize_worker_state(workers)
    return sink^


def _finish(mut sink: SortSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _expect(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label)
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ", position " + String(i))


def _want(
    rows: Int,
    cols: List[Int],
    desc: List[Bool],
    nf: List[Bool],
    offset: Int,
    n: Int,
) -> List[Int]:
    """Rows [offset, offset + n) of the oracle's order of `rows` rows."""
    var out = List[Int]()
    if offset >= rows or n <= 0:
        return out^
    var count = min(n, rows - offset)
    var first = oracle_first(rows, offset + count, cols, desc, nf)
    for i in range(offset, offset + count):
        out.append(first[i])
    return out^


def _label(
    cols: List[Int],
    desc: List[Bool],
    nf: List[Bool],
    offset: Int,
    n: Int,
    workers: Int,
    mode: Int,
) -> String:
    var label = String("keys")
    for i in range(len(cols)):
        label += " " + col_name(cols[i]) + (" desc" if desc[i] else " asc")
        label += " nulls first" if nf[i] else " nulls last"
    label += ", offset " + String(offset) + ", n " + String(n)
    label += ", workers " + String(workers) + ", dealing " + String(mode)
    return label^


def _dealing(morsels: Int, workers: Int, mode: Int) -> List[Int]:
    """The (morsel, worker) pairs, flattened, in the order they are handed
    over."""
    var ks = List[Int]()
    if mode == FORWARD:
        for k in range(morsels):
            ks.append(k)
    elif mode == REVERSE or mode == BLOCKS:
        for k in range(morsels - 1, -1, -1):
            ks.append(k)
    else:
        for k in range(1, morsels, 2):
            ks.append(k)
        for k in range(morsels - 1, -1, -1):
            if k % 2 == 0:
                ks.append(k)
    var out = List[Int]()
    for i in range(len(ks)):
        var k = ks[i]
        var w = k % workers
        if mode == INTERLEAVED:
            w = (k * 3 + 1) % workers
        elif mode == BLOCKS:
            w = k * workers // morsels
        out.append(k)
        out.append(w)
    return out^


@fieldwise_init
struct _Run(Movable):
    var ids: List[Int]
    """The ids of the answer."""
    var peak: Int
    """The most the pool had granted after any consume."""
    var input_bytes: Int
    """The buffer bytes of every morsel handed over."""


def _run(
    rows: Int,
    morsel_rows: Int,
    workers: Int,
    mode: Int,
    cols: List[Int],
    desc: List[Bool],
    nf: List[Bool],
    offset: Int,
    n: Int,
) raises -> _Run:
    """`rows` rows cut into morsels of `morsel_rows`, the morsel k stamped as
    position (k, k) and dealt as `mode` says, through a top-N sink."""
    var pool = SegmentPool()
    var data = _data(cols, desc, nf, offset, n)
    var sink = _sink(data, pool, workers)
    var morsels = (rows + morsel_rows - 1) // morsel_rows
    var order = _dealing(morsels, workers, mode)
    var peak = 0
    var input_bytes = 0
    for i in range(len(order) // 2):
        var k = order[2 * i]
        var start = k * morsel_rows
        var batch = table(start, min(morsel_rows, rows - start))
        input_bytes += batch_buffer_bytes(batch)
        sink.consume(order[2 * i + 1], Morsel(batch^, k, k))
        peak = max(peak, pool.granted())
    var out = _finish(sink, workers)
    # The pool was repaid by take_output, not by the sink going away.
    assert_equal(pool.granted(), 0)
    var ids = int64_column(out, 0)
    _ = sink^
    return _Run(ids^, peak, input_bytes)


def _check(
    rows: Int,
    morsel_rows: Int,
    workers: Int,
    mode: Int,
    cols: List[Int],
    desc: List[Bool],
    nf: List[Bool],
    offset: Int,
    n: Int,
) raises:
    _expect(
        _run(rows, morsel_rows, workers, mode, cols, desc, nf, offset, n).ids,
        _want(rows, cols, desc, nf, offset, n),
        _label(cols, desc, nf, offset, n, workers, mode),
    )


def _ranges() -> List[Int]:
    """(offset, n) pairs, flattened. The sort table's x has seven NULLs of 40
    and a value held by every fifth row, so these start and end inside tied
    groups and inside the NULL group, whether the NULLs sort first or last."""
    return [0, 1, 0, 5, 2, 3, 4, 6, 9, 13, 17, 9, 30, 6, 33, 7, 0, 40, 12, 28]


def test_one_key_ranges_cut_through_ties_and_nulls() raises:
    var ranges = _ranges()
    for col in [X, T, F]:
        for d in [False, True]:
            for nf in [False, True]:
                for i in range(len(ranges) // 2):
                    _check(
                        N,
                        10,
                        1,
                        FORWARD,
                        _keys(col),
                        _flags(d),
                        _flags(nf),
                        ranges[2 * i],
                        ranges[2 * i + 1],
                    )


def test_two_and_three_keys_mixed_directions_and_placements() raises:
    for a in range(2):
        for b in range(2):
            for c in range(2):
                for d in range(2):
                    _check(
                        N,
                        8,
                        2,
                        REVERSE,
                        _keys(X, T),
                        _flags(a == 1, b == 1, n=2),
                        _flags(c == 1, d == 1, n=2),
                        7,
                        11,
                    )
    _check(
        N, 5, 3, INTERLEAVED, _keys(T, F), _flags(True, False, n=2), _flags(True, False, n=2), 3, 17
    )
    _check(
        N,
        5,
        3,
        FORWARD,
        _keys(T, X, F),
        _flags(True, True, False, n=3),
        _flags(True, False, True, n=3),
        10,
        20,
    )


def test_no_placement_asks_for_the_default_nulls_last() raises:
    for d in [False, True]:
        var pool = SegmentPool()
        var data = _data(_keys(X), _flags(d), List[Bool](), 25, 15)
        var sink = _sink(data, pool, 1)
        sink.consume(0, Morsel(table(0, N), 0, 0))
        var got = int64_column(_finish(sink, 1), 0)
        _expect(
            got,
            _want(N, _keys(X), _flags(d), _flags(False), 25, 15),
            "default",
        )
        assert_true(got[14] % 6 == 1, "a NULL is last in both directions")


def test_every_worker_count_and_dealing_answers_the_ids_of_one_worker() raises:
    var ranges = [0, 17, 6, 9, 13, 8]
    var workers = [1, 2, 4, 7]
    var desc = _flags(False, True, n=2)
    var nf = _flags(True, False, n=2)
    for i in range(len(ranges) // 2):
        var offset = ranges[2 * i]
        var n = ranges[2 * i + 1]
        var one = _run(N, 4, 1, FORWARD, _keys(X, F), desc, nf, offset, n).ids.copy()
        _expect(
            one,
            _want(N, _keys(X, F), desc, nf, offset, n),
            "one worker against the oracle",
        )
        for w in workers:
            for mode in [FORWARD, REVERSE, INTERLEAVED, BLOCKS]:
                _expect(
                    _run(N, 4, w, mode, _keys(X, F), desc, nf, offset, n).ids,
                    one,
                    _label(_keys(X, F), desc, nf, offset, n, w, mode),
                )
    # Every row of one group ties on the key: only the collected order says
    # which of them are kept.
    for w in workers:
        for mode in [FORWARD, REVERSE, INTERLEAVED, BLOCKS]:
            _check(N, 3, w, mode, _keys(X), _flags(False), _flags(False), 5, 6)


def test_a_large_input_that_is_cut_many_times_equals_the_oracle() raises:
    # x has five values and NULLs, so thousands of rows tie with the last row
    # kept: which of them survive every cut is the position order's.
    _check(
        BIG, 250, 1, FORWARD, _keys(X), _flags(False), _flags(False), 100, 50
    )
    _check(
        BIG, 250, 4, REVERSE, _keys(X), _flags(False), _flags(False), 100, 50
    )
    _check(
        BIG, 250, 7, INTERLEAVED, _keys(X), _flags(True), _flags(True), 3, 150
    )
    _check(
        BIG,
        250,
        4,
        BLOCKS,
        _keys(T, F),
        _flags(True, False, n=2),
        _flags(True, False, n=2),
        7,
        20,
    )
    _check(
        BIG, 300, 2, FORWARD, _keys(F), _flags(False), _flags(True), 0, 1
    )
    # A range taller than a worker's cut threshold: nothing is cut away that
    # the answer needs.
    _check(
        6000, 250, 2, REVERSE, _keys(X), _flags(True), _flags(False), 2500, 1200
    )


def test_a_large_input_is_held_in_bounded_memory() raises:
    for workers in [1, 4]:
        var run = _run(
            BIG,
            250,
            workers,
            FORWARD,
            _keys(X),
            _flags(False),
            _flags(False),
            3,
            40,
        )
        _expect(
            run.ids,
            _want(BIG, _keys(X), _flags(False), _flags(False), 3, 40),
            "bounded",
        )
        # A worker holds fewer than compact_at(keep) + 250 rows, each its
        # input bytes plus three INT64 tags; a cut draws at most four times
        # that (the rows, their concatenation, the sorted copy with its key
        # batch, the survivors), and blocks round each worker up by at most
        # two. None of it grows with the input.
        var keep = rows_to_keep(3, 40)
        var row_bytes = run.input_bytes // BIG + 1 + TAG_COLUMNS * 8
        var per_worker = (
            4 * (compact_at(keep) + 250) * row_bytes + 2 * POOL_DEFAULT_BLOCK
        )
        var message = (
            "workers "
            + String(workers)
            + ": granted "
            + String(run.peak)
            + " of an input of "
            + String(run.input_bytes)
            + " bytes"
        )
        assert_true(run.peak <= workers * per_worker, message)
        if workers == 1:
            # One worker's bound is well under the input: the input is not
            # held whole.
            assert_true(run.input_bytes > 2 * per_worker, "the input is large")
            assert_true(run.peak * 2 < run.input_bytes, message)
        assert_true(run.peak > 0, "rows are charged while held")


def test_a_count_of_zero_or_an_offset_past_the_rows_answers_no_row() raises:
    var schema_width = table(0, 0).schema.num_columns()
    var cases = [0, 0, 5, 0, N, 5, N + 10, 5, Int.MAX, 3]
    for i in range(len(cases) // 2):
        var pool = SegmentPool()
        var data = _data(
            _keys(X), _flags(False), _flags(False), cases[2 * i], cases[2 * i + 1]
        )
        var sink = _sink(data, pool, 2)
        sink.consume(1, Morsel(table(0, N // 2), 0, 0))
        sink.consume(0, Morsel(table(N // 2, N // 2), 1, 1))
        var out = _finish(sink, 2)
        assert_equal(out.num_rows(), 0)
        assert_equal(out.num_columns(), schema_width)
        assert_equal(out.schema.field_name(0), "id")
        assert_equal(pool.granted(), 0)
    # No morsel at all.
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False), 0, 3)
    var empty = _sink(data, pool, 2)
    var out = _finish(empty, 2)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), schema_width)


def test_a_range_that_ends_past_the_last_row_is_clamped() raises:
    for d in [False, True]:
        _check(N, 7, 2, REVERSE, _keys(X, F), _flags(d, d, n=2), _flags(d, not d, n=2), 35, 100)
        _check(N, 7, 2, FORWARD, _keys(T), _flags(d), _flags(d), 39, 1)
        _check(N, 7, 2, FORWARD, _keys(T), _flags(d), _flags(d), 39, 2)
        _check(N, 7, 3, FORWARD, _keys(T), _flags(d), _flags(d), 0, N + 1)


def test_the_largest_count_and_offset_do_not_overflow() raises:
    var full = oracle_order(N, _keys(X), _flags(False), _flags(False))
    _expect(
        _run(N, 8, 2, FORWARD, _keys(X), _flags(False), _flags(False), 0, Int.MAX).ids,
        full,
        "n = Int.MAX",
    )
    var after = List[Int]()
    for i in range(3, N):
        after.append(full[i])
    _expect(
        _run(N, 8, 2, REVERSE, _keys(X), _flags(False), _flags(False), 3, Int.MAX).ids,
        after,
        "offset 3, n = Int.MAX",
    )
    _expect(
        _run(N, 8, 2, FORWARD, _keys(X), _flags(False), _flags(False), Int.MAX, 5).ids,
        List[Int](),
        "offset = Int.MAX",
    )
    _expect(
        _run(N, 8, 2, FORWARD, _keys(X), _flags(False), _flags(False), Int.MAX, Int.MAX).ids,
        List[Int](),
        "offset and n = Int.MAX",
    )
    # More rows than a worker's threshold with a range that is the whole of
    # them: no cut is made, nothing is lost.
    var big = _run(
        5000, 500, 2, FORWARD, _keys(X), _flags(False), _flags(False), Int.MAX - 1, 1
    )
    assert_equal(len(big.ids), 0)


def test_a_morsel_with_a_selection_mask_counts_only_its_selected_rows() raises:
    var rows = 60
    var per = 12
    for workers in [1, 3]:
        var pool = SegmentPool()
        var data = _data(_keys(X, F), _flags(False, True, n=2), _flags(True, False, n=2), 4, 14)
        var sink = _sink(data, pool, workers)
        for k in range(rows // per):
            var batch = table(k * per, per)
            var mask = BooleanArray.allocate(per)
            for i in range(per):
                if (k * per + i) % 3 != 0:
                    mask.set(i, True)
            batch.set_selection_mask(mask^)
            sink.consume((rows // per - 1 - k) % workers, Morsel(batch^, k, k))
        var got = int64_column(_finish(sink, workers), 0)
        var selected = List[Int]()
        var order = oracle_order(
            rows, _keys(X, F), _flags(False, True, n=2), _flags(True, False, n=2)
        )
        for i in range(len(order)):
            if order[i] % 3 != 0:
                selected.append(order[i])
        var want = List[Int]()
        for i in range(4, 18):
            want.append(selected[i])
        _expect(got, want, "selected rows, workers " + String(workers))


def _named_batch(start: Int, rows: Int) raises -> RecordBatch:
    """id, k and the three names the sink's hidden columns would take by
    default. Row r: k = (r * 7) % 5, __topn_partition = 1000 + r,
    __topn_hint = 2000 + r, __topn_seq = (r * 3) % 7."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var names = ["id", "k", "__topn_partition", "__topn_hint", "__topn_seq"]
    for c in range(5):
        var values = PrimitiveArray[DType.int64].allocate(rows)
        for i in range(rows):
            var r = start + i
            var v = r
            if c == 1:
                v = (r * 7) % 5
            elif c == 2:
                v = 1000 + r
            elif c == 3:
                v = 2000 + r
            elif c == 4:
                v = (r * 3) % 7
            values.set(i, Int64(v))
        sb.add_field(Field(names[c], ArrowType.INT64, False))
        rb.add_column(Column.from_primitive[DType.int64](values^))
    return rb.build(sb.build())


def test_columns_named_like_the_hidden_ones_are_kept_and_answered() raises:
    var rows = 30
    for key in [1, 4]:
        for d in [False, True]:
            var pool = SegmentPool()
            var key_name = String("k") if key == 1 else String("__topn_seq")
            var data = TopNSinkData(
                [key_name], _flags(d), 9, _flags(False), 5
            )
            var sink = SortSink(
                data, pool.share(), 7, _named_batch(0, 0).schema.copy()
            )
            sink.resize_worker_state(2)
            for k in range(3):
                sink.consume(k % 2, Morsel(_named_batch(k * 10, 10), k, 2 - k))
            var out = _finish(sink, 2)
            # The morsels carry positions 2, 1, 0, so the collected order is
            # the last third first.
            assert_equal(out.num_columns(), 5)
            assert_equal(out.schema.field_name(2), "__topn_partition")
            assert_equal(out.schema.field_name(3), "__topn_hint")
            assert_equal(out.schema.field_name(4), "__topn_seq")
            var ids = int64_column(out, 0)
            var part = int64_column(out, 2)
            var hint = int64_column(out, 3)
            var seq = int64_column(out, 4)
            assert_equal(len(ids), 9)
            for i in range(len(ids)):
                assert_equal(part[i], 1000 + ids[i])
                assert_equal(hint[i], 2000 + ids[i])
                assert_equal(seq[i], (ids[i] * 3) % 7)
            # Ties are in collected order, positions 0, 1, 2 being rows
            # 20 .. 29, 10 .. 19, 0 .. 9.
            var collected = List[Int]()
            for p in range(3):
                for i in range(10):
                    collected.append((2 - p) * 10 + i)
            var order = List[Int]()
            for j in range(rows):
                var r = collected[j]
                var v = (r * 7) % 5 if key == 1 else (r * 3) % 7
                var at = len(order)
                while at > 0:
                    var o = order[at - 1]
                    var ov = (o * 7) % 5 if key == 1 else (o * 3) % 7
                    var after = ov < v if d else ov > v
                    if not after:
                        break
                    at -= 1
                order.insert(at, r)
            var want = List[Int]()
            for i in range(9):
                want.append(order[5 + i])
            _expect(ids, want, "key " + key_name)
            assert_equal(pool.granted(), 0)


def test_a_sink_built_with_no_schema_takes_it_from_its_morsels() raises:
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False), 0, 0)
    var sink = SortSink(data, pool.share(), 7, None)
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(table(0, 10), 0, 0))
    var out = _finish(sink, 1)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 4)
    var none = SortSink(data, pool.share(), 7, None)
    none.resize_worker_state(1)
    var pipeline = PipelineExecution(1, 0)
    with assert_raises(
        contains=(
            "pipeline_exec: the sort sink of segment 7 produced no rows and"
            " its output schema could not be derived"
        )
    ):
        none.combine(pipeline)


def test_a_sink_the_plan_cannot_describe_is_refused_by_name() raises:
    var pool = SegmentPool()
    var schema = table(0, 0).schema.copy()
    with assert_raises(
        contains=(
            "pipeline_exec: the top-n sink of segment 7 keeps -1 rows after"
            " 0; neither may be negative"
        )
    ):
        _ = SortSink(_data(_keys(X), _flags(False), _flags(False), 0, -1), pool.share(), 7, schema.copy())
    with assert_raises(
        contains=(
            "pipeline_exec: the top-n sink of segment 7 keeps 5 rows after"
            " -3; neither may be negative"
        )
    ):
        _ = SortSink(_data(_keys(X), _flags(False), _flags(False), -3, 5), pool.share(), 7, schema.copy())
    with assert_raises(contains="segment 7 has no sort key"):
        _ = SortSink(_data(List[Int](), List[Bool](), List[Bool](), 0, 5), pool.share(), 7, schema.copy())
    with assert_raises(contains="lists 2 directions for 1 sort keys"):
        _ = SortSink(_data(_keys(X), _flags(False, True, n=2), List[Bool](), 0, 5), pool.share(), 7, schema.copy())
    with assert_raises(contains="lists 2 NULL placements for 1 sort keys"):
        _ = SortSink(_data(_keys(X), _flags(False), _flags(False, True, n=2), 0, 5), pool.share(), 7, schema.copy())
    with assert_raises(contains="sorts by 'nope', which is not a column"):
        _ = SortSink(TopNSinkData(["nope"], _flags(False), 5), pool.share(), 7, schema.copy())
    var data = _data(_keys(X), _flags(False), _flags(False), 0, 5)
    var sink = _sink(data, pool, 1)
    with assert_raises(contains="read before it was combined"):
        _ = sink.take_output()
    with assert_raises(contains="holds 1 worker slots, got worker 3"):
        sink.consume(3, Morsel(table(0, 2), 0, 0))


def test_a_morsel_the_pool_denies_fails_by_name_and_leaves_nothing() raises:
    var pool = SegmentPool(100)
    var data = _data(_keys(X), _flags(False), _flags(False), 2, 5)
    var sink = _sink(data, pool, 1)
    with assert_raises(
        contains="pipeline_exec: the sort sink of segment 7 was denied"
    ):
        sink.consume(0, Morsel(table(0, N), 0, 0))
    _ = sink^
    assert_equal(pool.granted(), 0)


def _attempt(
    pool: SegmentPool, morsels: Int, per: Int, offset: Int, n: Int
) raises -> String:
    """Hand `morsels` morsels of `per` rows to one worker of a top-N sink
    drawing on `pool`, combine and take the output; the message of the first
    failure, or an empty string. The sink is gone when this returns."""
    var data = _data(_keys(X, F), _flags(False, True, n=2), _flags(True, False, n=2), offset, n)
    var sink = _sink(data, pool, 1)
    for k in range(morsels):
        try:
            sink.consume(0, Morsel(table(k * per, per), k, k))
        except e:
            return String(e)
    try:
        var out = _finish(sink, 1)
        _expect(
            int64_column(out, 0),
            _want(
                morsels * per,
                _keys(X, F),
                _flags(False, True, n=2),
                _flags(True, False, n=2),
                offset,
                n,
            ),
            "the answer of a pool that was roomy enough",
        )
    except e:
        return String(e)
    return String("")


def _sweep(
    morsels: Int, per: Int, offset: Int, n: Int, mut messages: List[String]
) raises:
    var budget = 8 * 1024
    while budget <= 4 * 1024 * 1024:
        var pool = SegmentPool(budget)
        var message = _attempt(pool, morsels, per, offset, n)
        assert_equal(pool.granted(), 0, "budget " + String(budget))
        if message != "":
            assert_true(
                "was denied" in message,
                "budget " + String(budget) + ": " + message,
            )
        var roomy = message == ""
        messages.append(message^)
        if roomy:
            # A larger budget is as roomy: the sweep ends at the first one
            # the whole run fits in.
            return
        budget += 8 * 1024


def _seen(messages: List[String], text: String) -> Bool:
    for i in range(len(messages)):
        if text in messages[i]:
            return True
    return False


def test_a_cut_the_pool_denies_fails_by_name_and_leaves_nothing() raises:
    # 3000 rows reach a worker's threshold of 2048 at the third morsel.
    var messages = List[String]()
    _sweep(3, 1000, 5, 10, messages)
    assert_true(
        _seen(messages, "for the concatenation of what a worker holds"),
        "a cut denied its concatenation",
    )
    assert_true(
        _seen(messages, "for the sorted copy and the key batch of a worker"),
        "a cut denied its sorted copy",
    )
    assert_equal(messages[len(messages) - 1], "")


def test_a_combine_the_pool_denies_fails_by_name_and_leaves_nothing() raises:
    # 1500 rows are below a worker's threshold: the rows are cut only at
    # combine.
    var messages = List[String]()
    _sweep(3, 500, 5, 10, messages)
    assert_true(
        _seen(messages, "for a morsel it keeps"), "a consume denied"
    )
    assert_true(
        _seen(messages, "for the concatenation (segment pool budget"),
        "a combine denied its concatenation",
    )
    assert_true(
        _seen(messages, "for the sorted copy and the key batch (segment pool"),
        "a combine denied its sorted copy",
    )
    assert_equal(messages[len(messages) - 1], "")


def test_the_pool_is_charged_while_rows_are_held_and_repaid() raises:
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False), 1, 4)
    var sink = _sink(data, pool, 2)
    assert_equal(pool.granted(), 0)
    sink.consume(0, Morsel(table(0, N // 2), 0, 0))
    sink.consume(1, Morsel(table(N // 2, N // 2), 1, 1))
    assert_true(pool.granted() > 0, "held rows are charged")
    var pipeline = PipelineExecution(2, 0)
    sink.combine(pipeline)
    sink.finalize()
    # The answer, four rows, is what is held until it is taken.
    assert_true(pool.granted() > 0, "the answer is charged")
    _ = sink.take_output()
    assert_equal(pool.granted(), 0)
    _ = sink^


def test_a_sink_dropped_with_rows_in_it_repays_the_pool() raises:
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False), 1, 4)
    var sink = _sink(data, pool, 2)
    sink.consume(0, Morsel(table(0, N // 2), 0, 0))
    sink.consume(1, Morsel(table(N // 2, N // 2), 1, 1))
    assert_true(pool.granted() > 0)
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_one_key_ranges_cut_through_ties_and_nulls]()
    suite.test[test_two_and_three_keys_mixed_directions_and_placements]()
    suite.test[test_no_placement_asks_for_the_default_nulls_last]()
    suite.test[test_every_worker_count_and_dealing_answers_the_ids_of_one_worker]()
    suite.test[test_a_large_input_that_is_cut_many_times_equals_the_oracle]()
    suite.test[test_a_large_input_is_held_in_bounded_memory]()
    suite.test[test_a_count_of_zero_or_an_offset_past_the_rows_answers_no_row]()
    suite.test[test_a_range_that_ends_past_the_last_row_is_clamped]()
    suite.test[test_the_largest_count_and_offset_do_not_overflow]()
    suite.test[test_a_morsel_with_a_selection_mask_counts_only_its_selected_rows]()
    suite.test[test_columns_named_like_the_hidden_ones_are_kept_and_answered]()
    suite.test[test_a_sink_built_with_no_schema_takes_it_from_its_morsels]()
    suite.test[test_a_sink_the_plan_cannot_describe_is_refused_by_name]()
    suite.test[test_a_morsel_the_pool_denies_fails_by_name_and_leaves_nothing]()
    suite.test[test_a_cut_the_pool_denies_fails_by_name_and_leaves_nothing]()
    suite.test[test_a_combine_the_pool_denies_fails_by_name_and_leaves_nothing]()
    suite.test[test_the_pool_is_charged_while_rows_are_held_and_repaid]()
    suite.test[test_a_sink_dropped_with_rows_in_it_repays_the_pool]()
    suite^.run()
