# FETCH and UID FETCH, without a socket. What each case catches:
# - a message literal is the stored bytes exactly: every byte value, NUL, a
#   lone CR and LF, and a message larger than any buffer, with the right `{n}`
#   (a path that turns bytes into text, or counts the wrong length, fails);
# - the items: FLAGS, UID, BODY[], BODY.PEEK[] and RFC822 in the order asked,
#   a bare item or a parenthesised list, any letter case, an item twice;
# - UID FETCH puts the UID in every answer, also when it was not asked for, and
#   `FETCH` does not;
# - sets: a number, a range, a list, `*` (the last sequence number or UID), a
#   range written backwards, numbers past the end (skipped, not an error), and
#   a range as wide as the numbers go costs the messages and not its width; a
#   0, an empty item, a non-number, a second colon or more than 1024 ranges are
#   BAD;
# - \Seen: BODY[] and RFC822 set it durably on a read-write folder and the
#   answer carries it (added when FLAGS was not asked for); BODY.PEEK[] does
#   not, EXAMINE does not, a refused command does not (the \Seen of the
#   section forms is in test_sections);
# - an unknown or malformed item (a section or a partial that is not IMAP
#   included) is BAD before anything is read or sent, and sets no flag
#   (ENVELOPE, BODYSTRUCTURE and the sections are in test_bodystructure and
#   test_sections);
# - a FETCH whose message bytes would pass `max_fetch_bytes` is `NO [LIMIT]`,
#   exactly at the limit is allowed, and a FLAGS-only fetch of the same
#   messages is not limited;
# - a message another connection deleted since SELECT ends the command with
#   `NO [EXPUNGEISSUED]` after the others were answered.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_store import store_message
from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import (
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
    assign_uid,
)


def _server(
    limits: ImapLimits = ImapLimits(),
) -> ImapTestServer[SharedInMemoryConditionalStore]:
    var config = ImapServerConfig(
        String("imap.test"), False, True, limits.copy()
    )
    var s = ImapTestServer[SharedInMemoryConditionalStore](
        config^, SharedInMemoryConditionalStore()
    )
    s.add_user(String("bob@example.com"), String("pw"))
    return s^


