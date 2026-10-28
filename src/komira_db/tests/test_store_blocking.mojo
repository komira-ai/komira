# =============================================================================
# komira_db/tests/test_store_blocking.mojo
# The single-shot blocking helpers (blocking.mojo) and the typed Store surface
# with its column-index mapping (db_storable.mojo).
# =============================================================================
# `_LogDb[D]` is a recording `SqlDatabase`: each raw verb it is handed is logged
# as `<verb> <sql> [<params>]` (the same param encoding as test_sql_ops.mojo:
# `<logical type>=<text>`, `~` for a NULL) and answered from a script. Its nine
# neutral ops raise: neither blocking.mojo nor the Store reaches them, so a call
# into one is a defect this file would report. `D` picks the placeholder
# dialect (pg `$N`, sqlite `?N`).
#
# `_Thing` is a hand-written `DbStorable` (what protoc-gen-mojo generates):
# table `things`, primary key `id`, columns `id TEXT`, `n INT8`, `note TEXT
# NULL`. Every expected SQL text and log line below is written out by hand
# from the contracts in the two files' docstrings, never computed by the code
# under test.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_db.blocking import (
    db_blocking_execute,
    db_blocking_query,
    db_blocking_query_opt,
    db_blocking_query_one,
    db_blocking_begin,
    db_blocking_commit,
    db_blocking_rollback,
    db_blocking_claim_pending,
)
from komira_db.database import SqlDatabase
from komira_db.db_row import DbRow, DbRows
from komira_db.db_storable import (
    DbStorable,
    Store,
    col_index_for,
    identity_col_index,
)
from komira_db.db_value import (
    DbColumn,
    DbValue,
    LOGICAL_INT8,
    LOGICAL_TEXT,
)
from komira_db.neutral_ops import DbColVal, Filter, Order, PodNameMinter


comptime D_PG = 0
comptime D_SQLITE = 1

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


def _unused(op: String) raises:
    raise Error("_LogDb: neutral op " + op + " is not reached by this surface")


