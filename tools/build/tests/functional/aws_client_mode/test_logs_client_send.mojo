# The caller's test of the generated client-mode CloudWatch Logs client: what
# its `send` hands the transport, and what its operation method does with
# the answer.
#
# The transport is ../mojo_aws_client's stub `send_sigv4_signed_request`, a
# test double that signs and sends nothing: it refuses what the real request
# builder refuses of its arguments, echoes each argument as an `x-stub-*`
# header (the body as `x-stub-body`), then the `extra` headers as given, and
# takes its status and body from the endpoint host (`status-<NNN>.invalid`,
# `status-<NNN>-html.invalid`, `status-<NNN>-errortype.invalid`, else 200). So what is checked here is the
# generated code: that `send` takes the credential (session token included)
# from its source, resolves the endpoint from the region or hands the
# override on whole, passes the request body as built, the content type as
# its own argument (from a Content-Type header in any case) and X-Amz-Target
# as the only signed extra header, and calls the connector factory; that
# `get_log_events` goes through `send`, parses a 200, and turns a non-2xx
# into an error naming the operation, the status and the code and message
# komira_aws_core's aws_json_error_info reads (an X-Amzn-Errortype code
# included), never the raw body. It sends neither `retry_safe` nor
# `s3_200_error` (the transport's defaults, False). It hands on the
# HttpClientConfig the caller built it with, unchanged, on every send: the
# serving-ceiling clamp is the caller's, in that config. Signing is tested
# in komira//src/komira_aws_core.
from komira_aws_logs_client.komira_aws_logs_client import (
    CloudWatchLogsCloudWatchLogsClient,
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)
from komira_aws_core import AwsCredential, AwsCredsSource, AwsEndpoint, AwsRequest
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from std.testing import assert_equal, assert_false, assert_raises, assert_true


struct _NoConnector(Connector):
    """A connector the stub transport takes and never connects."""

    def __init__(out self):
        pass


def _mk_connector() raises -> _NoConnector:
    return _NoConnector()


def _mk_connector_refused() raises -> _NoConnector:
    raise Error("connector factory refused")


struct _FixedCreds(AwsCredsSource):
    var cred: AwsCredential

    def __init__(out self, cred: AwsCredential):
        self.cred = cred

    def credentials(mut self) raises -> AwsCredential:
        return self.cred


def _creds(session_token: String = String("")) -> _FixedCreds:
    # Made-up key material, in the shape of AWS's documented examples.
    return _FixedCreds(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            session_token,
        )
    )


comptime _Client = CloudWatchLogsCloudWatchLogsClient[_NoConnector, _FixedCreds]


def _defaults() -> HttpClientConfig:
    return HttpClientConfig.defaults()


def _client_at(host: String) -> _Client:
    return _Client(
        _mk_connector,
        _defaults(),
        _creds(),
        String("us-west-2"),
        Optional[AwsEndpoint](AwsEndpoint(String("https"), host, 443, String(""), True)),
    )


def _request() raises -> CloudWatchLogsGetLogEventsRequest:
    var input = CloudWatchLogsGetLogEventsRequest(String("web-1"))
    input.set_log_group_name(String("/example/app"))
    return input^


