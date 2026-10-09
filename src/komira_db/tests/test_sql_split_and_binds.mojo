# =============================================================================
# komira_db/tests/test_sql_split_and_binds.mojo
# The SQL renderer's refusals and edge shapes: an OR filter over query_rows'
# client-side split, a SET term of an unknown kind, an empty IN list, and a
# JSON-key predicate outside query_rows on pgstore.
# =============================================================================
# `_RecDb[D]` is a recording `SqlDatabase`: it logs every raw verb it is handed
# (`<verb> <sql> [<params>]`) and answers `query` from a script, so a test reads
# back the exact SQL and params an op produced and the rows a client-side
# filter kept. `D` picks the dialect tokens: pg (`$N`), sqlite (`?N`) and
# pgstore (`$N`, the narrow executor). Its ops delegate to the `sql_op_*`
# functions exactly as the pg and sqlite drivers do. A param is logged as
# `<logical type>=<text>`: logical type 1 is TEXT, 3 is INT8. Every expected
# string is written out by hand from the module's documented contract.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.db_value import DbValue
from komira_db.db_row import DbRow, DbRows
from komira_db.neutral_ops import (
    Pred,
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
    COLVAL_BIND,
    COLVAL_COALESCE,
    COLVAL_RAW_EXPR,
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
    render_where,
)


comptime D_PG = 0
comptime D_SQLITE = 1
comptime D_PGSTORE = 2

comptime RT = BlockingRuntime[NoopSink]


def _new_rt() raises -> RT:
    return RT.new(NoopSink(_placeholder=UInt8(0)))


def _enc(params: List[DbValue]) -> String:
    var s = String()
    for i in range(len(params)):
        if i > 0:
            s += ","
        s += String(params[i].logical_type) + "=" + params[i].as_text()
    return s^