struct _LogDb[D: Int](SqlDatabase):
    var log: List[String]
    var rows: List[DbRow]  # what `query` / `claim_pending` answer
    var cols: List[String]
    var opt_hit: Bool  # does `query_opt` find `one`
    var one: DbRow  # what `query_opt` (on a hit) and `query_one` answer
    var exec_ret: UInt64

    def __init__(out self):
        self.log = List[String]()
        self.rows = List[DbRow]()
        self.cols = List[String]()
        self.opt_hit = False
        self.one = DbRow.from_values(List[DbValue](), List[String]())
        self.exec_ret = 0

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
        return self.exec_ret

    def query[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> DbRows:
        self.log.append("query " + sql + " [" + _enc(params) + "]")
        return DbRows(self.rows.copy(), self.cols.copy())

    def query_opt[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> Optional[DbRow]:
        self.log.append("query_opt " + sql + " [" + _enc(params) + "]")
        if self.opt_hit:
            return Optional[DbRow](self.one.copy())
        return Optional[DbRow](None)

    def query_one[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]
    ) raises -> DbRow:
        self.log.append("query_one " + sql + " [" + _enc(params) + "]")
        return self.one.copy()

    @staticmethod
    def dialect() -> String:
        comptime if Self.D == D_SQLITE:
            return String("sqlite")
        else:
            return String("pg")

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
        self.log.append(
            "claim " + table + " n=" + String(n) + " " + phase_col + ":"
            + pending + "->" + assigned + " set " + extra_set
            + " [" + _enc(params) + "]"
        )
        return DbRows(self.rows.copy(), self.cols.copy())

    # ---- the nine neutral ops: not reached by blocking.mojo or Store ----
    def get_by_key[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        key_col: String,
        key_val: DbValue,
    ) raises -> Optional[DbRow]:
        _unused("get_by_key")
        return Optional[DbRow](None)

    def put[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> UInt64:
        _unused("put")
        return 0

    def delete_by_key[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        key_col: String,
        key_val: DbValue,
    ) raises -> UInt64:
        _unused("delete_by_key")
        return 0

    def query_rows[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        _unused("query_rows")
        return DbRows(List[DbRow](), List[String]())

    def query_rows_locked[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
    ) raises -> DbRows:
        _unused("query_rows_locked")
        return DbRows(List[DbRow](), List[String]())

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
        _unused("conditional_update")
        return 0

    def delete_where[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], table: String, filter: Filter
    ) raises -> UInt64:
        _unused("delete_where")
        return 0

    def create_if_absent[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        _unused("create_if_absent")
        return False

    def create_if_absent_composite[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        _unused("create_if_absent_composite")
        return False

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
        _unused("claim_rows")
        return DbRows(List[DbRow](), List[String]())


comptime PgDb = _LogDb[D_PG]
comptime SqliteDb = _LogDb[D_SQLITE]


# =============================================================================
# _Thing — a hand-written DbStorable (the shape protoc-gen-mojo generates).
# =============================================================================
struct _Thing(DbStorable):
    comptime TABLE: StaticString = "things"
    comptime PK: StaticString = "id"

    var id: String
    var n: Int64
    var note: Optional[String]

    def __init__(out self, var id: String, n: Int64, var note: Optional[String]):
        self.id = id^
        self.n = n
        self.note = note^

    @staticmethod
    def column_names() -> List[String]:
        var c = List[String]()
        c.append("id")
        c.append("n")
        c.append("note")
        return c^

    @staticmethod
    def column_types() -> List[DbColumn]:
        var c = List[DbColumn]()
        c.append(DbColumn("id", 1, LOGICAL_TEXT, False))
        c.append(DbColumn("n", 2, LOGICAL_INT8, False))
        c.append(DbColumn("note", 3, LOGICAL_TEXT, True))
        return c^

    @staticmethod
    def create_table_ddl() -> String:
        return String(
            "CREATE TABLE IF NOT EXISTS things (id TEXT PRIMARY KEY, n BIGINT"
            " NOT NULL, note TEXT)"
        )

    @staticmethod
    def insert_sql[D: SqlDatabase]() -> String:
        return (
            String("INSERT INTO things (id, n, note) VALUES (")
            + D.placeholder(0) + ", " + D.placeholder(1) + ", "
            + D.placeholder(2) + ")"
        )

    def to_row(self) -> List[DbValue]:
        var v = List[DbValue]()
        v.append(DbValue.text(self.id.copy()))
        v.append(DbValue.int8(self.n))
        if self.note:
            v.append(DbValue.text(self.note.value().copy()))
        else:
            v.append(DbValue.null(LOGICAL_TEXT))
        return v^

    @staticmethod
    def from_row(row: DbRow, col_index: List[Int]) raises -> Self:
        return _Thing(
            row.get_text(col_index[0]),
            row.get_int8(col_index[1]),
            row.get_opt_text(col_index[2]),
        )


# ---- small builders ----
def _s3(a: String, b: String, c: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    l.append(c)
    return l^


def _row(
    id: String, n: Int64, note: String, note_null: Bool, cols: List[String]
) -> DbRow:
    """A `things` row whose values are laid out in `cols`' order (each of
    `cols` is one of `id`, `n`, `note`, or a name `_Thing` does not know)."""
    var v = List[DbValue]()
    for i in range(len(cols)):
        if cols[i] == "id":
            v.append(DbValue.text(id))
        elif cols[i] == "n":
            v.append(DbValue.int8(n))
        elif cols[i] == "note":
            if note_null:
                v.append(DbValue.null(LOGICAL_TEXT))
            else:
                v.append(DbValue.text(note))
        else:
            v.append(DbValue.text("?"))
    return DbRow.from_values(v, cols)


def _params(a: String, b: Int64) -> List[DbValue]:
    var p = List[DbValue]()
    p.append(DbValue.text(a))
    p.append(DbValue.int8(b))
    return p^


def _expect_log(db_log: List[String], want: List[String]) raises:
    assert_equal(len(db_log), len(want), "log length")
    for i in range(len(want)):
        assert_equal(db_log[i], want[i])


def _ints(l: List[Int]) -> String:
    var s = String()
    for i in range(len(l)):
        if i > 0:
            s += ","
        s += String(l[i])
    return s^


# =============================================================================
# 1 — blocking.mojo: each helper reaches its own verb with the caller's args
# =============================================================================
def test_blocking_raw_verbs_pass_sql_params_and_results() raises:
    """Each `db_blocking_*` raw verb hands the caller's SQL and params to the
    matching `[RT]` method and returns its answer unchanged. Catches a helper
    wired to the wrong verb (query_opt answering through query_one), dropping
    the params, or replacing the result."""
    var db = PgDb()
    db.exec_ret = 7
    db.rows.append(_row("a", 1, "", True, _s3("id", "n", "note")))
    db.rows.append(_row("b", 2, "x", False, _s3("id", "n", "note")))
    db.cols = _s3("id", "n", "note")
    db.one = _row("c", 3, "y", False, _s3("id", "n", "note"))

    assert_equal(db_blocking_execute(db, "UPDATE t SET a = $1", _params("v", 4)), UInt64(7))
    var rows = db_blocking_query(db, "SELECT * FROM t WHERE a = $1", _params("q", 5))
    assert_equal(rows.__len__(), 2, "query returns the backend's rows")
    assert_equal(rows.row(1).get_text(0), String("b"))
    db.opt_hit = True
    var hit = db_blocking_query_opt(db, "SELECT 1", List[DbValue]())
    assert_true(hit.__bool__(), "query_opt passes a found row through")
    assert_equal(hit.value().get_text(0), String("c"))
    db.opt_hit = False
    var miss = db_blocking_query_opt(db, "SELECT 2", List[DbValue]())
    assert_false(miss.__bool__(), "query_opt passes no row through as None")
    var one = db_blocking_query_one(db, "SELECT 3", _params("o", -9))
    assert_equal(one.get_int8(1), Int64(3))

    var want = List[String]()
    want.append("execute UPDATE t SET a = $1 [1=v,3=4]")
    want.append("query SELECT * FROM t WHERE a = $1 [1=q,3=5]")
    want.append("query_opt SELECT 1 []")
    want.append("query_opt SELECT 2 []")
    want.append("query_one SELECT 3 [1=o,3=-9]")
    _expect_log(db.log, want)
    print("  [1] blocking raw verbs pass SQL, params and results OK")


def test_blocking_tx_verbs_reach_their_own_verb() raises:
    """begin / commit / rollback each reach their own tx verb (a helper wired
    to the wrong one would commit what the caller rolled back)."""
    var db = SqliteDb()
    db_blocking_begin(db)
    db_blocking_rollback(db)
    db_blocking_begin(db)
    db_blocking_commit(db)
    var want = List[String]()
    want.append("BEGIN")
    want.append("ROLLBACK")
    want.append("BEGIN")
    want.append("COMMIT")
    _expect_log(db.log, want)
    print("  [2] blocking tx verbs reach begin/rollback/commit in order OK")


def test_blocking_claim_pending_forwards_every_argument() raises:
    """`db_blocking_claim_pending` forwards table, n, both phases, the extra
    SET, the params and the phase column; the phase column defaults to
    `phase`. Catches a dropped `phase_col` (a claim on the wrong column) and a
    swapped pending/assigned pair."""
    var db = PgDb()
    db.rows.append(_row("a", 1, "", True, _s3("id", "n", "note")))
    db.cols = _s3("id", "n", "note")
    var got = db_blocking_claim_pending(
        db, "jobs", 3, "PENDING", "ASSIGNED", "worker = $1", _params("w", 8)
    )
    assert_equal(got.__len__(), 1, "the claimed rows come back")
    _ = db_blocking_claim_pending(
        db, "tasks", 1, "NEW", "TAKEN", "", List[DbValue](), String("status")
    )
    var want = List[String]()
    want.append("claim jobs n=3 phase:PENDING->ASSIGNED set worker = $1 [1=w,3=8]")
    want.append("claim tasks n=1 status:NEW->TAKEN set  []")
    _expect_log(db.log, want)
    print("  [3] blocking claim_pending forwards every argument OK")


# =============================================================================
# 2 — db_storable.mojo: the column-index mapping
# =============================================================================
def test_identity_col_index() raises:
    """`identity_col_index(n)` is exactly `[0, 1, ..., n-1]` (empty for 0)."""
    assert_equal(_ints(identity_col_index(0)), String(""))
    assert_equal(_ints(identity_col_index(1)), String("0"))
    assert_equal(_ints(identity_col_index(4)), String("0,1,2,3"))
    print("  [4] identity_col_index OK")


def test_col_index_for_matches_by_name_with_identity_fallback() raises:
    """`col_index_for[_Thing]` finds each of `_Thing`'s columns by name in the
    row; a name the row lacks falls back to its own position. The permuted row
    puts `note` at index 0, so a `>= 0` -> `> 0` slip (index 0 read as absent)
    maps `note` to 2 and goes red."""
    var permuted = _row("i", 5, "z", False, _s3("note", "id", "n"))
    assert_equal(_ints(col_index_for[_Thing](permuted)), String("1,2,0"))
    var positional = _row("i", 5, "z", False, _s3("c0", "c1", "c2"))
    assert_equal(_ints(col_index_for[_Thing](positional)), String("0,1,2"))
    # One name present (at position 2), the rest positional.
    var mixed = _row("i", 5, "z", False, _s3("c0", "c1", "id"))
    assert_equal(_ints(col_index_for[_Thing](mixed)), String("2,1,2"))
    print("  [5] col_index_for: by name, identity fallback OK")


# =============================================================================
# 3 — Store[DB]: the SQL it renders and the rows it decodes
# =============================================================================
def test_store_sql_per_dialect() raises:
    """`insert_sql_for` renders `T.insert_sql` with the store's dialect and
    `delete_sql_for` is `DELETE FROM <TABLE> WHERE <PK> = <placeholder 0>`."""
    assert_equal(
        Store[PgDb].insert_sql_for[_Thing](),
        String("INSERT INTO things (id, n, note) VALUES ($1, $2, $3)"),
    )
    assert_equal(
        Store[SqliteDb].insert_sql_for[_Thing](),
        String("INSERT INTO things (id, n, note) VALUES (?1, ?2, ?3)"),
    )
    assert_equal(
        Store[PgDb].delete_sql_for[_Thing](),
        String("DELETE FROM things WHERE id = $1"),
    )
    assert_equal(
        Store[SqliteDb].delete_sql_for[_Thing](),
        String("DELETE FROM things WHERE id = ?1"),
    )
    print("  [6] Store insert/delete SQL per dialect OK")


def test_store_insert_delete_and_tx_go_through_the_backend() raises:
    """`insert` executes the generated INSERT with `to_row()`'s values;
    `delete` executes the delete-by-PK with the one PK param; both return the
    backend's rows_affected; begin/commit/rollback reach their own verbs; `db()`
    borrows and `into_db()` hands back the same backend (its log survives)."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var store = Store[SqliteDb](SqliteDb())
    store.db().exec_ret = 1
    store.begin[RT](reactor)
    var t = _Thing("t1", -42, Optional[String]())
    assert_equal(store.insert[RT, _Thing](reactor, t), UInt64(1))
    store.db().exec_ret = 0
    var t2 = _Thing("t2", 9, Optional[String]("hello"))
    assert_equal(store.insert[RT, _Thing](reactor, t2), UInt64(0))
    store.rollback[RT](reactor)
    store.db().exec_ret = 1
    assert_equal(
        store.delete[RT, _Thing](reactor, DbValue.text("t1")), UInt64(1)
    )
    store.commit[RT](reactor)
    var db = store^.into_db()
    var want = List[String]()
    want.append("BEGIN")
    want.append("execute INSERT INTO things (id, n, note) VALUES (?1, ?2, ?3) [1=t1,3=-42,1~]")
    want.append("execute INSERT INTO things (id, n, note) VALUES (?1, ?2, ?3) [1=t2,3=9,1=hello]")
    want.append("ROLLBACK")
    want.append("execute DELETE FROM things WHERE id = ?1 [1=t1]")
    want.append("COMMIT")
    _expect_log(db.log, want)
    print("  [7] Store insert/delete/tx through the backend OK")


def test_store_query_decodes_rows_by_name() raises:
    """`query` decodes every row by column name (here the backend answers in a
    permuted order), keeps row order, and decodes a NULL to an empty Optional;
    an empty result set decodes to an empty list."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var db = PgDb()
    var cols = _s3("n", "note", "id")
    db.rows.append(_row("r1", 10, "", True, cols))
    db.rows.append(_row("r2", -3, "two", False, cols))
    db.cols = cols.copy()
    var store = Store[PgDb](db^)
    var got = store.query[RT, _Thing](reactor, "SELECT n, note, id FROM things", _params("p", 1))
    assert_equal(len(got), 2)
    assert_equal(got[0].id, String("r1"))
    assert_equal(got[0].n, Int64(10))
    assert_false(got[0].note.__bool__(), "a NULL note decodes to None")
    assert_equal(got[1].id, String("r2"))
    assert_equal(got[1].n, Int64(-3))
    assert_equal(got[1].note.value(), String("two"))
    store.db().rows = List[DbRow]()
    var none = store.query[RT, _Thing](reactor, "SELECT none", List[DbValue]())
    assert_equal(len(none), 0, "no rows decode to an empty list")
    var want = List[String]()
    want.append("query SELECT n, note, id FROM things [1=p,3=1]")
    want.append("query SELECT none []")
    _expect_log(store.db().log, want)
    print("  [8] Store.query decodes permuted rows by name OK")


def test_store_query_opt_and_one() raises:
    """`query_opt` decodes a found row and answers None for no row (never a
    zero-valued `T`); `query_one` decodes its row."""
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var store = Store[PgDb](PgDb())
    store.db().one = _row("o1", 77, "note", False, _s3("note", "id", "n"))
    store.db().opt_hit = True
    var hit = store.query_opt[RT, _Thing](reactor, "SELECT a", List[DbValue]())
    assert_true(hit.__bool__(), "a found row decodes")
    assert_equal(hit.value().id, String("o1"))
    assert_equal(hit.value().n, Int64(77))
    assert_equal(hit.value().note.value(), String("note"))
    store.db().opt_hit = False
    var miss = store.query_opt[RT, _Thing](reactor, "SELECT b", List[DbValue]())
    assert_false(miss.__bool__(), "no row is None")
    var one = store.query_one[RT, _Thing](reactor, "SELECT c", _params("k", 2))
    assert_equal(one.id, String("o1"))
    assert_equal(one.n, Int64(77))
    var want = List[String]()
    want.append("query_opt SELECT a []")
    want.append("query_opt SELECT b []")
    want.append("query_one SELECT c [1=k,3=2]")
    _expect_log(store.db().log, want)
    print("  [9] Store.query_opt / query_one OK")


def test_store_decode_row_and_rows() raises:
    """`decode_row` / `decode_rows` decode without touching the backend: a
    positional row (no known names) decodes by identity position."""
    var store = Store[PgDb](PgDb())
    var pv = List[DbValue]()
    pv.append(DbValue.text("p1"))
    pv.append(DbValue.int8(6))
    pv.append(DbValue.null(LOGICAL_TEXT))
    var positional = DbRow.from_values(pv, _s3("a", "b", "c"))
    var t = store.decode_row[_Thing](positional)
    assert_equal(t.id, String("p1"))
    assert_equal(t.n, Int64(6))
    assert_false(t.note.__bool__())
    var rs = List[DbRow]()
    rs.append(_row("x", 1, "one", False, _s3("id", "note", "n")))
    rs.append(_row("y", 2, "", True, _s3("id", "note", "n")))
    var all = store.decode_rows[_Thing](DbRows(rs^, _s3("id", "note", "n")))
    assert_equal(len(all), 2)
    assert_equal(all[0].id + "," + all[1].id, String("x,y"))
    assert_equal(all[1].n, Int64(2))
    assert_equal(all[0].note.value(), String("one"))
    assert_equal(len(store.db().log), 0, "decoding touches no backend")
    print("  [10] Store.decode_row / decode_rows OK")


def main() raises:
    print("== komira_db blocking helpers + Store ==")
    test_blocking_raw_verbs_pass_sql_params_and_results()
    test_blocking_tx_verbs_reach_their_own_verb()
    test_blocking_claim_pending_forwards_every_argument()
    test_identity_col_index()
    test_col_index_for_matches_by_name_with_identity_fallback()
    test_store_sql_per_dialect()
    test_store_insert_delete_and_tx_go_through_the_backend()
    test_store_query_decodes_rows_by_name()
    test_store_query_opt_and_one()
    test_store_decode_row_and_rows()
    print("PASS test_store_blocking")
