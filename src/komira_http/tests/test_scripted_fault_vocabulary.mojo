# =============================================================================
# src/komira_http/tests/test_scripted_fault_vocabulary.mojo
# =============================================================================
#
# THE FAULT VOCABULARY OF THE SCRIPTED TRANSPORT SEAM.
#
# ⭐ WHY THIS FILE EXISTS. A production defect like
# `HttpError[EOF_MID_RESPONSE: chunked body unterminated]` can go untested for a
# STRUCTURAL reason rather than an oversight: a scripted transport seam that
# CANNOT EXPRESS IT. Coverage by file count is not coverage.
#
# A minimal scripted vocabulary is not enough:
#
#   * One-shot EOF / error flags read at the very TOP of `try_read` can only be
#     placed at byte offset ZERO (the next call); "37 bytes of a 100-byte body,
#     then RST" is not expressible.
#   * `queue_read_pending(n)` alone covers only the FIRST n reads, so the
#     park/wake path is exercised ONLY at the START of a response — which is
#     exactly where a production hang is NOT.
#   * Without `max_write_per_call` `try_write` always accepts the whole `src`,
#     so no test can drive a writer through a SHORT WRITE — the class of a
#     positive partial rc discarded as blocked, which otherwise needs a real
#     socketpair with a shrunken `SO_SNDBUF` to find.
#   * An armed fault with no test caller proves nothing about the code it arms.
#   * A `ScriptedConnector.connect` that CANNOT FAIL (it returns an armed stream
#     or raises "no stream armed", a TEST BUG signal) leaves ECONNREFUSED,
#     connect timeout, SO_ERROR recovery and a half-open connect untestable.
#
# Every test below asserts one of those capabilities. The first test PINS the
# baseline vocabulary itself.
#
# Idiom: matches the neighbouring `test_scripted_byte_exchange.mojo` (helpers,
# `PerCoreAsyncRuntime[NoopSink]`, explicit `try_read`/`try_write` parameter
# lists) and `test_state_machine.mojo` (the OS-correct reactor + the real
# `OutboundDriver.run` drive).
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.body import BytesBody
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import (
    method_get,
    method_post,
    serialize_request_head,
)
from komira_http.client.response_body import RecvRingBody, collect_body
from komira_http.client.state_machine import (
    ClientResponse,
    OutboundDriver,
    OUTBOUND_STATE_DONE,
)
from komira_http.client.url import Url
from komira_http.transport.io_stream import StreamIo
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# Helpers — same shapes as the two neighbouring test files.
# =============================================================================


def _mock_reactor() raises -> Reactor[NoopSink]:
    """BACKEND_MOCK reactor for the pure-fixture tests (no fd allocation).
    The scripted stream ignores the reactor entirely."""
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)


