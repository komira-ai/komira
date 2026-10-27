# =============================================================================
# komira_aws_core/aws_retry.mojo -- which failed AWS attempts are retried
# =============================================================================
#
# The AWS classifier for komira_retry: it reads one failed attempt of a
# signed send (`AwsAttempt`) as a `Verdict`. The backoff, the attempt limit
# and the sleeping are komira_retry's; `aws_standard_retry_policy` is the
# AWS SDKs' standard retry mode in its terms, and `AwsRetryQuota` its retry
# quota.
#
# This is botocore's standard mode, botocore/retries/standard.py (with
# quota.py and special.py) at the release third_party/botocore pins, as
# that release runs by default (below). test_aws_retry reads those
# files from the pinned archive (`:retries`) and checks every entry of
# their lists and every constant below against them. botocore retries an
# attempt when it was not the last one allowed and any of these holds,
# whatever the operation and its HTTP method:
#
#   transient   the HTTP send raised (botocore: ConnectionError,
#               HTTPClientError, which its HTTP session raises for every
#               failure of a send, the dial and the TLS handshake, a refused
#               certificate and an unknown host included; but for
#               komira_http_client's `HttpError[BODY_TOO_LARGE]`, a response
#               over its own cap, which botocore has no counterpart of and
#               no resend changes); a status of
#               `_TRANSIENT_STATUS_CODES` (500, 502, 503, 504); a code of
#               `_TRANSIENT_ERROR_CODES` (RequestTimeout,
#               RequestTimeoutException, PriorRequestNotComplete). S3's 200
#               whose body is an <Error> counts as a 500 (botocore's s3
#               `_handle_200_error`), read by `send_sigv4_signed_request`
#               for the operations its generated client names.
#   throttled   a code of `_THROTTLED_ERROR_CODES`: Throttling,
#               ThrottlingException, ThrottledException,
#               RequestThrottledException, TooManyRequestsException,
#               ProvisionedThroughputExceededException,
#               TransactionInProgressException, RequestLimitExceeded,
#               BandwidthLimitExceeded, LimitExceededException,
#               RequestThrottled, SlowDown, PriorRequestNotComplete and
#               EC2ThrottledException.
#   special     (special.py) STS's IDPCommunicationError; and a DynamoDB
#               response whose `x-amz-crc32` header is not the CRC-32 of its
#               body, a 200 included (`aws_dynamodb_crc32_mismatch`).
#               botocore keys both on the model's service name; the send
#               knows only the signing name, which DynamoDB Streams shares
#               with DynamoDB, so a Streams response with a wrong
#               `x-amz-crc32` is retried here where botocore returns it.
#
# There is no retry-safety rule by method: a POST that may have reached the
# service (an SQS SendMessage, a DynamoDB UpdateItem, an S3
# CompleteMultipartUpload) is resent after a 5xx or a dropped response as
# any other request is, because botocore resends it.
#
# ONE EXCEPTION, A CONDITIONAL WRITE: a request whose method is not GET or
# HEAD and which carries an `If-Match` or `If-None-Match` header (the name
# in any case; `aws_request_is_conditional`, read off the request itself)
# is not resent once the service may have acted on it, that is after a
# transient answer (a 5xx, S3's 200-with-<Error>, the special cases) or a
# transport error raised after a request byte may have reached the peer.
# A resend of a conditional write the service applied is answered 412, and
# the caller would take its own write for a lost race; the failed answer is
# returned (or the transport's error raised) instead. It is still resent
# after a throttle, after a 4xx naming RequestTimeout or
# RequestTimeoutException (the service never read the whole request; with a
# 5xx it is not resent), and after a transport error raised before the
# request was sent (`aws_transport_error_unsent`):
#
#   not sent    the dial failed before a request byte was written:
#               komira_http_client's `HttpError[CONNECT_FAILED]`,
#               `[CONNECT_TIMEOUT]`, `[TLS_HANDSHAKE_FAILED]`,
#               `[TLS_VERIFY_FAILED]` and `[URL_INVALID]`; the kernel dial's
#               `TcpStream.connect: ...`; the TLS dial's
#               `TlsConnector.connect: ...` and `TlsConnector: refusing ...`;
#               name resolution's `DnsError[...]` and `dns: ...`. Also what
#               komira_http_client raises having proved the peer took no
#               action: `HttpError[RETRYABLE_TRANSPORT]` carrying its
#               `[NOTHING-WRITTEN]` token, an HTTP/2 RST_STREAM
#               REFUSED_STREAM (RFC 9113 section 8.7), and the HTTP/2 GOAWAY
#               class `is_h2_goaway_unprocessed` names.
#   maybe sent  any other transport error.
#
# A retry costs 5 from the retry quota (`_RETRY_COST`), and 10 when the
# transport timed out (`_TIMEOUT_RETRY_REQUEST`, botocore's
# ConnectTimeoutError and ReadTimeoutError). The quota holds 500
# (`RetryQuota.INITIAL_CAPACITY`) per client; a call that succeeds (a 2xx)
# puts back what its last retry cost, or 1 (`_NO_RETRY_INCREMENT`) when it
# made none. Three sends in all (`DEFAULT_MAX_ATTEMPTS`), to every
# service, waiting a uniform draw from [0, min(2^(i-1), 20)] seconds before
# send i+1 (`ExponentialBackoff`, `_BASE` 2, `_MAX_BACKOFF` 20). A caller
# that wants another attempt limit passes `aws_standard_retry_policy(n)` to
# `send_sigv4_signed_request_with`.
#
# The pinned `register_retry_handler` also has a second path, behind its
# `NEW_RETRIES_ENABLED` switch, which is off by default and which the
# pinned file calls internal-only, for testing. NONE of that path is
# followed here: not its per-service attempt limits
# (`_SERVICE_MAX_ATTEMPTS`, 4 for DynamoDB and DynamoDB Streams), its
# non-throttle base of 0.05 s (0.025 s for DynamoDB), its retry costs, its
# `x-amz-retry-after` header, nor the long-polling operations' wait.
#
# An error shape the model marks `retryable` is retried by botocore too
# (`ModeledRetryableChecker`). The send has no model; the client-mode
# generator refuses an operation that can return one
# (aws-client-gen, emit_aws), so no generated client depends on it.
# =============================================================================

