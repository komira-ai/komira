# The host a client sends to when its caller names none. ArtifactRegistry
# declares `option (google.api.default_host) =
# "artifactregistry.googleapis.com"`, and the generated client starts there.
# A caller reaching a regional endpoint (`<region>-artifactregistry.googleapis.com`)
# names it with `set_rest_host`.
#
# The default is read off a fresh client without sending (a send would
# resolve the name, which needs the network). The override sends to
# `localhost` (resolved without the network) through komira_http_core's
# ScriptedConnector, which records the host of every dial; no socket is used.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.repository import GetRepositoryRequest
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok() -> List[UInt8]:
    var body = String('{"name":"projects/p/locations/l/repositories/r"}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def test_a_fresh_client_starts_at_the_default_host() raises:
    var c = ArtifactRegistryClient[SC, TS](
        HttpClient[SC].with_defaults(
            SC.with_stream_tls(ScriptedStream.from_read_script(_ok()))
        ),
        TS(String("test-access-token")),
    )
    assert_equal(c._rest_host, "artifactregistry.googleapis.com")
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_set_rest_host_overrides_the_default() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = ArtifactRegistryClient[SC, TS](
        HttpClient[SC].with_defaults(
            SC.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        TS(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.get_repository[_RT](
        GetRepositoryRequest(String("projects/p/locations/l/repositories/r")),
        reactor,
    )
    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "localhost")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(
        wire.startswith("GET /v1/projects/p/locations/l/repositories/r HTTP/1.1\r\n")
    )
    assert_true("\r\nHost: localhost\r\n" in wire)
    assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)


def main() raises:
    test_a_fresh_client_starts_at_the_default_host()
    test_set_rest_host_overrides_the_default()
    print("OK")
