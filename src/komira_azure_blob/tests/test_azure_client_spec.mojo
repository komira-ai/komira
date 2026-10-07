# The SAS query layer, AzureCredential, AzureClientSpec and an AzureFs built
# from a spec, over scripted HTTP: no socket, no emulator.
#
# Rows:
#  * azure_sas_query_normalize: a leading `?` is dropped; an empty token,
#    a bare `?`, a token with no `sig=` parameter (`xsig=` is not one), and a
#    token holding CR/LF, a space or `#` are refused by exact message, which
#    names the offset and never the token.
#  * SasQueryLayer over a capturing service: the token lands in the query
#    and the request line (after an existing query, with `&`), the headers
#    and a PUT's body bytes after the request line are kept byte for byte,
#    and an empty token leaves the request bytes untouched.
#  * AzureClient with `sas_query`: a range GET's request line carries the
#    token and no Authorization header is sent; a List Blobs request carries
#    it after `restype=container&comp=list...`; a key and a token together
#    are refused.
#  * AzureCredential: a shared key without an account or a key is refused;
#    the kinds.
#  * AzureClientSpec: a Shared Key for another account than the endpoint's
#    is refused by exact message.
#  * AzureFs from a spec alone builds nothing until its first verb, then
#    reads through a client built from the spec: a SAS spec puts the token
#    on the wire, a Shared Key spec signs, and a clone builds its own client
#    from the same spec, signing the same way.
from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_blob import (
    AZURE_CREDENTIAL_ANONYMOUS,
    AZURE_CREDENTIAL_SAS,
    AZURE_CREDENTIAL_SHARED_KEY,
    AzureClient,
    AzureClientSpec,
    AzureConfig,
    AzureCredential,
    AzureFs,
    SasQueryLayer,
    azure_sas_query_normalize,
)
from komira_azure_core import AzureSas, AzureSharedKey
from komira_http_client.body import BytesBody, EmptyBody, RequestBody
from komira_http_client.client import build_get_request, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.request_writer import method_put
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector, TRANSPORT_KIND_KERNEL_TCP
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime ACCOUNT = "devstoreaccount1"
comptime FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime TOKEN = "sv=2021-08-06&sp=r&sig=abc%2Bdef%3D"


def _text(bytes: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(bytes))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


# ---- azure_sas_query_normalize ----------------------------------------------


def test_normalize_drops_a_leading_question_mark() raises:
    assert_equal(azure_sas_query_normalize("?" + TOKEN), TOKEN)
    assert_equal(azure_sas_query_normalize(TOKEN), TOKEN)
    assert_equal(azure_sas_query_normalize("sig=x"), "sig=x")


def test_normalize_refusals() raises:
    with assert_raises(contains="azure_sas: the SAS token is empty"):
        _ = azure_sas_query_normalize("")
    with assert_raises(contains="azure_sas: the SAS token is empty"):
        _ = azure_sas_query_normalize("?")
    with assert_raises(contains="azure_sas: the SAS token carries no sig= parameter"):
        _ = azure_sas_query_normalize("sv=1&sp=r")
    with assert_raises(contains="azure_sas: the SAS token carries no sig= parameter"):
        _ = azure_sas_query_normalize("sv=1&xsig=a")
    with assert_raises(
        contains="azure_sas: the SAS token holds a byte that is not visible ASCII or is '#', at offset 10"
    ):
        _ = azure_sas_query_normalize("sv=1&sig=a\r\nX-Evil: 1")
    with assert_raises(contains="is not visible ASCII or is '#', at offset 11"):
        _ = azure_sas_query_normalize("?sv=1&sig=a b")
    with assert_raises(contains="is not visible ASCII or is '#', at offset 10"):
        _ = azure_sas_query_normalize("sv=1&sig=a#frag")
    # The refusal never carries the token.
    try:
        _ = azure_sas_query_normalize("sv=1&sig=SECRETVALUE ")
    except e:
        assert_false(String(e).find("SECRETVALUE") >= 0, String(e))


# ---- SasQueryLayer ----------------------------------------------------------


