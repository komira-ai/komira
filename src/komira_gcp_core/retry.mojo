# =============================================================================
# komira_gcp_core/retry.mojo — which failures to retry, and when.
# =============================================================================
#
# WHICH (AIP-194, "Automatic retry configuration"): a client should retry only
# UNAVAILABLE, and must never retry OK, CANCELLED, DEADLINE_EXCEEDED,
# INVALID_ARGUMENT or DATA_LOSS. `RetryPolicy` retries UNAVAILABLE by default;
# a caller that knows a method is safe to retry on another code (e.g.
# RESOURCE_EXHAUSTED for an idempotent read) may add it, and adding a
# must-never code is refused.
#
# WHEN: exponential backoff with full jitter, as gRPC's retry design states it
# (gRPC proposal A6, "Retry Policy"): the n-th retry waits a uniformly random
# time in [0, min(initial * multiplier^(n-1), max)]. The defaults are the
# example values of AIP-4221 (initial 1 s, multiplier 2, max 10 s). A retry is
# not started if its wait would end past the call's deadline.
#
# The random source is injected (`RetryRng`) and the elapsed time is an
# argument, so a test pins every delay and never sleeps. `decide` is pure:
# this package owns no transport. The one transport seam is komira_http's
# `Connector`; the loop that sends, asks `decide`, and sleeps on an injected
# `Clock` belongs with the token sources and generated callers that run over
# it. A transport FAULT (the connector raised) is not a status and is not
# classified here: whether the request reached the server is the transport's
# knowledge, and resending a non-idempotent request that did arrive is not
# safe.
# =============================================================================

from komira_gcp_core.status import (
    CODE_OK,
    CODE_CANCELLED,
    CODE_DEADLINE_EXCEEDED,
    CODE_INVALID_ARGUMENT,
    CODE_DATA_LOSS,
    CODE_UNAVAILABLE,
    code_name,
)


trait RetryRng(Movable, Deinitable):
    """A source of uniformly distributed 64-bit values for jitter."""

    def next_u64(mut self) -> UInt64:
        ...


struct SplitMix64Rng(RetryRng, Movable, Deinitable):
    """SplitMix64 (Steele, Lea, Flood 2014): a small, fast generator that is
    plenty for spreading retries apart. Not a CSPRNG, and not used as one."""

    var _state: UInt64

    def __init__(out self, seed: UInt64):
        self._state = seed

    def next_u64(mut self) -> UInt64:
        self._state += UInt64(0x9E3779B97F4A7C15)
        var z = self._state
        z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> 31)


@fieldwise_init
struct RetryDecision(Copyable, Movable, Deinitable):
    """Whether to retry, after how long, and why (for a diagnostic)."""

    var retry: Bool
    var delay_ms: Int64
    var reason: String


def _never_retry(code: Int) -> Bool:
    """The codes AIP-194 says must never be retried."""
    return (
        code == CODE_OK
        or code == CODE_CANCELLED
        or code == CODE_DEADLINE_EXCEEDED
        or code == CODE_INVALID_ARGUMENT
        or code == CODE_DATA_LOSS
    )


struct RetryPolicy(Copyable, Movable, Deinitable):
    """Retryable codes, backoff shape, attempt limit and overall deadline.

    `max_attempts` counts every send, the first included; `deadline_ms` is
    measured from the first send."""

    var initial_delay_ms: Int64
    var multiplier: Float64
    var max_delay_ms: Int64
    var max_attempts: Int
    var deadline_ms: Int64
    var _retryable: List[Int]

    def __init__(
        out self,
        initial_delay_ms: Int64 = 1000,
        multiplier: Float64 = 2.0,
        max_delay_ms: Int64 = 10_000,
        max_attempts: Int = 5,
        deadline_ms: Int64 = 60_000,
    ) raises:
        if initial_delay_ms < 0 or max_delay_ms < initial_delay_ms:
            raise Error(
                String("RetryPolicy: need 0 <= initial_delay_ms <= max_delay_ms, got ")
                + String(initial_delay_ms) + " and " + String(max_delay_ms)
            )
        if multiplier < 1.0:
            raise Error(String("RetryPolicy: multiplier must be >= 1, got ") + String(multiplier))
        if max_attempts < 1:
            raise Error(String("RetryPolicy: max_attempts must be >= 1, got ") + String(max_attempts))
        if deadline_ms <= 0:
            raise Error(String("RetryPolicy: deadline_ms must be > 0, got ") + String(deadline_ms))
        self.initial_delay_ms = initial_delay_ms
        self.multiplier = multiplier
        self.max_delay_ms = max_delay_ms
        self.max_attempts = max_attempts
        self.deadline_ms = deadline_ms
        self._retryable = [CODE_UNAVAILABLE]

    def also_retry(mut self, code: Int) raises:
        """Retry `code` too. Refuses a code AIP-194 says must never be retried,
        and a value that is not a `google.rpc.Code`."""
        if code_name(code).byte_length() == 0:
            raise Error(String("RetryPolicy: ") + String(code) + " is not a google.rpc.Code")
        if _never_retry(code):
            raise Error(
                String("RetryPolicy: ") + code_name(code)
                + " must never be retried (AIP-194)"
            )
        if not self.is_retryable(code):
            self._retryable.append(code)

    def is_retryable(self, code: Int) -> Bool:
        for c in self._retryable:
            if c == code:
                return True
        return False

    def backoff_cap_ms(self, retry_number: Int) -> Int64:
        """The upper bound of the wait before retry `retry_number` (1-based):
        min(initial * multiplier^(retry_number-1), max)."""
        var cap = Float64(self.initial_delay_ms)
        var limit = Float64(self.max_delay_ms)
        for _ in range(1, retry_number):
            cap *= self.multiplier
            if cap >= limit:
                return self.max_delay_ms
        return min(Int64(cap), self.max_delay_ms)

    def jittered_delay_ms[R: RetryRng](self, retry_number: Int, mut rng: R) -> Int64:
        """A uniform draw from [0, backoff_cap_ms(retry_number)]."""
        var cap = self.backoff_cap_ms(retry_number)
        if cap <= 0:
            return 0
        # 53 random bits -> [0, 1).
        var unit = Float64(rng.next_u64() >> 11) * (1.0 / 9007199254740992.0)
        var d = Int64(unit * Float64(cap + 1))
        return min(d, cap)

    def decide[R: RetryRng](
        self, code: Int, attempts_made: Int, elapsed_ms: Int64, mut rng: R
    ) -> RetryDecision:
        """After `attempts_made` sends, the last failing with `code`, at
        `elapsed_ms` since the first send: retry, and after how long?"""
        if not self.is_retryable(code):
            return RetryDecision(
                False, 0, code_name(code) + " is not retryable under this policy"
            )
        if attempts_made >= self.max_attempts:
            return RetryDecision(
                False, 0,
                String("gave up after ") + String(attempts_made) + " attempts",
            )
        var delay = self.jittered_delay_ms(attempts_made, rng)
        if elapsed_ms + delay >= self.deadline_ms:
            return RetryDecision(
                False, 0,
                String("the next retry would pass the ")
                + String(self.deadline_ms) + " ms deadline",
            )
        return RetryDecision(
            True, delay, String("retrying ") + code_name(code)
        )