def test_send_hands_the_transport() raises:
    var client = _Client(_mk_connector, _defaults(), _creds(), String("us-west-2"))
    var built = build_get_log_events_request(_request())
    var want_body = built.body_text()
    var res = client.send(built^)
    assert_equal(res.status, 200)
    assert_equal(res.header(String("x-stub-method")), "POST")
    assert_equal(res.header(String("x-stub-access-key-id")), "AKIDEXAMPLE")
    assert_equal(res.header(String("x-stub-has-session-token")), "false")
    assert_equal(res.header(String("x-stub-region")), "us-west-2")
    assert_equal(res.header(String("x-stub-service")), "logs")
    assert_equal(res.header(String("x-stub-scheme")), "https")
    assert_equal(res.header(String("x-stub-host")), "logs.us-west-2.amazonaws.com")
    assert_equal(res.header(String("x-stub-port")), "443")
    assert_equal(res.header(String("x-stub-base-path")), "")
    assert_equal(res.header(String("x-stub-root-slash")), "true")
    assert_equal(res.header(String("x-stub-uri")), "/")
    assert_equal(
        res.header(String("x-stub-content-type")), "application/x-amz-json-1.1"
    )
    # The body as built, byte for byte.
    var body = res.header(String("x-stub-body"))
    assert_equal(body, want_body)
    assert_true(body.find('"logStreamName":"web-1"') >= 0)
    assert_true(body.find('"logGroupName":"/example/app"') >= 0)
    # X-Amz-Target rides in the signed extra headers; Content-Type is the
    # transport's own argument and is not repeated there.
    assert_equal(res.header(String("x-stub-extra-count")), "1")
    assert_equal(res.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvents")
    # GetLogEvents is not marked retry-safe and Logs is not S3.
    assert_equal(res.header(String("x-stub-retry-safe")), "false")
    assert_equal(res.header(String("x-stub-s3-200-error")), "false")
    # The caller's HTTP config, here the defaults: no containing deadline.
    assert_equal(res.header(String("x-stub-context-ceiling-us")), "0")
    assert_equal(res.header(String("x-stub-request-timeout-us")), "0")


def test_send_hands_on_the_callers_http_config() raises:
    # The config the caller built the client with reaches the transport
    # unchanged on every send: the client keeps no config of its own. Both
    # fields are set, to different values, so neither can stand in for the
    # other.
    var client = _Client(
        _mk_connector,
        HttpClientConfig(request_timeout_us=1_234_567, context_ceiling_us=4_500_000),
        _creds(),
        String("us-west-2"),
    )
    for _ in range(2):
        var res = client.send(build_get_log_events_request(_request()))
        assert_equal(res.header(String("x-stub-context-ceiling-us")), "4500000")
        assert_equal(res.header(String("x-stub-request-timeout-us")), "1234567")


def test_send_keeps_the_session_token() raises:
    var client = _Client(
        _mk_connector,
        _defaults(),
        _creds(String("example-session-token")),
        String("us-west-2"),
    )
    var res = client.send(build_get_log_events_request(_request()))
    assert_equal(res.header(String("x-stub-has-session-token")), "true")


def test_send_to_the_endpoint_override() raises:
    var client = _Client(
        _mk_connector,
        _defaults(),
        _creds(),
        String("us-east-1"),
        Optional[AwsEndpoint](
            AwsEndpoint(String("http"), String("localhost"), 4566, String("/proxy"), False)
        ),
    )
    var res = client.send(build_get_log_events_request(_request()))
    # The override is handed on whole, not rebuilt from scheme, host and port.
    assert_equal(res.header(String("x-stub-scheme")), "http")
    assert_equal(res.header(String("x-stub-host")), "localhost")
    assert_equal(res.header(String("x-stub-port")), "4566")
    assert_equal(res.header(String("x-stub-base-path")), "/proxy")
    assert_equal(res.header(String("x-stub-root-slash")), "false")
    # The region still scopes the signature.
    assert_equal(res.header(String("x-stub-region")), "us-east-1")


def test_send_takes_content_type_in_any_case() raises:
    var client = _Client(_mk_connector, _defaults(), _creds(), String("us-west-2"))
    var req = AwsRequest(String("POST"), String("/"))
    req.set_header(String("content-TYPE"), String("application/x-amz-json-1.0"))
    req.set_header(String("X-Amz-Target"), String("Logs_20140328.GetLogEvents"))
    var res = client.send(req^)
    assert_equal(
        res.header(String("x-stub-content-type")), "application/x-amz-json-1.0"
    )
    assert_equal(res.header(String("x-stub-extra-count")), "1")


def test_send_does_not_launder_a_reserved_header() raises:
    # A Host or Content-Length on the request reaches the transport as an
    # extra header, which the request builder refuses.
    var client = _Client(_mk_connector, _defaults(), _creds(), String("us-west-2"))
    var req = AwsRequest(String("POST"), String("/"))
    req.set_header(String("Content-Length"), String("2"))
    with assert_raises(contains="is set by the request builder"):
        _ = client.send(req^)


def test_send_calls_the_connector_factory() raises:
    var client = _Client(
        _mk_connector_refused, _defaults(), _creds(), String("us-west-2")
    )
    with assert_raises(contains="connector factory refused"):
        _ = client.send(build_get_log_events_request(_request()))


def test_get_log_events_goes_through_send() raises:
    var client = _Client(
        _mk_connector_refused, _defaults(), _creds(), String("us-west-2")
    )
    with assert_raises(contains="connector factory refused"):
        _ = client.get_log_events(_request())


def test_get_log_events_parses_a_200() raises:
    var client = _Client(_mk_connector, _defaults(), _creds(), String("us-west-2"))
    var resp = client.get_log_events(_request())
    assert_equal(resp.next_forward_token.value(), "f/1")
    assert_equal(len(resp.events.value()), 0)
    assert_false(Bool(resp.next_backward_token))


def test_get_log_events_error_names_code_and_message() raises:
    var client = _client_at(String("status-400.invalid"))
    var raised = False
    try:
        _ = client.get_log_events(_request())
    except e:
        raised = True
        var err = String(e)
        assert_true(
            err.startswith(
                "CloudWatchLogsCloudWatchLogs.GetLogEvents failed: HTTP 400"
            )
        )
        assert_true(err.find("ResourceNotFoundException") >= 0)
        assert_true(err.find("com.amazonaws.logs#") < 0)
        assert_true(err.find("no such group") >= 0)
        assert_true(err.find("/private/x") < 0)
    assert_true(raised)


def test_get_log_events_error_takes_the_errortype_header() raises:
    # The body names no code; the X-Amzn-Errortype header does. Only an
    # error builder that reads the response through aws_json_error_info
    # (headers, then body) finds it.
    var client = _client_at(String("status-404-errortype.invalid"))
    var raised = False
    try:
        _ = client.get_log_events(_request())
    except e:
        raised = True
        var err = String(e)
        assert_true(
            err.startswith(
                "CloudWatchLogsCloudWatchLogs.GetLogEvents failed: HTTP 404"
            )
        )
        assert_true(err.find("ResourceNotFoundException") >= 0)
        assert_true(err.find("internal.amazon.com") < 0)
        assert_true(err.find("no such group") >= 0)
        assert_true(err.find("/private/x") < 0)
    assert_true(raised)


def test_get_log_events_error_never_echoes_the_body() raises:
    # Not JSON, so the error readers find no code and no message in it:
    # whatever reaches the error is the generated code's doing.
    var client = _client_at(String("status-502-html.invalid"))
    var raised = False
    try:
        _ = client.get_log_events(_request())
    except e:
        raised = True
        var err = String(e)
        assert_true(
            err.startswith(
                "CloudWatchLogsCloudWatchLogs.GetLogEvents failed: HTTP 502"
            )
        )
        assert_true(err.find("/private/x") < 0)
        assert_true(err.find("html") < 0)
    assert_true(raised)


def test_creds_source_threads_through() raises:
    var client = _Client(_mk_connector, _defaults(), _creds(), String("eu-west-1"))
    assert_equal(client.region(), "eu-west-1")
    var source = client^.into_creds_source()
    assert_equal(source.credentials().access_key_id, "AKIDEXAMPLE")


def main() raises:
    test_send_hands_the_transport()
    test_send_hands_on_the_callers_http_config()
    test_send_keeps_the_session_token()
    test_send_to_the_endpoint_override()
    test_send_takes_content_type_in_any_case()
    test_send_does_not_launder_a_reserved_header()
    test_send_calls_the_connector_factory()
    test_get_log_events_goes_through_send()
    test_get_log_events_parses_a_200()
    test_get_log_events_error_names_code_and_message()
    test_get_log_events_error_takes_the_errortype_header()
    test_get_log_events_error_never_echoes_the_body()
    test_creds_source_threads_through()
