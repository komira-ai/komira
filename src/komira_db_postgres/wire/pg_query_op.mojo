# =============================================================================
# komira_db_postgres/wire/pg_query_op.mojo — frame-resumable poll-shaped PG EXECUTE round-trip
# (start / poll / take_result).
# =============================================================================
# The pgwire READ as a frame-resumable state machine, so a worker can hold >1
# PG query in flight (park the frame on the reactor, serve the next request,
# resume when the fd is readable) instead of parking the whole worker thread
# inside `PgConnection.query_prepared`'s blocking `_read_one_message`. This is
# the foundation for suspendable request handlers.
#
# The blocking `PgConnection.query_prepared` / `query` path is unchanged (the
# blocking `recv_some` is a thin wrapper over the non-blocking
# `try_recv_some` — same drain-then-park-then-retry loop).
#
# ── SCOPE ────────────────────────────────────────────────────────────────────
# This op poll-shapes the EXECUTE round-trip on a PRE-PREPARED PreparedStatement
# (Bind/Execute/Sync → drain DataRows → ReadyForQuery), which collapses the
# query to ONE poll-shaped round-trip — the bulk of the read serialization.
# `prepare` / `close_prepared` still run blocking before/after the op. For the
# dominant shape (a cached prepared statement, executed many times) the
# execute round-trip is the one that matters.
#
# ── TWO PIECES ───────────────────────────────────────────────────────────────
#   1. `PgReadFrame` — the critical framing-cursor + row-drain state
#      machine. Owns the partial read buffer (`_rbuf` / `_rpos`) + the row
#      accumulators as PLAIN VALUE fields, and exposes:
#        * `feed(bytes)`             — append a chunk of plaintext.
#        * `drain_complete()`        — fold every fully-buffered message into the
#                                      accumulators; set READY on ReadyForQuery /
#                                      ERR on ErrorResponse or a truncated
#                                      DataRow/RowDescription. Returns True at
#                                      a terminal. NEVER holds a Span of `_rbuf`
#                                      across the boundary (each message parsed +
#                                      copied out in a tight scope).
#      This is recv-source-AGNOSTIC: it never touches a socket / s2n / reactor,
#      so it is directly unit-testable over a plaintext socketpair feeding REAL
#      pgwire-framed bytes — which is how the tests prove the framing-cursor
#      re-park (a message split across two recvs makes `drain_complete` return
#      "need more" and the frame re-park) and the peak-inflight>1 multiplex.
#      The op feeds it s2n-decrypted bytes; the test feeds it plaintext bytes.
#      SAME framing machinery either way.
#   2. `PgQueryOp` — the reactor binding: owns a `PgConnection` (the s2n recv
#      source) + a `PgReadFrame`, and drives the non-blocking recv → feed →
#      drain → re-park loop over the reactor.
#
# ── THE FRAME OWNERSHIP (load-bearing) ───────────────────────────────────────
# `PgQueryOp` OWNS its `PgConnection` BY VALUE: the s2n mid-TLS-record
# reassembly state lives INSIDE the owned `PgConnection._stream`, and the
# framing cursor lives in the owned `PgReadFrame` — so moving the op (or its
# containing OwnedPointer frame) moves BOTH with it, pinned to one heap-stable
# address across every park. We NEVER return the leased connection to the pool
# while the op is parked (that would alias s2n's mid-record state), and we
# NEVER hold a Span/ref of `_rbuf` across a park — `PgReadFrame.drain_complete`
# parses each message in a tight scope and folds it before the next recv.
# Every field is a value type; the accumulators (`_rows: List[PgRow]`,
# `_col_*`) are plain single-level heap containers on a struct reached via an
# OwnedPointer frame, NEVER in a byte-slab and NEVER cast through a wildcard
# origin. `PgRow` is the flat single-level layout (pg_types.mojo) that is
# safe in a growing `List[PgRow]`.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ZERO UnsafePointer in any public signature. ZERO wildcard origin. ZERO
# unsafe_from_address. The reactor is threaded per-call (`mut reactor:
# Reactor[RT.Sink]`), never stored as a field. The fd the op parks on comes from
# the owned connection's stream, resolved fresh at each start/poll (no stored
# borrowed pointer).
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db_postgres.wire.connection import PgConnection, PreparedStatement
from komira_db_postgres.wire.pg_tls import PG_RECV_DONE, PG_RECV_PENDING, PG_RECV_EOF
from komira_db_postgres.wire.pg_types import (
    PgValue,
    PgRow,
    PgRows,
    PgError,
    binary_row_from_data_message,
)
from komira_db_postgres.wire.pgwire import (
    ErrorFields,
    BackendMessage,
    first_message_byte_len,
    parse_one_message,
    parse_row_description,
    parse_error_fields,
    MSG_BIND_COMPLETE,
    MSG_ROW_DESC,
    MSG_DATA_ROW,
    MSG_CMD_COMPLETE,
    MSG_EMPTY_QUERY,
    MSG_ERROR,
    MSG_READY,
)


