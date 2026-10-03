# =============================================================================
# komira_objectstore_s3/errors.mojo -- S3 answers as komira_objectstore errors
# =============================================================================
#
# Every failed store verb raises an Error whose message is
#
#   StoreError[<KIND>] <Operation> s3://<bucket>/<key> status=<http>
#       [s3_code=<code>] [s3_message=<message>]
#
# on one line, the shape every komira_objectstore conformer raises, so the
# readers built on that package match it: the leading `StoreError[<KIND>]`
# token (`store_error_kind_from_message`), `status=404` for an absent object
# and `412` / `precondition` for a lost conditional write
# (komira_objectstore.cas_manifest's `_is_not_found` / `is_precondition`).
# Only S3's error code and message ride out, never the response body.
#
# THE KINDS (`classify_http_status`):
#
#   304                                        PRECONDITION
#   404                                        NOT_FOUND
#   401, 403                                   PERMISSION_DENIED
#   412                                        PRECONDITION
#   409 ConditionalRequestConflict             PRECONDITION
#   429, 503, or a throttling code (SlowDown)  THROTTLED
#   other 5xx                                  TRANSPORT
#   other 4xx (and 416)                        MALFORMED
#
# THE 409 IS A LOST CONDITIONAL WRITE. S3 answers a conditional PutObject
# that races another conditional write on the same key with
# `409 ConditionalRequestConflict` ("A conflicting conditional operation is
# currently in progress against this resource. Please try again."). Nothing
# was written; the caller must read again and retry, which is what a 412
# asks of it too. A 409 classified as MALFORMED would end a compare-and-swap
# loop that retries only a lost precondition: the append would fail instead
# of retrying.
# tests/test_s3_conditional_store.mojo drives komira_objectstore's
# CasManifestStore into exactly that answer. Its message carries the word
# `precondition` because that is what the CAS substrate's retry reads.
# =============================================================================

from komira_aws_core import aws_is_throttling_code

from komira_objectstore.types import (
    STORE_ERR_MALFORMED,
    STORE_ERR_NOT_FOUND,
    STORE_ERR_PERMISSION_DENIED,
    STORE_ERR_PRECONDITION,
    STORE_ERR_THROTTLED,
    STORE_ERR_TRANSPORT,
    StoreError,
)


comptime S3_CONDITIONAL_CONFLICT_CODE = "ConditionalRequestConflict"
"""S3's code for a conditional write that raced another one on its key."""


def classify_http_status(status: Int, code: String, message: String) -> StoreError:
    """The `StoreError` of an S3 answer with HTTP `status` and S3 error
    `code` ("" when it names none). The table is the module header's."""
    if status == 304 or status == 412:
        return StoreError.precondition(message)
    if status == 409 and code == S3_CONDITIONAL_CONFLICT_CODE:
        return StoreError.precondition(message)
    if status == 404:
        return StoreError.not_found(message)
    if status == 401 or status == 403:
        return StoreError.permission_denied(message, status)
    if status == 429 or status == 503 or aws_is_throttling_code(code):
        return StoreError.throttled(message, status)
    if status >= 500 and status < 600:
        return StoreError(STORE_ERR_TRANSPORT, message, status)
    return StoreError(STORE_ERR_MALFORMED, message, status)


def store_error_kind_name(kind: UInt8) -> String:
    """The token a kind is written as inside `StoreError[...]`."""
    if kind == STORE_ERR_NOT_FOUND:
        return "NOT_FOUND"
    if kind == STORE_ERR_PERMISSION_DENIED:
        return "PERMISSION_DENIED"
    if kind == STORE_ERR_THROTTLED:
        return "THROTTLED"
    if kind == STORE_ERR_PRECONDITION:
        return "PRECONDITION"
    if kind == STORE_ERR_TRANSPORT:
        return "TRANSPORT"
    return "MALFORMED"


def _one_line(s: String) -> String:
    """`s` with CR and LF as spaces, so a message stays one line."""
    return s.replace("\r", " ").replace("\n", " ")


def s3_store_error(
    op: String,
    bucket: String,
    key: String,
    status: Int,
    code: String,
    message: String,
) -> Error:
    """The Error a store verb raises for an S3 answer (module header)."""
    var kind = classify_http_status(status, code, message).kind
    var msg = String("StoreError[") + store_error_kind_name(kind) + "] "
    msg += op + " s3://" + bucket + "/" + key
    msg += " status=" + String(status)
    if code.byte_length() > 0:
        msg += " s3_code=" + _one_line(code)
    if message.byte_length() > 0:
        msg += " s3_message=" + _one_line(message)
    if kind == STORE_ERR_PRECONDITION and status == 409:
        msg += " (precondition not met: a concurrent conditional write; read again and retry)"
    return Error(msg^)


def s3_malformed(op: String, bucket: String, key: String, what: String) -> Error:
    """A MALFORMED error for an answer S3 should not have given (a 206
    without a Content-Range, a PutObject without an ETag)."""
    return Error(
        String("StoreError[MALFORMED] ")
        + op
        + " s3://"
        + bucket
        + "/"
        + key
        + ": "
        + _one_line(what)
    )


def store_error_kind_from_message(msg: String) -> UInt8:
    """The kind named by the FIRST `StoreError[<KIND>]` token in `msg`, or 0
    when it holds none. Only the first counts: the key follows the kind, and
    a key may itself hold `StoreError[...]`."""
    var at = msg.find("StoreError[")
    if at < 0:
        return UInt8(0)
    var start = at + String("StoreError[").byte_length()
    var end = msg.find("]", start)
    if end < 0:
        return UInt8(0)
    var name = String(StringSlice(unsafe_from_utf8=msg.as_bytes()[start:end]))
    if name == "NOT_FOUND":
        return STORE_ERR_NOT_FOUND
    if name == "PERMISSION_DENIED":
        return STORE_ERR_PERMISSION_DENIED
    if name == "THROTTLED":
        return STORE_ERR_THROTTLED
    if name == "PRECONDITION":
        return STORE_ERR_PRECONDITION
    if name == "TRANSPORT":
        return STORE_ERR_TRANSPORT
    if name == "MALFORMED":
        return STORE_ERR_MALFORMED
    return UInt8(0)
