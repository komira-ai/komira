"""`komira_grpc.retry` — the STATUS-CODE retry policy the generated clients
carry, and the pure decision functions that drive it.

# WHY THE POLICY IS EMITTED, NOT HAND-WRITTEN

A hand-written retry at one call site fixes one verb; the NEXT transient error
lands on a different one. So the policy is DERIVED from the proto model by the
code generator and emitted per method, and this module is the mechanism it
names. A single transient server error (for example `[grpc:13] The service has
encountered an internal error. Please try again later`) should not throw away a
long multi-step operation when the verb that met it is safe to replay.

# ⚠ IDEMPOTENCY IS THE HARD PART, AND IT DECIDES CORRECTNESS

Retrying a failed CREATE can produce TWO resources. A duplicate resource is a
worse outcome than a failed call. So the retry gate is NOT "is this error
transient" — it is "**is replaying this verb safe**", and only then "is this
error transient".

The idempotency signals available in a proto model:

  * `(google.protobuf.MethodOptions).idempotency_level` — the field that would
    state the answer outright — is rarely set in published Google APIs.
  * `(google.api.http)` is present on most of them, and its verb is a sound
    idempotency oracle: RFC 9110 §9.2.2 makes GET / PUT / DELETE idempotent
    and POST / PATCH not. That is the signal the derivation uses.
  * An rpc with NO http annotation has UNKNOWN idempotency and gets NO retry.
    Under-retrying is the safe direction; over-retrying duplicates resources.

# ⚠ THE RETRYABLE CODE SET IS ONE CODE, AND THAT IS NOT AN OVERSIGHT

AIP-194 ("Automatic retry configuration") names exactly ONE code as retryable:
`UNAVAILABLE` (14). Google's own shipped gapic config for Cloud Run —
`google/cloud/run/v2/run_grpc_service_config.json` — configures a retryPolicy on
`ListServices` and `GetService` ONLY, with `retryableStatusCodes:
["UNAVAILABLE"]`, `maxAttempts: 5`, `initialBackoff: 1s`, `maxBackoff: 10s`,
`backoffMultiplier: 1.3`. CreateService / UpdateService / DeleteService are
given `retryPolicy: null` — no retry at all.

So `INTERNAL` (13) is **not** in the default set, and a create verb is **not** a
verb Google retries. That is deliberate on Google's part and it is deliberate
here: INTERNAL carries no guarantee that the call did not land, and a
landed-then-retried create is two resources.

`RetryPolicy.internal_on_alreadyexists_guarded()` exists for the ONE situation
where INTERNAL becomes replayable: a create with a CLIENT-ASSIGNED id whose
caller already treats `ALREADY_EXISTS` as success (AIP-133). There the duplicate
is not a duplicate — it is the first attempt's own resource, observed. It is
OPT-IN at the call site, because only the call site can know it swallows the
409, and it is never emitted by codegen.

# BOUNDS

Exponential backoff with FULL JITTER (`sleep ~ U[0, cap]`, AWS's formulation),
a bounded attempt count, and a backoff cap. Full jitter rather than the
deterministic 1.3^n Google configures, because N concurrent callers that meet
the same backend blip enter backoff within milliseconds of each other and a
deterministic schedule re-synchronises them onto the same retry instant.
"""

from std.ffi import external_call
from std.time import perf_counter_ns

from komira_connect.status import (
    GRPC_STATUS_ABORTED,
    GRPC_STATUS_DEADLINE_EXCEEDED,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_UNAVAILABLE,
)

from .error import parse_grpc_status_code


# =============================================================================
# §1 — The retryable-code bitmask.
# =============================================================================
#
# gRPC status codes are 0..16, so the whole set fits in a UInt32 and the
# membership test is one shift + one AND. A mask rather than a List because the
# policy is a value the generated code constructs per call — it must be trivially
# Copyable and allocation-free.

comptime RETRY_CODE_MASK_EMPTY: UInt32 = 0
"""No code is retryable. The mask of `RetryPolicy.none()`."""


def retry_code_bit(code: UInt8) -> UInt32:
    """The single-bit mask for one gRPC status code. Codes above 31 (there are
    none — the enum stops at 16) yield 0, so an out-of-range code can never
    alias bit 0 (`OK`)."""
    if Int(code) > 31:
        return UInt32(0)
    return UInt32(1) << UInt32(Int(code))


def retry_mask_has(mask: UInt32, code: Int) -> Bool:
    """Is `code` a member of `mask`? A negative code (the `parse_grpc_status_code`
    "no `[grpc:` anchor" sentinel) is NOT a member — a transport error with no
    status is not a status the policy named."""
    if code < 0 or code > 31:
        return False
    return (mask & (UInt32(1) << UInt32(code))) != UInt32(0)


