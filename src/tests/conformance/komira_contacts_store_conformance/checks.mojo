# =============================================================================
# komira_contacts_store_conformance/checks.mojo -- the store's contract.
# =============================================================================
#
# Each check states the behaviour it holds the store to and the defect it
# catches. Refusals are compared by their exact text (komira_contacts.ERR_*).
#
#   uid_unique_per_book   one uid in two books succeeds, twice in one book is
#                         refused, and a delete releases it in its own book
#                         only. Catches a uid unique across books (a global
#                         UNIQUE, which also reveals that the uid exists
#                         elsewhere) and a delete that releases the uid in
#                         every book.
#   version_cas           of two writes naming the same version, exactly one
#                         succeeds; the other, and a stale delete, are refused
#                         and change nothing; the uid cannot change, and an
#                         update with no uid keeps it. Catches a CAS without
#                         the version term and an empty uid refused as a
#                         change.
#   changes_feed          modseq strictly increases within a book across
#                         creates, updates and deletes; the feed lists each
#                         card once at its latest modseq (a delete as a
#                         tombstone), from any cursor; another book's modseq
#                         does not move. Catches a delete that does not bump
#                         modseq, a modseq shared across books, and a deleted
#                         card still read, updated or deleted by its id.
#   refused_write_moves_nothing  a stale update, a stale delete, a taken uid,
#                         an invalid card created and an invalid card
#                         written by an update leave the book's modseq and the
#                         feed unchanged. Catches a modseq bump outside the
#                         write's transaction, and an update that skips
#                         validation.
#   idor_personal_book    another subject (admin or not) gets the not-found
#                         text, byte for byte the text of an id that does not
#                         exist, for every read and write of a PERSONAL book
#                         and its cards, including a card id passed through
#                         the subject's own book; the owner's data is
#                         unchanged afterwards. Catches a dropped owner check
#                         and a card looked up without its book.
#   shared_book_rules     a SHARED book is read by everyone and written only
#                         by an admin; a DIRECTORY book cannot be created.
#   default_book          one default book per owner; a second default is
#                         refused at its claim, before it writes anything, and
#                         the next create runs (its transaction was closed);
#                         an empty book name is refused.
#   card_round_trip       every card field survives a write and a read; the
#                         server-written fields a client sends are ignored.
#   stale_uid_key         a uid key row naming no card (a create stopped
#                         between its key and its card) or a tombstone (a
#                         delete stopped before releasing the uid) does not
#                         hold the uid: the next create of it succeeds, and
#                         the key then holds it again. The rows are planted
#                         through the database directly. Catches a stale key
#                         that refuses its uid in that book for good.
#   stale_default_claim   a default claim naming no book (a create_book
#                         stopped between its claim and its book) does not
#                         hold the default: the owner's next default create
#                         succeeds, the claim then names its book, and a
#                         further default is refused. The claim is planted
#                         through the database directly. Catches a stale claim
#                         that refuses the owner a default book for good.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor
from komira_db import DbValue
from komira_proto_codec import decode_json, encode_json
from komira_contacts_proto.contacts import BookKind, Card, CardKind

from komira_contacts import (
    CARD_UIDS,
    Caller,
    ContactsStore,
    DEFAULT_BOOKS,
    ERR_DEFAULT_TAKEN,
    ERR_FORBIDDEN,
    ERR_NOT_FOUND,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
)

from komira_contacts_store_conformance.targets import ContactsTarget, Rt, new_rt

comptime OK = "ok"
comptime NO_SUCH_ID = "00000000-0000-7000-8000-000000000000"


def _alice() -> Caller:
    return Caller(String("alice"), False)


def _bob() -> Caller:
    return Caller(String("bob"), False)


def _admin() -> Caller:
    return Caller(String("root"), True)


def _card(json: StaticString) raises -> Card:
    return decode_json[Card](String(json))


