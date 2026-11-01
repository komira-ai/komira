# =============================================================================
# src/komira_http_core/tests/test_cov_scripted_faults.mojo
# =============================================================================
#
# The fault arms of the scripted transport (transport/scripted.mojo) that the
# client package's tests lean on, held here, in the package that ships them:
#
#   * offset-triggered faults: queue_pending_at, arm_error_at, arm_eof_at
#     each fire after EXACTLY `offset` script bytes, however large the read
#     buffer (the clamp), once, in the order Pending, Error, Eof;
#   * set_pending_after_script: a stalled peer is Pending n times, then Eof;
#   * the write side: arm_error, queue_write_pending, arm_write_error_after
#     (capturing nothing), set_max_write_per_call (a short write), and the
#     shared capture outliving the stream;
#   * the connector's dial faults: EINPROGRESS dials then SO_ERROR, a dial
#     that never resolves, a refused dial, each one-shot and none consuming
#     the armed stream; arm_next streams served oldest-first;
#   * unread rewinds only the bytes just handed out, and the connector's
#     TLS claim, arm replacement and dial-host record.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_core.transport.io_stream import StreamIo
from komira_http_core.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)

comptime RT = PerCoreAsyncRuntime[NoopSink]


def _reactor() raises -> Reactor[NoopSink]:
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)


def _script(n: Int) -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(n):
        s.append(UInt8(65 + i % 26))
    return s^


def _read(mut s: ScriptedStream, mut r: Reactor[NoopSink], cap: Int) raises -> StreamIo:
    var buf = List[UInt8](length=cap, fill=UInt8(0))
    return s.try_read[RT](reactor=r, dst=Span[UInt8](buf))


def test_offset_faults_fire_at_their_offset() raises:
    """Pending at 3 (twice), Error at 5, Eof at 8, read through a 64-byte
    buffer: each read stops at the next armed offset and each fault fires
    there exactly once, in that order."""
    var s = ScriptedStream.from_read_script(_script(12))
    s.queue_pending_at(3, 2)
    s.arm_error_at(5, Int64(104))
    s.arm_eof_at(8)
    var r = _reactor()
    var a = _read(s, r, 64)
    assert_true(a.is_ready())
    assert_equal(a.n_bytes(), Int64(3))
    var p1 = _read(s, r, 64)
    assert_true(p1.is_pending())
    assert_equal(p1.pending_token(), Int64(3))
    var p2 = _read(s, r, 64)
    assert_true(p2.is_pending())
    var b = _read(s, r, 64)
    assert_true(b.is_ready())
    assert_equal(b.n_bytes(), Int64(2))
    var e = _read(s, r, 64)
    assert_true(e.is_error())
    assert_equal(e.errno(), Int64(104))
    var c = _read(s, r, 64)
    assert_true(c.is_ready())
    assert_equal(c.n_bytes(), Int64(3))
    var f = _read(s, r, 64)
    assert_true(f.is_eof())
    # Each fault was one-shot: the rest of the script is still served.
    var d = _read(s, r, 64)
    assert_true(d.is_ready())
    assert_equal(d.n_bytes(), Int64(4))
    assert_equal(s.read_cursor(), 12)
    assert_equal(s.try_read_call_count(), 8)


def test_offset_clamp_order_reversed() raises:
    """Arming in the other order (Eof nearest, Pending farthest) clamps the
    first read to the Eof offset: the clamp takes the nearest offset of
    the three, not the first armed."""
    var s = ScriptedStream.from_read_script(_script(10))
    s.queue_pending_at(7, 1)
    s.arm_error_at(6, Int64(32))
    s.arm_eof_at(2)
    var r = _reactor()
    var a = _read(s, r, 64)
    assert_equal(a.n_bytes(), Int64(2))
    assert_true(_read(s, r, 64).is_eof())
    var b = _read(s, r, 64)
    assert_equal(b.n_bytes(), Int64(4))
    var e = _read(s, r, 64)
    assert_true(e.is_error())
    assert_equal(e.errno(), Int64(32))
    var c = _read(s, r, 64)
    assert_equal(c.n_bytes(), Int64(1))
    assert_true(_read(s, r, 64).is_pending())
    var d = _read(s, r, 64)
    assert_equal(d.n_bytes(), Int64(3))


