# `komira_chat_store`

## Responsibility

The storage of a small Slack-like chat, written once over komira_db's
backend-neutral `Database` trait so that it runs on a SQL database (SQLite,
Postgres) or a document store (Firestore) unchanged.

`ChatStore[DB, P]` holds:

- users, keyed by a token's issuer and subject (`ensure_user` creates the
  user the first time a subject is seen);
- public and private channels, DMs (one per set of 2 to 9 users) and their
  members;
- each channel's timeline: MESSAGE, EDIT, DELETE, JOIN and LEAVE events
  numbered 1, 2, 3, ... with no gaps, one-level threads, mentions, and
  read cursors (unread and mention counts);
- file records (pending, then complete);
- erasure of one user (`erase_user`, `erase_subject`): their rows go and their
  message bodies are redacted.

The kinds and states it stores carry the numbers of `komira.chat.v1`
(komira_chat_proto): `CHANNEL_PUBLIC`, `CHANNEL_PRIVATE`, `CHANNEL_DM`;
`EVENT_MESSAGE` to `EVENT_LEAVE`; `FILE_PENDING`, `FILE_COMPLETE`.

A SQL backend gets its schema from `chat_migrations()` (run with komira_db's
`MigrationRunner` and the `CHAT_MIGRATION_LEDGER` table), and each connection
goes through `prepare_sql_connection`; after an erasure on SQLite,
`finish_sql_erasure` moves the write-ahead log into the database file so the
erased bytes are gone from both. A document store declares
`CHAT_DOCUMENT_KEYS` (the key column of each table) and
`CHAT_DOCUMENT_INDEXES` (the composite indexes the store's queries need).

No pointer crosses the package's API: values, `List`s and `ref` accessors
only.

## API

Everything is exported from `komira_chat_store`:

- `ChatStore[DB: Database, P: SendProbe = NoSendProbe](db, probe)`: every
  operation takes the caller's async runtime and reactor (`[RT](reactor,
  ...)`) and a `now_ms` where it writes. `SendProbe` is a test seam called
  inside a send, between reading the channel's head and inserting the next
  event; `NoSendProbe` does nothing.
- The records it returns: `ChatUser`, `ChatChannel`, `ChatMember`,
  `ChatEvent`, `ChatFile`, `ReadState`, `MentionRef`, and the pages
  `EventPage`, `MentionPage` and `IdPage` (at most `MAX_PAGE_SIZE` items);
  `EraseCounts`.
- The pure helpers: `is_valid_id` (1 to `MAX_ID_BYTES` bytes of
  `A-Z a-z 0-9 _ -`), `subject_key`, `dm_channel_id`, `join_ids`, `split_ids`.
- The schema: `chat_migrations`, the table names (`T_USERS`, `T_EVENTS`, ...),
  `CHAT_DOCUMENT_KEYS`, `CHAT_DOCUMENT_INDEXES`.

A store over SQLite, in outline (the package's own tests run every call this
way, with komira_db_sqlite):

```text
var store = ChatStore[SqliteDatabase, NoSendProbe](db^, NoSendProbe())
var ada = store.ensure_user[RT](reactor, "u-ada", iss, sub, "Ada", "", now_ms)
_ = store.create_channel[RT](reactor, "general", CHANNEL_PUBLIC, "general", "",
                             "u-ada", List[String](), now_ms)
var event = store.send_message[RT](reactor, "general", "u-ada", "hello", 0,
                                   "client-msg-1", List[String](), False,
                                   List[String](), now_ms)
