# SELECT, EXAMINE, LIST and CLOSE, and the mapping from a login to a mailbox
# and from a name to a folder, without a socket. The SELECT/LIST cases run
# over two stores that satisfy CloneableConditionalWriteStore (the shared
# in-memory one and the local-file one). What each case catches:
# - SELECT answers exactly EXISTS, RECENT 0, FLAGS, PERMANENTFLAGS,
#   UIDVALIDITY and UIDNEXT then `OK [READ-WRITE]` (EXAMINE: `[READ-ONLY]`),
#   no HIGHESTMODSEQ (CONDSTORE is not offered), UIDNEXT is the largest UID
#   plus one, and sequence numbers follow ascending UIDs (a view in store
#   order, a reply with an extra or missing line, or a HIGHESTMODSEQ fails);
# - a folder name that leaves the user's mailbox (`..`, `../carol...`, a
#   `.` or empty segment, a trailing `/`, an empty name) is `NO`, the
#   connection stays, and the earlier selection is over (a name that reaches
#   another user's folder, or a drop of the connection, fails);
# - there is no shared default mailbox: a login without an `@` or for an
#   address nobody delivered to opens an empty INBOX, never the old
#   `user@local.test` one; a name that maps to no mailbox gets `NO`;
# - LIST: INBOX first, the others in byte order, `\HasChildren` where a folder
#   has sub-folders, `*` and `%` wildcards, a reference name, case-free
#   matching, an empty pattern for the delimiter, and no escaped folder;
# - CLOSE leaves the folder; the limits: a folder with more messages than
#   `max_messages` is not opened (and exactly `max_messages` is), objects in
#   a folder that are not messages are ignored;
# - flags and UIDVALIDITY are kept per folder.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_store import (
    folder_message_key,
    list_folder,
    normalize_recipient,
    store_message,
)
from komira_mail_test_support import scratch_dir
from komira_objectstore import (
    LocalFsConditionalStore,
    SharedInMemoryConditionalStore,
    WritePrecondition,
)
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_imap_server import (
    IMAP_STATE_AUTH,
    IMAP_STATE_SELECTED,
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
    assign_uid,
    uidvalidity_for,
)

comptime _FLAGS: String = "\\Seen \\Answered \\Flagged \\Deleted \\Draft"


def _server[
    S: CloneableConditionalWriteStore
](var store: S, limits: ImapLimits = ImapLimits()) -> ImapTestServer[S]:
    var config = ImapServerConfig(
        String("imap.test"), False, True, limits.copy()
    )
    var s = ImapTestServer[S](config^, store^)
    s.add_user(String("bob@example.com"), String("pw"))
    s.add_user(String("alice@example.com"), String("pw"))
    s.add_user(String("user"), String("pw"))
    return s^


def _raw(subject: String) -> List[UInt8]:
    var text = (
        String("From: a@sender.test\r\nTo: bob@example.com\r\nSubject: ")
        + subject
        + "\r\n\r\nbody of "
        + subject
        + "\r\n"
    )
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _seed[
    S: CloneableConditionalWriteStore
](mut s: ImapTestServer[S], mailbox: String, folder: String, count: Int) raises -> List[String]:
    """`count` distinct messages in a folder; their leaves."""
    var leaves = List[String]()
    for i in range(count):
        var outcome = store_message(
            s.store, mailbox, folder, _raw(folder + " message " + String(i))
        )
        leaves.append(outcome.leaf)
    return leaves^


def _expected_select(
    count: Int, scope: String, uidnext: Int, tag: String, read_only: Bool
) -> String:
    var text = String("* ") + String(count) + " EXISTS\r\n* 0 RECENT\r\n"
    text += String("* FLAGS (") + _FLAGS + ")\r\n"
    if read_only:
        text += String("* OK [PERMANENTFLAGS ()] No permanent flags\r\n")
    else:
        text += String("* OK [PERMANENTFLAGS (") + _FLAGS + ")] Flags that can be kept\r\n"
    text += String("* OK [UIDVALIDITY ") + String(uidvalidity_for(scope)) + "] UIDs valid\r\n"
    text += String("* OK [UIDNEXT ") + String(uidnext) + "] Predicted next UID\r\n"
    if read_only:
        text += tag + " OK [READ-ONLY] EXAMINE completed\r\n"
    else:
        text += tag + " OK [READ-WRITE] SELECT completed\r\n"
    return text^


