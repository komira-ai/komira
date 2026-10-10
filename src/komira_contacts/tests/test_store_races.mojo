# =============================================================================
# test_store_races.mojo -- ContactsStore when a peer writes between its read
#   and its guarded write.
# =============================================================================
#
# The store reads, then writes under a guard (a compare-and-set), so a peer
# that commits in between makes the guarded write match nothing. One store on
# one SQLite connection never interleaves, so `RacingDb` plays the peer: it
# delegates every call to a SqliteDatabase and, armed once, applies the peer's
# write just before the store's own guarded write. Each check would fail on
# the defect its comment names.
#
#   book_written   a peer advances the book's modseq before create_card's
#                  CAS: the create is refused with the version-conflict text
#                  and leaves no card and no uid key. Catches a book CAS whose
#                  miss is ignored (two writes at one modseq).
#   key_released   create_card's uid claim loses, then the peer releases the
#                  key before the store reads it: refused with the uid-taken
#                  text. Catches reading row 0 of an empty result.
#   key_taken      a uid key names no card (stale); the peer takes it over
#                  before the store does: refused with the uid-taken text,
#                  and the stale key is still there for the next create.
#                  Catches a takeover whose guard miss is ignored (two cards
#                  holding one uid).
#   delete_book_written  a peer advances the book's modseq after
#                  delete_card wrote its tombstone and released the uid key:
#                  refused with the version-conflict text, the card is still
#                  listed and its uid key still held. Catches a failed delete
#                  that commits instead of rolling back.
#   update_book_written  the same peer after update_card's card write: refused,
#                  and the card keeps its version and modseq. Catches the
#                  same defect in update_card.
#   book_put_fails  create_book of a default wins the default claim, then its
#                  book write fails: the error propagates, no book is listed,
#                  and the next default create for the owner succeeds.
#                  Catches a failed create_book that commits (the claim kept,
#                  naming no book) or skips the rollback. No claim row may be
#                  left: it is read back directly, since the next create
#                  would also take over a claim naming no book.
#   default_released  create_book's default claim loses, then the peer
#                  removes the claim before the store reads it: refused with
#                  the default-taken text, and the claim is still held.
#                  Catches reading a claim row that is not there.
#   default_moved  a default claim names no book (stale); the peer takes it
#                  over before the store does: refused with the default-taken
#                  text, no book written, and the next default create takes
#                  the claim. Catches a takeover whose guard miss is ignored
#                  (two books holding one owner's default).
# =============================================================================

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_db import Database, DbColVal, DbRow, DbRows, DbValue, Filter, Order, PodNameMinter, Pred
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json
from komira_contacts_proto.contacts import BookKind, Card

