# =============================================================================
# komira_db/tests/test_sql_ops.mojo
# The SQL implementation of the neutral ops (the renderers: test_sql_render.mojo).
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
# 3 — the key ops: SQL, params, and the result passed through unchanged
# =============================================================================


def test_get_by_key_hit_and_miss() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    db.opt_hits.append(True)
    db.opt_hits.append(False)
    var hit = db.get_by_key[RT](reactor, "jobs", _s2("id", "name"), "id", _t("j1"))
    assert_true(hit.__bool__(), "a found row is returned")
    assert_equal(hit.value().get_text(0), String("hit"))
    var miss = db.get_by_key[RT](reactor, "jobs", _s2("id", "name"), "id", _t("j2"))
    assert_false(miss.__bool__(), "no row is None")
    var want = List[String]()
    want.append("query_opt SELECT id, name FROM jobs WHERE id = $1 [1=j1]")
    want.append("query_opt SELECT id, name FROM jobs WHERE id = $1 [1=j2]")
    _expect_log(db.log, want)


def test_put_and_delete_by_key_return_rows_affected() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var lite = SqliteDb()
    lite.exec_ret = 1
    assert_equal(
        lite.put[RT](reactor, "jobs", _s2("id", "n"), _v2(_t("j1"), _i(4))),
        UInt64(1),
    )
    _expect_log(lite.log, _s("execute INSERT INTO jobs (id, n) VALUES (?1, ?2) [1=j1,3=4]"))
    var pg = PgDb()
    pg.exec_ret = 3
    assert_equal(pg.delete_by_key[RT](reactor, "jobs", "id", _t("j1")), UInt64(3))
    _expect_log(pg.log, _s("execute DELETE FROM jobs WHERE id = $1 [1=j1]"))


# =============================================================================
# 4 — query_rows: the push-down path (params in render order, LIMIT last)
# =============================================================================


def test_query_rows_pg_pushes_everything_limit_last() raises:
    """pg pushes ARRAY_CONTAINS and JSON_KEY_EQ; the params follow the
    placeholders (JSON key before value) and the LIMIT is the final INT8."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    db.rows.append(_row("r1", "tags", _one_arr("red")))
    db.rows.append(_row("r2", "tags", _one_arr("blue")))
    db.row_cols = _s2("id", "tags")
    var preds = _p2(Pred.eq("kind", _t("a")), Pred.array_contains("tags", _t("red")))
    preds.append(Pred.json_key_eq("config", "env", _t("prod")))
    var o = List[Order]()
    o.append(Order.asc("id"))
    var got = db.query_rows[RT](
        reactor, "t", _s2("id", "tags"), Filter.all_of(preds^), o, Optional[UInt32](5)
    )
    assert_equal(_ids(got), String("r1,r2"), "pushed rows are returned as the backend gave them")
    _expect_log(
        db.log,
        _s(
            "query SELECT id, tags FROM t WHERE kind = $1 AND $2 = ANY(tags) AND"
            " config ->> $3 = $4 ORDER BY id LIMIT $5 [1=a,1=red,1=env,1=prod,3=5]"
        ),
    )


def test_query_rows_binds_stay_in_step_with_placeholders() raises:
    """IS DISTINCT FROM NULL, literal IN and IS NULL bind nothing; bound IN binds
    each value; NE and LT bind once. No limit: no LIMIT clause, no limit param."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    var preds = _p2(
        Pred.ne("c", DbValue.null(LOGICAL_TEXT)), Pred.in_list("t", _v2(_t("p"), _t("q")))
    )
    preds.append(Pred.in_literals("s", _v2(_i(0), _i(1))))
    preds.append(Pred.is_null("g"))
    preds.append(Pred.lt("d", _i(1)))
    preds.append(Pred.ne("b", _t("y")))
    _ = db.query_rows[RT](
        reactor, "t", _s("id"), Filter.all_of(preds^), _no_order(), _no_limit()
    )
    _expect_log(
        db.log,
        _s(
            "query SELECT id FROM t WHERE c IS NOT NULL AND t IN (?1, ?2) AND s IN"
            " (0, 1) AND g IS NULL AND d < ?3 AND (b IS NULL OR b <> ?4)"
            " [1=p,1=q,3=1,1=y]"
        ),
    )


