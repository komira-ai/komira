# =============================================================================
# komira_db/tests/test_sql_render.mojo
# The shared SQL renderers of sql_neutral_ops.mojo (the ops: test_sql_ops.mojo).
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
    render_get_by_key,
    render_put,
    render_delete_by_key,
    render_query_rows,
    render_query_rows_locked,
    render_conditional_update,
    render_delete_where,
    render_create_if_absent_composite,
    render_where,
    render_order,
    _n_update_binds,
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


# =============================================================================
# 1 — render_where: every predicate arm, numbering, joiner, the pg-only refusal
# =============================================================================


def test_render_where_every_arm_pg_numbering_from_offset() raises:
    """Each predicate renders its documented SQL and consumes exactly its binds;
    numbering starts at the caller's `next_bind` (2 here, so the first
    placeholder is `$3`) and the counter ends past the last bind."""
    var preds = List[Pred]()
    preds.append(Pred.eq("a", _t("x")))
    preds.append(Pred.ne("b", _t("y")))
    preds.append(Pred.ne("c", DbValue.null(LOGICAL_TEXT)))
    preds.append(Pred.lt("d", _i(1)))
    preds.append(Pred.le("e", _i(2)))
    preds.append(Pred.gte("f", _i(3)))
    preds.append(Pred.is_null("g"))
    preds.append(Pred.is_not_null("h"))
    preds.append(Pred.in_literals("s", _v2(_i(0), _i(1))))
    preds.append(Pred.in_list("t", _v2(_t("p"), _t("q"))))
    preds.append(Pred.json_key_eq("config", "k", _t("v")))
    preds.append(Pred.array_contains("tags", _t("red")))
    var nb = 2
    var got = render_where[PgDb](Filter.all_of(preds^), "pg", nb)
    assert_equal(
        got,
        String(
            "a = $3 AND (b IS NULL OR b <> $4) AND c IS NOT NULL AND d < $5"
            " AND e <= $6 AND f >= $7 AND g IS NULL AND h IS NOT NULL"
            " AND s IN (0, 1) AND t IN ($8, $9) AND config ->> $10 = $11"
            " AND $12 = ANY(tags)"
        ),
    )
    assert_equal(nb, 12)


def test_render_where_sqlite_or_and_json_extract() raises:
    """sqlite: OR joins the terms, JSON_KEY_EQ binds the key then the value
    through `json_extract(col, '$.' || ?k) = ?v`, a single-value bound IN binds
    one placeholder."""
    var preds = _p2(
        Pred.json_key_eq("config", "env", _t("prod")),
        Pred.in_list("x", _v1(_i(7))),
    )
    preds.append(Pred.eq("y", _i(8)))
    var nb = 0
    var got = render_where[SqliteDb](Filter.any_of(preds^), "sqlite", nb)
    assert_equal(
        got,
        String("json_extract(config, '$.' || ?1) = ?2 OR x IN (?3) OR y = ?4"),
    )
    assert_equal(nb, 4)


def test_render_where_empty_filter_binds_nothing() raises:
    var nb = 5
    assert_equal(render_where[PgDb](Filter.none(), "pg", nb), String(""))
    assert_equal(nb, 5)


def test_render_where_array_contains_refused_off_pg() raises:
    """ARRAY_CONTAINS is pg-only in SQL: any other dialect reaching the renderer
    is a wiring bug and fails closed, naming the dialect."""
    var nb = 0
    var raised = False
    try:
        _ = render_where[SqliteDb](
            Filter.just(Pred.array_contains("tags", _t("a"))), "sqlite", nb
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            String(
                "render_where: PRED_ARRAY_CONTAINS is pg-only in SQL; the"
                " query-rows op must strip it for dialect \"sqlite\" and"
                " filter client-side"
            ),
        )
    assert_true(raised, "sqlite array_contains must raise")


def test_render_order() raises:
    var o = List[Order]()
    o.append(Order.descending("created_at"))
    o.append(Order.asc("name"))
    o.append(Order.asc_explicit("id"))
    assert_equal(render_order(o), String("created_at DESC, name, id ASC"))
    assert_equal(render_order(_no_order()), String(""))


# =============================================================================
# 2 — the statement renderers
# =============================================================================


def test_render_key_statements_per_dialect() raises:
    var cols = _s3("id", "name", "n")
    assert_equal(
        render_get_by_key[PgDb]("jobs", cols, "id"),
        String("SELECT id, name, n FROM jobs WHERE id = $1"),
    )
    assert_equal(
        render_put[PgDb]("jobs", cols),
        String("INSERT INTO jobs (id, name, n) VALUES ($1, $2, $3)"),
    )
    assert_equal(
        render_put[SqliteDb]("jobs", cols),
        String("INSERT INTO jobs (id, name, n) VALUES (?1, ?2, ?3)"),
    )
    assert_equal(
        render_delete_by_key[SqliteDb]("jobs", "id"),
        String("DELETE FROM jobs WHERE id = ?1"),
    )


def test_render_query_rows_shapes() raises:
    """Bare SELECT with no clause; then WHERE, ORDER BY and a LIMIT numbered
    after the filter's binds."""
    var nb = 0
    assert_equal(
        render_query_rows[PgDb]("t", _s("a"), Filter.none(), _no_order(), False, nb),
        String("SELECT a FROM t"),
    )
    assert_equal(nb, 0)
    var o = List[Order]()
    o.append(Order.descending("b"))
    assert_equal(
        render_query_rows[PgDb](
            "t", _s2("a", "b"), Filter.just(Pred.eq("a", _i(1))), o, True, nb
        ),
        String("SELECT a, b FROM t WHERE a = $1 ORDER BY b DESC LIMIT $2"),
    )
    assert_equal(nb, 2)


