# =============================================================================
# komira_db_conformance/neutral_checks.mojo -- the backend-neutral `Database`
#   operations, as komira_db/database.mojo documents them.
# =============================================================================
#
# Each check states the documented behaviour it holds the target to. Result
# sets whose order the contract does not fix (no ORDER BY, a claim's returned
# rows) are compared as sorted sets.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor

from komira_db import (
    DbColVal,
    DbRows,
    DbValue,
    Filter,
    LOGICAL_TEXT,
    Order,
    PodNameMinter,
    Pred,
)

from komira_db_conformance.common import (
    Rt,
    a_note,
    assert_strs,
    item_cols,
    item_row,
    new_rt,
    no_note,
    now_micros,
    sorted_strs,
    strs,
    text_col,
)
from komira_db_conformance.targets import ITEMS, PAIRS, NeutralTarget


def _no_limit() -> Optional[UInt32]:
    return Optional[UInt32]()


def _by_id(id: StaticString) -> Filter:
    return Filter.just(Pred.eq(String("id"), DbValue.text(String(id))))


def _seed4[T: NeutralTarget](mut db: T.DB, mut reactor: Reactor[Rt.Sink]) raises:
    """a(o1, 10, note NULL) b(o1, 40, "x") c(o2, 20, NULL) d(o1, 30, "y"),
    all phase NEW, version 1."""
    var c = item_cols()
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("a", "o1", "NEW", 1, no_note(), 10))
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("b", "o1", "NEW", 1, a_note("x"), 40))
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("c", "o2", "NEW", 1, no_note(), 20))
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("d", "o1", "NEW", 1, a_note("y"), 30))


def _ids_where[
    T: NeutralTarget
](mut db: T.DB, mut reactor: Reactor[Rt.Sink], filter: Filter) raises -> List[String]:
    """The ids `filter` selects, sorted."""
    var rows = db.query_rows[Rt](
        reactor, String(ITEMS), strs("id"), filter, List[Order](), _no_limit()
    )
    return sorted_strs(text_col(rows, String("id")))


def _get_item[
    T: NeutralTarget
](mut db: T.DB, mut reactor: Reactor[Rt.Sink], id: StaticString) raises -> DbRows:
    """Row `id` of conf_items, every column, as a one-row result (empty when
    absent), so `text_col` reads it by name."""
    return db.query_rows[Rt](
        reactor, String(ITEMS), item_cols(), _by_id(id), List[Order](), _no_limit()
    )


def check_put_get_by_key[T: NeutralTarget](mut t: T) raises:
    """put returns rows_affected 1; get_by_key projects `cols` in the order
    asked; an absent key is None; key_col need not be the primary key."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var n = db.put[Rt](
        reactor, String(ITEMS), item_cols(), item_row("a", "o1", "NEW", 1, no_note(), 10)
    )
    assert_equal(n, UInt64(1), "put rows_affected")
    _ = db.put[Rt](
        reactor, String(ITEMS), item_cols(), item_row("b", "o2", "RUN", 3, a_note("n"), 20)
    )
    var got = db.get_by_key[Rt](
        reactor, String(ITEMS), strs("phase", "id", "owner"), String("id"), DbValue.text(String("a"))
    )
    assert_true(got.__bool__(), "get_by_key finds the row put")
    var row = got.take()
    assert_equal(row.col_count(), 3, "get_by_key projects exactly cols")
    assert_equal(row.column_name(0), String("phase"), "projection order: column 0")
    assert_equal(row.get_text(0), String("NEW"), "phase")
    assert_equal(row.get_text(1), String("a"), "id")
    assert_equal(row.get_text(2), String("o1"), "owner")
    var none = db.get_by_key[Rt](
        reactor, String(ITEMS), strs("id"), String("id"), DbValue.text(String("zzz"))
    )
    assert_false(none.__bool__(), "get_by_key of an absent key is None")
    var by_owner = db.get_by_key[Rt](
        reactor, String(ITEMS), strs("id", "version"), String("owner"), DbValue.text(String("o2"))
    )
    assert_true(by_owner.__bool__(), "get_by_key on a non-key column finds the row")
    var r2 = by_owner.take()
    assert_equal(r2.get_text(0), String("b"), "get_by_key(owner) row")
    assert_equal(r2.get_int8(1), Int64(3), "get_by_key(owner) version")


def check_put_duplicate_key_raises[T: NeutralTarget](mut t: T) raises:
    """put inserts and never overwrites (the `Database.put` doc): a second row
    with the same primary key raises and the first row is unchanged."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _ = db.put[Rt](reactor, String(ITEMS), item_cols(), item_row("a", "o1", "NEW", 1, a_note("first"), 10))
    var raised = False
    try:
        _ = db.put[Rt](reactor, String(ITEMS), item_cols(), item_row("a", "o9", "NEW", 1, a_note("second"), 10))
    except:
        raised = True
    assert_true(raised, "a put of an existing primary key must raise")
    assert_strs(text_col(_get_item[T](db, reactor, "a"), String("note")), strs("first"), "first row kept")


