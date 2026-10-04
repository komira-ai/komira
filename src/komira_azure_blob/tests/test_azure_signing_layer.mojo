# SharedKeySigningLayer over a capturing HttpService: no socket, no emulator.
# The service keeps the `x-ms-date` and `Authorization` each request reached
# it with, and answers every request with one scripted body.
#
# Azure Shared Key REQUIRES `x-ms-date`, and signs it among the x-ms-*
# headers, and signs the request's query parameters in the canonicalized
# resource. So:
#   * a pinned date is stamped as given, and the Authorization equals a
#     golden computed independently (Python's hmac, values below) over a
#     string-to-sign that includes it;
#   * with NO pinned date the layer stamps the wall clock's date, in
#     HTTP-date form, at sign time — what AzureClient's production layer
#     relies on, since it pins none;
#   * a List Blobs request signs `comp`, `delimiter`, `prefix` (URL-decoded)
#     and `restype`, sorted by name, so the Authorization equals the golden
#     for a canonicalized resource that carries them;
#   * a query string is read into URL-decoded pairs, and a bad escape is
#     refused;
#   * `set_clock_override` changes the stamped date and the signature.
#
# Goldens, by Python, with key = base64.b64decode(FAKE_KEY):
#   GET  "GET" + "\n"*11 + "bytes=0-3\n" + "x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n"
#        + "x-ms-version:2021-08-06\n" + "/devstoreaccount1/devstoreaccount1/c/k.bin"
#        -> 2wjKQrCpIGVUerCsH143RNKgcuFKWtYFMzv83jTbAfU=
#   LIST "GET" + "\n"*12 + "x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n"
#        + "x-ms-version:2021-08-06\n" + "/devstoreaccount1/devstoreaccount1/c\n"
#        + "comp:list\ndelimiter:/\nprefix:dir one/\nrestype:container"
#        -> t3n8TCcmX3nlaYKHhupjzaUSU/g0X9CaCPNZtjjsamU=
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_blob.azure import AzureConfig, AzureStore
from komira_azure_blob.azure_signing import (
    AzureSharedKeySigningContext,
    Header,
    SharedKeySigningLayer,
    StaticSharedKeyProvider,
    azure_shared_key_sign,
    query_params_from,
)
from komira_azure_core import AzureSharedKey
from komira_clock import now_unix_ms
from komira_datetime import parse_http_date
from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime ACCOUNT = "devstoreaccount1"
comptime FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime PINNED_DATE = "Thu, 01 Oct 2026 12:00:00 GMT"
comptime OTHER_DATE = "Fri, 02 Oct 2026 08:49:37 GMT"
comptime API_VERSION = "2021-08-06"
comptime GET_GOLDEN = "SharedKey devstoreaccount1:2wjKQrCpIGVUerCsH143RNKgcuFKWtYFMzv83jTbAfU="
comptime LIST_GOLDEN = "SharedKey devstoreaccount1:t3n8TCcmX3nlaYKHhupjzaUSU/g0X9CaCPNZtjjsamU="

comptime _LIST_XML = (
    '<?xml version="1.0" encoding="utf-8"?><EnumerationResults'
    ' ContainerName="c"><Blobs></Blobs><NextMarker /></EnumerationResults>'
)


struct CapturingService(HttpService, Movable, Deinitable):
    """Answers every request with `body` (status 200) and keeps the
    `x-ms-date` and `Authorization` of the last one."""

    var body: String
    var calls: Int
    var x_ms_date: String
    var has_x_ms_date: Bool
    var authorization: String
    var query: String

    def __init__(out self, var body: String):
        self.body = body^
        self.calls = 0
        self.x_ms_date = String("")
        self.has_x_ms_date = False
        self.authorization = String("")
        self.query = String("")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self.calls += 1
        var d = req.headers.get(String("x-ms-date"))
        self.has_x_ms_date = Bool(d)
        self.x_ms_date = d.value() if d else String("")
        var a = req.headers.get(String("authorization"))
        self.authorization = a.value() if a else String("")
        self.query = String(req.url.query)
        _ = req^
        var bytes = List[UInt8]()
        bytes.extend(Span(self.body.as_bytes()))
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(bytes^)
        )
        resp.status = Int32(200)
        resp.reason = String("OK")
        resp.headers = HeaderMap()
        resp.headers.append(String("Content-Length"), String(self.body.byte_length()))
        resp.connection_close = False
        return resp^


comptime _Layer = SharedKeySigningLayer[CapturingService, StaticSharedKeyProvider]


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _store(var x_ms_date: String, var body: String) -> AzureStore[_Layer]:
    var layer = _Layer.wrap(
        CapturingService(body^),
        StaticSharedKeyProvider.make(String(ACCOUNT), String(FAKE_KEY)),
        x_ms_date^,
    )
    return AzureStore[_Layer].new(AzureConfig.azurite(String(ACCOUNT)), layer^)


