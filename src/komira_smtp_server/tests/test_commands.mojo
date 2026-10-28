# The command rules. What each case catches:
# - EHLO or HELO inside a transaction ends it like RSET and is answered 250
#   (the old answer was 503 with the recipients kept);
# - MAIL needs `FROM:` and RCPT needs `TO:`, with a bracketed path; the
#   keyword of the other command, a missing keyword and a bare address are 501;
# - STARTTLS matches the whole word: `STARTTLSxyz` is an unknown command and
#   `STARTTLS now` a syntax error;
# - VRFY, EXPN and HELP are answered 502;
# - EHLO advertises PIPELINING, 8BITMIME, SIZE n and ENHANCEDSTATUSCODES,
#   STARTTLS only on a clear channel with a certificate, and AUTH only on TLS;
# - MAIL FROM parameters: SIZE over the cap is 552 before any DATA, an unknown
#   parameter 555, a malformed or repeated one 501;
# - the recipient cap answers 452 and asks the delivery nothing;
# - addresses go through komira_mail_address: a bad one is 501, the domain
#   reaches the delivery in lower case, a quoted local part keeps its quotes;
# - out-of-sequence commands, an empty line, an unknown verb, RSET, NOOP, QUIT,
#   and the cap on commands in one transaction;
# - `RCPT TO:<postmaster>` without a domain is accepted (RFC 5321 section
#   4.5.1) in any case and reaches the delivery as `postmaster`, while another
#   name without a domain is still 501;
# - what MAIL declared reaches the delivery: the null sender `<>` as the empty
#   string, SIZE and BODY=8BITMIME, and a refused MAIL leaves nothing declared.

from std.testing import assert_equal, assert_false, assert_true

from komira_smtp_server import (
    SMTP_STATE_GREETED,
    SMTP_STATE_MAIL,
    SMTP_STATE_RCPT,
    SMTP_STATE_READY,
    SmtpLimits,
    SmtpServerConfig,
    SmtpTestSession,
)


def _session() -> SmtpTestSession:
    return SmtpTestSession(SmtpServerConfig(String("mx.test")))


def _ready() -> SmtpTestSession:
    var s = _session()
    _ = s.send(String("EHLO c.test\r\n"))
    return s^


def _has_line(reply: String, line: String) -> Bool:
    return ("\r\n" + reply).find("\r\n" + line + "\r\n") >= 0


def _cap(reply: String, name: String) -> Bool:
    """The EHLO reply advertises `name` (any line position)."""
    return _has_line(reply, String("250-") + name) or _has_line(
        reply, String("250 ") + name
    )


