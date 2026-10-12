# =============================================================================
# komira_crm/core.mojo -- what every store operation shares: the feed
#   counter, key tables, compare-and-set and ordering.
# =============================================================================
#
# THE WRITE ORDER (docs/design/contacts_and_crm.md, "How is uniqueness
# enforced?"). A write runs inside begin/commit and rolls back on any
# refusal. For each row it writes it first takes a number from the feed
# counter (`next_modseq`), then writes the row carrying that number, then,
# for a row a key table guards, creates the key row naming it
# (`claim_key`): the write commits when the key create wins and rolls back
# when it loses. A key row is never deleted or moved to make room. On a
# document backend, where each operation commits alone and a rollback
# deletes only the documents created since `begin`, a write that stops
# between its row and its key leaves a row no key names; every read of a
# guarded row checks that its key names it (`key_holder`) and skips it
# otherwise, so that row is never returned and the next create of the same
# tuple wins the key.
#
# THE FEED COUNTER. `next_modseq` bumps the one `crm_feed` row and reads the
# new value back, in the write's transaction, so every row a write changes
# gets a number of its own. On SQLite the transaction holds the database's
# write lock (BEGIN IMMEDIATE), so writes commit in number order.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbRow, DbValue, Filter, Order, Pred

from komira_crm.errors import ERR_NOT_INITIALIZED, version_conflict
from komira_crm.rows import int8, text
from komira_crm.schema import FEED, FEED_ROW_ID, feed_cols, strs


def no_limit() -> Optional[UInt32]:
    return Optional[UInt32]()


def by_id(id: String) -> Filter:
    return Filter.just(Pred.eq(String("id"), text(id)))


def next_modseq[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink]) raises -> UInt64:
    """Take the next feed number: bump the counter row and read it back, in
    the caller's transaction."""
    var n = db.conditional_update[RT](
        reactor,
        String(FEED),
        by_id(String(FEED_ROW_ID)),
        List[DbColVal](),
        False,
        Optional[String](String("modseq")),
        List[String](),
    )
    if n != 1:
        raise Error(String(ERR_NOT_INITIALIZED))
    return feed_counter[DB, RT](db, reactor)


def feed_counter[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink]) raises -> UInt64:
    """The last feed number taken."""
    var got = db.get_by_key[RT](reactor, String(FEED), feed_cols(), String("id"), text(String(FEED_ROW_ID)))
    if not got:
        raise Error(String(ERR_NOT_INITIALIZED))
    return UInt64(got.take().get_int8(1))


def load[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], table: StaticString, cols: List[String], id: String) raises -> Optional[
    DbRow
]:
    return db.get_by_key[RT](reactor, String(table), cols, String("id"), text(id))


def key_filter(a: StaticString, a_val: String, b: StaticString, b_val: String) -> Filter:
    var preds = List[Pred]()
    preds.append(Pred.eq(String(a), text(a_val)))
    preds.append(Pred.eq(String(b), text(b_val)))
    return Filter.all_of(preds^)


def key_holder[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    a: StaticString,
    a_val: String,
    b: StaticString,
    b_val: String,
    holder: StaticString,
) raises -> String:
    """The id the key row (a, b) of `table` names; empty when there is none."""
    var rows = db.query_rows[RT](
        reactor, String(table), strs(holder), key_filter(a, a_val, b, b_val), List[Order](), no_limit()
    )
    if rows.__len__() == 0:
        return String()
    return rows.row(0).get_text(0)


def claim_key[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    a: StaticString,
    a_val: String,
    b: StaticString,
    b_val: String,
    holder: StaticString,
    holder_val: String,
) raises -> Bool:
    """Create the key row (a, b) -> holder; True when this call created it."""
    var vals = List[DbValue]()
    vals.append(text(a_val))
    vals.append(text(b_val))
    vals.append(text(holder_val))
    return db.create_if_absent_composite[RT](reactor, String(table), strs(a, b), strs(a, b, holder), vals^)


def cas[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    id: String,
    expected_version: UInt64,
    var updates: List[DbColVal],
) raises:
    """Apply `updates` and bump `version`, only to row `id` at
    `expected_version`; a miss is a version conflict."""
    var guard = List[Pred]()
    guard.append(Pred.eq(String("id"), text(id)))
    guard.append(Pred.eq(String("version"), int8(expected_version)))
    var n = db.conditional_update[RT](
        reactor,
        String(table),
        Filter.all_of(guard^),
        updates^,
        False,
        Optional[String](String("version")),
        List[String](),
    )
    if n != 1:
        raise version_conflict()


def row_updates(cols: List[String], vals: List[DbValue], var keep: List[String]) -> List[DbColVal]:
    """A SET of every column of a row but `id`, `version` and those in
    `keep`, to the row's values."""
    keep.append(String("id"))
    keep.append(String("version"))
    var out = List[DbColVal]()
    for i in range(len(cols)):
        var kept = False
        for k in keep:
            if k == cols[i]:
                kept = True
        if not kept:
            out.append(DbColVal.bind(String(cols[i]), vals[i].copy()))
    return out^


def order_of(keys: List[String]) -> List[Int]:
    """The indices of `keys` in ascending key order (stable; lists are short)."""
    var idx = List[Int]()
    for i in range(len(keys)):
        idx.append(i)
    for i in range(1, len(idx)):
        var j = i
        while j > 0 and keys[idx[j - 1]] > keys[idx[j]]:
            var t = idx[j - 1]
            idx[j - 1] = idx[j]
            idx[j] = t
            j -= 1
    return idx^


def padded(v: UInt64) -> String:
    """`v` as 20 decimal digits, so text order is number order."""
    var s = String(v)
    var out = String()
    for _ in range(20 - s.byte_length()):
        out += "0"
    return out + s
