# =============================================================================
# komira_aws_core/aws_retry.mojo -- which failed AWS attempts are retried
# =============================================================================
#
# The AWS classifier for komira_retry: it reads one failed attempt of a
# signed send (`AwsAttempt`) as a `Verdict`. The backoff, the attempt limit
# and the sleeping are komira_retry's; `aws_standard_retry_policy` is the
# AWS SDKs' standard retry mode in its terms.
#
# What is retried follows botocore's standard mode
# (botocore/retries/standard.py, at the release third_party/botocore pins):
#
#   transient   a transport error (botocore: ConnectionError,
#               HTTPClientError); a status 500, 502, 503 or 504; the codes
#               RequestTimeout, RequestTimeoutException and InternalError.
#               S3's 200 whose body is an <Error> counts as a 500 (botocore's
#               s3 `_handle_200_error`), read by `send_sigv4_signed_request`.
#   throttled   the codes of `_THROTTLED_ERROR_CODES`: Throttling,
#               ThrottlingException, ThrottledException,
#               RequestThrottledException, TooManyRequestsException,
#               ProvisionedThroughputExceededException,
#               TransactionInProgressException, RequestLimitExceeded,
#               BandwidthLimitExceeded, LimitExceededException,
#               RequestThrottled, SlowDown, PriorRequestNotComplete and
#               EC2ThrottledException.
#
# A retry costs 5 from a retry budget, and 10 when the transport timed out
# (botocore's `_RETRY_COST` and `_TIMEOUT_RETRY_COST`).
#
# ONE RULE IS STRICTER THAN BOTOCORE: a request that is not RETRY-SAFE is
# resent only when the service cannot have acted on it. A request is
# retry-safe when its method is idempotent (RFC 9110 section 9.2.2: GET,
# HEAD, OPTIONS, PUT, DELETE; the AWS REST APIs define their PUT and DELETE
# operations as replaceable) or when the caller states that the operation
# is safe to repeat (`retry_safe`, for an operation whose model makes it so,
# such as an idempotency token the caller set). botocore resends every
# operation, POST included, which can repeat an awsJson write (an SQS
# SendMessage, a DynamoDB UpdateItem) after a 500 the service answered
# having already applied it. For a request that is not retry-safe:
#
#   resent      a dial that failed before any byte was sent (CONNECT_FAILED,
#               CONNECT_TIMEOUT, TLS_HANDSHAKE_FAILED); a throttling code
#               (the service refused the request); RequestTimeout and
#               RequestTimeoutException (the service never read the whole
#               request);
#   not resent  a transport error once the request may have been written,
#               500, 502, 503, 504 and InternalError.
#
# What botocore's standard mode also does and this does not: retry an error
# shape the model marks `retryable` (no model this repository generates from
# carries one on the operations it emits), and keep one retry quota per
# client (the free `send_sigv4_signed_request` has nowhere to keep one; a
# caller that wants one passes a `TokenBucket` to
# `send_sigv4_signed_request_with`).
# =============================================================================

from komira_retry import Backoff, Jitter, RetryClassifier, RetryPolicy, Verdict

from ._text import sub
from .creds_source import AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS


# botocore: `DEFAULT_MAX_ATTEMPTS` of standard mode, every send counted.
comptime AWS_STANDARD_MAX_ATTEMPTS = 3
# botocore's ExponentialBackoff: base 1 s doubling, capped at 20 s
# (`_MAX_BACKOFF`), drawn uniformly from [0, cap] (full jitter).
comptime AWS_RETRY_BASE_MS = 1000
comptime AWS_RETRY_MAX_BACKOFF_MS = 20_000
# A retry costs this from a budget, and a timed-out one AWS_TIMEOUT_RETRY_COST.
comptime AWS_RETRY_COST = 5
comptime AWS_TIMEOUT_RETRY_COST = 10


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


def aws_method_is_idempotent(method: String) -> Bool:
    """GET, HEAD, OPTIONS, PUT and DELETE (RFC 9110 section 9.2.2)."""
    return (
        method == "GET"
        or method == "HEAD"
        or method == "OPTIONS"
        or method == "PUT"
        or method == "DELETE"
    )


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