def test_ehlo_in_a_transaction_resets_it() raises:
    var s = _ready()
    assert_equal(s.send(String("MAIL FROM:<a@x.test>\r\n")), "250 2.1.0 Ok\r\n")
    assert_equal(s.send(String("RCPT TO:<b@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.reg.recipient_count(s.conn_id), 1)
    var r = s.send(String("EHLO again.test\r\n"))
    assert_true(r.startswith("250-mx.test greets you\r\n"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.reg.recipient_count(s.conn_id), 0)
    assert_equal(s.reg.mail_from_of(s.conn_id), "")
    # The old transaction is gone: RCPT is out of sequence, MAIL starts anew.
    assert_equal(
        s.send(String("RCPT TO:<c@y.test>\r\n")),
        "503 5.5.1 Bad sequence of commands (send MAIL first)\r\n",
    )
    assert_equal(s.send(String("MAIL FROM:<a2@x.test>\r\n")), "250 2.1.0 Ok\r\n")
    # HELO does the same, and answers with the name only.
    assert_equal(s.send(String("RCPT TO:<b@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.send(String("HELO c.test\r\n")), "250 mx.test\r\n")
    assert_equal(s.reg.recipient_count(s.conn_id), 0)
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)


def test_ehlo_needs_one_name() raises:
    var s = _session()
    assert_equal(
        s.send(String("EHLO\r\n")),
        "501 5.5.4 EHLO and HELO need one domain or address literal\r\n",
    )
    assert_true(s.send(String("EHLO a b\r\n")).startswith("501 5.5.4"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_GREETED)


def test_mail_and_rcpt_check_their_keywords() raises:
    var s = _ready()
    var bad_mail = List[String]()
    bad_mail.append(String("MAIL <a@x.test>\r\n"))
    bad_mail.append(String("MAIL TO:<a@x.test>\r\n"))
    bad_mail.append(String("MAIL SEND:<a@x.test>\r\n"))
    bad_mail.append(String("MAIL FROM:a@x.test\r\n"))
    bad_mail.append(String("MAIL\r\n"))
    bad_mail.append(String("MAIL FROM\r\n"))
    bad_mail.append(String("MAIL FROM :<a@x.test>\r\n"))
    bad_mail.append(String("MAIL FROM:<a@x.test>junk\r\n"))
    for i in range(len(bad_mail)):
        var r = s.send(bad_mail[i])
        assert_true(r.startswith("501 5.5.4 "))
        assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.send(String("mail from:<A@x.test>\r\n")), "250 2.1.0 Ok\r\n")
    assert_equal(s.reg.mail_from_of(s.conn_id), "A@x.test")
    var bad_rcpt = List[String]()
    bad_rcpt.append(String("RCPT FROM:<b@y.test>\r\n"))
    bad_rcpt.append(String("RCPT CC:<b@y.test>\r\n"))
    bad_rcpt.append(String("RCPT <b@y.test>\r\n"))
    bad_rcpt.append(String("RCPT TO:b@y.test\r\n"))
    bad_rcpt.append(String("RCPT\r\n"))
    for i in range(len(bad_rcpt)):
        assert_true(s.send(bad_rcpt[i]).startswith("501 5.5.4 "))
        assert_equal(s.reg.recipient_count(s.conn_id), 0)
    assert_equal(len(s.delivery.calls), 0)
    # Spaces after the colon are common in the wild and harmless.
    assert_equal(s.send(String("rcpt to: <b@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    # The null reverse path is a sender, not a recipient.
    var t = _ready()
    assert_equal(t.send(String("MAIL FROM:<>\r\n")), "250 2.1.0 Ok\r\n")
    assert_equal(t.reg.mail_from_of(t.conn_id), "")
    assert_equal(t.reg.state_of(t.conn_id), SMTP_STATE_MAIL)
    assert_true(t.send(String("RCPT TO:<>\r\n")).startswith("501 5.1.3"))


def test_starttls_is_an_exact_word() raises:
    var s = _ready()
    assert_equal(
        s.send(String("STARTTLSxyz\r\n")), "500 5.5.1 Command unrecognized\r\n"
    )
    assert_false(s.outcome.starttls)
    assert_true(s.send(String("STARTTLS now\r\n")).startswith("501 5.5.4"))
    assert_false(s.outcome.starttls)
    assert_equal(
        s.send(String("starttls\r\n")), "220 2.0.0 Ready to start TLS\r\n"
    )
    assert_true(s.outcome.starttls)
    # Without a certificate STARTTLS is not offered and not accepted.
    var config = SmtpServerConfig(String("mx.test"), offer_starttls=False)
    var t = SmtpTestSession(config^)
    var r = t.send(String("EHLO c.test\r\n"))
    assert_false(_cap(r, String("STARTTLS")))
    assert_equal(
        t.send(String("STARTTLS\r\n")), "502 5.5.1 STARTTLS not available\r\n"
    )


def test_vrfy_expn_help_are_502() raises:
    var s = _ready()
    var words = List[String]()
    words.append(String("VRFY postmaster\r\n"))
    words.append(String("vrfy\r\n"))
    words.append(String("EXPN list\r\n"))
    words.append(String("HELP\r\n"))
    words.append(String("HELP MAIL\r\n"))
    for i in range(len(words)):
        assert_equal(
            s.send(words[i]), "502 5.5.1 Command not implemented\r\n"
        )
    assert_false(s.outcome.closing)


def test_ehlo_advertises_what_is_supported() raises:
    var s = _session()
    var r = s.send(String("EHLO c.test\r\n"))
    assert_true(_cap(r, String("PIPELINING")))
    assert_true(_cap(r, String("8BITMIME")))
    assert_true(_cap(r, String("SIZE 10485760")))
    assert_true(_cap(r, String("STARTTLS")))
    assert_true(_cap(r, String("ENHANCEDSTATUSCODES")))
    # AUTH is not offered on a clear channel.
    assert_equal(r.find("AUTH"), -1)
    # The last line, and only the last, has the space after 250.
    var last = r.rfind("250 ")
    assert_equal(r.find("250 ", 0), last)
    assert_true(r.endswith("\r\n"))
    # On TLS: AUTH, no STARTTLS.
    s.reg.mark_tls_active(s.conn_id)
    var t = s.send(String("EHLO c.test\r\n"))
    assert_true(_cap(t, String("AUTH PLAIN LOGIN")))
    assert_equal(t.find("STARTTLS"), -1)
    assert_true(_cap(t, String("PIPELINING")))
    # The size is the configured cap.
    var limits = SmtpLimits()
    limits.max_message_bytes = 5000
    var u = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    assert_true(_cap(u.send(String("EHLO c.test\r\n")), String("SIZE 5000")))


def test_mail_parameters() raises:
    var limits = SmtpLimits()
    limits.max_message_bytes = 1000
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    _ = s.send(String("EHLO c.test\r\n"))
    # SIZE at the cap is fine; one over is refused early and starts nothing.
    assert_equal(
        s.send(String("MAIL FROM:<a@x.test> SIZE=1001\r\n")),
        "552 5.3.4 Message size exceeds fixed maximum\r\n",
    )
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.reg.mail_from_of(s.conn_id), "")
    assert_equal(
        s.send(String("MAIL FROM:<a@x.test> SIZE=1000\r\n")), "250 2.1.0 Ok\r\n"
    )
    _ = s.send(String("RSET\r\n"))
    # An unknown parameter is 555 and starts nothing.
    assert_true(s.send(String("MAIL FROM:<a@x.test> FOO=bar\r\n")).startswith("555 5.5.4"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_true(s.send(String("MAIL FROM:<a@x.test> SIZE=10 FOO\r\n")).startswith("555 5.5.4"))
    assert_true(s.send(String("MAIL FROM:<a@x.test> SMTPUTF8\r\n")).startswith("555 5.5.4"))
    # Malformed or repeated.
    assert_true(s.send(String("MAIL FROM:<a@x.test> SIZE=abc\r\n")).startswith("501 5.5.4"))
    assert_true(s.send(String("MAIL FROM:<a@x.test> SIZE=\r\n")).startswith("501 5.5.4"))
    assert_true(s.send(String("MAIL FROM:<a@x.test> SIZE=1 SIZE=2\r\n")).startswith("501 5.5.4"))
    assert_true(s.send(String("MAIL FROM:<a@x.test> SIZE=99999999999999999999\r\n")).startswith("501 5.5.4"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    # BODY is accepted for the two advertised values only.
    assert_equal(s.send(String("MAIL FROM:<a@x.test> BODY=8BITMIME size=5\r\n")), "250 2.1.0 Ok\r\n")
    _ = s.send(String("RSET\r\n"))
    assert_equal(s.send(String("MAIL FROM:<a@x.test> BODY=7BIT\r\n")), "250 2.1.0 Ok\r\n")
    _ = s.send(String("RSET\r\n"))
    assert_true(s.send(String("MAIL FROM:<a@x.test> BODY=BINARYMIME\r\n")).startswith("555 5.5.4"))
    # RCPT takes no parameters.
    _ = s.send(String("MAIL FROM:<a@x.test>\r\n"))
    assert_true(s.send(String("RCPT TO:<b@y.test> NOTIFY=NEVER\r\n")).startswith("555 5.5.4"))
    assert_equal(s.reg.recipient_count(s.conn_id), 0)


def test_recipient_cap_is_452() raises:
    var limits = SmtpLimits()
    limits.max_recipients = 3
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    _ = s.send(String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\n"))
    for i in range(3):
        assert_equal(
            s.send(String("RCPT TO:<r") + String(i) + "@y.test>\r\n"),
            "250 2.1.5 Ok\r\n",
        )
    assert_equal(
        s.send(String("RCPT TO:<r3@y.test>\r\n")),
        "452 4.5.3 Too many recipients\r\n",
    )
    assert_equal(s.reg.recipient_count(s.conn_id), 3)
    # The delivery was asked about three recipients, not four.
    assert_equal(len(s.delivery.rcpt_addresses), 3)
    # The transaction goes on with the three.
    var r = s.send(String("DATA\r\nx\r\n.\r\n"))
    assert_true(r.startswith("354 "))
    assert_equal(len(s.delivery.message_recipients[0]), 3)


def test_addresses_are_parsed() raises:
    var s = _ready()
    var bad = List[String]()
    bad.append(String("MAIL FROM:<a@>\r\n"))
    bad.append(String("MAIL FROM:<@x.test>\r\n"))
    bad.append(String("MAIL FROM:<a b@x.test>\r\n"))
    bad.append(String("MAIL FROM:<a@x.test\r\n"))
    bad.append(String("MAIL FROM:<a@@x.test>\r\n"))
    bad.append(String("MAIL FROM:<@r.test:a@x.test>\r\n"))
    for i in range(len(bad)):
        assert_true(
            s.send(bad[i]).startswith("501 "), "accepted: " + bad[i]
        )
        assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.send(String("MAIL FROM:<a@x.test>\r\n")), "250 2.1.0 Ok\r\n")
    assert_equal(
        s.send(String("RCPT TO:<>\r\n")),
        "501 5.1.3 Bad recipient address syntax\r\n",
    )
    assert_true(s.send(String("RCPT TO:<b@>\r\n")).startswith("501 5.1.3"))
    assert_true(s.send(String("RCPT TO:<b c@y.test>\r\n")).startswith("501 5.1.3"))
    assert_equal(s.reg.recipient_count(s.conn_id), 0)
    assert_equal(len(s.delivery.calls), 0)
    # The domain is lower case when the delivery sees it; the local part keeps
    # its case; a quoted local part keeps what needs quotes.
    assert_equal(s.send(String("RCPT TO:<Bob@EXAMPLE.Test>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.send(String("RCPT TO:<\"a b\"@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.delivery.rcpt_addresses[0], "Bob@example.test")
    assert_equal(s.delivery.rcpt_addresses[1], "\"a b\"@y.test")
    # A `>` inside the quoted local part does not end the path.
    assert_equal(s.send(String("RCPT TO:<\"a>b\"@y.test> \r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.delivery.rcpt_addresses[2], "\"a>b\"@y.test")


def test_sequence_and_simple_verbs() raises:
    var s = _session()
    # Nothing before EHLO.
    assert_equal(
        s.send(String("MAIL FROM:<a@x.test>\r\n")),
        "503 5.5.1 Bad sequence of commands\r\n",
    )
    assert_true(s.send(String("RCPT TO:<b@y.test>\r\n")).startswith("503"))
    assert_true(s.send(String("DATA\r\n")).startswith("503"))
    _ = s.send(String("EHLO c.test\r\n"))
    assert_true(s.send(String("RCPT TO:<b@y.test>\r\n")).startswith("503"))
    assert_true(s.send(String("DATA\r\n")).startswith("503"))
    _ = s.send(String("MAIL FROM:<a@x.test>\r\n"))
    # MAIL inside a transaction is nested.
    assert_true(s.send(String("MAIL FROM:<a@x.test>\r\n")).startswith("503"))
    # DATA needs a recipient.
    assert_true(s.send(String("DATA\r\n")).startswith("503"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_MAIL)
    _ = s.send(String("RCPT TO:<b@y.test>\r\n"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_RCPT)
    assert_true(s.send(String("DATA now\r\n")).startswith("501 5.5.4"))
    # RSET ends the transaction.
    assert_equal(s.send(String("RSET\r\n")), "250 2.0.0 Ok\r\n")
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.reg.recipient_count(s.conn_id), 0)
    assert_true(s.send(String("RSET now\r\n")).startswith("501 5.5.4"))
    assert_equal(s.send(String("NOOP ignored\r\n")), "250 2.0.0 Ok\r\n")
    assert_equal(
        s.send(String("FROB\r\n")), "500 5.5.1 Command unrecognized\r\n"
    )
    assert_equal(
        s.send(String("\r\n")), "500 5.5.2 Syntax error, command expected\r\n"
    )
    assert_equal(
        s.send(String(" NOOP\r\n")), "500 5.5.2 Syntax error, command expected\r\n"
    )
    assert_false(s.outcome.closing)
    assert_equal(
        s.send(String("quit\r\n")), "221 2.0.0 mx.test closing connection\r\n"
    )
    assert_true(s.outcome.closing)
    assert_true(s.reg.is_closing(s.conn_id))


def test_commands_in_one_transaction_are_capped() raises:
    var limits = SmtpLimits()
    limits.max_commands = 5
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    _ = s.send(String("EHLO c.test\r\n"))
    # EHLO started the count; five commands after it are allowed.
    for _ in range(5):
        assert_equal(s.send(String("NOOP\r\n")), "250 2.0.0 Ok\r\n")
    assert_equal(
        s.send(String("NOOP\r\n")), "421 4.7.0 Too many commands, closing\r\n"
    )
    assert_true(s.outcome.closing)
    # EHLO starts a new count.
    var t = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    for _ in range(3):
        _ = t.send(String("EHLO c.test\r\nNOOP\r\nNOOP\r\nNOOP\r\n"))
    assert_false(t.outcome.closing)


def test_postmaster_needs_no_domain() raises:
    var s = _ready()
    _ = s.send(String("MAIL FROM:<a@x.test>\r\n"))
    assert_equal(s.send(String("RCPT TO:<postmaster>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.send(String("RCPT TO:<PostMaster>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.delivery.rcpt_addresses[0], "postmaster")
    assert_equal(s.delivery.rcpt_addresses[1], "postmaster")
    assert_equal(s.reg.recipient_count(s.conn_id), 2)
    # Other names without a domain, and near misses, are still refused.
    assert_true(s.send(String("RCPT TO:<postmasters>\r\n")).startswith("501 5.1.3"))
    assert_true(s.send(String("RCPT TO:<postmaste>\r\n")).startswith("501 5.1.3"))
    assert_true(s.send(String("RCPT TO:<root>\r\n")).startswith("501 5.1.3"))
    assert_true(s.send(String("RCPT TO:<>\r\n")).startswith("501 5.1.3"))
    # With a domain it is the ordinary address.
    assert_equal(s.send(String("RCPT TO:<Postmaster@Y.test>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.delivery.rcpt_addresses[2], "Postmaster@y.test")
    # RCPT parameters are still refused after it.
    assert_true(s.send(String("RCPT TO:<postmaster> X=1\r\n")).startswith("555"))
    assert_equal(len(s.delivery.rcpt_addresses), 3)


def test_the_envelope_reaches_the_delivery() raises:
    var s = _ready()
    # The null sender is the empty string, and no SIZE or BODY is -1 / False.
    _ = s.send(String("MAIL FROM:<>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n"))
    assert_equal(s.delivery.rcpt_mail_from[0], "")
    assert_equal(s.delivery.message_from[0], "")
    assert_equal(s.delivery.rcpt_sizes[0], -1)
    assert_equal(s.delivery.message_sizes[0], -1)
    assert_false(s.delivery.message_8bit[0])
    # SIZE and BODY are passed on.
    _ = s.send(
        String("MAIL FROM:<a@x.test> SIZE=1234 BODY=8BITMIME\r\nRCPT TO:<b@y.test>\r\n")
        + "DATA\r\nx\r\n.\r\n"
    )
    assert_equal(s.delivery.rcpt_sizes[1], 1234)
    assert_equal(s.delivery.message_sizes[1], 1234)
    assert_true(s.delivery.message_8bit[1])
    # The next message starts clean, and so does one after a refused MAIL.
    _ = s.send(String("MAIL FROM:<a@x.test> BODY=7BIT\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n"))
    assert_equal(s.delivery.message_sizes[2], -1)
    assert_false(s.delivery.message_8bit[2])
    _ = s.send(String("MAIL FROM:<a@x.test> SIZE=77 BODY=8BITMIME\r\n"))
    _ = s.send(String("RSET\r\nMAIL FROM:<a@x.test> SIZE=99999999999 BODY=8BITMIME\r\n"))
    _ = s.send(String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n"))
    assert_equal(s.delivery.message_sizes[3], -1)
    assert_false(s.delivery.message_8bit[3])


def main() raises:
    test_ehlo_in_a_transaction_resets_it()
    test_ehlo_needs_one_name()
    test_mail_and_rcpt_check_their_keywords()
    test_starttls_is_an_exact_word()
    test_vrfy_expn_help_are_502()
    test_ehlo_advertises_what_is_supported()
    test_postmaster_needs_no_domain()
    test_the_envelope_reaches_the_delivery()
    test_mail_parameters()
    test_recipient_cap_is_452()
    test_addresses_are_parsed()
    test_sequence_and_simple_verbs()
    test_commands_in_one_transaction_are_capped()
    print("test_commands: OK")
