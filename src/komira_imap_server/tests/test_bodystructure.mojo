# ENVELOPE, BODYSTRUCTURE and BODY, as exact strings. Each expected string is
# written by hand from RFC 3501 sections 7.4.2 and 9 (`envelope`, `body-type-*`,
# `address`) and not produced by the code under test. What each case catches:
# - a simple text message: the envelope fields in order, sender and reply-to
#   defaulting to from, NIL for what is absent, `""` for an empty value, the
#   charset parameter and `US-ASCII` default of a part with no Content-Type,
#   and the octets and lines of the body; BODY is the same without the
#   extension data;
# - multipart/alternative: the parts written one after another with no
#   separator, the subtype, the boundary parameter, and a part's octets that
#   stop before the line break that belongs to the delimiter;
# - multipart/mixed with an attachment: parameters, Content-ID, the
#   Content-Disposition with its filename, the transfer encoding in capitals,
#   and no `lines` for a part that is not text;
# - a nested message/rfc822 and a multipart inside a multipart: the nested
#   envelope, its structure and its lines; Content-MD5, Content-Language and
#   Content-Location in the extension data;
# - subjects and names with encoded words are sent as written, not decoded;
# - groups, an empty group, an absent From, a list the address parser refuses
#   (NIL), and a mailbox with no display name;
# - quoting: a quote and a backslash are escaped, and a value with a byte over
#   0x7F or a CR is a literal with the right length;
# - the macros ALL, FAST and FULL expand to the items they name.

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

    def open(mut self) raises:
        self.id = self.s.connect()
        _ = self.s.login(self.id, String("bob@example.com"), String("pw"))
        var r = self.s.send(self.id, String("s1 SELECT INBOX\r\n"))
        assert_true(r.find("s1 OK") >= 0, r)

    def ask(mut self, line: String) -> String:
        return self.s.send(self.id, line)

    def item(mut self, item: String) -> String:
        """The answer to `FETCH 1 <item>`, which must be one message
        answered and completed."""
        return self.ask(String("f1 FETCH 1 ") + item + "\r\n")


def _one(raw: String) raises -> _Rig:
    var r = _Rig()
    r.add(raw)
    r.open()
    return r^


def _reply(inner: String) -> String:
    return String("* 1 FETCH (") + inner + ")\r\nf1 OK FETCH completed\r\n"


# ---- a simple message ------------------------------------------------------

comptime SIMPLE = (
    "Date: Tue, 01 Sep 2026 10:00:00 +0000\r\n"
    "From: Alice Example <alice@example.com>\r\n"
    "To: bob@example.org\r\n"
    "Subject: Hello\r\n"
    "Message-ID: <m1@example.com>\r\n"
    "\r\n"
    "Hi Bob.\r\n"
    "Second line.\r\n"
)

comptime ALICE = '(("Alice Example" NIL "alice" "example.com"))'


def test_envelope_of_a_simple_message() raises:
    var r = _one(String(SIMPLE))
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(
            String('ENVELOPE ("Tue, 01 Sep 2026 10:00:00 +0000" "Hello" ')
            + ALICE
            + " "
            + ALICE
            + " "
            + ALICE
            + ' ((NIL NIL "bob" "example.org")) NIL NIL NIL "<m1@example.com>")'
        ),
    )


def test_bodystructure_of_a_simple_message() raises:
    var r = _one(String(SIMPLE))
    # "Hi Bob.\r\n" is 9 octets and "Second line.\r\n" is 14: 23 and 2 lines.
    assert_equal(
        r.item(String("BODYSTRUCTURE")),
        _reply(
            String(
                'BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL'
                ' "7BIT" 23 2 NIL NIL NIL NIL)'
            )
        ),
    )
    assert_equal(
        r.item(String("BODY")),
        _reply(
            String(
                'BODY ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 23 2)'
            )
        ),
    )
    # Several items at once, in the order asked.
    assert_equal(
        r.item(String("(BODY.PEEK[1] BODY)")),
        _reply(
            String('BODY[1] {23}\r\nHi Bob.\r\nSecond line.\r\n BODY ')
            + '("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 23 2)'
        ),
    )


comptime TEXT_PARAMS = (
    "From: a@x.test\r\n"
    "Content-Type: text/plain; charset=utf-8; format=flowed\r\n"
    "Content-Transfer-Encoding: Quoted-Printable\r\n"
    "Content-Language: en, de\r\n"
    "Content-Location: part/one.txt\r\n"
    "Content-MD5: Q2hlY2sgSW50ZWdyaXR5IQ==\r\n"
    "Content-Description: A note\r\n"
    "\r\n"
    "caf=C3=A9\r\n"
)


