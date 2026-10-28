# komira_mail_store

Received mail as content-addressed objects, Maildir style, in any
`komira_objectstore` conditional-write store. One message is one immutable
object:

```text
mailboxes/<recipient>/<content-hash>.eml             INBOX
mailboxes/<recipient>/<folder>/<content-hash>.eml    a named folder
```

The stored bytes are the message exactly as given; nothing is parsed or
rewritten. The leaf is the FNV-1a-64 hash of the bytes (16 hex digits,
`content_hash_hex`), so storing the same bytes again in the same folder is a
no-op. The library reads no environment and names no backend: the caller picks
the store, and every signature takes and returns values.

```mojo
from komira_objectstore import SharedInMemoryConditionalStore
from komira_mail_store import (
    content_hash_hex,
    fetch_message,
    list_folder,
    list_folders,
    message_exists,
    store_message,
)
from std.testing import assert_equal, assert_false, assert_true

var raw = List[UInt8]()
for b in "Subject: hello\r\n\r\nhi\r\n".as_bytes():
    raw.append(b)

var store = SharedInMemoryConditionalStore()
var stored = store_message(store, "Alice@Example.com", "INBOX", raw)
assert_true(stored.created)
assert_equal(stored.leaf, content_hash_hex(raw))
assert_equal(
    stored.key, "mailboxes/alice_40example.com/" + stored.leaf + ".eml"
)

# The same bytes again: the same key, nothing created.
var again = store_message(store, "alice@example.com", "INBOX", raw)
assert_false(again.created)
assert_equal(again.key, stored.key)

# Fetch returns the bytes verbatim; an absent leaf is `found = False`.
var got = fetch_message(store, "alice@example.com", "INBOX", stored.leaf)
assert_true(got.found)
assert_true(got.bytes == raw)
assert_false(
    fetch_message(store, "alice@example.com", "Sent", stored.leaf).found
)
assert_true(message_exists(store, "alice@example.com", "INBOX", stored.leaf))

# A named folder is a path segment; listings are in leaf order.
_ = store_message(store, "alice@example.com", "Archive/2026", raw)
var inbox = list_folder(store, "alice@example.com", "INBOX")
assert_equal(len(inbox), 1)
assert_equal(inbox[0].leaf, stored.leaf)
assert_equal(inbox[0].size, len(raw))
var names = list_folders(store, "alice@example.com")
assert_equal(names[0], "INBOX")
assert_equal(names[1], "archive/2026")
```

## Names

`normalize_recipient` turns an address into one path segment. ASCII letters
are lowercased (`Alice@example.com` and `alice@example.com` are one mailbox), `[a-z0-9.-]`
pass through, and every other byte, including `_`, becomes `_` and two
lowercase hex digits. Two addresses that differ in any other way get
different segments, and the segment never holds a `/`. An address that is
exactly `.` or `..` becomes `_2e` or `_2e.`, so no recipient is a dot
segment. An empty address raises.

`normalize_folder` keeps `/`, so a folder can be a hierarchy
(`Archive/2026`). `INBOX`, in any case and with blanks around it, is the flat
layout above. Any other name is lowercased, keeps `[a-z0-9._-/]`, and every
other byte becomes `_` (so `Sent Items` and `sent_items` are one folder). A
`/`-separated segment that is empty, `.` or `..` is written `%`, `%2e` or
`%2e.`; the mapping emits `%` nowhere else, so such a name cannot leave the
recipient's directory or share a key with another folder. An empty or blank
name raises.

What the two mappings do not distinguish, on purpose or because keys already
written depend on it:

- The folder fold is lossy. `Sent Items` and `sent_items` share a key. Each
  byte of a non-ASCII character becomes `__`, so `Caf` plus an accented `e`
  (two bytes) and `Caf` plus four spaces share a key too. Two folders that
  must stay apart need names that differ in `[A-Za-z0-9._-/]`.
- A recipient is case-folded for ASCII only and is not Unicode-normalized: an
  address in NFC and the same address in NFD are two mailboxes, and the
  full-width dot U+FF0E is not a dot. Routing decides which form it sends.

## Length limits

A store that keeps one object per file (the local file system store) writes
the whole key, each `/` as `%2F`, as one file name, and Linux allows 255
bytes. Escaping can triple an address, so the names are bounded at the call
that names them instead of failing later inside the store:

- a normalized recipient is at most `MAX_RECIPIENT_BYTES` (128) bytes, so a
  plain-letter address of 129 or more bytes, and a shorter one with many
  escaped bytes, raises in `normalize_recipient`;
- a normalized folder weighs at most `MAX_FOLDER_WEIGHT` (80), each byte
  counting 1 and each `/` or `%` counting 3 (`INBOX` has no limit).

At the limits a key is 246 bytes as a file name. A name inside the limits
always fits; a name outside them is refused even on a store that would take
it.

## Behaviour to know

- `store_message` creates the object only if it is absent. If it exists, the
  stored bytes are read back: equal bytes are a duplicate (`created` is
  False); different bytes under the same 64-bit hash raise, and the existing
  object is left alone.
- `fetch_message` and `message_exists` raise on a store failure other than
  absence, and on a leaf that is not 16 lowercase hex digits (the form
  `content_hash_hex` makes; a leaf is never free text). Absence and a lost
  conditional write are recognised in the store's error message with the key
  removed from it, so a folder named `Not_Found` or a recipient named
  `precondition` cannot make another failure read as one of them.
- `list_folder` shows a folder's own messages only (INBOX does not show a
  sub-folder's, a folder does not show its sub-folders'), skips objects whose
  name does not end in `.eml`, and sorts by leaf, so the order is the same on
  every store.
- `list_folders` returns INBOX first (always) and then the normalized names
  of the folders that hold a message, in byte order. On a store that folds a
  listing at the delimiter it lists each sub-folder in turn. The names are
  those in the keys: a folder written with an empty, `.` or `..` segment comes
  back with its `%` escape, and handing that name to `list_folder` or
  `fetch_message` normalizes it again (`%` becomes `_`) and names a different
  folder. Ordinary names such as `archive/2026` come back unchanged.
- A message is not authenticated or checked: this layer stores bytes. Whether
  the sender was who they claim is for the caller.
