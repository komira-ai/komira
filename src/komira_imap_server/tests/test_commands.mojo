# The connection-level commands, without a socket. What each case catches:
# - CAPABILITY and the greeting: STARTTLS only on a clear channel with a
#   certificate, LOGINDISABLED only while LOGIN needs TLS and the channel is
#   clear, neither once TLS is active (a server that advertises STARTTLS it
#   cannot do, or hides LOGINDISABLED, fails);
# - LOGIN on a clear connection that needs TLS is `NO [PRIVACYREQUIRED]` even
#   with the right password, does not count as a failed attempt, and leaves
#   the connection logged out; on TLS it works (a server that lets a password
#   cross in the clear fails);
# - LOGIN arguments: atoms and quoted strings (with `\"` and `\\`), a password
#   with a space; anything else is BAD and is not a failed attempt;
# - failed LOGINs: `NO [AUTHENTICATIONFAILED]`; the one that reaches
#   `max_login_failures` is followed by `* BYE`, the connection closes and the
#   lines pipelined behind it do not run (a server that lets a peer guess
#   without end fails); a success does not need the verifier to be asked again;
# - the mailbox of a login: `normalize_recipient(user)`, no shared default; a
#   name that maps to no mailbox still logs in (SELECT then says no);
# - LOGIN twice is BAD; commands that need a login are `NO` before it, and a
#   command that needs a selected folder is `NO` without one;
# - LOGOUT and NOOP;
# - STARTTLS: accepted once, before LOGIN, on a clear channel with a
#   certificate; the lines pipelined behind it are reported as pending and never
#   answered; arriving bytes while the handshake is owed are all pending; when
#   TLS starts the user, the selection and the buffer are gone.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_store import normalize_recipient
from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import (
    IMAP_STATE_AUTH,
    IMAP_STATE_NOTAUTH,
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
)


def _server(
    require_tls: Bool = False,
    starttls: Bool = True,
    limits: ImapLimits = ImapLimits(),
) -> ImapTestServer[SharedInMemoryConditionalStore]:
    var config = ImapServerConfig(
        String("imap.test"), require_tls, starttls, limits.copy()
    )
    var s = ImapTestServer[SharedInMemoryConditionalStore](
        config^, SharedInMemoryConditionalStore()
    )
    s.add_user(String("alice@example.com"), String("s3cret"))
    s.add_user(String("bob"), String("pa ss\"word\\"))
    return s^


def test_the_greeting_and_capability_follow_the_channel() raises:
    # Default: LOGIN needs TLS and a certificate is configured.
    var s = _server(True, True)
    var id = s.connect()
    assert_equal(
        s.take(id),
        "* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] imap.test IMAP4rev1 ready\r\n",
    )
    assert_equal(
        s.send(id, String("a1 CAPABILITY\r\n")),
        "* CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED\r\na1 OK CAPABILITY completed\r\n",
    )
    # On TLS neither is advertised.
    s.reg.mark_tls_active(id)
    assert_equal(
        s.send(id, String("a2 CAPABILITY\r\n")),
        "* CAPABILITY IMAP4rev1\r\na2 OK CAPABILITY completed\r\n",
    )
    # LOGIN allowed on a clear channel: no LOGINDISABLED.
    var open = _server(False, True)
    var oid = open.connect()
    assert_equal(
        open.take(oid),
        "* OK [CAPABILITY IMAP4rev1 STARTTLS] imap.test IMAP4rev1 ready\r\n",
    )
    # No certificate: no STARTTLS.
    var bare = _server(True, False)
    var bid = bare.connect()
    assert_equal(
        bare.take(bid),
        "* OK [CAPABILITY IMAP4rev1 LOGINDISABLED] imap.test IMAP4rev1 ready\r\n",
    )
    var plain = _server(False, False)
    var pid = plain.connect()
    assert_equal(
        plain.take(pid), "* OK [CAPABILITY IMAP4rev1] imap.test IMAP4rev1 ready\r\n"
    )
    # CAPABILITY takes no argument.
    assert_equal(
        plain.send(pid, String("a1 CAPABILITY x\r\n")),
        "a1 BAD CAPABILITY takes no arguments\r\n",
    )


