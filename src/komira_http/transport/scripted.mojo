# =============================================================================
# src/komira_http/transport/scripted.mojo — ScriptedConnector + ScriptedStream
# =============================================================================
#
# The mock IoStream + Connector — a first-class conformer.
#
#   The Connector/IoStream seam is the highest-leverage testability
#   asset in the design — a comptime trait, no vtable, trivially
#   substitutable. Alongside KernelTcpConnector/TcpIoStream sits
#   ScriptedConnector producing a ScriptedStream, a first-class
#   conformer, not an afterthought.
#
#   A ScriptedStream lets every pool test, state-machine test, retry
#    test, codec test run deterministically with zero sockets: the test
#    scripts the exact byte sequence the 'server' returns, scripts a
#    Pending(READ) at a chosen point to exercise the park/wake path,
#    scripts a mid-response Eof to exercise the RST-during-response path,
#    scripts a connect that returns IN_PROGRESS then Error to exercise
#   SO_ERROR recovery, and (with the injectable clock) scripts a
#   connect that never resolves to exercise connect_timeout. Every
#   failure mode of the client state machine becomes a deterministic
#   unit test instead of a flaky network test.
#
# The mock is parametric over `[RT: Runtime]` exactly like KernelTcp —
# the comptime trait-substitution discipline means tests get the same
# AOT-monomorphization treatment as production. No fn-ptr table.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * ZERO unsafe_from_address.
#   * Internal storage: `List[UInt8]` for the script byte sequences
#     (script bytes are bounded and small; List is the natural fit).
#     Both the script and the captured-write buffer are owned fields,
#     drop with the struct.
# =============================================================================

from std.memory import ArcPointer, unsafe_memcpy

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from .io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    Pending,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)


# =============================================================================
# ScriptedStream — IoStream conformer that replays a pre-loaded byte script.
# =============================================================================
#
# Behavior model:
#   * `_read_script: List[UInt8]` — bytes the "server" returns to
#     try_read calls. The stream tracks `_read_cursor` as a position
#     into this list; each successful try_read consumes from
#     `_read_cursor` forward. When the cursor reaches the end of the
#     script, subsequent reads return Eof.
#   * `_write_capture: List[UInt8]` — bytes the "client" wrote. Tests
#     inspect this AFTER the exchange to verify the client emitted the
#     expected request bytes.
#   * `_pending_on_read: Int` — how many subsequent reads should return
#     StreamIo.pending() before serving real bytes. Decremented per
#     read. Test mode: a value > 0 lets the test exercise the park/wake
#     path even though no real socket is involved.
#   * `_force_eof: Bool` — if True, the next read returns Eof regardless
#     of script position. Tests use this to simulate mid-response RST.
#   * `_force_error_errno: Int64` — if > 0, next read/write returns
#     StreamIo.error(this errno). Tests use this to simulate hard
#     socket errors.
#   * `_max_read_per_call: Int` — clamp the bytes-per-Ready response.
#     Set to a small N to force the client to loop on partial reads
#     (testing partial-read handling).
#   * `_negotiated: UInt8` — the connection's "ALPN result" (mock
#     decides at construction; H1.1 default).
#
# Movability: ScriptedStream is Movable (List[UInt8] is Movable) but
# NOT Copyable (the script + capture buffers are single-owned). Same
# discipline as TcpIoStream.

