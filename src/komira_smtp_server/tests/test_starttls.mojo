# STARTTLS from the server's side (the handshake is the serving loop's). What
# each case catches:
# - STARTTLS is answered 220, asks the loop to start TLS, and wipes what the
#   client said before: the EHLO name, the transaction and the verified user;
# - bytes the client sent after STARTTLS in the same write are reported as
#   pending and are not run as commands (a MAIL pipelined behind STARTTLS
#   would otherwise run in the clear: CVE-2011-0411), including a partial
#   line and bytes that arrive after the 220;
# - `mark_tls_active` marks the connection as TLS, requires a new EHLO and
#   drops anything still buffered;
# - STARTTLS before EHLO, inside a transaction, twice, or on a connection
#   that is on TLS is 503;
# - a new connection starts with no verified user.

from std.testing import assert_equal, assert_false, assert_true

from komira_smtp_server import (
    SMTP_STATE_GREETED,
    SMTP_STATE_MAIL,
    SmtpServerConfig,
    SmtpTestSession,
)


def _ready() -> SmtpTestSession:
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test")))
    _ = s.send(String("EHLO c.test\r\n"))
    return s^


def test_starttls_asks_for_tls() raises:
    var s = _ready()
    assert_equal(
        s.send(String("STARTTLS\r\n")), "220 2.0.0 Ready to start TLS\r\n"
    )
    assert_true(s.outcome.starttls)
    assert_false(s.outcome.closing)
    assert_equal(s.outcome.pending_after_starttls, 0)
    assert_equal(s.reg.pending_rx_bytes(s.conn_id), 0)
    assert_false(s.reg.tls_active_of(s.conn_id))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_GREETED)
    s.reg.mark_tls_active(s.conn_id)
    assert_true(s.reg.tls_active_of(s.conn_id))
    # The client starts over with EHLO.
    assert_true(s.send(String("MAIL FROM:<a@x.test>\r\n")).startswith("503"))
    assert_true(s.send(String("EHLO c.test\r\n")).startswith("250-"))


def test_pipelined_commands_after_starttls_are_pending() raises:
    var s = _ready()
    var r = s.send(String("STARTTLS\r\nMAIL FROM:<a@x.test>\r\n"))
    # Only the 220 was written; the MAIL did not run.
    assert_equal(r, "220 2.0.0 Ready to start TLS\r\n")
    assert_true(s.outcome.starttls)
    assert_equal(s.outcome.pending_after_starttls, 22)
    assert_equal(s.reg.mail_from_of(s.conn_id), "")
    assert_equal(len(s.delivery.calls), 0)
    # A partial line behind it counts too.
    var t = _ready()
    _ = t.send(String("STARTTLS\r\nMA"))
    assert_equal(t.outcome.pending_after_starttls, 2)
    # Bytes that arrive after the 220 and before the handshake are pending.
    var u = _ready()
    _ = u.send(String("STARTTLS\r\n"))
    assert_equal(u.outcome.pending_after_starttls, 0)
    var later = u.send(String("NOOP\r\n"))
    assert_equal(later, "")
    assert_equal(u.outcome.pending_after_starttls, 6)
    assert_equal(u.reg.state_of(u.conn_id), SMTP_STATE_GREETED)
    # Across several chunks too.
    var v = _ready()
    _ = v.send_chunks(String("STARTTLS\r\nNOOP\r\nRSET\r\n"), 3)
    assert_true(v.outcome.pending_after_starttls > 0)
    assert_equal(v.reg.tx_len(v.conn_id), 0)


def test_mark_tls_active_drops_buffered_bytes() raises:
    var s = _ready()
    _ = s.send(String("STARTTLS\r\nNOOP"))
    assert_equal(s.reg.pending_rx_bytes(s.conn_id), 4)
    s.reg.mark_tls_active(s.conn_id)
    assert_equal(s.reg.pending_rx_bytes(s.conn_id), 0)
    # What follows is read as a new stream: the next line is a clean line.
    assert_equal(s.send(String("NOOP\r\n")), "250 2.0.0 Ok\r\n")


def test_starttls_clears_what_came_before() raises:
    var config = SmtpServerConfig(String("mx.test"), require_tls_for_auth=False)
    var s = SmtpTestSession(config^)
    s.verifier.add_user(String("alice"), String("s3cret"))
    _ = s.send(String("EHLO c.test\r\n"))
    var auth = String("AUTH PLAIN ") + "AGFsaWNlAHMzY3JldA==" + "\r\n"
    assert_equal(s.send(auth), "235 2.7.0 Authentication successful\r\n")
    assert_equal(s.reg.authed_user_of(s.conn_id), "alice")
    _ = s.send(String("STARTTLS\r\n"))
    assert_equal(s.reg.authed_user_of(s.conn_id), "")
    s.reg.mark_tls_active(s.conn_id)
    assert_equal(s.reg.authed_user_of(s.conn_id), "")
    # The delivery is told there is no user.
    _ = s.send(String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\n"))
    assert_equal(s.delivery.rcpt_users[0], "")
    assert_true(s.delivery.rcpt_tls[0])
    # The transaction in progress is dropped too.
    var t = SmtpTestSession(SmtpServerConfig(String("mx.test")))
    _ = t.send(String("EHLO c.test\r\n"))
    _ = t.send(String("STARTTLS\r\n"))
    t.reg.mark_tls_active(t.conn_id)
    assert_equal(t.reg.recipient_count(t.conn_id), 0)
    # A new connection has no user.
    var id = s.reg.accept(Int32(3), s.config, 1000)
    assert_equal(s.reg.authed_user_of(id.value()), "")


def test_starttls_in_the_wrong_place() raises:
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test")))
    assert_equal(
        s.send(String("STARTTLS\r\n")),
        "503 5.5.1 Bad sequence of commands (send EHLO first)\r\n",
    )
    assert_false(s.outcome.starttls)
    _ = s.send(String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\n"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_MAIL)
    assert_true(s.send(String("STARTTLS\r\n")).startswith("503"))
    assert_false(s.outcome.starttls)
    # On TLS already.
    var t = SmtpTestSession(SmtpServerConfig(String("mx.test")))
    t.reg.mark_tls_active(t.conn_id)
    _ = t.send(String("EHLO c.test\r\n"))
    assert_equal(t.send(String("STARTTLS\r\n")), "503 5.5.1 TLS already active\r\n")
    assert_false(t.outcome.starttls)


def main() raises:
    test_starttls_asks_for_tls()
    test_pipelined_commands_after_starttls_are_pending()
    test_mark_tls_active_drops_buffered_bytes()
    test_starttls_clears_what_came_before()
    test_starttls_in_the_wrong_place()
    print("test_starttls: OK")
