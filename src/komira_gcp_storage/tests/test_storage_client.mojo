# =============================================================================
# test_storage_client.mojo — the generated Cloud Storage gRPC client, on the wire.
# =============================================================================
#
# `StorageClient` is generated at build time from the pinned
# google/storage/v2/storage.proto (mojo_gcp_client, `protocol = "grpc"`).
# Each test drives one method over a ScriptedConnector (canned HTTP/1.1
# responses, every written byte captured; no socket, no credential, no
# service) and checks what reaches the wire and what comes back:
#
#   * the call: `POST /google.storage.v2.Storage/<Method>`, exactly one
#     `authorization: Bearer <token>` from the client's token source;
#   * the request message: the protobuf bytes, in one gRPC frame. For
#     GetObject they are compared with bytes written by hand, field by field,
#     with an encoder independent of komira_proto_codec. For the other
#     methods the frame is the generated encoding, and for ListObjects,
#     ReadObject and CreateBucket that encoding is then read back with a
#     field walker independent of komira_proto_codec, so a wrong field
#     number is caught;
#   * routing: the `x-goog-request-params` value each method's
#     `(google.api.routing)` annotation gives, percent-encoded, or no header
#     where the method has none (WriteObject);
#   * the response: protobuf bytes written by hand decode into the generated
#     types, an unknown field skipped;
#   * the error shape, for each call shape (unary, server streaming, client
#     streaming): a gRPC status is raised as komira_gcp_core's error, with
#     its google.rpc.Code and without the server's `grpc-message`.
#
# Every success response carries `grpc-status: 0`, as a conforming server
# sends it.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_http_client.client import HttpClient
from komira_http_client.url import Url
from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_gcp_core import GcpTokenSource
from komira_grpc import (
    CallOptions,
    ClientStreamEncoder,
    GrpcClient,
    ProtocolGrpcProto,
    STREAM_OUTCOME_END_ERROR,
    STREAM_OUTCOME_MESSAGE,
    ServerStreamDecoder,
)
from komira_proto_codec import Serializable
from komira_proto_codec.proto_binary import PbDecoder, PbEncoder

from komira_gcp_storage.iam_policy import GetIamPolicyRequest, SetIamPolicyRequest
from komira_gcp_storage.policy import AuditConfig, Binding, Policy
from komira_gcp_storage.storage import (
    Bucket,
    ChecksummedData,
    CreateBucketRequest,
    DeleteBucketRequest,
    DeleteObjectRequest,
    GetBucketRequest,
    GetObjectRequest,
    ListObjectsRequest,
    Object,
    ReadObjectRequest,
    ReadObjectResponse,
    StartResumableWriteRequest,
    StorageClient,
    WriteObjectRequest,
    WriteObjectSpec,
)


comptime RT = PerCoreAsyncRuntime[NoopSink]

comptime _SVC = "/google.storage.v2.Storage/"

comptime _BUCKET = "projects/_/buckets/acme"
comptime _BUCKET_PARAM = "bucket=projects%2F_%2Fbuckets%2Facme"
"""`_BUCKET` as its routing parameter: the key `{bucket=**}` names, and the
value percent-encoded, `/` included."""

comptime _SERVER_TEXT = "object logs/a.parquet in acme of leaked@example.com: no such object"
"""A `grpc-message` holding what a server's error text holds: names."""


# =============================================================================
# The token source.
# =============================================================================


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """Returns `tok-1`, `tok-2`, ...: a different token for each fetch."""

    var _fetches: Int

    def __init__(out self):
        self._fetches = 0

    def access_token(mut self) raises -> String:
        self._fetches += 1
        return String("tok-") + String(self._fetches)

    def fetches(self) -> Int:
        return self._fetches


comptime Client = StorageClient[ScriptedConnector, CountingTokenSource]


# =============================================================================
# An independent protobuf writer: the expected bytes are written field by
# field here, not by komira_proto_codec.
# =============================================================================


