# =============================================================================
# test_gcs_grpc_token_refresh.mojo — every call takes its token from the source.
# =============================================================================
#
# A long-lived backend must never present a token past its life: a handle that
# fetched one token at start and stamped it on every call would fail every
# call about an hour later with PERMISSION_DENIED. StorageGrpcBackend holds no
# token; each call asks its `GcpTokenSource`. In production that source is a
# komira_gcp_core `CachingTokenSource`, which serves its cached token while
# it is fresh and fetches a new one `refresh_before_ms` before it expires.
#
# Here the cache runs on a komira_retry `ManualClock` and a fetcher that
# hands out `tok-1`, `tok-2`, ... valid for one hour, so "an hour later" is
# one `advance` call. The first five cases pin the source on its own; the
# last four drive two calls through the backend over a scripted HTTP/2
# connection and read the bearer token each one carried on the wire.
# No socket, no credential, no service.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import (
    DEFAULT_REFRESH_BEFORE_MS,
    AccessToken,
    AccessTokenFetcher,
    CachingTokenSource,
    StaticTokenSource,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.codec.h2.connection_preface import H2_CLIENT_PREFACE_LEN
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_PADDED,
    FLAG_PRIORITY,
    FRAME_CONTINUATION,
    FRAME_HEADERS,
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock

from komira_objectstore_gcs import GCS_ERR_PERMISSION_DENIED, StorageGrpcBackend, gcs_store_error_kind_from_message


comptime _HOUR_S: Int64 = 3600


struct SeqFetcher(AccessTokenFetcher, Movable, Deinitable):
    """A token endpoint: `tok-1`, `tok-2`, ..., each valid for an hour from
    the fetch."""

    var _n: Int

    def __init__(out self):
        self._n = 0

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        self._n += 1
        return AccessToken.expiring_in(String("tok-") + String(self._n), now_ms, _HOUR_S)


struct ShortFetcher(AccessTokenFetcher, Movable, Deinitable):
    """A token endpoint whose tokens expire inside the refresh margin."""

    def __init__(out self):
        pass

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        return AccessToken.expiring_in(String("short"), now_ms, 60)


comptime Caching = CachingTokenSource[SeqFetcher, ManualClock]


def _caching() raises -> Caching:
    return Caching(SeqFetcher(), ManualClock(1_000_000))


# =============================================================================
# The token source on its own.
# =============================================================================


def test_cached_token_is_reused_while_fresh() raises:
    var src = _caching()
    var first = src.access_token()
    src.clock().advance(Int64(_HOUR_S * 1000) - DEFAULT_REFRESH_BEFORE_MS - 1)
    var second = src.access_token()
    assert_equal(first, "tok-1")
    assert_equal(second, "tok-1")
    assert_equal(src.fetches(), 1)


def test_token_near_expiry_is_refetched() raises:
    """At the refresh margin the cache fetches again: a token is never handed
    out with less than `refresh_before_ms` to live."""
    var src = _caching()
    _ = src.access_token()
    src.clock().advance(Int64(_HOUR_S * 1000) - DEFAULT_REFRESH_BEFORE_MS)
    assert_equal(src.access_token(), "tok-2")
    assert_equal(src.fetches(), 2)


def test_endpoint_token_already_stale_is_refused() raises:
    """A fetched token shorter-lived than the margin is an error, not a token
    to serve (and not a reason to fetch in a loop)."""
    var src = CachingTokenSource[ShortFetcher, ManualClock](ShortFetcher(), ManualClock(0))
    var msg = String()
    try:
        _ = src.access_token()
    except e:
        msg = String(e)
    assert_true(msg.find("unusable") >= 0, msg)
    assert_false(msg.find("short") >= 0, String("the token's bytes leaked: ") + msg)


def test_static_source_never_changes() raises:
    var src = StaticTokenSource(String("emulator-token"))
    assert_equal(src.access_token(), "emulator-token")
    assert_equal(src.access_token(), "emulator-token")


def test_static_source_refuses_an_empty_token() raises:
    """There is no anonymous mode: an empty token would go out as `Bearer `."""
    var raised = False
    try:
        _ = StaticTokenSource(String(""))
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# Through the backend: two calls on one HTTP/2 connection.
# =============================================================================