struct WireService(HttpService, Movable, Deinitable):
    """Keeps the request bytes and query of the last request; answers 200
    with an empty body."""

    var wire: String
    var query: String

    def __init__(out self):
        self.wire = String("")
        self.query = String("")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self.wire = _text(req.request_bytes)
        self.query = String(req.url.query)
        _ = req^
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(List[UInt8]())
        )
        resp.status = Int32(200)
        resp.reason = String("OK")
        resp.headers = HeaderMap()
        resp.headers.append(String("Content-Length"), String("0"))
        resp.connection_close = False
        return resp^


def _url(query: String) -> Url:
    var u = Url(scheme=String("http"), host=String("127.0.0.1"), port=UInt16(10000), path=String("/devstoreaccount1/c/k.bin"))
    u.query = query
    return u^


def _through[B: RequestBody](token: String, var req: ClientRequest[B]) raises -> WireService:
    var layer = SasQueryLayer[WireService].wrap(WireService(), token)
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    _ = layer.call[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, B](req^, conn, reactor)
    var out = WireService()
    out.wire = layer._inner.wire.copy()
    out.query = layer._inner.query.copy()
    return out^


def _get(query: String) raises -> ClientRequest[EmptyBody]:
    var h = HeaderMap()
    h.append(String("x-ms-version"), String("2021-08-06"))
    h.append(String("Range"), String("bytes=0-3"))
    return build_get_request(_url(query), h^)


def test_the_layer_appends_the_token() raises:
    var svc = _through("?" + TOKEN, _get(""))
    assert_equal(svc.query, TOKEN)
    assert_true(
        svc.wire.startswith("GET /devstoreaccount1/c/k.bin?" + TOKEN + " HTTP/1.1\r\n"),
        svc.wire,
    )
    # Every header after the request line is the request's own.
    var plain = _get("")
    var original = _text(plain.request_bytes)
    var at = original.find("\r\n")
    assert_true(svc.wire.endswith(String(original[byte=at:original.byte_length()])), svc.wire)


def test_the_token_follows_an_existing_query() raises:
    var svc = _through(TOKEN, _get("restype=container&comp=list"))
    assert_equal(svc.query, "restype=container&comp=list&" + TOKEN)
    assert_true(
        svc.wire.startswith(
            "GET /devstoreaccount1/c/k.bin?restype=container&comp=list&" + TOKEN + " HTTP/1.1\r\n"
        ),
        svc.wire,
    )


def test_a_body_after_the_request_line_is_kept() raises:
    var h = HeaderMap()
    h.append(String("x-ms-blob-type"), String("BlockBlob"))
    var req = build_request_with_body[BytesBody](
        method_put(), _url(""), h^, BytesBody.from_str("PAYLOAD-BYTES")
    )
    var original = _text(req.request_bytes)
    var svc = _through(TOKEN, req^)
    assert_true(svc.wire.startswith("PUT /devstoreaccount1/c/k.bin?" + TOKEN + " HTTP/1.1\r\n"), svc.wire)
    assert_true(svc.wire.endswith("\r\n\r\nPAYLOAD-BYTES"), svc.wire)
    var at = original.find("\r\n")
    assert_true(svc.wire.endswith(String(original[byte=at:original.byte_length()])), svc.wire)


def test_an_empty_token_passes_the_request_through() raises:
    var original = _text(_get("a=b").request_bytes)
    var svc = _through("", _get("a=b"))
    assert_equal(svc.wire, original)
    assert_equal(svc.query, "a=b")
    with assert_raises(contains="azure_sas: the SAS token carries no sig= parameter"):
        _ = SasQueryLayer[WireService].wrap(WireService(), "sv=1")


# ---- AzureClient with a SAS token -------------------------------------------


def _answer_206() -> List[UInt8]:
    return _bytes(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n"
        "Content-Range: bytes 0-3/10\r\n\r\nabcd"
    )


