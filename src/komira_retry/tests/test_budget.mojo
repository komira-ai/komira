# TokenBucket: spending, exhaustion, refill on success (capped), and the
# budget as the RetryLoop spends it, where each verdict spends its own cost.

from komira_retry import (
    Backoff,
    Jitter,
    ManualClock,
    NoBudget,
    RecordingSleeper,
    RetryLoop,
    RetryPolicy,
    SplitMix64Rng,
    TokenBucket,
    Verdict,
)

from std.testing import assert_equal, assert_false, assert_true


def test_spend_and_exhaust() raises:
    var b = TokenBucket(capacity=12)
    assert_equal(b.available(), 12)
    assert_true(b.try_spend(5))
    assert_true(b.try_spend(5))
    assert_equal(b.available(), 2)
    # Less left than the cost: refused, and nothing is taken.
    assert_false(b.try_spend(5))
    assert_equal(b.available(), 2)
    assert_true(b.try_spend(2))
    assert_false(b.try_spend(1))
    assert_true(b.try_spend(0))
    assert_false(b.try_spend(-1))
    assert_equal(b.available(), 0)


def test_refill_on_success() raises:
    var b = TokenBucket(capacity=500)
    assert_true(b.try_spend(10))
    assert_true(b.try_spend(5))
    assert_equal(b.available(), 485)
    # Success after a retry gives back that retry's cost.
    b.on_success(5)
    assert_equal(b.available(), 490)
    # First-time success gives back success_refill (1).
    b.on_success(0)
    assert_equal(b.available(), 491)
    # Never above capacity.
    for _ in range(20):
        b.on_success(10)
    assert_equal(b.available(), 500)
    var r = TokenBucket(capacity=10, success_refill=3)
    assert_true(r.try_spend(10))
    r.on_success(0)
    assert_equal(r.available(), 3)


def test_no_budget() raises:
    var n = NoBudget()
    for _ in range(1000):
        assert_true(n.try_spend(1_000_000))


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    var p = RetryPolicy(
        Backoff(initial_ms=10, multiplier=1.0, max_ms=10, jitter=Jitter.band(0)),
        max_attempts=100,
        deadline_ms=1_000_000,
    )
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        p^, ManualClock(), RecordingSleeper(), SplitMix64Rng(1)
    )


def _retries_until_refused(verdict: Verdict, mut budget: TokenBucket) raises -> Int:
    var loop = _loop()
    loop.start()
    var retries = 0
    while True:
        var d = loop.after_failure(verdict, budget)
        if not d.retry:
            assert_true(d.reason.startswith("retry budget exhausted"), d.reason)
            break
        retries += 1
    # The refused retry neither slept nor counted a send.
    assert_equal(len(loop.sleeper().slept), retries)
    assert_equal(loop.attempts(), retries + 1)
    return retries


def test_each_verdict_spends_its_cost_in_the_loop() raises:
    # Default costs follow botocore: a throttle costs what any retry does.
    var for_transient = TokenBucket(capacity=30)
    var for_throttle = TokenBucket(capacity=30)
    assert_equal(_retries_until_refused(Verdict.transient("503"), for_transient), 6)
    assert_equal(_retries_until_refused(Verdict.throttle("429"), for_throttle), 6)
    assert_equal(for_transient.available(), 0)
    assert_equal(for_throttle.available(), 0)
    # A classifier's own cost (an AWS timeout: 10) drains it faster.
    var for_timeout = TokenBucket(capacity=30)
    assert_equal(_retries_until_refused(Verdict.transient("timeout", cost=10), for_timeout), 3)
    assert_equal(for_timeout.available(), 0)


def test_loop_refills_last_retry_cost() raises:
    var budget = TokenBucket(capacity=100)
    var loop = _loop()
    loop.start()
    _ = loop.after_failure(Verdict.transient("timeout", cost=10), budget)
    _ = loop.after_failure(Verdict.throttle("429"), budget)
    assert_equal(budget.available(), 85)
    loop.after_success(budget)
    # botocore semantics: the LAST retry's cost comes back, not the total.
    assert_equal(budget.available(), 90)
    # A call that succeeds first time refills 1.
    loop.start()
    loop.after_success(budget)
    assert_equal(budget.available(), 91)


def test_budget_is_shared_across_calls() raises:
    var budget = TokenBucket(capacity=10)
    var a = _loop()
    var b = _loop()
    a.start()
    b.start()
    assert_true(a.after_failure(Verdict.transient("x"), budget).retry)
    assert_true(b.after_failure(Verdict.transient("x"), budget).retry)
    # Each call alone could retry; together they have spent the budget.
    assert_false(a.after_failure(Verdict.transient("x"), budget).retry)
    assert_false(b.after_failure(Verdict.transient("x"), budget).retry)


def main() raises:
    test_spend_and_exhaust()
    test_refill_on_success()
    test_no_budget()
    test_each_verdict_spends_its_cost_in_the_loop()
    test_loop_refills_last_retry_cost()
    test_budget_is_shared_across_calls()
    print("test_budget: OK")
