# The outcome of one message.

comptime SEND_ACCEPTED: Int = 0
"""The server accepted the message for at least one recipient (final 2xx)."""

comptime SEND_TRANSIENT: Int = 1
"""A 4xx reply ended the send: the same send may succeed later."""

comptime SEND_PERMANENT: Int = 2
"""A 5xx reply ended the send: retrying the same message will not help."""


def outcome_of_code(code: Int) -> Int:
    """`SEND_ACCEPTED` for 2xx, `SEND_TRANSIENT` for 4xx, else
    `SEND_PERMANENT`."""
    if code >= 200 and code < 300:
        return SEND_ACCEPTED
    if code >= 400 and code < 500:
        return SEND_TRANSIENT
    return SEND_PERMANENT


struct RecipientResult(Copyable, Movable):
    """The server's answer to one RCPT TO."""

    var address: String
    var accepted: Bool
    var code: Int
    var text: String
    var enhanced: String

    def __init__(
        out self,
        var address: String,
        accepted: Bool,
        code: Int,
        var text: String,
        var enhanced: String,
    ):
        self.address = address^
        self.accepted = accepted
        self.code = code
        self.text = text^
        self.enhanced = enhanced^


struct SendResult(Copyable, Movable):
    """What came of one message.

    `outcome` is `SEND_ACCEPTED`, `SEND_TRANSIENT` or `SEND_PERMANENT`.
    `stage` names where it ended: `accepted` for success, else `greeting`,
    `ehlo`, `starttls`, `auth`, `rset`, `mail`, `rcpt` (no recipient was
    accepted), `data` (DATA was not answered 354) or `end-of-data` (the reply
    after the message). `code`, `text` and `enhanced` are the reply that decided
    it; on success that is the final 250, whose text is usually the server's
    queue id. `recipients` holds one entry per recipient, in order, when the
    envelope got that far (a message accepted for some recipients and refused
    for others is `SEND_ACCEPTED` with `accepted_count() < len(recipients)`).

    Failures that are not a server reply (a timeout, a broken connection, a
    refused TLS policy, a bad address) are raised as errors instead; see
    `error_is_retryable`."""

    var outcome: Int
    var stage: String
    var code: Int
    var text: String
    var enhanced: String
    var recipients: List[RecipientResult]

    def __init__(
        out self,
        outcome: Int,
        var stage: String,
        code: Int,
        var text: String,
        var enhanced: String,
        var recipients: List[RecipientResult],
    ):
        self.outcome = outcome
        self.stage = stage^
        self.code = code
        self.text = text^
        self.enhanced = enhanced^
        self.recipients = recipients^

    def is_accepted(self) -> Bool:
        return self.outcome == SEND_ACCEPTED

    def is_transient(self) -> Bool:
        return self.outcome == SEND_TRANSIENT

    def is_permanent(self) -> Bool:
        return self.outcome == SEND_PERMANENT

    def accepted_count(self) -> Int:
        """How many recipients the server accepted."""
        var n = 0
        for i in range(len(self.recipients)):
            if self.recipients[i].accepted:
                n += 1
        return n


def error_is_retryable(error_text: String) -> Bool:
    """Whether a raised error of this package is worth retrying later: a
    timeout (`SmtpTimeout`) or a broken or refused connection
    (`SmtpTransport`). `SmtpProtocol`, `SmtpSecurity`, `SmtpEnvelope`,
    `SmtpConfig` and `SmtpAuth` are not."""
    return error_text.startswith("SmtpTimeout") or error_text.startswith(
        "SmtpTransport"
    )
