# The parser over a corpus: RFC 5322 Appendix A.1.1 and A.5 (white space,
# comments and folding; its fields then read by komira_mail_address), the
# RFC 2047 section 8 sample header (addresses replaced by reserved example
# names), LF-only mail, 8-bit and non-UTF-8 bodies
# and headers kept as bytes, transfer encodings undone, and the malformed
# inputs refused with their exact messages: a line without ':', a fold before
# the first field, a multipart without or with an invalid boundary or with no
# delimiter line, and the depth and part limits. A missing close delimiter
# and a boundary that only prefixes a line are read as RFC 2046 says. A text
# leaf with disposition attachment is an attachment, not the text part.

from std.testing import assert_equal, assert_true

from komira_mail_address import parse_address_list, parse_mailbox
from komira_mail_message import (
    MAX_DEPTH,
    MAX_PARTS,
    decode_header_text,
    error_kind,
    parse_message,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _s(b: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span(b)))


def _error(s: String) -> String:
    var data = _b(s)
    try:
        _ = parse_message(Span(data))
    except e:
        return String(e)
    return String("OK")


def test_rfc5322_a_1_1() raises:
    var data = _b(
        String("From: John Doe <jdoe@machine.example>\r\n")
        + "To: Mary Smith <mary@example.net>\r\n"
        + "Subject: Saying Hello\r\n"
        + "Date: Fri, 21 Nov 1997 09:55:06 -0600\r\n"
        + "Message-ID: <1234@local.machine.example>\r\n"
        + "\r\n"
        + "This is a message just to say hello.\r\n"
        + 'So, "Hello".\r\n'
    )
    var m = parse_message(Span(data))
    assert_equal(len(m.headers()), 5)
    assert_equal(m.subject().value(), "Saying Hello")
    assert_equal(_s(m.header("message-id").value().value()), "<1234@local.machine.example>")
    var from_ = parse_mailbox(Span(m.header("From").value().value()))
    assert_equal(from_.addr_spec().format(), "jdoe@machine.example")
    assert_equal(m.part(0).media_type(), "text/plain")
    assert_equal(m.text_part().value(), 0)
    assert_equal(
        _s(m.decoded_body(0)),
        'This is a message just to say hello.\r\nSo, "Hello".\r\n',
    )


def test_rfc5322_a_5_folding_and_comments() raises:
    var data = _b(
        String("From: Pete(A nice \\) chap) <pete(his account)@silly.test(his host)>\r\n")
        + "To:A Group(Some people)\r\n"
        + "     :Chris Jones <c@(Chris's host.)public.example>,\r\n"
        + "         joe@example.org,\r\n"
        + "  John <jdoe@one.test> (my dear friend); (the end of the group)\r\n"
        + "Cc:(Empty list)(start)Hidden recipients  :(nobody(that I know))  ;\r\n"
        + "Date: Thu,\r\n"
        + "      13\r\n"
        + "        Feb\r\n"
        + "          1969\r\n"
        + "      23:32\r\n"
        + "               -0330 (Newfoundland Time)\r\n"
        + "Message-ID:              <testabcd.1234@silly.test>\r\n"
        + "\r\n"
        + "Testing.\r\n"
    )
    var m = parse_message(Span(data))
    assert_equal(len(m.headers()), 5)
    var to = m.header("To").value().copy()
    # `raw` keeps the folds; `value` removes only the line breaks.
    assert_equal(len(to.raw()), 4 + 20 + 2 + 51 + 2 + 25 + 2 + 63)
    var group = parse_address_list(Span(to.value()))
    assert_equal(len(group), 1)
    assert_equal(group[0].group().name(), "A Group")
    assert_equal(len(group[0].group().members()), 3)
    assert_equal(
        _s(m.header("Date").value().value()),
        "Thu,      13        Feb          1969      23:32               -0330 (Newfoundland Time)",
    )
    assert_equal(_s(m.header("Message-ID").value().value()), "<testabcd.1234@silly.test>")
    assert_equal(_s(m.decoded_body(0)), "Testing.\r\n")


def test_rfc2047_section_8_message() raises:
    var data = _b(
        String("From: =?US-ASCII?Q?Keith_Moore?= <moore@example.org>\r\n")
        + "To: =?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?= <keld@example.org>\r\n"
        + "CC: =?ISO-8859-1?Q?Andr=E9?= Pirard <PIRARD@example.org>\r\n"
        + "Subject: =?ISO-8859-1?B?SWYgeW91IGNhbiByZWFkIHRoaXMgeW8=?=\r\n"
        + "    =?ISO-8859-2?B?dSB1bmRlcnN0YW5kIHRoZSBleGFtcGxlLg==?=\r\n"
        + "\r\n"
    )
    var m = parse_message(Span(data))
    assert_equal(m.subject().value(), "If you can read this you understand the example.")
    var cc = parse_mailbox(Span(m.header("cc").value().value()))
    assert_equal(decode_header_text(cc.display_name()), "André Pirard")
    var to = parse_mailbox(Span(m.header("TO").value().value()))
    assert_equal(decode_header_text(to.display_name()), "Keld Jørn Simonsen")
    assert_equal(len(m.decoded_body(0)), 0)


