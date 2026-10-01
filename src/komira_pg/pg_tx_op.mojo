# =============================================================================
# komira_pg/pg_tx_op.mojo — PgTxAsyncOp: a poll-shaped MULTI-STATEMENT
# transaction over a single HELD connection.
# =============================================================================
# The single-EXECUTE `PgQueryOp` poll-shapes ONE round-trip. An application
# WRITE is rarely one statement: creating a row with an audit event is
# `BEGIN`, `INSERT row`, `INSERT row_event`, `COMMIT`, and an optimistic
# update is `BEGIN`, `UPDATE … WHERE version=$`, `INSERT row_event`, `COMMIT`.
# Those statements MUST run inside ONE transaction on ONE connection
# (atomicity: a crash cannot leave a created row with no `created` event), and
# a poll-shaped handler must park between each statement WITHOUT releasing the
# connection (releasing a leased conn mid-TX would alias s2n's mid-record
# state AND abort the open TX).
#
# `PgTxAsyncOp` is the REUSABLE primitive for that. It OWNS a `PgConnection`
# by value (pinned across every park) and drives an ORDERED list of
# statements as a single `AsyncOp`:
#
#   BEGIN → step[0] → step[1] → … → step[n-1] → COMMIT
#
# with MULTIPLE reactor parks WITHIN one op (one park per statement's read
# round-trip). On ANY statement error it switches to `ROLLBACK`, drains it, and
# resolves the op ERR (carrying the original error text) — never leaving a
# dangling open transaction. The connection is recovered cleanly via
# `into_connection()` (the caller's give-back) once the op is fully done.
#
# ── THE STEP MODEL ───────────────────────────────────────────────────────────
# A `TxStep` is one statement: either a SIMPLE-query string (`BEGIN` / `COMMIT`
# / `ROLLBACK`, or any one-shot SQL) OR a PRE-PREPARED `PreparedStatement` +
# its `PgValue` binds (the `INSERT` / `UPDATE` / `SELECT`). The caller supplies
# the BUSINESS steps (the INSERTs / UPDATEs in order); the op auto-wraps them in
# `BEGIN` … `COMMIT` and owns the `ROLLBACK` error path. Each step drives the
# SAME `PgReadFrame` framing-cursor machinery `PgQueryOp` uses (the critical
# message fold) — so the TX op reuses the read path verbatim, only sequencing
# multiple sends over the held connection.
#
# ── THE PARK CONTRACT (multiple parks within one AsyncOp) ────────────────────
# The driver re-reads `op_id()` on every PENDING poll and re-parks on the
# CURRENT op_id. So the TX op allocates a FRESH op_id per statement: when
# statement N completes (frame READY), `poll` advances to statement N+1, sends
# it, registers a fresh op_id, and returns PENDING — the driver re-parks on
# the new op_id. The op resolves READY only after `COMMIT`'s ReadyForQuery;
# ERR only after `ROLLBACK` drains following a statement error.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ZERO UnsafePointer in any public signature. ZERO wildcard origin. ZERO
# unsafe_from_address. The reactor is threaded per-call, never stored. The op
# OWNS its `PgConnection` (wrapped in Optional so `into_connection` extracts it
# via the safe partial-move `Optional.take()`). Every field is a single-level
# value/heap container (`PgConnection` / `PgReadFrame` / `List[TxStep]` /
# `Int` / `Bool` / `String`); the step list holds plain value carriers (String
# + Copyable `PreparedStatement` + `List` binds), NEVER a byte-slab, NEVER
# cast through a wildcard origin. Movable, NOT Copyable (single owner of the
# connection).
# =============================================================================

from std.utils import Variant

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_pg.connection import PgConnection, PreparedStatement
from komira_pg.pg_tls import PG_RECV_DONE, PG_RECV_PENDING, PG_RECV_EOF
from komira_pg.pg_types import PgValue, PgRows, PgRow
from komira_pg.pg_query_op import (
    PgReadFrame,
    PG_OP_PENDING,
    PG_OP_READY,
    PG_OP_ERR,
)