def test_pending_after_script() raises:
    """Script exhausted, peer silent: Pending (token = cursor) twice, then
    Eof."""
    var s = ScriptedStream.from_read_script(_script(4))
    s.set_pending_after_script(2)
    var r = _reactor()
    assert_equal(_read(s, r, 64).n_bytes(), Int64(4))
    var p = _read(s, r, 64)
    assert_true(p.is_pending())
    assert_equal(p.pending_token(), Int64(4))
    assert_true(_read(s, r, 64).is_pending())
    assert_true(_read(s, r, 64).is_eof())


def test_write_faults() raises:
    """arm_error and queue_write_pending fire before any byte is taken; a
    short write takes max_write_per_call bytes; arm_write_error_after fails
    the write that follows N served ones, capturing nothing."""
    var s = ScriptedStream.empty()
    var r = _reactor()
    var src = _script(10)
    s.arm_error(Int64(32))
    var e = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    assert_true(e.is_error())
    assert_equal(e.errno(), Int64(32))
    assert_equal(s.capture_len(), 0)
    s.queue_write_pending(1)
    var p = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    assert_true(p.is_pending())
    assert_equal(s.capture_len(), 0)
    s.set_max_write_per_call(4)
    s.arm_write_error_after(Int64(104), 2)
    var w1 = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    assert_true(w1.is_ready())
    assert_equal(w1.n_bytes(), Int64(4))
    var w2 = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    assert_equal(w2.n_bytes(), Int64(4))
    assert_equal(s.capture_len(), 8)
    var w3 = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    assert_true(w3.is_error())
    assert_equal(w3.errno(), Int64(104))
    assert_equal(s.capture_len(), 8)
    # One-shot: the next write is served again, whole once unclamped.
    s.set_max_write_per_call(0)
    var w4 = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    assert_equal(w4.n_bytes(), Int64(10))
    assert_equal(s.capture_len(), 18)
    assert_equal(s.try_write_call_count(), 6)


def test_shared_capture_outlives_stream() raises:
    """from_read_script_with_capture mirrors each written byte into the
    shared buffer, which keeps them after the stream is dropped."""
    var shared = ArcPointer[List[UInt8]](List[UInt8]())
    var r = _reactor()
    var src = _script(5)
    var s = ScriptedStream.from_read_script_with_capture(_script(0), shared)
    s.set_max_write_per_call(3)
    _ = s.try_write[RT](reactor=r, src=Span[UInt8](src))
    _ = s^
    assert_equal(len(shared[]), 3)
    for i in range(3):
        assert_equal(Int(shared[][i]), Int(src[i]))


def _dial(mut c: ScriptedConnector, mut r: Reactor[NoopSink]) raises -> ScriptedStream:
    return c.connect[RT](reactor=r, ip_be=UInt32(0), port=UInt16(80))


def _dial_error(mut c: ScriptedConnector, mut r: Reactor[NoopSink]) -> String:
    try:
        var _s = _dial(c, r)
    except e:
        return String(e)
    return String("no error")


def test_connect_faults_then_armed_stream() raises:
    """Two EINPROGRESS dials, the SO_ERROR one, a never-resolving one and a
    refused one each raise their own message, once, and leave the armed
    stream for the dial after them; then arm_next streams come oldest
    first, and an exhausted connector raises."""
    var c = ScriptedConnector.with_stream(ScriptedStream.from_read_script(_script(1)))
    c.arm_next(ScriptedStream.from_read_script(_script(2)))
    c.arm_next(ScriptedStream.from_read_script(_script(3)))
    var r = _reactor()
    c.arm_connect_in_progress_then_error(2, Int64(111))
    var m1 = _dial_error(c, r)
    assert_true("EINPROGRESS" in m1, m1)
    assert_true("dial #1" in m1, m1)
    var m2 = _dial_error(c, r)
    assert_true("EINPROGRESS" in m2, m2)
    var m3 = _dial_error(c, r)
    assert_true("SO_ERROR errno=111" in m3, m3)
    c.arm_connect_never_resolves()
    var m4 = _dial_error(c, r)
    assert_true("never resolved" in m4, m4)
    assert_true("dial #4" in m4, m4)
    c.arm_connect_error(Int64(113))
    var m5 = _dial_error(c, r)
    assert_true("connect errno=113" in m5, m5)
    assert_true("dial #5" in m5, m5)
    var s1 = _dial(c, r)
    assert_equal(s1.read_remaining(), 1)
    var s2 = _dial(c, r)
    assert_equal(s2.read_remaining(), 2)
    var s3 = _dial(c, r)
    assert_equal(s3.read_remaining(), 3)
    var m6 = _dial_error(c, r)
    assert_true("no stream armed for dial #9" in m6, m6)
    assert_equal(c.connect_call_count(), 9)


