# Delivery into local mailboxes: the public `MailDelivery` that stores mail in
# komira_mail_store and fires an on-receipt hook.

from komira_mail_store import DEFAULT_FOLDER, store_message
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .delivery import DeliveryResult, MailDelivery, RcptDecision, SessionInfo
from .trace import append_renamed_trace_fields, trace_headers


trait MailReceiveHook(Movable, Deinitable):
    """What runs after a message is durably stored in a mailbox: a seam for a
    layer above the mail server (indexing, ingest) that the server must not
    depend on.

    `on_message_stored` is called once per recipient the message was stored
    for, after the bytes are durable, with the recipient mailbox and the bytes
    as stored (trace headers included). It is fail-soft: the message is
    already safe, so the delivery catches anything it raises and still
    answers 250. An implementation should catch its own errors anyway."""

    def on_message_stored(
        mut self, recipient: String, raw_bytes: List[UInt8]
    ) raises:
        ...


struct NoopMailReceiveHook(MailReceiveHook, Copyable, Movable):
    """The hook that does nothing."""

    def __init__(out self):
        pass

    def on_message_stored(
        mut self, recipient: String, raw_bytes: List[UInt8]
    ) raises:
        pass


def normalize_local_domain(domain: String) -> String:
    """A domain as the local-domain list compares it: ASCII letters lower
    case, one trailing dot removed. An address literal (`[192.0.2.1]`,
    `[IPv6:2001:DB8::1]`) is lower-cased the same way, so `[IPV6:2001:db8::1]`
    and `[ipv6:2001:DB8::1]` are one domain."""
    var bytes = domain.as_bytes()
    var n = len(bytes)
    var literal = n > 0 and bytes[0] == 0x5B
    if not literal and n > 0 and bytes[n - 1] == 0x2E:
        n -= 1
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = bytes[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


struct LocalDomains(Copyable, Movable):
    """The domains a server takes mail for. The first is the domain of the
    bare `postmaster`."""

    var _domains: List[String]

    def __init__(out self):
        self._domains = List[String]()

    def add(mut self, domain: String):
        """Add `domain` (an empty one is ignored)."""
        var d = normalize_local_domain(domain)
        if d.byte_length() == 0 or self.contains(d):
            return
        self._domains.append(d^)

    def contains(self, domain: String) -> Bool:
        var d = normalize_local_domain(domain)
        for i in range(len(self._domains)):
            if self._domains[i] == d:
                return True
        return False

    def first(self) -> String:
        """The postmaster's domain; empty when the list is empty."""
        if len(self._domains) == 0:
            return String("")
        return self._domains[0]

    def count(self) -> Int:
        return len(self._domains)


def _lower(text: String) -> String:
    var bytes = text.as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        var c = bytes[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _last_at(text: String) -> Int:
    var bytes = text.as_bytes()
    var i = len(bytes) - 1
    while i >= 0:
        if bytes[i] == 0x40:
            return i
        i -= 1
    return -1


def _is_postmaster(rcpt: String) -> Bool:
    var bytes = rcpt.as_bytes()
    var want = String("postmaster").as_bytes()
    if len(bytes) != len(want):
        return False
    for i in range(len(bytes)):
        var c = bytes[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        if c != want[i]:
            return False
    return True


struct LocalMailboxDelivery[S: ConditionalWriteStore, H: MailReceiveHook](
    MailDelivery
):
    """Stores each message in the INBOX of every recipient's mailbox, in
    `store` (komira_mail_store), with trace headers in front.

    RCPT: `postmaster` (any case, no domain) is accepted when the domain list
    is not empty and means `postmaster@<first domain>`; `local@domain` is
    accepted when the domain is in `local_domains` (case-insensitive, address
    literals normalised); anything else is `550 5.1.1`. The server is
    therefore not a relay.

    DATA: one copy per distinct mailbox, each with `Return-Path`, `Received`
    (naming the peer, the TLS state, a queue id that is unique per delivery
    and the recipient) and `Authentication-Results: <host>; none`. The leaf is
    the content hash of header plus message, so two deliveries of identical
    mail make two messages while the store's content addressing still makes a
    repeated write of the same bytes a no-op.

    All or nothing: if any copy cannot be stored the copies already written
    by this delivery are deleted (best effort) and the answer is 451, so the
    client's retry does not double-deliver. The hook fires only after every
    copy is durable, once per stored recipient, and anything it raises is
    swallowed. `deliver` never raises."""

    var store: Self.S
    var hook: Self.H
    var hostname: String
    var local_domains: LocalDomains
    var deliveries: Int

    def __init__(
        out self,
        var store: Self.S,
        var hook: Self.H,
        hostname: String,
        var local_domains: LocalDomains,
    ):
        self.store = store^
        self.hook = hook^
        self.hostname = hostname
        self.local_domains = local_domains^
        self.deliveries = 0

    def _mailbox_of(self, rcpt: String) -> Optional[String]:
        """The mailbox `rcpt` is delivered to, or None when it is not ours."""
        if _is_postmaster(rcpt):
            var home = self.local_domains.first()
            if home.byte_length() == 0:
                return None
            return Optional[String](String("postmaster@") + home)
        var at = _last_at(rcpt)
        if at <= 0:
            return None
        var domain = String(unsafe_from_utf8=rcpt.as_bytes()[at + 1 :])
        if not self.local_domains.contains(domain):
            return None
        var local = String(unsafe_from_utf8=rcpt.as_bytes()[0:at])
        # The store folds ASCII case in a mailbox name, so two spellings of
        # one address are one mailbox here too.
        return Optional[String](_lower(local) + "@" + normalize_local_domain(domain))

    def accept_recipient(
        mut self, session: SessionInfo, mail_from: String, rcpt: String
    ) -> RcptDecision:
        if self._mailbox_of(rcpt):
            return RcptDecision(0, String(""))
        return RcptDecision(550, String("5.1.1 No such user here"))

    def _message_for(
        self,
        session: SessionInfo,
        mail_from: String,
        rcpt: String,
        queue_id: String,
        message: Span[UInt8, _],
        now_ms: Int,
    ) -> List[UInt8]:
        """The bytes stored for one recipient: trace headers, then the message
        with any `Return-Path` or `Authentication-Results` field the sender put
        in its header renamed to `X-Original-...`, so the first of each in the
        stored bytes is ours and only ours."""
        var head = trace_headers(
            mail_from,
            session.helo,
            session.peer,
            session.authed_user,
            session.peer_tls,
            self.hostname,
            queue_id,
            rcpt,
            now_ms,
        )
        var out = List[UInt8](capacity=head.byte_length() + len(message) + 64)
        out.extend(head.as_bytes())
        append_renamed_trace_fields(out, message)
        return out^

    def _undo(mut self, keys: List[String]):
        for i in range(len(keys)):
            try:
                self.store.delete(Path.parse(keys[i]))
            except:
                pass

    def deliver(
        mut self,
        session: SessionInfo,
        mail_from: String,
        recipients: List[String],
        message: Span[UInt8, _],
        now_ms: Int,
    ) -> DeliveryResult:
        if len(recipients) == 0:
            return DeliveryResult(554, String("5.5.0 No valid recipients"))
        # Resolve every recipient again: what held at RCPT time is not assumed.
        var boxes = List[String]()
        var rcpts = List[String]()
        for i in range(len(recipients)):
            var box = self._mailbox_of(recipients[i])
            if not box:
                return DeliveryResult(554, String("5.1.1 No such user here"))
            var name = box.take()
            var seen = False
            for j in range(len(boxes)):
                if boxes[j] == name:
                    seen = True
            if not seen:
                boxes.append(name^)
                rcpts.append(recipients[i])
        self.deliveries += 1
        var queue_id = (
            String("q")
            + String(now_ms)
            + "-"
            + String(session.conn_id)
            + "-"
            + String(self.deliveries)
        )
        var created = List[String]()
        for i in range(len(boxes)):
            var bytes = self._message_for(
                session, mail_from, rcpts[i], queue_id, message, now_ms
            )
            try:
                var outcome = store_message(
                    self.store, boxes[i], String(DEFAULT_FOLDER), bytes
                )
                if outcome.created:
                    created.append(outcome.key)
            except:
                self._undo(created)
                return DeliveryResult(
                    451, String("4.3.0 Mailbox storage failed, try again later")
                )
        # Every copy is durable: tell the hook, once per recipient stored.
        for i in range(len(boxes)):
            var bytes = self._message_for(
                session, mail_from, rcpts[i], queue_id, message, now_ms
            )
            try:
                self.hook.on_message_stored(boxes[i], bytes)
            except:
                pass
        return DeliveryResult(250, queue_id)
