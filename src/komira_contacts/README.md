# `komira_contacts`

## Responsibility

The address books and cards of a simple contacts service, stored on any
`komira_db` `Database`, with the per-object access rules applied on every
call. The messages are
[`komira_contacts_proto`](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/README.md)'s.

- `ContactsStore[DB]`: create, read and list books; create, read, list,
  update and delete cards; the change feed of a book. It uses only the
  backend-neutral `Database` operations, so the same store runs on SQLite and
  on Firestore.
- A card's `uid` is unique within its address book and free in any other; a
  delete releases it.
- Every card write is a compare-and-set on the card's `version`: of two
  writes naming the same version, one succeeds and the other is refused with
  `contacts: version conflict`.
- Every card write and delete advances the book's `modseq` by one, in the same
  transaction as the card write; a refused write moves nothing. A delete keeps
  the card as a tombstone, so `changes(since)` reports it.
- `Caller` and the per-object rules: a PERSONAL book is its owner's alone, a
  SHARED book is read by everyone and written by an admin, a DIRECTORY book is
  read-only. A book the caller may not read is refused as not found, with the
  text of an id that does not exist. `Caller.admin` is the answer the
  deployment's authorization port gives to `admin` on the resource
  `{kind: "app", id}` (`AUTHZ_RESOURCE_KIND`, `ACTION_*`).
- `check_card` and `check_book_name`: what a client may write.
- `sqlite_schema()`: the SQLite tables. `composite_indexes()`: the one
  composite index a document backend needs (the change feed's query).

On a document backend each write is its own atomic write, and a rollback
deletes only the documents created since `begin`. A refused write is refused
before it writes, so it changes nothing there either. A write that stops part
way there is not undone: a uid key left naming no card or a tombstone is moved
to the next card created with that uid, a default-book claim left naming no
book is moved to the owner's next default book, and a card whose book did not
advance is listed in the change feed from the next write in the book. The
store claims a single writer per book, and one default-book create per owner
at a time, on such a backend. Postgres is not tested.

The store's contract is checked against SQLite and Firestore (over
`MockFirestore`) by
[`komira_contacts_store_conformance`](https://github.com/komira-ai/komira/blob/main/src/tests/conformance/komira_contacts_store_conformance/BUCK).

## API

| name | file | what it is |
|---|---|---|
| `ContactsStore` | [store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/store.mojo) | the store over a `Database` |
| `Caller`, `can_read_book`, `check_read_book`, `check_write_book`, `check_create_book` | [access.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/access.mojo) | who may read and write which book |
| `AUTHZ_RESOURCE_KIND`, `ACTION_READ`, `ACTION_WRITE`, `ACTION_ADMIN` | [access.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/access.mojo) | the authorization port's resource kind and actions |
| `check_card`, `check_book_name` | [validate.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/validate.mojo) | what a client may write |
| `sqlite_schema`, `composite_indexes`, `CompositeIndex`, `BOOKS`, `CARDS`, `CARD_UIDS`, `DEFAULT_BOOKS` | [schema.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/schema.mojo) | the tables |
| `ERR_NOT_FOUND`, `ERR_FORBIDDEN`, `ERR_VERSION_CONFLICT`, `ERR_UID_TAKEN`, `ERR_DEFAULT_TAKEN`, `ERR_INVALID` | [errors.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/errors.mojo) | the refusal texts |

## Example

Every example below runs as a test when the package is built.

Another subject's PERSONAL book is not found; a SHARED book is readable by
everyone and writable by an admin only:

```mojo
from komira_contacts import Caller, ERR_FORBIDDEN, ERR_NOT_FOUND, can_read_book, check_write_book
from komira_contacts_proto.contacts import BookKind
from std.testing import assert_equal, assert_false, assert_true

var bob = Caller(String("bob"), False)
assert_false(can_read_book(bob, BookKind.PERSONAL, String("alice")))
assert_true(can_read_book(bob, BookKind.SHARED, String("")))

var refusal = String()
try:
    check_write_book(bob, BookKind.PERSONAL, String("alice"))
except e:
    refusal = String(e)
assert_equal(refusal, ERR_NOT_FOUND)

try:
    check_write_book(bob, BookKind.SHARED, String(""))
except e:
    refusal = String(e)
assert_equal(refusal, ERR_FORBIDDEN)
```

A card is checked before it is stored:

```mojo
from komira_contacts import check_card
from komira_contacts_proto.contacts import Card
from komira_proto_codec import decode_json
from std.testing import assert_equal

var refusal = String()
try:
    check_card(decode_json[Card]('{"kind":"INDIVIDUAL","members":["urn:uuid:7f1c"]}'))
except e:
    refusal = String(e)
assert_equal(refusal, "contacts: invalid members: only a GROUP card has members")
```