def _is_unread_request_code(code: String) -> Bool:
    """The service timed out reading the request, so did not act on it."""
    return code == "RequestTimeout" or code == "RequestTimeoutException"


def _is_transient_status(status: Int) -> Bool:
    return status == 500 or status == 502 or status == 503 or status == 504


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


def _is_unsent_kind(kind: String) -> Bool:
    """A dial that failed before any request byte was written."""
    return (
        kind == "CONNECT_FAILED"
        or kind == "CONNECT_TIMEOUT"
        or kind == "TLS_HANDSHAKE_FAILED"
    )


def _is_sent_transient_kind(kind: String) -> Bool:
    """A transport failure once the request may have been written."""
    return (
        kind == "IO_ERROR"
        or kind == "RETRYABLE_TRANSPORT"
        or kind == "EOF_MID_RESPONSE"
        or kind == "TIMEOUT"
    )


struct AwsAttempt(Copyable, Movable):
    """One failed attempt of a signed AWS send.

    - `status`: the HTTP status, -1 when no response arrived (a transport
      error); S3's 200-with-<Error> is recorded as 500.
    - `code`: the AWS error code the response names, "" for none.
    - `transport_error`: the transport's error message, "" for a response.
    - `retry_safe`: whether the request may be resent after the service
      may have acted on it (see the module header).
    """

    var status: Int
    var code: String
    var transport_error: String
    var retry_safe: Bool

    def __init__(
        out self,
        status: Int,
        var code: String,
        var transport_error: String,
        retry_safe: Bool,
    ):
        self.status = status
        self.code = code^
        self.transport_error = transport_error^
        self.retry_safe = retry_safe

    @staticmethod
    def response(status: Int, var code: String, retry_safe: Bool) -> AwsAttempt:
        """A response with an error status (or S3's 200-with-<Error>, as
        500) naming `code`."""
        return AwsAttempt(status, code^, String(""), retry_safe)

    @staticmethod
    def transport(var message: String, retry_safe: Bool) -> AwsAttempt:
        """No response: the transport raised `message`."""
        return AwsAttempt(-1, String(""), message^, retry_safe)


struct AwsRetryClassifier(RetryClassifier, Copyable, Movable):
    """botocore's standard-mode retry conditions over an `AwsAttempt`, with
    the retry-safety rule of the module header."""

    comptime Outcome = AwsAttempt

    def __init__(out self):
        pass

    def classify(self, outcome: AwsAttempt) -> Verdict:
        if outcome.status < 0:
            var kind = aws_transport_error_kind(outcome.transport_error)
            var cost = AWS_TIMEOUT_RETRY_COST if (
                kind == "CONNECT_TIMEOUT" or kind == "TIMEOUT"
            ) else AWS_RETRY_COST
            if _is_unsent_kind(kind):
                return Verdict.transient(
                    String("transport error before the request was sent: ")
                    + outcome.transport_error,
                    cost=cost,
                )
            if _is_sent_transient_kind(kind):
                if not outcome.retry_safe:
                    return Verdict.stop(
                        String("transport error after the request may have")
                        + " been sent, on a request that is not retry-safe: "
                        + outcome.transport_error
                    )
                return Verdict.transient(
                    String("transport error: ") + outcome.transport_error,
                    cost=cost,
                )
            return Verdict.stop(
                String("transport error: ") + outcome.transport_error
            )
        var what = String("HTTP ") + String(outcome.status)
        if outcome.code.byte_length() > 0:
            what += String(" ") + outcome.code
        if aws_is_throttling_code(outcome.code):
            return Verdict.throttle(String("throttled: ") + what)
        if _is_unread_request_code(outcome.code):
            return Verdict.transient(String("transient: ") + what)
        if _is_transient_status(outcome.status) or outcome.code == "InternalError":
            if not outcome.retry_safe:
                return Verdict.stop(
                    String("not resent, the request is not retry-safe: ") + what
                )
            return Verdict.transient(String("transient: ") + what)
        return Verdict.stop(what^)