# -----------------------------------------------------------------------------
# Build a descriptive error string from parsed ErrorResponse fields (mirrors
# connection.mojo's private `_pg_error_from_fields`, here for the op).
# -----------------------------------------------------------------------------
def _pg_error_text(ef: ErrorFields) -> String:
    return PgError(
        ef.severity, ef.sqlstate, ef.message, ef.detail, False
    ).to_string()


# -----------------------------------------------------------------------------
# Op / frame lifecycle status.
# -----------------------------------------------------------------------------
comptime PG_OP_PENDING: UInt8 = 0  # awaiting more bytes; park on _op_id
comptime PG_OP_READY: UInt8 = 1  # ReadyForQuery seen; rows complete; take_result
comptime PG_OP_ERR: UInt8 = 2  # backend ErrorResponse or transport error


# =============================================================================
# §1 — PgReadFrame — the critical framing-cursor + row-drain state.
# =============================================================================
struct PgReadFrame(Movable, Deinitable):
    """The recv-source-AGNOSTIC framing cursor + result accumulator that
    survives across reactor parks. Owns the partial read buffer (`_rbuf` /
    `_rpos`) + the row accumulators as plain VALUE fields, so when the frame is
    moved (into an op, into an OwnedPointer suspended-frame, between workers)
    the partial-read state moves with it, pinned to one heap-stable address.

    The caller (the op) feeds plaintext chunks via `feed` and drains complete
    messages via `drain_complete`; the frame never touches a socket / s2n /
    reactor. This keeps the critical logic (the framing cursor + the DataRow
    fold) in ONE tested place, independent of the s2n transport — the tests
    drive THIS frame directly over plaintext pgwire bytes.

    Heap audit: every field is a single-level heap container (`List[UInt8]` /
    `Int` / `List[PgRow]` / `List[UInt32]` / `List[String]`). NEVER stored in a
    byte-slab and NEVER cast through a wildcard origin."""

    var _rbuf: List[UInt8]
    var _rpos: Int
    var _state: UInt8
    var _rows: List[PgRow]
    var _col_oids: List[UInt32]
    var _col_names: List[String]
    var _err_text: String

    def __init__(out self, var col_oids: List[UInt32], var col_names: List[String]):
        """Seed the frame with the result column metadata (the prepared
        statement's Describe OIDs + names — authoritative for the closed set; a
        RowDescription on the wire overrides them if present)."""
        self._rbuf = List[UInt8]()
        self._rpos = 0
        self._state = PG_OP_PENDING
        self._rows = List[PgRow]()
        self._col_oids = col_oids^
        self._col_names = col_names^
        self._err_text = String("")

    @always_inline
    def is_pending(self) -> Bool:
        return self._state == PG_OP_PENDING

    @always_inline
    def is_ready(self) -> Bool:
        return self._state == PG_OP_READY

    @always_inline
    def is_error(self) -> Bool:
        return self._state == PG_OP_ERR

    def err_text(self) -> String:
        return self._err_text

    def row_count(self) -> Int:
        return len(self._rows)

    def feed(mut self, bytes: List[UInt8]):
        """Append a chunk of plaintext to the read buffer (the bytes a recv
        produced). Pure value-append; no borrow held."""
        for i in range(len(bytes)):
            self._rbuf.append(bytes[i])

    def _compact(mut self):
        """Drop the consumed prefix [0:_rpos), resetting _rpos to 0. Mirrors
        connection.mojo's `_compact`."""
        if self._rpos == 0:
            return
        var tail = List[UInt8]()
        for i in range(self._rpos, len(self._rbuf)):
            tail.append(self._rbuf[i])
        self._rbuf = tail^
        self._rpos = 0

    def _try_next_message(mut self) -> Optional[BackendMessage]:
        """Non-blocking framing step: parse + return the next COMPLETE message
        (advancing `_rpos`), or None if the buffer holds no complete message.

        PARK-BUFFER (load-bearing): the length + parse happen inside a
        TIGHT scope so the Span borrow of `self._rbuf` is fully DEAD before we
        mutate self. The returned BackendMessage OWNS its body bytes (copied out
        by parse_one_message) so it carries NO borrow of `_rbuf` across the
        subsequent feed/recv. Identical discipline to
        connection.mojo's `_read_one_message`, here split so the op can
        interleave parks between messages."""
        var consumed = first_message_byte_len(
            Span[UInt8](self._rbuf)[self._rpos : len(self._rbuf)]
        )
        if consumed <= 0:
            return Optional[BackendMessage]()
        var msg = parse_one_message(
            Span[UInt8](self._rbuf)[self._rpos : len(self._rbuf)]
        )
        self._rpos += consumed
        if self._rpos == len(self._rbuf):
            self._rbuf = List[UInt8]()
            self._rpos = 0
        elif self._rpos > 65536:
            self._compact()
        return Optional[BackendMessage](msg^)

    def drain_complete(mut self) -> Bool:
        """Fold every COMPLETE message currently buffered into the accumulators.
        Returns True iff a TERMINAL message (ReadyForQuery → READY, or
        ErrorResponse → ERR) was reached (in which case `_state` is set). Returns
        False when the buffer is exhausted of complete messages without a
        terminal — the op needs more bytes and re-parks."""
        if self._state != PG_OP_PENDING:
            return True
        var guard = 0
        while guard < 1_000_000:
            var maybe = self._try_next_message()
            if not maybe:
                return False  # no more complete messages buffered
            var m = maybe.take()
            var t = m.msg_type
            if t == MSG_DATA_ROW or t == MSG_ROW_DESC:
                # A body shorter than its declared counts is a protocol
                # fault: land ERR with the decoder's text (as for EOF).
                try:
                    self._fold_row_message(m)
                except e:
                    self.mark_error(String(e))
                    return True
            elif t == MSG_CMD_COMPLETE:
                pass  # rows_affected available via the tag if needed
            elif t == MSG_BIND_COMPLETE:
                pass
            elif t == MSG_EMPTY_QUERY:
                pass
            elif t == MSG_ERROR:
                var ef = parse_error_fields(m)
                self._err_text = _pg_error_text(ef)
                self._state = PG_OP_ERR
                return True
            elif t == MSG_READY:
                self._state = PG_OP_READY
                return True
            else:
                pass  # NoticeResponse / ParameterStatus — ignore mid-result
            guard += 1
        return False

    def _fold_row_message(mut self, m: BackendMessage) raises:
        """Fold a DataRow into `_rows` or a RowDescription into the column
        metadata. Raises when the message body is truncated."""
        if m.msg_type == MSG_DATA_ROW:
            self._rows.append(binary_row_from_data_message(m, self._col_oids))
            return
        var cols = parse_row_description(m)
        if len(cols) > 0:
            self._col_names = List[String]()
            self._col_oids = List[UInt32]()
            for c in cols:
                self._col_names.append(c.name)
                self._col_oids.append(c.type_oid)

    def mark_error(mut self, msg: String):
        """Set the frame to the ERR terminal with `msg` (transport-level errors
        the op detects: EOF mid-result, a truncated DataRow/RowDescription
        body, etc.)."""
        self._state = PG_OP_ERR
        self._err_text = msg

    def take_result(mut self) -> PgRows:
        """Move the materialized rows + column names out (caller checks
        is_ready())."""
        var rows = self._rows^
        self._rows = List[PgRow]()
        var names = self._col_names^
        self._col_names = List[String]()
        return PgRows(rows^, names^)