def _uid_card(uid: StaticString, full: StaticString) raises -> Card:
    return decode_json[Card](
        String('{"uid":"') + String(uid) + String('","name":{"full":"') + String(full) + String('"}}')
    )


def _store[T: ContactsTarget](mut t: T) raises -> ContactsStore[T.DB]:
    return ContactsStore[T.DB](t.fresh())


def _feed[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, since: UInt64) raises -> String:
    """The change feed as `uid@modseq` (a tombstone `uid@modseq-`), comma
    separated, then `|<cursor>`."""
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


def _book_modseq[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String) raises -> UInt64:
    return store.get_book[Rt](reactor, who, book_id).modseq


def _uids(cards: List[Card]) -> String:
    var out = String()
    for i in range(len(cards)):
        if i > 0:
            out += ","
        out += cards[i].uid
    return out^


# ---- uid_unique_per_book -----------------------------------------------------


def check_uid_unique_per_book[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var x = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "X", False)
    var y = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Y", False)
    var in_x = store.create_card[Rt](reactor, _alice(), x.id, _uid_card("u-1", "One"))
    var in_y = store.create_card[Rt](reactor, _alice(), y.id, _uid_card("u-1", "One again"))
    assert_equal(in_x.uid, "u-1")
    assert_equal(in_y.uid, "u-1", "the same uid in a second book is accepted")
    assert_true(in_x.id != in_y.id, "two cards, two ids")
    var got = String(OK)
    try:
        _ = store.create_card[Rt](reactor, _alice(), x.id, _uid_card("u-1", "Dup"))
    except e:
        got = String(e)
    assert_equal(got, ERR_UID_TAKEN, "a uid already live in the book")
    assert_equal(_uids(store.list_cards[Rt](reactor, _alice(), x.id)), "u-1", "book X after the refusal")
    # A delete releases the uid.
    _ = store.delete_card[Rt](reactor, _alice(), x.id, in_x.id, in_x.version)
    var again = store.create_card[Rt](reactor, _alice(), x.id, _uid_card("u-1", "Back"))
    # The delete released the uid in book X only: Y still holds it.
    got = String(OK)
    try:
        _ = store.create_card[Rt](reactor, _alice(), y.id, _uid_card("u-1", "Dup in Y"))
    except e:
        got = String(e)
    assert_equal(got, ERR_UID_TAKEN, "a delete in X releases nothing in Y")
    assert_true(again.id != in_x.id, "a new card holds the released uid")
    # A card written without a uid is given urn:uuid:<id>.
    var minted = store.create_card[Rt](reactor, _alice(), x.id, _card('{"name":{"full":"No uid"}}'))
    assert_equal(minted.uid, String("urn:uuid:") + minted.id)


# ---- version_cas -------------------------------------------------------------


