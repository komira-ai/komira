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
#
# The same API called over gRPC answers with a gRPC status instead;
# `gcp_grpc_status_error` (at the end of this file) is the generated gRPC
# clients' contract, under the same rule: the server's text is counted, never
# kept.
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
            return _duration_to_ms(rd.as_string())
    except:
        return -1
    return -1


def _duration_to_ms(s: String) -> Int64:
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


# =============================================================================
# gRPC statuses.
# =============================================================================
#
# A Google API called over gRPC states its failure as a gRPC status: the
# `grpc-status` trailer (or a trailers-only response), with a free-text
# `grpc-message` beside it. komira_grpc raises such a status as
# `[grpc:N] <grpc-message>`, and a call whose retries ran out as
# `[grpc-retry:EXHAUSTED] gave up replaying <rpc> after <A> attempt(s) ...
# Last: [grpc:N] <grpc-message>`. The generated gRPC clients (proto-codegen
# `emit.rs`, `GCP_GRPC_STATUS_ERROR`) read `N` and hand it here with that
# text, and raise what comes back. As with the REST envelope, the text is
# counted and never kept: a `grpc-message` carries what an `error.message`
# carries.
#
# The raised text keeps ONE machine-readable part, a `[grpc:C]` anchor in
# front, where `C` is the google.rpc.Code. It is the anchor komira_grpc's
# `parse_grpc_status_code` and `is_retryable_grpc_error` read, so a caller
# classifies a mapped error the way it classifies komira_grpc's own (for
# example, `parse_grpc_status_code(String(e)) == CODE_UNAUTHENTICATED` to drop
# a cached token). The anchor is a number this package wrote; no server byte
# is in it.

comptime _GRPC_ANCHOR = "[grpc:"
comptime _GRPC_RETRY_EXHAUSTED = "[grpc-retry:EXHAUSTED]"
comptime _GRPC_RETRY_ATTEMPTS = " after "


def code_from_grpc_status(grpc_status: Int) -> Int:
    """The `google.rpc.Code` of a gRPC status.

    gRPC's status codes are google.rpc.Code's, number for number (gRPC
    doc/statuscodes.md; google/rpc/code.proto), so a code in 0..16 maps to
    itself. Any other value is UNKNOWN: a client receiving a status it does
    not know treats it as UNKNOWN (the same document)."""
    if grpc_status < CODE_OK or grpc_status > CODE_UNAUTHENTICATED:
        return CODE_UNKNOWN
    return grpc_status


def _find_bytes(hay: String, needle: String, start: Int) -> Int:
    """The byte offset of the first `needle` in `hay` at or after `start`, or
    -1."""
    var h = hay.as_bytes()
    var n = needle.as_bytes()
    var i = start
    while i + len(n) <= len(h):
        var j = 0
        while j < len(n) and h[i + j] == n[j]:
            j += 1
        if j == len(n):
            return i
        i += 1
    return -1


def _status_text_bytes(text: String) -> Int:
    """The byte length of what follows the first `[grpc:N]` anchor of `text`
    (and the one space after it): the `grpc-message`, or komira_grpc's own
    text for a status it derived. All of `text` when it has no anchor."""
    var b = text.as_bytes()
    var at = _find_bytes(text, _GRPC_ANCHOR, 0)
    if at < 0:
        return len(b)
    var i = at + _GRPC_ANCHOR.byte_length()
    while i < len(b) and b[i] != UInt8(ord("]")):
        i += 1
    if i >= len(b):
        return 0
    i += 1
    if i < len(b) and b[i] == UInt8(ord(" ")):
        i += 1
    return len(b) - i


def _retry_attempts(text: String) -> Int:
    """The attempt count of komira_grpc's retry-exhaustion error, or 1 when
    `text` is not one (a call that failed on its only attempt)."""
    if not text.startswith(_GRPC_RETRY_EXHAUSTED):
        return 1
    var at = _find_bytes(text, _GRPC_RETRY_ATTEMPTS, 0)
    if at < 0:
        return 1
    var b = text.as_bytes()
    var i = at + _GRPC_RETRY_ATTEMPTS.byte_length()
    var n = 0
    var digits = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        if digits < 6:
            n = n * 10 + Int(b[i] - UInt8(ord("0")))
        digits += 1
        i += 1
    if n < 1 or digits > 6:
        return 1
    return n


