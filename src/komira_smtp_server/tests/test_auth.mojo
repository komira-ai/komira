# SMTP AUTH. What each case catches:
# - AUTH on a clear channel is 538 and verifies nothing;
# - PLAIN (inline, after an empty 334, and `=`) and LOGIN (three exchanges,
#   with and without an initial response) verify through the verifier, set the
#   user, and the delivery sees that user (and only after a verified AUTH);
# - a wrong password or a malformed payload is refused and sets no user;
# - failed attempts are capped per connection: the attempt that reaches the cap
#   is answered 421 and closes (an unlimited guess count), while a cancelled
#   exchange does not count;
# - a second AUTH after success is 503, AUTH inside a transaction or before
#   EHLO is 503, an unknown mechanism 504, none 501;
# - a continuation line is capped at 12288 bytes: one more byte is 500 5.5.6
#   and closes;
# - a submission listener refuses MAIL with 530 until TLS and AUTH, a port-25
#   listener does not;
# - a user name with a control character (CR, LF, NUL, DEL) is refused 535
#   before the verifier is asked, even when the verifier knows it, and counts
#   as a failure (a name that can inject a header line when a delivery writes
#   it into a trace header); a mechanism name that is not text is 504;
# - a refused MAIL (530) starts no transaction: no sender is kept;
# - the delivery is told the listener, peer, EHLO name and connection in both
#   calls on a submission listener with AUTH;
# - with TLS not required AUTH works in the clear and is advertised.

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_encode
from komira_smtp_server import (
    SMTP_STATE_READY,
    SmtpLimits,
    SmtpServerConfig,
    SmtpTestSession,
)


def _b64(s: String) -> String:
    return base64_encode(s.as_bytes())


def _tls_session(var config: SmtpServerConfig) -> SmtpTestSession:
    var s = SmtpTestSession(config^)
    s.verifier.add_user(String("alice"), String("s3cret"))
    s.reg.mark_tls_active(s.conn_id)
    _ = s.send(String("EHLO c.test\r\n"))
    return s^


def _plain_cfg() -> SmtpServerConfig:
    return SmtpServerConfig(String("mx.test"))


def _many_attempts_cfg() -> SmtpServerConfig:
    var limits = SmtpLimits()
    limits.max_auth_failures = 100
    return SmtpServerConfig(String("mx.test"), limits=limits)


def _good_plain() -> String:
    return _b64(String("\0alice\0s3cret"))


def test_auth_needs_tls() raises:
    var s = SmtpTestSession(_plain_cfg())
    s.verifier.add_user(String("alice"), String("s3cret"))
    _ = s.send(String("EHLO c.test\r\n"))
    assert_equal(
        s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"),
        "538 5.7.11 Encryption required for requested authentication mechanism\r\n",
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "")
    assert_true(s.send(String("AUTH LOGIN\r\n")).startswith("538"))
    assert_false(s.outcome.closing)


def test_plain_inline_sets_the_user() raises:
    var s = _tls_session(_plain_cfg())
    assert_equal(
        s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"),
        "235 2.7.0 Authentication successful\r\n",
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "alice")
    # The delivery sees the user from MAIL on.
    _ = s.send(String("MAIL FROM:<alice@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n"))
    assert_equal(s.delivery.rcpt_users[0], "alice")
    assert_equal(s.delivery.message_users[0], "alice")
    assert_true(s.delivery.message_tls[0])
    assert_true(s.delivery.rcpt_tls[0])
    # EHLO and RSET do not clear it (RFC 4954 section 4).
    _ = s.send(String("EHLO again.test\r\nRSET\r\n"))
    assert_equal(s.reg.authed_user_of(s.conn_id), "alice")


def test_plain_with_an_empty_challenge() raises:
    var s = _tls_session(_plain_cfg())
    assert_equal(s.send(String("AUTH PLAIN\r\n")), "334 \r\n")
    assert_equal(
        s.send(_good_plain() + "\r\n"), "235 2.7.0 Authentication successful\r\n"
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "alice")
    var t = _tls_session(_plain_cfg())
    assert_equal(t.send(String("auth plain =\r\n")), "334 \r\n")
    assert_equal(
        t.send(_good_plain() + "\r\n"), "235 2.7.0 Authentication successful\r\n"
    )