def check_version_cas[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    var c = store.create_card[Rt](reactor, _alice(), b.id, _uid_card("u", "Zero"))
    assert_equal(c.version, UInt64(1))
    var first = store.update_card[Rt](reactor, _alice(), b.id, c.id, UInt64(1), _uid_card("u", "First"))
    assert_equal(first.version, UInt64(2), "the winning write bumps the version")
    var got = String(OK)
    try:
        _ = store.update_card[Rt](reactor, _alice(), b.id, c.id, UInt64(1), _uid_card("u", "Second"))
    except e:
        got = String(e)
    assert_equal(got, ERR_VERSION_CONFLICT, "the second write naming version 1")
    got = String(OK)
    try:
        _ = store.delete_card[Rt](reactor, _alice(), b.id, c.id, UInt64(1))
    except e:
        got = String(e)
    assert_equal(got, ERR_VERSION_CONFLICT, "a delete naming version 1")
    var now = store.get_card[Rt](reactor, _alice(), b.id, c.id)
    assert_equal(now.name.value().full, "First", "the losing write changed nothing")
    assert_equal(now.version, UInt64(2))
    # The uid cannot change.
    got = String(OK)
    try:
        _ = store.update_card[Rt](reactor, _alice(), b.id, c.id, UInt64(2), _uid_card("other", "x"))
    except e:
        got = String(e)
    assert_equal(got, "contacts: invalid uid: cannot change")
    # An empty uid keeps the card's uid.
    var kept = store.update_card[Rt](reactor, _alice(), b.id, c.id, UInt64(2), _uid_card("", "Third"))
    assert_equal(kept.uid, "u", "what the update returns")
    assert_equal(kept.version, UInt64(3))
    var reread = store.get_card[Rt](reactor, _alice(), b.id, c.id)
    assert_equal(reread.uid, "u", "what a read returns")
    assert_equal(reread.name.value().full, "Third")


# ---- changes_feed ------------------------------------------------------------


def check_changes_feed[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var al = _alice()
    var b = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "B", False)
    var other = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "Other", False)
    assert_equal(b.modseq, UInt64(0))
    var a = store.create_card[Rt](reactor, al, b.id, _uid_card("a", "A"))
    var c = store.create_card[Rt](reactor, al, b.id, _uid_card("c", "C"))
    var a2 = store.update_card[Rt](reactor, al, b.id, a.id, a.version, _uid_card("a", "A2"))
    var gone = store.delete_card[Rt](reactor, al, b.id, c.id, c.version)
    assert_true(a.modseq < c.modseq, "create then create")
    assert_true(c.modseq < a2.modseq, "create then update")
    assert_true(a2.modseq < gone, "update then delete")
    assert_equal(_book_modseq[T](store, reactor, al, b.id), gone, "the book's modseq is its latest write")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(0)), "a@3,c@4-|4", "the feed from the start")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(3)), "c@4-|4", "the feed after the update")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(4)), "|4", "the feed at the cursor")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(9)), "|4", "a cursor past the book")
    assert_equal(_uids(store.list_cards[Rt](reactor, al, b.id)), "a", "a tombstone is not listed")
    # A tombstone is not found by id, and cannot be updated or deleted again.
    assert_equal(_err_get_card[T](store, reactor, al, b.id, c.id), ERR_NOT_FOUND, "get a deleted card")
    assert_equal(_err_update[T](store, reactor, al, b.id, c.id), ERR_NOT_FOUND, "update a deleted card")
    assert_equal(_err_delete[T](store, reactor, al, b.id, c.id), ERR_NOT_FOUND, "delete a deleted card")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(0)), "a@3,c@4-|4", "the refusals moved nothing")
    assert_equal(_book_modseq[T](store, reactor, al, other.id), UInt64(0), "another book did not move")
    var o = store.create_card[Rt](reactor, al, other.id, _uid_card("o", "O"))
    assert_equal(o.modseq, UInt64(1), "each book counts on its own")


# ---- refused_write_moves_nothing ---------------------------------------------


