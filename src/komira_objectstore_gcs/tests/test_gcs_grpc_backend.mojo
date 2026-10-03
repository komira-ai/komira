# =============================================================================
# test_gcs_grpc_backend.mojo — StorageGrpcBackend, on an HTTP/2 wire.
# =============================================================================
#
# Each case drives the backend over a scripted HTTP/2 connection: the
# connector reports TLS and ALPN h2 (so the client takes its production path,
# the pooled h2 multiplex), the "server" is a pre-written frame script served
# one byte per read, and every byte the client writes is captured. No socket,
# no credential, no service.
#
# From the captured bytes the test decodes the client's frames (HPACK
# included) and checks what reached the wire: the method path, exactly one
# bearer token from the token source, the routing header, a `grpc-timeout`,
# and the request messages decoded back into the generated types. The
# responses are protobuf bytes written by hand, so the mapping of each reply
# onto the seam's value carriers is checked against bytes the generated
# encoder did not write. Every gRPC status is mapped onto its StoreError kind
# with no server text in the result.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import GcpTokenSource, gcp_grpc_status_error
from komira_gcp_storage.storage import (
    DeleteObjectRequest,
    GetObjectRequest,
    ListObjectsRequest,
    ReadObjectRequest,
    WriteObjectRequest,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.codec.h2.connection_preface import H2_CLIENT_PREFACE_LEN
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_PADDED,
    FLAG_PRIORITY,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_HEADERS,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
    encode_window_update_frame,
)
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore.path import Path
from komira_proto_codec.proto_binary import PbDecoder
from komira_retry import ManualClock

from komira_objectstore_gcs import (
    GCS_ERR_MALFORMED,
    GCS_ERR_NONE,
    GCS_ERR_NOT_FOUND,
    GCS_ERR_PERMISSION_DENIED,
    GCS_ERR_PRECONDITION,
    GCS_ERR_THROTTLED,
    GCS_ERR_TRANSPORT,
    GcsConditionalStore,
    StorageGrpcBackend,
    WRITE_OBJECT_CHUNK_BYTES,
    build_gcs_tls_connector,
    gcs_bucket_resource_name,
    gcs_error_kind_from_code,
    gcs_routing_param,
    gcs_store_error_from_code,
    gcs_store_error_from_raised,
    gcs_store_error_kind_from_message,
)


comptime _SVC = "/google.storage.v2.Storage/"
comptime _BUCKET = "acme"
comptime _RESOURCE = "projects/_/buckets/acme"
comptime _ROUTING = "bucket=projects%2F_%2Fbuckets%2Facme"
comptime _SERVER_TEXT = "object logs/a.parquet of leaked@example.com: no such object"
"""The `grpc-message` every failing script sends: it names things, and no
error the backend raises may repeat it."""


# =============================================================================
# The token source.
# =============================================================================


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """`tok-1`, `tok-2`, ...: a different token for each fetch."""

    var _fetches: Int

    def __init__(out self):
        self._fetches = 0

    def access_token(mut self) raises -> String:
        self._fetches += 1
        return String("tok-") + String(self._fetches)

    def fetches(self) -> Int:
        return self._fetches


struct EmptyTokenSource(GcpTokenSource, Movable, Deinitable):
    """A source that answers with no token."""

    def __init__(out self):
        pass

    def access_token(mut self) raises -> String:
        return String("")


comptime Backend = StorageGrpcBackend[ScriptedConnector, CountingTokenSource, ManualClock]


# =============================================================================
# Bytes written by hand.
# =============================================================================