# =============================================================================
# §2 — PgQueryOp — the reactor binding (PgConnection + PgReadFrame).
# =============================================================================
struct PgQueryOp(Movable, Deinitable):
    """A frame-resumable poll-shaped PG EXECUTE round-trip over a PRE-PREPARED
    statement. OWNS its `PgConnection` (the s2n recv source — pins the s2n
    mid-record state across parks) + a `PgReadFrame` (the framing cursor +
    accumulators). Drive shape:

      start(reactor, stmt, params) -> Int64
        Send Bind/Execute/Sync for `stmt` + `params`, register the conn fd for
        read-readiness under a fresh op_id, make ONE non-blocking drain attempt.
        Returns the op_id to park the FRAME on. On the immediate-ready fast path
        the op_id is deregistered before returning.

      poll(reactor) -> UInt8
        The driver calls this when a Completion for `_op_id` arrives. Make ONE
        non-blocking recv cycle (feed → drain), return READY once ReadyForQuery
        is seen (else PENDING → re-park on the SAME op_id).

      take_result() -> PgRows / into_connection() -> PgConnection
        Move the rows out, then CONSUME the op to recover the leased connection
        (ONLY when done — never while parked).

    Movable, NOT Copyable. Every field is a value type with NO
    borrowed/wildcard ref into the worker's stack or reactor."""

    # The leased connection, OWNED by value (pins the s2n mid-record state).
    # Wrapped in Optional so `into_connection` can extract it via the safe
    # partial-move primitive `Optional.take()` — a bare
    # `self._conn^` from a `var self` with sibling heap fields is rejected by
    # Mojo 1.0.0b1 ("field destroyed out of the middle of a value").
    var _conn: Optional[PgConnection]
    # The framing cursor + accumulators (pins the partial read buffer).
    var _frame: PgReadFrame
    # The reactor op_id the frame parks on (0 until start). The fd is resolved
    # fresh from `_conn` at each register — never stored as a pointer.
    var _op_id: Int64
    var _registered: Bool

    def __init__(out self, var conn: PgConnection):
        """Construct an op around an already-connected, IDLE `PgConnection`
        (moved in; the op owns it for the round-trip). The frame is seeded empty;
        `start` fills the column metadata from the prepared statement."""
        self._conn = Optional[PgConnection](conn^)
        self._frame = PgReadFrame(List[UInt32](), List[String]())
        self._op_id = Int64(0)
        self._registered = False

    @always_inline
    def is_pending(self) -> Bool:
        return self._frame.is_pending()

    @always_inline
    def is_ready(self) -> Bool:
        return self._frame.is_ready()

    @always_inline
    def is_error(self) -> Bool:
        return self._frame.is_error()

    @always_inline
    def op_id(self) -> Int64:
        return self._op_id

    def err_text(self) -> String:
        return self._frame.err_text()

    def start[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        stmt: PreparedStatement,
        params: List[PgValue],
    ) raises -> Int64:
        """Kick off the EXECUTE round-trip. Seeds the frame's column metadata
        from the prepared statement, sends Bind/Execute/Sync, registers the conn
        fd under a fresh op_id, and makes ONE non-blocking drain attempt."""
        # Seed the frame with the prepared statement's result column metadata.
        var col_oids = List[UInt32]()
        for o in stmt.result_oids:
            col_oids.append(o)
        var col_names = List[String]()
        for c in range(stmt.result_column_count()):
            col_names.append(stmt.result_column_name(c))
        self._frame = PgReadFrame(col_oids^, col_names^)

        # Send Bind/Execute/Sync (parks on would-block; small + fast — the
        # READ is what is poll-shaped).
        self._conn.value().send_bind_execute_prepared[RT](reactor, stmt, params)

        # Register the fd for read-readiness under a fresh op_id, then attempt
        # one non-blocking drain (bytes may already be on the socket).
        var fd = self._conn.value().stream_fd()
        self._op_id = reactor.alloc_op_id()
        reactor.register_read(fd, self._op_id, UInt16(0))
        self._registered = True
        self._drain_nonblocking[RT](reactor)
        if not self._frame.is_pending() and self._registered:
            reactor.deregister(self._op_id)
            self._registered = False
        return self._op_id

    def poll[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> UInt8:
        """The driver calls this when a Completion for `_op_id` arrives. Make
        ONE non-blocking recv cycle; return the new state. On READY/ERR the fd
        registration is removed; on PENDING the driver re-parks on the SAME
        op_id (the registration is still live)."""
        if not self._frame.is_pending():
            return self._frame_state()
        self._drain_nonblocking[RT](reactor)
        if not self._frame.is_pending() and self._registered:
            reactor.deregister(self._op_id)
            self._registered = False
        return self._frame_state()

    @always_inline
    def _frame_state(self) -> UInt8:
        if self._frame.is_ready():
            return PG_OP_READY
        if self._frame.is_error():
            return PG_OP_ERR
        return PG_OP_PENDING

    def _drain_nonblocking[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        """One non-blocking recv cycle: drain already-buffered messages, then do
        non-blocking recvs (feeding the frame) until a terminal lands or s2n
        would-block. The recv NEVER parks — on PENDING the op stays PENDING and
        the FRAME re-parks on `_op_id`.

        Framing discipline: `PgReadFrame.drain_complete` parses each
        message in a tight scope (no Span of the frame's `_rbuf` survives), and
        the recv decrypts into a fresh local chunk that `_pump_recv` feeds (by
        move) into the frame — no borrowed slice of any buffer is live across the
        recv (which itself never parks; on would-block the FRAME re-parks)."""
        # Drain any messages already fully buffered from a prior recv cycle.
        if self._frame.drain_complete():
            return
        var guard = 0
        while guard < 1_000_000:
            var status = self._pump_recv[RT](reactor)
            if status == PG_RECV_PENDING:
                return  # would-block; stay PENDING; the frame re-parks on _op_id
            if status == PG_RECV_EOF:
                self._frame.mark_error(
                    String("pg_query_op: peer closed before ReadyForQuery")
                )
                return
            # PG_RECV_DONE: bytes fed into the frame. Drain; terminal → done,
            # else loop (s2n may have more decrypted records pending).
            if self._frame.drain_complete():
                return
            guard += 1

    def _pump_recv[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> UInt8:
        """One non-blocking recv into a fresh chunk, fed into the frame. Returns
        PG_RECV_{DONE,PENDING,EOF}. The connection decrypts into a local buffer
        (NOT a shared `_rbuf`) and returns the OWNED bytes; the frame owns the
        ONLY framing cursor. No borrow crosses a park; the recv never parks."""
        var res = self._conn.value().try_recv_chunk[RT](reactor, 16384)
        var status = res[0]
        if status == PG_RECV_DONE:
            self._frame.feed(res[2])
        return status

    def take_result(mut self) -> PgRows:
        """Move the materialized rows out (caller checks is_ready())."""
        return self._frame.take_result()

    def into_connection(mut self) -> PgConnection:
        """Return the leased connection so it can be returned to the pool. Call
        ONLY after the op is fully done (is_ready / is_error) — NEVER while
        parked (returning a pooled conn while parked would alias s2n's mid-record
        state). Extracts the connection via `Optional.take()` (the safe
        partial-move primitive), leaving `_conn` in the None
        state (the op must not be re-driven after this). The op's own destructor
        then drops the empty Optional + the frame cleanly."""
        return self._conn.take()