def check_refused_write_moves_nothing[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var al = _alice()
    var b = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "B", False)
    var a = store.create_card[Rt](reactor, al, b.id, _uid_card("a", "A"))
    assert_equal(_book_modseq[T](store, reactor, al, b.id), UInt64(1))
    var got = String(OK)
    try:
        _ = store.update_card[Rt](reactor, al, b.id, a.id, UInt64(9), _uid_card("a", "Stale"))
    except e:
        got = String(e)
    assert_equal(got, ERR_VERSION_CONFLICT)
    assert_equal(_book_modseq[T](store, reactor, al, b.id), UInt64(1), "a stale update")
    got = String(OK)
    try:
        _ = store.delete_card[Rt](reactor, al, b.id, a.id, UInt64(9))
    except e:
        got = String(e)
    assert_equal(got, ERR_VERSION_CONFLICT)
    assert_equal(_book_modseq[T](store, reactor, al, b.id), UInt64(1), "a stale delete")
    got = String(OK)
    try:
        _ = store.create_card[Rt](reactor, al, b.id, _uid_card("a", "Dup"))
    except e:
        got = String(e)
    assert_equal(got, ERR_UID_TAKEN)
    assert_equal(_book_modseq[T](store, reactor, al, b.id), UInt64(1), "a taken uid")
    got = String(OK)
    try:
        _ = store.create_card[Rt](reactor, al, b.id, _card('{"uid":"m","members":["a"]}'))
    except e:
        got = String(e)
    assert_equal(got, "contacts: invalid members: only a GROUP card has members")
    assert_equal(_book_modseq[T](store, reactor, al, b.id), UInt64(1), "an invalid card")
    got = String(OK)
    try:
        _ = store.update_card[Rt](reactor, al, b.id, a.id, a.version, _card('{"uid":"a","members":["x"]}'))
    except e:
        got = String(e)
    assert_equal(got, "contacts: invalid members: only a GROUP card has members", "an update is validated")
    assert_equal(_book_modseq[T](store, reactor, al, b.id), UInt64(1), "an invalid update")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(0)), "a@1|1", "the feed after five refusals")
    assert_equal(_uids(store.list_cards[Rt](reactor, al, b.id)), "a")
    assert_equal(store.get_card[Rt](reactor, al, b.id, a.id).name.value().full, "A")


# ---- idor_personal_book ------------------------------------------------------


def _err_get_book[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String) -> String:
    try:
        _ = store.get_book[Rt](reactor, who, book_id)
        return String(OK)
    except e:
        return String(e)


def _err_get_card[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, card_id: String) -> String:
    try:
        _ = store.get_card[Rt](reactor, who, book_id, card_id)
        return String(OK)
    except e:
        return String(e)


def _err_list[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String) -> String:
    try:
        _ = store.list_cards[Rt](reactor, who, book_id)
        return String(OK)
    except e:
        return String(e)


def _err_changes[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String) -> String:
    try:
        _ = store.changes[Rt](reactor, who, book_id, UInt64(0))
        return String(OK)
    except e:
        return String(e)


def _err_create[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String) -> String:
    try:
        _ = store.create_card[Rt](reactor, who, book_id, _uid_card("x", "Intruder"))
        return String(OK)
    except e:
        return String(e)


def _err_update[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, card_id: String) -> String:
    try:
        _ = store.update_card[Rt](reactor, who, book_id, card_id, UInt64(1), _uid_card("", "Intruder"))
        return String(OK)
    except e:
        return String(e)


def _err_delete[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, card_id: String) -> String:
    try:
        _ = store.delete_card[Rt](reactor, who, book_id, card_id, UInt64(1))
        return String(OK)
    except e:
        return String(e)