def _os_reactor() raises -> Reactor[NoopSink]:
    """A CONSTRUCTIBLE reactor for the tests that drive the real
    `OutboundDriver` — its park path needs the OS-correct backend
    (`test_state_machine.mojo` uses exactly this)."""
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _counting_script(n: Int) -> List[UInt8]:
    """`n` bytes whose value is their own index mod 251 — a PRIME modulus, so
    no offset assertion can pass by accident against a repeating pattern that
    happens to align with a power-of-two read size."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        out.append(UInt8(i % 251))
        i = i + 1
    return out^


def _make_scratch() -> List[UInt8]:
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _drain_until_fault(
    mut stream: ScriptedStream,
    chunk: Int,
    cap: Int,
    mut got: List[UInt8],
) raises -> StreamIo:
    """Read from `stream` in `chunk`-byte requests until it returns anything
    that is not Ready, appending every delivered byte to `got`, and RETURN the
    terminal outcome.

    ⚠ The terminal outcome is returned rather than left on the stream because
    a `try_read` that returns it has ALREADY CONSUMED it — these faults are
    one-shot. A helper that swallowed it would make the next read look like
    the fault, which is a strictly weaker assertion (it cannot tell "the fault
    fired at offset N" from "a second, later fault fired").

    `cap` bounds the loop so a fixture bug is a FAILED test rather than a hung
    one."""
    var reactor = _mock_reactor()
    var buf = List[UInt8]()
    var j = 0
    while j < chunk:
        buf.append(UInt8(0))
        j = j + 1
    var iters = 0
    while iters < cap:
        iters = iters + 1
        var dst = Span[UInt8](buf)
        var r = stream.try_read[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, dst=dst,
        )
        if not r.is_ready():
            return r^
        var n = Int(r.n_bytes())
        var k = 0
        while k < n:
            got.append(buf[k])
            k = k + 1
    raise Error(
        "_drain_until_fault: no non-Ready outcome within "
        + String(cap)
        + " reads — the armed fault never fired"
    )


def _one_read(mut stream: ScriptedStream, chunk: Int) raises -> StreamIo:
    var reactor = _mock_reactor()
    var buf = List[UInt8]()
    var j = 0
    while j < chunk:
        buf.append(UInt8(0))
        j = j + 1
    var dst = Span[UInt8](buf)
    return stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )


# =============================================================================
# CASE 1 — the MEASURED BASELINE, pinned as an assertion.
# =============================================================================


def test_baseline_one_shot_arm_eof_can_only_fire_at_offset_zero() raises:
    """PINS WHAT THE ONE-SHOT VOCABULARY CANNOT SAY.

    `arm_eof` is a one-shot flag read at the TOP of `try_read`, so on a
    100-byte script it delivers ZERO bytes and then Eof — and the script is
    still fully intact afterwards. That is a "peer closed before answering",
    NOT a truncated body, and the two are different defects with different
    dispositions (`_write_error` in `state_machine.mojo` turns on exactly this
    distinction: zero bytes off the wire is RETRYABLE_TRANSPORT, bytes-then-
    failure is deliberately NOT in the retry set).

    If this test ever fails because `arm_eof` grew an offset, DELETE it — the
    baseline it pins would no longer exist."""
    var stream = ScriptedStream.from_read_script(_counting_script(100))
    stream.arm_eof()

    var r1 = _one_read(stream, 64)
    assert_true(r1.is_eof(), "arm_eof fires on the very next call")

    # ZERO bytes were consumed — the whole script is still there.
    assert_equal(
        stream.read_remaining(), 100,
        "arm_eof consumed no script bytes: it cannot express a TRUNCATION",
    )
    var r2 = _one_read(stream, 64)
    assert_true(r2.is_ready(), "one-shot: the flag disarmed itself")
    assert_equal(Int(r2.n_bytes()), 64)


def test_baseline_queue_read_pending_covers_only_the_first_reads() raises:
    """`queue_read_pending(n)` is a LEADING counter — it cannot place a Pending
    anywhere but the start. Pinned because it is the reason the park/wake path
    was exercised only where the production hang is not."""
    var stream = ScriptedStream.from_read_script(_counting_script(40))
    stream.queue_read_pending(2)
    assert_true(_one_read(stream, 16).is_pending())
    assert_true(_one_read(stream, 16).is_pending())
    # From here on it is impossible to get another Pending out of this stream.
    assert_true(_one_read(stream, 16).is_ready())
    assert_true(_one_read(stream, 16).is_ready())
    assert_true(_one_read(stream, 16).is_ready())
    assert_true(_one_read(stream, 16).is_eof())


# =============================================================================
# CASE 2 — arm_error_at(offset, errno): an RST at a byte offset.
# =============================================================================


def test_arm_error_at_delivers_exactly_n_bytes_then_the_errno() raises:
    """THE SELF-TEST NAMED IN THE SLICE: a 100-byte script with
    `arm_error_at(37, ECONNRESET)` delivers EXACTLY 37 bytes and then that
    errno.

    "Exactly" is the load-bearing word. A fault that lands somewhere after the
    offset — because one oversized read straddled the boundary — cannot carry
    an assertion about WHERE the peer died, which is the whole question a
    truncation bug asks."""
    var stream = ScriptedStream.from_read_script(_counting_script(100))
    stream.arm_error_at(37, Int64(104))  # ECONNRESET

    # Deliberately ask for 64 bytes a time: a read that did NOT clamp would
    # deliver 64 and blow straight past offset 37.
    var got = List[UInt8]()
    var fault = _drain_until_fault(stream, 64, 512, got)
    assert_equal(
        len(got), 37,
        "arm_error_at(37) must deliver EXACTLY 37 bytes before the fault",
    )
    var i = 0
    while i < 37:
        assert_equal(
            Int(got[i]), Int(UInt8(i % 251)),
            "delivered byte must be script byte",
        )
        i = i + 1

    assert_true(fault.is_error(), "the 38th byte's read is an ERROR")
    assert_equal(fault.errno(), Int64(104), "and it carries ECONNRESET")


def test_arm_error_at_fires_on_a_single_oversized_read() raises:
    """The clamp, isolated: ONE read with a 4 KiB dst over a 100-byte script
    armed at 37 returns exactly 37, not 100."""
    var stream = ScriptedStream.from_read_script(_counting_script(100))
    stream.arm_error_at(37, Int64(104))
    var r = _one_read(stream, 4096)
    assert_true(r.is_ready())
    assert_equal(
        Int(r.n_bytes()), 37,
        "the read is CLAMPED to the armed offset — a fault you cannot place"
        " precisely is a fault you cannot assert on",
    )
    assert_true(_one_read(stream, 4096).is_error())


def test_arm_error_at_zero_is_the_one_shot_shape() raises:
    """`arm_error_at(0, e)` degenerates to the pre-existing `arm_error(e)`
    behaviour — the vocabulary EXTENDS the old one rather than forking it."""
    var stream = ScriptedStream.from_read_script(_counting_script(100))
    stream.arm_error_at(0, Int64(32))  # EPIPE
    var r = _one_read(stream, 64)
    assert_true(r.is_error())
    assert_equal(r.errno(), Int64(32))
    assert_equal(stream.read_remaining(), 100, "no bytes consumed at offset 0")


# =============================================================================
# CASE 2b — arm_eof_at(offset): the TRUNCATED body.
# =============================================================================


def test_arm_eof_at_truncates_the_body_mid_stream() raises:
    """The production shape: a peer that half-closes after N body bytes. This
    is what `EOF_MID_RESPONSE` / `chunked body unterminated` IS at the
    transport layer, and it was inexpressible before `arm_eof_at`."""
    var stream = ScriptedStream.from_read_script(_counting_script(100))
    stream.arm_eof_at(50)

    var got = List[UInt8]()
    var fault = _drain_until_fault(stream, 64, 512, got)
    assert_equal(len(got), 50, "exactly 50 bytes before the half-close")
    assert_true(fault.is_eof(), "then EOF, mid-script")


def test_arm_eof_at_disarms_and_the_rest_of_the_script_survives() raises:
    """One-shot, like every other arm on this fixture: after the Eof fires the
    remaining script is readable. That is what lets a test model a peer that
    half-closes ONE response on a reused connection."""
    var stream = ScriptedStream.from_read_script(_counting_script(100))
    stream.arm_eof_at(50)
    var got = List[UInt8]()
    assert_true(_drain_until_fault(stream, 64, 512, got).is_eof())
    assert_equal(len(got), 50)
    var rest = _one_read(stream, 64)
    assert_true(rest.is_ready(), "disarmed — the tail is still scripted")
    assert_equal(Int(rest.n_bytes()), 50)
    assert_equal(stream.read_remaining(), 0)


def test_pending_wins_over_error_wins_over_eof_at_one_offset() raises:
    """PRECEDENCE, ASSERTED RATHER THAN LEFT TO BE DISCOVERED. A test WILL arm
    two faults at one offset; the documented order is Pending (transient, it
    is re-tried) then Error then Eof."""
    var stream = ScriptedStream.from_read_script(_counting_script(60))
    stream.queue_pending_at(20, 1)
    stream.arm_error_at(20, Int64(104))
    stream.arm_eof_at(20)

    var got = List[UInt8]()
    var first = _drain_until_fault(stream, 8, 128, got)
    assert_equal(len(got), 20)
    assert_true(first.is_pending(), "Pending first")
    assert_true(_one_read(stream, 8).is_error(), "then Error")
    assert_true(_one_read(stream, 8).is_eof(), "then Eof")


# =============================================================================
# CASE 3 — queue_pending_at(offset, n): a park in the MIDDLE of a body.
# =============================================================================


def test_queue_pending_at_parks_mid_body_then_resumes() raises:
    """Today the park/wake path is only ever exercised at the START of a
    response. A driver whose park bookkeeping is right on entry and wrong once
    it carries state is invisible to that. This places the park at byte 20 of
    a 40-byte script."""
    var stream = ScriptedStream.from_read_script(_counting_script(40))
    stream.queue_pending_at(20, 3)

    var got = List[UInt8]()
    var p1 = _drain_until_fault(stream, 64, 512, got)
    assert_equal(len(got), 20, "exactly 20 bytes before the mid-body park")

    assert_true(p1.is_pending(), "park #1")
    assert_true(_one_read(stream, 64).is_pending(), "park #2")
    assert_true(_one_read(stream, 64).is_pending(), "park #3")

    var rest = _one_read(stream, 64)
    assert_true(rest.is_ready(), "after n Pendings the body resumes")
    assert_equal(
        Int(rest.n_bytes()), 20,
        "and resumes with the WHOLE tail — the park must not have eaten a"
        " byte or left the cursor mid-way",
    )
    assert_true(_one_read(stream, 64).is_eof())


def test_queue_pending_at_composes_with_max_read_per_call() raises:
    """The offset is a BYTES-DELIVERED count, not a call count — so it lands
    on byte 20 whether the client reads 64 bytes at a time or 3."""
    var stream = ScriptedStream.from_read_script(_counting_script(40))
    stream.set_max_read_per_call(3)
    stream.queue_pending_at(20, 1)
    var got = List[UInt8]()
    var fault = _drain_until_fault(stream, 64, 512, got)
    assert_equal(
        len(got), 20,
        "3-byte reads still stop EXACTLY at 20 (the clamp shortens the read"
        " that would straddle the offset)",
    )
    assert_true(fault.is_pending())


# =============================================================================
# CASE 4 — set_max_write_per_call: the SHORT WRITE.
# =============================================================================


def test_max_write_per_call_reports_an_honest_partial_count() raises:
    """Without a clamp `try_write` accepts everything. A socket that accepts
    7 of 100 bytes and says so is the NORMAL case on a loaded send buffer, not
    an error path."""
    var stream = ScriptedStream.empty()
    stream.set_max_write_per_call(7)
    var reactor = _mock_reactor()
    var src = _counting_script(100)
    var r = stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=Span[UInt8](src).as_imm(),
    )
    assert_true(r.is_ready())
    assert_equal(
        Int(r.n_bytes()), 7,
        "a partial write reports the count it ACCEPTED, not the count offered",
    )
    assert_equal(
        stream.capture_len(), 7,
        "and it captured exactly that many — no silent full-accept",
    )


def test_max_write_per_call_zero_and_negative_mean_unlimited() raises:
    """Matches `set_max_read_per_call`'s documented `n <= 0 == unlimited`
    convention; a fixture whose two clamps disagreed would be a trap."""
    var stream = ScriptedStream.empty()
    stream.set_max_write_per_call(0)
    var reactor = _mock_reactor()
    var src = _counting_script(100)
    var r = stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=Span[UInt8](src).as_imm(),
    )
    assert_equal(Int(r.n_bytes()), 100)


def test_64kib_request_head_written_seven_bytes_at_a_time_is_byte_identical(
) raises:
    """⭐ THE BUG HUNT. A 64 KiB request blob driven through the REAL
    `OutboundDriver.run` write loop (`_drive_write`, which advances
    `_write_cursor` by whatever the stream accepted) against a stream that
    accepts 7 bytes per call.

    Same class as the measured TLS partial-send: a writer that treats
    `ready(n)` as "all of src was taken" truncates the request silently, and
    the server sees a short/hung request rather than an error. There is no
    other test in this repo that drives a writer through a short write."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    )
    var stream = ScriptedStream.from_read_script_with_capture(
        resp_script^, capture,
    )
    stream.set_max_write_per_call(7)

    # A ~64 KiB request head: a GET plus one enormous header value. The blob is
    # what `_drive_write` drains, so its exact composition does not matter —
    # only that it is far larger than the 7-byte clamp.
    var url = Url.parse(String("http://example.com/big"))
    var hdrs = HeaderMap()
    var filler = String()
    var f = 0
    while f < 65536:
        filler = filler + String("x")
        f = f + 1
    hdrs.append(String("X-Filler"), filler^)
    var req_bytes = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, req_bytes)
    var expected_len = len(req_bytes)
    assert_true(
        expected_len > 65536,
        "the request head must exceed 64 KiB for this to be the large-body"
        " short-write case",
    )
    var expected = req_bytes.copy()

    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _os_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200, "the exchange completed")

    # THE ASSERTION: every byte reached the wire, in order, exactly once.
    assert_equal(
        len(capture[]), expected_len,
        "a 7-byte-at-a-time write must deliver the FULL request head — a"
        " short count here is a silently truncated request",
    )
    var i = 0
    while i < expected_len:
        assert_equal(
            Int(capture[][i]), Int(expected[i]),
            "wire byte " + String(i) + " must match the serialized head:"
            " a mismatch is a write-cursor advance bug, not a short count",
        )
        i = i + 1


