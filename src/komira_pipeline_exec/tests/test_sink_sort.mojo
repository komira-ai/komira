# =============================================================================
# SINK_SORT, driven by hand
# =============================================================================
#
# `SortSink` is handed morsels of the sort table (`sort_harness`: ties and NULLs
# in an INT64, a STRING and a FLOAT64 column, and a row id that says in what
# order tied rows came out) worker by worker, combined once, and read. Each
# result is compared with an insertion-sort oracle that applies the plan's
# placement key by key. What these tests prove:
#
#   * One key, ascending and descending, with NULLs first and last: INT64,
#     STRING and FLOAT64 each, all eight orders equal the oracle, tied rows in
#     input order (stable).
#   * Two keys with mixed directions and mixed placements equal the oracle; a
#     NULL in the first key never decides the second key's order.
#   * An empty placement list asks for the default, NULLS LAST in both
#     directions; a key named twice is read once; a key that is all NULL
#     leaves the next key to decide.
#   * Four workers each holding a morsel, delivered in reverse worker order,
#     merge into the order of one worker holding every row.
#   * No row gives no row under the input's schema; one row gives itself.
#   * A sink with no key, a direction or placement list of the wrong length,
#     or a key the input does not have is refused by name when built; one read
#     before combine is refused.
#   * A morsel the pool denies, a concatenation the pool denies, a sorted copy
#     and key batch the pool denies, the consume that takes the input past the
#     sort's own memory budget, and a budget that holds the input and its
#     concatenation but not the peak, fail by name, and the pool holds nothing
#     afterwards; a budget of many inputs sorts the same rows.
#   * The pool is charged while rows are held, holds only the sorted copy once
#     the sort is done, and returns every block when the output is taken, when
#     a combine fails and when the sink is dropped with morsels in it.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.schema import RecordBatch
from komira_column_kernels.compiler_helpers import batch_buffer_bytes
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import SortSinkData
from komira_pipeline_exec.plan_harness import int64_column
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_sort import SortSink
from komira_pipeline_exec.sort_harness import (
    F,
    T,
    X,
    col_name,
    oracle_order,
    table,
)

comptime N = 40


def _data(
    cols: List[Int],
    desc: List[Bool],
    nf: List[Bool],
    budget: Int = 0,
) -> SortSinkData:
    var names = List[String]()
    for i in range(len(cols)):
        names.append(col_name(cols[i]))
    return SortSinkData(names^, desc.copy(), budget, nf.copy())


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
    ref data: SortSinkData, pool: SegmentPool, workers: Int
) raises -> SortSink:
    var sink = SortSink(data, pool.share(), 7, table(0, 0).schema.copy())
    sink.resize_worker_state(workers)
    return sink^


def _finish(mut sink: SortSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _sorted_ids(
    cols: List[Int], desc: List[Bool], nf: List[Bool], workers: Int = 1
) raises -> List[Int]:
    """The ids the sink returns for rows 0 .. N-1 cut into `workers` morsels
    handed to the workers in reverse order."""
    var pool = SegmentPool()
    var data = _data(cols, desc, nf)
    var sink = _sink(data, pool, workers)
    var per = N // workers
    for k in range(workers):
        var w = workers - 1 - k
        sink.consume(w, Morsel(table(w * per, per), w, w))
    var out = _finish(sink, workers)
    assert_equal(pool.granted(), 0)
    _ = sink^
    return int64_column(out, 0)


def _expect(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label)
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ", position " + String(i))


def _check(
    cols: List[Int], desc: List[Bool], nf: List[Bool], workers: Int = 1
) raises:
    var label = String("keys")
    for i in range(len(cols)):
        label += " " + col_name(cols[i]) + (" desc" if desc[i] else " asc")
        label += " nulls first" if nf[i] else " nulls last"
    _expect(
        _sorted_ids(cols, desc, nf, workers),
        oracle_order(N, cols, desc, nf),
        label,
    )


