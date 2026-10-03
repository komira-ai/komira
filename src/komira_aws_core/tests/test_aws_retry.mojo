# =============================================================================
# komira_aws_core/tests/test_aws_retry.mojo
# =============================================================================
#
# AwsRetryClassifier and aws_standard_retry_policy against botocore's
# standard retry mode. botocore/retries/standard.py is read from the botocore
# archive //third_party/botocore pins (`:retries`), staged at its path in
# it, and read as text (no Python runs): every entry of
# `_THROTTLED_ERROR_CODES`, `_TRANSIENT_ERROR_CODES` and
# `_TRANSIENT_STATUS_CODES`, and `DEFAULT_MAX_ATTEMPTS`, `_BASE`,
# `_MAX_BACKOFF`, `_RETRY_COST` and `_TIMEOUT_RETRY_REQUEST`, are checked
# against the classifier and the policy, so a new pin that changes one of
# them turns this red.
#
# Then the transport errors, in the text the stack raises them with
# (komira_http_client, its kernel and TLS dials, name resolution), and the
# retry-safety rule that is stricter than botocore (a request that is not
# retry-safe is resent only when the service cannot have acted on it).
# test_aws_send dials a closed loopback port through the kernel connector,
# so the dial's own text is pinned there too.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AWS_RETRY_COST,
    AWS_STANDARD_MAX_ATTEMPTS,
    AWS_TIMEOUT_RETRY_COST,
    AwsAttempt,
    AwsRetryClassifier,
    aws_is_throttling_code,
    aws_is_transient_code,
    aws_is_transient_status,
    aws_method_is_idempotent,
    aws_standard_retry_policy,
    aws_transport_error_kind,
    aws_transport_error_unsent,
)
from komira_retry import Verdict


comptime _STANDARD = "botocore/retries/standard.py"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _after(src: String, marker: String) raises -> Int:
    """The offset just past the one occurrence of `marker` in `src`."""
    var at = src.find(marker)
    if at < 0:
        raise Error(String(_STANDARD) + " has no `" + marker + "`")
    if src.find(marker, at + 1) >= 0:
        raise Error(String(_STANDARD) + " has `" + marker + "` twice")
    return at + marker.byte_length()


def _int_const(src: String, name: String, indented: Bool) raises -> Int:
    """`name = <int>` on a line of its own (at the margin, or indented in a
    class body)."""
    var lead = String(" ") if indented else String("\n")
    var start = _after(src, lead + name + " = ")
    var end = src.find("\n", start)
    return Int(String(src[byte=start:end].strip()))


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


def _verdict(status: Int, code: String, safe: Bool) -> Verdict:
    return AwsRetryClassifier().classify(AwsAttempt.response(status, code, safe))


def _transport(message: String, safe: Bool) -> Verdict:
    return AwsRetryClassifier().classify(AwsAttempt.transport(message, safe))


def test_throttling_codes_are_botocores(src: String) raises:
    var codes = _quoted(_list_body(src, "_THROTTLED_ERROR_CODES"))
    assert_true(len(codes) > 0)
    for i in range(len(codes)):
        assert_true(aws_is_throttling_code(codes[i]), codes[i])
        # A throttle is retried even on a request that is not retry-safe:
        # the service refused it.
        var v = _verdict(400, codes[i], False)
        assert_true(v.retryable, codes[i])
        assert_true(v.throttled, codes[i])
        assert_equal(v.cost, AWS_RETRY_COST)
    for c in ["Throttled", "throttling", "InternalError", "RequestTimeout"]:
        assert_false(aws_is_throttling_code(String(c)), c)
    # S3's 503 SlowDown is a throttle, and so retried on any request.
    assert_true(_verdict(503, String("SlowDown"), False).throttled)


def test_transient_codes_are_botocores(src: String) raises:
    var codes = _quoted(_list_body(src, "_TRANSIENT_ERROR_CODES"))
    assert_true(len(codes) > 0)
    for i in range(len(codes)):
        assert_true(aws_is_transient_code(codes[i]), codes[i])
        # Retried whatever the status says.
        assert_true(_verdict(400, codes[i], True).retryable, codes[i])
    # Not botocore's: an InternalError code is retried only by its status
    # (S3's 200-with-<Error> reaches the classifier as a 500), and a
    # precondition failure or a missing key stays an error.
    for c in ["InternalError", "PreconditionFailed", "NoSuchKey", "NoSuchUpload", "AccessDenied"]:
        assert_false(aws_is_transient_code(String(c)), c)
        assert_false(_verdict(400, String(c), True).retryable, c)
    assert_true(_verdict(500, String("InternalError"), True).retryable)


