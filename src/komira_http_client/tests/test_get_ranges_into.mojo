"""get_ranges_into scatter-write API.

Verifies the ObjectStoreHttp.get_ranges_into method:

1. 4-range scatter-write into a pre-allocated dst buffer; each range's
   bytes land at the correct offset.
2. Bytes-identical to the legacy get_ranges (the convenience wrapper).
3. Open-ended range (end < 0) raises HttpError[URL_INVALID].
4. dst_offsets length mismatch raises HttpError[URL_INVALID].
5. dst_offset + range_length exceeding dst capacity raises
   HttpError[URL_INVALID].

Uses ScriptedObjectStoreHttp to drive deterministic responses.
"""

from std.sys import CompilationTarget

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_http_client.objectstore_http import (
    ByteRange,
    ScriptedObjectStoreHttp,
)
from komira_http_client.url import Url


def _b(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var n = len(bs)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        out.append(bs[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _check_str_contains(s: String, needle: String) -> Bool:
    var sn = s.byte_length()
    var pn = needle.byte_length()
    if pn > sn:
        return False
    if pn == 0:
        return True
    var sb = s.as_bytes()
    var pb = needle.as_bytes()
    var i = 0
    while i <= sn - pn:
        var j = 0
        var is_match = True
        while j < pn:
            if sb[i + j] != pb[j]:
                is_match = False
                break
            j = j + 1
        if is_match:
            return True
        i = i + 1
    return False


def _setup_scripted() raises -> ScriptedObjectStoreHttp:
    """Build a ScriptedObjectStoreHttp pre-loaded with one canned
    GET response — 26 bytes of the alphabet 'abc...z'. Caller's
    get_range calls slice into this."""
    var oss = ScriptedObjectStoreHttp.new()
    var url_str = String("https://test/obj.bin")
    # 26-byte alphabet body.
    var body = _b(String("abcdefghijklmnopqrstuvwxyz"))
    oss.add_get_range_response(url_str, 206, body^)
    return oss^


# =============================================================================
# Test 1 — 4-range scatter-write correctness.
# =============================================================================


def test_get_ranges_into_4_ranges_scatter() raises:
    var oss = _setup_scripted()
    var reactor = _make_reactor()

    # 4 ranges of varying sizes:
    #   range[0] = bytes 0..2  (3 bytes: "abc")
    #   range[1] = bytes 10..12 (3 bytes: "klm")
    #   range[2] = bytes 23..25 (3 bytes: "xyz")
    #   range[3] = bytes 5..7  (3 bytes: "fgh")
    var ranges = List[ByteRange]()
    ranges.append(ByteRange.closed(Int64(0), Int64(2)))
    ranges.append(ByteRange.closed(Int64(10), Int64(12)))
    ranges.append(ByteRange.closed(Int64(23), Int64(25)))
    ranges.append(ByteRange.closed(Int64(5), Int64(7)))

    # dst is 16 bytes pre-zeroed; offsets [0, 3, 6, 9] pack the
    # 12 response bytes into the first 12 dst slots.
    var dst_buf = List[UInt8]()
    var i = 0
    while i < 16:
        dst_buf.append(UInt8(0))
        i = i + 1
    var dst_offsets = List[Int]()
    dst_offsets.append(0)
    dst_offsets.append(3)
    dst_offsets.append(6)
    dst_offsets.append(9)

    var dst_span = Span[UInt8](dst_buf)
    var url = Url.parse(String("https://test/obj.bin"))
    oss.get_ranges_into[PerCoreAsyncRuntime[NoopSink]](
        url^, ranges^, dst_span, dst_offsets^, 4, reactor,
    )

    # Verify scatter-write.
    var expected_str = String("abcklmxyzfgh")
    var expected = _b(expected_str)
    var ei = 0
    while ei < expected.__len__():
        assert_equal(
            Int(dst_buf[ei]),
            Int(expected[ei]),
            String("byte ") + String(ei),
        )
        ei = ei + 1
    # Trailing 4 bytes are untouched (zero).
    var ti = 12
    while ti < 16:
        assert_equal(Int(dst_buf[ti]), 0, String("trail byte ") + String(ti))
        ti = ti + 1


# =============================================================================
# Test 2 — get_ranges_into bytes-identical to get_ranges.
# =============================================================================


def test_get_ranges_into_matches_get_ranges() raises:
    var oss1 = _setup_scripted()
    var oss2 = _setup_scripted()
    var reactor = _make_reactor()

    var ranges = List[ByteRange]()
    ranges.append(ByteRange.closed(Int64(0), Int64(4)))
    ranges.append(ByteRange.closed(Int64(10), Int64(14)))

    # Convenience path: get_ranges.
    var url1 = Url.parse(String("https://test/obj.bin"))
    var ranges_copy1 = List[ByteRange]()
    var ri = 0
    while ri < ranges.__len__():
        ranges_copy1.append(ranges[ri])
        ri = ri + 1
    var result_convenience = oss1.get_ranges[PerCoreAsyncRuntime[NoopSink]](
        url1^, ranges_copy1^, 2, reactor,
    )
    # Extract responses[0].body.bytes_ref and responses[1].body.bytes_ref
    # and concatenate.
    var conv_bytes = List[UInt8]()
    var ci = 0
    while ci < 2:
        ref body = result_convenience.responses[ci].body.bytes_ref()
        var bi = 0
        while bi < body.__len__():
            conv_bytes.append(body[bi])
            bi = bi + 1
        ci = ci + 1

    # Scatter-write path: get_ranges_into.
    var dst_buf = List[UInt8]()
    var di = 0
    while di < 16:
        dst_buf.append(UInt8(0))
        di = di + 1
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(5)
    var url2 = Url.parse(String("https://test/obj.bin"))
    oss2.get_ranges_into[PerCoreAsyncRuntime[NoopSink]](
        url2^, ranges^, Span[UInt8](dst_buf), offsets^, 2, reactor,
    )
    # dst_buf[0:10] should match conv_bytes byte-for-byte.
    assert_equal(conv_bytes.__len__(), 10)
    var i = 0
    while i < 10:
        assert_equal(
            Int(conv_bytes[i]),
            Int(dst_buf[i]),
            String("identical byte ") + String(i),
        )
        i = i + 1


# =============================================================================
# Test 3 — open-ended range raises.
# =============================================================================


def test_get_ranges_into_open_ended_raises() raises:
    var oss = _setup_scripted()
    var reactor = _make_reactor()

    var ranges = List[ByteRange]()
    ranges.append(ByteRange.open(Int64(0)))  # end = -1, open-ended

    var dst_buf = List[UInt8]()
    var i = 0
    while i < 16:
        dst_buf.append(UInt8(0))
        i = i + 1
    var offsets = List[Int]()
    offsets.append(0)

    var url = Url.parse(String("https://test/obj.bin"))
    var raised = False
    try:
        oss.get_ranges_into[PerCoreAsyncRuntime[NoopSink]](
            url^, ranges^, Span[UInt8](dst_buf), offsets^, 1, reactor,
        )
    except e:
        var msg = String(e)
        assert_true(
            _check_str_contains(msg, String("HttpError[URL_INVALID]")),
            String("expected URL_INVALID prefix; got: ") + msg,
        )
        raised = True
    assert_true(raised, "open-ended range must raise")


# =============================================================================
# Test 4 — dst_offsets length mismatch raises.
# =============================================================================


def test_get_ranges_into_offsets_mismatch_raises() raises:
    var oss = _setup_scripted()
    var reactor = _make_reactor()

    var ranges = List[ByteRange]()
    ranges.append(ByteRange.closed(Int64(0), Int64(2)))
    ranges.append(ByteRange.closed(Int64(3), Int64(5)))

    var dst_buf = List[UInt8]()
    var i = 0
    while i < 16:
        dst_buf.append(UInt8(0))
        i = i + 1
    # ONLY ONE offset for TWO ranges — mismatch.
    var offsets = List[Int]()
    offsets.append(0)

    var url = Url.parse(String("https://test/obj.bin"))
    var raised = False
    try:
        oss.get_ranges_into[PerCoreAsyncRuntime[NoopSink]](
            url^, ranges^, Span[UInt8](dst_buf), offsets^, 1, reactor,
        )
    except e:
        var msg = String(e)
        assert_true(
            _check_str_contains(msg, String("HttpError[URL_INVALID]")),
        )
        assert_true(_check_str_contains(msg, String("dst_offsets length")))
        raised = True
    assert_true(raised, "length mismatch must raise")


# =============================================================================
# Test 5 — dst capacity exceeded raises.
# =============================================================================


def test_get_ranges_into_dst_overflow_raises() raises:
    var oss = _setup_scripted()
    var reactor = _make_reactor()

    var ranges = List[ByteRange]()
    ranges.append(ByteRange.closed(Int64(0), Int64(9)))  # 10 bytes

    # dst is only 5 bytes — overflow.
    var dst_buf = List[UInt8]()
    var i = 0
    while i < 5:
        dst_buf.append(UInt8(0))
        i = i + 1
    var offsets = List[Int]()
    offsets.append(0)

    var url = Url.parse(String("https://test/obj.bin"))
    var raised = False
    try:
        oss.get_ranges_into[PerCoreAsyncRuntime[NoopSink]](
            url^, ranges^, Span[UInt8](dst_buf), offsets^, 1, reactor,
        )
    except e:
        var msg = String(e)
        assert_true(
            _check_str_contains(msg, String("HttpError[URL_INVALID]")),
        )
        assert_true(_check_str_contains(msg, String("dst_offsets[")))
        raised = True
    assert_true(raised, "dst overflow must raise")


def main() raises:
    test_get_ranges_into_4_ranges_scatter()
    test_get_ranges_into_matches_get_ranges()
    test_get_ranges_into_open_ended_raises()
    test_get_ranges_into_offsets_mismatch_raises()
    test_get_ranges_into_dst_overflow_raises()
    print("[OK] test_get_ranges_into — all 5 tests passed")
