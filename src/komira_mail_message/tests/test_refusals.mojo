# What the builder refuses, each with its exact message: CR, LF or NUL in any
# value written into a header (header injection: a subject carrying
# "\r\nBcc: ..." must never become a second field), field names that are not
# ftext or that the builder writes itself (Bcc, Content-Type, ...), media
# types that are not type/subtype, message ids that are not msg-id, and a
# message without From or Date. Errors hold no input byte.

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


def test_crlf_in_other_values_is_refused() raises:
    var b = _builder()
    var msg = String("")
    try:
        b.add_to("Jane\r\nBcc: x@example.com", AddrSpec("j", "example.com"))
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.add_to: CR, LF or NUL")
    try:
        b.set_from("A\nB", AddrSpec("a", "example.com"))
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.set_from: CR, LF or NUL")
    try:
        b.add_header("X-Note", "a\r\nb")
    except e:
        msg = String(e)
    assert_equal(msg, String(FORBIDDEN) + "MessageBuilder.add_header: CR, LF or NUL")
    var data = List[UInt8]()
    try:
        b.add_attachment("a\nb.txt", "text/plain", Span(data))
    except e:
        msg = String(e)
    assert_equal(
        msg, String(FORBIDDEN) + "MessageBuilder.add_attachment: CR, LF or NUL"
    )


def test_field_names() raises:
    var b = _builder()
    var owned = List[String]()
    owned.append("Bcc")
    owned.append("content-type")
    owned.append("SUBJECT")
    owned.append("MIME-Version")
    owned.append("From")
    for i in range(len(owned)):
        var msg = String("")
        try:
            b.add_header(owned[i], "x")
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "komira_mail_message.InvalidHeader: MessageBuilder.add_header: a field the builder writes itself",
        )
    var msg = String("")
    try:
        b.add_header("X Bad", "x")
    except e:
        msg = String(e)
        assert_equal(error_kind(e), "InvalidHeader")
    assert_equal(
        msg,
        "komira_mail_message.InvalidHeader: MessageBuilder.add_header: a byte not allowed in a field name at position 1",
    )
    try:
        b.add_header("X:Bad", "x")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidHeader: MessageBuilder.add_header: a byte not allowed in a field name at position 1",
    )
    b.add_header("X-Mailer", "ok")


def test_values() raises:
    var b = _builder()
    var data = List[UInt8]()
    var msg = String("")
    try:
        b.add_attachment("f", "text", Span(data))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: MessageBuilder.add_attachment: a media type that is not type/subtype tokens",
    )
    try:
        b.add_attachment("f", "text/plain; x=1", Span(data))
    except e:
        msg = String(e)
    assert_equal(error_kind(Error(msg)), "InvalidValue")
    try:
        b.set_in_reply_to("abc@example.com")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: MessageBuilder.set_in_reply_to: not a message id",
    )
    try:
        b.add_reference("<a@b> <c@d>")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.InvalidValue: MessageBuilder.add_reference: not a message id",
    )
    b.set_in_reply_to("<a.1@example.com>")
    b.add_reference("<a.1@example.com>")


def test_required_fields() raises:
    var b = MessageBuilder()
    var msg = String("")
    try:
        _ = b.build()
    except e:
        msg = String(e)
    assert_equal(msg, "komira_mail_message.MissingField: MessageBuilder.build: no From")
    b.set_from("", AddrSpec("a", "acme.example"))
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
