# The pure parts of the SMTP client: reply and capability parsing, the DATA
# bytes and the envelope checks. No stream is involved.
#
# What each case catches:
# - test_reply_lines: `NNN text`, `NNN-text` and bare `NNN` read; a short line,
#   a non-digit code, a code outside 200 to 599 and a code glued to its text
#   refused; control bytes and bytes above 0x7F in the text become `?` (a
#   parser that keeps them lets a server put escape sequences in an error).
# - test_enhanced_status_codes: `d.d.d` is split from the text only when its
#   class digit is the reply's class and a space or the end follows (a split on
#   `5.1.1` under a 250, or on `2.1.0000`, fails).
# - test_capabilities: keywords in any case; AUTH mechanisms upper-cased, also
#   the legacy `AUTH=` spelling; SIZE with and without a limit; absent is -1.
# - test_normalize_line_endings: bare LF, bare CR, CRLF and a missing final CRLF
#   (a normaliser that leaves a bare LF lets a server read a smuggled end of data).
# - test_dot_stuffing: a line that starts with `.` gets a second one; a dot in
#   the middle of a line does not; the terminator is `.` CRLF (a stuffer that
#   skips the first line, or stuffs mid-line, or ends without the dot fails).
# - test_envelope: a good envelope; the null sender; no recipients, an empty
#   message, an address with a space, angle brackets, a line break (a command
#   injection) or no `@`; a non-ASCII address needs SMTPUTF8; SIZE counts the
#   normalised message.
# - test_error_kinds: only timeouts and transport errors are retryable.

from std.testing import assert_equal, assert_false, assert_true