def _object(name: String, generation: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(0x0A)  # field 1, length-delimited: name
    out.append(UInt8(name.byte_length()))
    for b in name.as_bytes():
        out.append(b)
    out.append(0x18)  # field 3, varint: generation
    out.append(UInt8(generation))
    return out^


def _frame(message: List[UInt8]) -> List[UInt8]:
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


def _reply(sid: Int, status: Int, mut hpack: HpackEncoder, mut out: List[UInt8]) raises:
    """GetObject's reply on stream `sid`: the object, or (status != 0) a
    trailers-only failure."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    if status != 0:
        hdrs.append(HpackHeader(String("grpc-status"), String(status)))
        encode_headers_frame(UInt32(sid), hpack.encode_block(hdrs^), end_stream=True, end_headers=True, out=out)
        return
    encode_headers_frame(UInt32(sid), hpack.encode_block(hdrs^), end_stream=False, end_headers=True, out=out)
    encode_data_frame(UInt32(sid), _frame(_object("k", 7)), end_stream=False, out=out)
    var trailers = List[HpackHeader]()
    trailers.append(HpackHeader(String("grpc-status"), String("0")))
    encode_headers_frame(UInt32(sid), hpack.encode_block(trailers^), end_stream=True, end_headers=True, out=out)


def _two_calls(first_status: Int) raises -> List[UInt8]:
    """Replies on streams 1 and 3, the first with `first_status`."""
    var out = List[UInt8]()
    encode_settings_frame(List[SettingsEntry](), out)
    var hpack = HpackEncoder(max_table_size=4096)
    _reply(1, first_status, hpack, out)
    _reply(3, 0, hpack, out)
    return out^


def _connector(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) -> ScriptedConnector:
    var s = ScriptedStream.from_read_script_with_capture(script^, capture)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    return ScriptedConnector.with_stream_tls(s^)


def _bearers(capture: ArcPointer[List[UInt8]]) raises -> List[String]:
    """Every `authorization` value the client sent, in order."""
    ref w = capture[]
    var hpack = HpackDecoder(max_table_size=4096)
    var out = List[String]()
    var i = H2_CLIENT_PREFACE_LEN
    var block = List[UInt8]()
    while i + 9 <= len(w):
        var length = (Int(w[i]) << 16) | (Int(w[i + 1]) << 8) | Int(w[i + 2])
        var kind = w[i + 3]
        var flags = w[i + 4]
        var start = i + 9
        var end = start + length
        if kind == FRAME_HEADERS or kind == FRAME_CONTINUATION:
            var pad = 0
            if kind == FRAME_HEADERS and (flags & FLAG_PADDED) != 0:
                pad = Int(w[start])
                start += 1
            if kind == FRAME_HEADERS and (flags & FLAG_PRIORITY) != 0:
                start += 5
            for k in range(start, end - pad):
                block.append(w[k])
            if (flags & FLAG_END_HEADERS) != 0:
                var hs = hpack.decode_block(Span(block))
                for k in range(len(hs)):
                    if hs[k].name == "authorization":
                        out.append(hs[k].value)
                block = List[UInt8]()
        i = end
    return out^


comptime CachingBackend = StorageGrpcBackend[ScriptedConnector, Caching, ManualClock]


def _caching_backend(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) raises -> CachingBackend:
    return CachingBackend(_connector(script^, capture), _caching(), ManualClock(0), HttpClientConfig.defaults())


def test_backend_refetches_a_token_near_expiry() raises:
    """THE FALSIFIER. An hour on, the next call carries a NEW token. A backend
    that kept the first token would send `tok-1` twice."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var backend = _caching_backend(_two_calls(0), capture)
    _ = backend.get_object("acme", "k")
    backend.token_source().clock().advance(Int64(_HOUR_S * 1000))
    _ = backend.get_object("acme", "k")
    var bearers = _bearers(capture)
    assert_equal(len(bearers), 2)
    assert_equal(bearers[0], "Bearer tok-1")
    assert_equal(bearers[1], "Bearer tok-2")
    assert_equal(backend.token_source().fetches(), 2)


def test_backend_reuses_a_fresh_token() raises:
    """Inside the token's life no call fetches again."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var backend = _caching_backend(_two_calls(0), capture)
    _ = backend.get_object("acme", "k")
    backend.token_source().clock().advance(Int64(60_000))
    _ = backend.get_object("acme", "k")
    var bearers = _bearers(capture)
    assert_equal(len(bearers), 2)
    assert_equal(bearers[0], "Bearer tok-1")
    assert_equal(bearers[1], "Bearer tok-1")
    assert_equal(backend.token_source().fetches(), 1)


def test_backend_refetches_after_invalidate() raises:
    """A call refused with UNAUTHENTICATED is PERMISSION_DENIED at the seam;
    the owner drops the cached token, and the next call carries a new one."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var backend = _caching_backend(_two_calls(16), capture)
    var msg = String()
    try:
        _ = backend.get_object("acme", "k")
    except e:
        msg = String(e)
    assert_equal(gcs_store_error_kind_from_message(msg), GCS_ERR_PERMISSION_DENIED, msg)
    backend.token_source().invalidate()
    _ = backend.get_object("acme", "k")
    var bearers = _bearers(capture)
    assert_equal(len(bearers), 2)
    assert_equal(bearers[0], "Bearer tok-1")
    assert_equal(bearers[1], "Bearer tok-2")


def test_backend_with_a_static_source_sends_the_same_token() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var backend = StorageGrpcBackend[ScriptedConnector, StaticTokenSource, ManualClock](
        _connector(_two_calls(0), capture),
        StaticTokenSource(String("emulator-token")),
        ManualClock(0),
        HttpClientConfig.defaults(),
    )
    _ = backend.get_object("acme", "k")
    _ = backend.get_object("acme", "k")
    var bearers = _bearers(capture)
    assert_equal(len(bearers), 2)
    assert_equal(bearers[0], "Bearer emulator-token")
    assert_equal(bearers[1], "Bearer emulator-token")


def main() raises:
    test_cached_token_is_reused_while_fresh()
    test_token_near_expiry_is_refetched()
    test_endpoint_token_already_stale_is_refused()
    test_static_source_never_changes()
    test_static_source_refuses_an_empty_token()
    test_backend_refetches_a_token_near_expiry()
    test_backend_reuses_a_fresh_token()
    test_backend_refetches_after_invalidate()
    test_backend_with_a_static_source_sends_the_same_token()
    print("all token refresh tests passed (9)")
