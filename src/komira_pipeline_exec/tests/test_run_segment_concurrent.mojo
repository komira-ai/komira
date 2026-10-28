# =============================================================================
# One segment on the runtime's threaded dispatcher
# =============================================================================
#
# The other segment tests run their workers one after another. These run the
# same fake segments on a `LocalDispatcher` with four attached workers, so the
# workers of a segment share the claim cursor, the cancel flag and the error
# slot across threads. They assert counters only. What they prove:
#
#   * Every row reaches the sink exactly once, each worker sees the end of
#     input once and none pulls again after it, and the sink is combined,
#     finalized and read once, after every worker saw the end of input.
#   * When an operator raises on every call from the fifth on, the segment
#     fails with that operator's error, nothing is combined, finalized or read,
#     and the sink is destroyed once.

from std.testing import TestSuite, assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FakeBuilder,
    FakeOpSpec,
    FakeScript,
    fake_desc,
)
from komira_pipeline_exec.fake_members import OP_FAIL_FROM
from komira_pipeline_exec.fake_support import (
    SLOT_COMBINES,
    SLOT_CONSUMED_ROWS,
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

comptime WORKERS = 4
comptime MORSELS = 200
comptime ROWS = 3


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _sorted(var v: List[Int64]) -> List[Int64]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def test_every_row_arrives_once_on_threads() raises:
    var b = FakeBuilder()
    _ = b.add(FakeScript(FROM_CURSOR, n_morsels=MORSELS, rows=ROWS))
    var published = PublishedOutputs(1)
    var token = CancellationToken.new()
    var rt = _started_runtime()
    var got = List[Int64]()
    var failure = String("")
    try:
        ref disp = rt.dispatcher()
        var out = run_segment(
            b, disp, fake_desc(0), published, WORKERS, token
        )
        got = batch_values(out)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")

    var want = List[Int64]()
    for k in range(MORSELS):
        var v = fake_values(k, ROWS)
        for i in range(len(v)):
            want.append(v[i])
    var a = _sorted(got^)
    var w = _sorted(want^)
    assert_equal(len(a), len(w))
    for i in range(len(w)):
        assert_equal(a[i], w[i])
    var t = b.tally(0)
    assert_equal(t.get(SLOT_CONSUMED_ROWS), MORSELS * ROWS)
    assert_equal(t.get(SLOT_EOF_SEEN), WORKERS)
    assert_equal(t.get(SLOT_PULLED_AFTER_EOF), 0)
    assert_equal(t.get(SLOT_COMBINES), 1)
    assert_equal(t.get(SLOT_EOF_AT_COMBINE), WORKERS)
    assert_equal(t.get(SLOT_FINALIZES), 1)
    assert_equal(t.get(SLOT_TAKES), 1)
    assert_equal(t.get(SLOT_SINK_DROPS), 1)


def test_a_raising_operator_fails_the_segment_on_threads() raises:
    var ops = List[FakeOpSpec]()
    ops.append(FakeOpSpec(OP_FAIL_FROM, 5))
    var b = FakeBuilder()
    _ = b.add(
        FakeScript(FROM_CURSOR, n_morsels=MORSELS, rows=ROWS, ops=ops^)
    )
    var published = PublishedOutputs(1)
    var token = CancellationToken.new()
    var rt = _started_runtime()
    var failure = String("")
    try:
        ref disp = rt.dispatcher()
        _ = run_segment(b, disp, fake_desc(0), published, WORKERS, token)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_true("fake operator failed at execute" in failure, failure)
    var t = b.tally(0)
    assert_equal(t.get(SLOT_COMBINES), 0)
    assert_equal(t.get(SLOT_FINALIZES), 0)
    assert_equal(t.get(SLOT_TAKES), 0)
    assert_equal(t.get(SLOT_SINK_DROPS), 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_row_arrives_once_on_threads]()
    suite.test[test_a_raising_operator_fails_the_segment_on_threads]()
    suite^.run()