from std.os import abort

from komira_http_client.h2_client import is_h2_goaway_unprocessed
from komira_http_client.state_machine import HTTP_NOTHING_WRITTEN_TOKEN
from komira_retry import (
    Backoff,
    Jitter,
    RetryBudget,
    RetryClassifier,
    RetryPolicy,
    TokenBucket,
    Verdict,
)

from ._text import sub
from .creds_source import AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS
from .s3_wire import s3_crc32
from .sigv4 import Header


# botocore: `DEFAULT_MAX_ATTEMPTS` of standard mode, every send counted.
comptime AWS_STANDARD_MAX_ATTEMPTS = 3
# botocore's ExponentialBackoff: base 1 s doubling (`_BASE` 2), capped at
# 20 s (`_MAX_BACKOFF`), drawn uniformly from [0, cap] (full jitter).
comptime AWS_RETRY_BASE_MS = 1000
comptime AWS_RETRY_MAX_BACKOFF_MS = 20_000
# A retry costs `_RETRY_COST` from the quota, and a timed-out one
# `_TIMEOUT_RETRY_REQUEST`.
comptime AWS_RETRY_COST = 5
comptime AWS_TIMEOUT_RETRY_COST = 10
# The quota a client starts with (`RetryQuota.INITIAL_CAPACITY`), and what a
# call that succeeds first time puts back (`_NO_RETRY_INCREMENT`).
comptime AWS_RETRY_QUOTA_CAPACITY = 500
comptime AWS_NO_RETRY_INCREMENT = 1
# special.py: the service and code of `RetryIDPCommunicationError`, and the
# service and header of `RetryDDBChecksumError`.
comptime AWS_IDP_COMMUNICATION_ERROR = "IDPCommunicationError"
comptime AWS_DYNAMODB_CRC32_HEADER = "x-amz-crc32"


