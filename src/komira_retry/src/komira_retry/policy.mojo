# =============================================================================
# komira_retry/policy.mojo -- when to retry and how long to wait.
# =============================================================================
#
# BACKOFF. The wait before retry n (n = sends made so far, so 1 before the
# first retry) is drawn around cap(n) = min(initial * multiplier^(n-1), max):
#   FULL jitter  -- uniform in [0, cap(n)], as in gRPC's retry design (A6)
#                   and the AWS SDKs' standard mode.
#   BAND(pct)    -- uniform in [cap(n) - pct%, cap(n) + pct%], clamped to
#                   [0, max]; spreads retries while keeping the curve's shape.
#
# SERVER DELAY. A classifier that read a server's own wait (HTTP
# `Retry-After`, google.rpc.RetryInfo) reports it on the `Verdict`; the loop
# waits max(backoff, server delay). A server delay longer than the policy's
# `max_server_delay_ms` gives up rather than wait that long.
#
# LIMITS. `max_attempts` counts every send, the first included. A retry is
# not started if its wait would end at or past `deadline_ms`, measured from
# the first send, so the loop never sleeps past the deadline.
#
# `decide` is pure apart from drawing from the injected random source; the
# retry budget is spent by the loop (loop.mojo), not here.
#
# BOUNDS. `max_ms` and `max_server_delay_ms` are refused above MAX_WAIT_MS
# (2^40 ms, about 35 years), so jitter arithmetic and `elapsed + wait` stay
# far inside Int64 and can never wrap to a negative wait.
# =============================================================================

from std.math import isinf

from .seams import RetryRng

# The budget a retry spends when the classifier does not choose, for a
# transient and a throttled verdict alike (TokenBucket, budget.mojo). This is
# botocore's standard-mode retry quota: RetryQuotaChecker charges
# _RETRY_COST = 5 of 500 for every retryable error, throttling included.
# Any other cost is a client's semantics, so its classifier sets
# `Verdict.cost` itself (botocore charges a timeout 10; that number belongs in
# an AWS classifier, not here).
comptime DEFAULT_RETRY_COST: Int = 5

# The largest `max_ms` / `max_server_delay_ms` accepted (see BOUNDS).
comptime MAX_WAIT_MS: Int64 = 1 << 40

# 2^53: 53 random bits make a Float64 in [0, 1) with no rounding.
comptime _TWO_POW_53: Float64 = 9007199254740992.0


