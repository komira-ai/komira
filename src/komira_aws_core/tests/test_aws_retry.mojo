# =============================================================================
# komira_aws_core/tests/test_aws_retry.mojo
# =============================================================================
#
# AwsRetryClassifier, aws_standard_retry_policy and AwsRetryQuota against
# botocore's standard retry mode.
# botocore/retries/standard.py, quota.py and special.py are read from the
# botocore archive //third_party/botocore pins (`:retries`), staged at
# their paths in it, and read as text (no Python runs): every entry of
# `_THROTTLED_ERROR_CODES`, `_TRANSIENT_ERROR_CODES` and
# `_TRANSIENT_STATUS_CODES`, the transient and timeout exception classes,
# `DEFAULT_MAX_ATTEMPTS` (and that the per-service limits are read only on
# the path behind the off-by-default `NEW_RETRIES_ENABLED`), `_BASE`,
# `_MAX_BACKOFF`, `_RETRY_COST`, `_TIMEOUT_RETRY_REQUEST`,
# `_NO_RETRY_INCREMENT`, the quota's `INITIAL_CAPACITY`, and the special
# cases' services, code and header, are checked against the classifier,
# the policy and the quota, so a new pin that changes one of them turns
# this red.
#
# Then the transport errors, in the text the stack raises them with
# (komira_http_client, its kernel and TLS dials, name resolution): every
# one is retried, as botocore retries every failure of its HTTP send, but
# a body over the client's own cap, and the timeouts cost more; and for a
# conditional write, the one exception (aws_retry.mojo's header), which of
# them were raised before the request was sent and are still resent. test_aws_send dials a closed loopback port
# through the kernel connector, so the dial's own text is pinned there too.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AWS_DYNAMODB_CRC32_HEADER,
    AWS_IDP_COMMUNICATION_ERROR,
    AWS_NO_RETRY_INCREMENT,
    AWS_RETRY_COST,
    AWS_RETRY_QUOTA_CAPACITY,
    AWS_STANDARD_MAX_ATTEMPTS,
    AWS_TIMEOUT_RETRY_COST,
    AwsAttempt,
    AwsRetryClassifier,
    AwsRetryQuota,
    Header,
    aws_dynamodb_crc32_mismatch,
    aws_is_throttling_code,
    aws_is_transient_code,
    aws_is_transient_status,
    aws_request_is_conditional,
    aws_standard_retry_policy,
    aws_transport_error_is_timeout,
    aws_transport_error_kind,
    aws_transport_error_unsent,
)
from komira_retry import Verdict


comptime _STANDARD = "botocore/retries/standard.py"
comptime _QUOTA = "botocore/retries/quota.py"
comptime _SPECIAL = "botocore/retries/special.py"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _after(src: String, marker: String) raises -> Int:
    """The offset just past the one occurrence of `marker` in `src`."""
    var at = src.find(marker)
    if at < 0:
        raise Error(String("botocore has no `") + marker + "`")
    if src.find(marker, at + 1) >= 0:
        raise Error(String("botocore has `") + marker + "` twice")
    return at + marker.byte_length()


def _int_const(src: String, name: String, indented: Bool) raises -> Int:
    """`name = <int>` on a line of its own (at the margin, or indented in a
    class body)."""
    var lead = String(" ") if indented else String("\n")
    var start = _after(src, lead + name + " = ")
    var end = src.find("\n", start)
    return Int(String(src[byte=start:end].strip()))


def _str_const(body: String, name: String) raises -> String:
    """`name = '<text>'` in `body`, the one occurrence."""
    var start = _after(body, name + " = '")
    var end = body.find("'", start)
    return String(body[byte=start:end])


def _class_body(src: String, name: String) raises -> String:
    """The text of `class <name>` up to the next class at the margin."""
    var start = _after(src, String("\nclass ") + name)
    var end = src.find("\nclass ", start)
    if end < 0:
        end = src.byte_length()
    return String(src[byte=start:end])


def _list_body(src: String, name: String) raises -> String:
    """The text between the brackets of `name = [...]`."""
    var start = _after(src, name + " = [")
    var end = src.find("]", start)
    if end < 0:
        raise Error(String(_STANDARD) + ": `" + name + "` is not closed")
    return String(src[byte=start:end])


def _quoted(body: String) -> List[String]:
    """Each single-quoted string of `body`, in order."""
    var out = List[String]()
    var i = 0
    while True:
        var open = body.find("'", i)
        if open < 0:
            return out^
        var close = body.find("'", open + 1)
        if close < 0:
            return out^
        out.append(String(body[byte=open + 1 : close]))
        i = close + 1