def _varint(mut out: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _str(mut out: List[UInt8], field: Int, s: String):
    _varint(out, UInt64(field * 8 + 2))
    _varint(out, UInt64(s.byte_length()))
    for b in s.as_bytes():
        out.append(b)


def _msg(mut out: List[UInt8], field: Int, b: List[UInt8]):
    _varint(out, UInt64(field * 8 + 2))
    _varint(out, UInt64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _int(mut out: List[UInt8], field: Int, v: Int):
    _varint(out, UInt64(field * 8))
    _varint(out, UInt64(v))


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _text(b: List[UInt8]) -> String:
    var out = String()
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _object(name: String, generation: Int, size: Int, etag: String) -> List[UInt8]:
    """A google.storage.v2.Object as the service sends it, with a field this
    proto does not define (999), which a reader skips."""
    var out = List[UInt8]()
    _str(out, 1, name)
    _str(out, 2, _RESOURCE)
    _int(out, 3, generation)
    _int(out, 6, size)
    _str(out, 27, etag)
    _int(out, 999, 1)
    return out^


def _write_response(generation: Int, size: Int) -> List[UInt8]:
    """WriteObjectResponse with the finished object (oneof arm `resource`, 2)."""
    var out = List[UInt8]()
    _msg(out, 2, _object("logs/new.parquet", generation, size, "CAE="))
    return out^


def _read_response(data: String) -> List[UInt8]:
    """ReadObjectResponse carrying `data` (checksummed_data.content)."""
    var cd = List[UInt8]()
    _msg(cd, 1, _b(data))
    var out = List[UInt8]()
    _msg(out, 1, cd)
    return out^


# =============================================================================
# The scripted HTTP/2 server.
# =============================================================================


def _prologue() -> List[UInt8]:
    """The server's SETTINGS (a stream window of 2^31-1) and a connection
    WINDOW_UPDATE to the same size, so a multi-MiB request is never held by
    flow control: this script cannot react to the client."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(SETTINGS_INITIAL_WINDOW_SIZE, UInt32(0x7FFFFFFF)))
    encode_settings_frame(entries^, out)
    encode_window_update_frame(UInt32(0), UInt32(0x7FFFFFFF - 65535), out)
    return out^


def _frame(message: List[UInt8]) -> List[UInt8]:
    """One gRPC length-prefixed message."""
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


def _reply_ok(
    sid: Int, messages: List[List[UInt8]], status: Int, mut hpack: HpackEncoder, mut out: List[UInt8]
) raises:
    """HEADERS, the messages in one DATA frame, then trailers with
    `grpc-status: status` (0 for success)."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    encode_headers_frame(UInt32(sid), hpack.encode_block(hdrs^), end_stream=False, end_headers=True, out=out)
    var body = List[UInt8]()
    for i in range(len(messages)):
        for b in _frame(messages[i]):
            body.append(b)
    encode_data_frame(UInt32(sid), body^, end_stream=False, out=out)
    var trailers = List[HpackHeader]()
    trailers.append(HpackHeader(String("grpc-status"), String(status)))
    if status != 0:
        trailers.append(HpackHeader(String("grpc-message"), String(_SERVER_TEXT)))
    encode_headers_frame(UInt32(sid), hpack.encode_block(trailers^), end_stream=True, end_headers=True, out=out)


def _reply_status(sid: Int, status: Int, mut hpack: HpackEncoder, mut out: List[UInt8]) raises:
    """A trailers-only failure: one HEADERS frame, END_STREAM, the status and
    the server's text."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    hdrs.append(HpackHeader(String("grpc-status"), String(status)))
    hdrs.append(HpackHeader(String("grpc-message"), String(_SERVER_TEXT)))
    encode_headers_frame(UInt32(sid), hpack.encode_block(hdrs^), end_stream=True, end_headers=True, out=out)


def _ok_script(var message: List[UInt8]) raises -> List[UInt8]:
    var out = _prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var messages = List[List[UInt8]]()
    messages.append(message^)
    _reply_ok(1, messages, 0, hpack, out)
    return out^


def _status_script(status: Int) raises -> List[UInt8]:
    var out = _prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    _reply_status(1, status, hpack, out)
    return out^


def _new_capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _connector(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) -> ScriptedConnector:
    """One h2 connection over TLS (as the connector reports it), one byte per
    read: without ALPN h2 the client falls back to HTTP/1.1, and a greedy read
    would take frames for a stream the client has not opened yet."""
    var s = ScriptedStream.from_read_script_with_capture(script^, capture)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    return ScriptedConnector.with_stream_tls(s^)


def _backend(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) raises -> Backend:
    return Backend(
        _connector(script^, capture),
        CountingTokenSource(),
        ManualClock(5_000_000),
        HttpClientConfig.defaults(),
    )


# =============================================================================
# What the client sent.
# =============================================================================


struct Sent(Movable, Deinitable):
    """The client's side of the exchange, decoded: every header it sent (in
    order, all streams) and the gRPC messages of each stream."""

    var headers: List[HpackHeader]
    var streams: List[Int]
    var bodies: List[List[UInt8]]

    def __init__(out self):
        self.headers = List[HpackHeader]()
        self.streams = List[Int]()
        self.bodies = List[List[UInt8]]()

    def values(self, name: String) -> List[String]:
        var out = List[String]()
        for i in range(len(self.headers)):
            if self.headers[i].name == name:
                out.append(self.headers[i].value)
        return out^

    def names_starting(self, prefix: String) -> Int:
        var n = 0
        for i in range(len(self.headers)):
            if self.headers[i].name.startswith(prefix):
                n += 1
        return n

    def messages(self, sid: Int) raises -> List[List[UInt8]]:
        """The gRPC messages the client sent on stream `sid`."""
        var at = -1
        for i in range(len(self.streams)):
            if self.streams[i] == sid:
                at = i
        var out = List[List[UInt8]]()
        if at < 0:
            return out^
        ref body = self.bodies[at]
        var i = 0
        while i < len(body):
            assert_true(i + 5 <= len(body), "a truncated gRPC message prefix")
            var n = (Int(body[i + 1]) << 24) | (Int(body[i + 2]) << 16) | (Int(body[i + 3]) << 8) | Int(body[i + 4])
            assert_true(i + 5 + n <= len(body), "a truncated gRPC message")
            var m = List[UInt8](capacity=n)
            for k in range(i + 5, i + 5 + n):
                m.append(body[k])
            out.append(m^)
            i += 5 + n
        return out^


def _sent(capture: ArcPointer[List[UInt8]]) raises -> Sent:
    """Decode the captured client bytes: the preface, then frames. Header
    blocks (HEADERS + CONTINUATION) are decoded in order with one HPACK
    decoder, as the server would."""
    ref w = capture[]
    var out = Sent()
    var hpack = HpackDecoder(max_table_size=4096)
    assert_true(len(w) >= H2_CLIENT_PREFACE_LEN, "no client preface")
    var i = H2_CLIENT_PREFACE_LEN
    var block = List[UInt8]()
    while i + 9 <= len(w):
        var length = (Int(w[i]) << 16) | (Int(w[i + 1]) << 8) | Int(w[i + 2])
        var kind = w[i + 3]
        var flags = w[i + 4]
        var sid = ((Int(w[i + 5]) & 0x7F) << 24) | (Int(w[i + 6]) << 16) | (Int(w[i + 7]) << 8) | Int(w[i + 8])
        var start = i + 9
        var end = start + length
        assert_true(end <= len(w), "a truncated client frame")
        if kind == FRAME_HEADERS or kind == FRAME_DATA or kind == FRAME_CONTINUATION:
            var pad = 0
            if (kind == FRAME_HEADERS or kind == FRAME_DATA) and (flags & FLAG_PADDED) != 0:
                pad = Int(w[start])
                start += 1
            if kind == FRAME_HEADERS and (flags & FLAG_PRIORITY) != 0:
                start += 5
            if kind == FRAME_DATA:
                var at = -1
                for k in range(len(out.streams)):
                    if out.streams[k] == sid:
                        at = k
                if at < 0:
                    out.streams.append(sid)
                    out.bodies.append(List[UInt8]())
                    at = len(out.bodies) - 1
                for k in range(start, end - pad):
                    out.bodies[at].append(w[k])
            else:
                for k in range(start, end - pad):
                    block.append(w[k])
                if (flags & FLAG_END_HEADERS) != 0:
                    var hs = hpack.decode_block(Span(block))
                    for k in range(len(hs)):
                        out.headers.append(hs[k])
                    block = List[UInt8]()
        i = end
    return out^


def _check_call(sent: Sent, method: String, token: String, routing: String) raises:
    """One call of `method` with one bearer token `token`, the routing header
    `routing`, a deadline, and no `grpc-metadata-` (Connect) prefix."""
    var paths = sent.values(":path")
    assert_equal(len(paths), 1, method)
    assert_equal(paths[0], String(_SVC) + method)
    var auth = sent.values("authorization")
    assert_equal(len(auth), 1, method + ": one authorization header")
    assert_equal(auth[0], String("Bearer ") + token)
    var params = sent.values("x-goog-request-params")
    assert_equal(len(params), 1, method + ": one routing header")
    assert_equal(params[0], routing)
    assert_equal(len(sent.values("grpc-timeout")), 1, method + ": the call states its deadline")
    assert_equal(sent.names_starting("grpc-metadata-"), 0)


def _assert_no_server_text(msg: String) raises:
    for leak in ["leaked@example.com", "no such object", "logs/a.parquet of"]:
        assert_false(msg.find(leak) >= 0, String("echoed the server's text: ") + msg)


# =============================================================================
# Writes.
# =============================================================================


def test_conditional_create_on_the_wire() raises:
    """create-if-absent: one WriteObject message carrying the spec
    (if_generation_match = 0, the bucket's resource name, the bare key), the
    data, and finish_write; the routing header the backend sets itself; the
    generation from the finished object."""
    var capture = _new_capture()
    var backend = _backend(_ok_script(_write_response(42, 3)), capture)
    var data = List[UInt8]()
    data.append(1)
    data.append(2)
    data.append(3)
    var gen = backend.conditional_create(_BUCKET, "logs/new.parquet", data)
    assert_equal(gen, Int64(42))
    assert_equal(backend.token_source().fetches(), 1)

    var sent = _sent(capture)
    _check_call(sent, "WriteObject", "tok-1", _ROUTING)
    var msgs = sent.messages(1)
    assert_equal(len(msgs), 1)
    var dec = PbDecoder(msgs[0].copy())
    var req = WriteObjectRequest.decode(dec)
    assert_equal(req.write_offset, Int64(0))
    assert_true(req.finish_write)
    assert_equal(req._oneof0_case, 2)
    ref spec = req.write_object_spec.value()
    assert_equal(spec.if_generation_match.value(), Int64(0))
    assert_equal(spec.resource.value().name, "logs/new.parquet")
    assert_equal(spec.resource.value().bucket, _RESOURCE)
    assert_equal(req._oneof1_case, 1)
    assert_equal(len(req.checksummed_data.value().content), 3)
    assert_equal(req.checksummed_data.value().content[2], UInt8(3))


def test_compare_and_swap_writes_a_large_object_in_chunks() raises:
    """A payload of two chunks and a bit goes out as three messages: the
    first with the spec and `if_generation_match`, each at its offset, only
    the last finishing the write, the content reassembling to the payload."""
    var total = 2 * WRITE_OBJECT_CHUNK_BYTES + 1000
    var data = List[UInt8](capacity=total)
    for i in range(total):
        data.append(UInt8(i % 251))
    var capture = _new_capture()
    var backend = _backend(_ok_script(_write_response(43, total)), capture)
    var gen = backend.compare_and_swap(_BUCKET, "logs/new.parquet", data, Int64(1_700_000_000_000_001))
    assert_equal(gen, Int64(43))

    var sent = _sent(capture)
    _check_call(sent, "WriteObject", "tok-1", _ROUTING)
    var msgs = sent.messages(1)
    assert_equal(len(msgs), 3)
    var at = 0
    for m in range(3):
        var dec = PbDecoder(msgs[m].copy())
        var req = WriteObjectRequest.decode(dec)
        assert_equal(req.write_offset, Int64(m * WRITE_OBJECT_CHUNK_BYTES))
        assert_equal(req.finish_write, m == 2)
        if m == 0:
            assert_equal(req._oneof0_case, 2)
            assert_equal(
                req.write_object_spec.value().if_generation_match.value(),
                Int64(1_700_000_000_000_001),
            )
        else:
            assert_equal(req._oneof0_case, 0)
            assert_false(req.write_object_spec.__bool__())
        ref content = req.checksummed_data.value().content
        assert_equal(len(content), WRITE_OBJECT_CHUNK_BYTES if m < 2 else 1000)
        for k in range(len(content)):
            if content[k] != data[at]:
                raise Error(String("payload byte ") + String(at) + " differs")
            at += 1
    assert_equal(at, total)


def test_write_preconditions_are_412() raises:
    """FAILED_PRECONDITION, ALREADY_EXISTS and ABORTED on WriteObject are the
    seam's PRECONDITION / 412, with no server text."""
    for code in [9, 6, 10]:
        var capture = _new_capture()
        var backend = _backend(_status_script(code), capture)
        var msg = String()
        try:
            _ = backend.conditional_create(_BUCKET, "logs/new.parquet", List[UInt8]())
        except e:
            msg = String(e)
        assert_true(
            msg.startswith("StoreError[PRECONDITION] WriteObject gs://acme/logs/new.parquet status=412 grpc_code="),
            msg,
        )
        assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_PRECONDITION)
        _assert_no_server_text(msg)


def test_refusals_send_nothing() raises:
    """A swap on generation 0 (which the wire reads as create-if-absent) and
    a negative range are refused before a token is fetched or a byte sent."""
    var capture = _new_capture()
    var backend = _backend(_ok_script(List[UInt8]()), capture)
    var msg = String()
    try:
        _ = backend.compare_and_swap(_BUCKET, "k", List[UInt8](), Int64(0))
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_MALFORMED, msg)
    msg = String()
    try:
        _ = backend.read_range(_BUCKET, "k", Int64(-10), Int64(0))
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_MALFORMED, msg)
    msg = String()
    try:
        _ = backend.read_range(_BUCKET, "k", Int64(0), Int64(-1))
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_MALFORMED, msg)
    assert_equal(backend.token_source().fetches(), 0)
    assert_equal(len(capture[]), 0)


