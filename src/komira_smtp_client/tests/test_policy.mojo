# The security policy and the order of steps of `send_via_session`, over
# ScriptedStream. The capture is asserted as exact bytes: what matters is as
# much what was never written (AUTH before TLS, MAIL after a refused upgrade)
# as what was.
#
# What each case catches:
# - test_plaintext_full_transcript: greeting, EHLO, AUTH PLAIN, MAIL, RCPT, DATA,
#   the body, QUIT, byte for byte, with the queue id in the result (a step
#   skipped, reordered or duplicated fails).
# - test_implicit_tls: a stream marked as TLS runs the whole transcript and AUTH
#   is allowed; a stream that is not TLS is refused before a byte is written (a
#   client that sends credentials over a stream it was told is TLS fails).
# - test_starttls_on_secure_stream: no second STARTTLS on a TLS stream.
# - test_starttls_not_offered: STARTTLS required and absent raises SmtpSecurity;
#   the wire holds only EHLO: no AUTH and no password, no MAIL (a silent
#   downgrade fails).
# - test_starttls_refused: 454 ends the send as a transient `starttls` result
#   and QUIT follows; a 220 followed by a stream that cannot run TLS raises
#   SmtpSecurity with no AUTH and no MAIL written.
# - test_greeting_and_ehlo_refusals: 554 permanent, 421 transient, a 250 where
#   220 belongs is a protocol error; EHLO 550 ends at stage `ehlo`.
# - test_auth_policy: 535 ends at stage `auth` with no MAIL; credentials with no
#   AUTH offered raise SmtpAuth; no credentials means no AUTH even if offered.
# - test_envelope_checked_first: a bad recipient raises before the greeting is
#   read, with nothing written.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.transport.scripted import ScriptedStream
from komira_smtp_client import (
    NoWaitHook,
    SendResult,
    SmtpClientConfig,
    SmtpCredentials,
    SmtpSecurity,
    SmtpSession,
    send_via_session,
)

comptime _Sess = SmtpSession[ScriptedStream, NoWaitHook]

