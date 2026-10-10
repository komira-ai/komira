# =============================================================================
# komira_chat_store/ops.mojo -- small builders over komira_db's neutral ops,
#   shared by the store's modules. Not exported by the package.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbRows, DbValue, Filter, Order, Pred

from .records import ChatEvent
from .keys import join_ids


@always_inline
def txt(s: String) -> DbValue:
    return DbValue.text(s)


@always_inline
def i64(v: Int64) -> DbValue:
    return DbValue.int8(v)


@always_inline
def flag(v: Bool) -> DbValue:
    return DbValue.int8(Int64(1) if v else Int64(0))


@always_inline
def eq(col: StaticString, var v: DbValue) -> Pred:
    return Pred.eq(String(col), v^)


def all_of(var a: Pred) -> Filter:
    return Filter.just(a^)


def all_of(var a: Pred, var b: Pred) -> Filter:
    var ps = List[Pred]()
    ps.append(a^)
    ps.append(b^)
    return Filter.all_of(ps^)


def all_of(var a: Pred, var b: Pred, var c: Pred) -> Filter:
    var ps = List[Pred]()
    ps.append(a^)
    ps.append(b^)
    ps.append(c^)
    return Filter.all_of(ps^)


def all_of(var a: Pred, var b: Pred, var c: Pred, var d: Pred) -> Filter:
    var ps = List[Pred]()
    ps.append(a^)
    ps.append(b^)
    ps.append(c^)
    ps.append(d^)
    return Filter.all_of(ps^)


def asc(col: StaticString) -> List[Order]:
    var o = List[Order]()
    o.append(Order.asc_explicit(String(col)))
    return o^


def desc(col: StaticString) -> List[Order]:
    var o = List[Order]()
    o.append(Order.descending(String(col)))
    return o^


def no_order() -> List[Order]:
    return List[Order]()


def limit(n: Int) -> Optional[UInt32]:
    return Optional[UInt32](UInt32(n))


def no_limit() -> Optional[UInt32]:
    return Optional[UInt32]()


def sets(var a: DbColVal) -> List[DbColVal]:
    var out = List[DbColVal]()
    out.append(a^)
    return out^


def sets(var a: DbColVal, var b: DbColVal) -> List[DbColVal]:
    var out = List[DbColVal]()
    out.append(a^)
    out.append(b^)
    return out^


def sets(var a: DbColVal, var b: DbColVal, var c: DbColVal) -> List[DbColVal]:
    var out = List[DbColVal]()
    out.append(a^)
    out.append(b^)
    out.append(c^)
    return out^


@always_inline
def set_to(col: StaticString, var v: DbValue) -> DbColVal:
    return DbColVal.bind(String(col), v^)


def update[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    guard: Filter,
    updates: List[DbColVal],
) raises -> Int:
    """`UPDATE <table> SET <updates> WHERE <guard>`; the rows it changed."""
    return Int(
        db.conditional_update[RT](
            reactor,
            String(table),
            guard,
            updates,
            False,
            Optional[String](),
            List[String](),
        )
    )


def update_all[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    guard: Filter,
    updates: List[DbColVal],
) raises -> Int:
    """`update` repeated until it changes nothing, for a guard the update
    itself falsifies: a document store changes at most a bounded batch of
    rows per call. Returns the total changed."""
    var total = 0
    while True:
        var n = update[RT, DB](db, reactor, table, guard, updates)
        if n == 0:
            return total
        total += n


def delete_all[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], table: StaticString, filter: Filter
) raises -> Int:
    """`DELETE FROM <table> WHERE <filter>`, repeated until nothing is left
    (a document store deletes a bounded batch per call). Returns the total."""
    var total = 0
    while True:
        var n = Int(db.delete_where[RT](reactor, String(table), filter))
        if n == 0:
            return total
        total += n


def select[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    cols: List[String],
    filter: Filter,
    order: List[Order],
    lim: Optional[UInt32],
) raises -> DbRows:
    return db.query_rows[RT](reactor, String(table), cols, filter, order, lim)


def event_values(ev: ChatEvent, last_edit_seq: Int64) -> List[DbValue]:
    """`ev` as a chat_events row, in `event_cols()` order."""
    var v = List[DbValue]()
    v.append(txt(ev.channel_id))
    v.append(i64(ev.seq))
    v.append(i64(Int64(ev.kind)))
    v.append(txt(ev.sender_user_id))
    v.append(txt(ev.body))
    v.append(i64(ev.thread_root_seq))
    v.append(i64(ev.target_seq))
    v.append(txt(ev.client_msg_id))
    v.append(txt(join_ids(ev.mention_user_ids)))
    v.append(flag(ev.mentions_channel))
    v.append(txt(join_ids(ev.file_ids)))
    v.append(i64(ev.created_at_ms))
    v.append(flag(ev.edited))
    v.append(flag(ev.deleted))
    v.append(i64(last_edit_seq))
    return v^


def event_key_cols() -> List[String]:
    """The columns a chat_events row is unique on."""
    var c = List[String]()
    c.append(String("channel_id"))
    c.append(String("seq"))
    return c^


def chat_err(var msg: String) -> Error:
    return Error(String("komira_chat_store: ") + msg)


# The largest page size a pager accepts.
comptime MAX_PAGE_SIZE: Int = 10_000


def require_page_size(n: Int, name: StaticString) raises:
    """Refuse a page size below 1 or above `MAX_PAGE_SIZE`. A page below 1
    holds nothing, so following it never moves on. A pager reads one row
    more than its page through a `UInt32` limit, which wraps for a size
    near or above 2^32 (`Int.MAX + 1` wraps and reads as a limit of 0)."""
    if n < 1:
        raise chat_err(
            String(name) + String(" must be at least 1, got ") + String(n)
        )
    if n > MAX_PAGE_SIZE:
        raise chat_err(
            String(name)
            + String(" must be at most ")
            + String(MAX_PAGE_SIZE)
            + String(", got ")
            + String(n)
        )
