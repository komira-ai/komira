# SmtpSession over ScriptedStream conversations: the commands of one message,
# every reply path, and the budgets on a manual clock. The script is what the
# server says; the capture is what the client wrote, asserted as exact bytes.
# No test sleeps or reads a clock: time moves only when a scripted read answers
# "nothing yet" (`advance_clock_on_read`).
#
# What each case catches:
# - test_greeting: 220 and 554 returned with their text and enhanced code and
#   nothing written before the greeting.
# - test_ehlo: multi-line capabilities in mixed case, HELO after a 500 or 502,
#   a reply whose lines carry different codes refused and the session closed.
# - test_auth_plain / _334 / _login / _refusals: PLAIN with the exact initial
#   response, a 334 that makes the client send it again, LOGIN with the two
#   exact base64 lines, 535 returned with its enhanced code, no mechanism
#   offered, credentials refused on a clear connection with nothing written.
# - test_password_never_in_text: the password and its base64 forms replaced in
#   a reply that echoes them, and absent from every error of every AUTH path.
# - test_mail_refused / test_mixed_recipients / test_all_recipients_refused:
#   MAIL 550 stops before RCPT; per-recipient codes, text and enhanced codes
#   kept in order with one accepted; when none is accepted RSET goes out and
#   DATA does not, transient when any refusal is 4xx.
# - test_data_outcomes: the 250 text (queue id) and its enhanced code, 452 as
#   transient, 554 as permanent, DATA answered 554 (RSET, no body), 421 closing.
# - test_data_bytes_exact: a body of `.hello`, a bare LF, a bare CR and no final
#   CRLF reaches the wire dot-stuffed, as CRLF lines, ending `.` CRLF.
# - test_size_and_eight_bit: the SIZE parameter, a message over the advertised
#   limit refused before MAIL, 8-bit without 8BITMIME refused, BODY=8BITMIME and
#   SMTPUTF8 sent when needed and offered, refused when not offered.
# - test_rset_between_messages_and_quit: the second message starts with RSET;
#   QUIT reads 221 and closes.
# - test_reply_caps: an over-long line with and without its CRLF, and a reply of
#   too many lines, each a SmtpProtocol error before memory grows.
# - test_budgets: a stall at the greeting, RCPT TO and the end of DATA raises
#   SmtpTimeout naming the stage; RCPT is bounded by the command budget and the
#   end of DATA by the data budget, not the other way round.
# - test_server_close_and_injection: EOF mid-reply is SmtpTransport; bytes
#   behind the STARTTLS 220 are SmtpSecurity.
# - test_huge_budgets_do_not_wrap: budgets of Int's maximum on a manual clock
#   that is above zero still let a whole message through (no wrapped deadline).
# - test_unsolicited_bytes_before_a_command: a reply left in the buffer when
#   the next command is about to be written ends the session before any write.
# - test_upgrade_refusals_close_the_session: upgrade_tls with no server name
#   and with no descriptor closes the session.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.transport.scripted import ScriptedStream
from komira_smtp_client import (
    NoWaitHook,
    SEND_PERMANENT,
    SEND_TRANSIENT,
    SmtpClientConfig,
    SmtpClock,
    SmtpCredentials,
    SmtpSecurity,
    SmtpSession,
    error_is_retryable,
)

comptime _Sess = SmtpSession[ScriptedStream, NoWaitHook]

comptime _G = "220 mail.test ESMTP ready\r\n"
comptime _EHLO = (
    "250-mail.test greets client.test\r\n"
    "250-AUTH PLAIN LOGIN\r\n"
    "250-SIZE 100000\r\n"
    "250-8BITMIME\r\n"
    "250 ENHANCEDSTATUSCODES\r\n"
)
comptime _EHLO_BARE = "250 mail.test\r\n"
comptime _PLAIN_B64 = "AGFsaWNlAHMzY3JldA=="
comptime _USER_B64 = "YWxpY2U="
comptime _PASS_B64 = "czNjcmV0"
comptime _MSG = "Subject: t\r\n\r\nhi\r\n"


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


