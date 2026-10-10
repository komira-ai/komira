# AzureStore, AzureClient and AzureFs over scripted HTTP: no socket, no
# emulator. A scripting HttpService answers each (method, URL) with a canned
# status and body; a scripted connector serves List Blobs pages in order and
# records the wire.
#
# Rows: the blob and listing URLs, virtual-hosted (real Azure) and
# path-style (Azurite); get_range / head / list_page through the
# HttpService seam, the List Blobs XML and its continuation marker; each
# error status onto its StoreError kind (404, 403, 429/503, 412, 5xx); the
# SharedKeySigningLayer adding `Authorization: SharedKey <account>:<sig>`,
# and nothing for the empty (anonymous) credential; and AzureFs: open, the
# capability flags, is_dir's `/`-normalized probe, `list` walking
# `<NextMarker>` and unioning pages, `list_dir_shallow` across pages, both
# refusing a `<NextMarker>` that never ends after exactly
# AZURE_LIST_MAX_PAGES requests, the read verbs reaching the transport, the write verbs refused (AzureFs is
# read-only) and delete left to komira_fs's raising default.
from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_fs.file_system import WriteMode
from komira_fs.footer_region import FOOTER_SPECULATIVE_WINDOW
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_collections.slab import Slab

from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import (
    Connector,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_azure_blob.azure import (
    AZURE_ERR_NOT_FOUND,
    AZURE_ERR_PERMISSION_DENIED,
    AZURE_ERR_PRECONDITION,
    AZURE_ERR_THROTTLED,
    AZURE_ERR_TRANSPORT,
    AzureConfig,
    AzureStore,
    azure_store_error_kind_from_message,
    build_azure_blob_url,
    build_azure_listing_url,
)
from komira_azure_blob.azure_client import AzureClient
from komira_azure_blob.azure_client_spec import AzureClientSpec, AzureCredential
from komira_azure_core import AzureSharedKey
from komira_azure_blob.azure_fs import (
    AZURE_LIST_MAX_PAGES,
    AzureFs,
    AzureFileHandle,
    AzureWriteFile,
)
from komira_azure_blob.azure_signing import (
    SharedKeySigningLayer,
    StaticSharedKeyProvider,
)


# -----------------------------------------------------------------------------
# ScriptingHttpService — HttpService conformer with per-URL canned responses
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ScriptedEntry(Movable, Deinitable):
    var url_str: String
    var method_name: String
    var status: Int32
    var content_length: Int64
    var etag: String
    var body: List[UInt8]


struct ScriptingHttpService(HttpService, Movable, Deinitable):
    """HttpService conformer scripting canned responses keyed by
    (url, method). Captures the last Authorization + Range headers so
    tests can verify the SharedKeySigningLayer injection + Range
    plumbing."""

    var _entries: Slab[_ScriptedEntry]
    var _call_count: Int
    var _last_url: String
    var _last_authorization: String
    var _last_range_header: String

    @staticmethod
    def new() -> ScriptingHttpService:
        return ScriptingHttpService(
            _entries=Slab[_ScriptedEntry](),
            _call_count=0,
            _last_url=String(""),
            _last_authorization=String(""),
            _last_range_header=String(""),
        )

    def __init__(
        out self,
        var _entries: Slab[_ScriptedEntry],
        _call_count: Int,
        var _last_url: String,
        var _last_authorization: String,
        var _last_range_header: String,
    ):
        self._entries = _entries^
        self._call_count = _call_count
        self._last_url = _last_url^
        self._last_authorization = _last_authorization^
        self._last_range_header = _last_range_header^

    def call_count(self) -> Int:
        return self._call_count

    def last_url(self) -> String:
        return self._last_url

    def last_authorization(self) -> String:
        return self._last_authorization

    def last_range_header(self) -> String:
        return self._last_range_header

    def add_head(
        mut self,
        url_str: String,
        status: Int,
        content_length: Int64,
        etag: String,
    ):
        var empty = List[UInt8]()
        self._entries.append(
            _ScriptedEntry(
                url_str=String(url_str),
                method_name=String("HEAD"),
                status=Int32(status),
                content_length=content_length,
                etag=String(etag),
                body=empty^,
            )
        )

    def add_get(
        mut self,
        url_str: String,
        status: Int,
        var body: List[UInt8],
    ):
        var cl = Int64(body.__len__())
        self._entries.append(
            _ScriptedEntry(
                url_str=String(url_str),
                method_name=String("GET"),
                status=Int32(status),
                content_length=cl,
                etag=String(""),
                body=body^,
            )
        )

    def _lookup_idx(self, url_str: String, method_name: String) -> Int:
        var n = self._entries.len()
        var i = 0
        while i < n:
            var url_match = self._entries[i].url_str == url_str
            var method_match = self._entries[i].method_name == method_name
            if url_match and method_match:
                return i
            i = i + 1
        return -1

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self._call_count = self._call_count + 1
        var method_str = String(req.method.name())
        var u_scheme = String(req.url.scheme)
        var u_host = String(req.url.host)
        var url_str = u_scheme + String("://") + u_host
        var port_val = req.url.effective_port()
        var default_port: UInt16 = UInt16(443) if req.url.is_https() else UInt16(
            80
        )
        if port_val != default_port:
            url_str = url_str + String(":") + String(Int(port_val))
        url_str = url_str + String(req.url.path)
        if req.url.query.byte_length() > 0:
            url_str = url_str + String("?") + String(req.url.query)

        self._last_url = String(url_str)
        var auth_opt = req.headers.get(String("authorization"))
        if auth_opt.__bool__():
            self._last_authorization = auth_opt.value()
        else:
            self._last_authorization = String("")
        var range_opt = req.headers.get(String("range"))
        if range_opt.__bool__():
            self._last_range_header = range_opt.value()
        else:
            self._last_range_header = String("")

        _ = req^

        var idx = self._lookup_idx(url_str, method_str)
        if idx < 0:
            raise Error(
                "HttpError[CONNECT_FAILED]: no scripted "
                + method_str + " entry for " + url_str
            )
        var status_val = self._entries[idx].status
        var cl = self._entries[idx].content_length
        var etag_str = String(self._entries[idx].etag)

        ref src_body = self._entries[idx].body
        var body_copy = List[UInt8]()
        var bi = 0
        var bn = src_body.__len__()
        while bi < bn:
            body_copy.append(src_body[bi])
            bi = bi + 1

        var resp_body = BufferedResponseBody.from_bytes(body_copy^)
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        resp.status = status_val
        resp.reason = String("Scripted")
        resp.headers = HeaderMap()
        if cl >= Int64(0):
            resp.headers.append(String("Content-Length"), String(Int(cl)))
        if etag_str.byte_length() > 0:
            resp.headers.append(String("ETag"), etag_str^)
        resp.connection_close = False
        return resp^


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _make_connector() -> ScriptedConnector:
    var stream = ScriptedStream.empty()
    return ScriptedConnector.with_stream(stream^)


def _azurite_config() -> AzureConfig:
    """Azurite runs http on 127.0.0.1:10000 with account devstoreaccount1."""
    return AzureConfig.azurite(String("devstoreaccount1"))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


# -----------------------------------------------------------------------------
# URL construction (offline)
# -----------------------------------------------------------------------------


def test_blob_url_real_azure() raises:
    """build_azure_blob_url for real Azure is virtual-hosted at
    <account>.blob.core.windows.net (account is the DNS label, NOT in
    the path)."""
    var cfg = AzureConfig.azure(String("mystoraccount"))
    var url = build_azure_blob_url(
        cfg, String("my-container"), String("a/b.parquet")
    )
    assert_equal(String(url.scheme), String("https"))
    assert_equal(String(url.host), String("mystoraccount.blob.core.windows.net"))
    assert_equal(String(url.path), String("/my-container/a/b.parquet"))


def test_blob_url_azurite_path_style() raises:
    """build_azure_blob_url for Azurite is path-style: the account is the
    FIRST path segment."""
    var cfg = _azurite_config()
    var url = build_azure_blob_url(cfg, String("c"), String("k.bin"))
    assert_equal(String(url.scheme), String("http"))
    assert_equal(String(url.host), String("127.0.0.1"))
    assert_equal(url.port, UInt16(10000))
    assert_equal(String(url.path), String("/devstoreaccount1/c/k.bin"))


def test_blob_url_percent_encodes_reserved() raises:
    """Reserved chars in a blob key are percent-encoded; `/` is preserved."""
    var cfg = AzureConfig.azure(String("acct"))
    var url = build_azure_blob_url(cfg, String("c"), String("a b/c?d"))
    assert_equal(String(url.path), String("/c/a%20b/c%3Fd"))


def test_listing_url_restype_comp() raises:
    """Azure listing requires restype=container&comp=list + marker
    pagination."""
    var cfg = AzureConfig.azure(String("acct"))
    var url = build_azure_listing_url(
        cfg, String("c"), String("data/"), String("/"), String("tok123")
    )
    assert_equal(String(url.path), String("/c"))
    var q = String(url.query)
    assert_true(q.find(String("restype=container")) >= 0)
    assert_true(q.find(String("comp=list")) >= 0)
    assert_true(q.find(String("prefix=data%2F")) >= 0)
    assert_true(q.find(String("delimiter=%2F")) >= 0)
    assert_true(q.find(String("marker=tok123")) >= 0)


# -----------------------------------------------------------------------------
# AzureStore dataplane (scripted)
# -----------------------------------------------------------------------------


def test_get_range_through_scripted_service() raises:
    """AzureStore.get_range issues a GET with a Range header and returns
    the body bytes."""
    var cfg = _azurite_config()
    var http = ScriptingHttpService.new()
    var expect_url = String(
        "http://127.0.0.1:10000/devstoreaccount1/mycontainer/obj.bin"
    )
    http.add_get(expect_url, 206, _bytes(String("HELLO-RANGE")))
    var store = AzureStore[ScriptingHttpService].new(cfg, http^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var body = store.get_range[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](
        String("mycontainer"), String("obj.bin"), Int64(0), Int64(10),
        conn, reactor,
    )
    assert_equal(body.__len__(), 11)
    assert_equal(store._http.last_range_header(), String("bytes=0-10"))
    assert_equal(store._http.last_url(), expect_url)


def test_head_through_scripted_service() raises:
    """AzureStore.head returns size + etag from response headers."""
    var cfg = _azurite_config()
    var http = ScriptingHttpService.new()
    http.add_head(
        String("http://127.0.0.1:10000/devstoreaccount1/c/k.bin"),
        200, Int64(4096), String("\"abc123\""),
    )
    var store = AzureStore[ScriptingHttpService].new(cfg, http^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var meta = store.head[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        String("c"), String("k.bin"), conn, reactor,
    )
    assert_equal(meta.size, Int64(4096))
    assert_equal(meta.etag, String("\"abc123\""))


def test_list_page_xml_parse() raises:
    """AzureStore.list_page parses a real Azure-shaped
    <EnumerationResults>."""
    var cfg = _azurite_config()
    var http = ScriptingHttpService.new()
    var xml = String(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<EnumerationResults ServiceEndpoint="http://127.0.0.1:10000/"'
        ' ContainerName="mycontainer">'
        "<Prefix>data/</Prefix>"
        "<Blobs>"
        "<Blob><Name>data/a.parquet</Name><Properties>"
        "<Content-Length>123</Content-Length><Etag>0x8DAAAA</Etag>"
        "<Last-Modified>Thu, 01 Oct 2026 12:00:12 GMT</Last-Modified>"
        "<BlobType>BlockBlob</BlobType></Properties></Blob>"
        "<Blob><Name>data/b.parquet</Name><Properties>"
        "<Content-Length>456</Content-Length><Etag>0x8DBBBB</Etag>"
        "<Last-Modified>Thu, 01 Oct 2026 12:00:13 GMT</Last-Modified>"
        "<BlobType>BlockBlob</BlobType></Properties></Blob>"
        "<BlobPrefix><Name>data/sub/</Name></BlobPrefix>"
        "</Blobs>"
        "<NextMarker>nm-7</NextMarker>"
        "</EnumerationResults>"
    )
    var list_url = String(
        "http://127.0.0.1:10000/devstoreaccount1/mycontainer"
        "?restype=container&comp=list&prefix=data%2F"
    )
    http.add_get(list_url, 200, _bytes(xml))
    var store = AzureStore[ScriptingHttpService].new(cfg, http^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var result = store.list_page[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](
        String("mycontainer"), String("data/"), String(""), String(""),
        conn, reactor,
    )
    assert_true(result.is_truncated())
    assert_equal(result.next_marker, String("nm-7"))
    assert_equal(result.blobs.__len__(), 2)
    assert_equal(result.blobs[0].name, String("data/a.parquet"))
    assert_equal(result.blobs[0].size, Int64(123))
    assert_equal(result.blobs[0].etag, String("0x8DAAAA"))
    assert_equal(result.blobs[1].name, String("data/b.parquet"))
    assert_equal(result.blobs[1].size, Int64(456))
    assert_equal(result.blob_prefixes.__len__(), 1)
    assert_equal(result.blob_prefixes[0], String("data/sub/"))


def test_list_page_no_next_marker_not_truncated() raises:
    """A self-closing/absent <NextMarker> => not truncated."""
    var cfg = _azurite_config()
    var http = ScriptingHttpService.new()
    var xml = String(
        '<EnumerationResults ContainerName="c">'
        "<Blobs><Blob><Name>only.bin</Name><Properties>"
        "<Content-Length>10</Content-Length></Properties></Blob></Blobs>"
        "<NextMarker />"
        "</EnumerationResults>"
    )
    var list_url = String(
        "http://127.0.0.1:10000/devstoreaccount1/c"
        "?restype=container&comp=list"
    )
    http.add_get(list_url, 200, _bytes(xml))
    var store = AzureStore[ScriptingHttpService].new(cfg, http^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var result = store.list_page[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](String("c"), String(""), String(""), String(""), conn, reactor)
    assert_false(result.is_truncated())
    assert_equal(result.next_marker, String(""))
    assert_equal(result.blobs.__len__(), 1)


# -----------------------------------------------------------------------------
# StoreError taxonomy
# -----------------------------------------------------------------------------


def _assert_get_error_kind(status: Int, expect_kind: UInt8) raises:
    var cfg = _azurite_config()
    var http = ScriptingHttpService.new()
    var url = String(
        "http://127.0.0.1:10000/devstoreaccount1/c/missing.bin"
    )
    var err_xml = String(
        "<?xml version=\"1.0\"?><Error><Code>BlobNotFound</Code>"
        "<Message>boom RequestId:abc</Message></Error>"
    )
    http.add_get(url, status, _bytes(err_xml))
    var store = AzureStore[ScriptingHttpService].new(cfg, http^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var raised = False
    var got_kind = UInt8(0)
    try:
        var _b = store.get_range[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector
        ](
            String("c"), String("missing.bin"), Int64(0), Int64(9),
            conn, reactor,
        )
    except e:
        raised = True
        got_kind = azure_store_error_kind_from_message(String(e))
    assert_true(raised)
    assert_equal(got_kind, expect_kind)


def test_error_404_not_found() raises:
    _assert_get_error_kind(404, AZURE_ERR_NOT_FOUND)


def test_error_403_permission_denied() raises:
    _assert_get_error_kind(403, AZURE_ERR_PERMISSION_DENIED)


def test_error_429_throttled() raises:
    _assert_get_error_kind(429, AZURE_ERR_THROTTLED)


def test_error_412_precondition() raises:
    _assert_get_error_kind(412, AZURE_ERR_PRECONDITION)


def test_error_500_transport() raises:
    _assert_get_error_kind(500, AZURE_ERR_TRANSPORT)


# -----------------------------------------------------------------------------
# SharedKeySigningLayer auth-header injection
# -----------------------------------------------------------------------------


def test_shared_key_layer_injects_authorization() raises:
    """SharedKeySigningLayer over the scripted service injects
    `Authorization: SharedKey <account>:<sig>` for a configured key."""
    var cfg = _azurite_config()
    var inner = ScriptingHttpService.new()
    var url = String("http://127.0.0.1:10000/devstoreaccount1/c/k.bin")
    inner.add_get(url, 200, _bytes(String("DATA")))
    var provider = StaticSharedKeyProvider.make(
        String("devstoreaccount1"),
        String("VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"),
    )
    var layered = SharedKeySigningLayer[
        ScriptingHttpService, StaticSharedKeyProvider
    ].wrap(inner^, provider^)
    var store = AzureStore[
        SharedKeySigningLayer[ScriptingHttpService, StaticSharedKeyProvider]
    ].new(cfg, layered^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var body = store.get_range[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](
        String("c"), String("k.bin"), Int64(0), Int64(3), conn, reactor,
    )
    assert_equal(body.__len__(), 4)
    # The inner scripted service captured the Authorization header that
    # the layer injected — must be a "SharedKey <account>:..." form.
    var captured = store._http._inner.last_authorization()
    assert_true(captured.startswith(String("SharedKey devstoreaccount1:")))


def test_shared_key_layer_skips_empty_credential() raises:
    """An empty (anonymous) credential => NO Authorization header is
    injected (public-container read)."""
    var cfg = _azurite_config()
    var inner = ScriptingHttpService.new()
    var url = String("http://127.0.0.1:10000/devstoreaccount1/pub/k.bin")
    inner.add_get(url, 200, _bytes(String("OPEN")))
    var provider = StaticSharedKeyProvider.make(String(""), String(""))
    var layered = SharedKeySigningLayer[
        ScriptingHttpService, StaticSharedKeyProvider
    ].wrap(inner^, provider^)
    var store = AzureStore[
        SharedKeySigningLayer[ScriptingHttpService, StaticSharedKeyProvider]
    ].new(cfg, layered^)
    var conn = _make_connector()
    var reactor = _make_reactor()
    var _b = store.get_range[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](
        String("pub"), String("k.bin"), Int64(0), Int64(3), conn, reactor,
    )
    assert_equal(store._http._inner.last_authorization(), String(""))


# -----------------------------------------------------------------------------
# AzureFs trait surface (mirrors test_s3_fs_adapter / test_gcs_fake_e2e)
# -----------------------------------------------------------------------------


def _make_configured_azure_client() raises -> AzureClient[ScriptedConnector]:
    return AzureClient[ScriptedConnector](
        account=String("devstoreaccount1"),
        key_b64=String(
            "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
        ),
        connector=_make_connector(),
        call_connector=_make_connector(),
        config=_azurite_config(),
    )


def _make_connector_raising() raises -> ScriptedConnector:
    return _make_connector()


def _test_credential() raises -> AzureCredential:
    return AzureCredential.shared_key(
        AzureSharedKey(
            String("devstoreaccount1"),
            String(
                "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
            ),
        )
    )


def _scripted_spec() raises -> AzureClientSpec[ScriptedConnector]:
    """The spec a clone's client is built from: the account and key of
    `_make_configured_azure_client`, over an empty scripted connection."""
    return AzureClientSpec[ScriptedConnector](
        _azurite_config(), _test_credential(), _make_connector_raising
    )


def test_azurefs_construct_and_container() raises:
    """AzureFs[C] constructs from an owned AzureClient[C]; container()
    surfaces the name."""
    var client = _make_configured_azure_client()
    var fs = AzureFs[ScriptedConnector](
        container=String("my-container"),
        client=client^,
        spec=_scripted_spec(),
        )
    assert_equal(fs.container(), String("my-container"))


def test_azurefs_open_returns_handle() raises:
    """AzureFs.open(key) returns an AzureFileHandle whose .key() matches."""
    var client = _make_configured_azure_client()
    var fs = AzureFs[ScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_scripted_spec(),
        )
    var h = fs.open(String("path/to/obj.parquet"))
    assert_equal(h.key(), String("path/to/obj.parquet"))


def test_azurefs_read_at_on_sentinel_raises() raises:
    """AzureFs.read_at against an OWNED SENTINEL AzureClient raises a clear
    error (the FS owns the client; the read-path lazy-build helper's
    is_configured() guard surfaces the sentinel)."""
    var sentinel = AzureClient[ScriptedConnector]()
    var fs = AzureFs[ScriptedConnector](
        container=String("c"),
        client=sentinel^,
        spec=_scripted_spec(),
    )
    var h = fs.open(String("k.bin"))
    with assert_raises(contains="sentinel"):
        var _buf = fs.read_at(h, Int64(0), Int64(16))


def test_azurefs_capability_queries() raises:
    var client = _make_configured_azure_client()
    var fs = AzureFs[ScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_scripted_spec(),
        )
    assert_equal(fs.prefetch_depth(), 64)
    assert_true(fs.supports_random_read())
    # list + list_dir_shallow work, so a lazy Hive discovery may prune
    # partitions over AzureFs; block-blob writes are never parallel.
    assert_true(AzureFs[ScriptedConnector].SUPPORTS_LAZY_HIVE)
    assert_false(AzureFs[ScriptedConnector].SUPPORTS_PARALLEL_WRITES)


def _http_200_xml(xml: String) -> List[UInt8]:
    """A raw HTTP/1.1 200 response carrying `xml`, for ScriptedStream."""
    var body = xml
    var head = String("HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\n")
    head += String("Content-Length: ") + String(body.byte_length()) + String("\r\n\r\n")
    return _bytes(head + body)


def _list_blobs_xml(var blobs: String, var prefixes: String) -> String:
    """An Azure <EnumerationResults> page with the given <Blob>/<BlobPrefix>
    fragments (either may be empty — that is the "prefix names nothing" case
    `is_dir` must report False for)."""
    return String(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<EnumerationResults ServiceEndpoint="http://127.0.0.1:10000/"'
        ' ContainerName="c">'
        "<Prefix>data/</Prefix><Delimiter>/</Delimiter><Blobs>"
    ) + blobs + prefixes + String("</Blobs><NextMarker /></EnumerationResults>")


def _azure_fs_serving(var response: List[UInt8]) raises -> AzureFs[
    ScriptedConnector
]:
    """An AzureFs whose client's connector replays ONE canned HTTP
    response — so the listing verbs run their REAL request/parse path
    hermetically (no socket, no emulator)."""
    var stream = ScriptedStream.from_read_script(response.copy())
    var call_stream = ScriptedStream.from_read_script(response^)
    var client = AzureClient[ScriptedConnector](
        account=String("devstoreaccount1"),
        key_b64=String(
            "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
        ),
        connector=ScriptedConnector.with_stream(stream^),
        call_connector=ScriptedConnector.with_stream(call_stream^),
        config=_azurite_config(),
    )
    return AzureFs[ScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_scripted_spec(),
    )


def test_azurefs_is_dir_convention() raises:
    """`is_dir` is a REAL shallow-listing probe, not a string convention.

    A string convention (`path.endswith("/")`) is wrong: a real Azure prefix
    like `events` with no trailing slash names a directory when blobs exist
    under `events/`. `is_dir` is a one-page `delimiter="/"` `list_page`
    probe; canned listing responses exercise the real probe path (URL build
    -> request -> <EnumerationResults> parse -> verdict) in both directions."""
    # A prefix under which a blob exists => a directory-like subtree.
    var fs_hit = _azure_fs_serving(
        _http_200_xml(
            _list_blobs_xml(
                String("<Blob><Name>data/part-0.parquet</Name></Blob>"),
                String(""),
            )
        )
    )
    assert_true(
        fs_hit.is_dir(String("data/")),
        "a prefix with a blob under it IS a directory",
    )

    # An UNSLASHED prefix is normalized to `data/`,
    # so a directory is found without the caller writing the trailing slash.
    var fs_unslashed = _azure_fs_serving(
        _http_200_xml(
            _list_blobs_xml(
                String(""),
                String("<BlobPrefix><Name>data/x/</Name></BlobPrefix>"),
            )
        )
    )
    assert_true(
        fs_unslashed.is_dir(String("data")),
        "an UNSLASHED prefix is normalized to 'data/' (an endswith('/')"
        " convention gets it wrong)",
    )

    # An empty page => the prefix names no subtree.
    var fs_miss = _azure_fs_serving(
        _http_200_xml(_list_blobs_xml(String(""), String("")))
    )
    assert_false(
        fs_miss.is_dir(String("data/file.parquet")),
        "a prefix with nothing under it is NOT a directory",
    )


# -----------------------------------------------------------------------------
# `<NextMarker>` pagination — the SEMANTIC coverage for AzureFs.list /
# list_dir_shallow
# -----------------------------------------------------------------------------
#
# `test_azurefs_stubs_raise` below can only assert that `list` raises SOMETHING
# offline. That is an
# is-it-wired proof, NOT a behavioural one — it would stay green if the
# pagination loop stopped after page 1, or re-issued page 1's URL forever.
#
# `ScriptedConnector` cannot express a multi-page listing: it arms ONE stream
# and `HttpClient.call` (the path `AzureStore.list_page` takes) FRESH-DIALS per
# request, so the second page's `connect()` raises "no stream armed". The
# fixture below is the missing seam — a Connector that hands out ONE scripted
# stream PER REQUEST, in order, from a pre-scripted page list, and mirrors
# every outbound byte into a SHARED capture so the test can assert the
# follow-up request actually carried `&marker=<NextMarker>`.
#
# Running off the END of the page list is a LOUD raise, not a silent EOF —
# that is what makes "a single-page listing does not loop" assertable.


struct PagedScriptedConnector(Connector, Movable, Deinitable):
    """A `ScriptedConnector` whose `connect()` serves a QUEUE of canned
    responses — one fresh `ScriptedStream` per dial, in order.

    Models a server that answers N successive requests with N different
    responses, which is exactly the shape a `<NextMarker>` pagination loop
    needs and `ScriptedConnector` (single armed stream) cannot express.
    Still hermetic: no socket, no emulator, no Azurite.

    All streams share ONE write-capture `ArcPointer`, so the concatenated
    outbound request bytes survive each stream's drop inside `HttpClient.call`
    and the test can assert what was actually sent (the marker propagation).
    """

    comptime Stream = ScriptedStream

    var _pages: List[List[UInt8]]
    var _next: Int
    var _capture: ArcPointer[List[UInt8]]

    def __init__(
        out self,
        var pages: List[List[UInt8]],
        capture: ArcPointer[List[UInt8]],
    ):
        self._pages = pages^
        self._next = 0
        self._capture = capture

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> ScriptedStream:
        """Hand out the next scripted response as a fresh stream. Dialing
        MORE times than there are scripted pages RAISES — an over-listing
        (a loop that ignores an exhausted `<NextMarker>`) fails loudly here
        instead of degrading into an empty-script EOF."""
        _ = reactor
        _ = ip_be
        _ = port
        if self._next >= len(self._pages):
            raise Error(
                String(
                    "PagedScriptedConnector: request #"
                )
                + String(self._next + 1)
                + String(" but only ")
                + String(len(self._pages))
                + String(
                    " page(s) scripted — the listing issued a request past"
                    " its LAST page (pagination did not terminate)"
                )
            )
        var stream = ScriptedStream.from_read_script_with_capture(
            self._pages[self._next].copy(), self._capture
        )
        self._next = self._next + 1
        return stream^

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        """`Connector.set_dial_host` — inert on this scripted double: it never
        handshakes, so it has no SNI to present. Present so the double still
        conforms to `Connector`."""
        _ = host^


def _paged_connector_no_pages() raises -> PagedScriptedConnector:
    """The connector factory of the paged fixtures' spec. NOT exercised by
    these tests — the fixture SEEDS slot 0 with a configured client and
    `AzureFs._build_client_if_absent` only builds when the slot is empty. It
    arms ZERO pages deliberately: if a future refactor ever did route through
    it, the first request would raise the loud "0 page(s) scripted" error
    rather than silently replaying another test's script."""
    return PagedScriptedConnector(
        List[List[UInt8]](), ArcPointer[List[UInt8]](List[UInt8]())
    )


def _paged_spec_no_pages() raises -> AzureClientSpec[PagedScriptedConnector]:
    return AzureClientSpec[PagedScriptedConnector](
        _azurite_config(), _test_credential(), _paged_connector_no_pages
    )


def _azure_fs_paged(
    var pages: List[List[UInt8]], capture: ArcPointer[List[UInt8]]
) raises -> AzureFs[PagedScriptedConnector]:
    """An AzureFs whose per-call connector (`AzureClient._inner_connector`,
    the one `list_page` dispatches on) replays `pages` one per request."""
    var client = AzureClient[PagedScriptedConnector](
        account=String("devstoreaccount1"),
        key_b64=String(
            "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
        ),
        # The HttpClient-embedded connector is unused on the `call` path
        # (`AzureStore.list_page` threads the per-call connector); arm it
        # empty so a mis-route surfaces rather than silently working.
        connector=PagedScriptedConnector(List[List[UInt8]](), capture),
        call_connector=PagedScriptedConnector(pages^, capture),
        config=_azurite_config(),
    )
    return AzureFs[PagedScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_paged_spec_no_pages(),
    )


def _page_xml(
    prefix: String,
    delimiter: String,
    var entries: String,
    next_marker: String,
) -> String:
    """One `<EnumerationResults>` page. An EMPTY `next_marker` emits Azure's
    self-closing `<NextMarker />` — the "this is the last page" form that
    `AzureListBlobsResult.is_truncated()` reads as False."""
    var marker_el = String("<NextMarker />")
    if next_marker.byte_length() > 0:
        marker_el = (
            String("<NextMarker>") + next_marker + String("</NextMarker>")
        )
    return (
        String(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<EnumerationResults ServiceEndpoint="http://127.0.0.1:10000/"'
            ' ContainerName="c">'
        )
        + String("<Prefix>")
        + prefix
        + String("</Prefix><Delimiter>")
        + delimiter
        + String("</Delimiter><Blobs>")
        + entries
        + String("</Blobs>")
        + marker_el
        + String("</EnumerationResults>")
    )


def _blob_el(name: String) -> String:
    return String("<Blob><Name>") + name + String("</Name></Blob>")


def _blob_prefix_el(name: String) -> String:
    return (
        String("<BlobPrefix><Name>") + name + String("</Name></BlobPrefix>")
    )


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    """The concatenated outbound request bytes across every page request."""
    var out = String()
    var i = 0
    while i < capture[].__len__():
        out = out + chr(Int(capture[][i]))
        i = i + 1
    return out^


def _count_occurrences(hay: String, needle: String) -> Int:
    """Non-overlapping occurrence count (String has `in`/`find` but no
    count; the request-count assertions need an exact number)."""
    var h = hay.as_bytes()
    var nd = needle.as_bytes()
    var n = len(h)
    var m = len(nd)
    if m == 0 or m > n:
        return 0
    var found = 0
    var i = 0
    while i + m <= n:
        var j = 0
        while j < m and h[i + j] == nd[j]:
            j = j + 1
        if j == m:
            found = found + 1
            i = i + m
        else:
            i = i + 1
    return found


def test_azurefs_list_walks_nextmarker_and_unions_pages() raises:
    """`AzureFs.list` FOLLOWS `<NextMarker>` and returns the UNION of every
    page, in arrival order.

    This is the behavioural contract of the pagination loop
    that `test_azurefs_stubs_raise` cannot state: that
    test only proves `list` is wired to a transport. Three distinct claims
    here, each independently falsifiable by breaking the loop:

      1. TWO requests are issued for a two-page listing (drop the
         `is_truncated()` follow-up -> 1 request, and the page-2 keys are
         missing from the result).
      2. The SECOND request carries `&marker=PAGETWOMARKER` — the marker the
         FIRST page's `<NextMarker>` returned (re-issue the same URL without
         threading the marker -> `marker=` count is 0).
      3. The result is the ordered UNION a..d, NOT just page 1 (a..b) and NOT
         just the last page (c..d, the "overwrite instead of append" bug).

    Also pinned: `list` is RECURSIVE, so its URL carries NO `&delimiter=`
    (a folded listing would silently hide nested keys from discovery)."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var pages = List[List[UInt8]]()
    pages.append(
        _http_200_xml(
            _page_xml(
                String("data/"),
                String(""),
                _blob_el(String("data/a.parquet"))
                + _blob_el(String("data/b.parquet")),
                String("PAGETWOMARKER"),
            )
        )
    )
    pages.append(
        _http_200_xml(
            _page_xml(
                String("data/"),
                String(""),
                _blob_el(String("data/nested/c.parquet"))
                + _blob_el(String("data/d.parquet")),
                String(""),
            )
        )
    )
    var fs = _azure_fs_paged(pages^, capture)

    var keys = fs.list(String("data/"))

    # (3) the ordered UNION of both pages — bare keys, `open`-round-trippable.
    assert_equal(len(keys), 4, "list must return BOTH pages' blobs")
    assert_equal(keys[0], String("data/a.parquet"))
    assert_equal(keys[1], String("data/b.parquet"))
    assert_equal(keys[2], String("data/nested/c.parquet"))
    assert_equal(keys[3], String("data/d.parquet"))

    var wire = _wire(capture)
    # (1) exactly TWO List Blobs requests went out — no more, no fewer.
    assert_equal(
        _count_occurrences(wire, String("comp=list")),
        2,
        String("expected exactly 2 List Blobs requests; wire=") + wire,
    )
    # (2) page 2's request carried the marker page 1 handed back — exactly
    # once (page 1's request must NOT carry a marker).
    assert_equal(
        _count_occurrences(wire, String("marker=PAGETWOMARKER")),
        1,
        String("page 2 must be fetched with &marker=<NextMarker>; wire=")
        + wire,
    )
    assert_equal(
        _count_occurrences(wire, String("marker=")),
        1,
        String("only the SECOND request may carry a marker; wire=") + wire,
    )
    # `list` is recursive: no delimiter, so nested keys are not folded away.
    assert_equal(
        _count_occurrences(wire, String("delimiter=")),
        0,
        String("AzureFs.list must be a RECURSIVE (undelimited) list; wire=")
        + wire,
    )


def test_azurefs_list_single_page_does_not_loop() raises:
    """A listing whose FIRST page has no `<NextMarker>` issues exactly ONE
    request and stops.

    The fixture arms exactly ONE page, so a loop that re-issued the request
    (the `is_truncated()`-inverted bug, or the "truncated but empty marker"
    non-conforming-proxy spin the impl guards against)
    raises "only 1 page(s) scripted" here — the termination claim is a hard
    failure, not a hang."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var pages = List[List[UInt8]]()
    pages.append(
        _http_200_xml(
            _page_xml(
                String("solo/"),
                String(""),
                _blob_el(String("solo/only.parquet")),
                String(""),
            )
        )
    )
    var fs = _azure_fs_paged(pages^, capture)

    var keys = fs.list(String("solo/"))
    assert_equal(len(keys), 1)
    assert_equal(keys[0], String("solo/only.parquet"))
    assert_equal(
        _count_occurrences(_wire(capture), String("comp=list")),
        1,
        "a non-truncated first page must issue exactly ONE request",
    )


def test_azurefs_list_dir_shallow_walks_nextmarker_across_pages() raises:
    """`AzureFs.list_dir_shallow` paginates the SAME way, and folds
    `<BlobPrefix>` -> dir / `<Blob>` -> file across page boundaries.

    Claims, each falsifiable by breaking the loop:
      1. Two requests; the second carries `&marker=SHALLOWPAGE2`.
      2. The URL carries `delimiter=%2F` (the FOLDED one-level view) and the
         prefix is NORMALIZED from `events` to `events/` (percent-encoded
         `events%2F`) — the load-bearing over-match fix.
      3. Entries are the ordered union across pages, dirs-then-files WITHIN
         each page, as BARE final components (`dt=2026-10-01`, not the full
         key).
      4. The zero-byte directory-placeholder blob (`events/`, echoed back by
         a delimiter listing) is SKIPPED, not surfaced as a child."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var pages = List[List[UInt8]]()
    pages.append(
        _http_200_xml(
            _page_xml(
                String("events/"),
                String("/"),
                _blob_prefix_el(String("events/dt=2026-10-01/"))
                # The directory placeholder itself — must be skipped.
                + _blob_el(String("events/"))
                + _blob_el(String("events/_SUCCESS")),
                String("SHALLOWPAGE2"),
            )
        )
    )
    pages.append(
        _http_200_xml(
            _page_xml(
                String("events/"),
                String("/"),
                _blob_prefix_el(String("events/dt=2026-10-02/"))
                + _blob_el(String("events/README.md")),
                String(""),
            )
        )
    )
    var fs = _azure_fs_paged(pages^, capture)

    # Deliberately UNSLASHED: exercises the prefix normalization too.
    var entries = fs.list_dir_shallow(String("events"))

    assert_equal(
        len(entries), 4, "both pages' children, placeholder blob excluded"
    )
    assert_equal(entries[0].name, String("dt=2026-10-01"))
    assert_true(entries[0].is_dir, "a <BlobPrefix> fold is a DIRECTORY")
    assert_equal(entries[1].name, String("_SUCCESS"))
    assert_false(entries[1].is_dir, "a <Blob> is a FILE")
    assert_equal(entries[2].name, String("dt=2026-10-02"))
    assert_true(entries[2].is_dir)
    assert_equal(entries[3].name, String("README.md"))
    assert_false(entries[3].is_dir)

    var wire = _wire(capture)
    assert_equal(
        _count_occurrences(wire, String("comp=list")),
        2,
        String("expected exactly 2 shallow-list requests; wire=") + wire,
    )
    assert_equal(
        _count_occurrences(wire, String("marker=SHALLOWPAGE2")),
        1,
        String("page 2 must be fetched with &marker=<NextMarker>; wire=")
        + wire,
    )
    # Both requests fold at one level and probe the NORMALIZED prefix.
    assert_equal(
        _count_occurrences(wire, String("delimiter=%2F")),
        2,
        String("shallow listing must send delimiter=/ on EVERY page; wire=")
        + wire,
    )
    assert_equal(
        _count_occurrences(wire, String("prefix=events%2F")),
        2,
        String(
            "an unslashed prefix must be normalized to 'events/' (the"
            " over-match fix); wire="
        )
        + wire,
    )


def _transport_error_of_read_verb(which: Int) raises -> String:
    """The error a read verb raises against a configured client whose
    scripted connection answers nothing (0 list, 1 read_footer, 2
    file_size), or "" if it did not raise."""
    var client = _make_configured_azure_client()
    var fs = AzureFs[ScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_scripted_spec(),
    )
    try:
        if which == 0:
            var _l = fs.list(String("prefix/"))
        elif which == 1:
            var _f = fs.read_footer(
                String("k.parquet"), FOOTER_SPECULATIVE_WINDOW
            )
        else:
            var _s = fs.file_size(String("k.parquet"))
    except e:
        return String(e)
    return String("")


def test_azurefs_read_verbs_reach_the_transport() raises:
    """The read verbs are wired: with nothing scripted on the connection
    each one raises the HTTP client's own transport error (it reached the
    wire), never the read-only refusal. Their success paths are pinned by
    the `list` / `list_dir_shallow` / footer rows above."""
    for which in range(3):
        var msg = _transport_error_of_read_verb(which)
        assert_true(
            msg.find(String("HttpError[")) >= 0,
            String("read verb ") + String(which)
            + String(" must raise the transport's error; got: ") + msg,
        )
        assert_false(msg.find(String("read-only")) >= 0, msg)


def test_azurefs_write_verbs_refused_read_only() raises:
    """AzureFs has no write path: open_write, write_at and close_write each
    refuse naming the read-only file system, and pwrite_at names the
    missing parallel-write support."""
    var client = _make_configured_azure_client()
    var fs = AzureFs[ScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_scripted_spec(),
    )
    with assert_raises(contains="AzureFs.open_write: AzureFs is read-only"):
        var _w = fs.open_write(String("w/obj"), WriteMode.create_truncate())
    var data = List[UInt8]()
    data.append(UInt8(1))
    var wf = AzureWriteFile(_path=String("w/obj"))
    with assert_raises(contains="AzureFs.write_at: AzureFs is read-only"):
        _ = fs.write_at(wf, Span(data))
    with assert_raises(contains="SUPPORTS_PARALLEL_WRITES"):
        _ = fs.pwrite_at(wf, Int64(0), Span(data))
    with assert_raises(contains="AzureFs.close_write: AzureFs is read-only"):
        fs.close_write(wf^)


def test_azurefs_delete_is_the_trait_default() raises:
    """AzureFs does not implement delete: it inherits komira_fs's raising
    default. A delete override must replace this row with its own."""
    var client = _make_configured_azure_client()
    var fs = AzureFs[ScriptedConnector](
        container=String("c"),
        client=client^,
        spec=_scripted_spec(),
    )
    with assert_raises(contains="FileSystem.delete: unimplemented"):
        fs.delete(String("k.parquet"))


# -----------------------------------------------------------------------------
# A <NextMarker> that never ends hits the page cap.
# -----------------------------------------------------------------------------


struct LoopingListConnector(Connector, Movable, Deinitable):
    """A Connector whose every dial answers one List Blobs page that is
    empty and carries the SAME non-empty `<NextMarker>`, so a pagination
    loop with no cap never ends. With `end_at > 0`, request `end_at` gets
    the last-page form (`<NextMarker />`) instead.

    Every dial is counted in a shared `ArcPointer[Int]`, so the test can
    state how many requests went out. A dial past AZURE_LIST_MAX_PAGES
    raises its own error, so a missing cap fails the test (with this
    message, not the page-cap one) instead of hanging it."""

    comptime Stream = ScriptedStream

    var _calls: ArcPointer[Int]
    var _end_at: Int
    var _delimiter: String

    def __init__(
        out self, calls: ArcPointer[Int], end_at: Int, delimiter: String
    ):
        self._calls = calls
        self._end_at = end_at
        self._delimiter = delimiter

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> ScriptedStream:
        _ = reactor
        _ = ip_be
        _ = port
        self._calls[] = self._calls[] + 1
        if self._calls[] > AZURE_LIST_MAX_PAGES:
            raise Error(
                "LoopingListConnector: List Blobs request past the page cap"
            )
        var marker = String("SAMEMARKER")
        if self._end_at > 0 and self._calls[] == self._end_at:
            marker = String("")
        return ScriptedStream.from_read_script(
            _http_200_xml(
                _page_xml(String("data/"), self._delimiter, String(""), marker)
            )
        )

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^


def _looping_connector_unused() raises -> LoopingListConnector:
    """The connector factory of the looping fixture's spec; never called
    (slot 0 is seeded). Its connector answers nothing usable: `end_at` 1
    ends at once."""
    return LoopingListConnector(ArcPointer[Int](0), 1, String(""))


def _looping_spec_unused() raises -> AzureClientSpec[LoopingListConnector]:
    return AzureClientSpec[LoopingListConnector](
        _azurite_config(), _test_credential(), _looping_connector_unused
    )


def _azure_fs_looping(
    calls: ArcPointer[Int], end_at: Int, delimiter: String
) raises -> AzureFs[LoopingListConnector]:
    """An AzureFs whose per-call connector (the one `list_page` dials) is a
    LoopingListConnector counting into `calls`."""
    var client = AzureClient[LoopingListConnector](
        account=String("devstoreaccount1"),
        key_b64=String(
            "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
        ),
        connector=LoopingListConnector(
            ArcPointer[Int](0), end_at, delimiter
        ),
        call_connector=LoopingListConnector(calls, end_at, delimiter),
        config=_azurite_config(),
    )
    return AzureFs[LoopingListConnector](
        container=String("c"),
        client=client^,
        spec=_looping_spec_unused(),
    )


def _assert_azure_page_cap_error(msg: String, verb: String) raises:
    assert_true(
        msg.find(String("AzureFs.") + verb + String(": page cap exceeded"))
        >= 0,
        String("want the AzureFs.") + verb + String(" page-cap error, got: ")
        + msg,
    )


def test_azurefs_list_page_cap_refuses_a_looping_marker() raises:
    """`list` raises a clear error once it has drained AZURE_LIST_MAX_PAGES
    pages of a `<NextMarker>` that never ends, after exactly that many
    requests (the connector's own guard proves none went past the cap). A
    listing that ends on exactly the last allowed page succeeds."""
    var calls = ArcPointer[Int](0)
    var fs = _azure_fs_looping(calls, 0, String(""))
    var raised = False
    try:
        _ = fs.list(String("data/"))
    except e:
        raised = True
        _assert_azure_page_cap_error(String(e), String("list"))
    assert_true(raised, "a NextMarker that never ends must hit the page cap")
    assert_equal(calls[], AZURE_LIST_MAX_PAGES)

    var at_cap_calls = ArcPointer[Int](0)
    var at_cap = _azure_fs_looping(
        at_cap_calls, AZURE_LIST_MAX_PAGES, String("")
    )
    assert_equal(len(at_cap.list(String("data/"))), 0)
    assert_equal(at_cap_calls[], AZURE_LIST_MAX_PAGES)


def test_azurefs_list_dir_shallow_page_cap_refuses_a_looping_marker() raises:
    """`list_dir_shallow` holds the same cap, counted the same way."""
    var calls = ArcPointer[Int](0)
    var fs = _azure_fs_looping(calls, 0, String("/"))
    var raised = False
    try:
        _ = fs.list_dir_shallow(String("data"))
    except e:
        raised = True
        _assert_azure_page_cap_error(String(e), String("list_dir_shallow"))
    assert_true(raised, "a NextMarker that never ends must hit the page cap")
    assert_equal(calls[], AZURE_LIST_MAX_PAGES)

    var at_cap_calls = ArcPointer[Int](0)
    var at_cap = _azure_fs_looping(
        at_cap_calls, AZURE_LIST_MAX_PAGES, String("/")
    )
    assert_equal(len(at_cap.list_dir_shallow(String("data"))), 0)
    assert_equal(at_cap_calls[], AZURE_LIST_MAX_PAGES)


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


def main() raises:
    test_blob_url_real_azure()
    test_blob_url_azurite_path_style()
    test_blob_url_percent_encodes_reserved()
    test_listing_url_restype_comp()
    test_get_range_through_scripted_service()
    test_head_through_scripted_service()
    test_list_page_xml_parse()
    test_list_page_no_next_marker_not_truncated()
    test_error_404_not_found()
    test_error_403_permission_denied()
    test_error_429_throttled()
    test_error_412_precondition()
    test_error_500_transport()
    test_shared_key_layer_injects_authorization()
    test_shared_key_layer_skips_empty_credential()
    test_azurefs_construct_and_container()
    test_azurefs_open_returns_handle()
    test_azurefs_read_at_on_sentinel_raises()
    test_azurefs_capability_queries()
    test_azurefs_is_dir_convention()
    test_azurefs_list_walks_nextmarker_and_unions_pages()
    test_azurefs_list_single_page_does_not_loop()
    test_azurefs_list_dir_shallow_walks_nextmarker_across_pages()
    test_azurefs_list_page_cap_refuses_a_looping_marker()
    test_azurefs_list_dir_shallow_page_cap_refuses_a_looping_marker()
    test_azurefs_read_verbs_reach_the_transport()
    test_azurefs_write_verbs_refused_read_only()
    test_azurefs_delete_is_the_trait_default()
    print("OK")