def test_query_rows_sqlite_pushes_json_key_eq() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    _ = db.query_rows[RT](
        reactor,
        "t",
        _s("id"),
        Filter.just(Pred.json_key_eq("config", "env", _t("prod"))),
        _no_order(),
        Optional[UInt32](10),
    )
    _expect_log(
        db.log,
        _s(
            "query SELECT id FROM t WHERE json_extract(config, '$.' || ?1) = ?2"
            " LIMIT ?3 [1=env,1=prod,3=10]"
        ),
    )


# =============================================================================
# 5 — query_rows: the client-side split (sqlite / pgstore)
# =============================================================================


def _array_candidates(mut db: SqliteDb):
    db.rows.append(_row("r1", "tags", _arr("red", "blue")))
    db.rows.append(_row("r2", "tags", DbValue.null(10)))  # NULL array
    db.rows.append(_row("r3", "tags", _one_arr("blue")))
    db.rows.append(_row("r4", "other", _one_arr("red")))  # no `tags` column
    db.rows.append(_row("r5", "tags", _one_arr("red")))
    db.rows.append(_row("r6", "tags", _arr("green", "red")))
    db.row_cols = _s2("id", "tags")


def test_query_rows_sqlite_array_contains_client_side_with_limit() raises:
    """sqlite strips ARRAY_CONTAINS from the pushed WHERE, sends no LIMIT, keeps
    only rows whose array holds the value (a NULL array or an absent column
    never does), and caps AFTER filtering: r2..r4 are dropped and do not count
    against the limit of 2."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    _array_candidates(db)
    var o = List[Order]()
    o.append(Order.asc("id"))
    var f = Filter.all_of(
        _p2(Pred.eq("kind", _t("a")), Pred.array_contains("tags", _t("red")))
    )
    var got = db.query_rows[RT](reactor, "t", _s2("id", "tags"), f, o, Optional[UInt32](2))
    assert_equal(_ids(got), String("r1,r5"))
    assert_equal(got.column_count(), 2)
    _expect_log(db.log, _s("query SELECT id, tags FROM t WHERE kind = ?1 ORDER BY id [1=a]"))
    var all = db.query_rows[RT](reactor, "t", _s2("id", "tags"), f, o, _no_limit())
    assert_equal(_ids(all), String("r1,r5,r6"))


def test_query_rows_pgstore_splits_json_key_and_array() raises:
    """pgstore cannot push either: both are stripped (the remaining EQ keeps
    `$1`) and a row survives only if its JSON column carries the key with the
    value AND its array holds the element (a NULL or absent JSON column, or a
    missing key, never matches)."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    db.rows.append(_row3("a", DbValue.jsonb("{\"env\":\"prod\"}"), _arr("t", "u")))
    db.rows.append(_row3("b", DbValue.jsonb("{\"env\":\"dev\"}"), _one_arr("t")))
    db.rows.append(_row3("c", DbValue.null(9), _one_arr("t")))
    db.rows.append(_row3("d", DbValue.jsonb("{\"other\":\"prod\"}"), _one_arr("t")))
    db.rows.append(_row3("e", DbValue.jsonb("{\"env\":\"prod\"}"), _one_arr("u")))
    db.rows.append(_row3("f", DbValue.jsonb("{\"z\":\"1\",\"env\":\"prod\"}"), _one_arr("t")))
    var g = List[DbValue]()  # no `config` column at all
    g.append(_t("g"))
    g.append(DbValue.jsonb("{\"env\":\"prod\"}"))
    g.append(_one_arr("t"))
    db.rows.append(DbRow.from_values(g, _s3("id", "cfg", "tags")))
    db.row_cols = _s3("id", "config", "tags")
    var preds = _p2(Pred.json_key_eq("config", "env", _t("prod")), Pred.eq("x", _i(1)))
    preds.append(Pred.array_contains("tags", _t("t")))
    var got = db.query_rows[RT](
        reactor, "t", _s3("id", "config", "tags"), Filter.all_of(preds^), _no_order(), _no_limit()
    )
    assert_equal(_ids(got), String("a,f"))
    _expect_log(db.log, _s("query SELECT id, config, tags FROM t WHERE x = $1 [3=1]"))
    # JSON key alone (no array pred): the pushed SELECT has no WHERE left, and
    # the limit of 1 stops at the first match.
    db.log.clear()
    var one = db.query_rows[RT](
        reactor,
        "t",
        _s3("id", "config", "tags"),
        Filter.just(Pred.json_key_eq("config", "env", _t("prod"))),
        _no_order(),
        Optional[UInt32](1),
    )
    assert_equal(_ids(one), String("a"))
    _expect_log(db.log, _s("query SELECT id, config, tags FROM t []"))
    # Array alone (no JSON key pred): only the membership filter applies, so
    # the rows whose JSON config differs (e) still come back.
    db.log.clear()
    var arr = db.query_rows[RT](
        reactor,
        "t",
        _s3("id", "config", "tags"),
        Filter.just(Pred.array_contains("tags", _t("u"))),
        _no_order(),
        _no_limit(),
    )
    assert_equal(_ids(arr), String("a,e"))
    _expect_log(db.log, _s("query SELECT id, config, tags FROM t []"))


