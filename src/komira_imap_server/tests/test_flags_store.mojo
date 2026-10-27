# Durable flags, STORE, EXPUNGE and the silent expunge of CLOSE, without a
# socket. The flag store runs over two stores (the shared in-memory one and
# the local-file one, re-opened as a restart would); the commands over the
# in-memory one and over a store that fails on request. What each case
# catches:
# - `MailboxFlagStore`: a flag set is read back, a later set replaces it, an
#   expunge removes it, a second handle on the same store and one on a store
#   re-opened from disk see the same flags, and another scope sees none (a
#   store that keeps flags in the handle, or one scope for all, fails); many
#   UIDs set in scrambled order are each found (the lookup);
# - flags as text and as bits: fixed order, any letter case, `\Recent` and
#   keywords are not flags this server keeps;
# - the cross-connection port of the old durable-flags case: a \Seen set by one
#   connection is read by a second one and by a new server over the same
#   store, `-FLAGS` clears it for both, `+FLAGS` adds to what is there, EXPUNGE
#   answers `* 1 EXPUNGE`, deletes the message from the store, and a third
#   connection agrees;
# - STORE: `+FLAGS`, `-FLAGS`, `FLAGS`, `.SILENT` in any letter case, flags in
#   parentheses or bare, a set, `UID STORE` (answers carry the UID); an
#   unsupported flag refuses the whole command (nothing is half set); BAD for
#   a malformed command; `NO [READ-ONLY]` after EXAMINE;
# - EXPUNGE answers highest sequence number first, deletes exactly the
#   \Deleted messages and their flags, keeps the others (and their flags),
#   renumbers the view, and does not touch a message that is not \Deleted;
# - CLOSE expunges silently (no `* n EXPUNGE`), but not after EXAMINE;
# - flags belong to a folder: the same message in two folders has two sets;
# - a store failure while listing, reading, writing flags or deleting is a
#   `NO [SERVERBUG]` that quotes nothing of the failure, the connection
#   stays, and a failed delete leaves the message in the store and sends no
#   `* n EXPUNGE` for it.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_store import list_folder, normalize_recipient, store_message
from komira_mail_test_support import scratch_dir
from komira_objectstore import (
    LocalFsConditionalStore,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_imap_server import (
    FLAG_ALL,
    FLAG_ANSWERED,
    FLAG_DELETED,
    FLAG_DRAFT,
    FLAG_FLAGGED,
    FLAG_SEEN,
    IMAP_STATE_SELECTED,
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
    MailboxFlagStore,
    flag_bit_of,
    flags_to_text,
)


# ---- the flag store ---------------------------------------------------------


def test_flags_as_text_and_bits() raises:
    assert_equal(flags_to_text(UInt8(0)), "")
    assert_equal(flags_to_text(FLAG_SEEN), "\\Seen")
    assert_equal(flags_to_text(FLAG_DELETED | FLAG_SEEN), "\\Seen \\Deleted")
    assert_equal(flags_to_text(FLAG_DRAFT | FLAG_ANSWERED), "\\Answered \\Draft")
    assert_equal(
        flags_to_text(FLAG_ALL), "\\Seen \\Answered \\Flagged \\Deleted \\Draft"
    )
    assert_equal(flag_bit_of(String("\\Seen")), FLAG_SEEN)
    assert_equal(flag_bit_of(String("\\SEEN")), FLAG_SEEN)
    assert_equal(flag_bit_of(String("\\deleted")), FLAG_DELETED)
    assert_equal(flag_bit_of(String("\\Flagged")), FLAG_FLAGGED)
    assert_equal(flag_bit_of(String("\\Answered")), FLAG_ANSWERED)
    assert_equal(flag_bit_of(String("\\Draft")), FLAG_DRAFT)
    assert_equal(flag_bit_of(String("\\Recent")), UInt8(0))
    assert_equal(flag_bit_of(String("$Junk")), UInt8(0))
    assert_equal(flag_bit_of(String("Seen")), UInt8(0))
    assert_equal(flag_bit_of(String("")), UInt8(0))


def _leaf(n: Int) -> String:
    """A well-formed leaf (16 lowercase hex digits) for the number `n`."""
    var digits = String("0123456789abcdef")
    var out = String("")
    var v = n
    for _ in range(16):
        out = String(digits[byte = v % 16 : v % 16 + 1]) + out
        v = v // 16
    return out^


def _scrambled_uids() -> List[Int]:
    var uids = List[Int]()
    for i in range(60):
        uids.append(((i * 37) % 101) * 1009 + 5)
    return uids^


def _check_flag_store[
    S: CloneableConditionalWriteStore
](mut store: S) raises:
    var scope = String("bob_40example.com/archive")
    var fs = MailboxFlagStore[S](store.clone(), scope)
    assert_equal(fs.flags_of(_leaf(7)), UInt8(0))
    assert_equal(fs.snapshot().count(), 0)
    fs.set_flags(_leaf(7), FLAG_SEEN)
    assert_equal(fs.flags_of(_leaf(7)), FLAG_SEEN)
    fs.set_flags(_leaf(7), FLAG_DRAFT)  # a later set replaces
    assert_equal(fs.flags_of(_leaf(7)), FLAG_DRAFT)
    fs.set_flags(_leaf(3), FLAG_FLAGGED | FLAG_DELETED)
    assert_equal(fs.flags_of(_leaf(3)), FLAG_FLAGGED | FLAG_DELETED)
    assert_equal(fs.flags_of(_leaf(4)), UInt8(0))
    # Bits that are not flags are not kept.
    fs.set_flags(_leaf(9), UInt8(0xFF))
    assert_equal(fs.flags_of(_leaf(9)), FLAG_ALL)
    # Many UIDs, set in scrambled order, are each found.
    var uids = _scrambled_uids()
    for i in range(len(uids)):
        fs.set_flags(_leaf(uids[i]), UInt8((uids[i] % 31) + 1))
    var snap = fs.snapshot()
    assert_equal(snap.count(), 3 + len(uids))
    for i in range(len(uids)):
        assert_equal(snap.flags_of(_leaf(uids[i])), UInt8((uids[i] % 31) + 1))
    assert_equal(snap.flags_of(_leaf(6)), UInt8(0))
    assert_equal(snap.flags_of(_leaf(2000000)), UInt8(0))
    # A second handle on the same store sees it; another scope does not.
    var second = MailboxFlagStore[S](store.clone(), scope)
    assert_equal(second.flags_of(_leaf(3)), FLAG_FLAGGED | FLAG_DELETED)
    var other = MailboxFlagStore[S](store.clone(), String("bob_40example.com"))
    assert_equal(other.flags_of(_leaf(3)), UInt8(0))
    assert_equal(other.snapshot().count(), 0)
    # Expunge removes the flags, only of that message, and a later set works.
    # (A handle that has written does not see what another appends, so what
    # is read next is read through new handles.)
    second.expunge(_leaf(3))
    var fresh = MailboxFlagStore[S](store.clone(), scope)
    assert_equal(fresh.flags_of(_leaf(3)), UInt8(0))
    assert_equal(fresh.flags_of(_leaf(7)), FLAG_DRAFT)
    assert_equal(fresh.snapshot().count(), 2 + len(uids))
    fresh.set_flags(_leaf(3), FLAG_SEEN)
    assert_equal(MailboxFlagStore[S](store.clone(), scope).flags_of(_leaf(3)), FLAG_SEEN)
    # Folding the log changes how many chunks it has, not what it says.
    var long = MailboxFlagStore[S](store.clone(), scope)
    var before = long.log_length()
    assert_true(before > 60)
    long.compact_if_longer_than(before)  # not longer than itself: left alone
    assert_equal(long.log_length(), before)
    long.compact_if_longer_than(10)
    var folded = MailboxFlagStore[S](store.clone(), scope)
    assert_true(folded.log_length() <= 2)
    assert_equal(folded.snapshot().count(), 1 + len(uids) + 2)
    assert_equal(folded.flags_of(_leaf(3)), FLAG_SEEN)
    assert_equal(folded.flags_of(_leaf(7)), FLAG_DRAFT)
    assert_equal(folded.flags_of(_leaf(9)), FLAG_ALL)
    assert_equal(folded.flags_of(_leaf(uids[17])), UInt8((uids[17] % 31) + 1))
    # And it goes on from there.
    folded.set_flags(_leaf(7), FLAG_SEEN)
    assert_equal(MailboxFlagStore[S](store.clone(), scope).flags_of(_leaf(7)), FLAG_SEEN)


def test_flag_store_over_the_shared_in_memory_store() raises:
    var store = SharedInMemoryConditionalStore()
    _check_flag_store(store)


def test_flag_store_over_the_local_file_store_and_a_restart() raises:
    var root = scratch_dir() + "/imap_flags_store"
    var store = LocalFsConditionalStore(root)
    _check_flag_store(store)
    # A new store on the same directory, as after a restart.
    var again = LocalFsConditionalStore(root)
    var fs = MailboxFlagStore[LocalFsConditionalStore](
        again.clone(), String("bob_40example.com/archive")
    )
    assert_equal(fs.flags_of(_leaf(3)), FLAG_SEEN)
    assert_equal(fs.flags_of(_leaf(7)), FLAG_SEEN)  # the last thing the check set
    assert_equal(fs.flags_of(_leaf(9)), FLAG_ALL)
    assert_true(fs.log_length() <= 3)


# ---- the commands -----------------------------------------------------------


def _text(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _server[
    S: CloneableConditionalWriteStore
](var store: S) -> ImapTestServer[S]:
    var config = ImapServerConfig(String("imap.test"), False, True)
    var s = ImapTestServer[S](config^, store^)
    s.add_user(String("bob@example.com"), String("pw"))
    return s^


def _seed[
    S: CloneableConditionalWriteStore
](mut store: S, folder: String, count: Int) raises -> List[String]:
    var leaves = List[String]()
    for i in range(count):
        var raw = _text(
            String("Subject: ") + folder + " " + String(i) + "\r\n\r\nbody " + String(i) + "\r\n"
        )
        leaves.append(
            store_message(store, String("bob@example.com"), folder, raw).leaf
        )
    return leaves^


def _open[
    S: CloneableConditionalWriteStore
](mut s: ImapTestServer[S], folder: String = "INBOX", examine: Bool = False) raises -> Int:
    var id = s.connect()
    _ = s.login(id, String("bob@example.com"), String("pw"))
    var verb = String("EXAMINE") if examine else String("SELECT")
    var r = s.send(id, String("s1 ") + verb + " " + folder + "\r\n")
    assert_true(r.find("s1 OK") >= 0, r)
    return id


def _stored_count[
    S: CloneableConditionalWriteStore
](mut store: S, folder: String) raises -> Int:
    return len(list_folder(store, String("bob@example.com"), folder))


def test_flags_are_shared_between_connections_and_survive_a_restart() raises:
    var s = _server(SharedInMemoryConditionalStore())
    var leaves = _seed(s.store, String("INBOX"), 1)
    var c1 = _open(s)
    assert_equal(
        s.send(c1, String("a1 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\na1 OK FETCH completed\r\n",
    )
    assert_equal(
        s.send(c1, String("a2 STORE 1 +FLAGS (\\Seen)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen))\r\na2 OK STORE completed\r\n",
    )
    # A second connection sees it.
    var c2 = _open(s)
    assert_equal(
        s.send(c2, String("b1 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen))\r\nb1 OK FETCH completed\r\n",
    )
    # So does a new server over the same store: a restart.
    var restarted = _server(s.store.clone())
    var c3 = _open(restarted)
    assert_equal(
        restarted.send(c3, String("c1 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen))\r\nc1 OK FETCH completed\r\n",
    )
    # A clear by one connection is a clear for the other.
    assert_equal(
        s.send(c2, String("b2 STORE 1 -FLAGS (\\Seen)\r\n")),
        "* 1 FETCH (FLAGS ())\r\nb2 OK STORE completed\r\n",
    )
    assert_equal(
        s.send(c1, String("a3 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\na3 OK FETCH completed\r\n",
    )
    # +FLAGS adds to what is there.
    _ = s.send(c1, String("a4 STORE 1 +FLAGS (\\Seen)\r\n"))
    assert_equal(
        s.send(c1, String("a5 STORE 1 +FLAGS (\\Deleted)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Deleted))\r\na5 OK STORE completed\r\n",
    )
    # EXPUNGE: the message is deleted from the store, and every connection
    # agrees.
    assert_equal(_stored_count(s.store, String("INBOX")), 1)
    assert_equal(
        s.send(c1, String("a6 EXPUNGE\r\n")),
        "* 1 EXPUNGE\r\na6 OK EXPUNGE completed\r\n",
    )
    assert_equal(_stored_count(s.store, String("INBOX")), 0)
    assert_equal(s.reg.view_count(c1), 0)
    assert_true(s.send(c1, String("a7 SELECT INBOX\r\n")).startswith("* 0 EXISTS\r\n"))
    var c4 = _open(s)
    assert_equal(s.reg.view_count(c4), 0)
    assert_equal(
        s.send(c4, String("d1 FETCH 1:* (FLAGS)\r\n")), "d1 OK FETCH completed\r\n"
    )
    # The flags of the expunged message are gone from the log too.
    var fs = MailboxFlagStore[SharedInMemoryConditionalStore](
        s.store.clone(), normalize_recipient(String("bob@example.com"))
    )
    assert_equal(fs.flags_of(leaves[0]), UInt8(0))
    assert_equal(fs.snapshot().count(), 0)


def test_store_operations() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s.store, String("INBOX"), 4)
    var id = _open(s)
    var u1 = s.reg.uid_at(id, 1)
    var u2 = s.reg.uid_at(id, 2)
    var done = String("f OK STORE completed\r\n")
    # FLAGS replaces, for every message of the set.
    assert_equal(
        s.send(id, String("f STORE 1:2 FLAGS (\\Flagged \\Draft)\r\n")),
        "* 1 FETCH (FLAGS (\\Flagged \\Draft))\r\n* 2 FETCH (FLAGS (\\Flagged \\Draft))\r\n" + done,
    )
    # +FLAGS is additive and does not duplicate, -FLAGS removes only what it
    # names.
    assert_equal(
        s.send(id, String("f STORE 1 +FLAGS (\\Flagged \\Seen)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Flagged \\Draft))\r\n" + done,
    )
    assert_equal(
        s.send(id, String("f STORE 1 -FLAGS (\\Flagged \\Answered)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Draft))\r\n" + done,
    )
    # An empty list clears with FLAGS and changes nothing with +FLAGS.
    assert_equal(
        s.send(id, String("f STORE 1 +FLAGS ()\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Draft))\r\n" + done,
    )
    assert_equal(
        s.send(id, String("f STORE 1 FLAGS ()\r\n")),
        "* 1 FETCH (FLAGS ())\r\n" + done,
    )
    # Flags without parentheses; the operation in any letter case.
    assert_equal(
        s.send(id, String("f store 3 +flags \\seen \\ANSWERED\r\n")),
        "* 3 FETCH (FLAGS (\\Seen \\Answered))\r\n" + done,
    )
    # .SILENT: no answer, but the change is made.
    assert_equal(s.send(id, String("f STORE 4 +FLAGS.SILENT (\\Flagged)\r\n")), done)
    assert_equal(s.send(id, String("f STORE 4 +flags.silent (\\Draft)\r\n")), done)
    assert_equal(
        s.send(id, String("f FETCH 4 (FLAGS)\r\n")),
        "* 4 FETCH (FLAGS (\\Flagged \\Draft))\r\nf OK FETCH completed\r\n",
    )
    assert_equal(s.send(id, String("f STORE 4 FLAGS.SILENT (\\Seen)\r\n")), done)
    assert_equal(
        s.send(id, String("f FETCH 4 (FLAGS)\r\n")),
        "* 4 FETCH (FLAGS (\\Seen))\r\nf OK FETCH completed\r\n",
    )
    # UID STORE: by UID, and every answer carries the UID.
    assert_equal(
        s.send(id, String("f UID STORE ") + String(u2) + " +FLAGS (\\Answered)\r\n"),
        "* 2 FETCH (FLAGS (\\Answered \\Flagged \\Draft) UID " + String(u2) + ")\r\n" + done,
    )
    assert_equal(
        s.send(id, String("f UID STORE ") + String(u1) + " FLAGS (\\Draft)\r\n"),
        "* 1 FETCH (FLAGS (\\Draft) UID " + String(u1) + ")\r\n" + done,
    )
    assert_equal(
        s.send(id, String("f UID STORE ") + String(u1) + " +FLAGS.SILENT (\\Seen)\r\n"),
        done,
    )
    # A set past the end is skipped; `*` is the last message.
    assert_equal(s.send(id, String("f STORE 9 +FLAGS (\\Seen)\r\n")), done)
    assert_equal(
        s.send(id, String("f STORE * +FLAGS (\\Flagged)\r\n")),
        "* 4 FETCH (FLAGS (\\Seen \\Flagged))\r\n" + done,
    )
    # Writing what is already there is not an error.
    assert_equal(
        s.send(id, String("f STORE 4 +FLAGS (\\Seen)\r\n")),
        "* 4 FETCH (FLAGS (\\Seen \\Flagged))\r\n" + done,
    )


def test_a_store_with_an_unsupported_flag_changes_nothing() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s.store, String("INBOX"), 2)
    var id = _open(s)
    var no = String("f NO [CANNOT] Only \\Seen, \\Answered, \\Flagged, \\Deleted and \\Draft can be stored\r\n")
    assert_equal(s.send(id, String("f STORE 1:2 +FLAGS ($Junk)\r\n")), no)
    assert_equal(s.send(id, String("f STORE 1:2 +FLAGS (\\Recent)\r\n")), no)
    # A mix: the whole command is refused, \Seen is not half set.
    assert_equal(s.send(id, String("f STORE 1:2 +FLAGS (\\Seen $Junk)\r\n")), no)
    assert_equal(
        s.send(id, String("f FETCH 1:2 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\n* 2 FETCH (FLAGS ())\r\nf OK FETCH completed\r\n",
    )


def test_malformed_store_commands_are_bad() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s.store, String("INBOX"), 1)
    var id = _open(s)
    assert_equal(
        s.send(id, String("f STORE\r\n")),
        "f BAD STORE needs a message set, an operation and flags\r\n",
    )
    assert_equal(
        s.send(id, String("f STORE 1\r\n")),
        "f BAD STORE needs a message set, an operation and flags\r\n",
    )
    assert_equal(s.send(id, String("f STORE 1 BOGUS (\\Seen)\r\n")), "f BAD Unknown STORE operation\r\n")
    assert_equal(s.send(id, String("f STORE 1 +FLAGS\r\n")), "f BAD Invalid flag list\r\n")
    assert_equal(s.send(id, String("f STORE 1 +FLAGS (\\Seen\r\n")), "f BAD Invalid flag list\r\n")
    assert_equal(s.send(id, String("f STORE 1 +FLAGS \\Seen)\r\n")), "f BAD Invalid flag list\r\n")
    assert_equal(s.send(id, String("f STORE 1 +FLAGS (\\Se%n)\r\n")), "f BAD Invalid flag list\r\n")
    assert_equal(s.send(id, String("f STORE 1 +FLAGS (\\)\r\n")), "f BAD Invalid flag list\r\n")
    assert_equal(s.send(id, String("f STORE 0 +FLAGS (\\Seen)\r\n")), "f BAD Invalid message set\r\n")
    assert_equal(s.send(id, String("f STORE 1,, +FLAGS (\\Seen)\r\n")), "f BAD Invalid message set\r\n")
    assert_equal(s.send(id, String("f UID STORE\r\n")), "f BAD STORE needs a message set, an operation and flags\r\n")
    assert_equal(
        s.send(id, String("f FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf OK FETCH completed\r\n",
    )


def test_a_read_only_folder_cannot_be_changed() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s.store, String("INBOX"), 1)
    var writer = _open(s)
    _ = s.send(writer, String("w STORE 1 +FLAGS (\\Deleted)\r\n"))
    var id = _open(s, "INBOX", True)
    var no = String("f NO [READ-ONLY] The mailbox is read-only\r\n")
    assert_equal(s.send(id, String("f STORE 1 +FLAGS (\\Seen)\r\n")), no)
    assert_equal(s.send(id, String("f UID STORE 1:* FLAGS ()\r\n")), no)
    assert_equal(s.send(id, String("f EXPUNGE\r\n")), no)
    assert_equal(
        s.send(id, String("f FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Deleted))\r\nf OK FETCH completed\r\n",
    )
    assert_equal(_stored_count(s.store, String("INBOX")), 1)


def test_expunge_removes_the_deleted_messages_highest_first() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s.store, String("INBOX"), 5)
    var id = _open(s)
    var uids = List[Int]()
    var view_leaves = List[String]()
    for k in range(1, 6):
        uids.append(s.reg.uid_at(id, k))
        view_leaves.append(s.reg.leaf_at(id, k))
    _ = s.send(id, String("f STORE 1:5 +FLAGS.SILENT (\\Flagged)\r\n"))
    _ = s.send(id, String("f STORE 2,3,5 +FLAGS.SILENT (\\Deleted)\r\n"))
    assert_equal(
        s.send(id, String("f EXPUNGE\r\n")),
        "* 5 EXPUNGE\r\n* 3 EXPUNGE\r\n* 2 EXPUNGE\r\nf OK EXPUNGE completed\r\n",
    )
    assert_equal(s.reg.view_count(id), 2)
    assert_equal(_stored_count(s.store, String("INBOX")), 2)
    # The two that stayed keep their flags and are now 1 and 2.
    assert_equal(
        s.send(id, String("f FETCH 1:* (UID FLAGS)\r\n")),
        "* 1 FETCH (UID " + String(uids[0]) + " FLAGS (\\Flagged))\r\n"
        "* 2 FETCH (UID " + String(uids[3]) + " FLAGS (\\Flagged))\r\n"
        "f OK FETCH completed\r\n",
    )
    # Their gone neighbours' flags are gone; theirs are not.
    var fs = MailboxFlagStore[SharedInMemoryConditionalStore](
        s.store.clone(), normalize_recipient(String("bob@example.com"))
    )
    assert_equal(fs.snapshot().count(), 2)
    assert_equal(fs.flags_of(view_leaves[1]), UInt8(0))
    assert_equal(fs.flags_of(view_leaves[0]), FLAG_FLAGGED)
    # Another connection agrees.
    var other = _open(s)
    assert_equal(s.reg.view_count(other), 2)
    # Nothing is \Deleted now: EXPUNGE is just OK.
    assert_equal(s.send(id, String("f EXPUNGE\r\n")), "f OK EXPUNGE completed\r\n")
    assert_equal(s.send(id, String("f EXPUNGE now\r\n")), "f BAD EXPUNGE takes no arguments\r\n")
    assert_equal(_stored_count(s.store, String("INBOX")), 2)


def test_close_expunges_silently_but_not_after_examine() raises:
    var s = _server(SharedInMemoryConditionalStore())
    _ = _seed(s.store, String("INBOX"), 1)
    var id = _open(s)
    _ = s.send(id, String("e1 STORE 1 +FLAGS (\\Deleted)\r\n"))
    # EXAMINE and CLOSE on another connection: nothing is removed.
    var viewer = _open(s, "INBOX", True)
    assert_equal(s.send(viewer, String("v1 CLOSE\r\n")), "v1 OK CLOSE completed\r\n")
    assert_equal(_stored_count(s.store, String("INBOX")), 1)
    # CLOSE of the read-write one: removed, and not a word about it.
    assert_equal(s.send(id, String("e2 CLOSE\r\n")), "e2 OK CLOSE completed\r\n")
    assert_equal(_stored_count(s.store, String("INBOX")), 0)
    assert_true(s.send(id, String("e3 SELECT INBOX\r\n")).startswith("* 0 EXISTS\r\n"))


def test_the_flag_log_is_folded_when_it_grows() raises:
    var limits = ImapLimits()
    limits.compact_flag_log_at = 8
    var config = ImapServerConfig(String("imap.test"), False, True, limits^)
    var s = ImapTestServer[SharedInMemoryConditionalStore](
        config^, SharedInMemoryConditionalStore()
    )
    s.add_user(String("bob@example.com"), String("pw"))
    _ = _seed(s.store, String("INBOX"), 2)
    var id = _open(s)
    var scope = normalize_recipient(String("bob@example.com"))
    for i in range(30):
        var line = String("f STORE 1 +FLAGS.SILENT (\\Flagged)\r\n")
        if i % 2 == 1:
            line = String("f STORE 1 -FLAGS.SILENT (\\Flagged)\r\n")
        assert_equal(s.send(id, line), "f OK STORE completed\r\n")
        var log = MailboxFlagStore[SharedInMemoryConditionalStore](
            s.store.clone(), scope
        )
        assert_true(log.log_length() <= 9)
    _ = s.send(id, String("f STORE 2 +FLAGS.SILENT (\\Seen)\r\n"))
    # 30 changes, an even number: cleared again; message 2 has its own flag.
    assert_equal(
        s.send(id, String("f FETCH 1:2 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\n* 2 FETCH (FLAGS (\\Seen))\r\nf OK FETCH completed\r\n",
    )
    # \Seen set by reading a message is a write too, and is folded the same way.
    var reader = _open(s)
    for _ in range(3):
        _ = s.send(reader, String("r FETCH 1 BODY[]\r\n"))
    _ = s.send(reader, String("r STORE 1 -FLAGS.SILENT (\\Seen)\r\n"))
    assert_equal(
        s.send(reader, String("r FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\nr OK FETCH completed\r\n",
    )
    # EXPUNGE after all of that: the right message goes, the other stays.
    _ = s.send(reader, String("r STORE 1 +FLAGS.SILENT (\\Deleted)\r\n"))
    assert_equal(
        s.send(reader, String("r EXPUNGE\r\n")), "* 1 EXPUNGE\r\nr OK EXPUNGE completed\r\n"
    )
    assert_equal(_stored_count(s.store, String("INBOX")), 1)
    assert_equal(
        s.send(reader, String("r FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen))\r\nr OK FETCH completed\r\n",
    )


def test_flags_belong_to_a_folder() raises:
    var s = _server(SharedInMemoryConditionalStore())
    # The same bytes in two folders: one UID, two sets of flags.
    var raw = _text(String("Subject: twice\r\n\r\nsame bytes\r\n"))
    var a = store_message(s.store, String("bob@example.com"), String("INBOX"), raw)
    var b = store_message(s.store, String("bob@example.com"), String("Archive"), raw)
    assert_equal(a.leaf, b.leaf)
    var id = _open(s)
    _ = s.send(id, String("f STORE 1 +FLAGS.SILENT (\\Seen \\Flagged)\r\n"))
    _ = s.send(id, String("f SELECT Archive\r\n"))
    assert_equal(
        s.send(id, String("f FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf OK FETCH completed\r\n",
    )
    _ = s.send(id, String("f STORE 1 +FLAGS.SILENT (\\Draft)\r\n"))
    _ = s.send(id, String("f SELECT INBOX\r\n"))
    assert_equal(
        s.send(id, String("f FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Flagged))\r\nf OK FETCH completed\r\n",
    )
    # Expunging in one folder leaves the other's message and flags.
    _ = s.send(id, String("f STORE 1 +FLAGS.SILENT (\\Deleted)\r\n"))
    _ = s.send(id, String("f EXPUNGE\r\n"))
    assert_equal(_stored_count(s.store, String("INBOX")), 0)
    assert_equal(_stored_count(s.store, String("Archive")), 1)
    _ = s.send(id, String("f SELECT Archive\r\n"))
    assert_equal(
        s.send(id, String("f FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Draft))\r\nf OK FETCH completed\r\n",
    )


# ---- a store that fails on request ------------------------------------------


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A store over the shared in-memory one that fails a verb while a marker
    object `fail/<verb>` exists in a second store the clones share."""

    var _inner: SharedInMemoryConditionalStore
    var _marks: SharedInMemoryConditionalStore

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var marks: SharedInMemoryConditionalStore,
    ):
        self._inner = inner^
        self._marks = marks^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._marks.clone())

    def _check(self, verb: String) raises:
        var down = True
        try:
            _ = self._marks.head(Path.parse(String("fail/") + verb))
        except:
            down = False
        if down:
            raise Error(
                String("injected ") + verb + " failure for bob@example.com mailboxes/bob_40example.com"
            )

    def head(self, path: Path) raises -> ObjectMeta:
        self._check(String("head"))
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._check(String("list"))
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._check(String("write"))
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._check(String("write"))
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._check(String("write"))
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._check(String("get"))
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._check(String("get"))
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._check(String("delete"))
        self._inner.delete(path)


struct _Faulty(Movable):
    var s: ImapTestServer[_FaultStore]
    var data: SharedInMemoryConditionalStore
    var marks: SharedInMemoryConditionalStore

    def __init__(out self, count: Int) raises:
        var inner = SharedInMemoryConditionalStore()
        self.data = inner.clone()
        var marks = SharedInMemoryConditionalStore()
        self.marks = marks.clone()
        self.s = _server(_FaultStore(inner^, marks^))
        _ = _seed(self.data, String("INBOX"), count)

    def fail(self, verb: String) raises:
        var mark = List[UInt8]()
        mark.append(UInt8(1))
        _ = self.marks.put(Path.parse(String("fail/") + verb), mark)

    def heal(self, verb: String) raises:
        self.marks.delete(Path.parse(String("fail/") + verb))


def _quiet(reply: String) -> Bool:
    """The reply names nothing of the failure or of the mailbox."""
    return not (
        reply.find("injected") >= 0
        or reply.find("bob") >= 0
        or reply.find("mailboxes") >= 0
    )


def test_a_failing_store_is_a_no_and_not_a_dropped_connection() raises:
    var f = _Faulty(2)
    var id = f.s.connect()
    _ = f.s.login(id, String("bob@example.com"), String("pw"))
    var internal = String("f NO [SERVERBUG] Internal error, try again\r\n")
    # Listing fails: SELECT is NO and nothing is selected.
    f.fail(String("list"))
    var r = f.s.send(id, String("f SELECT INBOX\r\n"))
    assert_equal(r, internal)
    assert_true(_quiet(r))
    assert_equal(f.s.reg.view_count(id), 0)
    assert_equal(f.s.send(id, String('f LIST "" "*"\r\n')), internal)
    f.heal(String("list"))
    assert_true(f.s.send(id, String("f SELECT INBOX\r\n")).startswith("* 2 EXISTS\r\n"))
    # Reading a message fails: FETCH is NO, \Seen is not set.
    f.fail(String("get"))
    r = f.s.send(id, String("f FETCH 1 BODY[]\r\n"))
    assert_equal(r, internal)
    assert_true(_quiet(r))
    f.heal(String("get"))
    assert_equal(
        f.s.send(id, String("f FETCH 1 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf OK FETCH completed\r\n",
    )
    # Writing the flag log fails: STORE is NO and nothing changed.
    f.fail(String("write"))
    r = f.s.send(id, String("f STORE 1 +FLAGS (\\Deleted)\r\n"))
    assert_equal(r, internal)
    assert_true(_quiet(r))
    f.heal(String("write"))
    assert_equal(
        f.s.send(id, String("f FETCH 1 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf OK FETCH completed\r\n",
    )
    assert_false(f.s.reg.is_closing(id))
    assert_equal(f.s.reg.state_of(id), IMAP_STATE_SELECTED)


def test_a_failed_delete_keeps_the_message_and_announces_nothing() raises:
    var f = _Faulty(2)
    var id = f.s.connect()
    _ = f.s.login(id, String("bob@example.com"), String("pw"))
    _ = f.s.send(id, String("f SELECT INBOX\r\n"))
    _ = f.s.send(id, String("f STORE 1:2 +FLAGS.SILENT (\\Deleted)\r\n"))
    f.fail(String("delete"))
    var r = f.s.send(id, String("f EXPUNGE\r\n"))
    assert_equal(r, "f NO [SERVERBUG] Internal error, try again\r\n")
    assert_true(_quiet(r))
    assert_equal(_stored_count(f.data, String("INBOX")), 2)
    assert_equal(f.s.reg.view_count(id), 2)
    # CLOSE fails the same way and the folder stays selected.
    r = f.s.send(id, String("f CLOSE\r\n"))
    assert_equal(r, "f NO [SERVERBUG] Internal error, try again\r\n")
    assert_equal(f.s.reg.view_count(id), 2)
    assert_false(f.s.reg.is_closing(id))
    # Healed, the messages can be marked and removed again.
    f.heal(String("delete"))
    _ = f.s.send(id, String("f STORE 1:2 +FLAGS.SILENT (\\Deleted)\r\n"))
    r = f.s.send(id, String("f EXPUNGE\r\n"))
    assert_equal(r, "* 2 EXPUNGE\r\n* 1 EXPUNGE\r\nf OK EXPUNGE completed\r\n")
    assert_equal(_stored_count(f.data, String("INBOX")), 0)


def main() raises:
    test_flags_as_text_and_bits()
    test_flag_store_over_the_shared_in_memory_store()
    test_flag_store_over_the_local_file_store_and_a_restart()
    test_flags_are_shared_between_connections_and_survive_a_restart()
    test_store_operations()
    test_a_store_with_an_unsupported_flag_changes_nothing()
    test_malformed_store_commands_are_bad()
    test_a_read_only_folder_cannot_be_changed()
    test_expunge_removes_the_deleted_messages_highest_first()
    test_close_expunges_silently_but_not_after_examine()
    test_the_flag_log_is_folded_when_it_grows()
    test_flags_belong_to_a_folder()
    test_a_failing_store_is_a_no_and_not_a_dropped_connection()
    test_a_failed_delete_keeps_the_message_and_announces_nothing()
    print("test_flags_store: OK")
