# The whole read path of an IMAP client, from delivery to LOGOUT, and the
# gating around it, on mail the SMTP side stored. What each case catches:
# - read_full_sequence: a multipart/alternative message delivered by
#   `LocalMailboxDelivery` is read by LOGIN, SELECT (EXISTS, RECENT, FLAGS,
#   PERMANENTFLAGS, UIDVALIDITY, UIDNEXT, READ-WRITE), `FETCH (UID FLAGS
#   ENVELOPE BODYSTRUCTURE BODY[])` with every part of the answer exact, the
#   BODY[] literal byte for byte the stored message, `UID FETCH`, SEARCH by
#   FROM and SUBJECT and UID SEARCH, STORE and a FETCH that shows the flag,
#   BODY[HEADER] and BODY[TEXT], CLOSE and LOGOUT;
# - examine_and_gating: SELECT before LOGIN, a wrong password, EXAMINE
#   (READ-ONLY, EXISTS), STORE refused on it, LIST, and what SELECT does with
#   a name that leaves the mailbox (`..`, `../x`): refused, and the selection
#   before it ended, as before.

from std.testing import assert_equal, assert_true

from komira_mail_store import fetch_message, list_folder
from komira_objectstore import SharedInMemoryConditionalStore
from komira_smtp_server import (
    LocalDomains,
    LocalMailboxDelivery,
    NoopMailReceiveHook,
    SessionInfo,
)

from komira_imap_server import ImapServerConfig, ImapTestServer