def test_one_key_all_directions_and_placements() raises:
    for col in [X, T, F]:
        for d in [False, True]:
            for nf in [False, True]:
                _check(_keys(col), _flags(d), _flags(nf))


def test_two_keys_mixed_directions_and_placements() raises:
    for a in range(2):
        for b in range(2):
            for c in range(2):
                for d in range(2):
                    _check(
                        _keys(X, T),
                        _flags(a == 1, b == 1, n=2),
                        _flags(c == 1, d == 1, n=2),
                    )
    _check(_keys(T, F), _flags(True, False, n=2), _flags(True, False, n=2))
    _check(_keys(F, X), _flags(False, True, n=2), _flags(False, True, n=2))
    _check(_keys(T, X, F), _flags(True, True, False, n=3), _flags(True, False, True, n=3))


def test_a_null_in_the_first_key_does_not_decide_the_second() raises:
    # Rows with x NULL (r % 6 == 1) are 1, 7, 13, ...: among them the order
    # must follow f (ascending, NULLs last), not any value stored under x.
    var got = _sorted_ids(_keys(X, F), _flags(False, False, n=2), _flags(True, False, n=2))
    var first = List[Int]()
    for r in range(N):
        if r % 6 == 1:
            first.append(r)
    for i in range(len(first)):
        assert_true(got[i] % 6 == 1, "the NULL-x rows come first")
    var want = oracle_order(
        N, _keys(X, F), _flags(False, False, n=2), _flags(True, False, n=2)
    )
    _expect(got, want, "x nulls first, f")


def test_no_placement_asks_for_the_default_nulls_last() raises:
    for d in [False, True]:
        var pool = SegmentPool()
        var data = _data(_keys(X), _flags(d), List[Bool]())
        var sink = _sink(data, pool, 1)
        sink.consume(0, Morsel(table(0, N), 0, 0))
        var got = int64_column(_finish(sink, 1), 0)
        _expect(got, oracle_order(N, _keys(X), _flags(d), _flags(False)), "default")
        assert_true(got[N - 1] % 6 == 1, "a NULL is last in both directions")


def test_a_repeated_key_is_read_once() raises:
    var got = _sorted_ids(_keys(X, X, F), _flags(False, True, False, n=3), _flags(True, False, False, n=3))
    # The second x key cannot reorder what the first settled.
    _expect(
        got,
        oracle_order(N, _keys(X, F), _flags(False, False, n=2), _flags(True, False, n=2)),
        "x, x, f",
    )


def test_a_key_that_is_all_null_leaves_the_next_key_to_decide() raises:
    # Rows 1, 7, 13, ... have x NULL everywhere.
    var ids = List[Int]()
    var pool = SegmentPool()
    var data = _data(_keys(X, F), _flags(True, True, n=2), _flags(True, False, n=2))
    var sink = _sink(data, pool, 1)
    var picked = List[Int]()
    for r in range(N):
        if r % 6 == 1:
            picked.append(r)
    for i in range(len(picked)):
        sink.consume(0, Morsel(table(picked[i], 1), i, i))
    var got = int64_column(_finish(sink, 1), 0)
    var want = List[Int]()
    var sub = oracle_order(N, _keys(F), _flags(True), _flags(False))
    for i in range(len(sub)):
        if sub[i] % 6 == 1:
            want.append(sub[i])
    _expect(got, want, "f decides")


def test_four_workers_merge_into_the_order_of_one() raises:
    for cols in [_keys(X), _keys(T, F), _keys(F, X, T)]:
        var desc = List[Bool]()
        var nf = List[Bool]()
        for i in range(len(cols)):
            desc.append(i % 2 == 1)
            nf.append(i % 2 == 0)
        _check(cols, desc, nf, 4)
        _expect(
            _sorted_ids(cols, desc, nf, 4),
            _sorted_ids(cols, desc, nf, 1),
            "four workers against one",
        )


