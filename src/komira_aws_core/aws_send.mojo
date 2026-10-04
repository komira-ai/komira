# =============================================================================
# komira_aws_core/aws_send.mojo -- the transport half of a send
# =============================================================================
#
# `send_sigv4_signed_request` is what a generated client's `send` calls: it
# signs the request (`build_sigv4_signed_request`), sends it over
# komira_http_client through the connector the client's factory makes, and
# retries a failed attempt as `AwsRetryClassifier` and the AWS SDKs'
# standard retry mode say (aws_retry.mojo), spending from the client's
# `AwsRetryQuota`. Every operation is retried alike, whatever its method,
# as botocore retries it, but for a conditional write the service may have
# acted on (`aws_request_is_conditional`, read off the method and `extra`),
# which is not resent. It returns the last response, successful or not:
# a generated client raises a failed one with its own error builder. When
# no response arrives and the failure is not retried, it raises.
#
# EVERY ATTEMPT IS SIGNED AGAIN, reading the clock again (`AwsClock`), so a
# retry carries a fresh X-Amz-Date: a signature older than five minutes is
# answered RequestTimeTooSkewed. Every attempt is signed with the credential
# the client read for the call; `DefaultChainCredsSource` hands out one with
# at least its mandatory refresh window left, and that window is the retry
# deadline (`aws_standard_retry_policy`).
#
# S3's 200 whose body is an <Error> (botocore's `_handle_200_error`) is read
# here as a 500 when the caller says the operation can answer one
# (`s3_200_error`). The generated S3 client says so for each operation
# botocore's `_should_handle_200_error` names: one with an output shape
# whose payload is not a blob or a string, so not GetObject, whose body may
# be an object that is itself an XML document with an <Error> root.
#
# A DynamoDB response whose `x-amz-crc32` is not its body's CRC-32 is a
# failed attempt too, a 200 included (botocore's `RetryDDBChecksumError`);
# once no retry follows it is returned as it is.
#
# `send_sigv4_signed_request_with` is the same send over injected seams:
# the transport (`AwsHttpTransport`), the signing clock, the retry loop (its
# monotonic clock, sleeper and random source) and a retry budget (the
# client's `AwsRetryQuota`, or any komira_retry `RetryBudget`). The
# hermetic tests drive it with a scripted connector, a stepping clock and a
# sleeper that records; `send_sigv4_signed_request` binds the process's
# clocks and a blocking sleep.
#
# The connector is made once per call, so the attempts of one call share
# its HTTP client (and a kept-alive connection) and the connector's dials.
# That client is built from the caller's `HttpClientConfig`, which has no
# default: it bounds each attempt (`request_timeout_us`) and the response
# body. A process serving requests under a platform deadline passes
# `HttpClientConfig.for_serving_ceiling(ceiling_us)`; clamping to that
# ceiling is the caller's job, not this function's.
# The HTTP client runs on a `BlockingRuntime`: the call blocks its thread.
# Nothing is pooled across calls.
#
# A RESPONSE BODY IS BUFFERED WHOLE, up to komira_http_client's default cap
# of 100 MiB (`HttpClientConfig.max_response_body_bytes`). A larger body,
# such as an S3 GetObject of a bigger object without a Range, fails with
# `HttpError[BODY_TOO_LARGE]`, which is raised at once, not retried: no
# resend changes the size (botocore has no cap). Read such an object in
# ranges.
#
# The retry loop runs on komira_clock's monotonic clock and waits in a
# reactor (`AwsReactorSleeper`), not on komira_retry's `SystemClock` and
# `SystemSleeper`. Those call `std.time.sleep`, whose foreign declaration of
# libc's `nanosleep` has a different signature from the one komira_async's
# reactor makes (it passes the timespec as a byte pointer and returns an
# Int32), and one program cannot hold both declarations: a binary holding
# the HTTP client cannot also hold them. Once those declarations agree,
# `aws_system_retry_loop` becomes komira_retry's `system_retry_loop`.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import BytesBody
from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_clock import now_ns
from komira_retry import (
    MonotonicClock,
    RetryBudget,
    RetryLoop,
    RetryPolicy,
    RetryRng,
    Sleeper,
    SplitMix64Rng,
)

from ._text import sub
from .aws_codec import aws_is_error_status
from .aws_error import aws_json_error_info
from .aws_request import HttpResult
from .aws_retry import (
    AWS_DYNAMODB_CRC32_HEADER,
    AwsAttempt,
    AwsRetryClassifier,
    AwsRetryQuota,
    aws_dynamodb_crc32_mismatch,
    aws_request_is_conditional,
    aws_standard_retry_policy,
)
from .aws_xml import aws_xml_body_is_error, aws_xml_error_info
from .credential import AwsCredential
from .credential_transport import CredentialHttpRequest
from .endpoint import AwsEndpoint
from .signed_request import AwsPayloadSigning, build_sigv4_signed_request
from .sigv4 import Header
from .sources import AwsClock, SystemAwsClock


