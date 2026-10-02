# =============================================================================
# komira_gcp_core/status.mojo — the google.rpc.Status error envelope.
# =============================================================================
#
# A Google REST API answers a failed call with (AIP-193):
#
#     {"error": {"code": 403, "message": "...", "status": "PERMISSION_DENIED",
#                "details": [...]}}
#
# where `error.code` is the HTTP status and `error.status` the
# `google.rpc.Code` name. `parse_gcp_status` reads that envelope LENIENTLY:
# a missing field, a wrong-typed field, a body that is not JSON at all, or no
# body, all still produce a `GcpStatusError` — classified by the HTTP status
# when the envelope does not say — because the caller needs an error to raise
# whatever the server sent.
#
# ⛔ THE BODY IS NEVER ECHOED. `error.message` and `error.details` routinely
# carry resource names, principals and request data; a 4xx from a token
# endpoint can carry the credential that was rejected. A `GcpStatusError`
# keeps only: the HTTP status, the envelope's numeric `code`, the `status`
# name IF it is a bare `[A-Z_]+` token of at most 64 bytes (so a server cannot
# smuggle text through it), the BYTE LENGTH of `error.message`, the byte
# count of the whole body, and the wait a `google.rpc.RetryInfo` detail asks
# for, as a number of milliseconds (`retry_delay_ms`; the retry classifier's
# server delay). `gcp_status_error` is the contract the generated
# REST clients call (proto-codegen `emit_rest.rs`, `GCP_STATUS_ERROR`).
# =============================================================================

from komira_json import JsonValue, JSON_STRING, parse_json_bytes


comptime MAX_PARSE_DEPTH: Int = 64
"""The nesting limit (arrays/objects) every server body is parsed under,
passed to komira_json as `max_depth`. A Google error envelope or list page
is a handful of levels deep. komira_json's parser is non-recursive and
refuses a deeper document itself, so no pre-scan of the body is needed."""


# google.rpc.Code (googleapis google/rpc/code.proto).
comptime CODE_OK: Int = 0
comptime CODE_CANCELLED: Int = 1
comptime CODE_UNKNOWN: Int = 2
comptime CODE_INVALID_ARGUMENT: Int = 3
comptime CODE_DEADLINE_EXCEEDED: Int = 4
comptime CODE_NOT_FOUND: Int = 5
comptime CODE_ALREADY_EXISTS: Int = 6
comptime CODE_PERMISSION_DENIED: Int = 7
comptime CODE_RESOURCE_EXHAUSTED: Int = 8
comptime CODE_FAILED_PRECONDITION: Int = 9
comptime CODE_ABORTED: Int = 10
comptime CODE_OUT_OF_RANGE: Int = 11
comptime CODE_UNIMPLEMENTED: Int = 12
comptime CODE_INTERNAL: Int = 13
comptime CODE_UNAVAILABLE: Int = 14
comptime CODE_DATA_LOSS: Int = 15
comptime CODE_UNAUTHENTICATED: Int = 16

# How the body was classified.
comptime ENVELOPE_PRESENT: Int = 0
"""Valid JSON with an `error` object (its fields may still be missing)."""
comptime ENVELOPE_ABSENT: Int = 1
"""Valid JSON (or an empty body) without an `error` object."""
comptime ENVELOPE_MALFORMED: Int = 2
"""Not a JSON document this parser will read."""

comptime _MAX_STATUS_TOKEN_BYTES: Int = 64
comptime _MAX_PARSE_BYTES: Int = 1 << 20
"""A larger body is not parsed (it is classified MALFORMED): an error envelope
is a few KiB, and the parser holds the whole document."""


def code_name(code: Int) -> String:
    """The `google.rpc.Code` name of `code`, or "" if it is not one."""
    var names: List[String] = [
        "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED",
        "NOT_FOUND", "ALREADY_EXISTS", "PERMISSION_DENIED",
        "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
        "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
        "UNAUTHENTICATED",
    ]
    if code < 0 or code >= len(names):
        return String()
    return names[code].copy()


def code_from_name(name: String) -> Int:
    """The `google.rpc.Code` named `name`, or -1."""
    for c in range(CODE_UNAUTHENTICATED + 1):
        if code_name(c) == name:
            return c
    return -1


