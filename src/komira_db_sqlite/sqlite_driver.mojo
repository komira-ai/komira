# =============================================================================
# komira_db_sqlite/sqlite_driver.mojo — the SqliteDatabase Database conformer.
# =============================================================================
#
# The in-process sqlite backend: a `Database`-trait conformer
# over the embedded system `libsqlite3` via the FFI shim (sqlite/ffi.mojo). It
# is the containerless, fast backend that makes most of the DB-abstraction
# testing run in a plain unit test (no docker, no socket) — `libsqlite3`
# is linked in-process.
#
# ENCAPSULATION: every UnsafePointer / opaque handle lives behind
# this struct's private helpers (the FFI declarations are in sqlite/ffi.mojo,
# the carve-out). The public surface is exactly `Database`:
#   execute / query / query_opt / query_one / begin / commit / rollback +
#   placeholder(i) / now_expr() + claim_pending — all String / List[DbValue]
#   in, DbRows / DbRow / UInt64 out. ZERO UnsafePointer crosses this boundary.
#
# TYPE MAPPING (the DbValue carrier is canonical TEXT, so the
# driver converts text -> native bind and native column -> canonical text):
#   * UUID         -> sqlite3_bind_blob (16 raw bytes, parsed from the
#                     hyphenated-hex carrier). On read a 16-byte BLOB column is
#                     rendered back to hyphenated hex (what DbRow.get_uuid
#                     expects). BLOB affinity is the cleaner choice (no
#                     hex-vs-canonical ambiguity, compact storage).
#   * TIMESTAMPTZ  -> sqlite3_bind_int64 (µs since the UNIX epoch — the same
#                     Int64 the carrier holds; identical logical value, INTEGER
#                     storage). On read INTEGER -> decimal text (get_timestamptz).
#   * INT4 / INT8  -> sqlite3_bind_int / _int64. On read INTEGER -> decimal text.
#   * TEXT / JSONB -> sqlite3_bind_text. On read TEXT -> passthrough.
#   * TEXT[]       -> sqlite3_bind_text carrying the `{a,b,c}` array literal
#                     VERBATIM (the carrier form). sqlite has no array type;
#                     we store the literal as TEXT and it round-trips directly
#                     through DbRow.get_text_array (which parses `{a,b,c}`).
#                     DECISION: store the `{a,b,c}` literal (NOT JSON `["a","b"]`)
#                     so a single TEXT column round-trips without the driver
#                     needing per-column logical-type knowledge on the
#                     schema-unknown `query` path. JSON1-queryability is not
#                     required by the intended access patterns; round-trip
#                     correctness + getter-compatibility is the gate.
#   * NULL         -> sqlite3_bind_null (typed NULL; SQLITE_NULL on read).
#
# RESULT DECODE (the schema-unknown path): `query` does not know each column's
# LOGICAL type — only sqlite's storage class. The driver renders each column to
# the canonical TEXT form the matching `DbRow.get_*` getter decodes:
#   INTEGER -> decimal text ; FLOAT -> text ; TEXT -> passthrough ;
#   BLOB(16) -> hyphenated UUID hex ; BLOB(other) -> raw bytes ; NULL -> null.
# This keeps the untyped DbRow self-describing-enough for the typed `from_row`
# cascade (which calls the right getter per field, in field-number order).
# =============================================================================

from std.memory import UnsafePointer

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.neutral_ops import Filter, Order, DbColVal, PodNameMinter
from komira_db.sql_neutral_ops import (
    sql_op_get_by_key,
    sql_op_put,
    sql_op_delete_by_key,
    sql_op_query_rows,
    sql_op_query_rows_locked,
    sql_op_conditional_update,
    sql_op_delete_where,
    sql_op_create_if_absent,
    sql_op_create_if_absent_composite,
    sql_op_claim_rows,
)
from komira_db.db_value import (
    DbValue,
    LOGICAL_UUID,
    LOGICAL_TEXT,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_FLOAT8,
    LOGICAL_FLOAT4,
    LOGICAL_BOOL,
    LOGICAL_BYTES,
    LOGICAL_TIMESTAMPTZ,
    LOGICAL_JSONB,
    LOGICAL_TEXT_ARRAY,
)
from komira_db.db_row import DbRow, DbRows

from komira_db_sqlite.ffi import (
    SqliteHandle,
    sqlite_null_handle,
    _ffi_null_byte,
    _FFI_ORIGIN,
    SQLITE_OK,
    SQLITE_ROW,
    SQLITE_DONE,
    SQLITE_CONSTRAINT,
    SQLITE_OPEN_READWRITE,
    SQLITE_OPEN_CREATE,
    SQLITE_INTEGER,
    SQLITE_FLOAT,
    SQLITE_TEXT,
    SQLITE_BLOB,
    SQLITE_NULL_TYPE,
    sqlite3_open_v2,
    sqlite3_close_v2,
    sqlite3_errmsg,
    sqlite3_extended_errcode,
    sqlite3_busy_timeout,
    sqlite3_changes,
    sqlite3_prepare_v2,
    sqlite3_step,
    sqlite3_reset,
    sqlite3_finalize,
    sqlite3_bind_int64,
    sqlite3_bind_int,
    sqlite3_bind_text,
    sqlite3_bind_blob,
    sqlite3_bind_null,
    sqlite3_column_count,
    sqlite3_column_type,
    sqlite3_column_int64,
    sqlite3_column_bytes,
    sqlite3_column_text,
    sqlite3_column_blob,
    sqlite3_column_name,
)


