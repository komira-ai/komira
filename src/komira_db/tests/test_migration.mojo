# =============================================================================
# komira_db/tests/test_migration.mojo
# MigrationRunner: ordering, name-keyed pending set, atomicity, drift guard.
# =============================================================================
# `MigrationRunner` applies the steps whose NAME the ledger lacks, in version
# order, in one transaction, recording each under the next apply-sequence
# number (migration.mojo, `run`). Every expected statement and message below is
# written out by hand from that contract, never computed by the code under
# test.
#
# `_RecDb[D]` is a recording `SqlDatabase`: it renders nothing itself, logs
# every raw verb it is handed (`<verb> <sql> [<params>]`) and answers from a
# script, so a test reads back the exact SQL and params an op produced and
# drives each result arm (a row or none, the candidate rows a client-side
# filter sees). `D` picks the dialect tokens: pg (`$N`, `NOW()`), sqlite
# (`?N`, the sqlite driver's now expression) and pgstore (`$N`, `NOW()`, the
# narrow executor). Its nine neutral ops delegate to the `sql_op_*` functions
# exactly as the pg and sqlite drivers do, so the ops are reached through the
# `Database` trait methods. For the migration runner it answers the
# `MAX(version)` read and `SELECT *` (the ledger, a live table's columns) from
# their own scripts, and `fail_on` makes one statement fail.
#
# `_RecDb` is the same in test_sql_render.mojo, test_sql_ops.mojo,
# test_sql_ops_split.mojo and test_migration.mojo: a test-support package
# implementing `SqlDatabase` would depend on komira_db, which its tests cannot
# depend on (a cycle), and each welded test is built from its one file.
#
# A param is logged as `<logical type>=<text>` (`~` instead of `=` for a NULL):
# logical type 1 is TEXT, 2 is INT4, 3 is INT8, 10 is TEXT[] (db_value.mojo).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.db_value import DbValue, DbColumn, LOGICAL_TEXT
from komira_db.db_row import DbRow, DbRows
from komira_db.db_storable import DbStorable
from komira_db.migration import Migration, MigrationRunner
from komira_db.neutral_ops import (
    Pred,
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
)
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


comptime D_PG = 0
comptime D_SQLITE = 1
comptime D_PGSTORE = 2
comptime SQLITE_NOW = "CAST(unixepoch('now','subsec')*1000000 AS INTEGER)"

comptime RT = BlockingRuntime[NoopSink]


def _new_rt() raises -> RT:
    return RT.new(NoopSink(_placeholder=UInt8(0)))


def _enc(params: List[DbValue]) -> String:
    var s = String()
    for i in range(len(params)):
        if i > 0:
            s += ","
        ref v = params[i]
        s += String(v.logical_type)
        if v.is_null:
            s += "~"
        else:
            s += "=" + v.as_text()
    return s^


