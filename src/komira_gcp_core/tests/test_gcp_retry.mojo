# =============================================================================
# test_gcp_retry.mojo — AIP-194 retry decisions and jittered backoff bounds.
# =============================================================================
#
# Every clock and random draw is injected: `FixedRng` pins the jitter to the
# bottom or top of its range, and `FakeClock` advances on `sleep_ms` instead of
# sleeping, so the tests assert exact delays and never wait. This package owns
# no transport (the one seam is komira_http's `Connector`); `_drive` is the
# loop a caller writes around `RetryPolicy.decide`, over scripted statuses.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_core import (
    CODE_OK,
    CODE_CANCELLED,
    CODE_UNKNOWN,
    CODE_INVALID_ARGUMENT,
    CODE_DEADLINE_EXCEEDED,
    CODE_NOT_FOUND,
    CODE_PERMISSION_DENIED,
    CODE_RESOURCE_EXHAUSTED,
    CODE_ABORTED,
    CODE_INTERNAL,
    CODE_UNAVAILABLE,
    CODE_DATA_LOSS,
    CODE_UNAUTHENTICATED,
    Clock,
    MonotonicClock,
    RetryPolicy,
    RetryRng,
    SplitMix64Rng,
    parse_gcp_status,
)

struct FixedRng(RetryRng, Movable, Deinitable):
    var value: UInt64

    def __init__(out self, value: UInt64):
        self.value = value

    def next_u64(mut self) -> UInt64:
        return self.value


struct FakeClock(Clock, Movable, Deinitable):
    var now: Int64
    var sleeps: List[Int64]

    def __init__(out self, start: Int64 = 1_000_000):
        self.now = start
        self.sleeps = List[Int64]()

    def now_ms(mut self) -> Int64:
        return self.now

    def sleep_ms(mut self, ms: Int64):
        self.sleeps.append(ms)
        self.now += ms


def _drive[K: Clock, R: RetryRng](
    statuses: List[Int],
    names: List[String],
    policy: RetryPolicy,
    mut clock: K,
    mut rng: R,
    mut sends: Int,
) raises -> Int:
    """Send until 2xx or `policy` stops; returns the last HTTP status. The
    i-th send answers `statuses[i]` (the last one repeats) with an envelope
    naming `names[i]` (none when empty)."""
    var started = clock.now_ms()
    while True:
        var i = min(sends, len(statuses) - 1)
        sends += 1
        if statuses[i] >= 200 and statuses[i] < 300:
            return statuses[i]
        var body = List[UInt8]()
        if names[i].byte_length() > 0:
            var s = String('{"error": {"status": "') + names[i] + '"}}'
            for b in s.as_bytes():
                body.append(b)
        var code = parse_gcp_status("GET", String(), statuses[i], body).code()
        var d = policy.decide(code, sends, clock.now_ms() - started, rng)
        if not d.retry:
            return statuses[i]
        clock.sleep_ms(d.delay_ms)

comptime _MAX_U64: UInt64 = 0xFFFFFFFFFFFFFFFF


def test_default_retryable_set_is_unavailable_only() raises:
    var p = RetryPolicy()
    var rng = FixedRng(0)
    # The whole google.rpc.Code range: only UNAVAILABLE (14) retries.
    for code in range(CODE_UNAUTHENTICATED + 1):
        var d = p.decide(code, 1, 0, rng)
        if code == CODE_UNAVAILABLE:
            assert_true(d.retry)
            continue
        assert_false(d.retry, String("retried code ") + String(code))
        assert_true(d.reason.find("not retryable") >= 0)


def test_must_never_codes_cannot_be_added() raises:
    var p = RetryPolicy()
    for code in [CODE_OK, CODE_CANCELLED, CODE_DEADLINE_EXCEEDED, CODE_INVALID_ARGUMENT, CODE_DATA_LOSS, 17, -1]:
        var raised = False
        try:
            p.also_retry(code)
        except:
            raised = True
        assert_true(raised, String("accepted code ") + String(code))
    p.also_retry(CODE_RESOURCE_EXHAUSTED)
    var rng = FixedRng(0)
    assert_true(p.decide(CODE_RESOURCE_EXHAUSTED, 1, 0, rng).retry)


def test_backoff_caps_grow_then_clamp() raises:
    var p = RetryPolicy()  # 1 s, x2, max 10 s
    assert_equal(p.backoff_cap_ms(1), 1000)
    assert_equal(p.backoff_cap_ms(2), 2000)
    assert_equal(p.backoff_cap_ms(3), 4000)
    assert_equal(p.backoff_cap_ms(4), 8000)
    assert_equal(p.backoff_cap_ms(5), 10_000)
    assert_equal(p.backoff_cap_ms(60), 10_000)


def test_jitter_spans_zero_to_cap() raises:
    var p = RetryPolicy()
    var lo = FixedRng(0)
    var hi = FixedRng(_MAX_U64)
    for n in range(1, 8):
        assert_equal(p.jittered_delay_ms(n, lo), 0)
        assert_equal(p.jittered_delay_ms(n, hi), p.backoff_cap_ms(n))
    var rng = SplitMix64Rng(42)
    var distinct = 0
    var prev = Int64(-1)
    for i in range(1000):
        var n = 1 + i % 6
        var d = p.jittered_delay_ms(n, rng)
        assert_true(d >= 0 and d <= p.backoff_cap_ms(n))
        if d != prev:
            distinct += 1
        prev = d
    assert_true(distinct > 900)


