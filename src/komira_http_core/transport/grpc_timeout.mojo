# =============================================================================
# src/komira_http_core/transport/grpc_timeout.mojo: the server's grpc-timeout
# =============================================================================
#
# The gRPC over HTTP/2 spec (grpc/doc/PROTOCOL-HTTP2.md):
#
#     Timeout      -> "grpc-timeout" TimeoutValue TimeoutUnit
#     TimeoutValue -> {positive integer as ASCII string of at most 8 digits}
#     TimeoutUnit  -> Hour / Minute / Second / Millisecond / Microsecond /
#                     Nanosecond
#     Hour -> "H"  Minute -> "M"  Second -> "S"  Millisecond -> "m"
#     Microsecond -> "u"  Nanosecond -> "n"
#
# What this file holds:
#   1. `parse_grpc_timeout_value`: one header value -> `GrpcTimeout`, a
#      three-state result (absent / set / malformed). A set value of zero is a
#      deadline that has already passed, not "no deadline".
#   2. `grpc_deadline_at_arrival`: the request's headers + the clock reading
#      taken when its HEADERS block completed -> `GrpcDeadline` (an absolute
#      monotonic nanosecond instant). The h2 serve loop computes it once per
#      request, at arrival, and checks it before and after the handler.
#   3. `emit_grpc_deadline_exceeded` / `emit_grpc_malformed_timeout`: the two
#      responses the serve loop sends in place of the handler's.
#
# Where this follows grpc-go's server transport
# (`internal/transport/http2_server.go`, `operateHeaders`, and
# `internal/transport/http_util.go`, `decodeTimeout`):
#   * a value shorter than 2 bytes, longer than 9 bytes (8 digits + unit),
#     with an unknown unit byte, or with a non-digit in the value is
#     malformed; the call is answered `:status 400`, `grpc-status 13`
#     (INTERNAL), `grpc-message: malformed grpc-timeout: <reason>`, as a
#     trailers-only response, and the handler is not run. The reject rules
#     are decodeTimeout's; the reason texts are this file's own;
#   * with several grpc-timeout fields, a malformed one makes the call
#     malformed even when a valid field follows (grpc-go sets an error that
#     no later field clears); otherwise the last field is used;
#   * a deadline already passed when the HEADERS block completes (a zero
#     value) is answered `:status 200`, `grpc-status 4` (DEADLINE_EXCEEDED),
#     `grpc-message: context deadline exceeded`, trailers-only, and the
#     handler is not run.
# Where it does not: grpc-go arms a timer at HEADERS time and, when it fires
# later, resets the stream with RST_STREAM(CANCEL). This serve loop has no
# per-stream timer; it checks the deadline when the call is dispatched (so a
# deadline that ran out while the body arrived is also answered grpc-status
# 4 without running the handler) and again after the handler returns
# (answering grpc-status 4 in place of the handler's response).
#
# Only classic gRPC content-types (`application/grpc`, `application/grpc+*`)
# are subject to it. gRPC-Web carries its status in the body and Connect uses
# `connect-timeout-ms`; neither is enforced here.
#
# No UnsafePointer, no wildcard origin. Plain values only.
# =============================================================================

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.hpack import HpackHeader
from komira_http_core.transport.grpc_emit import (
    _strip_ct_params,
    emit_grpc_trailers_only,
)


comptime GRPC_TIMEOUT_ABSENT: UInt8 = 0
"""No grpc-timeout field: the call has no deadline."""

comptime GRPC_TIMEOUT_SET: UInt8 = 1
"""A well-formed grpc-timeout field (zero included)."""

comptime GRPC_TIMEOUT_MALFORMED: UInt8 = 2
"""A grpc-timeout field that does not match `1*8DIGIT TimeoutUnit`."""

comptime GRPC_TIMEOUT_HEADER: String = "grpc-timeout"

comptime GRPC_STATUS_DEADLINE_EXCEEDED: UInt8 = 4
comptime GRPC_STATUS_INTERNAL: UInt8 = 13