def test_login_on_a_clear_connection_is_refused_when_it_needs_tls() raises:
    var s = _server(True, True)
    var id = s.connect()
    _ = s.take(id)
    for _ in range(5):
        # The right password, five times: refused each time, never counted.
        assert_equal(
            s.send(id, String("a1 LOGIN alice@example.com s3cret\r\n")),
            "a1 NO [PRIVACYREQUIRED] LOGIN is disabled until STARTTLS\r\n",
        )
    assert_equal(s.reg.login_failures_of(id), 0)
    assert_equal(s.reg.state_of(id), IMAP_STATE_NOTAUTH)
    assert_equal(s.reg.username_of(id), "")
    assert_false(s.reg.is_closing(id))
    # On TLS the same line works.
    s.reg.mark_tls_active(id)
    assert_equal(
        s.send(id, String("a2 LOGIN alice@example.com s3cret\r\n")),
        "a2 OK [CAPABILITY IMAP4rev1] LOGIN completed\r\n",
    )
    assert_equal(s.reg.state_of(id), IMAP_STATE_AUTH)
    assert_equal(s.reg.username_of(id), "alice@example.com")


def test_login_arguments_are_atoms_or_quoted_strings() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    # Quoted user, an atom password.
    assert_equal(
        s.send(id, String('a1 LOGIN "alice@example.com" s3cret\r\n')),
        "a1 OK [CAPABILITY IMAP4rev1 STARTTLS] LOGIN completed\r\n",
    )
    # A fresh connection: a password with a space, a quote and a backslash.
    var other = s.connect()
    _ = s.take(other)
    assert_equal(
        s.send(other, String('b1 LOGIN bob "pa ss\\"word\\\\"\r\n')),
        "b1 OK [CAPABILITY IMAP4rev1 STARTTLS] LOGIN completed\r\n",
    )
    assert_equal(s.reg.username_of(other), "bob")
    # Malformed: BAD, not counted, still logged out.
    var bad = List[String]()
    bad.append(String("c1 LOGIN\r\n"))
    bad.append(String("c1 LOGIN alice@example.com\r\n"))
    bad.append(String("c1 LOGIN alice@example.com s3cret extra\r\n"))
    bad.append(String('c1 LOGIN "alice@example.com s3cret\r\n'))
    bad.append(String('c1 LOGIN alice@example.com "s3cret\r\n'))
    bad.append(String('c1 LOGIN a"b s3cret\r\n'))
    bad.append(String("c1 LOGIN a(b s3cret\r\n"))
    bad.append(String("c1 LOGIN a\\b s3cret\r\n"))
    bad.append(String('c1 LOGIN "a\\xb" s3cret\r\n'))
    bad.append(String('c1 LOGIN "alice@example.com"s3cret\r\n'))
    var third = s.connect()
    _ = s.take(third)
    for i in range(len(bad)):
        assert_equal(
            s.send(third, bad[i]),
            "c1 BAD LOGIN takes a user name and a password\r\n",
        )
    assert_equal(s.reg.login_failures_of(third), 0)
    assert_equal(s.reg.state_of(third), IMAP_STATE_NOTAUTH)


def test_failed_logins_are_capped() raises:
    var limits = ImapLimits()
    limits.max_login_failures = 3
    var s = _server(False, True, limits.copy())
    var id = s.connect()
    _ = s.take(id)
    assert_equal(
        s.send(id, String("a1 LOGIN alice@example.com nope\r\n")),
        "a1 NO [AUTHENTICATIONFAILED] Authentication failed\r\n",
    )
    assert_equal(
        s.send(id, String("a2 LOGIN nobody@example.com s3cret\r\n")),
        "a2 NO [AUTHENTICATIONFAILED] Authentication failed\r\n",
    )
    assert_equal(s.reg.login_failures_of(id), 2)
    assert_false(s.reg.is_closing(id))
    # The third failure ends the connection; the good attempt pipelined behind
    # it does not run.
    var r = s.send(
        id,
        String(
            "a3 LOGIN alice@example.com nope\r\na4 LOGIN alice@example.com"
            " s3cret\r\n"
        ),
    )
    assert_equal(
        r,
        "a3 NO [AUTHENTICATIONFAILED] Authentication failed\r\n"
        "* BYE Too many failed login attempts\r\n",
    )
    assert_true(s.reg.is_closing(id))
    assert_equal(s.reg.username_of(id), "")
    # A success first, with failures before it below the cap, logs in.
    var t = _server(False, True, limits.copy())
    var tid = t.connect()
    _ = t.take(tid)
    _ = t.send(tid, String("a1 LOGIN alice@example.com nope\r\n"))
    assert_true(t.send(tid, String("a2 LOGIN alice@example.com s3cret\r\n")).startswith("a2 OK"))
    assert_false(t.reg.is_closing(tid))


