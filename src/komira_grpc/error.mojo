# =============================================================================
# komira_grpc/error.mojo — GrpcError + helpers
# =============================================================================
#
# Every generated RPC call raises a typed `GrpcError` carrying:
#   - `code`     — gRPC canonical 0..16 status (UInt8); re-uses
#                  komira_connect.status.GRPC_STATUS_* constants.
#   - `message`  — percent-decoded `grpc-message` (or Connect JSON error
#                  envelope's `message` field).
#   - `details`  — optional `grpc-status-details-bin` binary payload
#                  (base64-decoded for classic gRPC; JSON array for
#                  Connect — kept as the raw bytes for inspection).
#
# Trailers-only / status-from-trailers, plus HTTP non-200 → a gRPC status
# (section 4). Three extraction paths are folded:
#
#   - `parse_grpc_status_trailers(HeaderMap)` — extracts `grpc-status` /
#     `grpc-message` from an HTTP/2 trailer block; classic-gRPC.
#   - `parse_grpc_status_initial_headers(HeaderMap)` — extracts from the
#     INITIAL `HEADERS` (the trailers-only response case).
#   - `from_connect_error_envelope(ConnectErrorEnvelope)` — converts the
#     Connect-JSON error envelope (`code` string + `message`) into a
#     GrpcError; reuses komira_connect.codec_connect_json's parser.
#
# Encapsulation: NO UnsafePointer in any public sig. ZERO wildcard origins.
# ZERO take_pointee. ZERO new ArcPointer.
# =============================================================================

from komira_connect.status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_UNAUTHENTICATED,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_UNKNOWN,
    format_grpc_status_error,
)
from komira_connect.codec_grpc import grpc_percent_decode_message
from komira_connect.codec_connect_json import ConnectErrorEnvelope
from komira_http.client.header_map import HeaderMap


# =============================================================================
# §1 — GrpcError — the canonical raised-error shape.
# =============================================================================


@fieldwise_init
struct GrpcError(Movable, Deinitable):
    """The typed error every generated RPC raises path carries.

    Fields:
      code     — the canonical gRPC 0..16 status enum (UInt8 to match the
                 komira_connect.status alias namespace; codegen consumers
                 cast via `Int(err.code)`).
      message  — `grpc-message` percent-decoded (or Connect `message` field).
                 May be empty.
      details  — `grpc-status-details-bin` raw bytes (base64-decoded for
                 classic gRPC; the JSON details array's raw bytes for
                 Connect). Optional[List[UInt8]] — None when absent.

    Movable (NOT Copyable) — owns the message String and details List.

    Consumer pattern (the retry layer / observability layer):
        try:
            var resp = client.some_call(...)
        except e:
            # `e` is a Mojo Error whose `__str__()` is the formatted
            # GrpcError text — use `format_grpc_error_message` (below)
            # to construct it. The raised-Error indirection is the same
            # one the Connect server uses for handlers via the [connect:N]
            # prefix (komira_connect.status.format_connect_error /
            # parse_connect_error).
    """

    var code: UInt8
    """GRPC canonical 0..16 status (GRPC_STATUS_* from komira_connect)."""

    var message: String
    """Human-readable error text (percent-decoded for classic gRPC)."""

    var details: Optional[List[UInt8]]
    """Optional binary details payload (base64-decoded grpc-status-details-bin
    for classic gRPC; raw JSON details array bytes for Connect)."""

    @staticmethod
    def ok() -> GrpcError:
        """Build the canonical OK / no-error value (code=0, message='',
        details=None). Useful as a return sentinel."""
        return GrpcError(GRPC_STATUS_OK, String(""), Optional[List[UInt8]]())

    @staticmethod
    def simple(code: UInt8, message: String) -> GrpcError:
        """Build a GrpcError with no details payload."""
        return GrpcError(code, message, Optional[List[UInt8]]())

    @always_inline
    def is_ok(imm self) -> Bool:
        """True iff this is the OK sentinel (code==0)."""
        return self.code == GRPC_STATUS_OK


# =============================================================================
# §2 — Format and parse the raised-Error string carrying a GrpcError.
# =============================================================================
#
# Mojo's `Error` is a string-wrapped exception type. To carry a structured
# GrpcError through `raises`, the runtime formats it into a prefixed
# string the consumer can parse back. This matches the Connect server's
# pattern (komira_connect.status.format_connect_error / parse_connect_error)
# with `[grpc:N]` instead of `[connect:N]`.
# =============================================================================


