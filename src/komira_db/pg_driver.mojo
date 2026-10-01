# =============================================================================
# komira_db/pg_driver.mojo — the PgDatabase Database conformer.
# =============================================================================
#
# The Postgres backend: a `Database`-trait conformer over
# `komira_pg`'s `PgConnection`. It completes the dual backend — the same
# generated `DbStorable` row type runs on BOTH sqlite (in-process FFI)
# AND pg (wire-to-server over SCRAM-over-TLS).
#
# ENCAPSULATION — the STRONGEST possible: this driver contains ZERO
# UnsafePointer, ZERO wildcard origin, ZERO unsafe_from_address. Every pointer /
# raw-byte / FFI concern is already encapsulated INSIDE `komira_pg` (the s2n
# TLS shim + the pgwire framing); the pg driver speaks only `komira_pg`'s safe
# surface: `PgValue` in, `PgRow` / `PgRows` / `UInt64` out. The komira_db public
# surface is exactly `Database`: String / List[DbValue] in, DbRows / DbRow /
# UInt64 out. Nothing unsafe crosses any boundary here. (Contrast the sqlite
# driver, which owns an opaque `sqlite3*` handle + an FFI carve-out; the pg
# driver needs neither — it is a pure safe-type adapter.)
#
# THE TYPED BINARY PATH (the point of this driver): execute / query route through
# `komira_pg`'s PREPARED-STATEMENT BINARY path (`prepare` + `query_prepared` /
# `execute_prepared`), so params bind in BINARY format and results decode from
# BINARY format — exact types, no text-parse ambiguity. The `$N` placeholders the
# generated INSERT renders (via `placeholder(i)`) are the pg extended-protocol
# positional params the Bind step fills.
#
# TYPE MAPPING (DbValue <-> PgValue). Both carriers use the IDENTICAL canonical-
# text convention (UUID = hyphenated hex; TIMESTAMPTZ = µs since UNIX epoch;
# TEXT[] = the `{a,b,c}` literal; INT = decimal ASCII; TEXT/JSONB = raw text), so
# the param map is a LOGICAL_* -> OID tag translation that passes `_text`
# straight through, and the result map renders each PgRow column (by its result
# OID) back to that same canonical TEXT the matching DbRow.get_* getter decodes:
#   LOGICAL_UUID        <-> OID_UUID         (2950)  — hyphenated hex
#   LOGICAL_INT4        <-> OID_INT4         (23)    — decimal
#   LOGICAL_INT8        <-> OID_INT8         (20)    — decimal
#   LOGICAL_TEXT        <-> OID_TEXT         (25)    — raw text
#   LOGICAL_JSONB       <-> OID_JSONB        (3802)  — proto3-canonical JSON text
#   LOGICAL_TIMESTAMPTZ <-> OID_TIMESTAMPTZ  (1184)  — µs since UNIX epoch
#   LOGICAL_TEXT_ARRAY  <-> OID_TEXT_ARRAY   (1009)  — {a,b,c} literal
# The remaining LOGICAL_* (FLOAT8/FLOAT4/BOOL/BYTES) fall back to TEXT binding
# (pg accepts a text-format bind for a text-castable param); the control-plane
# closed set above is the load-bearing path.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.pool import PooledResource
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

from komira_pg.connection import PgConnection, PgConfig, PreparedStatement
from komira_pg.pg_types import (
    PgValue,
    PgRow,
    PgRows,
    OID_BOOL,
    OID_BYTEA,
    OID_INT8,
    OID_INT4,
    OID_TEXT,
    OID_VARCHAR,
    OID_JSONB,
    OID_UUID,
    OID_TIMESTAMPTZ,
    OID_TEXT_ARRAY,
)


