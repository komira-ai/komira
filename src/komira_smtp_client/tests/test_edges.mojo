# Edges of one message that the other scripted files do not reach: a reply that
# is not a refusal where one belongs, a 421 in the middle of the recipients, the
# duplicate warning when the end of DATA is lost, QUIT after a refusal that is
# raised, `all_accepted`, and the settings the README example builds.
#
# What each case catches:
# - test_data_answered_2xx: DATA answered 250 (not 354) raises SmtpProtocol and
#   the body is never written; it must not come back as an accepted message.
# - test_421_mid_rcpt: a 421 on the second RCPT returns a transient `rcpt`
#   result holding both recipients' answers, closes the session, and writes no
#   RSET and no DATA (a client that raises "session is closed" instead, or
#   drops the first recipient's answer, fails).
# - test_end_of_data_warning: a stall, and a close, after the whole body was
#   sent stay retryable errors at stage `end-of-data` and say a retry may
#   deliver the message twice; the same stall at RCPT TO does not say so.
# - test_size_refusal_quits: a message over the advertised SIZE raises
#   SmtpEnvelope and QUIT is still written (a TLS stream then sends its
#   close_notify).
# - test_all_accepted: one refused recipient is an accepted message that is
#   not `all_accepted()`; every recipient accepted is.
# - test_readme_settings: the config and credentials of the README's first
#   example (STARTTLS on 587 by default, the name and EHLO name it sets).

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.transport.scripted import ScriptedStream
from komira_smtp_client import (
    NoWaitHook,
    SEND_TRANSIENT,
    SmtpClientConfig,
    SmtpClock,
    SmtpCredentials,
    SmtpSecurity,
    SmtpSession,
    error_is_retryable,
    send_via_session,
)

comptime _Sess = SmtpSession[ScriptedStream, NoWaitHook]

comptime _G = "220 mail.test ESMTP ready\r\n"
comptime _EHLO = "250-mail.test\r\n250 SIZE 100000\r\n"
comptime _MSG = "Subject: t\r\n\r\nhi\r\n"


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _config() -> SmtpClientConfig:
    return SmtpClientConfig(
        String("mail.test"),
        UInt16(587),
        SmtpSecurity.plaintext(),
        String("client.test"),
    )


struct _Rig(Movable):
    var session: _Sess
    var wire: ArcPointer[List[UInt8]]

    def __init__(out self, var session: _Sess, wire: ArcPointer[List[UInt8]]):
        self.session = session^
        self.wire = wire

    def sent(self) -> String:
        # SAFETY: every test message is ASCII.
        return String(unsafe_from_utf8=Span(self.wire[]))


def _open(
    script: String,
    cfg: SmtpClientConfig,
    stall: Int,
    cell: Optional[ArcPointer[Int]],
) raises -> _Rig:
    var wire = ArcPointer[List[UInt8]](List[UInt8]())
    var s = ScriptedStream.from_read_script_with_capture(_b(script), wire)
    s.set_max_read_per_call(1)
    if stall > 0:
        s.set_pending_after_script(stall)
    if cell:
        s.advance_clock_on_read(cell.value(), 1000)
    var session = _Sess.new(s^, NoWaitHook(), cfg, False)
    return _Rig(session^, wire)


def _ready(script: String) raises -> _Rig:
    var rig = _open(String(_G) + _EHLO + script, _config(), 0, None)
    assert_equal(rig.session.read_greeting().code, 220)
    assert_equal(rig.session.ehlo().code, 250)
    return rig^


def _rcpts(a: String, b: String = "") -> List[String]:
    var l = List[String]()
    l.append(a)
    if b.byte_length() > 0:
        l.append(b)
    return l^


def test_data_answered_2xx() raises:
    var rig = _ready(String("250 ok\r\n250 ok\r\n250 2.0.0 fine\r\n"))
    var msg = String("")
    try:
        _ = rig.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpProtocol: DATA"), msg)
    assert_true(msg.find("not 354") >= 0, msg)
    assert_false(error_is_retryable(msg))
    assert_true(rig.session.is_closed())
    assert_false(rig.sent().find("Subject") >= 0)


def test_421_mid_rcpt() raises:
    var rig = _ready(String("250 ok\r\n250 ok\r\n421 4.3.2 shutting down\r\n"))
    var r = rig.session.send(
        String("a@sender.test"),
        _rcpts("x@example.com", "y@example.com"),
        Span(_b(_MSG)),
    )
    assert_equal(r.outcome, SEND_TRANSIENT)
    assert_equal(r.stage, "rcpt")
    assert_equal(r.code, 421)
    assert_equal(r.enhanced, "4.3.2")
    assert_equal(len(r.recipients), 2)
    assert_true(r.recipients[0].accepted)
    assert_false(r.recipients[1].accepted)
    assert_equal(r.recipients[1].code, 421)
    assert_false(r.all_accepted())
    assert_true(rig.session.is_closed())
    assert_false(rig.sent().find("DATA") >= 0)
    assert_false(rig.sent().find("RSET") >= 0)