# =============================================================================
# §0 — TxStep — one statement in the transaction (simple OR prepared).
# =============================================================================
# A simple-query step carries the SQL text (`BEGIN` / `COMMIT` / `ROLLBACK` or
# any one-shot statement). A prepared step carries the pre-prepared statement +
# its `PgValue` binds. Both drive the SAME `PgReadFrame` read path; only the
# SEND differs (`send_simple_query` vs `send_bind_execute_prepared`). A flat
# value carrier (String + Copyable PreparedStatement + List[PgValue]) —
# never byte-slab-stored.


# The per-step result-dependent ROLE a business step plays in a CAS transaction.
# These extend the plain "send + drain" step with the two result-dependent
# behaviours a CAS-UPDATE-and-append transaction needs, WITHOUT a second op or
# a wildcard cast:
#   * _STEP_ROLE_PLAIN     — the existing behaviour: send, drain, advance.
#   * _STEP_ROLE_SEQ_SELECT — a `SELECT COALESCE(MAX(seq),0)+1 …` whose single
#                             int8 result is CAPTURED into the TX's `_seq_value`
#                             so a later step can bind it (a per-key event seq,
#                             read INSIDE the TX — NOT a compile-time constant).
#   * _STEP_ROLE_CAS        — a `UPDATE … WHERE id=$ AND version=$ … RETURNING id`
#                             whose ROW COUNT is the CAS outcome: 0 rows ⇒ the
#                             optimistic-concurrency CAS MISSED (a stale version /
#                             an archived row) ⇒ the TX fails with the
#                             step's CAS-miss text (`TxStep.cas`) ⇒ ROLLBACK
#                             ⇒ ERR (e.g. the caller renders a 409). A non-zero count ⇒
#                             the CAS hit ⇒ the TX continues.
# A prepared step may ALSO declare a `_seq_bind_idx >= 0`: before SEND, the TX
# patches `_binds[_seq_bind_idx]` to the captured `_seq_value` (the event INSERT's
# seq parameter), so the seq the SEQ_SELECT read INSIDE the TX is the seq the
# event row is written with.
comptime _STEP_ROLE_PLAIN: UInt8 = 0
comptime _STEP_ROLE_SEQ_SELECT: UInt8 = 1
comptime _STEP_ROLE_CAS: UInt8 = 2

# The DEFAULT error text the TX fails with when a CAS step returns 0 rows. A
# caller that keys a conflict response (e.g. an HTTP 409) off the miss text
# supplies its own text per CAS step (`TxStep.cas(..., miss_text)`), so the
# text it matches on is the one it chose; this default is used otherwise.
comptime PG_TX_CAS_MISS_MARKER: String = (
    "concurrent modification: CAS step matched no row"
)


