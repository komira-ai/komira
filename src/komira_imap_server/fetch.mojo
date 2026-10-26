# FETCH and UID FETCH: FLAGS, UID, INTERNALDATE, RFC822.SIZE, ENVELOPE,
# BODYSTRUCTURE, BODY, BODY[<section>]<partial>, BODY.PEEK[...], RFC822,
# RFC822.HEADER, RFC822.TEXT and the macros ALL, FAST and FULL (which expand to
# the items they name). An item that is not IMAP at all is BAD.
#
# An item is a `FetchItem`: its kind and the text the client wrote, and for a
# BODY item its parsed section (section.mojo). The parser is
# `parse_fetch_items`, and `_emit_messages` answers each message in two steps:
# `_resolve` works out every item (the structures are built, the section bytes
# are located) and may fail on a message the MIME limits refuse, in which case
# nothing at all is sent for that message and the command ends
# `NO [UNAVAILABLE]` after the others; `emit_item` then queues the answers,
# which cannot fail. The message is read from the store once, parsed at most
# once (and only for BODYSTRUCTURE, BODY and a numbered section), and the
# section bytes go to the reply queue from a borrowed view of those bytes: one
# copy, no copy per item.
#
# Mail that a MIME parse refuses (no multipart boundary, too many parts, too
# deep) can still be read whole, by its header and its text, and ENVELOPE and
# INTERNALDATE read only the header block: only BODYSTRUCTURE, BODY and a
# numbered section need the parse.
#
# \Seen is set by BODY[...] (not BODY.PEEK), RFC822 and RFC822.TEXT on a
# folder opened read-write, durably, and only for a message that is answered.

from komira_mail_message import Message
from komira_mail_store import FetchOutcome, fetch_message
from komira_objectstore.store import CloneableConditionalWriteStore

from .bodystructure import body_structure_bytes, envelope_bytes
from .connection import ImapConnection
from .dates import format_internal_date, internal_date_ms
from .flags import (
    FLAG_SEEN,
    FlagSnapshot,
    MailboxFlagStore,
    flags_to_text,
)
from .headers import scan_fields
from .imapstr import append_text
from .limits import ImapServerConfig
from .parse import split_word, upper_ascii
from .reply import internal_error, tagged_bad, tagged_no_code, tagged_ok
from .section import (
    LOC_BODY,
    LOC_HEADER,
    LOC_NIL,
    LOC_OWNED,
    LOC_RAW,
    SEC_HEADER,
    SEC_TEXT,
    Located,
    SectionSpec,
    apply_partial,
    ensure_top,
    locate,
    parse_body_item,
    render_section,
)
from .sets import match_set, parse_id_set

comptime ITEM_FLAGS: Int = 0
comptime ITEM_UID: Int = 1
comptime ITEM_BODY: Int = 2  # BODY[<section>]<partial>: sets \Seen
comptime ITEM_BODY_PEEK: Int = 3  # BODY.PEEK[<section>]<partial>: does not
comptime ITEM_RFC822: Int = 4  # RFC822: sets \Seen
comptime ITEM_UNKNOWN: Int = 6
comptime ITEM_ENVELOPE: Int = 7
comptime ITEM_BODYSTRUCTURE: Int = 8
comptime ITEM_BODY_SHORT: Int = 9  # BODY: the structure without extension data
comptime ITEM_RFC822_SIZE: Int = 10
comptime ITEM_RFC822_HEADER: Int = 11  # does not set \Seen
comptime ITEM_RFC822_TEXT: Int = 12  # sets \Seen
comptime ITEM_INTERNALDATE: Int = 13

# What `_emit_messages` reports.
comptime _MISSING: Int = 1
comptime _UNAVAILABLE: Int = 2