def _max_uid(leaves: List[String]) -> Int:
    var best = 0
    for i in range(len(leaves)):
        var uid = assign_uid(leaves[i])
        if uid > best:
            best = uid
    return best


def _check_select[
    S: CloneableConditionalWriteStore
](var store: S) raises:
    var s = _server(store^)
    var bob = normalize_recipient(String("bob@example.com"))
    var leaves = _seed(s, String("bob@example.com"), String("INBOX"), 6)
    var archive = _seed(s, String("bob@example.com"), String("Archive"), 2)
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    assert_equal(
        s.send(id, String("a1 SELECT INBOX\r\n")),
        _expected_select(6, bob, _max_uid(leaves) + 1, String("a1"), False),
    )
    assert_equal(s.reg.state_of(id), IMAP_STATE_SELECTED)
    assert_equal(s.reg.view_count(id), 6)
    assert_equal(s.reg.folder_of(id), "INBOX")
    assert_false(s.reg.is_read_only(id))
    # Sequence numbers follow ascending UIDs, and every UID is a message's.
    var previous = 0
    for seq in range(1, 7):
        var uid = s.reg.uid_at(id, seq)
        assert_true(uid >= previous)
        previous = uid
        var known = False
        for k in range(len(leaves)):
            if assign_uid(leaves[k]) == uid:
                known = True
        assert_true(known)
    assert_equal(s.reg.uid_at(id, 0), -1)
    assert_equal(s.reg.uid_at(id, 7), -1)
    # EXAMINE: the same, read-only. `inbox` and a quoted name are INBOX too.
    assert_equal(
        s.send(id, String('a2 EXAMINE "inbox"\r\n')),
        _expected_select(6, bob, _max_uid(leaves) + 1, String("a2"), True),
    )
    assert_true(s.reg.is_read_only(id))
    # Another folder: its own count, UIDVALIDITY and UIDNEXT.
    assert_equal(
        s.send(id, String("a3 SELECT Archive\r\n")),
        _expected_select(
            2, bob + "/archive", _max_uid(archive) + 1, String("a3"), False
        ),
    )
    assert_equal(s.reg.folder_of(id), "archive")
    # An empty folder that was never written is empty, not an error.
    assert_equal(
        s.send(id, String("a4 SELECT Drafts\r\n")),
        _expected_select(0, bob + "/drafts", 1, String("a4"), False),
    )
    # Folders of one mailbox have different UIDVALIDITY.
    assert_true(uidvalidity_for(bob) != uidvalidity_for(bob + "/archive"))


def test_select_over_the_shared_in_memory_store() raises:
    _check_select(SharedInMemoryConditionalStore())


def test_select_over_the_local_file_store() raises:
    _check_select(LocalFsConditionalStore(scratch_dir() + "/imap_mailbox_select"))