struct _Rig(Movable):
    var session: _Sess
    var wire: ArcPointer[List[UInt8]]

    def __init__(out self, var session: _Sess, wire: ArcPointer[List[UInt8]]):
        self.session = session^
        self.wire = wire

    def sent(self) -> String:
        # SAFETY: every test message is valid UTF-8.
        return String(unsafe_from_utf8=Span(self.wire[]))


def _config() -> SmtpClientConfig:
    return SmtpClientConfig(
        String("mail.test"),
        UInt16(587),
        SmtpSecurity.plaintext(),
        String("client.test"),
    )


def _open_with(
    script: String,
    cfg: SmtpClientConfig,
    secure: Bool,
    max_read: Int,
    stall: Int,
    cell: Optional[ArcPointer[Int]],
) raises -> _Rig:
    var wire = ArcPointer[List[UInt8]](List[UInt8]())
    var s = ScriptedStream.from_read_script_with_capture(_b(script), wire)
    s.set_max_read_per_call(max_read)
    if stall > 0:
        s.set_pending_after_script(stall)
    if cell:
        s.advance_clock_on_read(cell.value(), 1000)
    var session = _Sess.new(s^, NoWaitHook(), cfg, secure)
    return _Rig(session^, wire)


def _open(script: String, secure: Bool = False) raises -> _Rig:
    return _open_with(script, _config(), secure, 1, 0, None)


def _ready(script: String, secure: Bool = False) raises -> _Rig:
    """A session that has read the greeting and EHLO."""
    var rig = _open(String(_G) + _EHLO + script, secure)
    _ = rig.session.read_greeting()
    var r = rig.session.ehlo()
    assert_equal(r.code, 250)
    return rig^


def _rcpts(a: String, b: String = "", c: String = "") -> List[String]:
    var l = List[String]()
    l.append(a)
    if b.byte_length() > 0:
        l.append(b)
    if c.byte_length() > 0:
        l.append(c)
    return l^


def _creds() -> SmtpCredentials:
    return SmtpCredentials(String("alice"), String("s3cret"))


def test_greeting() raises:
    var ok = _open(String(_G))
    var g = ok.session.read_greeting()
    assert_equal(g.code, 220)
    assert_equal(g.text(), "mail.test ESMTP ready")
    assert_equal(ok.sent(), "")
    var no = _open(String("554 5.3.2 no SMTP service here\r\n"))
    var r = no.session.read_greeting()
    assert_equal(r.code, 554)
    assert_equal(r.enhanced, "5.3.2")
    assert_equal(r.text(), "no SMTP service here")
    assert_true(r.is_permanent())
    assert_equal(no.sent(), "")


def test_ehlo() raises:
    var rig = _open(String(_G) + _EHLO)
    _ = rig.session.read_greeting()
    var r = rig.session.ehlo()
    assert_equal(r.code, 250)
    assert_equal(rig.sent(), "EHLO client.test\r\n")
    var caps = rig.session.capabilities()
    assert_true(caps.offers_auth("PLAIN"))
    assert_true(caps.offers_auth("LOGIN"))
    assert_equal(caps.size_limit, 100000)
    assert_true(caps.eight_bit_mime)
    assert_true(caps.enhanced_status_codes)
    assert_false(caps.starttls)

    var lower = _open(
        String("250-mail.test\r\n250-starttls\r\n250 auth plain\r\n")
    )
    _ = lower.session.ehlo()
    assert_true(lower.session.capabilities().starttls)
    assert_true(lower.session.capabilities().offers_auth("PLAIN"))

    var helo = _open(String("502 5.5.1 not implemented\r\n250 mail.test\r\n"))
    var h = helo.session.ehlo()
    assert_equal(h.code, 250)
    assert_equal(helo.sent(), "EHLO client.test\r\nHELO client.test\r\n")
    assert_false(helo.session.capabilities().starttls)

    var mixed = _open(String("250-mail.test\r\n251 other\r\n"))
    var msg = String("")
    try:
        _ = mixed.session.ehlo()
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpProtocol"), msg)
    assert_true(mixed.session.is_closed())


def test_auth_plain() raises:
    var rig = _ready(String("235 2.7.0 Authentication successful\r\n"), True)
    var r = rig.session.authenticate(_creds(), False)
    assert_equal(r.code, 235)
    assert_equal(
        rig.sent(),
        "EHLO client.test\r\nAUTH PLAIN " + String(_PLAIN_B64) + "\r\n",
    )