# event.seq is the next number of the channel's timeline.
```

## Examples

Every example below runs as a test when the package is built. They use the
pure helpers and the schema, which need no database.

Ids are short and plain, so an id can never hold the `,` an id list is joined
with, the `.` of a DM id, or a `/` a document store cannot name a document
with. A list of ids is stored joined, and splits back to the same list:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_chat_store import MAX_ID_BYTES, dm_channel_id, is_valid_id, join_ids, split_ids, subject_key

assert_true(is_valid_id(String("u-Ada_09")))
assert_false(is_valid_id(String("")))
assert_false(is_valid_id(String("a,b")))
assert_false(is_valid_id(String("a.b")))
assert_false(is_valid_id(String("a/b")))

var longest = String()
for _ in range(MAX_ID_BYTES):
    longest += "x"
assert_true(is_valid_id(longest))
assert_false(is_valid_id(longest + "x"))

var ids: List[String] = [String("u-ada"), String("u-bob"), String("u-cy")]
assert_equal(join_ids(ids), "u-ada,u-bob,u-cy")
var back = split_ids(join_ids(ids))
assert_equal(len(back), len(ids))
for i in range(len(ids)):
    assert_equal(back[i], ids[i])
assert_equal(len(split_ids(String(""))), 0)
```

A user is found by the subject key of their token's issuer and subject. The
issuer's length leads the key, so two different pairs never share one, even
when their concatenations are the same text:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from komira_chat_store import subject_key
-->
```mojo
assert_equal(subject_key(String("a"), String("bc")), "1:abc")
assert_equal(subject_key(String("ab"), String("c")), "2:abc")
assert_true(subject_key(String("a"), String("bc")) != subject_key(String("ab"), String("c")))
```

One set of users has one DM: its id is `dm-` and the sorted users joined by
`.`, whatever the order or repeats it was asked with. A DM holds 2 to 9
distinct valid users:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false
from komira_chat_store import dm_channel_id, is_valid_id
-->
```mojo
def raised_by(ids: List[String]) -> String:
    try:
        _ = dm_channel_id(ids)
    except e:
        return String(e)
    return String()

assert_equal(dm_channel_id([String("u-bob"), String("u-ada")]), "dm-u-ada.u-bob")
assert_equal(dm_channel_id([String("u-ada"), String("u-bob"), String("u-ada")]), "dm-u-ada.u-bob")
assert_false(is_valid_id(dm_channel_id([String("u-bob"), String("u-ada")])))

assert_equal(raised_by([String("u-ada"), String("u-ada")]), "komira_chat_store: a DM holds 2 to 9 distinct users, not 1")
assert_equal(raised_by([String("u-ada"), String("u,bob")]), 'komira_chat_store: invalid user id "u,bob"')
```

The SQL schema is an ordered chain of steps numbered from 1, each with its
own ledger name (the ledger records names, so a re-run applies nothing). The
document-store declarations name only the store's tables:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_chat_store import CHAT_DOCUMENT_INDEXES, CHAT_DOCUMENT_KEYS, T_CHANNELS, T_CURSORS, T_EVENTS, T_FILES, T_MEMBERS, T_MENTIONS, T_SUBJECTS, T_USERS, chat_migrations

var steps = chat_migrations()
assert_true(len(steps) > 0)
for i in range(len(steps)):
    assert_equal(steps[i].version, i + 1)
    assert_true(steps[i].up_sql.byte_length() > 0)
    for j in range(i):
        assert_true(steps[j].name != steps[i].name)

def is_chat_table(name: String) -> Bool:
    var tables: List[String] = [
        String(T_SUBJECTS), String(T_USERS), String(T_CHANNELS), String(T_MEMBERS),
        String(T_EVENTS), String(T_MENTIONS), String(T_CURSORS), String(T_FILES),
    ]
    for i in range(len(tables)):
        if name == tables[i]:
            return True
    return False

# One `table|column` per line.
var keys_text = String(CHAT_DOCUMENT_KEYS)
for line in keys_text.splitlines():
    var parts = line.split("|")
    assert_equal(len(parts), 2)
    assert_true(is_chat_table(String(parts[0])))

# One `table|column:MODE|...` per line, after `#` comments naming the query.
var indexes_text = String(CHAT_DOCUMENT_INDEXES)
var indexes = 0
for line in indexes_text.splitlines():
    if line.startswith("#"):
        continue
    assert_true(is_chat_table(String(line.split("|")[0])))
    indexes += 1
assert_true(indexes > 0)
```