def test_text_attachment_is_not_the_body() raises:
    # A text/plain leaf with `Content-Disposition: attachment` before the
    # body: text_part is the body, the attachment is in attachments.
    var m = parse_message(
        Span(
            _b(
                String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
                + "--b\r\nContent-Type: text/plain\r\n"
                + "Content-Disposition: attachment; filename=notes.txt\r\n\r\nnotes\r\n"
                + "--b\r\nContent-Type: text/plain\r\n\r\nbody\r\n"
                + "--b--\r\n"
            )
        )
    )
    assert_equal(m.part_count(), 3)
    assert_equal(m.text_part().value(), 2)
    assert_equal(_s(m.decoded_body(2)), "body")
    var att = m.attachments()
    assert_equal(len(att), 1)
    assert_equal(att[0], 1)
    # Only a text attachment: no text part.
    var only = parse_message(
        Span(
            _b(
                String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
                + "--b\r\nContent-Type: text/plain\r\n"
                + "Content-Disposition: ATTACHMENT\r\n\r\nnotes\r\n--b--\r\n"
            )
        )
    )
    assert_true(not only.text_part())
    assert_equal(len(only.attachments()), 1)
    assert_equal(only.attachments()[0], 1)


def test_lf_only_and_no_body() raises:
    var m = parse_message(Span(_b("Subject: a\n  b\nX: y\n\nbody\n")))
    assert_equal(m.subject().value(), "a  b")
    assert_equal(_s(m.decoded_body(0)), "body\n")
    var h = parse_message(Span(_b("Subject: only a header")))
    assert_equal(h.subject().value(), "only a header")
    assert_equal(len(h.raw_body(0)), 0)


def test_8bit_and_non_utf8_kept_as_bytes() raises:
    var data = _b(
        String("Subject: caf")
    )
    data.append(0xE9)  # ISO-8859-1 e-acute, not UTF-8
    var rest = _b(
        String("\r\nContent-Type: text/plain; charset=ISO-8859-1\r\n")
        + "Content-Transfer-Encoding: 8bit\r\n\r\nna"
    )
    for i in range(len(rest)):
        data.append(rest[i])
    data.append(0xEF)
    data.append(0x76)
    data.append(0xFF)
    data.append(0x00)
    var m = parse_message(Span(data))
    var subject = m.header("Subject").value().value()
    assert_equal(len(subject), 4)
    assert_equal(Int(subject[3]), 0xE9)
    assert_equal(m.subject().value(), String("caf") + chr(0xFFFD))
    assert_equal(m.part(0).charset(), "iso-8859-1")
    var body = m.decoded_body(0)
    assert_equal(len(body), 6)
    assert_equal(Int(body[2]), 0xEF)
    assert_equal(Int(body[4]), 0xFF)
    assert_equal(Int(body[5]), 0)


def test_transfer_encodings() raises:
    var data = _b(
        String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
        + "preamble\r\n"
        + "--b\r\n"
        + "Content-Type: text/plain; charset=utf-8\r\n"
        + "Content-Transfer-Encoding: Quoted-Printable\r\n\r\n"
        + "caf=C3=A9 =\r\nau lait\r\n"
        + "--b\r\n"
        + "Content-Type: image/png\r\n"
        + "Content-Disposition: inline; filename=\"=?UTF-8?Q?d=C3=A9.png?=\"\r\n"
        + "Content-Transfer-Encoding: BASE64\r\n\r\n"
        + "iVBO\r\n Rw0K\r\n"
        + "--b\r\n"
        + "Content-Transfer-Encoding: x-uuencode\r\n\r\n"
        + "begin\r\n"
        + "--b--\r\n"
        + "epilogue\r\n"
    )
    var m = parse_message(Span(data))
    assert_equal(m.part_count(), 4)
    assert_equal(_s(m.decoded_body(1)), "café au lait")
    var png = m.decoded_body(2)
    assert_equal(len(png), 6)
    assert_equal(Int(png[0]), 0x89)
    assert_equal(Int(png[5]), 0x0A)
    assert_equal(m.part(2).filename().value(), "dé.png")
    assert_equal(m.part(2).transfer_encoding(), "base64")
    var msg = String("")
    try:
        _ = m.decoded_body(3)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.Encoding: decoded_body: an unknown Content-Transfer-Encoding",
    )
    var att = m.attachments()
    assert_equal(len(att), 2)
    assert_equal(att[0], 2)
    assert_equal(att[1], 3)


