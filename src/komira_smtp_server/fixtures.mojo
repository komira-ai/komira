# Fixtures for testing an SMTP server and what feeds it: a delivery that
# records every call and answers as scripted, and a driver that feeds bytes
# to one connection and collects the replies. For tests and local use; no
# socket, no clock.

from komira_mail_auth import TestAuthVerifier

from .delivery import (
    DeliveryResult,
    MailDelivery,
    RcptDecision,
    SessionInfo,
)
from .limits import SmtpServerConfig
from .session import FeedOutcome, SmtpRegistry


struct RecordingDelivery(MailDelivery):
    """A `MailDelivery` that answers as scripted and records what it was asked.

    RCPT: an address listed with `refuse_rcpt` gets that code and text, any
    other is accepted. DATA: every `deliver` answers `result_code` and
    `result_text` (default 250 and `q1`). `calls` holds `rcpt:<address>` and
    `deliver` in the order they were made."""

    var calls: List[String]
    var rcpt_addresses: List[String]
    var rcpt_mail_from: List[String]
    var rcpt_users: List[String]
    var rcpt_tls: List[Bool]
    var rcpt_submission: List[Bool]
    var rcpt_peers: List[String]
    var rcpt_helos: List[String]
    var rcpt_conn_ids: List[Int]
    var rcpt_sizes: List[Int]
    var rule_address: List[String]
    var rule_code: List[Int]
    var rule_text: List[String]
    var result_code: Int
    var result_text: String
    var delivery_count: Int
    var messages: List[List[UInt8]]
    var message_from: List[String]
    var message_recipients: List[List[String]]
    var message_users: List[String]
    var message_tls: List[Bool]
    var message_peers: List[String]
    var message_helos: List[String]
    var message_submission: List[Bool]
    var message_conn_ids: List[Int]
    var message_sizes: List[Int]
    var message_8bit: List[Bool]
    var message_now: List[Int]

    def __init__(out self):
        self.calls = List[String]()
        self.rcpt_addresses = List[String]()
        self.rcpt_mail_from = List[String]()
        self.rcpt_users = List[String]()
        self.rcpt_tls = List[Bool]()
        self.rcpt_submission = List[Bool]()
        self.rcpt_peers = List[String]()
        self.rcpt_helos = List[String]()
        self.rcpt_conn_ids = List[Int]()
        self.rcpt_sizes = List[Int]()
        self.rule_address = List[String]()
        self.rule_code = List[Int]()
        self.rule_text = List[String]()
        self.result_code = 250
        self.result_text = String("q1")
        self.delivery_count = 0
        self.messages = List[List[UInt8]]()
        self.message_from = List[String]()
        self.message_recipients = List[List[String]]()
        self.message_users = List[String]()
        self.message_tls = List[Bool]()
        self.message_peers = List[String]()
        self.message_helos = List[String]()
        self.message_submission = List[Bool]()
        self.message_conn_ids = List[Int]()
        self.message_sizes = List[Int]()
        self.message_8bit = List[Bool]()
        self.message_now = List[Int]()

    def refuse_rcpt(mut self, address: String, code: Int, text: String):
        self.rule_address.append(address)
        self.rule_code.append(code)
        self.rule_text.append(text)

    def accept_recipient(
        mut self, session: SessionInfo, mail_from: String, rcpt: String
    ) -> RcptDecision:
        self.calls.append(String("rcpt:") + rcpt)
        self.rcpt_addresses.append(rcpt)
        self.rcpt_mail_from.append(mail_from)
        self.rcpt_users.append(session.authed_user)
        self.rcpt_tls.append(session.peer_tls)
        self.rcpt_submission.append(session.submission)
        self.rcpt_peers.append(session.peer)
        self.rcpt_helos.append(session.helo)
        self.rcpt_conn_ids.append(session.conn_id)
        self.rcpt_sizes.append(session.declared_size)
        for i in range(len(self.rule_address)):
            if self.rule_address[i] == rcpt:
                return RcptDecision(self.rule_code[i], self.rule_text[i])
        return RcptDecision(0, String(""))

    def deliver(
        mut self,
        session: SessionInfo,
        mail_from: String,
        recipients: List[String],
        message: Span[UInt8, _],
        now_ms: Int,
    ) -> DeliveryResult:
        self.calls.append(String("deliver"))
        self.delivery_count += 1
        var copy = List[UInt8]()
        copy.extend(message)
        self.messages.append(copy^)
        self.message_from.append(mail_from)
        self.message_recipients.append(recipients.copy())
        self.message_users.append(session.authed_user)
        self.message_tls.append(session.peer_tls)
        self.message_peers.append(session.peer)
        self.message_helos.append(session.helo)
        self.message_submission.append(session.submission)
        self.message_conn_ids.append(session.conn_id)
        self.message_sizes.append(session.declared_size)
        self.message_8bit.append(session.body_8bit)
        self.message_now.append(now_ms)
        return DeliveryResult(self.result_code, self.result_text)

    def message_text(self, index: Int) -> String:
        """Message `index` as a String (tests send ASCII)."""
        return String(unsafe_from_utf8=Span(self.messages[index]))


struct SmtpTestSession(Movable):
    """One connection of a registry, a `TestAuthVerifier`, a
    `RecordingDelivery` and a clock the test sets. `send` feeds a string and
    returns the replies that came back, `send_chunks` feeds it in pieces of
    the given size."""

    var reg: SmtpRegistry
    var config: SmtpServerConfig
    var verifier: TestAuthVerifier
    var delivery: RecordingDelivery
    var conn_id: Int
    var now_ms: Int
    var outcome: FeedOutcome
    var greeting: String

    def __init__(out self, var config: SmtpServerConfig):
        self.reg = SmtpRegistry()
        self.verifier = TestAuthVerifier()
        self.delivery = RecordingDelivery()
        self.now_ms = 1000
        self.outcome = FeedOutcome()
        var id = self.reg.accept(Int32(7), config, self.now_ms, String("192.0.2.1"))
        self.conn_id = id.value()
        self.config = config^
        self.greeting = String("")
        var first = self.take_replies()
        self.greeting = first^

    def take_replies(mut self) -> String:
        """Every reply byte queued so far; the queue is emptied."""
        var all = String("")
        while self.reg.tx_len(self.conn_id) > 0:
            var part = self.reg.tx_copy(self.conn_id, 4096)
            all += String(unsafe_from_utf8=Span(part))
            self.reg.tx_consume(self.conn_id, len(part))
        return all^

    def send_bytes(mut self, data: Span[UInt8, _]) -> String:
        self.outcome = self.reg.feed(
            self.conn_id,
            data,
            self.config,
            self.verifier,
            self.delivery,
            self.now_ms,
        )
        return self.take_replies()

    def send(mut self, text: String) -> String:
        return self.send_bytes(text.as_bytes())

    def send_chunks(mut self, text: String, size: Int) -> String:
        var bytes = text.as_bytes()
        var all = String("")
        var pos = 0
        while pos < len(bytes):
            var end = pos + size
            if end > len(bytes):
                end = len(bytes)
            all += self.send_bytes(bytes[pos:end])
            pos = end
        return all^