def _get(mut store: AzureStore[_Layer]) raises:
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    var body = store.get_range[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        String("c"), String("k.bin"), Int64(0), Int64(3), conn, reactor
    )
    assert_equal(len(body), 4)


def _list(mut store: AzureStore[_Layer]) raises:
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    var page = store.list_page[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        String("c"), String("dir one/"), String("/"), String(""), conn, reactor
    )
    assert_equal(len(page.blobs), 0)


def _get_golden_by_library(x_ms_date: String) raises -> String:
    """The same GET signed by `azure_shared_key_sign` directly."""
    var hdrs = List[Header]()
    hdrs.append(Header(String("x-ms-date"), x_ms_date))
    hdrs.append(Header(String("x-ms-version"), String(API_VERSION)))
    var ctx = AzureSharedKeySigningContext(
        cred=AzureSharedKey(String(ACCOUNT), String(FAKE_KEY)),
        verb=String("GET"),
        account=String(ACCOUNT),
        resource_path=String("/devstoreaccount1/c/k.bin"),
        query_params=List[Header](),
        content_encoding=String(""),
        content_language=String(""),
        content_length=String(""),
        content_md5=String(""),
        content_type=String(""),
        if_modified_since=String(""),
        if_match=String(""),
        if_none_match=String(""),
        if_unmodified_since=String(""),
        range_header=String("bytes=0-3"),
        x_ms_headers=hdrs^,
    )
    return azure_shared_key_sign(ctx).authorization


def test_pinned_date_is_stamped_and_signed() raises:
    var store = _store(String(PINNED_DATE), String("DATA"))
    _get(store)
    ref svc = store._http._inner
    assert_true(svc.has_x_ms_date)
    assert_equal(svc.x_ms_date, PINNED_DATE)
    assert_equal(svc.authorization, GET_GOLDEN)
    assert_equal(svc.authorization, _get_golden_by_library(String(PINNED_DATE)))


def test_no_pinned_date_stamps_the_wall_clock() raises:
    var store = _store(String(""), String("DATA"))
    var before = Int(now_unix_ms() // 1000)
    _get(store)
    var after = Int(now_unix_ms() // 1000)
    ref svc = store._http._inner
    assert_true(svc.has_x_ms_date, "a signed request must carry x-ms-date")
    var stamped = parse_http_date(svc.x_ms_date)
    assert_true(stamped >= before and stamped <= after, svc.x_ms_date)
    # The stamped date is the one that was signed.
    assert_equal(svc.authorization, _get_golden_by_library(svc.x_ms_date))


def test_list_request_signs_its_query_parameters() raises:
    var store = _store(String(PINNED_DATE), String(_LIST_XML))
    _list(store)
    ref svc = store._http._inner
    assert_equal(
        svc.query, "restype=container&comp=list&prefix=dir%20one%2F&delimiter=%2F"
    )
    assert_equal(svc.authorization, LIST_GOLDEN)


def test_query_params_are_url_decoded() raises:
    var q = query_params_from(String("restype=container&comp=list&prefix=a%20b%2Fc&&flag&m=%E2%82%AC"))
    assert_equal(len(q), 5)
    assert_equal(q[0].name, "restype")
    assert_equal(q[0].value, "container")
    assert_equal(q[2].name, "prefix")
    assert_equal(q[2].value, "a b/c")
    assert_equal(q[3].name, "flag")
    assert_equal(q[3].value, "")
    assert_equal(q[4].value, "\u20ac")
    assert_equal(len(query_params_from(String(""))), 0)
    with assert_raises(contains="bad percent-escape"):
        _ = query_params_from(String("a=%zz"))
    with assert_raises(contains="truncated percent-escape"):
        _ = query_params_from(String("a=%2"))


def test_set_clock_override_changes_date_and_signature() raises:
    var store = _store(String(PINNED_DATE), String("DATA"))
    store._http.set_clock_override(String(OTHER_DATE))
    _get(store)
    ref svc = store._http._inner
    assert_equal(svc.x_ms_date, OTHER_DATE)
    assert_equal(svc.authorization, _get_golden_by_library(String(OTHER_DATE)))
    assert_false(svc.authorization == GET_GOLDEN)


def test_anonymous_credential_is_not_signed() raises:
    var layer = _Layer.wrap(
        CapturingService(String("DATA")),
        StaticSharedKeyProvider.make(String(""), String("")),
        String(PINNED_DATE),
    )
    var store = AzureStore[_Layer].new(AzureConfig.azurite(String(ACCOUNT)), layer^)
    _get(store)
    ref svc = store._http._inner
    assert_equal(svc.authorization, "")
    assert_false(svc.has_x_ms_date)


def main() raises:
    test_pinned_date_is_stamped_and_signed()
    test_no_pinned_date_stamps_the_wall_clock()
    test_list_request_signs_its_query_parameters()
    test_query_params_are_url_decoded()
    test_set_clock_override_changes_date_and_signature()
    test_anonymous_credential_is_not_signed()
    print("OK")