trait AwsHttpTransport(Movable, Deinitable):
    """Sends one signed request and returns the response. Raises when no
    response arrives; the message of a komira_http_client failure starts
    `HttpError[<kind>]`, which `AwsRetryClassifier` reads."""

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        ...


def _http_method(method: String) raises -> HttpMethod:
    if method == "GET":
        return HttpMethod.get()
    if method == "PUT":
        return HttpMethod.put()
    if method == "POST":
        return HttpMethod.post()
    if method == "DELETE":
        return HttpMethod.delete()
    if method == "HEAD":
        return HttpMethod.head()
    if method == "PATCH":
        return HttpMethod.patch()
    if method == "OPTIONS":
        return HttpMethod.options()
    raise Error("an AWS request method is not one HTTP sends: " + method)


def _url_of(req: CredentialHttpRequest) -> Url:
    """The request's URL: its scheme, host (an IPv6 literal without its
    brackets), port, and target split at the first '?'."""
    var host = req.host.copy()
    var n = req.host.byte_length()
    if n >= 2 and req.host.startswith("[") and req.host.endswith("]"):
        host = sub(req.host, 1, n - 1)
    var path = req.target.copy()
    var query = String("")
    var q = req.target.find("?")
    if q >= 0:
        path = sub(req.target, 0, q)
        query = sub(req.target, q + 1, req.target.byte_length())
    var url = Url(
        scheme=req.scheme.copy(), host=host^, port=UInt16(req.port), path=path^
    )
    url.query = query^
    return url^


struct AwsConnectorTransport[C: Connector](AwsHttpTransport, Movable, Deinitable):
    """`AwsHttpTransport` over komira_http_client: one `HttpClient` on the
    connector it is given, driven on its own `BlockingRuntime`."""

    var _client: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]

    def __init__(out self, var connector: Self.C) raises:
        """A client from `HttpClientConfig.defaults()`: for a process with
        no containing request deadline (a job, a CLI, a test)."""
        self._client = HttpClient[Self.C].with_defaults(connector^)
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def __init__(out self, config: HttpClientConfig, var connector: Self.C) raises:
        """A client from the caller's `config`."""
        self._client = HttpClient[Self.C](config, connector^)
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def http_config(self) -> HttpClientConfig:
        """The config this transport's HTTP client was built from."""
        return self._client.config()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        var headers = HeaderMap()
        for i in range(len(req.headers)):
            headers.append(req.headers[i].name.copy(), req.headers[i].value.copy())
        var creq = build_request_with_body[BytesBody](
            _http_method(req.method),
            _url_of(req),
            headers^,
            BytesBody.from_bytes(req.body.copy()),
        )
        ref reactor = self._rt.reactor()
        var resp = self._client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            creq^, reactor
        )
        var entries = resp.headers.entries()
        var out = HttpResult(Int(resp.status), resp.body.take_bytes())
        for i in range(len(entries)):
            out.add_header(entries[i].name.copy(), entries[i].value.copy())
        return out^


