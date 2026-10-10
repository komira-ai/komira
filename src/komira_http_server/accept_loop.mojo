# =============================================================================
# src/komira_http_server/accept_loop.mojo — L0 multiplexed event loop
# =============================================================================
#
# Driver fns:
#   * accept_one_and_register  — drain accept queue (EPOLLET drain-to-EAGAIN);
#                                wrap each new fd in a ConnEntry; insert into
#                                the per-pthread Slab + fd→idx Dict.
#   * close_and_remove         — O(1) swap_remove + fd→idx dict patch.
#   * serve_read_round         — drain reads from a ready fd; parse each
#                                request via the L2 RFC-7230 parser;
#                                on parse error write
#                                the static error response (400/413/431/etc.)
#                                and close; on parse success write the
#                                canned 200 (handler dispatch is the
#                                `_dispatch` variant).
#                                On Expect: 100-continue write interim then
#                                continue. On EWOULDBLOCK buffer remaining
#                                tail bytes + transition state to
#                                WAITING_FOR_WRITABLE.
#   * resume_pending_write     — drain the buffered tail after EPOLLOUT.
#   * count_complete_requests  — minimal CRLFCRLF detector retained for
#                                test compatibility (kept for L0 unit tests).
#                                Production code uses parse_request_head.
#
# Dispatch glue (`HttpServer`-shaped) lives in `server.mojo`. These
# transport-layer fns are infrastructure used BY HttpServer (and by the
# L0 unit tests).
# =============================================================================

from std.collections.dict import Dict
from std.ffi import external_call

from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_io import (
    try_io_read,
    try_io_write,
)
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.tcp_stream import (
    TcpListener,
    TcpStream,
)
from komira_collections.slab import Slab

from komira_http_core.codec.h1.parser import (
    build_100_continue_bytes,
    build_error_response_bytes,
    parse_request_head,
)
from komira_http_core.codec.h1.limits import ParseLimits
from komira_http_core.codec.types import (
    HttpRequest,
    HttpResponse,
    serialize_response,
)
from komira_http_server.middleware.chain import MiddlewareChain
from komira_http_core.tls.conn import (
    CONN_STATE_CLOSED as TLS_CONN_STATE_CLOSED,
    TlsStream,
)
from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
)
from komira_http_server.connection import (
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
    RESP_BUF_CAP,
)


# =============================================================================
# §1 — HTTP/1.1 boundary detector (retained for L0 unit tests).
# =============================================================================


def count_complete_requests(
    buf: Array[UInt8, REQ_BUF_BYTES], n: Int,
) -> Int:
    """Count `\\r\\n\\r\\n` boundaries in `buf[0:n)`.

    Returns the number of complete HTTP/1.1 requests pipelined into one
    recv buffer. Retained for L0 unit tests; production code uses
    `parse_request_head` which validates the full RFC 7230 shape.
    """
    if n < 4:
        return 0
    var count = 0
    var i = 0
    while i + 4 <= n:
        if (
            buf[i] == UInt8(0x0D)
            and buf[i + 1] == UInt8(0x0A)
            and buf[i + 2] == UInt8(0x0D)
            and buf[i + 3] == UInt8(0x0A)
        ):
            count = count + 1
            i = i + 4
        else:
            i = i + 1
    return count


# =============================================================================
# §2 — Per-conn close + swap_remove.
# =============================================================================


@always_inline
def close_and_remove(
    mut conns: Slab[ConnEntry],
    mut fd_to_idx: Dict[Int, Int],
    idx: Int,
) raises:
    """Remove the conn at `idx` from the per-thread table.

    Steps:
      1. Read the closing fd from the slot.
      2. Pop the fd→idx entry for the closing fd.
      3. swap_remove on the slab (O(1)); if `idx` was not the tail, the
         former-tail entry moved to `idx` and its dict mapping must be
         patched to point at the new index.
      4. Drop the taken `ConnEntry` (its dtor closes the TcpStream's fd).

    `raises` because `Dict.pop` raises on missing key — under normal
    invariants this never fires (we only call after a successful lookup).
    """
    var n = conns.len()
    if idx < 0 or idx >= n:
        return
    var closing_fd = conns[idx]._fd
    _ = fd_to_idx.pop(Int(closing_fd))
    var tail_idx = n - 1
    if idx != tail_idx:
        var moved_fd = conns[tail_idx]._fd
        var taken = conns.swap_remove(idx)
        _ = taken^
        fd_to_idx[Int(moved_fd)] = idx
    else:
        var taken = conns.swap_remove(idx)
        _ = taken^


