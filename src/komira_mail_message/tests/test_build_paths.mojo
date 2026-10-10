# Builder paths beyond the goldens: the reply fields (Reply-To, In-Reply-To,
# References, RFC 5322 section 3.6.4) written exactly, an HTML-only message,
# line breaks normalized to CRLF (CRLF, bare LF and bare CR) with a final
# CRLF added, a text line over 998 octets sent quoted-printable instead of
# 7bit, a boundary changed when a part holds it, a long non-ASCII file name
# split into RFC 2231 sections that fold, an ASCII file name quoted with its
# escapes, an ASCII display name holding `=?` sent as an encoded word, an
# ASCII file name holding `=?` sent in RFC 2231 form so it reads back as
# written, and a forwarded message/rfc822 attachment and a message/partial
# attachment written 7bit.

from std.testing import assert_equal, assert_true

from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder, parse_message


def _s(b: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span(b)))


def _builder() raises -> MessageBuilder:
    var b = MessageBuilder()
    b.set_from("", AddrSpec("a", "acme.example"))
    b.set_date(1790000000)
    return b^


def _body_of(built: List[UInt8]) raises -> String:
    var text = _s(built)
    var at = text.find("\r\n\r\n")
    return String(text[byte = at + 4 : text.byte_length()])


def test_reply_fields() raises:
    var b = _builder()
    b.add_reply_to("Help", AddrSpec("help", "acme.example"))
    b.add_reply_to("", AddrSpec("ops", "acme.example"))
    b.set_in_reply_to("<a.1@example.com>")
    b.add_reference("<a.0@example.com>")
    b.add_reference("<a.1@example.com>")
    b.add_header("X-Mailer", "komira")
    var text = _s(b.build())
    var expected = (
        String("Date: Mon, 21 Sep 2026 14:13:20 +0000\r\n")
        + "From: a@acme.example\r\n"
        + "Reply-To: Help <help@acme.example>, ops@acme.example\r\n"
        + "In-Reply-To: <a.1@example.com>\r\n"
        + "References: <a.0@example.com> <a.1@example.com>\r\n"
        + "X-Mailer: komira\r\n"
        + "MIME-Version: 1.0\r\n"
    )
    assert_true(text.startswith(expected), text)


def test_html_only_and_line_breaks() raises:
    var b = _builder()
    b.set_html("<p>a</p>\r\n<p>b</p>\n<p>c</p>\rend")
    var built = b.build()
    var text = _s(built)
    assert_true(text.find("Content-Type: text/html; charset=utf-8\r\n") > 0, text)
    assert_equal(_body_of(built), "<p>a</p>\r\n<p>b</p>\r\n<p>c</p>\r\nend\r\n")
    var m = parse_message(Span(built))
    assert_equal(m.html_part().value(), 0)
    assert_true(not m.text_part())


def test_line_over_998_is_quoted_printable() raises:
    var line = String("")
    for _ in range(1000):
        line += "x"
    var b = _builder()
    b.set_text(line)
    var built = b.build()
    var text = _s(built)
    assert_true(text.find("Content-Transfer-Encoding: quoted-printable\r\n") > 0)
    var m = parse_message(Span(built))
    assert_equal(_s(m.decoded_body(0)), line + "\r\n")


def test_line_of_998_is_7bit() raises:
    # RFC 5322 section 2.1.1: 998 octets is the longest legal line.
    var line = String("")
    for _ in range(998):
        line += "x"
    # The line break after it ends the line and is not counted in it.
    var b = _builder()
    b.set_text(line + "\nnext")
    var built = b.build()
    var text = _s(built)
    assert_true(text.find("Content-Transfer-Encoding: 7bit\r\n") > 0, text)
    assert_equal(_body_of(built), line + "\r\nnext\r\n")


def test_line_of_998_after_a_line_is_7bit() raises:
    # The line break before a 998-octet line ends the line before it and is
    # not counted in the 998-octet line.
    var line = String("")
    for _ in range(998):
        line += "x"
    var b = _builder()
    b.set_text("a\n" + line)
    var built = b.build()
    var text = _s(built)
    assert_true(text.find("Content-Transfer-Encoding: 7bit\r\n") > 0, text)
    assert_equal(_body_of(built), "a\r\n" + line + "\r\n")


def test_boundary_held_by_a_part_is_changed() raises:
    var b = _builder()
    b.set_text("before\n--=_komira_0\nafter")
    b.set_html("<p>x</p>")
    var built = b.build()
    var text = _s(built)
    assert_true(text.find('boundary="=_komira_0_1"') > 0, text)
    var m = parse_message(Span(built))
    assert_equal(m.part_count(), 3)
    assert_equal(
        _s(m.decoded_body(m.text_part().value())),
        "before\r\n--=_komira_0\r\nafter",
    )


def test_long_non_ascii_file_name_is_split_into_sections() raises:
    var name = String("")
    for _ in range(12):
        name += "отчёт "
    name += "итог.pdf"
    var data = List[UInt8]()
    data.append(1)
    var b = _builder()
    b.set_text("see attached")
    b.add_attachment(name, "application/pdf", Span(data))
    var built = b.build()
    var text = _s(built)
    assert_true(text.find(" filename*0*=utf-8''%D0%BE") > 0, text)
    assert_true(text.find(" filename*1*=") > 0, text)
    assert_true(text.find(" name*0*=utf-8''") > 0, text)
    # Every section fits, so every line folds to 76.
    var start = 0
    for i in range(len(built)):
        if built[i] == 10:
            assert_true(i - 1 - start <= 76, String("line of ") + String(i - 1 - start))
            start = i + 1
    var m = parse_message(Span(built))
    var att = m.attachments()
    assert_equal(len(att), 1)
    assert_equal(m.part(att[0]).filename().value(), name)


