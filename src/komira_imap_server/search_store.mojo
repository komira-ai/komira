# STORE, UID STORE and EXPUNGE, and the expunge that CLOSE does silently.
# (SEARCH will live here too; until then it is answered `NO [CANNOT]`.)
#
# STORE changes the durable flags (flags.mojo) of the messages a set names;
# EXPUNGE removes the \Deleted ones: it first drops their flags from the log,
# then deletes the message objects. If the delete fails the message stays,
# without its flags; the reverse order could leave a stale \Deleted flag that
# a later message of the same content would inherit and lose to an EXPUNGE.

from komira_mail_store import folder_message_key
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .connection import ImapConnection, ViewRow
from .fetch import star_value, view_keys
from .flags import (
    FLAG_DELETED,
    MailboxFlagStore,
    flag_bit_of,
    flags_to_text,
)
from .parse import split_word, upper_ascii
from .reply import (
    internal_error,
    tagged_bad,
    tagged_no_code,
    tagged_ok,
)
from .sets import match_set, parse_id_set


struct FlagList(Movable):
    """A parsed STORE flag list: `ok` False if it is not one; `bits` the
    system flags named; `unsupported` True if it also names a flag that this
    server cannot keep (`\\Recent`, a keyword)."""

    var ok: Bool
    var bits: UInt8
    var unsupported: Bool

    def __init__(out self):
        self.ok = False
        self.bits = UInt8(0)
        self.unsupported = False


def _flag_char(c: UInt8) -> Bool:
    """An ATOM-CHAR: printable ASCII except `( ) { SP % * " \\ ]`."""
    if c <= 0x20 or c > 0x7E:
        return False
    return not (
        c == 0x28
        or c == 0x29
        or c == 0x7B
        or c == 0x25
        or c == 0x2A
        or c == 0x22
        or c == 0x5C
        or c == 0x5D
    )


def parse_flag_list(text: String) -> FlagList:
    """`(\\Seen \\Deleted)` or the same without parentheses. `()` is the
    empty list."""
    var out = FlagList()
    var bs = text.as_bytes()
    var begin = 0
    var end = len(bs)
    if end > 0 and bs[0] == 0x28:
        if bs[end - 1] != 0x29 or end < 2:
            return out^
        begin = 1
        end -= 1
    var i = begin
    while i < end:
        while i < end and bs[i] == 0x20:
            i += 1
        if i >= end:
            break
        var start = i
        while i < end and bs[i] != 0x20:
            i += 1
        # bs[start:i] is one flag: an optional backslash, then atom characters.
        var j = start
        if bs[j] == 0x5C:
            j += 1
            if j == i:
                return out^
        while j < i:
            if not _flag_char(bs[j]):
                return out^
            j += 1
        var bit = flag_bit_of(String(unsafe_from_utf8=bs[start:i]))
        if bit == 0:
            out.unsupported = True
        out.bits = out.bits | bit
    out.ok = True
    return out^


def handle_store[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    compact_at: Int,
    tag: String,
    args: String,
    by_uid: Bool,
):
    """`STORE <set> <op> <flags>` and `UID STORE ...`, `op` being `+FLAGS`,
    `-FLAGS` or `FLAGS`, with `.SILENT` after any of them. Answers
    `* <seq> FETCH (FLAGS (...))` (plus `UID n` for UID STORE) for each
    message unless silent, then OK. Refused on a mailbox opened with EXAMINE."""
    if conn.read_only:
        tagged_no_code(conn, tag, "READ-ONLY", "The mailbox is read-only")
        return
    var first = split_word(args)
    var second = split_word(first.rest)
    var set_text = first.first
    var op_text = upper_ascii(second.first)
    var flag_text = second.rest
    if set_text.byte_length() == 0 or op_text.byte_length() == 0:
        tagged_bad(conn, tag, "STORE needs a message set, an operation and flags")
        return
    var silent = False
    if op_text.endswith(".SILENT"):
        silent = True
        var base = String(op_text[byte=0 : op_text.byte_length() - 7])
        op_text = base^
    if op_text != "+FLAGS" and op_text != "-FLAGS" and op_text != "FLAGS":
        tagged_bad(conn, tag, "Unknown STORE operation")
        return
    var flags = parse_flag_list(flag_text)
    if not flags.ok or flag_text.byte_length() == 0:
        tagged_bad(conn, tag, "Invalid flag list")
        return
    var ids = parse_id_set(set_text, star_value(conn, by_uid))
    if not ids.ok:
        tagged_bad(conn, tag, "Invalid message set")
        return
    if flags.unsupported:
        tagged_no_code(
            conn,
            tag,
            "CANNOT",
            "Only \\Seen, \\Answered, \\Flagged, \\Deleted and \\Draft can be stored",
        )
        return
    var picked = match_set(ids, view_keys(conn, by_uid))
    try:
        _apply_flags(
            conn, store, picked, op_text, flags.bits, silent, by_uid, compact_at
        )
    except:
        internal_error(conn, tag)
        return
    tagged_ok(conn, tag, "STORE completed")