def test_no_row_gives_the_input_schema_and_one_row_gives_itself() raises:
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(True))
    var empty = _sink(data, pool, 2)
    var out = _finish(empty, 2)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 4)
    var one = _sink(data, pool, 2)
    one.consume(1, Morsel(table(1, 1), 0, 0))
    assert_equal(int64_column(_finish(one, 2), 0)[0], 1)


def test_a_sink_the_plan_cannot_describe_is_refused_by_name() raises:
    var pool = SegmentPool()
    var schema = table(0, 0).schema.copy()
    with assert_raises(contains="segment 7 has no sort key"):
        _ = SortSink(_data(List[Int](), List[Bool](), List[Bool]()), pool.share(), 7, schema.copy())
    with assert_raises(contains="lists 2 directions for 1 sort keys"):
        _ = SortSink(_data(_keys(X), _flags(False, True, n=2), List[Bool]()), pool.share(), 7, schema.copy())
    with assert_raises(contains="lists 2 NULL placements for 1 sort keys"):
        _ = SortSink(_data(_keys(X), _flags(False), _flags(False, True, n=2)), pool.share(), 7, schema.copy())
    var bad = SortSinkData(List[String](), _flags(False))
    bad.sort_keys.append("nope")
    with assert_raises(contains="sorts by 'nope', which is not a column"):
        _ = SortSink(bad, pool.share(), 7, schema.copy())


def test_the_output_is_read_only_after_combine() raises:
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False))
    var sink = _sink(data, pool, 1)
    with assert_raises(contains="read before it was combined"):
        _ = sink.take_output()
    with assert_raises(contains="holds 1 worker slots, got worker 3"):
        sink.consume(3, Morsel(table(0, 2), 0, 0))


def test_a_morsel_the_pool_denies_fails_by_name_and_leaves_nothing() raises:
    var pool = SegmentPool(100)
    var data = _data(_keys(X), _flags(False), _flags(False))
    var sink = _sink(data, pool, 1)
    with assert_raises(contains="was denied"):
        sink.consume(0, Morsel(table(0, N), 0, 0))
    assert_equal(pool.granted(), 0)


def test_a_concatenation_the_pool_denies_fails_in_combine() raises:
    var batch = table(0, N)
    var kept = batch_buffer_bytes(batch)
    var pool = SegmentPool(kept + kept // 2)
    var data = _data(_keys(X), _flags(False), _flags(False))
    var sink = _sink(data, pool, 1)
    sink.consume(0, Morsel(batch^, 0, 0))
    assert_equal(pool.granted(), kept)
    var pipeline = PipelineExecution(1, 0)
    with assert_raises(contains="was denied"):
        sink.combine(pipeline)
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_a_sorted_copy_and_key_batch_the_pool_denies_fail_in_combine() raises:
    # Room for the rows and their concatenation, not for the sorted copy and
    # the key batch the sort adds.
    var batch = table(0, N)
    var kept = batch_buffer_bytes(batch)
    var pool = SegmentPool(2 * kept + 8)
    var data = _data(_keys(X), _flags(False), _flags(False))
    var sink = _sink(data, pool, 1)
    sink.consume(0, Morsel(batch^, 0, 0))
    var pipeline = PipelineExecution(1, 0)
    with assert_raises(contains="the sorted copy and the key batch"):
        sink.combine(pipeline)
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_the_consume_that_crosses_the_sorts_memory_budget_is_refused() raises:
    var kept = batch_buffer_bytes(table(0, N))
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False), kept - 1)
    var sink = _sink(data, pool, 1)
    with assert_raises(contains="would hold more than its memory budget of"):
        sink.consume(0, Morsel(table(0, N), 0, 0))
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_the_memory_budget_bounds_the_peak_and_not_the_input() raises:
    var kept = batch_buffer_bytes(table(0, N))
    # Room for the input and the concatenation: the sorted copy and the key
    # batch push the sort over.
    var tight = _data(_keys(X), _flags(False), _flags(False), 2 * kept + 8)
    var pool = SegmentPool()
    var sink = _sink(tight, pool, 1)
    sink.consume(0, Morsel(table(0, N), 0, 0))
    var pipeline = PipelineExecution(1, 0)
    with assert_raises(contains="the sorted copy and the key batch"):
        sink.combine(pipeline)
    _ = sink^
    assert_equal(pool.granted(), 0)
    # A budget of many inputs sorts the same rows.
    var roomy = _data(_keys(X), _flags(False), _flags(False), 100 * kept)
    var sink2 = _sink(roomy, pool, 1)
    sink2.consume(0, Morsel(table(0, N), 0, 0))
    assert_equal(_finish(sink2, 1).num_rows(), N)