def test_the_mailbox_of_a_login() raises:
    var s = _server()
    s.add_user(String("Carol@Example.COM"), String("pw"))
    var long_name = String("n") * 200 + "@example.com"
    s.add_user(long_name, String("pw"))
    var a = s.connect()
    _ = s.login(a, String("alice@example.com"), String("s3cret"))
    assert_equal(s.reg.mailbox_of(a), "alice@example.com")
    var c = s.connect()
    _ = s.login(c, String("Carol@Example.COM"), String("pw"))
    # The store folds the case of an address, so this is carol's one mailbox.
    assert_equal(s.reg.mailbox_of(c), "Carol@Example.COM")
    assert_equal(
        normalize_recipient(s.reg.mailbox_of(c)),
        normalize_recipient(String("carol@example.com")),
    )
    # A bare name has its own mailbox of that name, never a shared default.
    var b = s.connect()
    _ = s.login(b, String("bob"), String('"pa ss\\"word\\\\"'))
    assert_equal(s.reg.mailbox_of(b), "bob")
    # A name too long to be a mailbox logs in, and has none.
    var l = s.connect()
    var r = s.login(l, long_name, String("pw"))
    assert_true(r.startswith("l1 OK"), r)
    assert_equal(s.reg.mailbox_of(l), "")


def test_login_twice_and_commands_out_of_state() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    # Before LOGIN.
    assert_equal(s.send(id, String("a1 SELECT INBOX\r\n")), "a1 NO Log in first\r\n")
    assert_equal(s.send(id, String("a2 LIST \"\" \"*\"\r\n")), "a2 NO Log in first\r\n")
    assert_equal(s.send(id, String("a3 FETCH 1 FLAGS\r\n")), "a3 NO Log in first\r\n")
    assert_equal(s.send(id, String("a4 CLOSE\r\n")), "a4 NO Log in first\r\n")
    _ = s.send(id, String("a5 LOGIN alice@example.com s3cret\r\n"))
    # Logged in, nothing selected.
    assert_equal(
        s.send(id, String("a6 LOGIN alice@example.com s3cret\r\n")),
        "a6 BAD Already logged in\r\n",
    )
    assert_equal(s.send(id, String("a7 FETCH 1 FLAGS\r\n")), "a7 NO No mailbox is selected\r\n")
    assert_equal(s.send(id, String("a8 STORE 1 +FLAGS (\\Seen)\r\n")), "a8 NO No mailbox is selected\r\n")
    assert_equal(s.send(id, String("a9 EXPUNGE\r\n")), "a9 NO No mailbox is selected\r\n")
    assert_equal(s.send(id, String("b1 CLOSE\r\n")), "b1 NO No mailbox is selected\r\n")
    assert_equal(s.send(id, String("b2 UID FETCH 1 FLAGS\r\n")), "b2 NO No mailbox is selected\r\n")
    assert_false(s.reg.is_closing(id))


def test_logout_and_noop() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    assert_equal(s.send(id, String("a1 NOOP\r\n")), "a1 OK NOOP completed\r\n")
    assert_equal(
        s.send(id, String("a2 LOGOUT\r\n")),
        "* BYE imap.test logging out\r\na2 OK LOGOUT completed\r\n",
    )
    assert_true(s.reg.is_closing(id))
    assert_true(s.outcome.closing)
    var t = _server()
    var tid = t.connect()
    _ = t.take(tid)
    assert_equal(
        t.send(tid, String("a1 LOGOUT now\r\n")),
        "a1 BAD LOGOUT takes no arguments\r\n",
    )
    assert_false(t.reg.is_closing(tid))


