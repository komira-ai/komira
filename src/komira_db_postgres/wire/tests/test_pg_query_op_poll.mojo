# =============================================================================
# komira_pg/tests/test_pg_query_op_poll.mojo — the poll-shaped pgwire READ
# =============================================================================
# The concurrency + framing-cursor evidence for the poll-shaped pgwire READ.
# Proves the foundation for suspendable handlers: ONE worker holds >1 PG query
# in flight, where query A suspends on its read and query B finishes BEFORE A —
# the queries are NOT serialized on each other's PG round-trip. And a backend
# message split across TWO recvs makes the framing cursor re-park mid-message
# (the critical partial-read path).
#
# WHAT THIS TESTS (the real op machinery, transport-decoupled):
#   * `PgReadFrame` — the critical framing-cursor + DataRow-drain state machine
#     that `PgQueryOp` owns. It is recv-source-AGNOSTIC (never touches a
#     socket / s2n / reactor), so we drive it DIRECTLY over plaintext
#     pgwire-framed bytes — the SAME framing logic the op feeds s2n-decrypted
#     bytes to. The s2n transport itself needs a live server; this test pins
#     the frame machinery with no server.
#   * A `_PgQueryOpDriver` (a suspendable-handler driver shape) parks
#     PgReadFrame-backed frames on REAL epoll-backed reactor fds (socketpairs)
#     and resumes them by op_id — proving peak_inflight>1.
#
# Coverage:
#   * SPLIT MESSAGE (the partial-read path): a DataRow whose bytes arrive in
#     TWO chunks → drain_complete returns "need more" after chunk 1 (re-park),
#     folds the row after chunk 2.
#   * MULTIPLEX (the headline): admit A (parks) + admit B (parks) → peak
#     in-flight == 2; make B's result ready first → B completes WHILE A is still
#     parked; then make A ready → A completes. Right rows to the right query.
#   * RE-PARK across two recvs over a real reactor fd: a result split across two
#     socket writes makes the frame park, resume partial, re-park, resume final.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, Reactor
from komira_async.runtime.parked_morsel_slab import ParkedMorselSlab

from komira_pg.pg_query_op import (
    PgReadFrame,
    PG_OP_PENDING,
    PG_OP_READY,
    PG_OP_ERR,
)
from komira_pg.pg_types import OID_TEXT
from komira_pg.pgwire import (
    put_i16_be,
    put_i32_be,
    MSG_DATA_ROW,
    MSG_CMD_COMPLETE,
    MSG_READY,
)


comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


