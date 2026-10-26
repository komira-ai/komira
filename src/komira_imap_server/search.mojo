# SEARCH and UID SEARCH: evaluate the parsed keys (search_parse.mojo) against
# each message of the selected folder and answer `* SEARCH n n ...`.
#
# Cost. A message is read from the store at most once per command, and only
# when the cheap keys (flags, sets, sizes) leave it undecided: each node is
# evaluated to true, false or "needs the message", and only then is the
# message read, its header block scanned once (headers.mojo, no MIME parse)
# and the tree evaluated again. So a search is at most one scan of the header
# block per message, and a body or text key is one pass of a linear string
# search (Knuth-Morris-Pratt, O(message + needle)) over the stored bytes. A
# search whose keys read messages is refused with `NO [LIMIT]` before any is
# read when the folder's messages together are over `max_scan_bytes`. A
# message deleted by another connection since SELECT matches nothing.
#
# `SEARCH CHARSET x ...` accepts US-ASCII and UTF-8 (the command line is
# 7-bit text either way) and refuses any other charset with
# `NO [BADCHARSET (US-ASCII UTF-8)]`. The answer is sequence numbers, or UIDs
# for UID SEARCH, ascending.

from komira_mail_message import decode_header_text
from komira_mail_store import FetchOutcome, fetch_message
from komira_objectstore.store import CloneableConditionalWriteStore

from .connection import ImapConnection
from .dates import day_of_ms, internal_date_ms, sent_ms
from .fetch import star_value
from .flags import FlagSnapshot, MailboxFlagStore
from .headers import HdrField, header_len, lower_byte, scan_fields
from .limits import ImapServerConfig
from .parse import upper_ascii
from .reply import internal_error, tagged_bad, tagged_no_code, tagged_ok
from .search_parse import (
    D_BEFORE,
    D_ON,
    N_AND,
    N_BODY,
    N_FALSE,
    N_FLAG,
    N_HEADER,
    N_IDATE,
    N_LARGER,
    N_NOT,
    N_OR,
    N_SDATE,
    N_SEQ,
    N_SMALLER,
    N_TEXT,
    N_TRUE,
    N_UID,
    SNode,
    SearchParser,
    T_ATOM,
    T_STR,
    tokenize,
)


struct MsgView(Movable):
    """What is known of one message while a search evaluates it. The bytes are
    held by the caller (`loaded` says they are there), and `hl` and `fields`
    are their header block."""

    var seq: Int
    var uid: Int
    var size: Int
    var bits: UInt8
    var loaded: Bool
    var hl: Int
    var fields: List[HdrField]

    def __init__(out self, seq: Int, uid: Int, size: Int, bits: UInt8):
        self.seq = seq
        self.uid = uid
        self.size = size
        self.bits = bits
        self.loaded = False
        self.hl = 0
        self.fields = List[HdrField]()


def contains_ci(
    hay: Span[UInt8, _], needle: List[UInt8], fail: List[Int]
) -> Bool:
    """Is the lower-case `needle` (with its failure table) in `hay`, without
    regard to ASCII case? Linear in `hay`. An empty needle is in anything."""
    var m = len(needle)
    if m == 0:
        return True
    var k = 0
    for i in range(len(hay)):
        var c = lower_byte(hay[i])
        while k > 0 and c != needle[k]:
            k = fail[k - 1]
        if c == needle[k]:
            k += 1
            if k == m:
                return True
    return False


def _in_set(los: List[Int], his: List[Int], key: Int) -> Bool:
    """Is `key` in the sorted, disjoint ranges? Binary search."""
    var lo = 0
    var hi = len(his)
    while lo < hi:
        var mid = (lo + hi) // 2
        if his[mid] < key:
            lo = mid + 1
        else:
            hi = mid
    if lo >= len(his):
        return False
    return los[lo] <= key


def _same(a: List[UInt8], b: String) -> Bool:
    var t = b.as_bytes()
    if len(a) != len(t):
        return False
    for i in range(len(a)):
        if a[i] != t[i]:
            return False
    return True


def _header_matches(node: SNode, m: MsgView) -> Bool:
    for i in range(len(m.fields)):
        if not _same(m.fields[i].name, node.name):
            continue
        if len(node.needle) == 0:
            return True
        if contains_ci(Span(m.fields[i].value), node.needle, node.fail):
            return True
        # An encoded word hides the text it carries; read it too.
        var v = Span(m.fields[i].value)
        var has_word = False
        for k in range(len(v) - 1):
            if v[k] == 0x3D and v[k + 1] == 0x3F:
                has_word = True
                break
        if has_word:
            try:
                var decoded = decode_header_text(v)
                if contains_ci(decoded.as_bytes(), node.needle, node.fail):
                    return True
            except:
                pass
    return False


def _date_matches(node: SNode, ms: Int) -> Bool:
    var day = day_of_ms(ms)
    if node.a == D_BEFORE:
        return day < node.b
    if node.a == D_ON:
        return day == node.b
    return day >= node.b


