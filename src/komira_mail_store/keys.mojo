# =============================================================================
# komira_mail_store/keys.mojo: the key layout of a stored message
# =============================================================================
#
#   mailboxes/<recipient>/<content-hash>.eml             (INBOX, the default)
#   mailboxes/<recipient>/<folder>/<content-hash>.eml    (a named folder)
#
# <recipient> is `normalize_recipient(address)`, <folder> is
# `normalize_folder(name)`, <content-hash> is `content_hash_hex(raw bytes)`.
# Pure String functions: nothing here touches a store.
#
# What the mapping guarantees, and what the callers (store, fetch, list) rely on:
#   * a normalized recipient or folder is within the length limits below, so a
#     key fits one file name of a one-object-per-file store;
#   * a recipient is ONE path segment and never a dot-only segment, so a
#     recipient cannot climb out of `mailboxes/` or alias another one;
#   * a folder is a `/`-separated hierarchy whose every segment is non-empty
#     and not `.` or `..`, so a folder cannot climb out of its recipient's
#     directory or alias another folder through the object store's own
#     normalization of `//`, `.` and `..`;
#   * an empty recipient or folder is refused (it raises), never mapped to a
#     placeholder another input also maps to.
# =============================================================================

# The canonical default folder. A message addressed to INBOX lands in the flat
# layout (`mailboxes/<recipient>/<hash>.eml`, no folder segment); any other
# folder gets a nested `<folder>/` segment.
comptime DEFAULT_FOLDER: String = "INBOX"

# Length limits, so a key always fits a store that keeps one object per file
# and writes the whole key (each `/` as `%2F`) as ONE file name of at most 255
# bytes: 12 (`mailboxes%2F`) + recipient + 3 + folder + 3 + 20 (hash and
# `.eml`) <= 12 + 128 + 3 + 80 + 3 + 20 = 246.
#   * MAX_RECIPIENT_BYTES: the longest normalized recipient segment. (Escaping
#     can triple an address, so a legal 254-byte address can exceed it.)
#   * MAX_FOLDER_WEIGHT: the longest normalized folder, counting every byte as
#     1 except `/` and `%`, which count 3 (their file-name spelling).
comptime MAX_RECIPIENT_BYTES: Int = 128
comptime MAX_FOLDER_WEIGHT: Int = 80


def content_hash_hex(bytes: List[UInt8]) -> String:
    """The FNV-1a-64 hash of `bytes` as 16 lowercase hex digits: the message
    leaf (a content address, sans `.eml`). Re-storing the same bytes in the
    same folder resolves to the same key."""
    var h = UInt64(14695981039346656037)  # FNV-1a-64 offset basis.
    var i = 0
    while i < len(bytes):
        h = h ^ UInt64(Int(bytes[i]))
        h = h * UInt64(1099511628211)
        i += 1
    var out = String("")
    var shift = 60
    while shift >= 0:
        out += _hex_nibble(Int((h >> UInt64(shift)) & UInt64(0xF)))
        shift -= 4
    return out^


def _hex_nibble(nib: Int) -> String:
    if nib < 10:
        return chr(0x30 + nib)
    return chr(0x61 + nib - 10)


def normalize_recipient(addr: String) raises -> String:
    """The mailbox segment of the address `addr`. Raises on an empty address
    and on one that is longer than MAX_RECIPIENT_BYTES once escaped.

    The mapping is injective up to the intended case fold: two addresses that
    differ in any byte other than the case of an ASCII letter give different
    segments.
      * ASCII letters are lowercased (`Alice@example.com` and `alice@example.com` are one
        mailbox).
      * `[a-z0-9.-]` pass through.
      * every other byte, including a literal `_`, becomes `_` and two
        lowercase hex digits of the byte (`_` is `_5f`, `@` is `_40`, `/` is
        `_2f`, a space is `_20`). So the output never holds a `/`.
      * a segment that would be exactly `.` or `..` is written `_2e` and
        `_2e.`: `_2e` otherwise never appears in an output (a `.` is never
        escaped), so these two cannot collide with another address, and the
        object store never sees a dot-only segment. `...` and `a..b` pass
        through unchanged.
    """
    var bs = addr.as_bytes()
    if len(bs) == 0:
        raise Error("normalize_recipient: the recipient is empty")
    var i = 0
    var out = String("")
    while i < len(bs):
        var orig = Int(bs[i])
        var c = orig
        if c >= ord("A") and c <= ord("Z"):
            c = c + 32
        var safe = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord(".")
            or c == ord("-")
        )
        if safe:
            out += chr(c)
        else:
            out += String("_")
            out += _hex_nibble((orig >> 4) & 0xF)
            out += _hex_nibble(orig & 0xF)
        i += 1
    if out.byte_length() > MAX_RECIPIENT_BYTES:
        raise Error(
            "normalize_recipient: the recipient is longer than "
            + String(MAX_RECIPIENT_BYTES)
            + " bytes once escaped"
        )
    if out == ".":
        return String("_2e")
    if out == "..":
        return String("_2e.")
    return out^