struct _RecDb[D: Int](SqlDatabase):
    var log: List[String]
    var rows: List[DbRow]  # what `query` answers
    var row_cols: List[String]

    def __init__(out self):
        self.log = List[String]()
        self.rows = List[DbRow]()
        self.row_cols = List[String]()

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.log.append("BEGIN")

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.log.append("COMMIT")

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.log.append("ROLLBACK")

    def execute[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> UInt64:
        self.log.append("execute " + sql + " [" + _enc(params) + "]")
        return 1

    def query[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> DbRows:
        self.log.append("query " + sql + " [" + _enc(params) + "]")
        return DbRows(self.rows.copy(), self.row_cols.copy())

    def query_opt[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> Optional[DbRow]:
        raise Error("_RecDb: query_opt is not used here")

    def query_one[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> DbRow:
        raise Error("_RecDb: query_one is not used here")

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
        self.log.append("claim set " + extra_set + " [" + _enc(params) + "]")
        return DbRows(self.rows.copy(), self.row_cols.copy())

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


def _t(a: String) -> DbValue:
    return DbValue.text(a)


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


def _ids(rows: DbRows) raises -> String:
    var s = String()
    for i in range(rows.__len__()):
        if i > 0:
            s += ","
        s += rows.row(i).get_text(0)
    return s^


def _row(id: String, kind: String, var tags: DbValue, var config: DbValue) -> DbRow:
    var v = List[DbValue]()
    v.append(_t(id))
    v.append(_t(kind))
    v.append(tags^)
    v.append(config^)
    var c = _s2("id", "kind")
    c.append("tags")
    c.append("config")
    return DbRow.from_values(v, c)


def _cols() -> List[String]:
    var c = _s2("id", "kind")
    c.append("tags")
    c.append("config")
    return c^


def _seed(mut rows: List[DbRow]):
    """Four rows over (kind, tags, config): `a_blue` matches only kind = 'a',
    `b_red` only tags holding 'red', `b_prod` only config env = 'prod', `b_none`
    nothing."""
    rows.append(_row("a_blue", "a", DbValue.text_array(_s("blue")), DbValue.jsonb("{\"env\":\"dev\"}")))
    rows.append(_row("b_red", "b", DbValue.text_array(_s2("green", "red")), DbValue.jsonb("{\"env\":\"dev\"}")))
    rows.append(_row("b_prod", "b", DbValue.text_array(_s("green")), DbValue.jsonb("{\"env\":\"prod\"}")))
    rows.append(_row("b_none", "b", DbValue.text_array(_s("green")), DbValue.jsonb("{\"env\":\"dev\"}")))


def _expect_log(db_log: List[String], want: List[String]) raises:
    assert_equal(len(db_log), len(want), "log length")
    for i in range(len(want)):
        assert_equal(db_log[i], want[i])


# =============================================================================
# 1. An OR filter over the client-side split.
# =============================================================================


def test_sqlite_or_mixing_pushed_and_array_contains_is_refused() raises:
    """sqlite pushes `kind = ?1` but evaluates array_contains in Mojo. Splitting
    an OR that way returned the AND (`b_red` dropped, `a_blue` dropped). The op
    must refuse before any query rather than answer wrong."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    _seed(db.rows)
    db.row_cols = _cols()
    var f = Filter.any_of(_p2(Pred.eq("kind", _t("a")), Pred.array_contains("tags", _t("red"))))
    var msg = String("")
    try:
        _ = db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), _no_limit())
    except e:
        msg = String(e)
    assert_true("OR filter" in msg, msg)
    assert_true("sqlite" in msg, msg)
    assert_equal(len(db.log), 0, "no query runs for a refused filter")


def test_pgstore_or_mixing_pushed_and_json_key_eq_is_refused() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    _seed(db.rows)
    db.row_cols = _cols()
    var f = Filter.any_of(
        _p2(Pred.eq("kind", _t("a")), Pred.json_key_eq("config", "env", _t("prod")))
    )
    var msg = String("")
    try:
        _ = db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), _no_limit())
    except e:
        msg = String(e)
    assert_true("OR filter" in msg and "pgstore" in msg, msg)
    assert_equal(len(db.log), 0)


def test_sqlite_or_of_only_array_contains_keeps_either() raises:
    """Every predicate is client-side: nothing is pushed and a row is kept if
    ANY holds (`a_blue` by blue, `b_red` by red). The AND reading kept none."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    _seed(db.rows)
    db.row_cols = _cols()
    var f = Filter.any_of(
        _p2(Pred.array_contains("tags", _t("red")), Pred.array_contains("tags", _t("blue")))
    )
    var got = db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), _no_limit())
    assert_equal(_ids(got), String("a_blue,b_red"))
    _expect_log(db.log, _s("query SELECT id, kind, tags, config FROM t []"))


def test_pgstore_or_of_array_contains_and_json_key_eq_keeps_either() raises:
    """pgstore evaluates both kinds client-side; the OR keeps `b_red` (tag) and
    `b_prod` (config), and the limit applies after the filter."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    _seed(db.rows)
    db.row_cols = _cols()
    var f = Filter.any_of(
        _p2(Pred.array_contains("tags", _t("red")), Pred.json_key_eq("config", "env", _t("prod")))
    )
    var got = db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), _no_limit())
    assert_equal(_ids(got), String("b_red,b_prod"))
    var one = db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), Optional[UInt32](UInt32(1)))
    assert_equal(_ids(one), String("b_red"))


def test_sqlite_and_split_still_requires_every_predicate() raises:
    """The AND split is unchanged: `kind = ?1` pushed, red required in Mojo. The
    recording db answers every seeded row, so the Mojo half alone decides."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    _seed(db.rows)
    db.row_cols = _cols()
    var f = Filter.all_of(_p2(Pred.eq("kind", _t("b")), Pred.array_contains("tags", _t("red"))))
    var got = db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), _no_limit())
    assert_equal(_ids(got), String("b_red"))
    _expect_log(db.log, _s("query SELECT id, kind, tags, config FROM t WHERE kind = ?1 [1=b]"))


def test_pg_or_with_array_contains_pushes_the_whole_or() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    var f = Filter.any_of(_p2(Pred.eq("kind", _t("a")), Pred.array_contains("tags", _t("red"))))
    _ = db.query_rows[RT](reactor, "t", _s("id"), f, _no_order(), _no_limit())
    _expect_log(db.log, _s("query SELECT id FROM t WHERE kind = $1 OR $2 = ANY(tags) [1=a,1=red]"))


