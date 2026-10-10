# MIME values: quoted-printable (RFC 2045 section 6.7, its own examples and
# the line rules), parameters (the RFC 2231 section 3 and 4 examples, the
# RFC 2045 section 5.1 equivalent forms, the RFC 2183 example), and the
# `Date` and `Message-ID` values (dates checked against GNU `date -R`). The
# host of the RFC 2231 section 3 URL is replaced by a reserved example name.
# At most MAX_PARAMS parameters are read from one field.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_message import (
    MAX_PARAMS,
    MediaHeader,
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


def _h(field: String) raises -> MediaHeader:
    return parse_media_header(field.as_bytes())


def test_parameter_grammar_edges() raises:
    # A quoted pair inside a comment: `\)` does not close it.
    assert_equal(_h("text/plain (a \\) b); charset=x").param("charset").value(), "x")
    # A quoted string without its closing quote ends the list (a=1 kept).
    var h = _h('text/plain; a=1; b="x')
    assert_equal(len(h.params()), 1)
    assert_equal(h.param("a").value(), "1")
    # An empty value and an empty name each end the list.
    assert_equal(len(_h("text/plain; a=; b=2").params()), 0)
    assert_equal(len(_h("text/plain; =x; a=b").params()), 0)


def test_rfc2231_suffixes_that_are_not_sections() raises:
    # `a**`, `a*01` (a leading zero), `a*-` (not a digit; `-` would read as
    # the plain marker -3 if the digit check were skipped) and `a*1001`
    # (over the 1000-section cap) are not RFC 2231 names: dropped.
    assert_true(not _h("text/plain; a**=utf-8''x").param("a"))
    assert_equal(_h("text/plain; a*0=x; a*01=y").param("a").value(), "x")
    assert_true(not _h("text/plain; a*-=v").param("a"))
    assert_true(not _h("text/plain; a*1001=y").param("a"))
    # `a*1000` is a section (the cap itself): it makes `a` an RFC 2231 name,
    # which wins over the plain `a=p` (no section 0, so the value is empty);
    # `a*1001` is not, so the plain value stays.
    assert_equal(_h("text/plain; a=p; a*1000=y").param("a").value(), "")
    assert_equal(_h("text/plain; a=p; a*1001=y").param("a").value(), "p")
    # An extended value without `charset'language'` does not read, and a
    # starred form that does not read is never taken as a plain value.
    assert_true(not _h("text/plain; a*=nolang").param("a"))
    assert_true(not _h("text/plain; a*0*=nolang").param("a"))
    assert_equal(_h("text/plain; a=p; a*=nolang").param("a").value(), "p")
    # An empty charset reads the bytes as they are: not ISO-8859-1.
    assert_equal(_h("text/plain; a*=''caf%E9").param("a").value(), "caf�")


def test_parameter_count_is_capped() raises:
    # Grouping RFC 2231 sections by name is quadratic in the parameter
    # count, so one field holds at most MAX_PARAMS; the rest are dropped.
    var field = String("a/b")
    for i in range(200):
        field += String("; p") + String(i) + "=" + String(i)
    var h = parse_media_header(field.as_bytes())
    assert_equal(MAX_PARAMS, 128)
    assert_equal(len(h.params()), 128)
    assert_equal(h.param("p127").value(), "127")
    assert_true(not h.param("p128"))
    # Whether a value came from an RFC 2231 form.
    var d = parse_media_header(
        String("attachment; filename*=utf-8''a%20b; name=c").as_bytes()
    )
    assert_equal(d.param("filename").value(), "a b")
    assert_true(d.param_is_extended("filename"))
    assert_false(d.param_is_extended("name"))
    assert_false(d.param_is_extended("absent"))


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


def test_date_and_message_id_edges() raises:
    # A zone offset that puts the local time before 1970 is refused; one
    # minute later it is written.
    var msg = String("not raised")
    try:
        _ = format_date(0, -1)
    except e:
        msg = String(e)
    assert_equal(
        msg, "komira_mail_message.InvalidValue: format_date: a local time before 1970"
    )
    assert_equal(format_date(60, -1), "Thu, 01 Jan 1970 00:00:00 -0001")
    # dot-atom-text: not empty, no leading, trailing or doubled dot.
    var bad = List[String]()
    bad.append("")
    bad.append(".a")
    bad.append("a.")
    bad.append("a..b")
    for i in range(len(bad)):
        msg = String("not raised")
        try:
            _ = format_message_id(bad[i], "acme.example")
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "komira_mail_message.InvalidValue: format_message_id: a message id part that is not dot-atom-text",
        )
    # At most 250 octets with `<`, `@` and `>`.
    var left = String("")
    for _ in range(200):
        left += "a"
    var right = String("")
    for _ in range(47):
        right += "b"
    assert_equal(format_message_id(left, right).byte_length(), 250)
    msg = String("not raised")
    try:
        _ = format_message_id(left, right + "b")
    except e:
        msg = String(e)
    assert_equal(
        msg, "komira_mail_message.InvalidValue: format_message_id: a message id over 250 octets"
    )


def test_error_kind_of_other_errors() raises:
    assert_equal(error_kind(Error("komira_mail_message.Syntax: f: d")), "Syntax")
    assert_equal(error_kind(Error("some_other_library.Kind: f: detail")), "")
    assert_equal(error_kind(Error("komira_mail_message.Syntax")), "")


def main() raises:
    test_qp_encode_rules()
    test_qp_decode_rfc2045_examples()
    test_rfc2231_examples()
    test_rfc2045_and_rfc2183_forms()
    test_parameter_grammar_edges()
    test_rfc2231_suffixes_that_are_not_sections()
    test_parameter_count_is_capped()
    test_format_date()
    test_format_message_id()
    test_date_and_message_id_edges()
    test_error_kind_of_other_errors()
    print("test_mime_values: OK")