def test_starttls_rules() raises:
    var s = _server(True, True)
    var id = s.connect()
    _ = s.take(id)
    assert_equal(s.send(id, String("a1 STARTTLS now\r\n")), "a1 BAD STARTTLS takes no arguments\r\n")
    assert_false(s.outcome.starttls)
    assert_equal(s.send(id, String("a2 STARTTLS\r\n")), "a2 OK Begin TLS negotiation now\r\n")
    assert_true(s.outcome.starttls)
    assert_equal(s.outcome.pending_after_starttls, 0)
    assert_true(s.reg.starttls_pending_of(id))
    # TLS starts: pending is over, the connection is on TLS.
    s.reg.mark_tls_active(id)
    assert_false(s.reg.starttls_pending_of(id))
    assert_true(s.reg.tls_active_of(id))
    assert_equal(s.send(id, String("a3 STARTTLS\r\n")), "a3 NO TLS is already active\r\n")
    # After LOGIN it is too late.
    var t = _server(False, True)
    var tid = t.connect()
    _ = t.login(tid, String("alice@example.com"), String("s3cret"))
    assert_equal(
        t.send(tid, String("a1 STARTTLS\r\n")),
        "a1 BAD STARTTLS is only valid before LOGIN\r\n",
    )
    assert_false(t.outcome.starttls)
    # Not offered, not accepted.
    var u = _server(False, False)
    var uid = u.connect()
    _ = u.take(uid)
    assert_equal(
        u.send(uid, String("a1 STARTTLS\r\n")),
        "a1 NO [CANNOT] STARTTLS is not available\r\n",
    )
    assert_false(u.outcome.starttls)


def test_lines_pipelined_behind_starttls_never_run() raises:
    var s = _server(False, True)
    var id = s.connect()
    _ = s.take(id)
    var tail = String("a2 LOGIN alice@example.com s3cret\r\na3 NOOP\r\n")
    var r = s.send(id, String("a1 STARTTLS\r\n") + tail)
    # Only the OK of STARTTLS was answered; the rest is pending, not run.
    assert_equal(r, "a1 OK Begin TLS negotiation now\r\n")
    assert_true(s.outcome.starttls)
    assert_equal(s.outcome.pending_after_starttls, tail.byte_length())
    assert_equal(s.reg.username_of(id), "")
    # A later read while the handshake is owed is all pending too.
    var more = s.feed_bytes(id, String("a4 NOOP\r\n").as_bytes())
    assert_true(more.starttls)
    assert_equal(more.pending_after_starttls, 9 + tail.byte_length())
    assert_equal(s.take(id), "")


def test_tls_starts_the_session_over() raises:
    # Bytes that were pipelined behind STARTTLS in the clear are dropped when
    # TLS starts: the next line the server runs is the first one sent on TLS.
    var t = _server(False, True)
    var tid = t.connect()
    _ = t.take(tid)
    _ = t.send(tid, String("a1 STARTTLS\r\na2 BOGUS\r\n"))
    assert_true(t.reg.pending_rx_bytes(tid) > 0)
    t.reg.mark_tls_active(tid)
    assert_equal(t.reg.pending_rx_bytes(tid), 0)
    assert_equal(t.send(tid, String("a3 NOOP\r\n")), "a3 OK NOOP completed\r\n")
    assert_equal(t.reg.state_of(tid), IMAP_STATE_NOTAUTH)
    # A user that was logged in before TLS is logged out by it.
    var s = _server(False, True)
    var id = s.connect()
    _ = s.login(id, String("alice@example.com"), String("s3cret"))
    assert_equal(s.reg.state_of(id), IMAP_STATE_AUTH)
    s.reg.mark_tls_active(id)
    assert_equal(s.reg.username_of(id), "")
    assert_equal(s.reg.mailbox_of(id), "")
    assert_equal(s.reg.state_of(id), IMAP_STATE_NOTAUTH)


def main() raises:
    test_the_greeting_and_capability_follow_the_channel()
    test_login_on_a_clear_connection_is_refused_when_it_needs_tls()
    test_login_arguments_are_atoms_or_quoted_strings()
    test_failed_logins_are_capped()
    test_the_mailbox_of_a_login()
    test_login_twice_and_commands_out_of_state()
    test_logout_and_noop()
    test_starttls_rules()
    test_lines_pipelined_behind_starttls_never_run()
    test_tls_starts_the_session_over()
    print("test_commands: OK")
