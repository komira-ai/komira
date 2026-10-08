# =============================================================================
# komira_gcp_fcm/outcome.mojo -- what one `messages:send` answer means for the
#   registration token it was sent to.
# =============================================================================
#
# FCM v1 answers an error with the `google.rpc.Status` envelope, whose
# `details` may hold a `google.firebase.fcm.v1.FcmError` naming an
# `errorCode` (FCM's v1 REST reference, `ErrorCode`). The answer is read as:
#
#   2xx                                    ACCEPTED   the `name` it returned
#   HTTP 404, or errorCode UNREGISTERED    DEAD       the token is no longer
#                                                     valid; the caller
#                                                     deletes it
#   HTTP 429, or any 5xx                   TRANSIENT  try again later, after
#                                                     `retry_after_ms` when
#                                                     the answer gave one
#   anything else (400, 401, 403, ...)     REFUSED    the request or the
#                                                     credentials are wrong;
#                                                     the same request will
#                                                     fail again, and the
#                                                     token is not shown dead
#
# DEAD is decided first: an UNREGISTERED errorCode on a 5xx is still a dead
# token. No answer at all (the connection failed or timed out) is TRANSIENT
# with `http_status` 0 (client.mojo).
#
# `retry_after_ms` is set on TRANSIENT only: the `Retry-After` header when
# it is a whole number of seconds (read as at most 10^9 s), else the
# envelope's `google.rpc.RetryInfo` delay, else -1. An HTTP-date
# `Retry-After` is not read.
#
# NO BODY TEXT. `detail` is komira_gcp_core's `GcpStatusError.message()` (the
# HTTP status, the canonical code, byte counts), and `fcm_error` is kept only
# when it is a bare `[A-Z_]` token. The envelope's `message` and any other
# body byte never reach the outcome.
# =============================================================================

from komira_gcp_core import parse_gcp_status
from komira_json import JsonValue, parse_json_bytes


comptime FCM_ACCEPTED: Int = 0
"""The message was accepted for delivery."""
comptime FCM_DEAD: Int = 1
"""The registration token is no longer valid."""
comptime FCM_TRANSIENT: Int = 2
"""A failure worth retrying; the token is not shown dead."""
comptime FCM_REFUSED: Int = 3
"""A failure that a retry of the same request repeats."""

comptime FCM_ERROR_TYPE: String = "type.googleapis.com/google.firebase.fcm.v1.FcmError"
"""The `@type` of an `FcmError` entry in the error envelope's `details`."""
comptime FCM_RPC: String = "FirebaseMessaging.SendMessage"
"""The RPC name in an outcome's `detail`."""

comptime _MAX_PARSE_BYTES: Int = 65536
comptime _MAX_PARSE_DEPTH: Int = 16
comptime _MAX_ERROR_CODE_BYTES: Int = 64
comptime _MAX_RETRY_AFTER_S: Int64 = 1_000_000_000
"""A larger `Retry-After` is read as this many seconds (the product in
milliseconds stays inside Int64)."""


def fcm_outcome_name(kind: Int) -> String:
    if kind == FCM_ACCEPTED:
        return String("ACCEPTED")
    if kind == FCM_DEAD:
        return String("DEAD")
    if kind == FCM_TRANSIENT:
        return String("TRANSIENT")
    if kind == FCM_REFUSED:
        return String("REFUSED")
    return String("UNKNOWN(") + String(kind) + String(")")