def test_empty_token_is_refused_before_sending() raises:
    """The generated client refuses an empty token; the backend reports it as
    a TRANSPORT error carrying that reason, and nothing is written."""
    var capture = _new_capture()
    var backend = StorageGrpcBackend[ScriptedConnector, EmptyTokenSource, ManualClock](
        _connector(_ok_script(List[UInt8]()), capture),
        EmptyTokenSource(),
        ManualClock(0),
        HttpClientConfig.defaults(),
    )
    var msg = String()
    try:
        _ = backend.get_object(_BUCKET, "k")
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_TRANSPORT, msg)
    assert_true(msg.find("empty access token") >= 0, msg)
    assert_equal(len(capture[]), 0)


# =============================================================================
# Reads.
# =============================================================================


def test_read_range_on_the_wire() raises:
    """The range request (resource name, key, offset, limit) and two
    responses concatenated."""
    var out = _prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var messages = List[List[UInt8]]()
    messages.append(_read_response("hello "))
    messages.append(_read_response("world"))
    _reply_ok(1, messages, 0, hpack, out)
    var capture = _new_capture()
    var backend = _backend(out^, capture)
    var got = backend.read_range(_BUCKET, "logs/a.parquet", Int64(100), Int64(11))
    assert_equal(_text(got), "hello world")

    var sent = _sent(capture)
    _check_call(sent, "ReadObject", "tok-1", _ROUTING)
    var msgs = sent.messages(1)
    assert_equal(len(msgs), 1)
    var dec = PbDecoder(msgs[0].copy())
    var req = ReadObjectRequest.decode(dec)
    assert_equal(req.bucket, _RESOURCE)
    assert_equal(req.object, "logs/a.parquet")
    assert_equal(req.read_offset, Int64(100))
    assert_equal(req.read_limit, Int64(11))


