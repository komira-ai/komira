# =============================================================================
# komira_db_conformance/sql_checks.mojo -- the `SqlDatabase` string surface:
#   execute / query / query_opt / query_one, the dialect tokens, parameter
#   binding, transactions and errors.
# =============================================================================
#
# The checks write their own DDL. Column types come from the dialect tag
# (`dialect()` exists to route per-backend SQL), spelled as protoc-gen-mojo-db
# spells them (emit_dbstorable.rs): INT8 is INTEGER on sqlite, BIGINT on pg
# and pgstore.
#
# What the trait leaves to the backend, the checks take from the target:
# `error_text(kind)` is the fragment the backend's own messages carry. Every
# error check then runs one more statement on the same handle, so a backend
# that leaves its connection unusable after an error fails too.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor

from komira_db import (
    DbRows,
    DbValue,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_TEXT,
    SqlDatabase,
)

from komira_db_conformance.common import (
    Rt,
    assert_raises_with,
    assert_strs,
    new_rt,
    sorted_strs,
    strs,
    text_col,
)
from komira_db_conformance.targets import (
    ERR_NO_TABLE,
    ERR_NOT_NULL,
    ERR_SYNTAX,
    ERR_UNIQUE,
    SQL_TABLE,
    SQL_TABLE_NN,
    SqlTarget,
)


def _int8_type[DB: SqlDatabase]() -> String:
    return String("INTEGER") if DB.dialect() == String("sqlite") else String("BIGINT")


def _ph[DB: SqlDatabase](i: Int) -> String:
    return DB.placeholder(i)


def _typed_ph[DB: SqlDatabase](i: Int, logical: Int) -> String:
    """Placeholder `i` for a value of `logical` type, as an expression whose
    type the server knows. SQLite types the bound value itself (its dynamic
    typing is what lets these checks see how a value was bound), so the bare
    placeholder; Postgres infers a bare parameter in `$1 < $2` as text and
    cannot type `$1 IS NULL` at all, so there it is cast to the logical
    type's column type."""
    if DB.dialect() == String("sqlite"):
        return DB.placeholder(i)
    var ty = String("TEXT")
    if logical == LOGICAL_INT8:
        ty = String("BIGINT")
    elif logical == LOGICAL_INT4:
        ty = String("INTEGER")
    return String("CAST(") + DB.placeholder(i) + String(" AS ") + ty + String(")")


def _no_params() -> List[DbValue]:
    return List[DbValue]()


def _params(*vals: DbValue) -> List[DbValue]:
    var out = List[DbValue]()
    for v in vals:
        out.append(v.copy())
    return out^


def _make_table[DB: SqlDatabase](mut db: DB, mut reactor: Reactor[Rt.Sink]) raises:
    """conf_sql_t(id TEXT PRIMARY KEY, n INT8, s TEXT)."""
    _ = db.execute[Rt](
        reactor,
        String("CREATE TABLE ")
        + String(SQL_TABLE)
        + String(" (id TEXT PRIMARY KEY, n ")
        + _int8_type[DB]()
        + String(", s TEXT)"),
        _no_params(),
    )


def _insert[
    DB: SqlDatabase
](mut db: DB, mut reactor: Reactor[Rt.Sink], id: String, n: Int64, s: String) raises -> UInt64:
    return db.execute[Rt](
        reactor,
        String("INSERT INTO ")
        + String(SQL_TABLE)
        + String(" (id, n, s) VALUES (")
        + _ph[DB](0)
        + String(", ")
        + _ph[DB](1)
        + String(", ")
        + _ph[DB](2)
        + String(")"),
        _params(DbValue.text(id), DbValue.int8(n), DbValue.text(s)),
    )


def _ids[DB: SqlDatabase](mut db: DB, mut reactor: Reactor[Rt.Sink]) raises -> List[String]:
    var rows = db.query[Rt](
        reactor, String("SELECT id FROM ") + String(SQL_TABLE), _no_params()
    )
    return sorted_strs(text_col(rows, String("id")))


def _error_of[
    DB: SqlDatabase
](mut db: DB, mut reactor: Reactor[Rt.Sink], sql: String, params: List[DbValue]) -> Optional[String]:
    """The text `execute(sql)` raised, or None when it returned."""
    try:
        _ = db.execute[Rt](reactor, sql, params)
    except e:
        return Optional[String](String(e))
    return Optional[String]()


def _still_usable[DB: SqlDatabase](mut db: DB, mut reactor: Reactor[Rt.Sink], what: String) raises:
    var row = db.query_one[Rt](reactor, String("SELECT 7 AS seven"), _no_params())
    assert_equal(row.get_int8(0), Int64(7), what + String(": the handle is usable after the error"))


