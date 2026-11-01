# A driver for tests of an IMAP server and of what feeds it: a registry, a
# store and a verifier, with connections the test opens, feeds text to and
# reads replies from. No socket, no clock: the test sets the time. For tests
# and local use.

from komira_mail_auth import TestAuthVerifier
from komira_objectstore.store import CloneableConditionalWriteStore

from .limits import ImapServerConfig
from .session import FeedOutcome, ImapRegistry


struct ImapTestServer[S: CloneableConditionalWriteStore](Movable):
    """A registry over the store `store`, with a `TestAuthVerifier` and a
    clock the test sets. `connect` opens a connection and returns its id;
    `send` feeds it text and returns the replies that came back; `login`
    logs a connection in. Several connections share the one store, as the
    connections of a server do."""

    var reg: ImapRegistry
    var config: ImapServerConfig
    var verifier: TestAuthVerifier
    var store: Self.S
    var now_ms: Int
    var outcome: FeedOutcome

    def __init__(out self, var config: ImapServerConfig, var store: Self.S):
        self.reg = ImapRegistry()
        self.config = config^
        self.verifier = TestAuthVerifier()
        self.store = store^
        self.now_ms = 1000
        self.outcome = FeedOutcome()

    def add_user(mut self, username: String, password: String):
        self.verifier.add_user(username, password)

    def connect(mut self) -> Int:
        """Open a connection. Its id is returned; the greeting is waiting to
        be read with `take`."""
        var id = self.reg.accept(
            Int32(7), self.config, self.now_ms, String("192.0.2.1")
        )
        return id.value()

    def take(mut self, conn_id: Int) -> String:
        """Every reply byte queued for the connection so far; the queue is
        emptied. The bytes of a message literal are included as they are, so
        a test of a message with bytes over 0x7F reads `take_bytes`."""
        var all = String("")
        while self.reg.tx_len(conn_id) > 0:
            var part = self.reg.tx_copy(conn_id, 4096)
            all += String(unsafe_from_utf8=Span(part))
            self.reg.tx_consume(conn_id, len(part))
        return all^

    def take_bytes(mut self, conn_id: Int) -> List[UInt8]:
        var all = List[UInt8]()
        while self.reg.tx_len(conn_id) > 0:
            var part = self.reg.tx_copy(conn_id, 4096)
            all.extend(Span(part))
            self.reg.tx_consume(conn_id, len(part))
        return all^

    def feed_bytes(mut self, conn_id: Int, data: Span[UInt8, _]) -> FeedOutcome:
        self.outcome = self.reg.feed(
            conn_id,
            data,
            self.config,
            self.verifier,
            self.store,
            self.now_ms,
        )
        return self.outcome.copy()

    def send(mut self, conn_id: Int, text: String) -> String:
        """Feed `text` to the connection and return the replies."""
        _ = self.feed_bytes(conn_id, text.as_bytes())
        return self.take(conn_id)

    def send_chunks(mut self, conn_id: Int, text: String, size: Int) -> String:
        """Feed `text` in pieces of `size` bytes."""
        var bytes = text.as_bytes()
        var pos = 0
        while pos < len(bytes):
            var end = pos + size
            if end > len(bytes):
                end = len(bytes)
            _ = self.feed_bytes(conn_id, bytes[pos:end])
            pos = end
        return self.take(conn_id)

    def login(mut self, conn_id: Int, user: String, password: String) -> String:
        """`LOGIN` with tag `l1`; the reply (the greeting is discarded
        first)."""
        _ = self.take(conn_id)
        return self.send(
            conn_id, String("l1 LOGIN ") + user + " " + password + "\r\n"
        )