# =============================================================================
# 6 — locked read, CAS update, range delete
# =============================================================================


def test_query_rows_locked_per_dialect_and_refusal() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var o = List[Order]()
    o.append(Order.asc("due"))
    var f = Filter.just(Pred.lt("due", _i(9)))
    var pg = PgDb()
    _ = pg.query_rows_locked[RT](reactor, "q", _s("id"), f, o)
    _expect_log(
        pg.log, _s("query SELECT id FROM q WHERE due < $1 ORDER BY due FOR UPDATE SKIP LOCKED [3=9]")
    )
    var lite = SqliteDb()
    _ = lite.query_rows_locked[RT](reactor, "q", _s("id"), f, o)
    _expect_log(lite.log, _s("query SELECT id FROM q WHERE due < ?1 ORDER BY due [3=9]"))
    lite.log.clear()
    var raised = False
    try:
        _ = lite.query_rows_locked[RT](
            reactor, "q", _s("id"), Filter.just(Pred.array_contains("tags", _t("a"))), o
        )
    except:
        raised = True
    assert_true(raised, "an array pred off pg fails closed, never silently dropped")
    assert_equal(len(lite.log), 0, "nothing reached the backend")


def test_conditional_update_params_set_then_guard() raises:
    """SET binds in update order (RAW binds nothing, a NULL COALESCE value binds
    a typed NULL), then the guard's binds; rows_affected is passed back."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    db.exec_ret = 1
    var u = List[DbColVal]()
    u.append(DbColVal.bind("phase", _t("RUNNING")))
    u.append(DbColVal.raw_expr("version", "version + 1"))
    u.append(DbColVal.coalesce("progress", DbValue.null(3)))
    var guard = Filter.all_of(
        _p2(Pred.eq("id", _t("j1")), Pred.in_list("phase", _v2(_t("P"), _t("Q"))))
    )
    var n = db.conditional_update[RT](
        reactor, "jobs", guard, u, False, _no_bump(), _s("updated_at")
    )
    assert_equal(n, UInt64(1))
    _expect_log(
        db.log,
        _s(
            "execute UPDATE jobs SET phase = $1, version = version + 1, progress ="
            " COALESCE($2, progress), updated_at = NOW() WHERE id = $3 AND phase"
            " IN ($4, $5) [1=RUNNING,3~,1=j1,1=P,1=Q]"
        ),
    )


def test_delete_where() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    db.exec_ret = 7
    var n = db.delete_where[RT](
        reactor, "idempotency_keys", Filter.just(Pred.lt("created_at", _i(100)))
    )
    assert_equal(n, UInt64(7))
    _expect_log(
        db.log, _s("execute DELETE FROM idempotency_keys WHERE created_at < ?1 [3=100]")
    )


# =============================================================================
# 7 — create_if_absent (single and composite): who won the key
# =============================================================================


def test_create_if_absent_on_conflict_arm() raises:
    """pg / sqlite: one ON CONFLICT ... RETURNING statement; a returned row means
    we won, none means a concurrent writer did."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    db.opt_hits.append(True)
    db.opt_hits.append(False)
    var vals = _v2(_t("k1"), _i(9))
    assert_true(db.create_if_absent[RT](reactor, "k", "key", _t("k1"), _s2("key", "v"), vals))
    assert_false(db.create_if_absent[RT](reactor, "k", "key", _t("k1"), _s2("key", "v"), vals))
    var stmt = String(
        "query_opt INSERT INTO k (key, v) VALUES ($1, $2) ON CONFLICT (key) DO"
        " NOTHING RETURNING key [1=k1,3=9]"
    )
    _expect_log(db.log, _s2(stmt, stmt))
    var lite = SqliteDb()
    lite.opt_hits.append(True)
    assert_true(lite.create_if_absent[RT](reactor, "k", "key", _t("k1"), _s2("key", "v"), vals))
    _expect_log(
        lite.log,
        _s(
            "query_opt INSERT INTO k (key, v) VALUES (?1, ?2) ON CONFLICT (key) DO"
            " NOTHING RETURNING key [1=k1,3=9]"
        ),
    )