def format_grpc_error_message(code: UInt8, message: String) -> String:
    """Format a GrpcError into a raised-Error string.

    Shape: `[grpc:<code>] <message>` — e.g. `[grpc:5] user 42 not found`.
    The dispatcher / generated stub raises `Error(this string)`; consumers
    parse it back via `parse_grpc_error_message`.

    Args:
        code:    GRPC canonical 0..16 status.
        message: Human-readable text (already percent-decoded).

    ⚠ DELEGATES to `komira_connect.status.format_grpc_status_error`, which is
    the SINGLE definition of the `[grpc:N]` shape. The wire-format primitives in
    `komira_connect` (`envelope`, `codec_grpc`) raise with the anchor too, and
    `komira_connect` cannot import from `komira_grpc` (the dependency runs the
    other way), so the definition lives at the bottom of the order and this
    spelling forwards to it. Do NOT re-inline the string here — two copies of a
    prefix that `parse_grpc_status_code` scans for is exactly the drift this
    delegation removes.
    """
    return format_grpc_status_error(code, message)


def parse_grpc_status_code(msg: String) -> Int:
    """Extract the integer gRPC status from a `[grpc:<N>] ...`-prefixed Error
    message. Returns -1 if the message has no recognizable `[grpc:` anchor
    (e.g. a raw transport error). The GrpcClient prefixes EVERY raised status
    with `[grpc:<N>]` (via `format_grpc_error_message` above), so this recovers
    the code without a typed-variant dependency (Mojo 1.0.0b1 raises `Error`,
    not a typed exception).

    Unlike `parse_grpc_error_message` (which requires the prefix at position 0
    via `startswith`), this scans for the `[grpc:` anchor ANYWHERE in the
    string — callers re-project errors that may carry leading context before
    the prefix. Hand-scans the digits after `[grpc:` (avoids the two-arg
    `String.find` overload).

    This is the SINGLE shared definition; error mappers built on this client
    (for example `komira_gcp_storage`'s) consume it rather than carrying their
    own hand-scanner."""
    var anchor = msg.find(String("[grpc:"))
    if anchor < 0:
        return -1
    var i = anchor + 6  # past "[grpc:"
    var n = msg.byte_length()
    var acc = 0
    var saw_digit = False
    while i < n:
        var c = ord(msg[byte=i])
        if c >= ord("0") and c <= ord("9"):
            acc = acc * 10 + (c - ord("0"))
            saw_digit = True
            i += 1
        else:
            break
    if not saw_digit:
        return -1
    return acc


def parse_grpc_error_message(text: String) -> Tuple[UInt8, String]:
    """Parse a raised-Error string back into (code, message).

    Returns (GRPC_STATUS_UNKNOWN, full text) if the prefix is malformed —
    fallback for unstructured errors that escaped the runtime layer.
    """
    var prefix = String("[grpc:")
    if not text.startswith(prefix):
        return (GRPC_STATUS_UNKNOWN, text)
    var p_len = prefix.byte_length()
    var close_idx = -1
    for i in range(p_len, text.byte_length()):
        if ord(text[byte=i]) == ord("]"):
            close_idx = i
            break
    if close_idx < 0:
        return (GRPC_STATUS_UNKNOWN, text)
    var code = UInt8(0)
    var any_digit = False
    for i in range(p_len, close_idx):
        var c = ord(text[byte=i])
        if c >= ord("0") and c <= ord("9"):
            code = code * 10 + UInt8(c - ord("0"))
            any_digit = True
        else:
            return (GRPC_STATUS_UNKNOWN, text)
    if not any_digit:
        return (GRPC_STATUS_UNKNOWN, text)
    var msg_start = close_idx + 1
    if msg_start < text.byte_length() and ord(text[byte=msg_start]) == ord(" "):
        msg_start += 1
    var msg = String("")
    for i in range(msg_start, text.byte_length()):
        msg += text[byte=i]
    return (code, msg)


# =============================================================================
# §3 — Extract a GrpcError from an HTTP/2 trailer block (classic gRPC).
# =============================================================================
#
# Classic gRPC responses ALWAYS use
# `:status: 200` at the HTTP layer; the gRPC status rides in trailers via
# the `grpc-status` (decimal-string) + `grpc-message` (percent-encoded)
# header pair. If the HTTP layer itself surfaces a non-200 BEFORE any
# gRPC framing (a proxy 502, a TLS reject), the consumer's call shim is
# expected to map it via `grpc_error_from_http_non_200`.
# =============================================================================