def test_auth_plain_334() raises:
    var rig = _ready(String("334 \r\n235 ok\r\n"), True)
    var r = rig.session.authenticate(_creds(), False)
    assert_equal(r.code, 235)
    assert_equal(
        rig.sent(),
        "EHLO client.test\r\nAUTH PLAIN "
        + String(_PLAIN_B64)
        + "\r\n"
        + String(_PLAIN_B64)
        + "\r\n",
    )


def test_auth_login() raises:
    var rig = _open(
        String(_G)
        + "250-mail.test\r\n250 AUTH LOGIN\r\n"
        + "334 VXNlcm5hbWU6\r\n334 UGFzc3dvcmQ6\r\n235 ok\r\n",
        True,
    )
    _ = rig.session.read_greeting()
    _ = rig.session.ehlo()
    var r = rig.session.authenticate(_creds(), False)
    assert_equal(r.code, 235)
    assert_equal(
        rig.sent(),
        "EHLO client.test\r\nAUTH LOGIN\r\n"
        + String(_USER_B64)
        + "\r\n"
        + String(_PASS_B64)
        + "\r\n",
    )


def test_auth_refusals() raises:
    var bad = _ready(
        String("535 5.7.8 Authentication credentials invalid\r\n"), True
    )
    var r = bad.session.authenticate(_creds(), False)
    assert_equal(r.code, 535)
    assert_equal(r.enhanced, "5.7.8")
    assert_true(r.is_permanent())

    var none = _open(String(_G) + _EHLO_BARE, True)
    _ = none.session.read_greeting()
    _ = none.session.ehlo()
    var msg = String("")
    try:
        _ = none.session.authenticate(_creds(), False)
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpAuth"), msg)
    assert_false(error_is_retryable(msg))
    assert_equal(none.sent(), "EHLO client.test\r\n")

    var clear = _ready(String(""), False)
    var msg2 = String("")
    try:
        _ = clear.session.authenticate(_creds(), False)
    except e:
        msg2 = String(e)
    assert_true(msg2.startswith("SmtpSecurity"), msg2)
    assert_equal(clear.sent(), "EHLO client.test\r\n")
    # The same call is allowed when the caller says the clear is acceptable.
    var allowed = _open(String(_G) + _EHLO + "235 ok\r\n", False)
    _ = allowed.session.read_greeting()
    _ = allowed.session.ehlo()
    assert_equal(allowed.session.authenticate(_creds(), True).code, 235)


def _no_secret(text: String) raises:
    assert_false(text.find("s3cret") >= 0, text)
    assert_false(text.find(_PLAIN_B64) >= 0, text)
    assert_false(text.find(_PASS_B64) >= 0, text)


def test_password_never_in_text() raises:
    var echo = _ready(
        String(
            "535 5.7.8 bad s3cret / "
            + String(_PLAIN_B64)
            + " / "
            + String(_PASS_B64)
            + "\r\n"
        ),
        True,
    )
    var r = echo.session.authenticate(_creds(), False)
    assert_equal(r.code, 535)
    assert_true(r.text().find("***") >= 0, r.text())
    _no_secret(r.text())

    var errors = List[String]()
    # An endless challenge.
    var chal = _ready(
        String("334 \r\n334 s3cret?\r\n501 cancelled\r\n"), True
    )
    try:
        _ = chal.session.authenticate(_creds(), False)
    except e:
        errors.append(String(e))
    # The server vanishes in the middle of AUTH.
    var eof = _ready(String(""), True)
    try:
        _ = eof.session.authenticate(_creds(), False)
    except e:
        errors.append(String(e))
    # Refused in the clear, no mechanism.
    var clear = _ready(String(""), False)
    try:
        _ = clear.session.authenticate(_creds(), False)
    except e:
        errors.append(String(e))
    # A stall in AUTH.
    var cell = ArcPointer[Int](0)
    var cfg = _config()
    cfg.clock = SmtpClock.manual(cell)
    cfg.command_budget_us = 5000
    var stall = _open_with(
        String(_G) + _EHLO, cfg, True, 1, 1000, Optional[ArcPointer[Int]](cell)
    )
    _ = stall.session.read_greeting()
    _ = stall.session.ehlo()
    try:
        _ = stall.session.authenticate(_creds(), False)
    except e:
        errors.append(String(e))
    assert_equal(len(errors), 4)
    for i in range(len(errors)):
        assert_true(errors[i].startswith("Smtp"), errors[i])
        _no_secret(errors[i])


