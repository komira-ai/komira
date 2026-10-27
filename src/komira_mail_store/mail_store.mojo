# =============================================================================
# komira_mail_store/mail_store.mojo: store, fetch and list received mail
# =============================================================================
#
# Each received message is ONE immutable, content-addressed object in any
# `ConditionalWriteStore`, laid out Maildir-style (keys.mojo):
#
#   mailboxes/<recipient>/<content-hash>.eml             (INBOX)
#   mailboxes/<recipient>/<folder>/<content-hash>.eml    (a named folder)
#
# The stored bytes are the message exactly as given: nothing is parsed or
# rewritten on the way in. Re-storing the same bytes in the same folder is a
# no-op that reports `created = False`.
#
# Values only: the store is threaded by `mut` reference, bytes are
# `List[UInt8]`, keys and ids are `String`. No pointer type appears in any
# signature of this package.
# =============================================================================

from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_mail_store.keys import (
    DEFAULT_FOLDER,
    content_hash_hex,
    folder_message_key,
    folder_prefix,
    mailbox_prefix,
)


@fieldwise_init
struct StoreOutcome(Copyable, Movable, Deinitable):
    """What `store_message` did.

    `key` is the object key; `leaf` is the content hash it ends in (sans
    `.eml`), the id `fetch_message` takes. `created` is False when the same
    bytes were already stored in that folder."""

    var key: String
    var leaf: String
    var created: Bool


def store_message[
    S: ConditionalWriteStore,
](
    mut s: S,
    recipient: String,
    folder: String,
    raw: List[UInt8],
) raises -> StoreOutcome:
    """Store the message `raw` verbatim in `recipient`'s `folder` (`INBOX`
    for the default folder), keyed by its content hash.

    The write creates the object only if it is absent. When it already exists
    the stored bytes are read back and compared: equal bytes are a duplicate
    (`created = False`, the same key); different bytes under the same 64-bit
    hash raise, so a hash collision can never silently drop a message.

    Raises on an empty recipient or folder, on a recipient or folder over the
    length limits (MAX_RECIPIENT_BYTES, MAX_FOLDER_WEIGHT: a key must fit one
    file name of a store that keeps an object per file), and on a store
    failure."""
    var leaf = content_hash_hex(raw)
    var key = folder_message_key(recipient, folder, leaf)
    var p = Path.parse(key)
    try:
        _ = s.conditional_put(p, raw, WritePrecondition.if_none_match_star())
    except e:
        if not is_precondition(_without_key(String(e), key)):
            raise e^
        var existing = s.get(p)
        if existing != raw:
            raise Error(
                "store_message: two different messages share the content"
                " hash "
                + leaf
                + " in "
                + key
            )
        return StoreOutcome(key^, leaf^, False)
    return StoreOutcome(key^, leaf^, True)


@fieldwise_init
struct FetchOutcome(Movable, Deinitable):
    """What `fetch_message` found: `found` is False for an absent message (then
    `bytes` is empty). `etag` is the store's ETag of the object."""

    var found: Bool
    var bytes: List[UInt8]
    var etag: String


def _check_leaf(leaf: String) raises:
    """A leaf is what `content_hash_hex` produces: exactly 16 lowercase hex
    digits. Nothing else is a message of this store, and refusing the rest
    keeps free text (a `/`, an error marker, control bytes, an upper-case
    spelling that a case-insensitive file system would alias) out of keys and
    out of the error messages that quote them."""
    var bs = leaf.as_bytes()
    if len(bs) != 16:
        raise Error("mail leaf must be 16 lowercase hex digits")
    var i = 0
    while i < len(bs):
        var c = Int(bs[i])
        var digit = c >= ord("0") and c <= ord("9")
        var lower = c >= ord("a") and c <= ord("f")
        if not (digit or lower):
            raise Error("mail leaf must be 16 lowercase hex digits")
        i += 1


def _hex_upper(nib: Int) -> String:
    if nib < 10:
        return chr(0x30 + nib)
    return chr(0x41 + nib - 10)


def _file_name_of(key: String) -> String:
    """`key` as one file name the way a one-object-per-file store writes it:
    every byte outside `[A-Za-z0-9._-]` as `%XX` (upper-case hex)."""
    var bs = key.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        var c = Int(bs[i])
        var safe = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord(".")
            or c == ord("_")
            or c == ord("-")
        )
        if safe:
            out += chr(c)
        else:
            out += String("%") + _hex_upper(c >> 4) + _hex_upper(c & 0xF)
        i += 1
    return out^


