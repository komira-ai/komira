# =============================================================================
# komira_retry/loop.mojo -- the loop between sends, without closures.
# =============================================================================
#
#     var loop = system_retry_loop(policy)
#     loop.start()
#     while True:
#         <send>
#         if <ok>:
#             loop.after_success(budget)
#             break
#         var d = loop.after_failure(classifier.classify(outcome), budget)
#         if not d.retry:
#             <fail with d.reason>
#
# `after_failure` asks `RetryPolicy.decide`, spends the retry's cost from the
# budget, sleeps the decided wait, and counts the next send. Elapsed time is
# read from the clock at each failure, so time spent sending counts against
# the deadline as well as time spent waiting.
#
# The classifier is the only per-protocol part: an HTTP client maps a status
# and `Retry-After` to a `Verdict`, a gRPC/GCP client a google.rpc.Code and
# RetryInfo, an AWS client an error code. None of that lives here.
# =============================================================================

from .seams import (
    MonotonicClock,
    Sleeper,
    RetryRng,
    SystemClock,
    SystemSleeper,
    SplitMix64Rng,
)
from .policy import Decision, RetryPolicy, Verdict
from .budget import RetryBudget, NoBudget


trait RetryClassifier:
    """Reads one failed attempt's outcome as a `Verdict`. `Outcome` is the
    client's own failure type (a response, a status, an error)."""

    comptime Outcome: AnyType

    def classify(self, outcome: Self.Outcome) -> Verdict:
        ...


struct RetryLoop[K: MonotonicClock, S: Sleeper, R: RetryRng](Movable, Deinitable):
    var policy: RetryPolicy
    var _clock: Self.K
    var _sleeper: Self.S
    var _rng: Self.R
    var _started: Bool
    var _start_ms: Int64
    var _attempts: Int
    var _last_cost: Int

    def __init__(
        out self, var policy: RetryPolicy, var clock: Self.K, var sleeper: Self.S, var rng: Self.R
    ):
        self.policy = policy^
        self._clock = clock^
        self._sleeper = sleeper^
        self._rng = rng^
        self._started = False
        self._start_ms = 0
        self._attempts = 0
        self._last_cost = 0

    def start(mut self):
        """Call just before the first send. A loop may be started again for
        the next call."""
        self._started = True
        self._start_ms = self._clock.now_ms()
        self._attempts = 1
        self._last_cost = 0

    def attempts(self) -> Int:
        """Sends made or in flight in this call, the first included."""
        return self._attempts

    def elapsed_ms(mut self) -> Int64:
        return self._clock.now_ms() - self._start_ms

    def after_failure[B: RetryBudget](mut self, verdict: Verdict, mut budget: B) raises -> Decision:
        """The last send failed as `verdict`. On a retry decision this has
        already slept; send again. Otherwise stop with `reason`."""
        if not self._started:
            raise Error("RetryLoop.after_failure: start() was not called")
        var elapsed = self.elapsed_ms()
        var d = self.policy.decide(self._attempts, elapsed, verdict, self._rng)
        if not d.retry:
            return d^
        if not budget.try_spend(d.cost):
            return Decision.give_up(
                String("retry budget exhausted (a retry costs ") + String(d.cost) + "): "
                + verdict.reason
            )
        self._last_cost = d.cost
        self._sleeper.sleep_ms(d.delay_ms)
        self._attempts += 1
        return d^

    def after_failure(mut self, verdict: Verdict) raises -> Decision:
        """As above, with no budget."""
        var none = NoBudget()
        return self.after_failure(verdict, none)

    def after_outcome[C: RetryClassifier, B: RetryBudget](
        mut self, classifier: C, outcome: C.Outcome, mut budget: B
    ) raises -> Decision:
        """`after_failure` on what `classifier` makes of `outcome`."""
        return self.after_failure(classifier.classify(outcome), budget)

    def after_success[B: RetryBudget](mut self, mut budget: B):
        """The last send succeeded: refill the budget."""
        budget.on_success(self._last_cost)
        self._started = False

    def clock(ref self) -> ref [self._clock] Self.K:
        return self._clock

    def sleeper(ref self) -> ref [self._sleeper] Self.S:
        return self._sleeper

    def rng(ref self) -> ref [self._rng] Self.R:
        return self._rng


def system_retry_loop(
    var policy: RetryPolicy,
) -> RetryLoop[SystemClock, SystemSleeper, SplitMix64Rng]:
    """A loop on the process's monotonic clock, blocking sleeps and a
    clock-seeded jitter source."""
    return RetryLoop[SystemClock, SystemSleeper, SplitMix64Rng](
        policy^, SystemClock(), SystemSleeper(), SplitMix64Rng.seeded_from_clock()
    )
