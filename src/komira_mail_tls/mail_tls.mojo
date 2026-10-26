# The STARTTLS side table of a mail server.

from std.memory import OwnedPointer

from komira_collections.slab import Slab
from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    tls_init,
)

from .ledger import note_created, note_freed

# Largest plaintext one `recv` call decrypts. Mail command lines are under a
# kilobyte; a DATA or FETCH burst accumulates across loop iterations in the
# protocol's own buffer.
comptime _RECV_CHUNK: Int = 16 * 1024


struct MailTlsConn(Movable, Deinitable):
    """One connection's TLS state: a server-mode `TlsConnection` bound to the
    connection's socket and whether its handshake has finished.

    It counts its own creation and destruction on the process-wide tallies in
    `ledger`, so a test can see each one freed exactly once. The socket is
    never closed here: the server's connection owns it. Movable, not Copyable:
    a TLS connection cannot be duplicated."""

    var _conn: TlsConnection
    var _handshake_done: Bool

    def __init__(out self, var conn: TlsConnection):
        self._conn = conn^
        self._handshake_done = False
        note_created()

    def __deinit__(deinit self):
        note_freed()

    def handshake(mut self) -> UInt8:
        if self._handshake_done:
            return TLS_OUTCOME_DONE
        var outcome = self._conn.handshake()
        if outcome == TLS_OUTCOME_DONE:
            self._handshake_done = True
        return outcome

    def recv(mut self, mut into: List[UInt8], max_bytes: Int) -> Tuple[UInt8, Int]:
        if max_bytes <= 0:
            # No room: an empty span would let s2n answer (DONE, 0), which the
            # caller reads as the peer's close_notify.
            return (TLS_OUTCOME_ERROR, -1)
        var cap = max_bytes
        if cap > _RECV_CHUNK:
            cap = _RECV_CHUNK
        # Decrypt straight into the tail of `into`, then cut it back to what
        # arrived. The span lives only for this call; s2n does not keep it.
        var start = len(into)
        into.resize(start + cap, UInt8(0))
        var res = self._conn.recv_into_span(
            Span[UInt8](into)[start : start + cap]
        )
        var got = res[1]
        if res[0] != TLS_OUTCOME_DONE or got < 0:
            into.resize(start, UInt8(0))
            return (res[0], 0 if got < 0 else got)
        into.resize(start + got, UInt8(0))
        return (TLS_OUTCOME_DONE, got)

    def send(mut self, data: Span[UInt8, _]) -> Tuple[UInt8, Int]:
        return self._conn.send(data)


