# The builder's exact bytes for the three message shapes it writes, written
# by hand from the RFCs (not captured from the code): a text message, a
# `multipart/alternative` text and HTML message with RFC 2047 encoded words
# in a display name and the subject, and a `multipart/mixed` message with
# base64 attachments, one named in RFC 2231 form. Each is then parsed back.
# Base64 values were checked with coreutils `base64`.

from std.testing import assert_equal, assert_true

from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder, parse_message


def _s(b: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span(b)))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_text_message() raises:
    var b = MessageBuilder()
    b.set_from("Acme Support", AddrSpec("support", "acme.example"))
    b.add_to("", AddrSpec("jane", "example.com"))
    b.set_subject("Your sign-in code")
    b.set_date(1790000000)
    b.set_message_id("a1b2c3d4.0", "acme.example")
    b.set_text("Your code is 123456.\nIt expires in 10 minutes.\n")
    var expected = (
        String("Date: Mon, 21 Sep 2026 14:13:20 +0000\r\n")
        + "From: Acme Support <support@acme.example>\r\n"
        + "To: jane@example.com\r\n"
        + "Message-ID: <a1b2c3d4.0@acme.example>\r\n"
        + "Subject: Your sign-in code\r\n"
        + "MIME-Version: 1.0\r\n"
        + "Content-Type: text/plain; charset=utf-8\r\n"
        + "Content-Transfer-Encoding: 7bit\r\n"
        + "\r\n"
        + "Your code is 123456.\r\n"
        + "It expires in 10 minutes.\r\n"
    )
    var built = b.build()
    assert_equal(_s(built), expected)
    var m = parse_message(Span(built))
    assert_equal(m.part_count(), 1)
    assert_equal(m.subject().value(), "Your sign-in code")
    assert_equal(m.text_part().value(), 0)
    assert_equal(
        _s(m.decoded_body(0)), "Your code is 123456.\r\nIt expires in 10 minutes.\r\n"
    )


def test_alternative_message() raises:
    var b = MessageBuilder()
    b.set_from("Équipe Acme", AddrSpec("team", "acme.example"))
    b.add_to("Jane Doe", AddrSpec("jane", "example.com"))
    b.add_cc("Doe, John", AddrSpec("john", "example.com"))
    b.set_subject("Café ☕ ready")
    b.set_date(1800000000, 60)
    b.set_message_id("m.42", "acme.example")
    b.set_text("Bonjour café\n")
    b.set_html("<p>Bonjour caf&eacute;</p>\n")
    var expected = (
        String("Date: Fri, 15 Jan 2027 09:00:00 +0100\r\n")
        + "From: =?UTF-8?Q?=C3=89quipe_Acme?= <team@acme.example>\r\n"
        + "To: Jane Doe <jane@example.com>\r\n"
        + 'Cc: "Doe, John" <john@example.com>\r\n'
        + "Message-ID: <m.42@acme.example>\r\n"
        + "Subject: =?UTF-8?B?Q2Fmw6kg4piVIHJlYWR5?=\r\n"
        + "MIME-Version: 1.0\r\n"
        + 'Content-Type: multipart/alternative; boundary="=_komira_0"\r\n'
        + "\r\n"
        + "--=_komira_0\r\n"
        + "Content-Type: text/plain; charset=utf-8\r\n"
        + "Content-Transfer-Encoding: quoted-printable\r\n"
        + "\r\n"
        + "Bonjour caf=C3=A9\r\n"
        + "\r\n"
        + "--=_komira_0\r\n"
        + "Content-Type: text/html; charset=utf-8\r\n"
        + "Content-Transfer-Encoding: 7bit\r\n"
        + "\r\n"
        + "<p>Bonjour caf&eacute;</p>\r\n"
        + "\r\n"
        + "--=_komira_0--\r\n"
    )
    var built = b.build()
    assert_equal(_s(built), expected)
    var m = parse_message(Span(built))
    assert_equal(m.part_count(), 3)
    assert_equal(m.subject().value(), "Café ☕ ready")
    assert_equal(_s(m.decoded_body(m.text_part().value())), "Bonjour café\r\n")
    assert_equal(
        _s(m.decoded_body(m.html_part().value())), "<p>Bonjour caf&eacute;</p>\r\n"
    )
    assert_equal(len(m.attachments()), 0)