comptime GRPC_DEADLINE_EXCEEDED_MESSAGE: String = "context deadline exceeded"
"""grpc-go's message for a server-side deadline (`context.DeadlineExceeded`)."""

comptime GRPC_MALFORMED_TIMEOUT_PREFIX: String = "malformed grpc-timeout: "
"""grpc-go's prefix for a malformed value; the reason follows it."""

comptime _UINT64_MAX: UInt64 = ~UInt64(0)


struct GrpcTimeout(Copyable, Movable, Deinitable):
    """One parsed grpc-timeout value.

    `state` is GRPC_TIMEOUT_ABSENT, GRPC_TIMEOUT_SET or
    GRPC_TIMEOUT_MALFORMED. `micros` is the duration in microseconds when SET
    (a nanosecond value is rounded up, so it is never shortened); 0 otherwise.
    `error` is the reason text when MALFORMED; empty otherwise.

    Microseconds hold every legal value: 99999999H is 3.6e17 us, below
    Int64's 9.2e18.
    """

    var state: UInt8
    var micros: Int
    var error: String

    def __init__(out self, state: UInt8, micros: Int, var error: String):
        self.state = state
        self.micros = micros
        self.error = error^

    @staticmethod
    def absent() -> GrpcTimeout:
        return GrpcTimeout(GRPC_TIMEOUT_ABSENT, 0, String(""))

    @staticmethod
    def malformed(var reason: String) -> GrpcTimeout:
        return GrpcTimeout(GRPC_TIMEOUT_MALFORMED, 0, reason^)


