# =============================================================================
# komira_contacts/store.mojo -- address books and cards on any komira_db
#   `Database`.
# =============================================================================
#
# `ContactsStore[DB]` is generic over the backend-neutral `komira_db.Database`
# trait: it uses only the transaction verbs and the structured operations, so
# the same code runs on SQLite and on Firestore (schema.mojo lists the tables).
# Every call takes the `Caller` and applies the per-object rules of
# access.mojo before it reads or writes a row.
#
# THE WRITE PROTOCOL. Every write runs inside begin/commit, and any refusal
# rolls back:
#
#   book    a default book: claim the owner in contact_default_books (a
#           claim that names no book is stale and is moved to the new book)
#           -> put the book
#   create  read the book (access) -> claim (book, uid) in contact_card_uids
#           (a key that names no card, or a tombstone, is stale and is moved
#           to the new card) -> insert the card at the book's modseq + 1
#           -> advance the book
#   update  read the book (access) and the live card -> CAS the card on
#           (id, book, live, version) -> advance the book
#   delete  read the book (access) and the live card -> CAS the card to a
#           tombstone -> release its uid -> advance the book
#
# "Advance the book" is a CAS of the book row from the modseq read at the
# start to that value + 1, after the card write succeeded. So:
#   - a card write and its book's modseq move together, and a refused write
#     (stale version, taken uid) moves neither;
#   - within one book, every write and every delete gets a strictly greater
#     modseq than the one before it, and the change feed (`changes`) lists the
#     cards whose modseq is above a client's cursor.
#
# What a document backend gives: each `Database` write there is its own
# atomic write, and `rollback` deletes the documents created since `begin`
# (komira_gcp_firestore_db). A refused write is refused before it writes, so
# it changes nothing on either backend. A write that stops part way (a crash,
# or a lost connection that also stops the rollback) is not undone on a
# document backend, and leaves one of these:
#   - a uid key naming no card (create stopped after its key) or a tombstone
#     (delete stopped after its tombstone): the next create of that uid in the
#     book moves the key to its own card, so the uid is not lost;
#   - a default claim naming no book (create_book stopped after its claim):
#     the owner's next default create moves the claim to its own book;
#   - a card write whose book modseq did not advance: the change feed does
#     not list it until the next write in the book, which takes the same
#     modseq.
# With more than one concurrent writer per book there, two writers can read
# the same book modseq and the second advance is refused after its card was
# written, a create can move a key whose card another writer is still
# writing, and a default create can move a claim whose book another default
# create of the same owner is still writing (two books then say they are the
# default). The store claims a single writer per book, and one default
# create per owner at a time, on a document backend.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import (
    Database,
    DbColVal,
    DbRow,
    DbValue,
    Filter,
    Order,
    Pred,
    generate_uuidv7,
)
from komira_proto_codec import decode_json_lenient, encode_json

from komira_contacts_proto.contacts import (
    AddressBook,
    BookKind,
    Card,
    CardChange,
    CardKind,
    ChangesResponse,
)

from komira_contacts.access import (
    Caller,
    check_create_book,
    check_read_book,
    check_write_book,
)
from komira_contacts.errors import (
    ERR_DEFAULT_TAKEN,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
    invalid,
    not_found,
)
from komira_contacts.schema import (
    BOOKS,
    CARDS,
    CARD_UIDS,
    DEFAULT_BOOKS,
    book_cols,
    card_cols,
    card_uid_cols,
    default_book_cols,
)
from komira_contacts.validate import check_book_name, check_card


# ---- rows -------------------------------------------------------------------


def _text(s: String) -> DbValue:
    return DbValue.text(String(s))


def _int(v: UInt64) -> DbValue:
    return DbValue.int8(Int64(v))


def _flag(b: Bool) -> DbValue:
    return DbValue.int8(Int64(1) if b else Int64(0))


def _book_row(book: AddressBook) -> List[DbValue]:
    """`book` in `book_cols()` order."""
    var out = List[DbValue]()
    out.append(_text(book.id))
    out.append(_text(book.kind.json_name()))
    out.append(_text(book.owner))
    out.append(_text(book.name))
    out.append(_flag(book.is_default))
    out.append(_int(book.version))
    out.append(_int(book.modseq))
    return out^