def test_64kib_streaming_body_written_seven_bytes_at_a_time_is_byte_identical(
) raises:
    """The SECOND write path — `_drive_write_body`, reached via
    `run_with_body`, which has its OWN `written < n` inner loop separate from
    `_drive_write`'s cursor. Two write loops means two places the short-write
    bug can live; a test that covers one covers neither of the other."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    )
    var stream = ScriptedStream.from_read_script_with_capture(
        resp_script^, capture,
    )
    stream.set_max_write_per_call(7)

    var body_bytes = _counting_script(65536)
    var expected_body = body_bytes.copy()
    var url = Url.parse(String("http://example.com/upload"))
    var hdrs = HeaderMap()
    var req_bytes = List[UInt8]()
    serialize_request_head(method_post(), url, hdrs, 65536, req_bytes)
    var head_len = len(req_bytes)

    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _os_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run_with_body[
        ScriptedStream, PerCoreAsyncRuntime[NoopSink], BytesBody,
    ](
        stream^,
        BytesBody.from_bytes(body_bytes^),
        reactor,
        Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)

    assert_equal(
        len(capture[]), head_len + 65536,
        "head + the FULL 64 KiB body must reach the wire at 7 bytes a call",
    )
    var i = 0
    while i < 65536:
        assert_equal(
            Int(capture[][head_len + i]), Int(expected_body[i]),
            "body byte " + String(i) + " mismatched — the body-write loop"
            " mis-advanced across a partial accept",
        )
        i = i + 1


# =============================================================================
# CASE 5 — queue_write_pending gets its first real caller.
# =============================================================================


def test_queue_write_pending_mid_head_then_completes_through_the_driver(
) raises:
    """`queue_write_pending` was referenced by ZERO of the repo's test files.
    An armed fault with no caller proves nothing about the code it arms.

    Here the FIRST two `try_write` calls return Pending and the request then
    completes — the shape a real `EAGAIN` on the send buffer produces. The
    assertion is that the driver re-issues rather than losing the request."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
    )
    var stream = ScriptedStream.from_read_script_with_capture(
        resp_script^, capture,
    )
    stream.queue_write_pending(2)

    var url = Url.parse(String("http://example.com/health"))
    var hdrs = HeaderMap()
    var req_bytes = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, req_bytes)
    var expected_len = len(req_bytes)
    var expected = req_bytes.copy()

    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _os_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200, "a write Pending is not a lost request")
    assert_equal(
        len(capture[]), expected_len,
        "and the whole head still reached the wire, exactly once — a"
        " re-issued write that RE-SENT the prefix would be LONGER",
    )
    var i = 0
    while i < expected_len:
        assert_equal(Int(capture[][i]), Int(expected[i]))
        i = i + 1