@fieldwise_init
struct GcpGrpcStatusError(Copyable, Movable, Deinitable):
    """A failed Google API call over gRPC, as much as can be said without the
    server's text.

    `grpc_status` is the number the server sent (or the runtime derived, for
    a deadline or a cancellation); `code()` is its `google.rpc.Code`.
    `message_bytes` is the byte length of the status text, what followed
    `[grpc:N]` in the transport's error: the `grpc-message`, or komira_grpc's
    own text for a status it derived. The text itself is not kept.
    `attempts` is how many times the call was sent: 1, or the count
    komira_grpc's retry-exhaustion error states."""

    var rpc: String
    var grpc_status: Int
    var message_bytes: Int
    var attempts: Int

    @staticmethod
    def from_transport_text(
        rpc: String, grpc_status: Int, text: String
    ) -> Self:
        """Classify the error text komira_grpc raised for a call to `rpc`,
        whose status anchor reads `grpc_status`. Keeps no byte of `text`."""
        return Self(
            rpc.copy(), grpc_status, _status_text_bytes(text), _retry_attempts(text)
        )

    def code(self) -> Int:
        """The canonical `google.rpc.Code` (`code_from_grpc_status`)."""
        return code_from_grpc_status(self.grpc_status)

    def message(self) -> String:
        """The error text: a `[grpc:C]` anchor with the google.rpc.Code, the
        RPC, the code and its name, the attempt count of a call whose retries
        ran out, and a byte count. A status outside google.rpc.Code is named
        as received."""
        var out = (
            String(_GRPC_ANCHOR)
            + String(self.code())
            + "] gRPC "
            + self.rpc
            + ": "
            + code_name(self.code())
            + " (code "
            + String(self.code())
            + ")"
        )
        if self.code() != self.grpc_status:
            out += ", grpc-status " + String(self.grpc_status)
        if self.attempts > 1:
            out += ", retries exhausted after " + String(self.attempts) + " attempts"
        out += ", error text " + String(self.message_bytes) + " bytes"
        return out^

    def to_error(self) -> Error:
        return Error(self.message())


def gcp_grpc_status_error(rpc: String, grpc_status: Int, text: String) -> Error:
    """The `Error` a generated gRPC client raises for a call that ended in a
    non-OK gRPC status. `rpc` is the method's path (`/pkg.Service/Method`),
    `grpc_status` the number of the status anchor in `text`, and `text` the
    error komira_grpc raised, which is read and not kept."""
    return GcpGrpcStatusError.from_transport_text(rpc, grpc_status, text).to_error()


def _digits_at(text: String, at: Int) -> Tuple[Int, Int]:
    """The decimal number starting at byte `at` of `text` and the byte just
    past it, or (-1, at) when no digit is there. At most 18 digits are read,
    so the value fits an Int."""
    var b = text.as_bytes()
    var i = at
    var v = 0
    while i < len(b) and i - at < 18 and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        v = v * 10 + (Int(b[i]) - ord("0"))
        i += 1
    if i == at:
        return (-1, at)
    return (v, i)


def _starts_at(text: String, tag: String, at: Int) -> Bool:
    """Whether `tag` occurs in `text` at byte `at`."""
    return _find_bytes(text, tag, at) == at


def gcp_grpc_error_code(rpc: String, text: String) -> Int:
    """The `google.rpc.Code` in an error a generated gRPC client raised for a
    call to `rpc`, or -1 when `text` is not such an error.

    `text` must be exactly what `gcp_grpc_status_error(rpc, ...)` renders:
    the code, the grpc-status, the attempt count and the byte count are read
    back and the message is rebuilt from them, so an error from another RPC,
    an error raised before any status arrived (which a generated client
    passes on unchanged), komira_grpc's own `[grpc:N] ...` text, or a message
    that merely contains `(code N)` returns -1. A caller that maps statuses
    onto its own errors reads the code here instead of parsing the message
    itself."""
    var b = text.as_bytes()
    if not text.startswith(_GRPC_ANCHOR):
        return -1
    var anchor = _digits_at(text, _GRPC_ANCHOR.byte_length())
    if anchor[0] < 0:
        return -1
    var head = String("] gRPC ") + rpc + ": "
    if not _starts_at(text, head, anchor[1]):
        return -1
    var at = _find_bytes(text, " (code ", anchor[1] + head.byte_length())
    if at < 0:
        return -1
    var code = _digits_at(text, at + 7)
    if code[0] < 0 or code[0] != anchor[0]:
        return -1
    var rest = code[1]
    if rest >= len(b) or b[rest] != UInt8(ord(")")):
        return -1
    rest += 1
    var grpc_status = code[0]
    var gs_tag = String(", grpc-status ")
    if _starts_at(text, gs_tag, rest):
        var gs = _digits_at(text, rest + gs_tag.byte_length())
        if gs[0] < 0:
            return -1
        grpc_status = gs[0]
        rest = gs[1]
    var attempts = 1
    var ra_tag = String(", retries exhausted after ")
    if _starts_at(text, ra_tag, rest):
        var ra = _digits_at(text, rest + ra_tag.byte_length())
        if ra[0] < 0:
            return -1
        attempts = ra[0]
        rest = ra[1]
        if not _starts_at(text, " attempts", rest):
            return -1
        rest += String(" attempts").byte_length()
    var et_tag = String(", error text ")
    if not _starts_at(text, et_tag, rest):
        return -1
    var mb = _digits_at(text, rest + et_tag.byte_length())
    if mb[0] < 0:
        return -1
    var rebuilt = GcpGrpcStatusError(rpc.copy(), grpc_status, mb[0], attempts)
    if rebuilt.message() != text:
        return -1
    return rebuilt.code()
