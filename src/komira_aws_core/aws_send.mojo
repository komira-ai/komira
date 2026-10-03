# =============================================================================
# komira_aws_core/aws_send.mojo -- the transport half of a send
# =============================================================================
#
# `send_sigv4_signed_request` is what a generated client's `send` calls: it
# signs the request (`build_sigv4_signed_request`), sends it over
# komira_http_client through the connector the client's factory makes, and
# retries a failed attempt as `AwsRetryClassifier` and the AWS SDKs'
# standard retry mode say (aws_retry.mojo). It returns the last response,
# successful or not: a generated client raises a failed one with its own
# error builder. When no response arrives and the failure is not retried,
# it raises.
#
# EVERY ATTEMPT IS SIGNED AGAIN, reading the clock again (`AwsClock`), so a
# retry carries a fresh X-Amz-Date: a signature older than five minutes is
# answered RequestTimeTooSkewed. Every attempt is signed with the credential
# the client read for the call; `DefaultChainCredsSource` hands out one with
# at least its mandatory refresh window left, and that window is the retry
# deadline (`aws_standard_retry_policy`).
#
# S3's 200 whose body is an <Error> (botocore's `_handle_200_error`) is read
# here as a 500 for any S3 request but GET and HEAD, the requests whose
# operations AWS documents as answering it (CopyObject, UploadPartCopy,
# CompleteMultipartUpload, DeleteObjects among them). A GET's body may be an
# object whose content is an XML document with an <Error> root, which this
# layer cannot tell from the error; the generated parser of a GET operation
# whose output is not a payload still raises it, as a 500, without a retry.
#
# `send_sigv4_signed_request_with` is the same send over injected seams:
# the transport (`AwsHttpTransport`), the signing clock, the retry loop (its
# monotonic clock, sleeper and random source) and a retry budget. The
# hermetic tests drive it with a scripted connector, a stepping clock and a
# sleeper that records; `send_sigv4_signed_request` binds the process's
# clocks and a blocking sleep.
#
# The connector is made once per call, so the attempts of one call share
# its HTTP client (and a kept-alive connection) and the connector's dials.
# The HTTP client runs on a `BlockingRuntime`: the call blocks its thread.
#
# The retry loop runs on komira_clock's monotonic clock and waits in a
# reactor (`AwsReactorSleeper`), not on komira_retry's `SystemClock` and
# `SystemSleeper`: those call `std.time`, whose `nanosleep` declaration
# conflicts with komira_async's in one program, so a binary holding the
# HTTP client cannot also hold them.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_clock import now_ns
from komira_retry import (
    MonotonicClock,
    NoBudget,
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
    AwsAttempt,
    AwsRetryClassifier,
    aws_method_is_idempotent,
    aws_standard_retry_policy,
)
from .aws_xml import aws_xml_body_is_error, aws_xml_error_info
from .credential import AwsCredential
from .credential_transport import CredentialHttpRequest
from .endpoint import AwsEndpoint
from .signed_request import (
    AwsPayloadSigning,
    build_sigv4_signed_request,
    is_s3_signing_name,
)
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
        self._client = HttpClient[Self.C].with_defaults(connector^)
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

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
    nothing registered (epoll or kqueue with a timeout)."""

    var _rt: BlockingRuntime[NoopSink]

    def __init__(out self) raises:
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def sleep_ms(mut self, ms: Int64) raises:
        if ms <= 0:
            return
        var deadline = Int64(Int(now_ns())) + ms * 1_000_000
        ref reactor = self._rt.reactor()
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


def _attempt_of(res: HttpResult, safe: Bool, s3_200_error: Bool) -> Optional[AwsAttempt]:
    """The failed attempt `res` is, or None when it succeeded."""
    if aws_is_error_status(res.status):
        return AwsAttempt.response(res.status, aws_response_error_code(res), safe)
    if s3_200_error and aws_xml_body_is_error(res.to_response()):
        return AwsAttempt.response(500, aws_response_error_code(res), safe)
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
    retry_safe: Bool = False,
    payload: AwsPayloadSigning = AwsPayloadSigning.hashed(),
) raises -> HttpResult:
    """`send_sigv4_signed_request` over the given seams (module header).

    Each attempt is built by `build_sigv4_signed_request` at `clock`'s
    time and sent through `transport`; a failed one is read by
    `AwsRetryClassifier` and `retry` decides, sleeps and counts. Returns
    the first successful response, or the last failed one once no retry
    follows. Raises when the last attempt got no response, naming the
    transport's error and why it was not retried. `retry_safe` states that
    the operation may be repeated though its method is not idempotent."""
    var safe = retry_safe or aws_method_is_idempotent(method)
    var s3_200_error = (
        is_s3_signing_name(service) and method != "GET" and method != "HEAD"
    )
    var classifier = AwsRetryClassifier()
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
                classifier, AwsAttempt.transport(error^, safe), budget
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
        var failed = _attempt_of(res, safe, s3_200_error)
        if not failed:
            retry.after_success(budget)
            return res^
        var d = retry.after_outcome(classifier, failed.take(), budget)
        if not d.retry:
            return res^


def send_sigv4_signed_request[C: Connector](
    mk_connector: def () raises thin -> C,
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: List[UInt8],
    extra: List[Header],
    retry_safe: Bool = False,
) raises -> HttpResult:
    """Sign `method uri` for (`region`, `service`) with `cred`, send it to
    `endpoint` over a connector `mk_connector` makes, and retry as the AWS
    SDKs' standard mode does (aws_retry.mojo): at most three sends, full
    jitter from 1 s, every attempt signed at the wall clock's time. The
    content type and every `extra` header are signed (signed_request.mojo).
    Returns the last response; raises when the last attempt got none."""
    var transport = AwsConnectorTransport[C](mk_connector())
    var clock = SystemAwsClock()
    var loop = aws_system_retry_loop(aws_standard_retry_policy())
    var budget = NoBudget()
    return send_sigv4_signed_request_with(
        transport,
        clock,
        loop,
        budget,
        method,
        cred,
        region,
        service,
        endpoint,
        uri,
        content_type,
        body,
        extra,
        retry_safe=retry_safe,
    )
