# BODY[<section>]<partial>, BODY.PEEK[...], RFC822.HEADER, RFC822.TEXT,
# RFC822.SIZE and INTERNALDATE: every section form on one fixture, with the
# expected bytes written out by hand. What each case catches:
# - HEADER, TEXT, HEADER.FIELDS (names in any case, quoted names, a field
#   that is absent, a folded field kept as written) and HEADER.FIELDS.NOT: the
#   exact bytes and the exact `{n}`, and the reply naming the section in
#   capitals;
# - numbered parts (1, 2.1, 3), MIME of each, a nested message/rfc822 reached
#   by path (2.2, its HEADER, TEXT, HEADER.FIELDS, MIME, and 2.2.1 inside it),
#   and a section that does not exist answered NIL: a part number past the
#   end, a number under a leaf, HEADER of a part that is not a message;
# - partials: the origin echoed, truncation at the end, an origin at the
#   end or past it (an empty literal), a partial of a header section, of a
#   built field subset and of a missing section; `<0.0>` and malformed
#   partials are BAD;
# - \Seen: BODY[...] of any section (partial too) sets it, BODY.PEEK[...] and
#   RFC822.HEADER do not, RFC822.TEXT does, and EXAMINE sets nothing;
# - UID FETCH adds the UID after a section;
# - INTERNALDATE: the first Received field's time, else the Date field's, else
#   the Unix epoch; a day under 10 padded by a space; a zone converted to UTC;
# - a message with bare LF line ends has the same sections.

from std.testing import assert_equal, assert_true

from komira_mail_store import store_message
from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import ImapServerConfig, ImapTestServer


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


struct _Rig(Movable):
    var s: ImapTestServer[SharedInMemoryConditionalStore]
    var id: Int

    def __init__(out self):
        var config = ImapServerConfig(String("imap.test"), False, True)
        self.s = ImapTestServer[SharedInMemoryConditionalStore](
            config^, SharedInMemoryConditionalStore()
        )
        self.s.add_user(String("bob@example.com"), String("pw"))
        self.id = 0

    def add(mut self, raw: String) raises:
        _ = store_message(
            self.s.store,
            String("bob@example.com"),
            String("INBOX"),
            _bytes(raw),
        )

    def open(mut self, examine: Bool = False) raises:
        self.id = self.s.connect()
        _ = self.s.login(self.id, String("bob@example.com"), String("pw"))
        var verb = String("EXAMINE") if examine else String("SELECT")
        var r = self.s.send(self.id, String("s1 ") + verb + " INBOX\r\n")
        assert_true(r.find("s1 OK") >= 0, r)

    def ask(mut self, line: String) -> String:
        return self.s.send(self.id, line)

    def item(mut self, item: String) -> String:
        return self.ask(String("f1 FETCH 1 ") + item + "\r\n")


def _one(raw: String, examine: Bool = False) raises -> _Rig:
    var r = _Rig()
    r.add(raw)
    r.open(examine)
    return r^


def _reply(inner: String) -> String:
    return String("* 1 FETCH (") + inner + ")\r\nf1 OK FETCH completed\r\n"


def _lit(name: String, payload: String) -> String:
    """An item answered as a literal: the name, `{n}` and the n bytes."""
    return name + " {" + String(payload.byte_length()) + "}\r\n" + payload


comptime HEADER = (
    "From: a@x.test\r\n"
    "To: b@x.test\r\n"
    "Subject: s\r\n"
    "X-Tag: one\r\n"
    " two\r\n"
    "Content-Type: multipart/mixed; boundary=o\r\n"
    "\r\n"
)

comptime NESTED = (
    "Subject: deep\r\n"
    "From: d@x.test\r\n"
    "X-A: 1\r\n"
    "\r\n"
    "deep body"
)

comptime TEXT = (
    "--o\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "part one\r\n"
    "--o\r\n"
    "Content-Type: multipart/alternative; boundary=i\r\n"
    "\r\n"
    "--i\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "alt plain\r\n"
    "--i\r\n"
    "Content-Type: message/rfc822\r\n"
    "\r\n"
    "Subject: deep\r\n"
    "From: d@x.test\r\n"
    "X-A: 1\r\n"
    "\r\n"
    "deep body\r\n"
    "--i--\r\n"
    "--o\r\n"
    "Content-Type: application/octet-stream\r\n"
    "\r\n"
    "BIN\r\n"
    "--o--\r\n"
)


