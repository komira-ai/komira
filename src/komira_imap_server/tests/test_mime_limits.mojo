# What FETCH does with mail that MIME parsing refuses or limits, and with the
# byte limits. What each case catches:
# - a multipart nested one level deeper than `MAX_DEPTH` (8), one part over
#   `MAX_PARTS` (128), and a chain of message/rfc822 parts one deeper than the
#   shared budget allows, each answered `NO [UNAVAILABLE]` for BODYSTRUCTURE,
#   BODY and a numbered section, with nothing of that message sent, and the
#   connection and the next command unharmed; the same mail one level inside
#   the limit is answered;
# - what needs no MIME parse still works on that mail: the whole message, its
#   header and text, a header-field subset, ENVELOPE, INTERNALDATE and
#   RFC822.SIZE (a path that parsed first would refuse them too);
# - a multipart without a boundary and a header line without a colon are the
#   same: BODYSTRUCTURE is `NO [UNAVAILABLE]` while ENVELOPE and the header
#   are served;
# - a nested message with a transfer encoding cannot be opened: its structure
#   and the sections inside it are `NO [UNAVAILABLE]`, its own bytes are not;
# - one message that cannot be read among others: the others are answered,
#   the command ends `NO [UNAVAILABLE]`, and the message that was refused is
#   not marked \Seen while the others are;
# - `max_fetch_bytes` counts a partial by its length, and `max_scan_bytes`
#   refuses a FETCH that would read more message bytes than it allows, before
#   anything is read, while FLAGS and RFC822.SIZE read nothing.

from std.testing import assert_equal, assert_true

from komira_mail_store import store_message
from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import (
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
    assign_uid,
)

comptime UNAVAILABLE = "f1 NO [UNAVAILABLE] Some messages could not be read as MIME within the limits\r\n"
comptime OK = "f1 OK FETCH completed\r\n"


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


struct _Rig(Movable):
    var s: ImapTestServer[SharedInMemoryConditionalStore]
    var id: Int
    var leaves: List[String]

    def __init__(out self, limits: ImapLimits = ImapLimits()):
        var config = ImapServerConfig(
            String("imap.test"), False, True, limits.copy()
        )
        self.s = ImapTestServer[SharedInMemoryConditionalStore](
            config^, SharedInMemoryConditionalStore()
        )
        self.s.add_user(String("bob@example.com"), String("pw"))
        self.id = 0
        self.leaves = List[String]()

    def add(mut self, raw: String) raises:
        var outcome = store_message(
            self.s.store,
            String("bob@example.com"),
            String("INBOX"),
            _bytes(raw),
        )
        self.leaves.append(outcome.leaf)

    def open(mut self) raises:
        self.id = self.s.connect()
        _ = self.s.login(self.id, String("bob@example.com"), String("pw"))
        var r = self.s.send(self.id, String("s1 SELECT INBOX\r\n"))
        assert_true(r.find("s1 OK") >= 0, r)

    def ask(mut self, line: String) -> String:
        return self.s.send(self.id, line)

    def item(mut self, item: String) -> String:
        return self.ask(String("f1 FETCH 1 ") + item + "\r\n")


def _one(raw: String) raises -> _Rig:
    var r = _Rig()
    r.add(raw)
    r.open()
    return r^


def _deep_multipart(levels: Int) -> String:
    """`levels` multiparts, each holding the next, and a text part inside the
    last: the text part is `levels` deep (the message is part 0 at depth 0)."""
    var out = String("Subject: deep\r\nDate: Tue, 01 Sep 2026 10:00:00 +0000\r\n")
    for k in range(levels):
        out += (
            "Content-Type: multipart/mixed; boundary=b" + String(k) + "\r\n\r\n"
        )
        out += "--b" + String(k) + "\r\n"
    out += "Content-Type: text/plain\r\n\r\nleaf"
    for k in range(levels - 1, -1, -1):
        out += "\r\n--b" + String(k) + "--"
    out += "\r\n"
    return out^