def _budget_rig(script: String, command_us: Int, data_us: Int, stall: Int) raises -> _Rig:
    var cell = ArcPointer[Int](0)
    var cfg = _config()
    cfg.clock = SmtpClock.manual(cell)
    cfg.command_budget_us = command_us
    cfg.data_budget_us = data_us
    var rig = _open(script, cfg, stall, Optional[ArcPointer[Int]](cell))
    assert_equal(rig.session.read_greeting().code, 220)
    assert_equal(rig.session.ehlo().code, 250)
    return rig^


def _send_error(mut rig: _Rig) -> String:
    try:
        _ = rig.session.send(
            String("a@sender.test"), _rcpts("bob@example.com"), Span(_b(_MSG))
        )
    except e:
        return String(e)
    return String("")


def test_end_of_data_warning() raises:
    var warn = String("may have accepted the message")
    var twice = String("deliver it twice")
    var stall = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n250 ok\r\n354 go\r\n",
        1_000_000_000_000,
        5000,
        1000,
    )
    var m1 = _send_error(stall)
    assert_true(m1.startswith("SmtpTimeout: end-of-data"), m1)
    assert_true(m1.find(warn) >= 0 and m1.find(twice) >= 0, m1)
    assert_true(error_is_retryable(m1))

    var gone = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n250 ok\r\n354 go\r\n",
        1_000_000_000_000,
        1_000_000_000_000,
        0,
    )
    var m2 = _send_error(gone)
    assert_true(m2.startswith("SmtpTransport: end-of-data"), m2)
    assert_true(m2.find(twice) >= 0, m2)

    var rcpt = _budget_rig(
        String(_G) + _EHLO + "250 ok\r\n", 5000, 1_000_000_000_000, 1000
    )
    var m3 = _send_error(rcpt)
    assert_true(m3.startswith("SmtpTimeout: RCPT TO"), m3)
    assert_false(m3.find(twice) >= 0, m3)


def test_size_refusal_quits() raises:
    var cfg = _config()
    var wire = ArcPointer[List[UInt8]](List[UInt8]())
    var script = String(_G) + "250-mail.test\r\n250 SIZE 10\r\n221 bye\r\n"
    var s = ScriptedStream.from_read_script_with_capture(_b(script), wire)
    s.set_max_read_per_call(1)
    var session = _Sess.new(s^, NoWaitHook(), cfg, False)
    var msg = String("")
    try:
        _ = send_via_session(
            session^,
            cfg,
            None,
            String("a@sender.test"),
            _rcpts("bob@example.com"),
            Span(_b(_MSG)),
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpEnvelope"), msg)
    # SAFETY: ASCII.
    assert_equal(String(unsafe_from_utf8=Span(wire[])), "EHLO client.test\r\nQUIT\r\n")


def test_all_accepted() raises:
    var part = _ready(String("250 ok\r\n250 ok\r\n550 5.1.1 no\r\n354 go\r\n250 2.0.0 q\r\n"))
    var r = part.session.send(
        String("a@sender.test"),
        _rcpts("x@example.com", "y@example.com"),
        Span(_b(_MSG)),
    )
    assert_true(r.is_accepted())
    assert_equal(r.accepted_count(), 1)
    assert_false(r.all_accepted())
    var full = _ready(String("250 ok\r\n250 ok\r\n250 ok\r\n354 go\r\n250 2.0.0 q\r\n"))
    var f = full.session.send(
        String("a@sender.test"),
        _rcpts("x@example.com", "y@example.com"),
        Span(_b(_MSG)),
    )
    assert_true(f.all_accepted())


def test_readme_settings() raises:
    var config = SmtpClientConfig(String("smtp.example.com"))
    config.ehlo_name = String("client.example.com")
    assert_equal(Int(config.port), 587)
    assert_true(config.security.is_starttls())
    assert_equal(config.effective_tls_server_name(), "smtp.example.com")
    var creds = Optional[SmtpCredentials](
        SmtpCredentials(String("ann"), String("her password"))
    )
    assert_equal(creds.value().username, "ann")


def main() raises:
    var failed = String("")
    try:
        test_data_answered_2xx()
    except e:
        failed += "\n  test_data_answered_2xx: " + String(e)
    try:
        test_421_mid_rcpt()
    except e:
        failed += "\n  test_421_mid_rcpt: " + String(e)
    try:
        test_end_of_data_warning()
    except e:
        failed += "\n  test_end_of_data_warning: " + String(e)
    try:
        test_size_refusal_quits()
    except e:
        failed += "\n  test_size_refusal_quits: " + String(e)
    try:
        test_all_accepted()
    except e:
        failed += "\n  test_all_accepted: " + String(e)
    try:
        test_readme_settings()
    except e:
        failed += "\n  test_readme_settings: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_edges: FAILED" + failed)
    print("test_edges: OK")