def test_mail_refused() raises:
    var rig = _ready(String("550 5.7.1 sender not allowed\r\n"))
    var res = rig.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_true(res.is_permanent())
    assert_equal(res.stage, "mail")
    assert_equal(res.code, 550)
    assert_equal(res.enhanced, "5.7.1")
    assert_equal(res.text, "sender not allowed")
    assert_equal(len(res.recipients), 0)
    assert_equal(
        rig.sent(),
        "EHLO client.test\r\nMAIL FROM:<a@sender.test> SIZE=18\r\n",
    )


def test_mixed_recipients() raises:
    var rig = _ready(
        String(
            "250 2.1.0 sender ok\r\n"
            "250 2.1.5 bob ok\r\n"
            "550 5.1.1 no such user\r\n"
            "451 4.7.1 greylisted\r\n"
            "354 go ahead\r\n"
            "250 2.0.0 Ok: queued as ABC123\r\n"
        )
    )
    var res = rig.session.send(
        String("a@sender.test"),
        _rcpts("bob@example.com", "ghost@example.com", "late@example.com"),
        Span(_b(_MSG)),
    )
    assert_true(res.is_accepted())
    assert_equal(res.stage, "accepted")
    assert_equal(res.code, 250)
    assert_equal(res.text, "Ok: queued as ABC123")
    assert_equal(res.enhanced, "2.0.0")
    assert_equal(len(res.recipients), 3)
    assert_equal(res.accepted_count(), 1)
    assert_equal(res.recipients[0].address, "bob@example.com")
    assert_true(res.recipients[0].accepted)
    assert_equal(res.recipients[0].enhanced, "2.1.5")
    assert_false(res.recipients[1].accepted)
    assert_equal(res.recipients[1].code, 550)
    assert_equal(res.recipients[1].enhanced, "5.1.1")
    assert_equal(res.recipients[1].text, "no such user")
    assert_false(res.recipients[2].accepted)
    assert_equal(res.recipients[2].code, 451)
    assert_equal(
        rig.sent(),
        "EHLO client.test\r\nMAIL FROM:<a@sender.test> SIZE=18\r\n"
        "RCPT TO:<bob@example.com>\r\nRCPT TO:<ghost@example.com>\r\n"
        "RCPT TO:<late@example.com>\r\nDATA\r\n"
        "Subject: t\r\n\r\nhi\r\n.\r\n",
    )


def test_all_recipients_refused() raises:
    var perm = _ready(
        String(
            "250 ok\r\n550 5.1.1 no\r\n550 5.1.2 nope\r\n250 2.0.0 reset\r\n"
        )
    )
    var r = perm.session.send(
        String("a@sender.test"),
        _rcpts("x@example.com", "y@example.com"),
        Span(_b(_MSG)),
    )
    assert_true(r.is_permanent())
    assert_equal(r.stage, "rcpt")
    assert_equal(r.code, 550)
    assert_equal(r.enhanced, "5.1.1")
    assert_equal(r.accepted_count(), 0)
    assert_true(perm.sent().endswith("RCPT TO:<y@example.com>\r\nRSET\r\n"))
    assert_false(perm.sent().find("DATA") >= 0)

    var trans = _ready(
        String("250 ok\r\n550 5.1.1 no\r\n451 4.3.0 later\r\n250 reset\r\n")
    )
    var t = trans.session.send(
        String("a@sender.test"),
        _rcpts("x@example.com", "y@example.com"),
        Span(_b(_MSG)),
    )
    assert_true(t.is_transient())
    assert_equal(t.code, 451)
    assert_equal(t.enhanced, "4.3.0")
    assert_false(trans.sent().find("DATA") >= 0)


def _one_rcpt_script(tail: String) -> String:
    return String("250 ok\r\n250 ok\r\n354 go\r\n") + tail