def test_a_text_part_with_its_parameters_and_extension_data() raises:
    var r = _one(String(TEXT_PARAMS))
    # "caf=C3=A9\r\n" is 11 octets, one line. Encodings are in capitals.
    assert_equal(
        r.item(String("BODYSTRUCTURE")),
        _reply(
            String(
                'BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "utf-8" "FORMAT"'
                ' "flowed") NIL "A note" "QUOTED-PRINTABLE" 11 1'
                ' "Q2hlY2sgSW50ZWdyaXR5IQ==" NIL ("en" "de") "part/one.txt")'
            )
        ),
    )


# ---- multiparts ------------------------------------------------------------

comptime ALTERNATIVE = (
    "From: a@x.test\r\n"
    "Subject: alt\r\n"
    'Content-Type: multipart/alternative; boundary="b1"\r\n'
    "\r\n"
    "This is the preamble.\r\n"
    "--b1\r\n"
    "Content-Type: text/plain; charset=us-ascii\r\n"
    "\r\n"
    "plain\r\n"
    "--b1\r\n"
    "Content-Type: text/html; charset=us-ascii\r\n"
    "\r\n"
    "<p>html</p>\r\n"
    "--b1--\r\n"
    "epilogue\r\n"
)


def test_bodystructure_of_multipart_alternative() raises:
    var r = _one(String(ALTERNATIVE))
    # "plain" is 5 octets and "<p>html</p>" is 11: the line break before each
    # delimiter is the delimiter's, so it is not counted. Each part is one
    # line (a last line with no break counts).
    var plain = String(
        '("TEXT" "PLAIN" ("CHARSET" "us-ascii") NIL NIL "7BIT" 5 1 NIL NIL NIL NIL)'
    )
    var html = String(
        '("TEXT" "HTML" ("CHARSET" "us-ascii") NIL NIL "7BIT" 11 1 NIL NIL NIL NIL)'
    )
    assert_equal(
        r.item(String("BODYSTRUCTURE")),
        _reply(
            String("BODYSTRUCTURE (")
            + plain
            + html
            + ' "ALTERNATIVE" ("BOUNDARY" "b1") NIL NIL NIL)'
        ),
    )
    # BODY drops every extension: the boundary, and the NILs of each part.
    assert_equal(
        r.item(String("BODY")),
        _reply(
            String(
                'BODY (("TEXT" "PLAIN" ("CHARSET" "us-ascii") NIL NIL "7BIT" 5 1)'
                '("TEXT" "HTML" ("CHARSET" "us-ascii") NIL NIL "7BIT" 11 1)'
                ' "ALTERNATIVE")'
            )
        ),
    )


comptime MIXED = (
    "From: a@x.test\r\n"
    "Content-Type: multipart/mixed; boundary=outer\r\n"
    "Content-Disposition: inline\r\n"
    "\r\n"
    "--outer\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "See attached.\r\n"
    "--outer\r\n"
    'Content-Type: application/pdf; name="r.pdf"\r\n'
    'Content-Disposition: attachment; filename="r.pdf"\r\n'
    "Content-Transfer-Encoding: base64\r\n"
    "Content-ID: <att1@x.test>\r\n"
    "\r\n"
    "QUJDREVGRw==\r\n"
    "--outer--\r\n"
)


def test_bodystructure_of_multipart_mixed_with_an_attachment() raises:
    var r = _one(String(MIXED))
    # The text part has a Content-Type with no parameter, so its list is NIL
    # (the US-ASCII default is for a part with no Content-Type at all). The
    # attachment is not text, so it has no `lines`.
    assert_equal(
        r.item(String("BODYSTRUCTURE")),
        _reply(
            String(
                'BODYSTRUCTURE (("TEXT" "PLAIN" NIL NIL NIL "7BIT" 13 1 NIL NIL NIL NIL)'
                '("APPLICATION" "PDF" ("NAME" "r.pdf") "<att1@x.test>" NIL "BASE64" 12'
                ' NIL ("ATTACHMENT" ("FILENAME" "r.pdf")) NIL NIL)'
                ' "MIXED" ("BOUNDARY" "outer") ("INLINE" NIL) NIL NIL)'
            )
        ),
    )


