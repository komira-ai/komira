# =============================================================================
# One segment over fake members
# =============================================================================
#
# What these tests prove (oracles are worked out from the fakes' definitions:
# morsel `k` of `r` rows holds the values k*100 + 0..r-1):
#
#   * Every row reaches the sink exactly once, on one, two and seven workers,
#     under a dispatcher that runs the workers first-to-last and under one that
#     runs them last-to-first. The end of input is seen once per worker and no
#     worker pulls again after it; the sink is combined, finalized and read once,
#     and combine ran after every worker had seen the end of input.
#   * The output order does not depend on which worker ran first: with every
#     worker given morsels of its own, the combined output is worker 0's rows,
#     then worker 1's, then worker 2's, under both dispatchers.
#   * The operator chain runs in order for each morsel (add one, then multiply
#     by ten); an operator that reports FILTERED_EMPTY drops its morsel; an
#     operator that returns HAVE_MORE_OUTPUT has each chunk pushed on before it
#     is asked again, so each row arrives as many times as the operator emits it;
#     an operator that reports FINISHED stops its worker's claims after passing
#     the rows it held on.
#   * An empty source gives an empty output, and a segment needs a worker.

from std.testing import TestSuite, assert_equal, assert_true

from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FROM_PER_WORKER,
    FakeBuilder,
    FakeOpSpec,
    FakeScript,
    fake_desc,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch, ReverseDispatch
from komira_pipeline_exec.fake_members import (
    OP_ADD,
    OP_DROP_ODD,
    OP_FINISH_AT,
    OP_MUL,
    OP_REPEAT,
)
from komira_pipeline_exec.fake_support import (
    SLOT_COMBINES,
    SLOT_CONSUMED_MORSELS,
    SLOT_CONSUMED_ROWS,
    SLOT_CURSOR,
    SLOT_EOF_AT_COMBINE,
    SLOT_EOF_SEEN,
    SLOT_FINALIZES,
    SLOT_PULLED_AFTER_EOF,
    SLOT_SINK_DROPS,
    SLOT_TAKES,
    batch_values,
    fake_values,
)
from komira_pipeline_exec.published_outputs import PublishedOutputs
from komira_pipeline_exec.run_segment import run_segment


def _sorted(var v: List[Int64]) -> List[Int64]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def _run[
    D: ParallelDispatch
](mut dispatch: D, mut builder: FakeBuilder, workers: Int) raises -> List[Int64]:
    var published = PublishedOutputs(1)
    var token = CancellationToken.new()
    var out = run_segment(
        builder, dispatch, fake_desc(0), published, workers, token
    )
    return batch_values(out)


def _expect_values(got: List[Int64], var want: List[Int64]) raises:
    var a = _sorted(got.copy())
    var b = _sorted(want^)
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i], b[i])


def _keys_values(n_keys: Int, rows: Int, times: Int = 1) -> List[Int64]:
    var out = List[Int64]()
    for k in range(n_keys):
        for _ in range(times):
            var v = fake_values(k, rows)
            for i in range(len(v)):
                out.append(v[i])
    return out^


def _check_every_row_once[D: ParallelDispatch](mut dispatch: D, workers: Int) raises:
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=20, rows=3))
    var got = _run(dispatch, b, workers)
    _expect_values(got, _keys_values(20, 3))
    var t = b.tally(0)
    assert_equal(t.get(SLOT_CONSUMED_ROWS), 60)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 20)
    assert_equal(t.get(SLOT_EOF_SEEN), workers)
    assert_equal(t.get(SLOT_PULLED_AFTER_EOF), 0)
    assert_equal(t.get(SLOT_COMBINES), 1)
    assert_equal(t.get(SLOT_FINALIZES), 1)
    assert_equal(t.get(SLOT_TAKES), 1)
    assert_equal(t.get(SLOT_EOF_AT_COMBINE), workers)
    assert_equal(t.get(SLOT_SINK_DROPS), 1)


def test_every_row_arrives_once_first_to_last() raises:
    var d1 = InlineDispatch()
    _check_every_row_once(d1, 1)
    var d2 = InlineDispatch()
    _check_every_row_once(d2, 2)
    var d7 = InlineDispatch()
    _check_every_row_once(d7, 7)


