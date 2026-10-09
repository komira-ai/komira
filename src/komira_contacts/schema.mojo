# =============================================================================
# komira_contacts/schema.mojo -- the store's tables, as every backend sees them.
# =============================================================================
#
# The store writes only through the backend-neutral `komira_db.Database`
# operations, so the same four tables live on a SQL backend (created by the
# DDL below) and on a document backend (nothing to create; one collection per
# table).
#
#   contact_books          one row per address book
#     id TEXT key, kind TEXT (the BookKind name), owner TEXT (PERSONAL: the
#     owner's subject; else empty), name TEXT, is_default INT8 (0 or 1),
#     version INT8, modseq INT8 (the book's latest change number)
#   contact_cards          one row per card, kept as a tombstone on delete
#     id TEXT key, address_book_id TEXT, uid TEXT, kind TEXT (the CardKind
#     name), deleted INT8 (0 or 1), version INT8, modseq INT8, body TEXT (the
#     card's proto3 JSON without the server-written fields)
#   contact_card_uids      the live uids of each book: (address_book_id, uid)
#     is the key, so a uid is unique within one book and free in another.
#     card_id TEXT names the card holding it. A delete releases the uid; a
#     key naming no card or a tombstone is stale and a create takes it over.
#   contact_default_books  owner TEXT key, book_id TEXT: at most one default
#     PERSONAL book per owner. A claim naming no book is stale and the
#     owner's next default create takes it over.
#
# The tables carry no column scoping a row to a customer: one deployment
# holds one dataset.
#
# A document backend needs one composite index for the change feed's query
# (`address_book_id == ? AND modseq in a range ORDER BY modseq`), listed by
# `composite_indexes()`. Every other query is equalities only.
# =============================================================================

comptime BOOKS: StaticString = "contact_books"
comptime CARDS: StaticString = "contact_cards"
comptime CARD_UIDS: StaticString = "contact_card_uids"
comptime DEFAULT_BOOKS: StaticString = "contact_default_books"


def _strs(*items: StaticString) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(String(s))
    return out^


def book_cols() -> List[String]:
    return _strs("id", "kind", "owner", "name", "is_default", "version", "modseq")


def card_cols() -> List[String]:
    return _strs("id", "address_book_id", "uid", "kind", "deleted", "version", "modseq", "body")


def card_uid_cols() -> List[String]:
    return _strs("address_book_id", "uid", "card_id")


def default_book_cols() -> List[String]:
    return _strs("owner", "book_id")


def sqlite_schema() -> List[String]:
    """The SQLite `CREATE TABLE` statements of the four tables."""
    var out = List[String]()
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS contact_books (id TEXT PRIMARY KEY,"
            " kind TEXT NOT NULL, owner TEXT NOT NULL, name TEXT NOT NULL,"
            " is_default INTEGER NOT NULL, version INTEGER NOT NULL,"
            " modseq INTEGER NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS contact_cards (id TEXT PRIMARY KEY,"
            " address_book_id TEXT NOT NULL, uid TEXT NOT NULL,"
            " kind TEXT NOT NULL, deleted INTEGER NOT NULL,"
            " version INTEGER NOT NULL, modseq INTEGER NOT NULL,"
            " body TEXT NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE INDEX IF NOT EXISTS contact_cards_book_modseq ON"
            " contact_cards (address_book_id, modseq)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS contact_card_uids ("
            " address_book_id TEXT NOT NULL, uid TEXT NOT NULL,"
            " card_id TEXT NOT NULL, PRIMARY KEY (address_book_id, uid))"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS contact_default_books ("
            " owner TEXT PRIMARY KEY, book_id TEXT NOT NULL)"
        )
    )
    return out^


@fieldwise_init
struct CompositeIndex(Copyable, Movable):
    """A composite index a document backend must have: its table and its
    columns, in order, each ascending."""

    var table: String
    var cols: List[String]


def composite_indexes() -> List[CompositeIndex]:
    var out = List[CompositeIndex]()
    out.append(CompositeIndex(String(CARDS), _strs("address_book_id", "modseq")))
    return out^