def _sweep_stale_mapping(
    mut conns: Slab[ConnEntry],
    mut fd_to_idx: Dict[Int, Int],
    fd: Int32,
):
    """Drop the table's mapping for `fd`, a number accept(2) just returned:
    whatever the table held under it was closed behind its back.

      * The mapped slot holds `fd`: the stale conn. Its slot goes WITHOUT
        closing the number (`ConnEntry.forget_fd`), which now belongs to
        the conn just accepted (komira-ai/komira#936).
      * The mapped slot holds another fd mapped to that slot: a live conn.
        Only the stale mapping goes.
      * The mapped slot holds an fd no mapping reaches (an orphan): nothing
        can address it, so it goes too, without closing a number the table
        cannot show it still owns (komira-ai/komira#947).

    Afterwards every slot left is reached by its own fd's mapping.
    """
    var idx = fd_to_idx.pop(Int(fd), -1)
    var n = conns.len()
    if idx < 0 or idx >= n:
        return
    var slot_fd = conns[idx]._fd
    if slot_fd != fd:
        var owner = fd_to_idx.find(Int(slot_fd))
        if owner and owner.value() == idx:
            return
    conns[idx].forget_fd()
    var tail_idx = n - 1
    var moved_fd = conns[tail_idx]._fd
    _ = conns.swap_remove(idx)
    if idx != tail_idx:
        var moved = fd_to_idx.find(Int(moved_fd))
        if moved and moved.value() == tail_idx:
            fd_to_idx[Int(moved_fd)] = idx


# =============================================================================
# §3 — Accept new conns from the listener.
# =============================================================================


@always_inline
def accept_one_and_register(
    mut listener: TcpListener,
    mut reactor: Reactor[NoopSink],
    mut conns: Slab[ConnEntry],
    mut fd_to_idx: Dict[Int, Int],
) raises -> Int:
    """Drain the kernel accept queue.

    Returns the number of NEW conns accepted in this call. WouldBlock /
    error breaks out of the inner loop; the caller is responsible for the
    `continue` on the outer event loop.

    On accept: wraps the fd in a TcpStream + registers it with the
    reactor (long-lived registration; one per conn lifetime)
    and appends a ConnEntry to the slab + records the fd→idx mapping.
    """
    var accepted = 0
    while True:
        var ar = listener.try_accept()
        if ar.is_would_block():
            break
        if ar.is_error():
            break
        var new_fd = Int32(Int(ar.value()))
        if new_fd < Int32(0):
            break
        # The table still maps the number the kernel re-handed: sweep it.
        _sweep_stale_mapping(conns, fd_to_idx, new_fd)
        var new_stream = TcpStream(new_fd)
        var new_reg = reactor.register_long_lived(new_fd, INTEREST_READ)
        var new_entry = ConnEntry(stream=new_stream^, reg=new_reg)
        var new_idx = conns.len()
        conns.append(new_entry^)
        fd_to_idx[Int(new_fd)] = new_idx
        accepted = accepted + 1
    return accepted


# =============================================================================
# §4 — Write-with-EWOULDBLOCK helper.
# =============================================================================