def _varint(mut out: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _tag(mut out: List[UInt8], field: Int, wire_type: Int):
    _varint(out, UInt64(field * 8 + wire_type))


def _str(mut out: List[UInt8], field: Int, s: String):
    _tag(out, field, 2)
    _varint(out, UInt64(s.byte_length()))
    for b in s.as_bytes():
        out.append(b)


def _bytes(mut out: List[UInt8], field: Int, b: List[UInt8]):
    _tag(out, field, 2)
    _varint(out, UInt64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _int(mut out: List[UInt8], field: Int, v: Int):
    _tag(out, field, 0)
    _varint(out, UInt64(v))


def _fixed32(mut out: List[UInt8], field: Int, v: UInt32):
    _tag(out, field, 5)
    for k in range(4):
        out.append(UInt8((v >> UInt32(8 * k)) & 0xFF))


@fieldwise_init
struct _Field(Copyable, Movable):
    """One field as read off the wire: its number, wire type, the varint
    value (wire type 0) and the payload (wire type 2)."""

    var number: Int
    var wire_type: Int
    var value: UInt64
    var payload: List[UInt8]


def _read_varint(b: List[UInt8], mut at: Int) raises -> UInt64:
    var v = UInt64(0)
    var shift = UInt64(0)
    while True:
        if at >= len(b):
            raise Error("truncated varint")
        var c = b[at]
        at += 1
        v |= UInt64(c & 0x7F) << shift
        if c < 0x80:
            return v
        shift += 7


def _fields(b: List[UInt8]) raises -> List[_Field]:
    """Every top-level field of the protobuf message `b`, in wire order. A
    reader independent of komira_proto_codec, for wire types 0, 2 and 5."""
    var out = List[_Field]()
    var at = 0
    while at < len(b):
        var key = _read_varint(b, at)
        var number = Int(key >> 3)
        var wt = Int(key & 7)
        if wt == 0:
            out.append(_Field(number, wt, _read_varint(b, at), List[UInt8]()))
        elif wt == 2:
            var n = Int(_read_varint(b, at))
            var payload = List[UInt8]()
            for i in range(at, at + n):
                payload.append(b[i])
            at += n
            out.append(_Field(number, wt, UInt64(0), payload^))
        elif wt == 5:
            at += 4
            out.append(_Field(number, wt, UInt64(0), List[UInt8]()))
        else:
            raise Error(String("unexpected wire type ") + String(wt))
    return out^


def _string_field(b: List[UInt8], number: Int) raises -> String:
    """The last string field `number` of `b` ("" when absent)."""
    var out = String()
    var fields = _fields(b)
    for i in range(len(fields)):
        if fields[i].number == number:
            assert_equal(fields[i].wire_type, 2, String("field ") + String(number))
            out = String()
            for c in fields[i].payload:
                out += chr(Int(c))
    return out^


def _message_field(b: List[UInt8], number: Int) raises -> List[UInt8]:
    """The payload of the last length-delimited field `number` of `b`."""
    var out = List[UInt8]()
    var fields = _fields(b)
    for i in range(len(fields)):
        if fields[i].number == number:
            assert_equal(fields[i].wire_type, 2, String("field ") + String(number))
            out = fields[i].payload.copy()
    return out^


def _varint_field(b: List[UInt8], number: Int) raises -> Int:
    """The last varint field `number` of `b` (0 when absent)."""
    var out = 0
    var fields = _fields(b)
    for i in range(len(fields)):
        if fields[i].number == number:
            assert_equal(fields[i].wire_type, 0, String("field ") + String(number))
            out = Int(fields[i].value)
    return out


def _frame(message: List[UInt8]) -> List[UInt8]:
    """One gRPC length-prefixed message: flag 0, the length big-endian, the
    bytes."""
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


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _object_bytes(name: String, generation: Int, size: Int) -> List[UInt8]:
    """A google.storage.v2.Object as a server sends it: name, bucket,
    generation, size, one metadata entry, and a field this proto does not
    define (999), which a reader must skip."""
    var out = List[UInt8]()
    _str(out, 1, name)
    _str(out, 2, _BUCKET)
    _int(out, 3, generation)
    _int(out, 6, size)
    var entry = List[UInt8]()
    _str(entry, 1, "owner")
    _str(entry, 2, "etl")
    _bytes(out, 22, entry)
    _int(out, 999, 1)
    return out^


def _encoded[M: Serializable](m: M) raises -> List[UInt8]:
    var enc = PbEncoder()
    m.encode(enc)
    return enc.into_buf()


# =============================================================================
# The rig.
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _http_200(
    body: List[UInt8], status_headers: String = "grpc-status: 0\r\n"
) -> List[UInt8]:
    """A canned HTTP/1.1 200 gRPC response: `status_headers` (CRLF-terminated
    lines; an OK status by default) after the content type, then `body`."""
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


def _status_only(grpc_status: Int) -> List[UInt8]:
    """A trailers-only failure: `grpc-status` and `grpc-message`, no body."""
    return _http_200(
        List[UInt8](),
        String("grpc-status: ")
        + String(grpc_status)
        + "\r\ngrpc-message: "
        + _SERVER_TEXT
        + "\r\n",
    )


def _client(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) raises -> Client:
    """A client whose connector serves `script` to its one dial and mirrors
    every written byte into `capture`."""
    var connector = ScriptedConnector()
    connector.arm(ScriptedStream.from_read_script_with_capture(script^, capture))
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("http://127.0.0.1:8080/"))
    return Client(GrpcClient[ScriptedConnector](http^, base^), CountingTokenSource())


def _h2_client(var script: List[UInt8]) raises -> Client:
    """A client over one scripted HTTP/2 connection, which (unlike the
    HTTP/1.1 rig) carries real trailers. ALPN h2 is reported, or the client
    falls back to HTTP/1.1; the script is served one byte per read, or a
    greedy read takes frames for a stream not yet opened."""
    var s = ScriptedStream.from_read_script(script^)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream_tls(s^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("https://storage.googleapis.com:443/"))
    return Client(GrpcClient[ScriptedConnector](http^, base^), CountingTokenSource())


def _h2_data_then_trailers(var body: List[UInt8], grpc_status: Int) raises -> List[UInt8]:
    """A stream that fails part way: HEADERS, a DATA frame of messages, then a
    real TRAILERS block with `grpc-status` and the server's text."""
    var out = List[UInt8]()
    encode_settings_frame(List[SettingsEntry](), out)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    encode_headers_frame(
        UInt32(1), hpack.encode_block(hdrs^), end_stream=False, end_headers=True, out=out
    )
    encode_data_frame(UInt32(1), body^, end_stream=False, out=out)
    var trailers = List[HpackHeader]()
    trailers.append(HpackHeader(String("grpc-status"), String(grpc_status)))
    trailers.append(HpackHeader(String("grpc-message"), String(_SERVER_TEXT)))
    encode_headers_frame(
        UInt32(1), hpack.encode_block(trailers^), end_stream=True, end_headers=True, out=out
    )
    return out^


def _assert_gcp_error(text: String, method: String, name: String, code: Int) raises:
    """`text` is komira_gcp_core's error for `method`: its own `[grpc:C]`
    anchor, the RPC and the code, a byte count, and no byte of the server's
    text (nor komira_grpc's `[grpc:N] <grpc-message>` passed through)."""
    assert_true(
        text.startswith(
            String("[grpc:") + String(code) + "] gRPC " + _SVC + method + ": "
            + name + " (code " + String(code) + "), error text "
        ),
        text,
    )
    assert_true(text.endswith(" bytes"), text)
    assert_equal(_count(text, "[grpc:"), 1, text)
    for leak in ["logs/a.parquet", "acme", "leaked@example.com", "no such object"]:
        assert_false(text.find(leak) >= 0, String("echoed: ") + leak + " in " + text)


def _new_capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _text(bytes: List[UInt8], lower: Bool) -> String:
    """`bytes` as one-byte-per-byte text: ASCII letters lowered when `lower`,
    every byte above 0x7F as `?`, so an offset into the text is the same
    offset into `bytes`."""
    var out = String()
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        if c > 0x7F:
            c = ord("?")
        elif lower and c >= ord("A") and c <= ord("Z"):
            c += 32
        out += chr(c)
    return out^


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _header_values(sent: List[UInt8], name: String) -> List[String]:
    """Every value of header `name` (lowercase) in the captured requests,
    the value as sent (case kept)."""
    var low = _text(sent, True)
    var raw = _text(sent, False)
    var key = String("\r\n") + name + ":"
    var out = List[String]()
    var at = low.find(key)
    while at >= 0:
        var start = at + key.byte_length()
        while start < len(sent) and sent[start] == UInt8(ord(" ")):
            start += 1
        var end = raw.find("\r\n", start)
        var value = String()
        for k in range(start, end):
            value += chr(Int(sent[k]))
        out.append(value^)
        at = low.find(key, end)
    return out^


def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    var last = len(hay) - len(needle)
    for i in range(last + 1):
        var j = 0
        while j < len(needle) and hay[i + j] == needle[j]:
            j += 1
        if j == len(needle):
            return True
    return False


def _check_call(sent: List[UInt8], method: String, routing: String) raises:
    """`sent` is one call of `method` carrying one bearer token, `tok-1`, and
    the routing header `routing` (none when "")."""
    var low = _text(sent, True)
    var path = String("post ") + _text(_b(String(_SVC) + method), True)
    assert_equal(_count(low, path), 1, method + ": " + low)
    var auth = _header_values(sent, "authorization")
    assert_equal(len(auth), 1, method + ": one authorization header")
    assert_equal(auth[0], "Bearer tok-1", method)
    var params = _header_values(sent, "x-goog-request-params")
    if routing.byte_length() == 0:
        assert_equal(len(params), 0, method + " has no routing annotation")
    else:
        assert_equal(len(params), 1, method + ": one routing header")
        assert_equal(params[0], routing, method)
    # Classic gRPC carries metadata under its own name; the Connect/gateway
    # prefix never reaches this wire.
    assert_equal(_count(low, "grpc-metadata-"), 0, method + ": " + low)


def _drain(var decoder: ServerStreamDecoder[ProtocolGrpcProto]) raises -> List[ReadObjectResponse]:
    var got = List[ReadObjectResponse]()
    for _ in range(100):
        var o = decoder.try_next_message()
        if o.kind == STREAM_OUTCOME_END_ERROR:
            raise Error("the stream ended in an error")
        if o.kind != STREAM_OUTCOME_MESSAGE:
            break
        var dec = PbDecoder(o.message_bytes.copy())
        got.append(ReadObjectResponse.decode(dec))
    return got^


def _get_object_request() -> GetObjectRequest:
    return GetObjectRequest(
        bucket=String(_BUCKET),
        object=String("logs/a.parquet"),
        generation=Int64(7),
        soft_deleted=None,
        if_generation_match=Optional[Int64](Int64(7)),
        if_generation_not_match=None,
        if_metageneration_match=None,
        if_metageneration_not_match=None,
        common_object_request_params=None,
        read_mask=None,
        restore_token=String(""),
    )


# =============================================================================
# Objects.
# =============================================================================


def test_get_object_golden() raises:
    """GetObject: the request bytes field by field, the routing header, and
    an Object decoded from bytes a server would send."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_object_bytes("logs/a.parquet", 7, 1234))), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var got = client.get_object[RT](_get_object_request(), CallOptions(), 0, reactor, token)

    var want = List[UInt8]()
    _str(want, 1, _BUCKET)
    _str(want, 2, "logs/a.parquet")
    _int(want, 3, 7)  # generation
    _int(want, 4, 7)  # if_generation_match, set: present on the wire
    # restore_token, an implicit-presence string at its default. The
    # generated encoder writes implicit-presence fields even at their
    # default: valid proto3 (a reader takes it as the default) but not the
    # canonical encoding, which leaves them off. These bytes pin that choice
    # of proto-codegen's; were it to stop, this field drops out and nothing
    # else changes.
    _str(want, 12, "")
    assert_true(_contains(capture[], _frame(want)), _text(capture[], False))
    _check_call(capture[], "GetObject", _BUCKET_PARAM)
    assert_equal(client.token_source().fetches(), 1)

    assert_equal(got.name, "logs/a.parquet")
    assert_equal(got.bucket, _BUCKET)
    assert_equal(got.generation, Int64(7))
    assert_equal(got.size, Int64(1234))
    assert_equal(len(got.metadata), 1)
    assert_equal(got.metadata["owner"], "etl")


def test_get_object_not_found_is_the_gcp_error_shape() raises:
    """The error shape: grpc-status 5 is raised as NOT_FOUND, naming the RPC
    and the length of the error text, never the text."""
    var capture = _new_capture()
    var client = _client(_status_only(5), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var text = String()
    try:
        _ = client.get_object[RT](_get_object_request(), CallOptions(), 0, reactor, token)
    except e:
        text = String(e)
    _assert_gcp_error(text, "GetObject", "NOT_FOUND", 5)


def test_list_objects() raises:
    var page = List[UInt8]()
    _bytes(page, 1, _object_bytes("logs/a.parquet", 7, 10))
    _bytes(page, 1, _object_bytes("logs/b.parquet", 8, 20))
    _str(page, 2, "logs/2026/")
    _str(page, 3, "page-2")
    var capture = _new_capture()
    var client = _client(_http_200(_frame(page)), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var req = ListObjectsRequest(
        parent=String(_BUCKET),
        page_size=Int32(2),
        page_token=String(""),
        delimiter=String("/"),
        include_trailing_delimiter=False,
        prefix=String("logs/"),
        versions=False,
        read_mask=None,
        lexicographic_start=String(""),
        lexicographic_end=String(""),
        soft_deleted=False,
        include_folders_as_prefixes=False,
        match_glob=String(""),
        filter=String(""),
    )
    var got = client.list_objects[RT](req, CallOptions(), 0, reactor, token)

    var sent = _encoded(req)
    assert_true(_contains(capture[], _frame(sent)))
    assert_equal(_string_field(sent, 1), _BUCKET)  # parent
    assert_equal(_varint_field(sent, 2), 2)  # page_size
    assert_equal(_string_field(sent, 4), "/")  # delimiter
    assert_equal(_string_field(sent, 6), "logs/")  # prefix
    _check_call(capture[], "ListObjects", _BUCKET_PARAM)
    assert_equal(len(got.objects), 2)
    assert_equal(got.objects[0].name, "logs/a.parquet")
    assert_equal(got.objects[1].size, Int64(20))
    assert_equal(len(got.prefixes), 1)
    assert_equal(got.prefixes[0], "logs/2026/")
    assert_equal(got.next_page_token, "page-2")


def test_delete_object() raises:
    var capture = _new_capture()
    var client = _client(_http_200(_frame(List[UInt8]())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = DeleteObjectRequest(
        bucket=String(_BUCKET),
        object=String("logs/a.parquet"),
        generation=Int64(0),
        if_generation_match=Optional[Int64](Int64(7)),
        if_generation_not_match=None,
        if_metageneration_match=None,
        if_metageneration_not_match=None,
        common_object_request_params=None,
    )
    _ = client.delete_object[RT](req, CallOptions(), 0, reactor, token)
    assert_true(_contains(capture[], _frame(_encoded(req))))
    _check_call(capture[], "DeleteObject", _BUCKET_PARAM)


def test_read_object_streams_the_range() raises:
    """ReadObject (server streaming): the range request, then two responses,
    the first carrying its checksum and the content range."""
    var first = List[UInt8]()
    var data1 = List[UInt8]()
    _bytes(data1, 1, _b("hello "))
    _fixed32(data1, 2, UInt32(0xE3069283))
    _bytes(first, 1, data1)
    var range_ = List[UInt8]()
    _int(range_, 1, 100)
    _int(range_, 2, 111)
    _int(range_, 3, 4096)
    _bytes(first, 3, range_)
    var second = List[UInt8]()
    var data2 = List[UInt8]()
    _bytes(data2, 1, _b("world"))
    _bytes(second, 1, data2)
    var body = _frame(first)
    for b in _frame(second):
        body.append(b)

    var capture = _new_capture()
    var client = _client(_http_200(body), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = ReadObjectRequest(
        bucket=String(_BUCKET),
        object=String("logs/a.parquet"),
        generation=Int64(7),
        read_offset=Int64(100),
        read_limit=Int64(11),
        if_generation_match=None,
        if_generation_not_match=None,
        if_metageneration_match=None,
        if_metageneration_not_match=None,
        common_object_request_params=None,
        read_mask=None,
    )
    var got = _drain(client.read_object[RT](req, CallOptions(), 0, reactor, token))

    var sent = _encoded(req)
    assert_true(_contains(capture[], _frame(sent)))
    assert_equal(_string_field(sent, 1), _BUCKET)
    assert_equal(_string_field(sent, 2), "logs/a.parquet")
    assert_equal(_varint_field(sent, 3), 7)  # generation
    assert_equal(_varint_field(sent, 4), 100)  # read_offset
    assert_equal(_varint_field(sent, 5), 11)  # read_limit
    _check_call(capture[], "ReadObject", _BUCKET_PARAM)
    assert_equal(len(got), 2)
    var text = String()
    for i in range(len(got)):
        for b in got[i].checksummed_data.value().content:
            text += chr(Int(b))
    assert_equal(text, "hello world")
    assert_equal(got[0].checksummed_data.value().crc32c.value(), UInt32(0xE3069283))
    assert_false(got[1].checksummed_data.value().crc32c.__bool__())
    assert_equal(got[0].content_range.value().start, Int64(100))
    assert_equal(got[0].content_range.value().end, Int64(111))
    assert_equal(got[0].content_range.value().complete_length, Int64(4096))
    assert_false(got[1].content_range.__bool__())


def _read_request() -> ReadObjectRequest:
    return ReadObjectRequest(
        bucket=String(_BUCKET),
        object=String("logs/a.parquet"),
        generation=Int64(0),
        read_offset=Int64(0),
        read_limit=Int64(0),
        if_generation_match=None,
        if_generation_not_match=None,
        if_metageneration_match=None,
        if_metageneration_not_match=None,
        common_object_request_params=None,
        read_mask=None,
    )


def test_read_object_not_found_is_the_gcp_error_shape() raises:
    """A ReadObject of a missing object: a trailers-only NOT_FOUND on a
    server-streaming call raises the same shape as a unary one."""
    var capture = _new_capture()
    var client = _client(_status_only(5), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var text = String()
    var n = -1
    try:
        n = len(_drain(client.read_object[RT](_read_request(), CallOptions(), 0, reactor, token)))
    except e:
        text = String(e)
    assert_equal(n, -1, "returned " + String(n) + " message(s) for a NOT_FOUND")
    _assert_gcp_error(text, "ReadObject", "NOT_FOUND", 5)


def test_read_object_failing_mid_stream_raises() raises:
    """A read that fails part way: a data message arrives, then trailers
    say DATA_LOSS. The call raises; it does not return the message it has,
    which a caller would take for the whole object."""
    var data = List[UInt8]()
    _bytes(data, 1, _b("hello "))
    var first = List[UInt8]()
    _bytes(first, 1, data)
    var client = _h2_client(_h2_data_then_trailers(_frame(first), 15))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var text = String()
    var n = -1
    try:
        n = len(_drain(client.read_object[RT](_read_request(), CallOptions(), 0, reactor, token)))
    except e:
        text = String(e)
    assert_equal(n, -1, "returned " + String(n) + " message(s) for a stream that failed")
    _assert_gcp_error(text, "ReadObject", "DATA_LOSS", 15)


def _write_request(first: Bool, data: String, finish: Bool, offset: Int) raises -> WriteObjectRequest:
    var spec = Optional[WriteObjectSpec]()
    var case0 = 0
    if first:
        var resource = List[UInt8]()
        _str(resource, 1, "logs/new.parquet")
        _str(resource, 2, _BUCKET)
        var dec = PbDecoder(resource^)
        spec = WriteObjectSpec(
            resource=Optional[Object](Object.decode(dec)),
            predefined_acl=String(""),
            if_generation_match=Optional[Int64](Int64(0)),
            if_generation_not_match=None,
            if_metageneration_match=None,
            if_metageneration_not_match=None,
            object_size=None,
            appendable=None,
        )
        case0 = 2
    return WriteObjectRequest(
        write_offset=Int64(offset),
        object_checksums=None,
        finish_write=finish,
        common_object_request_params=None,
        _oneof0_case=case0,
        upload_id=None,
        write_object_spec=spec^,
        _oneof1_case=1,
        checksummed_data=Optional[ChecksummedData](
            ChecksummedData(content=_b(data), crc32c=None)
        ),
    )


def test_write_object_streams_each_message() raises:
    """WriteObject (client streaming): two request messages, the first with
    the create-if-absent spec. The method has no routing annotation, so the
    routing header is the caller's, sent once and verbatim."""
    var resp = List[UInt8]()
    _bytes(resp, 2, _object_bytes("logs/new.parquet", 42, 11))
    var capture = _new_capture()
    var client = _client(_http_200(_frame(resp)), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var m1 = _encoded(_write_request(True, "hello ", False, 0))
    var m2 = _encoded(_write_request(False, "world", True, 6))
    var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
    encoder.encode_message(Span(m1))
    encoder.encode_message(Span(m2))
    encoder.mark_close()
    var opts = CallOptions()
    opts.raw_metadata.set(String("x-goog-request-params"), String(_BUCKET_PARAM))
    var got = client.write_object[RT](encoder^, opts^, 0, reactor, token)

    assert_true(_contains(capture[], _frame(m1)))
    assert_true(_contains(capture[], _frame(m2)))
    _check_call(capture[], "WriteObject", _BUCKET_PARAM)
    assert_equal(got._oneof0_case, 2)
    assert_equal(got.resource.value().name, "logs/new.parquet")
    assert_equal(got.resource.value().generation, Int64(42))
    assert_equal(got.resource.value().size, Int64(11))


def test_write_object_without_routing_sends_none() raises:
    """The generated WriteObject adds no routing header of its own."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(List[UInt8]())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
    encoder.encode_message(Span(_encoded(_write_request(True, "x", True, 0))))
    encoder.mark_close()
    _ = client.write_object[RT](encoder^, CallOptions(), 0, reactor, token)
    _check_call(capture[], "WriteObject", "")


def test_write_object_failed_precondition() raises:
    """A lost create-if-absent race: grpc-status 9 on a client-streaming call
    is FAILED_PRECONDITION, without the server's text."""
    var capture = _new_capture()
    var client = _client(_status_only(9), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
    encoder.encode_message(Span(_encoded(_write_request(True, "x", True, 0))))
    encoder.mark_close()
    var text = String()
    try:
        _ = client.write_object[RT](encoder^, CallOptions(), 0, reactor, token)
    except e:
        text = String(e)
    _assert_gcp_error(text, "WriteObject", "FAILED_PRECONDITION", 9)


def _start_request(with_resource: Bool) raises -> StartResumableWriteRequest:
    var resource = List[UInt8]()
    _str(resource, 1, "logs/big.parquet")
    _str(resource, 2, _BUCKET)
    var dec = PbDecoder(resource^)
    var obj = Optional[Object]()
    if with_resource:
        obj = Object.decode(dec)
    return StartResumableWriteRequest(
        write_object_spec=Optional[WriteObjectSpec](
            WriteObjectSpec(
                resource=obj^,
                predefined_acl=String(""),
                if_generation_match=Optional[Int64](Int64(0)),
                if_generation_not_match=None,
                if_metageneration_match=None,
                if_metageneration_not_match=None,
                object_size=None,
                appendable=None,
            )
        ),
        common_object_request_params=None,
        object_checksums=None,
    )


def test_start_resumable_write_routes_on_the_nested_bucket() raises:
    """StartResumableWrite routes on write_object_spec.resource.bucket, two
    messages deep."""
    var resp = List[UInt8]()
    _str(resp, 1, "upload-0001")
    var capture = _new_capture()
    var client = _client(_http_200(_frame(resp)), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = _start_request(True)
    var got = client.start_resumable_write[RT](req, CallOptions(), 0, reactor, token)
    assert_true(_contains(capture[], _frame(_encoded(req))))
    _check_call(capture[], "StartResumableWrite", _BUCKET_PARAM)
    assert_equal(got.upload_id, "upload-0001")


def test_start_resumable_write_without_a_resource_sends_no_routing() raises:
    """The routed field is absent (no resource), so there is nothing to
    route on and no header is sent."""
    var resp = List[UInt8]()
    _str(resp, 1, "upload-0002")
    var capture = _new_capture()
    var client = _client(_http_200(_frame(resp)), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    _ = client.start_resumable_write[RT](_start_request(False), CallOptions(), 0, reactor, token)
    _check_call(capture[], "StartResumableWrite", "")


# =============================================================================
# Buckets.
# =============================================================================


def _bucket_bytes() -> List[UInt8]:
    var out = List[UInt8]()
    _str(out, 1, _BUCKET)
    _str(out, 3, "projects/example-project")
    _int(out, 4, 3)  # metageneration
    _str(out, 5, "US-CENTRAL1")
    _int(out, 999, 1)
    return out^


def test_get_bucket() raises:
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_bucket_bytes())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = GetBucketRequest(
        name=String(_BUCKET),
        if_metageneration_match=None,
        if_metageneration_not_match=None,
        read_mask=None,
    )
    var got = client.get_bucket[RT](req, CallOptions(), 0, reactor, token)
    assert_true(_contains(capture[], _frame(_encoded(req))))
    _check_call(capture[], "GetBucket", _BUCKET_PARAM)
    assert_equal(got.name, _BUCKET)
    assert_equal(got.project, "projects/example-project")
    assert_equal(got.metageneration, Int64(3))
    assert_equal(got.location, "US-CENTRAL1")


def test_delete_bucket() raises:
    var capture = _new_capture()
    var client = _client(_http_200(_frame(List[UInt8]())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = DeleteBucketRequest(
        name=String(_BUCKET),
        if_metageneration_match=Optional[Int64](Int64(3)),
        if_metageneration_not_match=None,
    )
    _ = client.delete_bucket[RT](req, CallOptions(), 0, reactor, token)
    assert_true(_contains(capture[], _frame(_encoded(req))))
    _check_call(capture[], "DeleteBucket", _BUCKET_PARAM)


def _create_request(with_bucket: Bool, bucket_project: String) raises -> CreateBucketRequest:
    """A CreateBucket whose `parent` is `projects/_`, the one non-empty value
    storage.proto allows (the project goes in `bucket.project`). With a
    bucket, it carries `bucket_project` (unset when "") and a location."""
    var bucket = Optional[Bucket]()
    if with_bucket:
        var raw = List[UInt8]()
        if bucket_project.byte_length() > 0:
            _str(raw, 3, bucket_project)
        _str(raw, 5, "US-CENTRAL1")
        var dec = PbDecoder(raw^)
        bucket = Bucket.decode(dec)
    return CreateBucketRequest(
        parent=String("projects/_"),
        bucket=bucket^,
        bucket_id=String("acme"),
        predefined_acl=String(""),
        predefined_default_object_acl=String(""),
        enable_object_retention=False,
    )


def test_create_bucket_routes_on_the_project() raises:
    """CreateBucket names two routing parameters with the same key,
    `project`: `parent` and `bucket.project`. The last one with a non-empty
    match is sent, once: `bucket.project` when set; otherwise `parent`,
    whether there is no bucket or a bucket whose project is unset (`**`
    matches the empty string, and an empty match is not sent)."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_bucket_bytes())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = _create_request(True, "projects/example-project")
    var got = client.create_bucket[RT](req, CallOptions(), 0, reactor, token)
    var sent = _encoded(req)
    assert_true(_contains(capture[], _frame(sent)))
    assert_equal(_string_field(sent, 1), "projects/_")  # parent
    assert_equal(_string_field(_message_field(sent, 2), 3), "projects/example-project")
    assert_equal(_string_field(sent, 3), "acme")  # bucket_id
    _check_call(capture[], "CreateBucket", "project=projects%2Fexample-project")
    assert_equal(got.name, _BUCKET)

    var capture2 = _new_capture()
    var client2 = _client(_http_200(_frame(_bucket_bytes())), capture2)
    _ = client2.create_bucket[RT](_create_request(False, ""), CallOptions(), 0, reactor, token)
    _check_call(capture2[], "CreateBucket", "project=projects%2F_")

    var capture3 = _new_capture()
    var client3 = _client(_http_200(_frame(_bucket_bytes())), capture3)
    _ = client3.create_bucket[RT](_create_request(True, ""), CallOptions(), 0, reactor, token)
    _check_call(capture3[], "CreateBucket", "project=projects%2F_")


def test_an_empty_routed_value_sends_no_header() raises:
    """`bucket = ""` matches `{bucket=**}` with an empty capture, which is
    not sent: no `bucket=` header."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_object_bytes("k", 1, 1))), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = _get_object_request()
    req.bucket = String("")
    _ = client.get_object[RT](req, CallOptions(), 0, reactor, token)
    _check_call(capture[], "GetObject", "")


def _policy_bytes() -> List[UInt8]:
    var out = List[UInt8]()
    _int(out, 1, 3)  # version
    _bytes(out, 3, _b("etag-1"))
    var binding = List[UInt8]()
    _str(binding, 1, "roles/storage.objectViewer")
    _str(binding, 2, "serviceAccount:reader@example.iam.gserviceaccount.com")
    _bytes(out, 4, binding)
    return out^


def test_get_iam_policy_routes_on_the_bucket() raises:
    """GetIamPolicy's resource may name something inside a bucket. Its two
    routing parameters both key `bucket`, and the second, which captures
    `projects/*/buckets/*` alone, is the one sent."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_policy_bytes())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = GetIamPolicyRequest(
        resource=String(_BUCKET) + "/managedFolders/logs",
        options=None,
    )
    var got = client.get_iam_policy[RT](req, CallOptions(), 0, reactor, token)
    assert_true(_contains(capture[], _frame(_encoded(req))))
    _check_call(capture[], "GetIamPolicy", _BUCKET_PARAM)
    assert_equal(got.version, Int32(3))
    assert_equal(len(got.bindings), 1)
    assert_equal(got.bindings[0].role, "roles/storage.objectViewer")
    assert_equal(len(got.bindings[0].members), 1)
    assert_equal(len(got.etag), 6)


def test_set_iam_policy() raises:
    """SetIamPolicy on a managed folder routes on its bucket, as GetIamPolicy
    does: the second template, `{bucket=projects/*/buckets/*}/**`, is the
    last match."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_policy_bytes())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var members = List[String]()
    members.append(String("serviceAccount:reader@example.iam.gserviceaccount.com"))
    var bindings = List[Binding]()
    bindings.append(
        Binding(role=String("roles/storage.objectViewer"), members=members^, condition=None)
    )
    var req = SetIamPolicyRequest(
        resource=String(_BUCKET) + "/managedFolders/logs",
        policy=Optional[Policy](
            Policy(version=Int32(3), bindings=bindings^, audit_configs=List[AuditConfig](), etag=_b("etag-1"))
        ),
        update_mask=None,
    )
    var got = client.set_iam_policy[RT](req, CallOptions(), 0, reactor, token)
    assert_true(_contains(capture[], _frame(_encoded(req))))
    _check_call(capture[], "SetIamPolicy", _BUCKET_PARAM)
    assert_equal(got.bindings[0].members[0], "serviceAccount:reader@example.iam.gserviceaccount.com")


def test_iam_policy_on_a_bare_name_routes_on_the_first_template() raises:
    """A resource the second template does not match is routed by the first,
    `{bucket=**}`, whole."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_policy_bytes())), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = GetIamPolicyRequest(resource=String("acme"), options=None)
    _ = client.get_iam_policy[RT](req, CallOptions(), 0, reactor, token)
    _check_call(capture[], "GetIamPolicy", "bucket=acme")


# =============================================================================
# Headers.
# =============================================================================


def test_routing_and_bearer_replace_a_callers_entries() raises:
    """A caller's own `authorization` and `x-goog-request-params` are
    replaced by the token hook and the routing annotation, never sent beside
    them; the caller's other metadata travels under its own name."""
    var capture = _new_capture()
    var client = _client(_http_200(_frame(_object_bytes("logs/a.parquet", 7, 1))), capture)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    opts.raw_metadata.set(String("authorization"), String("Bearer stale"))
    opts.raw_metadata.set(String("x-goog-request-params"), String("bucket=other"))
    opts.metadata.set(String("x-goog-user-project"), String("billing-project"))
    _ = client.get_object[RT](_get_object_request(), opts^, 0, reactor, token)
    _check_call(capture[], "GetObject", _BUCKET_PARAM)
    var user_project = _header_values(capture[], "x-goog-user-project")
    assert_equal(len(user_project), 1)
    assert_equal(user_project[0], "billing-project")
    assert_false(_text(capture[], False).find("stale") >= 0)


def main() raises:
    test_get_object_golden()
    test_get_object_not_found_is_the_gcp_error_shape()
    test_list_objects()
    test_delete_object()
    test_read_object_streams_the_range()
    test_read_object_not_found_is_the_gcp_error_shape()
    test_read_object_failing_mid_stream_raises()
    test_write_object_streams_each_message()
    test_write_object_without_routing_sends_none()
    test_write_object_failed_precondition()
    test_start_resumable_write_routes_on_the_nested_bucket()
    test_start_resumable_write_without_a_resource_sends_no_routing()
    test_get_bucket()
    test_delete_bucket()
    test_create_bucket_routes_on_the_project()
    test_an_empty_routed_value_sends_no_header()
    test_get_iam_policy_routes_on_the_bucket()
    test_set_iam_policy()
    test_iam_policy_on_a_bare_name_routes_on_the_first_template()
    test_routing_and_bearer_replace_a_callers_entries()
    print("all Cloud Storage gRPC client tests passed")