def test_read_of_an_absent_object_is_404() raises:
    var capture = _new_capture()
    var backend = _backend(_status_script(5), capture)
    var msg = String()
    try:
        _ = backend.read_range(_BUCKET, "logs/a.parquet", Int64(0), Int64(0))
    except e:
        msg = String(e)
    assert_true(msg.startswith("StoreError[NOT_FOUND] ReadObject gs://acme/logs/a.parquet status=404 grpc_code=5"), msg)
    _assert_no_server_text(msg)


def test_read_status_after_data_is_raised() raises:
    """A status that arrives in the trailers, after data, still fails the
    read (DATA_LOSS: TRANSPORT), rather than returning the partial bytes."""
    var out = _prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var messages = List[List[UInt8]]()
    messages.append(_read_response("partial"))
    _reply_ok(1, messages, 15, hpack, out)
    var capture = _new_capture()
    var backend = _backend(out^, capture)
    var msg = String()
    try:
        _ = backend.read_range(_BUCKET, "logs/a.parquet", Int64(0), Int64(0))
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_TRANSPORT, msg)
    assert_true(msg.find("grpc_code=15") >= 0, msg)
    _assert_no_server_text(msg)


def test_get_object_maps_the_metadata() raises:
    var capture = _new_capture()
    var backend = _backend(_ok_script(_object("logs/a.parquet", 7, 1234, "CAc=")), capture)
    var meta = backend.get_object(_BUCKET, "logs/a.parquet")
    assert_equal(meta.key, "logs/a.parquet")
    assert_equal(meta.size, Int64(1234))
    assert_equal(meta.generation, Int64(7))
    assert_equal(meta.etag, "CAc=")

    var sent = _sent(capture)
    _check_call(sent, "GetObject", "tok-1", _ROUTING)
    var dec = PbDecoder(sent.messages(1)[0].copy())
    var req = GetObjectRequest.decode(dec)
    assert_equal(req.bucket, _RESOURCE)
    assert_equal(req.object, "logs/a.parquet")