comptime NESTED_MULTIPART = (
    "From: a@x.test\r\n"
    "Content-Type: multipart/mixed; boundary=o\r\n"
    "\r\n"
    "--o\r\n"
    "Content-Type: multipart/alternative; boundary=i\r\n"
    "\r\n"
    "--i\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "one\r\n"
    "--i\r\n"
    "Content-Type: text/html\r\n"
    "\r\n"
    "<b>one</b>\r\n"
    "--i--\r\n"
    "--o\r\n"
    "Content-Type: image/png\r\n"
    "Content-Transfer-Encoding: base64\r\n"
    "\r\n"
    "AAAA\r\n"
    "--o--\r\n"
)


def test_a_multipart_inside_a_multipart_is_written_to_any_depth() raises:
    var r = _one(String(NESTED_MULTIPART))
    assert_equal(
        r.item(String("BODY")),
        _reply(
            String(
                'BODY ((("TEXT" "PLAIN" NIL NIL NIL "7BIT" 3 1)'
                '("TEXT" "HTML" NIL NIL NIL "7BIT" 10 1) "ALTERNATIVE")'
                '("IMAGE" "PNG" NIL NIL NIL "BASE64" 4) "MIXED")'
            )
        ),
    )


comptime FORWARD = (
    "From: a@x.test\r\n"
    "Content-Type: multipart/mixed; boundary=o\r\n"
    "\r\n"
    "--o\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "fwd\r\n"
    "--o\r\n"
    "Content-Type: message/rfc822\r\n"
    "\r\n"
    "Date: Wed, 02 Sep 2026 08:30:00 +0000\r\n"
    "From: Carol <carol@x.test>\r\n"
    "Subject: inner\r\n"
    "\r\n"
    "inner body\r\n"
    "--o--\r\n"
)


def test_a_nested_message_has_its_own_envelope_and_structure() raises:
    var r = _one(String(FORWARD))
    # The nested message is 39 + 28 + 16 + 2 + 10 = 95 octets: three header
    # lines, the empty line, and "inner body" with no break (the break before
    # the delimiter is the delimiter's); 5 lines. Its body part is the nested
    # message's own text, with the default charset.
    var carol = String('(("Carol" NIL "carol" "x.test"))')
    var envelope = (
        String('("Wed, 02 Sep 2026 08:30:00 +0000" "inner" ')
        + carol
        + " "
        + carol
        + " "
        + carol
        + " NIL NIL NIL NIL NIL)"
    )
    var inner = String(
        '("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 10 1 NIL NIL NIL NIL)'
    )
    assert_equal(
        r.item(String("BODYSTRUCTURE")),
        _reply(
            String(
                'BODYSTRUCTURE (("TEXT" "PLAIN" NIL NIL NIL "7BIT" 3 1 NIL NIL NIL NIL)'
                '("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 95 '
            )
            + envelope
            + " "
            + inner
            + ' 5 NIL NIL NIL NIL) "MIXED" ("BOUNDARY" "o") NIL NIL NIL)'
        ),
    )
    assert_equal(
        r.item(String("BODY")),
        _reply(
            String(
                'BODY (("TEXT" "PLAIN" NIL NIL NIL "7BIT" 3 1)'
                '("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 95 '
            )
            + envelope
            + ' ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 10 1) 5)'
            + ' "MIXED")'
        ),
    )


# ---- encoded words ---------------------------------------------------------

comptime ENCODED = (
    "Subject: =?UTF-8?Q?Caf=C3=A9?= menu\r\n"
    "From: =?UTF-8?B?w4lsw6g=?= <e@x.test>\r\n"
    "\r\n"
    "x\r\n"
)


def test_encoded_words_are_sent_as_written() raises:
    var r = _one(String(ENCODED))
    var from_ = String('(("=?UTF-8?B?w4lsw6g=?=" NIL "e" "x.test"))')
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(
            String('ENVELOPE (NIL "=?UTF-8?Q?Caf=C3=A9?= menu" ')
            + from_
            + " "
            + from_
            + " "
            + from_
            + " NIL NIL NIL NIL NIL)"
        ),
    )


# ---- addresses -------------------------------------------------------------

comptime GROUPS = (
    "To: undisclosed-recipients:;\r\n"
    'Cc: Team: a@x.test, "Bob, Jr." <b@x.test>;\r\n'
    "Bcc: erin@x.test\r\n"
    "Sender: s@x.test\r\n"
    "Reply-To: Rae <r@x.test>\r\n"
    "In-Reply-To: <prev@x.test>\r\n"
    "\r\n"
    "x\r\n"
)


