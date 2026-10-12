# =============================================================================
# src/komira_http_server/connection.mojo — L0 per-conn state
# =============================================================================
#
# Per-connection state:
#   - TcpStream (RAII fd close on drop)
#   - RegistrationHandle (one per conn lifetime)
#   - State machine variant: READING vs WAITING_FOR_WRITABLE
#   - Pending-write buffer for EWOULDBLOCK→EPOLLOUT fallback
#   - The start of a request head still waiting for its end (head carry)
#
# ConnEntry is Movable but NOT Copyable — TcpStream is not Copyable
# (it owns an fd; copy would double-close).
# =============================================================================

from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    RegistrationHandle,
)
from komira_async.reactor.socket_io import try_io_read
from komira_async.runtime.tcp_stream import TcpStream

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.tls.conn import TlsStream


# =============================================================================
# §1 — Per-connection state constants.
# =============================================================================

comptime CONN_STATE_READING: UInt8 = 0
comptime CONN_STATE_WAITING_FOR_WRITABLE: UInt8 = 1

# h2-aware states.
# Post-handshake on an ALPN-h2 connection, the server first waits for the
# 24-byte client preface (PRI magic). Once validated, the conn enters
# ACTIVE and drives the frame-codec loop.
#
# State values 16 and 17 are RESERVED for TLS handshake states
# (CONN_STATE_TLS_HANDSHAKE_IN=16, CONN_STATE_TLS_HANDSHAKE_OUT=17) per
# `tls/handshake_state.mojo`. The H2 states use 32+ to avoid collision
# with the handshake-state detector `is_tls_handshake_state` in
# `tls/handshake_state.mojo:132` (which checks `state == 16 or state == 17`).
comptime CONN_STATE_H2_PREFACE_WAIT: UInt8 = 32
"""ALPN selected h2; awaiting 24-byte client preface (RFC 9113 §3.4)."""

comptime CONN_STATE_H2_ACTIVE: UInt8 = 33
"""Client preface validated; frame-codec loop drives requests + responses."""


def is_h2_state(state: UInt8) -> Bool:
    """True iff `state` is one of the H2-driven conn states."""
    return state == CONN_STATE_H2_PREFACE_WAIT or (
        state == CONN_STATE_H2_ACTIVE
    )


# Request-buffer size: enough for typical HTTP/1.1 headers + small body.
# will likely promote this to a config knob.
comptime REQ_BUF_BYTES: Int = 4096

# Response-buffer size: enough for a small pre-built response.
#
# NOTE: RESP_BUF_CAP is the size of the
# CANNED pre-built response buffers (`HttpServer._resp_buf`, the health
# response). It is NO LONGER the cap on the per-connection pending-write
# tail. The pending-write tail (`ConnEntry._pending_buf`) is now a growable
# `List[UInt8]` so a response of ANY size can be flushed across multiple
# EPOLLOUT events. Previously the 1KB cap here silently dropped any
# connection whose unsent tail (kernel send buffer full) exceeded 1024
# bytes — which broke any response larger than the socket send buffer
# (e.g. a 113KB `list_tasks` JSON dropped at ~77KB on Linux).
comptime RESP_BUF_CAP: Int = 1024


# =============================================================================
# §2 — ConnEntry.
# =============================================================================