def test_render_query_rows_locked_per_dialect() raises:
    """`FOR UPDATE SKIP LOCKED` on full Postgres only, after the ORDER BY."""
    var o = List[Order]()
    o.append(Order.asc("due"))
    var nb = 0
    assert_equal(
        render_query_rows_locked[PgDb](
            "q", _s("id"), Filter.just(Pred.lt("due", _i(9))), o, nb
        ),
        String("SELECT id FROM q WHERE due < $1 ORDER BY due FOR UPDATE SKIP LOCKED"),
    )
    assert_equal(nb, 1)
    nb = 0
    assert_equal(
        render_query_rows_locked[PgDb]("q", _s("id"), Filter.none(), _no_order(), nb),
        String("SELECT id FROM q FOR UPDATE SKIP LOCKED"),
    )
    nb = 0
    assert_equal(
        render_query_rows_locked[SqliteDb](
            "q", _s("id"), Filter.just(Pred.lt("due", _i(9))), o, nb
        ),
        String("SELECT id FROM q WHERE due < ?1 ORDER BY due"),
    )
    nb = 0
    assert_equal(
        render_query_rows_locked[PgstoreDb]("q", _s("id"), Filter.none(), o, nb),
        String("SELECT id FROM q ORDER BY due"),
    )


def test_render_conditional_update_mixed_set() raises:
    """The transition_job shape: plain, raw, COALESCE and plain terms keep their
    order, raw binds nothing, the now-stamp follows, and the guard numbers on
    from the SET's last bind."""
    var u = List[DbColVal]()
    u.append(DbColVal.bind("phase", _t("RUNNING")))
    u.append(DbColVal.raw_expr("version", "version + 1"))
    u.append(DbColVal.coalesce("progress", _i(5)))
    u.append(DbColVal.bind("msg", _t("m")))
    var guard = Filter.all_of(
        _p2(Pred.eq("id", _t("j1")), Pred.eq("phase", _t("PENDING")))
    )
    assert_equal(
        render_conditional_update[PgDb](
            "jobs", guard, u, False, _no_bump(), _s("updated_at")
        ),
        String(
            "UPDATE jobs SET phase = $1, version = version + 1, progress ="
            " COALESCE($2, progress), msg = $3, updated_at = NOW() WHERE id ="
            " $4 AND phase = $5"
        ),
    )


def test_render_conditional_update_coalesce_default_and_lead_terms() raises:
    """`coalesce=True` upgrades a plain bind to COALESCE; the version bump and a
    now-stamp each render correctly as the FIRST term (no leading comma), and
    an empty guard renders no WHERE."""
    var u = List[DbColVal]()
    u.append(DbColVal.bind("a", _i(1)))
    assert_equal(
        render_conditional_update[SqliteDb](
            "t", Filter.none(), u, True, Optional[String]("version"), List[String]()
        ),
        String("UPDATE t SET a = COALESCE(?1, a), version = version + 1"),
    )
    assert_equal(
        render_conditional_update[SqliteDb](
            "t",
            Filter.none(),
            List[DbColVal](),
            False,
            Optional[String]("version"),
            _s("updated_at"),
        ),
        String("UPDATE t SET version = version + 1, updated_at = ") + SQLITE_NOW,
    )
    assert_equal(
        render_conditional_update[PgDb](
            "t",
            Filter.just(Pred.eq("id", _i(4))),
            List[DbColVal](),
            False,
            _no_bump(),
            _s2("a_at", "b_at"),
        ),
        String("UPDATE t SET a_at = NOW(), b_at = NOW() WHERE id = $1"),
    )


def test_render_delete_where_and_composite_insert() raises:
    var nb = 0
    assert_equal(
        render_delete_where[PgDb](
            "idempotency_keys", Filter.just(Pred.lt("created_at", _i(100))), nb
        ),
        String("DELETE FROM idempotency_keys WHERE created_at < $1"),
    )
    assert_equal(nb, 1)
    nb = 0
    assert_equal(
        render_delete_where[PgDb]("t", Filter.none(), nb), String("DELETE FROM t")
    )
    assert_equal(
        render_create_if_absent_composite[PgDb](
            "m", _s2("mailbox_id", "content_hash"), _s3("mailbox_id", "content_hash", "body")
        ),
        String(
            "INSERT INTO m (mailbox_id, content_hash, body) VALUES ($1, $2, $3)"
            " ON CONFLICT (mailbox_id, content_hash) DO NOTHING RETURNING"
            " mailbox_id"
        ),
    )


def test_n_update_binds() raises:
    """BIND and COALESCE terms bind one param each; RAW_EXPR binds none.
    `_n_update_binds` has no caller in the library: this test only covers the
    uncalled helper and goes away with it (komira#954, item 5)."""
    var u = List[DbColVal]()
    u.append(DbColVal.bind("a", _i(1)))
    u.append(DbColVal.raw_expr("v", "v + 1"))
    u.append(DbColVal.coalesce("c", _i(2)))
    assert_equal(_n_update_binds(u), 2)
    assert_equal(_n_update_binds(List[DbColVal]()), 0)


def main() raises:
    print("== komira_db sql_neutral_ops ==")
    test_render_where_every_arm_pg_numbering_from_offset()
    test_render_where_sqlite_or_and_json_extract()
    test_render_where_empty_filter_binds_nothing()
    test_render_where_array_contains_refused_off_pg()
    test_render_order()
    test_render_key_statements_per_dialect()
    test_render_query_rows_shapes()
    test_render_query_rows_locked_per_dialect()
    test_render_conditional_update_mixed_set()
    test_render_conditional_update_coalesce_default_and_lead_terms()
    test_render_delete_where_and_composite_insert()
    test_n_update_binds()
    print("PASS test_sql_neutral_ops (renderers)")