def test_select_refuses_names_that_leave_the_mailbox() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s, String("bob@example.com"), String("INBOX"), 2)
    _ = _seed(s, String("alice@example.com"), String("INBOX"), 3)
    _ = _seed(s, String("alice@example.com"), String("Archive"), 1)
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    _ = s.send(id, String("a0 SELECT INBOX\r\n"))
    var names = List[String]()
    names.append(String(".."))
    names.append(String("../alice@example.com"))
    names.append(String("../alice@example.com/archive"))
    names.append(String("../../etc/passwd"))
    names.append(String("a/../b"))
    names.append(String("a//b"))
    names.append(String("/a"))
    names.append(String("a/"))
    names.append(String("."))
    names.append(String("./a"))
    names.append(String("a/."))
    names.append(String("a/.."))
    names.append(String("INBOX/.."))
    for i in range(len(names)):
        var r = s.send(id, String("a1 SELECT \"") + names[i] + "\"\r\n")
        assert_equal(r, "a1 NO [NONEXISTENT] No such mailbox\r\n")
        assert_false(s.reg.is_closing(id))
        assert_equal(s.reg.state_of(id), IMAP_STATE_AUTH)
        # The refused SELECT also ended the selection that came before it.
        assert_equal(
            s.send(id, String("a2 FETCH 1 FLAGS\r\n")),
            "a2 NO No mailbox is selected\r\n",
        )
        _ = s.send(id, String("a0 SELECT INBOX\r\n"))
    assert_equal(
        s.send(id, String('a3 SELECT ""\r\n')),
        "a3 NO [NONEXISTENT] No such mailbox\r\n",
    )
    assert_equal(
        s.send(id, String('a4 EXAMINE "  "\r\n')),
        "a4 NO [NONEXISTENT] No such mailbox\r\n",
    )
    assert_false(s.reg.is_closing(id))


def test_select_and_examine_take_one_name() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    assert_equal(
        s.send(id, String("a1 SELECT\r\n")),
        "a1 BAD SELECT and EXAMINE take one mailbox name\r\n",
    )
    assert_equal(
        s.send(id, String("a2 SELECT INBOX extra\r\n")),
        "a2 BAD SELECT and EXAMINE take one mailbox name\r\n",
    )
    assert_equal(
        s.send(id, String('a3 EXAMINE "INBOX\r\n')),
        "a3 BAD SELECT and EXAMINE take one mailbox name\r\n",
    )
    assert_equal(
        s.send(id, String("a4 SELECT a*b\r\n")),
        "a4 BAD SELECT and EXAMINE take one mailbox name\r\n",
    )
    assert_false(s.reg.is_closing(id))


def test_there_is_no_shared_default_mailbox() raises:
    var s = _server(SharedInMemoryConditionalStore())
    # The mailbox the old server opened for every login without an `@`.
    _ = _seed(s, String("user@local.test"), String("INBOX"), 2)
    _ = _seed(s, String("bob@example.com"), String("INBOX"), 3)
    s.add_user(String("user@local.test"), String("pw"))
    var bare = s.connect()
    _ = s.login(bare, String("user"), String("pw"))
    assert_equal(s.reg.mailbox_of(bare), "user")
    var r = s.send(bare, String("a1 SELECT INBOX\r\n"))
    assert_true(r.startswith("* 0 EXISTS\r\n"), r)
    # Nobody delivered to alice: an empty INBOX, not bob's and not the default.
    var alice = s.connect()
    _ = s.login(alice, String("alice@example.com"), String("pw"))
    r = s.send(alice, String("a1 SELECT INBOX\r\n"))
    assert_true(r.startswith("* 0 EXISTS\r\n"), r)
    # The default mailbox's own owner and bob see their own mail.
    var owner = s.connect()
    _ = s.login(owner, String("user@local.test"), String("pw"))
    assert_true(s.send(owner, String("a1 SELECT INBOX\r\n")).startswith("* 2 EXISTS\r\n"))
    var bob = s.connect()
    _ = s.login(bob, String("bob@example.com"), String("pw"))
    assert_true(s.send(bob, String("a1 SELECT INBOX\r\n")).startswith("* 3 EXISTS\r\n"))
    # Case in the login name does not change whose mail it is.
    s.add_user(String("BOB@Example.com"), String("pw"))
    var shout = s.connect()
    _ = s.login(shout, String("BOB@Example.com"), String("pw"))
    assert_true(s.send(shout, String("a1 SELECT INBOX\r\n")).startswith("* 3 EXISTS\r\n"))


