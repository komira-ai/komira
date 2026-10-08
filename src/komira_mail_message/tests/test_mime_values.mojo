# MIME values: quoted-printable (RFC 2045 section 6.7, its own examples and
# the line rules), parameters (the RFC 2231 section 3 and 4 examples, the
# RFC 2045 section 5.1 equivalent forms, the RFC 2183 example), and the
# `Date` and `Message-ID` values (dates checked against GNU `date -R`). The
# host of the RFC 2231 section 3 URL is replaced by a reserved example name.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_message import (
    error_kind,
    format_date,
    format_message_id,
    parse_media_header,
    quoted_printable_decode,
    quoted_printable_encode,
)


def _s(b: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span(b)))


def _qp(text: String) raises -> String:
    return _s(quoted_printable_encode(text.as_bytes()))


def _unqp(text: String) raises -> String:
    return _s(quoted_printable_decode(text.as_bytes()))


def test_qp_encode_rules() raises:
    # Rule 3: a space or tab ending a line is encoded; elsewhere kept.
    assert_equal(_qp("a b \r\nc\t"), "a b=20\r\nc=09")
    # Rule 1: `=` and every byte outside printable ASCII.
    assert_equal(_qp("x=y café"), "x=3Dy caf=C3=A9")
    # A CR or LF outside a CRLF pair is not a line break.
    assert_equal(_qp("a\nb\rc"), "a=0Ab=0Dc")
    # Rule 5: at most 76 characters, a soft break `=` before overflow.
    var a76 = String("")
    for _ in range(76):
        a76 += "a"
    assert_equal(_qp(a76), a76)
    var a100 = String("")
    for _ in range(100):
        a100 += "a"
    var enc = _qp(a100)
    var first = String("")
    for _ in range(75):
        first += "a"
    var rest = String("")
    for _ in range(25):
        rest += "a"
    assert_equal(enc, first + "=\r\n" + rest)
    # An escape is never split by a soft break.
    var e40 = String("")
    for _ in range(40):
        e40 += "é"
    var encoded = _qp(e40)
    var lines = encoded.split("\r\n")
    for i in range(len(lines)):
        assert_true(lines[i].byte_length() <= 76)
        var l = String(lines[i])
        var body = String(l[byte = 0 : l.byte_length() - 1]) if l.endswith("=") else l
        assert_equal(body.byte_length() % 3, 0, l)
    assert_equal(_unqp(_qp(e40)), e40)


def test_qp_decode_rfc2045_examples() raises:
    # The rule 5 example: soft line breaks are removed.
    assert_equal(
        _unqp(
            "Now's the time =\r\nfor all folk to come=\r\n to the aid of their country."
        ),
        "Now's the time for all folk to come to the aid of their country.",
    )
    # Rule 3: white space at the end of an encoded line is dropped.
    assert_equal(_unqp("ab  \r\ncd\t\r\n"), "ab\r\ncd\r\n")
    # Lower-case hex is read; a malformed `=` is kept (note 2 of 6.7).
    assert_equal(_unqp("caf=c3=a9 = x =4"), "café = x =4")
    # LF-only line breaks are read and kept.
    assert_equal(_unqp("a=\nb\nc"), "ab\nc")