from komira_smtp_client.reply import (
    SmtpCapabilities,
    assemble_reply,
    parse_reply_line,
)
from komira_smtp_client.result import error_is_retryable
from komira_smtp_client.wire import (
    dot_stuff_and_terminate,
    has_eight_bit,
    normalize_line_endings,
    validate_envelope,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _s(b: List[UInt8]) -> String:
    # SAFETY: the test inputs are ASCII.
    return String(unsafe_from_utf8=Span(b))


def _refused_with(text: String, prefix: String) raises:
    var raised = False
    try:
        _ = parse_reply_line(Span(_b(text)))
    except e:
        raised = True
        assert_true(String(e).startswith(prefix), String(e))
    assert_true(raised, "no error for: " + text)


def test_reply_lines() raises:
    var a = parse_reply_line(Span(_b("250 ok")))
    assert_equal(a.code, 250)
    assert_true(a.is_last)
    assert_equal(a.text, "ok")
    var m = parse_reply_line(Span(_b("250-more")))
    assert_false(m.is_last)
    assert_equal(m.text, "more")
    var bare = parse_reply_line(Span(_b("354")))
    assert_true(bare.is_last)
    assert_equal(bare.text, "")
    _refused_with("25", "SmtpProtocol")
    _refused_with("abc ok", "SmtpProtocol")
    _refused_with("250ok", "SmtpProtocol")
    _refused_with("199 x", "SmtpProtocol")
    _refused_with("600 x", "SmtpProtocol")
    var bytes = _b("250 a")
    bytes.append(UInt8(0x1B))
    bytes.append(UInt8(0xC3))
    bytes.append(UInt8(0x28))
    bytes.append(UInt8(0x09))
    var c = parse_reply_line(Span(bytes))
    assert_equal(c.text, "a??(" + chr(9))


def test_enhanced_status_codes() raises:
    var t = List[String]()
    t.append(String("2.1.0 Sender OK"))
    t.append(String("2.1.0 second"))
    var r = assemble_reply(250, t)
    assert_equal(r.enhanced, "2.1.0")
    assert_equal(r.lines[0], "Sender OK")
    assert_equal(r.lines[1], "second")
    assert_equal(r.text(), "Sender OK\nsecond")
    var only = List[String]()
    only.append(String("2.0.0"))
    var r2 = assemble_reply(250, only)
    assert_equal(r2.enhanced, "2.0.0")
    assert_equal(r2.lines[0], "")
    var wrong_class = List[String]()
    wrong_class.append(String("5.1.1 not for a 250"))
    var r3 = assemble_reply(250, wrong_class)
    assert_equal(r3.enhanced, "")
    assert_equal(r3.lines[0], "5.1.1 not for a 250")
    var too_long = List[String]()
    too_long.append(String("2.1.0000 text"))
    assert_equal(assemble_reply(250, too_long).enhanced, "")
    var five = List[String]()
    five.append(String("5.7.8 Authentication credentials invalid"))
    var r5 = assemble_reply(535, five)
    assert_equal(r5.enhanced, "5.7.8")
    assert_true(r5.is_permanent())
    assert_false(r5.is_transient())
    var four = List[String]()
    four.append(String("4.2.2 mailbox full"))
    assert_true(assemble_reply(452, four).is_transient())


def _ehlo(lines: List[String]) -> SmtpCapabilities:
    return SmtpCapabilities.from_ehlo(assemble_reply(250, lines))


def test_capabilities() raises:
    var l = List[String]()
    l.append(String("mail.test greets you"))
    l.append(String("starttls"))
    l.append(String("Auth plain LOGIN"))
    l.append(String("size 35882577"))
    l.append(String("8BitMime"))
    l.append(String("smtputf8"))
    l.append(String("PipeLining"))
    l.append(String("EnhancedStatusCodes"))
    var caps = _ehlo(l)
    assert_true(caps.starttls)
    assert_true(caps.offers_auth("PLAIN"))
    assert_true(caps.offers_auth("LOGIN"))
    assert_false(caps.offers_auth("XOAUTH2"))
    assert_equal(caps.size_limit, 35882577)
    assert_true(caps.eight_bit_mime)
    assert_true(caps.smtputf8)
    assert_true(caps.pipelining)
    assert_true(caps.enhanced_status_codes)

    var none = List[String]()
    none.append(String("mail.test"))
    var bare = _ehlo(none)
    assert_false(bare.starttls)
    assert_equal(len(bare.auth_mechanisms), 0)
    assert_equal(bare.size_limit, -1)
    assert_false(bare.eight_bit_mime)

    var legacy = List[String]()
    legacy.append(String("mail.test"))
    legacy.append(String("AUTH=PLAIN LOGIN"))
    legacy.append(String("SIZE"))
    var lc = _ehlo(legacy)
    assert_true(lc.offers_auth("PLAIN"))
    assert_true(lc.offers_auth("LOGIN"))
    assert_equal(lc.size_limit, 0)

    # The greeting line is not a keyword: a server named STARTTLS is not
    # offering it.
    var named = List[String]()
    named.append(String("STARTTLS"))
    assert_false(_ehlo(named).starttls)


def test_normalize_line_endings() raises:
    assert_equal(_s(normalize_line_endings(Span(_b("a\nb")))), "a\r\nb\r\n")
    assert_equal(_s(normalize_line_endings(Span(_b("a\r\nb\r\n")))), "a\r\nb\r\n")
    assert_equal(_s(normalize_line_endings(Span(_b("a\rb")))), "a\r\nb\r\n")
    assert_equal(_s(normalize_line_endings(Span(_b("a\r")))), "a\r\n")
    assert_equal(_s(normalize_line_endings(Span(_b("\n\n")))), "\r\n\r\n")
    assert_equal(_s(normalize_line_endings(Span(_b("a\n\rb")))), "a\r\n\r\nb\r\n")
    assert_equal(len(normalize_line_endings(Span(_b("")))), 0)


def test_dot_stuffing() raises:
    assert_equal(
        _s(dot_stuff_and_terminate(Span(_b(".hello\r\n")))), "..hello\r\n.\r\n"
    )
    assert_equal(
        _s(dot_stuff_and_terminate(Span(_b("a\r\n.\r\n.b\r\n")))),
        "a\r\n..\r\n..b\r\n.\r\n",
    )
    assert_equal(
        _s(dot_stuff_and_terminate(Span(_b("a.b\r\n")))), "a.b\r\n.\r\n"
    )
    assert_equal(
        _s(dot_stuff_and_terminate(Span(_b("a\r\n..\r\n")))), "a\r\n...\r\n.\r\n"
    )
    assert_equal(_s(dot_stuff_and_terminate(Span(_b("")))), ".\r\n")
    var bytes = _b("caf")
    bytes.append(UInt8(0xC3))
    assert_true(has_eight_bit(Span(bytes)))
    assert_false(has_eight_bit(Span(_b("plain"))))


def _recipients(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _envelope_error(
    mail_from: String, rcpts: List[String], message: String
) raises:
    var raised = False
    try:
        _ = validate_envelope(mail_from, rcpts, Span(_b(message)))
    except e:
        raised = True
        assert_true(String(e).startswith("SmtpEnvelope"), String(e))
    assert_true(raised, "an invalid envelope was accepted: " + mail_from)


def test_envelope() raises:
    var env = validate_envelope(
        String("a@sender.test"), _recipients("bob@example.com"), Span(_b("a\nb"))
    )
    assert_equal(env.mail_from, "a@sender.test")
    assert_false(env.needs_smtputf8)
    assert_false(env.eight_bit)
    assert_equal(env.size, 6)
    var bounce = validate_envelope(
        String(""), _recipients("bob@example.com"), Span(_b("x"))
    )
    assert_equal(bounce.mail_from, "")

    var raised = False
    try:
        _ = validate_envelope(String("a@b.test"), List[String](), Span(_b("x")))
    except e:
        raised = True
        assert_true(String(e).startswith("SmtpEnvelope"), String(e))
    assert_true(raised)

    _envelope_error(String("a@b.test"), _recipients("c@d.test"), String(""))
    _envelope_error(String("a@b.test"), _recipients("no-at-sign"), String("x"))
    _envelope_error(String("a@b.test"), _recipients("c@d e.test"), String("x"))
    _envelope_error(String("a@b.test"), _recipients("<c@d.test>"), String("x"))
    _envelope_error(
        String("a@b.test"),
        _recipients(String("c@d.test\r\nRCPT TO:<evil@e.test>")),
        String("x"),
    )
    _envelope_error(
        String("a@b.test\r\nDATA"), _recipients("c@d.test"), String("x")
    )
    _envelope_error(String("a@b.test"), _recipients(""), String("x"))

    var utf8 = String("m") + chr(0xFC) + "ller@example.com"
    var env8 = validate_envelope(
        String("a@b.test"), _recipients(utf8), Span(_b("x"))
    )
    assert_true(env8.needs_smtputf8)


def test_error_kinds() raises:
    assert_true(error_is_retryable(String("SmtpTimeout: MAIL FROM: no progress")))
    assert_true(error_is_retryable(String("SmtpTransport: connect: refused")))
    assert_false(error_is_retryable(String("SmtpProtocol: x")))
    assert_false(error_is_retryable(String("SmtpSecurity: x")))
    assert_false(error_is_retryable(String("SmtpEnvelope: x")))
    assert_false(error_is_retryable(String("SmtpAuth: x")))
    assert_false(error_is_retryable(String("SmtpConfig: x")))


def main() raises:
    # Every case runs; the failures are reported together.
    var failed = String("")
    try:
        test_reply_lines()
    except e:
        failed += "\n  test_reply_lines: " + String(e)
    try:
        test_enhanced_status_codes()
    except e:
        failed += "\n  test_enhanced_status_codes: " + String(e)
    try:
        test_capabilities()
    except e:
        failed += "\n  test_capabilities: " + String(e)
    try:
        test_normalize_line_endings()
    except e:
        failed += "\n  test_normalize_line_endings: " + String(e)
    try:
        test_dot_stuffing()
    except e:
        failed += "\n  test_dot_stuffing: " + String(e)
    try:
        test_envelope()
    except e:
        failed += "\n  test_envelope: " + String(e)
    try:
        test_error_kinds()
    except e:
        failed += "\n  test_error_kinds: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_reply_wire: FAILED" + failed)
    print("test_reply_wire: OK")