def aws_standard_retry_policy(
    max_attempts: Int = AWS_STANDARD_MAX_ATTEMPTS,
) raises -> RetryPolicy:
    """botocore's standard retry mode as a komira_retry policy:
    `max_attempts` sends in all, full-jitter exponential backoff from 1 s
    capped at 20 s. Its deadline is the credential's mandatory refresh
    window: `DefaultChainCredsSource` hands out a credential with at least
    that long left, so no retry is signed with one that has expired."""
    return RetryPolicy(
        Backoff(
            initial_ms=AWS_RETRY_BASE_MS,
            multiplier=2.0,
            max_ms=AWS_RETRY_MAX_BACKOFF_MS,
            jitter=Jitter.full(),
        ),
        max_attempts=max_attempts,
        deadline_ms=Int64(AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS) * 1000,
    )


def aws_request_is_conditional(method: String, headers: List[Header]) -> Bool:
    """Whether a request is a conditional write: its method is not GET or
    HEAD and it carries an `If-Match` or `If-None-Match` header (the name
    in any case). A resend of one the service applied is answered 412."""
    if method == "GET" or method == "HEAD":
        return False
    for i in range(len(headers)):
        var name = headers[i].name.lower()
        if name == "if-match" or name == "if-none-match":
            return True
    return False


struct AwsRetryQuota(RetryBudget, Movable, Deinitable):
    """botocore's retry quota (`RetryQuota` under `RetryQuotaChecker`), one
    per client: komira_retry's `TokenBucket`, which is that quota, holding
    `AWS_RETRY_QUOTA_CAPACITY` and putting back `AWS_NO_RETRY_INCREMENT`
    for a call that made no retry. Not thread-safe: a generated client
    holds one and spends it in its `mut` send."""

    var _bucket: TokenBucket

    def __init__(out self):
        self._bucket = _aws_token_bucket()

    def available(self) -> Int:
        return self._bucket.available()

    def try_spend(mut self, cost: Int) -> Bool:
        return self._bucket.try_spend(cost)

    def on_success(mut self, last_retry_cost: Int):
        self._bucket.on_success(last_retry_cost)


def _aws_token_bucket() -> TokenBucket:
    """The quota's bucket. `TokenBucket` refuses a negative setting; both
    constants are positive, so it never does here."""
    try:
        return TokenBucket(
            capacity=AWS_RETRY_QUOTA_CAPACITY,
            success_refill=AWS_NO_RETRY_INCREMENT,
        )
    except e:
        abort(String("AwsRetryQuota: ") + String(e))  # cov: unreachable TokenBucket refuses only a negative setting; both constants are positive


def aws_is_throttling_code(code: String) -> Bool:
    """botocore's `_THROTTLED_ERROR_CODES` (standard mode)."""
    return (
        code == "Throttling"
        or code == "ThrottlingException"
        or code == "ThrottledException"
        or code == "RequestThrottledException"
        or code == "TooManyRequestsException"
        or code == "ProvisionedThroughputExceededException"
        or code == "TransactionInProgressException"
        or code == "RequestLimitExceeded"
        or code == "BandwidthLimitExceeded"
        or code == "LimitExceededException"
        or code == "RequestThrottled"
        or code == "SlowDown"
        or code == "PriorRequestNotComplete"
        or code == "EC2ThrottledException"
    )


def aws_is_transient_code(code: String) -> Bool:
    """botocore's `_TRANSIENT_ERROR_CODES` (standard mode)."""
    return (
        code == "RequestTimeout"
        or code == "RequestTimeoutException"
        or code == "PriorRequestNotComplete"
    )


def aws_is_transient_status(status: Int) -> Bool:
    """botocore's `_TRANSIENT_STATUS_CODES` (standard mode)."""
    return status == 500 or status == 502 or status == 503 or status == 504