def test_data_outcomes() raises:
    var r452 = _ready(_one_rcpt_script(String("452 4.3.1 insufficient storage\r\n")))
    var t = r452.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_true(t.is_transient())
    assert_equal(t.stage, "end-of-data")
    assert_equal(t.code, 452)
    assert_equal(t.accepted_count(), 1)

    var r554 = _ready(_one_rcpt_script(String("554 5.6.0 content refused\r\n")))
    var p = r554.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_true(p.is_permanent())
    assert_equal(p.code, 554)
    assert_equal(p.outcome, SEND_PERMANENT)

    var refused = _ready(
        String("250 ok\r\n250 ok\r\n554 5.5.1 no valid recipients\r\n250 reset\r\n")
    )
    var d = refused.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_true(d.is_permanent())
    assert_equal(d.stage, "data")
    assert_true(refused.sent().endswith("DATA\r\nRSET\r\n"))
    assert_false(refused.sent().find("Subject") >= 0)

    var closing = _ready(String("250 ok\r\n421 4.3.2 shutting down\r\n"))
    var c = closing.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_equal(c.outcome, SEND_TRANSIENT)
    assert_equal(c.stage, "rcpt")
    assert_true(closing.session.is_closed())
    assert_false(closing.sent().find("RSET") >= 0)


def test_data_bytes_exact() raises:
    var rig = _ready(String("250 ok\r\n250 ok\r\n354 go\r\n250 queued\r\n"))
    var message = String(".hello\nsecond\r\n..dot\rthird")
    var res = rig.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(message))
    )
    assert_true(res.is_accepted())
    var sent = rig.sent()
    var at = sent.find("DATA\r\n")
    assert_true(at >= 0)
    var body = String(sent[byte = at + 6 : sent.byte_length()])
    assert_equal(body, "..hello\r\nsecond\r\n...dot\r\nthird\r\n.\r\n")
    # SIZE counted the normalised message, not the input.
    assert_true(sent.find("SIZE=30") >= 0, sent)


def test_size_and_eight_bit() raises:
    var small = _open(
        String(_G) + "250-mail.test\r\n250 SIZE 100\r\n"
    )
    _ = small.session.read_greeting()
    _ = small.session.ehlo()
    var big = String("")
    for _ in range(198):
        big += "x"
    big += "\r\n"
    var msg = String("")
    try:
        _ = small.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(big))
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpEnvelope"), msg)
    assert_equal(small.sent(), "EHLO client.test\r\n")

    var latin = String("caf") + chr(0xE9) + "\r\n"
    var no8 = _open(String(_G) + _EHLO_BARE)
    _ = no8.session.read_greeting()
    _ = no8.session.ehlo()
    var m2 = String("")
    try:
        _ = no8.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(latin))
        )
    except e:
        m2 = String(e)
    assert_true(m2.startswith("SmtpEnvelope"), m2)
    assert_true(m2.find("8BITMIME") >= 0, m2)
    assert_equal(no8.sent(), "EHLO client.test\r\n")

    var with8 = _ready(String("250 ok\r\n250 ok\r\n354 go\r\n250 queued\r\n"))
    var ok8 = with8.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(latin))
    )
    assert_true(ok8.is_accepted())
    assert_true(
        with8.sent().find("MAIL FROM:<a@sender.test> SIZE=7 BODY=8BITMIME\r\n") >= 0,
        with8.sent(),
    )

    var utf8_rcpt = String("m") + chr(0xFC) + "ller@example.com"
    var nou = _open(String(_G) + _EHLO)
    _ = nou.session.read_greeting()
    _ = nou.session.ehlo()
    var m3 = String("")
    try:
        _ = nou.session.send(
            String("a@sender.test"), _rcpts(utf8_rcpt), Span(_b(_MSG))
        )
    except e:
        m3 = String(e)
    assert_true(m3.startswith("SmtpEnvelope"), m3)
    assert_true(m3.find("SMTPUTF8") >= 0, m3)

    var withu = _open(
        String(_G)
        + "250-mail.test\r\n250-SMTPUTF8\r\n250 8BITMIME\r\n"
        + "250 ok\r\n250 ok\r\n354 go\r\n250 queued\r\n"
    )
    _ = withu.session.read_greeting()
    _ = withu.session.ehlo()
    var ru = withu.session.send(
        String("a@sender.test"), _rcpts(utf8_rcpt), Span(_b(_MSG))
    )
    assert_true(ru.is_accepted())
    assert_true(withu.sent().find("MAIL FROM:<a@sender.test> SMTPUTF8\r\n") >= 0, withu.sent())
    assert_true(withu.sent().find("RCPT TO:<" + utf8_rcpt + ">\r\n") >= 0, withu.sent())


