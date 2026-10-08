# Where the generated Cloud Run clients send.
#
# The default: each of Run's services (`Services`, `Revisions`, `Jobs`,
# `Executions`, `WorkerPools`) declares `option (google.api.default_host) =
# "run.googleapis.com"`, and the operations client starts at run_v2.yaml's
# `name`, the same host, so a client whose caller names no host starts there
# and its bearer token goes to the service it was minted for. Run Admin v2
# is served at that one global host; a resource's region is in its name
# (`projects/*/locations/*/...`). The default is read off fresh clients
# without sending (a send would resolve the name, which needs outbound
# DNS).
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
from komira_gcp_run.execution import ExecutionsClient
from komira_gcp_run.job import GetJobRequest, JobsClient
from komira_gcp_run.operations import OperationsClient
from komira_gcp_run.revision import RevisionsClient
from komira_gcp_run.service import ServicesClient
from komira_gcp_run.worker_pool import WorkerPoolsClient
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


def _http() -> HttpClient[ScriptedConnector]:
    return HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok()))
    )


def _token() raises -> StaticTokenSource:
    return StaticTokenSource(String("test-access-token"))


def test_every_fresh_client_starts_at_the_default_host() raises:
    var services = ServicesClient[ScriptedConnector, StaticTokenSource](_http(), _token())
    var revisions = RevisionsClient[ScriptedConnector, StaticTokenSource](_http(), _token())
    var jobs = JobsClient[ScriptedConnector, StaticTokenSource](_http(), _token())
    var executions = ExecutionsClient[ScriptedConnector, StaticTokenSource](
        _http(), _token()
    )
    var operations = OperationsClient[ScriptedConnector, StaticTokenSource](
        _http(), _token()
    )
    var worker_pools = WorkerPoolsClient[ScriptedConnector, StaticTokenSource](
        _http(), _token()
    )
    assert_equal(services._rest_host, "run.googleapis.com")
    assert_equal(revisions._rest_host, "run.googleapis.com")
    assert_equal(jobs._rest_host, "run.googleapis.com")
    assert_equal(executions._rest_host, "run.googleapis.com")
    assert_equal(operations._rest_host, "run.googleapis.com")
    assert_equal(worker_pools._rest_host, "run.googleapis.com")
    assert_equal(jobs._client._connector.connect_call_count(), 0)


def test_set_rest_host_is_what_is_dialled() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = JobsClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        _token(),
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
        "GET /v2/projects/p/locations/l/jobs/j HTTP/1.1\r\nHost: localhost\r\n"
    ))


def main() raises:
    test_every_fresh_client_starts_at_the_default_host()
    test_set_rest_host_is_what_is_dialled()
    print("OK")