def test_section_ends_on_a_character_boundary() raises:
    # `utf-8''` and 50 ASCII bytes fill 57 of a section's 60; an e-acute
    # (C3 A9) is 6 more, so it starts the next section rather than spill to 63.
    var name = String("")
    for _ in range(50):
        name += "a"
    name += String(chr(0xE9)) + ".txt"
    var data = List[UInt8]()
    var b = _builder()
    b.set_text("x")
    b.add_attachment(name, "text/plain", Span(data))
    var built = b.build()
    var start = 0
    for i in range(len(built)):
        if built[i] == 10:
            assert_true(i - 1 - start <= 76, String("line of ") + String(i - 1 - start))
            start = i + 1
    var text = _s(built)
    assert_true(text.find(" filename*1*=%C3%A9.txt") > 0, text)
    var m = parse_message(Span(built))
    assert_equal(m.part(m.attachments()[0]).filename().value(), name)


def test_ascii_file_names() raises:
    var data = List[UInt8]()
    var b = _builder()
    b.set_text("x")
    b.add_attachment('my "q" file.txt', "text/plain", Span(data))
    var built = b.build()
    var text = _s(built)
    assert_true(
        text.find('Content-Disposition: attachment; filename="my \\"q\\" file.txt"\r\n') > 0,
        text,
    )
    var m = parse_message(Span(built))
    assert_equal(m.part(m.attachments()[0]).filename().value(), 'my "q" file.txt')


def test_display_name_that_looks_encoded_is_encoded() raises:
    var b = _builder()
    b.add_to("=?x?q?y?=", AddrSpec("t", "example.com"))
    var text = _s(b.build())
    assert_true(text.find("To: =?UTF-8?B?PT94P3E/eT89?= <t@example.com>\r\n") > 0, text)


def test_file_name_that_looks_encoded_round_trips() raises:
    # Written as a quoted string, `=?UTF-8?Q?x?=` would be read back as the
    # encoded word for "x"; RFC 2231 form keeps it a file name.
    var data = List[UInt8]()
    data.append(120)
    var b = _builder()
    b.add_attachment("=?UTF-8?Q?x?=", "text/plain", Span(data))
    var built = b.build()
    var text = _s(built)
    assert_true(
        text.find(" filename*=utf-8''%3D%3FUTF-8%3FQ%3Fx%3F%3D\r\n") > 0, text
    )
    var m = parse_message(Span(built))
    assert_equal(m.part(m.attachments()[0]).filename().value(), "=?UTF-8?Q?x?=")


def test_forwarded_message_is_7bit() raises:
    # RFC 2046 section 5.2.1: message/rfc822 is 7bit, 8bit or binary, never
    # base64. Its line breaks are made CRLF.
    var inner = String("From: a@example.com\nSubject: hi\n\nbody\n")
    var b = _builder()
    b.set_text("see below")
    b.add_attachment("fwd.eml", "message/rfc822", inner.as_bytes())
    var built = b.build()
    var text = _s(built)
    assert_true(
        text.find(
            "Content-Disposition: attachment; filename=fwd.eml\r\n"
            + "Content-Transfer-Encoding: 7bit\r\n\r\nFrom: a@example.com\r\n"
        )
        > 0,
        text,
    )
    var m = parse_message(Span(built))
    var k = m.attachments()[0]
    assert_equal(m.part(k).media_type(), "message/rfc822")
    assert_equal(m.part(k).transfer_encoding(), "7bit")
    assert_equal(
        _s(m.decoded_body(k)), "From: a@example.com\r\nSubject: hi\r\n\r\nbody\r\n"
    )


def test_other_message_subtype_is_7bit() raises:
    # RFC 2046 section 5.2.2: message/partial is 7bit; every message/*
    # subtype is written 7bit, not base64. The media type is lower-cased.
    var b = _builder()
    b.set_text("see below")
    b.add_attachment("", "Message/Partial", "id=x\n".as_bytes())
    var built = b.build()
    var text = _s(built)
    assert_true(
        text.find(
            "Content-Type: message/partial\r\n"
            + "Content-Disposition: attachment\r\n"
            + "Content-Transfer-Encoding: 7bit\r\n\r\nid=x\r\n"
        )
        > 0,
        text,
    )
    var m = parse_message(Span(built))
    var k = m.attachments()[0]
    assert_equal(m.part(k).transfer_encoding(), "7bit")
    assert_equal(_s(m.decoded_body(k)), "id=x\r\n")


def test_empty_field_name_is_refused() raises:
    var b = _builder()
    var msg = String("")
    try:
        b.add_header("", "v")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidHeader: MessageBuilder.add_header: an empty field name",
    )


def main() raises:
    test_reply_fields()
    test_html_only_and_line_breaks()
    test_line_over_998_is_quoted_printable()
    test_line_of_998_is_7bit()
    test_line_of_998_after_a_line_is_7bit()
    test_boundary_held_by_a_part_is_changed()
    test_long_non_ascii_file_name_is_split_into_sections()
    test_section_ends_on_a_character_boundary()
    test_ascii_file_names()
    test_display_name_that_looks_encoded_is_encoded()
    test_empty_field_name_is_refused()
    test_file_name_that_looks_encoded_round_trips()
    test_forwarded_message_is_7bit()
    test_other_message_subtype_is_7bit()
    print("test_build_paths: OK")