def test_rset_between_messages_and_quit() raises:
    var rig = _ready(
        String(
            "250 ok\r\n250 ok\r\n354 go\r\n250 first\r\n"
            "250 reset\r\n250 ok\r\n250 ok\r\n354 go\r\n250 second\r\n"
            "221 2.0.0 bye\r\n"
        )
    )
    var one = rig.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_equal(one.text, "first")
    var two = rig.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_equal(two.text, "second")
    var q = rig.session.quit()
    assert_equal(q.code, 221)
    assert_true(rig.session.is_closed())
    var sent = rig.sent()
    assert_true(
        sent.find("\r\n.\r\nRSET\r\nMAIL FROM:") >= 0,
        "no RSET between the messages: " + sent,
    )
    var first_rset = sent.find("RSET\r\n")
    assert_true(first_rset >= 0)
    assert_true(sent.find("RSET\r\n", first_rset + 1) < 0, sent)
    assert_true(sent.endswith("\r\n.\r\nQUIT\r\n"), sent)


def test_reply_caps() raises:
    var cfg = _config()
    cfg.max_reply_line_bytes = 64
    var long_line = String("")
    for _ in range(100):
        long_line += "x"
    var framed = _open_with(
        String("220 ") + long_line + "\r\n", cfg, False, 1, 0, None
    )
    var m1 = String("")
    try:
        _ = framed.session.read_greeting()
    except e:
        m1 = String(e)
    assert_true(m1.startswith("SmtpProtocol"), m1)
    assert_true(m1.find("longer than 64") >= 0, m1)
    assert_true(framed.session.is_closed())

    var unframed = _open_with(
        String("220 ") + long_line, cfg, False, 1, 0, None
    )
    var m2 = String("")
    try:
        _ = unframed.session.read_greeting()
    except e:
        m2 = String(e)
    assert_true(m2.startswith("SmtpProtocol"), m2)
    assert_true(m2.find("longer than 64") >= 0, m2)

    # The whole line arrives in one read: the cap still holds.
    var slurped = _open_with(
        String("220 ") + long_line + "\r\n", cfg, False, 4096, 0, None
    )
    var m3 = String("")
    try:
        _ = slurped.session.read_greeting()
    except e:
        m3 = String(e)
    assert_true(m3.startswith("SmtpProtocol"), m3)

    var flood = String("")
    for _ in range(600):
        flood += "250-more\r\n"
    flood += "250 end\r\n"
    var many = _open_with(flood, _config(), False, 4096, 0, None)
    var m4 = String("")
    try:
        _ = many.session.read_greeting()
    except e:
        m4 = String(e)
    assert_true(m4.startswith("SmtpProtocol"), m4)
    assert_true(m4.find("size caps") >= 0, m4)
    assert_false(error_is_retryable(m4))


def _budget_rig(
    script: String, command_us: Int, data_us: Int, stall: Int
) raises -> _Rig:
    var cell = ArcPointer[Int](0)
    var cfg = _config()
    cfg.clock = SmtpClock.manual(cell)
    cfg.command_budget_us = command_us
    cfg.data_budget_us = data_us
    return _open_with(script, cfg, False, 1, stall, Optional[ArcPointer[Int]](cell))