def test_a_name_that_maps_to_no_mailbox_gets_no() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var long_name = String("n") * 200 + "@example.com"
    s.add_user(long_name, String("pw"))
    var id = s.connect()
    _ = s.login(id, long_name, String("pw"))
    assert_equal(s.reg.state_of(id), IMAP_STATE_AUTH)
    assert_equal(
        s.send(id, String("a1 SELECT INBOX\r\n")),
        "a1 NO [NONEXISTENT] This user has no mailbox\r\n",
    )
    assert_equal(
        s.send(id, String("a2 EXAMINE INBOX\r\n")),
        "a2 NO [NONEXISTENT] This user has no mailbox\r\n",
    )
    assert_equal(
        s.send(id, String('a3 LIST "" "*"\r\n')),
        "a3 NO [NONEXISTENT] This user has no mailbox\r\n",
    )
    # The hierarchy-delimiter query needs no mailbox.
    assert_equal(
        s.send(id, String('a4 LIST "" ""\r\n')),
        '* LIST (\\Noselect) "/" ""\r\na4 OK LIST completed\r\n',
    )
    assert_false(s.reg.is_closing(id))


def _check_list[S: CloneableConditionalWriteStore](var store: S) raises:
    var s = _server(store^)
    _ = _seed(s, String("bob@example.com"), String("INBOX"), 1)
    _ = _seed(s, String("bob@example.com"), String("Archive"), 1)
    _ = _seed(s, String("bob@example.com"), String("Archive/2026"), 1)
    _ = _seed(s, String("bob@example.com"), String("Sent Items"), 1)
    # A folder written with a dot-only name is stored under an escaped
    # segment; no SELECT can reach it, so LIST does not offer it.
    _ = store_message(s.store, String("bob@example.com"), String(".."), _raw(String("dots")))
    _ = _seed(s, String("alice@example.com"), String("Alices"), 1)
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    var all = String(
        '* LIST (\\HasNoChildren) "/" "INBOX"\r\n'
        '* LIST (\\HasChildren) "/" "archive"\r\n'
        '* LIST (\\HasNoChildren) "/" "archive/2026"\r\n'
        '* LIST (\\HasNoChildren) "/" "sent_items"\r\n'
    )
    assert_equal(
        s.send(id, String('a1 LIST "" "*"\r\n')),
        all + "a1 OK LIST completed\r\n",
    )
    assert_equal(
        s.send(id, String('a2 LIST "" %\r\n')),
        '* LIST (\\HasNoChildren) "/" "INBOX"\r\n'
        '* LIST (\\HasChildren) "/" "archive"\r\n'
        '* LIST (\\HasNoChildren) "/" "sent_items"\r\n'
        "a2 OK LIST completed\r\n",
    )
    assert_equal(
        s.send(id, String('a3 LIST "" "arch*"\r\n')),
        '* LIST (\\HasChildren) "/" "archive"\r\n'
        '* LIST (\\HasNoChildren) "/" "archive/2026"\r\n'
        "a3 OK LIST completed\r\n",
    )
    assert_equal(
        s.send(id, String('a4 LIST "" "archive/%"\r\n')),
        '* LIST (\\HasNoChildren) "/" "archive/2026"\r\na4 OK LIST completed\r\n',
    )
    assert_equal(
        s.send(id, String('a5 LIST "archive/" "*"\r\n')),
        '* LIST (\\HasNoChildren) "/" "archive/2026"\r\na5 OK LIST completed\r\n',
    )
    assert_equal(
        s.send(id, String('a6 LIST "" inbox\r\n')),
        '* LIST (\\HasNoChildren) "/" "INBOX"\r\na6 OK LIST completed\r\n',
    )
    assert_equal(
        s.send(id, String('a7 LIST "" "*2026"\r\n')),
        '* LIST (\\HasNoChildren) "/" "archive/2026"\r\na7 OK LIST completed\r\n',
    )
    assert_equal(
        s.send(id, String('a8 LIST "" "nothing*"\r\n')), "a8 OK LIST completed\r\n"
    )
    assert_equal(
        s.send(id, String('a9 LIST "" ""\r\n')),
        '* LIST (\\Noselect) "/" ""\r\na9 OK LIST completed\r\n',
    )
    assert_equal(
        s.send(id, String('b1 LIST ""\r\n')),
        "b1 BAD LIST takes a reference name and a pattern\r\n",
    )
    # Alice's folder is not in bob's list, and bob cannot select it.
    var r = s.send(id, String('b2 LIST "" "*"\r\n'))
    assert_false(r.find("alices") >= 0)
    assert_false(r.find("%") >= 0)