def test_login() raises:
    var s = _tls_session(_plain_cfg())
    assert_equal(s.send(String("AUTH LOGIN\r\n")), "334 VXNlcm5hbWU6\r\n")
    assert_equal(
        s.send(_b64(String("alice")) + "\r\n"), "334 UGFzc3dvcmQ6\r\n"
    )
    assert_equal(
        s.send(_b64(String("s3cret")) + "\r\n"),
        "235 2.7.0 Authentication successful\r\n",
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "alice")
    # With the username as an initial response.
    var t = _tls_session(_plain_cfg())
    assert_equal(
        t.send(String("AUTH LOGIN ") + _b64(String("alice")) + "\r\n"),
        "334 UGFzc3dvcmQ6\r\n",
    )
    assert_equal(
        t.send(_b64(String("s3cret")) + "\r\n"),
        "235 2.7.0 Authentication successful\r\n",
    )


def test_wrong_credentials_are_refused() raises:
    var s = _tls_session(_many_attempts_cfg())
    assert_equal(
        s.send(String("AUTH PLAIN ") + _b64(String("\0alice\0wrong")) + "\r\n"),
        "535 5.7.8 Authentication credentials invalid\r\n",
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "")
    assert_true(
        s.send(String("AUTH PLAIN ") + _b64(String("\0nobody\0s3cret")) + "\r\n").startswith("535")
    )
    # Malformed: not base64, a missing NUL, an authzid that differs.
    assert_true(s.send(String("AUTH PLAIN !!!!\r\n")).startswith("501 5.5.2"))
    assert_true(
        s.send(String("AUTH PLAIN ") + _b64(String("alice\0s3cret")) + "\r\n").startswith("501 5.5.2")
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "")
    assert_false(s.outcome.closing)
    # The failed LOGIN leaves no half-open exchange: the next line is a command.
    var t = _tls_session(_plain_cfg())
    _ = t.send(String("AUTH LOGIN\r\n"))
    _ = t.send(_b64(String("alice")) + "\r\n")
    assert_true(t.send(_b64(String("bad")) + "\r\n").startswith("535"))
    assert_equal(t.send(String("NOOP\r\n")), "250 2.0.0 Ok\r\n")
    # A good attempt still works afterwards.
    assert_equal(
        t.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"),
        "235 2.7.0 Authentication successful\r\n",
    )


