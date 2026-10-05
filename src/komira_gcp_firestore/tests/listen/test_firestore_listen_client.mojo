# The generated gRPC `FirestoreClient.listen` (komira_gcp_firestore_listen)
# over komira_grpc's classic gRPC, through komira_http_core's
# ScriptedConnector (no socket): the call it makes (its path, its one bearer
# token, the request message framed) and the pushed responses it hands back,
# and a non-OK status raised through komira_gcp_core with no byte of the
# server's text.
#
# `listen` is komira_grpc's BUFFERED bidi call: it sends the buffered
# requests, reads the response to its end and returns the decoder. That fits
# a bounded exchange (the rig here ends the stream); the long-lived watch in
# komira_gcp_firestore drives its own HTTP/2 receive loop with these same
# generated messages instead (firestore_listen_client.mojo).
from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_gcp_core import GcpTokenSource
from komira_gcp_firestore_listen.firestore import (
    FirestoreClient,
    ListenRequest,
    ListenResponse,
    Target,
    Target_DocumentsTarget,
)
from komira_grpc import (
    BidiStreamCodec,
    CallOptions,
    GrpcClient,
    ProtocolGrpcProto,
    STREAM_OUTCOME_END_ERROR,
    STREAM_OUTCOME_MESSAGE,
    ServerStreamDecoder,
)
from komira_http_client.client import HttpClient
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_proto, encode_proto


comptime RT = PerCoreAsyncRuntime[NoopSink]
comptime _DB = "projects/demo-project/databases/(default)"
comptime _SERVER_TEXT = "database demo-project secret-name is gone"


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def access_token(mut self) raises -> String:
        self.calls += 1
        return String("token-") + String(self.calls)


comptime Client = FirestoreClient[ScriptedConnector, CountingTokenSource]


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _frame(message: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0))
    var n = len(message)
    out.append(UInt8((n >> 24) & 0xFF))
    out.append(UInt8((n >> 16) & 0xFF))
    out.append(UInt8((n >> 8) & 0xFF))
    out.append(UInt8(n & 0xFF))
    for i in range(n):
        out.append(message[i])
    return out^


def _http_200(
    body: List[UInt8], status_headers: String = "grpc-status: 0\r\n"
) -> List[UInt8]:
    var out = _b(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/grpc\r\n")
        + status_headers
        + "Content-Length: "
        + String(len(body))
        + "\r\nConnection: close\r\n\r\n"
    )
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _client(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) raises -> Client:
    var connector = ScriptedConnector()
    connector.arm(ScriptedStream.from_read_script_with_capture(script^, capture))
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("http://127.0.0.1:8080/"))
    return Client(GrpcClient[ScriptedConnector](http^, base^), CountingTokenSource())


def _request() -> ListenRequest:
    var names = List[String]()
    names.append(String(_DB) + "/documents/c/a")
    var target = Target(
        Int32(1), False, None, 2, None, Target_DocumentsTarget(names^), 0, None, None
    )
    return ListenRequest(String(_DB), Dict[String, String](), None, 1, target^, None)


def _codec() raises -> BidiStreamCodec[ProtocolGrpcProto]:
    var codec = BidiStreamCodec[ProtocolGrpcProto].new()
    var msg = encode_proto(_request())
    codec.encoder.encode_message(Span(msg))
    codec.encoder.mark_close()
    return codec^


def _drain(var decoder: ServerStreamDecoder[ProtocolGrpcProto]) raises -> List[ListenResponse]:
    var got = List[ListenResponse]()
    for _ in range(100):
        var o = decoder.try_next_message()
        if o.kind == STREAM_OUTCOME_END_ERROR:
            raise Error("the stream ended in an error")
        if o.kind != STREAM_OUTCOME_MESSAGE:
            break
        got.append(decode_proto[ListenResponse](o.message_bytes.copy()))
    return got^


def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    if len(needle) == 0:
        return True
    for i in range(len(hay) - len(needle) + 1):
        var same = True
        for j in range(len(needle)):
            if hay[i + j] != needle[j]:
                same = False
                break
        if same:
            return True
    return False


def test_listen_sends_the_target_and_reads_the_pushes() raises:
    # Two pushes: the target is added, then a document is deleted.
    # target_change=2 (5 bytes) {target_change_type=1: ADD (1),
    # target_ids=2: packed [1]}
    var add: List[UInt8] = [0x12, 0x05, 0x08, 0x01, 0x12, 0x01, 0x01]
    var del_ = List[UInt8]()
    # document_delete=4 {document=1: "n"}
    del_.append(UInt8(0x22))
    del_.append(UInt8(0x03))
    del_.append(UInt8(0x0A))
    del_.append(UInt8(0x01))
    del_.append(UInt8(ord("n")))
    var body = _frame(add)
    for b in _frame(del_):
        body.append(b)
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var client = _client(_http_200(body), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var got = _drain(client.listen[RT](_codec(), CallOptions(), 0, reactor, token))
    assert_equal(len(got), 2)
    assert_equal(got[0]._oneof0_case, 1)
    assert_equal(got[0].target_change.value().target_change_type.value, 1)
    assert_equal(got[0].target_change.value().target_ids[0], Int32(1))
    assert_equal(got[1]._oneof0_case, 3)
    assert_equal(got[1].document_delete.value().document, String("n"))
    # The call: its path, one bearer token, the request framed.
    var sent = capture[].copy()
    assert_true(_contains(sent, _b("POST /google.firestore.v1.Firestore/Listen HTTP/1.1")))
    assert_true(_contains(sent, _b("authorization: Bearer token-1")))
    assert_false(_contains(sent, _b("token-2")))
    assert_true(_contains(sent, _frame(encode_proto(_request()))))
    assert_equal(client.token_source().calls, 1)


def test_a_failed_listen_names_the_code_not_the_text() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var client = _client(
        _http_200(
            List[UInt8](),
            String("grpc-status: 5\r\ngrpc-message: ") + _SERVER_TEXT + "\r\n",
        ),
        capture,
    )
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var raised = String("")
    try:
        _ = _drain(client.listen[RT](_codec(), CallOptions(), 0, reactor, token))
    except e:
        raised = String(e)
    assert_true(
        raised.startswith(
            "[grpc:5] gRPC /google.firestore.v1.Firestore/Listen: NOT_FOUND (code 5)"
        ),
        raised,
    )
    assert_false(String("secret-name") in raised, raised)


def main() raises:
    test_listen_sends_the_target_and_reads_the_pushes()
    test_a_failed_listen_names_the_code_not_the_text()
    print("OK")
