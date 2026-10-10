# AzureStore.put_blob (Put Blob, a block blob in one request) through
# SharedKeySigningLayer over a capturing HttpService: no socket, no emulator.
#
# Put Blob (https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob)
# is `PUT /<container>/<blob>` with the blob in the body, `x-ms-blob-type:
# BlockBlob` (required) and Content-Length; the service answers 201 Created
# with the blob's ETag. Shared Key signs the length, the Content-Type and the
# x-ms-* headers ("Authorize with Shared Key").
#
# Rows:
#   * an 11-byte blob with a Content-Type: the request line, the required
#     x-ms-blob-type, x-ms-version, Content-Type and Content-Length on the
#     wire, the body after the head, an Authorization equal to the golden, and
#     the ETag and size returned;
#   * a zero-byte blob: `Content-Length: 0` on the wire, an empty
#     Content-Length slot in the string-to-sign (version 2021-08-06), no
#     Content-Type header when none is given;
#   * a 403 reads as PERMISSION_DENIED, with the method, the blob and the
#     service's code in the message;
#   * an empty blob name is refused before any request (it would address the
#     container).
#
# Goldens, by Python (hmac, base64), key = base64.b64decode(FAKE_KEY):
#   "PUT\n\n\n11\n\ntext/plain; charset=UTF-8\n\n\n\n\n\n\nx-ms-blob-type:BlockBlob\n"
#   "x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\nx-ms-version:2021-08-06\n"
#   "/devstoreaccount1/devstoreaccount1/c/hello.txt"
#     -> txwRFA4DeStSk3jWo8oEwkb2GN5HIVJZlPT6g0qAqSw=
#   "PUT" + "\n"*12 + "x-ms-blob-type:BlockBlob\nx-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n"
#   "x-ms-version:2021-08-06\n/devstoreaccount1/devstoreaccount1/c/empty.bin"
#     -> FKgqj/cYd7gnJumNph3tzfBIr0/mo+aK7Lq3G1SF2AU=
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_blob import (
    AZURE_ERR_PERMISSION_DENIED,
    azure_store_error_kind_from_message,
)
from komira_azure_blob.azure import AzureConfig, AzureStore
from komira_azure_blob.azure_signing import (
    SharedKeySigningLayer,
    StaticSharedKeyProvider,
)
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
comptime HELLO_GOLDEN = "SharedKey devstoreaccount1:txwRFA4DeStSk3jWo8oEwkb2GN5HIVJZlPT6g0qAqSw="
comptime EMPTY_GOLDEN = "SharedKey devstoreaccount1:FKgqj/cYd7gnJumNph3tzfBIr0/mo+aK7Lq3G1SF2AU="


struct CapturingService(HttpService, Movable, Deinitable):
    """Answers with `status`, an ETag and `body`; keeps the last request's
    Authorization and serialized bytes."""

    var status: Int
    var body: String
    var authorization: String
    var wire: List[UInt8]
    var calls: Int

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^
        self.authorization = String("")
        self.wire = List[UInt8]()
        self.calls = 0

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self.calls += 1
        var a = req.headers.get(String("authorization"))
        self.authorization = a.value() if a else String("")
        self.wire = req.request_bytes.copy()
        _ = req^
        var bytes = List[UInt8]()
        bytes.extend(Span(self.body.as_bytes()))
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(bytes^)
        )
        resp.status = Int32(self.status)
        resp.reason = String("Created")
        resp.headers = HeaderMap()
        resp.headers.append(String("ETag"), String('"0x8DPUT"'))
        resp.headers.append(String("Content-Length"), String(self.body.byte_length()))
        resp.connection_close = False
        return resp^


comptime _Layer = SharedKeySigningLayer[CapturingService, StaticSharedKeyProvider]


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _store(status: Int, var body: String) -> AzureStore[_Layer]:
    var layer = _Layer.wrap(
        CapturingService(status, body^),
        StaticSharedKeyProvider.make(String(ACCOUNT), String(FAKE_KEY)),
        String(PINNED_DATE),
    )
    return AzureStore[_Layer].new(AzureConfig.azurite(String(ACCOUNT)), layer^)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _wire_text(wire: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(wire))


def test_put_blob_sends_a_signed_block_blob() raises:
    var store = _store(201, String(""))
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    var meta = store.put_blob[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        String("c"),
        String("hello.txt"),
        _bytes(String("hello world")),
        String("text/plain; charset=UTF-8"),
        conn,
        reactor,
    )
    assert_equal(meta.size, Int64(11))
    assert_equal(meta.etag, String('"0x8DPUT"'))
    ref svc = store._http._inner
    assert_equal(svc.calls, 1)
    assert_equal(svc.authorization, HELLO_GOLDEN)
    var wire = _wire_text(svc.wire)
    assert_true(wire.startswith("PUT /devstoreaccount1/c/hello.txt HTTP/1.1\r\n"), wire)
    assert_true(wire.find("\r\nx-ms-blob-type: BlockBlob\r\n") > 0, wire)
    assert_true(wire.find("\r\nx-ms-version: 2021-08-06\r\n") > 0, wire)
    assert_true(wire.find("\r\ncontent-type: text/plain; charset=UTF-8\r\n") > 0, wire)
    assert_true(wire.find("\r\nContent-Length: 11\r\n") > 0, wire)
    assert_true(wire.endswith("\r\n\r\nhello world"), wire)


def test_put_empty_blob_signs_an_empty_length_slot() raises:
    var store = _store(201, String(""))
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    var meta = store.put_blob[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        String("c"), String("empty.bin"), List[UInt8](), String(""), conn, reactor
    )
    assert_equal(meta.size, Int64(0))
    ref svc = store._http._inner
    assert_equal(svc.authorization, EMPTY_GOLDEN)
    var wire = _wire_text(svc.wire)
    assert_true(wire.find("\r\nContent-Length: 0\r\n") > 0, wire)
    assert_equal(wire.find("content-type"), -1, wire)
    assert_true(wire.endswith("\r\n\r\n"), wire)


def test_put_blob_403_reads_as_permission_denied() raises:
    var store = _store(
        403,
        String(
            '<?xml version="1.0" encoding="utf-8"?><Error><Code>'
            "AuthenticationFailed</Code><Message>no</Message></Error>"
        ),
    )
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    try:
        _ = store.put_blob[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
            String("c"), String("hello.txt"), _bytes(String("x")), String(""), conn, reactor
        )
        raise Error("expected a refusal")
    except e:
        var msg = String(e)
        assert_equal(
            msg,
            String(
                "StoreError[PERMISSION_DENIED] PUT az://c/hello.txt status=403"
                " azure_code=AuthenticationFailed azure_message=no"
            ),
        )
        assert_equal(azure_store_error_kind_from_message(msg), AZURE_ERR_PERMISSION_DENIED)


def test_put_blob_refuses_an_empty_blob_name() raises:
    var store = _store(201, String(""))
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    with assert_raises(contains="azure store: refusing to put an empty blob name"):
        _ = store.put_blob[PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
            String("c"), String(""), _bytes(String("x")), String(""), conn, reactor
        )
    assert_equal(store._http._inner.calls, 0)


def main() raises:
    test_put_blob_sends_a_signed_block_blob()
    test_put_empty_blob_signs_an_empty_length_slot()
    test_put_blob_403_reads_as_permission_denied()
    test_put_blob_refuses_an_empty_blob_name()
    print("OK")