def code_from_http_status(http_status: Int) -> Int:
    """The canonical code for an HTTP status when the envelope names none.

    The mapping is the one stated in google/rpc/code.proto (for a status it
    lists under several codes, the first: 400 INVALID_ARGUMENT, 409 ABORTED,
    500 INTERNAL), plus 502 UNAVAILABLE as in gRPC's HTTP-to-gRPC status
    mapping (doc/http-grpc-status-mapping.md): a gateway fault is transient.
    Any other non-2xx status is UNKNOWN."""
    if http_status >= 200 and http_status < 300:
        return CODE_OK
    if http_status == 400:
        return CODE_INVALID_ARGUMENT
    if http_status == 401:
        return CODE_UNAUTHENTICATED
    if http_status == 403:
        return CODE_PERMISSION_DENIED
    if http_status == 404:
        return CODE_NOT_FOUND
    if http_status == 409:
        return CODE_ABORTED
    if http_status == 429:
        return CODE_RESOURCE_EXHAUSTED
    if http_status == 499:
        return CODE_CANCELLED
    if http_status == 500:
        return CODE_INTERNAL
    if http_status == 501:
        return CODE_UNIMPLEMENTED
    if http_status == 502 or http_status == 503:
        return CODE_UNAVAILABLE
    if http_status == 504:
        return CODE_DEADLINE_EXCEEDED
    return CODE_UNKNOWN


def _is_status_token(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > _MAX_STATUS_TOKEN_BYTES:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("A") and c <= ord("Z")) or c == ord("_")):
            return False
    return True


@fieldwise_init
struct GcpStatusError(Copyable, Movable, Deinitable):
    """A failed Google API call, as much as can be said without the body.

    `envelope_code` and `message_bytes` are -1 when the envelope has no such
    field (or a wrong-typed one); `status` is "" when absent or not a bare
    status token. `retry_delay_ms` is the first `google.rpc.RetryInfo`
    detail's `retryDelay` in milliseconds (rounded up), or -1 when there is
    none or it is not a well-formed non-negative proto3 JSON Duration."""

    var verb: String
    var rpc: String
    var http_status: Int
    var envelope: Int
    var envelope_code: Int
    var status: String
    var message_bytes: Int
    var body_bytes: Int
    var retry_delay_ms: Int64

    def code(self) -> Int:
        """The canonical `google.rpc.Code`: the envelope's `status` name when it
        is one, else derived from the HTTP status."""
        var named = code_from_name(self.status)
        if named >= 0:
            return named
        return code_from_http_status(self.http_status)

    def message(self) -> String:
        """The error text: verb, RPC, HTTP status, code and byte counts only."""
        var out = (
            self.verb
            + " "
            + self.rpc
            + ": HTTP "
            + String(self.http_status)
            + ", "
            + code_name(self.code())
            + " (code "
            + String(self.code())
            + ")"
        )
        if self.envelope == ENVELOPE_PRESENT:
            if self.status.byte_length() == 0:
                out += ", error.status absent or not a status token"
            if self.message_bytes >= 0:
                out += ", error.message " + String(self.message_bytes) + " bytes"
        elif self.envelope == ENVELOPE_ABSENT:
            out += ", no google.rpc.Status envelope"
        else:
            out += ", body is not a JSON document"
        out += ", body " + String(self.body_bytes) + " bytes"
        if self.retry_delay_ms >= 0:
            out += ", RetryInfo " + String(self.retry_delay_ms) + " ms"
        return out^

    def to_error(self) -> Error:
        return Error(self.message())