def normalize_folder(folder: String) raises -> String:
    """The key segment(s) of the folder name `folder`. Raises on an empty name
    (after trimming ASCII whitespace) and on one heavier than
    MAX_FOLDER_WEIGHT once normalized.

    `INBOX`, in any case, is the literal `INBOX`. Any other name is lowercased,
    keeps `[a-z0-9._-]` and `/` (a hierarchy such as `Archive/2026`), and
    every other byte becomes `_`. That fold is lossy (`Sent Items` and
    `sent_items` share a key); it is kept because changing it would move
    stored messages. A `/`-separated segment that is empty, `.` or `..` is
    escaped with `%` (`%`, `%2e`, `%2e.`), a byte the fold never emits, so such
    a name cannot reach another folder or leave the recipient's directory.
    """
    var t = _trim_ws(folder)
    if t.byte_length() == 0:
        raise Error("normalize_folder: the folder name is empty")
    if _eq_ignore_case(t, DEFAULT_FOLDER):
        return DEFAULT_FOLDER
    var bs = t.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        var c = Int(bs[i])
        if c >= ord("A") and c <= ord("Z"):
            c = c + 32
        var safe = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord(".")
            or c == ord("_")
            or c == ord("-")
            or c == ord("/")
        )
        if safe:
            out += chr(c)
        elif c >= 0x80:
            # Two `_` per non-ASCII byte: the keys written before this
            # package existed came from a fold that re-encoded each such byte
            # as a two-byte character first. Kept so those keys do not move.
            out += String("__")
        else:
            out += String("_")
        i += 1
    var escaped = _escape_dot_segments(out)
    if _folder_weight(escaped) > MAX_FOLDER_WEIGHT:
        raise Error(
            "normalize_folder: the folder name is heavier than "
            + String(MAX_FOLDER_WEIGHT)
            + " once normalized (each '/' and '%' counts 3 bytes)"
        )
    return escaped^


def _folder_weight(folder: String) -> Int:
    """The bytes `folder` takes in a file name: 1 each, 3 for `/` and `%`."""
    var bs = folder.as_bytes()
    var n = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("/")) or bs[i] == UInt8(ord("%")):
            n += 3
        else:
            n += 1
    return n


def _escape_dot_segments(folder: String) -> String:
    """`folder` with every `/`-separated segment that is empty, `.` or `..`
    written `%`, `%2e` or `%2e.`."""
    var bs = folder.as_bytes()
    var out = String("")
    var seg_start = 0
    var i = 0
    while i <= len(bs):
        if i == len(bs) or bs[i] == UInt8(ord("/")):
            var n = i - seg_start
            var is_dot = n == 1 and bs[seg_start] == UInt8(ord("."))
            var is_dotdot = (
                n == 2
                and bs[seg_start] == UInt8(ord("."))
                and bs[seg_start + 1] == UInt8(ord("."))
            )
            if n == 0:
                out += String("%")
            elif is_dot:
                out += String("%2e")
            elif is_dotdot:
                out += String("%2e.")
            else:
                out += String(folder[byte=seg_start:i])
            if i < len(bs):
                out += String("/")
            seg_start = i + 1
        i += 1
    return out^


def is_default_folder(folder: String) -> Bool:
    """True iff `folder` names INBOX (case-insensitive, ASCII whitespace
    trimmed): the flat layout."""
    return _eq_ignore_case(_trim_ws(folder), DEFAULT_FOLDER)


def folder_message_key(
    recipient: String, folder: String, msg_leaf: String
) raises -> String:
    """The object key of the message `msg_leaf` in `recipient`'s `folder`:
    `mailboxes/<recipient>/<folder>/<msg_leaf>.eml`, or for INBOX the flat
    `mailboxes/<recipient>/<msg_leaf>.eml`."""
    return folder_prefix(recipient, folder) + msg_leaf + String(".eml")


def message_key(recipient: String, msg_leaf: String) raises -> String:
    """The object key of the message `msg_leaf` in `recipient`'s INBOX."""
    return folder_message_key(recipient, DEFAULT_FOLDER, msg_leaf)


def mailbox_prefix(recipient: String) raises -> String:
    """`mailboxes/<recipient>/`: the prefix of everything one recipient holds."""
    return String("mailboxes/") + normalize_recipient(recipient) + String("/")


def folder_prefix(recipient: String, folder: String) raises -> String:
    """The listing prefix of `recipient`'s `folder`: `mailboxes/<recipient>/`
    for INBOX, `mailboxes/<recipient>/<folder>/` otherwise."""
    if is_default_folder(folder):
        return mailbox_prefix(recipient)
    return mailbox_prefix(recipient) + normalize_folder(folder) + String("/")


def _eq_ignore_case(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    var i = 0
    while i < len(ab):
        var ca = Int(ab[i])
        var cb = Int(bb[i])
        if ca >= ord("A") and ca <= ord("Z"):
            ca = ca + 32
        if cb >= ord("A") and cb <= ord("Z"):
            cb = cb + 32
        if ca != cb:
            return False
        i += 1
    return True


def _trim_ws(s: String) -> String:
    """`s` without leading and trailing ASCII space, tab, CR and LF."""
    var bs = s.as_bytes()
    var n = len(bs)
    var start = 0
    while start < n:
        var c = Int(bs[start])
        if c == 32 or c == 9 or c == 13 or c == 10:
            start += 1
            continue
        break
    var end = n
    while end > start:
        var c = Int(bs[end - 1])
        if c == 32 or c == 9 or c == 13 or c == 10:
            end -= 1
            continue
        break
    # The cut points follow ASCII bytes, so they are character boundaries.
    return String(s[byte=start:end])