def _is_unread_request_code(status: Int, code: String) -> Bool:
    """A 4xx naming RequestTimeout or RequestTimeoutException: the service
    timed out reading the request, so did not act on it. With a 5xx the
    service may have acted on it."""
    return not aws_is_transient_status(status) and (
        code == "RequestTimeout" or code == "RequestTimeoutException"
    )


def aws_transport_error_kind(message: String) -> String:
    """The kind of a komira_http_client error, `X` of a message that starts
    `HttpError[X]` or `HttpError[X: <detail>]`; "" for any other message."""
    var prefix = String("HttpError[")
    if not message.startswith(prefix):
        return String("")
    var start = prefix.byte_length()
    var end = message.find("]", start)
    if end < 0:
        return String("")
    var colon = message.find(":", start)
    if colon >= 0 and colon < end:
        end = colon
    return sub(message, start, end)


def aws_transport_error_unsent(message: String) -> Bool:
    """Whether the transport error `message` was raised before any request
    byte reached the peer, or with komira_http_client's proof that the peer
    took no action (the module header's `not sent`)."""
    var kind = aws_transport_error_kind(message)
    if (
        kind == "CONNECT_FAILED"
        or kind == "CONNECT_TIMEOUT"
        or kind == "TLS_HANDSHAKE_FAILED"
        or kind == "TLS_VERIFY_FAILED"
        or kind == "URL_INVALID"
    ):
        return True
    if kind == "RETRYABLE_TRANSPORT":
        return (
            message.find(HTTP_NOTHING_WRITTEN_TOKEN) >= 0
            or message.find("RST_STREAM(REFUSED_STREAM)") >= 0
        )
    if kind.byte_length() > 0:
        return is_h2_goaway_unprocessed(message)
    return (
        message.startswith("TcpStream.connect: ")
        or message.startswith("TlsConnector.connect: ")
        or message.startswith("TlsConnector: refusing ")
        or message.startswith("DnsError[")
        or message.startswith("dns: ")
    )


def aws_transport_error_is_timeout(message: String) -> Bool:
    """A connect or read timeout, in the spelling of the stack that raises
    it (komira_http_client's `HttpError[CONNECT_TIMEOUT]` and
    `HttpError[TIMEOUT]`, the kernel dial's and the TLS handshake's
    deadlines): botocore's ConnectTimeoutError and ReadTimeoutError, whose
    retry costs `_TIMEOUT_RETRY_REQUEST`."""
    var kind = aws_transport_error_kind(message)
    return (
        kind == "CONNECT_TIMEOUT"
        or kind == "TIMEOUT"
        or message.startswith("TcpStream.connect: connect timed out")
        or message.startswith("TlsConnector.connect: TLS handshake to ")
    )


def aws_dynamodb_crc32_mismatch(header: String, body: List[UInt8]) -> Bool:
    """Whether a DynamoDB response's `x-amz-crc32` header (`header`, "" when
    absent) names a number other than the CRC-32 of its body (special.py's
    `RetryDDBChecksumError`, which compares `int(checksum)` with it). False
    without the header, and for a value that is not a decimal integer (an
    optional sign, then digits, spaces around), on which botocore's `int()`
    raises rather than retry."""
    if header.byte_length() == 0:
        return False
    var t = String(header.strip())
    var b = t.as_bytes()
    var i = 0
    var negative = False
    if len(b) > 0 and (b[0] == UInt8(0x2B) or b[0] == UInt8(0x2D)):
        negative = b[0] == UInt8(0x2D)
        i = 1
    if i >= len(b):
        return False
    for j in range(i, len(b)):
        if b[j] < UInt8(0x30) or b[j] > UInt8(0x39):
            return False
    while i < len(b) - 1 and b[i] == UInt8(0x30):
        i += 1
    var crc = UInt64(s3_crc32(Span(body)))
    if len(b) - i > 10:
        return True
    var v = UInt64(0)
    for j in range(i, len(b)):
        v = v * 10 + UInt64(b[j] - UInt8(0x30))
    if negative and v != 0:
        return True
    return v != crc


