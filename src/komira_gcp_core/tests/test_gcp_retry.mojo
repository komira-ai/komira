# =============================================================================
# test_gcp_retry.mojo — AIP-194 retry decisions over komira_retry.
# =============================================================================
#
# `GcpRetryClassifier` is the only retry code in komira_gcp_core; backoff,
# jitter, the attempt limit, the deadline and the loop are komira_retry's.
# These tests pin the GOOGLE claims (which codes retry, which may never be
# added, RetryInfo as the server delay, AIP-4221's backoff shape) end to end
# through komira_retry's `RetryPolicy.decide` and `RetryLoop`. Every clock
# and random draw is injected: `FixedRng` pins the jitter to the bottom or
# top of its range, `ManualClock` moves only when told and
# `RecordingSleeper` records waits, so the tests assert exact delays and
# never wait. (The SplitMix64 reference vector is komira_retry's own test.)
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_retry import (
    ManualClock,
    NoBudget,
    RecordingSleeper,
    RetryLoop,
    RetryPolicy,
    RetryRng,
    SplitMix64Rng,
)

from komira_gcp_core import (
    CODE_OK,
    CODE_CANCELLED,
    CODE_INVALID_ARGUMENT,
    CODE_DEADLINE_EXCEEDED,
    CODE_RESOURCE_EXHAUSTED,
    CODE_UNAVAILABLE,
    CODE_DATA_LOSS,
    CODE_UNAUTHENTICATED,
    GcpRetryClassifier,
    RETRY_INFO_TYPE,
    duration_to_ms,
    gcp_retry_policy,
    parse_gcp_status,
)


struct FixedRng(RetryRng, Movable, Deinitable):
    var value: UInt64

    def __init__(out self, value: UInt64):
        self.value = value

    def next_u64(mut self) -> UInt64:
        return self.value


comptime _MAX_U64: UInt64 = 0xFFFFFFFFFFFFFFFF
comptime GcpLoop = RetryLoop[ManualClock, RecordingSleeper, FixedRng]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _envelope(name: String, retry_delay: String = "") -> List[UInt8]:
    """An error envelope naming `name` (none when empty), with a RetryInfo
    detail asking for `retry_delay` when that is non-empty."""
    if name.byte_length() == 0 and retry_delay.byte_length() == 0:
        return List[UInt8]()
    var s = String('{"error": {')
    if name.byte_length() > 0:
        s += String('"status": "') + name + '"'
    if retry_delay.byte_length() > 0:
        if name.byte_length() > 0:
            s += ", "
        s += (
            String('"details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo"}, ')
            + '{"@type": "' + RETRY_INFO_TYPE + '", "retryDelay": "' + retry_delay + '"}]'
        )
    s += "}}"
    return _bytes(s)


def _drive(
    statuses: List[Int],
    names: List[String],
    classifier: GcpRetryClassifier,
    mut loop: GcpLoop,
    mut sends: Int,
) raises -> Int:
    """Send until 2xx or the loop stops; returns the last HTTP status. The
    i-th send answers `statuses[i]` (the last one repeats) with an envelope
    naming `names[i]` (none when empty). A retry's wait advances the clock,
    as a real sleep would."""
    loop.start()
    while True:
        var i = min(sends, len(statuses) - 1)
        sends += 1
        if statuses[i] >= 200 and statuses[i] < 300:
            var none = NoBudget()
            loop.after_success(none)
            return statuses[i]
        var err = parse_gcp_status("GET", String(), statuses[i], _envelope(names[i]))
        var d = loop.after_failure(classifier.classify(err))
        if not d.retry:
            return statuses[i]
        loop.clock().advance(d.delay_ms)


def test_default_retryable_set_is_unavailable_only() raises:
    var c = GcpRetryClassifier()
    var p = gcp_retry_policy()
    var rng = FixedRng(0)
    # The whole google.rpc.Code range: only UNAVAILABLE (14) retries.
    for code in range(CODE_UNAUTHENTICATED + 1):
        var d = p.decide(1, 0, c.classify_code(code), rng)
        if code == CODE_UNAVAILABLE:
            assert_true(d.retry)
            assert_false(c.classify_code(code).throttled)
            continue
        assert_false(d.retry, String("retried code ") + String(code))
        assert_true(d.reason.find("not retryable") >= 0, d.reason)


def test_must_never_codes_cannot_be_added() raises:
    var c = GcpRetryClassifier()
    for code in [CODE_OK, CODE_CANCELLED, CODE_DEADLINE_EXCEEDED, CODE_INVALID_ARGUMENT, CODE_DATA_LOSS, 17, -1]:
        var raised = False
        try:
            c.also_retry(code)
        except:
            raised = True
        assert_true(raised, String("accepted code ") + String(code))
    c.also_retry(CODE_RESOURCE_EXHAUSTED)
    var rng = FixedRng(0)
    var v = c.classify_code(CODE_RESOURCE_EXHAUSTED)
    assert_true(v.throttled, "RESOURCE_EXHAUSTED is a throttle")
    assert_true(gcp_retry_policy().decide(1, 0, v, rng).retry)