struct ScriptedStream(IoStream, Movable, Deinitable):
    """Mock IoStream. Replays a pre-loaded byte script on
    try_read; captures bytes to a buffer on try_write. Lets tests run
    every state-machine path deterministically with ZERO sockets.

    Construction:
      * `ScriptedStream.empty()` — empty script (read returns Eof,
        write captures everything). Useful for "client emits request
        line + headers, server replies nothing" smoke tests.
      * `ScriptedStream.from_read_script(bytes)` — preload the
        server-side response bytes. Tests typically build a
        request-response cycle by:
          ```mojo
          var bytes = List[UInt8]()
          bytes.append(UInt8('H')); ... ;
          var s = ScriptedStream.from_read_script(bytes^)
          ```
    """

    var _read_script: List[UInt8]
    var _read_cursor: Int
    var _write_capture: List[UInt8]
    var _pending_on_read: Int
    var _pending_on_write: Int
    var _force_eof: Bool
    var _force_error_errno: Int64
    var _max_read_per_call: Int
    var _negotiated: UInt8

    # how many try_read calls
    # return Pending AFTER the script is exhausted, before EOF. 0 (default)
    # is the prior behaviour exactly -- an exhausted script EOFs at once.
    #
    # WHY THIS IS NOT `queue_read_pending`. That counter is consumed from the
    # FIRST try_read, so on any end-to-end fixture the HEAD read eats it and
    # the stall lands in the wrong phase. This one arms only once the script
    # has run out, which is the shape of the real failure: the peer completes
    # the response HEAD and then sends nothing while holding the socket open.
    # Finite on purpose -- an infinite stall makes the PRE-FIX red
    # unobservable, and the whole point of the regression fixture is that the
    # bug is observable in bounded time.
    var _pending_after_script: Int
    # ----- FAULT-AT-AN-OFFSET vocabulary -------------------
    # Before these, the ONLY expressible read-side fault was at script
    # EXHAUSTION (a clean Eof) or at the very NEXT call (`arm_eof` /
    # `arm_error`, one-shot flags read at the top of `try_read`). Neither
    # can say "the peer sent 37 bytes of a 100-byte body and THEN RST" —
    # which is the shape of the live `EOF_MID_RESPONSE` /
    # `chunked body unterminated` defect this fixture exists to reproduce.
    #
    # Each is a byte OFFSET into `_read_script` measured in SCRIPT bytes
    # DELIVERED (i.e. against `_read_cursor`), or -1 for "unarmed". They
    # ALSO CLAMP `n_to_copy`, so the fault lands at EXACTLY the armed
    # offset rather than after whatever oversized read happened to
    # straddle it — a fault you cannot place precisely is a fault you
    # cannot write an assertion about.
    var _eof_at_offset: Int
    var _error_at_offset: Int
    var _error_at_errno: Int64
    var _pending_at_offset: Int
    var _pending_at_count: Int
    # ----- WRITE-SIDE CLAMP -------------------------------
    # Without a clamp `try_write` always accepts the whole `src`, so no test
    # can drive a writer through a short write — the class of a positive
    # partial rc discarded as blocked, which otherwise needs a real
    # socketpair with a shrunken SO_SNDBUF to find. `n <= 0` means unlimited (default).
    var _max_write_per_call: Int
    # ----- CLOCK-FREE PROMPTNESS COUNTERS -----------------
    # `assert_true(stream.try_read_call_count() <= BUDGET)` is a
    # DETERMINISTIC promptness assertion that needs no clock at all — and
    # therefore cannot be fooled by a clock that advances on every read,
    # which is precisely how a busy-polling client passes a promptness
    # assertion on time it never actually spent.
    var _try_read_calls: Int
    var _try_write_calls: Int
    # OPTIONAL shared write-capture (additive; default None). When present,
    # try_write ALSO mirrors the written bytes into this `ArcPointer`-shared
    # `List[UInt8]`. The point: a client's `call`/`send` path DIALS the
    # connector, takes ownership of the stream, drives the exchange, and
    # DROPS the stream at the end — so the per-stream `_write_capture` is
    # gone before a test can inspect it. A SHARED buffer (held by the test
    # via the same `ArcPointer`) survives the stream's drop, letting the test
    # assert the exact outbound request bytes a generated client emitted.
    # ArcPointer[List[UInt8]] is the established shared-byte-buffer primitive
    # in this package (header_map.mojo's response-head sharing).
    var _shared_capture: Optional[ArcPointer[List[UInt8]]]
    # ★ THE DELAYED WRITE-FAULT SLOT.
    # The read side of a reaped pooled connection is covered by the
    # fault-at-an-OFFSET vocabulary above (`arm_error_at(len(script), errno)`
    # is an RST exactly where the FIN would have been). The WRITE side is not,
    # and cannot be: `arm_error` is ONE-SHOT and is consumed by whichever of
    # try_read / try_write runs FIRST — and on every request the WRITE runs
    # first, so it can only ever poison the FIRST request on a connection.
    #
    # What is missing is a write that fails having written NOTHING on the
    # SECOND request of a REUSED connection — Go's `nothingWrittenError`, the
    # one term of its three-term retry rule that makes replaying a
    # non-idempotent request safe. Defaults to disabled; changes no existing
    # behaviour.
    var _write_error_errno: Int64
    """When > 0 AND `_write_error_after` writes have already been served,
    the next try_write returns `error(errno)` having captured ZERO bytes."""
    var _write_error_after: Int
    """How many try_write calls complete normally before `_write_error_errno`
    fires. 0 = the very next one."""
    var _writes_served: Int
    """try_write calls that returned Ready so far (the `_write_error_after`
    counter)."""

    def __init__(out self):
        """Empty-script ScriptedStream. try_read returns Eof; try_write
        captures all bytes."""
        self._read_script = List[UInt8]()
        self._read_cursor = 0
        self._write_capture = List[UInt8]()
        self._pending_on_read = 0
        self._pending_on_write = 0
        self._force_eof = False
        self._force_error_errno = Int64(0)
        # Default: unlimited bytes-per-Ready (clamp at script length).
        self._max_read_per_call = -1
        self._negotiated = NEGOTIATED_HTTP_1_1
        self._shared_capture = None
        self._pending_after_script = 0
        self._eof_at_offset = -1
        self._error_at_offset = -1
        self._error_at_errno = Int64(0)
        self._pending_at_offset = -1
        self._pending_at_count = 0
        # Default: unlimited bytes-per-write (accept the whole src).
        self._max_write_per_call = -1
        self._try_read_calls = 0
        self._try_write_calls = 0
        self._write_error_errno = Int64(0)
        self._write_error_after = 0
        self._writes_served = 0

    @staticmethod
    def empty() -> ScriptedStream:
        """Construct an empty-script stream."""
        return ScriptedStream()

    @staticmethod
    def from_read_script(var script: List[UInt8]) -> ScriptedStream:
        """Construct from a pre-loaded read-side script. Consumes
        `script`."""
        var s = ScriptedStream()
        s._read_script = script^
        return s^

    @staticmethod
    def from_read_script_with_capture(
        var script: List[UInt8],
        shared: ArcPointer[List[UInt8]],
    ) -> ScriptedStream:
        """Construct from a pre-loaded read-side script AND a SHARED
        write-capture buffer. The stream mirrors every written byte into
        `shared` (in addition to its own `_write_capture`), so the bytes
        survive the stream's drop and a test holding the same `ArcPointer`
        can assert them after a client `call`/`send` consumes the stream.
        Consumes `script`; clones the `ArcPointer` (refcount inc)."""
        var s = ScriptedStream()
        s._read_script = script^
        s._shared_capture = Optional[ArcPointer[List[UInt8]]](shared)
        return s^

    # ----- Test fixture API ---------------------------------------------
    # These mutators let a test pre-load behavior before handing the
    # stream off to the client under test. They are NOT part of the
    # IoStream trait; they're concrete-type-only conveniences. Tests
    # use them with the concrete `ScriptedStream` handle BEFORE the
    # stream is moved into a generic IoStream slot.

    def queue_read_pending(mut self, n: Int):
        """Make the next `n` try_read calls return StreamIo.pending(...)
        before serving script bytes. Exercises the park/wake path."""
        self._pending_on_read = self._pending_on_read + n

    def queue_write_pending(mut self, n: Int):
        """Make the next `n` try_write calls return StreamIo.pending(...)
        before accepting bytes."""
        self._pending_on_write = self._pending_on_write + n

    def arm_eof(mut self):
        """Make the next try_read return StreamIo.eof() — simulates
        peer-side close mid-response."""
        self._force_eof = True

    def arm_error(mut self, errno: Int64):
        """Make the next try_read / try_write return
        StreamIo.error(errno). Tests use this to drive the hard-error
        path."""
        self._force_error_errno = errno

    def arm_write_error_after(mut self, errno: Int64, after_writes: Int):
        """Fire `StreamIo.error(errno)` on the try_write call that FOLLOWS
        `after_writes` successful ones, capturing ZERO bytes — Go's
        `nothingWrittenError`, and the term of its three-term retry rule that
        makes replaying a non-idempotent request safe.

        `after_writes = 1` poisons the SECOND request on a reused connection
        (the first request's single write having pooled it), which is the
        exact shape of a server that reaped the connection between them."""
        self._write_error_errno = errno
        self._write_error_after = after_writes

    def set_max_read_per_call(mut self, n: Int):
        """Clamp bytes-per-Ready. `n <= 0` means "unlimited" (default).
        Used by partial-read tests."""
        self._max_read_per_call = n

    def set_pending_after_script(mut self, n: Int):
        """Make the next `n` try_read calls AFTER the script is exhausted
        return Pending, before EOF. Default 0 (EOF immediately, the prior
        behaviour).

        This is the STALLED-PEER generator: a peer that finished the response
        head and then sends nothing, while holding the connection open. It is
        distinct from `queue_read_pending`, which is consumed from the very
        first read and so is eaten by the head phase."""
        self._pending_after_script = n

    def set_negotiated_protocol(mut self, p: UInt8):
        """Override the negotiated_protocol return — tests with H2 ALPN
        flows."""
        self._negotiated = p

    # ----- Fault-at-an-OFFSET fixture API -------------------
    #
    # ⚠ THE OFFSET IS A *SCRIPT-BYTES-DELIVERED* COUNT, not a call count
    # and not a wire offset. `arm_error_at(37, ECONNRESET)` on a 100-byte
    # script means: `try_read` hands out exactly bytes [0, 37) — across
    # however many calls the client makes, and clamped so no single call
    # straddles the boundary — and the FIRST call that would have crossed
    # 37 returns `StreamIo.error(ECONNRESET)` instead.
    #
    # Precedence at one offset, checked in this order and stated because
    # a test WILL arm two at once: PENDING (transient — it is re-tried),
    # then ERROR, then EOF. A one-shot `arm_error` / `arm_eof` still wins
    # over all three: those are read at the very top of `try_read`.

    def arm_eof_at(mut self, offset: Int):
        """Deliver exactly `offset` script bytes, then return
        `StreamIo.eof()` — the peer half-closing MID-BODY.

        This is the capability the module shipped WITHOUT: `arm_eof` is a
        one-shot flag read at the top of `try_read`, so it can only place
        an Eof at the NEXT call; script exhaustion can only place one at
        the END. Neither expresses "the response was truncated at byte
        N", which is what a `Content-Length` short-body and an
        unterminated chunked body both are.

        Disarms itself once fired. `offset < 0` disarms without firing."""
        self._eof_at_offset = offset

    def arm_error_at(mut self, offset: Int, errno: Int64):
        """Deliver exactly `offset` script bytes, then return
        `StreamIo.error(errno)` — an RST at a byte offset.

        Without this, an RST mid-response is INEXPRESSIBLE and only a
        clean Eof is: `arm_error` fires at the next call, which is before
        any body byte has been served. Disarms itself once fired."""
        self._error_at_offset = offset
        self._error_at_errno = errno

    def queue_pending_at(mut self, offset: Int, n: Int):
        """After exactly `offset` script bytes have been delivered, make
        the next `n` `try_read` calls return `StreamIo.pending(...)`
        before serving the rest.

        `queue_read_pending(n)` covers only the FIRST n reads, so the
        park/wake path is today exercised ONLY at the START of a
        response — which is exactly where the production hang is NOT. A
        Pending in the MIDDLE of a body is the shape that catches a
        driver whose park bookkeeping is right on entry and wrong once
        it has state."""
        self._pending_at_offset = offset
        self._pending_at_count = n

    def set_max_write_per_call(mut self, n: Int):
        """Clamp bytes-accepted-per-`try_write`. `n <= 0` means
        "unlimited" (the default).

        A kernel socket accepts a PARTIAL write whenever the send buffer
        is short of room, and TLS `s2n_send` does the same. A writer that
        treats `ready(n)` as "all of src was taken" silently truncates
        the request. This clamp is how that is asserted with zero
        sockets."""
        self._max_write_per_call = n

    def try_read_call_count(self) -> Int:
        """How many times `try_read` has been ENTERED on this stream —
        every outcome counted, Pending and Eof included.

        ★ CLOCK-FREE PROMPTNESS. `assert_true(s.try_read_call_count() <=
        BUDGET)` is deterministic and cannot be fooled by a test clock
        that advances on each read (which REWARDS a spinning client with
        fabricated elapsed time). It needs no production change."""
        return self._try_read_calls

    def try_write_call_count(self) -> Int:
        """How many times `try_write` has been ENTERED. Same contract as
        `try_read_call_count`; the write-side half of a spin assertion."""
        return self._try_write_calls

    def capture_view(self) -> Span[UInt8, origin_of(self._write_capture)]:
        """Borrow the write-side capture buffer for assertion. Tests
        inspect this AFTER the client has run to verify it emitted the
        expected bytes."""
        return Span[UInt8](self._write_capture)

    def capture_len(self) -> Int:
        """Number of bytes the client has written to this stream."""
        return self._write_capture.__len__()

    def read_remaining(self) -> Int:
        """Bytes left in the read script (script len − cursor)."""
        return self._read_script.__len__() - self._read_cursor

    def read_cursor(self) -> Int:
        """Diagnostic: current read-cursor position — the number of script
        bytes this stream has handed out and NOT been given back. Used by
        the h1-keepalive-reuse test to inspect cursor advancement across
        cached-stream reuses, and by the message-boundary tests to assert
        that a body reader left the following response on the connection
        (`unread` rewinds this)."""
        return self._read_cursor

    # ----- IoStream trait ----------------------------------------------

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        """Replay-from-script try_read. The `reactor` argument is
        ignored (mock doesn't drive any I/O); the type-level parameter
        keeps the trait surface monomorphizable identically to
        KernelTcpConnector.

        Decision tree:
          1. If `_force_error_errno > 0`: clear + return error.
          2. If `_force_eof`: clear + return eof.
          3. If `_pending_on_read > 0`: decrement + return pending().
             Token encodes the cursor position so a future test
             harness can verify which Pending was returned.
          4. If `read_cursor == len(script)`: return eof.
          5. Else: copy at most `min(dst.len, remaining,
             _max_read_per_call_or_unlimited)` bytes into dst, advance
             cursor, return ready(n).
        """
        _ = reactor
        self._try_read_calls = self._try_read_calls + 1
        if self._force_error_errno > Int64(0):
            var errno = self._force_error_errno
            self._force_error_errno = Int64(0)
            return StreamIo.error(errno)
        if self._force_eof:
            self._force_eof = False
            return StreamIo.eof()
        if self._pending_on_read > 0:
            self._pending_on_read = self._pending_on_read - 1
            return StreamIo.pending(Int64(self._read_cursor))
        # ----- OFFSET-TRIGGERED FAULTS --------------------
        # Fire only once the cursor has REACHED the armed offset, i.e.
        # after exactly that many script bytes have been handed out. The
        # clamp further down guarantees the cursor lands ON the offset
        # rather than past it. Order: Pending (transient), Error, Eof.
        if (
            self._pending_at_offset >= 0
            and self._read_cursor >= self._pending_at_offset
            and self._pending_at_count > 0
        ):
            self._pending_at_count = self._pending_at_count - 1
            if self._pending_at_count <= 0:
                self._pending_at_offset = -1
            return StreamIo.pending(Int64(self._read_cursor))
        if (
            self._error_at_offset >= 0
            and self._read_cursor >= self._error_at_offset
        ):
            var at_errno = self._error_at_errno
            self._error_at_offset = -1
            self._error_at_errno = Int64(0)
            return StreamIo.error(at_errno)
        if self._eof_at_offset >= 0 and self._read_cursor >= self._eof_at_offset:
            self._eof_at_offset = -1
            return StreamIo.eof()
        var remaining = self._read_script.__len__() - self._read_cursor
        if remaining <= 0:
            # STALLED PEER: script exhausted but the peer is still holding
            # the connection open and sending nothing.
            if self._pending_after_script > 0:
                self._pending_after_script = self._pending_after_script - 1
                return StreamIo.pending(Int64(self._read_cursor))
            return StreamIo.eof()
        var n_to_copy = remaining
        if dst.__len__() < n_to_copy:
            n_to_copy = dst.__len__()
        if self._max_read_per_call > 0 and self._max_read_per_call < n_to_copy:
            n_to_copy = self._max_read_per_call
        # ⚠ CLAMP TO THE NEAREST ARMED OFFSET AHEAD OF THE CURSOR. Without
        # this a single oversized read straddles the boundary and the
        # fault lands LATE by however many bytes that read happened to
        # carry — so `arm_error_at(37, ...)` would deliver 100 bytes and
        # then the errno, and the assertion "exactly 37 bytes then
        # ECONNRESET" would be unwritable.
        n_to_copy = self._clamp_to_armed_offset(n_to_copy)
        # SAFETY: `dst` is a caller-frame-rooted Span[UInt8, _]; its
        # `unsafe_ptr()` points into the caller's buffer storage. The
        # script bytes live in `self._read_script` (List[UInt8]) at
        # `_read_cursor + i for i in [0, n_to_copy)`. memcpy is the
        # canonical encapsulated bulk-copy primitive — both pointers
        # are valid for the duration of this function frame, never
        # stored. Internal UnsafePointer use is allowed (not in a
        # public signature) per pointer-hierarchy item 4.
        # Bounds-check assertions above ensure n_to_copy <=
        # min(dst.__len__(), script-remaining).
        var dst_ptr = dst.unsafe_ptr()
        var src_ptr = self._read_script.unsafe_ptr() + self._read_cursor
        unsafe_memcpy(dest=dst_ptr, src=src_ptr, count=n_to_copy)
        self._read_cursor = self._read_cursor + n_to_copy
        return StreamIo.ready(Int64(n_to_copy))

    def unread(mut self, src: Span[UInt8, _]) raises:
        """IoStream override — REWIND the script cursor by `src`.

        For a scripted stream the script IS the wire, so a pushback and a
        rewind are the same operation and no side buffer is needed: after
        this call `read_cursor()` is exactly where it was before the bytes
        were handed out, and the next `try_read` replays them.

        ⛔ IT VERIFIES THE BYTES RATHER THAN TRUSTING THE COUNT, and that
        check is the whole reason this conformer is the one the boundary
        tests measure. `unread` has a contract — `src` must be the tail of
        what was just handed out — and a rewind by length alone would
        satisfy every cursor assertion in the suite while a caller handed
        back bytes it had invented. Here the original bytes are still in
        `_read_script`, so the contract is CHECKABLE, and checking it is
        what makes `read_cursor() == message_length` mean "the body gave
        back exactly the bytes it took" instead of "the body decremented a
        counter".
        """
        var n = src.__len__()
        if n == 0:
            return
        if n > self._read_cursor:
            raise Error(
                String("ScriptedStream.unread: asked to push back ")
                + String(n)
                + String(" byte(s) but only ")
                + String(self._read_cursor)
                + String(" have been read from the script")
            )
        var base = self._read_cursor - n
        var i = 0
        while i < n:
            if self._read_script[base + i] != src[i]:
                raise Error(
                    String(
                        "ScriptedStream.unread: pushback does not match the"
                        " bytes handed out (first mismatch at offset "
                    )
                    + String(i)
                    + String(" of ")
                    + String(n)
                    + String(")")
                )
            i = i + 1
        self._read_cursor = base

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        """Capture-on-write try_write. The `reactor` argument is
        ignored. Decision tree:
          1. If `_force_error_errno > 0`: clear + return error.
          2. If `_pending_on_write > 0`: decrement + return pending().
          3. Else: append all `src` bytes to `_write_capture` (and the
             optional shared-capture buffer), return ready(src.len).
        """
        _ = reactor
        self._try_write_calls = self._try_write_calls + 1
        if self._force_error_errno > Int64(0):
            var errno = self._force_error_errno
            self._force_error_errno = Int64(0)
            return StreamIo.error(errno)
        if self._pending_on_write > 0:
            self._pending_on_write = self._pending_on_write - 1
            return StreamIo.pending(Int64(self._write_capture.__len__()))
        # `arm_write_error_after` — fail having captured ZERO bytes. The
        # capture buffers are deliberately left untouched so a test can assert
        # "the request never reached the wire" on the buffer itself.
        if (
            self._write_error_errno > Int64(0)
            and self._writes_served >= self._write_error_after
        ):
            var werrno = self._write_error_errno
            self._write_error_errno = Int64(0)
            return StreamIo.error(werrno)
        self._writes_served = self._writes_served + 1
        var i = 0
        var n = src.__len__()
        # SHORT WRITE. A kernel socket takes only what fits in
        # its send buffer and reports that count; `s2n_send` does the same.
        # Accepting fewer than `src.__len__()` bytes and reporting the
        # honest count is the NORMAL case on a loaded socket, not an error
        # path — and it is the case this fixture could not express at all
        # before this clamp.
        if self._max_write_per_call > 0 and self._max_write_per_call < n:
            n = self._max_write_per_call
        while i < n:
            self._write_capture.append(src[i])
            # Mirror into the shared buffer (if any) so the captured bytes
            # survive this stream's drop — see `_shared_capture`.
            if self._shared_capture:
                self._shared_capture.value()[].append(src[i])
            i = i + 1
        return StreamIo.ready(Int64(n))

    def _clamp_to_armed_offset(self, n_to_copy: Int) -> Int:
        """Shrink `n_to_copy` so this read cannot deliver past the nearest
        armed fault offset AHEAD of the cursor.

        An offset already reached is handled by the fault checks at the
        top of `try_read` (they fire before any copy); this only stops a
        read from jumping OVER one."""
        var out = n_to_copy
        if (
            self._pending_at_offset > self._read_cursor
            and self._pending_at_count > 0
        ):
            var room = self._pending_at_offset - self._read_cursor
            if room < out:
                out = room
        if self._error_at_offset > self._read_cursor:
            var room_e = self._error_at_offset - self._read_cursor
            if room_e < out:
                out = room_e
        if self._eof_at_offset > self._read_cursor:
            var room_f = self._eof_at_offset - self._read_cursor
            if room_f < out:
                out = room_f
        return out

    def close(var self):
        """Drop the stream. The script + capture buffers drop with
        self via the implicit __del__."""
        # The List[UInt8] fields drop via the moved-self frame exit.
        _ = self._read_script^
        _ = self._write_capture^

    def negotiated_protocol(self) -> UInt8:
        return self._negotiated

    def fd(self) -> Int32:
        """ScriptedStream has no real kernel fd — returns -1. Consumers
        that DEPEND on a real fd (e.g., TlsConnector binding s2n to the
        fd) gracefully detect -1 and error.

        ⚠ THE DETECTION IS IN `TlsConnector._extract_fd`. Without it the
        dial still fails, but from inside `s2n_negotiate` with an
        `underlying I/O operation failed` errno that names neither the
        descriptor nor the connector."""
        return Int32(-1)


