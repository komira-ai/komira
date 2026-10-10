# =============================================================================
# komira_db/tests/test_sql_ops_split.mojo
# query_rows' client-side split with several predicates of one kind (the other
# ops: test_sql_ops.mojo).
# =============================================================================
# `sql_neutral_ops.mojo` is the one place the SQL drivers render the neutral
# ops. Its contract is the exact SQL text and the bind order: a placeholder the
# renderer numbers must be the param the op appends at that position. Every
# expected string below is written out by hand from that contract (the module
# header and the per-function docstrings), never computed by the code under
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
# logical type 1 is TEXT, 3 is INT8, 10 is TEXT[] (db_value.mojo).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.db_value import DbValue, LOGICAL_TEXT
from komira_db.db_row import DbRow, DbRows
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


def _row3(id: String, var config: DbValue, var tags: DbValue) -> DbRow:
    var v = List[DbValue]()
    v.append(_t(id))
    v.append(config^)
    v.append(tags^)
    return DbRow.from_values(v, _s3("id", "config", "tags"))


def _arr(a: String, b: String) -> DbValue:
    return DbValue.text_array(_s2(a, b))


def _one_arr(a: String) -> DbValue:
    return DbValue.text_array(_s(a))


def _expect_log(db_log: List[String], want: List[String]) raises:
    assert_equal(len(db_log), len(want), "log length")
    for i in range(len(want)):
        assert_equal(db_log[i], want[i])


# =============================================================================
# The client-side split with SEVERAL predicates of one kind: every one of them
# must hold (an AND filter). Each case has a row matching only the first
# predicate and a row matching only the second (both dropped), rows matching
# both (kept) and a row matching neither.
# =============================================================================


def _add_two_tag_rows(mut rows: List[DbRow]):
    rows.append(_row("both1", "tags", _arr("red", "blue")))
    rows.append(_row("first", "tags", _one_arr("red")))
    rows.append(_row("second", "tags", _one_arr("blue")))
    rows.append(_row("both2", "tags", DbValue.text_array(_s3("blue", "green", "red"))))
    rows.append(_row("neither", "tags", _one_arr("green")))


def test_sqlite_two_array_contains_all_must_hold() raises:
    """sqlite: both array_contains preds are stripped (the EQ stays pushed) and a
    row is kept only if its array holds `red` AND `blue`."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    _add_two_tag_rows(db.rows)
    db.row_cols = _s2("id", "tags")
    var preds = _p2(Pred.eq("kind", _t("a")), Pred.array_contains("tags", _t("red")))
    preds.append(Pred.array_contains("tags", _t("blue")))
    var got = db.query_rows[RT](
        reactor, "t", _s2("id", "tags"), Filter.all_of(preds^), _no_order(), _no_limit()
    )
    assert_equal(_ids(got), String("both1,both2"))
    _expect_log(db.log, _s("query SELECT id, tags FROM t WHERE kind = ?1 [1=a]"))


def test_pgstore_two_array_contains_all_must_hold() raises:
    """pgstore: with only array preds nothing is left to push (no WHERE), and a
    row is kept only if its array holds both values."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    _add_two_tag_rows(db.rows)
    db.row_cols = _s2("id", "tags")
    var f = Filter.all_of(
        _p2(Pred.array_contains("tags", _t("red")), Pred.array_contains("tags", _t("blue")))
    )
    var got = db.query_rows[RT](reactor, "t", _s2("id", "tags"), f, _no_order(), _no_limit())
    assert_equal(_ids(got), String("both1,both2"))
    _expect_log(db.log, _s("query SELECT id, tags FROM t []"))


def test_pgstore_two_json_key_eq_all_must_hold() raises:
    """pgstore: a row is kept only if its JSON config carries `env` = `prod` AND
    `tier` = `gold` (key order in the object is irrelevant; a missing second key
    drops the row)."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    db.rows.append(_row("both1", "config", DbValue.jsonb("{\"env\":\"prod\",\"tier\":\"gold\"}")))
    db.rows.append(_row("first", "config", DbValue.jsonb("{\"env\":\"prod\",\"tier\":\"free\"}")))
    db.rows.append(_row("second", "config", DbValue.jsonb("{\"env\":\"dev\",\"tier\":\"gold\"}")))
    db.rows.append(_row("nokey", "config", DbValue.jsonb("{\"env\":\"prod\"}")))
    db.rows.append(_row("both2", "config", DbValue.jsonb("{\"tier\":\"gold\",\"env\":\"prod\"}")))
    db.rows.append(_row("neither", "config", DbValue.jsonb("{\"env\":\"dev\"}")))
    db.row_cols = _s2("id", "config")
    var f = Filter.all_of(
        _p2(
            Pred.json_key_eq("config", "env", _t("prod")),
            Pred.json_key_eq("config", "tier", _t("gold")),
        )
    )
    var got = db.query_rows[RT](reactor, "t", _s2("id", "config"), f, _no_order(), _no_limit())
    assert_equal(_ids(got), String("both1,both2"))
    _expect_log(db.log, _s("query SELECT id, config FROM t []"))


def main() raises:
    print("== komira_db sql_neutral_ops: multi-predicate client-side split ==")
    test_sqlite_two_array_contains_all_must_hold()
    test_pgstore_two_array_contains_all_must_hold()
    test_pgstore_two_json_key_eq_all_must_hold()
    print("PASS test_sql_ops_split")