def test_write_pending_then_short_write_compose() raises:
    """The two write faults must compose: Pending is checked BEFORE the clamp,
    so a Pending call accepts zero bytes and the NEXT call accepts the clamp."""
    var stream = ScriptedStream.empty()
    stream.queue_write_pending(1)
    stream.set_max_write_per_call(5)
    var reactor = _mock_reactor()
    var src = _counting_script(50)
    var r1 = stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=Span[UInt8](src).as_imm(),
    )
    assert_true(r1.is_pending())
    assert_equal(stream.capture_len(), 0, "a Pending write accepts NOTHING")
    var r2 = stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=Span[UInt8](src).as_imm(),
    )
    assert_true(r2.is_ready())
    assert_equal(Int(r2.n_bytes()), 5)
    assert_equal(stream.capture_len(), 5)


# =============================================================================
# CASE 6 — connect-phase faults.
# =============================================================================


def test_arm_connect_error_makes_the_dial_refusable() raises:
    """Before this the connector COULD NOT FAIL a dial. ECONNREFUSED now
    raises a CONNECT_FAILED-shaped error carrying the errno."""
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    connector.arm_connect_error(Int64(111))  # ECONNREFUSED
    var reactor = _mock_reactor()
    var raised = False
    var detail = String()
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except e:
        raised = True
        detail = String(e)
    assert_true(raised, "an armed connect error must raise")
    assert_true(
        String("CONNECT_FAILED") in detail,
        "the raise must be CONNECT_FAILED-shaped so a client classifies it"
        " like a real dial failure; got: " + detail,
    )
    assert_true(String("111") in detail, "and must carry the errno")