def _ints(body: String) raises -> List[Int]:
    var out = List[Int]()
    for part in body.split(","):
        var t = String(part.strip())
        if t.byte_length() > 0:
            out.append(Int(t))
    return out^


def _verdict(status: Int, code: String, service: String = "sqs") -> Verdict:
    return AwsRetryClassifier(service.copy()).classify(
        AwsAttempt.response(status, code.copy())
    )


def _transport(message: String) -> Verdict:
    return AwsRetryClassifier(String("sqs")).classify(
        AwsAttempt.transport(message.copy())
    )


def test_throttling_codes_are_botocores(src: String) raises:
    var codes = _quoted(_list_body(src, "_THROTTLED_ERROR_CODES"))
    assert_true(len(codes) > 0)
    for i in range(len(codes)):
        assert_true(aws_is_throttling_code(codes[i]), codes[i])
        var v = _verdict(400, codes[i])
        assert_true(v.retryable, codes[i])
        assert_true(v.throttled, codes[i])
        assert_equal(v.cost, AWS_RETRY_COST)
    for c in ["Throttled", "throttling", "InternalError", "RequestTimeout"]:
        assert_false(aws_is_throttling_code(String(c)), c)
    assert_true(_verdict(503, String("SlowDown")).throttled)


def test_transient_codes_are_botocores(src: String) raises:
    var codes = _quoted(_list_body(src, "_TRANSIENT_ERROR_CODES"))
    assert_true(len(codes) > 0)
    for i in range(len(codes)):
        assert_true(aws_is_transient_code(codes[i]), codes[i])
        # Retried whatever the status says.
        assert_true(_verdict(400, codes[i]).retryable, codes[i])
    # Not botocore's: an InternalError code is retried only by its status
    # (S3's 200-with-<Error> reaches the classifier as a 500), and a
    # precondition failure or a missing key stays an error.
    for c in [
        "InternalError",
        "PreconditionFailed",
        "NoSuchKey",
        "NoSuchUpload",
        "AccessDenied",
    ]:
        assert_false(aws_is_transient_code(String(c)), c)
        assert_false(_verdict(400, String(c)).retryable, c)
    assert_true(_verdict(500, String("InternalError")).retryable)


def test_transient_statuses_are_botocores(src: String) raises:
    var statuses = _ints(_list_body(src, "_TRANSIENT_STATUS_CODES"))
    assert_true(len(statuses) > 0)
    for s in range(100, 600):
        var listed = False
        for i in range(len(statuses)):
            if statuses[i] == s:
                listed = True
        assert_equal(aws_is_transient_status(s), listed, String(s))
        assert_equal(_verdict(s, String("")).retryable, listed, String(s))
        if listed:
            var v = _verdict(s, String(""))
            assert_false(v.throttled, String(s))
            assert_equal(v.cost, AWS_RETRY_COST)


def test_no_condition_reads_the_operation(src: String) raises:
    # botocore's standard conditions are the attempt limit and the
    # transient, throttled, modeled and special checks: none of them reads
    # the request's method or whether the operation is idempotent, so every
    # operation is retried alike. A POST and a GET classify the same: the
    # classifier is not told the method at all.
    var conditions = _class_body(src, "StandardRetryConditions")
    for checker in [
        "MaxAttemptsChecker(max_attempts)",
        "TransientRetryableChecker()",
        "ThrottledRetryableChecker()",
        "ModeledRetryableChecker()",
        "special.RetryIDPCommunicationError()",
        "special.RetryDDBChecksumError()",
    ]:
        assert_true(conditions.find(checker) >= 0, checker)
    assert_true(src.lower().find("idempot") < 0)
    assert_true(src.find(".method") < 0)