struct TxStep(Movable, Copyable, Deinitable):
    """One transactional statement: a SIMPLE-query string OR a PREPARED
    statement + binds. `_is_prepared` selects the SEND path. For a simple step
    `_sql` holds the statement text and `_binds` is empty; for a prepared step
    `_stmt` holds the handle, `_binds` the parameters, and `_sql` is unused.

    `_role` selects a RESULT-DEPENDENT behaviour (PLAIN / SEQ_SELECT / CAS — see
    the role constants above); `_seq_bind_idx >= 0` marks a prepared bind slot
    the TX patches to the captured per-key seq before SEND. Plain steps use
    the defaults (PLAIN, -1); CAS transactions set the roles.

    Copyable (so it can be stored in a `List[TxStep]`) — every field is a
    Copyable single-level value/heap container (Bool + String + the
    flat-storage `PreparedStatement` + `List[PgValue]` + scalar `UInt8`/`Int`)."""

    var _is_prepared: Bool
    var _sql: String
    var _stmt: PreparedStatement
    var _binds: List[PgValue]
    # The result-dependent role (PLAIN / SEQ_SELECT / CAS).
    var _role: UInt8
    # If >= 0, the index in `_binds` the TX patches to the captured seq pre-SEND.
    var _seq_bind_idx: Int
    # The error text a CAS-role step fails the TX with on a zero-row result.
    # Unused by the other roles.
    var _cas_miss_text: String

    @staticmethod
    def simple(var sql: String) -> TxStep:
        """A simple-query step (`BEGIN` / `COMMIT` / `ROLLBACK` / one-shot SQL).
        """
        return TxStep(
            _is_prepared=False,
            _sql=sql^,
            _stmt=PreparedStatement(
                String(""),
                List[UInt32](),
                List[UInt32](),
                List[UInt8](),
                List[Int](),
            ),
            _binds=List[PgValue](),
            _role=_STEP_ROLE_PLAIN,
            _seq_bind_idx=-1,
        )

    @staticmethod
    def prepared(var stmt: PreparedStatement, var binds: List[PgValue]) -> TxStep:
        """A prepared-statement step (`INSERT` / `UPDATE` / `SELECT`) executed
        with `binds` (extended-protocol Bind/Execute/Sync)."""
        return TxStep(
            _is_prepared=True,
            _sql=String(""),
            _stmt=stmt^,
            _binds=binds^,
            _role=_STEP_ROLE_PLAIN,
            _seq_bind_idx=-1,
        )

    @staticmethod
    def seq_select(var stmt: PreparedStatement, var binds: List[PgValue]) -> TxStep:
        """A `SELECT COALESCE(MAX(seq),0)+1 FROM <events> WHERE <key>=$1` step:
        the TX captures its single int8 result into `_seq_value` so a later event
        INSERT (declaring a `seq_bind_idx`) binds it. Read INSIDE the TX so the
        seq is consistent under the row's version-CAS."""
        return TxStep(
            _is_prepared=True,
            _sql=String(""),
            _stmt=stmt^,
            _binds=binds^,
            _role=_STEP_ROLE_SEQ_SELECT,
            _seq_bind_idx=-1,
        )

    @staticmethod
    def cas(
        var stmt: PreparedStatement,
        var binds: List[PgValue],
        var miss_text: String = PG_TX_CAS_MISS_MARKER,
    ) -> TxStep:
        """A `UPDATE … WHERE id=$ AND version=$ … RETURNING id` CAS step: the TX
        treats a ZERO-ROW result as the CAS MISS (a stale version / an archived
        row) and fails the TX with `miss_text` (→ ROLLBACK → ERR → e.g. a 409 at
        the caller, which matches on the text it passed; default
        `PG_TX_CAS_MISS_MARKER`). A non-zero result continues the TX. The
        `RETURNING id` is what makes the affected-row count visible as DataRows
        (the frame captures DataRows, not the CommandComplete tag)."""
        return TxStep(
            _is_prepared=True,
            _sql=String(""),
            _stmt=stmt^,
            _binds=binds^,
            _role=_STEP_ROLE_CAS,
            _seq_bind_idx=-1,
            _cas_miss_text=miss_text^,
        )

    @staticmethod
    def prepared_seq_bound(
        var stmt: PreparedStatement, var binds: List[PgValue], seq_bind_idx: Int
    ) -> TxStep:
        """A prepared INSERT whose bind at `seq_bind_idx` is PATCHED to the
        per-key seq the SEQ_SELECT step captured, just before SEND. The event
        INSERT uses this so its `seq` column is the value read INSIDE the TX."""
        return TxStep(
            _is_prepared=True,
            _sql=String(""),
            _stmt=stmt^,
            _binds=binds^,
            _role=_STEP_ROLE_PLAIN,
            _seq_bind_idx=seq_bind_idx,
        )

    def __init__(
        out self,
        var _is_prepared: Bool,
        var _sql: String,
        var _stmt: PreparedStatement,
        var _binds: List[PgValue],
        var _role: UInt8 = _STEP_ROLE_PLAIN,
        var _seq_bind_idx: Int = -1,
        var _cas_miss_text: String = String(""),
    ):
        self._is_prepared = _is_prepared
        self._sql = _sql^
        self._stmt = _stmt^
        self._binds = _binds^
        self._role = _role
        self._seq_bind_idx = _seq_bind_idx
        self._cas_miss_text = _cas_miss_text^