def test_backoff_caps_grow_then_clamp() raises:
    var b = gcp_retry_policy().backoff  # AIP-4221: 1 s, x2, max 10 s
    assert_equal(b.cap_ms(1), 1000)
    assert_equal(b.cap_ms(2), 2000)
    assert_equal(b.cap_ms(3), 4000)
    assert_equal(b.cap_ms(4), 8000)
    assert_equal(b.cap_ms(5), 10_000)
    assert_equal(b.cap_ms(60), 10_000)


def test_jitter_spans_zero_to_cap() raises:
    var b = gcp_retry_policy().backoff
    var lo = FixedRng(0)
    var hi = FixedRng(_MAX_U64)
    for n in range(1, 8):
        assert_equal(b.delay_ms(n, lo), 0)
        assert_equal(b.delay_ms(n, hi), b.cap_ms(n))
    var rng = SplitMix64Rng(42)
    var distinct = 0
    var prev = Int64(-1)
    for i in range(1000):
        var n = 1 + i % 6
        var d = b.delay_ms(n, rng)
        assert_true(d >= 0 and d <= b.cap_ms(n))
        if d != prev:
            distinct += 1
        prev = d
    assert_true(distinct > 900)


def test_attempt_limit_and_deadline() raises:
    var c = GcpRetryClassifier()
    var p = gcp_retry_policy(max_attempts=3, deadline_ms=5000)
    var hi = FixedRng(_MAX_U64)
    assert_true(p.decide(2, 0, c.classify_code(CODE_UNAVAILABLE), hi).retry)
    var d = p.decide(3, 0, c.classify_code(CODE_UNAVAILABLE), hi)
    assert_false(d.retry)
    assert_true(d.reason.find("gave up after 3 attempts") >= 0, d.reason)
    # Second retry waits up to 2000 ms; at 3500 ms elapsed that ends past 5000.
    var late = p.decide(2, 3500, c.classify_code(CODE_UNAVAILABLE), hi)
    assert_false(late.retry)
    assert_true(late.reason.find("deadline") >= 0, late.reason)
    var lo = FixedRng(0)
    assert_true(p.decide(2, 3500, c.classify_code(CODE_UNAVAILABLE), lo).retry)


def test_policy_refuses_nonsense() raises:
    var cases = 0
    try:
        _ = gcp_retry_policy(max_attempts=0)
    except:
        cases += 1
    try:
        _ = gcp_retry_policy(deadline_ms=0)
    except:
        cases += 1
    try:
        _ = gcp_retry_policy(max_server_delay_ms=-1)
    except:
        cases += 1
    assert_equal(cases, 3)


def test_retry_info_is_the_server_delay() raises:
    # A 503 whose envelope carries RetryInfo 3.5s: the status keeps the
    # number, the verdict carries it, and decide waits at least that long
    # even when the jittered backoff would be 0.
    var err = parse_gcp_status("GET", "S", 503, _envelope("UNAVAILABLE", "3.5s"))
    assert_equal(err.retry_delay_ms, 3500)
    assert_true(err.message().find("RetryInfo 3500 ms") >= 0, err.message())
    var c = GcpRetryClassifier()
    var v = c.classify(err)
    assert_true(v.retryable)
    assert_equal(v.server_delay_ms, 3500)
    var lo = FixedRng(0)
    var d = gcp_retry_policy().decide(1, 0, v, lo)
    assert_true(d.retry)
    assert_equal(d.delay_ms, 3500)
    # Asked for longer than max_server_delay_ms: give up instead of waiting.
    var long_err = parse_gcp_status("GET", "S", 503, _envelope("UNAVAILABLE", "120s"))
    var g = gcp_retry_policy().decide(1, 0, c.classify(long_err), lo)
    assert_false(g.retry)
    assert_true(g.reason.find("server asked to wait 120000 ms") >= 0, g.reason)
    # RetryInfo on a non-retryable code does not make it retryable.
    var denied = parse_gcp_status("GET", "S", 403, _envelope("PERMISSION_DENIED", "1s"))
    assert_false(c.classify(denied).retryable)
    # No RetryInfo: -1.
    assert_equal(parse_gcp_status("GET", "S", 503, _envelope("UNAVAILABLE")).retry_delay_ms, -1)


