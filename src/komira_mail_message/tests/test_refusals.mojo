# What the builder refuses, each with its exact message: CR, LF or NUL in any
# value written into a header (header injection: a subject carrying
# "\r\nBcc: ..." must never become a second field), field names that are not
# ftext (a colon included: it would start a second field) or that the
# builder writes itself, each of them plus Bcc and Sender, media types that
# are not type/subtype tokens (a parameter or CRLF in one included), a
# multipart attachment, a message/* attachment that is not 7bit text,
# message ids that are not msg-id, and a message without From or Date.
# Errors hold no input byte. Every case starts from a fresh value, so a call
# that does not raise fails.

from std.testing import assert_equal, assert_false

from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder, error_kind


comptime FORBIDDEN = "komira_mail_message.ForbiddenByte: "


def _builder() raises -> MessageBuilder:
    var b = MessageBuilder()
    b.set_from("", AddrSpec("a", "acme.example"))
    b.set_date(1790000000)
    return b^


def _subject_error(s: String) raises -> String:
    var b = _builder()
    try:
        b.set_subject(s)
    except e:
        return String(e)
    return String("OK")


def test_crlf_in_subject_is_refused() raises:
    var expected = String(FORBIDDEN) + "MessageBuilder.set_subject: CR, LF or NUL"
    assert_equal(_subject_error("Hello\r\nBcc: victim@example.com"), expected)
    assert_equal(_subject_error("Hello\nBcc: victim@example.com"), expected)
    assert_equal(_subject_error("Hello\rX"), expected)
    assert_equal(_subject_error(String("a") + chr(0) + "b"), expected)
    assert_equal(_subject_error("Hello\tworld"), "OK")
    var msg = _subject_error("secret-token\r\n")
    assert_false("secret" in msg, msg)


comptime NOT_SET = "not raised"


def test_crlf_in_other_values_is_refused() raises:
    # Each case starts from NOT_SET, so a call that does not raise fails the
    # assertion instead of passing on the previous case's message.
    var b = _builder()
    var msg = String(NOT_SET)
    try:
        b.add_to("Jane\r\nBcc: x@example.com", AddrSpec("j", "example.com"))
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.add_to: CR, LF or NUL")
    msg = String(NOT_SET)
    try:
        b.add_cc("Jane\r\nBcc: x@example.com", AddrSpec("j", "example.com"))
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.add_cc: CR, LF or NUL")
    msg = String(NOT_SET)
    try:
        b.add_reply_to("Help\rBcc: x@example.com", AddrSpec("h", "example.com"))
    except e:
        msg = String(e)
    assert_equal(
        msg, String(FORBIDDEN) + "MessageBuilder.add_reply_to: CR, LF or NUL"
    )
    msg = String(NOT_SET)
    try:
        b.set_from("A\nB", AddrSpec("a", "example.com"))
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.set_from: CR, LF or NUL")
    msg = String(NOT_SET)
    try:
        b.add_header("X-Note", "a\r\nb")
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.add_header: CR, LF or NUL")
    var data = List[UInt8]()
    msg = String(NOT_SET)
    try:
        b.add_attachment("a\nb.txt", "text/plain", Span(data))
    except e:
        msg = String(e)
    assert_equal(
        msg, String(FORBIDDEN) + "MessageBuilder.add_attachment: CR, LF or NUL"
    )


def _header_error(name: String) raises -> String:
    var b = _builder()
    try:
        b.add_header(name, "x")
    except e:
        return String(e)
    return String("OK")


comptime OWNED_ERROR = "komira_mail_message.InvalidHeader: MessageBuilder.add_header: a field the builder writes itself"
comptime NAME_BYTE = "komira_mail_message.InvalidHeader: MessageBuilder.add_header: a byte not allowed in a field name at position "


def test_field_names() raises:
    # Every field `build()` writes, plus Bcc and Sender, in mixed case.
    var owned = List[String]()
    owned.append("Date")
    owned.append("FROM")
    owned.append("sender")
    owned.append("Reply-To")
    owned.append("to")
    owned.append("CC")
    owned.append("Bcc")
    owned.append("Message-Id")
    owned.append("in-reply-to")
    owned.append("References")
    owned.append("SUBJECT")
    owned.append("MIME-Version")
    owned.append("content-type")
    owned.append("Content-Transfer-Encoding")
    owned.append("Content-Disposition")
    for i in range(len(owned)):
        assert_equal(_header_error(owned[i]), OWNED_ERROR, owned[i])
    assert_equal(_header_error("X Bad"), String(NAME_BYTE) + "1")
    assert_equal(_header_error("X:Bad"), String(NAME_BYTE) + "1")
    # A colon in the name would write a second field: `Bcc:victim...: x`
    # parses as a Bcc field.
    assert_equal(_header_error("Bcc:victim@example.com"), String(NAME_BYTE) + "3")
    var b = _builder()
    try:
        b.add_header("X Bad", "x")
    except e:
        assert_equal(error_kind(e), "InvalidHeader")
    assert_equal(_header_error("X-Mailer"), "OK")
    assert_equal(_header_error("Sender-X"), "OK")