def check_idor_personal_book[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var al = _alice()
    var a_book = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "Private", False)
    var a_card = store.create_card[Rt](reactor, al, a_book.id, _uid_card("secret", "Secret"))
    var b_book = store.create_book[Rt](reactor, _bob(), BookKind.PERSONAL, "Bob's", False)
    var missing = String(NO_SUCH_ID)

    # The text of an id that does not exist: what every refusal below must equal.
    var absent = _err_get_book[T](store, reactor, _bob(), missing)
    assert_equal(absent, ERR_NOT_FOUND, "a book id that does not exist")
    assert_equal(_err_get_card[T](store, reactor, al, a_book.id, missing), absent, "a card id that does not exist")

    for who_i in range(2):
        var who = _bob() if who_i == 0 else _admin()
        var tag = String("bob: ") if who_i == 0 else String("admin: ")
        assert_equal(_err_get_book[T](store, reactor, who, a_book.id), absent, tag + "get the book")
        assert_equal(_err_get_card[T](store, reactor, who, a_book.id, a_card.id), absent, tag + "get the card")
        assert_equal(_err_list[T](store, reactor, who, a_book.id), absent, tag + "list the book")
        assert_equal(_err_changes[T](store, reactor, who, a_book.id), absent, tag + "the book's feed")
        assert_equal(_err_create[T](store, reactor, who, a_book.id), absent, tag + "create in the book")
        assert_equal(_err_update[T](store, reactor, who, a_book.id, a_card.id), absent, tag + "update the card")
        assert_equal(_err_delete[T](store, reactor, who, a_book.id, a_card.id), absent, tag + "delete the card")

    # Alice's card id through Bob's own (readable, writable) book.
    assert_equal(_err_get_card[T](store, reactor, _bob(), b_book.id, a_card.id), absent, "get via own book")
    assert_equal(_err_update[T](store, reactor, _bob(), b_book.id, a_card.id), absent, "update via own book")
    assert_equal(_err_delete[T](store, reactor, _bob(), b_book.id, a_card.id), absent, "delete via own book")

    var bobs = store.list_books[Rt](reactor, _bob())
    assert_equal(len(bobs), 1, "bob lists only his own book")
    assert_equal(bobs[0].id, b_book.id)

    # Alice's data is untouched.
    var still = store.get_card[Rt](reactor, al, a_book.id, a_card.id)
    assert_equal(still.version, UInt64(1))
    assert_equal(still.name.value().full, "Secret")
    assert_equal(_feed[T](store, reactor, al, a_book.id, UInt64(0)), "secret@1|1")
    assert_equal(_book_modseq[T](store, reactor, _bob(), b_book.id), UInt64(0))


# ---- shared_book_rules -------------------------------------------------------


def check_shared_book_rules[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _bob(), BookKind.SHARED, "Mine", False)
    except e:
        got = String(e)
    assert_equal(got, ERR_FORBIDDEN, "a non-admin creates a SHARED book")
    got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _admin(), BookKind.DIRECTORY, "Dir", False)
    except e:
        got = String(e)
    assert_equal(got, "contacts: invalid kind: a DIRECTORY book is projected from the directory, not created")
    var team = store.create_book[Rt](reactor, _admin(), BookKind.SHARED, "Team", False)
    assert_equal(team.owner, "", "a SHARED book has no owner")
    var c = store.create_card[Rt](reactor, _admin(), team.id, _uid_card("t", "Team member"))
    assert_equal(store.get_card[Rt](reactor, _bob(), team.id, c.id).uid, "t", "bob reads a shared card")
    assert_equal(_uids(store.list_cards[Rt](reactor, _bob(), team.id)), "t")
    assert_equal(_err_create[T](store, reactor, _bob(), team.id), ERR_FORBIDDEN, "bob creates in SHARED")
    assert_equal(_err_update[T](store, reactor, _bob(), team.id, c.id), ERR_FORBIDDEN, "bob updates in SHARED")
    assert_equal(_err_delete[T](store, reactor, _bob(), team.id, c.id), ERR_FORBIDDEN, "bob deletes in SHARED")
    var listed = store.list_books[Rt](reactor, _bob())
    assert_equal(len(listed), 1)
    assert_equal(listed[0].id, team.id, "bob lists the shared book")
    assert_equal(_feed[T](store, reactor, _bob(), team.id, UInt64(0)), "t@1|1")


# ---- default_book ------------------------------------------------------------


def check_default_book[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var first = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    assert_true(first.is_default)
    var got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Second", True)
    except e:
        got = String(e)
    assert_equal(got, ERR_DEFAULT_TAKEN)
    var books = store.list_books[Rt](reactor, _alice())
    assert_equal(len(books), 1, "the refused default left no book")
    var plain = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Second", False)
    assert_false(plain.is_default)
    var bobs = store.create_book[Rt](reactor, _bob(), BookKind.PERSONAL, "Main", True)
    assert_true(bobs.is_default, "each owner has a default of their own")
    got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _admin(), BookKind.SHARED, "Team", True)
    except e:
        got = String(e)
    assert_equal(got, "contacts: invalid is_default: only a PERSONAL book can be a default")
    got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "", False)
    except e:
        got = String(e)
    assert_equal(got, "contacts: invalid name: required", "a book name is validated")
    var again = store.list_books[Rt](reactor, _alice())
    assert_equal(len(again), 2)
    assert_equal(again[0].name, "Main", "sorted by name")
    assert_true(again[0].is_default)
    assert_false(again[1].is_default)