struct AwsMonotonicClock(MonotonicClock, Movable, Deinitable):
    """komira_clock's monotonic clock, in milliseconds."""

    def __init__(out self):
        pass

    def now_ms(mut self) -> Int64:
        return Int64(Int(now_ns() // 1_000_000))


struct AwsReactorSleeper(Sleeper, Movable, Deinitable):
    """Blocks the calling thread for a retry's wait in a reactor with
    nothing registered (epoll or kqueue with a timeout). The reactor is
    made on the first wait, so a call that is never retried makes none."""

    var _rt: Optional[BlockingRuntime[NoopSink]]

    def __init__(out self):
        self._rt = None

    def sleep_ms(mut self, ms: Int64) raises:
        if ms <= 0:
            return
        var deadline = Int64(Int(now_ns())) + ms * 1_000_000
        if not self._rt:
            self._rt = BlockingRuntime[NoopSink].new(
                NoopSink(_placeholder=UInt8(0))
            )
        ref reactor = self._rt.value().reactor()
        while True:
            var left_us = (deadline - Int64(Int(now_ns()))) // 1000
            if left_us <= 0:
                return
            _ = reactor.run_once(Int32(Int(min(left_us, Int64(1_000_000_000)))))


def aws_system_retry_loop(
    var policy: RetryPolicy,
) raises -> RetryLoop[AwsMonotonicClock, AwsReactorSleeper, SplitMix64Rng]:
    """A retry loop on the process's monotonic clock, waiting in a reactor,
    with jitter seeded from the clock."""
    return RetryLoop[AwsMonotonicClock, AwsReactorSleeper, SplitMix64Rng](
        policy^,
        AwsMonotonicClock(),
        AwsReactorSleeper(),
        SplitMix64Rng(UInt64(now_ns())),
    )


def _starts_with_byte(body: List[UInt8], c: UInt8) -> Bool:
    for i in range(len(body)):
        var b = body[i]
        if b == UInt8(0x20) or b == UInt8(0x09) or b == UInt8(0x0A) or b == UInt8(0x0D):
            continue
        return b == c
    return False


def aws_response_error_code(res: HttpResult) -> String:
    """The AWS error code a response names, whatever its protocol: an XML
    body's (`aws_xml_error_info`), else the awsJson reading
    (`aws_json_error_info`: `x-amzn-query-error`, `X-Amzn-Errortype`, the
    body's `__type`). "" when it names none."""
    if _starts_with_byte(res.body, UInt8(0x3C)):
        return aws_xml_error_info(res.status, res.body, String("")).code
    return aws_json_error_info(res.to_response()).code


def _attempt_of(
    res: HttpResult, service: String, s3_200_error: Bool
) -> Optional[AwsAttempt]:
    """The failed attempt `res` is, or None when it succeeded."""
    var crc = service == "dynamodb" and aws_dynamodb_crc32_mismatch(
        res.header(String(AWS_DYNAMODB_CRC32_HEADER)), res.body
    )
    if aws_is_error_status(res.status):
        return AwsAttempt.response(res.status, aws_response_error_code(res), crc)
    if s3_200_error and aws_xml_body_is_error(res.to_response()):
        return AwsAttempt.response(500, aws_response_error_code(res), crc)
    if crc:
        return AwsAttempt.response(res.status, String(""), True)
    return None


def _send_once[X: AwsHttpTransport](
    mut transport: X, req: CredentialHttpRequest, mut error: String
) -> Optional[HttpResult]:
    try:
        return transport.send(req)
    except e:
        error = String(e)
        return None


def send_sigv4_signed_request_with[
    X: AwsHttpTransport,
    K: AwsClock,
    L: MonotonicClock,
    S: Sleeper,
    R: RetryRng,
    B: RetryBudget,
](
    mut transport: X,
    mut clock: K,
    mut retry: RetryLoop[L, S, R],
    mut budget: B,
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: List[UInt8],
    extra: List[Header],
    s3_200_error: Bool = False,
    payload: AwsPayloadSigning = AwsPayloadSigning.hashed(),
) raises -> HttpResult:
    """`send_sigv4_signed_request` over the given seams (module header).

    Each attempt is built by `build_sigv4_signed_request` at `clock`'s
    time and sent through `transport`; a failed one is read by
    `AwsRetryClassifier` and `retry` decides, sleeps and counts. Returns
    the first successful response, or the last failed one once no retry
    follows. Raises when the last attempt got no response, naming the
    transport's error and why it was not retried. `s3_200_error` states
    that a 200 whose body is an <Error> is S3's error (the module
    header). A conditional write (`aws_request_is_conditional` over
    `method` and `extra`) is not resent once the service may have acted on
    it."""
    var classifier = AwsRetryClassifier(
        service.copy(), conditional=aws_request_is_conditional(method, extra)
    )
    retry.start()
    while True:
        var signed = build_sigv4_signed_request(
            method,
            cred,
            region,
            service,
            endpoint,
            uri,
            content_type,
            Span(body),
            extra,
            clock,
            payload,
        )
        var error = String("")
        var got = _send_once(transport, signed, error)
        if not got:
            var d = retry.after_outcome(
                classifier, AwsAttempt.transport(error^), budget
            )
            if not d.retry:
                raise Error(
                    String("the AWS request got no response (")
                    + String(retry.attempts())
                    + " attempts): "
                    + d.reason
                )
            continue
        var res = got.take()
        var failed = _attempt_of(res, service, s3_200_error)
        if not failed:
            retry.after_success(budget)
            return res^
        var d = retry.after_outcome(classifier, failed.take(), budget)
        if not d.retry:
            return res^


def send_sigv4_signed_request[C: Connector](
    mk_connector: def () raises thin -> C,
    http_config: HttpClientConfig,
    mut retry_quota: AwsRetryQuota,
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: List[UInt8],
    extra: List[Header],
    s3_200_error: Bool = False,
) raises -> HttpResult:
    """Sign `method uri` for (`region`, `service`) with `cred`, send it to
    `endpoint` over a connector `mk_connector` makes, through an HTTP
    client built from `http_config` (the caller's; it has no default), and
    retry as the AWS SDKs' standard mode does (aws_retry.mojo): at most
    three sends, full jitter from 1 s, every attempt signed at the wall
    clock's time, each retry paid for from `retry_quota`, the calling
    client's; a conditional write is not resent once the service may have
    acted on it. The content type and every `extra` header are signed
    (signed_request.mojo). `s3_200_error` is
    `send_sigv4_signed_request_with`'s. Returns the last response; raises
    when the last attempt got none."""
    var transport = AwsConnectorTransport[C](http_config, mk_connector())
    var clock = SystemAwsClock()
    var loop = aws_system_retry_loop(aws_standard_retry_policy())
    return send_sigv4_signed_request_with(
        transport,
        clock,
        loop,
        retry_quota,
        method,
        cred,
        region,
        service,
        endpoint,
        uri,
        content_type,
        body,
        extra,
        s3_200_error=s3_200_error,
    )
