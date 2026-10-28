# =============================================================================
# One segment over fake members: failure and cancellation
# =============================================================================
#
# The workers of a segment run one after another under the fake dispatchers, so
# which worker fails first is a fact of the test, and the counters say exactly
# how far the others got. What these tests prove:
#
#   * An operator that raises fails the segment with that error. The other
#     workers stop at their next morsel boundary and claim nothing further, under
#     either order of workers: the claim counter stops at the morsel that failed.
#     The sink is neither combined nor finalized nor read, and it is destroyed.
#   * A source that raises (a decode error) fails the segment the same way.
#   * A sink whose memory grow is denied fails the segment with the denial named;
#     the rows already held stay charged, the rows of the denied morsel do not,
#     and nothing is combined or read.
#   * The caller's cancellation stops the other workers at their next boundary,
#     the segment raises a cancelled error carrying the caller's reason, and
#     nothing is combined or read. A token cancelled before the run builds
#     nothing.

from std.testing import TestSuite, assert_equal, assert_true

from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FakeBuilder,
    FakeOpSpec,
    FakeScript,
    fake_desc,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch, ReverseDispatch
from komira_pipeline_exec.fake_members import (
    OP_CANCEL_AT,
    OP_FAIL_AT,
)
from komira_pipeline_exec.fake_support import (
    SLOT_COMBINES,
    SLOT_CONSUMED_MORSELS,
    SLOT_CURSOR,
    SLOT_EOF_SEEN,
    SLOT_FINALIZES,
    SLOT_GROW_DENIED,
    SLOT_GROW_HELD,
    SLOT_SINK_DROPS,
    SLOT_TAKES,
)
from komira_pipeline_exec.published_outputs import PublishedOutputs
from komira_pipeline_exec.run_segment import run_segment


def _expect_failure[
    D: ParallelDispatch
](
    mut dispatch: D,
    mut builder: FakeBuilder,
    workers: Int,
    token: CancellationToken,
    needle: String,
) raises:
    var published = PublishedOutputs(1)
    try:
        _ = run_segment(
            builder, dispatch, fake_desc(0), published, workers, token
        )
    except e:
        assert_true(needle in String(e), String(e))
        return
    assert_true(False, "the segment must fail with: " + needle)


def _nothing_after_the_failure(b: FakeBuilder) raises:
    var t = b.tally(0)
    assert_equal(t.get(SLOT_COMBINES), 0)
    assert_equal(t.get(SLOT_FINALIZES), 0)
    assert_equal(t.get(SLOT_TAKES), 0)
    assert_equal(t.get(SLOT_SINK_DROPS), 1)


def _failing_operator_script() -> FakeScript:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_FAIL_AT, 3))
    return FakeScript(FROM_CURSOR, n_morsels=10, rows=2, ops=ops^)


def test_a_raising_operator_fails_the_segment_and_stops_the_others() raises:
    var b = FakeBuilder()
    _ = b.add(_failing_operator_script())
    var d = InlineDispatch()
    _expect_failure(
        d, b, 3, CancellationToken.new(), "fake operator failed at execute 3"
    )
    var t = b.tally(0)
    # Worker 0 claimed three morsels; the third raised before the sink. Workers
    # 1 and 2 stopped at their first boundary without claiming.
    assert_equal(t.get(SLOT_CURSOR), 3)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 2)
    assert_equal(t.get(SLOT_EOF_SEEN), 0)
    _nothing_after_the_failure(b)


def test_the_first_error_wins_whichever_worker_ran_first() raises:
    var b = FakeBuilder()
    _ = b.add(_failing_operator_script())
    var d = ReverseDispatch()
    _expect_failure(
        d, b, 3, CancellationToken.new(), "fake operator failed at execute 3"
    )
    var t = b.tally(0)
    assert_equal(t.get(SLOT_CURSOR), 3)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 2)
    _nothing_after_the_failure(b)


def test_a_raising_source_fails_the_segment() raises:
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=10, rows=2, fail_at_claim=4))
    var d = InlineDispatch()
    _expect_failure(
        d, b, 2, CancellationToken.new(), "fake source failed at claim 4"
    )
    var t = b.tally(0)
    assert_equal(t.get(SLOT_CURSOR), 5)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 4)
    _nothing_after_the_failure(b)


def test_a_denied_memory_grow_fails_the_segment() raises:
    # Each morsel is 2 rows of 8 bytes. A budget of 40 bytes holds two.
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=10, rows=2, budget_bytes=40))
    var d = InlineDispatch()
    _expect_failure(
        d,
        b,
        2,
        CancellationToken.new(),
        "memory budget of 40 bytes denied a grow of 16 bytes",
    )
    var t = b.tally(0)
    assert_equal(t.get(SLOT_GROW_DENIED), 1)
    assert_equal(t.get(SLOT_GROW_HELD), 32)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 2)
    assert_equal(t.get(SLOT_CURSOR), 3)
    _nothing_after_the_failure(b)


def test_the_callers_cancel_stops_the_other_workers() raises:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_CANCEL_AT, 3))
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=10, rows=2, ops=ops^))
    var token = CancellationToken.new()
    b.cancel_token = Optional[CancellationToken](token.clone())
    var d = InlineDispatch()
    _expect_failure(d, b, 3, token, "the query was cancelled: fake operator cancelled")
    var t = b.tally(0)
    # The morsel in hand when the token was cancelled reaches the sink; no
    # worker claims another.
    assert_equal(t.get(SLOT_CURSOR), 3)
    assert_equal(t.get(SLOT_CONSUMED_MORSELS), 3)
    _nothing_after_the_failure(b)


def test_a_token_cancelled_before_the_run_builds_nothing() raises:
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=10, rows=2))
    var token = CancellationToken.new()
    token.cancel(String("stop"))
    var d = InlineDispatch()
    _expect_failure(d, b, 2, token, "the query was cancelled: stop")
    assert_equal(len(b.built_order), 0)
    assert_equal(b.tally(0).get(SLOT_CURSOR), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_raising_operator_fails_the_segment_and_stops_the_others]()
    suite.test[test_the_first_error_wins_whichever_worker_ran_first]()
    suite.test[test_a_raising_source_fails_the_segment]()
    suite.test[test_a_denied_memory_grow_fails_the_segment]()
    suite.test[test_the_callers_cancel_stops_the_other_workers]()
    suite.test[test_a_token_cancelled_before_the_run_builds_nothing]()
    suite^.run()
