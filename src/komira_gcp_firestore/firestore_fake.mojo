# =============================================================================
# komira_gcp_firestore/firestore_fake.mojo — a connector that answers each
#   HTTP request with a handler, for stateful Firestore doubles in tests.
# =============================================================================
#
# `ScriptedFirestore` (firestore_scripted.mojo) replays answers queued in
# advance. A test of a STORE needs more: a double that holds documents,
# applies the preconditions, and answers each request from its state, so a
# sequence of operations (publish, resolve, republish) runs as it would
# against the service. `ExchangeConnector[H]` is the transport half of such a
# double: every connection it hands out reads one HTTP/1.1 request the client
# wrote, passes its method, target and body to the handler `H`, and returns
# the handler's status and JSON body as the response. The handler is shared
# (an `ArcPointer`) by the connector and every connection, and by the test,
# which keeps a handle to it to read the state afterwards.
#
# The handler sees the request the generated client BUILT, so a double that
# reads it with the same generated messages (`decode_json[CommitRequest]`)
# exercises everything but the socket. No socket, no network.
# =============================================================================

from std.memory import ArcPointer

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)

from .firestore_scripted import scripted_http_response


@fieldwise_init
struct ExchangeAnswer(Copyable, Movable):
    """A handler's answer: the HTTP status and the JSON body."""

    var status: Int
    var body: String


trait HttpExchange(Movable, Deinitable):
    """Answers one HTTP request. `target` is the request target (path and
    query) as written; `body` the request body."""

    def answer(
        mut self, method: String, target: String, body: String
    ) raises -> ExchangeAnswer:
        ...


def _find(b: List[UInt8], needle: StringSlice, start: Int) -> Int:
    var nb = needle.as_bytes()
    var i = start
    while i + len(nb) <= len(b):
        var same = True
        for j in range(len(nb)):
            if b[i + j] != nb[j]:
                same = False
                break
        if same:
            return i
        i += 1
    return -1


def _text(b: List[UInt8], start: Int, end: Int) -> String:
    var out = List[UInt8](capacity=end - start)
    for i in range(start, end):
        out.append(b[i])
    return String(unsafe_from_utf8=Span(out))


struct ExchangeStream[H: HttpExchange](IoStream, Movable, Deinitable):
    """One connection of an `ExchangeConnector`: it buffers what the client
    writes, and on the first read answers the request through the handler
    (`Connection: close`, so one request per connection)."""

    var _handler: ArcPointer[Self.H]
    var _in: List[UInt8]
    var _out: List[UInt8]
    var _out_at: Int
    var _answered: Bool

    def __init__(out self, handler: ArcPointer[Self.H]):
        self._handler = handler
        self._in = List[UInt8]()
        self._out = List[UInt8]()
        self._out_at = 0
        self._answered = False

    def _answer(mut self) raises:
        var head_end = _find(self._in, "\r\n\r\n", 0)
        if head_end < 0:
            raise Error("ExchangeStream: the client read before writing a request")
        var head = _text(self._in, 0, head_end)
        var lines = head.split("\r\n")
        var first = String(lines[0]).split(" ")
        if len(first) < 2:
            raise Error("ExchangeStream: no request line")
        var length = 0
        for i in range(1, len(lines)):
            var line = String(lines[i]).lower()
            if line.startswith("content-length: "):
                length = atol(String(unsafe_from_utf8=line.as_bytes()[16:]))
        var start = head_end + 4
        if start + length > len(self._in):
            raise Error("ExchangeStream: the request body is incomplete")
        var body = _text(self._in, start, start + length)
        var a = self._handler[].answer(String(first[0]), String(first[1]), body)
        self._out = scripted_http_response(a.status, a.body)
        self._answered = True

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        _ = reactor
        if not self._answered:
            self._answer()
        var n = len(self._out) - self._out_at
        if n <= 0:
            return StreamIo.eof()
        if n > len(dst):
            n = len(dst)
        for i in range(n):
            dst[i] = self._out[self._out_at + i]
        self._out_at += n
        return StreamIo.ready(Int64(n))

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        _ = reactor
        for i in range(len(src)):
            self._in.append(src[i])
        return StreamIo.ready(Int64(len(src)))

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return Int32(-1)


struct ExchangeConnector[H: HttpExchange](Connector, Movable, Deinitable):
    """A connector whose every connection is answered by the shared handler
    `H`. `is_tls` is claimed (the generated clients send https) without any
    TLS; `refuse_every_dial` makes every connect raise instead (a transport
    that answers nothing)."""

    comptime Stream = ExchangeStream[Self.H]

    var _handler: ArcPointer[Self.H]
    var _refuse: Bool
    var _dials: Int

    def __init__(out self, handler: ArcPointer[Self.H]):
        self._handler = handler
        self._refuse = False
        self._dials = 0

    @staticmethod
    def refuse_every_dial(handler: ArcPointer[Self.H]) -> Self:
        var c = Self(handler)
        c._refuse = True
        return c^

    def dial_count(self) -> Int:
        return self._dials

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> Self.Stream:
        _ = reactor
        _ = ip_be
        _ = port
        self._dials += 1
        if self._refuse:
            raise Error(
                "HttpError[CONNECT_FAILED]: this exchange connector refuses"
                " every dial, on purpose"
            )
        return ExchangeStream[Self.H](self._handler)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return True

    def set_dial_host(mut self, var host: String):
        pass
