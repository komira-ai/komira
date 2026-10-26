# SELECT, EXAMINE, LIST and CLOSE: choosing a folder of the user's mailbox.
#
# The mailbox is the one the login name maps to (`normalize_recipient`), the
# folders are the ones `komira_mail_store` keeps under it, and a name from the
# client reaches the store only through `resolve_folder`.

from komira_mail_store import (
    MailEntry,
    list_folder,
    list_folders,
    normalize_folder,
    normalize_recipient,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .connection import IMAP_STATE_SELECTED, ImapConnection, ViewRow
from .flags import FLAG_ALL, flag_scope, flags_to_text
from .limits import ImapServerConfig
from .parse import ArgCursor, eq_ci, lower_ascii
from .reply import (
    internal_error,
    tagged_bad,
    tagged_no_code,
    tagged_ok,
    tagged_ok_code,
)
from .search_store import expunge_deleted
from .sets import ascending_order
from .uid import assign_uid, is_valid_leaf, uidvalidity_for


def resolve_folder(name: String) -> Optional[String]:
    """The normalized folder a client's mailbox name selects, or None when it
    names none: empty, a name with an empty, `.` or `..` segment (`..`,
    `../x`, `a//b`, a trailing `/`), or one that cannot be normalized. `INBOX`
    in any letter case is the INBOX. Every other name is folded by
    `normalize_folder` (lower case, letters, digits and `._-/` kept)."""
    var bs = name.as_bytes()
    var n = len(bs)
    if n == 0:
        return None
    if eq_ci(name, "INBOX"):
        return Optional[String](String("INBOX"))
    var start = 0
    for i in range(n + 1):
        if i == n or bs[i] == 0x2F:
            var len_seg = i - start
            if len_seg == 0:
                return None
            if len_seg == 1 and bs[start] == 0x2E:
                return None
            if len_seg == 2 and bs[start] == 0x2E and bs[start + 1] == 0x2E:
                return None
            start = i + 1
    try:
        return Optional[String](normalize_folder(name))
    except:
        return None


def handle_select[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    config: ImapServerConfig,
    tag: String,
    args: String,
    read_only: Bool,
):
    """`SELECT <folder>` and `EXAMINE <folder>`. Lists the folder once and
    keeps the list as the view: sequence numbers are positions in it, in
    ascending UID order, and mail that arrives later shows after the next
    SELECT. Answers EXISTS, RECENT (always 0), FLAGS, PERMANENTFLAGS,
    UIDVALIDITY and UIDNEXT, then `OK [READ-WRITE]` or `OK [READ-ONLY]`. Any
    earlier selection ends first, and stays ended if this one fails."""
    var cur = ArgCursor(args)
    var name = cur.next_astring()
    if not cur.ok or cur.rest().byte_length() > 0:
        tagged_bad(conn, tag, "SELECT and EXAMINE take one mailbox name")
        return
    conn.deselect()
    if conn.mailbox.byte_length() == 0:
        tagged_no_code(conn, tag, "NONEXISTENT", "This user has no mailbox")
        return
    var folder = resolve_folder(name)
    if not folder:
        tagged_no_code(conn, tag, "NONEXISTENT", "No such mailbox")
        return
    var folder_name = folder.value()
    var entries = List[MailEntry]()
    try:
        entries = list_folder(store, conn.mailbox, folder_name)
    except:
        internal_error(conn, tag)
        return
    var rows = List[ViewRow]()
    var uids = List[Int]()
    for i in range(len(entries)):
        if not is_valid_leaf(entries[i].leaf):
            continue
        var uid = assign_uid(entries[i].leaf)
        rows.append(ViewRow(entries[i].leaf, uid, entries[i].size))
        uids.append(uid)
    if len(rows) > config.limits.max_messages:
        tagged_no_code(
            conn, tag, "LIMIT", "The mailbox has too many messages to open"
        )
        return
    var order = ascending_order(uids)
    var view = List[ViewRow](capacity=len(rows))
    var max_uid = 0
    for k in range(len(order)):
        view.append(rows[order[k]].copy())
        if uids[order[k]] > max_uid:
            max_uid = uids[order[k]]
    var scope = String("")
    try:
        scope = flag_scope(normalize_recipient(conn.mailbox), folder_name)
    except:
        internal_error(conn, tag)
        return
    conn.folder = folder_name
    conn.scope = scope
    conn.read_only = read_only
    conn.view = view^
    conn.state = IMAP_STATE_SELECTED
    conn.enqueue(String("* ") + String(len(conn.view)) + " EXISTS\r\n")
    conn.enqueue(String("* 0 RECENT\r\n"))
    conn.enqueue(
        String("* FLAGS (") + flags_to_text(FLAG_ALL) + ")\r\n"
    )
    if read_only:
        # RFC 3501 section 6.3.2: a read-only mailbox has no permanent flags.
        conn.enqueue(String("* OK [PERMANENTFLAGS ()] No permanent flags\r\n"))
    else:
        conn.enqueue(
            String("* OK [PERMANENTFLAGS (")
            + flags_to_text(FLAG_ALL)
            + ")] Flags that can be kept\r\n"
        )
    conn.enqueue(
        String("* OK [UIDVALIDITY ")
        + String(uidvalidity_for(scope))
        + "] UIDs valid\r\n"
    )
    conn.enqueue(
        String("* OK [UIDNEXT ")
        + String(max_uid + 1)
        + "] Predicted next UID\r\n"
    )
    if read_only:
        tagged_ok_code(conn, tag, "READ-ONLY", "EXAMINE completed")
    else:
        tagged_ok_code(conn, tag, "READ-WRITE", "SELECT completed")


def match_pattern(pattern: String, name: String) -> Bool:
    """Does the LIST pattern match the folder name? `*` matches any run of
    characters, `%` any run without `/`; letters compare without regard to
    case."""
    var lowered_pattern = lower_ascii(pattern)
    var p = lowered_pattern.as_bytes()
    var lowered = lower_ascii(name)
    var t = lowered.as_bytes()
    var pi = 0
    var ti = 0
    var star_p = -1
    var star_t = 0
    var star_any = True
    while ti < len(t):
        if pi < len(p) and (p[pi] == 0x2A or p[pi] == 0x25):
            star_p = pi
            star_t = ti
            star_any = p[pi] == 0x2A
            pi += 1
            continue
        if pi < len(p) and p[pi] == t[ti]:
            pi += 1
            ti += 1
            continue
        if star_p >= 0 and (star_any or t[star_t] != 0x2F):
            star_t += 1
            ti = star_t
            pi = star_p + 1
            continue
        return False
    while pi < len(p) and (p[pi] == 0x2A or p[pi] == 0x25):
        pi += 1
    return pi == len(p)


def handle_list[
    S: CloneableConditionalWriteStore,
](mut conn: ImapConnection, mut store: S, tag: String, args: String):
    """`LIST <reference> <pattern>`: the folders of the user's mailbox that
    match, INBOX first, each with `\\HasChildren` or `\\HasNoChildren`. An
    empty pattern asks for the hierarchy delimiter. Only a folder that holds
    a message is listed."""
    var cur = ArgCursor(args)
    var reference = cur.next_astring(True)
    var pattern = cur.next_astring(True)
    if not cur.ok or cur.rest().byte_length() > 0:
        tagged_bad(conn, tag, "LIST takes a reference name and a pattern")
        return
    if pattern.byte_length() == 0:
        conn.enqueue(String('* LIST (\\Noselect) "/" ""\r\n'))
        tagged_ok(conn, tag, "LIST completed")
        return
    if conn.mailbox.byte_length() == 0:
        tagged_no_code(conn, tag, "NONEXISTENT", "This user has no mailbox")
        return
    var folders = List[String]()
    try:
        folders = list_folders(store, conn.mailbox)
    except:
        internal_error(conn, tag)
        return
    var full = reference + pattern
    for i in range(len(folders)):
        var name = folders[i]
        # A name with a `%` is an escaped one (`komira_mail_store` writes
        # such a segment for an empty or dot-only name); SELECT cannot reach
        # it, so it is not offered.
        if name.find("%") >= 0:
            continue
        if not match_pattern(full, name):
            continue
        var has_children = False
        var prefix = name + "/"
        for j in range(len(folders)):
            if folders[j].startswith(prefix):
                has_children = True
                break
        var attr = String("\\HasNoChildren")
        if has_children:
            attr = String("\\HasChildren")
        conn.enqueue(
            String("* LIST (") + attr + ') "/" "' + name + '"\r\n'
        )
    tagged_ok(conn, tag, "LIST completed")


def handle_close[
    S: CloneableConditionalWriteStore,
](
    mut conn: ImapConnection,
    mut store: S,
    compact_at: Int,
    tag: String,
    args: String,
):
    """`CLOSE`: permanently remove the \\Deleted messages without announcing
    them (RFC 3501 section 6.4.2; none for a mailbox opened with EXAMINE),
    then leave the folder. If the store fails the folder stays selected."""
    if args.byte_length() > 0:
        tagged_bad(conn, tag, "CLOSE takes no arguments")
        return
    if not conn.read_only:
        if not expunge_deleted(conn, store, False, compact_at):
            internal_error(conn, tag)
            return
    conn.deselect()
    tagged_ok(conn, tag, "CLOSE completed")
