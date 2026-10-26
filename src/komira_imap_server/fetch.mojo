# FETCH and UID FETCH: FLAGS, UID, BODY[], BODY.PEEK[] and RFC822.
#
# Every other FETCH item that IMAP4rev1 defines (ENVELOPE, BODYSTRUCTURE,
# INTERNALDATE, RFC822.SIZE, RFC822.HEADER, RFC822.TEXT, BODY[<section>],
# partial fetches, the macros ALL, FAST and FULL) is recognised and refused
# with `NO [CANNOT]`; an item that is not IMAP at all is BAD. The refusal
# happens before any message is read, so a command never answers half its
# items.
#
# An item is a `FetchItem`: its kind and the text the client wrote (a later part
# parses a section, a partial range or a field list out of `text`). The parser
# is `parse_fetch_items`, the answer for one item is `emit_item`, and
# `_emit_messages` loops over the items of each message. A later part adds a
# kind to `_kind_of` (taking its name out of `_is_known_unsupported`) and a
# branch to `emit_item`.
#
# The message bytes go to the reply queue exactly as stored (a `{n}` literal
# of n raw bytes); nothing is decoded or re-encoded.

from komira_mail_store import FetchOutcome, fetch_message
from komira_objectstore.store import CloneableConditionalWriteStore

from .connection import ImapConnection
from .flags import (
    FLAG_SEEN,
    FlagSnapshot,
    MailboxFlagStore,
    flags_to_text,
)
from .limits import ImapServerConfig
from .parse import split_word, upper_ascii
from .reply import internal_error, tagged_bad, tagged_no_code, tagged_ok
from .sets import match_set, parse_id_set

comptime ITEM_FLAGS: Int = 0
comptime ITEM_UID: Int = 1
comptime ITEM_BODY: Int = 2  # BODY[]: sets \Seen
comptime ITEM_BODY_PEEK: Int = 3  # BODY.PEEK[]: does not
comptime ITEM_RFC822: Int = 4  # RFC822: sets \Seen
comptime ITEM_UNSUPPORTED: Int = 5
comptime ITEM_UNKNOWN: Int = 6


def _is_known_unsupported(item: String) -> Bool:
    """An IMAP4rev1 FETCH item this server does not implement (yet)."""
    if (
        item == "ENVELOPE"
        or item == "BODYSTRUCTURE"
        or item == "BODY"
        or item == "INTERNALDATE"
        or item == "RFC822.SIZE"
        or item == "RFC822.HEADER"
        or item == "RFC822.TEXT"
        or item == "ALL"
        or item == "FAST"
        or item == "FULL"
    ):
        return True
    # BODY[<section>], BODY[]<partial>, and the PEEK forms of both.
    if item.startswith("BODY[") or item.startswith("BODY.PEEK["):
        return True
    return False


struct FetchItem(Copyable, Movable):
    """One FETCH item: `kind` (an `ITEM_*`) and `text`, the item as the
    client wrote it."""

    var kind: Int
    var text: String

    def __init__(out self, kind: Int, var text: String):
        self.kind = kind
        self.text = text^


def _kind_of(item: String) -> Int:
    var up = upper_ascii(item)
    if up == "FLAGS":
        return ITEM_FLAGS
    if up == "UID":
        return ITEM_UID
    if up == "BODY[]":
        return ITEM_BODY
    if up == "BODY.PEEK[]":
        return ITEM_BODY_PEEK
    if up == "RFC822":
        return ITEM_RFC822
    if _is_known_unsupported(up):
        return ITEM_UNSUPPORTED
    return ITEM_UNKNOWN


def parse_fetch_items(spec: String) -> List[FetchItem]:
    """Each item in a FETCH item list: one item, or a
    parenthesised list. Brackets and parentheses inside an item (a section
    such as `HEADER.FIELDS (FROM TO)`) keep it in one piece. An empty result
    means the list is malformed (empty, or brackets that do not balance)."""
    var items = List[FetchItem]()
    var text = spec
    var bs = text.as_bytes()
    var n = len(bs)
    var begin = 0
    var end = n
    if n >= 2 and bs[0] == 0x28 and bs[n - 1] == 0x29:
        begin = 1
        end = n - 1
    var depth_b = 0
    var depth_p = 0
    var start = -1
    for i in range(begin, end + 1):
        var c = bs[i] if i < end else UInt8(0x20)
        var separator = c == 0x20 and depth_b == 0 and depth_p == 0
        if separator:
            if start >= 0:
                var word = String(unsafe_from_utf8=bs[start:i])
                var kind = _kind_of(word)
                items.append(FetchItem(kind, word^))
                start = -1
            continue
        if start < 0:
            start = i
        if c == 0x5B:
            depth_b += 1
        elif c == 0x5D:
            depth_b -= 1
        elif c == 0x28:
            depth_p += 1
        elif c == 0x29:
            depth_p -= 1
        if depth_b < 0 or depth_p < 0:
            return List[FetchItem]()
    if depth_b != 0 or depth_p != 0:
        return List[FetchItem]()
    return items^


def _has(items: List[FetchItem], kind: Int) -> Bool:
    for i in range(len(items)):
        if items[i].kind == kind:
            return True
    return False


def _count_bodies(items: List[FetchItem]) -> Int:
    var n = 0
    for i in range(len(items)):
        if (
            items[i].kind == ITEM_BODY
            or items[i].kind == ITEM_BODY_PEEK
            or items[i].kind == ITEM_RFC822
        ):
            n += 1
    return n


