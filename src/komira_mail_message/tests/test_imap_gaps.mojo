# What an IMAP server reads from a parsed message: its bytes lent as views
# (`raw`, `header_bytes`, `body_bytes`), a part's octet and line counts,
# RFC 3501 section paths, and a nested message/rfc822 opened under the
# parent's limits. Every fixture is read twice, as CRLF and as bare-LF mail,
# for the counts and the header bytes. The existing reading of the same
# messages is pinned at the end.

from std.testing import assert_equal, assert_true

from komira_buffer.byte_view import ByteView
from komira_mail_message import MAX_DEPTH, error_kind, parse_message, Message


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _without_cr(s: String) -> List[UInt8]:
    """`s` as bytes with every CR dropped: the same mail with bare LF."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] != 13:
            out.append(b[i])
    return out^


def _parse(s: String) raises -> Message:
    var data = _b(s)
    return parse_message(Span(data))


def _parse_lf(s: String) raises -> Message:
    var data = _without_cr(s)
    return parse_message(Span(data))


def _text(v: ByteView[_]) raises -> String:
    var out = List[UInt8]()
    for i in range(v.len()):
        out.append(v.read_u8_at(i))
    return String(StringSlice(from_utf8=Span(out)))


# Parts: 0 the message, 1 text/plain, 2 multipart/alternative, 3 text/plain,
# 4 text/html, 5 message/rfc822 (a leaf), 6 a part with no empty line.
comptime MAIL = (
    "From: a@example.com\r\n"
    "Subject: Hi\r\n"
    "Content-Type: multipart/mixed; boundary=outer\r\n"
    "\r\n"
    "--outer\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "line1\r\n"
    "line2\r\n"
    "--outer\r\n"
    "Content-Type: multipart/alternative; boundary=inner\r\n"
    "\r\n"
    "--inner\r\n"
    "Content-Type: text/plain\r\n"
    "\r\n"
    "alt-plain\r\n"
    "--inner\r\n"
    "Content-Type: text/html\r\n"
    "\r\n"
    "<b>alt</b>\r\n"
    "--inner--\r\n"
    "--outer\r\n"
    "Content-Type: message/rfc822\r\n"
    "\r\n"
    "Subject: inner\r\n"
    "\r\n"
    "nested body\r\n"
    "--outer\r\n"
    "Content-Type: text/plain\r\n"
    "--outer--\r\n"
)


def test_raw_is_the_input() raises:
    var m = _parse(MAIL)
    assert_equal(_text(m.raw()), String(MAIL))
    assert_equal(m.raw().len(), String(MAIL).byte_length())
    var lf = _parse_lf(MAIL)
    assert_equal(lf.raw().len(), String(MAIL).byte_length() - 30)  # one CR per line
    assert_true("\r" not in _text(lf.raw()))


def test_header_bytes_crlf_and_lf() raises:
    var m = _parse(MAIL)
    assert_equal(
        _text(m.header_bytes(0)),
        "From: a@example.com\r\nSubject: Hi\r\nContent-Type: multipart/mixed; boundary=outer\r\n\r\n",
    )
    assert_equal(_text(m.header_bytes(1)), "Content-Type: text/plain\r\n\r\n")
    assert_equal(_text(m.header_bytes(4)), "Content-Type: text/html\r\n\r\n")
    assert_equal(_text(m.header_bytes(5)), "Content-Type: message/rfc822\r\n\r\n")
    # No empty line: the block ends at the part's last octet.
    assert_equal(_text(m.header_bytes(6)), "Content-Type: text/plain")
    # The same through the part, over the message's bytes.
    assert_equal(_text(m.part(3).header_bytes(m.raw())), "Content-Type: text/plain\r\n\r\n")

    var lf = _parse_lf(MAIL)
    assert_equal(
        _text(lf.header_bytes(0)),
        "From: a@example.com\nSubject: Hi\nContent-Type: multipart/mixed; boundary=outer\n\n",
    )
    assert_equal(_text(lf.header_bytes(1)), "Content-Type: text/plain\n\n")
    assert_equal(_text(lf.header_bytes(6)), "Content-Type: text/plain")


def test_header_bytes_keep_folding_as_written() raises:
    var m = _parse("Subject: one\r\n two\r\nX: y\r\n\r\nbody\r\n")
    assert_equal(_text(m.header_bytes(0)), "Subject: one\r\n two\r\nX: y\r\n\r\n")
    assert_equal(_text(m.body_bytes(0)), "body\r\n")


def test_body_bytes_octets_and_lines_crlf() raises:
    var m = _parse(MAIL)
    # The line break before a delimiter belongs to the delimiter.
    assert_equal(_text(m.body_bytes(1)), "line1\r\nline2")
    assert_equal(m.part(1).body_octets(), 12)
    assert_equal(m.part(1).body_lines(), 2)
    assert_equal(_text(m.body_bytes(3)), "alt-plain")
    assert_equal(m.part(3).body_octets(), 9)
    assert_equal(m.part(3).body_lines(), 1)
    assert_equal(m.part(4).body_octets(), 10)
    assert_equal(m.part(4).body_lines(), 1)
    assert_equal(_text(m.body_bytes(5)), "Subject: inner\r\n\r\nnested body")
    assert_equal(m.part(5).body_lines(), 3)
    # No body at all.
    assert_equal(m.part(6).body_octets(), 0)
    assert_equal(m.part(6).body_lines(), 0)
    assert_equal(m.body_bytes(6).len(), 0)
    # Bytes borrowed are the bytes copied.
    assert_equal(_text(m.body_bytes(1)), String(StringSlice(from_utf8=Span(m.raw_body(1)))))


def test_body_octets_and_lines_bare_lf() raises:
    var m = _parse_lf(MAIL)
    assert_equal(_text(m.body_bytes(1)), "line1\nline2")
    assert_equal(m.part(1).body_octets(), 11)
    assert_equal(m.part(1).body_lines(), 2)
    assert_equal(m.part(3).body_octets(), 9)
    assert_equal(m.part(3).body_lines(), 1)
    assert_equal(m.part(5).body_lines(), 3)
    assert_equal(m.part(6).body_lines(), 0)


def _counts(body: String, crlf: Bool) raises -> String:
    var head = String("Subject: x\r\n\r\n")
    var m = _parse(head + body) if crlf else _parse_lf(head + body)
    return String(m.part(0).body_octets()) + "/" + String(m.part(0).body_lines())


def test_line_counts_of_edge_bodies() raises:
    assert_equal(_counts("", True), "0/0")
    assert_equal(_counts("body\r\n", True), "6/1")
    assert_equal(_counts("body", True), "4/1")
    assert_equal(_counts("a\r\n\r\nb\r\n", True), "8/3")
    assert_equal(_counts("\r\n\r\n", True), "4/2")
    assert_equal(_counts("a\r\nb", True), "4/2")
    assert_equal(_counts("body\r\n", False), "5/1")
    assert_equal(_counts("body", False), "4/1")
    assert_equal(_counts("a\r\n\r\nb\r\n", False), "5/3")
    assert_equal(_counts("\r\n\r\n", False), "2/2")
    assert_equal(_counts("a\r\nb", False), "3/2")


def _sec(m: Message, path: String) -> Int:
    var r = m.part_by_section(path)
    if r:
        return r.value()
    return -1


def test_sections_of_a_multipart() raises:
    var m = _parse(MAIL)
    assert_equal(_sec(m, "1"), 1)
    assert_equal(_sec(m, "2"), 2)
    assert_equal(_sec(m, "2.1"), 3)
    assert_equal(_sec(m, "2.2"), 4)
    assert_equal(_sec(m, "3"), 5)
    assert_equal(_sec(m, "4"), 6)
    # Same answers on the bare-LF copy.
    var lf = _parse_lf(MAIL)
    assert_equal(_sec(lf, "2.2"), 4)
    assert_equal(_sec(lf, "4"), 6)


def test_sections_refused() raises:
    var m = _parse(MAIL)
    assert_equal(_sec(m, "0"), -1)
    assert_equal(_sec(m, "0.1"), -1)
    assert_equal(_sec(m, "2.0"), -1)
    assert_equal(_sec(m, "5"), -1)  # past the 4 children
    assert_equal(_sec(m, "2.3"), -1)  # past the 2 children
    assert_equal(_sec(m, "1.1"), -1)  # below a leaf
    assert_equal(_sec(m, "3.1"), -1)  # below a message/rfc822: open_rfc822 first
    assert_equal(_sec(m, "2.1.1"), -1)
    assert_equal(_sec(m, ""), -1)
    assert_equal(_sec(m, "."), -1)
    assert_equal(_sec(m, "1."), -1)
    assert_equal(_sec(m, ".1"), -1)
    assert_equal(_sec(m, "1..2"), -1)
    assert_equal(_sec(m, "01"), -1)
    assert_equal(_sec(m, "-1"), -1)
    assert_equal(_sec(m, "+1"), -1)
    assert_equal(_sec(m, " 1"), -1)
    assert_equal(_sec(m, "1 "), -1)
    assert_equal(_sec(m, "a"), -1)
    assert_equal(_sec(m, "1a"), -1)
    assert_equal(_sec(m, "999999999"), -1)
    assert_equal(_sec(m, "1000000000"), -1)
    assert_equal(_sec(m, "99999999999999999999"), -1)
    # A MIME, TEXT or HEADER suffix is for the IMAP layer to strip.
    assert_equal(_sec(m, "1.MIME"), -1)
    assert_equal(_sec(m, "2.2.MIME"), -1)
    assert_equal(_sec(m, "TEXT"), -1)
    assert_equal(_sec(m, "HEADER"), -1)
    assert_equal(_sec(m, "1.HEADER.FIELDS"), -1)


def test_sections_of_a_message_that_is_not_a_multipart() raises:
    var m = _parse("Subject: x\r\n\r\nbody\r\n")
    assert_equal(_sec(m, "1"), 0)
    assert_equal(_sec(m, "2"), -1)
    assert_equal(_sec(m, "0"), -1)
    assert_equal(_sec(m, "1.1"), -1)
    var one = _parse("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\nx\r\n--b--\r\n")
    assert_equal(_sec(one, "1"), 1)
    assert_equal(_sec(one, "2"), -1)
    assert_equal(_sec(one, "1.1"), -1)


def test_open_rfc822() raises:
    var m = _parse(MAIL)
    var inner = m.open_rfc822(5)
    assert_equal(inner.part_count(), 1)
    assert_equal(inner.subject().value(), "inner")
    assert_equal(String(StringSlice(from_utf8=Span(inner.raw_body(0)))), "nested body")
    assert_equal(_text(inner.raw()), "Subject: inner\r\n\r\nnested body")
    assert_equal(_sec(inner, "1"), 0)
    assert_equal(_text(inner.header_bytes(0)), "Subject: inner\r\n\r\n")
    # The parent is untouched.
    assert_equal(m.part_count(), 7)
    var lf = _parse_lf(MAIL)
    assert_equal(_text(lf.open_rfc822(5).raw()), "Subject: inner\n\nnested body")


def _open_error(m: Message, index: Int) -> String:
    try:
        _ = m.open_rfc822(index)
    except e:
        return String(e)
    return String("not raised")


def test_open_rfc822_of_the_wrong_part_is_refused() raises:
    var m = _parse(MAIL)
    var not_message = "komira_mail_message.InvalidValue: open_rfc822: a part that is not message/rfc822"
    var out_of_range = "komira_mail_message.InvalidValue: open_rfc822: a part index out of range"
    assert_equal(_open_error(m, 0), not_message)
    assert_equal(_open_error(m, 1), not_message)
    assert_equal(_open_error(m, 2), not_message)
    assert_equal(_open_error(m, 6), not_message)
    assert_equal(_open_error(m, -1), out_of_range)
    assert_equal(_open_error(m, 7), out_of_range)
    assert_equal(_open_error(m, 99), out_of_range)


def test_views_refuse_a_wrong_view_and_a_bad_index() raises:
    var m = _parse(MAIL)
    var short = _parse("Subject: s\r\n\r\nx")
    # A part of a long message given the bytes of a short one, or none.
    assert_equal(m.part(3).header_bytes(short.raw()).len(), 0)
    assert_equal(m.part(3).body_bytes(short.raw()).len(), 0)
    assert_equal(m.part(6).body_bytes(short.raw()).len(), 0)
    var empty = _parse("")
    assert_equal(m.part(1).header_bytes(empty.raw()).len(), 0)
    assert_equal(m.part(1).body_bytes(empty.raw()).len(), 0)
    # The right view still works.
    assert_equal(_text(m.part(1).body_bytes(m.raw())), "line1\r\nline2")
    # An index out of range gives an empty view.
    assert_equal(m.header_bytes(-1).len(), 0)
    assert_equal(m.header_bytes(7).len(), 0)
    assert_equal(m.body_bytes(-1).len(), 0)
    assert_equal(m.body_bytes(7).len(), 0)


def _encoded_message(cte: String) -> String:
    return String("Content-Type: message/rfc822\r\nContent-Transfer-Encoding: ") + cte + "\r\n\r\nSubject: x\r\n\r\nb\r\n"


def test_open_rfc822_refuses_an_encoded_body() raises:
    var refused = "komira_mail_message.InvalidValue: open_rfc822: a message/rfc822 with a transfer encoding"
    assert_equal(_open_error(_parse(_encoded_message("base64")), 0), refused)
    assert_equal(_open_error(_parse(_encoded_message("quoted-printable")), 0), refused)
    for ok in ["7bit", "8bit", "binary"]:
        assert_equal(_parse(_encoded_message(String(ok))).open_rfc822(0).subject().value(), "x")


def _chain(levels: Int) -> String:
    """A message/rfc822 holding a message/rfc822 ... `levels` of them, the
    innermost holding plain text."""
    var s = String("Content-Type: text/plain\r\n\r\nend\r\n")
    for _ in range(levels):
        s = String("Content-Type: message/rfc822\r\n\r\n") + s
    return s


def _opens_until_refused(var m: Message) raises -> Int:
    """How many times part 0 can be opened, each result opened in turn."""
    var opened = 0
    while True:
        try:
            m = m.open_rfc822(0)
        except e:
            assert_equal(error_kind(e), "Limit")
            return opened
        opened += 1
    return opened


def test_open_rfc822_shares_the_depth_limit() raises:
    # Each nested message costs one level of the parent's MAX_DEPTH (8): 8
    # opens succeed and the 9th raises Limit, however long the chain.
    assert_equal(_opens_until_refused(_parse(_chain(12))), MAX_DEPTH)
    # A chain exactly that long ends in text and opens without a refusal.
    var m = _parse(_chain(MAX_DEPTH))
    for _ in range(MAX_DEPTH):
        m = m.open_rfc822(0)
    assert_equal(m.part(0).media_type(), "text/plain")
    # A smaller limit given to parse_message is the one shared.
    var data = _b(_chain(5))
    assert_equal(_opens_until_refused(parse_message(Span(data), max_depth=2)), 2)
    var zero = parse_message(Span(data), max_depth=0)
    assert_equal(_opens_until_refused(zero^), 0)


def test_open_rfc822_inside_multiparts_counts_their_depth() raises:
    # The message/rfc822 leaf is at depth 1; read with max_depth=1, a message
    # opened from it would sit at depth 2.
    var s = String(
        "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n"
        "Content-Type: message/rfc822\r\n\r\nSubject: x\r\n\r\nhi\r\n--b--\r\n"
    )
    var data = _b(s)
    var tight = parse_message(Span(data), max_depth=1)
    assert_equal(tight.part(1).depth(), 1)
    try:
        _ = tight.open_rfc822(1)
        assert_true(False, "opened past the parent's depth limit")
    except e:
        assert_equal(
            String(e),
            "komira_mail_message.Limit: open_rfc822: parts nested deeper than the limit",
        )
    # With one more level the nested message opens, and a multipart inside it
    # is the level that is refused.
    var roomy = parse_message(Span(data), max_depth=2)
    assert_equal(roomy.open_rfc822(1).subject().value(), "x")
    var deep = _b(
        String(
            "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n"
            "Content-Type: message/rfc822\r\n\r\n"
            "Content-Type: multipart/mixed; boundary=c\r\n\r\n--c\r\n\r\nx\r\n--c--\r\n"
            "--b--\r\n"
        )
    )
    var m2 = parse_message(Span(deep), max_depth=2)
    try:
        _ = m2.open_rfc822(1)
        assert_true(False, "a multipart opened past the shared depth")
    except e:
        assert_equal(error_kind(e), "Limit")
    var m3 = parse_message(Span(deep), max_depth=3)
    assert_equal(m3.open_rfc822(1).part_count(), 2)


def test_open_rfc822_shares_the_part_limit() raises:
    # Three parts: the message, text and a message/rfc822.
    var s = String(
        "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\ntext\r\n--b\r\n"
        "Content-Type: message/rfc822\r\n\r\nSubject: x\r\n\r\nhi\r\n--b--\r\n"
    )
    var data = _b(s)
    var full = parse_message(Span(data), max_parts=3)
    assert_equal(full.part_count(), 3)
    try:
        _ = full.open_rfc822(2)
        assert_true(False, "opened with no part left")
    except e:
        assert_equal(
            String(e),
            "komira_mail_message.Limit: open_rfc822: more parts than the limit",
        )
    # One part left: a one-part message opens.
    var one_left = parse_message(Span(data), max_parts=4)
    assert_equal(one_left.open_rfc822(2).part_count(), 1)
    # A nested multipart of two parts does not fit in one.
    var nested = _b(
        String(
            "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n"
            "Content-Type: message/rfc822\r\n\r\n"
            "Content-Type: multipart/mixed; boundary=c\r\n\r\n--c\r\n\r\nx\r\n--c--\r\n"
            "--b--\r\n"
        )
    )
    var m = parse_message(Span(nested), max_parts=3)
    try:
        _ = m.open_rfc822(1)
        assert_true(False, "a nested multipart exceeded the shared part limit")
    except e:
        assert_equal(error_kind(e), "Limit")
    assert_equal(parse_message(Span(nested), max_parts=4).open_rfc822(1).part_count(), 2)


def test_existing_reading_is_unchanged() raises:
    var m = _parse(MAIL)
    assert_equal(m.part_count(), 7)
    assert_equal(m.part(0).media_type(), "multipart/mixed")
    assert_equal(m.part(2).media_type(), "multipart/alternative")
    assert_equal(m.part(5).media_type(), "message/rfc822")
    assert_equal(m.part(5).is_multipart(), False)
    assert_equal(len(m.part(5).children()), 0)
    assert_equal(len(m.part(0).children()), 4)
    assert_equal(m.part(3).depth(), 2)
    assert_equal(m.part(3).parent(), 2)
    assert_equal(m.subject().value(), "Hi")
    assert_equal(m.text_part().value(), 1)
    assert_equal(m.html_part().value(), 4)
    assert_equal(String(StringSlice(from_utf8=Span(m.raw_body(1)))), "line1\r\nline2")
    assert_equal(String(StringSlice(from_utf8=Span(m.decoded_body(3)))), "alt-plain")
    assert_equal(m.body_start(), 83)
    var lf = _parse_lf(MAIL)
    assert_equal(lf.part_count(), 7)
    assert_equal(lf.subject().value(), "Hi")
    assert_equal(String(StringSlice(from_utf8=Span(lf.raw_body(1)))), "line1\nline2")


def main() raises:
    test_raw_is_the_input()
    test_header_bytes_crlf_and_lf()
    test_header_bytes_keep_folding_as_written()
    test_body_bytes_octets_and_lines_crlf()
    test_body_octets_and_lines_bare_lf()
    test_line_counts_of_edge_bodies()
    test_sections_of_a_multipart()
    test_sections_refused()
    test_sections_of_a_message_that_is_not_a_multipart()
    test_open_rfc822()
    test_open_rfc822_of_the_wrong_part_is_refused()
    test_views_refuse_a_wrong_view_and_a_bad_index()
    test_open_rfc822_refuses_an_encoded_body()
    test_open_rfc822_shares_the_depth_limit()
    test_open_rfc822_inside_multiparts_counts_their_depth()
    test_open_rfc822_shares_the_part_limit()
    test_existing_reading_is_unchanged()
    print("test_imap_gaps: OK")
