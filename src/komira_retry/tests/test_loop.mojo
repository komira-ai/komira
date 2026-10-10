# RetryLoop on a fake clock, sleeper and random source: the exact sleep
# sequence and attempt count, the deadline never slept past, the server
# delay, a classifier through after_outcome, and restarting for a new call.

from komira_retry import (
    Backoff,
    Jitter,
    ManualClock,
    RecordingSleeper,
    RetryClassifier,
    RetryLoop,
    RetryPolicy,
    RetryRng,
    SplitMix64Rng,
    TokenBucket,
    Verdict,
)

from std.testing import assert_equal, assert_false, assert_true


comptime _SEND_MS: Int64 = 10


struct ZeroRng(RetryRng, Movable, Deinitable):
    def __init__(out self):
        pass

    def next_u64(mut self) -> UInt64:
        return 0


comptime FakeLoop = RetryLoop[ManualClock, RecordingSleeper, ZeroRng]


def _exact_loop(max_attempts: Int, deadline_ms: Int64) raises -> FakeLoop:
    # BAND(0): no jitter, so the sleeps are the caps 100, 200, 400, 800, 1000.
    var p = RetryPolicy(
        Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.band(0)),
        max_attempts=max_attempts,
        deadline_ms=deadline_ms,
    )
    return FakeLoop(p^, ManualClock(start_ms=5_000), RecordingSleeper(), ZeroRng())


def _same(a: List[Int64], b: List[Int64]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _show(a: List[Int64]) -> String:
    var s = String("[")
    for i in range(len(a)):
        if i > 0:
            s += ", "
        s += String(a[i])
    return s + "]"


def test_sleep_sequence_and_attempts() raises:
    var loop = _exact_loop(max_attempts=5, deadline_ms=100_000)
    loop.start()
    var sends = 1
    while True:
        loop.clock().advance(_SEND_MS)  # the send that failed
        var d = loop.after_failure(Verdict.transient("503"))
        if not d.retry:
            assert_true(d.reason.startswith("gave up after 5 attempts"), d.reason)
            break
        loop.clock().advance(d.delay_ms)  # the sleep the loop asked for
        sends += 1
    assert_equal(sends, 5)
    assert_equal(loop.attempts(), 5)
    var expect: List[Int64] = [100, 200, 400, 800]
    assert_true(_same(loop.sleeper().slept, expect), _show(loop.sleeper().slept))


def test_never_sleeps_past_the_deadline() raises:
    var deadline = Int64(1_000)
    var loop = _exact_loop(max_attempts=50, deadline_ms=deadline)
    loop.start()
    var start = loop.clock().now
    while True:
        loop.clock().advance(_SEND_MS)
        var d = loop.after_failure(Verdict.transient("503"))
        if not d.retry:
            assert_true(d.reason.startswith("the next retry would pass the 1000 ms deadline"), d.reason)
            break
        loop.clock().advance(d.delay_ms)
        # Every sleep ends before the deadline.
        assert_true(loop.clock().now - start < deadline, String(loop.clock().now - start))
    # t=10 +100 -> 110, t=120 +200 -> 320, t=330 +400 -> 730, t=740: +800 would end at 1540.
    var expect: List[Int64] = [100, 200, 400]
    assert_true(_same(loop.sleeper().slept, expect), _show(loop.sleeper().slept))
    assert_equal(loop.attempts(), 4)


def test_server_delay_is_slept() raises:
    var loop = _exact_loop(max_attempts=5, deadline_ms=100_000)
    loop.start()
    _ = loop.after_failure(Verdict.throttle("429", server_delay_ms=300))
    _ = loop.after_failure(Verdict.transient("503", server_delay_ms=50))
    var expect: List[Int64] = [300, 200]
    assert_true(_same(loop.sleeper().slept, expect), _show(loop.sleeper().slept))


struct StatusClassifier(RetryClassifier):
    """A stand-in for a client's classifier: an HTTP-like status code."""

    comptime Outcome = Int

    def __init__(out self):
        pass

    def classify(self, outcome: Int) -> Verdict:
        if outcome == 503:
            return Verdict.transient("503")
        if outcome == 429:
            return Verdict.throttle("429", server_delay_ms=250)
        return Verdict.stop(String(outcome))


def test_after_outcome_with_a_classifier() raises:
    var loop = _exact_loop(max_attempts=10, deadline_ms=100_000)
    var budget = TokenBucket()
    var c = StatusClassifier()
    loop.start()
    assert_true(loop.after_outcome(c, 503, budget).retry)
    assert_true(loop.after_outcome(c, 429, budget).retry)
    var last = loop.after_outcome(c, 404, budget)
    assert_false(last.retry)
    assert_equal(last.reason, "not retryable: 404")
    var expect: List[Int64] = [100, 250]
    assert_true(_same(loop.sleeper().slept, expect), _show(loop.sleeper().slept))
    assert_equal(loop.attempts(), 3)
    # 500 - 5 (transient) - 5 (throttled).
    assert_equal(budget.available(), 490)


def test_restart_for_the_next_call() raises:
    var loop = _exact_loop(max_attempts=3, deadline_ms=100_000)
    loop.start()
    _ = loop.after_failure(Verdict.transient("x"))
    _ = loop.after_failure(Verdict.transient("x"))
    assert_false(loop.after_failure(Verdict.transient("x")).retry)
    # A new call starts over: attempts, backoff and elapsed time.
    loop.clock().advance(60_000)
    loop.start()
    assert_equal(loop.attempts(), 1)
    assert_equal(loop.elapsed_ms(), 0)
    var d = loop.after_failure(Verdict.transient("x"))
    assert_true(d.retry)
    assert_equal(d.delay_ms, 100)


def test_full_jitter_sequence_is_seed_determined() raises:
    var p = RetryPolicy(
        Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.full()),
        max_attempts=6,
        deadline_ms=100_000,
    )
    var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        p.copy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )
    loop.start()
    while loop.after_failure(Verdict.transient("x")).retry:
        pass
    # The same seed through the pure decide gives the same waits.
    var rng = SplitMix64Rng(7)
    var expect = List[Int64]()
    for n in range(1, 6):
        var d = p.decide(n, 0, Verdict.transient("x"), rng)
        expect.append(d.delay_ms)
        assert_true(d.delay_ms >= 0 and d.delay_ms <= p.backoff.cap_ms(n))
    assert_true(_same(loop.sleeper().slept, expect), _show(loop.sleeper().slept))
    assert_equal(loop.attempts(), 6)