def _attachment_error(media_type: String, data: String = "") raises -> String:
    var b = _builder()
    try:
        b.add_attachment("f", media_type, data.as_bytes())
    except e:
        return String(e)
    return String("OK")


def _raw_attachment_error(media_type: String, data: List[UInt8]) raises -> String:
    var b = _builder()
    try:
        b.add_attachment("f", media_type, Span(data))
    except e:
        return String(e)
    return String("OK")


def _raw_line(byte: UInt8) -> List[UInt8]:
    """`Subject: a`, then `byte`, then CRLF CRLF, as raw bytes (not UTF-8)."""
    var out = List[UInt8]()
    for c in "Subject: a".as_bytes():
        out.append(c)
    out.append(byte)
    for c in "\r\n\r\n".as_bytes():
        out.append(c)
    return out^


def _raw_body(byte: UInt8) -> List[UInt8]:
    """`Subject: a`, CRLF CRLF, then `byte` and CRLF as the body, as raw
    bytes (not UTF-8)."""
    var out = List[UInt8]()
    for c in "Subject: a\r\n\r\n".as_bytes():
        out.append(c)
    out.append(byte)
    for c in "\r\n".as_bytes():
        out.append(c)
    return out^


def _long_body(last: List[UInt8]) -> List[UInt8]:
    """`Subject: a`, CRLF CRLF, then 80 body lines of 60 `x` (4960 octets
    with their CRLFs, past any 4 KiB prefix), then `last` and CRLF, as raw
    bytes (not UTF-8)."""
    var out = List[UInt8]()
    for c in "Subject: a\r\n\r\n".as_bytes():
        out.append(c)
    for _ in range(80):
        for _ in range(60):
            out.append(UInt8(ord("x")))
        for c in "\r\n".as_bytes():
            out.append(c)
    for c in last:
        out.append(c)
    for c in "\r\n".as_bytes():
        out.append(c)
    return out^


def _x_line(n: Int) -> List[UInt8]:
    """`n` octets of `x`."""
    var out = List[UInt8]()
    for _ in range(n):
        out.append(UInt8(ord("x")))
    return out^


comptime NOT_A_MEDIA_TYPE = "komira_mail_message.InvalidValue: MessageBuilder.add_attachment: a media type that is not type/subtype tokens"