def _without_key(msg: String, key: String) -> String:
    """`msg` with `key`, and `key` as a file name, cut out. The store's error
    classifiers (`is_not_found`, `is_precondition`) look for words anywhere in
    a message, and a store quotes the key in its message: a folder `Not_Found`
    (key `.../not_found/...`) or a recipient `precondition@...` would make any
    failure on that key read as absence or as a lost write. A key is lowercase
    apart from the file-name escapes and never holds `[`, `]` or `=`, so these
    two words are the only markers it can spell; classify what is left."""
    return msg.replace(key, String("")).replace(_file_name_of(key), String(""))


def fetch_message[
    S: ConditionalWriteStore,
](
    mut s: S,
    recipient: String,
    folder: String,
    leaf: String,
) raises -> FetchOutcome:
    """The message `leaf` of `recipient`'s `folder`: `found = False` when it is
    absent, its bytes exactly as stored otherwise. Raises on an empty
    recipient or folder, on a leaf that is not 16 lowercase hex digits, and on
    any store failure other than absence."""
    _check_leaf(leaf)
    var key = folder_message_key(recipient, folder, leaf)
    var p = Path.parse(key)
    try:
        var meta = s.head(p)
        var bytes = s.get(p)
        return FetchOutcome(True, bytes^, meta.etag)
    except e:
        if is_not_found(_without_key(String(e), key)):
            return FetchOutcome(False, List[UInt8](), String(""))
        raise e^


def message_exists[
    S: ConditionalWriteStore,
](
    mut s: S,
    recipient: String,
    folder: String,
    leaf: String,
) raises -> Bool:
    """True iff the message `leaf` is in `recipient`'s `folder`. Raises under
    the same conditions as `fetch_message`."""
    _check_leaf(leaf)
    var key = folder_message_key(recipient, folder, leaf)
    var p = Path.parse(key)
    try:
        _ = s.head(p)
        return True
    except e:
        if is_not_found(_without_key(String(e), key)):
            return False
        raise e^


@fieldwise_init
struct MailEntry(Copyable, Movable, Deinitable):
    """One stored message in a listing: its leaf (content hash, sans `.eml`)
    and its size in bytes."""

    var leaf: String
    var size: Int


def list_folder[
    S: ConditionalWriteStore,
](mut s: S, recipient: String, folder: String) raises -> List[MailEntry]:
    """The messages stored in `recipient`'s `folder`, sorted by leaf (byte
    order), so the order is the same on every store.

    A folder lists only its own messages: INBOX does not show a sub-folder's,
    and a folder does not show its sub-folders'. Objects whose name does not
    end in `.eml` are not messages and are skipped. Raises on an empty
    recipient or folder and on a store failure."""
    var prefix = folder_prefix(recipient, folder)
    var listing = s.list_with_delimiter(Path.parse(prefix))
    var found = List[MailEntry]()
    var i = 0
    while i < len(listing.objects):
        ref obj = listing.objects[i]
        i += 1
        var rest = _after_prefix(obj.location, prefix)
        if _contains_slash(rest):
            continue
        var leaf = _strip_eml(rest)
        if leaf.byte_length() == 0:
            continue
        found.append(MailEntry(leaf^, Int(obj.size)))
    return _sorted_by_leaf(found^)