def test_delete_object_on_the_wire() raises:
    var capture = _new_capture()
    var backend = _backend(_ok_script(List[UInt8]()), capture)
    backend.delete_object(_BUCKET, "logs/a.parquet")
    var sent = _sent(capture)
    _check_call(sent, "DeleteObject", "tok-1", _ROUTING)
    var dec = PbDecoder(sent.messages(1)[0].copy())
    var req = DeleteObjectRequest.decode(dec)
    assert_equal(req.bucket, _RESOURCE)
    assert_equal(req.object, "logs/a.parquet")
    assert_false(req.if_generation_match.__bool__())


def test_list_objects_maps_the_page() raises:
    var page = List[UInt8]()
    _msg(page, 1, _object("logs/a.parquet", 7, 10, "e1"))
    _msg(page, 1, _object("logs/b.parquet", 8, 20, "e2"))
    _str(page, 2, "logs/2026/")
    _str(page, 3, "page-2")
    var capture = _new_capture()
    var backend = _backend(_ok_script(page^), capture)
    var got = backend.list_objects(_BUCKET, "logs/", "page-1", "/")
    assert_equal(len(got.objects), 2)
    assert_equal(got.objects[0].key, "logs/a.parquet")
    assert_equal(got.objects[1].generation, Int64(8))
    assert_equal(got.objects[1].size, Int64(20))
    assert_equal(got.objects[1].etag, "e2")
    assert_equal(len(got.common_prefixes), 1)
    assert_equal(got.common_prefixes[0], "logs/2026/")
    assert_equal(got.next_page_token, "page-2")

    var sent = _sent(capture)
    _check_call(sent, "ListObjects", "tok-1", _ROUTING)
    var dec = PbDecoder(sent.messages(1)[0].copy())
    var req = ListObjectsRequest.decode(dec)
    assert_equal(req.parent, _RESOURCE)
    assert_equal(req.prefix, "logs/")
    assert_equal(req.page_token, "page-1")
    assert_equal(req.delimiter, "/")


