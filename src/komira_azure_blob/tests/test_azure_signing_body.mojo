# SharedKeySigningLayer over requests with a body: no socket, no emulator.
# The capturing service keeps the Authorization and the serialized request
# bytes each request reached it with.
#
# Shared Key for the Blob service signs twelve standard header slots before
# the canonicalized headers ("Authorize with Shared Key",
# https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key):
# VERB, Content-Encoding, Content-Language, Content-Length, Content-MD5,
# Content-Type, Date, If-Modified-Since, If-Match, If-None-Match,
# If-Unmodified-Since, Range. Content-Length is the empty string when the
# length is zero for version 2015-02-21 and later, and "0" for 2014-02-14 and
# earlier. Put Blob sends the blob in the body with Content-Length, and
# optionally Content-MD5 and Content-Type
# (https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob).
#
# Rows:
#   * the document's own PUT example (Create Container, Content-Length 0),
#     at version 2014-02-14 ("0" in the Content-Length slot) and at
#     2015-02-21 (an empty slot): the layer's string-to-sign is the
#     document's (verbatim for 2015-02-21; for 2014-02-14 with the "0" moved
#     from the Content-MD5 slot, where the document's example misprints it,
#     to the Content-Length slot its format block names) and its
#     Authorization equals the golden over it;
#   * the Content-Length slot rule itself, at the 2015-02-21 boundary;
#   * a Put Blob with an 11-byte body, Content-MD5 and Content-Type: the
#     Authorization equals the golden over a string-to-sign carrying all
#     three, and the wire bytes carry `Content-Length: 11` and the body;
#   * a PUT setting every standard slot but Date and Range to a distinct
#     value: the golden catches a slot read from the wrong header or
#     signed in the wrong place;
#   * a body sent as a stream (not drained into request_bytes) is signed
#     with its length and the head is replaced without inventing body bytes;
#   * a body of unknown length (chunked) is refused, with the reason;
#   * a Content-Length header on the request that disagrees with the body is
#     refused, and so are serialized body bytes that disagree with it.
#
# Goldens, by Python (hmac, hashlib, base64), key = base64.b64decode(FAKE_KEY):
#   DOC_2014 "PUT\n\n\n0\n\n\n\n\n\n\n\n\nx-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\n"
#            "x-ms-version:2014-02-14\n/myaccount/mycontainer\nrestype:container\ntimeout:30"
#            -> 1MHDXtIqBPKTSZ4Idn4iWyyE8EO4O2p0IKGfoLJmWH4=
#   DOC_2015 the same with "\n\n\n\n" for "\n\n\n0\n" and x-ms-version:2015-02-21
#            -> rLZx3DvlYvC5J2YLRYoVRsA2FHEQTUPXcYnx7Q0+hHM=
#   PUT_BLOB "PUT\n\n\n11\nXrY7u+Ae7tCTyyK7j1rNww==\ntext/plain; charset=UTF-8\n\n\n\n\n\n\n"
#            "x-ms-blob-type:BlockBlob\nx-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n"
#            "x-ms-version:2021-08-06\n/devstoreaccount1/devstoreaccount1/c/hello.txt"
#            -> Ykt9bV+YhfyPe4aVYICqVe2GFjDagM/Qx1ZmF1K1W7s=
#            (XrY7u+Ae7tCTyyK7j1rNww== is base64(md5(b"hello world")))
#   ALL      "\n".join(["PUT", "gzip", "en-US", "3", "kAFQmDzST7DWlj99KOF/cg==",
#            "application/octet-stream", "", "Wed, 30 Sep 2026 00:00:00 GMT",
#            '"0x8D1"', '"0x8D2"', "Thu, 01 Oct 2026 00:00:00 GMT", ""])
#            + "\nx-ms-blob-type:BlockBlob\nx-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n"
#            + "x-ms-version:2021-08-06\n/devstoreaccount1/devstoreaccount1/c/all.bin"
#            -> 9W6MUM14E2PhIGOLQR3g5tuVxYesHj6HLeFSZAa8UFU=
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_blob.azure_signing import (
    SharedKeySigningLayer,
    StaticSharedKeyProvider,
    shared_key_content_length,
)
from komira_http_client.body import BytesBody, EmptyBody, RequestBody, StreamingBody
from komira_http_client.client import build_request_with_body, build_streaming_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.request_writer import method_put
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime DOC_DATE = "Fri, 26 Jun 2015 23:39:12 GMT"
comptime PINNED_DATE = "Thu, 01 Oct 2026 12:00:00 GMT"
comptime DOC_2014_GOLDEN = "SharedKey myaccount:1MHDXtIqBPKTSZ4Idn4iWyyE8EO4O2p0IKGfoLJmWH4="
comptime DOC_2015_GOLDEN = "SharedKey myaccount:rLZx3DvlYvC5J2YLRYoVRsA2FHEQTUPXcYnx7Q0+hHM="
comptime PUT_BLOB_GOLDEN = "SharedKey devstoreaccount1:Ykt9bV+YhfyPe4aVYICqVe2GFjDagM/Qx1ZmF1K1W7s="
comptime ALL_SLOTS_GOLDEN = "SharedKey devstoreaccount1:9W6MUM14E2PhIGOLQR3g5tuVxYesHj6HLeFSZAa8UFU="