def parse_grpc_status_trailers(trailers: HeaderMap) -> GrpcError:
    """Extract a GrpcError from an HTTP/2 trailer block.

    Per the gRPC spec:
      - `grpc-status` is a decimal-string ASCII integer (e.g. `"14"`); the
        framer parses via simple digit-scan.
      - `grpc-message` is percent-encoded; the framer percent-decodes it
        before placing in GrpcError.message.
      - `grpc-status-details-bin` is base64-encoded (standard alphabet
        alphabet); the framer reads it as raw header
        bytes — base64 decode is deferred to consumer call sites that
        actually need to materialize the protobuf detail.

    If `grpc-status` is absent, returns GRPC_STATUS_UNKNOWN with a
    diagnostic message (a missing status is an unknown failure, not a
    silent OK).

    NOTE: passes through Mojo `raises` only via grpc_percent_decode_message
    which itself raises on malformed input; the caller wraps. It returns
    GRPC_STATUS_UNKNOWN on malformed percent-encoding rather than
    raise, so the consumer always gets a GrpcError back.
    """
    var status_opt = trailers.get("grpc-status")
    if not status_opt.__bool__():
        return GrpcError.simple(
            GRPC_STATUS_UNKNOWN,
            String("missing grpc-status trailer"),
        )
    var status_str = status_opt.value()
    # Parse decimal-string code (`grpc-status` is decimal ASCII).
    var code = _parse_decimal_uint8(status_str)
    if not code.__bool__():
        # Malformed decimal — unknown.
        return GrpcError.simple(
            GRPC_STATUS_UNKNOWN,
            String("malformed grpc-status trailer: '") + status_str + "'",
        )
    # Pull and percent-decode the message if present.
    var msg_opt = trailers.get("grpc-message")
    var msg = String("")
    if msg_opt.__bool__():
        var raw_msg = msg_opt.value()
        try:
            msg = grpc_percent_decode_message(raw_msg)
        except:
            # Malformed percent-encoding: fall back to the raw bytes; better
            # than dropping the message entirely.
            msg = raw_msg
    return GrpcError.simple(code.value(), msg)


def parse_grpc_status_initial_headers(headers: HeaderMap) -> Optional[GrpcError]:
    """Extract a GrpcError from the INITIAL response HEADERS block.

    The trailers-only response: a gRPC
    server MAY send a single HTTP/2 HEADERS frame with both END_HEADERS
    and END_STREAM set, carrying `:status: 200` and `grpc-status` (non-zero,
    typically a permission / not-found / unimplemented). No DATA frames
    follow. The HTTP/2 codec surfaces this as an initial HeaderMap with
    `grpc-status` already present.

    Returns Some(GrpcError) if `grpc-status` is on the initial headers;
    None otherwise (the normal case — status will arrive in trailers).
    """
    # contains_static() avoids a String materialization
    # on the common path (no grpc-status on initial headers). The slow
    # path delegates to parse_grpc_status_trailers, which is the
    # cold path that DOES need the value as a String for downstream
    # decimal-parse + error messages.
    if not headers.contains_static("grpc-status"):
        return Optional[GrpcError]()
    return Optional(parse_grpc_status_trailers(headers))


# =============================================================================
# §4 — HTTP non-200 → gRPC status. THE SPEC'S OWN TABLE.
# =============================================================================
#
# `grpc/doc/http-grpc-status-mapping.md` ("HTTP to gRPC Status Code Mapping")
# and grpc-go's `HTTPStatusConvTab` (`internal/transport/http_util.go`) state
# the SAME eight rows:
#
#     400 Bad Request        -> INTERNAL          (13)
#     401 Unauthorized       -> UNAUTHENTICATED   (16)
#     403 Forbidden          -> PERMISSION_DENIED (7)
#     404 Not Found          -> UNIMPLEMENTED     (12)
#     429 Too Many Requests  -> UNAVAILABLE       (14)
#     502 Bad Gateway        -> UNAVAILABLE       (14)
#     503 Service Unavailable-> UNAVAILABLE       (14)
#     504 Gateway Timeout    -> UNAVAILABLE       (14)
#     everything else        -> UNKNOWN           (2)
#
# ⚠ WHY THE TABLE IS NOT COSMETIC. `RetryPolicy.idempotent()` carries
# `RETRY_CODES_AIP194` — UNAVAILABLE(14) and nothing else. With every non-200
# collapsed to UNKNOWN(2), the entire edge-proxy failure class would sit
# OUTSIDE the retryable set: a 503/504 from a front-end proxy would never be
# replayed, with the retry machinery present, correct, and unreachable.
#
# ⚠ AND WHY IT IS NOT "map every 5xx to UNAVAILABLE". 500 INTERNAL SERVER
# ERROR is deliberately NOT in the table: it carries no not-processed
# guarantee, so a replayed CREATE whose first attempt landed is two resources.
# The rows that ARE mapped to UNAVAILABLE are the ones a proxy emits when the
# request did not reach a handler.
# =============================================================================