def test_policy_and_costs_are_botocores(src: String) raises:
    var p = aws_standard_retry_policy()
    assert_equal(
        AWS_STANDARD_MAX_ATTEMPTS,
        _int_const(src, "DEFAULT_MAX_ATTEMPTS", False),
    )
    assert_equal(p.max_attempts, AWS_STANDARD_MAX_ATTEMPTS)
    # ExponentialBackoff: rand(0, 1) * min(_BASE ** (attempt - 1),
    # _MAX_BACKOFF) seconds, so 1 s doubling up to the cap.
    var base = _int_const(src, "_BASE", True)
    assert_equal(p.backoff.multiplier, Float64(base))
    assert_equal(p.backoff.initial_ms, 1000)
    assert_equal(
        p.backoff.max_ms, Int64(_int_const(src, "_MAX_BACKOFF", True) * 1000)
    )
    assert_true(p.backoff.jitter.is_full())
    assert_equal(AWS_RETRY_COST, _int_const(src, "_RETRY_COST", True))
    assert_equal(
        AWS_TIMEOUT_RETRY_COST,
        _int_const(src, "_TIMEOUT_RETRY_REQUEST", True),
    )
    # The credential's mandatory refresh window: 10 minutes.
    assert_equal(p.deadline_ms, 600_000)
    assert_equal(aws_standard_retry_policy(4).max_attempts, 4)