struct CapturingService(HttpService, Movable, Deinitable):
    """Answers 201 and keeps the last request's Authorization and bytes."""

    var authorization: String
    var wire: List[UInt8]
    var calls: Int

    def __init__(out self):
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
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(List[UInt8]())
        )
        resp.status = Int32(201)
        resp.reason = String("Created")
        resp.headers = HeaderMap()
        resp.headers.append(String("Content-Length"), String("0"))
        resp.connection_close = False
        return resp^


struct UnknownLengthBody(RequestBody, Movable, Deinitable):
    """A body that reports no length, as a chunked stream does."""

    var _done: Bool

    def __init__(out self):
        self._done = False

    def content_length(self) -> Int:
        return -1

    def read_chunk[o: Origin[mut=True]](mut self, dst: Span[UInt8, o]) -> Int:
        return 0

    def replayable(self) -> Bool:
        return False

    def rewind(mut self) raises:
        raise Error("not replayable")


comptime _Layer = SharedKeySigningLayer[CapturingService, StaticSharedKeyProvider]


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _layer(account: String, date: String) -> _Layer:
    return _Layer.wrap(
        CapturingService(),
        StaticSharedKeyProvider.make(account, String(FAKE_KEY)),
        date,
    )


def _send[B: RequestBody](mut layer: _Layer, var req: ClientRequest[B]) raises:
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    var resp = layer.call[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, B](
        req^, conn, reactor
    )
    assert_equal(Int(resp.status), 201)


def _wire_text(wire: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(wire))


comptime DOC_STS_2014 = (
    "PUT\n\n\n0\n\n\n\n\n\n\n\n\nx-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\n"
    "x-ms-version:2014-02-14\n/myaccount/mycontainer\nrestype:container\ntimeout:30"
)
"""The document's 2014-02-14 example prints "PUT\n\n\n\n0\n" + 8 newlines: four
newlines before the "0", which puts it in the Content-MD5 slot. The format
block on the same page, and the 2015-02-21 example beside it (twelve
newlines), place Content-Length fourth: VERB, Content-Encoding,
Content-Language, Content-Length. This is the example with the "0" in that
slot (three newlines before it, nine after)."""
comptime DOC_STS_2015 = (
    "PUT\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\n"
    "x-ms-version:2015-02-21\n/myaccount/mycontainer\nrestype:container\ntimeout:30"
)