# ---- card_round_trip ---------------------------------------------------------

comptime _FULL = (
    '{"id":"forged","addressBookId":"elsewhere","uid":"g-1","kind":"GROUP",'
    '"name":{"full":"Team A","given":"G","surname":"S","middle":"M","prefix":"P","suffix":"X"},'
    '"nickname":"n","organization":{"name":"Org","units":["Unit 1","Unit 2"]},"title":"t",'
    '"emails":[{"address":"a@example.org","label":"work","pref":1},{"address":"b@example.org"}],'
    '"phones":[{"number":"+1 555 0100","label":"cell","pref":2}],'
    '"addresses":[{"street":"1 Main St","locality":"Town","region":"R","postcode":"00000",'
    '"country":"C","label":"home","pref":3}],'
    '"urls":["https://example.org/a"],"birthday":"19850412","notes":"line 1\\nline 2 \\"quoted\\"",'
    '"members":["m-1","m-2"],"vcardExtra":["X-CUSTOM;TYPE=a:v\\\\;1","item1.X-ABLabel:other"],'
    '"version":"77","modseq":"88"}'
)

comptime _FULL_STORED = (
    '"uid":"g-1","kind":"GROUP",'
    '"name":{"full":"Team A","given":"G","surname":"S","middle":"M","prefix":"P","suffix":"X"},'
    '"nickname":"n","organization":{"name":"Org","units":["Unit 1","Unit 2"]},"title":"t",'
    '"emails":[{"address":"a@example.org","label":"work","pref":1},{"address":"b@example.org"}],'
    '"phones":[{"number":"+1 555 0100","label":"cell","pref":2}],'
    '"addresses":[{"street":"1 Main St","locality":"Town","region":"R","postcode":"00000",'
    '"country":"C","label":"home","pref":3}],'
    '"urls":["https://example.org/a"],"birthday":"19850412","notes":"line 1\\nline 2 \\"quoted\\"",'
    '"members":["m-1","m-2"],"vcardExtra":["X-CUSTOM;TYPE=a:v\\\\;1","item1.X-ABLabel:other"],'
    '"version":"1","modseq":"1"}'
)


def check_card_round_trip[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var b = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "B", False)
    var made = store.create_card[Rt](reactor, _alice(), b.id, _card(_FULL))
    assert_true(made.id != "forged", "the client's id is ignored")
    assert_equal(made.address_book_id, b.id, "the client's address book id is ignored")
    assert_equal(made.kind.value, CardKind.GROUP)
    var want = (
        String('{"id":"') + made.id + String('","addressBookId":"') + b.id + String('",') + String(_FULL_STORED)
    )
    assert_equal(encode_json(made), want, "what create returns")
    assert_equal(encode_json(store.get_card[Rt](reactor, _alice(), b.id, made.id)), want, "what a read returns")
    var listed = store.list_cards[Rt](reactor, _alice(), b.id)
    assert_equal(encode_json(listed[0]), want, "what a list returns")


# ---- stale_uid_key -----------------------------------------------------------


def _plant_uid_key[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], book_id: String, uid: StaticString, card_id: String) raises:
    """Write a uid key row directly, as a write that stopped part way leaves
    it."""
    var cols = List[String]()
    cols.append(String("address_book_id"))
    cols.append(String("uid"))
    cols.append(String("card_id"))
    var conflict = List[String]()
    conflict.append(String("address_book_id"))
    conflict.append(String("uid"))
    var vals = List[DbValue]()
    vals.append(DbValue.text(String(book_id)))
    vals.append(DbValue.text(String(uid)))
    vals.append(DbValue.text(String(card_id)))
    var won = store.database().create_if_absent_composite[Rt](reactor, String(CARD_UIDS), conflict^, cols^, vals^)
    assert_true(won, "the planted key is new")


