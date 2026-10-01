# =============================================================================
# src/komira_http/tests/test_objectstore_http.mojo
# ObjectStoreHttp seam.
# =============================================================================
#
# Contract:
#   * (d-i)  head returns ObjectMetadata (Content-Length, ETag,
#            content-type, last-modified)
#   * (d-ii) get_range delegates correctness verified
#   * (d-iii) get_ranges fan-out: 4 concurrent ranges, each response
#            intact + bytes match the source
#   * ScriptedObjectStoreHttp conformer verified end-to-end
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
)
from komira_http.client.objectstore_http import (
    ByteRange,
    HttpClientObjectStoreHttp,
    ObjectMetadata,
    ObjectStoreHttp,
    RangeFanoutResult,
    ScriptedObjectStoreHttp,
)
from komira_http.client.response_body import BufferedResponseBody
from komira_http.client.state_machine import ClientResponse
from komira_http.client.url import Url


# =============================================================================
# Helpers.
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _make_pattern_body(size: Int) -> List[UInt8]:
    """Pattern body for differential range testing — byte at offset i
    is `i & 0xFF`."""
    var out = List[UInt8]()
    var i = 0
    while i < size:
        out.append(UInt8(i & 0xFF))
        i = i + 1
    return out^


def _drain_body(
    mut resp: ClientResponse[BufferedResponseBody],
    mut reactor: Reactor[NoopSink],
) raises -> List[UInt8]:
    """Drain a BufferedResponseBody via poll_frame. Returns the
    extracted body bytes (one Data frame's worth, since
    BufferedResponseBody emits the whole body in one shot)."""
    var tok = CancellationToken.never()
    var frame = resp.body.poll_frame[PerCoreAsyncRuntime[NoopSink]](
        reactor, tok,
    )
    if frame.kind == BODY_FRAME_KIND_END:
        return List[UInt8]()
    if frame.kind != BODY_FRAME_KIND_DATA:
        raise Error("expected DATA or END frame")
    var bytes_out = frame.take_data_chunk()
    return bytes_out^


# =============================================================================
# Acceptance test (d-i) — head returns ObjectMetadata.
# =============================================================================


def test_head_returns_metadata() raises:
    """ScriptedObjectStoreHttp.head returns ObjectMetadata with all
    fields extracted: status, content-length, etag, content-type,
    last-modified."""
    var conformer = ScriptedObjectStoreHttp.new()
    conformer.add_head_response(
        url_str=String("https://bucket.example.com/object"),
        status=200,
        content_length=Int64(4096),
        content_type=String("application/octet-stream"),
        etag=String("\"abc123\""),
        last_modified=String("Mon, 22 May 2026 12:00:00 GMT"),
    )

    var reactor = _make_reactor()
    var url = Url.parse(String("https://bucket.example.com/object"))
    var meta = conformer.head[PerCoreAsyncRuntime[NoopSink]](
        url^, reactor,
    )
    assert_equal(meta.status, 200)
    assert_equal(meta.content_length, Int64(4096))
    assert_equal(meta.content_type, String("application/octet-stream"))
    assert_equal(meta.etag, String("\"abc123\""))
    assert_equal(meta.last_modified, String("Mon, 22 May 2026 12:00:00 GMT"))


def test_head_missing_metadata_fields_handled() raises:
    """ObjectMetadata.from_response gracefully handles missing fields:
    content_length=-1, content_type=empty, etag=empty,
    last_modified=empty."""
    var conformer = ScriptedObjectStoreHttp.new()
    conformer.add_head_response(
        url_str=String("https://bucket.example.com/sparse"),
        status=200,
        content_length=Int64(-1),
        content_type=String(),
        etag=String(),
        last_modified=String(),
    )

    var reactor = _make_reactor()
    var url = Url.parse(String("https://bucket.example.com/sparse"))
    var meta = conformer.head[PerCoreAsyncRuntime[NoopSink]](
        url^, reactor,
    )
    assert_equal(meta.status, 200)
    assert_equal(meta.content_length, Int64(-1))
    assert_equal(meta.content_type.byte_length(), 0)
    assert_equal(meta.etag.byte_length(), 0)
    assert_equal(meta.last_modified.byte_length(), 0)


# =============================================================================
# Acceptance test (d-ii) — get_range returns correct byte slice.
# =============================================================================


def test_get_range_returns_correct_bytes() raises:
    """Pattern body [0..255]. Request bytes=10-19 (10 bytes).
    Returned body is [10, 11, ..., 19]."""
    var conformer = ScriptedObjectStoreHttp.new()
    var pattern = _make_pattern_body(256)
    conformer.add_get_range_response(
        url_str=String("https://bucket.example.com/object"),
        status=206,
        body=pattern^,
    )

    var reactor = _make_reactor()
    var url = Url.parse(String("https://bucket.example.com/object"))
    var resp = conformer.get_range[PerCoreAsyncRuntime[NoopSink]](
        url^, Int64(10), Int64(19), reactor,
    )
    assert_equal(Int(resp.status), 206)
    var body_bytes = _drain_body(resp, reactor)
    assert_equal(body_bytes.__len__(), 10)
    var i = 0
    while i < 10:
        assert_equal(Int(body_bytes[i]), 10 + i)
        i = i + 1


