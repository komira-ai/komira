# What a message's flags and EXPUNGE are keyed by, and whether they are really
# on the store. What each case catches:
# - two messages of one folder whose UIDs are equal (found by search, then
#   stored): STORE \Deleted on one, EXPUNGE and CLOSE remove that one and keep
#   the other with its flags and its bytes; a \Seen set by reading one is not
#   shown on the other; `UID STORE` names both, as UIDs say (flags keyed by
#   UID instead of leaf fail every one of these);
# - STORE \Deleted then EXPUNGE, and STORE \Deleted then CLOSE, over the
#   local-file store, then a NEW store on the same directory and a NEW
#   server: the message and its flags are gone, the other message keeps its
#   flags (a delete or a flag write that stays in a handle, a cache or the
#   registry fails);
# - the same message delivered again after it was expunged has no flags (a
#   stale \Deleted left in the log would be inherited and the message lost);
# - a folder named `_flags` and the INBOX flag log do not read each other;
# - the flag log's names: a mailbox and its folders are never under one prefix.

from std.collections import Dict
from std.testing import assert_equal, assert_true

from komira_mail_store import (
    content_hash_hex,
    list_folder,
    normalize_recipient,
    store_message,
)
from komira_mail_test_support import scratch_dir
from komira_objectstore import (
    LocalFsConditionalStore,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_imap_server import (
    FLAG_FLAGGED,
    FLAG_SEEN,
    ImapServerConfig,
    ImapTestServer,
    MailboxFlagStore,
    assign_uid,
)

comptime _BOB: String = "bob@example.com"


def _text(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _raw(n: Int) -> List[UInt8]:
    return _text(String("Subject: m") + String(n) + "\r\n\r\nbody " + String(n) + "\r\n")


def _colliding_pair() raises -> List[Int]:
    """Two message numbers whose leaves have one UID. The search is over a
    fixed sequence and finds the same pair every run; a 31-bit UID collides
    among a few tens of thousands of messages."""
    var seen = Dict[Int, Int]()
    for n in range(600000):
        var uid = assign_uid(content_hash_hex(_raw(n)))
        if uid in seen:
            var out = List[Int]()
            out.append(seen[uid])
            out.append(n)
            return out^
        seen[uid] = n
    raise Error("no UID collision found")


def _server[
    S: CloneableConditionalWriteStore
](var store: S) -> ImapTestServer[S]:
    var config = ImapServerConfig(String("imap.test"), False, True)
    var s = ImapTestServer[S](config^, store^)
    s.add_user(String(_BOB), String("pw"))
    return s^


def _open[
    S: CloneableConditionalWriteStore
](mut s: ImapTestServer[S], folder: String = "INBOX") raises -> Int:
    var id = s.connect()
    _ = s.login(id, String(_BOB), String("pw"))
    var r = s.send(id, String("s1 SELECT ") + folder + "\r\n")
    assert_true(r.find("s1 OK") >= 0, r)
    return id


def _seed_pair[
    S: CloneableConditionalWriteStore
](mut store: S) raises -> List[String]:
    var pair = _colliding_pair()
    var a = store_message(store, String(_BOB), String("INBOX"), _raw(pair[0])).leaf
    var b = store_message(store, String(_BOB), String("INBOX"), _raw(pair[1])).leaf
    assert_true(a != b)
    assert_equal(assign_uid(a), assign_uid(b))
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def test_a_shared_uid_does_not_share_flags_or_expunge() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var leaves = _seed_pair(s.store)
    var id = _open(s)
    assert_equal(s.reg.view_count(id), 2)
    assert_equal(s.reg.uid_at(id, 1), s.reg.uid_at(id, 2))
    var first = s.reg.leaf_at(id, 1)
    var second = s.reg.leaf_at(id, 2)
    assert_true(first != second)
    # Flags are per message.
    assert_equal(
        s.send(id, String("a1 STORE 1 +FLAGS (\\Deleted \\Flagged)\r\n")),
        "* 1 FETCH (FLAGS (\\Flagged \\Deleted))\r\na1 OK STORE completed\r\n",
    )
    assert_equal(
        s.send(id, String("a2 FETCH 1:2 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Flagged \\Deleted))\r\n* 2 FETCH (FLAGS ())\r\na2 OK FETCH completed\r\n",
    )
    # Reading the second marks only the second as seen.
    _ = s.send(id, String("a3 FETCH 2 (BODY[])\r\n"))
    assert_equal(
        s.send(id, String("a4 FETCH 1:2 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Flagged \\Deleted))\r\n* 2 FETCH (FLAGS (\\Seen))\r\na4 OK FETCH completed\r\n",
    )
    # EXPUNGE takes the marked one and not its namesake.
    assert_equal(
        s.send(id, String("a5 EXPUNGE\r\n")),
        "* 1 EXPUNGE\r\na5 OK EXPUNGE completed\r\n",
    )
    var left = list_folder(s.store, String(_BOB), String("INBOX"))
    assert_equal(len(left), 1)
    assert_equal(left[0].leaf, second)
    var fs = MailboxFlagStore[SharedInMemoryConditionalStore](
        s.store.clone(), normalize_recipient(String(_BOB))
    )
    assert_equal(fs.flags_of(second), FLAG_SEEN)
    assert_equal(fs.flags_of(first), UInt8(0))
    assert_equal(fs.snapshot().count(), 1)


def test_close_keeps_the_message_that_shares_a_uid_with_a_deleted_one() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed_pair(s.store)
    var id = _open(s)
    var second = s.reg.leaf_at(id, 2)
    _ = s.send(id, String("c1 STORE 1 +FLAGS.SILENT (\\Deleted)\r\n"))
    assert_equal(s.send(id, String("c2 CLOSE\r\n")), "c2 OK CLOSE completed\r\n")
    var left = list_folder(s.store, String(_BOB), String("INBOX"))
    assert_equal(len(left), 1)
    assert_equal(left[0].leaf, second)
    var other = _open(s)
    assert_equal(s.reg.view_count(other), 1)
    assert_equal(
        s.send(other, String("c3 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\nc3 OK FETCH completed\r\n",
    )


def test_uid_commands_name_every_message_with_that_uid() raises:
    # A UID is not an identity here (README, "UIDs"): UID STORE answers for
    # both messages that carry it.
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed_pair(s.store)
    var id = _open(s)
    var uid = s.reg.uid_at(id, 1)
    assert_equal(
        s.send(id, String("u1 UID STORE ") + String(uid) + " +FLAGS.SILENT (\\Flagged)\r\n"),
        "u1 OK STORE completed\r\n",
    )
    assert_equal(
        s.send(id, String("u2 FETCH 1:2 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Flagged))\r\n* 2 FETCH (FLAGS (\\Flagged))\r\nu2 OK FETCH completed\r\n",
    )


def _fresh_server(root: String) raises -> ImapTestServer[LocalFsConditionalStore]:
    return _server(LocalFsConditionalStore(root))


def _flag_and_expunge(root: String, keep_raw: List[UInt8], gone_raw: List[UInt8]) raises -> List[String]:
    """The first server: two messages, one marked \\Deleted, the other
    \\Flagged, then EXPUNGE. Returns the leaves kept and gone."""
    var s = _fresh_server(root)
    var keep = store_message(s.store, String(_BOB), String("INBOX"), keep_raw).leaf
    var gone = store_message(s.store, String(_BOB), String("INBOX"), gone_raw).leaf
    var id = _open(s)
    var viewed_gone = String("")
    var viewed_keep = String("")
    for k in range(1, 3):
        if s.reg.leaf_at(id, k) == gone:
            viewed_gone = String(k)
        else:
            viewed_keep = String(k)
    _ = s.send(id, String("d1 STORE ") + viewed_gone + " +FLAGS.SILENT (\\Deleted)\r\n")
    _ = s.send(id, String("d2 STORE ") + viewed_keep + " +FLAGS.SILENT (\\Flagged)\r\n")
    assert_equal(
        s.send(id, String("d3 EXPUNGE\r\n")),
        "* " + viewed_gone + " EXPUNGE\r\nd3 OK EXPUNGE completed\r\n",
    )
    var out = List[String]()
    out.append(keep)
    out.append(gone)
    return out^


def test_store_expunge_and_close_are_on_the_local_file_store() raises:
    var root = scratch_dir() + "/imap_durable_expunge"
    var keep_raw = _raw(1)
    var gone_raw = _raw(2)
    var leaves = _flag_and_expunge(root, keep_raw, gone_raw)
    var keep = leaves[0]
    var gone = leaves[1]
    # A new store on the same directory and a new server: a restart.
    var again = _fresh_server(root)
    var left = list_folder(again.store, String(_BOB), String("INBOX"))
    assert_equal(len(left), 1)
    assert_equal(left[0].leaf, keep)
    var fs = MailboxFlagStore[LocalFsConditionalStore](
        again.store.clone(), normalize_recipient(String(_BOB))
    )
    assert_equal(fs.snapshot().count(), 1)
    assert_equal(fs.flags_of(keep), FLAG_FLAGGED)
    assert_equal(fs.flags_of(gone), UInt8(0))
    var id2 = _open(again)
    assert_equal(
        again.send(id2, String("e1 FETCH 1:* (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Flagged))\r\ne1 OK FETCH completed\r\n",
    )
    # The same bytes delivered again are a new message with no flags.
    _ = store_message(again.store, String(_BOB), String("INBOX"), gone_raw)
    var id3 = _open(again)
    assert_equal(again.reg.view_count(id3), 2)
    var back = String("")
    for k in range(1, 3):
        if again.reg.leaf_at(id3, k) == gone:
            back = String(k)
    assert_equal(
        again.send(id3, String("e2 FETCH ") + back + " (FLAGS)\r\n"),
        "* " + back + " FETCH (FLAGS ())\r\ne2 OK FETCH completed\r\n",
    )
    # And EXPUNGE does not take it.
    assert_equal(again.send(id3, String("e3 EXPUNGE\r\n")), "e3 OK EXPUNGE completed\r\n")
    assert_equal(len(list_folder(again.store, String(_BOB), String("INBOX"))), 2)

    # CLOSE, in another folder of the same store, then a new store again.
    var root2 = scratch_dir() + "/imap_durable_close"
    var c = _fresh_server(root2)
    var one = store_message(c.store, String(_BOB), String("INBOX"), keep_raw).leaf
    _ = store_message(c.store, String(_BOB), String("INBOX"), gone_raw)
    var cid = _open(c)
    for k in range(1, 3):
        if c.reg.leaf_at(cid, k) != one:
            _ = c.send(cid, String("k") + String(k) + " STORE " + String(k) + " +FLAGS.SILENT (\\Deleted)\r\n")
    assert_equal(c.send(cid, String("k9 CLOSE\r\n")), "k9 OK CLOSE completed\r\n")
    var reopened = _fresh_server(root2)
    var after = list_folder(reopened.store, String(_BOB), String("INBOX"))
    assert_equal(len(after), 1)
    assert_equal(after[0].leaf, one)
    var rid = _open(reopened)
    assert_equal(reopened.reg.view_count(rid), 1)
    var rfs = MailboxFlagStore[LocalFsConditionalStore](
        reopened.store.clone(), normalize_recipient(String(_BOB))
    )
    assert_equal(rfs.snapshot().count(), 0)


def test_a_folder_named_flags_and_the_inbox_do_not_read_each_others_flags() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var in_leaf = store_message(s.store, String(_BOB), String("INBOX"), _raw(1)).leaf
    var f_leaf = store_message(s.store, String(_BOB), String("_flags"), _raw(2)).leaf
    var inbox = _open(s)
    _ = s.send(inbox, String("i1 STORE 1 +FLAGS.SILENT (\\Seen)\r\n"))
    var folder = _open(s, "_flags")
    assert_equal(s.reg.leaf_at(folder, 1), f_leaf)
    assert_equal(
        s.send(folder, String("f1 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf1 OK FETCH completed\r\n",
    )
    _ = s.send(folder, String("f2 STORE 1 +FLAGS.SILENT (\\Flagged)\r\n"))
    assert_equal(
        s.send(inbox, String("i2 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen))\r\ni2 OK FETCH completed\r\n",
    )
    var inbox_log = MailboxFlagStore[SharedInMemoryConditionalStore](
        s.store.clone(), normalize_recipient(String(_BOB))
    )
    assert_equal(inbox_log.snapshot().count(), 1)
    assert_equal(inbox_log.flags_of(in_leaf), FLAG_SEEN)
    assert_equal(inbox_log.flags_of(f_leaf), UInt8(0))
    var folder_log = MailboxFlagStore[SharedInMemoryConditionalStore](
        s.store.clone(), normalize_recipient(String(_BOB)) + "/_flags"
    )
    assert_equal(folder_log.snapshot().count(), 1)
    assert_equal(folder_log.flags_of(f_leaf), FLAG_FLAGGED)
    # Compacting one log leaves the other as it was.
    inbox_log.compact_if_longer_than(0)
    assert_equal(
        MailboxFlagStore[SharedInMemoryConditionalStore](
            s.store.clone(), normalize_recipient(String(_BOB)) + "/_flags"
        ).flags_of(f_leaf),
        FLAG_FLAGGED,
    )


def main() raises:
    test_a_shared_uid_does_not_share_flags_or_expunge()
    test_close_keeps_the_message_that_shares_a_uid_with_a_deleted_one()
    test_uid_commands_name_every_message_with_that_uid()
    test_store_expunge_and_close_are_on_the_local_file_store()
    test_a_folder_named_flags_and_the_inbox_do_not_read_each_others_flags()
    print("test_flag_identity: OK")
