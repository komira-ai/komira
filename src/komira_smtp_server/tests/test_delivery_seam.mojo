# The MailDelivery seam, against a recording fake. What each case catches:
# - the server asks `accept_recipient` once per RCPT (and never for a RCPT it
#   refused itself) and calls `deliver` once per DATA, in that order, with the
#   envelope sender, the accepted recipients in order and the message;
# - each RcptDecision code reaches the right reply, a refused recipient is not
#   in the transaction, and a code outside 400 to 599 is never a success;
# - each DeliveryResult code reaches the right reply; only 250 counts as an
#   accepted message and any other code is 451 or an error, never a 250;
# - text from a delivery cannot put a second line in a reply;
# - a 451 from `deliver` leaves a clean transaction: the next message goes
#   through with none of the first one's recipients or text;
# - a refused recipient does not stop the transaction for the others, and a
#   transaction with only refused recipients cannot DATA;
# - `deliver` is not called for a message that was too big, or cut by a bare LF;
# - a closed relay is the delivery's decision and works end to end: a delivery
#   that only takes local recipients from the world and any recipient from an
#   authenticated submission session sees, in `accept_recipient`, the listener,
#   the verified user and TLS state of the connection, and its 554 reaches the
#   wire (a core that dropped the session fields, or ignored a refusal, opens
#   the relay).

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_encode
from komira_mail_auth import TestAuthVerifier
from komira_smtp_server import (
    DeliveryResult,
    MailDelivery,
    RcptDecision,
    SMTP_STATE_MAIL,
    SMTP_STATE_RCPT,
    SMTP_STATE_READY,
    SessionInfo,
    SmtpRegistry,
    SmtpServerConfig,
    SmtpTestSession,
)


def _ready() -> SmtpTestSession:
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test")))
    _ = s.send(String("EHLO c.test\r\n"))
    return s^


def _count(s: String, needle: String) -> Int:
    var n = 0
    var at = s.find(needle, 0)
    while at >= 0:
        n += 1
        at = s.find(needle, at + 1)
    return n


def test_one_accept_per_rcpt_and_one_deliver_per_data() raises:
    var s = _ready()
    _ = s.send(String("MAIL FROM:<Sender@X.test>\r\n"))
    _ = s.send(String("RCPT TO:<a@y.test>\r\nRCPT TO:<b@y.test>\r\nRCPT TO:<c@y.test>\r\n"))
    assert_equal(len(s.delivery.calls), 3)
    assert_equal(s.delivery.delivery_count, 0)
    _ = s.send(String("DATA\r\nline\r\n.\r\n"))
    assert_equal(len(s.delivery.calls), 4)
    assert_equal(s.delivery.calls[0], "rcpt:a@y.test")
    assert_equal(s.delivery.calls[1], "rcpt:b@y.test")
    assert_equal(s.delivery.calls[2], "rcpt:c@y.test")
    assert_equal(s.delivery.calls[3], "deliver")
    assert_equal(s.delivery.delivery_count, 1)
    assert_equal(s.delivery.message_from[0], "Sender@x.test")
    assert_equal(len(s.delivery.message_recipients[0]), 3)
    assert_equal(s.delivery.message_recipients[0][0], "a@y.test")
    assert_equal(s.delivery.message_recipients[0][2], "c@y.test")
    assert_equal(s.delivery.message_text(0), "line\r\n")
    # The sender the delivery was asked about is the one given to MAIL.
    assert_equal(s.delivery.rcpt_mail_from[1], "Sender@x.test")
    # A second message is a second call.
    _ = s.send(String("MAIL FROM:<a@x.test>\r\nRCPT TO:<d@y.test>\r\nDATA\r\nm2\r\n.\r\n"))
    assert_equal(s.delivery.delivery_count, 2)
    assert_equal(s.reg.messages_accepted_of(s.conn_id), 2)
    # A syntax error is not shown to the delivery.
    var before = len(s.delivery.calls)
    _ = s.send(String("MAIL FROM:<a@x.test>\r\nRCPT TO:<bad>\r\n"))
    assert_equal(len(s.delivery.calls), before)