@fieldwise_init
struct FcmOutcome(Copyable, Movable, Deinitable):
    """One send's outcome.

    - `kind`: FCM_ACCEPTED, FCM_DEAD, FCM_TRANSIENT or FCM_REFUSED.
    - `http_status`: the answer's status; 0 when no answer arrived.
    - `message_name`: on ACCEPTED, the `name` FCM returned
      (`projects/<p>/messages/<id>`), "" when the body held none.
    - `fcm_error`: the FcmError `errorCode` when it is a bare token, else "".
    - `retry_after_ms`: the server's delay (module header), -1 when none.
    - `detail`: for anything but ACCEPTED, the status, code and byte counts;
      never body text."""

    var kind: Int
    var http_status: Int
    var message_name: String
    var fcm_error: String
    var retry_after_ms: Int64
    var detail: String

    def is_accepted(self) -> Bool:
        return self.kind == FCM_ACCEPTED

    def is_dead(self) -> Bool:
        return self.kind == FCM_DEAD

    def is_transient(self) -> Bool:
        return self.kind == FCM_TRANSIENT

    def is_refused(self) -> Bool:
        return self.kind == FCM_REFUSED


def _is_error_code_token(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > _MAX_ERROR_CODE_BYTES:
        return False
    for i in range(len(b)):
        var c = b[i]
        if not (
            (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or c == UInt8(ord("_"))
        ):
            return False
    return True


def fcm_error_code(body: List[UInt8]) -> String:
    """The `errorCode` of the first FcmError in `error.details`, when it is a
    bare `[A-Z_]` token; else "". Never raises."""
    if len(body) == 0 or len(body) > _MAX_PARSE_BYTES:
        return String()
    try:
        var doc = parse_json_bytes(body, _MAX_PARSE_DEPTH)
        if not doc.is_object() or not doc.has(String("error")):
            return String()
        var err = doc.get(String("error"))
        if not err.is_object() or not err.has(String("details")):
            return String()
        var details = err.get(String("details"))
        if not details.is_array():
            return String()
        for i in range(details.array_len()):
            var d = details.element_at(i)
            if not d.is_object() or not d.has(String("@type")):
                continue
            var t = d.get(String("@type"))
            if not t.is_string() or t.as_string() != String(FCM_ERROR_TYPE):
                continue
            if not d.has(String("errorCode")):
                return String()
            var code = d.get(String("errorCode"))
            if not code.is_string():
                return String()
            var s = code.as_string()
            if _is_error_code_token(s):
                return s^
            return String()
    except:
        pass
    return String()


def _message_name(body: List[UInt8]) -> String:
    """The `name` of a 2xx answer, "" when it has none."""
    if len(body) == 0 or len(body) > _MAX_PARSE_BYTES:
        return String()
    try:
        var doc = parse_json_bytes(body, _MAX_PARSE_DEPTH)
        if doc.is_object() and doc.has(String("name")):
            var n = doc.get(String("name"))
            if n.is_string():
                return n.as_string()
    except:
        pass
    return String()


def classify_fcm_response(
    http_status: Int, retry_after_s: Int64, body: List[UInt8]
) -> FcmOutcome:
    """Read one `messages:send` answer (module header). `retry_after_s` is
    the `Retry-After` header in seconds, -1 when absent or not a number."""
    if http_status >= 200 and http_status < 300:
        return FcmOutcome(
            FCM_ACCEPTED, http_status, _message_name(body), String(), -1, String()
        )
    var status = parse_gcp_status(
        String("POST"), String(FCM_RPC), http_status, body
    )
    var code = fcm_error_code(body)
    var detail = status.message()
    if code.byte_length() > 0:
        detail += ", FcmError " + code
    var kind = FCM_REFUSED
    if http_status == 404 or code == String("UNREGISTERED"):
        kind = FCM_DEAD
    elif http_status == 429 or (http_status >= 500 and http_status < 600):
        kind = FCM_TRANSIENT
    var retry_ms: Int64 = -1
    if kind == FCM_TRANSIENT:
        if retry_after_s >= 0:
            retry_ms = (
                retry_after_s * 1000 if retry_after_s
                <= _MAX_RETRY_AFTER_S else _MAX_RETRY_AFTER_S * 1000
            )
        elif status.retry_delay_ms >= 0:
            retry_ms = status.retry_delay_ms
    return FcmOutcome(kind, http_status, String(), code^, retry_ms, detail^)
