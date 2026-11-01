# Mail delivered by the SMTP side and mail filed in another folder, read over
# IMAP, over two stores (the shared in-memory one and the local-file one).
# What each case catches:
# - a message `LocalMailboxDelivery` stored (trace headers and all) is in the
#   recipient's INBOX and nowhere else, and FETCH returns the stored bytes
#   exactly; a message filed into Archive with a \Flagged flag already on it
#   (the UID is the one the server derives from the leaf) is in Archive and
#   not in INBOX, LIST names both folders, SELECT Archive finds it, and FETCH
#   gives the flag and the bytes back (folders that share messages, flags that
#   do not follow the folder, or a changed byte fail);
# - the two folders do not mix: INBOX still has only the delivered message and
#   Archive only the filed one, by count and by content;
# - two deliveries of identical mail are two messages (two UIDs) for the
#   recipient, one each for two recipients, and a recipient sees only their
#   own;
# - the same IMAP session reads a folder it did not know about before: a
#   message filed after SELECT shows after the next SELECT, not before.

from std.testing import assert_equal, assert_true

from komira_mail_store import fetch_message, list_folder, store_message
from komira_mail_test_support import scratch_dir
from komira_objectstore import (
    LocalFsConditionalStore,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_smtp_server import (
    LocalDomains,
    LocalMailboxDelivery,
    NoopMailReceiveHook,
    SessionInfo,
)

from komira_imap_server import (
    FLAG_FLAGGED,
    ImapServerConfig,
    ImapTestServer,
    MailboxFlagStore,
)


def _text(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _cat(prefix: String, body: List[UInt8], suffix: String) -> List[UInt8]:
    var out = _text(prefix)
    out.extend(Span(body))
    out.extend(suffix.as_bytes())
    return out^


def _deliver[
    S: CloneableConditionalWriteStore
](mut store: S, recipients: List[String], message: List[UInt8], now_ms: Int) raises:
    """Deliver `message` to `recipients` the way the SMTP server does."""
    var domains = LocalDomains()
    domains.add(String("example.com"))
    var delivery = LocalMailboxDelivery[S, NoopMailReceiveHook](
        store.clone(), NoopMailReceiveHook(), String("mx.example.com"), domains^
    )
    var result = delivery.deliver(
        SessionInfo(False, String(""), False, String("192.0.2.7"), String("client.test"), 1),
        String("alice@sender.test"),
        recipients,
        Span(message),
        now_ms,
    )
    assert_equal(result.code, 250)


def _inbox_message() -> List[UInt8]:
    return _text(
        String(
            "From: Alice <alice@sender.test>\r\nTo: Bob <bob@example.com>\r\n"
            "Subject: Inbox message\r\n\r\nThis one lives in INBOX.\r\n"
        )
    )


def _archive_message() -> List[UInt8]:
    return _text(
        String(
            "From: Carol <carol@sender.test>\r\nTo: Bob <bob@example.com>\r\n"
            "Subject: Archived message\r\n\r\nThis one lives in Archive.\r\n"
        )
    )


def _check_folders[S: CloneableConditionalWriteStore](var store: S) raises:
    var config = ImapServerConfig(String("imap.test"), False, True)
    var s = ImapTestServer[S](config^, store^)
    s.add_user(String("bob@example.com"), String("pw"))
    s.add_user(String("dave@example.com"), String("pw"))
    var bob = String("bob@example.com")

    # (1) Delivered by the SMTP side into INBOX.
    var to_bob = List[String]()
    to_bob.append(bob)
    _deliver(s.store, to_bob, _inbox_message(), 1_790_000_000_000)
    var inbox_entries = list_folder(s.store, bob, String("INBOX"))
    assert_equal(len(inbox_entries), 1)
    var inbox_leaf = inbox_entries[0].leaf
    var inbox_stored = fetch_message(s.store, bob, String("INBOX"), inbox_leaf).bytes.copy()
    assert_true(String(unsafe_from_utf8=Span(inbox_stored)).startswith("Return-Path: <alice@sender.test>\r\n"))

    # (2) Filed into Archive, with a flag put on it before any IMAP session.
    var filed = store_message(s.store, bob, String("Archive"), _archive_message())
    var scope = String("bob_40example.com/archive")
    var flags = MailboxFlagStore[S](s.store.clone(), scope)
    flags.set_flags(filed.leaf, FLAG_FLAGGED)
    assert_equal(len(list_folder(s.store, bob, String("INBOX"))), 1)
    assert_equal(len(list_folder(s.store, bob, String("Archive"))), 1)

    # (3) Over IMAP.
    var id = s.connect()
    _ = s.login(id, bob, String("pw"))
    assert_equal(
        s.send(id, String('a1 LIST "" "*"\r\n')),
        '* LIST (\\HasNoChildren) "/" "INBOX"\r\n'
        '* LIST (\\HasNoChildren) "/" "archive"\r\n'
        "a1 OK LIST completed\r\n",
    )
    var selected = s.send(id, String("a2 SELECT Archive\r\n"))
    assert_true(selected.startswith("* 1 EXISTS\r\n"), selected)
    assert_true(selected.endswith("a2 OK [READ-WRITE] SELECT completed\r\n"), selected)
    var archive_bytes = _archive_message()
    var want = _cat(
        String("* 1 FETCH (FLAGS (\\Flagged) BODY[] {") + String(len(archive_bytes)) + "}\r\n",
        archive_bytes,
        String(")\r\na3 OK FETCH completed\r\n"),
    )
    _ = s.feed_bytes(id, String("a3 FETCH 1 (FLAGS BODY.PEEK[])\r\n").as_bytes())
    assert_true(_same(s.take_bytes(id), want))
    # Reading it for real marks it \Seen as well; the flag it had stays.
    var want_seen = _cat(
        String("* 1 FETCH (FLAGS (\\Seen \\Flagged) BODY[] {") + String(len(archive_bytes)) + "}\r\n",
        archive_bytes,
        String(")\r\na4 OK FETCH completed\r\n"),
    )
    _ = s.feed_bytes(id, String("a4 FETCH 1 (FLAGS BODY[])\r\n").as_bytes())
    assert_true(_same(s.take_bytes(id), want_seen))

    # (4) INBOX has only the delivered message, byte for byte, with no flag.
    selected = s.send(id, String("a5 SELECT INBOX\r\n"))
    assert_true(selected.startswith("* 1 EXISTS\r\n"), selected)
    var want_inbox = _cat(
        String("* 1 FETCH (FLAGS () BODY[] {") + String(len(inbox_stored)) + "}\r\n",
        inbox_stored,
        String(")\r\na6 OK FETCH completed\r\n"),
    )
    _ = s.feed_bytes(id, String("a6 FETCH 1 (FLAGS BODY.PEEK[])\r\n").as_bytes())
    assert_true(_same(s.take_bytes(id), want_inbox))

    # A message filed after SELECT shows after the next SELECT.
    var late = _text(String("Subject: late\r\n\r\nlate\r\n"))
    _ = store_message(s.store, bob, String("INBOX"), late)
    assert_equal(s.reg.view_count(id), 1)
    assert_true(s.send(id, String("a7 SELECT INBOX\r\n")).startswith("* 2 EXISTS\r\n"))

    # (5) Another user sees none of it.
    var dave = s.connect()
    _ = s.login(dave, String("dave@example.com"), String("pw"))
    assert_true(s.send(dave, String("d1 SELECT INBOX\r\n")).startswith("* 0 EXISTS\r\n"))
    assert_true(s.send(dave, String("d2 SELECT Archive\r\n")).startswith("* 0 EXISTS\r\n"))


def test_delivered_and_filed_mail_over_the_shared_in_memory_store() raises:
    _check_folders(SharedInMemoryConditionalStore())


def test_delivered_and_filed_mail_over_the_local_file_store() raises:
    _check_folders(LocalFsConditionalStore(scratch_dir() + "/imap_folders"))


def test_identical_deliveries_are_separate_messages() raises:
    var config = ImapServerConfig(String("imap.test"), False, True)
    var s = ImapTestServer[SharedInMemoryConditionalStore](
        config^, SharedInMemoryConditionalStore()
    )
    s.add_user(String("bob@example.com"), String("pw"))
    s.add_user(String("erin@example.com"), String("pw"))
    var both = List[String]()
    both.append(String("bob@example.com"))
    both.append(String("erin@example.com"))
    var only_bob = List[String]()
    only_bob.append(String("bob@example.com"))
    var message = _inbox_message()
    _deliver(s.store, both, message, 1_790_000_000_001)
    _deliver(s.store, only_bob, message, 1_790_000_000_002)
    var b = s.connect()
    _ = s.login(b, String("bob@example.com"), String("pw"))
    assert_true(s.send(b, String("b1 SELECT INBOX\r\n")).startswith("* 2 EXISTS\r\n"))
    assert_true(s.reg.uid_at(b, 1) != s.reg.uid_at(b, 2))
    var e = s.connect()
    _ = s.login(e, String("erin@example.com"), String("pw"))
    assert_true(s.send(e, String("e1 SELECT INBOX\r\n")).startswith("* 1 EXISTS\r\n"))
    # Bob deletes one copy; erin's copy and his other one are untouched.
    _ = s.send(b, String("b2 STORE 1 +FLAGS.SILENT (\\Deleted)\r\n"))
    assert_equal(s.send(b, String("b3 EXPUNGE\r\n")), "* 1 EXPUNGE\r\nb3 OK EXPUNGE completed\r\n")
    assert_equal(len(list_folder(s.store, String("bob@example.com"), String("INBOX"))), 1)
    assert_equal(len(list_folder(s.store, String("erin@example.com"), String("INBOX"))), 1)


def main() raises:
    test_delivered_and_filed_mail_over_the_shared_in_memory_store()
    test_delivered_and_filed_mail_over_the_local_file_store()
    test_identical_deliveries_are_separate_messages()
    print("test_folders: OK")