def _fixture() -> String:
    return String(HEADER) + String(TEXT)


# ---- the message and its header --------------------------------------------


def test_whole_message_header_and_text() raises:
    var r = _one(_fixture())
    assert_equal(
        r.item(String("BODY.PEEK[HEADER]")),
        _reply(_lit(String("BODY[HEADER]"), String(HEADER))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[TEXT]")),
        _reply(_lit(String("BODY[TEXT]"), String(TEXT))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[]")), _reply(_lit(String("BODY[]"), _fixture()))
    )
    # The older names for the same bytes.
    assert_equal(
        r.item(String("RFC822.HEADER")),
        _reply(_lit(String("RFC822.HEADER"), String(HEADER))),
    )
    assert_equal(
        r.item(String("RFC822.SIZE")),
        _reply(String("RFC822.SIZE ") + String(_fixture().byte_length())),
    )


def test_header_fields_and_the_fields_not() raises:
    var r = _one(_fixture())
    # The lines as written, in the message's order, then the empty line. The
    # reply names the keyword in capitals and the fields as the client wrote
    # them.
    assert_equal(
        r.item(String("BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)]")),
        _reply(
            _lit(
                String("BODY[HEADER.FIELDS (FROM SUBJECT)]"),
                String("From: a@x.test\r\nSubject: s\r\n\r\n"),
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[header.fields (subject from)]")),
        _reply(
            _lit(
                String("BODY[HEADER.FIELDS (subject from)]"),
                String("From: a@x.test\r\nSubject: s\r\n\r\n"),
            )
        ),
    )
    # A folded field keeps its fold; a quoted name works; the name's case does
    # not matter.
    assert_equal(
        r.item(String('BODY.PEEK[HEADER.FIELDS ("x-tag" TO)]')),
        _reply(
            _lit(
                String('BODY[HEADER.FIELDS (x-tag TO)]'),
                String("To: b@x.test\r\nX-Tag: one\r\n two\r\n\r\n"),
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[HEADER.FIELDS.NOT (from to subject content-type)]")),
        _reply(
            _lit(
                String("BODY[HEADER.FIELDS.NOT (from to subject content-type)]"),
                String("X-Tag: one\r\n two\r\n\r\n"),
            )
        ),
    )
    # No field matches: only the empty line. Every field excluded likewise.
    assert_equal(
        r.item(String("BODY.PEEK[HEADER.FIELDS (Cc)]")),
        _reply(_lit(String("BODY[HEADER.FIELDS (Cc)]"), String("\r\n"))),
    )
    assert_equal(
        r.item(
            String(
                "BODY.PEEK[HEADER.FIELDS.NOT (from to subject x-tag content-type)]"
            )
        ),
        _reply(
            _lit(
                String("BODY[HEADER.FIELDS.NOT (from to subject x-tag content-type)]"),
                String("\r\n"),
            )
        ),
    )


# ---- numbered parts --------------------------------------------------------


def test_numbered_parts_and_their_mime() raises:
    var r = _one(_fixture())
    assert_equal(
        r.item(String("BODY.PEEK[1]")),
        _reply(_lit(String("BODY[1]"), String("part one"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.1]")),
        _reply(_lit(String("BODY[2.1]"), String("alt plain"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[3]")), _reply(_lit(String("BODY[3]"), String("BIN")))
    )
    # A multipart part is its preamble, delimiters and parts as written.
    assert_equal(
        r.item(String("BODY.PEEK[2]")),
        _reply(
            _lit(
                String("BODY[2]"),
                String(
                    "--i\r\nContent-Type: text/plain\r\n\r\nalt plain\r\n"
                    "--i\r\nContent-Type: message/rfc822\r\n\r\n"
                    "Subject: deep\r\nFrom: d@x.test\r\nX-A: 1\r\n\r\ndeep body\r\n"
                    "--i--"
                ),
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1.MIME]")),
        _reply(
            _lit(String("BODY[1.MIME]"), String("Content-Type: text/plain\r\n\r\n"))
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.MIME]")),
        _reply(
            _lit(
                String("BODY[2.MIME]"),
                String("Content-Type: multipart/alternative; boundary=i\r\n\r\n"),
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.1.MIME]")),
        _reply(
            _lit(
                String("BODY[2.1.MIME]"), String("Content-Type: text/plain\r\n\r\n")
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[3.MIME]")),
        _reply(
            _lit(
                String("BODY[3.MIME]"),
                String("Content-Type: application/octet-stream\r\n\r\n"),
            )
        ),
    )


def test_a_nested_message_is_reached_by_path() raises:
    var r = _one(_fixture())
    # 2.2 is the nested message's bytes as the outer message holds them.
    assert_equal(
        r.item(String("BODY.PEEK[2.2]")),
        _reply(_lit(String("BODY[2.2]"), String(NESTED))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.2.HEADER]")),
        _reply(
            _lit(
                String("BODY[2.2.HEADER]"),
                String("Subject: deep\r\nFrom: d@x.test\r\nX-A: 1\r\n\r\n"),
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.2.TEXT]")),
        _reply(_lit(String("BODY[2.2.TEXT]"), String("deep body"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.2.HEADER.FIELDS (X-A subject)]")),
        _reply(
            _lit(
                String("BODY[2.2.HEADER.FIELDS (X-A subject)]"),
                String("Subject: deep\r\nX-A: 1\r\n\r\n"),
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.2.HEADER.FIELDS.NOT (X-A subject)]")),
        _reply(
            _lit(
                String("BODY[2.2.HEADER.FIELDS.NOT (X-A subject)]"),
                String("From: d@x.test\r\n\r\n"),
            )
        ),
    )
    # The nested message is not a multipart, so its part 1 is its body.
    assert_equal(
        r.item(String("BODY.PEEK[2.2.1]")),
        _reply(_lit(String("BODY[2.2.1]"), String("deep body"))),
    )
    # MIME of the part is the part's own header block in the outer message.
    assert_equal(
        r.item(String("BODY.PEEK[2.2.MIME]")),
        _reply(
            _lit(
                String("BODY[2.2.MIME]"),
                String("Content-Type: message/rfc822\r\n\r\n"),
            )
        ),
    )


def test_a_section_that_does_not_exist_is_nil() raises:
    var r = _one(_fixture())
    var names = List[String]()
    names.append(String("4"))  # past the last part
    names.append(String("2.3"))
    names.append(String("1.1"))  # under a leaf
    names.append(String("3.1"))
    names.append(String("2.2.2"))  # past the nested message's one part
    names.append(String("1.HEADER"))  # HEADER and TEXT need a message
    names.append(String("1.TEXT"))
    names.append(String("2.HEADER"))
    names.append(String("3.HEADER.FIELDS (X)"))
    names.append(String("9.MIME"))
    for i in range(len(names)):
        assert_equal(
            r.item(String("BODY.PEEK[") + names[i] + "]"),
            _reply(String("BODY[") + names[i] + "] NIL"),
        )
    # A nonexistent section does not fail the command or the others.
    assert_equal(
        r.item(String("(BODY.PEEK[1] BODY.PEEK[4])")),
        _reply(_lit(String("BODY[1]"), String("part one")) + " BODY[4] NIL"),
    )


# ---- partials --------------------------------------------------------------


def test_partial_edges() raises:
    var r = _one(_fixture())
    # <origin.length>: the origin is echoed, the length truncates at the end.
    assert_equal(
        r.item(String("BODY.PEEK[1]<2.3>")),
        _reply(_lit(String("BODY[1]<2>"), String("rt "))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1]<0.100>")),
        _reply(_lit(String("BODY[1]<0>"), String("part one"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1]<0.8>")),
        _reply(_lit(String("BODY[1]<0>"), String("part one"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1]<0.1>")),
        _reply(_lit(String("BODY[1]<0>"), String("p"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1]<7.5>")),
        _reply(_lit(String("BODY[1]<7>"), String("e"))),
    )
    # At the end, and past it: an empty literal, not NIL and not an error.
    assert_equal(
        r.item(String("BODY.PEEK[1]<8.5>")),
        _reply(String("BODY[1]<8> {0}\r\n")),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1]<9999.5>")),
        _reply(String("BODY[1]<9999> {0}\r\n")),
    )
    # A partial of the whole message, of a header, of a built field subset,
    # of a nested part and of a section that is not there.
    assert_equal(
        r.item(String("BODY.PEEK[]<6.10>")),
        _reply(_lit(String("BODY[]<6>"), String("a@x.test\r\n"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[HEADER]<12.9>")),
        _reply(_lit(String("BODY[HEADER]<12>"), String("st\r\nTo: b"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)]<8.8>")),
        _reply(
            _lit(
                String("BODY[HEADER.FIELDS (FROM SUBJECT)]<8>"), String("x.test\r\n")
            )
        ),
    )
    assert_equal(
        r.item(String("BODY.PEEK[2.2.TEXT]<5.100>")),
        _reply(_lit(String("BODY[2.2.TEXT]<5>"), String("body"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[4]<0.10>")), _reply(String("BODY[4]<0> NIL"))
    )
    # An empty section with a partial is an empty literal too.
    assert_equal(
        r.item(String("BODY.PEEK[HEADER.FIELDS (Cc)]<5.10>")),
        _reply(String("BODY[HEADER.FIELDS (Cc)]<5> {0}\r\n")),
    )


def test_a_partial_with_a_zero_length_is_not_imap() raises:
    var r = _one(_fixture())
    assert_equal(
        r.item(String("BODY.PEEK[1]<0.0>")), "f1 BAD Invalid FETCH item\r\n"
    )


# ---- \Seen -----------------------------------------------------------------


def _flags(mut r: _Rig) -> String:
    return r.ask(String("g1 FETCH 1 FLAGS\r\n"))


def test_which_items_set_seen() raises:
    var unseen = String("* 1 FETCH (FLAGS ())\r\ng1 OK FETCH completed\r\n")
    var seen = String("* 1 FETCH (FLAGS (\\Seen))\r\ng1 OK FETCH completed\r\n")
    var no = List[String]()
    no.append(String("BODY.PEEK[1]"))
    no.append(String("BODY.PEEK[HEADER]"))
    no.append(String("RFC822.HEADER"))
    no.append(String("RFC822.SIZE"))
    no.append(String("ENVELOPE"))
    no.append(String("BODYSTRUCTURE"))
    no.append(String("INTERNALDATE"))
    for i in range(len(no)):
        var r = _one(_fixture())
        _ = r.item(no[i])
        assert_equal(_flags(r), unseen)
    var yes = List[String]()
    yes.append(String("BODY[1]"))
    yes.append(String("BODY[HEADER]"))
    yes.append(String("BODY[HEADER.FIELDS (FROM)]"))
    yes.append(String("BODY[2.2.TEXT]"))
    yes.append(String("BODY[]<0.5>"))
    yes.append(String("RFC822.TEXT"))
    yes.append(String("RFC822"))
    for i in range(len(yes)):
        var r = _one(_fixture())
        _ = r.item(yes[i])
        assert_equal(_flags(r), seen)
    # EXAMINE sets nothing.
    var ro = _one(_fixture(), True)
    _ = ro.item(String("BODY[1]"))
    assert_equal(_flags(ro), unseen)


def test_a_section_that_sets_seen_adds_flags_to_the_answer() raises:
    var r = _one(_fixture())
    assert_equal(
        r.item(String("BODY[1]")),
        String("* 1 FETCH (")
        + _lit(String("BODY[1]"), String("part one"))
        + " FLAGS (\\Seen))\r\nf1 OK FETCH completed\r\n",
    )
    # The second time it is already set and nothing is added.
    assert_equal(
        r.item(String("BODY[1]")),
        _reply(_lit(String("BODY[1]"), String("part one"))),
    )


def test_uid_fetch_adds_the_uid_after_a_section() raises:
    var r = _one(_fixture())
    var uid = r.s.reg.uid_at(r.id, 1)
    assert_equal(
        r.ask(String("u1 UID FETCH ") + String(uid) + " BODY.PEEK[1]\r\n"),
        String("* 1 FETCH (")
        + _lit(String("BODY[1]"), String("part one"))
        + " UID "
        + String(uid)
        + ")\r\nu1 OK FETCH completed\r\n",
    )


# ---- INTERNALDATE ----------------------------------------------------------


def _date_of(raw: String) raises -> String:
    var r = _one(raw)
    return r.item(String("INTERNALDATE"))


def test_internaldate_comes_from_received_then_date_then_the_epoch() raises:
    var received = String(
        "Received: from c.test (192.0.2.1)\r\n"
        "\tby mx.example.com with ESMTP id q1\r\n"
        "\tfor <bob@example.com>; Mon, 21 Sep 2026 14:13:20 +0000\r\n"
    )
    # The first Received field is the time the mail arrived, not the Date.
    assert_equal(
        _date_of(
            received
            + "Received: from older.test; Tue, 01 Sep 2026 10:00:00 +0000\r\n"
            + "Date: Wed, 02 Sep 2026 08:30:00 +0000\r\n\r\nx\r\n"
        ),
        _reply(String('INTERNALDATE "21-Sep-2026 14:13:20 +0000"')),
    )
    # No Received: the Date, with the day padded to two characters.
    assert_equal(
        _date_of(String("Date: Tue, 01 Sep 2026 10:00:00 +0000\r\n\r\nx\r\n")),
        _reply(String('INTERNALDATE " 1-Sep-2026 10:00:00 +0000"')),
    )
    # A zone is converted: the instant is written in UTC.
    assert_equal(
        _date_of(String("Date: Tue, 01 Sep 2026 10:00:00 +0200\r\n\r\nx\r\n")),
        _reply(String('INTERNALDATE " 1-Sep-2026 08:00:00 +0000"')),
    )
    # A Received without a date, or with one that is not, falls to the Date.
    assert_equal(
        _date_of(
            String(
                "Received: from c.test by mx\r\n"
                "Date: Wed, 02 Sep 2026 08:30:00 +0000\r\n\r\nx\r\n"
            )
        ),
        _reply(String('INTERNALDATE " 2-Sep-2026 08:30:00 +0000"')),
    )
    assert_equal(
        _date_of(
            String(
                "Received: from c.test by mx; not a date\r\n"
                "Date: Wed, 02 Sep 2026 08:30:00 +0000\r\n\r\nx\r\n"
            )
        ),
        _reply(String('INTERNALDATE " 2-Sep-2026 08:30:00 +0000"')),
    )
    # Neither: the Unix epoch, a fixed value.
    assert_equal(
        _date_of(String("Subject: none\r\n\r\nx\r\n")),
        _reply(String('INTERNALDATE " 1-Jan-1970 00:00:00 +0000"')),
    )
    assert_equal(
        _date_of(String("Date: yesterday\r\n\r\nx\r\n")),
        _reply(String('INTERNALDATE " 1-Jan-1970 00:00:00 +0000"')),
    )


# ---- bare LF ---------------------------------------------------------------


def test_a_message_with_bare_lf_line_ends() raises:
    var r = _one(String("Subject: x\nTo: a@x.test\n\nbody\n"))
    assert_equal(
        r.item(String("BODY.PEEK[HEADER]")),
        _reply(_lit(String("BODY[HEADER]"), String("Subject: x\nTo: a@x.test\n\n"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[TEXT]")),
        _reply(_lit(String("BODY[TEXT]"), String("body\n"))),
    )
    assert_equal(
        r.item(String("BODY.PEEK[1]")), _reply(_lit(String("BODY[1]"), String("body\n")))
    )
    # The lines are as written; the empty line the subset ends with is CRLF.
    assert_equal(
        r.item(String("BODY.PEEK[HEADER.FIELDS (to)]")),
        _reply(_lit(String("BODY[HEADER.FIELDS (to)]"), String("To: a@x.test\n\r\n"))),
    )
    assert_equal(
        r.item(String("BODYSTRUCTURE")),
        _reply(
            String(
                'BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT"'
                " 5 1 NIL NIL NIL NIL)"
            )
        ),
    )


def main() raises:
    test_whole_message_header_and_text()
    test_header_fields_and_the_fields_not()
    test_numbered_parts_and_their_mime()
    test_a_nested_message_is_reached_by_path()
    test_a_section_that_does_not_exist_is_nil()
    test_partial_edges()
    test_a_partial_with_a_zero_length_is_not_imap()
    test_which_items_set_seen()
    test_a_section_that_sets_seen_adds_flags_to_the_answer()
    test_uid_fetch_adds_the_uid_after_a_section()
    test_internaldate_comes_from_received_then_date_then_the_epoch()
    test_a_message_with_bare_lf_line_ends()
    print("test_sections: OK")