def test_rfc2231_examples() raises:
    var h = parse_media_header(
        String(
            'message/external-body; access-type=URL; URL*0="ftp://"; '
            + 'URL*1="ftp.example.org/pub/bulk-mailer/bulk-mailer.tar"'
        ).as_bytes()
    )
    assert_equal(h.value(), "message/external-body")
    assert_equal(h.param("access-type").value(), "URL")
    assert_equal(
        h.param("url").value(),
        "ftp://ftp.example.org/pub/bulk-mailer/bulk-mailer.tar",
    )
    h = parse_media_header(
        String(
            "application/x-stuff; title*=us-ascii'en-us'This%20is%20%2A%2A%2Afun%2A%2A%2A"
        ).as_bytes()
    )
    assert_equal(h.param("title").value(), "This is ***fun***")
    h = parse_media_header(
        String(
            "application/x-stuff; title*0*=us-ascii'en'This%20is%20even%20more%20; "
            + "title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2=\"isn't it!\""
        ).as_bytes()
    )
    assert_equal(h.param("title").value(), "This is even more ***fun*** isn't it!")
    # Sections out of order are joined in order; a gap ends the value.
    h = parse_media_header(
        String('a/b; t*1="two"; t*0="one"; t*3="four"').as_bytes()
    )
    assert_equal(h.param("t").value(), "onetwo")
    # UTF-8 and ISO-8859-1 are read; the RFC 2231 form wins over a plain one.
    h = parse_media_header(
        String(
            "attachment; filename=fallback.pdf; filename*=UTF-8''%E2%82%AC%20rates.pdf"
        ).as_bytes()
    )
    assert_equal(h.value(), "attachment")
    assert_equal(h.param("filename").value(), "€ rates.pdf")
    h = parse_media_header(String("a/b; n*=iso-8859-1''caf%E9").as_bytes())
    assert_equal(h.param("n").value(), "café")


def test_rfc2045_and_rfc2183_forms() raises:
    # RFC 2045 section 5.1: these are the same, a comment is skipped, the type
    # and the parameter names are case-insensitive.
    var a = parse_media_header(
        String("text/plain; charset=us-ascii (Plain text)").as_bytes()
    )
    var b = parse_media_header(String('TEXT/PLAIN; CHARSET="us-ascii"').as_bytes())
    assert_equal(a.value(), "text/plain")
    assert_equal(b.value(), "text/plain")
    assert_equal(a.param("charset").value(), "us-ascii")
    assert_equal(b.param("charset").value(), "us-ascii")
    # RFC 2183 section 2 example, unfolded.
    var d = parse_media_header(
        String(
            'attachment; filename=genome.jpeg;  modification-date="Wed, 12 Feb 1997 16:29:51 -0500";'
        ).as_bytes()
    )
    assert_equal(d.value(), "attachment")
    assert_equal(d.param("filename").value(), "genome.jpeg")
    assert_equal(
        d.param("modification-date").value(), "Wed, 12 Feb 1997 16:29:51 -0500"
    )
    # A quoted pair; a parameter that does not parse ends the list.
    var q = parse_media_header(String('a/b; x="q\\"t"; y; z=1').as_bytes())
    assert_equal(q.param("x").value(), 'q"t')
    assert_true(not q.param("z"))
    # Not a media type: empty value.
    assert_equal(parse_media_header(String("text/").as_bytes()).value(), "")


def test_format_date() raises:
    assert_equal(format_date(0), "Thu, 01 Jan 1970 00:00:00 +0000")
    assert_equal(format_date(951782400), "Tue, 29 Feb 2000 00:00:00 +0000")
    assert_equal(format_date(4107542399), "Sun, 28 Feb 2100 23:59:59 +0000")
    assert_equal(format_date(1790000000), "Mon, 21 Sep 2026 14:13:20 +0000")
    assert_equal(format_date(1790000000, -210), "Mon, 21 Sep 2026 10:43:20 -0330")
    assert_equal(format_date(1790000000, 330), "Mon, 21 Sep 2026 19:43:20 +0530")
    var msg = String("")
    try:
        _ = format_date(-1)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: format_date: a time before 1970 or after 9999",
    )
    try:
        _ = format_date(0, 1440)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: format_date: a zone offset outside -2359..+2359",
    )


def test_format_message_id() raises:
    assert_equal(format_message_id("a1b2.c3", "acme.example"), "<a1b2.c3@acme.example>")
    var msg = String("")
    try:
        _ = format_message_id("a b", "acme.example")
    except e:
        msg = String(e)
        assert_equal(error_kind(e), "InvalidValue")
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: format_message_id: a message id part that is not dot-atom-text",
    )


def main() raises:
    test_qp_encode_rules()
    test_qp_decode_rfc2045_examples()
    test_rfc2231_examples()
    test_rfc2045_and_rfc2183_forms()
    test_format_date()
    test_format_message_id()
    print("test_mime_values: OK")