# =============================================================================
# Above the seam.
# =============================================================================


def _no_clone() raises -> Backend:
    raise Error("this test does not clone the store")


def test_conditional_store_runs_over_the_grpc_backend() raises:
    """GcsConditionalStore over StorageGrpcBackend: `head` is a GetObject,
    and the generation is the handle; `delete` of an absent object swallows
    the NOT_FOUND, as over the fake."""
    var capture = _new_capture()
    var store = GcsConditionalStore[Backend](
        String(_BUCKET),
        _backend(_ok_script(_object("logs/a.parquet", 7, 1234, "CAc=")), capture),
        _no_clone,
    )
    var meta = store.head(Path.parse("logs/a.parquet"))
    assert_equal(meta.size, Int64(1234))
    assert_equal(meta.etag, "7")

    var capture2 = _new_capture()
    var store2 = GcsConditionalStore[Backend](
        String(_BUCKET), _backend(_status_script(5), capture2), _no_clone
    )
    store2.delete(Path.parse("logs/gone.parquet"))
    _check_call(_sent(capture2), "DeleteObject", "tok-1", _ROUTING)


# =============================================================================
# The status mapping, the cancellation token, the helpers.
# =============================================================================


def test_every_status_maps_to_its_kind() raises:
    var want: List[UInt8] = [
        GCS_ERR_MALFORMED,  # 0 OK (never raised; not a failure kind)
        GCS_ERR_TRANSPORT,  # 1 CANCELLED
        GCS_ERR_TRANSPORT,  # 2 UNKNOWN
        GCS_ERR_MALFORMED,  # 3 INVALID_ARGUMENT
        GCS_ERR_TRANSPORT,  # 4 DEADLINE_EXCEEDED
        GCS_ERR_NOT_FOUND,  # 5 NOT_FOUND
        GCS_ERR_PRECONDITION,  # 6 ALREADY_EXISTS
        GCS_ERR_PERMISSION_DENIED,  # 7 PERMISSION_DENIED
        GCS_ERR_THROTTLED,  # 8 RESOURCE_EXHAUSTED
        GCS_ERR_PRECONDITION,  # 9 FAILED_PRECONDITION
        GCS_ERR_PRECONDITION,  # 10 ABORTED
        GCS_ERR_MALFORMED,  # 11 OUT_OF_RANGE
        GCS_ERR_MALFORMED,  # 12 UNIMPLEMENTED
        GCS_ERR_TRANSPORT,  # 13 INTERNAL
        GCS_ERR_THROTTLED,  # 14 UNAVAILABLE
        GCS_ERR_TRANSPORT,  # 15 DATA_LOSS
        GCS_ERR_PERMISSION_DENIED,  # 16 UNAUTHENTICATED
    ]
    var http: List[Int] = [400, 500, 500, 400, 500, 404, 412, 403, 429, 412, 412, 400, 400, 500, 429, 500, 403]
    for code in range(17):
        assert_equal(gcs_error_kind_from_code(code), want[code], String("code ") + String(code))
        var msg = String(gcs_store_error_from_code("GetObject", "b", "k", code))
        assert_equal(gcs_store_error_kind_from_message(msg), want[code], msg)
        assert_true(msg.find(String(" status=") + String(http[code]) + " ") >= 0, msg)
        # The same, from the error the generated client raises.
        var raised = String(gcp_grpc_status_error(String(_SVC) + "GetObject", code, 40))
        assert_equal(String(gcs_store_error_from_raised("GetObject", "b", "k", raised)), msg)