def parse_grpc_timeout_value(value: String) -> GrpcTimeout:
    """Parse one grpc-timeout header value.

    Never ABSENT: an empty value is MALFORMED ("too short"), as in grpc-go.
    The value is read through `as_bytes()`, so a non-ASCII byte is a
    malformed value, never an abort.
    """
    var bytes = value.as_bytes()
    var n = len(bytes)
    if n < 2:
        return GrpcTimeout.malformed(String("timeout string is too short"))
    if n > 9:
        return GrpcTimeout.malformed(String("timeout string is too long"))
    var unit = bytes[n - 1]
    var unit_us: Int
    if unit == UInt8(ord("H")):
        unit_us = 3_600_000_000
    elif unit == UInt8(ord("M")):
        unit_us = 60_000_000
    elif unit == UInt8(ord("S")):
        unit_us = 1_000_000
    elif unit == UInt8(ord("m")):
        unit_us = 1_000
    elif unit == UInt8(ord("u")):
        unit_us = 1
    elif unit == UInt8(ord("n")):
        unit_us = 0  # nanoseconds: rounded up to micros below
    else:
        return GrpcTimeout.malformed(String("timeout unit is not recognized"))
    var v = 0
    for i in range(n - 1):
        var b = bytes[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return GrpcTimeout.malformed(
                String("timeout value is not a decimal number")
            )
        v = v * 10 + Int(b - UInt8(ord("0")))
    if unit_us == 0:
        return GrpcTimeout(GRPC_TIMEOUT_SET, (v + 999) // 1000, String(""))
    return GrpcTimeout(GRPC_TIMEOUT_SET, v * unit_us, String(""))


def find_grpc_timeout(headers: List[HpackHeader]) -> GrpcTimeout:
    """The grpc-timeout of a decoded request header list: ABSENT when no
    field is named `grpc-timeout`; MALFORMED (with the last malformed
    field's reason) when any such field is malformed; else the parse of the
    LAST such field."""
    var out = GrpcTimeout.absent()
    var bad = GrpcTimeout.absent()
    for i in range(len(headers)):
        if headers[i].name == GRPC_TIMEOUT_HEADER:
            var t = parse_grpc_timeout_value(headers[i].value)
            if t.state == GRPC_TIMEOUT_MALFORMED:
                bad = t^
            else:
                out = t^
    if bad.state == GRPC_TIMEOUT_MALFORMED:
        return bad^
    return out^


def is_grpc_h2_content_type(ct: String) -> Bool:
    """True iff `ct` (parameters ignored) is `application/grpc` or
    `application/grpc+<subtype>`: the content-types the gRPC over HTTP/2
    spec covers. gRPC-Web (`application/grpc-web*`) is not one of them."""
    var base = _strip_ct_params(ct)
    if base == "application/grpc":
        return True
    return base.startswith("application/grpc+")


struct GrpcDeadline(Copyable, Movable, Deinitable):
    """The deadline of one gRPC call, fixed when its HEADERS block arrived.

    `state` mirrors `GrpcTimeout.state`. `at_ns` is the monotonic-clock
    instant (the clock `GrpcDispatch.grpc_now_ns` reads) at which the call
    expires when SET, saturating at UInt64 max. `error` is the malformed
    reason.
    """

    var state: UInt8
    var at_ns: UInt64
    var error: String

    def __init__(out self, state: UInt8, at_ns: UInt64, var error: String):
        self.state = state
        self.at_ns = at_ns
        self.error = error^

    @staticmethod
    def none() -> GrpcDeadline:
        return GrpcDeadline(GRPC_TIMEOUT_ABSENT, UInt64(0), String(""))

    def expired(self, now_ns: UInt64) -> Bool:
        """True iff the call has a deadline and `now_ns` is at or past it
        (grpc-go's `context.WithDeadline` expires at `d <= now`)."""
        return self.state == GRPC_TIMEOUT_SET and now_ns >= self.at_ns


def grpc_deadline_at_arrival(
    headers: List[HpackHeader], content_type: String, arrival_ns: UInt64
) -> GrpcDeadline:
    """The call's deadline: `arrival_ns` plus its grpc-timeout.

    NONE for a content-type `is_grpc_h2_content_type` rejects or a request
    with no grpc-timeout field. The addition saturates, so the longest legal
    value (99999999H) does not wrap to an early deadline.
    """
    if not is_grpc_h2_content_type(content_type):
        return GrpcDeadline.none()
    var t = find_grpc_timeout(headers)
    if t.state == GRPC_TIMEOUT_ABSENT:
        return GrpcDeadline.none()
    if t.state == GRPC_TIMEOUT_MALFORMED:
        return GrpcDeadline(GRPC_TIMEOUT_MALFORMED, UInt64(0), t.error.copy())
    var us = UInt64(t.micros)
    var room_us = (_UINT64_MAX - arrival_ns) // UInt64(1000)
    if us > room_us:
        return GrpcDeadline(GRPC_TIMEOUT_SET, _UINT64_MAX, String(""))
    return GrpcDeadline(
        GRPC_TIMEOUT_SET, arrival_ns + us * UInt64(1000), String("")
    )


def emit_grpc_deadline_exceeded(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    content_type: String,
    mut reqs_handled: Int64,
) -> Bool:
    """Close `stream_id` with `:status 200`, `grpc-status 4`,
    `grpc-message: context deadline exceeded` (one trailers-only HEADERS)."""
    return emit_grpc_trailers_only(
        h2,
        stream_id,
        UInt16(200),
        _strip_ct_params(content_type),
        GRPC_STATUS_DEADLINE_EXCEEDED,
        String(GRPC_DEADLINE_EXCEEDED_MESSAGE),
        reqs_handled,
    )


def emit_grpc_malformed_timeout(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    content_type: String,
    reason: String,
    mut reqs_handled: Int64,
) -> Bool:
    """Close `stream_id` with `:status 400`, `grpc-status 13`,
    `grpc-message: malformed grpc-timeout: <reason>` (one trailers-only
    HEADERS). `reason` is one of this file's ASCII texts, which need no
    percent-encoding."""
    return emit_grpc_trailers_only(
        h2,
        stream_id,
        UInt16(400),
        _strip_ct_params(content_type),
        GRPC_STATUS_INTERNAL,
        String(GRPC_MALFORMED_TIMEOUT_PREFIX) + reason,
        reqs_handled,
    )