def test_seam_accessors_after_a_call() raises:
    # rng(): the loop draws from the random source it was given exactly what
    # decide draws for the same sends, the give-up included, so the next
    # value it holds is the next value of a fresh source fed the same calls.
    # sleeper().total_ms(): the sum of every wait the loop asked for.
    var p = RetryPolicy(
        Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.full()),
        max_attempts=5,
        deadline_ms=100_000,
    )
    var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        p.copy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(11)
    )
    loop.start()
    while loop.after_failure(Verdict.transient("x")).retry:
        pass
    var fresh = SplitMix64Rng(11)
    var total = Int64(0)
    for n in range(1, 6):
        var d = p.decide(n, 0, Verdict.transient("x"), fresh)
        if d.retry:
            total += d.delay_ms
    assert_equal(loop.rng().next_u64(), fresh.next_u64())
    assert_equal(len(loop.sleeper().slept), 4)
    assert_true(total > 0)
    assert_equal(loop.sleeper().total_ms(), total)
    # A sleeper that never slept totals 0.
    assert_equal(RecordingSleeper().total_ms(), 0)


def main() raises:
    test_sleep_sequence_and_attempts()
    test_never_sleeps_past_the_deadline()
    test_server_delay_is_slept()
    test_after_outcome_with_a_classifier()
    test_restart_for_the_next_call()
    test_full_jitter_sequence_is_seed_determined()
    test_seam_accessors_after_a_call()
    print("test_loop: OK")