def _many_parts(count: Int) -> String:
    var out = String(
        "Subject: many\r\nContent-Type: multipart/mixed; boundary=m\r\n\r\n"
    )
    for _ in range(count):
        out += "--m\r\nContent-Type: text/plain\r\n\r\nx\r\n"
    out += "--m--\r\n"
    return out^


def _message_chain(links: Int) -> String:
    """A message whose body is a message/rfc822 part, `links` times over, and
    a plain message inside the last."""
    var out = String("Subject: end\r\n\r\ntext\r\n")
    for _ in range(links):
        out = String("Subject: link\r\nContent-Type: message/rfc822\r\n\r\n") + out
    return out^


def _path_into(which: Int) -> String:
    """A section path that needs what the `which`th refused message above
    refuses: any part for the two multiparts, ten levels for the chain."""
    if which < 2:
        return String("1")
    return String("1.1.1.1.1.1.1.1.1.1")


def test_depth_and_part_limits_are_unavailable_and_never_a_crash() raises:
    var refused = List[String]()
    refused.append(_deep_multipart(9))
    refused.append(_many_parts(128))
    refused.append(_message_chain(9))
    for i in range(len(refused)):
        var r = _one(refused[i])
        assert_equal(r.item(String("BODYSTRUCTURE")), UNAVAILABLE)
        assert_equal(r.item(String("BODY")), UNAVAILABLE)
        # A numbered section needs the parse (the multiparts), or the nested
        # messages it crosses (the chain: ten numbers open nine of them).
        assert_equal(
            r.item(String("BODY.PEEK[") + _path_into(i) + "]"), UNAVAILABLE
        )
        assert_equal(r.item(String("(FLAGS BODYSTRUCTURE)")), UNAVAILABLE)
        # By UID too, and the session goes on.
        var uid = r.s.reg.uid_at(r.id, 1)
        assert_equal(
            r.ask(String("f1 UID FETCH ") + String(uid) + " BODYSTRUCTURE\r\n"),
            UNAVAILABLE,
        )
        assert_equal(r.ask(String("n1 NOOP\r\n")), "n1 OK NOOP completed\r\n")
        assert_equal(
            r.item(String("FLAGS")),
            "* 1 FETCH (FLAGS ())\r\nf1 OK FETCH completed\r\n",
        )


def test_mail_inside_the_limits_is_answered() raises:
    var ok = List[String]()
    ok.append(_deep_multipart(8))
    ok.append(_many_parts(127))
    ok.append(_message_chain(8))
    for i in range(len(ok)):
        var r = _one(ok[i])
        var reply = r.item(String("BODYSTRUCTURE"))
        assert_true(reply.startswith("* 1 FETCH (BODYSTRUCTURE ("), reply)
        assert_true(reply.endswith(")\r\nf1 OK FETCH completed\r\n"), reply)
        var body = r.item(String("BODY"))
        assert_true(body.startswith("* 1 FETCH (BODY ("), body)
        assert_true(body.endswith(OK), body)
    # Eight nested messages are opened and the text of the last is the part.
    var chain = _one(_message_chain(8))
    assert_equal(
        chain.item(String("BODY.PEEK[1.1.1.1.1.1.1.1.1]")),
        "* 1 FETCH (BODY[1.1.1.1.1.1.1.1.1] {6}\r\ntext\r\n)\r\nf1 OK FETCH completed\r\n",
    )


def test_what_needs_no_mime_parse_is_served_on_mail_that_is_refused() raises:
    var refused = List[String]()
    refused.append(_deep_multipart(9))
    refused.append(_many_parts(128))
    refused.append(_message_chain(9))
    for i in range(len(refused)):
        var raw = refused[i]
        var r = _one(raw)
        var n = raw.byte_length()
        var reply = r.item(String("BODY.PEEK[]"))
        assert_equal(
            reply,
            String("* 1 FETCH (BODY[] {")
            + String(n)
            + "}\r\n"
            + raw
            + ")\r\nf1 OK FETCH completed\r\n",
        )
        assert_true(r.item(String("BODY.PEEK[HEADER]")).endswith(OK))
        assert_true(r.item(String("BODY.PEEK[TEXT]")).endswith(OK))
        assert_true(
            r.item(String("BODY.PEEK[HEADER.FIELDS (SUBJECT)]")).find("Subject: ") > 0
        )
        assert_true(r.item(String("ENVELOPE")).startswith("* 1 FETCH (ENVELOPE ("))
        assert_true(r.item(String("ENVELOPE")).endswith(OK))
        assert_equal(
            r.item(String("RFC822.SIZE")),
            "* 1 FETCH (RFC822.SIZE " + String(n) + ")\r\nf1 OK FETCH completed\r\n",
        )
        assert_true(r.item(String("INTERNALDATE")).endswith(OK))


