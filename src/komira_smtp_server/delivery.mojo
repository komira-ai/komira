# The delivery seam: what the SMTP server asks of whatever receives mail.

comptime _MAX_TEXT_BYTES: Int = 200


struct SessionInfo(Copyable, Movable):
    """What a delivery may know about the connection a command came from.

    `authed_user` is the username of a verified AUTH, else empty; STARTTLS
    clears it. `peer` is the text the serving loop gave `SmtpRegistry.accept`
    (an address, for a trace header) and `helo` the name the client gave in
    EHLO or HELO (the client's claim, unverified)."""

    var peer_tls: Bool
    var authed_user: String
    var submission: Bool
    var peer: String
    var helo: String

    def __init__(
        out self,
        peer_tls: Bool = False,
        authed_user: String = "",
        submission: Bool = False,
        peer: String = "",
        helo: String = "",
    ):
        self.peer_tls = peer_tls
        self.authed_user = authed_user
        self.submission = submission
        self.peer = peer
        self.helo = helo


struct RcptDecision(Copyable, Movable):
    """The answer to one RCPT. `code` 0 (or 250) accepts the recipient. Any
    other code must be 400 to 599 (450, 550, 530 ...) and is the reply code
    with `text` as its text (an empty text gets a default). A code outside
    those ranges is answered 451."""

    var code: Int
    var text: String

    def __init__(out self, code: Int = 0, text: String = ""):
        self.code = code
        self.text = text


struct DeliveryResult(Copyable, Movable):
    """The answer to one finished DATA. Code 250 means the message is durable;
    `text` is then the queue id echoed to the client. 451 (try later), 554
    (refused) and 552 (too big) are the others; any other code is answered
    451, so an odd value never reads as success."""

    var code: Int
    var text: String

    def __init__(out self, code: Int = 250, text: String = ""):
        self.code = code
        self.text = text


trait MailDelivery(Movable):
    """Where accepted mail goes. The server never asks whether a destination
    is local: it asks `accept_recipient` per RCPT and calls `deliver` once per
    DATA, then maps the answers to replies.

    `deliver` cannot raise: an implementation catches its own errors and
    returns 451, so one storage failure cannot take down the connections that
    share the serving loop. It is all-or-nothing for one DATA: a transient
    failure for any recipient is 451 for the whole message. `message` is the
    dot-unstuffed message, every line ending in CRLF, borrowed for the call."""

    def accept_recipient(
        mut self, session: SessionInfo, mail_from: String, rcpt: String
    ) -> RcptDecision:
        ...

    def deliver(
        mut self,
        session: SessionInfo,
        mail_from: String,
        recipients: List[String],
        message: Span[UInt8, _],
        now_ms: Int,
    ) -> DeliveryResult:
        ...


def clean_reply_text(text: String, fallback: String) -> String:
    """`text` as it may appear in a reply line: printable ASCII only (every
    other byte, CR and LF included, becomes a space), at most 200 bytes, the
    `fallback` when nothing is left. A delivery's text can hold what a client
    sent, so it never reaches the wire unfiltered."""
    var out = List[UInt8]()
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > _MAX_TEXT_BYTES:
        n = _MAX_TEXT_BYTES
    var seen_graph = False
    for i in range(n):
        var c = bytes[i]
        if c >= 0x21 and c <= 0x7E:
            seen_graph = True
            out.append(c)
        else:
            out.append(UInt8(0x20))
    if not seen_graph:
        return fallback
    return String(unsafe_from_utf8=Span(out))


def rcpt_reply(decision: RcptDecision) -> String:
    """The reply line for a decision that is not an accept."""
    var code = decision.code
    if code < 400 or code > 599:
        return String("451 4.3.0 Recipient check failed\r\n")
    var fallback: String
    if code >= 500:
        fallback = String("5.1.1 Recipient refused")
    else:
        fallback = String("4.2.0 Recipient temporarily refused")
    return String(code) + " " + clean_reply_text(decision.text, fallback) + "\r\n"


def delivery_reply(result: DeliveryResult) -> String:
    """The reply line for a finished DATA."""
    var code = result.code
    if code == 250:
        var id = clean_reply_text(result.text, String(""))
        if id.byte_length() == 0:
            return String("250 2.0.0 Ok\r\n")
        return String("250 2.0.0 Ok: queued as ") + id + "\r\n"
    if code < 400 or code > 599:
        return String("451 4.3.0 Delivery returned an invalid result\r\n")
    var fallback: String
    if code >= 500:
        fallback = String("5.3.0 Message refused")
    else:
        fallback = String("4.3.0 Temporary local problem, try later")
    return String(code) + " " + clean_reply_text(result.text, fallback) + "\r\n"