def test_content_type_name_fallback() raises:
    # With no Content-Disposition filename, filename() reads the Content-Type
    # `name`. An RFC 2231 value is taken as written; a plain value has its
    # RFC 2047 encoded words decoded.
    var data = _b(
        String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
        + "--b\r\n"
        + "Content-Type: application/x; name*=utf-8''%3D%3FUTF-8%3FQ%3Fx%3F%3D\r\n\r\n"
        + "a\r\n"
        + "--b\r\n"
        + "Content-Type: application/x; name=\"=?UTF-8?Q?y?=\"\r\n\r\n"
        + "b\r\n"
        + "--b--\r\n"
    )
    var m = parse_message(Span(data))
    assert_equal(m.part_count(), 3)
    assert_equal(m.part(1).filename().value(), "=?UTF-8?Q?x?=")
    assert_equal(m.part(2).filename().value(), "y")


def test_disposition_filename_wins_over_name() raises:
    # When both are present and differ, the Content-Disposition `filename`
    # is the file name and the Content-Type `name` is not read.
    var data = _b(
        String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
        + "--b\r\n"
        + "Content-Type: application/x; name=b.bin\r\n"
        + "Content-Disposition: attachment; filename=a.bin\r\n\r\n"
        + "a\r\n"
        + "--b--\r\n"
    )
    var m = parse_message(Span(data))
    assert_equal(m.part_count(), 2)
    assert_equal(m.part(1).filename().value(), "a.bin")


def test_malformed_headers() raises:
    assert_equal(
        _error("Subject: a\r\nno colon here\r\n\r\n"),
        "komira_mail_message.Syntax: parse_message: a header line without ':' at position 12",
    )
    assert_equal(
        _error(" folded: first\r\n\r\n"),
        "komira_mail_message.Syntax: parse_message: a folded line before the first header field at position 0",
    )
    assert_equal(
        _error(String("Sub") + chr(1) + "ject: a\r\n\r\n"),
        "komira_mail_message.Syntax: parse_message: a byte not allowed in a header field name at position 3",
    )
    # An mbox "From " line is not a header field.
    assert_equal(error_kind(Error(_error("From a@b Thu Oct  8 12:00:00 1998\n\n"))), "Syntax")
    # The obsolete white space before the colon is accepted.
    var m = parse_message(Span(_b("Subject : x\r\n\r\n")))
    assert_equal(m.headers()[0].name(), "Subject")


def test_header_and_part_edges() raises:
    # White space ending a field body is trimmed.
    var m = parse_message(Span(_b("Subject: hi \t\r\n\r\nbody")))
    assert_equal(_s(m.headers()[0].value()), "hi")
    # An empty field name, at the start and after a field.
    assert_equal(
        _error(": x\r\n\r\n"),
        "komira_mail_message.Syntax: parse_message: an empty header field name at position 0",
    )
    assert_equal(
        _error("Subject: a\r\n: x\r\n\r\n"),
        "komira_mail_message.Syntax: parse_message: an empty header field name at position 12",
    )
    # Absent values: a header, the charset, the Subject.
    m = parse_message(Span(_b("Content-Type: text/plain\r\n\r\nx")))
    assert_true(Bool(m.part(0).header("content-type")))
    assert_true(not m.part(0).header("X-Absent"))
    assert_equal(m.part(0).charset(), "")
    assert_true(not m.subject())
    m = parse_message(Span(_b("Content-Type: text/plain; charset=UTF-8\r\n\r\nx")))
    assert_equal(m.part(0).charset(), "utf-8")
    # A boundary byte outside bcharsnospace: in the middle, first and last.
    var bad_boundaries = List[String]()
    bad_boundaries.append("a<b")
    bad_boundaries.append("<ab")
    bad_boundaries.append("ab<")
    for k in range(len(bad_boundaries)):
        var bb = bad_boundaries[k]
        assert_equal(
            _error(
                'Content-Type: multipart/mixed; boundary="' + bb + '"\r\n\r\n--'
                + bb + "\r\n\r\nx\r\n--" + bb + "--\r\n"
            ),
            "komira_mail_message.Syntax: parse_message: an invalid multipart boundary at position 0",
        )
    # base64 whose alphabet characters are not a multiple of four.
    m = parse_message(
        Span(_b("Content-Transfer-Encoding: base64\r\n\r\nQUJD\r\nR\r\n"))
    )
    var msg = String("not raised")
    try:
        _ = m.decoded_body(0)
    except e:
        msg = String(e)
    assert_equal(
        msg, "komira_mail_message.Encoding: decoded_body: base64 that does not decode"
    )


