# =============================================================================
# komira_gcp_core/retry.mojo — which Google API failures to retry.
# =============================================================================
#
# The retry MECHANISM (backoff and jitter, attempt limit, call deadline,
# server-delay limit, budget, the send/classify/sleep loop) is komira_retry's.
# This file holds only the Google part, `GcpRetryClassifier`, which turns a
# `GcpStatusError` into a komira_retry `Verdict`:
#
# WHICH (AIP-194, "Automatic retry configuration"): a client should retry only
# UNAVAILABLE, and must never retry OK, CANCELLED, DEADLINE_EXCEEDED,
# INVALID_ARGUMENT or DATA_LOSS. The classifier retries UNAVAILABLE by
# default; a caller that knows a method is safe to retry on another code
# (e.g. RESOURCE_EXHAUSTED for an idempotent read) may add it, and adding a
# must-never code is refused. RESOURCE_EXHAUSTED, when added, is a THROTTLED
# verdict (quota or load), every other retryable code a transient one.
#
# SERVER DELAY: a `google.rpc.RetryInfo` detail's `retryDelay`
# (`GcpStatusError.retry_delay_ms`) becomes the verdict's server delay, so
# komira_retry waits at least that long, or gives up if it is over the
# policy's `max_server_delay_ms`.
#
# `gcp_retry_policy` is a komira_retry `RetryPolicy` with the example values
# of AIP-4221 (initial 1 s, multiplier 2, max 10 s) and full jitter, as
# gRPC's retry design (proposal A6) states it.
#
# A transport FAULT (the connector raised) is not a status and is not
# classified here: whether the request reached the server is the
# transport's knowledge, and resending a non-idempotent request that did
# arrive is not safe.
# =============================================================================

from komira_retry import Backoff, Jitter, RetryClassifier, RetryPolicy, Verdict

from komira_gcp_core.status import (
    CODE_OK,
    CODE_CANCELLED,
    CODE_DEADLINE_EXCEEDED,
    CODE_INVALID_ARGUMENT,
    CODE_DATA_LOSS,
    CODE_RESOURCE_EXHAUSTED,
    CODE_UNAVAILABLE,
    GcpStatusError,
    code_name,
)


def _never_retry(code: Int) -> Bool:
    """The codes AIP-194 says must never be retried."""
    return (
        code == CODE_OK
        or code == CODE_CANCELLED
        or code == CODE_DEADLINE_EXCEEDED
        or code == CODE_INVALID_ARGUMENT
        or code == CODE_DATA_LOSS
    )


struct GcpRetryClassifier(RetryClassifier, Copyable, Movable, Deinitable):
    """AIP-194's retryable `google.rpc.Code` set, as a komira_retry
    classifier over `GcpStatusError`."""

    comptime Outcome = GcpStatusError

    var _retryable: List[Int]

    def __init__(out self):
        self._retryable = [CODE_UNAVAILABLE]

    def also_retry(mut self, code: Int) raises:
        """Retry `code` too. Refuses a code AIP-194 says must never be
        retried, and a value that is not a `google.rpc.Code`."""
        if code_name(code).byte_length() == 0:
            raise Error(String("GcpRetryClassifier: ") + String(code) + " is not a google.rpc.Code")
        if _never_retry(code):
            raise Error(
                String("GcpRetryClassifier: ") + code_name(code)
                + " must never be retried (AIP-194)"
            )
        if not self.is_retryable(code):
            self._retryable.append(code)

    def is_retryable(self, code: Int) -> Bool:
        for c in self._retryable:
            if c == code:
                return True
        return False

    def classify_code(self, code: Int, server_delay_ms: Int64 = -1) -> Verdict:
        """The verdict for a failure with canonical `code`, the server having
        asked for `server_delay_ms` (-1: no RetryInfo)."""
        if not self.is_retryable(code):
            return Verdict.stop(code_name(code) + " is not retryable under this policy")
        if code == CODE_RESOURCE_EXHAUSTED:
            return Verdict.throttle(code_name(code), server_delay_ms)
        return Verdict.transient(code_name(code), server_delay_ms)

    def classify(self, outcome: GcpStatusError) -> Verdict:
        return self.classify_code(outcome.code(), outcome.retry_delay_ms)


def gcp_retry_policy(
    max_attempts: Int = 5,
    deadline_ms: Int64 = 60_000,
    max_server_delay_ms: Int64 = 60_000,
) raises -> RetryPolicy:
    """A komira_retry policy with AIP-4221's example backoff (1 s, x2, max
    10 s, full jitter). Refuses what komira_retry refuses."""
    return RetryPolicy(
        Backoff(initial_ms=1000, multiplier=2.0, max_ms=10_000, jitter=Jitter.full()),
        max_attempts=max_attempts,
        deadline_ms=deadline_ms,
        max_server_delay_ms=max_server_delay_ms,
    )