def test_a_refused_dial_does_not_consume_the_armed_stream() raises:
    """THE PROPERTY THAT MAKES RETRY TESTABLE: dial 1 is refused, dial 2 gets
    the script. If the fault consumed the stream, "the client retried" and
    "the test ran out of streams" would be the same observation."""
    var script = _b(String("HTTP/1.1 204 No Content\r\n\r\n"))
    var connector = ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(script^)
    )
    connector.arm_connect_error(Int64(111))
    var reactor = _mock_reactor()

    var raised = False
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except:
        raised = True
    assert_true(raised)

    # The retry succeeds and gets the FULL script.
    var s2 = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
    )
    assert_equal(
        s2.read_remaining(), 27,
        "the refused dial consumed no script bytes",
    )
    assert_equal(
        connector.connect_call_count(), 2,
        "a FAILED dial is still a dial and must be counted — a client that"
        " retried once made two",
    )


def test_arm_connect_never_resolves_is_the_connect_timeout_outcome() raises:
    """The scripted module's header promises this. The trait is synchronous, so what is modelled is the OUTCOME
    the caller observes when the dial never resolves — which is the half a
    test can assert on."""
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    connector.arm_connect_never_resolves()
    var reactor = _mock_reactor()
    var detail = String()
    var raised = False
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except e:
        raised = True
        detail = String(e)
    assert_true(raised)
    assert_true(String("CONNECT_FAILED") in detail)
    assert_true(
        String("never resolved") in detail,
        "the detail must DISTINGUISH a hang from a refusal — they have"
        " different remedies; got: " + detail,
    )