def list_folders[
    S: ConditionalWriteStore,
](mut s: S, recipient: String) raises -> List[String]:
    """The folder names under `recipient`, as the normalized path segments
    that appear in the keys (`archive`, `archive/2026`, `sent`): INBOX first
    (always present), then the others in byte order. Only a folder that holds
    a message itself is listed.

    These are the names as they appear in keys, not the names a caller passed
    in: a folder written with an empty, `.` or `..` segment shows its `%`
    escape (`%`, `%2e`, `%2e.`), and passing such a name back to a function
    that takes a folder normalizes it again (`%` becomes `_`), which names a
    different folder. Ordinary names (`archive/2026`) come back as they went in.

    A store that folds a listing at the delimiter (an object store) reports a
    sub-folder only as a common prefix, so each one is listed in turn; a store
    that lists every key under the prefix needs no further call."""
    var root = mailbox_prefix(recipient)
    var folders = List[String]()
    folders.append(DEFAULT_FOLDER)
    var pending = List[String]()
    pending.append(root)
    var next = 0
    while next < len(pending):
        var prefix = pending[next]
        next += 1
        var listing = s.list_with_delimiter(Path.parse(prefix))
        var i = 0
        while i < len(listing.objects):
            ref obj = listing.objects[i]
            i += 1
            var rest = _after_prefix(obj.location, root)
            var cut = _last_slash(rest)
            if cut <= 0 or not rest.endswith(String(".eml")):
                # A flat INBOX message, or not a message.
                continue
            var name = String(rest[byte=0:cut])
            if not _list_contains(folders, name):
                folders.append(name^)
        var j = 0
        while j < len(listing.common_prefixes):
            var cp = listing.common_prefixes[j]
            j += 1
            if cp.startswith(root) and not _list_contains(pending, cp):
                pending.append(cp^)
    return _sorted_folders(folders^)


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _after_prefix(key: String, prefix: String) -> String:
    """`key` after `prefix`; empty if `key` does not start with it. The prefix
    is ASCII, so the cut is a character boundary."""
    if not key.startswith(prefix):
        return String("")
    return String(key[byte=prefix.byte_length() : key.byte_length()])


def _strip_eml(name: String) -> String:
    """`name` without a trailing `.eml`; empty if it has none."""
    var suffix = String(".eml")
    if not name.endswith(suffix):
        return String("")
    return String(name[byte=0 : name.byte_length() - suffix.byte_length()])


def _contains_slash(s: String) -> Bool:
    return _last_slash(s) >= 0


def _last_slash(s: String) -> Int:
    var bs = s.as_bytes()
    var i = len(bs) - 1
    while i >= 0:
        if bs[i] == UInt8(ord("/")):
            return i
        i -= 1
    return -1


def _list_contains(lst: List[String], v: String) -> Bool:
    var i = 0
    while i < len(lst):
        if lst[i] == v:
            return True
        i += 1
    return False


def _bytes_gt(a: String, b: String) -> Bool:
    """True iff `a` sorts after `b` in byte order."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    var i = 0
    while i < n:
        if ab[i] != bb[i]:
            return Int(ab[i]) > Int(bb[i])
        i += 1
    return len(ab) > len(bb)


def _folder_gt(a: String, b: String) -> Bool:
    """True iff `a` sorts after `b`, INBOX first and the rest in byte order."""
    if a == DEFAULT_FOLDER:
        return False
    if b == DEFAULT_FOLDER:
        return True
    return _bytes_gt(a, b)


def _sorted_folders(var lst: List[String]) -> List[String]:
    """Insertion sort: a mailbox has few folders."""
    var n = len(lst)
    var i = 1
    while i < n:
        var key = lst[i]
        var j = i - 1
        while j >= 0 and _folder_gt(lst[j], key):
            lst[j + 1] = lst[j]
            j -= 1
        lst[j + 1] = key^
        i += 1
    return lst^


def _sorted_by_leaf(var entries: List[MailEntry]) -> List[MailEntry]:
    """Entries ordered by leaf. A bottom-up merge sort over indices: a
    mailbox can hold many thousands of messages, so no quadratic sort."""
    var n = len(entries)
    var order = List[Int](capacity=n)
    for k in range(n):
        order.append(k)
    var scratch = List[Int](capacity=n)
    for k in range(n):
        scratch.append(0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = lo + width if lo + width < n else n
            var hi = lo + 2 * width if lo + 2 * width < n else n
            var a = lo
            var b = mid
            var o = lo
            while a < mid and b < hi:
                # Take from the right run only when it is strictly smaller,
                # which keeps the sort stable.
                if _bytes_gt(entries[order[a]].leaf, entries[order[b]].leaf):
                    scratch[o] = order[b]
                    b += 1
                else:
                    scratch[o] = order[a]
                    a += 1
                o += 1
            while a < mid:
                scratch[o] = order[a]
                a += 1
                o += 1
            while b < hi:
                scratch[o] = order[b]
                b += 1
                o += 1
            lo += 2 * width
        var spare = order^
        order = scratch^
        scratch = spare^
        width *= 2
    var out = List[MailEntry](capacity=n)
    for k in range(n):
        out.append(entries[order[k]].copy())
    return out^