comptime _G = "220 mail.test ESMTP ready\r\n"
comptime _EHLO = "250-mail.test\r\n250-AUTH PLAIN LOGIN\r\n250 SIZE 100000\r\n"
comptime _PLAIN_B64 = "AGFsaWNlAHMzY3JldA=="
comptime _MSG = "Subject: t\r\n\r\nhi\r\n"
comptime _TXN = (
    "250 ok\r\n250 ok\r\n354 go\r\n250 2.0.0 queued as Q1\r\n221 bye\r\n"
)
comptime _TXN_WIRE = (
    "MAIL FROM:<a@sender.test> SIZE=18\r\nRCPT TO:<bob@example.com>\r\nDATA\r\n"
    "Subject: t\r\n\r\nhi\r\n.\r\nQUIT\r\n"
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _config(security: SmtpSecurity) -> SmtpClientConfig:
    return SmtpClientConfig(
        String("mail.test"), UInt16(587), security.copy(), String("client.test")
    )


def _rcpts() -> List[String]:
    var l = List[String]()
    l.append(String("bob@example.com"))
    return l^


def _creds() -> Optional[SmtpCredentials]:
    return Optional[SmtpCredentials](
        SmtpCredentials(String("alice"), String("s3cret"))
    )


def _run(
    script: String,
    security: SmtpSecurity,
    secure: Bool,
    creds: Optional[SmtpCredentials],
    wire: ArcPointer[List[UInt8]],
) raises -> SendResult:
    var cfg = _config(security)
    var s = ScriptedStream.from_read_script_with_capture(_b(script), wire)
    s.set_max_read_per_call(1)
    var session = _Sess.new(s^, NoWaitHook(), cfg, secure)
    return send_via_session(
        session^,
        cfg,
        creds,
        String("a@sender.test"),
        _rcpts(),
        Span(_b(_MSG)),
    )


def _wire() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _text(wire: ArcPointer[List[UInt8]]) -> String:
    # SAFETY: the transcripts are ASCII.
    return String(unsafe_from_utf8=Span(wire[]))


def test_plaintext_full_transcript() raises:
    var wire = _wire()
    var r = _run(
        String(_G) + _EHLO + "235 ok\r\n" + _TXN,
        SmtpSecurity.plaintext(),
        False,
        _creds(),
        wire,
    )
    assert_true(r.is_accepted())
    assert_equal(r.text, "queued as Q1")
    assert_equal(r.enhanced, "2.0.0")
    assert_equal(
        _text(wire),
        "EHLO client.test\r\nAUTH PLAIN "
        + String(_PLAIN_B64)
        + "\r\n"
        + String(_TXN_WIRE),
    )


def test_implicit_tls() raises:
    var wire = _wire()
    var r = _run(
        String(_G) + _EHLO + "235 ok\r\n" + _TXN,
        SmtpSecurity.implicit_tls(),
        True,
        _creds(),
        wire,
    )
    assert_true(r.is_accepted())
    assert_equal(
        _text(wire),
        "EHLO client.test\r\nAUTH PLAIN "
        + String(_PLAIN_B64)
        + "\r\n"
        + String(_TXN_WIRE),
    )
    var clear = _wire()
    var msg = String("")
    try:
        _ = _run(
            String(_G) + _EHLO,
            SmtpSecurity.implicit_tls(),
            False,
            _creds(),
            clear,
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpSecurity"), msg)
    assert_equal(_text(clear), "")


def test_starttls_on_secure_stream() raises:
    var wire = _wire()
    var r = _run(
        String(_G) + "250-mail.test\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n235 ok\r\n" + _TXN,
        SmtpSecurity.starttls(),
        True,
        _creds(),
        wire,
    )
    assert_true(r.is_accepted())
    assert_false(_text(wire).find("STARTTLS") >= 0, _text(wire))


def test_starttls_not_offered() raises:
    var wire = _wire()
    var msg = String("")
    try:
        _ = _run(
            String(_G) + _EHLO,
            SmtpSecurity.starttls(),
            False,
            _creds(),
            wire,
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpSecurity"), msg)
    assert_true(msg.find("STARTTLS") >= 0, msg)
    assert_equal(_text(wire), "EHLO client.test\r\n")


def test_starttls_refused() raises:
    var wire = _wire()
    var r = _run(
        String(_G)
        + "250-mail.test\r\n250 STARTTLS\r\n454 4.7.0 TLS not available\r\n221 bye\r\n",
        SmtpSecurity.starttls(),
        False,
        _creds(),
        wire,
    )
    assert_true(r.is_transient())
    assert_equal(r.stage, "starttls")
    assert_equal(r.code, 454)
    assert_equal(r.enhanced, "4.7.0")
    assert_equal(_text(wire), "EHLO client.test\r\nSTARTTLS\r\nQUIT\r\n")

    var wire2 = _wire()
    var msg = String("")
    try:
        _ = _run(
            String(_G)
            + "250-mail.test\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n220 go ahead\r\n",
            SmtpSecurity.starttls(),
            False,
            _creds(),
            wire2,
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpSecurity"), msg)
    assert_equal(_text(wire2), "EHLO client.test\r\nSTARTTLS\r\n")


def test_greeting_and_ehlo_refusals() raises:
    var w1 = _wire()
    var r1 = _run(
        String("554 5.3.2 go away\r\n"),
        SmtpSecurity.plaintext(),
        False,
        None,
        w1,
    )
    assert_true(r1.is_permanent())
    assert_equal(r1.stage, "greeting")
    assert_equal(_text(w1), "")

    var w2 = _wire()
    var r2 = _run(
        String("421 4.3.2 busy\r\n"),
        SmtpSecurity.plaintext(),
        False,
        None,
        w2,
    )
    assert_true(r2.is_transient())
    assert_equal(r2.stage, "greeting")

    var w3 = _wire()
    var msg = String("")
    try:
        _ = _run(
            String("250 mail.test\r\n"),
            SmtpSecurity.plaintext(),
            False,
            None,
            w3,
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpProtocol"), msg)

    var w4 = _wire()
    var r4 = _run(
        String(_G) + "550 5.7.0 no EHLO for you\r\n221 bye\r\n",
        SmtpSecurity.plaintext(),
        False,
        None,
        w4,
    )
    assert_true(r4.is_permanent())
    assert_equal(r4.stage, "ehlo")
    assert_equal(_text(w4), "EHLO client.test\r\nQUIT\r\n")


def test_auth_policy() raises:
    var w1 = _wire()
    var r1 = _run(
        String(_G) + _EHLO + "535 5.7.8 bad credentials\r\n221 bye\r\n",
        SmtpSecurity.plaintext(),
        False,
        _creds(),
        w1,
    )
    assert_true(r1.is_permanent())
    assert_equal(r1.stage, "auth")
    assert_equal(r1.code, 535)
    assert_equal(r1.enhanced, "5.7.8")
    assert_false(_text(w1).find("MAIL") >= 0, _text(w1))
    assert_true(_text(w1).endswith("QUIT\r\n"))

    var w2 = _wire()
    var r2 = _run(
        String(_G) + _EHLO + "454 4.7.0 try later\r\n221 bye\r\n",
        SmtpSecurity.plaintext(),
        False,
        _creds(),
        w2,
    )
    assert_true(r2.is_transient())
    assert_equal(r2.stage, "auth")

    var w3 = _wire()
    var msg = String("")
    try:
        _ = _run(
            String(_G) + "250 mail.test\r\n",
            SmtpSecurity.plaintext(),
            False,
            _creds(),
            w3,
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpAuth"), msg)
    # The refusal is raised, and the connection still ends with QUIT.
    assert_equal(_text(w3), "EHLO client.test\r\nQUIT\r\n")

    var w4 = _wire()
    var r4 = _run(
        String(_G) + _EHLO + _TXN,
        SmtpSecurity.plaintext(),
        False,
        None,
        w4,
    )
    assert_true(r4.is_accepted())
    assert_equal(_text(w4), "EHLO client.test\r\n" + String(_TXN_WIRE))


def test_envelope_checked_first() raises:
    var wire = _wire()
    var cfg = _config(SmtpSecurity.plaintext())
    var s = ScriptedStream.from_read_script_with_capture(
        _b(String(_G) + _EHLO), wire
    )
    var session = _Sess.new(s^, NoWaitHook(), cfg, False)
    var bad = List[String]()
    bad.append(String("not an address"))
    var msg = String("")
    try:
        _ = send_via_session(
            session^,
            cfg,
            None,
            String("a@sender.test"),
            bad,
            Span(_b(_MSG)),
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpEnvelope"), msg)
    assert_equal(_text(wire), "")


def main() raises:
    # Every case runs; the failures are reported together.
    var failed = String("")
    try:
        test_plaintext_full_transcript()
    except e:
        failed += "\n  test_plaintext_full_transcript: " + String(e)
    try:
        test_implicit_tls()
    except e:
        failed += "\n  test_implicit_tls: " + String(e)
    try:
        test_starttls_on_secure_stream()
    except e:
        failed += "\n  test_starttls_on_secure_stream: " + String(e)
    try:
        test_starttls_not_offered()
    except e:
        failed += "\n  test_starttls_not_offered: " + String(e)
    try:
        test_starttls_refused()
    except e:
        failed += "\n  test_starttls_refused: " + String(e)
    try:
        test_greeting_and_ehlo_refusals()
    except e:
        failed += "\n  test_greeting_and_ehlo_refusals: " + String(e)
    try:
        test_auth_policy()
    except e:
        failed += "\n  test_auth_policy: " + String(e)
    try:
        test_envelope_checked_first()
    except e:
        failed += "\n  test_envelope_checked_first: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_policy: FAILED" + failed)
    print("test_policy: OK")