def test_arm_connect_in_progress_then_error_models_so_error_recovery(
) raises:
    """The scripted module's other promise: a connect that
    returns IN_PROGRESS and only later reports its real failure through
    `SO_ERROR`.

    The defect this catches is a client that reads the in-progress outcome as
    SUCCESS and writes to a socket whose connect ultimately failed."""
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    connector.arm_connect_in_progress_then_error(2, Int64(110))  # ETIMEDOUT
    var reactor = _mock_reactor()

    var d1 = String()
    try:
        var _a = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except e:
        d1 = String(e)
    assert_true(String("EINPROGRESS") in d1, "dial 1 is still in flight")

    var d2 = String()
    try:
        var _b2 = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except e:
        d2 = String(e)
    assert_true(String("EINPROGRESS") in d2, "dial 2 is still in flight")

    var d3 = String()
    try:
        var _c = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(80),
        )
    except e:
        d3 = String(e)
    assert_true(
        String("SO_ERROR") in d3,
        "dial 3 reports the DEFERRED failure, which is what SO_ERROR is for;"
        " got: " + d3,
    )
    assert_true(String("110") in d3, "carrying ETIMEDOUT")


# =============================================================================
# CASE 8 — the clock-free promptness counters.
# =============================================================================


def test_try_read_call_count_counts_every_entry_including_faults() raises:
    """EVERY outcome is counted — Pending and Eof included. A counter that
    only counted successful reads would make a spinning client look idle,
    which is the failure mode this counter exists to catch."""
    var stream = ScriptedStream.from_read_script(_counting_script(10))
    assert_equal(stream.try_read_call_count(), 0)
    stream.queue_read_pending(3)
    _ = _one_read(stream, 4)   # pending
    _ = _one_read(stream, 4)   # pending
    _ = _one_read(stream, 4)   # pending
    _ = _one_read(stream, 4)   # ready 4
    _ = _one_read(stream, 4)   # ready 4
    _ = _one_read(stream, 4)   # ready 2
    _ = _one_read(stream, 4)   # eof
    assert_equal(
        stream.try_read_call_count(), 7,
        "3 Pending + 3 Ready + 1 Eof == 7 entries",
    )


def test_try_write_call_count_counts_pending_and_partial_writes() raises:
    var stream = ScriptedStream.empty()
    stream.queue_write_pending(1)
    stream.set_max_write_per_call(4)
    var reactor = _mock_reactor()
    var src = _counting_script(12)
    var i = 0
    while i < 4:
        _ = stream.try_write[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, src=Span[UInt8](src).as_imm(),
        )
        i = i + 1
    assert_equal(stream.try_write_call_count(), 4)
    assert_equal(
        stream.capture_len(), 12,
        "1 Pending + 3 accepts of 4 == 12 bytes captured",
    )