from komira_contacts import (
    BOOKS,
    CARD_UIDS,
    Caller,
    ContactsStore,
    DEFAULT_BOOKS,
    ERR_DEFAULT_TAKEN,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
    sqlite_schema,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime OK = "ok"
comptime NO_SUCH_ID = "00000000-0000-7000-8000-000000000000"

comptime NO_RACE = 0
comptime BOOK_WRITTEN = 1
comptime KEY_RELEASED = 2
comptime KEY_TAKEN = 3
comptime BOOK_PUT_FAILS = 4
comptime DEFAULT_RELEASED = 5
comptime DEFAULT_MOVED = 6
comptime PUT_FAILED = "racing db: book write failed"


def _key(book_id: String, uid: String) -> Filter:
    var key = List[Pred]()
    key.append(Pred.eq(String("address_book_id"), DbValue.text(String(book_id))))
    key.append(Pred.eq(String("uid"), DbValue.text(String(uid))))
    return Filter.all_of(key^)


def _owner(owner: String) -> Filter:
    return Filter.just(Pred.eq(String("owner"), DbValue.text(String(owner))))


struct RacingDb(Database, Movable, Deinitable):
    """SQLite, plus one armed peer write (`race`, on `book_id` / `uid`),
    applied once just before the store's guarded write it races."""

    var inner: SqliteDatabase
    var race: Int
    var book_id: String
    var uid: String

    def __init__(out self, var inner: SqliteDatabase):
        self.inner = inner^
        self.race = NO_RACE
        self.book_id = String()
        self.uid = String()

    def arm(mut self, race: Int, book_id: String, uid: String):
        self.race = race
        self.book_id = String(book_id)
        self.uid = String(uid)

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.begin[RT](reactor)

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.commit[RT](reactor)

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.rollback[RT](reactor)

    def get_by_key[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], key_col: String, key_val: DbValue
    ) raises -> Optional[DbRow]:
        return self.inner.get_by_key[RT](reactor, table, cols, key_col, key_val)

    def put[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], vals: List[DbValue]) raises -> UInt64:
        if self.race == BOOK_PUT_FAILS and table == String(BOOKS):
            # The book write fails after the default claim was written.
            self.race = NO_RACE
            raise Error(String(PUT_FAILED))
        return self.inner.put[RT](reactor, table, cols, vals)

    def delete_by_key[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, key_col: String, key_val: DbValue) raises -> UInt64:
        return self.inner.delete_by_key[RT](reactor, table, key_col, key_val)

    def query_rows[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        return self.inner.query_rows[RT](reactor, table, cols, filter, order, limit)

    def query_rows_locked[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], filter: Filter, order: List[Order]
    ) raises -> DbRows:
        return self.inner.query_rows_locked[RT](reactor, table, cols, filter, order)

    def conditional_update[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        guard: Filter,
        updates: List[DbColVal],
        coalesce: Bool,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> UInt64:
        if self.race == BOOK_WRITTEN and table == String(BOOKS):
            # The peer's own card write advanced the book.
            self.race = NO_RACE
            var peer = List[DbColVal]()
            peer.append(DbColVal.bind(String("modseq"), DbValue.int8(Int64(99))))
            _ = self.inner.conditional_update[RT](
                reactor,
                table,
                Filter.just(Pred.eq(String("id"), DbValue.text(String(self.book_id)))),
                peer^,
                False,
                Optional[String](),
                List[String](),
            )
        elif self.race == KEY_TAKEN and table == String(CARD_UIDS):
            # The peer's create took the stale key first.
            self.race = NO_RACE
            var peer = List[DbColVal]()
            peer.append(DbColVal.bind(String("card_id"), DbValue.text(String("peer-card"))))
            _ = self.inner.conditional_update[RT](
                reactor, table, _key(self.book_id, self.uid), peer^, False, Optional[String](), List[String]()
            )
        elif self.race == DEFAULT_MOVED and table == String(DEFAULT_BOOKS):
            # The peer's default create took the stale claim first.
            self.race = NO_RACE
            var peer = List[DbColVal]()
            peer.append(DbColVal.bind(String("book_id"), DbValue.text(String("peer-book"))))
            _ = self.inner.conditional_update[RT](
                reactor, table, _owner(self.uid), peer^, False, Optional[String](), List[String]()
            )
        return self.inner.conditional_update[RT](
            reactor, table, guard, updates, coalesce, bump_version_col, now_cols
        )

    def delete_where[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, filter: Filter) raises -> UInt64:
        return self.inner.delete_where[RT](reactor, table, filter)

    def create_if_absent[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        var won = self.inner.create_if_absent[RT](reactor, table, unique_col, unique_val, cols, vals)
        if self.race == DEFAULT_RELEASED and table == String(DEFAULT_BOOKS) and not won:
            # The peer removed the claim the default create just lost to.
            self.race = NO_RACE
            _ = self.inner.delete_where[RT](reactor, table, _owner(self.uid))
        return won

    def create_if_absent_composite[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        var won = self.inner.create_if_absent_composite[RT](reactor, table, conflict_cols, cols, vals)
        if self.race == KEY_RELEASED and table == String(CARD_UIDS) and not won:
            # The peer's delete released the key the claim just lost to.
            self.race = NO_RACE
            _ = self.inner.delete_where[RT](reactor, table, _key(self.book_id, self.uid))
        return won

    def claim_rows[
        RT: Runtime,
    ](
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
        return self.inner.claim_rows[RT](
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


comptime Store = ContactsStore[RacingDb]


def _alice() -> Caller:
    return Caller(String("alice"), False)


def _uid_card(uid: StaticString) raises -> Card:
    return decode_json[Card](String('{"uid":"') + String(uid) + String('","name":{"full":"X"}}'))


def _store() raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var ddl = sqlite_schema()
    for i in range(len(ddl)):
        _ = db_blocking_execute(db, ddl[i], List[DbValue]())
    return Store(RacingDb(db^))


def _create(mut store: Store, mut reactor: Reactor[Rt.Sink], book_id: String, uid: StaticString) -> String:
    try:
        _ = store.create_card[Rt](reactor, _alice(), book_id, _uid_card(uid))
        return String(OK)
    except e:
        return String(e)


def _uids(mut store: Store, mut reactor: Reactor[Rt.Sink], book_id: String) raises -> String:
    var cards = store.list_cards[Rt](reactor, _alice(), book_id)
    var out = String()
    for i in range(len(cards)):
        if i > 0:
            out += ","
        out += cards[i].uid
    return out^


def check_book_written() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    store.database().arm(BOOK_WRITTEN, b.id, "a")
    assert_equal(_create(store, reactor, b.id, "a"), ERR_VERSION_CONFLICT, "the book moved under the create")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(_uids(store, reactor, b.id), "", "the refused create left no card")
    var c = store.create_card[Rt](reactor, _alice(), b.id, _uid_card("a"))
    assert_equal(c.modseq, UInt64(1), "and no uid key: the retry takes the uid")


def check_key_released() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    assert_equal(_create(store, reactor, b.id, "u"), OK)
    store.database().arm(KEY_RELEASED, b.id, "u")
    assert_equal(_create(store, reactor, b.id, "u"), ERR_UID_TAKEN, "the key went away under the create")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(_create(store, reactor, b.id, "u"), ERR_UID_TAKEN, "the rollback kept the key")
    assert_equal(_uids(store, reactor, b.id), "u")


def check_key_taken() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    # A uid key naming no card, as a create that stopped after its key leaves.
    var vals = List[DbValue]()
    vals.append(DbValue.text(String(b.id)))
    vals.append(DbValue.text(String("s")))
    vals.append(DbValue.text(String(NO_SUCH_ID)))
    var cols = List[String]()
    cols.append(String("address_book_id"))
    cols.append(String("uid"))
    cols.append(String("card_id"))
    _ = store.database().put[Rt](reactor, String(CARD_UIDS), cols^, vals^)
    store.database().arm(KEY_TAKEN, b.id, "s")
    assert_equal(_create(store, reactor, b.id, "s"), ERR_UID_TAKEN, "the peer took the stale key first")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(_uids(store, reactor, b.id), "", "the refused create left no card")
    assert_equal(_create(store, reactor, b.id, "s"), OK, "the stale key is still stale")


def check_delete_book_written() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    var c = store.create_card[Rt](reactor, _alice(), b.id, _uid_card("d"))
    store.database().arm(BOOK_WRITTEN, b.id, "d")
    var got = String(OK)
    try:
        _ = store.delete_card[Rt](reactor, _alice(), b.id, c.id, c.version)
    except e:
        got = String(e)
    assert_equal(got, ERR_VERSION_CONFLICT, "the book moved under the delete")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(_uids(store, reactor, b.id), "d", "the rollback undid the tombstone")
    assert_equal(_create(store, reactor, b.id, "d"), ERR_UID_TAKEN, "the rollback kept the uid key")


def check_update_book_written() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    var c = store.create_card[Rt](reactor, _alice(), b.id, _uid_card("p"))
    store.database().arm(BOOK_WRITTEN, b.id, "p")
    var got = String(OK)
    try:
        _ = store.update_card[Rt](reactor, _alice(), b.id, c.id, c.version, _uid_card("p"))
    except e:
        got = String(e)
    assert_equal(got, ERR_VERSION_CONFLICT, "the book moved under the update")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    var now = store.get_card[Rt](reactor, _alice(), b.id, c.id)
    assert_equal(now.version, c.version, "the rollback undid the card write")
    assert_equal(now.modseq, c.modseq, "and its modseq")


def check_book_put_fails() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    store.database().arm(BOOK_PUT_FAILS, "", "")
    var got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    except e:
        got = String(e)
    assert_equal(got, PUT_FAILED, "the book write failed after the default claim")
    assert_equal(store.database().race, NO_RACE, "the failing write ran")
    assert_equal(len(store.list_books[Rt](reactor, _alice())), 0, "the failed create left no book")
    assert_equal(_claim(store, reactor, "alice"), "", "the rollback removed the default claim")
    var home = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    assert_equal(home.is_default, True, "the rollback freed the default claim")


def _claim(mut store: Store, mut reactor: Reactor[Rt.Sink], owner: StaticString) raises -> String:
    """The book id the owner's default claim names; empty when there is none."""
    var cols = List[String]()
    cols.append(String("owner"))
    cols.append(String("book_id"))
    var got = store.database().get_by_key[Rt](
        reactor, String(DEFAULT_BOOKS), cols^, String("owner"), DbValue.text(String(owner))
    )
    if not got:
        return String()
    var row = got.take()
    return row.get_text(1)


def _plant_claim(mut store: Store, mut reactor: Reactor[Rt.Sink], owner: StaticString, book_id: StaticString) raises:
    """A default claim written directly, as a create_book that stopped after
    its claim leaves it."""
    var cols = List[String]()
    cols.append(String("owner"))
    cols.append(String("book_id"))
    var vals = List[DbValue]()
    vals.append(DbValue.text(String(owner)))
    vals.append(DbValue.text(String(book_id)))
    _ = store.database().put[Rt](reactor, String(DEFAULT_BOOKS), cols^, vals^)


def _err_default(mut store: Store, mut reactor: Reactor[Rt.Sink]) -> String:
    try:
        _ = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
        return String(OK)
    except e:
        return String(e)


def check_default_released() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var home = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    store.database().arm(DEFAULT_RELEASED, "", "alice")
    assert_equal(_err_default(store, reactor), ERR_DEFAULT_TAKEN, "the claim went away under the create")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(_claim(store, reactor, "alice"), home.id, "the rollback kept the claim")
    assert_equal(len(store.list_books[Rt](reactor, _alice())), 1, "the refused create left no book")


def check_default_moved() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _plant_claim(store, reactor, "alice", NO_SUCH_ID)
    store.database().arm(DEFAULT_MOVED, "", "alice")
    assert_equal(_err_default(store, reactor), ERR_DEFAULT_TAKEN, "the peer took the stale claim first")
    assert_equal(store.database().race, NO_RACE, "the peer wrote")
    assert_equal(len(store.list_books[Rt](reactor, _alice())), 0, "the refused create left no book")
    assert_equal(_claim(store, reactor, "alice"), NO_SUCH_ID, "the rollback undid the peer's move")
    var home = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    assert_equal(_claim(store, reactor, "alice"), home.id, "the stale claim is still stale: the next default takes it")


def main() raises:
    check_book_written()
    check_key_released()
    check_key_taken()
    check_delete_book_written()
    check_update_book_written()
    check_book_put_fails()
    check_default_released()
    check_default_moved()
    print("PASS komira_contacts test_store_races")