def test_every_rcpt_code_reaches_the_reply() raises:
    var s = _ready()
    s.delivery.refuse_rcpt(String("a@y.test"), 550, String("5.1.1 No such user"))
    s.delivery.refuse_rcpt(String("b@y.test"), 450, String("4.2.0 Mailbox busy"))
    s.delivery.refuse_rcpt(String("c@y.test"), 530, String("5.7.1 Relaying denied"))
    s.delivery.refuse_rcpt(String("d@y.test"), 550, String(""))
    s.delivery.refuse_rcpt(String("e@y.test"), 450, String(""))
    s.delivery.refuse_rcpt(String("f@y.test"), 250, String("fine"))
    s.delivery.refuse_rcpt(String("g@y.test"), 354, String("go on"))
    s.delivery.refuse_rcpt(String("h@y.test"), 700, String("odd"))
    s.delivery.refuse_rcpt(String("i@y.test"), 200, String("odd"))
    _ = s.send(String("MAIL FROM:<s@x.test>\r\n"))
    assert_equal(
        s.send(String("RCPT TO:<a@y.test>\r\n")), "550 5.1.1 No such user\r\n"
    )
    assert_equal(
        s.send(String("RCPT TO:<b@y.test>\r\n")), "450 4.2.0 Mailbox busy\r\n"
    )
    assert_equal(
        s.send(String("RCPT TO:<c@y.test>\r\n")), "530 5.7.1 Relaying denied\r\n"
    )
    assert_equal(
        s.send(String("RCPT TO:<d@y.test>\r\n")), "550 5.1.1 Recipient refused\r\n"
    )
    assert_equal(
        s.send(String("RCPT TO:<e@y.test>\r\n")),
        "450 4.2.0 Recipient temporarily refused\r\n",
    )
    # 250 from the delivery is an accept.
    assert_equal(s.send(String("RCPT TO:<f@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    # A code that is not 400 to 599 is never taken as an accept.
    assert_equal(
        s.send(String("RCPT TO:<g@y.test>\r\n")),
        "451 4.3.0 Recipient check failed\r\n",
    )
    assert_equal(
        s.send(String("RCPT TO:<h@y.test>\r\n")),
        "451 4.3.0 Recipient check failed\r\n",
    )
    assert_equal(
        s.send(String("RCPT TO:<i@y.test>\r\n")),
        "451 4.3.0 Recipient check failed\r\n",
    )
    # Code 0, and a recipient the fake does not know, accept.
    assert_equal(s.send(String("RCPT TO:<z@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    # Only the two accepted are in the transaction.
    assert_equal(s.reg.recipient_count(s.conn_id), 2)
    _ = s.send(String("DATA\r\nx\r\n.\r\n"))
    assert_equal(s.delivery.message_recipients[0][0], "f@y.test")
    assert_equal(s.delivery.message_recipients[0][1], "z@y.test")


def test_refused_recipients_leave_the_transaction_usable() raises:
    var s = _ready()
    s.delivery.refuse_rcpt(String("a@y.test"), 550, String("5.1.1 No such user"))
    _ = s.send(String("MAIL FROM:<s@x.test>\r\n"))
    _ = s.send(String("RCPT TO:<a@y.test>\r\n"))
    # Only a refused recipient: nothing to send to.
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_MAIL)
    assert_true(s.send(String("DATA\r\n")).startswith("503"))
    # A good one after a refused one is fine, and the refused one is not in it.
    assert_equal(s.send(String("RCPT TO:<b@y.test>\r\n")), "250 2.1.5 Ok\r\n")
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_RCPT)
    _ = s.send(String("DATA\r\nx\r\n.\r\n"))
    assert_equal(len(s.delivery.message_recipients[0]), 1)
    assert_equal(s.delivery.message_recipients[0][0], "b@y.test")


def test_every_delivery_code_reaches_the_reply() raises:
    var cases_code = List[Int]()
    var cases_text = List[String]()
    var expected = List[String]()
    cases_code.append(250)
    cases_text.append(String("q42"))
    expected.append(String("250 2.0.0 Ok: queued as q42\r\n"))
    cases_code.append(250)
    cases_text.append(String(""))
    expected.append(String("250 2.0.0 Ok\r\n"))
    cases_code.append(451)
    cases_text.append(String("4.3.0 Disk trouble"))
    expected.append(String("451 4.3.0 Disk trouble\r\n"))
    cases_code.append(451)
    cases_text.append(String(""))
    expected.append(String("451 4.3.0 Temporary local problem, try later\r\n"))
    cases_code.append(554)
    cases_text.append(String("5.7.1 Refused by policy"))
    expected.append(String("554 5.7.1 Refused by policy\r\n"))
    cases_code.append(552)
    cases_text.append(String("5.3.4 Too big"))
    expected.append(String("552 5.3.4 Too big\r\n"))
    cases_code.append(554)
    cases_text.append(String(""))
    expected.append(String("554 5.3.0 Message refused\r\n"))
    # A code that is not 250 or 400 to 599 is a 451, never a success.
    var odd = List[Int]()
    odd.append(0)
    odd.append(200)
    odd.append(251)
    odd.append(354)
    odd.append(600)
    odd.append(-5)
    for i in range(len(odd)):
        cases_code.append(odd[i])
        cases_text.append(String("looks fine"))
        expected.append(String("451 4.3.0 Delivery returned an invalid result\r\n"))
    for i in range(len(cases_code)):
        var s = _ready()
        s.delivery.result_code = cases_code[i]
        s.delivery.result_text = cases_text[i]
        var r = s.send(
            String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n")
        )
        assert_true(r.endswith(expected[i]), "case " + String(i) + ": " + r)
        assert_equal(s.delivery.delivery_count, 1)
        var accepted = 1 if cases_code[i] == 250 else 0
        assert_equal(s.reg.messages_accepted_of(s.conn_id), accepted)
        assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)


def test_delivery_text_cannot_add_a_reply_line() raises:
    var s = _ready()
    s.delivery.refuse_rcpt(
        String("a@y.test"), 550, String("5.1.1 no\r\n250 2.1.5 forged")
    )
    _ = s.send(String("MAIL FROM:<s@x.test>\r\n"))
    var r = s.send(String("RCPT TO:<a@y.test>\r\n"))
    assert_equal(_count(r, "\r\n"), 1)
    assert_true(r.startswith("550 5.1.1 no"))
    var t = _ready()
    t.delivery.result_code = 451
    t.delivery.result_text = String("4.3.0 bad\r\n250 2.0.0 forged\nX")
    var d = t.send(
        String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n")
    )
    # MAIL, RCPT, 354 and the one 451 line: four lines.
    assert_equal(_count(d, "\r\n"), 4)
    assert_true(d.endswith("\r\n"))
    assert_true(d.find("\r\n451 4.3.0 bad") >= 0)
    # Long text is cut.
    var u = _ready()
    u.delivery.result_code = 554
    var long = String("")
    for _ in range(500):
        long += "w"
    u.delivery.result_text = long
    var l = u.send(
        String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nx\r\n.\r\n")
    )
    assert_true(l.byte_length() < 600)


def test_a_451_leaves_a_clean_transaction() raises:
    var s = _ready()
    s.delivery.result_code = 451
    s.delivery.result_text = String("4.3.0 Try later")
    _ = s.send(String("MAIL FROM:<first@x.test>\r\nRCPT TO:<one@y.test>\r\nDATA\r\nFIRST\r\n.\r\n"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.reg.recipient_count(s.conn_id), 0)
    assert_equal(s.reg.mail_from_of(s.conn_id), "")
    assert_equal(s.reg.data_len(s.conn_id), 0)
    assert_equal(s.reg.messages_accepted_of(s.conn_id), 0)
    # RCPT without MAIL is out of sequence: nothing is left over.
    assert_true(s.send(String("RCPT TO:<x@y.test>\r\n")).startswith("503"))
    # The client retries; this time the delivery works.
    s.delivery.result_code = 250
    s.delivery.result_text = String("q9")
    var r = s.send(String("MAIL FROM:<second@x.test>\r\nRCPT TO:<two@y.test>\r\nDATA\r\nSECOND\r\n.\r\n"))
    assert_true(r.endswith("250 2.0.0 Ok: queued as q9\r\n"))
    assert_equal(s.delivery.delivery_count, 2)
    assert_equal(s.delivery.message_text(1), "SECOND\r\n")
    assert_equal(s.delivery.message_from[1], "second@x.test")
    assert_equal(len(s.delivery.message_recipients[1]), 1)
    assert_equal(s.delivery.message_recipients[1][0], "two@y.test")


def test_deliver_is_not_called_without_a_complete_message() raises:
    var s = _ready()
    _ = s.send(String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nabc\n.\r\n"))
    assert_equal(s.delivery.delivery_count, 0)
    # Cut off mid-message: nothing is delivered.
    var t = _ready()
    _ = t.send(String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nabc\r\n"))
    assert_equal(t.delivery.delivery_count, 0)
    # Dropping the connection does not deliver either.
    _ = t.reg.drop(t.conn_id)
    assert_equal(t.delivery.delivery_count, 0)


struct RelayCheckingDelivery(MailDelivery):
    """A closed relay: `@local.test` from anyone, anything from an
    authenticated submission session, else 554 5.7.1."""

    var seen_submission: List[Bool]
    var seen_user: List[String]
    var seen_tls: List[Bool]
    var delivered: Int

    def __init__(out self):
        self.seen_submission = List[Bool]()
        self.seen_user = List[String]()
        self.seen_tls = List[Bool]()
        self.delivered = 0

    def accept_recipient(
        mut self, session: SessionInfo, mail_from: String, rcpt: String
    ) -> RcptDecision:
        self.seen_submission.append(session.submission)
        self.seen_user.append(session.authed_user)
        self.seen_tls.append(session.peer_tls)
        if rcpt.endswith("@local.test"):
            return RcptDecision(0, String(""))
        if session.submission and session.authed_user.byte_length() > 0:
            return RcptDecision(0, String(""))
        return RcptDecision(554, String("5.7.1 Relay access denied"))

    def deliver(
        mut self,
        session: SessionInfo,
        mail_from: String,
        recipients: List[String],
        message: Span[UInt8, _],
        now_ms: Int,
    ) -> DeliveryResult:
        self.delivered += 1
        return DeliveryResult(250, String(""))


def _run(
    mut reg: SmtpRegistry,
    id: Int,
    config: SmtpServerConfig,
    verifier: TestAuthVerifier,
    mut delivery: RelayCheckingDelivery,
    text: String,
) -> String:
    _ = reg.feed(id, text.as_bytes(), config, verifier, delivery, 1000)
    var all = String("")
    while reg.tx_len(id) > 0:
        var part = reg.tx_copy(id, 4096)
        all += String(unsafe_from_utf8=Span(part))
        reg.tx_consume(id, len(part))
    return all^


def test_closed_relay_end_to_end() raises:
    var verifier = TestAuthVerifier()
    verifier.add_user(String("alice"), String("s3cret"))
    # Port 25: no AUTH, no submission.
    var port25 = SmtpServerConfig(String("mx.test"))
    var reg = SmtpRegistry()
    var delivery = RelayCheckingDelivery()
    var id = reg.accept(Int32(5), port25, 1000).value()
    _ = _run(reg, id, port25, verifier, delivery, String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\n"))
    assert_equal(
        _run(reg, id, port25, verifier, delivery, String("RCPT TO:<u@local.test>\r\n")),
        "250 2.1.5 Ok\r\n",
    )
    assert_equal(
        _run(reg, id, port25, verifier, delivery, String("RCPT TO:<v@elsewhere.test>\r\n")),
        "554 5.7.1 Relay access denied\r\n",
    )
    assert_equal(len(delivery.seen_submission), 2)
    assert_false(delivery.seen_submission[1])
    assert_equal(delivery.seen_user[1], "")
    assert_false(delivery.seen_tls[1])
    # The refused recipient is not in the transaction: the one local one is.
    assert_equal(reg.recipient_count(id), 1)
    # A transaction with only a refused relay recipient cannot send DATA.
    var id2 = reg.accept(Int32(6), port25, 1000).value()
    _ = _run(reg, id2, port25, verifier, delivery, String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\nRCPT TO:<v@elsewhere.test>\r\n"))
    assert_true(
        _run(reg, id2, port25, verifier, delivery, String("DATA\r\n")).startswith("503")
    )
    assert_equal(delivery.delivered, 0)
    # Submission listener: the same recipient is fine once authenticated.
    var sub = SmtpServerConfig(String("mx.test"), submission=True)
    var id3 = reg.accept(Int32(7), sub, 1000).value()
    reg.mark_tls_active(id3)
    var plain = base64_encode(String("\0alice\0s3cret").as_bytes())
    _ = _run(reg, id3, sub, verifier, delivery, String("EHLO c.test\r\nAUTH PLAIN ") + plain + "\r\nMAIL FROM:<alice@x.test>\r\n")
    var before = len(delivery.seen_user)
    assert_equal(
        _run(reg, id3, sub, verifier, delivery, String("RCPT TO:<v@elsewhere.test>\r\n")),
        "250 2.1.5 Ok\r\n",
    )
    assert_true(delivery.seen_submission[before])
    assert_equal(delivery.seen_user[before], "alice")
    assert_true(delivery.seen_tls[before])
    # STARTTLS-style reset: the user is gone with the TLS state, and the relay
    # is closed again.
    reg.mark_tls_active(id3)
    _ = _run(reg, id3, sub, verifier, delivery, String("EHLO c.test\r\n"))
    assert_true(
        _run(reg, id3, sub, verifier, delivery, String("MAIL FROM:<a@x.test>\r\n")).startswith("530")
    )


def main() raises:
    test_one_accept_per_rcpt_and_one_deliver_per_data()
    test_every_rcpt_code_reaches_the_reply()
    test_refused_recipients_leave_the_transaction_usable()
    test_every_delivery_code_reaches_the_reply()
    test_delivery_text_cannot_add_a_reply_line()
    test_a_451_leaves_a_clean_transaction()
    test_deliver_is_not_called_without_a_complete_message()
    test_closed_relay_end_to_end()
    print("test_delivery_seam: OK")
