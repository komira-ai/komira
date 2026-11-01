# =============================================================================
# test_http_clients.mojo -- the embedder and the chat client over HTTP, against a
# server in this process.
# =============================================================================
#
# The server is the one of test_http_transport (a loopback listener on a second
# thread answering scripted bytes and recording what it received); nothing waits
# on time.
#
#   embedder     a batch goes out in one request to the configured path with the
#                model id and the texts unchanged, rows come back in input order
#                whatever order the server listed them, a response of the wrong
#                width is refused (and accepted at its own width), a malformed
#                response is refused (test_embedder_*).
#   chat client  two different prompts reach the wire unchanged, once substituted
#                (test_chat_client_two_prompts_reach_the_wire_unchanged); the
#                caller's response schema is attached
#                (test_chat_client_attaches_the_callers_schema); a judgment and a
#                synthesis send the messages they should and read the answer
#                (test_chat_client_judgments_and_synthesis_over_http); malformed
#                JSON, prose without an object and a server error object are
#                refused (test_chat_client_refuses_malformed_json).
# =============================================================================

from std.memory import Pointer
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.tcp_stream import TcpListener, TcpStream
from komira_atomic_alias import AtomicI64
from komira_fork_join import ForkJoinBody, fork_join
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_json import parse_json_value
from komira_kg_format import EntityMention
from komira_kg_llm import (
    ChatCompletionsLlmClient,
    EmbeddingsWireEmbedder,
    ExtractionPrompt,
    HttpChatTransport,
    HttpEmbedTransport,
    JudgmentPrompt,
    NoAuth,
    WireEndpoint,
)


# -----------------------------------------------------------------------------
# The server.
# -----------------------------------------------------------------------------


def _backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


def _bytes_of(text: String) -> List[UInt8]:
    var out = List[UInt8](capacity=text.byte_length())
    out.extend(text.as_bytes())
    return out^


def _find(hay: List[UInt8], needle: String, start: Int = 0) -> Int:
    """The first index at or after `start` where `needle` occurs, or -1."""
    var nb = needle.as_bytes()
    var m = len(nb)
    var i = start
    while i + m <= len(hay):
        var same = True
        for j in range(m):
            if hay[i + j] != nb[j]:
                same = False
                break
        if same:
            return i
        i += 1
    return -1


def _lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        out.append(c)
    return String(from_utf8_lossy=Span(out))


def _content_length(head_lower: String) -> Int:
    """The Content-Length in a lower-cased request head, or 0."""
    var key = "content-length:"
    var at = head_lower.find(key)
    if at < 0:
        return 0
    var bytes = head_lower.as_bytes()
    var i = at + key.byte_length()
    var value = 0
    while i < len(bytes) and bytes[i] == 0x20:
        i += 1
    while i < len(bytes) and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        value = value * 10 + Int(bytes[i] - 0x30)
        i += 1
    return value


def _read_request(
    mut conn: TcpStream, mut reactor: Reactor[NoopSink]
) raises -> List[UInt8]:
    """Read one request: the head, then the body its head declares."""
    var got = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var need = -1
    while True:
        var n = conn.read[NoopSink](reactor, Span(buf))
        if n <= 0:
            break
        got.extend(Span(buf)[0 : Int(n)])
        if need < 0:
            var head_end = _find(got, "\r\n\r\n")
            if head_end >= 0:
                var head = _lower(String(from_utf8_lossy=Span(got)[0:head_end]))
                if "transfer-encoding: chunked" in head:
                    need = -2
                else:
                    need = head_end + 4 + _content_length(head)
        if need >= 0 and len(got) >= need:
            break
        if need == -2 and _find(got, "\r\n0\r\n\r\n") >= 0:
            break
    return got^


struct _Server(Movable):
    """A loopback server that answers each connection with a scripted reply."""

    var listener: TcpListener
    var reactor: Reactor[NoopSink]
    var replies: List[List[UInt8]]
    var requests: List[List[UInt8]]
    var served: Int
    var fault: String
    var port: UInt16

    def __init__(out self, var replies: List[List[UInt8]]) raises:
        self.listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16)
        )
        self.port = self.listener.local_port()
        self.reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), _backend()
        )
        self.replies = replies^
        self.requests = List[List[UInt8]]()
        self.served = 0
        self.fault = String()

    def step(mut self) raises:
        """Accept and answer one connection if one is waiting."""
        if self.served >= len(self.replies):
            _ = self.reactor.poll_completions(timeout_us=Int32(0))
            return
        var accepted = self.listener.try_accept()
        if not accepted.is_ready():
            _ = self.reactor.poll_completions(timeout_us=Int32(0))
            return
        var conn = TcpStream(Int32(Int(accepted.value())))
        try:
            self.requests.append(_read_request(conn, self.reactor))
            var reply = self.replies[self.served].copy()
            var sent = 0
            while sent < len(reply):
                var n = conn.write[NoopSink](
                    self.reactor, Span(reply)[sent:]
                )
                sent += Int(n)
        except e:
            self.fault = String(e)
        self.served += 1