def _captured_client(
    var answer: List[UInt8], capture: ArcPointer[List[UInt8]], key_b64: String, sas: String
) raises -> AzureClient[ScriptedConnector]:
    return AzureClient[ScriptedConnector](
        account=String(ACCOUNT),
        key_b64=key_b64,
        connector=ScriptedConnector.with_stream(ScriptedStream.empty()),
        call_connector=ScriptedConnector.with_stream(
            ScriptedStream.from_read_script_with_capture(answer^, capture)
        ),
        config=AzureConfig.azurite(String(ACCOUNT)),
        sas_query=sas,
    )


def test_a_sas_client_puts_the_token_on_the_wire() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var client = _captured_client(_answer_206(), capture, String(""), "?" + TOKEN)
    var body = client.get_blob_range("c", "k.bin", 0, 3)
    assert_equal(_text(body), "abcd")
    var wire = _text(capture[])
    assert_true(
        wire.startswith("GET /devstoreaccount1/c/k.bin?" + TOKEN + " HTTP/1.1\r\n"), wire
    )
    assert_false(wire.lower().find("authorization") >= 0, wire)


def test_a_sas_listing_keeps_its_own_query_first() raises:
    var xml = String(
        '<?xml version="1.0" encoding="utf-8"?><EnumerationResults'
        ' ContainerName="c"><Blobs><Blob><Name>p/a</Name></Blob></Blobs>'
        "<NextMarker /></EnumerationResults>"
    )
    var answer = _bytes(
        "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: "
        + String(xml.byte_length())
        + "\r\n\r\n"
        + xml
    )
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var client = _captured_client(answer^, capture, String(""), TOKEN)
    var fs = AzureFs[ScriptedConnector](
        container=String("c"), client=client^, spec=_spec_sas()
    )
    var names = fs.list("p/")
    assert_equal(len(names), 1)
    assert_equal(names[0], "p/a")
    var wire = _text(capture[])
    assert_true(
        wire.startswith(
            "GET /devstoreaccount1/c?restype=container&comp=list&prefix=p%2F&" + TOKEN + " HTTP/1.1\r\n"
        ),
        wire,
    )


def test_a_key_and_a_token_together_are_refused() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    with assert_raises(
        contains="AzureClient: a shared key and a SAS token were both given; a request is authorized by one"
    ):
        _ = _captured_client(_answer_206(), capture, String(FAKE_KEY), TOKEN)


# ---- AzureCredential and AzureClientSpec -------------------------------------


def test_credential_kinds_and_refusals() raises:
    assert_equal(AzureCredential.anonymous().kind(), AZURE_CREDENTIAL_ANONYMOUS)
    var k = AzureCredential.shared_key(AzureSharedKey(String(ACCOUNT), String(FAKE_KEY)))
    assert_equal(k.kind(), AZURE_CREDENTIAL_SHARED_KEY)
    assert_equal(k.shared_key_account(), ACCOUNT)
    assert_equal(AzureCredential.sas(AzureSas("?" + TOKEN)).kind(), AZURE_CREDENTIAL_SAS)
    with assert_raises(contains="azure_credential: a shared key needs an account name and a key"):
        _ = AzureCredential.shared_key(AzureSharedKey(String(""), String(FAKE_KEY)))
    with assert_raises(contains="azure_credential: a shared key needs an account name and a key"):
        _ = AzureCredential.shared_key(AzureSharedKey(String(ACCOUNT), String("")))
    with assert_raises(contains="azure_sas: the SAS token is empty"):
        _ = AzureCredential.sas(AzureSas(String("")))


def _mk_one_206() raises -> ScriptedConnector:
    """One dial, answering one 4-byte range; a second dial finds no stream."""
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(_answer_206()))


def _spec_sas() raises -> AzureClientSpec[ScriptedConnector]:
    return AzureClientSpec[ScriptedConnector](
        AzureConfig.azurite(String(ACCOUNT)), AzureCredential.sas(AzureSas(TOKEN)), _mk_one_206
    )