def test_a_null_or_absent_client_column_never_matches() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    db.rows.append(_row("nulls", "a", DbValue.null(10), DbValue.null(1)))
    db.row_cols = _cols()
    var f = Filter.any_of(
        _p2(Pred.array_contains("tags", _t("red")), Pred.json_key_eq("config", "env", _t("prod")))
    )
    assert_equal(_ids(db.query_rows[RT](reactor, "t", _cols(), f, _no_order(), _no_limit())), String(""))
    var g = Filter.just(Pred.array_contains("missing", _t("red")))
    assert_equal(_ids(db.query_rows[RT](reactor, "t", _cols(), g, _no_order(), _no_limit())), String(""))


# =============================================================================
# 2. A SET term of an unknown kind.
# =============================================================================


def test_three_argument_colval_refuses_an_unknown_kind() raises:
    var ok = DbColVal("c", _t("v"), COLVAL_COALESCE)
    assert_true(ok.is_coalesce())
    var raw = DbColVal("c", _t("c + 1"), COLVAL_RAW_EXPR)
    assert_true(raw.is_raw_expr())
    # The factories, which no longer go through the three-argument form.
    assert_true(DbColVal.bind("c", _t("v")).is_bind())
    assert_true(DbColVal.coalesce("c", _t("v")).is_coalesce())
    var bump = DbColVal.raw_expr("version", "version + 1")
    assert_true(bump.is_raw_expr() and not bump.binds_a_param())
    assert_equal(bump.val.as_text(), String("version + 1"))
    var refused = False
    try:
        _ = DbColVal("c", _t("v"), UInt8(3))
    except e:
        refused = True
        assert_true("kind 3" in String(e), String(e))
    assert_true(refused, "kind 3 must be refused")


def _updates_with_kind(kind: UInt8) raises -> List[DbColVal]:
    """`a` bound, `b` with `kind` forced through the public field, `c` bound."""
    var u = List[DbColVal]()
    u.append(DbColVal.bind("a", _t("A")))
    var b = DbColVal("b", _t("B"), COLVAL_BIND)
    b.kind = kind
    u.append(b^)
    u.append(DbColVal.bind("c", _t("C")))
    return u^


def test_conditional_update_refuses_an_unknown_kind() raises:
    """Before: `b` rendered `$2` but bound nothing, so `c = $3` and the guard
    `id = $4` read past the three params. Now the op refuses before executing."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    var msg = String("")
    try:
        _ = db.conditional_update[RT](
            reactor, "t", Filter.just(Pred.eq("id", _t("x"))), _updates_with_kind(9), False, _no_bump(), List[String]()
        )
    except e:
        msg = String(e)
    assert_true("\"b\": kind 9" in msg, msg)
    assert_equal(len(db.log), 0)
    # The valid kinds still number in step with the params.
    _ = db.conditional_update[RT](
        reactor, "t", Filter.just(Pred.eq("id", _t("x"))), _updates_with_kind(COLVAL_COALESCE), False, _no_bump(), List[String]()
    )
    _expect_log(db.log, _s("execute UPDATE t SET a = $1, b = COALESCE($2, b), c = $3 WHERE id = $4 [1=A,1=B,1=C,1=x]"))


def test_claim_refuses_an_unknown_kind() raises:
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    var msg = String("")
    try:
        _ = db.claim_rows[RT](
            reactor, "t", 1, Filter.none(), _no_order(), "phase", "P", "A", _updates_with_kind(7), PodNameMinter(), _no_bump(), List[String]()
        )
    except e:
        msg = String(e)
    assert_true("\"b\": kind 7" in msg, msg)
    assert_equal(len(db.log), 0)


# =============================================================================
# 3. An empty IN list.
# =============================================================================


def test_empty_in_renders_false_and_keeps_bind_numbering() raises:
    """`col IN ()` is not Postgres. An empty list renders `1 = 0`, binds nothing,
    and the next predicate takes the next placeholder."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    var preds = _p2(Pred.in_list("id", List[DbValue]()), Pred.eq("kind", _t("a")))
    preds.append(Pred.in_literals("status", List[DbValue]()))
    _ = db.delete_where[RT](reactor, "t", Filter.any_of(preds^))
    _expect_log(db.log, _s("execute DELETE FROM t WHERE 1 = 0 OR kind = $1 OR 1 = 0 [1=a]"))


# =============================================================================
# 4. A JSON-key predicate outside query_rows on pgstore.
# =============================================================================


def _expect_pgstore_json_refusal(msg: String) raises:
    assert_true("PRED_JSON_KEY_EQ" in msg and "pgstore" in msg, msg)