def test_list_over_the_shared_in_memory_store() raises:
    _check_list(SharedInMemoryConditionalStore())


def test_list_over_the_local_file_store() raises:
    _check_list(LocalFsConditionalStore(scratch_dir() + "/imap_mailbox_list"))


def test_close_leaves_the_folder() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s, String("bob@example.com"), String("INBOX"), 2)
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    assert_equal(s.send(id, String("a0 CLOSE\r\n")), "a0 NO No mailbox is selected\r\n")
    _ = s.send(id, String("a1 SELECT INBOX\r\n"))
    assert_equal(s.send(id, String("a2 CLOSE now\r\n")), "a2 BAD CLOSE takes no arguments\r\n")
    assert_equal(s.reg.state_of(id), IMAP_STATE_SELECTED)
    assert_equal(s.send(id, String("a3 CLOSE\r\n")), "a3 OK CLOSE completed\r\n")
    assert_equal(s.reg.state_of(id), IMAP_STATE_AUTH)
    assert_equal(s.reg.view_count(id), 0)
    assert_equal(s.reg.folder_of(id), "")
    assert_equal(s.send(id, String("a4 FETCH 1 FLAGS\r\n")), "a4 NO No mailbox is selected\r\n")
    assert_equal(s.send(id, String("a5 CLOSE\r\n")), "a5 NO No mailbox is selected\r\n")


def test_a_folder_over_the_message_limit_is_not_opened() raises:
    var limits = ImapLimits()
    limits.max_messages = 3
    var s = _server(SharedInMemoryConditionalStore(), limits.copy())
    _ = _seed(s, String("bob@example.com"), String("INBOX"), 3)
    _ = _seed(s, String("bob@example.com"), String("Big"), 4)
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    # Exactly the limit is allowed.
    assert_true(s.send(id, String("a1 SELECT INBOX\r\n")).startswith("* 3 EXISTS\r\n"))
    assert_equal(
        s.send(id, String("a2 SELECT Big\r\n")),
        "a2 NO [LIMIT] The mailbox has too many messages to open\r\n",
    )
    assert_equal(s.reg.state_of(id), IMAP_STATE_AUTH)
    assert_equal(s.reg.view_count(id), 0)


def test_objects_that_are_not_messages_are_ignored() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var leaves = _seed(s, String("bob@example.com"), String("INBOX"), 2)
    var junk = List[String]()
    junk.append(String("notamessage"))
    junk.append(String("0123456789ABCDEF"))  # upper case is not a leaf
    junk.append(String("0123456789abcde"))  # 15 digits
    junk.append(String("0123456789abcdeg"))  # not hex
    for i in range(len(junk)):
        var key = folder_message_key(String("bob@example.com"), String("INBOX"), junk[i])
        var bytes = List[UInt8]()
        bytes.extend(String("not mail").as_bytes())
        _ = s.store.conditional_put(Path.parse(key), bytes, WritePrecondition.if_none_match_star())
    # The store lists them; the server does not count them.
    assert_equal(len(list_folder(s.store, String("bob@example.com"), String("INBOX"))), 2 + len(junk))
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    var r = s.send(id, String("a1 SELECT INBOX\r\n"))
    assert_true(r.startswith("* 2 EXISTS\r\n"), r)
    r = s.send(id, String("a2 FETCH 1:* (UID)\r\n"))
    assert_true(r.endswith("a2 OK FETCH completed\r\n"), r)
    assert_true(r.find("* 2 FETCH (UID ") >= 0)
    assert_false(r.find("* 3 FETCH") >= 0)
    assert_equal(len(leaves), 2)


