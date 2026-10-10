# =============================================================================
# komira_db/database.mojo — the Database / SqlDatabase / Store trait skeleton.
# =============================================================================
#
# The backend-generic execution surface. `Database` is the
# common seam across the concrete backends (pg = wire-to-server over
# komira_db_postgres.wire; sqlite = FFI to embedded libsqlite3; pgstore = serverless-pg over
# object-store) — designed against all so the trait bakes in NO backend's
# assumptions.
#
# THE TWO-TRAIT SPLIT:
# the surface is partitioned into a BACKEND-NEUTRAL CORE (`Database`) + a
# SQL-SPECIFIC sub-trait (`SqlDatabase(Database)`). This is the shared
# foundation for running a non-SQL backend (Firestore) under the same services
# AND making app binaries generic over the backend implementation.
#
#   * `Database` — the backend-neutral surface EVERY backend (SQL OR
#     document-store) can supply: the tx verbs (begin / commit / rollback) +
#     the 9 STRUCTURED-OP methods (get_by_key / put / delete_by_key /
#     query_rows / conditional_update / delete_where / create_if_absent /
#     claim_rows) that operate over structured value types (Pred / Filter /
#     Order / DbColVal / PodNameMinter), NOT SQL strings. A Firestore-style
#     document backend implements these 9 ops NATIVELY (a document GET / PATCH /
#     conditional-create / structured-query), never rendering SQL. `Database`
#     is SQL-STRING-FREE (`execute` / `query` / `query_opt` /
#     `query_one` live on `SqlDatabase`).
#
#   * `SqlDatabase(Database)` — the SQL-string + SQL-dialect surface only a
#     relational backend can supply:
#       - execute / query / query_opt / query_one  — the raw SQL-string verbs
#         (here, not on `Database` — a document backend has no SQL
#         string to run; only a relational backend does). `MigrationRunner`,
#         `Store`, hand-written raw-SQL admin callers, and the SQL IMPL of the 9
#         neutral ops reach these.
#       - dialect()      — the backend identity TAG ("pg" | "sqlite" |
#                          "pgstore") that routes per-backend SQL-FEATURE arms.
#       - placeholder(i) — pg "$N" | sqlite "?N" (the generated insert_sql
#                          renders positional binds with it).
#       - now_expr()     — pg "NOW()" | sqlite strftime-based.
#       - claim_pending  — the portable SKIP-LOCKED concurrent CLAIM op
#                          (pg FOR UPDATE SKIP LOCKED, sqlite
#                          BEGIN IMMEDIATE). Its SQL-shaped table/pending/
#                          assigned/extra_set contract is SQL-specific.
#       - the SQL IMPLEMENTATION of the 9 neutral ops: each renders
#         the SAME SQL a hand-built SQL store would (byte-identical),
#         calling the driver's own execute/query/claim_pending internally.
#     `DbStorable.insert_sql[D: SqlDatabase]`, `Store[DB: SqlDatabase]`, and
#     the SQL stores (`JobStore[DB]` and other typed SQL stores) parametrize
#     over `SqlDatabase` precisely because they reach these SQL methods.
#
# THE 9 NEUTRAL OPS render byte-identical SQL through the shared
# free functions in `sql_neutral_ops.mojo` (one place, called by each driver's
# 1-line conformance), so the SQL wire behavior is the same as the
# hand-built SQL. A store written over these 9 ops on a
# NEUTRAL `Database` bound runs on Firestore too.
#
# Every I/O method is METHOD-`[RT: Runtime]`-
# parametric and takes `mut reactor: Reactor[RT.Sink]`. The caller supplies
# the runtime (a `BlockingRuntime[NoopSink]` for single-shot / tests — via the
# `blocking_*` sugar in `komira_db.blocking`; a `PerCoreAsyncRuntime` for
# concurrent / pipelined production reads). pg parks its wire I/O on the
# reactor (so N connections' queries interleave on ONE reactor); sqlite is
# in-process synchronous FFI and IGNORES the reactor (`_ = reactor`) — the
# param exists purely for trait uniformity so ONE `Store[DB]` / `JobStore[DB]`
# cascade drives both backends. `placeholder` / `now_expr` stay reactor-free
# (pure comptime dialect).
#
# Encapsulation: the surface is String / List[DbValue] /
# structured value types in, DbRows / DbRow / typed scalar out. ZERO
# UnsafePointer crosses any boundary.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db.db_value import DbValue
from komira_db.db_row import DbRow, DbRows
from komira_db.neutral_ops import (
    Pred,
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
)