def test_a_spec_for_another_account_is_refused() raises:
    with assert_raises(
        contains="azure_client_spec: the shared key is for account 'otheraccount' and the endpoint is account 'devstoreaccount1'"
    ):
        _ = AzureClientSpec[ScriptedConnector](
            AzureConfig.azurite(String(ACCOUNT)),
            AzureCredential.shared_key(AzureSharedKey(String("otheraccount"), String(FAKE_KEY))),
            _mk_one_206,
        )


# ---- AzureFs built from a spec ----------------------------------------------


struct WireConnector(Connector, Movable, Deinitable):
    """Answers every dial with one 4-byte range and keeps every byte
    written to it, so a test reads the wire back from the connector a
    built client holds."""

    comptime Stream = ScriptedStream

    var _capture: ArcPointer[List[UInt8]]

    def __init__(out self):
        self._capture = ArcPointer[List[UInt8]](List[UInt8]())

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> ScriptedStream:
        return ScriptedStream.from_read_script_with_capture(_answer_206(), self._capture)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^

    def wire(self) -> String:
        return _text(self._capture[])


def _mk_wire() raises -> WireConnector:
    return WireConnector()


def _read_and_wire(fs: AzureFs[WireConnector]) raises -> String:
    var f = fs.open("data/k.bin")
    var buf = fs.read_at(f, 0, 4)
    var view = buf.view_range_ro(0, buf.len())
    assert_equal(String(unsafe_from_utf8=view.into_span()), "abcd")
    return fs._client.get_mut_interior(0).value()._inner_connector.value().wire()


def test_a_spec_built_fs_dials_nothing_until_its_first_verb() raises:
    var fs = AzureFs[WireConnector](
        container=String("c"),
        spec=AzureClientSpec[WireConnector](
            AzureConfig.azurite(String(ACCOUNT)), AzureCredential.sas(AzureSas(TOKEN)), _mk_wire
        ),
    )
    assert_false(fs.client_built())
    assert_equal(fs.container(), "c")
    assert_equal(fs.spec().credential_kind(), AZURE_CREDENTIAL_SAS)
    var wire = _read_and_wire(fs)
    assert_true(fs.client_built())
    assert_true(
        wire.startswith("GET /devstoreaccount1/c/data/k.bin?" + TOKEN + " HTTP/1.1\r\n"), wire
    )
    assert_false(wire.lower().find("authorization") >= 0, wire)


def test_a_clone_builds_its_client_from_the_same_spec() raises:
    var fs = AzureFs[WireConnector](
        container=String("c"),
        spec=AzureClientSpec[WireConnector](
            AzureConfig.azurite(String(ACCOUNT)),
            AzureCredential.shared_key(AzureSharedKey(String(ACCOUNT), String(FAKE_KEY))),
            _mk_wire,
        ),
    )
    var wire = _read_and_wire(fs)
    assert_true(wire.startswith("GET /devstoreaccount1/c/data/k.bin HTTP/1.1\r\n"), wire)
    assert_true(wire.lower().find("authorization: sharedkey devstoreaccount1:") >= 0, wire)
    var c = fs.clone()
    assert_false(c.client_built())
    var cwire = _read_and_wire(c)
    # The clone's wire is its own connector's: one request, signed the same way.
    assert_true(cwire.startswith("GET /devstoreaccount1/c/data/k.bin HTTP/1.1\r\n"), cwire)
    assert_equal(cwire.find("GET ", 1), -1)
    assert_true(cwire.lower().find("authorization: sharedkey devstoreaccount1:") >= 0, cwire)


def main() raises:
    test_normalize_drops_a_leading_question_mark()
    test_normalize_refusals()
    test_the_layer_appends_the_token()
    test_the_token_follows_an_existing_query()
    test_a_body_after_the_request_line_is_kept()
    test_an_empty_token_passes_the_request_through()
    test_a_sas_client_puts_the_token_on_the_wire()
    test_a_sas_listing_keeps_its_own_query_first()
    test_a_key_and_a_token_together_are_refused()
    test_credential_kinds_and_refusals()
    test_a_spec_for_another_account_is_refused()
    test_a_spec_built_fs_dials_nothing_until_its_first_verb()
    test_a_clone_builds_its_client_from_the_same_spec()
    print("OK")