# =============================================================================
# ScriptedConnector — Connector conformer that hands out a pre-loaded stream.
# =============================================================================
#
# the test seam mandates that EVERY unit test that
# previously needed a real socket can instead substitute a
# ScriptedConnector that returns a pre-loaded ScriptedStream on connect.
#
# The connector holds an OPTIONAL pre-loaded stream. If `connect` is
# called and the stream is present, it's taken and returned. If absent,
# `connect` raises (test bug — the test didn't pre-load a stream).
#
# Optional design — tests construct + pre-load once + call connect
# once. Multi-connect tests use a List of streams (TODO in a future
# refinement; This version ships the single-connect case which covers ~80% of
# state-machine tests).

struct ScriptedConnector(Connector, Movable, Deinitable):
    """Mock Connector. Pre-loads a ScriptedStream; hands it
    out on connect(). The `[RT: Runtime]` parameterization is the same
    as KernelTcpConnector — tests get the same monomorphization shape.

    Construction:
      * `ScriptedConnector()` — empty. `connect()` will raise. The
        caller is expected to call `arm(stream)` to pre-load.
      * `ScriptedConnector.with_stream(s)` — pre-loaded. `connect()`
        returns `s` once.

    The mock pretends to be a TCP connector for the TransportKind sense
    (transport_kind() returns TRANSPORT_KIND_KERNEL_TCP). The codec
    layer above doesn't see the difference; the test substitution is
    invisible above the IoStream surface.
    """
    comptime Stream = ScriptedStream

    var _armed_stream: Optional[ScriptedStream]
    # count distinct connect calls. The fd-count=1
    # invariant assertion uses this counter — N sequential
    # HttpClient.send_buffered calls to the same origin via h2 must
    # result in connect_call_count==1 (multiplex reuse) instead of N.
    var _connect_call_count: Int
    # Additive test-fixture toggle (default False): make `is_tls()` report
    # True WITHOUT any real TLS, so a client that dials an `https://` URL
    # passes the `_scheme_check_or_raise` https-needs-TLS gate while still
    # running over the plaintext ScriptedStream. Used by tests for generated
    # clients that hardcode the `https` scheme (e.g. the REST codegen client).
    # The handshake is never exercised — this is purely the scheme-check claim.
    var _claim_tls: Bool
    # Additive FIFO of FURTHER streams, one per SUBSEQUENT dial (default
    # empty). `_armed_stream` alone models a client that dials once; a client
    # that RECONNECTS — the GOAWAY-unprocessed re-issue in
    # `GrpcClient._send_unary_bounded_goaway_retry`, any pool-eviction path —
    # dials again, and without a second stream `connect()` raises "no stream
    # armed", which a test would misread as the retry not having happened.
    # Queued via `arm_next`; drained oldest-first AFTER `_armed_stream`.
    var _queued_streams: List[ScriptedStream]
    # ★ THE HOSTS THE CLIENT SAID EACH DIAL WAS **FOR**, in dial order
    # (`Connector.set_dial_host`). A ScriptedConnector never handshakes, so it
    # cannot present an SNI — but it CAN record what it was TOLD, which is the
    # half of the contract the HTTP client owns. That makes "did this client
    # push the per-request host down to the transport, per request?" assertable
    # with ZERO sockets. `_connect_call_count` answers HOW MANY dials; this
    # answers WHERE each one was aimed.
    var _dial_hosts: List[String]
    # ----- CONNECT-PHASE FAULTS ---------------------------
    # Before these the connector COULD NOT FAIL: `connect` either handed
    # out an armed stream or raised "no stream armed", which is a TEST
    # BUG signal, not a dial outcome. So ECONNREFUSED, a connect that
    # never resolves, and SO_ERROR recovery after EINPROGRESS were all
    # inexpressible — even though this module's OWN docstring (lines
    # 20-22) names the last two as the reason the seam exists.
    #
    # ⚠ THE TRAIT IS SYNCHRONOUS. `Connector.connect` returns a Stream or
    # RAISES; there is no third outcome, so "still in progress" cannot be
    # REPRESENTED here however it is spelled. What these arms model is the
    # OBSERVABLE OUTCOME the caller sees, and each carries a distinct
    # `HttpError[CONNECT_FAILED]` detail so a test can tell them apart.
    # `_connect_errno > 0` is armed; each is ONE-SHOT, matching
    # `arm_eof` / `arm_error` on the stream side.
    var _connect_errno: Int64
    var _connect_never_resolves: Bool
    # Remaining dials to answer with the EINPROGRESS-shaped raise before
    # `_connect_in_progress_errno` is delivered. 0 = unarmed.
    var _connect_in_progress_remaining: Int
    var _connect_in_progress_errno: Int64

    def __init__(out self):
        self._armed_stream = Optional[ScriptedStream]()
        self._connect_call_count = 0
        self._claim_tls = False
        self._queued_streams = List[ScriptedStream]()
        self._dial_hosts = List[String]()
        self._connect_errno = Int64(0)
        self._connect_never_resolves = False
        self._connect_in_progress_remaining = 0
        self._connect_in_progress_errno = Int64(0)

    @staticmethod
    def with_stream(var stream: ScriptedStream) -> ScriptedConnector:
        """Construct with a pre-armed stream."""
        var c = ScriptedConnector()
        c._armed_stream = Optional[ScriptedStream](stream^)
        return c^

    @staticmethod
    def with_stream_tls(var stream: ScriptedStream) -> ScriptedConnector:
        """Construct with a pre-armed stream that REPORTS as TLS (`is_tls()`
        == True) without any real TLS — so a client dialing an `https://` URL
        passes the scheme-check gate while the bytes flow over the plaintext
        ScriptedStream. For tests of generated clients that hardcode `https`."""
        var c = ScriptedConnector()
        c._armed_stream = Optional[ScriptedStream](stream^)
        c._claim_tls = True
        return c^

    def arm(mut self, var stream: ScriptedStream):
        """Pre-load a stream. The next connect() call returns it.
        Replaces any previously-armed stream (drops the old one)."""
        # Drop the old stream (if any) before arming the new one.
        if self._armed_stream:
            var _old = self._armed_stream.take()
        self._armed_stream = Optional[ScriptedStream](stream^)

    def arm_next(mut self, var stream: ScriptedStream):
        """APPEND a stream for a SUBSEQUENT dial, without disturbing the one
        already armed. `arm` replaces; this queues.

        For tests of any client that RECONNECTS: dial K gets `_armed_stream`,
        dial K+1..K+N get the queued streams oldest-first. A test that asserts
        `connect_call_count() == N` is asserting the reconnects happened; the
        queue is what makes those dials serve DIFFERENT scripts (e.g. GOAWAY
        first, then a real response) instead of raising "no stream armed"."""
        self._queued_streams.append(stream^)

    def arm_connect_error(mut self, errno: Int64):
        """Make the NEXT `connect` raise `HttpError[CONNECT_FAILED]`
        carrying `errno` — ECONNREFUSED (111), EHOSTUNREACH (113), …

        This is the dial-refused outcome. Without it a test cannot
        distinguish "the client retried a failed dial" from "the test
        forgot to arm a stream", because both arrived as the same raise.
        ONE-SHOT: a subsequent dial falls through to the armed stream."""
        self._connect_errno = errno

    def arm_connect_never_resolves(mut self):
        """Make the NEXT `connect` raise the CONNECT-TIMEOUT-shaped
        outcome — the dial that is still in flight when the caller's
        `connect_timeout` expires.

        ⚠ HONEST ABOUT THE SEAM: `Connector.connect` is SYNCHRONOUS, so a
        fixture cannot literally hang without hanging the test process.
        What is modelled is the outcome the caller observes when a dial
        never resolves, which is the assertable half. A test that needs
        the deadline ARITHMETIC drives `TimeoutLayer` with an injected
        clock over this connector. ONE-SHOT."""
        self._connect_never_resolves = True

    def arm_connect_in_progress_then_error(
        mut self, in_progress_dials: Int, errno: Int64,
    ):
        """SO_ERROR RECOVERY. The next `in_progress_dials` dials raise the
        EINPROGRESS-shaped outcome (the socket is connecting; no verdict
        yet), and the dial AFTER them raises `errno` — the deferred error
        a real `connect(2)` reports through `getsockopt(SO_ERROR)` once
        the fd becomes writable.

        The failure this exists to catch is a client that treats the
        EINPROGRESS-shaped outcome as SUCCESS and proceeds to write on a
        socket whose connect ultimately failed."""
        self._connect_in_progress_remaining = in_progress_dials
        self._connect_in_progress_errno = errno

    def connect_call_count(self) -> Int:
        """Total connect calls this connector has serviced.
        Used by the fd-count=1 gate test — proves that multiple
        send_buffered calls via h2 multiplex result in exactly ONE
        connect (the second call reuses the pooled conn)."""
        return self._connect_call_count

    def set_dial_host(mut self, var host: String):
        """RECORD the host the next dial is FOR (`Connector.set_dial_host`).

        A ScriptedConnector performs no handshake, so it has no SNI to present
        — but the client's HALF of the contract is "push the per-request host
        down to the transport BEFORE dialing", and that half is exactly what a
        test needs to falsify. Appending here (rather than overwriting) keeps
        the ORDER, so a test can assert that dial 1 was for bucket A and dial 2
        for bucket B — the assertion "one process dialed two different hosts"
        is meaningless against a single last-write-wins slot."""
        self._dial_hosts.append(host^)

    def dial_hosts_len(self) -> Int:
        """How many `set_dial_host` pushes this connector has received."""
        return len(self._dial_hosts)

    def dial_host_at(self, i: Int) raises -> String:
        """The host of the i-th push, in push order. Raises on a bad index
        rather than returning an empty String — an out-of-range read that
        answered `""` would let a test assert against a host nobody ever
        pushed and call it a match."""
        if i < 0 or i >= len(self._dial_hosts):
            raise Error(
                String("ScriptedConnector.dial_host_at: index ")
                + String(i)
                + String(" out of range; ")
                + String(len(self._dial_hosts))
                + String(
                    " host(s) were pushed. A client that never called"
                    " set_dial_host pushes ZERO — which is the failure this"
                    " accessor exists to make visible."
                )
            )
        return self._dial_hosts[i].copy()

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> ScriptedStream:
        """Hand out the pre-armed stream. Raises if no stream was
        armed (test bug). The `reactor`/`ip_be`/`port` arguments are
        accepted to match the Connector trait signature; the mock
        ignores them (the test's pre-load encodes the per-endpoint
        choice)."""
        _ = reactor
        _ = ip_be
        _ = port
        self._connect_call_count = self._connect_call_count + 1
        # ----- CONNECT-PHASE FAULTS ----------------------
        # Checked BEFORE the armed stream is taken: a dial that fails must
        # not consume the script a later, successful dial is meant to
        # serve. That is what makes `arm_connect_error` + `arm` compose
        # into "the first dial is refused, the retry succeeds".
        if self._connect_in_progress_remaining > 0:
            self._connect_in_progress_remaining = (
                self._connect_in_progress_remaining - 1
            )
            raise Error(
                "HttpError[CONNECT_FAILED]: EINPROGRESS — dial #"
                + String(self._connect_call_count)
                + " has not resolved; SO_ERROR is not yet readable"
            )
        if self._connect_in_progress_errno > Int64(0):
            var so_errno = self._connect_in_progress_errno
            self._connect_in_progress_errno = Int64(0)
            raise Error(
                "HttpError[CONNECT_FAILED]: SO_ERROR errno="
                + String(Int(so_errno))
                + " — the dial resolved to a failure after EINPROGRESS"
            )
        if self._connect_never_resolves:
            self._connect_never_resolves = False
            raise Error(
                "HttpError[CONNECT_FAILED]: dial never resolved —"
                " connect_timeout would have fired on dial #"
                + String(self._connect_call_count)
            )
        if self._connect_errno > Int64(0):
            var c_errno = self._connect_errno
            self._connect_errno = Int64(0)
            raise Error(
                "HttpError[CONNECT_FAILED]: connect errno="
                + String(Int(c_errno))
                + " on dial #"
                + String(self._connect_call_count)
            )
        if self._armed_stream:
            return self._armed_stream.take()
        # Fall through to the `arm_next` FIFO (oldest-first) so a client that
        # RECONNECTS gets its own script per dial. `List.pop(0)` is the
        # front-take; the queue is a handful of entries in a test fixture.
        if len(self._queued_streams) > 0:
            return self._queued_streams.pop(0)
        raise Error(
            "ScriptedConnector.connect: no stream armed for dial #"
            + String(self._connect_call_count)
            + "; call arm() (first dial) / arm_next() (each reconnect)"
            + " before connect()"
        )

    def transport_kind(self) -> UInt8:
        """The mock pretends to be kernel TCP — the codec layer above
        cannot tell the difference (which is the point of the test
        seam). TRANSPORT_KIND_KERNEL_TCP."""
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        """ScriptedConnector is plaintext by default — tests that
        exercise TLS use TlsConnector[ScriptedConnector] composition.
        additive trait method. Returns `_claim_tls` (default False):
        a test built via `with_stream_tls` reports True to pass an
        `https://` client's scheme-check gate without real TLS."""
        return self._claim_tls