struct ConnEntry(Movable, Deinitable):
    """Per-connection state owned by the per-pthread accept loop.

    Lifetime:
      * Created in `_accept_one_and_register` after `try_accept` returns
        a new fd.
      * Lives in the per-pthread `Slab[OwnedPointer[ConnEntry]]`.
      * Destroyed in `_close_and_remove` via swap_remove → drop → fd close.

    Fields:
      _stream         — owned TcpStream (RAII fd close on drop)
      _reg            — reactor registration handle (one per conn)
      _fd             — cached fd (== _stream.fd())
      _state          — CONN_STATE_*
      _interest_set   — currently armed reactor interest mask
      _pending_buf    — buffered tail bytes for EWOULDBLOCK→EPOLLOUT path.
                        Growable List[UInt8] (heap-owning, Movable) so a
                        response of ANY size flushes across multiple
                        EPOLLOUT events. The List OWNS the buffered bytes
                        (no borrow held across the reactor park, no
                        wildcard origin — encapsulation-clean).
      _pending_len    — bytes of valid data in _pending_buf (0 == no
                        pending; -1 == hard-error sentinel). NOTE: this is
                        the logical valid-length, which may be <= the
                        List's capacity (the List can retain capacity
                        across requests for allocation reuse).
      _pending_off    — bytes already drained from _pending_buf
      _keep_alive     — HTTP/1.1 keep-alive flag

    Movable, NOT Copyable — TcpStream is not Copyable.
    """

    var _stream: TcpStream
    var _reg: RegistrationHandle
    var _fd: Int32
    var _state: UInt8
    var _interest_set: UInt8
    # Growable pending-write tail. List[UInt8] is Movable (keeps ConnEntry
    # Movable) and OWNS its bytes, so it correctly outlives the reactor
    # park between EPOLLOUT events. Unlike the prior fixed 1KB InlineArray,
    # this holds an arbitrarily large unsent tail so big responses flush
    # across multiple writable events instead of dropping the connection.
    var _pending_buf: List[UInt8]
    var _pending_len: Int
    var _pending_off: Int
    var _keep_alive: Bool
    # Optional TLS stream. When Some, the conn was
    # accepted on a TLS-enabled listener; the byte transport (read/write)
    # goes through TlsStream.read_app / write_app instead of try_io_read /
    # try_io_write. When None (the default), the plaintext path
    # runs unchanged.
    var _tls: Optional[TlsStream]
    # Optional H2 connection state. When Some, this
    # conn was ALPN-negotiated to h2 (the post-handshake serve loop
    # routes through serve_read_round_h2 instead of serve_read_round_tls
    # for the h1 codec). When None,
    # the h1 path runs unchanged.
    #
    # Heap-Movable + heap-owning fields (Dict + List + HpackDynamicTable);
    # NOT byte-backed (pointer safety per + connection_state
    # module-doc header).
    var _h2: Optional[H2ConnectionState]
    # The received start of a request head whose end has not arrived yet
    # (RFC 9112 section 2.2: a request may arrive in any number of
    # segments). A read round keeps it here when the parser asks for more
    # bytes, and puts it back at the front of the receive buffer before the
    # next read. Never longer than REQ_BUF_BYTES - 1.
    var _head_carry: List[UInt8]

    def __init__(
        out self,
        var stream: TcpStream,
        reg: RegistrationHandle,
    ):
        self._fd = stream.fd()
        self._stream = stream^
        self._reg = reg
        self._state = CONN_STATE_READING
        self._interest_set = INTEREST_READ
        self._pending_buf = List[UInt8]()
        self._pending_len = 0
        self._pending_off = 0
        self._keep_alive = True
        self._tls = Optional[TlsStream]()
        self._h2 = Optional[H2ConnectionState]()
        self._head_carry = List[UInt8]()

    def __init__(
        out self,
        var stream: TcpStream,
        reg: RegistrationHandle,
        var tls_stream: TlsStream,
        initial_state: UInt8,
    ):
        """TLS-aware constructor. Same as the
        plaintext constructor but pre-installs a `TlsStream` and starts
        in `initial_state` (typically `CONN_STATE_TLS_HANDSHAKE_IN`).

        Caller is responsible for setting the fd non-blocking BEFORE
        constructing the TlsStream (s2n_negotiate on a
        blocking fd hangs indefinitely).
        """
        self._fd = stream.fd()
        self._stream = stream^
        self._reg = reg
        self._state = initial_state
        self._interest_set = INTEREST_READ
        self._pending_buf = List[UInt8]()
        self._pending_len = 0
        self._pending_off = 0
        self._keep_alive = True
        self._tls = Optional[TlsStream](tls_stream^)
        self._h2 = Optional[H2ConnectionState]()
        self._head_carry = List[UInt8]()

    def fd(self) -> Int32:
        """Borrow the conn's fd (the kernel-level identifier)."""
        return self._fd

    def forget_fd(mut self):
        """Give up the fd without closing it: the entry's drop then closes
        nothing. For an entry whose fd number was closed behind its back
        and has been handed out again (komira_http_server.accept_loop's
        stale-mapping sweep): closing it would close the new owner's
        descriptor."""
        _ = self._stream.release_fd()
        self._fd = Int32(-1)

    def state(self) -> UInt8:
        """Current connection state (CONN_STATE_*)."""
        return self._state

    def interest_set(self) -> UInt8:
        """Currently armed reactor interest mask."""
        return self._interest_set

    def registration(ref self) -> ref [self._reg] RegistrationHandle:
        """Borrow the reactor registration handle for `reactor.modify` calls."""
        return self._reg

    def pending_len(self) -> Int:
        """Bytes in the pending-write buffer; <0 = sentinel hard error."""
        return self._pending_len

    def pending_off(self) -> Int:
        """Bytes already drained from the pending-write buffer."""
        return self._pending_off

    def keep_alive(self) -> Bool:
        return self._keep_alive

    def set_state(mut self, new_state: UInt8):
        self._state = new_state

    def set_interest(mut self, mask: UInt8):
        self._interest_set = mask

    def set_pending(
        mut self,
        bytes_view: Span[UInt8, origin_of(self)],
        length: Int,
    ):
        """Buffer `length` bytes from `bytes_view` into the pending tail.

        The pending buffer is a growable List[UInt8]; it is resized to
        `length` so a tail of ANY size is held. The offset is reset to 0;
        state transitions to WAITING_FOR_WRITABLE. No cap — large
        responses flush across multiple EPOLLOUT events.
        """
        self._pending_buf.resize(unsafe_uninit_length=length)
        var k = 0
        while k < length:
            self._pending_buf[k] = bytes_view[k]
            k = k + 1
        self._pending_len = length
        self._pending_off = 0
        self._state = CONN_STATE_WAITING_FOR_WRITABLE

    def drain_pending(mut self, n_drained: Int):
        """Advance the pending-write offset by `n_drained` bytes."""
        self._pending_off = self._pending_off + n_drained

    def clear_pending(mut self):
        """Mark the pending-write buffer empty and return to READING.

        Clears the List so a long-lived keep-alive connection does not
        hold a large buffer forever after one big response drains. The
        List frees its backing storage; the next pending tail re-grows it.
        """
        self._pending_buf.clear()
        self._pending_len = 0
        self._pending_off = 0
        self._state = CONN_STATE_READING

    def mark_pending_error(mut self):
        """Sentinel: pending-write hit a hard error; caller will close."""
        self._pending_len = -1

    def pending_view(ref self) -> Span[UInt8, origin_of(self._pending_buf)]:
        """Return a view of the remaining pending-write bytes."""
        var full = Span[UInt8](self._pending_buf)
        return full[self._pending_off:self._pending_len]

    def set_pending_from_list(
        mut self,
        src: List[UInt8],
        start_off: Int,
    ):
        """Buffer `src[start_off:]` into the pending tail (growable).

        Used by `_write_all_or_buffer` when a write EWOULDBLOCKs partway:
        the full remaining tail (`len(src) - start_off`, which may be
        many KB) is copied into the List-backed pending buffer with NO
        cap. State transitions to WAITING_FOR_WRITABLE; offset reset to 0.
        """
        var n = len(src)
        var rem = n - start_off
        if rem < 0:
            rem = 0
        self._pending_buf.resize(unsafe_uninit_length=rem)
        var k = 0
        while k < rem:
            self._pending_buf[k] = src[start_off + k]
            k = k + 1
        self._pending_len = rem
        self._pending_off = 0
        self._state = CONN_STATE_WAITING_FOR_WRITABLE

    # Partial request head carried across reads.
    def head_carry_len(self) -> Int:
        """Bytes of an unfinished request head kept from earlier reads."""
        return len(self._head_carry)

    def carry_head(mut self, part: Span[UInt8, _]) -> Bool:
        """Keep `part`, the received start of a request head, for the next
        read. Returns False, keeping nothing, when `part` fills the whole
        receive buffer: the head cannot complete in it, and the caller
        answers 431."""
        if len(part) >= REQ_BUF_BYTES:
            return False
        self._head_carry.clear()
        for i in range(len(part)):
            self._head_carry.append(part[i])
        return True

    def restore_head_carry(
        mut self, mut io_buf: Array[UInt8, REQ_BUF_BYTES]
    ) -> Int:
        """Copy the carried head to the front of `io_buf` and return its
        length; the next read lands after it. The carry is kept until
        `clear_head_carry`, so a read that would block loses nothing."""
        var n = len(self._head_carry)
        for i in range(n):
            io_buf[i] = self._head_carry[i]
        return n

    def clear_head_carry(mut self):
        """Forget the carried head: a read appended to it in `io_buf`."""
        self._head_carry.clear()

    # TLS accessors.
    def is_tls(self) -> Bool:
        """True iff this conn was accepted on a TLS-enabled listener.
        When True, the byte transport goes through `tls_stream_ref()`."""
        return Bool(self._tls)

    def tls_stream_ref(ref self) -> ref [self._tls] Optional[TlsStream]:
        """Borrow the Optional TLS stream. When the Optional is Some,
        `read_app` / `write_app` / `drive_handshake` are valid on the
        underlying TlsStream. When None, the plaintext path is in use.
        """
        return self._tls

    # H2 accessors.
    def is_h2(self) -> Bool:
        """True iff this conn has been ALPN-negotiated to HTTP/2 and the
        per-conn H2 state has been installed (either pre-preface or
        preface-OK). When True, the serve loop routes through
        `serve_read_round_h2` instead of the h1 codec."""
        return Bool(self._h2)

    def install_h2_state(mut self, var h2_state: H2ConnectionState):
        """Install per-conn H2ConnectionState. Called by the accept-loop
        ALPN-readback path when `negotiated_protocol == "h2"` immediately
        after TLS_OUTCOME_DONE. Subsequent reads go through the h2
        codec loop."""
        self._h2 = Optional[H2ConnectionState](h2_state^)

    def h2_state_ref(ref self) -> ref [self._h2] Optional[H2ConnectionState]:
        """Borrow the Optional H2 connection state. When Some, the h2
        path is active. When None, the h1 path runs (default)."""
        return self._h2


# =============================================================================
# §3 — A plaintext read after the carried head.
# =============================================================================

comptime HEAD_READ_BLOCKED: Int = -1
"""`read_after_head_carry`: nothing new to read; the carry stays in the entry."""


def read_after_head_carry(
    mut entry: ConnEntry, mut io_buf: Array[UInt8, REQ_BUF_BYTES]
) -> Int:
    """Read from `entry`'s socket into `io_buf`, after the head carried from
    earlier reads. Returns how many bytes at the front of `io_buf` are valid
    (carry plus new bytes), `HEAD_READ_BLOCKED` when the read would block, or
    0 on end of stream or a read error (the caller drops the connection)."""
    var carried = entry.restore_head_carry(io_buf)
    var rr = try_io_read(
        entry._fd, Span[UInt8](io_buf)[carried:REQ_BUF_BYTES]
    )
    if rr.is_would_block():
        return HEAD_READ_BLOCKED
    if rr.is_error():
        return 0
    var n = Int(rr.value())
    if n <= 0:
        return 0
    entry.clear_head_carry()
    return carried + n
