# =============================================================================
# deadline.mojo — Grpc-Timeout + Connect-Timeout-Ms parse
# =============================================================================
#
# Per https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md
# §"Request" + https://connectrpc.com/docs/protocol/#timeouts.
#
# Two timeout-header parsers:
#   - grpc: `Grpc-Timeout: <int><unit>` where unit ∈ {H, M, S, m, u, n}
#     (hours / minutes / seconds / milliseconds / microseconds / nanoseconds)
#     Per RFC strict ABNF. Max int value is up to 8 digits.
#   - connect: `Connect-Timeout-Ms: <int>` plain milliseconds.
#
# Both parsers return micros (Int) for uniform downstream handling.
# Returns 0 (no deadline) when header is absent / empty / malformed; the
# caller decides how to handle that — typically "deadline = none".
#
# Encapsulation: NO UnsafePointer in any public sig.
# =============================================================================

from komira_http_core.transport.grpc_timeout import (
    GRPC_TIMEOUT_SET,
    parse_grpc_timeout_value,
)


# =============================================================================
# §1 — Sentinels
# =============================================================================

comptime DEADLINE_UNSET_MICROS: Int = 0
"""Sentinel returned when no deadline header is present or it's malformed."""


# =============================================================================
# §2 — grpc-timeout parsing
# =============================================================================


def parse_grpc_timeout(header_value: String) -> Int:
    """Parse a `Grpc-Timeout` header value into microseconds.

    Returns DEADLINE_UNSET_MICROS (0) if the header is empty or malformed.

    Format per gRPC HTTP/2 spec:
      TimeoutValue = 1*8DIGIT
      TimeoutUnit  = "H" / "M" / "S" / "m" / "u" / "n"

    A nanosecond value is rounded up to whole micros. The parse is
    `komira_http_core`'s `parse_grpc_timeout_value`; this wrapper folds its
    three states into one Int, so malformed, absent and a legal zero all read
    as 0 here. The h2 serve loop enforces grpc-timeout through the
    three-state result (`grpc_deadline_at_arrival`), not through this.
    """
    var t = parse_grpc_timeout_value(header_value)
    if t.state != GRPC_TIMEOUT_SET:
        return DEADLINE_UNSET_MICROS
    return t.micros


# =============================================================================
# §3 — Connect-Timeout-Ms parsing
# =============================================================================


def parse_connect_timeout_ms(header_value: String) -> Int:
    """Parse a `Connect-Timeout-Ms` header value into microseconds.

    Plain decimal integer in milliseconds. Returns DEADLINE_UNSET_MICROS
    if absent / empty / malformed.
    """
    # Read through `as_bytes()`, as in `parse_grpc_timeout`: a non-ASCII
    # byte is malformed, never an abort.
    var bytes = header_value.as_bytes()
    var n = len(bytes)
    if n == 0:
        return DEADLINE_UNSET_MICROS
    var v = 0
    var digit_count = 0
    for i in range(n):
        var b = Int(bytes[i])
        if b < ord("0") or b > ord("9"):
            return DEADLINE_UNSET_MICROS
        v = v * 10 + (b - ord("0"))
        digit_count += 1
        if digit_count > 15:
            return DEADLINE_UNSET_MICROS
    if digit_count == 0:
        return DEADLINE_UNSET_MICROS
    return v * 1000


# =============================================================================
# §4 — Encoding the reverse direction (server-emit / client-set)
# =============================================================================


comptime GRPC_TIMEOUT_MAX_VALUE: Int = 99_999_999
"""The largest `TimeoutValue` the wire format can carry.

The gRPC HTTP/2 spec (`grpc/doc/PROTOCOL-HTTP2.md`) states

    TimeoutValue -> {positive integer as ASCII string of at most 8 digits}

so 99999999 is the ceiling in EVERY unit. A 9-digit value is a MALFORMED
request to a conformant server, which answers INTERNAL "malformed
grpc-timeout" + HTTP 400 rather than applying the deadline the caller asked
for. grpc-go spells the same constant `maxTimeoutValue` in
`internal/transport/http_util.go`."""