def check_delete_by_key[T: NeutralTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var n = db.delete_by_key[Rt](reactor, String(ITEMS), String("id"), DbValue.text(String("a")))
    assert_equal(n, UInt64(1), "delete_by_key rows_affected")
    var again = db.delete_by_key[Rt](reactor, String(ITEMS), String("id"), DbValue.text(String("a")))
    assert_equal(again, UInt64(0), "delete_by_key of an absent key affects 0")
    assert_strs(_ids_where[T](db, reactor, Filter.none()), strs("b", "c", "d"), "the other rows remain")


def check_query_rows_filter_order_limit[T: NeutralTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var o1 = Filter.just(Pred.eq(String("owner"), DbValue.text(String("o1"))))
    var asc = List[Order]()
    asc.append(Order.asc(String("created_at")))
    var rows = db.query_rows[Rt](reactor, String(ITEMS), strs("id", "created_at"), o1, asc, _no_limit())
    assert_strs(text_col(rows, String("id")), strs("a", "d", "b"), "owner=o1 by created_at")
    assert_equal(rows.column_count(), 2, "query_rows projects cols")
    var lim = db.query_rows[Rt](
        reactor, String(ITEMS), strs("id"), o1, asc, Optional[UInt32](UInt32(2))
    )
    assert_strs(text_col(lim, String("id")), strs("a", "d"), "limit 2 keeps the first two")
    var desc = List[Order]()
    desc.append(Order.descending(String("created_at")))
    var all = db.query_rows[Rt](reactor, String(ITEMS), strs("id"), Filter.none(), desc, _no_limit())
    assert_strs(text_col(all, String("id")), strs("b", "d", "c", "a"), "no filter, created_at DESC")
    var nobody = Filter.just(Pred.eq(String("owner"), DbValue.text(String("nobody"))))
    assert_equal(
        db.query_rows[Rt](reactor, String(ITEMS), strs("id"), nobody, asc, _no_limit()).__len__(),
        0,
        "a filter matching nothing yields no rows",
    )


def check_query_rows_ranges[T: NeutralTarget](mut t: T) raises:
    """LT, LE and GTE on an integer column compare numerically."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var v = DbValue.int8(30)
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.lt(String("created_at"), v.copy()))), strs("a", "c"), "created_at < 30")
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.le(String("created_at"), v.copy()))), strs("a", "c", "d"), "created_at <= 30")
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.gte(String("created_at"), v.copy()))), strs("b", "d"), "created_at >= 30")
    # 9 < 10 numerically but not as text: a value compared as text fails here.
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.lt(String("created_at"), DbValue.int8(9)))), List[String](), "created_at < 9")


def check_query_rows_null_preds[T: NeutralTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.is_null(String("note")))), strs("a", "c"), "note IS NULL")
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.is_not_null(String("note")))), strs("b", "d"), "note IS NOT NULL")


def check_query_rows_in[T: NeutralTarget](mut t: T) raises:
    """IN with bound values, and with trusted literals."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var ids = List[DbValue]()
    ids.append(DbValue.text(String("a")))
    ids.append(DbValue.text(String("c")))
    ids.append(DbValue.text(String("zzz")))
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.in_list(String("id"), ids^))), strs("a", "c"), "id IN (a, c, zzz)")
    var lits = List[DbValue]()
    lits.append(DbValue.int8(10))
    lits.append(DbValue.int8(40))
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.in_literals(String("created_at"), lits^))), strs("a", "b"), "created_at IN (10, 40)")


def check_query_rows_ne[T: NeutralTarget](mut t: T) raises:
    """PRED_NE is IS DISTINCT FROM: a NULL column is distinct from any value
    (komira_db/neutral_ops.mojo)."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.ne(String("note"), DbValue.text(String("x"))))), strs("a", "c", "d"), "note IS DISTINCT FROM 'x'")


def check_query_rows_locked[T: NeutralTarget](mut t: T) raises:
    """query_rows_locked reads what query_rows reads (the lock is a hint)."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var asc = List[Order]()
    asc.append(Order.asc(String("created_at")))
    var rows = db.query_rows_locked[Rt](
        reactor, String(ITEMS), strs("id"), Filter.just(Pred.eq(String("owner"), DbValue.text(String("o1")))), asc
    )
    assert_strs(text_col(rows, String("id")), strs("a", "d", "b"), "locked read, owner=o1 by created_at")