def parse_gcp_status(
    verb: String, rpc: String, http_status: Int, body: List[UInt8]
) -> GcpStatusError:
    """Classify an error response. Never raises; never keeps a body byte
    beyond the allow-listed fields described in the module header."""
    var out = GcpStatusError(
        verb.copy(), rpc.copy(), http_status, ENVELOPE_MALFORMED, -1, String(),
        -1, len(body), -1,
    )
    # Whitespace-only (or empty) body: nothing to parse.
    var blank = True
    for i in range(len(body)):
        var c = Int(body[i])
        if not (c == ord(" ") or c == ord("\t") or c == ord("\n") or c == ord("\r")):
            blank = False
            break
    if blank:
        out.envelope = ENVELOPE_ABSENT
        return out^
    if len(body) > _MAX_PARSE_BYTES:
        return out^
    # Non-ASCII bytes only ever occur inside JSON strings; replacing each with
    # one ASCII byte keeps every length, so ill-formed UTF-8 in `message`
    # (which is only counted) cannot make the envelope MALFORMED.
    var ascii = List[UInt8](capacity=len(body))
    for i in range(len(body)):
        var c = Int(body[i])
        ascii.append(UInt8(c) if c < 0x80 else UInt8(ord("x")))
    var doc = JsonValue()
    try:
        doc = parse_json_bytes(ascii, MAX_PARSE_DEPTH)
    except:
        return out^
    if not doc.is_object() or not doc.has("error"):
        out.envelope = ENVELOPE_ABSENT
        return out^
    try:
        var err = doc.get("error")
        if not err.is_object():
            out.envelope = ENVELOPE_ABSENT
            return out^
        out.envelope = ENVELOPE_PRESENT
        if err.has("code") and err.get("code").is_integral_number():
            try:
                out.envelope_code = Int(err.get("code").as_int64())
            except:
                out.envelope_code = -1
        if err.has("status") and err.get("status").kind_tag() == JSON_STRING:
            var s = err.get("status").as_string()
            if _is_status_token(s):
                out.status = s^
        if err.has("message") and err.get("message").kind_tag() == JSON_STRING:
            out.message_bytes = err.get("message").as_string().byte_length()
        if err.has("details") and err.get("details").is_array():
            out.retry_delay_ms = _retry_info_delay_ms(err.get("details"))
    except:
        pass
    return out^


comptime RETRY_INFO_TYPE = "type.googleapis.com/google.rpc.RetryInfo"
"""The `@type` of a `google.rpc.RetryInfo` entry in `error.details`."""

comptime _MAX_DURATION_SECONDS_DIGITS: Int = 12
"""A `retryDelay` with more whole-second digits than this is clamped to
`_HUGE_DELAY_MS` rather than parsed: 10^12 s is already far past any
`max_server_delay_ms`, and the clamp keeps the arithmetic in Int64."""

comptime _HUGE_DELAY_MS: Int64 = 1 << 62


def _retry_info_delay_ms(details: JsonValue) -> Int64:
    """`retryDelay` of the first RetryInfo entry in `details`, in ms, or -1."""
    try:
        for i in range(details.array_len()):
            var d = details.element_at(i)
            if not d.is_object() or not d.has("@type"):
                continue
            var t = d.get("@type")
            if t.kind_tag() != JSON_STRING or t.as_string() != RETRY_INFO_TYPE:
                continue
            if not d.has("retryDelay"):
                return -1
            var rd = d.get("retryDelay")
            if rd.kind_tag() != JSON_STRING:
                return -1
            return duration_to_ms(rd.as_string())
    except:
        return -1
    return -1


def duration_to_ms(s: String) -> Int64:
    """A proto3 JSON `google.protobuf.Duration` (`"1.5s"`: whole seconds, an
    optional 1-9 digit fraction, then `s`) as milliseconds, rounded up so a
    retry never comes earlier than asked. -1 for a negative or malformed
    duration."""
    var b = s.as_bytes()
    var n = len(b)
    if n < 2 or b[n - 1] != UInt8(ord("s")):
        return -1
    var i = 0
    var secs: Int64 = 0
    var sec_digits = 0
    while i < n - 1 and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        if sec_digits < _MAX_DURATION_SECONDS_DIGITS:
            secs = secs * 10 + Int64(Int(b[i]) - ord("0"))
        sec_digits += 1
        i += 1
    if sec_digits == 0:
        return -1
    var nanos: Int64 = 0
    if i < n - 1:
        if b[i] != UInt8(ord(".")):
            return -1
        i += 1
        var frac_digits = 0
        while i < n - 1:
            if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
                return -1
            frac_digits += 1
            if frac_digits > 9:
                return -1
            nanos = nanos * 10 + Int64(Int(b[i]) - ord("0"))
            i += 1
        if frac_digits == 0:
            return -1
        for _ in range(frac_digits, 9):
            nanos *= 10
    if sec_digits > _MAX_DURATION_SECONDS_DIGITS:
        return _HUGE_DELAY_MS
    return secs * 1000 + (nanos + 999_999) // 1_000_000


def gcp_status_error(
    verb: String, rpc: String, http_status: Int, body: List[UInt8]
) -> Error:
    """The `Error` a generated REST client raises for a non-2xx response."""
    return parse_gcp_status(verb, rpc, http_status, body).to_error()