def test_create_if_absent_pgstore_check_then_insert() raises:
    """pgstore: a visible key loses with no INSERT; an absent key is inserted with
    a plain INSERT and wins."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    db.opt_hits.append(True)
    var vals = _v2(_t("k1"), _i(9))
    assert_false(db.create_if_absent[RT](reactor, "k", "key", _t("k1"), _s2("key", "v"), vals))
    var sel = String("query_opt SELECT key FROM k WHERE key = $1 [1=k1]")
    _expect_log(db.log, _s(sel))
    db.log.clear()
    db.opt_hits.append(False)
    assert_true(db.create_if_absent[RT](reactor, "k", "key", _t("k1"), _s2("key", "v"), vals))
    _expect_log(db.log, _s2(sel, "execute INSERT INTO k (key, v) VALUES ($1, $2) [1=k1,3=9]"))


def test_create_if_absent_composite_arms() raises:
    """The composite key is matched against `cols` by name: the conflict order
    (mailbox_id, content_hash) differs from the column order, and the pgstore
    snapshot read binds the values in conflict order."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var cols = _s3("content_hash", "body", "mailbox_id")
    var vals = _v3(_t("h"), _t("b"), _t("mb"))
    var conflict = _s2("mailbox_id", "content_hash")
    var pg = PgDb()
    pg.opt_hits.append(False)
    pg.opt_hits.append(True)
    assert_false(pg.create_if_absent_composite[RT](reactor, "m", conflict, cols, vals))
    assert_true(pg.create_if_absent_composite[RT](reactor, "m", conflict, cols, vals))
    var stmt = String(
        "query_opt INSERT INTO m (content_hash, body, mailbox_id) VALUES ($1, $2,"
        " $3) ON CONFLICT (mailbox_id, content_hash) DO NOTHING RETURNING"
        " mailbox_id [1=h,1=b,1=mb]"
    )
    _expect_log(pg.log, _s2(stmt, stmt))
    var ps = PgstoreDb()
    ps.opt_hits.append(True)
    ps.opt_hits.append(False)
    assert_false(ps.create_if_absent_composite[RT](reactor, "m", conflict, cols, vals))
    assert_true(ps.create_if_absent_composite[RT](reactor, "m", conflict, cols, vals))
    var sel = String(
        "query_opt SELECT mailbox_id FROM m WHERE mailbox_id = $1 AND"
        " content_hash = $2 [1=mb,1=h]"
    )
    var want = _s2(sel, sel)
    want.append("execute INSERT INTO m (content_hash, body, mailbox_id) VALUES ($1, $2, $3) [1=h,1=b,1=mb]")
    _expect_log(ps.log, want)