def _doc_put_container(version: String, want_sts: String) raises -> String:
    """The document's Create Container example: PUT
    /mycontainer?restype=container&timeout=30, Content-Length 0. The
    layer's string-to-sign is the document's, verbatim."""
    var layer = _layer(String("myaccount"), String(DOC_DATE))
    var headers = HeaderMap()
    headers.insert(String("x-ms-version"), version)
    var url = Url.http(String("myaccount"), UInt16(80), String("/mycontainer"))
    url.query = String("restype=container&timeout=30")
    var req = build_request_with_body[EmptyBody](
        method_put(), url^, headers^, EmptyBody.new()
    )
    _send(layer, req^)
    assert_equal(layer.last_string_to_sign(), want_sts)
    return layer._inner.authorization


def test_doc_put_zero_length_2014_02_14_signs_0() raises:
    assert_equal(
        _doc_put_container(String("2014-02-14"), String(DOC_STS_2014)),
        DOC_2014_GOLDEN,
    )


def test_doc_put_zero_length_2015_02_21_signs_empty() raises:
    assert_equal(
        _doc_put_container(String("2015-02-21"), String(DOC_STS_2015)),
        DOC_2015_GOLDEN,
    )


def test_content_length_slot_by_version() raises:
    """The rule behind the two document examples, at its boundary."""
    assert_equal(shared_key_content_length(0, String("2015-02-21")), "")
    assert_equal(shared_key_content_length(0, String("2021-08-06")), "")
    assert_equal(shared_key_content_length(0, String("2014-02-14")), "0")
    assert_equal(shared_key_content_length(0, String("2009-09-19")), "0")
    assert_equal(shared_key_content_length(0, String("")), "")
    assert_equal(shared_key_content_length(11, String("2021-08-06")), "11")
    assert_equal(shared_key_content_length(11, String("2014-02-14")), "11")


def _put_blob_headers() raises -> HeaderMap:
    var headers = HeaderMap()
    headers.insert(String("x-ms-version"), String("2021-08-06"))
    headers.insert(String("x-ms-blob-type"), String("BlockBlob"))
    headers.insert(String("Content-Type"), String("text/plain; charset=UTF-8"))
    headers.insert(String("Content-MD5"), String("XrY7u+Ae7tCTyyK7j1rNww=="))
    return headers^


def _blob_url(blob: String) -> Url:
    return Url.http(
        String("127.0.0.1"), UInt16(10000), String("/devstoreaccount1/c/") + blob
    )


def test_put_blob_signs_length_md5_and_type_and_sends_the_body() raises:
    var layer = _layer(String("devstoreaccount1"), String(PINNED_DATE))
    var req = build_request_with_body[BytesBody](
        method_put(),
        _blob_url(String("hello.txt")),
        _put_blob_headers(),
        BytesBody.from_str(String("hello world")),
    )
    _send(layer, req^)
    ref svc = layer._inner
    assert_equal(svc.authorization, PUT_BLOB_GOLDEN)
    var wire = _wire_text(svc.wire)
    assert_true(wire.startswith("PUT /devstoreaccount1/c/hello.txt HTTP/1.1\r\n"), wire)
    assert_true(wire.find("\r\nContent-Length: 11\r\n") > 0, wire)
    assert_true(wire.find("\r\nauthorization: " + String(PUT_BLOB_GOLDEN) + "\r\n") > 0, wire)
    assert_true(wire.endswith("\r\n\r\nhello world"), wire)
    # One head, one body: the body is not duplicated or dropped.
    assert_equal(len(wire.split("\r\n\r\n")), 2)


def test_every_standard_slot_is_signed_in_its_place() raises:
    var layer = _layer(String("devstoreaccount1"), String(PINNED_DATE))
    var headers = HeaderMap()
    headers.insert(String("x-ms-version"), String("2021-08-06"))
    headers.insert(String("x-ms-blob-type"), String("BlockBlob"))
    headers.insert(String("Content-Encoding"), String("gzip"))
    headers.insert(String("Content-Language"), String("en-US"))
    headers.insert(String("Content-MD5"), String("kAFQmDzST7DWlj99KOF/cg=="))
    headers.insert(String("Content-Type"), String("application/octet-stream"))
    headers.insert(String("If-Modified-Since"), String("Wed, 30 Sep 2026 00:00:00 GMT"))
    headers.insert(String("If-Match"), String('"0x8D1"'))
    headers.insert(String("If-None-Match"), String('"0x8D2"'))
    headers.insert(String("If-Unmodified-Since"), String("Thu, 01 Oct 2026 00:00:00 GMT"))
    var req = build_request_with_body[BytesBody](
        method_put(), _blob_url(String("all.bin")), headers^, BytesBody.from_str(String("abc"))
    )
    _send(layer, req^)
    assert_equal(layer._inner.authorization, ALL_SLOTS_GOLDEN)