def test_uids_come_from_the_message_and_do_not_change() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var leaves = _seed(s, String("bob@example.com"), String("INBOX"), 5)
    var first = s.connect()
    _ = s.login(first, String("bob@example.com"), String("pw"))
    var reply = s.send(first, String("a1 SELECT INBOX\r\n"))
    # Each message's UID is the one derived from its leaf, and none is missing.
    for k in range(len(leaves)):
        var found = False
        for seq in range(1, 6):
            if s.reg.uid_at(first, seq) == assign_uid(leaves[k]):
                found = True
        assert_true(found)
    # Another session, and the same session again, see the same numbers.
    var second = s.connect()
    _ = s.login(second, String("bob@example.com"), String("pw"))
    assert_equal(s.send(second, String("a1 SELECT INBOX\r\n")), reply)
    assert_equal(s.send(first, String("a1 SELECT INBOX\r\n")), reply)
    for seq in range(1, 6):
        assert_equal(s.reg.uid_at(first, seq), s.reg.uid_at(second, seq))
    # The same bytes in another folder are the same UID in a folder with a
    # different UIDVALIDITY (the numbers are not unique across folders).
    var raw = _raw(String("INBOX message 0"))
    var filed = store_message(s.store, String("bob@example.com"), String("Archive"), raw)
    assert_equal(filed.leaf, leaves[0])
    var archive = s.send(first, String("a2 SELECT Archive\r\n"))
    assert_equal(s.reg.uid_at(first, 1), assign_uid(leaves[0]))
    assert_false(archive.find(String("[UIDVALIDITY ") + String(uidvalidity_for(normalize_recipient(String("bob@example.com")))) + "]") >= 0)


def test_uids_and_uidvalidity_are_pinned() raises:
    # They are kept in flag logs on the store, so the functions must not
    # change: these are the values the hash gives, worked out outside Mojo.
    assert_equal(assign_uid(String("0123456789abcdef")), 387685513)
    assert_equal(assign_uid(String("ffffffffffffffff")), 1655702294)
    assert_equal(assign_uid(String("0000000000000000")), 1632168701)
    assert_equal(uidvalidity_for(String("bob_40example.com")), 743030446)
    assert_equal(uidvalidity_for(String("bob_40example.com/archive")), 753819319)
    assert_true(assign_uid(String("a")) > 0)
    # And what SELECT answers is built from them.
    var s = _server(SharedInMemoryConditionalStore())
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    var r = s.send(id, String("a1 SELECT INBOX\r\n"))
    assert_true(r.find("[UIDVALIDITY 743030446]") >= 0, r)
    r = s.send(id, String("a2 SELECT Archive\r\n"))
    assert_true(r.find("[UIDVALIDITY 753819319]") >= 0, r)


def test_mail_of_one_user_is_not_visible_to_another() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s, String("bob@example.com"), String("INBOX"), 2)
    _ = _seed(s, String("bob@example.com"), String("Private"), 1)
    var alice = s.connect()
    _ = s.login(alice, String("alice@example.com"), String("pw"))
    assert_true(s.send(alice, String("a1 SELECT INBOX\r\n")).startswith("* 0 EXISTS\r\n"))
    assert_true(s.send(alice, String("a2 SELECT Private\r\n")).startswith("* 0 EXISTS\r\n"))
    var r = s.send(alice, String('a3 LIST "" "*"\r\n'))
    assert_equal(
        r,
        '* LIST (\\HasNoChildren) "/" "INBOX"\r\na3 OK LIST completed\r\n',
    )


def main() raises:
    test_select_over_the_shared_in_memory_store()
    test_select_over_the_local_file_store()
    test_select_refuses_names_that_leave_the_mailbox()
    test_select_and_examine_take_one_name()
    test_there_is_no_shared_default_mailbox()
    test_a_name_that_maps_to_no_mailbox_gets_no()
    test_list_over_the_shared_in_memory_store()
    test_list_over_the_local_file_store()
    test_close_leaves_the_folder()
    test_a_folder_over_the_message_limit_is_not_opened()
    test_objects_that_are_not_messages_are_ignored()
    test_uids_come_from_the_message_and_do_not_change()
    test_uids_and_uidvalidity_are_pinned()
    test_mail_of_one_user_is_not_visible_to_another()
    print("test_mailbox: OK")