def test_budgets() raises:
    var greet = _budget_rig(String(""), 5000, 1_000_000_000_000, 1000)
    var m1 = String("")
    try:
        _ = greet.session.read_greeting()
    except e:
        m1 = String(e)
    assert_true(m1.startswith("SmtpTimeout: greeting"), m1)
    assert_true(error_is_retryable(m1))
    assert_true(greet.session.is_closed())
    var m1b = String("")
    try:
        _ = greet.session.ehlo()
    except e:
        m1b = String(e)
    assert_true(m1b.startswith("SmtpProtocol"), m1b)
    assert_equal(greet.sent(), "")

    var rcpt = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n", 5000, 1_000_000_000_000, 1000
    )
    _ = rcpt.session.read_greeting()
    _ = rcpt.session.ehlo()
    var m2 = String("")
    try:
        _ = rcpt.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
        )
    except e:
        m2 = String(e)
    assert_true(m2.startswith("SmtpTimeout: RCPT TO"), m2)
    assert_true(rcpt.session.is_closed())

    var eod = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n250 ok\r\n354 go\r\n",
        1_000_000_000_000,
        5000,
        1000,
    )
    _ = eod.session.read_greeting()
    _ = eod.session.ehlo()
    var m3 = String("")
    try:
        _ = eod.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
        )
    except e:
        m3 = String(e)
    assert_true(m3.startswith("SmtpTimeout: end-of-data"), m3)
    assert_true(eod.sent().endswith("hi\r\n.\r\n"), eod.sent())

    # RCPT is bounded by the command budget: a tiny data budget does not
    # time it out (100 silent reads = 100000 us, then the server closes).
    var rcpt_long = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n", 1_000_000_000_000, 5000, 100
    )
    _ = rcpt_long.session.read_greeting()
    _ = rcpt_long.session.ehlo()
    var m4 = String("")
    try:
        _ = rcpt_long.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
        )
    except e:
        m4 = String(e)
    assert_true(m4.startswith("SmtpTransport: RCPT TO"), m4)

    # The end of DATA is bounded by the data budget: a tiny command budget
    # does not time it out.
    var eod_long = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n250 ok\r\n354 go\r\n",
        5000,
        1_000_000_000_000,
        100,
    )
    _ = eod_long.session.read_greeting()
    _ = eod_long.session.ehlo()
    var m5 = String("")
    try:
        _ = eod_long.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
        )
    except e:
        m5 = String(e)
    assert_true(m5.startswith("SmtpTransport: end-of-data"), m5)


def test_server_close_and_injection() raises:
    var eof = _open(String("250-mail.test\r\n250-partial\r\n"))
    var m1 = String("")
    try:
        _ = eof.session.ehlo()
    except e:
        m1 = String(e)
    assert_true(m1.startswith("SmtpTransport: EHLO"), m1)
    assert_true(error_is_retryable(m1))
    assert_true(eof.session.is_closed())

    # Whole script in one read: the 250 arrives behind the 220.
    var inj = _open_with(
        String("220 go ahead\r\n250 INJECTED\r\n"), _config(), False, 4096, 0, None
    )
    var m2 = String("")
    try:
        _ = inj.session.starttls_command()
    except e:
        m2 = String(e)
    assert_true(m2.startswith("SmtpSecurity"), m2)
    assert_true(inj.session.is_closed())

    # Without the extra bytes the 220 is returned and the upgrade is the
    # caller's step; a stream with no descriptor cannot run TLS.
    var clean = _open(String("220 go ahead\r\n"))
    var go = clean.session.starttls_command()
    assert_equal(go.code, 220)
    var m3 = String("")
    try:
        _ = clean.session.upgrade_tls(String(""), String("mail.test"))
    except e:
        m3 = String(e)
    assert_true(m3.startswith("SmtpSecurity"), m3)
    assert_true(m3.find("descriptor") >= 0, m3)


def test_huge_budgets_do_not_wrap() raises:
    # A budget near the top of Int must mean "very long", never an instant
    # timeout: the deadline is the clock plus the budget, and that sum must not
    # wrap negative. The clock is manual and starts above zero, so a plain sum
    # of this budget wraps.
    var cell = ArcPointer[Int](1000)
    var cfg = _config()
    cfg.clock = SmtpClock.manual(cell)
    cfg.command_budget_us = 9223372036854775807
    cfg.data_budget_us = 9223372036854775807
    var rig = _open_with(
        String(_G)
        + _EHLO
        + "250 ok\r\n250 ok\r\n354 go\r\n250 2.0.0 queued\r\n",
        cfg,
        False,
        1,
        0,
        None,
    )
    var g = rig.session.read_greeting()
    assert_equal(g.code, 220)
    var h = rig.session.ehlo()
    assert_equal(h.code, 250)
    var r = rig.session.send(
        String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
    )
    assert_equal(r.code, 250)
    assert_equal(r.stage, "accepted")
    assert_false(rig.session.is_closed())