def test_streamed_body_is_signed_with_its_length() raises:
    """A streaming body is not in request_bytes: the new head says its
    length and no body bytes are appended to it."""
    var layer = _layer(String("devstoreaccount1"), String(PINNED_DATE))
    var req = build_streaming_request[StreamingBody](
        method_put(),
        _blob_url(String("hello.txt")),
        _put_blob_headers(),
        StreamingBody.from_pattern(UInt8(0x61), 11),
    )
    _send(layer, req^)
    ref svc = layer._inner
    # The same string-to-sign as the buffered Put Blob: length 11, MD5, type.
    assert_equal(svc.authorization, PUT_BLOB_GOLDEN)
    var wire = _wire_text(svc.wire)
    assert_true(wire.find("\r\nContent-Length: 11\r\n") > 0, wire)
    assert_true(wire.endswith("\r\n\r\n"), wire)


def test_body_of_unknown_length_is_refused() raises:
    var layer = _layer(String("devstoreaccount1"), String(PINNED_DATE))
    var req = build_streaming_request[UnknownLengthBody](
        method_put(), _blob_url(String("x.bin")), _put_blob_headers(), UnknownLengthBody()
    )
    with assert_raises(
        contains=(
            "azure signing: refusing a request body of unknown length: Shared"
            " Key signs Content-Length, so a chunked body cannot be signed"
        )
    ):
        _send(layer, req^)
    assert_equal(layer._inner.calls, 0)


def test_content_length_header_disagreeing_with_the_body_is_refused() raises:
    var layer = _layer(String("devstoreaccount1"), String(PINNED_DATE))
    var headers = _put_blob_headers()
    headers.insert(String("Content-Length"), String("5"))
    var req = build_request_with_body[BytesBody](
        method_put(), _blob_url(String("x.bin")), headers^, BytesBody.from_str(String("hello world"))
    )
    with assert_raises(
        contains=(
            "azure signing: the request's Content-Length header says 5 but its"
            " body is 11 bytes"
        )
    ):
        _send(layer, req^)
    assert_equal(layer._inner.calls, 0)


def test_request_bytes_body_disagreeing_with_the_body_is_refused() raises:
    """request_bytes holding part of the body is refused rather than sent
    under a head that frames the whole body."""
    var layer = _layer(String("devstoreaccount1"), String(PINNED_DATE))
    var wire = List[UInt8]()
    wire.extend(Span(String("PUT /devstoreaccount1/c/x.bin HTTP/1.1\r\n\r\nhel").as_bytes()))
    var req = ClientRequest[BytesBody](
        method=method_put(),
        url=_blob_url(String("x.bin")),
        headers=_put_blob_headers(),
        request_bytes=wire^,
        body=BytesBody.from_str(String("hello world")),
    )
    with assert_raises(
        contains="azure signing: request_bytes carries 3 body bytes but the body is 11 bytes"
    ):
        _send(layer, req^)
    assert_equal(layer._inner.calls, 0)


def main() raises:
    test_doc_put_zero_length_2014_02_14_signs_0()
    test_doc_put_zero_length_2015_02_21_signs_empty()
    test_content_length_slot_by_version()
    test_put_blob_signs_length_md5_and_type_and_sends_the_body()
    test_every_standard_slot_is_signed_in_its_place()
    test_streamed_body_is_signed_with_its_length()
    test_body_of_unknown_length_is_refused()
    test_content_length_header_disagreeing_with_the_body_is_refused()
    test_request_bytes_body_disagreeing_with_the_body_is_refused()
    print("OK")
