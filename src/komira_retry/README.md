# `komira_retry`

## Responsibility

When to retry a failed call and how long to wait first. It depends only on
the Mojo standard library.

It does not know which failures are worth retrying. That depends on the
protocol, so each client library writes a small `RetryClassifier` that turns
its own failure (an HTTP status and `Retry-After`, a `google.rpc.Code` and
`RetryInfo`, an AWS error code) into a `Verdict`. Status lists, gRPC codes,
idempotency rules and request replay all stay in the client libraries.

Keep this package small. It holds retry policy and the seams the retry loop
sleeps through, nothing else. A helper that is not about retrying belongs
somewhere else, even when the retry code uses it.

## API

| name | file | what it is |
|---|---|---|
| `MonotonicClock`, `Sleeper`, `RetryRng` | [seams.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/seams.mojo) | the injected time, wait and random-number seams |
| `SystemClock`, `SystemSleeper`, `SplitMix64Rng` | [seams.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/seams.mojo) | the real conformers (`std.time`; SplitMix64 is not a CSPRNG) |
| `ManualClock`, `RecordingSleeper` | [seams.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/seams.mojo) | test fakes: time moves only when told, sleeps are recorded and return at once |
| `Jitter`, `Backoff` | [policy.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/policy.mojo) | exponential backoff with FULL or BAND(pct) jitter |
| `Verdict` | [policy.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/policy.mojo) | a classifier's reading: retryable, throttled, server delay, budget cost, reason |
| `RetryPolicy`, `Decision` | [policy.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/policy.mojo) | the limits on a call, and the pure `decide` |
| `RetryBudget`, `NoBudget`, `TokenBucket` | [budget.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/budget.mojo) | an optional retry budget shared across calls |
| `RetryClassifier`, `RetryLoop`, `system_retry_loop` | [loop.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_retry/loop.mojo) | the classifier trait and the loop that sleeps between sends |

## Semantics

- **Attempts.** `max_attempts` counts every send, the first included, so
  `max_attempts = 1` means no retry.
- **Backoff.** Retry n (n = sends made so far) waits around
  `cap(n) = min(initial * multiplier^(n-1), max)`. FULL jitter draws
  uniformly from `[0, cap(n)]`; this is gRPC's retry design and the AWS
  SDKs' standard mode. BAND(pct) draws uniformly from `cap(n) +/- pct%`,
  clamped to `[0, max]`. Each retry draws exactly one random value.
- **Server delay.** The wait is `max(backoff, server delay)`. If the server
  asks for longer than `max_server_delay_ms`, the call gives up rather than
  wait.
- **Deadline.** `deadline_ms` is measured from the first send. A retry
  whose wait would end at or past it is not started, so the loop never
  sleeps past the deadline. Time spent sending counts as well, because the
  loop reads the clock at every failure.
- **Budget.** `TokenBucket` follows botocore's standard-mode retry quota:
  it starts full (500 by default), each retry spends its `Verdict.cost`, and
  a retry the bucket cannot pay for ends the call. A call that succeeds puts
  back the cost of its last retry, or 1 if it made no retry, never above
  capacity. If the classifier does not set a cost, a retry costs 5, transient
  and throttled alike, as botocore's `_RETRY_COST` does. Any other cost is
  the client's semantics and its classifier sets it: an AWS classifier
  passes 10 for a timeout, as botocore does.
  A budget is not thread-safe. Its owner decides how to share it.
- **Refusals.** A bad setting is refused when it is constructed, and the
  error names the setting: a negative or inverted backoff range, a
  multiplier below 1 (NaN included) or infinite, a jitter band outside
  `[0, 100]`, `max_attempts < 1`, `deadline_ms <= 0`, a negative
  server-delay limit, a `max_ms` or server-delay limit above `MAX_WAIT_MS`
  (2^40 ms, so no wait computation can overflow), or a negative bucket
  capacity or refill. A loop refuses `after_failure` before `start()`, and
  `after_success` ends the call, so the next call must `start()` again.

## Use

A client's classifier reads its own failure (here an HTTP-like status) as a
`Verdict`; the loop decides and sleeps between sends:

```mojo module
from komira_retry import Backoff, RetryClassifier, RetryPolicy, TokenBucket, Verdict, system_retry_loop
from std.testing import assert_equal


struct StatusClassifier(RetryClassifier):
    comptime Outcome = Int

    def __init__(out self):
        pass

    def classify(self, outcome: Int) -> Verdict:
        if outcome == 503:
            return Verdict.transient("503")
        return Verdict.stop(String(outcome))


def main() raises:
    var loop = system_retry_loop(RetryPolicy(Backoff(initial_ms=5, max_ms=50), max_attempts=4))
    var budget = TokenBucket()
    var sends = 0
    loop.start()
    while True:
        sends += 1
        var status = 503 if sends < 3 else 200  # the send: two 503s, then a success
        if status == 200:
            loop.after_success(budget)
            break
        var d = loop.after_outcome(StatusClassifier(), status, budget)
        if not d.retry:
            raise Error(d.reason)
    assert_equal(sends, 3)
```

If a decision says to retry, `after_failure` / `after_outcome` has already
slept.

A test builds `RetryLoop[ManualClock, RecordingSleeper, R]` with a fixed
random source. It advances the clock itself, by the time a send takes and by
each wait the loop asked for, and then reads `loop.sleeper().slept`. With no
jitter the waits are exactly the backoff caps:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_retry import Backoff, Jitter, ManualClock, RecordingSleeper, RetryLoop, RetryPolicy, SplitMix64Rng, Verdict

var policy = RetryPolicy(
    Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.band(0)),
    max_attempts=4,
)
var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
    policy^, ManualClock(), RecordingSleeper(), SplitMix64Rng(1)
)
loop.start()
while True:
    loop.clock().advance(10)  # the send took 10 ms and failed
    var d = loop.after_failure(Verdict.transient("503"))
    if not d.retry:
        break
    loop.clock().advance(d.delay_ms)
assert_equal(loop.attempts(), 4)
assert_equal(loop.sleeper().slept, [Int64(100), 200, 400])
```

A bad setting is refused when it is built, naming the setting:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_retry import Backoff

var message = String()
try:
    _ = Backoff(initial_ms=100, multiplier=0.5)
except e:
    message = String(e)
assert_equal(message, "Backoff: multiplier must be >= 1, got 0.5")
```

## Clock

`SystemClock` reads `std.time.perf_counter_ns`, and it stays on `std.time`:
komira_retry depends on nothing beyond the Mojo standard library, and on no
first-party package. If a shared monotonic clock is ever extracted, it becomes its own
small library, conforms to `MonotonicClock` there, and callers inject it into
`RetryLoop`. Nothing in this package changes and nothing here imports it.

## Tests

Every file in [tests/](https://github.com/komira-ai/komira/tree/main/src/komira_retry/tests) is welded to the package (`test_srcs`). The
package is published only if they all pass:

- `test_decide` covers the `decide` table.
- `test_backoff` covers the caps, both jitter modes under fixed random
  values, and SplitMix64's reference outputs.
- `test_budget` covers spending, exhaustion and refill.
- `test_refusals` covers every refused setting and the loop's call
  lifecycle.
- `test_loop` covers the loop's exact sleep sequence and attempt count, the
  deadline and the classifier hook.
- `test_system` covers the real seams: `SystemSleeper` sleeps, `SystemClock`
  reads milliseconds, and `system_retry_loop` runs end to end.