comptime RETRY_CODES_AIP194: UInt32 = UInt32(1) << UInt32(
    Int(GRPC_STATUS_UNAVAILABLE)
)
"""The AIP-194 retryable set: `UNAVAILABLE` (14), and nothing else.

This is not a shortened list — it is the whole list. AIP-194 names one code, and
Google's shipped `run_grpc_service_config.json` uses exactly this set. Adding
`INTERNAL` / `ABORTED` / `DEADLINE_EXCEEDED` here would make every generated
CREATE replay a call that may already have landed."""


comptime RETRY_CODES_UNAVAILABLE_OR_INTERNAL: UInt32 = (
    (UInt32(1) << UInt32(Int(GRPC_STATUS_UNAVAILABLE)))
    | (UInt32(1) << UInt32(Int(GRPC_STATUS_INTERNAL)))
)
"""`UNAVAILABLE` (14) + `INTERNAL` (13) — the OPT-IN set for a create whose
caller swallows `ALREADY_EXISTS`.

⛔ NEVER a codegen default. `INTERNAL` gives no not-processed guarantee, so this
set is only sound where a replay that DOES duplicate is observed as the original
(AIP-133 client-assigned id + an ALREADY_EXISTS-tolerant caller). The call site
asserts that property by naming this policy; codegen cannot."""


# =============================================================================
# §2 — RetryPolicy — the value the generated client carries per method.
# =============================================================================


comptime RETRY_ATTEMPTS_MAX_CEILING: Int = 16
"""Hard ceiling on `max_attempts`, applied in the constructor. A policy is a
value any caller can build; an unbounded retry loop is how a deploy hangs
forever instead of failing, which is strictly worse than the bug being fixed."""

comptime RETRY_BACKOFF_MS_CEILING: Int = 120_000
"""Hard ceiling (2 min) on `max_backoff_ms`, applied in the constructor."""


struct RetryPolicy(Copyable, Movable, Deinitable):
    """One method's retry policy: WHICH statuses replay, HOW MANY times, and the
    backoff schedule.

    Copyable + allocation-free (four Ints and a UInt32) — the generated client
    constructs one per call, on the stack, on the hot path of every RPC.

    ⚠ `max_attempts` is TOTAL attempts, not retries. `max_attempts == 1` means
    "call once, never replay" and is what `none()` returns. There is no value
    that means unbounded.
    """

    var max_attempts: Int
    """Total attempts for one RPC, including the first. Clamped to
    [1, RETRY_ATTEMPTS_MAX_CEILING]."""

    var initial_backoff_ms: Int
    """The first retry's backoff CAP in milliseconds (the actual wait is drawn
    from [0, cap] — see `backoff_cap_ms`). Clamped to >= 0."""

    var max_backoff_ms: Int
    """The ceiling the growing cap saturates at. Clamped to
    [initial_backoff_ms, RETRY_BACKOFF_MS_CEILING]."""

    var backoff_multiplier_pct: Int
    """The per-attempt growth factor in PERCENT (130 = 1.3x, matching Google's
    shipped Cloud Run config). Integer percent rather than a float so the
    schedule is exactly reproducible in a test. Clamped to >= 100 — a
    multiplier below 1.0 would SHRINK the backoff under load."""

    var retryable_codes: UInt32
    """The bitmask of gRPC status codes that replay. See `retry_mask_has`."""

    def __init__(
        out self,
        max_attempts: Int,
        initial_backoff_ms: Int,
        max_backoff_ms: Int,
        backoff_multiplier_pct: Int,
        retryable_codes: UInt32,
    ):
        """Construct a policy, CLAMPING every field into its safe range.

        The clamps are not defensive noise: a policy is a plain value, and the
        emitter, the call sites and any future config path all build one. The
        constructor is the single place that can guarantee no input produces an
        unbounded or shrinking retry."""
        var a = max_attempts
        if a < 1:
            a = 1
        if a > RETRY_ATTEMPTS_MAX_CEILING:
            a = RETRY_ATTEMPTS_MAX_CEILING
        self.max_attempts = a

        var ib = initial_backoff_ms
        if ib < 0:
            ib = 0
        self.initial_backoff_ms = ib

        var mb = max_backoff_ms
        if mb > RETRY_BACKOFF_MS_CEILING:
            mb = RETRY_BACKOFF_MS_CEILING
        if mb < ib:
            mb = ib
        self.max_backoff_ms = mb

        var mp = backoff_multiplier_pct
        if mp < 100:
            mp = 100
        self.backoff_multiplier_pct = mp

        self.retryable_codes = retryable_codes

    @staticmethod
    def none() -> RetryPolicy:
        """NO retry: one attempt, no code replays.

        The default for every method whose replay-safety is not PROVEN — every
        POST / PATCH verb, and every method with no `(google.api.http)`
        annotation at all. Behaviourally identical to a client with no retry
        layer."""
        return RetryPolicy(1, 0, 0, 100, RETRY_CODE_MASK_EMPTY)

    @staticmethod
    def idempotent() -> RetryPolicy:
        """The AIP-194 policy for a verb proven idempotent by its HTTP verb
        (GET / PUT / DELETE).

        The four numbers are Google's own, copied from the shipped
        `google/cloud/run/v2/run_grpc_service_config.json` retryPolicy
        (maxAttempts 5, initialBackoff 1s, maxBackoff 10s, multiplier 1.3), so
        this client backs off on the same schedule the service was configured to
        expect. The code set is AIP-194's: UNAVAILABLE alone."""
        return RetryPolicy(5, 1000, 10_000, 130, RETRY_CODES_AIP194)

    @staticmethod
    def internal_on_alreadyexists_guarded() -> RetryPolicy:
        """OPT-IN: the idempotent schedule, plus `INTERNAL` (13).

        ⛔ ONLY for a call site that (a) assigns the resource id itself, so a
        replay targets the SAME resource, and (b) already treats
        `ALREADY_EXISTS` as success. Both must hold; (a) without (b) turns a
        successful retry into a hard 409.

        The motivating instance is a Cloud Run job create whose job id the
        caller derives itself, and whose error classifier already swallows
        ALREADY_EXISTS. NEVER emitted by codegen: the proto cannot state (b)."""
        return RetryPolicy(
            5, 1000, 10_000, 130, RETRY_CODES_UNAVAILABLE_OR_INTERNAL
        )

    def retries_nothing(self) -> Bool:
        """True iff this policy can never replay — one attempt, or an empty code
        set. The retry loop uses it to skip the clock read on the hot path."""
        return (
            self.max_attempts <= 1
            or self.retryable_codes == RETRY_CODE_MASK_EMPTY
        )


