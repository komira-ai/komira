# =============================================================================
# komira_aws_core/tests/test_aws_retry.mojo
# =============================================================================
#
# AwsRetryClassifier, row by row against botocore's standard retry mode
# (botocore/retries/standard.py): the transient statuses and codes, every
# throttling code, the transport errors, the costs, and the retry-safety
# rule that is stricter than botocore (a request that is not retry-safe is
# resent only when the service cannot have acted on it). Then the standard
# policy: three sends, full jitter from 1 s capped at 20 s.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AWS_RETRY_COST,
    AWS_STANDARD_MAX_ATTEMPTS,
    AWS_TIMEOUT_RETRY_COST,
    AwsAttempt,
    AwsRetryClassifier,
    aws_is_throttling_code,
    aws_method_is_idempotent,
    aws_standard_retry_policy,
    aws_transport_error_kind,
)
from komira_retry import Verdict


def _verdict(status: Int, code: String, safe: Bool) -> Verdict:
    return AwsRetryClassifier().classify(AwsAttempt.response(status, code, safe))


def _transport(message: String, safe: Bool) -> Verdict:
    return AwsRetryClassifier().classify(AwsAttempt.transport(message, safe))


def test_transient_statuses() raises:
    for s in [500, 502, 503, 504]:
        var v = _verdict(s, String(""), True)
        assert_true(v.retryable, String(s))
        assert_false(v.throttled, String(s))
        assert_equal(v.cost, AWS_RETRY_COST)
    for s in [400, 403, 404, 409, 412, 501, 505]:
        assert_false(_verdict(s, String(""), True).retryable, String(s))


def test_transient_codes() raises:
    # Retried whatever the status says.
    for code in ["RequestTimeout", "RequestTimeoutException", "InternalError"]:
        var v = _verdict(400, String(code), True)
        assert_true(v.retryable, code)
        assert_false(v.throttled, code)
    # Not botocore's: a precondition failure or a missing key stays an error.
    for code in ["PreconditionFailed", "NoSuchKey", "NoSuchUpload", "AccessDenied"]:
        assert_false(_verdict(400, String(code), True).retryable, code)


def test_every_throttling_code() raises:
    var codes: List[String] = [
        "Throttling",
        "ThrottlingException",
        "ThrottledException",
        "RequestThrottledException",
        "TooManyRequestsException",
        "ProvisionedThroughputExceededException",
        "TransactionInProgressException",
        "RequestLimitExceeded",
        "BandwidthLimitExceeded",
        "LimitExceededException",
        "RequestThrottled",
        "SlowDown",
        "PriorRequestNotComplete",
        "EC2ThrottledException",
    ]
    for i in range(len(codes)):
        assert_true(aws_is_throttling_code(codes[i]), codes[i])
        # A throttle is retried even on a request that is not retry-safe:
        # the service refused it.
        var v = _verdict(400, codes[i], False)
        assert_true(v.retryable, codes[i])
        assert_true(v.throttled, codes[i])
        assert_equal(v.cost, AWS_RETRY_COST)
    assert_false(aws_is_throttling_code(String("Throttled")))
    assert_false(aws_is_throttling_code(String("throttling")))
    # S3's 503 SlowDown is a throttle, and so retried on any request.
    assert_true(_verdict(503, String("SlowDown"), False).throttled)


def test_transport_errors() raises:
    assert_equal(
        aws_transport_error_kind(String("HttpError[CONNECT_FAILED]: errno 111")),
        "CONNECT_FAILED",
    )
    # The client's own spelling of a short body.
    assert_equal(
        aws_transport_error_kind(
            String("HttpError[EOF_MID_RESPONSE: short body CL=100 got=3]: collect_body")
        ),
        "EOF_MID_RESPONSE",
    )
    assert_equal(aws_transport_error_kind(String("no stream armed")), "")
    assert_equal(aws_transport_error_kind(String("HttpError[IO_ERROR")), "")
    # Before the request was sent: retried on any request.
    for m in [
        "HttpError[CONNECT_FAILED]: refused",
        "HttpError[TLS_HANDSHAKE_FAILED]: alert",
    ]:
        var v = _transport(String(m), False)
        assert_true(v.retryable, m)
        assert_equal(v.cost, AWS_RETRY_COST)
    var ct = _transport(String("HttpError[CONNECT_TIMEOUT]: dial"), False)
    assert_true(ct.retryable)
    assert_equal(ct.cost, AWS_TIMEOUT_RETRY_COST)
    # After it may have been sent: retried only on a retry-safe request.
    for m in [
        "HttpError[IO_ERROR]: errno 104",
        "HttpError[RETRYABLE_TRANSPORT]: reset",
        "HttpError[EOF_MID_RESPONSE]: eof",
        "HttpError[TIMEOUT]: request",
    ]:
        assert_true(_transport(String(m), True).retryable, m)
        assert_false(_transport(String(m), False).retryable, m)
    assert_equal(
        _transport(String("HttpError[TIMEOUT]: request"), True).cost,
        AWS_TIMEOUT_RETRY_COST,
    )
    # Neither a certificate nor a malformed URL nor an unknown failure gets
    # better on a retry.
    for m in [
        "HttpError[TLS_VERIFY_FAILED]: name",
        "HttpError[URL_INVALID]: host",
        "HttpError[BODY_TOO_LARGE]: limit",
        "something else",
    ]:
        assert_false(_transport(String(m), True).retryable, m)


def test_a_request_that_is_not_retry_safe() raises:
    # The service may have acted: not resent.
    for s in [500, 502, 503, 504]:
        assert_false(_verdict(s, String(""), False).retryable, String(s))
    assert_false(_verdict(200, String("InternalError"), False).retryable)
    # It never read the whole request: resent.
    assert_true(_verdict(400, String("RequestTimeout"), False).retryable)


def test_idempotent_methods() raises:
    for m in ["GET", "HEAD", "OPTIONS", "PUT", "DELETE"]:
        assert_true(aws_method_is_idempotent(String(m)), m)
    for m in ["POST", "PATCH", "get", ""]:
        assert_false(aws_method_is_idempotent(String(m)), m)


def test_standard_policy() raises:
    var p = aws_standard_retry_policy()
    assert_equal(AWS_STANDARD_MAX_ATTEMPTS, 3)
    assert_equal(p.max_attempts, 3)
    assert_equal(p.backoff.initial_ms, 1000)
    assert_equal(p.backoff.max_ms, 20_000)
    assert_equal(p.backoff.multiplier, 2.0)
    assert_true(p.backoff.jitter.is_full())
    # The credential's mandatory refresh window: 10 minutes.
    assert_equal(p.deadline_ms, 600_000)
    assert_equal(aws_standard_retry_policy(5).max_attempts, 5)


def main() raises:
    test_transient_statuses()
    test_transient_codes()
    test_every_throttling_code()
    test_transport_errors()
    test_a_request_that_is_not_retry_safe()
    test_idempotent_methods()
    test_standard_policy()
    print("OK")