# -----------------------------------------------------------------------------
# pgwire backend-message builders (the SERVER side — the client only decodes;
# the test forges the bytes a real Postgres would send). A framed backend
# message is: Type(1) Length(Int32, includes itself) Body.
# -----------------------------------------------------------------------------
def _framed(msg_type: UInt8, body: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(msg_type)
    put_i32_be(out, Int32(4 + len(body)))  # length includes the 4-byte field
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _data_row(cells: List[String]) -> List[UInt8]:
    """A text-format DataRow ('D'): Int16 col-count, then per column Int32 length
    + bytes (text format, the simple-query shape PgRow.get_* text decoders
    read)."""
    var body = List[UInt8]()
    put_i16_be(body, Int16(len(cells)))
    for ci in range(len(cells)):
        var cb = cells[ci].as_bytes()
        put_i32_be(body, Int32(len(cb)))
        for j in range(len(cb)):
            body.append(cb[j])
    return _framed(MSG_DATA_ROW, body^)


def _ready_for_query() -> List[UInt8]:
    """ReadyForQuery ('Z'): one status byte ('I' = idle)."""
    var body = List[UInt8]()
    body.append(UInt8(ord("I")))
    return _framed(MSG_READY, body^)


def _command_complete(tag: String) -> List[UInt8]:
    """CommandComplete ('C'): a NUL-terminated command tag."""
    var body = List[UInt8]()
    var tb = tag.as_bytes()
    for i in range(len(tb)):
        body.append(tb[i])
    body.append(UInt8(0))
    return _framed(MSG_CMD_COMPLETE, body^)


def _append_all(mut dst: List[UInt8], src: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


# -----------------------------------------------------------------------------
# A complete EXECUTE reply byte-stream: N DataRows (each a single text column)
# + CommandComplete + ReadyForQuery. Models the wire bytes the op's frame drains.
# -----------------------------------------------------------------------------
def _execute_reply(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for vi in range(len(values)):
        var cells = List[String]()
        cells.append(values[vi])
        _append_all(out, _data_row(cells))
    _append_all(out, _command_complete(String("SELECT ") + String(len(values))))
    _append_all(out, _ready_for_query())
    return out^


# =============================================================================
# TEST 1 — PgReadFrame framing-cursor re-park across a SPLIT message.
# =============================================================================
def test_frame_repark_on_split_message() raises:
    """A backend message whose bytes arrive in TWO feeds makes the framing
    cursor return "need more" (re-park) after the first, then fold the row on the
    second. This is the critical partial-read path: the frame holds the
    partial bytes across the (modeled) park, and parses the message ONLY once the
    whole message is buffered — never holding a Span of the partial buffer across
    the feed boundary."""
    # One DataRow (text "hello") + CommandComplete + ReadyForQuery.
    var values = List[String]()
    values.append(String("hello"))
    var reply = _execute_reply(values)

    # Seed the frame for one TEXT column.
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    var names = List[String]()
    names.append(String("c0"))
    var frame = PgReadFrame(oids^, names^)

    # Split the reply at byte 3 — mid-DataRow header (so the framing cursor sees
    # an INCOMPLETE message and must wait for more).
    var split = 3
    var chunk1 = List[UInt8]()
    for i in range(split):
        chunk1.append(reply[i])
    var chunk2 = List[UInt8]()
    for i in range(split, len(reply)):
        chunk2.append(reply[i])

    # Feed chunk 1 → drain returns False (no complete message yet → re-park).
    frame.feed(chunk1)
    var terminal1 = frame.drain_complete()
    assert_false(terminal1)
    assert_true(frame.is_pending())
    assert_equal(frame.row_count(), 0)

    # Feed chunk 2 → now the whole reply is buffered → DataRow folds, then
    # ReadyForQuery → terminal READY.
    frame.feed(chunk2)
    var terminal2 = frame.drain_complete()
    assert_true(terminal2)
    assert_true(frame.is_ready())
    assert_equal(frame.row_count(), 1)

    var rows = frame.take_result()
    assert_equal(rows.__len__(), 1)
    ref r0 = rows.row(0)
    assert_equal(r0.get_text(0), String("hello"))


# =============================================================================
# TEST 2 — message boundary split (a DataRow split EXACTLY between two whole
# messages still drains incrementally, no double-parse).
# =============================================================================
def test_frame_two_rows_split_between_messages() raises:
    """Two DataRows; feed only the first row's bytes (drain folds row 0, then
    needs more → re-park), then the rest (row 1 + terminal). Proves the cursor
    advances past consumed messages and resumes cleanly."""
    # NOTE: the op reads BINARY-format DataRows (the extended-protocol path), so
    # the forged DataRow bodies here are TEXT-as-raw-bytes read through the TEXT
    # OID (get_text reads the raw column bytes regardless of format — the test
    # exercises the FRAMING cursor, not the per-OID binary decode, which the
    # binary-codec test covers).
    var values = List[String]()
    values.append(String("11"))
    values.append(String("22"))
    var reply = _execute_reply(values)

    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    var names = List[String]()
    names.append(String("n"))
    var frame = PgReadFrame(oids^, names^)

    # Length of exactly the first DataRow.
    var first_row = _data_row(_one(String("11")))
    var n1 = len(first_row)

    var chunk1 = List[UInt8]()
    for i in range(n1):
        chunk1.append(reply[i])
    var chunk2 = List[UInt8]()
    for i in range(n1, len(reply)):
        chunk2.append(reply[i])

    frame.feed(chunk1)
    var t1 = frame.drain_complete()
    assert_false(t1)  # row 0 folded, but no terminal yet
    assert_equal(frame.row_count(), 1)
    assert_true(frame.is_pending())

    frame.feed(chunk2)
    var t2 = frame.drain_complete()
    assert_true(t2)
    assert_true(frame.is_ready())
    assert_equal(frame.row_count(), 2)

    var rows = frame.take_result()
    assert_equal(rows.__len__(), 2)
    # ⚠ Mojo 1.0.0: forming `r1` INVALIDATES `r0` — two interior references into
    # one container cannot both be live. Each ref is used before the next is
    # formed; the two assertions are unchanged.
    ref r0 = rows.row(0)
    assert_equal(r0.get_text(0), String("11"))
    ref r1 = rows.row(1)
    assert_equal(r1.get_text(0), String("22"))


def _one(v: String) -> List[String]:
    var l = List[String]()
    l.append(v)
    return l^


# =============================================================================
# §3 — A poll-shaped frame parked on a REAL reactor fd (a socketpair). The
# `_PgReadOpFrame` couples a PgReadFrame with the fd it parks on + a request id;
# `_PgQueryOpDriver` multiplexes them by op_id (a suspendable-handler driver
# shape, here over the real PgReadFrame machinery).
# =============================================================================


def _socketpair() raises -> Array[Int32, 2]:
    """SAFETY: pair is stack-local; the kernel writes 2 fds into it and does not
    retain the pointer. Confined to this test helper."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_bytes(fd: Int32, data: List[UInt8]) raises:
    """Write `data` to `fd` (the PG-server side of the pair) — models the reply
    bytes arriving on the connection."""
    var off = 0
    var n = len(data)
    while off < n:
        var scratch = Array[UInt8, 16384](fill=UInt8(0))
        var want = n - off
        if want > 16384:
            want = 16384
        for i in range(want):
            scratch[i] = data[off + i]
        var w = external_call["send", Int](
            fd, scratch.unsafe_ptr(), UInt(want), Int32(0),
        )
        if w <= 0:
            raise Error("send() failed")
        off += Int(w)


def _recv_nonblocking(fd: Int32) raises -> List[UInt8]:
    """Non-blocking plaintext recv on `fd` (the client read end). Returns the
    bytes available right now (possibly empty on EWOULDBLOCK). Models
    PgReactorStream.try_recv_some's "decrypt whatever is buffered" without the
    s2n layer (which needs a live server)."""
    var out = List[UInt8]()
    var msg_dontwait = Int32(0x40)  # MSG_DONTWAIT on Linux
    var guard = 0
    while guard < 1024:
        var scratch = Array[UInt8, 4096](fill=UInt8(0))
        var got = external_call["recv", Int](
            fd, scratch.unsafe_ptr(), UInt(4096), msg_dontwait,
        )
        if got > 0:
            for i in range(Int(got)):
                out.append(scratch[i])
            if Int(got) < 4096:
                break  # drained what was available
        else:
            break  # EWOULDBLOCK or EOF
        guard += 1
    return out^


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


struct _PgReadOpFrame(Movable, Deinitable):
    """A PgReadFrame coupled with the fd it parks on + a request id + the op_id
    it is currently parked under. An owned-frame shape (a suspended frame)
    over the real PgReadFrame machinery."""

    var _frame: PgReadFrame
    var _fd: Int32
    var _request_id: Int64
    var _parked_op_id: Int64

    def __init__(out self, var frame: PgReadFrame, fd: Int32, request_id: Int64):
        self._frame = frame^
        self._fd = fd
        self._request_id = request_id
        self._parked_op_id = Int64(0)

    @always_inline
    def request_id(self) -> Int64:
        return self._request_id

    @always_inline
    def fd(self) -> Int32:
        return self._fd

    def set_parked_op_id(mut self, op_id: Int64):
        self._parked_op_id = op_id

    def pump(mut self) raises -> Bool:
        """Non-blocking recv on the fd, feed the frame, drain. Returns True at a
        terminal (READY / ERR). This is the test-transport analog of
        PgQueryOp._drain_nonblocking (plaintext recv instead of s2n)."""
        if not self._frame.is_pending():
            return True
        if self._frame.drain_complete():
            return True
        var chunk = _recv_nonblocking(self._fd)
        if len(chunk) > 0:
            self._frame.feed(chunk)
            return self._frame.drain_complete()
        return False  # nothing read → re-park


struct _PgQueryOpDriver(Movable, Deinitable):
    """Per-worker multiplexing driver over `_PgReadOpFrame`, keyed by op_id (a
    suspendable-handler driver shape). Holds parked frames in a
    ParkedMorselSlab; tracks peak in-flight (>1 == multiplex win) + delivered
    results."""

    var _parked: ParkedMorselSlab[_PgReadOpFrame]
    var _delivered_ids: List[Int64]
    var _delivered_row_counts: List[Int]
    var _peak_inflight: Int64
    var _resume_count: Int64

    def __init__(out self):
        self._parked = ParkedMorselSlab[_PgReadOpFrame]()
        self._delivered_ids = List[Int64]()
        self._delivered_row_counts = List[Int]()
        self._peak_inflight = Int64(0)
        self._resume_count = Int64(0)

    def inflight_count(self) -> Int:
        return self._parked.len()

    def peak_inflight(self) -> Int64:
        return self._peak_inflight

    def resume_count(self) -> Int64:
        return self._resume_count

    def delivered_count(self) -> Int:
        return len(self._delivered_ids)

    def delivered_id(self, i: Int) -> Int64:
        return self._delivered_ids[i]

    def delivered_rows(self, i: Int) -> Int:
        return self._delivered_row_counts[i]

    def _update_peak(mut self):
        var n = Int64(self._parked.len())
        if n > self._peak_inflight:
            self._peak_inflight = n

    def _deliver(mut self, var frame: _PgReadOpFrame):
        self._delivered_ids.append(frame.request_id())
        self._delivered_row_counts.append(frame._frame.row_count())
        _ = frame^

    def _park(mut self, var frame: _PgReadOpFrame, op_id: Int64):
        frame.set_parked_op_id(op_id)
        self._parked.park(op_id, frame^)
        self._update_peak()

    def admit(
        mut self, var frame: _PgReadOpFrame, mut reactor: Reactor[NoopSink]
    ) raises:
        """Step a freshly-admitted frame once. If still pending, register its fd
        + park it; else deliver immediately."""
        var done = frame.pump()
        if done:
            self._deliver(frame^)
        else:
            var op_id = reactor.alloc_op_id()
            reactor.register_read(frame.fd(), op_id, UInt16(0))
            self._park(frame^, op_id)

    def _resume(mut self, op_id: Int64, mut reactor: Reactor[NoopSink]) raises:
        var maybe = self._parked.take(op_id)
        if maybe:
            self._resume_count = self._resume_count + Int64(1)
            var frame = maybe.take()
            var done = frame.pump()
            if done:
                reactor.deregister(op_id)
                self._deliver(frame^)
            else:
                # Re-park on the SAME op_id (registration still live).
                self._park(frame^, op_id)

    def drive_one_ready_batch(mut self, mut reactor: Reactor[NoopSink]) raises:
        """Block until ≥1 parked frame's fd is ready; resume the matching
        frame(s). Frames whose fds are NOT ready stay parked."""
        if self._parked.len() == 0:
            return
        var completions = reactor.poll_completions(Int32(-1))
        for ci in range(len(completions)):
            self._resume(completions[ci].op_id, reactor)


# =============================================================================
# TEST 3 — MULTIPLEX: one driver holds TWO queries in flight; B finishes while A
# is still parked. peak_inflight == 2.
# =============================================================================
def test_multiplex_two_queries_one_worker() raises:
    comptime if CompilationTarget.is_linux():
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var a = _socketpair()
        var b = _socketpair()

        var driver = _PgQueryOpDriver()

        # Admit A (id=1) — no bytes primed on A yet → it parks on A's fd.
        var oa = List[UInt32](); oa.append(OID_TEXT)
        var na = List[String](); na.append(String("c0"))
        driver.admit(
            _PgReadOpFrame(PgReadFrame(oa^, na^), a[0], Int64(1)), reactor
        )
        assert_equal(driver.inflight_count(), 1)
        assert_equal(driver.delivered_count(), 0)

        # Admit B (id=2) — parks too. NOW the worker holds BOTH in flight.
        var ob = List[UInt32](); ob.append(OID_TEXT)
        var nb = List[String](); nb.append(String("c0"))
        driver.admit(
            _PgReadOpFrame(PgReadFrame(ob^, nb^), b[0], Int64(2)), reactor
        )
        assert_equal(driver.inflight_count(), 2)
        assert_equal(driver.peak_inflight(), Int64(2))
        assert_equal(driver.delivered_count(), 0)

        # Make B's full reply ready FIRST (completion order != admit order):
        # 3 DataRows. Drive one poll cycle → only B is ready → B completes while
        # A is still parked.
        var bvals = List[String]()
        bvals.append(String("b0")); bvals.append(String("b1"))
        bvals.append(String("b2"))
        _send_bytes(b[1], _execute_reply(bvals))
        driver.drive_one_ready_batch(reactor)
        assert_equal(driver.delivered_count(), 1)
        assert_equal(driver.inflight_count(), 1)  # A still parked

        # Now make A ready (1 DataRow) and finish it.
        var avals = List[String]()
        avals.append(String("a0"))
        _send_bytes(a[1], _execute_reply(avals))
        driver.drive_one_ready_batch(reactor)
        assert_equal(driver.delivered_count(), 2)
        assert_equal(driver.inflight_count(), 0)

        # B delivered first (id=2, 3 rows), A second (id=1, 1 row) — completion
        # order, not admit order, proving resume-by-op_id + the right rows to the
        # right query.
        assert_equal(driver.delivered_id(0), Int64(2))
        assert_equal(driver.delivered_rows(0), 3)
        assert_equal(driver.delivered_id(1), Int64(1))
        assert_equal(driver.delivered_rows(1), 1)

        _close(a[0]); _close(a[1]); _close(b[0]); _close(b[1])


# =============================================================================
# TEST 4 — RE-PARK across two recvs over a real reactor fd: a reply split across
# two socket writes makes the frame park, resume partial, re-park, resume final.
# =============================================================================
def test_repark_across_two_recvs_real_fd() raises:
    comptime if CompilationTarget.is_linux():
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var c = _socketpair()

        var driver = _PgQueryOpDriver()
        var oc = List[UInt32](); oc.append(OID_TEXT)
        var nc = List[String](); nc.append(String("c0"))
        driver.admit(
            _PgReadOpFrame(PgReadFrame(oc^, nc^), c[0], Int64(7)), reactor
        )
        assert_equal(driver.inflight_count(), 1)

        # Build a 2-row reply; split it mid-stream so the first socket write
        # delivers a partial message → the frame resumes, stays partial,
        # re-parks; the second write delivers the rest → resume + finish.
        var vals = List[String]()
        vals.append(String("row-one")); vals.append(String("row-two"))
        var reply = _execute_reply(vals)
        var split = len(reply) // 2

        var part1 = List[UInt8]()
        for i in range(split):
            part1.append(reply[i])
        var part2 = List[UInt8]()
        for i in range(split, len(reply)):
            part2.append(reply[i])

        # First chunk → resume reads a partial, re-parks (still in flight).
        _send_bytes(c[1], part1)
        driver.drive_one_ready_batch(reactor)
        assert_equal(driver.inflight_count(), 1)  # re-parked
        assert_equal(driver.delivered_count(), 0)

        # Second chunk → the rest → READY → finish.
        _send_bytes(c[1], part2)
        driver.drive_one_ready_batch(reactor)
        assert_equal(driver.inflight_count(), 0)
        assert_equal(driver.delivered_count(), 1)
        assert_equal(driver.delivered_id(0), Int64(7))
        assert_equal(driver.delivered_rows(0), 2)
        # resume_count == 2: the partial resume + the final resume.
        assert_equal(driver.resume_count(), Int64(2))

        _close(c[0]); _close(c[1])


def main() raises:
    test_frame_repark_on_split_message()
    test_frame_two_rows_split_between_messages()
    test_multiplex_two_queries_one_worker()
    test_repark_across_two_recvs_real_fd()
    print("PASS komira_pg.pg_query_op_poll")