def _book_from_row(row: DbRow) raises -> AddressBook:
    return AddressBook(
        id=row.get_text(0),
        kind=BookKind.from_json_name(row.get_text(1)),
        owner=row.get_text(2),
        name=row.get_text(3),
        is_default=row.get_int8(4) != 0,
        version=UInt64(row.get_int8(5)),
        modseq=UInt64(row.get_int8(6)),
    )


def _card_body(card: Card) raises -> String:
    """The card's proto3 JSON without the server-written fields, which have
    columns of their own."""
    var body = card.copy()
    body.id = String()
    body.address_book_id = String()
    body.version = UInt64(0)
    body.modseq = UInt64(0)
    return encode_json(body)


def _card_row(card: Card, deleted: Bool) raises -> List[DbValue]:
    """`card` in `card_cols()` order."""
    var out = List[DbValue]()
    out.append(_text(card.id))
    out.append(_text(card.address_book_id))
    out.append(_text(card.uid))
    out.append(_text(card.kind.json_name()))
    out.append(_flag(deleted))
    out.append(_int(card.version))
    out.append(_int(card.modseq))
    out.append(_text(_card_body(card)))
    return out^


def _card_from_row(row: DbRow) raises -> Card:
    # Lenient: a body written by a newer schema keeps the fields this one knows.
    var card = decode_json_lenient[Card](row.get_text(7))
    card.id = row.get_text(0)
    card.address_book_id = row.get_text(1)
    card.uid = row.get_text(2)
    card.kind = CardKind.from_json_name(row.get_text(3))
    card.version = UInt64(row.get_int8(5))
    card.modseq = UInt64(row.get_int8(6))
    return card^


def _strs(*items: StaticString) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(String(s))
    return out^


def _no_limit() -> Optional[UInt32]:
    return Optional[UInt32]()


def _sort_books(mut xs: List[AddressBook]):
    """By kind number, then name, then id (insertion sort; lists are short)."""
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and _book_after(xs[j - 1], xs[j]):
            var t = xs[j - 1].copy()
            xs[j - 1] = xs[j].copy()
            xs[j] = t^
            j -= 1


def _book_after(a: AddressBook, b: AddressBook) -> Bool:
    if a.kind.value != b.kind.value:
        return a.kind.value > b.kind.value
    if a.name != b.name:
        return a.name > b.name
    return a.id > b.id


def _sort_cards(mut xs: List[Card]):
    """By uid (unique within a book)."""
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j - 1].uid > xs[j].uid:
            var t = xs[j - 1].copy()
            xs[j - 1] = xs[j].copy()
            xs[j] = t^
            j -= 1


# ---- the store --------------------------------------------------------------