struct AwsAttempt(Copyable, Movable):
    """One failed attempt of a signed AWS send.

    - `status`: the HTTP status, -1 when no response arrived (a transport
      error); S3's 200-with-<Error> is recorded as 500.
    - `code`: the AWS error code the response names, "" for none.
    - `transport_error`: the transport's error message, "" for a response.
    - `crc32_mismatch`: a DynamoDB response whose `x-amz-crc32` is not its
      body's CRC-32 (`aws_dynamodb_crc32_mismatch`).
    """

    var status: Int
    var code: String
    var transport_error: String
    var crc32_mismatch: Bool

    def __init__(
        out self,
        status: Int,
        var code: String,
        var transport_error: String,
        crc32_mismatch: Bool = False,
    ):
        self.status = status
        self.code = code^
        self.transport_error = transport_error^
        self.crc32_mismatch = crc32_mismatch

    @staticmethod
    def response(
        status: Int, var code: String, crc32_mismatch: Bool = False
    ) -> AwsAttempt:
        """A response with an error status (or S3's 200-with-<Error>, as
        500) naming `code`, or one whose checksum does not match."""
        return AwsAttempt(status, code^, String(""), crc32_mismatch)

    @staticmethod
    def transport(var message: String) -> AwsAttempt:
        """No response: the transport raised `message`."""
        return AwsAttempt(-1, String(""), message^)


struct AwsRetryClassifier(RetryClassifier, Copyable, Movable):
    """botocore's standard-mode retry conditions over an `AwsAttempt` of a
    call to `service`, the signing name, with the one exception of the
    module header: an attempt of a `conditional` write
    (`aws_request_is_conditional`) that the service may have acted on is
    not retried. botocore's special cases name the service by the model's
    service name; `sts` and `dynamodb` sign as themselves, but DynamoDB
    Streams signs as `dynamodb` too, so its responses get the DynamoDB
    checksum check (the module header's `special`). A
    `HttpError[BODY_TOO_LARGE]` is not retried: the response is over this
    client's own cap, which no resend changes (botocore has no cap)."""

    comptime Outcome = AwsAttempt

    var service: String
    var conditional: Bool

    def __init__(out self, var service: String, conditional: Bool = False):
        self.service = service^
        self.conditional = conditional

    def classify(self, outcome: AwsAttempt) -> Verdict:
        if outcome.status < 0:
            var message = outcome.transport_error.copy()
            if aws_transport_error_kind(message) == "BODY_TOO_LARGE":
                return Verdict.stop(
                    String("the response is over the client's body cap: ")
                    + message
                )
            if self.conditional and not aws_transport_error_unsent(message):
                return Verdict.stop(
                    String("transport error after a conditional write may")
                    + " have reached the service, not resent: "
                    + message
                )
            var cost = AWS_TIMEOUT_RETRY_COST if aws_transport_error_is_timeout(
                message
            ) else AWS_RETRY_COST
            return Verdict.transient(
                String("transport error: ") + message, cost=cost
            )
        var what = String("HTTP ") + String(outcome.status)
        if outcome.code.byte_length() > 0:
            what += String(" ") + outcome.code
        if aws_is_throttling_code(outcome.code):
            return Verdict.throttle(String("throttled: ") + what)
        var reason = String("")
        if aws_is_transient_status(outcome.status) or aws_is_transient_code(
            outcome.code
        ):
            reason = String("transient: ")
        elif (
            self.service == "sts" and outcome.code == AWS_IDP_COMMUNICATION_ERROR
        ):
            reason = String("transient: ")
        elif self.service == "dynamodb" and outcome.crc32_mismatch:
            reason = String(
                "the x-amz-crc32 checksum does not match the body: "
            )
        else:
            return Verdict.stop(what^)
        if self.conditional and not _is_unread_request_code(
            outcome.status, outcome.code
        ):
            return Verdict.stop(
                String("not resent, a conditional write the service may have")
                + " applied: "
                + what
            )
        return Verdict.transient(reason + what)