def test_values() raises:
    assert_equal(_attachment_error("text"), NOT_A_MEDIA_TYPE)
    assert_equal(_attachment_error("text/"), NOT_A_MEDIA_TYPE)
    assert_equal(_attachment_error("/plain"), NOT_A_MEDIA_TYPE)
    # The media type goes into the part header: a parameter or a line break
    # in it is refused, not written.
    assert_equal(_attachment_error("text/plain; x=1"), NOT_A_MEDIA_TYPE)
    assert_equal(
        _attachment_error("text/plain\r\nBcc: x@example.com"), NOT_A_MEDIA_TYPE
    )
    assert_equal(_attachment_error("text/plain"), "OK")
    # RFC 2046 section 5.1: a multipart needs a boundary and 7bit, 8bit or
    # binary; the builder writes neither for an attachment.
    assert_equal(
        _attachment_error("Multipart/Mixed"),
        "komira_mail_message.InvalidValue: MessageBuilder.add_attachment: a multipart media type",
    )
    # RFC 2046 section 5.2: a message/* attachment is written 7bit, so its
    # text must be 7bit.
    var not_7bit = "komira_mail_message.InvalidValue: MessageBuilder.add_attachment: a message/* attachment that is not 7bit text"
    assert_equal(
        _attachment_error("message/rfc822", String("Subject: caf") + chr(0xE9) + "\r\n\r\n"),
        not_7bit,
    )
    assert_equal(
        _attachment_error("message/rfc822", String("Subject: a") + chr(0) + "\r\n\r\n"),
        not_7bit,
    )
    var long_line = String("Subject: ")
    for _ in range(990):
        long_line += "x"
    assert_equal(_attachment_error("message/rfc822", long_line), not_7bit)
    # RFC 5322 section 2.1.1: a 998-octet line is legal; 999 (above) is not.
    # The CRLF after it ends the line and is not counted in it.
    var line_998 = String("Subject: ")
    for _ in range(989):
        line_998 += "x"
    assert_equal(
        _attachment_error("message/rfc822", line_998 + "\r\n\r\nbody\r\n"), "OK"
    )
    assert_equal(_attachment_error("message/rfc822", line_998 + "\n\nbody\n"), "OK")
    # A 998-octet line after another line: the LF of the CRLF before it is
    # not counted into it either.
    assert_equal(
        _attachment_error(
            "message/rfc822",
            String("To: a@example.com\r\n") + line_998 + "\r\n\r\nbody\r\n",
        ),
        "OK",
    )
    assert_equal(
        _attachment_error(
            "message/rfc822", String("To: a@example.com\n") + line_998 + "\n\nb\n"
        ),
        "OK",
    )
    # RFC 2045 section 2.7: 7bit is octets 1 to 127. Raw bytes, not UTF-8,
    # reach the edge itself: 0x80 (a windows-1252 euro sign) is refused,
    # 0x7F (DEL) is 7bit.
    assert_equal(
        _raw_attachment_error("message/rfc822", _raw_line(0x80)), not_7bit
    )
    assert_equal(_raw_attachment_error("message/rfc822", _raw_line(0x7F)), "OK")
    assert_equal(_raw_attachment_error("message/rfc822", _raw_line(0x01)), "OK")
    # The rule covers the whole attachment, not just its header section: a
    # violation after the blank line is refused too.
    assert_equal(
        _attachment_error(
            "message/rfc822", String("Subject: a\r\n\r\ncaf") + chr(0xE9) + "\r\n"
        ),
        not_7bit,
    )
    assert_equal(
        _raw_attachment_error("message/rfc822", _raw_body(0x80)), not_7bit
    )
    assert_equal(_raw_attachment_error("message/rfc822", _raw_body(0x7F)), "OK")
    var body_998 = String("Subject: a\r\n\r\n")
    for _ in range(998):
        body_998 += "x"
    assert_equal(_attachment_error("message/rfc822", body_998 + "\r\n"), "OK")
    assert_equal(
        _attachment_error("message/rfc822", body_998 + "x\r\n"), not_7bit
    )
    # A forwarded message is usually longer than 4 KiB and has many body
    # lines: a violation on the last line, past the first body line and past
    # the first 4096 octets, is refused too.
    var cafe = List[UInt8]()
    for c in "caf".as_bytes():
        cafe.append(c)
    cafe.append(0xC3)
    cafe.append(0xA9)
    assert_equal(
        _raw_attachment_error("message/rfc822", _long_body(cafe)), not_7bit
    )
    assert_equal(
        _raw_attachment_error("message/rfc822", _long_body([UInt8(0x80)])),
        not_7bit,
    )
    assert_equal(
        _raw_attachment_error("message/rfc822", _long_body([UInt8(0x7F)])),
        "OK",
    )
    assert_equal(
        _raw_attachment_error("message/rfc822", _long_body(_x_line(999))),
        not_7bit,
    )
    assert_equal(
        _raw_attachment_error("message/rfc822", _long_body(_x_line(998))),
        "OK",
    )
    # The 7bit rule is for every message/* subtype (RFC 2046 section 5.2.2
    # for message/partial), not just message/rfc822.
    assert_equal(
        _attachment_error("Message/Partial", String("caf") + chr(0xE9) + "\r\n"),
        not_7bit,
    )
    assert_equal(
        _attachment_error("message/delivery-status", long_line), not_7bit
    )
    # Media types are case-insensitive (RFC 2045 section 5.1): the 7bit check
    # holds for `Message/RFC822` too.
    assert_equal(
        _attachment_error("Message/RFC822", String("Subject: caf") + chr(0xE9) + "\r\n\r\n"),
        not_7bit,
    )
    assert_equal(_attachment_error("message/rfc822", "Subject: a\n\nb\n"), "OK")
    var b = _builder()
    var msg = String(NOT_SET)
    try:
        b.set_in_reply_to("abc@example.com")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: MessageBuilder.set_in_reply_to: not a message id",
    )
    msg = String(NOT_SET)
    try:
        b.add_reference("<a@b> <c@d>")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: MessageBuilder.add_reference: not a message id",
    )
    # No `@`, an empty left part, and two `@`.
    var not_ids = List[String]()
    not_ids.append("<abcd>")
    not_ids.append("<@b.c>")
    not_ids.append("<a@b@c>")
    for i in range(len(not_ids)):
        msg = String(NOT_SET)
        try:
            b.set_in_reply_to(not_ids[i])
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "komira_mail_message.InvalidValue: MessageBuilder.set_in_reply_to: not a message id",
        )
    b.set_in_reply_to("<a.1@example.com>")
    b.add_reference("<a.1@example.com>")


def test_required_fields() raises:
    var b = MessageBuilder()
    var msg = String(NOT_SET)
    try:
        _ = b.build()
    except e:
        msg = String(e)
    assert_equal(msg, "komira_mail_message.MissingField: MessageBuilder.build: no From")
    b.set_from("", AddrSpec("a", "acme.example"))
    msg = String(NOT_SET)
    try:
        _ = b.build()
    except e:
        msg = String(e)
    assert_equal(msg, "komira_mail_message.MissingField: MessageBuilder.build: no Date")
    b.set_date(1790000000)
    _ = b.build()


def main() raises:
    test_crlf_in_subject_is_refused()
    test_crlf_in_other_values_is_refused()
    test_field_names()
    test_values()
    test_required_fields()
    print("test_refusals: OK")