def _guard_a_v(version: Int64) -> Filter:
    var p = List[Pred]()
    p.append(Pred.eq(String("id"), DbValue.text(String("a"))))
    p.append(Pred.eq(String("version"), DbValue.int8(version)))
    return Filter.all_of(p^)


def check_conditional_update_cas[T: NeutralTarget](mut t: T) raises:
    """A guard that holds updates the row, bumps the version by 1 and stamps
    the now column, returning 1; a stale guard returns 0 and writes nothing."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var ups = List[DbColVal]()
    ups.append(DbColVal.bind(String("phase"), DbValue.text(String("RUN"))))
    var n = db.conditional_update[Rt](
        reactor, String(ITEMS), _guard_a_v(1), ups, False, Optional[String](String("version")), strs("updated_at")
    )
    assert_equal(n, UInt64(1), "a guard that holds updates one row")
    var a = _get_item[T](db, reactor, "a")
    assert_strs(text_col(a, String("phase")), strs("RUN"), "phase set")
    assert_strs(text_col(a, String("version")), strs("2"), "version bumped by 1")
    assert_true(now_micros(a, String("updated_at")) > 0, "now column stamped after the epoch")
    var stale = db.conditional_update[Rt](
        reactor, String(ITEMS), _guard_a_v(1), ups, False, Optional[String](String("version")), List[String]()
    )
    assert_equal(stale, UInt64(0), "a stale version guard updates nothing")
    var a2 = _get_item[T](db, reactor, "a")
    assert_strs(text_col(a2, String("version")), strs("2"), "stale guard left the version")
    var other = db.conditional_update[Rt](
        reactor, String(ITEMS), _by_id("zzz"), ups, False, Optional[String](), List[String]()
    )
    assert_equal(other, UInt64(0), "a guard on an absent row updates nothing")
    assert_strs(text_col(_get_item[T](db, reactor, "b"), String("phase")), strs("NEW"), "rows outside the guard untouched")


def _set_note[
    T: NeutralTarget
](mut db: T.DB, mut reactor: Reactor[Rt.Sink], u: DbColVal, coalesce: Bool) raises -> String:
    var ups = List[DbColVal]()
    ups.append(u.copy())
    var n = db.conditional_update[Rt](
        reactor, String(ITEMS), _by_id("b"), ups, coalesce, Optional[String](), List[String]()
    )
    assert_equal(n, UInt64(1), "the guard on b holds")
    return text_col(_get_item[T](db, reactor, "b"), String("note"))[0]


def check_conditional_update_coalesce[T: NeutralTarget](mut t: T) raises:
    """`coalesce=True` makes a plain bind COALESCE($n, col): a NULL leaves the
    column; a per-column DbColVal.coalesce does the same with the flag off; a
    plain bind with the flag off writes the NULL."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var null_text = DbValue.null(LOGICAL_TEXT)
    assert_equal(_set_note[T](db, reactor, DbColVal.bind(String("note"), null_text.copy()), True), String("x"), "coalesce=True: NULL bind leaves the column")
    assert_equal(_set_note[T](db, reactor, DbColVal.coalesce(String("note"), null_text.copy()), False), String("x"), "DbColVal.coalesce: NULL leaves the column")
    assert_equal(_set_note[T](db, reactor, DbColVal.coalesce(String("note"), DbValue.text(String("z"))), False), String("z"), "DbColVal.coalesce: a value is written")
    assert_equal(_set_note[T](db, reactor, DbColVal.bind(String("note"), null_text.copy()), False), String("<NULL>"), "coalesce=False: NULL bind writes NULL")