def test_transient_statuses_are_botocores(src: String) raises:
    var statuses = _ints(_list_body(src, "_TRANSIENT_STATUS_CODES"))
    assert_true(len(statuses) > 0)
    for s in range(100, 600):
        var listed = False
        for i in range(len(statuses)):
            if statuses[i] == s:
                listed = True
        assert_equal(aws_is_transient_status(s), listed, String(s))
        assert_equal(_verdict(s, String(""), True).retryable, listed, String(s))
        if listed:
            var v = _verdict(s, String(""), True)
            assert_false(v.throttled, String(s))
            assert_equal(v.cost, AWS_RETRY_COST)


def test_policy_and_costs_are_botocores(src: String) raises:
    var p = aws_standard_retry_policy()
    assert_equal(AWS_STANDARD_MAX_ATTEMPTS, _int_const(src, "DEFAULT_MAX_ATTEMPTS", False))
    assert_equal(p.max_attempts, AWS_STANDARD_MAX_ATTEMPTS)
    # ExponentialBackoff: rand(0, 1) * min(_BASE ** (attempt - 1),
    # _MAX_BACKOFF) seconds, so 1 s doubling up to the cap.
    var base = _int_const(src, "_BASE", True)
    assert_equal(p.backoff.multiplier, Float64(base))
    assert_equal(p.backoff.initial_ms, 1000)
    assert_equal(p.backoff.max_ms, Int64(_int_const(src, "_MAX_BACKOFF", True) * 1000))
    assert_true(p.backoff.jitter.is_full())
    assert_equal(AWS_RETRY_COST, _int_const(src, "_RETRY_COST", True))
    assert_equal(AWS_TIMEOUT_RETRY_COST, _int_const(src, "_TIMEOUT_RETRY_REQUEST", True))
    # What aws_retry.mojo's header says the pin has and this does not use
    # by default: DynamoDB's 4 attempts.
    var service = _after(src, "_SERVICE_MAX_ATTEMPTS = {")
    var block = String(src[byte=service : src.find("}", service)])
    assert_true(block.find("'dynamodb': 4") >= 0, block)
    # The credential's mandatory refresh window: 10 minutes.
    assert_equal(p.deadline_ms, 600_000)
    assert_equal(aws_standard_retry_policy(4).max_attempts, 4)


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


def test_errors_before_the_request_was_sent() raises:
    # Retried on any request: nothing reached the service.
    var unsent: List[String] = [
        # komira_http_client's vocabulary (its timeout layer, a scripted dial).
        "HttpError[CONNECT_FAILED]: connect errno=111 on dial #1",
        "HttpError[TLS_HANDSHAKE_FAILED]: alert",
        # The kernel dial (komira_async's TcpStream.connect).
        "TcpStream.connect: connect() error",
        "TcpStream.connect: connect failed (errno=111)",
        # The TLS dial (komira_http_client's TlsConnector).
        "TlsConnector.connect: handshake failed (s2n_errno=402653198,"
        " msg='Connection reset by peer', debug='', last_handshake_msg='')",
        # Name resolution (komira_net).
        "DnsError[TRANSIENT]: temporary failure resolving 's3.amazonaws.com'"
        " (EAI_AGAIN)",
        "DnsError[RESOLVE_FAILED]: getaddrinfo('s3.amazonaws.com') failed (EAI=-11)",
        # komira_http_client's proofs that the peer took no action.
        "HttpError[RETRYABLE_TRANSPORT]: write errno=32 on a reused"
        " connection [NOTHING-WRITTEN]",
        "HttpError[RETRYABLE_TRANSPORT]: server sent RST_STREAM(REFUSED_STREAM)"
        " on stream 3",
        "HttpError[H2_PROTOCOL]: GOAWAY received; stream 5 > last_stream_id 3;"
        " will not be processed [h2-goaway-unprocessed]",
    ]
    for i in range(len(unsent)):
        assert_true(aws_transport_error_unsent(unsent[i]), unsent[i])
        var v = _transport(unsent[i], False)
        assert_true(v.retryable, unsent[i])
        assert_equal(v.cost, AWS_RETRY_COST, unsent[i])
    # A timed-out dial costs the timeout's price.
    var timed_out: List[String] = [
        "HttpError[CONNECT_TIMEOUT]: connect phase exceeded 5000000us",
        "TcpStream.connect: connect timed out after 5000000us",
        "TlsConnector.connect: TLS handshake to 's3.amazonaws.com' did not"
        " complete within its wall-clock budget — elapsed_ms=10001",
    ]
    for i in range(len(timed_out)):
        var v = _transport(timed_out[i], False)
        assert_true(v.retryable, timed_out[i])
        assert_equal(v.cost, AWS_TIMEOUT_RETRY_COST, timed_out[i])