def test_malformed_multipart() raises:
    assert_equal(
        _error("Content-Type: multipart/mixed\r\n\r\n--b\r\n\r\nx\r\n--b--\r\n"),
        "komira_mail_message.Syntax: parse_message: a multipart without a boundary parameter at position 0",
    )
    var long = String("")
    for _ in range(71):
        long += "b"
    assert_equal(
        _error(String("Content-Type: multipart/mixed; boundary=") + long + "\r\n\r\n"),
        "komira_mail_message.Syntax: parse_message: an invalid multipart boundary at position 0",
    )
    assert_equal(
        _error('Content-Type: multipart/mixed; boundary="b "\r\n\r\n'),
        "komira_mail_message.Syntax: parse_message: an invalid multipart boundary at position 0",
    )
    assert_equal(
        _error("Content-Type: multipart/mixed; boundary=b\r\n\r\nno delimiter\r\n"),
        "komira_mail_message.Syntax: parse_message: a multipart body without a delimiter line at position 45",
    )
    # A part inside the multipart with a bad header names its own position.
    assert_equal(
        _error("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nbad\r\n--b--\r\n"),
        "komira_mail_message.Syntax: parse_message: a header line without ':' at position 50",
    )


def test_lenient_multipart_reading() raises:
    # No close delimiter: the last part runs to the end. `--bx` and `--b x`
    # are not delimiters; `--b  ` (transport padding) is.
    var m = parse_message(
        Span(
            _b(
                String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
                + "--b  \r\n\r\none\r\n--bx\r\n--b x\r\n"
                + "--b\r\n\r\ntwo"
            )
        )
    )
    assert_equal(m.part_count(), 3)
    assert_equal(_s(m.raw_body(1)), "one\r\n--bx\r\n--b x")
    assert_equal(_s(m.raw_body(2)), "two")


def _nested(levels: Int) -> String:
    var s = String("")
    for i in range(levels):
        s += "Content-Type: multipart/mixed; boundary=b" + String(i) + "\r\n\r\n--b" + String(i) + "\r\n"
    s += "\r\nleaf\r\n"
    for i in range(levels - 1, -1, -1):
        s += "--b" + String(i) + "--\r\n"
    return s


def test_depth_limit() raises:
    # MAX_DEPTH multiparts put the leaf at depth MAX_DEPTH: read.
    var ok = _b(_nested(MAX_DEPTH))
    var m = parse_message(Span(ok))
    assert_equal(m.part_count(), MAX_DEPTH + 1)
    assert_equal(m.part(MAX_DEPTH).depth(), MAX_DEPTH)
    # One more: refused, and so with a smaller limit.
    var msg = _error(_nested(MAX_DEPTH + 1))
    assert_true(
        msg.startswith("komira_mail_message.Limit: parse_message: parts nested deeper than the limit at position "),
        msg,
    )
    var two = _b(_nested(2))
    try:
        _ = parse_message(Span(two), max_depth=1)
        assert_true(False, "depth 2 read with max_depth=1")
    except e:
        assert_equal(error_kind(e), "Limit")


def _many(parts: Int) -> String:
    var s = String("Content-Type: multipart/mixed; boundary=b\r\n\r\n")
    for _ in range(parts):
        s += "--b\r\n\r\nx\r\n"
    s += "--b--\r\n"
    return s


def test_part_limit() raises:
    # The message and MAX_PARTS - 1 children: read.
    var ok = _b(_many(MAX_PARTS - 1))
    assert_equal(parse_message(Span(ok)).part_count(), MAX_PARTS)
    var msg = _error(_many(MAX_PARTS))
    assert_true(
        msg.startswith("komira_mail_message.Limit: parse_message: more parts than the limit at position "),
        msg,
    )
    var five = _b(_many(5))
    try:
        _ = parse_message(Span(five), max_parts=5)
        assert_true(False, "6 parts read with max_parts=5")
    except e:
        assert_equal(error_kind(e), "Limit")


def main() raises:
    test_rfc5322_a_1_1()
    test_rfc5322_a_5_folding_and_comments()
    test_rfc2047_section_8_message()
    test_text_attachment_is_not_the_body()
    test_lf_only_and_no_body()
    test_8bit_and_non_utf8_kept_as_bytes()
    test_transfer_encodings()
    test_content_type_name_fallback()
    test_disposition_filename_wins_over_name()
    test_malformed_headers()
    test_header_and_part_edges()
    test_malformed_multipart()
    test_lenient_multipart_reading()
    test_depth_limit()
    test_part_limit()
    print("test_parse_corpus: OK")
