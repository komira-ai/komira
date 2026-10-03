# The caller's test of the generated client-mode CloudWatch Logs client: what
# its `send` hands the transport, and its error builder.
#
# The transport is ../mojo_aws_client's stub `send_sigv4_signed_request`, a
# test double that signs and sends nothing and answers 200 with the body
# `{}` and one `x-stub-*` header per argument it was given, then the `extra`
# headers as given. So what is checked here is the generated code: that
# `send` takes the credential from its source, resolves the endpoint from
# the region or the override it was constructed with, passes the content
# type as its own argument and X-Amz-Target among the signed extra headers
# (and Content-Type not among them), and calls the connector factory; that
# `get_log_events` parses a 200; and that the error builder reports the
# operation and the status and never the raw body. Signing is tested in
# komira//src/komira_aws_core.
from komira_aws_logs_client.komira_aws_logs_client import (
    CloudWatchLogsCloudWatchLogsClient,
    CloudWatchLogsGetLogEventsRequest,
    _komira_aws_logs_client_error,
    build_get_log_events_request,
)
from komira_aws_core import AwsCredential, AwsCredsSource, AwsEndpoint, HttpResult
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


def _creds() -> _FixedCreds:
    # Made-up key material, in the shape of AWS's documented examples.
    return _FixedCreds(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _request() raises -> CloudWatchLogsGetLogEventsRequest:
    var input = CloudWatchLogsGetLogEventsRequest(String("web-1"))
    input.set_log_group_name(String("/example/app"))
    return input^


def test_send_hands_the_transport() raises:
    var client = CloudWatchLogsCloudWatchLogsClient[_NoConnector, _FixedCreds](
        _mk_connector, _creds(), String("us-west-2")
    )
    var res = client.send(build_get_log_events_request(_request()))
    assert_equal(res.status, 200)
    assert_equal(res.header(String("x-stub-method")), "POST")
    assert_equal(res.header(String("x-stub-access-key-id")), "AKIDEXAMPLE")
    assert_equal(res.header(String("x-stub-region")), "us-west-2")
    assert_equal(res.header(String("x-stub-service")), "logs")
    assert_equal(res.header(String("x-stub-scheme")), "https")
    assert_equal(res.header(String("x-stub-host")), "logs.us-west-2.amazonaws.com")
    assert_equal(res.header(String("x-stub-port")), "443")
    assert_equal(res.header(String("x-stub-uri")), "/")
    assert_equal(
        res.header(String("x-stub-content-type")), "application/x-amz-json-1.1"
    )
    assert_true(Int(res.header(String("x-stub-body-bytes"))) > 0)
    # X-Amz-Target rides in the signed extra headers; Content-Type is the
    # transport's own argument and is not repeated there.
    assert_equal(res.header(String("x-stub-extra-count")), "1")
    assert_equal(res.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvents")


def test_send_to_the_endpoint_override() raises:
    var client = CloudWatchLogsCloudWatchLogsClient[_NoConnector, _FixedCreds](
        _mk_connector,
        _creds(),
        String("us-east-1"),
        Optional[AwsEndpoint](
            AwsEndpoint(String("http"), String("localhost"), 4566, String(""), True)
        ),
    )
    var res = client.send(build_get_log_events_request(_request()))
    assert_equal(res.header(String("x-stub-scheme")), "http")
    assert_equal(res.header(String("x-stub-host")), "localhost")
    assert_equal(res.header(String("x-stub-port")), "4566")
    # The region still scopes the signature.
    assert_equal(res.header(String("x-stub-region")), "us-east-1")


def test_send_calls_the_connector_factory() raises:
    var client = CloudWatchLogsCloudWatchLogsClient[_NoConnector, _FixedCreds](
        _mk_connector_refused, _creds(), String("us-west-2")
    )
    with assert_raises(contains="connector factory refused"):
        _ = client.send(build_get_log_events_request(_request()))


def test_get_log_events_parses_a_200() raises:
    var client = CloudWatchLogsCloudWatchLogsClient[_NoConnector, _FixedCreds](
        _mk_connector, _creds(), String("us-west-2")
    )
    var resp = client.get_log_events(_request())
    assert_false(Bool(resp.events))


def test_creds_source_threads_through() raises:
    var client = CloudWatchLogsCloudWatchLogsClient[_NoConnector, _FixedCreds](
        _mk_connector, _creds(), String("eu-west-1")
    )
    assert_equal(client.region(), "eu-west-1")
    var source = client^.into_creds_source()
    assert_equal(source.credentials().access_key_id, "AKIDEXAMPLE")


def test_error_never_echoes_the_body() raises:
    # Not JSON, so the real error readers find no code and no message in it
    # either: whatever reaches the error is the generated code's doing.
    var body_text = String("<html>upstream detail /private/x</html>")
    var body = List[UInt8]()
    body.extend(Span(body_text.as_bytes()))
    var err = String(
        _komira_aws_logs_client_error(String("GetLogEvents"), HttpResult(400, body^))
    )
    assert_true(
        err.startswith("CloudWatchLogsCloudWatchLogs.GetLogEvents failed: HTTP 400")
    )
    assert_true(err.find("/private/x") < 0)


def main() raises:
    test_send_hands_the_transport()
    test_send_to_the_endpoint_override()
    test_send_calls_the_connector_factory()
    test_get_log_events_parses_a_200()
    test_creds_source_threads_through()
    test_error_never_echoes_the_body()