def test_errors_once_the_request_may_have_been_sent() raises:
    # Retried only on a retry-safe request.
    var maybe: List[String] = [
        "HttpError[IO_ERROR]: errno 104",
        # RETRYABLE_TRANSPORT without the proof: the peer may have read the
        # whole request and acted on it before dying.
        "HttpError[RETRYABLE_TRANSPORT]: peer closed before any response byte",
        "HttpError[EOF_MID_RESPONSE]: eof",
        "HttpError[TIMEOUT]: request",
        # The GOAWAY class the peer may have processed.
        "HttpError[H2_PROTOCOL]: GOAWAY received; stream 3 <= last_stream_id 3"
        " [h2-goaway-maybe-processed]",
    ]
    for i in range(len(maybe)):
        assert_false(aws_transport_error_unsent(maybe[i]), maybe[i])
        assert_false(_transport(maybe[i], False).retryable, maybe[i])
    for i in range(4):
        assert_true(_transport(maybe[i], True).retryable, maybe[i])
    assert_equal(
        _transport(String("HttpError[TIMEOUT]: request"), True).cost,
        AWS_TIMEOUT_RETRY_COST,
    )


def test_errors_a_retry_does_not_fix() raises:
    for m in [
        # A certificate refused in the handshake.
        "TlsConnector.connect: handshake failed (s2n_errno=335544366,"
        " msg='Certificate is untrusted', debug='', last_handshake_msg='')",
        "TlsConnector: refusing VERIFY_PEER connect with an empty server name",
        "HttpError[TLS_VERIFY_FAILED]: name",
        "DnsError[NXDOMAIN]: no such host 'nope.invalid' (EAI_NONAME)",
        "dns: malformed IPv4 literal '1.2.3'",
        "HttpError[URL_INVALID]: host",
        "HttpError[BODY_TOO_LARGE]: limit",
        "something else",
    ]:
        assert_false(aws_transport_error_unsent(String(m)), m)
        assert_false(_transport(String(m), True).retryable, m)


def test_a_request_that_is_not_retry_safe() raises:
    # The service may have acted: not resent.
    for s in [500, 502, 503, 504]:
        assert_false(_verdict(s, String(""), False).retryable, String(s))
    # It never read the whole request: resent.
    assert_true(_verdict(400, String("RequestTimeout"), False).retryable)
    assert_true(_verdict(400, String("RequestTimeoutException"), False).retryable)
    # PriorRequestNotComplete is a throttle too, so resent.
    assert_true(_verdict(400, String("PriorRequestNotComplete"), False).throttled)


def test_idempotent_methods() raises:
    for m in ["GET", "HEAD", "OPTIONS", "PUT", "DELETE"]:
        assert_true(aws_method_is_idempotent(String(m)), m)
    for m in ["POST", "PATCH", "get", ""]:
        assert_false(aws_method_is_idempotent(String(m)), m)


def main() raises:
    var src = _read(_STANDARD)
    test_throttling_codes_are_botocores(src)
    test_transient_codes_are_botocores(src)
    test_transient_statuses_are_botocores(src)
    test_policy_and_costs_are_botocores(src)
    test_transport_error_kind()
    test_errors_before_the_request_was_sent()
    test_errors_once_the_request_may_have_been_sent()
    test_errors_a_retry_does_not_fix()
    test_a_request_that_is_not_retry_safe()
    test_idempotent_methods()
    print("OK")
