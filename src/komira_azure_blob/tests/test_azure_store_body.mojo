# AzureStore reading response bodies as UTF-8, over an HttpService that
# answers every request with one status and one body: no socket, no emulator.
#
# The Azure SDKs strip a leading UTF-8 byte order mark (EF BB BF) from every
# XML response before they parse it (azure-sdk-for-go
# sdk/azcore/runtime/response.go, removeBOM; azure-sdk-for-rust
# sdk/core/src/xml.rs, slice_bom), because the service sends one. komira_xml
# steps over a BOM at the start of its input (XML 1.0 §4.3.3), so the store
# hands it the body's bytes unchanged.
#
# Rows:
#   * a List Blobs 200 that starts with a BOM and an XML declaration parses:
#     ContainerName, the blob and the empty NextMarker;
#   * a blob name of two-byte UTF-8 sequences reads as its code points;
#   * a 404 error body that starts with a BOM keeps the service's code and
#     message in the StoreError;
#   * a List Blobs 200 whose body is not UTF-8 is refused with the store's
#     message;
#   * a 404 whose body is not UTF-8 keeps the status taxonomy and carries no
#     azure_code.
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_blob.azure import AzureConfig, AzureStore
from komira_azure_blob.azure_xml import AzureListBlobsResult
from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime ACCOUNT = "devstoreaccount1"


struct CannedService(HttpService, Movable, Deinitable):
    """Answers every request with `status` and `body`."""

    var status: Int
    var body: List[UInt8]

    def __init__(out self, status: Int, var body: List[UInt8]):
        self.status = status
        self.body = body^

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        _ = req^
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(self.body.copy())
        )
        resp.status = Int32(self.status)
        resp.reason = String("Canned")
        resp.headers = HeaderMap()
        resp.headers.append(String("Content-Length"), String(len(self.body)))
        resp.connection_close = False
        return resp^


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _with_bom(s: String) -> List[UInt8]:
    var out: List[UInt8] = [0xEF, 0xBB, 0xBF]
    out.extend(Span(s.as_bytes()))
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _store(status: Int, var body: List[UInt8]) -> AzureStore[CannedService]:
    return AzureStore[CannedService].new(
        AzureConfig.azurite(String(ACCOUNT)), CannedService(status, body^)
    )


def _list(status: Int, var body: List[UInt8]) raises -> AzureListBlobsResult:
    var store = _store(status, body^)
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    return store.list_page[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        String("c"), String(""), String(""), String(""), conn, reactor
    )


def _get_error(status: Int, var body: List[UInt8]) raises -> String:
    var store = _store(status, body^)
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    try:
        _ = store.get[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
            String("c"), String("k.bin"), conn, reactor
        )
    except e:
        return String(e)
    raise Error("expected a refusal")


def test_list_body_with_a_byte_order_mark_parses() raises:
    var r = _list(
        200,
        _with_bom(
            String(
                '<?xml version="1.0" encoding="utf-8"?>'
                '<EnumerationResults ServiceEndpoint="http://127.0.0.1:10000/devstoreaccount1"'
                ' ContainerName="c"><Blobs><Blob><Name>a.bin</Name><Properties>'
                "<Content-Length>3</Content-Length></Properties></Blob></Blobs>"
                "<NextMarker /></EnumerationResults>"
            )
        ),
    )
    assert_equal(r.container, String("c"))
    assert_equal(len(r.blobs), 1)
    assert_equal(r.blobs[0].name, String("a.bin"))
    assert_equal(r.blobs[0].size, Int64(3))
    assert_equal(r.next_marker, String(""))


def test_list_blob_name_reads_as_utf8() raises:
    # U+00E9 is C3 A9 in UTF-8; U+00FC is C3 BC.
    var body = _bytes(String('<EnumerationResults ContainerName="c"><Blobs><Blob><Name>caf'))
    body.extend([UInt8(0xC3), UInt8(0xA9), UInt8(0x2F), UInt8(0xC3), UInt8(0xBC)])
    body.extend(Span(String("</Name></Blob></Blobs><NextMarker /></EnumerationResults>").as_bytes()))
    var r = _list(200, body^)
    assert_equal(len(r.blobs), 1)
    var want: List[UInt8] = [0x63, 0x61, 0x66, 0xC3, 0xA9, 0x2F, 0xC3, 0xBC]
    var got = _bytes(r.blobs[0].name)
    assert_equal(len(got), len(want), r.blobs[0].name)
    for i in range(len(want)):
        assert_equal(got[i], want[i], r.blobs[0].name)


def test_error_body_with_a_byte_order_mark_keeps_the_code() raises:
    var msg = _get_error(
        404,
        _with_bom(
            String(
                '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code>'
                "<Message>gone</Message></Error>"
            )
        ),
    )
    assert_equal(
        msg,
        String(
            "StoreError[NOT_FOUND] GET az://c/k.bin status=404"
            " azure_code=BlobNotFound azure_message=gone"
        ),
    )


def test_list_body_not_utf8_is_refused() raises:
    var body = _bytes(String('<EnumerationResults ContainerName="c"><Blobs><Blob><Name>'))
    body.append(UInt8(0xFF))
    body.extend(Span(String("</Name></Blob></Blobs></EnumerationResults>").as_bytes()))
    try:
        _ = _list(200, body^)
    except e:
        assert_equal(String(e), String("azure store: response body is not UTF-8"))
        return
    raise Error("expected a refusal")


def test_error_body_not_utf8_keeps_the_status() raises:
    var body = _bytes(String("<Error><Code>X"))
    body.append(UInt8(0xFF))
    body.extend(Span(String("</Code></Error>").as_bytes()))
    var msg = _get_error(404, body^)
    assert_equal(msg, String("StoreError[NOT_FOUND] GET az://c/k.bin status=404"))


def main() raises:
    var failures = List[String]()
    try:
        test_list_body_with_a_byte_order_mark_parses()
    except e:
        failures.append("test_list_body_with_a_byte_order_mark_parses: " + String(e))
    try:
        test_list_blob_name_reads_as_utf8()
    except e:
        failures.append("test_list_blob_name_reads_as_utf8: " + String(e))
    try:
        test_error_body_with_a_byte_order_mark_keeps_the_code()
    except e:
        failures.append("test_error_body_with_a_byte_order_mark_keeps_the_code: " + String(e))
    try:
        test_list_body_not_utf8_is_refused()
    except e:
        failures.append("test_list_body_not_utf8_is_refused: " + String(e))
    try:
        test_error_body_not_utf8_keeps_the_status()
    except e:
        failures.append("test_error_body_not_utf8_keeps_the_status: " + String(e))
    if len(failures) > 0:
        var all = String("FAILED ") + String(len(failures)) + ":"
        for f in failures:
            all += "\n  " + f
        raise Error(all)
    print("OK")
