# Each generated Cloud Run `WorkerPools` method, once: the request it puts
# on the wire, byte for byte (request line with the resource-name captures
# and the query, the headers, the JSON body), and the response it reads
# back. A worker pool is a background worker: containers with no ingress
# and a fixed instance count. CreateWorkerPool, UpdateWorkerPool and
# DeleteWorkerPool answer with a google.longrunning.Operation, which the
# operations client polls (test_run_operations).
#
# The expected forms are written here from the Cloud Run Admin v2 REST
# reference (projects.locations.workerPools.create, .get, .list, .patch,
# .delete); no upstream test body is copied. The connector is
# komira_http_core's ScriptedConnector with a shared write capture; no
# socket is opened. Each client is pointed at `localhost` with
# `set_rest_host`; the default host is test_run_endpoint's subject.
#
# A body holds only the fields the caller set, in declaration order
# (`template` before `scaling`), as the proto3 JSON mapping writes them.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource, StaticTokenSource
from komira_gcp_run.worker_pool import (
    CreateWorkerPoolRequest,
    DeleteWorkerPoolRequest,
    GetWorkerPoolRequest,
    ListWorkerPoolsRequest,
    UpdateWorkerPoolRequest,
    WorkerPoolsClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]

comptime _PARENT = "projects/demo-project/locations/us-central1"
comptime _NAME = "projects/demo-project/locations/us-central1/workerPools/queue"

# The worker pool as a caller states it, and as the client writes it: the
# fields set, in declaration order.
comptime _POOL_TAIL = (
    '"labels":{"app":"queue"},"template":{'
    + '"serviceAccount":"queue-runtime@example.com",'
    + '"containers":[{"image":"us-docker.pkg.dev/demo-project/apps/queue@sha256:0f1e",'
    + '"args":["--drain"]}]},"scaling":{"manualInstanceCount":2}}'
)

# A running operation, as Create/Update/Delete answer.
comptime _OPERATION = (
    '{"name":"projects/demo-project/locations/us-central1/operations/7a1c",'
    + '"metadata":{"@type":"type.googleapis.com/google.cloud.run.v2.WorkerPool",'
    + '"name":"projects/demo-project/locations/us-central1/workerPools/queue"},'
    + '"done":false}'
)

# The worker pool as the service answers it.
comptime _POOL_ANSWER = (
    '{"name":"projects/demo-project/locations/us-central1/workerPools/queue",'
    + '"uid":"0b6e4c2a-1d3f-4a5b-8c7d-9e0f1a2b3c4d","generation":"2",'
    + '"labels":{"app":"queue"},"template":{'
    + '"serviceAccount":"queue-runtime@example.com",'
    + '"containers":[{"image":"us-docker.pkg.dev/demo-project/apps/queue@sha256:0f1e"}]},'
    + '"scaling":{"manualInstanceCount":2},"observedGeneration":"2",'
    + '"latestReadyRevision":"projects/demo-project/locations/us-central1/workerPools/'
    + 'queue/revisions/queue-00002-abc","etag":"\\"Cx1\\"","reconciling":false}'
)


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


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _pools(
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> WorkerPoolsClient[ScriptedConnector, StaticTokenSource]:
    var c = WorkerPoolsClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _expected(target: String, body: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length, then the client's headers, a content-type only with a
    body, then the body."""
    var out = (
        target
        + " HTTP/1.1\r\n"
        + "Host: localhost\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n"
        + "authorization: Bearer test-access-token\r\n"
    )
    if body.byte_length() > 0:
        out += "content-type: application/json\r\n"
    return out + "\r\n" + body


def test_create_worker_pool() raises:
    # POST .../locations/{location}/workerPools?workerPoolId=..., the
    # WorkerPool as the body.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _pools(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.create_worker_pool[_RT](
        decode_json[CreateWorkerPoolRequest](
            String('{"parent":"')
            + _PARENT
            + '","workerPoolId":"queue","workerPool":{'
            + _POOL_TAIL
            + "}"
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v2/") + _PARENT + "/workerPools?workerPoolId=queue",
            String("{") + _POOL_TAIL,
        ),
    )
    assert_equal(op.name, "projects/demo-project/locations/us-central1/operations/7a1c")
    assert_false(op.done)


def test_get_worker_pool() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _pools(capture, _POOL_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var pool = c.get_worker_pool[_RT](
        decode_json[GetWorkerPoolRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("GET /v2/") + _NAME))
    assert_equal(pool.name, _NAME)
    assert_equal(pool.generation, Int64(2))
    assert_equal(pool.observed_generation, Int64(2))
    assert_equal(pool.labels["app"], "queue")
    assert_equal(
        pool.template.value().service_account,
        "queue-runtime@example.com",
    )
    assert_equal(pool.scaling.value().manual_instance_count.value(), Int32(2))
    assert_equal(pool.etag, '"Cx1"')


def test_list_worker_pools() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _pools(
        capture,
        String('{"workerPools":[') + _POOL_ANSWER + '],"nextPageToken":"CgVxdWV1ZQ=="}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_worker_pools[_RT](
        decode_json[ListWorkerPoolsRequest](
            String('{"parent":"') + _PARENT + '","pageSize":50,"pageToken":"CgRh="}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("GET /v2/")
            + _PARENT
            + "/workerPools?pageSize=50&pageToken=CgRh%3D"
        ),
    )
    assert_equal(len(page.worker_pools), 1)
    assert_equal(page.worker_pools[0].name, _NAME)
    assert_equal(page.next_page_token, "CgVxdWV1ZQ==")


def test_update_worker_pool() raises:
    # PATCH /v2/{worker_pool.name=...}: the path is the body's pool name;
    # allowMissing creates it if absent.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _pools(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.update_worker_pool[_RT](
        decode_json[UpdateWorkerPoolRequest](
            String('{"workerPool":{"name":"')
            + _NAME
            + '",'
            + _POOL_TAIL
            + ',"allowMissing":true}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("PATCH /v2/") + _NAME + "?allowMissing=true",
            String('{"name":"') + _NAME + '",' + _POOL_TAIL,
        ),
    )
    assert_false(op.done)


def test_update_worker_pool_without_a_pool_is_refused_before_any_send() raises:
    # The path is built from `worker_pool.name`; with no worker pool there
    # is no path, and the client refuses before it asks for a token or dials.
    var calls = ArcPointer[Int](0)
    var c = WorkerPoolsClient[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok("{}")))
        ),
        CountingTokenSource(calls),
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.update_worker_pool[_RT](
            decode_json[UpdateWorkerPoolRequest]('{"validateOnly":true}'), reactor
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        "update_worker_pool: the request's `worker_pool` is unset, and the path"
        " is built from `worker_pool.name`",
    )
    assert_equal(calls[], 0)
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_delete_worker_pool() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _pools(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete_worker_pool[_RT](
        decode_json[DeleteWorkerPoolRequest](
            String('{"name":"') + _NAME + '","etag":"\\"Cx1\\""}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture), _expected(String("DELETE /v2/") + _NAME + "?etag=%22Cx1%22")
    )
    assert_equal(op.name, "projects/demo-project/locations/us-central1/operations/7a1c")


def main() raises:
    test_create_worker_pool()
    test_get_worker_pool()
    test_list_worker_pools()
    test_update_worker_pool()
    test_update_worker_pool_without_a_pool_is_refused_before_any_send()
    test_delete_worker_pool()
    print("OK")