# =============================================================================
# Database — the backend-NEUTRAL surface (tx verbs + the 9 structured ops).
# =============================================================================
trait Database(Movable, Deinitable):
    """The backend-neutral database surface: the transactional core that EVERY
    backend (SQL OR document-store) can supply. It carries NO SQL-STRING
    assumption — `execute` / `query` / `query_opt` / `query_one` live on
    the `SqlDatabase` sub-trait, so a non-relational backend (e.g. a
    Firestore-style document store) can conform to `Database` alone. `Database`
    now exposes ONLY the tx verbs (begin / commit / rollback) + the 9
    STRUCTURED-OP methods (over Pred / Filter / Order / DbColVal / PodNameMinter
    — never SQL strings). A document backend implements those 9 ops natively; a
    SQL backend implements them by rendering the byte-identical SQL a
    hand-built SQL store would (via `SqlDatabase`'s execute/query).

    Every I/O method is METHOD-`[RT: Runtime]`-
    parametric and takes `mut reactor: Reactor[RT.Sink]`. The caller supplies
    the runtime (a `BlockingRuntime[NoopSink]` for single-shot / tests — via the
    `blocking_*` sugar in `komira_db.blocking`; a `PerCoreAsyncRuntime` for
    concurrent / pipelined production reads). pg parks its wire I/O on the
    reactor (so N connections' queries interleave on ONE reactor); sqlite is
    in-process synchronous FFI and IGNORES the reactor (`_ = reactor`) — the
    param exists purely for trait uniformity so ONE `Store[DB]` / `JobStore[DB]`
    cascade drives both backends."""

    # ---- the tx verbs (backend-neutral) ----
    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        ...

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        ...

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        ...

    # =========================================================================
    # The 9 STRUCTURED-OP methods. Backend-neutral: they operate over
    # structured value types (Pred / Filter / Order / DbColVal / PodNameMinter),
    # NOT SQL strings. A SQL backend implements each by rendering the SAME SQL
    # a hand-built SQL store would (byte-identical, via SqlDatabase.execute/query);
    # a document backend implements each natively (GET / PATCH / conditional-
    # create / structured-query). All are `[RT]`-parametric + reactor-threaded.
    # =========================================================================

    def get_by_key[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        key_col: String,
        key_val: DbValue,
    ) raises -> Optional[DbRow]:
        """Fetch the single row in `table` whose `key_col == key_val`, projecting
        `cols` (in order). None if absent. (SQL: `SELECT <cols> FROM <table>
        WHERE <key_col> = $0`)."""
        ...

    def put[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> UInt64:
        """Insert one row into `table` binding `vals` positionally to `cols`.
        Returns rows_affected. An insert, never an upsert: a row whose primary
        key already exists is refused (raises) and the stored row is
        unchanged, as a plain SQL INSERT is (a document backend creates the
        document only if absent). (SQL: `INSERT INTO <table> (<cols>) VALUES
        (<placeholders>)`)."""
        ...

    def delete_by_key[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        key_col: String,
        key_val: DbValue,
    ) raises -> UInt64:
        """Delete the row(s) in `table` whose `key_col == key_val`. Returns
        rows_affected. (SQL: `DELETE FROM <table> WHERE <key_col> = $0`)."""
        ...

    def query_rows[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        """Select `cols` from `table` where `filter` holds, ordered by `order`,
        capped at `limit`. The workhorse read. (SQL: `SELECT <cols> FROM <table>
        [WHERE <filter>] [ORDER BY <order>] [LIMIT $n]`)."""
        ...

    def query_rows_locked[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
    ) raises -> DbRows:
        """The concurrent-SCAN read (`query_rows` + a backend-divergent row-lock
        hint). Select `cols` from `table` where `filter` holds, ordered by
        `order`, taking a per-row exclusive lock that SKIPS rows a peer already
        holds — the multi-replica defense-in-depth read (list_by_status /
        list_due). SAME shape as `claim_rows`'s SKIP-LOCKED, but for a plain
        enumerate: a SQL backend renders `FOR UPDATE SKIP LOCKED` on FULL Postgres
        ONLY (sqlite / pgstore OMIT it — there a single scheduler tick is the
        single writer); a document backend IGNORES the lock (the same single-writer
        property covers it) and delegates to `query_rows`. (SQL: `SELECT <cols>
        FROM <table> [WHERE <filter>] [ORDER BY <order>] [FOR UPDATE SKIP
        LOCKED]`)."""
        ...

    def conditional_update[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        guard: Filter,
        updates: List[DbColVal],
        coalesce: Bool,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> UInt64:
        """The optimistic-concurrency CAS UPDATE: set each `updates` column
        (`COALESCE($n, col)` when `coalesce` so a NULL leaves the column
        untouched — the partial-heartbeat shape), bump `bump_version_col` by 1,
        stamp each `now_cols` column with `now_expr()`, WHERE `guard` holds.
        Returns rows_affected (0 ⇒ the caller raises ConcurrentModification).
        (SQL: `UPDATE <table> SET ... WHERE <guard>`)."""
        ...

    def delete_where[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        filter: Filter,
    ) raises -> UInt64:
        """Delete every row in `table` matching `filter` (the range-DELETE / TTL
        sweep). Returns rows_affected. (SQL: `DELETE FROM <table> WHERE
        <filter>`)."""
        ...

    def create_if_absent[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        """Atomically insert the row (`cols`/`vals`) IFF no row with
        `unique_col == unique_val` exists. Returns True iff WE inserted it (won
        the key); False iff a row already claimed it (the caller re-reads the
        winner). The idempotency-dedup primitive. (SQL: `INSERT ... ON CONFLICT
        (<unique_col>) DO NOTHING RETURNING ...` on pg; a native-OCC
        check-then-insert on pgstore)."""
        ...

    def create_if_absent_composite[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        """The COMPOSITE-KEY generalization of `create_if_absent`: atomically
        insert the row (`cols`/`vals`) IFF no row exists with the SAME tuple of
        `conflict_cols` values. Returns True iff WE won the composite key; False
        iff a row already claims it. This expresses keys like `(mailbox_id,
        content_hash)` that the single-column `create_if_absent` cannot — callers
        previously did INSERT + catch-unique-violation + re-read. The conflict
        values are the row's own values for `conflict_cols` (matched positionally
        against `cols`). (SQL: `INSERT ... ON CONFLICT (<c1, c2, ...>) DO NOTHING
        RETURNING <c1>` on pg/sqlite; a native-OCC composite-key snapshot-read +
        plain INSERT on pgstore. Document backend: a deterministic doc-id derived
        from the composite key tuple + a conditional create)."""
        ...

    def claim_rows[
        RT: Runtime,
    ](
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
        """Atomically claim up to `n` rows matching `filter` (ordered by
        `order`), transition `phase_col` `from_phase` -> `to_phase`, apply each
        `extra` SET, bump `bump_version_col` by 1, stamp each `now_cols` column
        with the backend's now-expr, mint a per-row id via `per_row_mint`, and
        return them. The queue-as-query. Realized via the driver's native
        concurrent-claim (pg FOR UPDATE SKIP LOCKED; sqlite BEGIN IMMEDIATE;
        pgstore native-OCC loop). This is the neutral face over `claim_pending` +
        the pod_name mint.

        `bump_version_col` / `now_cols` are FIRST-CLASS (not raw-expr `extra`
        terms) so a NEUTRAL caller (a store on the `Database` bound) never needs
        `now_expr()` — the SQL renderer supplies the dialect now-expr, a document
        backend stamps its own server timestamp. `JobStore.find_and_assign_jobs`
        is the worked example: `pod_name` via `per_row_mint`,
        `bump_version_col="version"`, `now_cols=["updated_at"]` renders
        `pod_name = <expr>, version = version + 1, updated_at = <now_expr>`.

        ⚠ `per_row_mint` BINDS NO PARAMETER. `pod_name` is
        `derive_pod_name(prefix, <the row's id>)`, a pure function of the row,
        so every backend computes it from data it already has — see
        `komira_db.neutral_ops.derive_pod_name` for why it may never grow a term
        that is not recomputable."""
        ...


# =============================================================================
# SqlDatabase — the SQL-specific sub-trait (dialect helpers + SKIP-LOCKED claim).
# =============================================================================
trait SqlDatabase(Database):
    """The SQL-specific database surface: everything a RELATIONAL backend must
    expose that a document-store backend need not. A `SqlDatabase` IS a
    `Database` (it inherits the neutral execution + tx core) PLUS the per-driver
    SQL-dialect helpers and the SQL-shaped concurrent-CLAIM op.

    `DbStorable.insert_sql[D: SqlDatabase]`, `Store[DB: SqlDatabase]`, and the
    SQL data-access services (`JobStore[DB]`, `MigrationRunner[DB]` and
    other typed SQL stores) parametrize over `SqlDatabase` precisely because
    their bodies render SQL via `D.execute` / `D.query` / `D.placeholder(i)` /
    `D.now_expr()`, branch on `D.dialect()`, and call `D.claim_pending`.
    Consumers that use ONLY the neutral tx verbs + the 9 structured ops stay
    bound on `Database` (and run on a document backend too)."""

    # ---- the raw SQL-string execution surface (not on Database) ----
    # A document backend has no SQL string to run — only a relational backend
    # does — so these live on the SQL sub-trait, not the neutral core. The 9
    # neutral ops' SQL implementations render SQL and call THESE internally.
    def execute[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> UInt64:
        """Run a non-result statement; return rows_affected."""
        ...

    def query[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> DbRows:
        """Run a query; return the full materialized result set."""
        ...

    def query_opt[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> Optional[DbRow]:
        """Run a query expected to yield 0-or-1 rows."""
        ...

    def query_one[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> DbRow:
        """Run a query expected to yield exactly 1 row (raises otherwise)."""
        ...

    # ---- per-driver dialect (the differences the trait MUST expose) ----
    @staticmethod
    def dialect() -> String:
        """The driver's dialect TAG — the single source of truth for backend
        identity. `"pg"` (PgDatabase, full Postgres over the wire), `"sqlite"`
        (SqliteDatabase, embedded), or `"pgstore"` (PgstoreDatabase, the
        serverless Postgres FACE over object-store: pg-style `$N` placeholders +
        `NOW()` BUT a deliberately NARROW SQL executor — no ON CONFLICT /
        RETURNING / FOR UPDATE SKIP LOCKED / JSONB `->>` / pg-expression claim
        sets).

        WHY THIS EXISTS: a binary dialect probe such as
        `placeholder(0) == "$1"` cannot work here. pgstore IS
        a `$1` face, so that probe classifies it as full-pg and routes it onto
        pg-only SQL its executor cannot parse. A THIRD tag lets each store
        SQL-gen site emit a pgstore-SAFE arm (drop SKIP LOCKED; a portable
        config-key filter; a native-OCC idempotency dedup instead of ON CONFLICT;
        a pgstore-native claim set) WITHOUT widening the pgsql executor. The
        `placeholder` / `now_expr` dialect (pg-style for pgstore) is UNCHANGED —
        `dialect()` distinguishes the SQL-FEATURE surface, which placeholder
        shape alone cannot."""
        ...

    @staticmethod
    def placeholder(i: Int) -> String:
        """Positional placeholder for bind index `i` (0-based). pg renders
        `$<i+1>`; sqlite renders `?<i+1>`."""
        ...

    @staticmethod
    def now_expr() -> String:
        """The current-timestamp SQL expression. pg `NOW()`; sqlite a
        strftime-based expression."""
        ...

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
        """Atomically transition up to `n` rows from `pending` -> `assigned`
        and return them, matching on the queue/status column named `phase_col`
        (defaulted to `"phase"` at the neutral `claim_rows` layer + the
        `db_blocking_claim_pending` sugar so existing callers are byte-identical;
        a store whose queue column is named differently passes its own name
        without renaming the column). Each driver realizes the exclusivity
        natively (pg: FOR UPDATE SKIP LOCKED; sqlite: BEGIN IMMEDIATE + UPDATE
        ... WHERE id IN (SELECT ... LIMIT n) RETURNING)."""
        ...
