# =============================================================================
# test_store_sqlite.mojo -- ContactsStore on komira_db_sqlite, from the
#   library's own tests.
# =============================================================================
#
# The store's full contract, on SQLite and Firestore, is
# //src/tests/conformance/komira_contacts_store_conformance. This test runs
# one pass through every store call on SQLite (`test_deps`), so the store's
# own package measures its lines: each check below would fail on the defect
# its comment names.
#
#   books      create (PERSONAL, default, SHARED by an admin), a second
#              default refused and rolled back, a SHARED default refused, an
#              empty name refused, get, list sorted by name
#   cards      create (a uid minted when empty), get, list, update (the
#              version bumped, an empty uid keeps the uid, a changed uid
#              refused), a stale version refused, delete (a tombstone not
#              found by id), the uid taken in its book only
#   feed       modseq per write and the change feed with the tombstone
#   stale key  a uid key naming no card is taken over by the next create
#   access     another subject gets the not-found text on a PERSONAL book;
#              a non-admin cannot write a SHARED book
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbValue
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase
from komira_proto_codec import decode_json
from komira_contacts_proto.contacts import BookKind, Card

from komira_contacts import (
    CARD_UIDS,
    Caller,
    ContactsStore,
    ERR_DEFAULT_TAKEN,
    ERR_FORBIDDEN,
    ERR_NOT_FOUND,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
    sqlite_schema,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = ContactsStore[SqliteDatabase]
comptime OK = "ok"
comptime NO_SUCH_ID = "00000000-0000-7000-8000-000000000000"


def _alice() -> Caller:
    return Caller(String("alice"), False)


def _bob() -> Caller:
    return Caller(String("bob"), False)


def _admin() -> Caller:
    return Caller(String("root"), True)


def _uid_card(uid: StaticString, full: StaticString) raises -> Card:
    return decode_json[Card](
        String('{"uid":"') + String(uid) + String('","name":{"full":"') + String(full) + String('"}}')
    )


def _store() raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var ddl = sqlite_schema()
    for i in range(len(ddl)):
        _ = db_blocking_execute(db, ddl[i], List[DbValue]())
    return Store(db^)


def _feed(mut store: Store, mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, since: UInt64) raises -> String:
    """The change feed as `uid@modseq` (a tombstone `uid@modseq-`), then
    `|<cursor>`."""
    var resp = store.changes[Rt](reactor, who, book_id, since)
    var out = String()
    for i in range(len(resp.changes)):
        if i > 0:
            out += ","
        ref c = resp.changes[i]
        out += c.uid + String("@") + String(c.modseq)
        if c.deleted:
            out += "-"
    out += String("|") + String(resp.modseq)
    return out^


def _uids(cards: List[Card]) -> String:
    var out = String()
    for i in range(len(cards)):
        if i > 0:
            out += ","
        out += cards[i].uid
    return out^


def _err_create(mut store: Store, mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, uid: StaticString) -> String:
    try:
        _ = store.create_card[Rt](reactor, who, book_id, _uid_card(uid, "X"))
        return String(OK)
    except e:
        return String(e)


def _err_book(mut store: Store, mut reactor: Reactor[Rt.Sink], who: Caller, kind: Int, name: StaticString, is_default: Bool) -> String:
    try:
        _ = store.create_book[Rt](reactor, who, kind, String(name), is_default)
        return String(OK)
    except e:
        return String(e)


def _err_get(mut store: Store, mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, card_id: String) -> String:
    try:
        _ = store.get_card[Rt](reactor, who, book_id, card_id)
        return String(OK)
    except e:
        return String(e)


def _err_update(
    mut store: Store, mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, card_id: String, version: UInt64, uid: StaticString
) -> String:
    try:
        _ = store.update_card[Rt](reactor, who, book_id, card_id, version, _uid_card(uid, "Upd"))
        return String(OK)
    except e:
        return String(e)


def check_books() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var home = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    assert_true(home.is_default)
    assert_equal(home.owner, "alice")
    # A second default is refused and leaves no book (the rollback).
    assert_equal(_err_book(store, reactor, _alice(), BookKind.PERSONAL, "Two", True), ERR_DEFAULT_TAKEN)
    assert_equal(
        _err_book(store, reactor, _admin(), BookKind.SHARED, "Team", True),
        "contacts: invalid is_default: only a PERSONAL book can be a default",
    )
    assert_equal(_err_book(store, reactor, _alice(), BookKind.PERSONAL, "", False), "contacts: invalid name: required")
    assert_equal(_err_book(store, reactor, _bob(), BookKind.SHARED, "Team", False), ERR_FORBIDDEN, "SHARED needs admin")
    var aux = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Aux", False)
    assert_false(aux.is_default)
    var team = store.create_book[Rt](reactor, _admin(), BookKind.SHARED, "Team", False)
    assert_equal(team.owner, "", "a SHARED book has no owner")
    var books = store.list_books[Rt](reactor, _alice())
    assert_equal(len(books), 3, "alice's two books and the shared one")
    assert_equal(books[0].name, "Aux", "sorted by kind, then name")
    assert_equal(books[1].name, "Main")
    assert_equal(books[2].name, "Team")
    assert_equal(len(store.list_books[Rt](reactor, _bob())), 1, "bob sees the shared book only")
    assert_equal(store.get_book[Rt](reactor, _alice(), home.id).name, "Main")
    # Another subject gets the text of an id that does not exist.
    assert_equal(_err_create(store, reactor, _bob(), home.id, "b"), ERR_NOT_FOUND, "bob writes alice's book")
    assert_equal(_err_create(store, reactor, _bob(), team.id, "b"), ERR_FORBIDDEN, "bob writes the shared book")


def check_cards_and_feed() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var al = _alice()
    var b = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "B", False)
    var other = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "Other", False)
    var a = store.create_card[Rt](reactor, al, b.id, _uid_card("a", "A"))
    assert_equal(a.version, UInt64(1))
    assert_equal(a.modseq, UInt64(1))
    var minted = store.create_card[Rt](reactor, al, b.id, decode_json[Card](String('{"name":{"full":"M"}}')))
    assert_equal(minted.uid, String("urn:uuid:") + minted.id, "an empty uid is minted from the id")
    # The uid is taken in its book only.
    assert_equal(_err_create(store, reactor, al, b.id, "a"), ERR_UID_TAKEN)
    var in_other = store.create_card[Rt](reactor, al, other.id, _uid_card("a", "A elsewhere"))
    assert_equal(in_other.modseq, UInt64(1), "each book counts on its own")
    # Update: the version CAS, an empty uid keeps the uid, a new uid is refused.
    var a2 = store.update_card[Rt](reactor, al, b.id, a.id, a.version, _uid_card("", "A2"))
    assert_equal(a2.uid, "a", "an empty uid keeps the uid")
    assert_equal(a2.version, UInt64(2))
    assert_equal(a2.modseq, UInt64(3))
    assert_equal(_err_update(store, reactor, al, b.id, a.id, UInt64(1), "a"), ERR_VERSION_CONFLICT)
    assert_equal(_err_update(store, reactor, al, b.id, a.id, UInt64(2), "z"), "contacts: invalid uid: cannot change")
    var got = store.get_card[Rt](reactor, al, b.id, a.id)
    assert_equal(got.name.value().full, "A2", "the refused updates changed nothing")
    # Delete leaves a tombstone: not found by id, not listed, in the feed.
    var gone = store.delete_card[Rt](reactor, al, b.id, minted.id, minted.version)
    assert_equal(gone, UInt64(4))
    assert_equal(_err_get(store, reactor, al, b.id, minted.id), ERR_NOT_FOUND, "get a deleted card")
    assert_equal(_uids(store.list_cards[Rt](reactor, al, b.id)), "a")
    var minted_uid = minted.uid
    assert_equal(
        _feed(store, reactor, al, b.id, UInt64(0)),
        String("a@3,") + minted_uid + String("@4-|4"),
        "the feed from the start",
    )
    assert_equal(_feed(store, reactor, al, b.id, UInt64(3)), String(minted_uid) + String("@4-|4"), "after the update")
    assert_equal(_feed(store, reactor, al, b.id, UInt64(4)), "|4", "at the cursor")
    assert_equal(store.get_book[Rt](reactor, al, b.id).modseq, UInt64(4), "the book's modseq is its latest write")
    # A card is looked up together with its book.
    assert_equal(_err_get(store, reactor, al, other.id, a.id), ERR_NOT_FOUND, "a card through another book")
    assert_equal(_err_get(store, reactor, _bob(), b.id, a.id), ERR_NOT_FOUND, "another subject")


def check_stale_key() raises:
    var store = _store()
    var rt = Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var al = _alice()
    var b = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "B", False)
    # A uid key naming no card, as a create that stopped after its key leaves.
    var cols = List[String]()
    cols.append(String("address_book_id"))
    cols.append(String("uid"))
    cols.append(String("card_id"))
    var conflict = List[String]()
    conflict.append(String("address_book_id"))
    conflict.append(String("uid"))
    var vals = List[DbValue]()
    vals.append(DbValue.text(String(b.id)))
    vals.append(DbValue.text(String("u-crash")))
    vals.append(DbValue.text(String(NO_SUCH_ID)))
    assert_true(store.database().create_if_absent_composite[Rt](reactor, String(CARD_UIDS), conflict^, cols^, vals^))
    var c = store.create_card[Rt](reactor, al, b.id, _uid_card("u-crash", "Crash"))
    assert_equal(c.uid, "u-crash", "a key naming no card does not hold the uid")
    assert_equal(_err_create(store, reactor, al, b.id, "u-crash"), ERR_UID_TAKEN, "the key holds the uid again")


def main() raises:
    check_books()
    check_cards_and_feed()
    check_stale_key()
    print("PASS komira_contacts test_store_sqlite")