def test_groups_and_missing_addresses() raises:
    var r = _one(String(GROUPS))
    # No From: from is NIL; sender and reply-to are what the message says. A
    # group is its start, its members and its end.
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(
            String(
                'ENVELOPE (NIL NIL NIL ((NIL NIL "s" "x.test")) (("Rae" NIL "r" "x.test"))'
                ' ((NIL NIL "undisclosed-recipients" NIL)(NIL NIL NIL NIL))'
                ' ((NIL NIL "Team" NIL)(NIL NIL "a" "x.test")("Bob, Jr." NIL "b" "x.test")'
                '(NIL NIL NIL NIL))'
                ' ((NIL NIL "erin" "x.test")) "<prev@x.test>" NIL)'
            )
        ),
    )


def test_an_address_list_the_parser_refuses_is_nil() raises:
    var r = _one(
        String("From: not an address at all\r\nTo: a@x.test, <\r\n\r\nx\r\n")
    )
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(String("ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL)")),
    )


def test_empty_and_absent_values() raises:
    var r = _one(String("Subject:\r\nMessage-ID:   \r\nTo: a@x.test\r\n\r\nx\r\n"))
    # Present and empty is `""`; absent is NIL.
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(
            String(
                'ENVELOPE (NIL "" NIL NIL NIL ((NIL NIL "a" "x.test")) NIL NIL NIL "")'
            )
        ),
    )


# ---- quoting ---------------------------------------------------------------


def test_quotes_and_backslashes_are_escaped() raises:
    var r = _one(
        String('Subject: say "hi" \\ back\r\nMessage-ID: <a"b@x>\r\n\r\nx\r\n')
    )
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(
            String(
                'ENVELOPE (NIL "say \\"hi\\" \\\\ back" NIL NIL NIL NIL NIL NIL NIL'
                ' "<a\\"b@x>")'
            )
        ),
    )


def test_eight_bit_and_cr_values_are_literals() raises:
    # "café" is five octets (the accent is two), and a CR inside a value
    # cannot be quoted either.
    var r = _one(
        String("Subject: caf") + chr(0xE9) + "\r\nMessage-ID: a\rb\r\n\r\nx\r\n"
    )
    assert_equal(
        r.item(String("ENVELOPE")),
        _reply(
            String("ENVELOPE (NIL {5}\r\ncaf")
            + chr(0xE9)
            + " NIL NIL NIL NIL NIL NIL NIL {3}\r\na\rb)"
        ),
    )


def test_an_eight_bit_parameter_is_a_literal() raises:
    var r = _one(
        String("Content-Type: application/x-test; name=\"")
        + chr(0xE9)
        + '.bin"\r\n\r\nx\r\n'
    )
    assert_equal(
        r.item(String("BODY")),
        _reply(
            String('BODY ("APPLICATION" "X-TEST" ("NAME" {6}\r\n')
            + chr(0xE9)
            + '.bin) NIL NIL "7BIT" 3)'
        ),
    )


# ---- macros ----------------------------------------------------------------


def test_the_macros_expand_to_their_items() raises:
    var r = _one(String(SIMPLE))
    var envelope = (
        String('ENVELOPE ("Tue, 01 Sep 2026 10:00:00 +0000" "Hello" ')
        + ALICE
        + " "
        + ALICE
        + " "
        + ALICE
        + ' ((NIL NIL "bob" "example.org")) NIL NIL NIL "<m1@example.com>")'
    )
    var size = String(SIMPLE).byte_length()
    # No Received field: the date is the Date field's.
    var head = (
        String('FLAGS () INTERNALDATE " 1-Sep-2026 10:00:00 +0000" RFC822.SIZE ')
        + String(size)
    )
    assert_equal(r.item(String("FAST")), _reply(head))
    assert_equal(r.item(String("ALL")), _reply(head + " " + envelope))
    assert_equal(
        r.item(String("FULL")),
        _reply(
            head
            + " "
            + envelope
            + ' BODY ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 23 2)'
        ),
    )


def main() raises:
    test_envelope_of_a_simple_message()
    test_bodystructure_of_a_simple_message()
    test_a_text_part_with_its_parameters_and_extension_data()
    test_bodystructure_of_multipart_alternative()
    test_bodystructure_of_multipart_mixed_with_an_attachment()
    test_a_multipart_inside_a_multipart_is_written_to_any_depth()
    test_a_nested_message_has_its_own_envelope_and_structure()
    test_encoded_words_are_sent_as_written()
    test_groups_and_missing_addresses()
    test_an_address_list_the_parser_refuses_is_nil()
    test_empty_and_absent_values()
    test_quotes_and_backslashes_are_escaped()
    test_eight_bit_and_cr_values_are_literals()
    test_an_eight_bit_parameter_is_a_literal()
    test_the_macros_expand_to_their_items()
    print("test_bodystructure: OK")