def _text(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _plain_message() -> List[UInt8]:
    return _text(
        String("From: a@sender.test\r\nSubject: plain\r\n\r\nhello world\r\n")
    )


def _eight_bit_message() -> List[UInt8]:
    """Every byte value once, a NUL, a lone CR and a lone LF."""
    var m = _text(String("Subject: eight bit\r\n\r\n"))
    for b in range(256):
        m.append(UInt8(b))
    m.extend(String("\rlone cr\nlone lf\r\n").as_bytes())
    return m^


def _big_message() -> List[UInt8]:
    var m = _text(String("Subject: big\r\n\r\n"))
    for i in range(70000):
        m.append(UInt8((i * 7) % 251))
    return m^


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


struct _Rig(Movable):
    var s: ImapTestServer[SharedInMemoryConditionalStore]
    var id: Int
    var leaves: List[String]
    var messages: List[List[UInt8]]

    def __init__(out self, var s: ImapTestServer[SharedInMemoryConditionalStore]):
        self.s = s^
        self.id = 0
        self.leaves = List[String]()
        self.messages = List[List[UInt8]]()

    def add(mut self, var raw: List[UInt8]) raises:
        var outcome = store_message(
            self.s.store, String("bob@example.com"), String("INBOX"), raw
        )
        self.leaves.append(outcome.leaf)
        self.messages.append(raw^)

    def open(mut self, examine: Bool = False) raises:
        self.id = self.s.connect()
        _ = self.s.login(self.id, String("bob@example.com"), String("pw"))
        var verb = String("EXAMINE") if examine else String("SELECT")
        var r = self.s.send(self.id, String("s1 ") + verb + " INBOX\r\n")
        assert_true(r.find("s1 OK") >= 0, r)

    def seq_of(self, uid: Int) -> Int:
        for k in range(1, len(self.leaves) + 1):
            if self.s.reg.uid_at(self.id, k) == uid:
                return k
        return -1

    def index_of(self, which: Int) -> Int:
        """The index in `leaves` of the message that is at sequence number
        `which`."""
        var uid = self.s.reg.uid_at(self.id, which)
        for k in range(len(self.leaves)):
            if assign_uid(self.leaves[k]) == uid:
                return k
        return -1

    def raw(mut self, line: String) -> List[UInt8]:
        _ = self.s.feed_bytes(self.id, line.as_bytes())
        return self.s.take_bytes(self.id)

    def text(mut self, line: String) -> String:
        return self.s.send(self.id, line)


def _rig(limits: ImapLimits = ImapLimits()) raises -> _Rig:
    var r = _Rig(_server(limits.copy()))
    r.add(_plain_message())
    r.add(_eight_bit_message())
    r.add(_big_message())
    r.open()
    return r^


def test_literals_are_the_stored_bytes() raises:
    var r = _rig()
    # Whatever the order, every message comes back exactly, by sequence number
    # and by UID.
    for seq in range(1, 4):
        var k = r.index_of(seq)
        var n = len(r.messages[k])
        var want = _cat(
            String("* ") + String(seq) + " FETCH (BODY[] {" + String(n) + "}\r\n",
            r.messages[k],
            String(")\r\nf1 OK FETCH completed\r\n"),
        )
        assert_true(_same(r.raw(String("f1 FETCH ") + String(seq) + " BODY.PEEK[]\r\n"), want))
        var uid = assign_uid(r.leaves[k])
        var by_uid = _cat(
            String("* ") + String(seq) + " FETCH (BODY[] {" + String(n) + "}\r\n",
            r.messages[k],
            String(" UID ") + String(uid) + ")\r\nf2 OK FETCH completed\r\n",
        )
        assert_true(
            _same(
                r.raw(String("f2 UID FETCH ") + String(uid) + " (BODY.PEEK[])\r\n"),
                by_uid,
            )
        )
        # RFC822 is the same bytes under its own name.
        var old = _cat(
            String("* ") + String(seq) + " FETCH (RFC822 {" + String(n) + "}\r\n",
            r.messages[k],
            String(" FLAGS (\\Seen))\r\nf3 OK FETCH completed\r\n"),
        )
        assert_true(_same(r.raw(String("f3 FETCH ") + String(seq) + " RFC822\r\n"), old))


def test_items_come_in_the_order_asked() raises:
    var r = _rig()
    var k = r.index_of(1)
    var uid = assign_uid(r.leaves[k])
    var n = len(r.messages[k])
    var want = _cat(
        String("* 1 FETCH (UID ") + String(uid) + " FLAGS () BODY[] {" + String(n) + "}\r\n",
        r.messages[k],
        String(" BODY[] {") + String(n) + "}\r\n",
    )
    var more = want.copy()
    more.extend(Span(r.messages[k]))
    more.extend(String(")\r\nf1 OK FETCH completed\r\n").as_bytes())
    assert_true(
        _same(
            r.raw(String("f1 FETCH 1 (uid Flags body.peek[] BODY.PEEK[])\r\n")),
            more,
        )
    )
    # A single item, bare or in parentheses, gives the same line.
    assert_equal(
        r.text(String("f2 FETCH 1 UID\r\n")),
        String("* 1 FETCH (UID ") + String(uid) + ")\r\nf2 OK FETCH completed\r\n",
    )
    assert_equal(
        r.text(String("f3 FETCH 1 (UID)\r\n")),
        String("* 1 FETCH (UID ") + String(uid) + ")\r\nf3 OK FETCH completed\r\n",
    )


def test_uid_fetch_always_carries_the_uid() raises:
    var r = _rig()
    var all = String("")
    var by_seq = String("")
    for seq in range(1, 4):
        var uid = r.s.reg.uid_at(r.id, seq)
        all += String("* ") + String(seq) + " FETCH (FLAGS () UID " + String(uid) + ")\r\n"
        by_seq += String("* ") + String(seq) + " FETCH (FLAGS ())\r\n"
    assert_equal(r.text(String("f1 UID FETCH 1:* FLAGS\r\n")), all + "f1 OK FETCH completed\r\n")
    # FETCH by sequence number does not add it.
    assert_equal(r.text(String("f2 FETCH 1:3 (FLAGS)\r\n")), by_seq + "f2 OK FETCH completed\r\n")
    # Asked for, it appears once, where it was put.
    var uid2 = r.s.reg.uid_at(r.id, 2)
    assert_equal(
        r.text(String("f3 UID FETCH ") + String(uid2) + " (UID FLAGS)\r\n"),
        String("* 2 FETCH (UID ") + String(uid2) + " FLAGS ())\r\nf3 OK FETCH completed\r\n",
    )


def test_message_sets() raises:
    var r = _rig()
    var u1 = r.s.reg.uid_at(r.id, 1)
    var u2 = r.s.reg.uid_at(r.id, 2)
    var u3 = r.s.reg.uid_at(r.id, 3)
    var line1 = String("* 1 FETCH (UID ") + String(u1) + ")\r\n"
    var line2 = String("* 2 FETCH (UID ") + String(u2) + ")\r\n"
    var line3 = String("* 3 FETCH (UID ") + String(u3) + ")\r\n"
    var done = String("f OK FETCH completed\r\n")
    assert_equal(r.text(String("f FETCH 2 (UID)\r\n")), line2 + done)
    assert_equal(r.text(String("f FETCH 1,3 (UID)\r\n")), line1 + line3 + done)
    assert_equal(r.text(String("f FETCH 2:3 (UID)\r\n")), line2 + line3 + done)
    assert_equal(r.text(String("f FETCH 3:2 (UID)\r\n")), line2 + line3 + done)
    assert_equal(r.text(String("f FETCH * (UID)\r\n")), line3 + done)
    assert_equal(r.text(String("f FETCH 2:* (UID)\r\n")), line2 + line3 + done)
    assert_equal(r.text(String("f FETCH *:2 (UID)\r\n")), line2 + line3 + done)
    assert_equal(r.text(String("f FETCH 3,1,3,1:2 (UID)\r\n")), line1 + line2 + line3 + done)
    # Past the end: skipped, and the command still succeeds.
    assert_equal(r.text(String("f FETCH 4 (UID)\r\n")), done)
    assert_equal(r.text(String("f FETCH 3:99 (UID)\r\n")), line3 + done)
    assert_equal(r.text(String("f FETCH 99:100 (UID)\r\n")), done)
    # A range as wide as numbers go: three answers, at once.
    assert_equal(
        r.text(String("f FETCH 1:4294967295 (UID)\r\n")),
        line1 + line2 + line3 + done,
    )
    # By UID: a number, a range, `*` is the largest UID, and an unknown UID is
    # skipped.
    assert_equal(
        r.text(String("f UID FETCH ") + String(u2) + " (UID)\r\n"), line2 + done
    )
    assert_equal(r.text(String("f UID FETCH 1:* (UID)\r\n")), line1 + line2 + line3 + done)
    assert_equal(r.text(String("f UID FETCH * (UID)\r\n")), line3 + done)
    assert_equal(
        r.text(String("f UID FETCH ") + String(u1) + ":" + String(u2) + " (UID)\r\n"),
        line1 + line2 + done,
    )
    assert_equal(
        r.text(String("f UID FETCH ") + String(u3 + 1) + ":* (UID)\r\n"), line3 + done
    )
    # A set the numbers of which are not UIDs of this folder.
    assert_equal(r.text(String("f UID FETCH 2147483647 (UID)\r\n")), done)


def test_malformed_sets_are_bad() raises:
    var r = _rig()
    var bad = List[String]()
    bad.append(String("f FETCH 0 (UID)\r\n"))
    bad.append(String("f FETCH 1,,2 (UID)\r\n"))
    bad.append(String("f FETCH 1: (UID)\r\n"))
    bad.append(String("f FETCH :1 (UID)\r\n"))
    bad.append(String("f FETCH 1:a (UID)\r\n"))
    bad.append(String("f FETCH a (UID)\r\n"))
    bad.append(String("f FETCH 1:2:3 (UID)\r\n"))
    bad.append(String("f FETCH 1, (UID)\r\n"))
    bad.append(String("f FETCH -1 (UID)\r\n"))
    bad.append(String("f FETCH 12345678901 (UID)\r\n"))
    bad.append(String("f FETCH 1:99999999999999 (UID)\r\n"))
    bad.append(String("f UID FETCH 0:5 (UID)\r\n"))
    for i in range(len(bad)):
        assert_equal(r.text(bad[i]), "f BAD Invalid message set\r\n")
    # The command words themselves.
    assert_equal(r.text(String("f FETCH\r\n")), "f BAD FETCH needs a message set and items\r\n")
    assert_equal(r.text(String("f FETCH 1\r\n")), "f BAD FETCH needs a message set and items\r\n")
    assert_equal(r.text(String("f UID FETCH\r\n")), "f BAD FETCH needs a message set and items\r\n")
    assert_equal(r.text(String("f UID BOGUS 1 FLAGS\r\n")), "f BAD Unknown UID command\r\n")
    # 1024 ranges are the most a set may have.
    var many = String("")
    for i in range(1024):
        if i > 0:
            many += String(",")
        many += String(2 * i + 1)
    var ok = r.text(String("f FETCH ") + many + " (UID)\r\n")
    assert_true(ok.endswith("f OK FETCH completed\r\n"), ok)
    many += String(",3000")
    assert_equal(r.text(String("f FETCH ") + many + " (UID)\r\n"), "f BAD Invalid message set\r\n")
    assert_false(r.s.reg.is_closing(r.id))


def test_body_sets_seen_and_peek_does_not() raises:
    var r = _rig()
    var k = r.index_of(1)
    var n = len(r.messages[k])
    # PEEK: no flag, no change.
    _ = r.raw(String("f1 FETCH 1 BODY.PEEK[]\r\n"))
    assert_equal(
        r.text(String("f2 FETCH 1 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf2 OK FETCH completed\r\n",
    )
    # BODY[]: the answer carries the new flag even though FLAGS was not asked.
    var want = _cat(
        String("* 1 FETCH (BODY[] {") + String(n) + "}\r\n",
        r.messages[k],
        String(" FLAGS (\\Seen))\r\nf3 OK FETCH completed\r\n"),
    )
    assert_true(_same(r.raw(String("f3 FETCH 1 BODY[]\r\n")), want))
    # It is durable: a second connection sees it.
    var other = r.s.connect()
    _ = r.s.login(other, String("bob@example.com"), String("pw"))
    _ = r.s.send(other, String("s SELECT INBOX\r\n"))
    assert_equal(
        r.s.send(other, String("g1 FETCH 1 (FLAGS)\r\n")),
        "* 1 FETCH (FLAGS (\\Seen))\r\ng1 OK FETCH completed\r\n",
    )
    # With FLAGS asked for, the answer has the flag as this very fetch set it.
    var k2 = r.index_of(2)
    var n2 = len(r.messages[k2])
    var want2 = _cat(
        String("* 2 FETCH (FLAGS (\\Seen) RFC822 {") + String(n2) + "}\r\n",
        r.messages[k2],
        String(")\r\nf5 OK FETCH completed\r\n"),
    )
    assert_true(_same(r.raw(String("f5 FETCH 2 (FLAGS RFC822)\r\n")), want2))
    # Already seen: nothing is added to the answer.
    var again = _cat(
        String("* 2 FETCH (RFC822 {") + String(n2) + "}\r\n",
        r.messages[k2],
        String(")\r\nf6 OK FETCH completed\r\n"),
    )
    assert_true(_same(r.raw(String("f6 FETCH 2 RFC822\r\n")), again))
    # \Seen is kept with the other flags a message has.
    assert_equal(
        r.text(String("f7 STORE 3 +FLAGS (\\Flagged)\r\n")),
        "* 3 FETCH (FLAGS (\\Flagged))\r\nf7 OK STORE completed\r\n",
    )
    _ = r.raw(String("f8 FETCH 3 BODY[]\r\n"))
    assert_equal(
        r.text(String("f9 FETCH 3 FLAGS\r\n")),
        "* 3 FETCH (FLAGS (\\Seen \\Flagged))\r\nf9 OK FETCH completed\r\n",
    )


def test_examine_does_not_set_seen() raises:
    var r = _Rig(_server())
    r.add(_plain_message())
    r.open(True)
    var k = r.index_of(1)
    var n = len(r.messages[k])
    var want = _cat(
        String("* 1 FETCH (BODY[] {") + String(n) + "}\r\n",
        r.messages[k],
        String(")\r\nf1 OK FETCH completed\r\n"),
    )
    assert_true(_same(r.raw(String("f1 FETCH 1 BODY[]\r\n")), want))
    assert_equal(
        r.text(String("f2 FETCH 1 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\nf2 OK FETCH completed\r\n",
    )


def test_bad_items_are_refused_before_anything_runs() raises:
    var r = _rig()
    var unknown = List[String]()
    unknown.append(String("(FOO)"))
    unknown.append(String("(FLAGS FOO)"))
    unknown.append(String("BINARY[1]"))
    unknown.append(String("()"))
    unknown.append(String("BODY["))
    unknown.append(String("BODY.PEEK[HEADER.FIELDS (FROM)"))
    unknown.append(String("(FLAGS"))
    unknown.append(String("FLAGS)"))
    unknown.append(String("BODY]"))
    # An item left open next to good ones is not skipped.
    unknown.append(String("(FLAGS BODY[)"))
    unknown.append(String("(UID BODY.PEEK[HEADER.FIELDS (FROM)"))
    unknown.append(String("(BODY.PEEK[] (FLAGS)"))
    # Sections and partials that are not IMAP.
    unknown.append(String("BODY[0]"))
    unknown.append(String("BODY[1.]"))
    unknown.append(String("BODY[.1]"))
    unknown.append(String("BODY[01]"))
    unknown.append(String("BODY[1HEADER]"))
    unknown.append(String("BODY[MIME]"))
    unknown.append(String("BODY[TEXT.HEADER]"))
    unknown.append(String("BODY[HEADER.FIELDS]"))
    unknown.append(String("BODY[HEADER.FIELDS ()]"))
    unknown.append(String("BODY[HEADER.FIELDSX (A)]"))
    unknown.append(String("BODY[]<0.0>"))
    unknown.append(String("BODY[]<1>"))
    unknown.append(String("BODY[]<a.1>"))
    unknown.append(String("BODY[]<1.a>"))
    unknown.append(String("BODY[]<1.2"))
    unknown.append(String("BODY[]<99999999999.1>"))
    for i in range(len(unknown)):
        assert_equal(
            r.text(String("f4 FETCH 1 ") + unknown[i] + "\r\n"),
            "f4 BAD Invalid FETCH item\r\n",
        )
        # Mixed with an item that would set \Seen: the whole command is
        # refused and the flag stays unset.
        assert_equal(
            r.text(String("f5 FETCH 1:3 (BODY[] ") + unknown[i] + ")\r\n"),
            "f5 BAD Invalid FETCH item\r\n",
        )
    assert_equal(
        r.text(String("f3 FETCH 1:3 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\n* 2 FETCH (FLAGS ())\r\n* 3 FETCH (FLAGS ())\r\nf3 OK FETCH completed\r\n",
    )


def test_a_fetch_past_the_byte_limit_is_refused() raises:
    var a = _plain_message()
    var b = _eight_bit_message()
    var total = len(a) + len(b)
    # Exactly the limit: allowed.
    var limits = ImapLimits()
    limits.max_fetch_bytes = total
    var r = _Rig(_server(limits.copy()))
    r.add(a.copy())
    r.add(b.copy())
    r.open()
    var ok = r.raw(String("f1 FETCH 1:2 BODY.PEEK[]\r\n"))
    assert_true(len(ok) > total)
    # One byte under: refused before any message is read.
    var tight = ImapLimits()
    tight.max_fetch_bytes = total - 1
    var t = _Rig(_server(tight.copy()))
    t.add(a.copy())
    t.add(b.copy())
    t.open()
    assert_equal(
        t.text(String("f1 FETCH 1:2 BODY.PEEK[]\r\n")),
        "f1 NO [LIMIT] The response would be too large; fetch fewer messages\r\n",
    )
    # Two body items count twice.
    assert_equal(
        r.text(String("f2 FETCH 1:2 (BODY.PEEK[] RFC822)\r\n")),
        "f2 NO [LIMIT] The response would be too large; fetch fewer messages\r\n",
    )
    # And no \Seen came of the refused ones.
    assert_equal(
        t.text(String("f3 FETCH 1:2 FLAGS\r\n")),
        "* 1 FETCH (FLAGS ())\r\n* 2 FETCH (FLAGS ())\r\nf3 OK FETCH completed\r\n",
    )
    # One message at a time still works.
    assert_true(len(t.raw(String("f4 FETCH 1 BODY.PEEK[]\r\n"))) > 0)


def test_a_message_deleted_by_another_connection() raises:
    var r = _Rig(_server())
    for i in range(3):
        r.add(_text(String("Subject: m") + String(i) + "\r\n\r\nbody\r\n"))
    r.open()
    # Another connection deletes the message at its sequence number 2.
    var other = r.s.connect()
    _ = r.s.login(other, String("bob@example.com"), String("pw"))
    _ = r.s.send(other, String("s SELECT INBOX\r\n"))
    _ = r.s.send(other, String("d1 STORE 2 +FLAGS (\\Deleted)\r\n"))
    var done = r.s.send(other, String("d2 EXPUNGE\r\n"))
    assert_true(done.find("* 2 EXPUNGE") >= 0, done)
    # The first connection still lists three; asked for the bodies, it answers
    # the two that exist and ends the command NO.
    var listed = r.text(String("f1 FETCH 1:3 (UID)\r\n"))
    assert_true(listed.find("* 3 FETCH") >= 0)
    assert_true(listed.endswith("f1 OK FETCH completed\r\n"), listed)
    var body = r.text(String("f2 FETCH 1:3 BODY.PEEK[]\r\n"))
    var tail = String(
        "f2 NO [EXPUNGEISSUED] Some of the requested messages no longer exist\r\n"
    )
    assert_true(body.endswith(tail), body)
    var answers = 0
    var at = 0
    while True:
        var found = body.find("FETCH (BODY[]", at)
        if found < 0:
            break
        answers += 1
        at = found + 1
    assert_equal(answers, 2)


def main() raises:
    test_literals_are_the_stored_bytes()
    test_items_come_in_the_order_asked()
    test_uid_fetch_always_carries_the_uid()
    test_message_sets()
    test_malformed_sets_are_bad()
    test_body_sets_seen_and_peek_does_not()
    test_examine_does_not_set_seen()
    test_bad_items_are_refused_before_anything_runs()
    test_a_fetch_past_the_byte_limit_is_refused()
    test_a_message_deleted_by_another_connection()
    print("test_fetch: OK")