struct ContactsStore[DB: Database](Movable):
    """Address books and cards over one `Database` (see the module header).
    Owns the database by value."""

    var _db: Self.DB

    def __init__(out self, var db: Self.DB):
        self._db = db^

    def database(ref self) -> ref [self._db] Self.DB:
        """Borrow the underlying database."""
        return self._db

    # ---- books --------------------------------------------------------------

    def create_book[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        caller: Caller,
        kind: Int,
        name: String,
        is_default: Bool,
    ) raises -> AddressBook:
        """Create a book of `kind` (PERSONAL, owned by the caller, or SHARED,
        by an admin). `is_default` claims the caller's one default book."""
        check_create_book(caller, kind)
        check_book_name(name)
        if is_default and kind != BookKind.PERSONAL:
            raise invalid("is_default", "only a PERSONAL book can be a default")
        var owner = String(caller.subject) if kind == BookKind.PERSONAL else String()
        var book = AddressBook(
            id=generate_uuidv7().to_hyphenated(),
            kind=BookKind(kind),
            owner=owner,
            name=String(name),
            is_default=is_default,
            version=UInt64(1),
            modseq=UInt64(0),
        )
        self._db.begin[RT](reactor)
        try:
            if is_default:
                var vals = List[DbValue]()
                vals.append(_text(book.owner))
                vals.append(_text(book.id))
                var won = self._db.create_if_absent[RT](
                    reactor,
                    String(DEFAULT_BOOKS),
                    String("owner"),
                    _text(book.owner),
                    default_book_cols(),
                    vals^,
                )
                if not won:
                    self._take_stale_default[RT](reactor, book.owner, book.id)
            _ = self._db.put[RT](reactor, String(BOOKS), book_cols(), _book_row(book))
            self._db.commit[RT](reactor)
            return book^
        except e:
            self._db.rollback[RT](reactor)
            raise e^

    def _take_stale_default[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], owner: String, book_id: String) raises:
        """`owner` already has a default claim. Refuse with ERR_DEFAULT_TAKEN
        when the claim names a book; otherwise the claim is stale (a
        create_book stopped between its claim and its book) and is moved to
        `book_id`, guarded on the book it named."""
        var got = self._db.get_by_key[RT](
            reactor, String(DEFAULT_BOOKS), default_book_cols(), String("owner"), _text(owner)
        )
        if not got:
            raise Error(String(ERR_DEFAULT_TAKEN))
        var claim = got.take()
        var holder = claim.get_text(1)
        var held = self._db.get_by_key[RT](
            reactor, String(BOOKS), book_cols(), String("id"), _text(holder)
        )
        if held:
            raise Error(String(ERR_DEFAULT_TAKEN))
        var guard = List[Pred]()
        guard.append(Pred.eq(String("owner"), _text(owner)))
        guard.append(Pred.eq(String("book_id"), _text(holder)))
        var updates = List[DbColVal]()
        updates.append(DbColVal.bind(String("book_id"), _text(book_id)))
        var n = self._db.conditional_update[RT](
            reactor,
            String(DEFAULT_BOOKS),
            Filter.all_of(guard^),
            updates^,
            False,
            Optional[String](),
            List[String](),
        )
        if n != 1:
            raise Error(String(ERR_DEFAULT_TAKEN))

    def get_book[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String) raises -> AddressBook:
        return self._readable_book[RT](reactor, caller, book_id)

    def list_books[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller) raises -> List[AddressBook]:
        """The caller's PERSONAL books and every SHARED book: PERSONAL first, then
        by name, then by id."""
        var out = List[AddressBook]()
        if caller.subject.byte_length() > 0:
            var mine = List[Pred]()
            mine.append(Pred.eq(String("owner"), _text(caller.subject)))
            mine.append(Pred.eq(String("kind"), DbValue.text(String("PERSONAL"))))
            self._append_books[RT](reactor, Filter.all_of(mine^), out)
        self._append_books[RT](
            reactor, Filter.just(Pred.eq(String("kind"), DbValue.text(String("SHARED")))), out
        )
        _sort_books(out)
        return out^

    def _append_books[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], filter: Filter, mut out: List[AddressBook]) raises:
        var rows = self._db.query_rows[RT](
            reactor, String(BOOKS), book_cols(), filter, List[Order](), _no_limit()
        )
        for i in range(rows.__len__()):
            out.append(_book_from_row(rows.row(i)))

    def _load_book[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], book_id: String) raises -> AddressBook:
        var got = self._db.get_by_key[RT](
            reactor, String(BOOKS), book_cols(), String("id"), _text(book_id)
        )
        if not got:
            raise not_found()
        return _book_from_row(got.take())

    def _readable_book[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String) raises -> AddressBook:
        var book = self._load_book[RT](reactor, book_id)
        check_read_book(caller, book.kind.value, book.owner)
        return book^

    def _writable_book[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String) raises -> AddressBook:
        var book = self._load_book[RT](reactor, book_id)
        check_write_book(caller, book.kind.value, book.owner)
        return book^

    def _advance_book[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], book_id: String, seen: UInt64) raises:
        """CAS the book's modseq from `seen` to `seen + 1`."""
        var guard = List[Pred]()
        guard.append(Pred.eq(String("id"), _text(book_id)))
        guard.append(Pred.eq(String("modseq"), _int(seen)))
        var updates = List[DbColVal]()
        updates.append(DbColVal.bind(String("modseq"), _int(seen + 1)))
        var n = self._db.conditional_update[RT](
            reactor,
            String(BOOKS),
            Filter.all_of(guard^),
            updates^,
            False,
            Optional[String](),
            List[String](),
        )
        if n != 1:
            raise Error(String(ERR_VERSION_CONFLICT))

    # ---- cards --------------------------------------------------------------

    def _live_card[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], book_id: String, card_id: String) raises -> Card:
        """The live card `card_id` of book `book_id`; not found when it is in
        another book or deleted."""
        var got = self._db.get_by_key[RT](
            reactor, String(CARDS), card_cols(), String("id"), _text(card_id)
        )
        if not got:
            raise not_found()
        var row = got.take()
        if row.get_text(1) != book_id or row.get_int8(4) != 0:
            raise not_found()
        return _card_from_row(row)

    def get_card[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String, card_id: String) raises -> Card:
        _ = self._readable_book[RT](reactor, caller, book_id)
        return self._live_card[RT](reactor, book_id, card_id)

    def list_cards[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String) raises -> List[Card]:
        """The live cards of a book, by uid."""
        _ = self._readable_book[RT](reactor, caller, book_id)
        var preds = List[Pred]()
        preds.append(Pred.eq(String("address_book_id"), _text(book_id)))
        preds.append(Pred.eq(String("deleted"), _flag(False)))
        var rows = self._db.query_rows[RT](
            reactor, String(CARDS), card_cols(), Filter.all_of(preds^), List[Order](), _no_limit()
        )
        var out = List[Card]()
        for i in range(rows.__len__()):
            out.append(_card_from_row(rows.row(i)))
        _sort_cards(out)
        return out^

    def create_card[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String, card: Card) raises -> Card:
        """Store a new card in a book. An empty `uid` becomes `urn:uuid:<id>`;
        a uid already live in the book is refused."""
        check_card(card)
        var out = card.copy()
        out.id = generate_uuidv7().to_hyphenated()
        out.address_book_id = String(book_id)
        if out.uid.byte_length() == 0:
            out.uid = String("urn:uuid:") + out.id
        out.version = UInt64(1)
        self._db.begin[RT](reactor)
        try:
            var book = self._writable_book[RT](reactor, caller, book_id)
            var claim = List[DbValue]()
            claim.append(_text(book_id))
            claim.append(_text(out.uid))
            claim.append(_text(out.id))
            var won = self._db.create_if_absent_composite[RT](
                reactor,
                String(CARD_UIDS),
                _strs("address_book_id", "uid"),
                card_uid_cols(),
                claim^,
            )
            if not won:
                self._take_stale_uid[RT](reactor, book_id, out.uid, out.id)
            out.modseq = book.modseq + 1
            _ = self._db.put[RT](reactor, String(CARDS), card_cols(), _card_row(out, False))
            self._advance_book[RT](reactor, book_id, book.modseq)
            self._db.commit[RT](reactor)
            return out^
        except e:
            self._db.rollback[RT](reactor)
            raise e^

    def _take_stale_uid[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], book_id: String, uid: String, card_id: String) raises:
        """`uid` is already keyed in the book. Refuse with ERR_UID_TAKEN when
        the key names a live card of the book; otherwise the key is stale (a
        create stopped between its key and its card, or a delete stopped
        between its tombstone and the key's removal) and is moved to
        `card_id`, guarded on the card it named."""
        var key = List[Pred]()
        key.append(Pred.eq(String("address_book_id"), _text(book_id)))
        key.append(Pred.eq(String("uid"), _text(uid)))
        var rows = self._db.query_rows[RT](
            reactor, String(CARD_UIDS), _strs("card_id"), Filter.all_of(key^), List[Order](), _no_limit()
        )
        if rows.__len__() != 1:
            raise Error(String(ERR_UID_TAKEN))
        var holder = rows.row(0).get_text(0)
        var held = self._db.get_by_key[RT](
            reactor, String(CARDS), card_cols(), String("id"), _text(holder)
        )
        if held:
            var row = held.take()
            if row.get_text(1) == book_id and row.get_int8(4) == 0:
                raise Error(String(ERR_UID_TAKEN))
        var guard = List[Pred]()
        guard.append(Pred.eq(String("address_book_id"), _text(book_id)))
        guard.append(Pred.eq(String("uid"), _text(uid)))
        guard.append(Pred.eq(String("card_id"), _text(holder)))
        var updates = List[DbColVal]()
        updates.append(DbColVal.bind(String("card_id"), _text(card_id)))
        var n = self._db.conditional_update[RT](
            reactor,
            String(CARD_UIDS),
            Filter.all_of(guard^),
            updates^,
            False,
            Optional[String](),
            List[String](),
        )
        if n != 1:
            raise Error(String(ERR_UID_TAKEN))

    def update_card[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        caller: Caller,
        book_id: String,
        card_id: String,
        expected_version: UInt64,
        card: Card,
    ) raises -> Card:
        """Replace a live card's fields if its version is still
        `expected_version`. The uid cannot change (an empty one keeps it)."""
        check_card(card)
        self._db.begin[RT](reactor)
        try:
            var book = self._writable_book[RT](reactor, caller, book_id)
            var current = self._live_card[RT](reactor, book_id, card_id)
            if card.uid.byte_length() > 0 and card.uid != current.uid:
                raise invalid("uid", "cannot change")
            var out = card.copy()
            out.id = String(card_id)
            out.address_book_id = String(book_id)
            out.uid = current.uid
            out.version = expected_version + 1
            out.modseq = book.modseq + 1
            var updates = List[DbColVal]()
            updates.append(DbColVal.bind(String("kind"), _text(out.kind.json_name())))
            updates.append(DbColVal.bind(String("body"), _text(_card_body(out))))
            updates.append(DbColVal.bind(String("modseq"), _int(out.modseq)))
            self._cas_card[RT](reactor, book_id, card_id, expected_version, updates^)
            self._advance_book[RT](reactor, book_id, book.modseq)
            self._db.commit[RT](reactor)
            return out^
        except e:
            self._db.rollback[RT](reactor)
            raise e^

    def delete_card[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        caller: Caller,
        book_id: String,
        card_id: String,
        expected_version: UInt64,
    ) raises -> UInt64:
        """Delete a live card if its version is still `expected_version`: it
        stays as a tombstone for the change feed and its uid is released.
        Returns the tombstone's modseq."""
        self._db.begin[RT](reactor)
        try:
            var book = self._writable_book[RT](reactor, caller, book_id)
            var current = self._live_card[RT](reactor, book_id, card_id)
            var modseq = book.modseq + 1
            var updates = List[DbColVal]()
            updates.append(DbColVal.bind(String("deleted"), _flag(True)))
            updates.append(DbColVal.bind(String("modseq"), _int(modseq)))
            self._cas_card[RT](reactor, book_id, card_id, expected_version, updates^)
            var key = List[Pred]()
            key.append(Pred.eq(String("address_book_id"), _text(book_id)))
            key.append(Pred.eq(String("uid"), _text(current.uid)))
            _ = self._db.delete_where[RT](reactor, String(CARD_UIDS), Filter.all_of(key^))
            self._advance_book[RT](reactor, book_id, book.modseq)
            self._db.commit[RT](reactor)
            return modseq
        except e:
            self._db.rollback[RT](reactor)
            raise e^

    def _cas_card[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        book_id: String,
        card_id: String,
        expected_version: UInt64,
        var updates: List[DbColVal],
    ) raises:
        """Apply `updates` and bump the version, only to the live card
        `card_id` of `book_id` at `expected_version`."""
        var guard = List[Pred]()
        guard.append(Pred.eq(String("id"), _text(card_id)))
        guard.append(Pred.eq(String("address_book_id"), _text(book_id)))
        guard.append(Pred.eq(String("deleted"), _flag(False)))
        guard.append(Pred.eq(String("version"), _int(expected_version)))
        var n = self._db.conditional_update[RT](
            reactor,
            String(CARDS),
            Filter.all_of(guard^),
            updates^,
            False,
            Optional[String](String("version")),
            List[String](),
        )
        if n != 1:
            raise Error(String(ERR_VERSION_CONFLICT))

    # ---- the change feed ------------------------------------------------------

    def changes[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], caller: Caller, book_id: String, since: UInt64) raises -> ChangesResponse:
        """The cards of a book written or deleted after change number `since`,
        in modseq order, each once at its latest state. `modseq` in the
        response is the cursor for the next call."""
        var book = self._readable_book[RT](reactor, caller, book_id)
        var out = List[CardChange]()
        if since < book.modseq:
            var preds = List[Pred]()
            preds.append(Pred.eq(String("address_book_id"), _text(book_id)))
            preds.append(Pred.gte(String("modseq"), _int(since + 1)))
            preds.append(Pred.le(String("modseq"), _int(book.modseq)))
            var order = List[Order]()
            order.append(Order.asc(String("modseq")))
            var rows = self._db.query_rows[RT](
                reactor,
                String(CARDS),
                _strs("id", "uid", "modseq", "deleted"),
                Filter.all_of(preds^),
                order^,
                _no_limit(),
            )
            for i in range(rows.__len__()):
                ref r = rows.row(i)
                out.append(
                    CardChange(
                        card_id=r.get_text(0),
                        uid=r.get_text(1),
                        modseq=UInt64(r.get_int8(2)),
                        deleted=r.get_int8(3) != 0,
                    )
                )
        return ChangesResponse(changes=out^, modseq=book.modseq)