def _grpc_status_for_http_status(http_status: UInt16) -> UInt8:
    """The gRPC status code for an HTTP status, per the spec's mapping table.

    Anything outside the table is UNKNOWN(2) — the conservative answer, and
    the one the spec names.
    """
    var s = Int(http_status)
    if s == 400:
        return GRPC_STATUS_INTERNAL
    if s == 401:
        return GRPC_STATUS_UNAUTHENTICATED
    if s == 403:
        return GRPC_STATUS_PERMISSION_DENIED
    if s == 404:
        # UNIMPLEMENTED, not NOT_FOUND: a 404 from an HTTP layer means the
        # ROUTE is absent (no such service/method at this endpoint), not that
        # a requested entity is missing. A caller reading 5 as "the row isn't
        # there" would silently swallow a misrouted deploy.
        return GRPC_STATUS_UNIMPLEMENTED
    if s == 429 or s == 502 or s == 503 or s == 504:
        return GRPC_STATUS_UNAVAILABLE
    return GRPC_STATUS_UNKNOWN


def grpc_error_from_http_non_200(http_status: UInt16) -> GrpcError:
    """Map a non-200 HTTP status to a GrpcError.

    Classic gRPC ALWAYS uses HTTP `:status: 200`; if the HTTP layer returns a
    non-200 BEFORE any gRPC framing (a proxy 502, a TLS reject, an
    HTTP/2-level reject), this synthesizes the GrpcError the caller sees. Per
    the spec, raw HTTP errors must NOT bubble up as bare HTTP exceptions.

    The code comes from the spec's HTTP->gRPC table above. The HTTP status
    stays IN the diagnostic message whatever the code becomes — it is the only
    thing that tells an operator an edge proxy answered rather than the
    service.
    """
    return GrpcError.simple(
        _grpc_status_for_http_status(http_status),
        String("HTTP non-200 before gRPC framing: status=")
        + String(Int(http_status)),
    )


# =============================================================================
# §5 — Convert a Connect-JSON error envelope to a GrpcError.
# =============================================================================
#
# Connect-unary errors are a (non-2xx HTTP status, JSON body with `code`
# string + `message`).
# komira_connect.codec_connect_json.parse_connect_error_json parses the
# JSON body into a `ConnectErrorEnvelope` (code-string + message + details
# raw). This shim re-maps the Connect error name into a gRPC numeric.
# =============================================================================


def from_connect_error_envelope(env: ConnectErrorEnvelope) -> GrpcError:
    """Build a GrpcError from a parsed Connect JSON error envelope.

    `ConnectErrorEnvelope.code` is already the gRPC numeric code (mapped
    from the Connect string at parse time by komira_connect's
    `parse_connect_error_json`, which threads through
    `connect_name_to_grpc_status` internally). This shim just copies the
    fields into a GrpcError.

    NOTE: the Connect envelope's `details` field is a JSON array; there is
    no JSON-array decoder for it here, so details are dropped on
    the Connect path. Consumers needing details can call
    parse_connect_error_json themselves and inspect the raw bytes.
    """
    return GrpcError.simple(env.code, env.message)


# =============================================================================
# §6 — Helpers
# =============================================================================


def _parse_decimal_uint8(s: String) -> Optional[UInt8]:
    """Parse a decimal-string ASCII integer (0..255) into UInt8.

    Returns Some(v) if `s` is a non-empty ASCII decimal in the UInt8 range.
    Returns None on empty / non-digit / out-of-range.
    """
    var n = s.byte_length()
    if n == 0:
        return Optional[UInt8]()
    var v: Int = 0
    for i in range(n):
        var b = ord(s[byte=i])
        if b < ord("0") or b > ord("9"):
            return Optional[UInt8]()
        v = v * 10 + (b - ord("0"))
        if v > 255:
            return Optional[UInt8]()
    return Optional[UInt8](UInt8(v))