def test_unread_rewinds_only_what_was_read() raises:
    """unread of the tail just handed out rewinds the cursor and the bytes
    are served again; more bytes than were read, or bytes that differ from
    the script, raise and leave the cursor where it was."""
    var s = ScriptedStream.from_read_script(_script(6))
    var r = _reactor()
    var buf = List[UInt8](length=4, fill=UInt8(0))
    _ = s.try_read[RT](reactor=r, dst=Span[UInt8](buf))
    assert_equal(s.read_cursor(), 4)
    var none = List[UInt8]()
    s.unread(Span[UInt8](none))
    assert_equal(s.read_cursor(), 4)
    var too_many = _script(5)
    var raised = String()
    try:
        s.unread(Span[UInt8](too_many))
    except e:
        raised = String(e)
    assert_true("only 4 have been read" in raised, raised)
    assert_equal(s.read_cursor(), 4)
    var wrong = List[UInt8]()
    wrong.append(buf[2])
    wrong.append(UInt8(0x7A))
    raised = String()
    try:
        s.unread(Span[UInt8](wrong))
    except e:
        raised = String(e)
    assert_true("first mismatch at offset 1 of 2" in raised, raised)
    assert_equal(s.read_cursor(), 4)
    var tail = List[UInt8]()
    tail.append(buf[2])
    tail.append(buf[3])
    s.unread(Span[UInt8](tail))
    assert_equal(s.read_cursor(), 2)
    assert_equal(s.read_remaining(), 4)
    var again = List[UInt8](length=8, fill=UInt8(0))
    var a = s.try_read[RT](reactor=r, dst=Span[UInt8](again))
    assert_equal(a.n_bytes(), Int64(4))
    assert_equal(Int(again[0]), Int(buf[2]))
    assert_equal(Int(again[1]), Int(buf[3]))
    s^.close()


def test_connector_surface() raises:
    """with_stream_tls claims TLS and with_stream does not; arm replaces an
    armed stream; dial hosts are kept in push order and an index out of
    range raises."""
    var plain = ScriptedConnector.with_stream(ScriptedStream.empty())
    assert_false(plain.is_tls())
    var tls = ScriptedConnector.with_stream_tls(ScriptedStream.empty())
    assert_true(tls.is_tls())
    var c = ScriptedConnector()
    c.arm(ScriptedStream.from_read_script(_script(1)))
    c.arm(ScriptedStream.from_read_script(_script(2)))
    var r = _reactor()
    var got = _dial(c, r)
    assert_equal(got.read_remaining(), 2)
    var m = _dial_error(c, r)
    assert_true("no stream armed" in m, m)
    assert_equal(c.dial_hosts_len(), 0)
    c.set_dial_host(String("a.example.com"))
    c.set_dial_host(String("b.example.com"))
    assert_equal(c.dial_hosts_len(), 2)
    assert_equal(c.dial_host_at(0), String("a.example.com"))
    assert_equal(c.dial_host_at(1), String("b.example.com"))
    for bad in range(-1, 3, 3):
        var msg = String()
        try:
            _ = c.dial_host_at(bad)
        except e:
            msg = String(e)
        assert_true("out of range" in msg, String(bad) + ": " + msg)


def main() raises:
    test_offset_faults_fire_at_their_offset()
    test_offset_clamp_order_reversed()
    test_pending_after_script()
    test_write_faults()
    test_shared_capture_outlives_stream()
    test_connect_faults_then_armed_stream()
    test_unread_rewinds_only_what_was_read()
    test_connector_surface()
    print("PASS test_cov_scripted_faults")