def http_reply(status: Int, body: String) -> List[UInt8]:
    """A complete reply with the right Content-Length, then the connection ends."""
    var text = (
        "HTTP/1.1 "
        + String(status)
        + " Scripted\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    return _bytes_of(text)


# -----------------------------------------------------------------------------
# Running a client leg beside the server.
# -----------------------------------------------------------------------------


trait ClientLeg(Movable):
    def run(mut self) raises:
        ...


struct _StopFlag(Movable):
    var stop: AtomicI64

    def __init__(out self):
        self.stop = AtomicI64(Int64(0))


struct _Duet[
    C: ClientLeg,
    so: MutOrigin,
    co: MutOrigin,
    fo: MutOrigin,
](ForkJoinBody):
    var server: Pointer[_Server, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[_Server, Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
    ):
        self.server = server
        self.client = client
        self.flag = flag

    def run(self, tid: Int) raises:
        if tid == 0:
            while self.flag[].stop.load() == Int64(0):
                self.server[].step()
            return
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def _serve_while[C: ClientLeg](mut server: _Server, mut leg: C) raises:
    var flag = _StopFlag()
    # SAFETY: the three pointers borrow `server`, `leg` and `flag`, which live in
    # this frame until `fork_join` has joined both threads. Thread 0 alone touches
    # the server, thread 1 alone the leg, and the flag only through its atomic.
    var duet = _Duet(Pointer(to=server), Pointer(to=leg), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^


comptime _TIMEOUT_MS: Int = 30_000
comptime _MAX_BYTES: Int = 4096


def _mk(timeout_ms: Int) raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def _one(var reply: List[UInt8]) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(reply^)
    return out^


def _head(server: _Server, i: Int) -> String:
    """The request head of connection `i`, lower-cased."""
    var req = server.requests[i].copy()
    var end = _find(req, "\r\n\r\n")
    return _lower(String(from_utf8_lossy=Span(req)[0:end]))


def _body(server: _Server, i: Int) -> String:
    """The request body of connection `i`, exactly as received."""
    var req = server.requests[i].copy()
    var end = _find(req, "\r\n\r\n")
    return String(from_utf8_lossy=Span(req)[end + 4 :])


# -----------------------------------------------------------------------------
# The embedder over HTTP.
# -----------------------------------------------------------------------------


struct _EmbedLeg(ClientLeg):
    var port: UInt16
    var dimension: Int
    var texts: List[String]
    var vectors: List[List[Float64]]
    var error: String

    def __init__(out self, port: UInt16, dimension: Int, var texts: List[String]):
        self.port = port
        self.dimension = dimension
        self.texts = texts^
        self.vectors = List[List[Float64]]()
        self.error = String()

    def run(mut self) raises:
        try:
            var ep = WireEndpoint(
                "127.0.0.1",
                self.port,
                "/embed/here",
                timeout_ms=_TIMEOUT_MS,
                max_response_bytes=_MAX_BYTES,
            )
            var transport = HttpEmbedTransport[KernelTcpConnector, NoAuth](
                _mk, ep^, NoAuth()
            )
            var e = EmbeddingsWireEmbedder[
                HttpEmbedTransport[KernelTcpConnector, NoAuth]
            ](transport^, "embed-model-7", self.dimension)
            self.vectors = e.embed_batch(self.texts)
        except e:
            self.error = String(e)


def _embed(
    var replies: List[List[UInt8]], dimension: Int, var texts: List[String]
) raises -> Tuple[_EmbedLeg, _Server]:
    var server = _Server(replies^)
    var leg = _EmbedLeg(server.port, dimension, texts^)
    _serve_while(server, leg)
    return (leg^, server^)


def test_embedder_batch_goes_out_in_one_request() raises:
    var texts = List[String]()
    texts.append("first \"text\"")
    texts.append("second\ntext é")
    var rows = (
        '{"data":[{"index":1,"embedding":[0.5,1.5,2.5]},'
        '{"index":0,"embedding":[-1,0,1e-3]}]}'
    )
    var r = _embed(_one(http_reply(200, rows)), 3, texts.copy())
    assert_equal(r[0].error, "")
    # One request, to the configured path, carrying the model and both texts.
    assert_equal(len(r[1].requests), 1)
    assert_true(_head(r[1], 0).startswith("post /embed/here http/1.1"))
    var sent = parse_json_value(_body(r[1], 0))
    assert_equal(sent.get("model").as_string(), "embed-model-7")
    assert_equal(sent.get("input").array_len(), 2)
    assert_equal(sent.get("input").element_at(0).as_string(), texts[0])
    assert_equal(sent.get("input").element_at(1).as_string(), texts[1])
    # The rows come back in input order whatever order the server listed them.
    assert_equal(len(r[0].vectors), 2)
    assert_equal(r[0].vectors[0][0], -1.0)
    assert_equal(r[0].vectors[0][2], 0.001)
    assert_equal(r[0].vectors[1][0], 0.5)
    assert_equal(r[0].vectors[1][2], 2.5)


def test_embedder_refuses_a_response_of_the_wrong_dimension() raises:
    var texts = List[String]()
    texts.append("one")
    var rows = '{"data":[{"index":0,"embedding":[0.5,1.5,2.5]}]}'
    var r = _embed(_one(http_reply(200, rows)), 4, texts.copy())
    assert_equal(len(r[0].vectors), 0)
    assert_true("3 components, the embedder's dimension is 4" in r[0].error, r[0].error)
    # The control: the same response is accepted at its own dimension.
    var ok = _embed(_one(http_reply(200, rows)), 3, texts^)
    assert_equal(ok[0].error, "")
    assert_equal(len(ok[0].vectors[0]), 3)


def test_embedder_refuses_a_malformed_response() raises:
    var texts = List[String]()
    texts.append("one")
    var r = _embed(_one(http_reply(200, '{"data":[{"embedding":[0.5,')), 2, texts^)
    assert_equal(len(r[0].vectors), 0)
    assert_true("JsonError" in r[0].error, r[0].error)


# -----------------------------------------------------------------------------
# The chat client over HTTP.
# -----------------------------------------------------------------------------


struct _ChatLeg(ClientLeg):
    var port: UInt16
    var kind: Int  # 0 extract, 1 contradiction, 2 same entity, 3 synthesize
    var system_text: String
    var user_template: String
    var text: String
    var known: List[EntityMention]
    var schema: String
    var entity_names: List[String]
    var triple_subjects: List[String]
    var verdict: Bool
    var answer: String
    var error: String

    def __init__(
        out self,
        port: UInt16,
        kind: Int,
        system_text: String,
        user_template: String,
        text: String,
        schema: String = "",
    ):
        self.port = port
        self.kind = kind
        self.system_text = system_text
        self.user_template = user_template
        self.text = text
        self.known = List[EntityMention]()
        self.schema = schema
        self.entity_names = List[String]()
        self.triple_subjects = List[String]()
        self.verdict = False
        self.answer = String()
        self.error = String()

    def run(mut self) raises:
        try:
            var ep = WireEndpoint(
                "127.0.0.1",
                self.port,
                "/chat/here",
                timeout_ms=_TIMEOUT_MS,
                max_response_bytes=_MAX_BYTES,
            )
            var transport = HttpChatTransport[KernelTcpConnector, NoAuth](
                _mk, ep^, NoAuth()
            )
            var client = ChatCompletionsLlmClient[
                HttpChatTransport[KernelTcpConnector, NoAuth]
            ](
                transport^,
                "chat-model-3",
                ExtractionPrompt(
                    self.system_text,
                    self.user_template,
                    List[String](),
                    self.schema,
                ),
                JudgmentPrompt.neutral(),
            )
            if self.kind == 0:
                var ex = client.extract(self.text, self.known)
                for i in range(len(ex.entities)):
                    self.entity_names.append(ex.entities[i].name)
                for i in range(len(ex.triples)):
                    self.triple_subjects.append(ex.triples[i].subject_name)
            elif self.kind == 1:
                self.verdict = client.judge_contradiction(self.text, "old")
            elif self.kind == 2:
                self.verdict = client.judge_same_entity(self.text, "", "b", "s")
            else:
                self.answer = client.synthesize(self.system_text, self.text)
        except e:
            self.error = String(e)


def _chat(
    var replies: List[List[UInt8]],
    kind: Int,
    system_text: String,
    user_template: String,
    text: String,
    schema: String = "",
) raises -> Tuple[_ChatLeg, _Server]:
    var server = _Server(replies^)
    var leg = _ChatLeg(
        server.port, kind, system_text, user_template, text, schema
    )
    _serve_while(server, leg)
    return (leg^, server^)


def test_chat_client_two_prompts_reach_the_wire_unchanged() raises:
    var system_one = String('First system: say "only" JSON.\nLine two é.')
    var system_two = String("Second system text, wholly different \\ backslash.")
    var template_one = String("<<{text}>> and {unknown} stay")
    var template_two = String("{text}\n---\nsecond")
    var reply = http_reply(
        200,
        '{"choices":[{"message":{"content":"{\\"entities\\":[{\\"name\\":\\"X\\"}],'
        '\\"triples\\":[]}"}}]}',
    )
    var a = _chat(_one(reply.copy()), 0, system_one, template_one, "alpha {text}")
    var b = _chat(_one(reply.copy()), 0, system_two, template_two, "beta")
    assert_equal(a[0].error, "")
    assert_equal(b[0].error, "")
    assert_equal(len(a[0].entity_names), 1)
    assert_equal(a[0].entity_names[0], "X")
    var sent_a = parse_json_value(_body(a[1], 0))
    var sent_b = parse_json_value(_body(b[1], 0))
    assert_true(_head(a[1], 0).startswith("post /chat/here http/1.1"))
    assert_equal(sent_a.get("model").as_string(), "chat-model-3")
    var msgs_a = sent_a.get("messages")
    assert_equal(msgs_a.element_at(0).get("role").as_string(), "system")
    assert_equal(msgs_a.element_at(0).get("content").as_string(), system_one)
    assert_equal(msgs_a.element_at(1).get("role").as_string(), "user")
    # The text is substituted once; its own `{text}` is not substituted again.
    assert_equal(
        msgs_a.element_at(1).get("content").as_string(),
        "<<alpha {text}>> and {unknown} stay",
    )
    var msgs_b = sent_b.get("messages")
    assert_equal(msgs_b.element_at(0).get("content").as_string(), system_two)
    assert_equal(
        msgs_b.element_at(1).get("content").as_string(), "beta\n---\nsecond"
    )
    assert_false(sent_a.has("response_format"))


def test_chat_client_attaches_the_callers_schema() raises:
    var reply = http_reply(
        200, '{"choices":[{"message":{"content":"{\\"entities\\":[]}"}}]}'
    )
    var schema = '{"type":"object","properties":{"entities":{"type":"array"}}}'
    var r = _chat(_one(reply^), 0, "sys", "{text}", "t", schema)
    assert_equal(r[0].error, "")
    var sent = parse_json_value(_body(r[1], 0))
    var format = sent.get("response_format")
    assert_equal(format.get("type").as_string(), "json_schema")
    assert_equal(format.get("json_schema").get("schema").serialize(), schema)


def test_chat_client_judgments_and_synthesis_over_http() raises:
    var yes = http_reply(200, '{"choices":[{"message":{"content":"Yes."}}]}')
    var no = http_reply(200, '{"choices":[{"message":{"content":"No"}}]}')
    var a = _chat(_one(yes.copy()), 1, "s", "{text}", "new fact")
    assert_equal(a[0].error, "")
    assert_true(a[0].verdict)
    var sent = parse_json_value(_body(a[1], 0))
    var user = sent.get("messages").element_at(1).get("content").as_string()
    assert_true("NEW: new fact" in user, user)
    assert_true("OLD: old" in user, user)
    var b = _chat(_one(no.copy()), 2, "s", "{text}", "name a")
    assert_equal(b[0].error, "")
    assert_false(b[0].verdict)
    var sent_b = parse_json_value(_body(b[1], 0))
    var user_b = sent_b.get("messages").element_at(1).get("content").as_string()
    assert_true("A: name a\n" in user_b, user_b)
    assert_true("B: b (s)" in user_b, user_b)
    var c = _chat(_one(yes^), 3, "synthesis system", "{text}", "the evidence")
    assert_equal(c[0].error, "")
    assert_equal(c[0].answer, "Yes.")
    var sent_c = parse_json_value(_body(c[1], 0))
    assert_equal(
        sent_c.get("messages").element_at(0).get("content").as_string(),
        "synthesis system",
    )
    assert_equal(
        sent_c.get("messages").element_at(1).get("content").as_string(),
        "the evidence",
    )


def test_chat_client_refuses_malformed_json() raises:
    var cases = List[String]()
    cases.append("{not json")
    cases.append('{"choices":[{"message":{"content":"{\\"entities\\":')
    cases.append("[]")
    cases.append("")
    for k in range(len(cases)):
        var r = _chat(_one(http_reply(200, cases[k])), 0, "sys", "{text}", "t")
        assert_equal(len(r[0].entity_names), 0)
        assert_true(r[0].error.byte_length() > 0, "case " + String(k))
        assert_equal(len(r[1].requests), 1)
    # An answer that is JSON but whose content is not an extraction object.
    var prose = http_reply(
        200, '{"choices":[{"message":{"content":"no object here"}}]}'
    )
    var p = _chat(_one(prose^), 0, "sys", "{text}", "t")
    assert_true("no JSON object" in p[0].error, p[0].error)
    # A server error object is quoted.
    var err = http_reply(200, '{"error":{"message":"model is loading"}}')
    var e = _chat(_one(err^), 0, "sys", "{text}", "t")
    assert_true("model is loading" in e[0].error, e[0].error)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