def test_failed_attempts_are_capped() raises:
    var s = _tls_session(_plain_cfg())  # the default cap is 3
    var bad = String("AUTH PLAIN ") + _b64(String("\0alice\0wrong")) + "\r\n"
    assert_true(s.send(bad).startswith("535"))
    assert_true(s.send(bad).startswith("535"))
    assert_false(s.outcome.closing)
    assert_equal(
        s.send(bad), "421 4.7.0 Too many failed authentication attempts\r\n"
    )
    assert_true(s.outcome.closing)
    assert_true(s.reg.is_closing(s.conn_id))
    # The right password afterwards is not tried: the connection is closing.
    assert_equal(s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"), "")
    assert_equal(s.reg.authed_user_of(s.conn_id), "")
    # A correct attempt before the cap succeeds and a mix of mechanisms counts.
    var t = _tls_session(_plain_cfg())
    assert_true(t.send(bad).startswith("535"))
    _ = t.send(String("AUTH LOGIN\r\n"))
    _ = t.send(_b64(String("alice")) + "\r\n")
    assert_true(t.send(_b64(String("nope")) + "\r\n").startswith("535"))
    assert_true(t.send(String("AUTH PLAIN !!\r\n")).startswith("421"))
    assert_true(t.outcome.closing)


def test_cancelling_is_not_a_failure() raises:
    var s = _tls_session(_plain_cfg())
    for _ in range(6):
        assert_equal(s.send(String("AUTH LOGIN\r\n")), "334 VXNlcm5hbWU6\r\n")
        assert_equal(s.send(String("*\r\n")), "501 5.7.0 Authentication cancelled\r\n")
    assert_false(s.outcome.closing)
    assert_equal(
        s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"),
        "235 2.7.0 Authentication successful\r\n",
    )


def test_sequence_rules() raises:
    var s = _tls_session(_plain_cfg())
    _ = s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n")
    # A second AUTH after success.
    assert_equal(
        s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"),
        "503 5.5.1 Already authenticated\r\n",
    )
    assert_equal(s.reg.authed_user_of(s.conn_id), "alice")
    # Inside a transaction.
    var t = _tls_session(_plain_cfg())
    _ = t.send(String("MAIL FROM:<a@x.test>\r\n"))
    assert_true(t.send(String("AUTH PLAIN ") + _good_plain() + "\r\n").startswith("503"))
    assert_equal(t.reg.authed_user_of(t.conn_id), "")
    # Before EHLO.
    var u = SmtpTestSession(_plain_cfg())
    u.verifier.add_user(String("alice"), String("s3cret"))
    u.reg.mark_tls_active(u.conn_id)
    assert_true(u.send(String("AUTH PLAIN ") + _good_plain() + "\r\n").startswith("503"))
    # Mechanisms.
    var v = _tls_session(_plain_cfg())
    assert_equal(
        v.send(String("AUTH CRAM-MD5\r\n")),
        "504 5.5.4 Unrecognized authentication mechanism\r\n",
    )
    assert_true(v.send(String("AUTH\r\n")).startswith("501 5.5.4"))


def test_continuation_line_cap() raises:
    var s = _tls_session(_plain_cfg())
    _ = s.send(String("AUTH LOGIN\r\n"))
    var at_cap = String("")
    for _ in range(12288):
        at_cap += "A"
    # Exactly the cap is read as an answer (and refused as a payload).
    var r = s.send(at_cap + "\r\n")
    assert_true(r.startswith("501 5.5.2"))
    assert_false(s.outcome.closing)
    # One byte more ends the exchange and the connection.
    var t = _tls_session(_plain_cfg())
    _ = t.send(String("AUTH LOGIN\r\n"))
    assert_equal(
        t.send(at_cap + "A\r\n"),
        "500 5.5.6 Authentication exchange line is too long\r\n",
    )
    assert_true(t.outcome.closing)
    # The same bytes as a command are over the 512-byte command cap.
    var u = _tls_session(_plain_cfg())
    assert_equal(
        u.send(String("AUTH PLAIN ") + at_cap + "\r\n"), "500 5.5.2 Line too long\r\n"
    )


def test_submission_listener_needs_auth() raises:
    var config = SmtpServerConfig(String("mx.test"), submission=True)
    var s = SmtpTestSession(config.copy())
    s.verifier.add_user(String("alice"), String("s3cret"))
    _ = s.send(String("EHLO c.test\r\n"))
    assert_equal(
        s.send(String("MAIL FROM:<a@x.test>\r\n")),
        "530 5.7.0 Must issue a STARTTLS command first\r\n",
    )
    s.reg.mark_tls_active(s.conn_id)
    _ = s.send(String("EHLO c.test\r\n"))
    assert_equal(
        s.send(String("MAIL FROM:<a@x.test>\r\n")),
        "530 5.7.0 Authentication required\r\n",
    )
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    # The refused MAIL left nothing behind: no sender, and RCPT is out of order.
    assert_equal(s.reg.mail_from_of(s.conn_id), "")
    assert_true(s.send(String("RCPT TO:<b@y.test>\r\n")).startswith("503"))
    assert_equal(len(s.delivery.calls), 0)
    _ = s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n")
    assert_equal(s.send(String("MAIL FROM:<a@x.test>\r\n")), "250 2.1.0 Ok\r\n")
    # The delivery is told it is a submission session.
    _ = s.send(String("RCPT TO:<b@y.test>\r\n"))
    assert_true(s.delivery.rcpt_submission[0])
    _ = s.send(String("DATA\r\nx\r\n.\r\n"))
    assert_true(s.delivery.message_submission[0])
    assert_equal(s.delivery.rcpt_users[0], "alice")
    assert_equal(s.delivery.message_users[0], "alice")
    assert_equal(s.delivery.rcpt_peers[0], "192.0.2.1")
    assert_equal(s.delivery.message_peers[0], "192.0.2.1")
    assert_equal(s.delivery.rcpt_helos[0], "c.test")
    assert_equal(s.delivery.message_helos[0], "c.test")
    assert_equal(s.delivery.rcpt_conn_ids[0], s.conn_id)
    assert_equal(s.delivery.message_conn_ids[0], s.conn_id)
    # A port-25 listener takes mail without AUTH and without TLS.
    var port25 = SmtpTestSession(_plain_cfg())
    _ = port25.send(String("EHLO c.test\r\n"))
    assert_equal(port25.send(String("MAIL FROM:<a@x.test>\r\n")), "250 2.1.0 Ok\r\n")
    _ = port25.send(String("RCPT TO:<b@y.test>\r\n"))
    assert_false(port25.delivery.rcpt_submission[0])


def test_auth_in_the_clear_when_allowed() raises:
    var config = SmtpServerConfig(String("mx.test"), require_tls_for_auth=False)
    var s = SmtpTestSession(config^)
    s.verifier.add_user(String("alice"), String("s3cret"))
    var r = s.send(String("EHLO c.test\r\n"))
    assert_true(r.find("AUTH PLAIN LOGIN") >= 0)
    assert_equal(
        s.send(String("AUTH PLAIN ") + _good_plain() + "\r\n"),
        "235 2.7.0 Authentication successful\r\n",
    )
    assert_false(s.reg.tls_active_of(s.conn_id))


def test_control_characters_in_the_user_name_are_refused() raises:
    var names = List[String]()
    names.append(String("al\r\nice"))
    names.append(String("al\nice"))
    names.append(String("a\x7fb"))
    names.append(String("a\tb"))
    for i in range(len(names)):
        var s = _tls_session(_many_attempts_cfg())
        # The verifier knows this very name, so only the check can refuse it.
        s.verifier.add_user(names[i], String("s3cret"))
        var payload = _b64(String("\0") + names[i] + String("\0s3cret"))
        assert_equal(
            s.send(String("AUTH PLAIN ") + payload + "\r\n"),
            "535 5.7.8 Authentication credentials invalid\r\n",
        )
        assert_equal(s.reg.authed_user_of(s.conn_id), "")
        # LOGIN is checked the same way.
        _ = s.send(String("AUTH LOGIN\r\n"))
        _ = s.send(_b64(names[i]) + "\r\n")
        assert_true(s.send(_b64(String("s3cret")) + "\r\n").startswith("535"))
        assert_equal(s.reg.authed_user_of(s.conn_id), "")
    # The refusals count as failures.
    var t = _tls_session(_plain_cfg())
    t.verifier.add_user(String("a\nb"), String("s3cret"))
    var bad = String("AUTH PLAIN ") + _b64(String("\0a\nb\0s3cret")) + "\r\n"
    _ = t.send(bad)
    _ = t.send(bad)
    assert_true(t.send(bad).startswith("421"))
    assert_true(t.outcome.closing)
    # A printable name with a space or a non-ASCII letter is still fine.
    var u = _tls_session(_plain_cfg())
    u.verifier.add_user(String("josé m"), String("s3cret"))
    assert_true(
        u.send(String("AUTH PLAIN ") + _b64(String("\0josé m\0s3cret")) + "\r\n").startswith("235")
    )


def test_a_mechanism_that_is_not_text_is_unrecognized() raises:
    var s = _tls_session(_plain_cfg())
    var raw = List[UInt8]()
    raw.extend(String("AUTH ").as_bytes())
    raw.append(0xFF)
    raw.append(0xFE)
    raw.extend(String("\r\n").as_bytes())
    assert_equal(
        s.send_bytes(Span(raw)), "504 5.5.4 Unrecognized authentication mechanism\r\n"
    )
    assert_false(s.outcome.closing)
    # Mechanism names are case-insensitive.
    assert_equal(s.send(String("auth Plain\r\n")), "334 \r\n")


def main() raises:
    test_auth_needs_tls()
    test_plain_inline_sets_the_user()
    test_plain_with_an_empty_challenge()
    test_login()
    test_wrong_credentials_are_refused()
    test_failed_attempts_are_capped()
    test_cancelling_is_not_a_failure()
    test_sequence_rules()
    test_continuation_line_cap()
    test_submission_listener_needs_auth()
    test_auth_in_the_clear_when_allowed()
    test_control_characters_in_the_user_name_are_refused()
    test_a_mechanism_that_is_not_text_is_unrecognized()
    print("test_auth: OK")