def test_quota_is_botocores(src: String, quota_src: String) raises:
    assert_equal(
        AWS_RETRY_QUOTA_CAPACITY,
        _int_const(quota_src, "INITIAL_CAPACITY", True),
    )
    assert_equal(AWS_NO_RETRY_INCREMENT, _int_const(src, "_NO_RETRY_INCREMENT", True))
    var q = AwsRetryQuota()
    assert_equal(q.available(), AWS_RETRY_QUOTA_CAPACITY)
    # A call that never retried puts back 1, never above the capacity.
    q.on_success(0)
    assert_equal(q.available(), AWS_RETRY_QUOTA_CAPACITY)
    # 100 retries at 5 empty it; the next is refused and spends nothing.
    for i in range(AWS_RETRY_QUOTA_CAPACITY // AWS_RETRY_COST):
        assert_true(q.try_spend(AWS_RETRY_COST), String(i))
    assert_equal(q.available(), 0)
    assert_false(q.try_spend(AWS_RETRY_COST))
    assert_equal(q.available(), 0)
    # A success puts back what the call's last retry cost, else 1.
    q.on_success(AWS_TIMEOUT_RETRY_COST)
    assert_equal(q.available(), AWS_TIMEOUT_RETRY_COST)
    q.on_success(0)
    assert_equal(q.available(), AWS_TIMEOUT_RETRY_COST + AWS_NO_RETRY_INCREMENT)
    assert_false(q.try_spend(-1))


def test_special_cases_are_botocores(special: String) raises:
    var idp = _class_body(special, "RetryIDPCommunicationError")
    assert_equal(_str_const(idp, "_SERVICE_NAME"), "sts")
    _ = _after(idp, String("error_code == '") + AWS_IDP_COMMUNICATION_ERROR + "'")
    assert_true(_verdict(400, String(AWS_IDP_COMMUNICATION_ERROR), "sts").retryable)
    assert_false(_verdict(400, String(AWS_IDP_COMMUNICATION_ERROR), "sqs").retryable)
    var ddb = _class_body(special, "RetryDDBChecksumError")
    assert_equal(_str_const(ddb, "_SERVICE_NAME"), "dynamodb")
    assert_equal(_str_const(ddb, "_CHECKSUM_HEADER"), AWS_DYNAMODB_CRC32_HEADER)
    var bad = AwsAttempt.response(200, String(""), crc32_mismatch=True)
    var v = AwsRetryClassifier(String("dynamodb")).classify(bad)
    assert_true(v.retryable)
    assert_equal(v.cost, AWS_RETRY_COST)
    assert_false(AwsRetryClassifier(String("s3")).classify(bad).retryable)
    # A DynamoDB 400 with a good checksum is an answer.
    assert_false(
        _verdict(
            400, String("ConditionalCheckFailedException"), "dynamodb"
        ).retryable
    )


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_dynamodb_crc32() raises:
    # zlib.crc32(b"{}") == 2745614147; of no bytes, 0.
    var body = _bytes(String("{}"))
    assert_false(aws_dynamodb_crc32_mismatch(String("2745614147"), body))
    assert_false(aws_dynamodb_crc32_mismatch(String(" 2745614147 "), body))
    assert_false(aws_dynamodb_crc32_mismatch(String("+0002745614147"), body))
    assert_false(aws_dynamodb_crc32_mismatch(String("0"), List[UInt8]()))
    assert_false(aws_dynamodb_crc32_mismatch(String(""), body))
    assert_true(aws_dynamodb_crc32_mismatch(String("2745614146"), body))
    assert_true(aws_dynamodb_crc32_mismatch(String("0"), body))
    assert_true(aws_dynamodb_crc32_mismatch(String("-2745614147"), body))
    assert_true(aws_dynamodb_crc32_mismatch(String("99999999999999999999"), body))
    # Not a number: botocore's int() raises, and nothing is retried here.
    for v in ["abc", "0x1", "12 34", "+", "-", "1.0"]:
        assert_false(aws_dynamodb_crc32_mismatch(String(v), body), v)


def test_transport_errors_are_botocores(src: String) raises:
    # botocore retries the exceptions its HTTP session raises: every failure
    # of a send is one of them (httpsession.py wraps any other exception as
    # HTTPClientError).
    var transient = _class_body(src, "TransientRetryableChecker")
    _ = _after(
        transient,
        "_TRANSIENT_EXCEPTION_CLS = (\n        ConnectionError,\n        HTTPClientError,\n    )",
    )
    _ = _after(src, "_TIMEOUT_EXCEPTIONS = (ConnectTimeoutError, ReadTimeoutError)")


def test_transport_error_kind() raises:
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


def test_every_transport_error_is_retried() raises:
    # Before a request byte was written, after it may have been read and
    # acted on, and those a retry does not fix: botocore resends after each
    # (ConnectionError, HTTPClientError; SSLError and EndpointConnectionError
    # are ConnectionErrors), whatever the operation.
    var errors: List[String] = [
        "HttpError[CONNECT_FAILED]: connect errno=111 on dial #1",
        "HttpError[TLS_HANDSHAKE_FAILED]: alert",
        "TcpStream.connect: connect() error",
        "TcpStream.connect: connect failed (errno=111)",
        "TlsConnector.connect: handshake failed (s2n_errno=402653198,"
        " msg='Connection reset by peer', debug='', last_handshake_msg='')",
        "DnsError[TRANSIENT]: temporary failure resolving 's3.amazonaws.com'"
        " (EAI_AGAIN)",
        "DnsError[RESOLVE_FAILED]: getaddrinfo('s3.amazonaws.com') failed (EAI=-11)",
        "HttpError[RETRYABLE_TRANSPORT]: write errno=32 on a reused"
        " connection [NOTHING-WRITTEN]",
        "HttpError[RETRYABLE_TRANSPORT]: server sent RST_STREAM(REFUSED_STREAM)"
        " on stream 3",
        "HttpError[H2_PROTOCOL]: GOAWAY received; stream 5 > last_stream_id 3;"
        " will not be processed [h2-goaway-unprocessed]",
        "HttpError[IO_ERROR]: errno 104",
        "HttpError[RETRYABLE_TRANSPORT]: peer closed before any response byte",
        "HttpError[EOF_MID_RESPONSE]: eof",
        "HttpError[H2_PROTOCOL]: GOAWAY received; stream 3 <= last_stream_id 3"
        " [h2-goaway-maybe-processed]",
        "TlsConnector.connect: handshake failed (s2n_errno=335544366,"
        " msg='Certificate is untrusted', debug='', last_handshake_msg='')",
        "TlsConnector: refusing VERIFY_PEER connect with an empty server name",
        "HttpError[TLS_VERIFY_FAILED]: name",
        "DnsError[NXDOMAIN]: no such host 'nope.invalid' (EAI_NONAME)",
        "dns: malformed IPv4 literal '1.2.3'",
        "HttpError[URL_INVALID]: host",
        "something else",
    ]
    for i in range(len(errors)):
        assert_false(aws_transport_error_is_timeout(errors[i]), errors[i])
        var v = _transport(errors[i])
        assert_true(v.retryable, errors[i])
        assert_false(v.throttled, errors[i])
        assert_equal(v.cost, AWS_RETRY_COST, errors[i])
    # A timeout costs the timeout's price (botocore's ConnectTimeoutError
    # and ReadTimeoutError).
    var timed_out: List[String] = [
        "HttpError[CONNECT_TIMEOUT]: connect phase exceeded 5000000us",
        "HttpError[TIMEOUT]: request",
        "TcpStream.connect: connect timed out after 5000000us",
        "TlsConnector.connect: TLS handshake to 's3.amazonaws.com' did not"
        " complete within its wall-clock budget — elapsed_ms=10001",
    ]
    for i in range(len(timed_out)):
        assert_true(aws_transport_error_is_timeout(timed_out[i]), timed_out[i])
        var v = _transport(timed_out[i])
        assert_true(v.retryable, timed_out[i])
        assert_equal(v.cost, AWS_TIMEOUT_RETRY_COST, timed_out[i])
    # A body over komira_http_client's own cap: no resend changes its size.
    var too_large = String("HttpError[BODY_TOO_LARGE]: limit")
    assert_false(_transport(too_large).retryable)
    assert_false(_conditional_transport(too_large).retryable)


def test_a_post_classifies_as_any_request() raises:
    # A 5xx answer to an SQS SendMessage or an S3 CompleteMultipartUpload,
    # which may have been applied: retried, as botocore retries it.
    for s in [500, 502, 503, 504]:
        assert_true(_verdict(s, String(""), "sqs").retryable, String(s))
        assert_true(_verdict(s, String("InternalError"), "s3").retryable, String(s))
        assert_true(_verdict(s, String(""), "dynamodb").retryable, String(s))
    assert_true(_verdict(400, String("RequestTimeout")).retryable)
    assert_true(_verdict(400, String("PriorRequestNotComplete")).throttled)
    # Answers a retry does not change.
    for s in [400, 403, 404, 409, 412, 501]:
        assert_false(_verdict(s, String("")).retryable, String(s))


def test_the_attempt_limit_is_the_default_paths(src: String) raises:
    # The pinned `register_retry_handler` reads `_SERVICE_MAX_ATTEMPTS`
    # only on the path behind `NEW_RETRIES_ENABLED`, which is off by
    # default; the default path takes `max_attempts or
    # DEFAULT_MAX_ATTEMPTS` for every service, so DynamoDB gets three.
    var handler = _after(src, "\ndef register_retry_handler(")
    var gated = _after(src, "\n    if NEW_RETRIES_ENABLED:\n")
    var stock = _after(src, "\n    else:\n")
    assert_true(handler < gated and gated < stock)
    var lookup = _after(src, "_SERVICE_MAX_ATTEMPTS[")
    assert_true(gated < lookup and lookup < stock)
    var limit = _after(
        src, "max_attempts=max_attempts or DEFAULT_MAX_ATTEMPTS"
    )
    assert_true(stock < limit)
    assert_equal(aws_standard_retry_policy().max_attempts, 3)


def _conditional(status: Int, code: String) -> Verdict:
    return AwsRetryClassifier(String("s3"), conditional=True).classify(
        AwsAttempt.response(status, code.copy())
    )


def _conditional_transport(message: String) -> Verdict:
    return AwsRetryClassifier(String("s3"), conditional=True).classify(
        AwsAttempt.transport(message.copy())
    )


def test_request_is_conditional() raises:
    # The method and the headers decide, the header's name in any case,
    # either precondition, on any method but GET and HEAD.
    var h = List[Header]()
    assert_false(aws_request_is_conditional(String("PUT"), h))
    h.append(Header(String("x-amz-meta-if-match"), String("*")))
    h.append(Header(String("If-Modified-Since"), String("x")))
    h.append(Header(String("x-amz-copy-source-if-match"), String('"e"')))
    assert_false(aws_request_is_conditional(String("PUT"), h))
    var m = h.copy()
    m.append(Header(String("If-Match"), String('"e1"')))
    var n = h.copy()
    n.append(Header(String("iF-nOnE-mAtCh"), String("*")))
    for method in ["PUT", "POST", "DELETE", "PATCH"]:
        assert_true(aws_request_is_conditional(String(method), m), method)
        assert_true(aws_request_is_conditional(String(method), n), method)
    for method in ["GET", "HEAD"]:
        assert_false(aws_request_is_conditional(String(method), m), method)
        assert_false(aws_request_is_conditional(String(method), n), method)


def test_a_conditional_write_the_service_may_have_applied_is_not_retried() raises:
    # A 5xx, S3's 200-with-<Error> (a 500 here) and a transient code: the
    # write may have landed, and its resend would be answered 412.
    for s in [500, 502, 503, 504]:
        assert_false(_conditional(s, String("")).retryable, String(s))
        assert_false(_conditional(s, String("InternalError")).retryable, String(s))
    # A throttle: the service refused it. Resent, as any request is.
    for c in ["SlowDown", "Throttling", "PriorRequestNotComplete"]:
        var v = _conditional(503, String(c))
        assert_true(v.retryable, c)
        assert_true(v.throttled, c)
    # The service never read the whole request: resent. With a 5xx it may
    # have acted on it: not resent.
    for c in ["RequestTimeout", "RequestTimeoutException"]:
        assert_true(_conditional(400, String(c)).retryable, c)
        assert_false(_conditional(500, String(c)).retryable, c)
        assert_false(_conditional(503, String(c)).retryable, c)
        assert_true(_verdict(503, String(c), "s3").retryable, c)
    # Answers a retry does not change, alike.
    assert_false(_conditional(412, String("PreconditionFailed")).retryable)
    # Not conditional: the same 500 is retried.
    assert_true(_verdict(500, String(""), "s3").retryable)


def test_a_conditional_write_is_resent_only_after_an_unsent_transport_error() raises:
    var unsent: List[String] = [
        "HttpError[CONNECT_FAILED]: connect errno=111 on dial #1",
        "HttpError[CONNECT_TIMEOUT]: connect phase exceeded 5000000us",
        "HttpError[TLS_HANDSHAKE_FAILED]: alert",
        "HttpError[TLS_VERIFY_FAILED]: name",
        "HttpError[URL_INVALID]: host",
        "TcpStream.connect: connect failed (errno=111)",
        "TcpStream.connect: connect timed out after 5000000us",
        "TlsConnector.connect: handshake failed (s2n_errno=402653198,"
        " msg='Connection reset by peer', debug='', last_handshake_msg='')",
        "TlsConnector.connect: handshake failed (s2n_errno=335544366,"
        " msg='Certificate is untrusted', debug='', last_handshake_msg='')",
        "TlsConnector.connect: TLS handshake to 's3.amazonaws.com' did not"
        " complete within its wall-clock budget — elapsed_ms=10001",
        "TlsConnector: refusing VERIFY_PEER connect with an empty server name",
        "DnsError[TRANSIENT]: temporary failure resolving 's3.amazonaws.com'"
        " (EAI_AGAIN)",
        "DnsError[NXDOMAIN]: no such host 'nope.invalid' (EAI_NONAME)",
        "dns: malformed IPv4 literal '1.2.3'",
        "HttpError[RETRYABLE_TRANSPORT]: write errno=32 on a reused"
        " connection [NOTHING-WRITTEN]",
        "HttpError[RETRYABLE_TRANSPORT]: server sent RST_STREAM(REFUSED_STREAM)"
        " on stream 3",
        "HttpError[H2_PROTOCOL]: GOAWAY received; stream 5 > last_stream_id 3;"
        " will not be processed [h2-goaway-unprocessed]",
    ]
    for i in range(len(unsent)):
        assert_true(aws_transport_error_unsent(unsent[i]), unsent[i])
        assert_true(_conditional_transport(unsent[i]).retryable, unsent[i])
    # The connect timeout still costs the timeout's price.
    assert_equal(_conditional_transport(unsent[1]).cost, AWS_TIMEOUT_RETRY_COST)
    var maybe_sent: List[String] = [
        "HttpError[IO_ERROR]: errno 104",
        "HttpError[RETRYABLE_TRANSPORT]: peer closed before any response byte",
        "HttpError[EOF_MID_RESPONSE]: eof",
        "HttpError[TIMEOUT]: request",
        "HttpError[H2_PROTOCOL]: GOAWAY received; stream 3 <= last_stream_id 3"
        " [h2-goaway-maybe-processed]",
        "something else",
    ]
    for i in range(len(maybe_sent)):
        assert_false(aws_transport_error_unsent(maybe_sent[i]), maybe_sent[i])
        assert_false(_conditional_transport(maybe_sent[i]).retryable, maybe_sent[i])
        # Not conditional: retried, as botocore retries it.
        assert_true(_transport(maybe_sent[i]).retryable, maybe_sent[i])


def main() raises:
    var src = _read(_STANDARD)
    test_throttling_codes_are_botocores(src)
    test_transient_codes_are_botocores(src)
    test_transient_statuses_are_botocores(src)
    test_no_condition_reads_the_operation(src)
    test_policy_and_costs_are_botocores(src)
    test_the_attempt_limit_is_the_default_paths(src)
    test_quota_is_botocores(src, _read(_QUOTA))
    test_special_cases_are_botocores(_read(_SPECIAL))
    test_dynamodb_crc32()
    test_transport_errors_are_botocores(src)
    test_transport_error_kind()
    test_every_transport_error_is_retried()
    test_a_post_classifies_as_any_request()
    test_request_is_conditional()
    test_a_conditional_write_the_service_may_have_applied_is_not_retried()
    test_a_conditional_write_is_resent_only_after_an_unsent_transport_error()
    print("OK")