def test_pgstore_json_key_eq_is_refused_outside_query_rows() raises:
    """pgstore's executor has neither `->>` nor `json_extract`; delete_where,
    conditional_update and query_rows_locked rendered sqlite's json_extract.
    Each now refuses before any statement runs."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgstoreDb()
    var f = Filter.just(Pred.json_key_eq("config", "env", _t("prod")))
    var m1 = String("")
    try:
        _ = db.delete_where[RT](reactor, "t", f)
    except e:
        m1 = String(e)
    _expect_pgstore_json_refusal(m1)
    var m2 = String("")
    try:
        var u = List[DbColVal]()
        u.append(DbColVal.bind("a", _t("A")))
        _ = db.conditional_update[RT](reactor, "t", f, u, False, _no_bump(), List[String]())
    except e:
        m2 = String(e)
    _expect_pgstore_json_refusal(m2)
    var m3 = String("")
    try:
        _ = db.query_rows_locked[RT](reactor, "t", _s("id"), f, _no_order())
    except e:
        m3 = String(e)
    _expect_pgstore_json_refusal(m3)
    assert_equal(len(db.log), 0)


def test_pg_and_sqlite_json_key_eq_render_unchanged() raises:
    var nb = 0
    var f = Filter.just(Pred.json_key_eq("config", "env", _t("prod")))
    assert_equal(render_where[PgDb](f, "pg", nb), String("config ->> $1 = $2"))
    assert_equal(nb, 2)
    var ns = 0
    assert_equal(
        render_where[SqliteDb](f, "sqlite", ns),
        String("json_extract(config, '$.' || ?1) = ?2"),
    )
    assert_equal(ns, 2)


def test_sqlite_query_rows_pushes_json_key_eq_whole() raises:
    """sqlite pushes json_key_eq (`json_extract`), so query_rows sends it in the
    WHERE: under AND beside `kind = ?1`, and under OR the whole filter is pushed
    rather than refused. A dialect check that sent sqlite's json_key_eq to the
    client-side split would log no json_extract for the AND and refuse the OR.
    The recording db answers no rows, so the log alone decides."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = SqliteDb()
    var fa = Filter.all_of(
        _p2(Pred.eq("kind", _t("b")), Pred.json_key_eq("config", "env", _t("prod")))
    )
    _ = db.query_rows[RT](reactor, "t", _s("id"), fa, _no_order(), _no_limit())
    _expect_log(
        db.log,
        _s("query SELECT id FROM t WHERE kind = ?1 AND json_extract(config, '$.' || ?2) = ?3 [1=b,1=env,1=prod]"),
    )
    var fo = Filter.any_of(
        _p2(Pred.eq("kind", _t("a")), Pred.json_key_eq("config", "env", _t("prod")))
    )
    _ = db.query_rows[RT](reactor, "t", _s("id"), fo, _no_order(), _no_limit())
    _expect_log(
        db.log,
        _s2(
            "query SELECT id FROM t WHERE kind = ?1 AND json_extract(config, '$.' || ?2) = ?3 [1=b,1=env,1=prod]",
            "query SELECT id FROM t WHERE kind = ?1 OR json_extract(config, '$.' || ?2) = ?3 [1=a,1=env,1=prod]",
        ),
    )


def main() raises:
    print("== komira_db sql_neutral_ops: split, kinds, empty IN, pgstore JSON ==")
    test_sqlite_or_mixing_pushed_and_array_contains_is_refused()
    test_pgstore_or_mixing_pushed_and_json_key_eq_is_refused()
    test_sqlite_or_of_only_array_contains_keeps_either()
    test_pgstore_or_of_array_contains_and_json_key_eq_keeps_either()
    test_sqlite_and_split_still_requires_every_predicate()
    test_pg_or_with_array_contains_pushes_the_whole_or()
    test_a_null_or_absent_client_column_never_matches()
    test_three_argument_colval_refuses_an_unknown_kind()
    test_conditional_update_refuses_an_unknown_kind()
    test_claim_refuses_an_unknown_kind()
    test_empty_in_renders_false_and_keeps_bind_numbering()
    test_pgstore_json_key_eq_is_refused_outside_query_rows()
    test_pg_and_sqlite_json_key_eq_render_unchanged()
    test_sqlite_query_rows_pushes_json_key_eq_whole()
    print("PASS test_sql_split_and_binds")