def _div_round_up(numer: Int, denom: Int) -> Int:
    """`numer / denom`, rounded UP — grpc-go's `div()`.

    Rounding UP is the load-bearing half. Rounding DOWN SHORTENS the
    deadline the caller asked for, so a call fails early for no reason the
    caller can observe; rounding up only ever grants a few microseconds more
    than requested.
    """
    if numer % denom > 0:
        return numer // denom + 1
    return numer // denom


def encode_grpc_timeout_us(micros: Int) -> String:
    """Encode a microsecond duration as a `Grpc-Timeout` header value.

    The result is ALWAYS a legal `TimeoutValue TimeoutUnit` — at most 8
    digits — and always decodes back to a duration >= `micros`.

    Two passes, in this order:

      1. The LARGEST unit that divides EXACTLY and still fits 8 digits. This
         is what makes an ordinary deadline read the way a human wrote it
         (`5S`, not `5000000u`) and it is lossless, so it cannot shorten
         anything.
      2. Otherwise grpc-go's `encodeTimeout` ladder: the SMALLEST unit whose
         ROUND-UP quotient fits 8 digits. Precision is given up only as far
         as the 8-digit cap forces, and always in the safe direction.

    ⚠ Pass 2 is not optional. Pass 1 alone, with `String(micros) + "u"` as
    a fallback and no digit cap, renders any duration >= 100_000_000us that
    is not a whole number of milliseconds with 9+ digits —
    `200_000_001` would become `200000001u`, which THIS MODULE'S OWN
    `parse_grpc_timeout` rejects to DEADLINE_UNSET_MICROS. A bounded call
    would silently become an unbounded one, the fail-OPEN direction.

    The input unit is the MICROSECOND, so the `n` (nanosecond) rung of
    grpc-go's ladder is unreachable here — there is no value this function
    can be handed that would round to zero micros — and it is deliberately
    not emitted.
    """
    if micros <= 0:
        # `0u` means "already expired" to the server. A caller with NO
        # deadline must omit the header entirely rather than send this;
        # `komira_grpc.headers._set_grpc_timeout_if_set` is where that is
        # decided.
        return String("0u")

    # ---- Pass 1 — largest EXACT unit that fits 1*8DIGIT. ----
    if micros % 3_600_000_000 == 0:
        var exact_h = micros // 3_600_000_000
        if exact_h <= GRPC_TIMEOUT_MAX_VALUE:
            return String(exact_h) + "H"
    if micros % 60_000_000 == 0:
        var exact_min = micros // 60_000_000
        if exact_min <= GRPC_TIMEOUT_MAX_VALUE:
            return String(exact_min) + "M"
    if micros % 1_000_000 == 0:
        var exact_s = micros // 1_000_000
        if exact_s <= GRPC_TIMEOUT_MAX_VALUE:
            return String(exact_s) + "S"
    if micros % 1_000 == 0:
        var exact_ms = micros // 1_000
        if exact_ms <= GRPC_TIMEOUT_MAX_VALUE:
            return String(exact_ms) + "m"
    if micros <= GRPC_TIMEOUT_MAX_VALUE:
        return String(micros) + "u"

    # ---- Pass 2 — grpc-go's ladder: smallest unit whose CEILING fits. ----
    # `u` is already known not to fit (the guard immediately above).
    var ms = _div_round_up(micros, 1_000)
    if ms <= GRPC_TIMEOUT_MAX_VALUE:
        return String(ms) + "m"
    var s = _div_round_up(micros, 1_000_000)
    if s <= GRPC_TIMEOUT_MAX_VALUE:
        return String(s) + "S"
    var minutes = _div_round_up(micros, 60_000_000)
    if minutes <= GRPC_TIMEOUT_MAX_VALUE:
        return String(minutes) + "M"
    var hours = _div_round_up(micros, 3_600_000_000)
    if hours <= GRPC_TIMEOUT_MAX_VALUE:
        return String(hours) + "H"

    # Past 99999999 hours (~11415 years) the wire format cannot express the
    # duration at all. Emit the longest LEGAL value: a deadline that is
    # merely astronomically far away is strictly better than a 9-digit token
    # the server rejects, which would drop the deadline altogether.
    #
    # ⚠ This is the ONE input for which the round-UP property cannot hold,
    # and it is unreachable from any real clock: `micros` here exceeds
    # 3.6e17, i.e. a deadline more than eleven millennia out.
    return String(GRPC_TIMEOUT_MAX_VALUE) + "H"