struct MailTlsTable(Movable, Deinitable):
    """The mail server's TLS side table: the one server certificate and key,
    and per-connection TLS state keyed by connection id.

    A connection has TLS state exactly when `is_tls(conn_id)` is true; a
    connection that never sends `STARTTLS` has no entry and keeps its
    plaintext path. The table is single-threaded, like the poll loop that
    drives it.

    Storage: `_conns` is a `Slab[OwnedPointer[MailTlsConn]]` parallel to
    `_conn_ids`. The slab keeps its elements inline in a byte buffer, so the
    element must not be a heap-owning struct moved by value; it is an
    `OwnedPointer`, an 8-byte handle whose move leaves an empty handle, and
    the TLS connection itself stays at a stable heap address. Removal is
    `swap_remove`, which moves the whole handle. The churn test in
    `tests/test_entry_lifetime.mojo` holds this to account: every entry freed
    exactly once, through growth and removal from the middle."""

    # Declared first so it drops last; each connection also co-owns a share of
    # the config, so neither order can free it under a live connection.
    var _config: TlsConfig
    var _conns: Slab[OwnedPointer[MailTlsConn]]
    var _conn_ids: List[Int]

    def __init__(out self, var config: TlsConfig):
        """Take ownership of a configured server `TlsConfig`."""
        self._config = config^
        self._conns = Slab[OwnedPointer[MailTlsConn]]()
        self._conn_ids = List[Int]()

    @staticmethod
    def from_cert_pem(cert_pem: String, key_pem: String) raises -> MailTlsTable:
        """Build a table from a PEM certificate chain and a PKCS#8 PEM private
        key; the caller reads the files. Raises on a malformed PEM or a key
        that does not match. The error text never carries the key or the
        certificate."""
        tls_init()
        var config = TlsConfig()
        # "default_tls13" negotiates TLS 1.3 with modern clients; a fresh s2n
        # config defaults to TLS 1.2 only.
        config.set_cipher_preferences(String("default_tls13"))
        config.load_cert(cert_pem, key_pem)
        return MailTlsTable(config^)

    def _index_of(self, conn_id: Int) -> Int:
        for i in range(len(self._conn_ids)):
            if self._conn_ids[i] == conn_id:
                return i
        return -1

    def is_tls(self, conn_id: Int) -> Bool:
        """True when `conn_id` has begun or finished an upgrade."""
        return self._index_of(conn_id) >= 0

    def handshake_done(self, conn_id: Int) -> Bool:
        """True when `conn_id`'s handshake has finished; false for an unknown
        id or a handshake still running."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return False
        return self._conns[idx][]._handshake_done

    def conn_fd(self, conn_id: Int) -> Int32:
        """The socket `conn_id`'s TLS state is bound to, or -1 for an unknown
        id."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return Int32(-1)
        return self._conns[idx][]._conn.fd()

    def tls_conn_count(self) -> Int:
        """How many connections hold TLS state."""
        return len(self._conn_ids)

    def begin_upgrade(
        mut self, conn_id: Int, fd: Int32, pending_plaintext_bytes: Int
    ) raises:
        """Start TLS on `conn_id` over its socket `fd`.

        `pending_plaintext_bytes` is how many bytes the server has read from
        this connection and not yet consumed. It must be 0: bytes a client
        pipelined after `STARTTLS` were sent in the clear, and parsing them as
        commands after the upgrade is the command-injection flaw of RFC 3207
        section 4.2. The call raises, creating no entry, when it is not 0, so
        the caller closes the connection. An empty buffer also means the
        handshake's first bytes never append to stale input.

        s2n reads and writes `fd` itself (no IO callbacks), so `fd` MUST be
        non-blocking: on a blocking socket `drive_handshake_burst`, `recv`
        and `send` wait inside s2n and stall the whole poll loop. The table
        cannot check it (there is no flags shim to read them with); the
        caller sets `O_NONBLOCK` when it accepts the connection. The caller
        must also have flushed every plaintext reply (the `220`) before this
        call: handshake bytes written ahead of an unsent reply would
        interleave with it. The table cannot see the server's write queue.

        The caller keeps `fd` open until `drop` and closes it. A second call
        for an id that already has an entry with the same `fd` changes
        nothing; with a different `fd` it raises, because TLS would otherwise
        keep running over a descriptor the server has closed and may have
        reused. Drop the id first."""
        if pending_plaintext_bytes != 0:
            raise Error(
                "MailTlsTable.begin_upgrade: plaintext is buffered after STARTTLS"
            )
        var existing = self._index_of(conn_id)
        if existing >= 0:
            if self._conns[existing][]._conn.fd() != fd:
                raise Error(
                    "MailTlsTable.begin_upgrade: the id already has TLS state"
                    " on another socket"
                )
            return
        var conn = TlsConnection(self._config)
        conn.bind_fd(fd)
        self._conns.append(OwnedPointer[MailTlsConn](MailTlsConn(conn^)))
        self._conn_ids.append(conn_id)

    def drive_handshake_burst(mut self, conn_id: Int) -> UInt8:
        """Advance `conn_id`'s handshake. One call runs `s2n_negotiate`, which
        itself processes every handshake message the socket has ready and
        stops when it must wait; the loop calls this once per iteration until
        `TLS_OUTCOME_DONE`. Returns `TLS_OUTCOME_DONE`,
        `TLS_OUTCOME_BLOCKED_ON_READ`, `TLS_OUTCOME_BLOCKED_ON_WRITE` or
        `TLS_OUTCOME_ERROR` (close the connection); an id with no entry is
        `TLS_OUTCOME_ERROR`. After `DONE` it answers `DONE` without touching
        the socket."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return TLS_OUTCOME_ERROR
        return self._conns[idx][].handshake()

    def recv(
        mut self, conn_id: Int, mut into: List[UInt8], max_bytes: Int
    ) -> Tuple[UInt8, Int]:
        """Decrypt up to `max_bytes` (at most 16 KiB) of plaintext from
        `conn_id`, appending to `into`. Returns `(outcome, n)`: `DONE` with `n`
        bytes appended (`n == 0` is the peer's close_notify), a `BLOCKED_ON_*`
        with nothing appended, or `ERROR` (also `(ERROR, -1)` when `max_bytes` is
        not positive). Call after `handshake_done`; an id
        with no entry is `(ERROR, -1)`."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return (TLS_OUTCOME_ERROR, -1)
        return self._conns[idx][].recv(into, max_bytes)

    def send(mut self, conn_id: Int, data: Span[UInt8, _]) -> Tuple[UInt8, Int]:
        """Encrypt and send `data` on `conn_id`. `n` may be short of
        `len(data)`; the caller sends the rest later. When the socket is full
        s2n holds the record it could not write and flushes it at the start of
        the next non-empty `send`, so the rest must be offered again (an empty
        `data` does nothing). Call after `handshake_done`; an id with no entry is `(ERROR, -1)`."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return (TLS_OUTCOME_ERROR, -1)
        return self._conns[idx][].send(data)

    def drop(mut self, conn_id: Int):
        """Free `conn_id`'s TLS state when its connection closes. The socket
        is not closed here. An id with no entry is a no-op. No close_notify is
        sent: a server that wants a TLS goodbye must not assume one from
        `drop` (an SMTP `QUIT` reply is sent with `send` before the drop, and
        the close that follows is a plain TCP close)."""
        var idx = self._index_of(conn_id)
        if idx < 0:
            return
        var removed = self._conns.swap_remove(idx)
        _ = removed^
        # `swap_remove` moved the last entry into `idx`; do the same to the ids.
        var last = len(self._conn_ids) - 1
        if idx != last:
            self._conn_ids[idx] = self._conn_ids[last]
        _ = self._conn_ids.pop()