def _text(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _the_message() -> List[UInt8]:
    return _text(
        String(
            "From: Alice <alice@example.com>\r\n"
            "To: Bob <user@local.test>\r\n"
            "Subject: Read over IMAP\r\n"
            "Message-ID: <imap-001@example.com>\r\n"
            "Date: Mon, 14 Sep 2026 13:45:30 +0000\r\n"
            "In-Reply-To: <prev-000@example.com>\r\n"
            'Content-Type: multipart/alternative; boundary="BND9"\r\n'
            "\r\n"
            "--BND9\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n"
            "Content-Transfer-Encoding: 7bit\r\n"
            "\r\n"
            "Read this over IMAP.\r\n"
            "--BND9\r\n"
            "Content-Type: text/html\r\n"
            "\r\n"
            "<p>Read this over IMAP.</p>\r\n"
            "--BND9--\r\n"
        )
    )


def _deliver(
    mut store: SharedInMemoryConditionalStore, message: List[UInt8]
) raises:
    var domains = LocalDomains()
    domains.add(String("example.com"))
    var delivery = LocalMailboxDelivery[
        SharedInMemoryConditionalStore, NoopMailReceiveHook
    ](
        store.clone(),
        NoopMailReceiveHook(),
        String("mx.example.com"),
        domains^,
    )
    var to = List[String]()
    to.append(String("bob@example.com"))
    var result = delivery.deliver(
        SessionInfo(
            False,
            String(""),
            False,
            String("192.0.2.7"),
            String("client.test"),
            1,
        ),
        String("alice@sender.test"),
        to,
        Span(message),
        1_790_000_000_000,
    )
    assert_equal(result.code, 250)


def _server() raises -> ImapTestServer[SharedInMemoryConditionalStore]:
    var config = ImapServerConfig(String("imap.test"), False, False)
    var s = ImapTestServer[SharedInMemoryConditionalStore](
        config^, SharedInMemoryConditionalStore()
    )
    s.add_user(String("bob@example.com"), String("pw"))
    return s^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_read_full_sequence() raises:
    var s = _server()
    _deliver(s.store, _the_message())
    var entries = list_folder(s.store, String("bob@example.com"), String("INBOX"))
    assert_equal(len(entries), 1)
    var stored = fetch_message(
        s.store, String("bob@example.com"), String("INBOX"), entries[0].leaf
    ).bytes.copy()

    var id = s.connect()
    var greeting = s.take(id)
    assert_true(greeting.startswith("* OK [CAPABILITY IMAP4rev1"), greeting)
    assert_true(greeting.find("IMAP4rev1 ready") > 0, greeting)

    var login = s.send(id, String("a001 LOGIN bob@example.com pw\r\n"))
    assert_equal(login, "a001 OK [CAPABILITY IMAP4rev1] LOGIN completed\r\n")

    var select = s.send(id, String("a002 SELECT INBOX\r\n"))
    assert_true(select.startswith("* 1 EXISTS\r\n"), select)
    assert_true(select.find("* 0 RECENT\r\n") > 0, select)
    assert_true(select.find("* FLAGS (") > 0, select)
    assert_true(select.find("[PERMANENTFLAGS (") > 0, select)
    assert_true(select.find("[UIDVALIDITY ") > 0, select)
    assert_true(select.find("[UIDNEXT ") > 0, select)
    assert_true(select.endswith("a002 OK [READ-WRITE] SELECT completed\r\n"), select)
    var uid = s.reg.uid_at(id, 1)

    # One FETCH of a client's first sync, every part exact. The Date is the
    # sender's, the Subject and Message-ID as written, sender and reply-to
    # default to from. BODY[] is the stored message, trace headers and all.
    # \Seen is set by it, and FLAGS (asked for before it) shows the flag.
    var alice = String('(("Alice" NIL "alice" "example.com"))')
    var envelope = (
        String('ENVELOPE ("Mon, 14 Sep 2026 13:45:30 +0000" "Read over IMAP" ')
        + alice
        + " "
        + alice
        + " "
        + alice
        + ' (("Bob" NIL "user" "local.test")) NIL NIL "<prev-000@example.com>"'
        + ' "<imap-001@example.com>")'
    )
    # The text part is "Read this over IMAP." (20 octets) and the html part
    # "<p>Read this over IMAP.</p>" (27): the line break before a delimiter
    # belongs to the delimiter.
    var structure = String(
        'BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" 20 1'
        ' NIL NIL NIL NIL)("TEXT" "HTML" NIL NIL NIL "7BIT" 27 1 NIL NIL NIL NIL)'
        ' "ALTERNATIVE" ("BOUNDARY" "BND9") NIL NIL NIL)'
    )
    _ = s.feed_bytes(
        id,
        String("a003 FETCH 1 (UID FLAGS ENVELOPE BODYSTRUCTURE BODY[])\r\n").as_bytes(),
    )
    var got = s.take_bytes(id)
    var want = _text(
        String("* 1 FETCH (UID ")
        + String(uid)
        + " FLAGS (\\Seen) "
        + envelope
        + " "
        + structure
        + " BODY[] {"
        + String(len(stored))
        + "}\r\n"
    )
    want.extend(Span(stored))
    want.extend(String(")\r\na003 OK FETCH completed\r\n").as_bytes())
    assert_true(_same(got, want), String(unsafe_from_utf8=Span(got)))

    # UID FETCH answers with the UID.
    assert_equal(
        s.send(id, String("a004 UID FETCH ") + String(uid) + " (FLAGS)\r\n"),
        "* 1 FETCH (FLAGS (\\Seen) UID " + String(uid) + ")\r\na004 OK FETCH completed\r\n",
    )

    # SEARCH finds it by FROM and SUBJECT, and answers a UID for UID SEARCH.
    assert_equal(
        s.send(id, String('a005 SEARCH FROM "alice"\r\n')),
        "* SEARCH 1\r\na005 OK SEARCH completed\r\n",
    )
    assert_equal(
        s.send(id, String('a006 SEARCH SUBJECT "Read over"\r\n')),
        "* SEARCH 1\r\na006 OK SEARCH completed\r\n",
    )
    assert_equal(
        s.send(id, String("a007 UID SEARCH ALL\r\n")),
        "* SEARCH " + String(uid) + "\r\na007 OK SEARCH completed\r\n",
    )
    assert_equal(
        s.send(id, String('a008 SEARCH FROM "nobody"\r\n')),
        "* SEARCH\r\na008 OK SEARCH completed\r\n",
    )

    # STORE and a FETCH that shows the flag.
    assert_equal(
        s.send(id, String("a010 STORE 1 +FLAGS (\\Flagged)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Flagged))\r\na010 OK STORE completed\r\n",
    )
    assert_equal(
        s.send(id, String("a011 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen \\Flagged))\r\na011 OK FETCH completed\r\n",
    )

    # The header and the text of the message, as stored.
    var header_reply = s.send(id, String("a012 FETCH 1 (BODY[HEADER])\r\n"))
    assert_true(header_reply.startswith("* 1 FETCH (BODY[HEADER] {"), header_reply)
    assert_true(header_reply.find("Subject: Read over IMAP\r\n") > 0, header_reply)
    assert_true(header_reply.find("Read this over IMAP.") < 0, header_reply)
    assert_true(header_reply.find("Return-Path: <alice@sender.test>\r\n") > 0, header_reply)
    var text_reply = s.send(id, String("a013 FETCH 1 (BODY[TEXT])\r\n"))
    assert_true(text_reply.startswith("* 1 FETCH (BODY[TEXT] {"), text_reply)
    assert_true(text_reply.find("Read this over IMAP.") > 0, text_reply)
    assert_true(text_reply.find("Subject:") < 0, text_reply)

    assert_equal(
        s.send(id, String("a014 CLOSE\r\n")), "a014 OK CLOSE completed\r\n"
    )
    assert_equal(
        s.send(id, String("a015 LOGOUT\r\n")),
        "* BYE imap.test logging out\r\na015 OK LOGOUT completed\r\n",
    )


def test_examine_and_gating() raises:
    var s = _server()
    _deliver(s.store, _the_message())
    var id = s.connect()
    _ = s.take(id)

    assert_equal(
        s.send(id, String("b001 SELECT INBOX\r\n")), "b001 NO Log in first\r\n"
    )
    assert_equal(
        s.send(id, String("b002 LOGIN bob@example.com wrongpass\r\n")),
        "b002 NO [AUTHENTICATIONFAILED] Authentication failed\r\n",
    )
    assert_true(
        s.send(id, String("b003 LOGIN bob@example.com pw\r\n")).startswith("b003 OK")
    )

    var examine = s.send(id, String("b004 EXAMINE INBOX\r\n"))
    assert_true(examine.startswith("* 1 EXISTS\r\n"), examine)
    assert_true(examine.endswith("b004 OK [READ-ONLY] EXAMINE completed\r\n"), examine)
    assert_equal(
        s.send(id, String("b005 STORE 1 +FLAGS (\\Seen)\r\n")),
        "b005 NO [READ-ONLY] The mailbox is read-only\r\n",
    )
    # Reading on EXAMINE sets nothing, structures and sections included.
    _ = s.send(id, String("b006 FETCH 1 (ENVELOPE BODYSTRUCTURE BODY[1] BODY[TEXT])\r\n"))
    assert_equal(
        s.send(id, String("b007 FETCH 1 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\nb007 OK FETCH completed\r\n",
    )
    assert_equal(
        s.send(id, String('b008 LIST "" "*"\r\n')),
        '* LIST (\\HasNoChildren) "/" "INBOX"\r\nb008 OK LIST completed\r\n',
    )

    # A name that leaves the mailbox is refused, and the selection that came
    # before it has ended: nothing is selected afterwards.
    assert_equal(
        s.send(id, String("b009 SELECT ..\r\n")),
        "b009 NO [NONEXISTENT] No such mailbox\r\n",
    )
    assert_equal(
        s.send(id, String("b010 FETCH 1 FLAGS\r\n")),
        "b010 NO No mailbox is selected\r\n",
    )
    _ = s.send(id, String("b011 EXAMINE INBOX\r\n"))
    assert_equal(
        s.send(id, String("b012 SELECT ../x\r\n")),
        "b012 NO [NONEXISTENT] No such mailbox\r\n",
    )
    assert_equal(
        s.send(id, String("b013 SEARCH ALL\r\n")),
        "b013 NO No mailbox is selected\r\n",
    )
    assert_equal(
        s.send(id, String("b014 LOGOUT\r\n")),
        "* BYE imap.test logging out\r\nb014 OK LOGOUT completed\r\n",
    )


def main() raises:
    test_read_full_sequence()
    test_examine_and_gating()
    print("test_read_sequence: OK")
