# Every bad setting is refused at construction, naming the setting, and a
# loop used before start() refuses rather than deciding on garbage.

from komira_retry import (
    Backoff,
    Jitter,
    ManualClock,
    RecordingSleeper,
    RetryLoop,
    RetryPolicy,
    SplitMix64Rng,
    TokenBucket,
    Verdict,
)

from std.testing import assert_true


def _refused_backoff(initial: Int64, mult: Float64, max_ms: Int64, expect: String) raises:
    try:
        _ = Backoff(initial_ms=initial, multiplier=mult, max_ms=max_ms)
    except e:
        assert_true(String(e).startswith(expect), String(e))
        return
    raise Error(String("Backoff accepted ") + String(initial) + "/" + String(mult) + "/" + String(max_ms))


def _refused_policy(attempts: Int, deadline: Int64, max_server: Int64, expect: String) raises:
    try:
        _ = RetryPolicy(
            Backoff(), max_attempts=attempts, deadline_ms=deadline, max_server_delay_ms=max_server
        )
    except e:
        assert_true(String(e).startswith(expect), String(e))
        return
    raise Error(String("RetryPolicy accepted ") + String(attempts) + "/" + String(deadline))


def _refused_band(pct: Int) raises:
    try:
        _ = Jitter.band(pct)
    except e:
        assert_true(String(e).startswith("Jitter.band: pct must be in [0, 100]"), String(e))
        return
    raise Error(String("Jitter.band accepted ") + String(pct))


def _refused_bucket(capacity: Int, refill: Int, expect: String) raises:
    try:
        _ = TokenBucket(capacity=capacity, success_refill=refill)
    except e:
        assert_true(String(e).startswith(expect), String(e))
        return
    raise Error("TokenBucket accepted a bad setting")


def test_backoff() raises:
    _refused_backoff(-1, 2.0, 100, "Backoff: need 0 <= initial_ms <= max_ms")
    _refused_backoff(200, 2.0, 100, "Backoff: need 0 <= initial_ms <= max_ms")
    _refused_backoff(100, 0.5, 1000, "Backoff: multiplier must be >= 1")
    _refused_backoff(100, 0.0, 1000, "Backoff: multiplier must be >= 1")
    var nan = Float64(0.0) / Float64(0.0)
    _refused_backoff(100, nan, 1000, "Backoff: multiplier must be >= 1")
    # +inf passes `>= 1`; with initial 0 the cap would be 0 * inf = NaN.
    var inf = Float64(1.0) / Float64(0.0)
    _refused_backoff(0, inf, 1000, "Backoff: multiplier must be finite")
    _refused_backoff(100, inf, 1000, "Backoff: multiplier must be finite")
    # A cap so large that jitter arithmetic overflows Int64 (cap + 1,
    # cap * pct) would give a negative wait that passes the deadline check.
    _refused_backoff(0, 2.0, Int64.MAX, "Backoff: max_ms must be <= ")
    _refused_backoff(0, 2.0, (Int64(1) << 40) + 1, "Backoff: max_ms must be <= ")
    # The edges are accepted.
    _ = Backoff(initial_ms=0, multiplier=1.0, max_ms=0)
    _ = Backoff(initial_ms=0, multiplier=2.0, max_ms=Int64(1) << 40)


def test_largest_backoff_waits_are_sane() raises:
    # At the largest accepted cap both jitter modes stay in [0, cap].
    var top = Int64(1) << 40
    var full = Backoff(initial_ms=top, multiplier=1.0, max_ms=top, jitter=Jitter.full())
    var band = Backoff(initial_ms=top, multiplier=1.0, max_ms=top, jitter=Jitter.band(100))
    var rng = SplitMix64Rng(3)
    for _ in range(64):
        var f = full.delay_ms(1, rng)
        assert_true(f >= 0 and f <= top, String(f))
        var b = band.delay_ms(1, rng)
        assert_true(b >= 0 and b <= top, String(b))


def test_jitter() raises:
    _refused_band(-1)
    _refused_band(101)
    _ = Jitter.band(0)
    _ = Jitter.band(100)


def test_policy() raises:
    _refused_policy(0, 1000, 0, "RetryPolicy: max_attempts must be >= 1")
    _refused_policy(-3, 1000, 0, "RetryPolicy: max_attempts must be >= 1")
    _refused_policy(3, 0, 0, "RetryPolicy: deadline_ms must be > 0")
    _refused_policy(3, -5, 0, "RetryPolicy: deadline_ms must be > 0")
    _refused_policy(3, 1000, -1, "RetryPolicy: max_server_delay_ms must be >= 0")
    # elapsed + an Int64.MAX server delay would wrap negative and pass the
    # deadline check.
    _refused_policy(3, 1000, Int64.MAX, "RetryPolicy: max_server_delay_ms must be <= ")
    # The stated bound is MAX_WAIT_MS itself: one past it is refused, the
    # bound is accepted.
    _refused_policy(3, 1000, (Int64(1) << 40) + 1, "RetryPolicy: max_server_delay_ms must be <= ")
    _ = RetryPolicy(Backoff(), max_attempts=1, deadline_ms=1, max_server_delay_ms=0)
    _ = RetryPolicy(Backoff(), max_server_delay_ms=Int64(1) << 40)


def test_bucket() raises:
    _refused_bucket(-1, 1, "TokenBucket: capacity must be >= 0")
    _refused_bucket(10, -1, "TokenBucket: success_refill must be >= 0")


def test_loop_before_start() raises:
    var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        RetryPolicy(Backoff()), ManualClock(), RecordingSleeper(), SplitMix64Rng(1)
    )
    try:
        _ = loop.after_failure(Verdict.transient("x"))
    except e:
        assert_true(String(e).startswith("RetryLoop.after_failure: start() was not called"))
        return
    raise Error("after_failure ran before start()")


def test_after_success_ends_the_call() raises:
    # A caller that skips start() on its next call must not silently carry
    # on with the previous call's attempts and start time.
    var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        RetryPolicy(Backoff()), ManualClock(), RecordingSleeper(), SplitMix64Rng(1)
    )
    var budget = TokenBucket()
    loop.start()
    loop.after_success(budget)
    try:
        _ = loop.after_failure(Verdict.transient("x"))
    except e:
        assert_true(String(e).startswith("RetryLoop.after_failure: start() was not called"))
        return
    raise Error("after_failure ran after after_success() without a new start()")


def main() raises:
    test_backoff()
    test_largest_backoff_waits_are_sane()
    test_jitter()
    test_policy()
    test_bucket()
    test_loop_before_start()
    test_after_success_ends_the_call()
    print("test_refusals: OK")