@always_inline
def _write_all_or_buffer(
    mut entry: ConnEntry,
    src: List[UInt8],
    mut bytes_sent: Int64,
) -> Int:
    """Try to write the bytes from `src` to entry._fd. On EWOULDBLOCK,
    buffer the tail into entry._pending_buf and transition state.

    Returns:
      0  — fully written.
      1  — partial write; pending state set; caller should return True.
     -1  — hard error; caller should close.
    """
    var fd = entry._fd
    var n = len(src)
    var sent_off = 0
    while sent_off < n:
        # Build a Span over the unsent tail via stdlib slice.
        # No raw pointer arithmetic in the public-callable surface;
        # the slice's origin is bound to `src` which is borrowed for
        # the duration of this call.
        var full = Span[UInt8](src)
        var tail_span = full[sent_off:n]
        var wr = try_io_write(fd, tail_span)
        if wr.is_would_block():
            # Kernel send buffer is full. Buffer the FULL remaining tail
            # into entry._pending_buf (a growable List[UInt8]) — NO CAP.
            # A response of any size flushes across multiple EPOLLOUT
            # events via resume_pending_write. (Prior behavior: a fixed
            # 1KB cap returned -1 here, dropping the connection for any
            # response whose unsent tail exceeded the socket send buffer
            # — e.g. a 113KB list_tasks JSON dropped at ~77KB.)
            var rem = n - sent_off
            entry._pending_buf.resize(unsafe_uninit_length=rem)
            var kk = 0
            while kk < rem:
                entry._pending_buf[kk] = src[sent_off + kk]
                kk = kk + 1
            entry._pending_len = rem
            entry._pending_off = 0
            entry._state = CONN_STATE_WAITING_FOR_WRITABLE
            bytes_sent = bytes_sent + Int64(sent_off)
            return 1
        if wr.is_error():
            return -1
        var sent_n = Int(wr.value())
        if sent_n <= 0:
            return -1
        sent_off = sent_off + sent_n
    bytes_sent = bytes_sent + Int64(n)
    return 0


def _park_behind(mut entry: ConnEntry, src: List[UInt8]):
    """Queue `src` behind the tail `_write_all_or_buffer` just parked (its
    buffer holds exactly `_pending_len` bytes), so the resume sends both."""
    for i in range(len(src)):
        entry._pending_buf.append(src[i])
    entry._pending_len = entry._pending_len + len(src)


# =============================================================================
# §5 — Drain a read-ready conn (recv → parse → write response/error).
# =============================================================================