def test_attempt_limit_and_deadline() raises:
    var p = RetryPolicy(max_attempts=3, deadline_ms=5000)
    var hi = FixedRng(_MAX_U64)
    assert_true(p.decide(CODE_UNAVAILABLE, 2, 0, hi).retry)
    var d = p.decide(CODE_UNAVAILABLE, 3, 0, hi)
    assert_false(d.retry)
    assert_true(d.reason.find("gave up after 3 attempts") >= 0)
    # Second retry waits up to 2000 ms; at 3500 ms elapsed that ends past 5000.
    var late = p.decide(CODE_UNAVAILABLE, 2, 3500, hi)
    assert_false(late.retry)
    assert_true(late.reason.find("deadline") >= 0)
    var lo = FixedRng(0)
    assert_true(p.decide(CODE_UNAVAILABLE, 2, 3500, lo).retry)


def test_policy_refuses_nonsense() raises:
    var cases = 0
    try:
        _ = RetryPolicy(initial_delay_ms=-1)
    except:
        cases += 1
    try:
        _ = RetryPolicy(initial_delay_ms=500, max_delay_ms=100)
    except:
        cases += 1
    try:
        _ = RetryPolicy(multiplier=0.5)
    except:
        cases += 1
    try:
        _ = RetryPolicy(max_attempts=0)
    except:
        cases += 1
    try:
        _ = RetryPolicy(deadline_ms=0)
    except:
        cases += 1
    assert_equal(cases, 5)


def test_retry_loop_sleeps_on_the_injected_clock() raises:
    var clock = FakeClock()
    var rng = FixedRng(_MAX_U64)
    var sends = 0
    var status = _drive([503, 503, 200], ["UNAVAILABLE", "", ""], RetryPolicy(), clock, rng, sends)
    assert_equal(status, 200)
    assert_equal(sends, 3)
    assert_equal(len(clock.sleeps), 2)
    assert_equal(clock.sleeps[0], 1000)
    assert_equal(clock.sleeps[1], 2000)


def test_retry_loop_returns_a_non_retryable_failure_at_once() raises:
    var clock = FakeClock()
    var rng = FixedRng(0)
    var sends = 0
    var status = _drive([403], ["PERMISSION_DENIED"], RetryPolicy(), clock, rng, sends)
    assert_equal(status, 403)
    assert_equal(sends, 1)
    assert_equal(len(clock.sleeps), 0)
    # A 503 the envelope labels INVALID_ARGUMENT is not retried either.
    var sends2 = 0
    _ = _drive([503], ["INVALID_ARGUMENT"], RetryPolicy(), clock, rng, sends2)
    assert_equal(sends2, 1)


def test_retry_loop_stops_at_max_attempts() raises:
    var clock = FakeClock()
    var rng = FixedRng(0)
    var sends = 0
    var status = _drive([503], [""], RetryPolicy(max_attempts=4), clock, rng, sends)
    assert_equal(status, 503)
    assert_equal(sends, 4)
    assert_equal(len(clock.sleeps), 3)


def test_retry_loop_honours_the_deadline() raises:
    # Retry 1 waits 1000 ms (0 + 1000 < 2500); retry 2 would wait 2000 ms
    # from 1000 ms elapsed, which passes the 2500 ms deadline: stop at 2 sends.
    var clock = FakeClock()
    var rng = FixedRng(_MAX_U64)
    var sends = 0
    var status = _drive([503], [""], RetryPolicy(deadline_ms=2500), clock, rng, sends)
    assert_equal(status, 503)
    assert_equal(sends, 2)
    assert_equal(len(clock.sleeps), 1)
    assert_equal(clock.sleeps[0], 1000)


def test_split_mix64_reference_vector() raises:
    # Seed 0, first three outputs of the reference splitmix64.c implementation.
    var rng = SplitMix64Rng(0)
    assert_equal(rng.next_u64(), UInt64(0xE220A8397B1DCDAF))
    assert_equal(rng.next_u64(), UInt64(0x6E789E6AA1B965F4))
    assert_equal(rng.next_u64(), UInt64(0x06C45D188009454F))


def test_monotonic_clock_is_milliseconds_and_sleeps() raises:
    # The production clock behind token expiry and retry deadlines: now_ms is
    # in MILLISECONDS and sleep_ms really waits. The lower bound is exact; the
    # upper bound only has to rule out a micro- or nanosecond unit.
    var clock = MonotonicClock()
    var before = clock.now_ms()
    clock.sleep_ms(50)
    var delta = clock.now_ms() - before
    assert_true(delta >= 50, String("slept ") + String(delta) + " ms")
    assert_true(delta <= 5000, String("slept ") + String(delta) + " ms")
    # A non-positive sleep returns at once.
    var t0 = clock.now_ms()
    clock.sleep_ms(0)
    clock.sleep_ms(-5)
    assert_true(clock.now_ms() - t0 < 1000)


def main() raises:
    test_default_retryable_set_is_unavailable_only()
    test_must_never_codes_cannot_be_added()
    test_backoff_caps_grow_then_clamp()
    test_jitter_spans_zero_to_cap()
    test_attempt_limit_and_deadline()
    test_policy_refuses_nonsense()
    test_retry_loop_sleeps_on_the_injected_clock()
    test_retry_loop_returns_a_non_retryable_failure_at_once()
    test_retry_loop_stops_at_max_attempts()
    test_retry_loop_honours_the_deadline()
    test_split_mix64_reference_vector()
    test_monotonic_clock_is_milliseconds_and_sleeps()
    print("all gcp retry tests passed")