def test_every_row_arrives_once_last_to_first() raises:
    var d1 = ReverseDispatch()
    _check_every_row_once(d1, 1)
    var d2 = ReverseDispatch()
    _check_every_row_once(d2, 2)
    var d7 = ReverseDispatch()
    _check_every_row_once(d7, 7)


def _per_worker_script() -> FakeScript:
    return FakeScript(FROM_PER_WORKER, n_morsels=2, rows=2)


def _per_worker_want() -> List[Int64]:
    var want = List[Int64]()
    for w in range(3):
        for j in range(2):
            var v = fake_values(w * 100 + j, 2)
            for i in range(len(v)):
                want.append(v[i])
    return want^


def _assert_same_order(got: List[Int64], want: List[Int64]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def test_combine_order_is_worker_order_whoever_ran_first() raises:
    var forward = FakeBuilder()
    _ = forward.add(_per_worker_script())
    var d1 = InlineDispatch()
    var a = _run(d1, forward, 3)
    var reverse = FakeBuilder()
    _ = reverse.add(_per_worker_script())
    var d2 = ReverseDispatch()
    var b = _run(d2, reverse, 3)
    _assert_same_order(a, _per_worker_want())
    _assert_same_order(b, _per_worker_want())


def test_operator_chain_runs_in_order_for_each_morsel() raises:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_ADD, 1))
    ops.append(FakeOpSpec(OP_MUL, 10))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=6, rows=2, ops=ops^))
    var d = InlineDispatch()
    var got = _run(d, b, 3)
    var want = List[Int64]()
    for k in range(6):
        var v = fake_values(k, 2)
        for i in range(len(v)):
            want.append((v[i] + 1) * 10)
    _expect_values(got, want^)


def test_filtered_empty_morsels_are_dropped() raises:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_DROP_ODD))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=7, rows=2, ops=ops^))
    var d = InlineDispatch()
    var got = _run(d, b, 2)
    var want = List[Int64]()
    for k in range(0, 7, 2):
        var v = fake_values(k, 2)
        for i in range(len(v)):
            want.append(v[i])
    _expect_values(got, want^)
    assert_equal(b.tally(0).get(SLOT_CONSUMED_MORSELS), 4)


def test_have_more_output_pushes_each_chunk_on() raises:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_REPEAT, 3))
    ops.append(FakeOpSpec(OP_ADD, 1000))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=2, ops=ops^))
    var d = InlineDispatch()
    var got = _run(d, b, 2)
    var want = List[Int64]()
    for k in range(4):
        for _ in range(3):
            var v = fake_values(k, 2)
            for i in range(len(v)):
                want.append(v[i] + 1000)
    _expect_values(got, want^)
    assert_equal(b.tally(0).get(SLOT_CONSUMED_MORSELS), 12)


def test_finished_operator_stops_the_claims_after_passing_its_rows() raises:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_FINISH_AT, 4))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=10, rows=2, ops=ops^))
    var d = InlineDispatch()
    var got = _run(d, b, 1)
    _expect_values(got, _keys_values(4, 2))
    var t = b.tally(0)
    assert_equal(t.get(SLOT_CURSOR), 4)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 4)
    assert_equal(t.get(SLOT_EOF_SEEN), 0)


def test_an_empty_source_gives_an_empty_output() raises:
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=0, rows=2))
    var d = InlineDispatch()
    var got = _run(d, b, 3)
    assert_equal(len(got), 0)
    var t = b.tally(0)
    assert_equal(t.get(SLOT_EOF_SEEN), 3)
    assert_equal(t.get(SLOT_COMBINES), 1)


def test_a_segment_needs_a_worker() raises:
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=1, rows=1))
    var d = InlineDispatch()
    try:
        _ = _run(d, b, 0)
        assert_true(False, "zero workers must be refused")
    except e:
        assert_true("at least one worker" in String(e), String(e))
    assert_equal(len(b.built_order), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_row_arrives_once_first_to_last]()
    suite.test[test_every_row_arrives_once_last_to_first]()
    suite.test[test_combine_order_is_worker_order_whoever_ran_first]()
    suite.test[test_operator_chain_runs_in_order_for_each_morsel]()
    suite.test[test_filtered_empty_morsels_are_dropped]()
    suite.test[test_have_more_output_pushes_each_chunk_on]()
    suite.test[test_finished_operator_stops_the_claims_after_passing_its_rows]()
    suite.test[test_an_empty_source_gives_an_empty_output]()
    suite.test[test_a_segment_needs_a_worker]()
    suite^.run()