def serve_read_round(
    mut entry: ConnEntry,
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    resp_buf: Array[UInt8, RESP_BUF_CAP],
    resp_len: Int,
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Handle one round of activity on a connection.

    Flow:
      1. recv() into io_buf.
      2. Use `parse_request_head` to validate the HTTP/1.1 shape over
         the recv buffer.
         a. Parse error → write static error response (status from the
            ParseError) and close the conn. NO client bytes leak.
         b. Need-more (partial-headers) → for now we drop the conn (no
            multi-recv buffering on this path).
         c. Expect: 100-continue → write the interim "HTTP/1.1 100 Continue"
            then continue to the canned 200 response.
         d. Success → write the canned 200 response (real handler
            dispatch is).
      3. If pipelined requests follow in the buffer (CRLFCRLF at
         headers_end_off), parse them in turn and respond per-request.

    Returns:
      * True  — conn remains in the table (alive)
      * False — caller should drop the conn

    On write-side EWOULDBLOCK, buffers the unwritten tail bytes into
    `entry._pending_buf` and transitions state to
    `CONN_STATE_WAITING_FOR_WRITABLE`. The CALLER then issues
    `reactor.modify(entry.registration(), INTEREST_WRITE)`.
    """
    var fd = entry._fd
    var keep_alive = True

    while keep_alive:
        var read_span = Span[UInt8](io_buf)
        var rr = try_io_read(fd, read_span)
        if rr.is_would_block():
            break
        if rr.is_error():
            keep_alive = False
            break
        var got = Int(rr.value())
        if got <= 0:
            # Peer closed cleanly (read returned 0).
            keep_alive = False
            break

        # Parse + dispatch in a loop over the buffer (pipelining).
        var off = 0
        while off < got and keep_alive:
            var parse_span = Span[UInt8](io_buf)[off:got]
            var outcome = parse_request_head(parse_span, limits)

            if outcome.err.is_need_more():
                # Partial request: This version doesn't yet buffer across recvs.
                # Drop the conn to keep the design surgical; multi-recv
                # streaming is not on this path.
                keep_alive = False
                break

            if not outcome.err.is_ok():
                # Hard parse error — emit static response, close.
                var err_buf = List[UInt8]()
                build_error_response_bytes(outcome.err.status, err_buf)
                var w = _write_all_or_buffer(entry, err_buf, bytes_sent)
                if w == 1:
                    # Partially buffered; conn alive but pending.
                    return True
                # Any outcome (0 fully written or -1 error) — close after.
                keep_alive = False
                break

            # Optionally serve the 100 Continue interim.
            var interim_parked = False
            if outcome.expects_continue:
                if not enable_expect_continue:
                    # Server config disabled — respond 417 instead.
                    var err_buf = List[UInt8]()
                    build_error_response_bytes(UInt16(417), err_buf)
                    var ew = _write_all_or_buffer(entry, err_buf, bytes_sent)
                    if ew == 1:
                        return True
                    keep_alive = False
                    break
                var interim_buf = List[UInt8]()
                build_100_continue_bytes(interim_buf)
                var iw = _write_all_or_buffer(entry, interim_buf, bytes_sent)
                if iw == 1:
                    interim_parked = True
                if iw < 0:
                    keep_alive = False
                    break

            # Success path: emit the canned response (handler
            # dispatch is). Convert resp_buf into a List for the
            # write helper (same shape as the error path).
            var resp_list = List[UInt8]()
            var i = 0
            while i < resp_len:
                resp_list.append(resp_buf[i])
                i = i + 1
            if interim_parked:
                # The request is consumed: its response must follow the
                # parked interim, or it is never sent (komira-ai/komira#947).
                _park_behind(entry, resp_list)
                reqs_handled = reqs_handled + Int64(1)
                return True
            var rw = _write_all_or_buffer(entry, resp_list, bytes_sent)
            if rw == 1:
                # Partially buffered; conn alive but pending. Treat
                # this request as handled even though some bytes are
                # still in flight.
                reqs_handled = reqs_handled + Int64(1)
                return True
            if rw < 0:
                keep_alive = False
                break
            reqs_handled = reqs_handled + Int64(1)

            # If the request had a Content-Length, skip past those
            # bytes too so the next iteration starts at the next
            # pipelined request (or runs off the end of the buffer).
            var advance = outcome.headers_end_off
            if outcome.content_length > 0:
                advance = advance + outcome.content_length
                # Don't try to dereference past `got`; on the wire
                # the body may have been split across recvs.
                if off + advance > got:
                    # Body bytes not all present yet — drop (no multi-recv
                    # streaming on this path).
                    keep_alive = False
                    break

            # If the request asked for Connection: close, drop the conn
            # after responding.
            if outcome.connection_close:
                keep_alive = False
                break

            off = off + advance

    return keep_alive


# =============================================================================
# §5b — serve_read_round_chained: same as serve_read_round, but
#       routes successful requests through a MiddlewareChain instead of
#       writing the canned bytes. The chain runs middleware before/after
#       (including ErrorMappingMiddleware which converts raises → 500).
#       The resulting HttpResponse is serialized via `serialize_response`
#       and written to the wire.
# =============================================================================


def serve_read_round_chained(
    mut entry: ConnEntry,
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut chain: MiddlewareChain,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Handle one round of activity, routing through a MiddlewareChain.

    Identical to `serve_read_round` except: on parser-success, we build
    an HttpRequest, run it through `chain.run_with_canned(req, canned)`
    (where `canned` is a default 200 OK — the baseline; the dispatch
    variants swap in a Router-dispatched handler), and serialize the resulting
    HttpResponse into bytes to write on the wire.

    Returns:
      * True  — conn remains in the table (alive)
      * False — caller should drop the conn
    """
    var fd = entry._fd
    var keep_alive = True

    while keep_alive:
        var read_span = Span[UInt8](io_buf)
        var rr = try_io_read(fd, read_span)
        if rr.is_would_block():
            break
        if rr.is_error():
            keep_alive = False
            break
        var got = Int(rr.value())
        if got <= 0:
            keep_alive = False
            break

        var off = 0
        while off < got and keep_alive:
            var parse_span = Span[UInt8](io_buf)[off:got]
            var outcome = parse_request_head(parse_span, limits)

            if outcome.err.is_need_more():
                keep_alive = False
                break

            if not outcome.err.is_ok():
                var err_buf = List[UInt8]()
                build_error_response_bytes(outcome.err.status, err_buf)
                var w = _write_all_or_buffer(entry, err_buf, bytes_sent)
                if w == 1:
                    return True
                keep_alive = False
                break

            var interim_parked = False
            if outcome.expects_continue:
                if not enable_expect_continue:
                    var err_buf = List[UInt8]()
                    build_error_response_bytes(UInt16(417), err_buf)
                    var ew = _write_all_or_buffer(entry, err_buf, bytes_sent)
                    if ew == 1:
                        return True
                    keep_alive = False
                    break
                var interim_buf = List[UInt8]()
                build_100_continue_bytes(interim_buf)
                var iw = _write_all_or_buffer(entry, interim_buf, bytes_sent)
                if iw == 1:
                    interim_parked = True
                if iw < 0:
                    keep_alive = False
                    break

            # chain-integration path:
            # 1. Build an HttpRequest from the parsed outcome.
            # 2. Build a canned 200 OK as the "handler" stand-in.
            # 3. Run the chain.
            # 4. Serialize the chain's response.
            # 5. Write to the wire.
            #
            # NOTE: we move req out of `outcome.request` via swap.
            # The outcome struct is local; after consumption we don't
            # use it again on this iteration.
            var req = HttpRequest()
            swap(req.method, outcome.request.method)
            swap(req.path, outcome.request.path)
            swap(req.query_string, outcome.request.query_string)
            swap(req.headers, outcome.request.headers)
            swap(req.body, outcome.request.body)

            var canned = HttpResponse.ok(String("Hello, World!"))
            var chain_outcome = chain.run_with_canned(req^, canned^)

            var resp_list = List[UInt8]()
            serialize_response(chain_outcome.response, resp_list)
            if interim_parked:
                # As in `serve_read_round`: the response follows the parked
                # interim (komira-ai/komira#947).
                _park_behind(entry, resp_list)
                reqs_handled = reqs_handled + Int64(1)
                return True
            var rw = _write_all_or_buffer(entry, resp_list, bytes_sent)
            if rw == 1:
                reqs_handled = reqs_handled + Int64(1)
                return True
            if rw < 0:
                keep_alive = False
                break
            reqs_handled = reqs_handled + Int64(1)

            var advance = outcome.headers_end_off
            if outcome.content_length > 0:
                advance = advance + outcome.content_length
                if off + advance > got:
                    keep_alive = False
                    break

            if outcome.connection_close:
                keep_alive = False
                break

            off = off + advance

    return keep_alive


# =============================================================================
# §5c —: TLS-aware accept + read/write helpers.
# =============================================================================


def _set_fd_nonblock(fd: Int32) raises:
    """Set `fd` to non-blocking via the posix shim.

    s2n_negotiate on a blocking fd blocks indefinitely on
    read(). The TLS handshake driver requires non-blocking semantics
    so each s2n_negotiate call returns immediately with BLOCKED_ON_* on
    EWOULDBLOCK. Uses the `komira_fcntl_set_nonblock` shim (same as
    `src/komira_async/reactor/socket_setup.mojo:_create_listener`) to
    avoid the fcntl-variadic-ABI bug.
    """
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error(
            "_set_fd_nonblock(fd=" + String(Int(fd)) + ") returned "
            + String(Int(rc))
        )


def accept_one_and_register_tls(
    mut listener: TcpListener,
    mut reactor: Reactor[NoopSink],
    mut conns: Slab[ConnEntry],
    mut fd_to_idx: Dict[Int, Int],
    ref tls_config: TlsConfig,
) raises -> Int:
    """TLS-aware variant of `accept_one_and_register`.

    Same accept-and-register loop, but each accepted fd is set
    non-blocking and wrapped in a `TlsStream` BEFORE the ConnEntry is
    inserted into the slab. The initial state is
    `CONN_STATE_TLS_HANDSHAKE_IN`  — the server's first
    wait is on the ClientHello.

    The `tls_config` is borrowed (non-owning ref); it MUST outlive
    every conn this loop creates. HttpServer owns the config and lives
    longer than any individual ConnEntry by construction.

    Returns the number of NEW conns accepted in this call. Same shape
    as the plaintext accept loop.
    """
    var accepted = 0
    while True:
        var ar = listener.try_accept()
        if ar.is_would_block():
            break
        if ar.is_error():
            break
        var new_fd = Int32(Int(ar.value()))
        if new_fd < Int32(0):
            break
        # Stale-mapping sweep (same as the plaintext path).
        _sweep_stale_mapping(conns, fd_to_idx, new_fd)

        # Set the fd non-blocking BEFORE constructing the TlsStream —
        # otherwise s2n_negotiate would block on read() indefinitely.
        try:
            _set_fd_nonblock(new_fd)
        except e:
            _ = e
            # If we can't set non-blocking, the fd is unusable; close it
            # and skip this accept.
            _ = external_call["close", Int32](new_fd)
            continue

        # Construct the TlsStream first. If TlsConnection construction
        # fails (s2n OOM or set_config error), close the fd and skip.
        var tls_stream: TlsStream
        try:
            tls_stream = TlsStream(tls_config, new_fd)
        except e:
            _ = e
            _ = external_call["close", Int32](new_fd)
            continue

        var new_stream = TcpStream(new_fd)
        var new_reg = reactor.register_long_lived(new_fd, INTEREST_READ)
        # Use the TLS-aware ConnEntry constructor — starts in
        # CONN_STATE_TLS_HANDSHAKE_IN waiting for inbound ClientHello.
        var new_entry = ConnEntry(
            stream=new_stream^,
            reg=new_reg,
            tls_stream=tls_stream^,
            initial_state=UInt8(16),  # CONN_STATE_TLS_HANDSHAKE_IN
        )
        var new_idx = conns.len()
        conns.append(new_entry^)
        fd_to_idx[Int(new_fd)] = new_idx
        accepted = accepted + 1
    return accepted


def drive_tls_handshake(
    mut entry: ConnEntry,
) -> Tuple[UInt8, UInt8, UInt8]:
    """Step one round of the TLS handshake on this conn.

    Returns `(outcome, interest_mask, next_conn_state)`. Per design:
      - outcome           → TLS_OUTCOME_*
      - interest_mask     → INTEREST_READ / INTEREST_WRITE / 0 (close)
      - next_conn_state   → CONN_STATE_TLS_HANDSHAKE_IN/OUT (still
                            handshaking) / 0 (== CONN_STATE_READING,
                            handshake done, plaintext path resumes) /
                            255 (TLS_CONN_STATE_CLOSED — close on error).

    Pre-condition: `entry.is_tls() == True` (the caller branched on
    this before invoking). If the conn is not TLS, this is a no-op
    that returns ERROR + 0 mask.

    Updates the ConnEntry's interest_set; the caller is responsible
    for `reactor.modify(reg, mask)` if `mask != entry.interest_set()`.
    """
    # Borrow the Optional[TlsStream]; if it's None we treat as no-op.
    ref tls_opt = entry.tls_stream_ref()
    if not tls_opt:
        return (TLS_OUTCOME_ERROR, UInt8(0), TLS_CONN_STATE_CLOSED)
    ref tls = tls_opt.value()
    return tls.drive_handshake()


def serve_read_round_tls(
    mut entry: ConnEntry,
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    resp_buf: Array[UInt8, RESP_BUF_CAP],
    resp_len: Int,
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """TLS variant of `serve_read_round`.

    Same parse-then-dispatch flow as the plaintext variant, but:
      - Reads go through `TlsStream.read_app` (decrypts s2n's inbound
        record stream into plaintext bytes).
      - Writes go through `TlsStream.write_app` (encrypts before send).

    The HTTP/1.1 parser code (`parse_request_head`) is reused
    unchanged — it operates on decrypted plaintext bytes, the same as
    in the plaintext path.

    Returns:
      * True  — conn remains in the table (alive)
      * False — caller should drop the conn

    Pre-condition: `entry.is_tls() == True` AND the underlying
    TlsStream has `handshake_done() == True`. If the handshake hasn't
    completed, callers should route to `drive_tls_handshake` instead.

    Phase-1 caveat: this function omits the EWOULDBLOCK-on-write
    buffered-tail path. TLS's record layer batches writes; partial-
    write handling is territory if the canned 200 ever exceeds
    one record's worth (it doesn't — the response is ~92 bytes).
    """
    # Borrow the Optional[TlsStream]; the caller's pre-condition is
    # that this is Some.
    ref tls_opt = entry.tls_stream_ref()
    if not tls_opt:
        return False
    var keep_alive = True

    while keep_alive:
        # Reserve buf capacity then call read_app.
        var rd_buf = List[UInt8]()
        rd_buf.reserve(REQ_BUF_BYTES)
        rd_buf.resize(unsafe_uninit_length=REQ_BUF_BYTES)
        # The recv() helper writes into the List's backing storage and
        # resizes the List to the actual byte count.
        var read_outcome_and_n = tls_opt.value().read_app(
            rd_buf, REQ_BUF_BYTES,
        )
        var read_outcome = read_outcome_and_n[0]
        var got = read_outcome_and_n[1]
        if read_outcome == TLS_OUTCOME_BLOCKED_ON_READ:
            break
        if read_outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
            # Rare TLS-rekey case; treat as need-more-driver-loop.
            break
        if read_outcome == TLS_OUTCOME_ERROR:
            keep_alive = False
            break
        if got <= 0:
            # Peer sent close_notify (graceful EOF).
            keep_alive = False
            break

        # Copy the decrypted bytes into the io_buf scratch (the parser
        # consumes an InlineArray-backed Span).
        var copy_n = got
        if copy_n > REQ_BUF_BYTES:
            copy_n = REQ_BUF_BYTES
        var cc = 0
        while cc < copy_n:
            io_buf[cc] = rd_buf[cc]
            cc = cc + 1

        # Now run the same parse-then-dispatch loop as the plaintext path.
        var off = 0
        while off < copy_n and keep_alive:
            var parse_span = Span[UInt8](io_buf)[off:copy_n]
            var outcome = parse_request_head(parse_span, limits)

            if outcome.err.is_need_more():
                keep_alive = False
                break

            if not outcome.err.is_ok():
                var err_buf = List[UInt8]()
                build_error_response_bytes(outcome.err.status, err_buf)
                if not _tls_write_all(entry, err_buf, bytes_sent):
                    keep_alive = False
                    break
                keep_alive = False
                break

            if outcome.expects_continue:
                if not enable_expect_continue:
                    var err_buf = List[UInt8]()
                    build_error_response_bytes(UInt16(417), err_buf)
                    if not _tls_write_all(entry, err_buf, bytes_sent):
                        keep_alive = False
                        break
                    keep_alive = False
                    break
                var interim_buf = List[UInt8]()
                build_100_continue_bytes(interim_buf)
                if not _tls_write_all(entry, interim_buf, bytes_sent):
                    keep_alive = False
                    break

            # Success path: emit the canned response.
            var resp_list = List[UInt8]()
            var i = 0
            while i < resp_len:
                resp_list.append(resp_buf[i])
                i = i + 1
            if not _tls_write_all(entry, resp_list, bytes_sent):
                keep_alive = False
                break
            reqs_handled = reqs_handled + Int64(1)

            var advance = outcome.headers_end_off
            if outcome.content_length > 0:
                advance = advance + outcome.content_length
                if off + advance > copy_n:
                    keep_alive = False
                    break

            if outcome.connection_close:
                keep_alive = False
                break

            off = off + advance

    return keep_alive


def _tls_write_all(
    mut entry: ConnEntry,
    bytes: List[UInt8],
    mut bytes_sent: Int64,
) -> Bool:
    """Write all bytes via the TlsStream, looping on BLOCKED_ON_*.

    Returns True on full success, False on hard error.

    Phase-1 simplification: this blocks the accept-loop iteration on
    a BLOCKED_ON_WRITE retry. A full reactor-driven write-resume path
    (analog to `_write_all_or_buffer` for the plaintext side) is
    territory. For the-shape canned 200 OK (~92 bytes), the s2n
    record layer accepts the whole thing in one s2n_send call ~always
    on a freshly-handshaked conn.
    """
    ref tls_opt = entry.tls_stream_ref()
    if not tls_opt:
        return False
    var n = len(bytes)
    var sent_off = 0
    while sent_off < n:
        var tail_span = Span[UInt8](bytes)[sent_off:n]
        var oc_n = tls_opt.value().write_app(tail_span)
        var oc = oc_n[0]
        var sent_n = oc_n[1]
        if oc == TLS_OUTCOME_ERROR:
            return False
        if oc == TLS_OUTCOME_BLOCKED_ON_READ:
            # TLS rekey race; bail and let the reactor re-fire.
            return False
        if oc == TLS_OUTCOME_BLOCKED_ON_WRITE:
            # Phase-1 simplification: in the absence of the TLS
            # write-buffering path, treat as failed-this-round.
            return False
        if sent_n <= 0:
            return False
        sent_off = sent_off + sent_n
    bytes_sent = bytes_sent + Int64(n)
    return True


# =============================================================================
# §6 — Resume buffered-tail write after EPOLLOUT.
# =============================================================================


@always_inline
def resume_pending_write(
    mut entry: ConnEntry,
    mut bytes_sent: Int64,
) -> Bool:
    """Resume the buffered-tail write after the reactor signaled EPOLLOUT.

    Returns:
      * True  — write fully drained; caller should switch interest BACK
                to INTEREST_READ and entry's state is now CONN_STATE_READING.
      * False — either still backed up (state stays WAITING_FOR_WRITABLE)
                OR hard error (entry._pending_len == -1 sentinel; caller
                should close).
    """
    var fd = entry._fd
    # A single EPOLLOUT may only drain PART of a large tail. This loop
    # writes as much as the kernel accepts this round; if the socket fills
    # again it returns False (caller keeps INTEREST_WRITE armed and the
    # next EPOLLOUT re-enters here, advancing _pending_off further). The
    # connection stays in WAITING_FOR_WRITABLE until _pending_off ==
    # _pending_len, so an arbitrarily large response drains across
    # however many writable events it takes.
    while entry._pending_off < entry._pending_len:
        var rem = entry._pending_len - entry._pending_off
        var span_full = Span[UInt8](entry._pending_buf)
        var slice_span = span_full[entry._pending_off:entry._pending_off + rem]
        var wr = try_io_write(fd, slice_span)
        if wr.is_would_block():
            # Socket backed up again mid-tail; stay WAITING_FOR_WRITABLE.
            # Caller leaves INTEREST_WRITE armed; the next EPOLLOUT resumes.
            return False
        if wr.is_error():
            entry._pending_len = -1
            return False
        var sent_n = Int(wr.value())
        if sent_n <= 0:
            entry._pending_len = -1
            return False
        entry._pending_off = entry._pending_off + sent_n
        bytes_sent = bytes_sent + Int64(sent_n)
    # Fully drained; reset + free the backing storage so a long-lived
    # keep-alive conn does not retain a large buffer after a big response.
    entry._pending_buf.clear()
    entry._pending_off = 0
    entry._pending_len = 0
    entry._state = CONN_STATE_READING
    return True