def check_dialect_tokens[T: SqlTarget]() raises:
    """dialect() is one of the three documented tags; placeholder(i) is `$<i+1>`
    on pg and pgstore and `?<i+1>` on sqlite. Needs no database."""
    var d = T.DB.dialect()
    assert_true(
        d == String("pg") or d == String("sqlite") or d == String("pgstore"),
        String("dialect() is a documented tag, got '") + d + "'",
    )
    var sigil = String("?") if d == String("sqlite") else String("$")
    for i in range(3):
        assert_equal(T.DB.placeholder(i), sigil + String(i + 1), "placeholder(" + String(i) + ")")
    assert_true(T.DB.now_expr().byte_length() > 0, "now_expr() is an expression")


def check_now_expr_evaluates[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var row = db.query_one[Rt](reactor, String("SELECT ") + T.DB.now_expr() + String(" AS now"), _no_params())
    assert_equal(row.col_count(), 1, "one column")
    assert_false(row.is_null(0), "now_expr() is not NULL")


def check_execute_rows_affected[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    for i in range(3):
        assert_equal(_insert(db, reactor, String("r") + String(i), Int64(i), String("s")), UInt64(1), "INSERT affects 1")
    var t_ = String(SQL_TABLE)
    assert_equal(db.execute[Rt](reactor, String("UPDATE ") + t_ + String(" SET n = n + 1"), _no_params()), UInt64(3), "UPDATE of every row affects 3")
    assert_equal(db.execute[Rt](reactor, String("UPDATE ") + t_ + String(" SET n = 0 WHERE id = ") + _ph[T.DB](0), _params(DbValue.text(String("none")))), UInt64(0), "UPDATE matching nothing affects 0")
    assert_equal(db.execute[Rt](reactor, String("DELETE FROM ") + t_ + String(" WHERE id = ") + _ph[T.DB](0), _params(DbValue.text(String("r1")))), UInt64(1), "DELETE of one row affects 1")
    assert_strs(_ids(db, reactor), strs("r0", "r2"), "r1 deleted")


def check_query_shape[T: SqlTarget](mut t: T) raises:
    """query returns every row in ORDER BY order, with the select-list names;
    a query matching nothing returns no rows."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    _ = _insert(db, reactor, String("b"), 2, String("two"))
    _ = _insert(db, reactor, String("a"), 1, String("one"))
    _ = _insert(db, reactor, String("c"), 3, String("three"))
    var rows = db.query[Rt](reactor, String("SELECT id AS ident, n FROM ") + String(SQL_TABLE) + String(" ORDER BY n DESC"), _no_params())
    assert_equal(rows.__len__(), 3, "three rows")
    assert_equal(rows.column_count(), 2, "two columns")
    assert_equal(rows.column_name(0), String("ident"), "column 0 carries its alias")
    assert_equal(rows.column_name(1), String("n"), "column 1 name")
    assert_strs(text_col(rows, String("ident")), strs("c", "b", "a"), "ORDER BY n DESC")
    assert_equal(rows.row(0).get_int8(1), Int64(3), "n of the first row")
    var empty = db.query[Rt](reactor, String("SELECT id FROM ") + String(SQL_TABLE) + String(" WHERE n > 99"), _no_params())
    assert_equal(empty.__len__(), 0, "no rows")


def check_query_one_and_opt[T: SqlTarget](mut t: T) raises:
    """query_one raises unless exactly one row; query_opt is None on zero
    rows and the row on one."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    _ = _insert(db, reactor, String("a"), 1, String("x"))
    _ = _insert(db, reactor, String("b"), 1, String("x"))
    var sel = String("SELECT id FROM ") + String(SQL_TABLE) + String(" WHERE n = ") + _ph[T.DB](0)
    var one = db.query_one[Rt](reactor, String("SELECT id FROM ") + String(SQL_TABLE) + String(" WHERE id = ") + _ph[T.DB](0), _params(DbValue.text(String("a"))))
    assert_equal(one.get_text(0), String("a"), "query_one, one row")
    var zero_raised = False
    try:
        _ = db.query_one[Rt](reactor, sel, _params(DbValue.int8(5)))
    except:
        zero_raised = True
    assert_true(zero_raised, "query_one of zero rows raises")
    var two_raised = False
    try:
        _ = db.query_one[Rt](reactor, sel, _params(DbValue.int8(1)))
    except:
        two_raised = True
    assert_true(two_raised, "query_one of two rows raises")
    assert_false(db.query_opt[Rt](reactor, sel, _params(DbValue.int8(5))).__bool__(), "query_opt of zero rows is None")
    var opt = db.query_opt[Rt](reactor, String("SELECT s FROM ") + String(SQL_TABLE) + String(" WHERE id = ") + _ph[T.DB](0), _params(DbValue.text(String("b"))))
    assert_true(opt.__bool__(), "query_opt of one row is the row")
    assert_equal(opt.take().get_text(0), String("x"), "query_opt row value")


def check_params_never_interpolated[T: SqlTarget](mut t: T) raises:
    """A bound value is data, never SQL: quotes, a statement terminator with a
    DROP TABLE, comment markers and placeholder-shaped text are stored and
    matched verbatim, and the table survives."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    var hostile = strs(
        "O'Brien",
        "x'); DROP TABLE conf_sql_t; --",
        "'; DELETE FROM conf_sql_t; --",
        "?1 $1 ?2",
        "back\\slash \"dq\" /* c */",
        "% _ wildcard",
    )
    for i in range(len(hostile)):
        assert_equal(_insert(db, reactor, String("h") + String(i), Int64(i), hostile[i]), UInt64(1), "insert of a hostile value")
    var sel = String("SELECT id, s FROM ") + String(SQL_TABLE) + String(" WHERE s = ") + _ph[T.DB](0)
    for i in range(len(hostile)):
        var rows = db.query[Rt](reactor, sel, _params(DbValue.text(hostile[i])))
        assert_equal(rows.__len__(), 1, String("lookup by hostile value ") + String(i))
        assert_equal(rows.row(0).get_text(0), String("h") + String(i), "the row found")
        assert_equal(rows.row(0).get_text(1), hostile[i], "stored verbatim")
    var tautology = db.query[Rt](reactor, sel, _params(DbValue.text(String("' OR '1'='1"))))
    assert_equal(tautology.__len__(), 0, "a quoted tautology matches nothing")
    var n = db.query_one[Rt](reactor, String("SELECT COUNT(*) AS c FROM ") + String(SQL_TABLE), _no_params())
    assert_equal(n.get_int8(0), Int64(len(hostile)), "every row is still there")


def _cmp_sql[DB: SqlDatabase](logical: Int) -> String:
    return (
        String("SELECT 1 AS one WHERE ")
        + _typed_ph[DB](0, logical)
        + String(" < ")
        + _typed_ph[DB](1, logical)
    )


def check_params_typed[T: SqlTarget](mut t: T) raises:
    """INT4 and INT8 parameters bind as numbers: 9 < 10 holds for them and
    fails for the same digits bound as TEXT (the control). On SQLite the
    bound value's own type decides the comparison, so an integer bound as
    text fails here; on Postgres each parameter is cast to its logical
    type's column type (`_typed_ph`)."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var i8 = _cmp_sql[T.DB](LOGICAL_INT8)
    var i4 = _cmp_sql[T.DB](LOGICAL_INT4)
    var tx = _cmp_sql[T.DB](LOGICAL_TEXT)
    assert_equal(db.query[Rt](reactor, i8, _params(DbValue.int8(9), DbValue.int8(10))).__len__(), 1, "INT8 9 < 10")
    assert_equal(db.query[Rt](reactor, i4, _params(DbValue.int4(9), DbValue.int4(10))).__len__(), 1, "INT4 9 < 10")
    assert_equal(db.query[Rt](reactor, i8, _params(DbValue.int8(-5), DbValue.int8(3))).__len__(), 1, "INT8 -5 < 3")
    assert_equal(db.query[Rt](reactor, tx, _params(DbValue.text(String("9")), DbValue.text(String("10")))).__len__(), 0, "TEXT '9' < '10' is false")


def check_params_null[T: SqlTarget](mut t: T) raises:
    """A typed NULL binds as SQL NULL; an empty string does not."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var txt = String("SELECT 1 AS one WHERE ") + _typed_ph[T.DB](0, LOGICAL_TEXT) + String(" IS NULL")
    var int8 = String("SELECT 1 AS one WHERE ") + _typed_ph[T.DB](0, LOGICAL_INT8) + String(" IS NULL")
    assert_equal(db.query[Rt](reactor, txt, _params(DbValue.null(LOGICAL_TEXT))).__len__(), 1, "NULL IS NULL")
    assert_equal(db.query[Rt](reactor, int8, _params(DbValue.null(LOGICAL_INT8))).__len__(), 1, "INT8 NULL IS NULL")
    assert_equal(db.query[Rt](reactor, txt, _params(DbValue.text(String("")))).__len__(), 0, "'' is not NULL")


def check_tx_commit_visible[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    db.begin[Rt](reactor)
    _ = _insert(db, reactor, String("a"), 1, String("x"))
    db.commit[Rt](reactor)
    assert_strs(_ids(db, reactor), strs("a"), "a committed insert is visible")


def check_tx_rollback_undoes[T: SqlTarget](mut t: T) raises:
    """Inside begin/rollback an INSERT, an UPDATE and a DELETE are all undone."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    _ = _insert(db, reactor, String("keep"), 1, String("orig"))
    _ = _insert(db, reactor, String("gone"), 2, String("orig"))
    db.begin[Rt](reactor)
    _ = _insert(db, reactor, String("new"), 3, String("x"))
    _ = db.execute[Rt](reactor, String("UPDATE ") + String(SQL_TABLE) + String(" SET s = 'changed' WHERE id = 'keep'"), _no_params())
    _ = db.execute[Rt](reactor, String("DELETE FROM ") + String(SQL_TABLE) + String(" WHERE id = 'gone'"), _no_params())
    db.rollback[Rt](reactor)
    assert_strs(_ids(db, reactor), strs("gone", "keep"), "insert and delete undone")
    var s = db.query_one[Rt](reactor, String("SELECT s FROM ") + String(SQL_TABLE) + String(" WHERE id = 'keep'"), _no_params())
    assert_equal(s.get_text(0), String("orig"), "update undone")


def check_tx_rollback_after_error[T: SqlTarget](mut t: T) raises:
    """A statement that fails inside a transaction raises; rollback then
    undoes the statements before it."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    _ = _insert(db, reactor, String("a"), 1, String("x"))
    db.begin[Rt](reactor)
    _ = _insert(db, reactor, String("b"), 2, String("x"))
    var raised = False
    try:
        _ = _insert(db, reactor, String("a"), 3, String("dup"))
    except:
        raised = True
    assert_true(raised, "a duplicate key inside the transaction raises")
    db.rollback[Rt](reactor)
    assert_strs(_ids(db, reactor), strs("a"), "the transaction's insert is undone")


def check_error_syntax[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var err = _error_of(db, reactor, String("SELEC 1"), _no_params())
    assert_raises_with(err, t.error_text(ERR_SYNTAX), "syntax error")
    _still_usable(db, reactor, "syntax error")


def check_error_unique[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _make_table(db, reactor)
    _ = _insert(db, reactor, String("a"), 1, String("first"))
    var err = Optional[String]()
    try:
        _ = _insert(db, reactor, String("a"), 2, String("second"))
    except e:
        err = Optional[String](String(e))
    assert_raises_with(err, t.error_text(ERR_UNIQUE), "duplicate primary key")
    _still_usable(db, reactor, "duplicate primary key")
    var s = db.query_one[Rt](reactor, String("SELECT s FROM ") + String(SQL_TABLE) + String(" WHERE id = 'a'"), _no_params())
    assert_equal(s.get_text(0), String("first"), "the first row is unchanged")


def check_error_not_null[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _ = db.execute[Rt](reactor, String("CREATE TABLE ") + String(SQL_TABLE_NN) + String(" (id TEXT PRIMARY KEY, req TEXT NOT NULL)"), _no_params())
    var err = _error_of(
        db,
        reactor,
        String("INSERT INTO ") + String(SQL_TABLE_NN) + String(" (id, req) VALUES (") + _ph[T.DB](0) + String(", ") + _ph[T.DB](1) + String(")"),
        _params(DbValue.text(String("a")), DbValue.null(LOGICAL_TEXT)),
    )
    assert_raises_with(err, t.error_text(ERR_NOT_NULL), "NULL in a NOT NULL column")
    _still_usable(db, reactor, "NOT NULL")
    var n = db.query_one[Rt](reactor, String("SELECT COUNT(*) AS c FROM ") + String(SQL_TABLE_NN), _no_params())
    assert_equal(n.get_int8(0), Int64(0), "nothing was stored")


def check_error_missing_table[T: SqlTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var err = Optional[String]()
    try:
        _ = db.query[Rt](reactor, String("SELECT * FROM conf_no_such_table"), _no_params())
    except e:
        err = Optional[String](String(e))
    assert_raises_with(err, t.error_text(ERR_NO_TABLE), "missing table")
    _still_usable(db, reactor, "missing table")


def check_getter_type_mismatch[T: SqlTarget](mut t: T) raises:
    """A cell read through the getter of another type raises (DbRow parses the
    canonical text; komira_db/db_row.mojo)."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var row = db.query_one[Rt](reactor, String("SELECT 'zz' AS s"), _no_params())
    assert_equal(row.get_text(0), String("zz"), "text getter")
    var int_err = Optional[String]()
    try:
        _ = row.get_int8(0)
    except e:
        int_err = Optional[String](String(e))
    assert_raises_with(int_err, String("DbRow: non-numeric byte in integer text"), "get_int8 of text")
    var uuid_err = Optional[String]()
    try:
        _ = row.get_uuid(0)
    except e:
        uuid_err = Optional[String](String(e))
    assert_raises_with(uuid_err, String("DbRow: invalid hex nibble in UUID"), "get_uuid of text")