struct Jitter(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """FULL (uniform in [0, cap]) or BAND(pct) (cap +/- pct percent)."""

    # -1 = FULL; 0..100 = BAND with that percentage.
    var _band_pct: Int

    def __init__(out self, *, _band_pct: Int):
        self._band_pct = _band_pct

    @staticmethod
    def full() -> Jitter:
        return Jitter(_band_pct=-1)

    @staticmethod
    def band(pct: Int) raises -> Jitter:
        """Refuses a percentage outside [0, 100]. BAND(0) is no jitter."""
        if pct < 0 or pct > 100:
            raise Error(
                String("Jitter.band: pct must be in [0, 100], got ") + String(pct)
            )
        return Jitter(_band_pct=pct)

    def is_full(self) -> Bool:
        return self._band_pct < 0

    def band_pct(self) -> Int:
        """The band percentage; -1 for FULL."""
        return self._band_pct


struct Backoff(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Exponential backoff: initial wait, growth factor, cap, jitter."""

    var initial_ms: Int64
    var multiplier: Float64
    var max_ms: Int64
    var jitter: Jitter

    def __init__(
        out self,
        initial_ms: Int64 = 1000,
        multiplier: Float64 = 2.0,
        max_ms: Int64 = 20_000,
        jitter: Jitter = Jitter.full(),
    ) raises:
        if initial_ms < 0 or max_ms < initial_ms:
            raise Error(
                String("Backoff: need 0 <= initial_ms <= max_ms, got ")
                + String(initial_ms) + " and " + String(max_ms)
            )
        if max_ms > MAX_WAIT_MS:
            raise Error(
                String("Backoff: max_ms must be <= ") + String(MAX_WAIT_MS) + ", got "
                + String(max_ms)
            )
        # Written so that NaN is refused too.
        if not (multiplier >= 1.0):
            raise Error(String("Backoff: multiplier must be >= 1, got ") + String(multiplier))
        # +inf passes the test above; 0 * inf would make the cap NaN.
        if isinf(multiplier):
            raise Error(String("Backoff: multiplier must be finite, got ") + String(multiplier))
        self.initial_ms = initial_ms
        self.multiplier = multiplier
        self.max_ms = max_ms
        self.jitter = jitter

    def cap_ms(self, n: Int) -> Int64:
        """min(initial * multiplier^(n-1), max) for retry n >= 1 (0 for n < 1)."""
        if n < 1:
            return 0
        var cap = Float64(self.initial_ms)
        var limit = Float64(self.max_ms)
        for _ in range(1, n):
            cap *= self.multiplier
            if cap >= limit:
                return self.max_ms
        return min(Int64(cap), self.max_ms)

    def delay_ms[R: RetryRng](self, n: Int, mut rng: R) -> Int64:
        """The jittered wait before retry `n`. Draws exactly one value from
        `rng` when n >= 1, so a fixed seed pins every delay."""
        if n < 1:
            return 0
        var cap = self.cap_ms(n)
        var draw = rng.next_u64()
        if self.jitter.is_full():
            var unit = Float64(draw >> 11) * (1.0 / _TWO_POW_53)
            return min(Int64(unit * (Float64(cap) + 1.0)), cap)
        var band = cap * Int64(self.jitter.band_pct()) // 100
        if band == 0:
            return cap
        var roll = Int64(Int(draw % UInt64(Int(2 * band + 1))))
        var d = cap + roll - band
        if d < 0:
            return 0
        return min(d, self.max_ms)


struct Verdict(Copyable, Movable, Deinitable):
    """A classifier's reading of one failed attempt.

    `server_delay_ms` < 0 means the server named no wait. `cost` is what a
    retry spends from a `RetryBudget`; the classifier chooses it. The
    default, DEFAULT_RETRY_COST, is the same for a transient and a throttled
    verdict, as in botocore; an AWS classifier passes 10 for a timeout."""

    var retryable: Bool
    var throttled: Bool
    var server_delay_ms: Int64
    var cost: Int
    var reason: String

    def __init__(
        out self,
        *,
        retryable: Bool,
        throttled: Bool,
        server_delay_ms: Int64,
        cost: Int,
        var reason: String,
    ):
        self.retryable = retryable
        self.throttled = throttled
        self.server_delay_ms = server_delay_ms
        self.cost = cost
        self.reason = reason^

    @staticmethod
    def stop(var reason: String) -> Verdict:
        """Not retryable."""
        return Verdict(
            retryable=False, throttled=False, server_delay_ms=-1, cost=0, reason=reason^
        )

    @staticmethod
    def transient(
        var reason: String, server_delay_ms: Int64 = -1, cost: Int = DEFAULT_RETRY_COST
    ) -> Verdict:
        """Retryable: the failure is expected to pass."""
        return Verdict(
            retryable=True,
            throttled=False,
            server_delay_ms=server_delay_ms,
            cost=cost,
            reason=reason^,
        )

    @staticmethod
    def throttle(
        var reason: String, server_delay_ms: Int64 = -1, cost: Int = DEFAULT_RETRY_COST
    ) -> Verdict:
        """Retryable: the server refused for load or quota."""
        return Verdict(
            retryable=True,
            throttled=True,
            server_delay_ms=server_delay_ms,
            cost=cost,
            reason=reason^,
        )


@fieldwise_init
struct Decision(Copyable, Movable, Deinitable):
    """Retry or not, after how long, at what budget cost, and why."""

    var retry: Bool
    var delay_ms: Int64
    var cost: Int
    var reason: String

    @staticmethod
    def give_up(var reason: String) -> Decision:
        return Decision(False, 0, 0, reason^)


struct RetryPolicy(Copyable, Movable, Deinitable):
    """Backoff shape plus the limits on a call: attempts, total deadline and
    the longest server-requested wait honoured."""

    var backoff: Backoff
    var max_attempts: Int
    var deadline_ms: Int64
    var max_server_delay_ms: Int64

    def __init__(
        out self,
        backoff: Backoff,
        max_attempts: Int = 3,
        deadline_ms: Int64 = 60_000,
        max_server_delay_ms: Int64 = 60_000,
    ) raises:
        if max_attempts < 1:
            raise Error(String("RetryPolicy: max_attempts must be >= 1, got ") + String(max_attempts))
        if deadline_ms <= 0:
            raise Error(String("RetryPolicy: deadline_ms must be > 0, got ") + String(deadline_ms))
        if max_server_delay_ms < 0:
            raise Error(
                String("RetryPolicy: max_server_delay_ms must be >= 0, got ")
                + String(max_server_delay_ms)
            )
        if max_server_delay_ms > MAX_WAIT_MS:
            raise Error(
                String("RetryPolicy: max_server_delay_ms must be <= ") + String(MAX_WAIT_MS)
                + ", got " + String(max_server_delay_ms)
            )
        self.backoff = backoff
        self.max_attempts = max_attempts
        self.deadline_ms = deadline_ms
        self.max_server_delay_ms = max_server_delay_ms

    def decide[R: RetryRng](
        self, attempts_made: Int, elapsed_ms: Int64, verdict: Verdict, mut rng: R
    ) -> Decision:
        """After `attempts_made` sends (>= 1), the last failing as `verdict`,
        `elapsed_ms` after the first send: retry, and after how long?"""
        if attempts_made < 1:
            return Decision.give_up(
                String("decide: attempts_made must be >= 1, got ") + String(attempts_made)
            )
        if not verdict.retryable:
            return Decision.give_up(String("not retryable: ") + verdict.reason)
        if verdict.cost < 0:
            return Decision.give_up(
                String("classifier gave a negative cost (") + String(verdict.cost)
                + "): " + verdict.reason
            )
        if attempts_made >= self.max_attempts:
            return Decision.give_up(
                String("gave up after ") + String(attempts_made) + " attempts: " + verdict.reason
            )
        if verdict.server_delay_ms > self.max_server_delay_ms:
            return Decision.give_up(
                String("server asked to wait ") + String(verdict.server_delay_ms)
                + " ms, over the " + String(self.max_server_delay_ms) + " ms limit: "
                + verdict.reason
            )
        var delay = max(self.backoff.delay_ms(attempts_made, rng), verdict.server_delay_ms)
        if elapsed_ms + delay >= self.deadline_ms:
            return Decision.give_up(
                String("the next retry would pass the ") + String(self.deadline_ms)
                + " ms deadline: " + verdict.reason
            )
        var kind = String("throttled") if verdict.throttled else String("retrying")
        return Decision(
            True,
            delay,
            verdict.cost,
            kind + " after " + String(delay) + " ms: " + verdict.reason,
        )