def test_errors_without_a_status_are_transport() raises:
    """An error the client raised before any status arrived, or a status of
    another RPC, is not read as this call's status."""
    var msg = String(
        gcs_store_error_from_raised("GetObject", "b", "k", "HttpError[EOF_MID_RESPONSE]: peer closed")
    )
    assert_equal(msg, "StoreError[TRANSPORT] GetObject gs://b/k status=500 detail=HttpError[EOF_MID_RESPONSE]: peer closed")
    var other = String(gcp_grpc_status_error(String(_SVC) + "ReadObject", 5, 1))
    assert_equal(
        gcs_store_error_kind_from_message(String(gcs_store_error_from_raised("GetObject", "b", "k", other))),
        GCS_ERR_TRANSPORT,
    )
    assert_equal(gcs_store_error_kind_from_message("no kind here"), GCS_ERR_NONE)


def test_cancel_fails_later_calls() raises:
    """After `cancel`, a call starts with its token tripped and fails as
    TRANSPORT instead of returning the reply."""
    var capture = _new_capture()
    var backend = _backend(_ok_script(_object("logs/a.parquet", 7, 1, "e")), capture)
    backend.cancel("shutting down")
    var msg = String()
    try:
        _ = backend.get_object(_BUCKET, "logs/a.parquet")
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_TRANSPORT, msg)