def check_conditional_update_multi_row[T: NeutralTarget](mut t: T) raises:
    """Every row the guard matches is updated and counted; a PRED_NE guard
    reaches the NULL rows."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var p = List[Pred]()
    p.append(Pred.eq(String("owner"), DbValue.text(String("o1"))))
    p.append(Pred.ne(String("note"), DbValue.text(String("x"))))
    var ups = List[DbColVal]()
    ups.append(DbColVal.bind(String("phase"), DbValue.text(String("SKIP"))))
    var n = db.conditional_update[Rt](
        reactor, String(ITEMS), Filter.all_of(p^), ups, False, Optional[String](), List[String]()
    )
    assert_equal(n, UInt64(2), "owner=o1 AND note IS DISTINCT FROM 'x' matches a and d")
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.eq(String("phase"), DbValue.text(String("SKIP"))))), strs("a", "d"), "a and d updated")
    var ups2 = List[DbColVal]()
    ups2.append(DbColVal.bind(String("phase"), DbValue.text(String("DONE"))))
    var o1 = Filter.just(Pred.eq(String("owner"), DbValue.text(String("o1"))))
    var m = db.conditional_update[Rt](reactor, String(ITEMS), o1, ups2, False, Optional[String](), List[String]())
    assert_equal(m, UInt64(3), "owner=o1 matches three rows")
    assert_strs(_ids_where[T](db, reactor, Filter.just(Pred.eq(String("phase"), DbValue.text(String("DONE"))))), strs("a", "b", "d"), "all three updated")


def check_conditional_update_coalesce_multi_row[T: NeutralTarget](mut t: T) raises:
    """`coalesce=True` on a guard that is not the key (the multi-row update,
    a separate path from the keyed one on a document backend): every matched
    row takes the bound value and keeps its column where the bind is NULL."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var ups = List[DbColVal]()
    ups.append(DbColVal.bind(String("note"), DbValue.null(LOGICAL_TEXT)))
    ups.append(DbColVal.bind(String("phase"), DbValue.text(String("M"))))
    var o1 = Filter.just(Pred.eq(String("owner"), DbValue.text(String("o1"))))
    var n = db.conditional_update[Rt](reactor, String(ITEMS), o1, ups, True, Optional[String](), List[String]())
    assert_equal(n, UInt64(3), "owner=o1 matches three rows")
    var rows = db.query_rows[Rt](reactor, String(ITEMS), strs("id", "phase", "note"), o1.copy(), _asc_created(), _no_limit())
    assert_strs(text_col(rows, String("phase")), strs("M", "M", "M"), "the non-NULL bind is written to every row")
    assert_strs(text_col(rows, String("note")), strs("<NULL>", "y", "x"), "coalesce=True: each row keeps its note")


def _asc_created() -> List[Order]:
    var o = List[Order]()
    o.append(Order.asc(String("created_at")))
    return o^


def check_delete_where[T: NeutralTarget](mut t: T) raises:
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    _seed4[T](db, reactor)
    var o1 = Filter.just(Pred.eq(String("owner"), DbValue.text(String("o1"))))
    assert_equal(db.delete_where[Rt](reactor, String(ITEMS), o1.copy()), UInt64(3), "delete_where owner=o1")
    assert_equal(db.delete_where[Rt](reactor, String(ITEMS), o1.copy()), UInt64(0), "delete_where again deletes 0")
    assert_strs(_ids_where[T](db, reactor, Filter.none()), strs("c"), "c remains")


def check_create_if_absent[T: NeutralTarget](mut t: T) raises:
    """True when we inserted; False when the key is taken, and the first row
    stands."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var key = DbValue.text(String("k1"))
    var won = db.create_if_absent[Rt](reactor, String(ITEMS), String("id"), key.copy(), item_cols(), item_row("k1", "o1", "NEW", 1, a_note("first"), 10))
    assert_true(won, "the first create wins")
    var lost = db.create_if_absent[Rt](reactor, String(ITEMS), String("id"), key.copy(), item_cols(), item_row("k1", "o2", "NEW", 1, a_note("second"), 20))
    assert_false(lost, "a second create of the same key loses")
    var row = _get_item[T](db, reactor, "k1")
    assert_equal(row.__len__(), 1, "one row for the key")
    assert_strs(text_col(row, String("note")), strs("first"), "the winner's row stands")


def _pair(a: StaticString, b: StaticString, v: Int64) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(String(a)))
    out.append(DbValue.text(String(b)))
    out.append(DbValue.int8(v))
    return out^


def check_create_if_absent_composite[T: NeutralTarget](mut t: T) raises:
    """The key is the tuple: the same (a, b) loses, a different tuple wins,
    including two that concatenate alike."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var cc = strs("a", "b")
    var cols = strs("a", "b", "v")
    var table = String(PAIRS)
    assert_true(db.create_if_absent_composite[Rt](reactor, table, cc, cols, _pair("x", "y", 1)), "(x, y) wins")
    assert_false(db.create_if_absent_composite[Rt](reactor, table, cc, cols, _pair("x", "y", 2)), "(x, y) again loses")
    assert_true(db.create_if_absent_composite[Rt](reactor, table, cc, cols, _pair("x", "z", 3)), "(x, z) wins")
    assert_true(db.create_if_absent_composite[Rt](reactor, table, cc, cols, _pair("x~y", "z", 4)), "(x~y, z) wins")
    assert_true(db.create_if_absent_composite[Rt](reactor, table, cc, cols, _pair("x", "y~z", 5)), "(x, y~z) wins")
    var rows = db.query_rows[Rt](
        reactor, table, strs("v"), Filter.just(Pred.eq(String("a"), DbValue.text(String("x")))), List[Order](), _no_limit()
    )
    assert_strs(sorted_strs(text_col(rows, String("v"))), strs("1", "3", "5"), "a=x rows keep their first values")