def test_a_multipart_without_a_boundary_and_a_header_without_a_colon() raises:
    var raws = List[String]()
    raws.append(
        String(
            "Subject: s\r\nFrom: a@x.test\r\nContent-Type: multipart/mixed\r\n\r\nbody\r\n"
        )
    )
    raws.append(
        String(
            "Subject: s\r\nthis line has no colon\r\nFrom: a@x.test\r\n\r\nbody\r\n"
        )
    )
    for i in range(len(raws)):
        var r = _one(raws[i])
        assert_equal(r.item(String("BODYSTRUCTURE")), UNAVAILABLE)
        assert_equal(r.item(String("BODY.PEEK[1]")), UNAVAILABLE)
        # What is a field is read as written, and a line that is no field is
        # not one.
        assert_equal(
            r.item(String("ENVELOPE")),
            "* 1 FETCH (ENVELOPE (NIL \"s\" ((NIL NIL \"a\" \"x.test\")) "
            + "((NIL NIL \"a\" \"x.test\")) ((NIL NIL \"a\" \"x.test\")) "
            + "NIL NIL NIL NIL NIL))\r\nf1 OK FETCH completed\r\n",
        )
        assert_equal(
            r.item(String("BODY.PEEK[TEXT]")),
            "* 1 FETCH (BODY[TEXT] {6}\r\nbody\r\n)\r\nf1 OK FETCH completed\r\n",
        )
    # The line that is no field is still in the header bytes.
    var r = _one(raws[1])
    assert_true(r.item(String("BODY.PEEK[HEADER]")).find("this line has no colon") > 0)


def test_one_unreadable_message_among_readable_ones() raises:
    var r = _Rig()
    r.add(String("Subject: good\r\n\r\nfine\r\n"))
    r.add(_deep_multipart(9))
    r.open()
    # The message that needs no parse is answered, the other is not, and the
    # command says so at the end.
    var bad = -1
    for k in range(1, 3):
        var reply = r.ask(String("f1 FETCH ") + String(k) + " BODYSTRUCTURE\r\n")
        if reply == UNAVAILABLE:
            bad = k
    assert_true(bad > 0)
    var good = 3 - bad
    var all = r.ask(String("f1 FETCH 1:2 (BODY[1] BODYSTRUCTURE)\r\n"))
    assert_true(all.endswith(UNAVAILABLE), all)
    assert_true(all.find("* " + String(good) + " FETCH (") >= 0, all)
    assert_true(all.find("* " + String(bad) + " FETCH (") < 0, all)
    # The readable one was marked \Seen, the refused one was not.
    var flags = r.ask(String("g1 FETCH 1:2 FLAGS\r\n"))
    var seen_line = "* " + String(good) + " FETCH (FLAGS (\\Seen))\r\n"
    var plain_line = "* " + String(bad) + " FETCH (FLAGS ())\r\n"
    assert_true(flags.find(seen_line) >= 0, flags)
    assert_true(flags.find(plain_line) >= 0, flags)


