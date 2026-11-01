# A non-blocking loopback client for tests: plaintext, then optionally TLS.

from std.ffi import external_call
from std.pathlib import Path
from std.sys.info import CompilationTarget

from komira_async.reactor.socket_io import (
    errno_is_would_block,
    try_recv,
    try_send,
)
from komira_async.reactor.socket_setup import (
    close_fd,
    inet_loopback_be,
    sockaddr_in_bytes,
)
from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
)
from komira_runtime_paths import test_tmpdir

comptime _FIXTURES: String = "src/komira_http_core/tests/fixtures/tls/"
comptime _CHUNK: Int = 16 * 1024


def yield_cpu():
    """Let other threads and the kernel run. The only wait the tests use."""
    _ = external_call["sched_yield", Int32]()


def read_fixture(name: String) raises -> String:
    """A file of komira_http_core's TLS test fixtures (`leaf_cert.pem`,
    `leaf_key.pem`, `root_ca.pem`). The test declares the file in `test_data`."""
    return Path(_FIXTURES + name).read_text()


def scratch_dir() raises -> String:
    """The directory this run may write scratch files into (TEST_TMPDIR)."""
    return test_tmpdir()


struct Peer(Movable):
    """The client end of a loopback connection.

    `poll` appends whatever has arrived (decrypted once `start_tls` has been
    called) to `inbox`; `eof` becomes True when the server closed or reset the
    connection. `send` writes everything, yielding when the socket is full."""

    var fd: Int32
    var inbox: List[UInt8]
    var eof: Bool
    var _config: Optional[TlsConfig]
    var _tls: Optional[TlsConnection]

    def __init__(out self, fd: Int32):
        self.fd = fd
        self.inbox = List[UInt8]()
        self.eof = False
        self._config = None
        self._tls = None

    @staticmethod
    def connect(port: UInt16) raises -> Peer:
        """Connect to 127.0.0.1:`port`; the socket is non-blocking."""
        # FFI-BOUNDARY: plain libc socket/connect/close on a descriptor this
        # struct owns until `close`; the sockaddr is a local that outlives
        # the call.
        var fd = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
        if fd < Int32(0):
            raise Error("Peer.connect: socket() failed")
        var sa = sockaddr_in_bytes(inet_loopback_be(), port)
        # SAFETY: `sa` is a 16-byte local; connect copies it.
        var rc = external_call["connect", Int32](fd, sa.unsafe_ptr(), UInt32(16))
        if rc < Int32(0):
            close_fd(fd)
            raise Error("Peer.connect: connect() to the loopback listener failed")
        if external_call["komira_fcntl_set_nonblock", Int32](fd) < Int32(0):
            close_fd(fd)
            raise Error("Peer.connect: set_nonblock failed")
        return Peer(fd)

    def close(mut self):
        """Close the socket (no TLS goodbye). Safe to call twice."""
        self._tls = None
        close_fd(self.fd)
        self.fd = Int32(-1)

    def reset(mut self):
        """Abort the connection: the server sees a reset (RST), not a close.
        Linux and macOS socket constants."""
        # FFI-BOUNDARY: setsockopt(SO_LINGER {on, 0}) on the descriptor this
        # struct owns, then close; the 8-byte linger value is a local that
        # outlives the call.
        var sol_socket = Int32(1)
        var so_linger = Int32(13)
        comptime if CompilationTarget.is_macos():
            sol_socket = Int32(0xFFFF)
            so_linger = Int32(0x80)
        var linger = Array[Int32, 2](fill=Int32(0))
        linger[0] = Int32(1)
        # SAFETY: `linger` is a local of 8 bytes, copied by the kernel.
        _ = external_call["setsockopt", Int32](
            self.fd, sol_socket, so_linger, linger.unsafe_ptr(), UInt32(8)
        )
        self.close()

    def send(mut self, text: String) raises:
        """Write all of `text`, encrypted once TLS is on."""
        self.send_bytes(text.as_bytes())

    def send_bytes(mut self, bytes: Span[UInt8, _]) raises:
        """Write all of `bytes`, encrypted once TLS is on."""
        var off = 0
        while off < len(bytes):
            if self._tls:
                var r = self._tls.value().send(bytes[off:])
                if r[0] == TLS_OUTCOME_ERROR:
                    raise Error("Peer.send: TLS send failed")
                if r[0] == TLS_OUTCOME_DONE and r[1] > 0:
                    off += r[1]
                    continue
            else:
                var n = try_send(self.fd, bytes[off:])
                if n > Int64(0):
                    off += Int(n)
                    continue
                if n < Int64(0) and not errno_is_would_block(Int32(-Int(n))):
                    raise Error("Peer.send: the connection is gone")
            yield_cpu()

    def poll(mut self) -> Int:
        """Read what has arrived into `inbox`. Returns the bytes added; sets
        `eof` when the connection ended. Never blocks."""
        if self.eof or self.fd < Int32(0):
            return 0
        var added = 0
        if self._tls:
            var scratch = List[UInt8](length=_CHUNK, fill=UInt8(0))
            while True:
                var r = self._tls.value().recv_into_span(Span[UInt8](scratch))
                if r[0] == TLS_OUTCOME_ERROR:
                    self.eof = True
                    break
                if r[0] != TLS_OUTCOME_DONE:
                    break
                if r[1] == 0:
                    self.eof = True
                    break
                self.inbox.extend(Span(scratch)[0 : r[1]])
                added += r[1]
            return added
        var raw = List[UInt8](length=_CHUNK, fill=UInt8(0))
        while True:
            var n = try_recv(self.fd, Span(raw))
            if n > Int64(0):
                self.inbox.extend(Span(raw)[0 : Int(n)])
                added += Int(n)
                continue
            if n == Int64(0):
                self.eof = True
            elif not errno_is_would_block(Int32(-Int(n))):
                self.eof = True  # a reset ends the connection too
            break
        return added

    def text(self) -> String:
        """Everything received and not yet taken, as text."""
        return String(unsafe_from_utf8=Span(self.inbox))

    def has(self, marker: String) -> Bool:
        """True when `inbox` holds `marker`."""
        return self.text().find(marker) >= 0

    def take_through(mut self, marker: String) -> String:
        """Remove and return the text up to and including the first `marker`
        in `inbox`; empty (and nothing removed) when it is not there."""
        var all = self.text()
        var at = all.find(marker)
        if at < 0:
            return String("")
        var end = at + marker.byte_length()
        var head = String(unsafe_from_utf8=all.as_bytes()[0:end])
        var rest = List[UInt8]()
        rest.extend(all.as_bytes()[end:])
        self.inbox = rest^
        return head^

    def start_tls(mut self, root_ca_pem: String) raises:
        """Make this end a TLS client that trusts `root_ca_pem`. Call after the
        server's 220; then call `tls_step` until it returns True."""
        var cfg = TlsConfig()
        cfg.wipe_trust()
        cfg.add_trust_pem(root_ca_pem)
        self._config = cfg^
        var conn = TlsConnection.new_client(self._config.value())
        conn.bind_fd(self.fd)
        conn.set_server_name(String("localhost"))
        self._tls = conn^

    def tls_step(mut self) raises -> Bool:
        """Advance the client handshake once. True when it is done."""
        if not self._tls:
            raise Error("Peer.tls_step: start_tls was not called")
        var o = self._tls.value().handshake()
        if o == TLS_OUTCOME_ERROR:
            raise Error("Peer.tls_step: the TLS handshake failed")
        return o == TLS_OUTCOME_DONE
