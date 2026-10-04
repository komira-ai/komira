# Where the generated Cloud Scheduler client sends.
#
# The default: `CloudScheduler` declares `option (google.api.default_host)
# = "cloudscheduler.googleapis.com"`, so a client whose caller names no
# host starts there and its bearer token goes to the service it was minted
# for. The default is read off a fresh client without sending (a send would
# resolve the name, which needs outbound DNS). Cloud Scheduler has one
# global endpoint; a job's region is in its name
# (`projects/*/locations/*/jobs/*`), not in the host.
#
# An override: `set_rest_host` replaces the host, and the replacement is
# what is dialled and named in the Host header (`localhost`, resolved
# without the network, through komira_http_core's ScriptedConnector, which
# records each dial's host; no socket is used).
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_cloudscheduler.cloudscheduler import CloudSchedulerClient, GetJobRequest
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok() -> List[UInt8]:
    var body = String('{"name":"projects/p/locations/l/jobs/j"}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def test_a_fresh_client_starts_at_the_default_host() raises:
    var c = CloudSchedulerClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok()))
        ),
        StaticTokenSource(String("test-access-token")),
    )
    assert_equal(c._rest_host, "cloudscheduler.googleapis.com")
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_set_rest_host_is_what_is_dialled() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = CloudSchedulerClient[ScriptedConnector, StaticTokenSource](
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
    _ = c.get_job[_RT](
        decode_json[GetJobRequest]('{"name":"projects/p/locations/l/jobs/j"}'), reactor
    )
    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "localhost")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(wire.startswith(
        "GET /v1/projects/p/locations/l/jobs/j HTTP/1.1\r\nHost: localhost\r\n"
    ))


def main() raises:
    test_a_fresh_client_starts_at_the_default_host()
    test_set_rest_host_is_what_is_dialled()
    print("OK")