def test_call_deadline_must_be_positive() raises:
    var capture = _new_capture()
    var raised = False
    try:
        _ = Backend(
            _connector(List[UInt8](), capture),
            CountingTokenSource(),
            ManualClock(0),
            HttpClientConfig.defaults(),
            call_deadline_ms=0,
        )
    except e:
        raised = True
        assert_true(String(e).find("call_deadline_ms") >= 0, String(e))
    assert_true(raised)


def test_helpers_and_constants() raises:
    assert_equal(gcs_bucket_resource_name("my-bucket"), "projects/_/buckets/my-bucket")
    assert_equal(gcs_routing_param("my-bucket"), "bucket=projects%2F_%2Fbuckets%2Fmy-bucket")
    # Every chunk but the last must be 256 KiB-aligned, and a chunk plus the
    # first message's spec must stay well under the 4 MiB message limit.
    assert_equal(WRITE_OBJECT_CHUNK_BYTES % (256 * 1024), 0)
    assert_true(WRITE_OBJECT_CHUNK_BYTES > 0)
    assert_true(WRITE_OBJECT_CHUNK_BYTES <= 3 * 1024 * 1024)
    # The production connector is TLS (it dials nothing until a call).
    assert_true(build_gcs_tls_connector().is_tls())


def main() raises:
    test_conditional_create_on_the_wire()
    test_compare_and_swap_writes_a_large_object_in_chunks()
    test_write_preconditions_are_412()
    test_refusals_send_nothing()
    test_empty_token_is_refused_before_sending()
    test_read_range_on_the_wire()
    test_read_of_an_absent_object_is_404()
    test_read_status_after_data_is_raised()
    test_get_object_maps_the_metadata()
    test_delete_object_on_the_wire()
    test_list_objects_maps_the_page()
    test_conditional_store_runs_over_the_grpc_backend()
    test_every_status_maps_to_its_kind()
    test_errors_without_a_status_are_transport()
    test_cancel_fails_later_calls()
    test_call_deadline_must_be_positive()
    test_helpers_and_constants()
    print("all StorageGrpcBackend tests passed")