# =============================================================================
# §1 — PgTxAsyncOp — the held-connection multi-statement transaction op.
# =============================================================================
# The op's internal cursor walks: BEGIN → the business steps → COMMIT, one read
# round-trip at a time. On a statement error it walks to ROLLBACK, drains it,
# and lands ERR. The connection is held across every park; recovered via
# `into_connection()` once done. NOTE: `take_result()` returns the LAST step's
# rows (the rows from the final business statement before COMMIT — e.g. a CAS
# UPDATE's affected-row count or a RETURNING projection); for a create whose
# carry is built in Mojo (no RETURNING), the caller ignores the (empty) rows.


# The TX-cursor phases.
comptime _TX_PHASE_BEGIN: UInt8 = 0  # running BEGIN
comptime _TX_PHASE_STEP: UInt8 = 1  # running business step `_step_idx`
comptime _TX_PHASE_COMMIT: UInt8 = 2  # running COMMIT
comptime _TX_PHASE_ROLLBACK: UInt8 = 3  # running ROLLBACK (error path)
comptime _TX_PHASE_DONE_OK: UInt8 = 4  # COMMIT's ReadyForQuery seen
comptime _TX_PHASE_DONE_ERR: UInt8 = 5  # ROLLBACK drained after an error


struct PgTxAsyncOp(Movable, Deinitable):
    """A poll-shaped multi-statement transaction over a single HELD connection.
    OWNS its `PgConnection` by value (pins the s2n mid-record state across every
    park) + a `PgReadFrame` (reset per statement). Drives `BEGIN` → the business
    steps → `COMMIT` one read round-trip at a time, parking between each on a
    fresh op_id. On a statement error it runs `ROLLBACK` and resolves ERR with
    the original error text. Movable, NOT Copyable.

    `Out = PgRows` — the last business statement's rows (empty for a no-RETURNING
    INSERT; the caller projects its result in Mojo). The terminal projection is
    the wrapping AsyncOp's concern."""

    # The leased connection, OWNED by value. Optional so `into_connection` can
    # extract it via the safe partial-move `Optional.take()`.
    var _conn: Optional[PgConnection]
    # The framing cursor + accumulators (reset at the start of each statement).
    var _frame: PgReadFrame
    # The business statements (BEGIN/COMMIT auto-wrapped; ROLLBACK owned).
    var _steps: List[TxStep]
    # The TX cursor: which phase + (in _TX_PHASE_STEP) which business step.
    var _phase: UInt8
    var _step_idx: Int
    # The reactor op_id the current statement parks on (fresh per statement).
    var _op_id: Int64
    var _registered: Bool
    # The rows from the last business statement (moved into the frame's
    # accumulator, taken out at each statement boundary; the final one is `Out`).
    var _last_rows: PgRows
    # On the error path, the original error text (the ROLLBACK's own result is
    # discarded; this is what `err_text()` surfaces).
    var _err_text: String
    # The per-key event seq captured from a SEQ_SELECT step's single int8 result
    # (read INSIDE the TX). A later prepared step with `_seq_bind_idx >= 0`
    # binds it. Int64(0) until a SEQ_SELECT runs.
    var _seq_value: Int64
    # The ORDERED log of statement labels actually issued (BEGIN / step-N / COMMIT
    # / ROLLBACK). Recorded at SEND time so a driver-level test can assert the
    # exact statement SEQUENCE (and the ROLLBACK on the error path) without a live
    # PG — the sequencing is what the test pins.
    var _executed: List[String]

    def __init__(out self, var conn: PgConnection, var steps: List[TxStep]):
        """Construct a TX op around an already-connected, IDLE `PgConnection`
        (moved in; the op owns it for the whole transaction) and the ORDERED
        business statements (the op auto-wraps them in `BEGIN` … `COMMIT`). The
        first `start` sends `BEGIN`."""
        self._conn = Optional[PgConnection](conn^)
        self._frame = PgReadFrame(List[UInt32](), List[String]())
        self._steps = steps^
        self._phase = _TX_PHASE_BEGIN
        self._step_idx = 0
        self._op_id = Int64(0)
        self._registered = False
        self._last_rows = _empty_pg_rows()
        self._err_text = String("")
        self._seq_value = Int64(0)
        self._executed = List[String]()

    @staticmethod
    def for_sequence_test(var steps: List[TxStep]) -> PgTxAsyncOp:
        """TEST-ONLY: build a TX op with NO connection, for the SENDLESS
        `test_drive_sequence` cursor drive. The op never touches a socket — only
        its phase/step cursor + the `_executed` label log are exercised. The
        `into_connection` / live `start`/`poll` paths MUST NOT be called on an
        op built this way (the `_conn` is None)."""
        return PgTxAsyncOp(_conn=Optional[PgConnection](), steps=steps^)

    def __init__(
        out self,
        var _conn: Optional[PgConnection],
        var steps: List[TxStep],
    ):
        """The connection-Optional ctor (used by the test factory with a None
        connection). The production ctor wraps a present connection."""
        self._conn = _conn^
        self._frame = PgReadFrame(List[UInt32](), List[String]())
        self._steps = steps^
        self._phase = _TX_PHASE_BEGIN
        self._step_idx = 0
        self._op_id = Int64(0)
        self._registered = False
        self._last_rows = _empty_pg_rows()
        self._err_text = String("")
        self._seq_value = Int64(0)
        self._executed = List[String]()

    @always_inline
    def is_pending(self) -> Bool:
        return (
            self._phase != _TX_PHASE_DONE_OK
            and self._phase != _TX_PHASE_DONE_ERR
        )

    @always_inline
    def is_ready(self) -> Bool:
        return self._phase == _TX_PHASE_DONE_OK

    @always_inline
    def is_error(self) -> Bool:
        return self._phase == _TX_PHASE_DONE_ERR

    @always_inline
    def op_id(self) -> Int64:
        return self._op_id

    def err_text(self) -> String:
        return self._err_text

    @always_inline
    def op_state(self) -> UInt8:
        if self._phase == _TX_PHASE_DONE_OK:
            return PG_OP_READY
        if self._phase == _TX_PHASE_DONE_ERR:
            return PG_OP_ERR
        return PG_OP_PENDING

    # -------------------------------------------------------------------------
    # start — send BEGIN, register a fresh op_id, make one non-blocking drain.
    # -------------------------------------------------------------------------
    def start[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> Int64:
        """Kick off the transaction: send `BEGIN`, register the conn fd under a
        fresh op_id, attempt one non-blocking drain. Returns the op_id to park
        the frame on. On the immediate-ready fast path (BEGIN already
        complete) the op advances to the first business statement IN THIS CALL,
        so the returned op_id is the FIRST business statement's park."""
        self._phase = _TX_PHASE_BEGIN
        self._send_current_statement[RT](reactor)
        self._advance_if_statement_done[RT](reactor)
        return self._op_id

    # -------------------------------------------------------------------------
    # poll — one non-blocking recv cycle for the current statement; on its
    # completion, advance the TX cursor (which sends the next statement).
    # -------------------------------------------------------------------------
    def poll[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> UInt8:
        """The driver calls this when a Completion for `_op_id` (the current
        statement's park) arrives. Drain the current statement non-blocking;
        when it completes, advance the cursor (send the next statement) and
        return PENDING so the driver re-parks on the NEW op_id; return READY only
        after COMMIT, ERR only after ROLLBACK."""
        if not self.is_pending():
            return self.op_state()
        self._drain_nonblocking[RT](reactor)
        self._advance_if_statement_done[RT](reactor)
        return self.op_state()

    # -------------------------------------------------------------------------
    # _advance_if_statement_done — if the current statement's frame reached a
    # terminal, advance the TX cursor (send the next statement, or finish).
    # Loops so a chain of immediately-ready statements (e.g. BEGIN then a fast
    # INSERT already buffered) advances in one call.
    # -------------------------------------------------------------------------
    def _advance_if_statement_done[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        var guard = 0
        while guard < 1_000_000:
            guard += 1
            if self._frame.is_pending():
                return  # current statement still parked; nothing to advance
            if self._frame.is_error():
                # A statement failed. Capture the error text (unless we are
                # ALREADY draining ROLLBACK — then keep the ORIGINAL error), and
                # switch to the ROLLBACK path. If the FAILED statement WAS the
                # rollback, we are done (ERR).
                if self._phase == _TX_PHASE_ROLLBACK:
                    self._phase = _TX_PHASE_DONE_ERR
                    self._deregister(reactor)
                    return
                if self._err_text.byte_length() == 0:
                    self._err_text = self._frame.err_text()
                self._phase = _TX_PHASE_ROLLBACK
                self._send_current_statement[RT](reactor)
                continue  # re-check: ROLLBACK may already be buffered/ready
            # The current statement is READY (its ReadyForQuery landed).
            if self._phase == _TX_PHASE_ROLLBACK:
                # ROLLBACK completed cleanly after an error -> ERR terminal.
                self._phase = _TX_PHASE_DONE_ERR
                self._deregister(reactor)
                return
            if self._phase == _TX_PHASE_COMMIT:
                # COMMIT completed -> the OK terminal.
                self._phase = _TX_PHASE_DONE_OK
                self._deregister(reactor)
                return
            # BEGIN or a business STEP completed -> move the cursor forward.
            # Capture the rows of a business step (the last one is `Out`), and
            # apply the result-dependent role (SEQ_SELECT capture / CAS miss).
            if self._phase == _TX_PHASE_STEP:
                var rows = self._frame.take_result()
                var role = self._steps[self._step_idx]._role
                # SEQ_SELECT: capture the per-key seq (single int8 row) so a
                # later event INSERT binds it (read INSIDE the TX).
                if role == _STEP_ROLE_SEQ_SELECT:
                    self._seq_value = _first_int8_or_zero(rows)
                # CAS: a ZERO-ROW `RETURNING` result is the CAS MISS (stale
                # version / archived row). Fail the TX with the CAS-miss marker
                # (the caller renders the 409); the loop's next pass sees the
                # error and switches to ROLLBACK (atomicity: the event INSERT
                # never runs, nothing commits).
                if role == _STEP_ROLE_CAS and rows.__len__() == 0:
                    var miss = self._steps[self._step_idx]._cas_miss_text.copy()
                    self._frame.mark_error(miss)
                    continue  # re-enter the loop -> the error branch -> ROLLBACK
                self._last_rows = rows^
            self._cursor_next()
            self._send_current_statement[RT](reactor)
            continue  # the next statement may already be buffered/ready

    # -------------------------------------------------------------------------
    # TEST SEAM — a SENDLESS sequencer that drives the EXACT cursor logic of
    # `_advance_if_statement_done` over a list of simulated per-statement
    # outcomes, with NO socket / reactor. `step_ok[k]` is the outcome of the
    # k-th ISSUED statement (True = its ReadyForQuery landed; False = it
    # errored). The op records each issued statement's label in `_executed`
    # exactly as the live path does, so a test asserts the issued SEQUENCE
    # (BEGIN/step-0/step-1/COMMIT on success; BEGIN/…/step-k/ROLLBACK on an
    # error at step k) — the SAME transitions the live `poll` drives, minus the
    # wire I/O. The error-path label parity is the load-bearing proof: a
    # statement error switches to ROLLBACK and lands ERR, never leaving a
    # dangling open TX.
    # -------------------------------------------------------------------------
    def test_drive_sequence(mut self, step_ok: List[Bool]):
        """SENDLESS deterministic drive of the TX cursor over `step_ok` outcomes
        (the k-th entry = the k-th issued statement's outcome). Records the
        issued labels in `_executed` and lands the op in DONE_OK (all OK) or
        DONE_ERR (an error triggered ROLLBACK). Pure cursor logic — no reactor,
        no PG. Used ONLY by the driver-level sequence/rollback test."""
        var k = 0
        # Issue BEGIN.
        self._phase = _TX_PHASE_BEGIN
        self._executed.append(self._current_label())
        while True:
            var ok = step_ok[k] if k < len(step_ok) else True
            k += 1
            if not ok:
                # The current statement errored.
                if self._phase == _TX_PHASE_ROLLBACK:
                    self._phase = _TX_PHASE_DONE_ERR
                    return
                if self._err_text.byte_length() == 0:
                    self._err_text = String("simulated statement error")
                self._phase = _TX_PHASE_ROLLBACK
                self._executed.append(self._current_label())
                continue
            # The current statement completed READY.
            if self._phase == _TX_PHASE_ROLLBACK:
                self._phase = _TX_PHASE_DONE_ERR
                return
            if self._phase == _TX_PHASE_COMMIT:
                self._phase = _TX_PHASE_DONE_OK
                return
            # BEGIN or a business STEP completed -> advance + issue the next.
            self._cursor_next()
            self._executed.append(self._current_label())

    # -------------------------------------------------------------------------
    # _cursor_next — advance the phase/step cursor: BEGIN -> step 0 -> step 1 ->
    # … -> COMMIT. (The ERROR path sets ROLLBACK directly, not via this.)
    # -------------------------------------------------------------------------
    def _cursor_next(mut self):
        if self._phase == _TX_PHASE_BEGIN:
            if len(self._steps) == 0:
                self._phase = _TX_PHASE_COMMIT
            else:
                self._phase = _TX_PHASE_STEP
                self._step_idx = 0
        elif self._phase == _TX_PHASE_STEP:
            self._step_idx += 1
            if self._step_idx >= len(self._steps):
                self._phase = _TX_PHASE_COMMIT

    # -------------------------------------------------------------------------
    # _send_current_statement — reset the frame + SEND the statement the cursor
    # currently points at (BEGIN / COMMIT / ROLLBACK simple, or a prepared
    # business step), register a fresh op_id, and make one non-blocking drain.
    # -------------------------------------------------------------------------
    @always_inline
    def _current_label(self) -> String:
        """The label of the statement the cursor currently points at (BEGIN /
        COMMIT / ROLLBACK / `step-<i>`). Recorded in `_executed` at send time so
        a test can assert the issued sequence."""
        if self._phase == _TX_PHASE_BEGIN:
            return String("BEGIN")
        if self._phase == _TX_PHASE_COMMIT:
            return String("COMMIT")
        if self._phase == _TX_PHASE_ROLLBACK:
            return String("ROLLBACK")
        return String("step-") + String(self._step_idx)

    def executed_labels(self) -> List[String]:
        """The ORDERED labels of the statements issued so far (test-introspection
        + observability). After a clean run: `["BEGIN", "step-0", …, "COMMIT"]`;
        after an error at step k: `["BEGIN", …, "step-k", "ROLLBACK"]`."""
        return self._executed.copy()

    def _send_current_statement[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        # Record the statement label at SEND time (the issued sequence).
        self._executed.append(self._current_label())
        # Reset the framing cursor + accumulators for the NEW statement. A
        # prepared step seeds the result-column metadata from its statement.
        if self._phase == _TX_PHASE_STEP and self._steps[self._step_idx]._is_prepared:
            ref stmt = self._steps[self._step_idx]._stmt
            var col_oids = List[UInt32]()
            for o in stmt.result_oids:
                col_oids.append(o)
            var col_names = List[String]()
            for c in range(stmt.result_column_count()):
                col_names.append(stmt.result_column_name(c))
            self._frame = PgReadFrame(col_oids^, col_names^)
        else:
            self._frame = PgReadFrame(List[UInt32](), List[String]())

        # SEND the statement (simple-query for BEGIN/COMMIT/ROLLBACK + any
        # simple business step; Bind/Execute/Sync for a prepared business step).
        if self._phase == _TX_PHASE_BEGIN:
            self._conn.value().send_simple_query[RT](reactor, String("BEGIN"))
        elif self._phase == _TX_PHASE_COMMIT:
            self._conn.value().send_simple_query[RT](reactor, String("COMMIT"))
        elif self._phase == _TX_PHASE_ROLLBACK:
            self._conn.value().send_simple_query[RT](
                reactor, String("ROLLBACK")
            )
        else:
            # A business step. If it declares a `_seq_bind_idx`, PATCH that bind
            # slot to the seq the SEQ_SELECT step captured INSIDE the TX, just
            # before SEND (the event INSERT's `seq` column).
            if self._steps[self._step_idx]._seq_bind_idx >= 0:
                var bidx = self._steps[self._step_idx]._seq_bind_idx
                self._steps[self._step_idx]._binds[bidx] = PgValue.int8(
                    self._seq_value
                )
            ref step = self._steps[self._step_idx]
            if step._is_prepared:
                self._conn.value().send_bind_execute_prepared[RT](
                    reactor, step._stmt, step._binds
                )
            else:
                self._conn.value().send_simple_query[RT](reactor, step._sql)

        # Register the fd for read-readiness under a FRESH op_id (the driver
        # re-parks on the current op_id each PENDING poll), then drain once.
        var fd = self._conn.value().stream_fd()
        self._op_id = reactor.alloc_op_id()
        reactor.register_read(fd, self._op_id, UInt16(0))
        self._registered = True
        self._drain_nonblocking[RT](reactor)

    # -------------------------------------------------------------------------
    # _drain_nonblocking — one non-blocking recv cycle for the CURRENT statement
    # (verbatim the PgQueryOp drain shape — drain buffered, then non-blocking
    # recvs until a terminal lands or s2n would-block). On a would-block the
    # FRAME stays pending and the op re-parks on `_op_id`.
    # -------------------------------------------------------------------------
    def _drain_nonblocking[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        if self._frame.drain_complete():
            self._maybe_deregister(reactor)
            return
        var guard = 0
        while guard < 1_000_000:
            var res = self._conn.value().try_recv_chunk[RT](reactor, 16384)
            var status = res[0]
            if status == PG_RECV_PENDING:
                return  # would-block; stay PENDING; the op re-parks on _op_id
            if status == PG_RECV_EOF:
                self._frame.mark_error(
                    String("pg_tx_op: peer closed before ReadyForQuery")
                )
                self._maybe_deregister(reactor)
                return
            # PG_RECV_DONE: bytes fed into the frame. Drain; terminal -> done.
            self._frame.feed(res[2])
            if self._frame.drain_complete():
                self._maybe_deregister(reactor)
                return
            guard += 1

    def _maybe_deregister[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        """Deregister the current statement's op_id once its frame is no longer
        pending (READY/ERR). The NEXT statement registers a fresh op_id. Keeps
        the reactor table clean between the TX's statements."""
        if not self._frame.is_pending() and self._registered:
            reactor.deregister(self._op_id)
            self._registered = False

    def _deregister[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        if self._registered:
            reactor.deregister(self._op_id)
            self._registered = False

    # -------------------------------------------------------------------------
    # take_result — the LAST business statement's rows (the caller's carry input;
    # empty for a no-RETURNING INSERT). Valid only after is_ready().
    # -------------------------------------------------------------------------
    def take_result(mut self) -> PgRows:
        var rows = self._last_rows^
        self._last_rows = _empty_pg_rows()
        return rows^

    # -------------------------------------------------------------------------
    # into_connection — recover the leased connection (ONLY after is_ready /
    # is_error — never while parked). Extracts via `Optional.take()` (the safe
    # partial-move primitive).
    # -------------------------------------------------------------------------
    def into_connection(mut self) -> PgConnection:
        """Return the leased connection so it can be returned to the pool. Call
        ONLY after the op is fully done (is_ready / is_error) — NEVER while
        parked (returning a pooled conn mid-park would alias s2n's mid-record
        state). After COMMIT or ROLLBACK the connection is back at
        ReadyForQuery with NO open transaction, so it is clean to recycle."""
        return self._conn.take()


# =============================================================================
# §2 — helpers.
# =============================================================================


def _empty_pg_rows() -> PgRows:
    """An empty result set (the initial `_last_rows`, and the post-take value).
    """
    return PgRows(List[PgRow](), List[String]())


def _first_int8_or_zero(rows: PgRows) -> Int64:
    """The single int8 value of a one-row, one-column SELECT result (the
    `SEQ_SELECT` step's `COALESCE(MAX(seq),0)+1`). Returns 0 if the result is
    empty (defensive — `COALESCE` always yields exactly one non-NULL row, so
    this is the never-taken safety floor)."""
    if rows.__len__() == 0:
        return Int64(0)
    try:
        return rows.row(0).get_int8(0)
    except:
        return Int64(0)