def test_a_nested_message_with_a_transfer_encoding_cannot_be_opened() raises:
    var r = _one(
        String(
            "Subject: x\r\nContent-Type: multipart/mixed; boundary=o\r\n\r\n"
            "--o\r\nContent-Type: message/rfc822\r\n"
            "Content-Transfer-Encoding: base64\r\n\r\n"
            "U3ViamVjdDogeA0KDQp0ZXh0\r\n--o--\r\n"
        )
    )
    # The structure needs the nested message's envelope, the section inside it
    # needs the message: both are unavailable. The part's own bytes are not.
    assert_equal(r.item(String("BODYSTRUCTURE")), UNAVAILABLE)
    assert_equal(r.item(String("BODY.PEEK[1.TEXT]")), UNAVAILABLE)
    assert_equal(
        r.item(String("BODY.PEEK[1]")),
        "* 1 FETCH (BODY[1] {24}\r\nU3ViamVjdDogeA0KDQp0ZXh0)\r\nf1 OK FETCH completed\r\n",
    )
    assert_true(r.item(String("ENVELOPE")).endswith(OK))


def test_the_fetch_limit_counts_a_partial_by_its_length() raises:
    var limits = ImapLimits()
    limits.max_fetch_bytes = 100
    var r = _Rig(limits^)
    var big = String("Subject: big\r\n\r\n")
    for _ in range(50):
        big += "0123456789"
    r.add(big)
    r.open()
    assert_equal(
        r.item(String("BODY.PEEK[]")),
        "f1 NO [LIMIT] The response would be too large; fetch fewer messages\r\n",
    )
    assert_equal(
        r.item(String("BODY.PEEK[]<0.101>")),
        "f1 NO [LIMIT] The response would be too large; fetch fewer messages\r\n",
    )
    # Exactly at the limit is allowed.
    assert_equal(
        r.item(String("BODY.PEEK[]<0.100>")),
        "* 1 FETCH (BODY[]<0> {100}\r\n"
        + String(big[byte=0:100])
        + ")\r\nf1 OK FETCH completed\r\n",
    )
    # A structure returns no message bytes.
    assert_true(r.item(String("ENVELOPE")).endswith(OK))


def test_the_scan_limit_refuses_before_reading() raises:
    var limits = ImapLimits()
    limits.max_scan_bytes = 100
    var r = _Rig(limits^)
    r.add(String("Subject: small\r\n\r\nx\r\n"))
    var big = String("Subject: big\r\n\r\n")
    for _ in range(20):
        big += "0123456789"
    r.add(big)
    r.open()
    var small_seq = -1
    for k in range(1, 3):
        if r.s.reg.uid_at(r.id, k) == assign_uid(r.leaves[0]):
            small_seq = k
    assert_true(small_seq > 0)
    var refused = String(
        "f1 NO [LIMIT] Too many message bytes to read; fetch fewer messages\r\n"
    )
    # Both together are over the limit, whatever they are asked for.
    assert_equal(r.ask(String("f1 FETCH 1:2 ENVELOPE\r\n")), refused)
    assert_equal(r.ask(String("f1 FETCH 1:2 BODY.PEEK[1]<0.4>\r\n")), refused)
    assert_equal(r.ask(String("f1 FETCH 1:2 INTERNALDATE\r\n")), refused)
    # The small one alone fits.
    var one = r.ask(String("f1 FETCH ") + String(small_seq) + " ENVELOPE\r\n")
    assert_true(one.startswith("* " + String(small_seq) + " FETCH (ENVELOPE ("), one)
    assert_true(one.endswith(OK), one)
    # Items that read nothing are not counted.
    var sizes = r.ask(String("f1 FETCH 1:2 (UID RFC822.SIZE)\r\n"))
    assert_true(sizes.endswith(OK), sizes)
    assert_true(sizes.find("RFC822.SIZE " + String(big.byte_length())) > 0, sizes)


def main() raises:
    test_depth_and_part_limits_are_unavailable_and_never_a_crash()
    test_mail_inside_the_limits_is_answered()
    test_what_needs_no_mime_parse_is_served_on_mail_that_is_refused()
    test_a_multipart_without_a_boundary_and_a_header_without_a_colon()
    test_one_unreadable_message_among_readable_ones()
    test_a_nested_message_with_a_transfer_encoding_cannot_be_opened()
    test_the_fetch_limit_counts_a_partial_by_its_length()
    test_the_scan_limit_refuses_before_reading()
    print("test_mime_limits: OK")