def test_mixed_message() raises:
    var b = MessageBuilder()
    b.set_from("", AddrSpec("reports", "acme.example"))
    b.add_to("", AddrSpec("ops", "example.com"))
    b.set_subject("Weekly report")
    b.set_date(1790000000)
    b.set_text("See attached.")
    var csv = _bytes("a,b\n1,2\n")
    b.add_attachment("report.csv", "text/csv", Span(csv))
    var pdf = _bytes("%PDF-1.4\n")
    b.add_attachment("résumé.pdf", "Application/PDF", Span(pdf))
    var expected = (
        String("Date: Mon, 21 Sep 2026 14:13:20 +0000\r\n")
        + "From: reports@acme.example\r\n"
        + "To: ops@example.com\r\n"
        + "Subject: Weekly report\r\n"
        + "MIME-Version: 1.0\r\n"
        + 'Content-Type: multipart/mixed; boundary="=_komira_0"\r\n'
        + "\r\n"
        + "--=_komira_0\r\n"
        + "Content-Type: text/plain; charset=utf-8\r\n"
        + "Content-Transfer-Encoding: 7bit\r\n"
        + "\r\n"
        + "See attached.\r\n"
        + "--=_komira_0\r\n"
        + "Content-Type: text/csv; name=report.csv\r\n"
        + "Content-Disposition: attachment; filename=report.csv\r\n"
        + "Content-Transfer-Encoding: base64\r\n"
        + "\r\n"
        + "YSxiCjEsMgo=\r\n"
        + "--=_komira_0\r\n"
        + "Content-Type: application/pdf; name*=utf-8''r%C3%A9sum%C3%A9.pdf\r\n"
        + "Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf\r\n"
        + "Content-Transfer-Encoding: base64\r\n"
        + "\r\n"
        + "JVBERi0xLjQK\r\n"
        + "--=_komira_0--\r\n"
    )
    var built = b.build()
    assert_equal(_s(built), expected)
    var m = parse_message(Span(built))
    assert_equal(m.part_count(), 4)
    assert_equal(_s(m.decoded_body(m.text_part().value())), "See attached.")
    var att = m.attachments()
    assert_equal(len(att), 2)
    assert_equal(m.part(att[0]).filename().value(), "report.csv")
    assert_equal(m.part(att[0]).media_type(), "text/csv")
    assert_equal(_s(m.decoded_body(att[0])), "a,b\n1,2\n")
    assert_equal(m.part(att[1]).filename().value(), "résumé.pdf")
    assert_equal(m.part(att[1]).media_type(), "application/pdf")
    assert_equal(_s(m.decoded_body(att[1])), "%PDF-1.4\n")


def test_alternative_inside_mixed_round_trip() raises:
    # Text, HTML and an attachment: mixed(alternative(text, html), file). The
    # inner boundary differs from the outer one.
    var b = MessageBuilder()
    b.set_from("", AddrSpec("a", "acme.example"))
    b.set_date(1790000000)
    b.set_text("plain")
    b.set_html("<b>html</b>")
    var data = List[UInt8]()
    for i in range(256):
        data.append(UInt8(i))
    b.add_attachment("", "application/octet-stream", Span(data))
    var built = b.build()
    var text = _s(built)
    assert_true(text.find('boundary="=_komira_0"') > 0)
    assert_true(text.find('boundary="=_komira_1"') > 0)
    var m = parse_message(Span(built))
    assert_equal(m.part_count(), 5)
    assert_equal(m.part(1).media_type(), "multipart/alternative")
    assert_equal(m.part(1).parent(), 0)
    assert_equal(m.part(2).parent(), 1)
    assert_equal(_s(m.decoded_body(m.text_part().value())), "plain")
    assert_equal(_s(m.decoded_body(m.html_part().value())), "<b>html</b>")
    var att = m.attachments()
    assert_equal(len(att), 1)
    assert_true(not m.part(att[0]).filename())
    var got = m.decoded_body(att[0])
    assert_equal(len(got), 256)
    for i in range(256):
        assert_equal(Int(got[i]), i)
    # Every line is CRLF-terminated and at most 76 characters.
    var line = 0
    for i in range(len(built)):
        if built[i] == 10:
            assert_true(i > 0 and built[i - 1] == 13)
            line = 0
        elif built[i] != 13:
            line += 1
            assert_true(line <= 76)


def main() raises:
    test_text_message()
    test_alternative_message()
    test_mixed_message()
    test_alternative_inside_mixed_round_trip()
    print("test_build_golden: OK")