def test_get_range_open_ended() raises:
    """end=-1 means open-ended (read to EOF). Request bytes=200-
    against a 256-byte object returns bytes [200..255] (56 bytes)."""
    var conformer = ScriptedObjectStoreHttp.new()
    var pattern = _make_pattern_body(256)
    conformer.add_get_range_response(
        url_str=String("https://bucket.example.com/object"),
        status=206,
        body=pattern^,
    )

    var reactor = _make_reactor()
    var url = Url.parse(String("https://bucket.example.com/object"))
    var resp = conformer.get_range[PerCoreAsyncRuntime[NoopSink]](
        url^, Int64(200), Int64(-1), reactor,
    )
    assert_equal(Int(resp.status), 206)
    var body_bytes = _drain_body(resp, reactor)
    assert_equal(body_bytes.__len__(), 56)
    assert_equal(Int(body_bytes[0]), 200)
    assert_equal(Int(body_bytes[55]), 255)


# =============================================================================
# Acceptance test (d-iii) — get_ranges fan-out correctness.
# =============================================================================


def test_get_ranges_fanout_4_ranges_correct() raises:
    """4 ranges over a 1024-byte pattern body. Each range gets its
    correct bytes back, ranges are returned in order."""
    var conformer = ScriptedObjectStoreHttp.new()
    var pattern = _make_pattern_body(1024)
    conformer.add_get_range_response(
        url_str=String("https://bucket.example.com/big-object"),
        status=206,
        body=pattern^,
    )

    var reactor = _make_reactor()
    var url = Url.parse(String("https://bucket.example.com/big-object"))
    var ranges = List[ByteRange]()
    ranges.append(ByteRange.closed(Int64(0), Int64(99)))      # 100 bytes
    ranges.append(ByteRange.closed(Int64(100), Int64(199)))   # 100 bytes
    ranges.append(ByteRange.closed(Int64(500), Int64(599)))   # 100 bytes
    ranges.append(ByteRange.closed(Int64(1000), Int64(1023))) # 24 bytes
    var result = conformer.get_ranges[PerCoreAsyncRuntime[NoopSink]](
        url^, ranges^, 4, reactor,
    )
    assert_equal(result.count(), 4)
    # Range 0: bytes 0..99, expected bytes [0, 1, ..., 99].
    assert_equal(Int(result.responses[0].status), 206)
    var b0 = _drain_body(result.responses[0], reactor)
    assert_equal(b0.__len__(), 100)
    assert_equal(Int(b0[0]), 0)
    assert_equal(Int(b0[99]), 99)
    # Range 1: bytes 100..199, expected bytes [100, ..., 199].
    var b1 = _drain_body(result.responses[1], reactor)
    assert_equal(b1.__len__(), 100)
    assert_equal(Int(b1[0]), 100)
    assert_equal(Int(b1[99]), 199)
    # Range 2: bytes 500..599 — pattern wraps mod 256.
    var b2 = _drain_body(result.responses[2], reactor)
    assert_equal(b2.__len__(), 100)
    assert_equal(Int(b2[0]), 500 & 0xFF)  # = 244
    assert_equal(Int(b2[99]), 599 & 0xFF)  # = 87
    # Range 3: bytes 1000..1023, 24 bytes.
    var b3 = _drain_body(result.responses[3], reactor)
    assert_equal(b3.__len__(), 24)
    assert_equal(Int(b3[0]), 1000 & 0xFF)
    assert_equal(Int(b3[23]), 1023 & 0xFF)


# =============================================================================
# call_count diagnostic.
# =============================================================================


def test_call_count_increments() raises:
    """head + get_range + get_ranges(3 ranges) = 5 total calls."""
    var conformer = ScriptedObjectStoreHttp.new()
    conformer.add_head_response(
        url_str=String("http://x.test/o"),
        status=200,
        content_length=Int64(100),
        content_type=String(),
        etag=String(),
        last_modified=String(),
    )
    conformer.add_get_range_response(
        url_str=String("http://x.test/o"),
        status=206,
        body=_make_pattern_body(100),
    )

    var reactor = _make_reactor()
    var url1 = Url.parse(String("http://x.test/o"))
    var _meta = conformer.head[PerCoreAsyncRuntime[NoopSink]](url1^, reactor)
    assert_equal(conformer.call_count(), 1)

    var url2 = Url.parse(String("http://x.test/o"))
    var _resp = conformer.get_range[PerCoreAsyncRuntime[NoopSink]](
        url2^, Int64(0), Int64(9), reactor,
    )
    assert_equal(conformer.call_count(), 2)

    var url3 = Url.parse(String("http://x.test/o"))
    var ranges = List[ByteRange]()
    ranges.append(ByteRange.closed(Int64(10), Int64(19)))
    ranges.append(ByteRange.closed(Int64(20), Int64(29)))
    ranges.append(ByteRange.closed(Int64(30), Int64(39)))
    var _fan = conformer.get_ranges[PerCoreAsyncRuntime[NoopSink]](
        url3^, ranges^, 3, reactor,
    )
    # get_ranges in internally calls get_range N times.
    assert_equal(conformer.call_count(), 5)


# =============================================================================
# Error path: missing URL.
# =============================================================================


def test_head_missing_url_raises() raises:
    var conformer = ScriptedObjectStoreHttp.new()
    var reactor = _make_reactor()
    var url = Url.parse(String("https://nonexistent.example.com/x"))

    var raised = False
    try:
        var _meta = conformer.head[PerCoreAsyncRuntime[NoopSink]](
            url^, reactor,
        )
    except e:
        var msg = String(e)
        assert_true("CONNECT_FAILED" in msg)
        raised = True
    assert_true(raised, "missing URL must raise")


def main() raises:
    test_head_returns_metadata()
    test_head_missing_metadata_fields_handled()
    test_get_range_returns_correct_bytes()
    test_get_range_open_ended()
    test_get_ranges_fanout_4_ranges_correct()
    test_call_count_increments()
    test_head_missing_url_raises()
    print("[OK] test_objectstore_http — all 7 tests passed")