struct FetchItem(Copyable, Movable):
    """One FETCH item: `kind` (an `ITEM_*`), `text`, the item as the client
    wrote it, and `sec`, the parsed section of a BODY item."""

    var kind: Int
    var text: String
    var sec: SectionSpec

    def __init__(out self, kind: Int, var text: String):
        self.kind = kind
        self.text = text^
        self.sec = SectionSpec()

    def __init__(out self, kind: Int, var text: String, var sec: SectionSpec):
        self.kind = kind
        self.text = text^
        self.sec = sec^


def _item_of(word: String) -> FetchItem:
    var up = upper_ascii(word)
    var kind = ITEM_UNKNOWN
    if up == "FLAGS":
        kind = ITEM_FLAGS
    elif up == "UID":
        kind = ITEM_UID
    elif up == "RFC822":
        kind = ITEM_RFC822
    elif up == "ENVELOPE":
        kind = ITEM_ENVELOPE
    elif up == "BODYSTRUCTURE":
        kind = ITEM_BODYSTRUCTURE
    elif up == "BODY":
        kind = ITEM_BODY_SHORT
    elif up == "RFC822.SIZE":
        kind = ITEM_RFC822_SIZE
    elif up == "RFC822.HEADER":
        kind = ITEM_RFC822_HEADER
    elif up == "RFC822.TEXT":
        kind = ITEM_RFC822_TEXT
    elif up == "INTERNALDATE":
        kind = ITEM_INTERNALDATE
    elif up.startswith("BODY[") or up.startswith("BODY.PEEK["):
        var spec = parse_body_item(word)
        if spec.ok:
            var k = ITEM_BODY
            if up.startswith("BODY.PEEK["):
                k = ITEM_BODY_PEEK
            return FetchItem(k, word, spec^)
    return FetchItem(kind, word)


def _add_macro(mut items: List[FetchItem], up: String) -> Bool:
    """Expand ALL, FAST and FULL into the items they stand for."""
    if up != "ALL" and up != "FAST" and up != "FULL":
        return False
    items.append(_item_of(String("FLAGS")))
    items.append(_item_of(String("INTERNALDATE")))
    items.append(_item_of(String("RFC822.SIZE")))
    if up == "ALL" or up == "FULL":
        items.append(_item_of(String("ENVELOPE")))
    if up == "FULL":
        items.append(_item_of(String("BODY")))
    return True


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
                if not _add_macro(items, upper_ascii(word)):
                    items.append(_item_of(word))
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


def _reads_message(items: List[FetchItem]) -> Bool:
    """True when an item needs the message's bytes."""
    for i in range(len(items)):
        var k = items[i].kind
        if k != ITEM_FLAGS and k != ITEM_UID and k != ITEM_RFC822_SIZE:
            return True
    return False