def test_the_pool_is_charged_while_rows_are_held_and_repaid() raises:
    # A budget under one block, so every grant is exactly the bytes asked for.
    var first = table(0, N // 2)
    var second = table(N // 2, N // 2)
    var kept = batch_buffer_bytes(first) + batch_buffer_bytes(second)
    var pool = SegmentPool(10 * kept)
    var data = _data(_keys(X), _flags(False), _flags(False))
    var sink = _sink(data, pool, 2)
    sink.consume(0, Morsel(first^, 0, 0))
    sink.consume(1, Morsel(second^, 1, 1))
    assert_equal(pool.granted(), kept)
    var pipeline = PipelineExecution(2, 0)
    sink.combine(pipeline)
    # The workers' reservations and the key batch went back; the sorted copy,
    # about the size of the input, is held until the output is taken.
    assert_true(pool.granted() >= kept - 16, "the sorted copy is held")
    assert_true(pool.granted() <= kept + 16, "nothing else is held")
    sink.finalize()
    _ = sink.take_output()
    assert_equal(pool.granted(), 0)
    # The sink is still alive here: the pool was repaid by take_output, not by
    # the sink going away.
    _ = sink^


def test_a_sink_dropped_with_rows_in_it_repays_the_pool() raises:
    var pool = SegmentPool()
    var data = _data(_keys(X), _flags(False), _flags(False))
    var sink = _sink(data, pool, 2)
    sink.consume(0, Morsel(table(0, N // 2), 0, 0))
    sink.consume(1, Morsel(table(N // 2, N // 2), 1, 1))
    assert_true(pool.granted() > 0)
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_one_key_all_directions_and_placements]()
    suite.test[test_two_keys_mixed_directions_and_placements]()
    suite.test[test_a_null_in_the_first_key_does_not_decide_the_second]()
    suite.test[test_no_placement_asks_for_the_default_nulls_last]()
    suite.test[test_a_repeated_key_is_read_once]()
    suite.test[test_a_key_that_is_all_null_leaves_the_next_key_to_decide]()
    suite.test[test_four_workers_merge_into_the_order_of_one]()
    suite.test[test_no_row_gives_the_input_schema_and_one_row_gives_itself]()
    suite.test[test_a_sink_the_plan_cannot_describe_is_refused_by_name]()
    suite.test[test_the_output_is_read_only_after_combine]()
    suite.test[test_a_morsel_the_pool_denies_fails_by_name_and_leaves_nothing]()
    suite.test[test_a_concatenation_the_pool_denies_fails_in_combine]()
    suite.test[test_a_sorted_copy_and_key_batch_the_pool_denies_fail_in_combine]()
    suite.test[test_the_consume_that_crosses_the_sorts_memory_budget_is_refused]()
    suite.test[test_the_memory_budget_bounds_the_peak_and_not_the_input]()
    suite.test[test_the_pool_is_charged_while_rows_are_held_and_repaid]()
    suite.test[test_a_sink_dropped_with_rows_in_it_repays_the_pool]()
    suite^.run()