def eval_node(
    nodes: List[SNode], idx: Int, m: MsgView, bytes: List[UInt8]
) -> Int:
    """0 (no match), 1 (match) or 2 (undecided until the message is read;
    never returned once `m.loaded`)."""
    var kind = nodes[idx].kind
    if kind == N_TRUE:
        return 1
    if kind == N_FALSE:
        return 0
    if kind == N_FLAG:
        var has = (m.bits & UInt8(nodes[idx].a)) != 0
        return 1 if has == (nodes[idx].b == 1) else 0
    if kind == N_SEQ:
        return 1 if _in_set(nodes[idx].los, nodes[idx].his, m.seq) else 0
    if kind == N_UID:
        return 1 if _in_set(nodes[idx].los, nodes[idx].his, m.uid) else 0
    if kind == N_LARGER:
        return 1 if m.size > nodes[idx].a else 0
    if kind == N_SMALLER:
        return 1 if m.size < nodes[idx].a else 0
    if kind == N_NOT:
        var r = eval_node(nodes, nodes[idx].kids[0], m, bytes)
        if r == 2:
            return 2
        return 1 - r
    if kind == N_AND or kind == N_OR:
        # Cheap children first, then the ones that read the message.
        var is_and = kind == N_AND
        var unknown = False
        for pass_ in range(2):
            for i in range(len(nodes[idx].kids)):
                var kid = nodes[idx].kids[i]
                if nodes[kid].content != (pass_ == 1):
                    continue
                var r = eval_node(nodes, kid, m, bytes)
                if r == 2:
                    unknown = True
                elif is_and and r == 0:
                    return 0
                elif (not is_and) and r == 1:
                    return 1
        if unknown:
            return 2
        return 1 if is_and else 0
    # The keys that read the message.
    if not m.loaded:
        return 2
    if kind == N_HEADER:
        return 1 if _header_matches(nodes[idx], m) else 0
    if kind == N_TEXT:
        return (
            1 if contains_ci(Span(bytes), nodes[idx].needle, nodes[idx].fail) else 0
        )
    if kind == N_BODY:
        return (
            1
            if contains_ci(
                Span(bytes)[m.hl : len(bytes)], nodes[idx].needle, nodes[idx].fail
            )
            else 0
        )
    if kind == N_IDATE:
        return 1 if _date_matches(nodes[idx], internal_date_ms(m.fields)) else 0
    if kind == N_SDATE:
        var sent = sent_ms(m.fields)
        if not sent:
            return 0
        return 1 if _date_matches(nodes[idx], sent.value()) else 0
    return 0


def handle_search[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    config: ImapServerConfig,
    tag: String,
    args: String,
    by_uid: Bool,
):
    """`SEARCH [CHARSET x] key ...` and `UID SEARCH ...`."""
    var toks = tokenize(args)
    if not toks:
        tagged_bad(conn, tag, "Invalid SEARCH arguments")
        return
    var tokens = toks.value().copy()
    var start = 0
    if len(tokens) > 0 and tokens[0].kind == T_ATOM and upper_ascii(tokens[0].text) == "CHARSET":
        if len(tokens) < 2 or (tokens[1].kind != T_ATOM and tokens[1].kind != T_STR):
            tagged_bad(conn, tag, "CHARSET needs a charset name")
            return
        var cs = upper_ascii(tokens[1].text)
        if cs != "US-ASCII" and cs != "UTF-8":
            tagged_no_code(
                conn, tag, "BADCHARSET (US-ASCII UTF-8)", "Unsupported charset"
            )
            return
        start = 2
    var parser = SearchParser(
        tokens^, start, star_value(conn, False), star_value(conn, True)
    )
    var root = parser.parse_all()
    if not parser.ok:
        tagged_bad(conn, tag, "Invalid SEARCH arguments")
        return
    var total = 0
    for i in range(len(conn.view)):
        total += conn.view[i].size
    if parser.uses_content and total > config.limits.max_scan_bytes:
        tagged_no_code(
            conn,
            tag,
            "LIMIT",
            "Too many message bytes to search; narrow the search",
        )
        return
    var found = List[Int]()
    try:
        var snap = FlagSnapshot()
        if parser.uses_flags:
            var fstore = MailboxFlagStore[S](store.clone(), conn.scope)
            snap = fstore.snapshot()
        for i in range(len(conn.view)):
            var row_leaf = conn.view[i].leaf
            var m = MsgView(
                i + 1, conn.view[i].uid, conn.view[i].size, snap.flags_of(row_leaf)
            )
            var got = FetchOutcome(False, List[UInt8](), String(""))
            var r = eval_node(parser.nodes, root, m, got.bytes)
            if r == 2:
                got = fetch_message(store, conn.mailbox, conn.folder, row_leaf)
                if not got.found:
                    continue
                m.hl = header_len(Span(got.bytes))
                m.fields = scan_fields(Span(got.bytes)[0 : m.hl])
                m.loaded = True
                r = eval_node(parser.nodes, root, m, got.bytes)
            if r == 1:
                found.append(i)
    except:
        internal_error(conn, tag)
        return
    var line = String("* SEARCH")
    for k in range(len(found)):
        var at = found[k]
        if by_uid:
            line += String(" ") + String(conn.view[at].uid)
        else:
            line += String(" ") + String(at + 1)
    conn.enqueue(line + "\r\n")
    tagged_ok(conn, tag, "SEARCH completed")