# =============================================================================
# §3 — The decision + schedule, as pure functions.
# =============================================================================


def is_retryable_grpc_error(msg: String, policy: RetryPolicy) -> Bool:
    """Does this raised-Error message carry a status the policy names?

    The gate is the STATUS CODE, recovered from the `[grpc:<N>]` prefix that
    `format_grpc_error_message` puts on every status the client raises. A
    message with no `[grpc:` anchor is a TRANSPORT error, not a status, and is
    NOT retried here — `_send_unary_bounded_goaway_retry` is the layer that owns
    the transport classes carrying a not-processed guarantee (RFC 9113 §6.8
    GOAWAY-above-Last-Stream-ID, zero response bytes, REFUSED_STREAM), and
    every other transport failure leaves the verdict unknown."""
    if policy.retries_nothing():
        return False
    return retry_mask_has(policy.retryable_codes, parse_grpc_status_code(msg))


def backoff_cap_ms(attempt: Int, policy: RetryPolicy) -> Int:
    """The backoff CAP before the `attempt`-th retry (1-based: `attempt == 1` is
    the wait before the SECOND overall attempt).

    `initial * multiplier^(attempt-1)`, saturated at `max_backoff_ms`. Computed
    in integer percent so the schedule is exactly reproducible; the multiply is
    guarded against overflow by the saturation check running INSIDE the loop."""
    if attempt <= 0:
        return 0
    var cap = policy.initial_backoff_ms
    var i = 1
    while i < attempt:
        if cap >= policy.max_backoff_ms:
            return policy.max_backoff_ms
        cap = (cap * policy.backoff_multiplier_pct) // 100
        i += 1
    if cap > policy.max_backoff_ms:
        return policy.max_backoff_ms
    return cap


def _xorshift64(var x: UInt64) -> UInt64:
    x ^= x << 13
    x ^= x >> 7
    x ^= x << 17
    return x


def backoff_draw_ms(attempt: Int, policy: RetryPolicy, salt: UInt64) -> Int:
    """FULL JITTER: a uniform draw from [0, `backoff_cap_ms(attempt, policy)`].

    ⚠ THE JITTER IS THE POINT, not a refinement. N concurrent callers start
    within milliseconds of each other; when a shared backend blips, all N enter
    backoff together. A deterministic `1.3^n` schedule re-synchronises them onto
    the identical retry instant and re-creates the thundering herd on every
    round. Drawing from [0, cap] de-correlates them (AWS "Full Jitter").

    `salt` distinguishes two draws taken inside the same clock tick — the
    monotonic counter alone is not enough at this resolution."""
    var cap = backoff_cap_ms(attempt, policy)
    if cap <= 0:
        return 0
    var seed = UInt64(perf_counter_ns()) ^ (
        salt * UInt64(0x9E3779B97F4A7C15)
    )
    var r = _xorshift64(seed | UInt64(1))
    return Int(r % UInt64(cap + 1))


def sleep_backoff_ms(ms: Int):
    """Sleep `ms` milliseconds.

    `usleep` (microsecond, a distinct symbol) rather than the stdlib
    `time.sleep` -> `nanosleep`: an AOT binary that also links `komira_async`
    (whose reactor declares its OWN `external_call["nanosleep", ...]`) fails to
    legalize with a conflicting-signature error."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))