def check_claim_rows[T: NeutralTarget](mut t: T) raises:
    """claim_rows moves up to n rows from_phase -> to_phase, oldest
    created_at first, applies `extra`, bumps the version, stamps now_cols,
    and returns them; claimed rows are not claimed again."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var c = item_cols()
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("p1", "o1", "PENDING", 1, no_note(), 30))
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("p2", "o1", "PENDING", 1, no_note(), 10))
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("p3", "o1", "PENDING", 1, no_note(), 20))
    _ = db.put[Rt](reactor, String(ITEMS), c, item_row("q", "o1", "NEW", 1, no_note(), 5))
    var extra = List[DbColVal]()
    extra.append(DbColVal.bind(String("note"), DbValue.text(String("w1"))))
    var order = List[Order]()
    order.append(Order.asc(String("created_at")))
    var claimed = db.claim_rows[Rt](
        reactor, String(ITEMS), 2, Filter.none(), order, String("phase"), String("PENDING"), String("CLAIMED"),
        extra, PodNameMinter(), Optional[String](String("version")), strs("updated_at"),
    )
    assert_equal(claimed.__len__(), 2, "claim n=2 returns two rows")
    assert_strs(sorted_strs(text_col(claimed, String("id"))), strs("p2", "p3"), "the two oldest are claimed")
    assert_strs(text_col(claimed, String("phase")), strs("CLAIMED", "CLAIMED"), "returned rows carry to_phase")
    var p2 = _get_item[T](db, reactor, "p2")
    assert_strs(text_col(p2, String("phase")), strs("CLAIMED"), "p2 persisted CLAIMED")
    assert_strs(text_col(p2, String("version")), strs("2"), "p2 version bumped")
    assert_strs(text_col(p2, String("note")), strs("w1"), "extra applied")
    assert_true(now_micros(p2, String("updated_at")) > 0, "now column stamped after the epoch")
    assert_strs(text_col(_get_item[T](db, reactor, "p1"), String("phase")), strs("PENDING"), "p1 not claimed")
    assert_strs(text_col(_get_item[T](db, reactor, "q"), String("phase")), strs("NEW"), "a row in another phase is never claimed")
    var rest = db.claim_rows[Rt](
        reactor, String(ITEMS), 5, Filter.none(), order, String("phase"), String("PENDING"), String("CLAIMED"),
        List[DbColVal](), PodNameMinter(), Optional[String](String("version")), List[String](),
    )
    assert_strs(text_col(rest, String("id")), strs("p1"), "the second claim takes only what is left")
    var none = db.claim_rows[Rt](
        reactor, String(ITEMS), 5, Filter.none(), order, String("phase"), String("PENDING"), String("CLAIMED"),
        List[DbColVal](), PodNameMinter(), Optional[String](String("version")), List[String](),
    )
    assert_equal(none.__len__(), 0, "nothing left to claim")


def check_tx_rollback_undoes_create[T: NeutralTarget](mut t: T) raises:
    """begin, put, create_if_absent, rollback: neither row exists."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    db.begin[Rt](reactor)
    _ = db.put[Rt](reactor, String(ITEMS), item_cols(), item_row("a", "o1", "NEW", 1, no_note(), 10))
    _ = db.create_if_absent[Rt](reactor, String(ITEMS), String("id"), DbValue.text(String("b")), item_cols(), item_row("b", "o1", "NEW", 1, no_note(), 20))
    db.rollback[Rt](reactor)
    assert_strs(_ids_where[T](db, reactor, Filter.none()), List[String](), "rolled-back creates are gone")


def check_tx_commit_keeps[T: NeutralTarget](mut t: T) raises:
    """begin, put, commit: the row stands, and a later transaction commits
    on top of it."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    db.begin[Rt](reactor)
    _ = db.put[Rt](reactor, String(ITEMS), item_cols(), item_row("a", "o1", "NEW", 1, no_note(), 10))
    db.commit[Rt](reactor)
    db.begin[Rt](reactor)
    _ = db.put[Rt](reactor, String(ITEMS), item_cols(), item_row("b", "o1", "NEW", 1, no_note(), 20))
    db.commit[Rt](reactor)
    assert_strs(_ids_where[T](db, reactor, Filter.none()), strs("a", "b"), "committed rows stand")
