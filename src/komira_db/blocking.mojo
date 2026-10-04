# =============================================================================
# komira_db/blocking.mojo — single-shot blocking sugar over the [RT] Database.
# =============================================================================
#
# The `Database` trait's I/O methods are
# METHOD-`[RT: Runtime]`-parametric (`db.query[RT](reactor, sql, params)`), so
# the CALLER supplies the runtime + reactor. For SINGLE-SHOT callers (tests,
# one-row control-plane reads, the synchronous pool path) hand-threading a
# `BlockingRuntime` + `rt.reactor()` at every call site is pure ceremony.
#
# This file is that ceremony, factored out ONCE: each `db_blocking_*` free
# helper stands up a `BlockingRuntime[NoopSink]` on the calling thread, binds
# its reactor, and calls the corresponding `[RT]` `Database` method (a SYNC
# ESCAPE over the same `[RT]` transport). When the wire op parks, the calling thread blocks on the
# reactor's ONE fd until ready, then resumes (tokio current-thread `block_on`).
#
# THIS IS SUGAR OVER THE *ONE* TRAIT — NOT A SECOND TRAIT. There
# is exactly ONE `Database` surface (the `[RT]` methods). These helpers do not
# add a parallel API the production async path must keep in sync; they are a
# thin convenience the production `PerCoreAsyncRuntime` path simply does NOT
# use (production threads its own reactor through the `[RT]` methods directly).
#
# Encapsulation: String / List[DbValue] in, DbRows / DbRow / UInt64 out — no
# UnsafePointer, no reactor handle, crosses the helper boundary. The
# BlockingRuntime + reactor are stack-local to each call and drop at return.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db.database import Database, SqlDatabase
from komira_db.db_value import DbValue
from komira_db.db_row import DbRow, DbRows


comptime _SingleShotRt = BlockingRuntime[NoopSink]


def _new_single_shot_rt() raises -> _SingleShotRt:
    """Stand up a fresh current-thread BlockingRuntime[NoopSink] (no pthreads,
    no scheduler) — the single-shot sync-escape runtime."""
    return _SingleShotRt.new(NoopSink(_placeholder=UInt8(0)))


# =============================================================================
# Per-method blocking helpers — one per `Database` I/O method.
# =============================================================================
def db_blocking_execute[
    DB: SqlDatabase,
](mut db: DB, sql: String, params: List[DbValue]) raises -> UInt64:
    """Blocking `db.execute` — stand up a BlockingRuntime, run the `[RT]`
    execute to completion on its reactor, return rows_affected. Bound on
    `SqlDatabase`: `execute` is a SQL-string verb on the SQL
    sub-trait, not the neutral `Database` core."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    return db.execute[_SingleShotRt](reactor, sql, params)


def db_blocking_query[
    DB: SqlDatabase,
](mut db: DB, sql: String, params: List[DbValue]) raises -> DbRows:
    """Blocking `db.query`. Bound on `SqlDatabase` (the raw SQL-string
    verbs live on the SQL sub-trait)."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    return db.query[_SingleShotRt](reactor, sql, params)


def db_blocking_query_opt[
    DB: SqlDatabase,
](mut db: DB, sql: String, params: List[DbValue]) raises -> Optional[DbRow]:
    """Blocking `db.query_opt`. Bound on `SqlDatabase`."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    return db.query_opt[_SingleShotRt](reactor, sql, params)


def db_blocking_query_one[
    DB: SqlDatabase,
](mut db: DB, sql: String, params: List[DbValue]) raises -> DbRow:
    """Blocking `db.query_one`. Bound on `SqlDatabase`."""

    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    return db.query_one[_SingleShotRt](reactor, sql, params)


def db_blocking_begin[DB: Database](mut db: DB) raises:
    """Blocking `db.begin`."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    db.begin[_SingleShotRt](reactor)


def db_blocking_commit[DB: Database](mut db: DB) raises:
    """Blocking `db.commit`."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    db.commit[_SingleShotRt](reactor)


def db_blocking_rollback[DB: Database](mut db: DB) raises:
    """Blocking `db.rollback`."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    db.rollback[_SingleShotRt](reactor)


def db_blocking_claim_pending[
    DB: SqlDatabase,
](
    mut db: DB,
    table: String,
    n: Int,
    pending: String,
    assigned: String,
    extra_set: String,
    params: List[DbValue],
    phase_col: String = String("phase"),
) raises -> DbRows:
    """Blocking `db.claim_pending`. Bound on `SqlDatabase` (the only blocking
    helper that reaches a SQL-specific method — the `claim_pending` SKIP-LOCKED
    op); the other `db_blocking_*` helpers stay on the neutral `Database`.
    `phase_col` names the queue/status column, defaulted to `"phase"` so existing
    callers are byte-identical."""
    var rt = _new_single_shot_rt()
    ref reactor = rt.reactor()
    return db.claim_pending[_SingleShotRt](
        reactor, table, n, pending, assigned, extra_set, params, phase_col
    )