def test_throttle_keeps_the_retry_info_delay() raises:
    # Quota errors are where Google sends RetryInfo most. A 429
    # RESOURCE_EXHAUSTED made retryable with also_retry is a THROTTLE, and the
    # verdict must still carry the server's 3.5s, so decide waits that long
    # even when the jittered backoff would be 0.
    var c = GcpRetryClassifier()
    c.also_retry(CODE_RESOURCE_EXHAUSTED)
    var err = parse_gcp_status("GET", "S", 429, _envelope("RESOURCE_EXHAUSTED", "3.5s"))
    assert_equal(err.retry_delay_ms, 3500)
    var v = c.classify(err)
    assert_true(v.retryable)
    assert_true(v.throttled, "RESOURCE_EXHAUSTED is a throttle")
    assert_equal(v.server_delay_ms, 3500)
    var lo = FixedRng(0)
    var d = gcp_retry_policy().decide(1, 0, v, lo)
    assert_true(d.retry)
    assert_equal(d.delay_ms, 3500)


def test_duration_to_ms() raises:
    assert_equal(duration_to_ms("0s"), 0)
    assert_equal(duration_to_ms("1s"), 1000)
    assert_equal(duration_to_ms("1.5s"), 1500)
    assert_equal(duration_to_ms("0.000000001s"), 1)  # rounded up, never early
    assert_equal(duration_to_ms("2.0010s"), 2001)
    var bads: List[String] = [
        "", "s", "1", "-1s", "1.s", ".5s", "1.0000000001s", "1ms", "1.5 s", "+1s", "1e3s"
    ]
    for bad in bads:
        assert_equal(duration_to_ms(bad), -1, String("accepted ") + bad)
    # Absurdly many second digits clamp to a huge value (decide gives up).
    assert_true(duration_to_ms("99999999999999999999999s") > Int64(1) << 50)


def _loop(max_attempts: Int = 5, deadline_ms: Int64 = 60_000, rng: UInt64 = _MAX_U64) raises -> GcpLoop:
    return GcpLoop(
        gcp_retry_policy(max_attempts=max_attempts, deadline_ms=deadline_ms),
        ManualClock(1_000_000),
        RecordingSleeper(),
        FixedRng(rng),
    )


def test_retry_loop_sleeps_on_the_injected_sleeper() raises:
    var loop = _loop()
    var sends = 0
    var status = _drive([503, 503, 200], ["UNAVAILABLE", "", ""], GcpRetryClassifier(), loop, sends)
    assert_equal(status, 200)
    assert_equal(sends, 3)
    assert_equal(len(loop.sleeper().slept), 2)
    assert_equal(loop.sleeper().slept[0], 1000)
    assert_equal(loop.sleeper().slept[1], 2000)


def test_retry_loop_returns_a_non_retryable_failure_at_once() raises:
    var loop = _loop(rng=0)
    var sends = 0
    var status = _drive([403], ["PERMISSION_DENIED"], GcpRetryClassifier(), loop, sends)
    assert_equal(status, 403)
    assert_equal(sends, 1)
    assert_equal(len(loop.sleeper().slept), 0)
    # A 503 the envelope labels INVALID_ARGUMENT is not retried either.
    var loop2 = _loop(rng=0)
    var sends2 = 0
    _ = _drive([503], ["INVALID_ARGUMENT"], GcpRetryClassifier(), loop2, sends2)
    assert_equal(sends2, 1)


def test_retry_loop_stops_at_max_attempts() raises:
    var loop = _loop(max_attempts=4, rng=0)
    var sends = 0
    var status = _drive([503], [""], GcpRetryClassifier(), loop, sends)
    assert_equal(status, 503)
    assert_equal(sends, 4)
    assert_equal(len(loop.sleeper().slept), 3)


def test_retry_loop_honours_the_deadline() raises:
    # Retry 1 waits 1000 ms (0 + 1000 < 2500); retry 2 would wait 2000 ms
    # from 1000 ms elapsed, which passes the 2500 ms deadline: stop at 2 sends.
    var loop = _loop(deadline_ms=2500)
    var sends = 0
    var status = _drive([503], [""], GcpRetryClassifier(), loop, sends)
    assert_equal(status, 503)
    assert_equal(sends, 2)
    assert_equal(len(loop.sleeper().slept), 1)
    assert_equal(loop.sleeper().slept[0], 1000)


def main() raises:
    test_default_retryable_set_is_unavailable_only()
    test_must_never_codes_cannot_be_added()
    test_backoff_caps_grow_then_clamp()
    test_jitter_spans_zero_to_cap()
    test_attempt_limit_and_deadline()
    test_policy_refuses_nonsense()
    test_retry_info_is_the_server_delay()
    test_throttle_keeps_the_retry_info_delay()
    test_duration_to_ms()
    test_retry_loop_sleeps_on_the_injected_sleeper()
    test_retry_loop_returns_a_non_retryable_failure_at_once()
    test_retry_loop_stops_at_max_attempts()
    test_retry_loop_honours_the_deadline()
    print("all gcp retry tests passed")
