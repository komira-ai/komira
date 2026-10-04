# Where the generated Secret Manager client sends.
#
# The default: `SecretManagerService` declares `option
# (google.api.default_host) = "secretmanager.googleapis.com"`, so a client
# whose caller names no host starts there and its bearer token goes to the
# service it was minted for. The default is read off a fresh client without
# sending (a send would resolve the name, which needs outbound DNS).
#
# An override: `set_rest_host` replaces the host, and the replacement is
# what is dialled and named in the Host header (`localhost`, resolved
# without the network, through komira_http_core's ScriptedConnector, which
# records each dial's host; no socket is used).
#
# Regional endpoints: Secret Manager also serves regional secrets at
# `secretmanager.<location>.rep.googleapis.com`, named
# `projects/*/locations/*/secrets/*`. Those paths are each method's
# `additional_bindings`, which the generator does not emit: the client
# holds the global bindings only (`projects/*/secrets/*`). A caller can
# point it at a regional host, but a regional secret's name does not match
# the global pattern and is refused before the token source is asked or
# anything is dialled, rather than sent to a path the service would read
# differently.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource, StaticTokenSource
from komira_gcp_secretmanager.service import (
    AccessSecretVersionRequest,
    SecretManagerServiceClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """Counts the tokens asked of it in a cell the test keeps."""

    var calls: ArcPointer[Int]

    def __init__(out self, calls: ArcPointer[Int]):
        self.calls = calls

    def access_token(mut self) raises -> String:
        self.calls[] += 1
        return String("test-access-token")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok() -> List[UInt8]:
    var body = String('{"name":"projects/1/secrets/s/versions/1","payload":{"data":""}}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _access(name: String) raises -> AccessSecretVersionRequest:
    return decode_json[AccessSecretVersionRequest](
        String('{"name":"') + name + '"}'
    )


def test_a_fresh_client_starts_at_the_default_host() raises:
    var c = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok()))
        ),
        StaticTokenSource(String("test-access-token")),
    )
    assert_equal(c._rest_host, "secretmanager.googleapis.com")
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_set_rest_host_is_what_is_dialled() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.access_secret_version[_RT](
        _access("projects/demo-project/secrets/s/versions/1"), reactor
    )
    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "localhost")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(wire.startswith(
        "GET /v1/projects/demo-project/secrets/s/versions/1:access HTTP/1.1\r\n"
        + "Host: localhost\r\n"
    ))


def test_a_regional_secret_name_is_refused_before_any_send() raises:
    var calls = ArcPointer[Int](0)
    var c = SecretManagerServiceClient[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok()))
        ),
        CountingTokenSource(calls),
    )
    c.set_rest_host(String("secretmanager.us-central1.rep.googleapis.com"))
    assert_equal(c._rest_host, "secretmanager.us-central1.rep.googleapis.com")
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = False
    try:
        _ = c.access_secret_version[_RT](
            _access("projects/demo-project/locations/us-central1/secrets/s/versions/1"),
            reactor,
        )
    except e:
        raised = True
        assert_true("name" in String(e), String(e))
    assert_true(raised, "a regional secret name was sent on a global binding")
    assert_equal(calls[], 0)
    assert_equal(c._client._connector.connect_call_count(), 0)


def main() raises:
    test_a_fresh_client_starts_at_the_default_host()
    test_set_rest_host_is_what_is_dialled()
    test_a_regional_secret_name_is_refused_before_any_send()
    print("OK")