def test_promptness_is_assertable_without_a_clock() raises:
    """⭐ THE POINT OF THE COUNTERS. A client draining a 40-byte body behind a
    3-Pending mid-body park must not make unboundedly many `try_read` calls.
    This assertion is DETERMINISTIC and needs no clock — so unlike a
    promptness assertion read off `AutoAdvancingClock`, a busy-polling client
    cannot pass it on time it never spent."""
    var stream = ScriptedStream.from_read_script(_counting_script(40))
    stream.set_max_read_per_call(10)
    stream.queue_pending_at(20, 3)

    var total = 0
    var iters = 0
    while iters < 200:
        iters = iters + 1
        var r = _one_read(stream, 64)
        if r.is_ready():
            total = total + Int(r.n_bytes())
        if r.is_eof():
            break
    assert_equal(total, 40, "the whole body arrived")
    # 4 x 10-byte reads + 3 Pendings + 1 Eof == 8. The bound is stated as a
    # BUDGET rather than an equality so a legitimate extra probe does not red
    # the test, but it is far below anything a spin would produce.
    assert_true(
        stream.try_read_call_count() <= 12,
        "drained in "
        + String(stream.try_read_call_count())
        + " try_read calls; a spinning drain would be orders of magnitude more",
    )


def test_collect_body_promptness_over_a_mid_body_park() raises:
    """The same clock-free promptness assertion against the REAL
    `collect_body` drain loop, with the park placed MID-BODY — the position
    `queue_read_pending` could not reach.

    ⚠ The stream is moved into the response body, so the counter is read back
    off `resp.body` rather than off the local handle."""
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n")
    ) + _counting_script(40)
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.set_max_read_per_call(64)
    # Park after the head (39 bytes) plus 20 body bytes.
    stream.queue_pending_at(59, 3)

    var url = Url.parse(String("http://example.com/body"))
    var hdrs = HeaderMap()
    var req_bytes = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, req_bytes)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _os_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)

    var reactor2 = _os_reactor()
    var tok = CancellationToken.never()
    var body = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        resp.body, reactor2, tok,
    )
    assert_equal(len(body), 40, "the whole 40-byte body arrived")
    var i = 0
    while i < 40:
        assert_equal(
            Int(body[i]), Int(UInt8(i % 251)), "body byte " + String(i),
        )
        i = i + 1


def main() raises:
    test_baseline_one_shot_arm_eof_can_only_fire_at_offset_zero()
    test_baseline_queue_read_pending_covers_only_the_first_reads()
    test_arm_error_at_delivers_exactly_n_bytes_then_the_errno()
    test_arm_error_at_fires_on_a_single_oversized_read()
    test_arm_error_at_zero_is_the_one_shot_shape()
    test_arm_eof_at_truncates_the_body_mid_stream()
    test_arm_eof_at_disarms_and_the_rest_of_the_script_survives()
    test_pending_wins_over_error_wins_over_eof_at_one_offset()
    test_queue_pending_at_parks_mid_body_then_resumes()
    test_queue_pending_at_composes_with_max_read_per_call()
    test_max_write_per_call_reports_an_honest_partial_count()
    test_max_write_per_call_zero_and_negative_mean_unlimited()
    test_64kib_request_head_written_seven_bytes_at_a_time_is_byte_identical()
    test_64kib_streaming_body_written_seven_bytes_at_a_time_is_byte_identical()
    test_queue_write_pending_mid_head_then_completes_through_the_driver()
    test_write_pending_then_short_write_compose()
    test_arm_connect_error_makes_the_dial_refusable()
    test_a_refused_dial_does_not_consume_the_armed_stream()
    test_arm_connect_never_resolves_is_the_connect_timeout_outcome()
    test_arm_connect_in_progress_then_error_models_so_error_recovery()
    test_try_read_call_count_counts_every_entry_including_faults()
    test_try_write_call_count_counts_pending_and_partial_writes()
    test_promptness_is_assertable_without_a_clock()
    test_collect_body_promptness_over_a_mid_body_park()
    print("PASS test_scripted_fault_vocabulary")