# =============================================================================
# PgDatabase — the Database conformer over a PgConnection.
# =============================================================================
struct PgDatabase(SqlDatabase, PooledResource):
    """A Postgres-backed `Database`. Owns ONE `PgConnection` (a single server
    session over SCRAM-over-TLS). v1 is a single connection — a connection pool
    (`PgPool` / per-lease checkout) is the documented FOLLOW-ON for concurrent
    control-plane access; a single connection is correct + sufficient for the
    sequential CRUD + claim workload.

    All execution routes through the komira_pg PREPARED-STATEMENT BINARY path,
    so the typed surface gets exact-typed values with no text-parse ambiguity.
    The public surface is exactly `Database` (String / List[DbValue] in, DbRows
    out); ZERO UnsafePointer crosses this boundary (komira_pg already owns every
    unsafe concern)."""

    var _conn: PgConnection

    # ---- lifecycle ----

    def __init__(out self, var conn: PgConnection):
        """Adopt an already-connected `PgConnection` (single owner; moved in)."""
        self._conn = conn^

    @staticmethod
    def connect[
        RT: Runtime,
    ](
        mut reactor: Reactor[RT.Sink], var config: PgConfig
    ) raises -> PgDatabase:
        """Open a fresh connection (TCP -> TLS -> SCRAM -> ReadyForQuery) on the
        CALLER's `reactor` and wrap it. The canonical entry point for
        `Store[PgDatabase]`. The runtime is the caller's (a
        `BlockingRuntime` for single-shot / tests via the blocking sugar; a
        `PerCoreAsyncRuntime` for concurrent production reads)."""
        var conn = PgConnection.connect[RT](reactor, config^)
        return PgDatabase(conn^)

    @staticmethod
    def connect_blocking(var config: PgConfig) raises -> PgDatabase:
        """Single-shot blocking connect: stand up a `BlockingRuntime[NoopSink]`
        on the calling thread, dial over its reactor, and return the connected
        driver. The SYNC ESCAPE for tests / the synchronous pool path.
        Production concurrent reads
        instead call `connect[PerCoreAsyncRuntime](reactor, config)` and thread
        their own reactor. ONE-trait sugar, NOT a parallel API."""
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        return PgDatabase.connect[BlockingRuntime[NoopSink]](reactor, config^)

    # ---- PooledResource conformance ----
    # `PgDatabase` is the canonical `PooledResource` conformer: `Pool[PgDatabase]`
    # is `PgPool` (pg_pool.mojo). The `Config` associated type is `PgConfig`, and
    # the pool factory `pooled_connect` delegates to the existing
    # `connect_blocking` (the synchronous-pool establishment path). `close` (above
    # / below) is the teardown. This makes `PgDatabase` a drop-in `Pool[T]`
    # element — the SAME cheap-vacate machinery a Redis/HTTP/gRPC resource uses.
    comptime Config = PgConfig

    @staticmethod
    def pooled_connect(var config: PgConfig) raises -> PgDatabase:
        """The `PooledResource` factory: establish ONE pg connection (full
        TCP->TLS->SCRAM->ReadyForQuery handshake) from the config. Delegates to
        the synchronous `connect_blocking` (the blocking-pool establishment
        path). Each call is a real handshake and bumps `Pool.connects_made()`."""
        return PgDatabase.connect_blocking(config^)

    def close(mut self):
        """Graceful Terminate + TLS shutdown + fd close."""
        self._conn.close()

    def into_conn(deinit self) -> PgConnection:
        """Recover the owned `PgConnection` out of the driver (single-owner
        move-out). The mirror of `__init__(out self, var conn)`: a caller that
        needs the raw connection — to drive a poll-shaped `PgQueryOp`
        (suspendable handlers) that owns the connection by value across
        reactor parks — extracts it here, drives the op, then re-wraps the
        recovered connection via `PgDatabase(conn^)` to hand it back to the pool.
        Encapsulation-clean: the connection moves by value (`^`); no pointer
        crosses the boundary."""
        return self._conn^

    # ---- the Database execution surface (the typed BINARY path) ----

    def execute[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> UInt64:
        """Run a non-result statement and return rows_affected. Routes through
        prepare + execute_prepared (BINARY bind) on the CALLER's reactor (every
        wire op parks on it). The prepared statement is single-use here
        (parse-per-call); statement caching is a FOLLOW-ON."""
        var stmt = self._conn.prepare[RT](reactor, sql)
        var pg_params = _to_pg_params(params)
        var affected = self._conn.execute_prepared[RT](reactor, stmt, pg_params)
        self._conn.close_prepared[RT](reactor, stmt)
        return affected

    def query[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> DbRows:
        """Run a query and return the full materialized result set. Routes
        through prepare + query_prepared (BINARY bind + BINARY results) on the
        CALLER's reactor; each PgRow column is rendered to the canonical TEXT the
        DbRow getters decode."""
        var stmt = self._conn.prepare[RT](reactor, sql)
        var pg_params = _to_pg_params(params)
        # Capture the result column OIDs + names from the Describe BEFORE the
        # execute (so the renderer knows each column's logical type). The Bind
        # step may also emit a fresh RowDescription, but the statement's
        # Describe OIDs are authoritative for the closed set.
        var result_oids = List[UInt32]()
        for o in stmt.result_oids:
            result_oids.append(o)
        var col_names = List[String]()
        for c in range(stmt.result_column_count()):
            col_names.append(stmt.result_column_name(c))
        var pg_rows = self._conn.query_prepared[RT](reactor, stmt, pg_params)
        self._conn.close_prepared[RT](reactor, stmt)
        var rows = _pg_rows_to_db_rows(pg_rows, result_oids, col_names)
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
        # Transaction verbs run as RAW SQL via the simple-query path — they take
        # no params and return no rows, so the extended-protocol round-trip is
        # unnecessary overhead.
        _ = self._conn.execute[RT](reactor, String("BEGIN"))

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = self._conn.execute[RT](reactor, String("COMMIT"))

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = self._conn.execute[RT](reactor, String("ROLLBACK"))

    # ---- per-driver dialect ----

    @staticmethod
    def dialect() -> String:
        """Full Postgres over the wire (ON CONFLICT / RETURNING / FOR UPDATE SKIP
        LOCKED / JSONB `->>` / pg-expression sets all supported)."""
        return String("pg")

    @staticmethod
    def placeholder(i: Int) -> String:
        """Pg positional placeholder `$<i+1>` (1-based)."""
        return String("$") + String(i + 1)

    @staticmethod
    def now_expr() -> String:
        """Pg current-timestamp expression."""
        return String("NOW()")

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
        return them, lock-free across concurrent claimers. The queue/status column
        is `phase_col` (default `"phase"` at the neutral layer). pg realizes the
        exclusivity NATIVELY via `FOR UPDATE SKIP LOCKED`: the inner SELECT locks
        only rows no other transaction holds, so two concurrent claimers never
        select the same row (no global write serialization — true concurrency,
        unlike the sqlite BEGIN-IMMEDIATE single-writer approach). The whole
        statement is a single auto-committed UPDATE ... RETURNING, so no explicit
        BEGIN/COMMIT is needed (it is atomic on its own)."""
        var set_clause = phase_col + String(" = '") + assigned + String("'")
        if extra_set.byte_length() > 0:
            set_clause += String(", ") + extra_set
        # The LIMIT count is the FINAL positional param; `params` (if any) feed
        # the extra_set assignments in order, then the LIMIT binds last.
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
            + String(" FOR UPDATE SKIP LOCKED) RETURNING *")
        )
        var claim_params = params.copy()
        claim_params.append(DbValue.int8(Int64(n)))
        return self.query[RT](reactor, sql, claim_params)

    # The default primary-key column name for the claim's identity sub-select.
    # Mirrors the sqlite driver; a future caller needing a different PK threads
    # it through a richer claim signature.
    comptime PK_DEFAULT: StaticString = "id"

    # =========================================================================
    # The 9 neutral structured ops — each a 1-line delegation to the
    # shared byte-identical SQL renderer in sql_neutral_ops.mojo. Identical
    # bodies across pg / sqlite / pgstore; this driver supplies its dialect
    # tokens ("pg" / "$N" / "NOW()") + its execute/query/claim_pending.
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


# =============================================================================
# DbValue -> PgValue (the param BINARY-bind map).
# =============================================================================
def to_pg_params(params: List[DbValue]) -> List[PgValue]:
    """PUBLIC wrapper over `_to_pg_params` (the backend-neutral `DbValue` ->
    `PgValue` BINARY-bind map the synchronous `PgDatabase` path uses).
    Suspendable handlers build their bind params as `List[DbValue]` (the
    SAME shape the store builds, so the bind is byte-identical to the synchronous
    path) and feed them to a poll-shaped `PgQueryOp`, which wants `List[PgValue]`
    — this is the bridge."""
    return _to_pg_params(params)


def _to_pg_params(params: List[DbValue]) -> List[PgValue]:
    """Map each backend-neutral `DbValue` to its `PgValue` rendering for the
    BINARY bind. Both carriers hold the canonical value in a single `_text`
    field with the identical convention, so this is a LOGICAL_* -> OID tag
    translation that passes the text straight through; `PgValue.binary_body()`
    then encodes the wire body from the OID + text at bind time."""
    var out = List[PgValue]()
    for i in range(len(params)):
        ref v = params[i]
        var oid = _oid_for_logical(v.logical_type)
        if v.is_null:
            out.append(PgValue.null(oid))
        else:
            # Pass the canonical text straight through; tag with the pg OID so
            # binary_body() picks the right binary encoder.
            out.append(PgValue(oid, False, v.as_text()))
    return out^


def _oid_for_logical(lt: Int) -> UInt32:
    """The pg OID for a backend-neutral logical type tag. The closed control-
    plane set maps 1:1; everything else binds as TEXT (a text-format-castable
    param — pg coerces on the server)."""
    if lt == LOGICAL_UUID:
        return OID_UUID
    elif lt == LOGICAL_INT4:
        return OID_INT4
    elif lt == LOGICAL_INT8:
        return OID_INT8
    elif lt == LOGICAL_TIMESTAMPTZ:
        return OID_TIMESTAMPTZ
    elif lt == LOGICAL_JSONB:
        return OID_JSONB
    elif lt == LOGICAL_TEXT_ARRAY:
        return OID_TEXT_ARRAY
    elif lt == LOGICAL_BOOL:
        # A native BOOLEAN column needs OID_BOOL(16): the bind path sends all
        # params with format-code BINARY(1), and pg's binary bool is exactly
        # 1 byte (0x00/0x01). Tagging BOOL as OID_TEXT would send a 4-byte ASCII
        # "true" under a binary format code -> "22P03 incorrect binary data
        # format in bind parameter N" on every INSERT/UPDATE of a bool column.
        # pg_param_binary(OID_BOOL) emits the 1 byte.
        return OID_BOOL
    elif lt == LOGICAL_BYTES:
        # A native `bytea` column needs OID_BYTEA(17): the DbValue.bytes carrier
        # holds the RAW blob bytes verbatim, and pg_param_binary(OID_BYTEA) emits
        # exactly those bytes as the binary value body — a REAL binary bind, not a
        # base64/hex TEXT literal.
        return OID_BYTEA
    else:
        # LOGICAL_TEXT / FLOAT8 / FLOAT4 — bind as TEXT. The carrier already holds
        # the canonical decimal / raw text, and a text-format value body is a valid
        # bind for a text-coercible column.
        return OID_TEXT


# =============================================================================
# PgRows (BINARY) -> DbRows (the result render map).
# =============================================================================
def pg_rows_to_db_rows(
    pg_rows: PgRows, result_oids: List[UInt32], col_names: List[String]
) raises -> DbRows:
    """PUBLIC wrapper over `_pg_rows_to_db_rows` (the BINARY `PgRows` ->
    backend-neutral `DbRows` renderer the synchronous `PgDatabase.query` path
    uses). Suspendable handlers drive the EXECUTE round-trip via a

    poll-shaped `PgQueryOp` that returns `PgRows` directly (it bypasses
    `PgDatabase.query`, which would block the worker), so they need this SAME
    mapper to render those rows into the `DbRows` the typed `from_row` cascade
    decodes — producing a result byte-identical to the synchronous path. Pass the
    prepared statement's result OIDs + names (the authoritative closed set)."""
    return _pg_rows_to_db_rows(pg_rows, result_oids, col_names)


def _pg_rows_to_db_rows(
    pg_rows: PgRows, result_oids: List[UInt32], col_names: List[String]
) raises -> DbRows:
    """Render a BINARY-format `PgRows` into the backend-neutral `DbRows`. Each
    column is decoded from its binary wire form via the typed `PgRow.get_*`
    getter selected by the column's result OID, then re-rendered to the canonical
    TEXT the matching `DbRow.get_*` getter decodes. This keeps the untyped DbRow
    self-describing enough for the typed `from_row` cascade (which calls the
    right getter per field in field-number order)."""
    var out_rows = List[DbRow]()
    var ncols = len(result_oids)
    for ri in range(pg_rows.__len__()):
        ref pr = pg_rows.row(ri)
        var data = List[UInt8]()
        var offsets = List[Int]()
        offsets.append(0)
        var nulls = List[Bool]()
        var ltypes = List[Int]()
        var row_cols = pr.col_count()
        var limit = ncols if ncols < row_cols else row_cols
        for c in range(limit):
            if pr.is_null(c):
                nulls.append(True)
                ltypes.append(LOGICAL_TEXT)
                offsets.append(len(data))
                continue
            nulls.append(False)
            var cell = _render_pg_cell(pr, c, result_oids[c])
            ltypes.append(cell[1])
            var cb = cell[0].as_bytes()
            for j in range(len(cb)):
                data.append(cb[j])
            offsets.append(len(data))
        out_rows.append(
            DbRow(data^, offsets^, nulls^, ltypes^, col_names.copy())
        )
    return DbRows(out_rows^, col_names.copy())


def _render_pg_cell(
    row: PgRow, col: Int, oid: UInt32
) raises -> Tuple[String, Int]:
    """Decode column `col` of a BINARY `PgRow` (by its result `oid`) to the
    canonical TEXT form + the logical-type tag the matching DbRow getter
    expects. Uses the format-aware PgRow getters (which branch to the binary
    decoder on the `_binary` flag set by the extended-protocol path)."""
    if oid == OID_BOOL:
        # 1 binary byte -> canonical "true"/"false" text the DbRow bool decoder
        # (_db_decode_bool / _row_bool) accepts.
        return (
            (String("true") if row.get_bool(col) else String("false")),
            LOGICAL_BOOL,
        )
    elif oid == OID_UUID:
        # 16 binary bytes -> hyphenated hex (what DbRow.get_uuid re-parses).
        return (row.get_uuid_hex(col), LOGICAL_UUID)
    elif oid == OID_INT4:
        return (String(Int(row.get_int4(col))), LOGICAL_INT4)
    elif oid == OID_INT8:
        return (String(Int(row.get_int8(col))), LOGICAL_INT8)
    elif oid == OID_TIMESTAMPTZ:
        # pg 2000-epoch binary -> µs since UNIX epoch (decimal), the carrier
        # convention DbRow.get_timestamptz decodes.
        return (
            String(Int(row.get_timestamptz_micros(col))),
            LOGICAL_TIMESTAMPTZ,
        )
    elif oid == OID_JSONB:
        return (row.get_jsonb(col), LOGICAL_JSONB)
    elif oid == OID_TEXT_ARRAY:
        # Binary array_send body -> elements -> the canonical {a,b,c} literal
        # DbRow.get_text_array re-parses.
        return (_elements_to_literal(row.get_text_array(col)), LOGICAL_TEXT_ARRAY)
    elif oid == OID_BYTEA:
        # bytea BINARY body = the raw blob bytes. `get_text` carries them VERBATIM
        # into the canonical `_text` (byte-backed String, no codepoint promotion),
        # so DbRow.get_bytes reads the exact write-side bytes back. Tagged
        # LOGICAL_BYTES so the DbRow's is_null flag + logical_type are precise.
        return (row.get_text(col), LOGICAL_BYTES)
    else:
        # OID_TEXT / OID_VARCHAR / anything else — raw UTF-8.
        return (row.get_text(col), LOGICAL_TEXT)


def _elements_to_literal(elements: List[String]) -> String:
    """Render TEXT[] elements back to the canonical pg `{a,b,c}` array literal
    (the DbValue / DbRow carrier form). The closed-set contract is simple labels
    (no embedded ',' / '}' / quoting)."""
    var lit = String("{")
    for i in range(len(elements)):
        if i > 0:
            lit += ","
        lit += elements[i]
    lit += "}"
    return lit^