# =============================================================================
# SqliteDatabase — the Database conformer over libsqlite3.
# =============================================================================
struct SqliteDatabase(SqlDatabase):
    """A sqlite-backed `Database`. Owns one `sqlite3*` connection (a single file
    path or ":memory:"). All UnsafePointer / opaque-handle work is confined to
    this struct's private helpers + the sqlite/ffi.mojo carve-out; the public
    surface is the `Database` trait (String / List[DbValue] in, DbRows out)."""

    # SAFETY (FFI-POD opaque-handle carve-out): `_conn` is an FFI-POD opaque
    # handle (a `sqlite3*`) — a bare C pointer holding NO Mojo heap (no inner
    # List/String/OwnedPointer), so it carries no stale-heap hazard across a
    # destroy-and-recreate (that hazard is about heap-owning INNER fields under
    # a wildcard cast; an opaque C pointer has none). It is
    # NEVER dereferenced on the Mojo side — only handed back to libsqlite3 by the
    # private helpers. A NULL sentinel marks a default-constructed / never-opened
    # connection so `__del__` never double-closes; the synthesized move tracks
    # moved-from instances and skips their `__del__`. The same pattern as the s2n
    # handles in `komira_http`. The handle
    # does NOT cross the komira_db module boundary.
    #
    # b2: the origin is the CONCRETE `_FFI_ORIGIN` (StaticConstantOrigin), NOT
    # the banned `MutExternalOrigin` wildcard — so this field is not a
    # wildcard-origin field.

    var _conn: SqliteHandle

    # ---- lifecycle ----

    def __init__(out self, path: String) raises:
        """Open (or create) the database at `path`. Use ":memory:" for an
        in-process, ephemeral database (the default test backend)."""
        self._conn = sqlite_null_handle()  # null until open succeeds
        var path_buf = _nul_terminated(path)
        # Stack-local out-slot the open call writes the sqlite3* handle into.
        var handle_local = sqlite_null_handle()
        # SAFETY: FFI carve-out. `path_buf` is a local NUL-terminated buffer
        # held alive across the call by the trailing keepalive; `handle_local`
        # is a stack out-param the call writes exactly once. b2: erase to the
        # CONCRETE `_FFI_ORIGIN` (immutable static FFI origin), so unsafe_mut_cast
        # [False] precedes unsafe_origin_cast (sqlite reads the path
        # synchronously, retains no pointer).
        var rc = sqlite3_open_v2(
            path_buf.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            UnsafePointer(to=handle_local).unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            _ffi_null_byte(),  # default VFS (null)
        )
        _ = path_buf  # keep the path buffer alive across the open call
        var opened = handle_local
        if rc != SQLITE_OK:
            # opened may be non-null even on error; close it if so.
            if Int(opened) != 0:
                _ = sqlite3_close_v2(opened)
            raise Error(
                String("sqlite3_open_v2 failed (rc=") + String(Int(rc)) + ")"
            )
        self._conn = opened

    def __deinit__(deinit self):
        # SAFETY: exactly-one close per non-null handle; the null sentinel
        # guards default-constructed / never-opened drivers. The SYNTHESIZED
        # move (Movable) tracks moved-from instances and skips their __del__,
        # so the handle is never double-closed (no manual __moveinit__ nulling
        # needed; an explicit __moveinit__ on a

        # wildcard-origin field trips a Mojo 1.0.0b1 parse quirk).
        if Int(self._conn) != 0:
            _ = sqlite3_close_v2(self._conn)

    # ---- the Database execution surface ----
    #
    # Every method is METHOD-`[RT]`-parametric + takes `mut reactor`
    # for trait uniformity, but sqlite is in-process synchronous libsqlite3 FFI
    # — there is NO socket, NO would-block, NOTHING to park on. So each method
    # IGNORES the reactor (`_ = reactor`). The param exists purely so ONE
    # `Store[DB]` / `JobStore[DB]` cascade drives BOTH backends from a single
    # generic call site (the pg driver actually parks on the reactor).

    def execute[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> UInt64:
        """Run a non-result statement; return rows_affected (sqlite3_changes).
        sqlite is in-process FFI; `reactor` is ignored (trait uniformity)."""
        _ = reactor
        var stmt = self._prepare(sql)
        # `bind_bufs` owns every bound byte buffer; it MUST stay alive until the
        # step completes (binds use SQLITE_STATIC — sqlite reads, does not copy).
        var bind_bufs = self._bind_params(stmt, params)
        var rc = sqlite3_step(stmt)
        # A non-result statement steps to DONE; a statement that yields rows
        # (e.g. a misused SELECT) is drained so the changes count is well-defined.
        while rc == SQLITE_ROW:
            rc = sqlite3_step(stmt)
        _ = sqlite3_finalize(stmt)
        _ = bind_bufs  # keepalive: bound buffers must outlive the step
        if rc != SQLITE_DONE:
            # Name the STATEMENT: "step failed: database is locked" with no SQL
            # forces the reader to guess which statement of a transaction lost
            # the race, and the SQLITE_BUSY family's remedies differ per
            # statement kind. Placeholders, never bound values.
            raise self._err(
                String("execute: step failed for [") + sql + String("]")
            )
        return UInt64(Int(sqlite3_changes(self._conn)))

    def query[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> DbRows:
        """Run a query; return the full materialized result set. sqlite is
        in-process FFI; `reactor` is ignored (trait uniformity)."""
        _ = reactor
        var stmt = self._prepare(sql)
        var bind_bufs = self._bind_params(stmt, params)
        var rows = self._collect(stmt)
        _ = sqlite3_finalize(stmt)
        _ = bind_bufs  # keepalive: bound buffers must outlive the collect loop
        return rows^

    def query_opt[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> Optional[DbRow]:
        var rows = self.query[RT](reactor, sql, params)
        if rows.__len__() == 0:
            return Optional[DbRow]()
        return Optional[DbRow](rows.row(0).copy())

    def query_one[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> DbRow:
        var rows = self.query[RT](reactor, sql, params)
        if rows.__len__() != 1:
            raise Error(
                String("query_one: expected exactly 1 row, got ")
                + String(rows.__len__())
            )
        return rows.row(0).copy()

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        """Open a write transaction — `BEGIN IMMEDIATE`, never a bare `BEGIN`.

        ⚠ THE `IMMEDIATE` IS LOAD-BEARING AND IS NOT A PERFORMANCE CHOICE.
        A bare `BEGIN` is DEFERRED: it takes no lock, and the transaction's
        lock is decided by its FIRST statement. A typical store transaction
        reads before it writes (an event append reads the next per-task
        `seq`, a CAS reads the current row), so a DEFERRED transaction
        starts as a READER and then has to UPGRADE to a writer.

        In WAL mode that upgrade is the one SQLite failure a busy-timeout
        CANNOT rescue. If any other connection committed between this
        transaction's read snapshot and its first write, the upgrade returns
        `SQLITE_BUSY_SNAPSHOT` — reported through `sqlite3_errmsg` as the
        generic "database is locked" — and SQLite returns it IMMEDIATELY
        WITHOUT invoking the busy handler, because retrying could only
        deadlock: the snapshot is stale and no amount of waiting un-stales it.
        `PRAGMA busy_timeout` is not consulted. So a DEFERRED-`BEGIN` writer
        under WAL fails on the FIRST concurrent commit, deterministically, no
        matter how long it is willing to wait.

        `BEGIN IMMEDIATE` takes the write lock up front, so there is no upgrade
        and no stale snapshot. Contention becomes an ordinary lock wait, which
        the busy handler DOES service — arm one with
        `arm_for_concurrent_use` (or `PRAGMA busy_timeout`) on every connection
        that shares a file, or a contended writer still fails instantly.
        """

        _ = self.execute[RT](
            reactor, String("BEGIN IMMEDIATE"), List[DbValue]()
        )

    def arm_for_concurrent_use[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        busy_timeout_ms: Int,
    ) raises:
        """Arm this connection for multi-connection use on a shared file — WAL
        journal mode + a busy timeout — and VERIFY that both actually took.

        ⚠ BOTH OF THESE ARE PRAGMAS THAT REPORT THEIR RESULT IN A ROW INSTEAD
        OF RAISING. `PRAGMA journal_mode=WAL` on a database that cannot host a
        `-shm` mapping — an in-memory database, a TEMP database, some network
        filesystems — leaves the connection in its previous journal mode and
        returns THAT mode as its row. Issuing it through `execute` (which
        drains and discards rows) is therefore a setting that reports success
        without having been applied, and the failure only surfaces much later
        as "database is locked" under contention. This method reads the row
        back and raises naming the mode it actually got.

        ⚠ THE ORDER IS LOAD-BEARING: the busy timeout is armed FIRST, through
        the C API, BEFORE any statement that touches the WAL. `PRAGMA
        journal_mode=WAL` is itself a WAL operation, so on an unarmed
        connection it can lose to another connection running WAL recovery and
        fail instantly with `SQLITE_BUSY_RECOVERY` (extended rc 261) — the
        arming statement defeated by the very contention it was there to
        absorb: `prepare failed for [PRAGMA journal_mode=WAL]: database is
        locked (sqlite extended rc=261)` is what a timeout armed second looks
        like under load. `sqlite3_busy_timeout()` is
        used rather than `PRAGMA busy_timeout` because it is a direct C call:
        there is no statement to prepare, so nothing about arming can itself
        contend. The PRAGMA is still issued afterwards, purely to READ the
        value back and prove it took.
        """
        # 1. Arm the busy handler. No SQL, no prepare, nothing to contend with.
        var rc = sqlite3_busy_timeout(self._conn, Int32(busy_timeout_ms))
        if rc != SQLITE_OK:
            raise self._err(
                String("sqlite3_busy_timeout(")
                + String(busy_timeout_ms)
                + String(") failed")
            )
        # 2. Only now touch the WAL.
        var jrows = self.query[RT](
            reactor, String("PRAGMA journal_mode=WAL"), List[DbValue]()
        )
        if jrows.__len__() != 1:
            raise Error(
                String("PRAGMA journal_mode=WAL returned ")
                + String(jrows.__len__())
                + String(" rows; expected exactly 1")
            )
        var mode = jrows.row(0).get_text(0)
        if mode != String("wal"):
            raise Error(
                String("PRAGMA journal_mode=WAL did not engage: this")
                + String(" connection is in '")
                + mode
                + String("' journal mode. Concurrent connections on this")
                + String(" database will serialize into SQLITE_BUSY.")
            )
        # 3. Read the timeout back — proof that step 1 took, not a second set.
        var brows = self.query[RT](
            reactor, String("PRAGMA busy_timeout"), List[DbValue]()
        )
        if brows.__len__() != 1:
            raise Error(
                String("PRAGMA busy_timeout returned ")
                + String(brows.__len__())
                + String(" rows; expected exactly 1")
            )
        var got = Int(brows.row(0).get_int8(0))
        if got != busy_timeout_ms:
            raise Error(
                String("PRAGMA busy_timeout did not take: asked for ")
                + String(busy_timeout_ms)
                + String(" ms, connection reports ")
                + String(got)
                + String(" ms")
            )

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = self.execute[RT](reactor, String("COMMIT"), List[DbValue]())

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = self.execute[RT](reactor, String("ROLLBACK"), List[DbValue]())

    # ---- per-driver dialect ----

    @staticmethod
    def dialect() -> String:
        """Embedded SQLite (`?N` placeholders, JSON1 `json_extract`, BEGIN
        IMMEDIATE claim)."""
        return String("sqlite")

    @staticmethod
    def placeholder(i: Int) -> String:
        """Sqlite positional placeholder `?<i+1>` (1-based)."""
        return String("?") + String(i + 1)

    @staticmethod
    def now_expr() -> String:
        """Current time as µs since the UNIX epoch (the TIMESTAMPTZ convention):
        `unixepoch('now','subsec')*1000000`. (`unixepoch(...,'subsec')` returns
        a REAL with fractional seconds; ×1e6 yields µs)."""
        return String("CAST(unixepoch('now','subsec')*1000000 AS INTEGER)")

    # ---- the portable concurrent-CLAIM op ----

    def claim_pending[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        n: Int,
        pending: String,
        assigned: String,
        extra_set: String,
        params: List[DbValue],
        phase_col: String,
    ) raises -> DbRows:
        """Atomically transition up to `n` rows `pending` -> `assigned` and
        return them, matching on the queue/status column `phase_col` (default
        `"phase"` at the neutral layer). sqlite realizes the exclusivity by
        single-writer serialization: `BEGIN IMMEDIATE` acquires the write lock up
        front, then `UPDATE ... WHERE id IN (SELECT id ... ORDER BY created_at
        LIMIT n) RETURNING *`, then `COMMIT`. No two claims run concurrently, so
        no two claimers ever get the same row (the SKIP-LOCKED guarantee achieved
        by serializing writers). sqlite is in-process FFI; the
        forwarded `reactor` is ultimately ignored by execute/query (trait
        uniformity)."""
        # Acquire the write lock before reading the candidate set.
        _ = self.execute[RT](
            reactor, String("BEGIN IMMEDIATE"), List[DbValue]()
        )
        var set_clause = phase_col + String(" = '") + assigned + String("'")
        if extra_set.byte_length() > 0:
            set_clause += String(", ") + extra_set
        # The LIMIT count is the FINAL placeholder; `params` (if any) feed the
        # extra_set assignments in order, then the LIMIT binds last.
        var limit_idx = len(params)
        var sql = (
            String("UPDATE ")
            + table
            + String(" SET ")
            + set_clause
            + String(" WHERE ")
            + Self.PK_DEFAULT
            + String(" IN (SELECT ")
            + Self.PK_DEFAULT
            + String(" FROM ")
            + table
            + String(" WHERE ")
            + phase_col
            + String(" = '")
            + pending
            + String("' ORDER BY created_at LIMIT ")
            + Self.placeholder(limit_idx)
            + String(") RETURNING *")
        )
        var claim_params = params.copy()
        claim_params.append(DbValue.int8(Int64(n)))
        try:
            var rows = self.query[RT](reactor, sql, claim_params)
            _ = self.execute[RT](reactor, String("COMMIT"), List[DbValue]())
            return rows^
        except e:
            # Roll back the write lock on any failure, then surface the error.
            _ = self.execute[RT](
                reactor, String("ROLLBACK"), List[DbValue]()
            )
            raise Error(String("claim_pending failed: ") + String(e))

    # The default primary-key column name for the claim's identity sub-select.
    # A job table keys on `id`; a future caller that needs a
    # different PK threads it through a richer claim signature.
    comptime PK_DEFAULT: StaticString = "id"

    # =========================================================================
    # The 9 neutral structured ops — each a 1-line delegation to the
    # shared byte-identical SQL renderer in sql_neutral_ops.mojo. The SQL is
    # rendered ONCE (there), identical across pg / sqlite / pgstore; this driver
    # supplies its dialect tokens + its execute/query/claim_pending.
    # =========================================================================

    def get_by_key[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        key_col: String,
        key_val: DbValue,
    ) raises -> Optional[DbRow]:
        return sql_op_get_by_key[RT, Self](
            self, reactor, table, cols, key_col, key_val
        )

    def put[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> UInt64:
        return sql_op_put[RT, Self](self, reactor, table, cols, vals)

    def delete_by_key[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        key_col: String,
        key_val: DbValue,
    ) raises -> UInt64:
        return sql_op_delete_by_key[RT, Self](
            self, reactor, table, key_col, key_val
        )

    def query_rows[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        return sql_op_query_rows[RT, Self](
            self, reactor, table, cols, filter, order, limit
        )

    def query_rows_locked[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
    ) raises -> DbRows:
        return sql_op_query_rows_locked[RT, Self](
            self, reactor, table, cols, filter, order
        )

    def conditional_update[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        guard: Filter,
        updates: List[DbColVal],
        coalesce: Bool,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> UInt64:
        return sql_op_conditional_update[RT, Self](
            self,
            reactor,
            table,
            guard,
            updates,
            coalesce,
            bump_version_col,
            now_cols,
        )

    def delete_where[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        filter: Filter,
    ) raises -> UInt64:
        return sql_op_delete_where[RT, Self](self, reactor, table, filter)

    def create_if_absent[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        return sql_op_create_if_absent[RT, Self](
            self, reactor, table, unique_col, unique_val, cols, vals
        )

    def create_if_absent_composite[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        return sql_op_create_if_absent_composite[RT, Self](
            self, reactor, table, conflict_cols, cols, vals
        )

    def claim_rows[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        n: Int,
        filter: Filter,
        order: List[Order],
        phase_col: String,
        from_phase: String,
        to_phase: String,
        extra: List[DbColVal],
        per_row_mint: PodNameMinter,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> DbRows:
        return sql_op_claim_rows[RT, Self](
            self,
            reactor,
            table,
            n,
            filter,
            order,
            phase_col,
            from_phase,
            to_phase,
            extra,
            per_row_mint,
            bump_version_col,
            now_cols,
        )

    # =========================================================================
    # Private FFI helpers — ALL UnsafePointer arithmetic confined here.
    # =========================================================================

    def _prepare(self, sql: String) raises -> SqliteHandle:
        """Compile `sql` to a prepared statement (the opaque handle stays
        INSIDE the driver — never returned across the module boundary)."""
        var sql_buf = _nul_terminated(sql)
        # Stack-local out-slots for the statement handle + the (unused) tail.
        var stmt_local = sqlite_null_handle()
        var tail_local = _ffi_null_byte()
        # SAFETY: FFI carve-out. `sql_buf` is a local NUL-terminated buffer held
        # alive across the call by the trailing keepalive; `stmt_local` /
        # `tail_local` are stack out-params the call writes. b2: erase to the
        # CONCRETE `_FFI_ORIGIN` (immutable static FFI origin); unsafe_mut_cast
        # [False] precedes unsafe_origin_cast.
        var rc = sqlite3_prepare_v2(
            self._conn,
            sql_buf.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            Int32(-1),  # read to first NUL
            UnsafePointer(to=stmt_local).unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            UnsafePointer(to=tail_local).unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
        )
        _ = sql_buf  # keep the SQL buffer alive across prepare
        if rc != SQLITE_OK:
            # Name the STATEMENT. "prepare failed: database is locked" with
            # no SQL forces the reader to guess which of a transaction's dozen
            # statements lost the race. Parameters are bound later, so the text
            # carries placeholders, never values.
            raise self._err(String("prepare failed for [") + sql + String("]"))
        return stmt_local

    def _bind_params(
        self, stmt: SqliteHandle, params: List[DbValue]
    ) raises -> List[List[UInt8]]:
        """Bind each DbValue to its native sqlite parameter (1-based index).

        TEXT / BLOB binds use SQLITE_STATIC (the null destructor) — sqlite
        READS the bytes (does not copy) — so every bound byte buffer is
        accumulated into the returned `bufs` list, which the CALLER must keep
        alive until the statement is fully stepped. This avoids the
        `(void*)-1` SQLITE_TRANSIENT sentinel (which would require
        `unsafe_from_address`, banned even in the FFI carve-out) by guaranteeing
        buffer liveness structurally instead."""
        var bufs = List[List[UInt8]]()
        for i in range(len(params)):
            ref v = params[i]
            var idx = Int32(i + 1)
            if v.is_null:
                _ = sqlite3_bind_null(stmt, idx)
                continue
            var lt = v.logical_type
            if lt == LOGICAL_UUID:
                bufs.append(self._bind_uuid_blob(stmt, idx, v.as_text()))
            elif lt == LOGICAL_INT4:
                _ = sqlite3_bind_int(stmt, idx, Int32(_parse_i64(v.as_text())))
            elif lt == LOGICAL_INT8 or lt == LOGICAL_TIMESTAMPTZ:
                _ = sqlite3_bind_int64(stmt, idx, _parse_i64(v.as_text()))
            elif lt == LOGICAL_BYTES:
                # A binary/blob value binds as a native sqlite BLOB (the RAW
                # carrier bytes verbatim) — a REAL binary param, not the base64/
                # hex TEXT workaround. Read back as SQLITE_BLOB -> LOGICAL_BYTES.
                bufs.append(self._bind_blob(stmt, idx, v.as_bytes_owned()))
            else:
                # TEXT / JSONB / BOOL / FLOAT / TEXT_ARRAY: bind the canonical
                # TEXT carrier verbatim (TEXT_ARRAY carries the `{a,b}` literal;
                # BOOL carries "true"/"false"; FLOAT decimal).
                bufs.append(self._bind_text(stmt, idx, v.as_text()))
        return bufs^

    def _bind_text(
        self, stmt: SqliteHandle, idx: Int32, text: String
    ) -> List[UInt8]:
        """Bind `text` as a TEXT parameter; return the owned byte buffer the
        caller keeps alive (SQLITE_STATIC — sqlite does not copy)."""
        var buf = List[UInt8]()
        var b = text.as_bytes()
        for i in range(len(b)):
            buf.append(b[i])
        # SAFETY: bind with the SQLITE_STATIC null destructor — sqlite reads
        # `buf`'s bytes lazily during step, so `buf` MUST outlive the step. The
        # caller (`execute`/`query`) holds the returned buffer alive until after
        # `sqlite3_step`/`_collect`. `buf.unsafe_ptr()` is a stable List buffer
        # pointer (List does not relocate while borrowed here).
        _ = sqlite3_bind_text(
            stmt,
            idx,
            buf.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            Int32(len(buf)),
            _ffi_null_byte(),  # SQLITE_STATIC (null)
        )
        return buf^

    def _bind_uuid_blob(
        self, stmt: SqliteHandle, idx: Int32, hyphenated: String
    ) raises -> List[UInt8]:
        """Parse the hyphenated-hex UUID carrier into 16 raw bytes and bind as a
        BLOB (the cleaner affinity choice). Returns the owned
        16-byte buffer the caller keeps alive (SQLITE_STATIC)."""
        var bytes = _parse_uuid_text(hyphenated)
        var raw = List[UInt8]()
        for i in range(16):
            raw.append(bytes[i])
        # SAFETY: SQLITE_STATIC null destructor — `raw` is read during step and
        # MUST outlive it; the caller holds the returned buffer alive.
        _ = sqlite3_bind_blob(
            stmt,
            idx,
            raw.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            Int32(16),
            _ffi_null_byte(),  # SQLITE_STATIC (null)
        )
        return raw^

    def _bind_blob(
        self, stmt: SqliteHandle, idx: Int32, var raw: List[UInt8]
    ) -> List[UInt8]:
        """Bind arbitrary RAW bytes as a native sqlite BLOB param (a genuine
        binary bind — the LOGICAL_BYTES path). Returns the owned buffer the caller
        keeps alive (SQLITE_STATIC — sqlite reads it lazily during step). Length
        is arbitrary (unlike `_bind_uuid_blob`'s fixed 16)."""
        # SAFETY: SQLITE_STATIC null destructor — `raw` is read during step and
        # MUST outlive it; the caller holds the returned buffer alive until after
        # `sqlite3_step`/`_collect`. `raw.unsafe_ptr()` is a stable List buffer
        # pointer (List does not relocate while borrowed here).
        _ = sqlite3_bind_blob(
            stmt,
            idx,
            raw.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
                _FFI_ORIGIN
            ](),
            Int32(len(raw)),
            _ffi_null_byte(),  # SQLITE_STATIC (null)
        )
        return raw^

    def _collect(self, stmt: SqliteHandle) raises -> DbRows:
        """Step the statement to completion, materializing each result row into
        a flat `DbRow`. Column names come from `sqlite3_column_name`; each cell
        is rendered to the canonical TEXT form the typed getters decode."""
        var col_names = List[String]()
        var have_names = False
        var out_rows = List[DbRow]()
        # Capture the result column names from the prepared statement BEFORE the
        # first step. `sqlite3_column_count` / `sqlite3_column_name` are valid on
        # a prepared SELECT regardless of whether any row is produced — so a
        # zero-row result (e.g. `SELECT * ... LIMIT 0`, the drift-guard's
        # describe shape) still carries the column list. This mirrors the pg
        # path, which reads the result column names from the Describe.
        var stmt_ncols = Int(sqlite3_column_count(stmt))
        if stmt_ncols > 0:
            for c in range(stmt_ncols):
                col_names.append(self._col_name(stmt, Int32(c)))
            have_names = True
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW:
            var ncols = Int(sqlite3_column_count(stmt))
            if not have_names:
                for c in range(ncols):
                    col_names.append(self._col_name(stmt, Int32(c)))
                have_names = True
            # Build the flat DbRow storage for this row.
            var data = List[UInt8]()
            var offsets = List[Int]()
            offsets.append(0)
            var nulls = List[Bool]()
            var ltypes = List[Int]()
            for c in range(ncols):
                var ctype = sqlite3_column_type(stmt, Int32(c))
                if ctype == SQLITE_NULL_TYPE:
                    nulls.append(True)
                    ltypes.append(LOGICAL_TEXT)
                    offsets.append(len(data))
                    continue
                nulls.append(False)
                var cell = self._render_cell(stmt, Int32(c), ctype)
                ltypes.append(cell[1])
                var cb = cell[0].as_bytes()
                for j in range(len(cb)):
                    data.append(cb[j])
                offsets.append(len(data))
            out_rows.append(
                DbRow(
                    data^,
                    offsets^,
                    nulls^,
                    ltypes^,
                    col_names.copy(),
                )
            )
            rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE:
            raise self._err("collect: step failed")
        return DbRows(out_rows^, col_names^)

    def _render_cell(
        self, stmt: SqliteHandle, col: Int32, ctype: Int32
    ) raises -> Tuple[String, Int]:
        """Render result column `col` (storage class `ctype`) to its canonical
        TEXT form + the logical-type tag the matching getter expects."""
        if ctype == SQLITE_INTEGER:
            # INTEGER stores INT4 / INT8 / TIMESTAMPTZ µs — all decode from
            # decimal text via the int / timestamptz getters.
            var v = sqlite3_column_int64(stmt, col)
            return (String(Int(v)), LOGICAL_INT8)
        elif ctype == SQLITE_BLOB:
            var raw = self._read_blob(stmt, col)
            if len(raw) == 16:
                # A 16-byte BLOB is a UUID — render to hyphenated hex.
                return (_uuid_bytes_to_hex_list(raw), LOGICAL_UUID)
            # Other BLOB (LOGICAL_BYTES): carry the raw bytes VERBATIM into the
            # canonical `_text` (byte-backed String, no codepoint promotion).
            # A chr()-per-byte conversion would double-encode every byte >= 0x80

            # (the double-UTF-8 mojibake class), corrupting a binary round-trip —
            # so use the verbatim byte carrier that DbRow.get_bytes reads back exact.
            return (_owned_bytes_verbatim(raw), LOGICAL_BYTES)
        else:
            # SQLITE_TEXT / SQLITE_FLOAT: read the text bytes verbatim. This
            # covers TEXT / JSONB / the `{a,b}` TEXT_ARRAY literal / FLOAT (which
            # sqlite renders as text on a _text read).
            var raw = self._read_text(stmt, col)
            return (_owned_utf8(raw), LOGICAL_TEXT)

    def _read_text(self, stmt: SqliteHandle, col: Int32) -> List[UInt8]:
        """Copy column `col`'s TEXT bytes into an owned List (sqlite's pointer
        is valid only until the next step; we copy immediately)."""
        var n = Int(sqlite3_column_bytes(stmt, col))
        var p = sqlite3_column_text(stmt, col)
        var out = List[UInt8]()
        # SAFETY: `p` is a sqlite-owned buffer of exactly `n` bytes, valid until
        # the next step/reset/finalize. We copy all `n` bytes here and never
        # retain `p`.
        for i in range(n):
            out.append(p[i])
        return out^

    def _read_blob(self, stmt: SqliteHandle, col: Int32) -> List[UInt8]:
        """Copy column `col`'s BLOB bytes into an owned List (copy immediately;
        sqlite's pointer is valid only until the next step)."""
        var n = Int(sqlite3_column_bytes(stmt, col))
        var p = sqlite3_column_blob(stmt, col)
        var out = List[UInt8]()
        # SAFETY: `p` is a sqlite-owned buffer of exactly `n` bytes, valid until
        # the next step/reset/finalize. We copy all `n` bytes and never retain `p`.
        for i in range(n):
            out.append(p[i])
        return out^

    def _col_name(self, stmt: SqliteHandle, col: Int32) -> String:
        """Copy column `col`'s NUL-terminated name into an owned String."""
        var p = sqlite3_column_name(stmt, col)
        var s = String()
        # SAFETY: `p` is a sqlite-owned NUL-terminated const char*; we copy
        # until the NUL and never retain `p`.
        var i = 0
        while p[i] != 0:
            s += chr(Int(p[i]))
            i += 1
        return s^

    def _err(self, where: String) -> Error:
        """Build an Error carrying the sqlite errmsg text AND the EXTENDED
        result code.

        The code is not decoration. `sqlite3_errmsg` collapses the whole
        SQLITE_BUSY family onto the single string "database is locked", and its
        members have opposite remedies — 5 SQLITE_BUSY is an ordinary lock wait
        a busy-timeout fixes, 517 SQLITE_BUSY_SNAPSHOT is a stale-snapshot
        write upgrade no timeout can fix, 261 SQLITE_BUSY_RECOVERY is a
        WAL-recovery collision. Telling those three apart is what diagnoses a
        contention failure; without the code each hypothesis needs its own
        instrumented run."""
        var p = sqlite3_errmsg(self._conn)
        var msg = String()
        var i = 0
        # SAFETY: errmsg returns a sqlite-owned NUL-terminated const char*;
        # copied into a String, pointer not retained.
        while p[i] != 0 and i < 512:
            msg += chr(Int(p[i]))
            i += 1
        return Error(
            where
            + String(": ")
            + msg
            + String(" (sqlite extended rc=")
            + String(Int(sqlite3_extended_errcode(self._conn)))
            + String(")")
        )


# =============================================================================
# Local helpers — self-contained byte/text utilities (no cross-module pointers).
# =============================================================================
def _nul_terminated(s: String) -> List[UInt8]:
    """A NUL-terminated UTF-8 copy of `s` (for the C `const char*` args)."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    out.append(0)
    return out^


def _parse_i64(s: String) raises -> Int64:
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        raise Error("sqlite driver: empty integer text")
    var i = 0
    var neg = False
    if b[0] == UInt8(ord("-")):
        neg = True
        i = 1
    elif b[0] == UInt8(ord("+")):
        i = 1
    var acc: Int64 = 0
    var any = False
    while i < n:
        var c = b[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            raise Error("sqlite driver: non-numeric byte in integer text")
        acc = acc * Int64(10) + Int64(Int(c) - ord("0"))
        any = True
        i += 1
    if not any:
        raise Error("sqlite driver: integer text had no digits")
    return -acc if neg else acc


def _hex_nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error("sqlite driver: invalid hex nibble in UUID")


def _parse_uuid_text(s: String) raises -> Array[UInt8, 16]:
    var b = s.as_bytes()
    var out = Array[UInt8, 16](fill=0)
    var oi = 0
    var i = 0
    var n = len(b)
    while i < n and oi < 16:
        if b[i] == UInt8(ord("-")):
            i += 1
            continue
        if i + 1 >= n:
            raise Error("sqlite driver: truncated UUID hex")
        var hi = _hex_nibble(b[i])
        var lo = _hex_nibble(b[i + 1])
        out[oi] = (hi << 4) | lo
        oi += 1
        i += 2
    if oi != 16:
        raise Error("sqlite driver: UUID did not yield 16 bytes")
    return out^


def _hex_digit_lower(nibble: Int) -> String:
    if nibble < 10:
        return String(chr(ord("0") + nibble))
    return String(chr(ord("a") + (nibble - 10)))


def _uuid_bytes_to_hex_list(b: List[UInt8]) -> String:
    """Canonical 8-4-4-4-12 lowercase hyphenated UUID from 16 raw bytes."""
    var out = String()
    for i in range(16):
        var v = Int(b[i])
        out += _hex_digit_lower(v >> 4)
        out += _hex_digit_lower(v & 0x0F)
        if i == 3 or i == 5 or i == 7 or i == 9:
            out += "-"
    return out^


def _owned_utf8(b: List[UInt8]) -> String:
    """Carry a sqlite TEXT column's bytes into an owned String VERBATIM.

    ⛔ IT DOES NOT GO THROUGH `chr(Int(byte))`. `chr` maps a CODEPOINT to
    UTF-8, so every byte >= 0x80 would come back out as its own two-byte
    character: a TEXT column holding `⛔` (3 bytes) would read back as 6, and
    the corruption is INVISIBLE to an ASCII test.

    ⚠ IT IS THE **SAME** HAZARD AS ON THE BLOB ARM, and the TEXT arm is the one
    every ordinary string column takes. Sqlite stores TEXT as UTF-8 by
    definition, so the bytes are already a valid encoding and re-encoding them
    is pure loss. Byte-identical for ASCII."""
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _owned_bytes_verbatim(b: List[UInt8]) -> String:
    """Carry RAW bytes into an owned String VERBATIM (no chr()-per-byte codepoint
    promotion). The inverse of DbValue.bytes — an arbitrary byte sequence (0x00 /
    0xFF / non-UTF-8) round-trips exactly. Used for the LOGICAL_BYTES BLOB read arm
    so DbRow.get_bytes recovers the exact write-side bytes."""
    return String(StringSlice(unsafe_from_utf8=Span(b)))