def test_create_if_absent_composite_refusals() raises:
    """An empty conflict list, and a conflict column missing from `cols`, are
    refused before anything reaches the backend."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var cols = _s2("a", "b")
    var vals = _v2(_t("1"), _t("2"))
    var pg = PgDb()
    var msg = String()
    try:
        _ = pg.create_if_absent_composite[RT](reactor, "m", List[String](), cols, vals)
    except e:
        msg = String(e)
    assert_equal(msg, String("create_if_absent_composite: empty conflict_cols"))
    assert_equal(len(pg.log), 0)
    var ps = PgstoreDb()
    msg = String()
    try:
        _ = ps.create_if_absent_composite[RT](reactor, "m", _s2("a", "zz"), cols, vals)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("create_if_absent_composite: conflict column \"zz\" is not in the inserted cols"),
    )
    assert_equal(len(ps.log), 0)


# =============================================================================
# 8 — claim_rows: the extra_set handed to claim_pending, per dialect
# =============================================================================


def test_claim_rows_pg_full_extra_set() raises:
    """pg: the pod_name mint (binds nothing), then the extra terms numbered from
    $1 (raw binds nothing), the version bump and the now-stamp; the params are
    the bound extra values only; the claimed rows come back."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    db.rows.append(_row("j1", "phase", _t("ASSIGNED")))
    db.row_cols = _s2("id", "phase")
    var extra = List[DbColVal]()
    extra.append(DbColVal.bind("node", _t("n1")))
    extra.append(DbColVal.raw_expr("attempts", "attempts + 1"))
    extra.append(DbColVal.bind("zone", _t("z")))
    var got = db.claim_rows[RT](
        reactor,
        "jobs",
        3,
        Filter.none(),
        _no_order(),
        "phase",
        "PENDING",
        "ASSIGNED",
        extra,
        PodNameMinter("job"),
        Optional[String]("version"),
        _s("updated_at"),
    )
    assert_equal(_ids(got), String("j1"))
    _expect_log(
        db.log,
        _s(
            "claim jobs n=3 phase:PENDING->ASSIGNED set pod_name = CONCAT('job',"
            " '-', RIGHT(id::text, 12)), node = $1, attempts = attempts + 1, zone"
            " = $2, version = version + 1, updated_at = NOW() [1=n1,1=z]"
        ),
    )


def _claim[DB: SqlDatabase](
    mut db: DB, n: Int, phase_col: String, extra: List[DbColVal], prefix: String,
    bump: Optional[String], now_cols: List[String],
) raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    _ = db.claim_rows[RT](
        reactor, "q", n, Filter.none(), _no_order(), phase_col, "P", "A", extra,
        PodNameMinter(prefix), bump, now_cols,
    )


def test_claim_rows_mint_per_dialect_and_lead_terms() raises:
    """sqlite and pgstore mint spellings (sqlite's tail is hex chars 21..32,
    lowercased); with no mint, the first extra term, the bump or a now-stamp
    leads with no comma."""
    var none = List[DbColVal]()
    var one = List[DbColVal]()
    one.append(DbColVal.bind("a", _i(1)))
    var lite = SqliteDb()
    _claim(lite, 1, "state", none, "job", _no_bump(), List[String]())
    _expect_log(
        lite.log,
        _s("claim q n=1 state:P->A set pod_name = ('job' || '-' || lower(substr(hex(id), 21, 12))) []"),
    )
    var ps = PgstoreDb()
    _claim(ps, 2, "phase", one, "w", _no_bump(), List[String]())
    _expect_log(ps.log, _s("claim q n=2 phase:P->A set pod_name = pgstore_pod_name('w'), a = $1 [3=1]"))
    var pg = PgDb()
    _claim(pg, 1, "phase", one, "", Optional[String]("version"), List[String]())
    _claim(pg, 1, "phase", none, "", Optional[String]("version"), _s("u_at"))
    _claim(pg, 1, "phase", none, "", _no_bump(), _s("x_at"))
    var want = _s("claim q n=1 phase:P->A set a = $1, version = version + 1 [3=1]")
    want.append("claim q n=1 phase:P->A set version = version + 1, u_at = NOW() []")
    want.append("claim q n=1 phase:P->A set x_at = NOW() []")
    _expect_log(pg.log, want)


def main() raises:
    print("== komira_db sql_neutral_ops: the ops ==")
    test_get_by_key_hit_and_miss()
    test_put_and_delete_by_key_return_rows_affected()
    test_query_rows_pg_pushes_everything_limit_last()
    test_query_rows_binds_stay_in_step_with_placeholders()
    test_query_rows_sqlite_pushes_json_key_eq()
    test_query_rows_sqlite_array_contains_client_side_with_limit()
    test_query_rows_pgstore_splits_json_key_and_array()
    test_query_rows_locked_per_dialect_and_refusal()
    test_conditional_update_params_set_then_guard()
    test_delete_where()
    test_create_if_absent_on_conflict_arm()
    test_create_if_absent_pgstore_check_then_insert()
    test_create_if_absent_composite_arms()
    test_create_if_absent_composite_refusals()
    test_claim_rows_pg_full_extra_set()
    test_claim_rows_mint_per_dialect_and_lead_terms()
    print("PASS test_sql_ops")