def view_keys(conn: ImapConnection, by_uid: Bool) -> List[Int]:
    """The key of each message of the view, ascending: its UID, or its
    sequence number."""
    var keys = List[Int](capacity=len(conn.view))
    for i in range(len(conn.view)):
        if by_uid:
            keys.append(conn.view[i].uid)
        else:
            keys.append(i + 1)
    return keys^


def star_value(conn: ImapConnection, by_uid: Bool) -> Int:
    """What `*` means in a set: the largest sequence number, or UID, in use."""
    var n = len(conn.view)
    if n == 0:
        return 0
    if by_uid:
        return conn.view[n - 1].uid
    return n


def handle_fetch[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    config: ImapServerConfig,
    tag: String,
    args: String,
    by_uid: Bool,
):
    """`FETCH <set> <items>` and `UID FETCH <set> <items>`. Answers one
    `* <seq> FETCH (...)` per message, in sequence order, then OK. A message
    deleted by another connection since SELECT ends the command with
    `NO [EXPUNGEISSUED]` after the others are answered."""
    var words = split_word(args)
    var set_text = words.first
    var item_text = words.rest
    if set_text.byte_length() == 0 or item_text.byte_length() == 0:
        tagged_bad(conn, tag, "FETCH needs a message set and items")
        return
    var ids = parse_id_set(set_text, star_value(conn, by_uid))
    if not ids.ok:
        tagged_bad(conn, tag, "Invalid message set")
        return
    var items = parse_fetch_items(item_text)
    if len(items) == 0 or _has(items, ITEM_UNKNOWN):
        tagged_bad(conn, tag, "Invalid FETCH item")
        return
    if _has(items, ITEM_UNSUPPORTED):
        tagged_no_code(
            conn, tag, "CANNOT", "This FETCH item is not supported"
        )
        return
    var picked = match_set(ids, view_keys(conn, by_uid))
    var bodies = _count_bodies(items)
    if bodies > 0:
        var total = 0
        for k in range(len(picked)):
            total += conn.view[picked[k]].size * bodies
        if total > config.limits.max_fetch_bytes:
            tagged_no_code(
                conn,
                tag,
                "LIMIT",
                "The response would be too large; fetch fewer messages",
            )
            return
    var missing = False
    try:
        missing = _emit_messages(
            conn, store, picked, items, by_uid, config.limits.compact_flag_log_at
        )
    except:
        internal_error(conn, tag)
        return
    if missing:
        tagged_no_code(
            conn,
            tag,
            "EXPUNGEISSUED",
            "Some of the requested messages no longer exist",
        )
        return
    tagged_ok(conn, tag, "FETCH completed")


def emit_item(
    mut conn: ImapConnection,
    item: FetchItem,
    uid: Int,
    bits: UInt8,
    msg_bytes: List[UInt8],
):
    """Queue the answer for one item of one message: `FLAGS (...)`, `UID n`,
    or a `{n}` literal of the message bytes. `msg_bytes` is empty unless the
    command asked for a body."""
    if item.kind == ITEM_FLAGS:
        conn.enqueue(String("FLAGS (") + flags_to_text(bits) + ")")
    elif item.kind == ITEM_UID:
        conn.enqueue(String("UID ") + String(uid))
    elif item.kind == ITEM_RFC822:
        conn.enqueue(String("RFC822 {") + String(len(msg_bytes)) + "}\r\n")
        conn.enqueue_bytes(Span(msg_bytes))
    elif item.kind == ITEM_BODY or item.kind == ITEM_BODY_PEEK:
        conn.enqueue(String("BODY[] {") + String(len(msg_bytes)) + "}\r\n")
        conn.enqueue_bytes(Span(msg_bytes))


def _emit_messages[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    picked: List[Int],
    items: List[FetchItem],
    by_uid: Bool,
    compact_at: Int,
) raises -> Bool:
    """Answer each picked message. True when one was missing from the store."""
    var wants_flags = _has(items, ITEM_FLAGS)
    var wants_uid = _has(items, ITEM_UID)
    var bodies = _count_bodies(items)
    var sets_seen = (
        not conn.read_only
        and (_has(items, ITEM_BODY) or _has(items, ITEM_RFC822))
    )
    var fstore = MailboxFlagStore[S](store.clone(), conn.scope)
    var snap = FlagSnapshot()
    if wants_flags or sets_seen:
        snap = fstore.snapshot()
    var missing = False
    var wrote = False
    for k in range(len(picked)):
        var at = picked[k]
        var uid = conn.view[at].uid
        var leaf = conn.view[at].leaf
        var bits = snap.flags_of(leaf)
        var got = FetchOutcome(False, List[UInt8](), String(""))
        if bodies > 0:
            got = fetch_message(store, conn.mailbox, conn.folder, leaf)
            if not got.found:
                missing = True
                continue
        var changed = False
        if sets_seen and (bits & FLAG_SEEN) == 0:
            bits = bits | FLAG_SEEN
            fstore.set_flags(leaf, bits)
            changed = True
            wrote = True
        conn.enqueue(String("* ") + String(at + 1) + " FETCH (")
        for i in range(len(items)):
            if i > 0:
                conn.enqueue(String(" "))
            emit_item(conn, items[i], uid, bits, got.bytes)
        if by_uid and not wants_uid:
            conn.enqueue(String(" UID ") + String(uid))
        if changed and not wants_flags:
            conn.enqueue(String(" FLAGS (") + flags_to_text(bits) + ")")
        conn.enqueue(String(")\r\n"))
    if wrote:
        fstore.compact_if_longer_than(compact_at)
    return missing