struct _RecDb[D: Int](SqlDatabase):
    var log: List[String]
    var rows: List[DbRow]  # what `query` / `claim_pending` answer
    var row_cols: List[String]
    var opt_hits: List[Bool]  # FIFO: does the next `query_opt` find a row
    var opt_row: DbRow
    var exec_ret: UInt64
    var ledger_rows: List[DbRow]  # what `SELECT * FROM ...` answers
    var ledger_cols: List[String]
    var max_version: Int  # the `MAX(version)` answer; -1 answers no row
    var fail_on: String  # `execute` of exactly this SQL (or this tx verb) raises

    def __init__(out self):
        self.log = List[String]()
        self.rows = List[DbRow]()
        self.row_cols = List[String]()
        self.opt_hits = List[Bool]()
        var v = List[DbValue]()
        v.append(DbValue.text("hit"))
        var c = List[String]()
        c.append("id")
        self.opt_row = DbRow.from_values(v, c)
        self.exec_ret = 0
        self.ledger_rows = List[DbRow]()
        self.ledger_cols = List[String]()
        self.max_version = 0
        self.fail_on = String("")

    # ---- tx verbs ----
    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.log.append("BEGIN")
        if self.fail_on == "BEGIN":
            raise Error("boom")

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.log.append("COMMIT")
        if self.fail_on == "COMMIT":
            raise Error("boom")

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.log.append("ROLLBACK")
        if self.fail_on == "ROLLBACK":
            raise Error("boom")

    # ---- raw SQL verbs (recorded, scripted) ----
    def execute[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> UInt64:
        self.log.append("execute " + sql + " [" + _enc(params) + "]")
        if self.fail_on.byte_length() > 0 and sql == self.fail_on:
            raise Error("boom")
        return self.exec_ret

    def query[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> DbRows:
        self.log.append("query " + sql + " [" + _enc(params) + "]")
        if sql.startswith("SELECT COALESCE(MAX(version), 0) AS v FROM "):
            var out = List[DbRow]()
            if self.max_version >= 0:
                var v = List[DbValue]()
                v.append(DbValue.int8(Int64(self.max_version)))
                out.append(DbRow.from_values(v, _s("v")))
            return DbRows(out^, _s("v"))
        if sql.startswith("SELECT * FROM "):
            return DbRows(self.ledger_rows.copy(), self.ledger_cols.copy())
        return DbRows(self.rows.copy(), self.row_cols.copy())

    def query_opt[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> Optional[DbRow]:
        self.log.append("query_opt " + sql + " [" + _enc(params) + "]")
        if len(self.opt_hits) == 0:
            raise Error("_RecDb: unscripted query_opt")
        var hit = self.opt_hits.pop(0)
        if hit:
            return Optional[DbRow](self.opt_row.copy())
        return Optional[DbRow](None)

    def query_one[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> DbRow:
        raise Error("_RecDb: query_one is not used by the neutral ops")

    @staticmethod
    def dialect() -> String:
        comptime if Self.D == D_PG:
            return String("pg")
        elif Self.D == D_SQLITE:
            return String("sqlite")
        else:
            return String("pgstore")

    @staticmethod
    def placeholder(i: Int) -> String:
        comptime if Self.D == D_SQLITE:
            return String("?") + String(i + 1)
        else:
            return String("$") + String(i + 1)

    @staticmethod
    def now_expr() -> String:
        comptime if Self.D == D_SQLITE:
            return String(SQLITE_NOW)
        else:
            return String("NOW()")

    def claim_pending[RT: Runtime](
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
        self.log.append(
            "claim "
            + table
            + " n="
            + String(n)
            + " "
            + phase_col
            + ":"
            + pending
            + "->"
            + assigned
            + " set "
            + extra_set
            + " ["
            + _enc(params)
            + "]"
        )
        return DbRows(self.rows.copy(), self.row_cols.copy())

    # ---- the 9 neutral ops: the drivers' one-line delegations ----
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
            self, reactor, table, guard, updates, coalesce, bump_version_col, now_cols
        )

    def delete_where[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], table: String, filter: Filter
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


comptime PgDb = _RecDb[D_PG]
comptime SqliteDb = _RecDb[D_SQLITE]
comptime PgstoreDb = _RecDb[D_PGSTORE]


# ---- small builders ----
def _s(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _s2(a: String, b: String) -> List[String]:
    var l = _s(a)
    l.append(b)
    return l^


def _s3(a: String, b: String, c: String) -> List[String]:
    var l = _s2(a, b)
    l.append(c)
    return l^


def _t(a: String) -> DbValue:
    return DbValue.text(a)


def _i(v: Int) -> DbValue:
    return DbValue.int8(Int64(v))


def _v1(a: DbValue) -> List[DbValue]:
    var l = List[DbValue]()
    l.append(a.copy())
    return l^


def _v2(a: DbValue, b: DbValue) -> List[DbValue]:
    var l = _v1(a)
    l.append(b.copy())
    return l^


def _v3(a: DbValue, b: DbValue, c: DbValue) -> List[DbValue]:
    var l = _v2(a, b)
    l.append(c.copy())
    return l^


def _p2(var a: Pred, var b: Pred) -> List[Pred]:
    var l = List[Pred]()
    l.append(a^)
    l.append(b^)
    return l^


def _no_order() -> List[Order]:
    return List[Order]()


def _no_limit() -> Optional[UInt32]:
    return Optional[UInt32](None)


def _no_bump() -> Optional[String]:
    return Optional[String](None)


def _row(id: String, col: String, var val: DbValue) -> DbRow:
    """A candidate row `(id, <col>)`; `val` may be a NULL."""
    var v = List[DbValue]()
    v.append(_t(id))
    v.append(val^)
    return DbRow.from_values(v, _s2("id", col))


def _ids(rows: DbRows) raises -> String:
    var s = String()
    for i in range(rows.__len__()):
        if i > 0:
            s += ","
        s += rows.row(i).get_text(0)
    return s^


# =============================================================================
# The migration runner over `_RecDb`
# =============================================================================


def _ddl(ledger: String) -> String:
    return (
        "execute CREATE TABLE IF NOT EXISTS "
        + ledger
        + " (\n    id INTEGER PRIMARY KEY,\n    version INTEGER NOT NULL UNIQUE,\n"
        + "    name TEXT NOT NULL,\n    applied_at TIMESTAMPTZ NOT NULL\n) []"
    )


def _prologue(ledger: String) -> List[String]:
    """What `run` issues before it decides anything: the ledger DDL (from `run`,
    `current_version` and `applied_identities`, each ensuring it), the
    high-water read and the ledger read."""
    var l = _s(_ddl(ledger))
    l.append(_ddl(ledger))
    l.append("query SELECT COALESCE(MAX(version), 0) AS v FROM " + ledger + " []")
    l.append(_ddl(ledger))
    l.append("query SELECT * FROM " + ledger + " []")
    return l^


def _pg_ins(seq: Int, name: String) -> String:
    return (
        "execute INSERT INTO _komira_migrations (id, version, name, applied_at)"
        " VALUES ($1, $2, $3, NOW()) [2="
        + String(seq)
        + ",2="
        + String(seq)
        + ",1="
        + name
        + "]"
    )


def _ledger_row(id: Int, var name: DbValue) -> DbRow:
    var v = List[DbValue]()
    v.append(_i(id))
    v.append(_i(id))
    v.append(name^)
    v.append(_i(1000))
    return DbRow.from_values(v, _ledger_cols())


def _ledger_cols() -> List[String]:
    var c = _s2("id", "version")
    c.append("name")
    c.append("applied_at")
    return c^


def _expect_log(db_log: List[String], want: List[String]) raises:
    assert_equal(len(db_log), len(want), "log length")
    for i in range(len(want)):
        assert_equal(db_log[i], want[i])


def _raises_with[DB: SqlDatabase](
    mut r: MigrationRunner[DB], chain: List[Migration]
) raises -> String:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    try:
        _ = r.run[RT](reactor, chain)
    except e:
        return String(e)
    return String("<no error>")


struct _Thing(DbStorable):
    """A DbStorable whose table `things` has the columns `id` and `a`; only
    `TABLE` and `column_names` are read by the drift guard."""

    comptime TABLE: StaticString = "things"
    comptime PK: StaticString = "id"

    def __init__(out self):
        pass

    @staticmethod
    def column_names() -> List[String]:
        return _s2("id", "a")

    @staticmethod
    def column_types() -> List[DbColumn]:
        return List[DbColumn]()

    @staticmethod
    def create_table_ddl() -> String:
        return String("")

    @staticmethod
    def insert_sql[D: SqlDatabase]() -> String:
        return String("")

    def to_row(self) -> List[DbValue]:
        return List[DbValue]()

    @staticmethod
    def from_row(row: DbRow, col_index: List[Int]) raises -> Self:
        raise Error("_Thing.from_row is not used")


def test_run_fresh_chain_in_version_order() raises:
    """A fresh database: the chain, given out of order, is applied in version
    order inside one BEGIN/COMMIT; each step is recorded with the next
    apply-sequence number (INT4 id and version) and its identity, an unnamed
    step's identity being `sql:<up_sql>`."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var r = MigrationRunner[PgDb](PgDb())
    r.db().ledger_cols = _ledger_cols()
    assert_equal(r.ledger(), String("_komira_migrations"))
    var chain = List[Migration]()
    chain.append(Migration(2, "CREATE INDEX i ON t (a)", "idx"))
    chain.append(Migration(1, "CREATE TABLE t (a INT)", "tbl"))
    chain.append(Migration(3, "ALTER TABLE t ADD b INT"))
    assert_equal(r.run[RT](reactor, chain), 3)
    var want = _prologue("_komira_migrations")
    want.append("BEGIN")
    want.append("execute CREATE TABLE t (a INT) []")
    want.append(_pg_ins(1, "tbl"))
    want.append("execute CREATE INDEX i ON t (a) []")
    want.append(_pg_ins(2, "idx"))
    want.append("execute ALTER TABLE t ADD b INT []")
    want.append(_pg_ins(3, "sql:ALTER TABLE t ADD b INT"))
    want.append("COMMIT")
    var db = r^.into_db()
    _expect_log(db.log, want)


def test_run_pending_by_name_from_high_water() raises:
    """The ledger holds `tbl` and `idx` (plus a NULL-name and an empty-name row,
    which carry no identity) and a high-water mark of 5: only `u`, inserted
    BETWEEN them in the chain, is pending; it is recorded as sequence 6 in the
    caller's ledger table with sqlite's tokens. A second run with `u` recorded
    applies nothing and opens no transaction."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var r = MigrationRunner[SqliteDb](SqliteDb(), "app_ledger")
    assert_equal(r.ledger(), String("app_ledger"))
    r.db().max_version = 5
    r.db().ledger_cols = _ledger_cols()
    r.db().ledger_rows.append(_ledger_row(1, _t("tbl")))
    r.db().ledger_rows.append(_ledger_row(2, _t("idx")))
    r.db().ledger_rows.append(_ledger_row(3, DbValue.null(LOGICAL_TEXT)))
    r.db().ledger_rows.append(_ledger_row(4, _t("")))
    var chain = List[Migration]()
    chain.append(Migration(1, "CREATE TABLE t (a INT)", "tbl"))
    chain.append(Migration(2, "CREATE TABLE u (x INT)", "u"))
    chain.append(Migration(3, "CREATE INDEX i ON t (a)", "idx"))
    assert_equal(r.run[RT](reactor, chain), 1)
    var want = _prologue("app_ledger")
    want.append("BEGIN")
    want.append("execute CREATE TABLE u (x INT) []")
    want.append(
        "execute INSERT INTO app_ledger (id, version, name, applied_at) VALUES"
        " (?1, ?2, ?3, " + String(SQLITE_NOW) + ") [2=6,2=6,1=u]"
    )
    want.append("COMMIT")
    _expect_log(r.db().log, want)
    r.db().log.clear()
    r.db().ledger_rows.append(_ledger_row(6, _t("u")))
    assert_equal(r.run[RT](reactor, chain), 0)
    _expect_log(r.db().log, _prologue("app_ledger"))
    # The NULL-name and empty-name rows carry no identity and are skipped.
    var ids = r.applied_identities[RT](reactor)
    assert_equal(len(ids), 3)
    assert_equal(ids[0], String("tbl"))
    assert_equal(ids[1], String("idx"))
    assert_equal(ids[2], String("u"))


def test_run_same_step_twice_applied_once() raises:
    """One name over IDENTICAL up_sql (a step folded in twice) is applied and
    recorded once."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var r = MigrationRunner[PgDb](PgDb())
    var chain = List[Migration]()
    chain.append(Migration(1, "CREATE TABLE t (a INT)", "tbl"))
    chain.append(Migration(2, "CREATE TABLE t (a INT)", "tbl"))
    assert_equal(r.run[RT](reactor, chain), 1)
    var want = _prologue("_komira_migrations")
    want.append("BEGIN")
    want.append("execute CREATE TABLE t (a INT) []")
    want.append(_pg_ins(1, "tbl"))
    want.append("COMMIT")
    _expect_log(r.db().log, want)


def test_run_refuses_chain_authoring_bugs_before_begin() raises:
    """One name over two DIFFERENT statements, and a repeated version, are
    refused before any transaction opens."""
    var r = MigrationRunner[PgDb](PgDb())
    var conflict = List[Migration]()
    conflict.append(Migration(2, "CREATE TABLE t (b INT)", "a"))
    conflict.append(Migration(1, "CREATE TABLE t (a INT)", "a"))
    assert_equal(
        _raises_with(r, conflict),
        String(
            "MigrationRunner: CONFLICTING migration identity 'a' in chain — two"
            " steps (versions 1 and 2) share one name but carry DIFFERENT"
            " up_sql. The ledger keys on the name, so one of them would be"
            " considered applied by the other and would never reach an"
            " already-migrated database. Give them distinct names, or stop"
            " folding both copies into one chain."
        ),
    )
    var dup = List[Migration]()
    dup.append(Migration(2, "A", "x"))
    dup.append(Migration(1, "B", "y"))
    dup.append(Migration(2, "C", "z"))
    assert_equal(_raises_with(r, dup), String("MigrationRunner: duplicate version 2 in chain"))
    for i in range(len(r.db().log)):
        assert_true(r.db().log[i] != String("BEGIN"), "no transaction opened")


def test_run_failure_rolls_back_and_reports() raises:
    """The second step fails: the first step and its ledger row were issued, then
    ROLLBACK (never COMMIT), and the error names the run and the cause."""
    var r = MigrationRunner[PgDb](PgDb())
    r.db().fail_on = String("BAD SQL")
    var chain = List[Migration]()
    chain.append(Migration(1, "CREATE TABLE t (a INT)", "tbl"))
    chain.append(Migration(2, "BAD SQL", "bad"))
    chain.append(Migration(3, "CREATE TABLE never (a INT)", "never"))
    assert_equal(_raises_with(r, chain), String("MigrationRunner.run failed: boom"))
    var want = _prologue("_komira_migrations")
    want.append("BEGIN")
    want.append("execute CREATE TABLE t (a INT) []")
    want.append(_pg_ins(1, "tbl"))
    want.append("execute BAD SQL []")
    want.append("ROLLBACK")
    _expect_log(r.db().log, want)


def test_run_ledger_insert_or_commit_failure_rolls_back() raises:
    """A failing ledger INSERT, and a failing COMMIT, roll back the same way: the
    run raises, and ROLLBACK is the last statement."""
    var one = List[Migration]()
    one.append(Migration(1, "CREATE TABLE t (a INT)", "tbl"))
    var r = MigrationRunner[PgDb](PgDb())
    r.db().fail_on = String(
        "INSERT INTO _komira_migrations (id, version, name, applied_at) VALUES"
        " ($1, $2, $3, NOW())"
    )
    assert_equal(_raises_with(r, one), String("MigrationRunner.run failed: boom"))
    var want = _prologue("_komira_migrations")
    want.append("BEGIN")
    want.append("execute CREATE TABLE t (a INT) []")
    want.append(_pg_ins(1, "tbl"))
    want.append("ROLLBACK")
    _expect_log(r.db().log, want)
    var c = MigrationRunner[PgDb](PgDb())
    c.db().fail_on = String("COMMIT")
    assert_equal(_raises_with(c, one), String("MigrationRunner.run failed: boom"))
    want.insert(len(want) - 1, "COMMIT")
    _expect_log(c.db().log, want)


def test_current_version_and_identities_edges() raises:
    """`current_version` is the high-water read, 0 when the backend answers no
    row; a ledger with no `name` column yields no identities."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var r = MigrationRunner[PgDb](PgDb())
    r.db().max_version = 7
    assert_equal(r.current_version[RT](reactor), 7)
    r.db().max_version = -1
    assert_equal(r.current_version[RT](reactor), 0)
    r.db().ledger_cols = _s2("id", "version")
    var v = List[DbValue]()
    v.append(_i(1))
    v.append(_i(1))
    r.db().ledger_rows.append(DbRow.from_values(v, _s2("id", "version")))
    assert_equal(len(r.applied_identities[RT](reactor)), 0)


def test_live_columns_and_check_drift() raises:
    """The drift guard reads the live columns through `SELECT * ... LIMIT 0`
    and requires exactly the DbStorable's set, in any order."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var r = MigrationRunner[PgDb](PgDb())
    r.db().ledger_cols = _s2("a", "id")
    var live = r.live_columns[RT](reactor, "things")
    assert_equal(len(live), 2)
    assert_equal(live[0], String("a"))
    assert_equal(live[1], String("id"))
    _expect_log(r.db().log, _s("query SELECT * FROM things LIMIT 0 []"))
    r.check_drift[RT, _Thing](reactor)  # same set, other order: no drift
    r.db().ledger_cols = _s("id")
    var msg = String()
    try:
        r.check_drift[RT, _Thing](reactor)
    except e:
        msg = String(e)
    assert_equal(
        msg, String("schema drift: column 'a' in DbStorable but MISSING from live table 'things'")
    )
    r.db().ledger_cols = _s3("id", "a", "zz")
    msg = String()
    try:
        r.check_drift[RT, _Thing](reactor)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("schema drift: live table 'things' has column 'zz' not present in the DbStorable schema"),
    )


def main() raises:
    print("== komira_db MigrationRunner ==")
    test_run_fresh_chain_in_version_order()
    test_run_pending_by_name_from_high_water()
    test_run_same_step_twice_applied_once()
    test_run_refuses_chain_authoring_bugs_before_begin()
    test_run_failure_rolls_back_and_reports()
    test_run_ledger_insert_or_commit_failure_rolls_back()
    test_current_version_and_identities_edges()
    test_live_columns_and_check_drift()
    print("PASS test_migration")