def check_stale_uid_key[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    var al = _alice()
    var b = store.create_book[Rt](reactor, al, BookKind.PERSONAL, "B", False)
    # A create that claimed the uid and stopped before the card was written.
    _plant_uid_key[T](store, reactor, b.id, "u-crash", String(NO_SUCH_ID))
    var c = store.create_card[Rt](reactor, al, b.id, _uid_card("u-crash", "Crash"))
    assert_equal(c.uid, "u-crash", "a key naming no card does not hold the uid")
    assert_equal(store.get_card[Rt](reactor, al, b.id, c.id).name.value().full, "Crash")
    # A delete that wrote the tombstone and stopped before releasing the uid.
    var d = store.create_card[Rt](reactor, al, b.id, _uid_card("u-del", "Del"))
    _ = store.delete_card[Rt](reactor, al, b.id, d.id, d.version)
    _plant_uid_key[T](store, reactor, b.id, "u-del", d.id)
    var again = store.create_card[Rt](reactor, al, b.id, _uid_card("u-del", "Again"))
    assert_true(again.id != d.id, "a key naming a tombstone does not hold the uid")
    assert_equal(_err_get_card[T](store, reactor, al, b.id, d.id), ERR_NOT_FOUND, "the tombstone stays deleted")
    assert_equal(_uids(store.list_cards[Rt](reactor, al, b.id)), "u-crash,u-del")
    # Both keys now name live cards and hold their uids again.
    assert_equal(_err_create_uid[T](store, reactor, al, b.id, "u-crash"), ERR_UID_TAKEN, "u-crash after the repair")
    assert_equal(_err_create_uid[T](store, reactor, al, b.id, "u-del"), ERR_UID_TAKEN, "u-del after the repair")
    assert_equal(_feed[T](store, reactor, al, b.id, UInt64(0)), "u-crash@1,u-del@3-,u-del@4|4", "the feed after the repairs")


def _err_create_uid[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], who: Caller, book_id: String, uid: StaticString) -> String:
    try:
        _ = store.create_card[Rt](reactor, who, book_id, _uid_card(uid, "Dup"))
        return String(OK)
    except e:
        return String(e)


# ---- stale_default_claim -----------------------------------------------------


def _default_claim[
    T: ContactsTarget
](mut store: ContactsStore[T.DB], mut reactor: Reactor[Rt.Sink], owner: StaticString) raises -> String:
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


def check_stale_default_claim[T: ContactsTarget](mut t: T) raises:
    var store = _store[T](t)
    var rt = new_rt()
    ref reactor = rt.reactor()
    # A create_book that claimed alice's default and stopped before its book
    # was written.
    var cols = List[String]()
    cols.append(String("owner"))
    cols.append(String("book_id"))
    var vals = List[DbValue]()
    vals.append(DbValue.text(String("alice")))
    vals.append(DbValue.text(String(NO_SUCH_ID)))
    var won = store.database().create_if_absent[Rt](
        reactor, String(DEFAULT_BOOKS), String("owner"), DbValue.text(String("alice")), cols^, vals^
    )
    assert_true(won, "the planted claim is new")
    var home = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Main", True)
    assert_true(home.is_default, "a claim naming no book does not hold the default")
    assert_equal(_default_claim[T](store, reactor, "alice"), home.id, "the claim moved to the new book")
    var got = String(OK)
    try:
        _ = store.create_book[Rt](reactor, _alice(), BookKind.PERSONAL, "Second", True)
    except e:
        got = String(e)
    assert_equal(got, ERR_DEFAULT_TAKEN, "the claim holds the default again")
    var books = store.list_books[Rt](reactor, _alice())
    assert_equal(len(books), 1, "one book, the default")
    assert_equal(books[0].id, home.id)