def _apply_flags[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    picked: List[Int],
    op: String,
    named: UInt8,
    silent: Bool,
    by_uid: Bool,
    compact_at: Int,
) raises:
    var fstore = MailboxFlagStore[S](store.clone(), conn.scope)
    var snap = fstore.snapshot()
    var wrote = False
    for k in range(len(picked)):
        var at = picked[k]
        var uid = conn.view[at].uid
        var current = snap.flags_of(uid)
        var wanted = current
        if op == "+FLAGS":
            wanted = current | named
        elif op == "-FLAGS":
            wanted = current & ~named
        else:
            wanted = named
        if wanted != current:
            fstore.set_flags(uid, wanted)
            wrote = True
        if not silent:
            var line = String("* ") + String(at + 1) + " FETCH (FLAGS ("
            line += flags_to_text(wanted) + ")"
            if by_uid:
                line += String(" UID ") + String(uid)
            line += String(")\r\n")
            conn.enqueue(line)
    if wrote:
        fstore.compact_if_longer_than(compact_at)


def handle_expunge[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    compact_at: Int,
    tag: String,
    args: String,
):
    """`EXPUNGE`: delete every \\Deleted message of the folder, answering
    `* <seq> EXPUNGE` for each, highest first (so the numbers a client holds
    stay right), then OK."""
    if args.byte_length() > 0:
        tagged_bad(conn, tag, "EXPUNGE takes no arguments")
        return
    if conn.read_only:
        tagged_no_code(conn, tag, "READ-ONLY", "The mailbox is read-only")
        return
    if not expunge_deleted(conn, store, True, compact_at):
        internal_error(conn, tag)
        return
    tagged_ok(conn, tag, "EXPUNGE completed")


def expunge_deleted[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection, mut store: S, announce: Bool, compact_at: Int
) -> Bool:
    """Delete the \\Deleted messages of the selected folder and take them out
    of the view. With `announce`, queue `* <seq> EXPUNGE` for each (highest
    sequence number first). False if the store failed: the messages deleted
    until then are gone from the view, the rest are untouched."""
    var n = len(conn.view)
    if n == 0:
        return True
    var removed = List[Bool](capacity=n)
    for _ in range(n):
        removed.append(False)
    var ok = True
    try:
        var fstore = MailboxFlagStore[S](store.clone(), conn.scope)
        var snap = fstore.snapshot()
        var i = n - 1
        while i >= 0:
            var uid = conn.view[i].uid
            if (snap.flags_of(uid) & FLAG_DELETED) != 0:
                var leaf = conn.view[i].leaf
                fstore.expunge(uid)
                store.delete(
                    Path.parse(folder_message_key(conn.mailbox, conn.folder, leaf))
                )
                removed[i] = True
                if announce:
                    conn.enqueue(String("* ") + String(i + 1) + " EXPUNGE\r\n")
            i -= 1
        fstore.compact_if_longer_than(compact_at)
    except:
        ok = False
    var kept = List[ViewRow]()
    for k in range(n):
        if not removed[k]:
            kept.append(conn.view[k].copy())
    conn.view = kept^
    return ok
