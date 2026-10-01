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
# smuggle text through it), the BYTE LENGTH of `error.message`, and the byte
# count of the whole body. `gcp_status_error` is the contract the generated
# REST clients call (proto-codegen `emit_rest.rs`, `GCP_STATUS_ERROR`).
# =============================================================================

from komira_serde.json_value import parse_json_value, JsonValue, JSON_STRING
from komira_gcp_core.nesting import MAX_PARSE_DEPTH, nesting_within


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
    status token."""

    var verb: String
    var rpc: String
    var http_status: Int
    var envelope: Int
    var envelope_code: Int
    var status: String
    var message_bytes: Int
    var body_bytes: Int

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
        -1, len(body),
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
    if len(body) > _MAX_PARSE_BYTES or not nesting_within(body, MAX_PARSE_DEPTH):
        return out^
    # Non-ASCII bytes only ever occur inside JSON strings; replacing each with
    # one ASCII byte keeps every length and makes the text valid UTF-8.
    var ascii = List[UInt8](capacity=len(body))
    for i in range(len(body)):
        var c = Int(body[i])
        ascii.append(UInt8(c) if c < 0x80 else UInt8(ord("x")))
    var doc = JsonValue()
    try:
        doc = parse_json_value(String(unsafe_from_utf8=Span(ascii)))
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
    except:
        pass
    return out^


def gcp_status_error(
    verb: String, rpc: String, http_status: Int, body: List[UInt8]
) -> Error:
    """The `Error` a generated REST client raises for a non-2xx response."""
    return parse_gcp_status(verb, rpc, http_status, body).to_error()