def _returned_bytes(items: List[FetchItem], size: Int) -> Int:
    """The most message bytes the items return for a message of `size`: a
    section is bounded by the message (and by its partial length)."""
    var total = 0
    for i in range(len(items)):
        var k = items[i].kind
        if (
            k == ITEM_BODY
            or k == ITEM_BODY_PEEK
            or k == ITEM_RFC822
            or k == ITEM_RFC822_HEADER
            or k == ITEM_RFC822_TEXT
        ):
            var part = size
            if k == ITEM_BODY or k == ITEM_BODY_PEEK:
                if items[i].sec.has_partial and items[i].sec.length < part:
                    part = items[i].sec.length
            total += part
    return total


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
    `NO [EXPUNGEISSUED]` after the others are answered, and one the MIME
    limits refuse with `NO [UNAVAILABLE]`."""
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
    var picked = match_set(ids, view_keys(conn, by_uid))
    if _reads_message(items):
        var returned = 0
        var scanned = 0
        for k in range(len(picked)):
            var size = conn.view[picked[k]].size
            scanned += size
            returned += _returned_bytes(items, size)
        if returned > config.limits.max_fetch_bytes:
            tagged_no_code(
                conn,
                tag,
                "LIMIT",
                "The response would be too large; fetch fewer messages",
            )
            return
        if scanned > config.limits.max_scan_bytes:
            tagged_no_code(
                conn,
                tag,
                "LIMIT",
                "Too many message bytes to read; fetch fewer messages",
            )
            return
    var outcome = 0
    try:
        outcome = _emit_messages(
            conn, store, picked, items, by_uid, config.limits.compact_flag_log_at
        )
    except:
        internal_error(conn, tag)
        return
    if (outcome & _MISSING) != 0:
        tagged_no_code(
            conn,
            tag,
            "EXPUNGEISSUED",
            "Some of the requested messages no longer exist",
        )
        return
    if (outcome & _UNAVAILABLE) != 0:
        tagged_no_code(
            conn,
            tag,
            "UNAVAILABLE",
            "Some messages could not be read as MIME within the limits",
        )
        return
    tagged_ok(conn, tag, "FETCH completed")


struct Resolved(Copyable, Movable):
    """The answer to one item of one message, worked out: `head`, the bytes
    that come first (the whole answer for a structure), and `loc`, the
    section bytes that follow the head."""

    var head: List[UInt8]
    var loc: Located

    def __init__(out self):
        self.head = List[UInt8]()
        self.loc = Located()


def _spec_of(item: FetchItem) -> SectionSpec:
    """The section an item asks for: its own for a BODY item, the whole
    message, its header or its text for the RFC822 forms."""
    if item.kind == ITEM_BODY or item.kind == ITEM_BODY_PEEK:
        return item.sec.copy()
    var spec = SectionSpec()
    spec.ok = True
    if item.kind == ITEM_RFC822_HEADER:
        spec.suffix = SEC_HEADER
    elif item.kind == ITEM_RFC822_TEXT:
        spec.suffix = SEC_TEXT
    return spec^


def _name_of(item: FetchItem) -> String:
    if item.kind == ITEM_RFC822:
        return String("RFC822")
    if item.kind == ITEM_RFC822_HEADER:
        return String("RFC822.HEADER")
    if item.kind == ITEM_RFC822_TEXT:
        return String("RFC822.TEXT")
    var out = String("BODY[") + render_section(item.sec) + "]"
    if item.sec.has_partial:
        out += String("<") + String(item.sec.origin) + ">"
    return out^


def _resolve(
    item: FetchItem,
    bytes: List[UInt8],
    size: Int,
    mut messages: List[Message],
) raises -> Resolved:
    """Work out one item of a message whose stored bytes are `bytes`. Raises
    when a parse or the opening of a nested message is refused."""
    var r = Resolved()
    var k = item.kind
    if k == ITEM_ENVELOPE:
        append_text(r.head, String("ENVELOPE "))
        var env = envelope_bytes(Span(bytes))
        r.head.extend(Span(env))
    elif k == ITEM_INTERNALDATE:
        var fields = scan_fields(Span(bytes))
        append_text(
            r.head,
            String('INTERNALDATE "')
            + format_internal_date(internal_date_ms(fields))
            + '"',
        )
    elif k == ITEM_BODYSTRUCTURE or k == ITEM_BODY_SHORT:
        ensure_top(bytes, messages)
        if k == ITEM_BODYSTRUCTURE:
            append_text(r.head, String("BODYSTRUCTURE "))
        else:
            append_text(r.head, String("BODY "))
        var structure = body_structure_bytes(messages[0], k == ITEM_BODYSTRUCTURE)
        r.head.extend(Span(structure))
    elif k == ITEM_RFC822_SIZE:
        append_text(r.head, String("RFC822.SIZE ") + String(size))
    elif (
        k == ITEM_RFC822
        or k == ITEM_RFC822_HEADER
        or k == ITEM_RFC822_TEXT
        or k == ITEM_BODY
        or k == ITEM_BODY_PEEK
    ):
        var spec = _spec_of(item)
        var loc = locate(spec, bytes, messages)
        apply_partial(loc, spec)
        var name = _name_of(item)
        if loc.mode == LOC_NIL:
            append_text(r.head, name + " NIL")
        else:
            append_text(r.head, name + " {" + String(loc.length) + "}\r\n")
        r.loc = loc^
    return r^


def _enqueue_payload(
    mut conn: ImapConnection,
    loc: Located,
    bytes: List[UInt8],
    messages: List[Message],
):
    """Queue the bytes a `Located` names, from a borrowed view of them."""
    var lo = loc.off
    var hi = loc.off + loc.length
    if loc.mode == LOC_RAW:
        conn.enqueue_bytes(Span(bytes)[lo:hi])
    elif loc.mode == LOC_HEADER:
        conn.enqueue_bytes(
            messages[loc.src].header_bytes(loc.part).into_span()[lo:hi]
        )
    elif loc.mode == LOC_BODY:
        conn.enqueue_bytes(
            messages[loc.src].body_bytes(loc.part).into_span()[lo:hi]
        )
    elif loc.mode == LOC_OWNED:
        conn.enqueue_bytes(Span(loc.owned)[lo:hi])


def emit_item(
    mut conn: ImapConnection,
    item: FetchItem,
    resolved: Resolved,
    uid: Int,
    bits: UInt8,
    bytes: List[UInt8],
    messages: List[Message],
):
    """Queue the answer for one item of one message: `FLAGS (...)`, `UID n`,
    or the resolved head and the bytes after it."""
    if item.kind == ITEM_FLAGS:
        conn.enqueue(String("FLAGS (") + flags_to_text(bits) + ")")
    elif item.kind == ITEM_UID:
        conn.enqueue(String("UID ") + String(uid))
    else:
        conn.enqueue_bytes(Span(resolved.head))
        _enqueue_payload(conn, resolved.loc, bytes, messages)


def _emit_messages[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    picked: List[Int],
    items: List[FetchItem],
    by_uid: Bool,
    compact_at: Int,
) raises -> Int:
    """Answer each picked message. The result has `_MISSING` set when one was
    gone from the store and `_UNAVAILABLE` when the limits refused one."""
    var wants_flags = _has(items, ITEM_FLAGS)
    var wants_uid = _has(items, ITEM_UID)
    var reads = _reads_message(items)
    var sets_seen = not conn.read_only and (
        _has(items, ITEM_BODY)
        or _has(items, ITEM_RFC822)
        or _has(items, ITEM_RFC822_TEXT)
    )
    var fstore = MailboxFlagStore[S](store.clone(), conn.scope)
    var snap = FlagSnapshot()
    if wants_flags or sets_seen:
        snap = fstore.snapshot()
    var outcome = 0
    var wrote = False
    for k in range(len(picked)):
        var at = picked[k]
        var uid = conn.view[at].uid
        var leaf = conn.view[at].leaf
        var size = conn.view[at].size
        var bits = snap.flags_of(leaf)
        var got = FetchOutcome(False, List[UInt8](), String(""))
        if reads:
            got = fetch_message(store, conn.mailbox, conn.folder, leaf)
            if not got.found:
                outcome = outcome | _MISSING
                continue
        var messages = List[Message]()
        var resolved = List[Resolved]()
        var refused = False
        try:
            for i in range(len(items)):
                resolved.append(_resolve(items[i], got.bytes, size, messages))
        except:
            refused = True
        if refused:
            outcome = outcome | _UNAVAILABLE
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
            emit_item(
                conn, items[i], resolved[i], uid, bits, got.bytes, messages
            )
        if by_uid and not wants_uid:
            conn.enqueue(String(" UID ") + String(uid))
        if changed and not wants_flags:
            conn.enqueue(String(" FLAGS (") + flags_to_text(bits) + ")")
        conn.enqueue(String(")\r\n"))
    if wrote:
        fstore.compact_if_longer_than(compact_at)
    return outcome
