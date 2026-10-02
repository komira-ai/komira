# RetryPolicy.decide as a table: attempt limits, the deadline cut-off, the
# server delay against the backoff, budget cost by verdict kind, and the
# verdicts and inputs that stop.

from komira_retry import (
    Backoff,
    Jitter,
    RetryPolicy,
    RetryRng,
    Verdict,
    DEFAULT_RETRY_COST,
)

from std.testing import assert_equal, assert_false, assert_true


struct ZeroRng(RetryRng, Movable, Deinitable):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def next_u64(mut self) -> UInt64:
        self.calls += 1
        return 0


def _policy() raises -> RetryPolicy:
    # BAND(0) = no jitter, so every delay is the cap: 100, 200, 400, 800, 1000.
    return RetryPolicy(
        Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.band(0)),
        max_attempts=4,
        deadline_ms=10_000,
        max_server_delay_ms=5_000,
    )


def test_attempt_limit() raises:
    var p = _policy()
    var rng = ZeroRng()
    var expect: List[Int64] = [100, 200, 400]
    for i in range(3):
        var d = p.decide(i + 1, 0, Verdict.transient("503"), rng)
        assert_true(d.retry, d.reason)
        assert_equal(d.delay_ms, expect[i])
    var last = p.decide(4, 0, Verdict.transient("503"), rng)
    assert_false(last.retry)
    assert_equal(last.delay_ms, 0)
    assert_true(last.reason.startswith("gave up after 4 attempts"), last.reason)
    # One attempt allowed means no retry at all.
    var once = RetryPolicy(Backoff(), max_attempts=1)
    assert_false(once.decide(1, 0, Verdict.transient("x"), rng).retry)


def test_deadline_cut_off() raises:
    var p = _policy()
    var rng = ZeroRng()
    # The wait would END exactly at the deadline: refused.
    var at = p.decide(1, 9_900, Verdict.transient("503"), rng)
    assert_false(at.retry)
    assert_true(at.reason.startswith("the next retry would pass the 10000 ms deadline"), at.reason)
    # One millisecond earlier it fits.
    var before = p.decide(1, 9_899, Verdict.transient("503"), rng)
    assert_true(before.retry)
    assert_equal(before.delay_ms, 100)
    # A server delay is held to the deadline too.
    assert_false(p.decide(1, 6_000, Verdict.transient("x", server_delay_ms=4_000), rng).retry)


def test_server_delay_against_backoff() raises:
    var p = _policy()
    var rng = ZeroRng()
    # Longer than the backoff: the server's wait wins.
    assert_equal(p.decide(1, 0, Verdict.transient("x", server_delay_ms=700), rng).delay_ms, 700)
    assert_equal(p.decide(1, 0, Verdict.throttle("x", server_delay_ms=700), rng).delay_ms, 700)
    # Shorter: the backoff still applies.
    assert_equal(p.decide(2, 0, Verdict.transient("x", server_delay_ms=50), rng).delay_ms, 200)
    # Zero is a real (immediate) server delay; -1 is none.
    assert_equal(p.decide(1, 0, Verdict.transient("x", server_delay_ms=0), rng).delay_ms, 100)
    # Exactly the limit is honoured; over it gives up instead of waiting.
    assert_equal(
        p.decide(1, 0, Verdict.transient("x", server_delay_ms=5_000), rng).delay_ms, 5_000
    )
    var over = p.decide(1, 0, Verdict.transient("x", server_delay_ms=5_001), rng)
    assert_false(over.retry)
    assert_true(over.reason.startswith("server asked to wait 5001 ms"), over.reason)


def test_cost_by_verdict_kind() raises:
    var p = _policy()
    var rng = ZeroRng()
    var t = p.decide(1, 0, Verdict.transient("503"), rng)
    var th = p.decide(1, 0, Verdict.throttle("429"), rng)
    # botocore's RetryQuotaChecker (standard mode) charges _RETRY_COST = 5
    # for every retryable error, throttling included. A throttle costs no
    # more than any other retry unless the classifier says so.
    assert_equal(DEFAULT_RETRY_COST, 5)
    assert_equal(t.cost, 5)
    assert_equal(th.cost, 5)
    assert_true(th.reason.startswith("throttled after 100 ms: 429"), th.reason)
    assert_true(t.reason.startswith("retrying after 100 ms: 503"), t.reason)
    # The classifier's own cost is carried through.
    # (botocore charges a timeout 10; that is the AWS classifier's call.)
    assert_equal(p.decide(1, 0, Verdict.transient("timeout", cost=10), rng).cost, 10)
    assert_equal(p.decide(1, 0, Verdict.throttle("slow", cost=14), rng).cost, 14)


def test_stops() raises:
    var p = _policy()
    var rng = ZeroRng()
    var s = p.decide(1, 0, Verdict.stop("400 Bad Request"), rng)
    assert_false(s.retry)
    assert_equal(s.reason, "not retryable: 400 Bad Request")
    # Non-retryable wins over every other consideration, even a server delay.
    var v = Verdict.stop("403")
    v.server_delay_ms = 10
    assert_false(p.decide(1, 0, v, rng).retry)
    # A negative cost is a classifier bug: stop, do not retry for free.
    assert_false(p.decide(1, 0, Verdict.transient("x", cost=-1), rng).retry)
    # attempts_made counts the first send, so 0 is a caller bug.
    var z = p.decide(0, 0, Verdict.transient("x"), rng)
    assert_false(z.retry)
    assert_true(z.reason.startswith("decide: attempts_made must be >= 1"), z.reason)


def test_rng_drawn_once_per_retry() raises:
    var p = _policy()
    var rng = ZeroRng()
    _ = p.decide(1, 0, Verdict.transient("x"), rng)
    assert_equal(rng.calls, 1)
    # A stop decided before the backoff draws nothing.
    _ = p.decide(1, 0, Verdict.stop("x"), rng)
    _ = p.decide(4, 0, Verdict.transient("x"), rng)
    assert_equal(rng.calls, 1)


def main() raises:
    test_attempt_limit()
    test_deadline_cut_off()
    test_server_delay_against_backoff()
    test_cost_by_verdict_kind()
    test_stops()
    test_rng_drawn_once_per_retry()
    print("test_decide: OK")