def test_unsolicited_bytes_before_a_command() raises:
    # The server sends a second reply before the client has written the
    # command it would answer. The client must not take that leftover line as
    # the answer to its next command (here STARTTLS): it ends the session and
    # writes nothing more.
    var rig = _open_with(
        String("250-m\r\n250 STARTTLS\r\n220 INJECTED\r\n"),
        _config(),
        False,
        4096,
        0,
        None,
    )
    var h = rig.session.ehlo()
    assert_equal(h.code, 250)
    var m = String("")
    try:
        _ = rig.session.starttls_command()
    except e:
        m = String(e)
    assert_true(m.startswith("SmtpProtocol"), m)
    assert_true(m.find("unsolicited") >= 0, m)
    assert_true(rig.session.is_closed())
    assert_equal(rig.sent(), "EHLO client.test\r\n")


def test_upgrade_refusals_close_the_session() raises:
    # After a raised error the session is closed, as the type says.
    var noname = _open(String("220 go ahead\r\n"))
    _ = noname.session.starttls_command()
    var m1 = String("")
    try:
        _ = noname.session.upgrade_tls(String(""), String(""))
    except e:
        m1 = String(e)
    assert_true(m1.startswith("SmtpSecurity"), m1)
    assert_true(m1.find("server name") >= 0, m1)
    assert_true(noname.session.is_closed())

    var nofd = _open(String("220 go ahead\r\n"))
    _ = nofd.session.starttls_command()
    var m2 = String("")
    try:
        _ = nofd.session.upgrade_tls(String(""), String("mail.test"))
    except e:
        m2 = String(e)
    assert_true(m2.find("descriptor") >= 0, m2)
    assert_true(nofd.session.is_closed())


def main() raises:
    # Every case runs; the failures are reported together.
    var failed = String("")
    try:
        test_greeting()
    except e:
        failed += "\n  test_greeting: " + String(e)
    try:
        test_ehlo()
    except e:
        failed += "\n  test_ehlo: " + String(e)
    try:
        test_auth_plain()
    except e:
        failed += "\n  test_auth_plain: " + String(e)
    try:
        test_auth_plain_334()
    except e:
        failed += "\n  test_auth_plain_334: " + String(e)
    try:
        test_auth_login()
    except e:
        failed += "\n  test_auth_login: " + String(e)
    try:
        test_auth_refusals()
    except e:
        failed += "\n  test_auth_refusals: " + String(e)
    try:
        test_password_never_in_text()
    except e:
        failed += "\n  test_password_never_in_text: " + String(e)
    try:
        test_mail_refused()
    except e:
        failed += "\n  test_mail_refused: " + String(e)
    try:
        test_mixed_recipients()
    except e:
        failed += "\n  test_mixed_recipients: " + String(e)
    try:
        test_all_recipients_refused()
    except e:
        failed += "\n  test_all_recipients_refused: " + String(e)
    try:
        test_data_outcomes()
    except e:
        failed += "\n  test_data_outcomes: " + String(e)
    try:
        test_data_bytes_exact()
    except e:
        failed += "\n  test_data_bytes_exact: " + String(e)
    try:
        test_size_and_eight_bit()
    except e:
        failed += "\n  test_size_and_eight_bit: " + String(e)
    try:
        test_rset_between_messages_and_quit()
    except e:
        failed += "\n  test_rset_between_messages_and_quit: " + String(e)
    try:
        test_reply_caps()
    except e:
        failed += "\n  test_reply_caps: " + String(e)
    try:
        test_budgets()
    except e:
        failed += "\n  test_budgets: " + String(e)
    try:
        test_server_close_and_injection()
    except e:
        failed += "\n  test_server_close_and_injection: " + String(e)
    try:
        test_huge_budgets_do_not_wrap()
    except e:
        failed += "\n  test_huge_budgets_do_not_wrap: " + String(e)
    try:
        test_unsolicited_bytes_before_a_command()
    except e:
        failed += "\n  test_unsolicited_bytes_before_a_command: " + String(e)
    try:
        test_upgrade_refusals_close_the_session()
    except e:
        failed += "\n  test_upgrade_refusals_close_the_session: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_session: FAILED" + failed)
    print("test_session: OK")
