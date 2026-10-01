# =============================================================================
# src/komira_http/transport/dispatch.mojo — route→handler dispatch hook
# =============================================================================
#
# The server leaf is a CANNED response: `serve_read_round` writes a
# pre-built "Hello, World!" for every request, and `serve_read_round_chained`
# runs the middleware chain but still bottoms out on a canned 200. Neither
# routes the parsed request to a per-(METHOD, path) handler.
#
# This file adds the missing leaf: a `RequestDispatcher` trait (the
# application's request→response surface) + a `serve_read_round_dispatch[D, RT]`
# transport round that drives the SAME parse / pipeline / EWOULDBLOCK-buffer
# machinery as `serve_read_round`, but replaces the canned write with a real
# `dispatcher.dispatch[RT](reactor, parsed_request) -> HttpResponse`.
#
# This is the genuine reuse seam: the reactor accept loop, the RFC-7230
# parser, the per-conn state machine, and the partial-write buffering all
# stay in `komira_http` unchanged; an application package plugs ONE
# conformer in and gets a runnable service.
#
# `dispatch` is `[RT: Runtime]`-
# parametric and receives `mut reactor: Reactor[RT.Sink]` — the SERVER'S OWN
# reactor (the one its accept loop is already polling). A handler that performs
# async I/O (e.g. a heartbeat handler driving `[RT]` DB reads) PARKS on the
# SAME reactor that serves HTTP, so a slow DB write yields to serving other
# requests (under a non-blocking runtime) rather than blocking a disjoint
# internal event loop. The `[RT]` is supplied by the server's
# `serve_*_dispatch[D, RT]` call site; `RT.Sink` must match the server reactor's
# sink (today `NoopSink`). A no-I/O handler simply ignores the reactor.
#
# ENCAPSULATION: the dispatcher surface is value-typed — `HttpRequest` in
# (moved), `HttpResponse` out (moved). The reactor is a `mut` borrow threaded
# per-call (never stored — no wildcard-origin field, no borrow held across the
# accept-loop poll). No UnsafePointer crosses the boundary; no wildcard origin.
# The `[D: RequestDispatcher, RT: Runtime]` parameters are comptime-
# monomorphized (no dynamic dispatch). pointer-free: nothing here is stored in
# a byte-slab.
# =============================================================================

from std.ffi import external_call

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_io import try_io_read
from komira_async.runtime.shared_erasure import (
    ErasedHandlerDriver,
    ErasedHandlerFrame,
)
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.suspendable_handler import (
    SuspendableHandler,
    SuspendableHandlerDriver,
    SuspendedFrame,
)

from komira_http.codec.h1.chunked import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    ChunkedDecoder,
    decode_block,
)
from komira_http.codec.h1.parser import (
    build_100_continue_bytes,
    build_error_response_bytes,
    parse_request_head,
)
from komira_http.codec.h1.limits import ParseLimits
from komira_http.codec.response_framing import (
    response_may_be_chunked,
    serialize_response_framed,
)
from komira_http.codec.types import (
    HTTP_METHOD_HEAD,
    HttpRequest,
    HttpResponse,
    serialize_response,
)
from komira_http.middleware.chain import MiddlewareChain
from komira_http.middleware.fault_report import (
    FAULT_CODE_TRANSPORT,
    WIRING_UNWIRED_UNKNOWN,
    observe_error_response,
    report_fault,
    trace_header_of,
)
from komira_http.middleware.middleware import Middleware, RequestContext
from komira_http.transport.accept_loop import _write_all_or_buffer
from komira_http.transport.connection import (
    ConnEntry,
    REQ_BUF_BYTES,
)


# =============================================================================
# §0 — M-2 body-accumulation helpers (cross-recv Content-Length buffering).
# =============================================================================
#
# These are the leaf of the M-2 fix: the dispatch round copies whatever body
# bytes are present in the current recv buffer, then — when the declared
# Content-Length is split across recvs — drains the remainder into the
# request's `req.body` (a heap-owning `List[UInt8]`) before dispatching.
#
# ENCAPSULATION: no UnsafePointer crosses any boundary here. `accumulate_body_
# remainder` reads into a stack-local `InlineArray` scratch buffer and copies
# bytes into the caller's `out_body: List[UInt8]` by value. pointer-free:
# `out_body` is a stack-local request field, never stored in a byte-slab.

# Per-WOULD_BLOCK-retry budget. The body bytes are already in flight on the
# socket (the client sent Content-Length bytes), so they arrive within a small
# spin; between empty reads we `sched_yield` to avoid a hot busy-loop. The
# total budget bounds a stalled/slow client so a half-sent body can't pin the
# serve thread forever (the conn is dropped and the client retries).
comptime _BODY_RECV_MAX_EMPTY_SPINS: Int = 100_000

# Scratch read buffer size for the remainder drain — one page-ish chunk.
comptime _BODY_RECV_CHUNK: Int = 4096


def body_end_in_buf(body_start: Int, content_length: Int, got: Int) -> Int:
    """The exclusive end offset of the body bytes that are PRESENT in the
    current recv buffer (`io_buf[0:got]`). The body wants
    `[body_start : body_start + content_length)`, but only up to `got` bytes
    were recv'd, so the present portion ends at `min(body_start +
    content_length, got)`."""
    var want_end = body_start + content_length
    if want_end < got:
        return want_end
    return got


def reserve_declared_body(mut out_body: List[UInt8], content_length: Int):
    """Reserve room for a body of `content_length` bytes BEFORE accumulating it.

    `out_body` is grown by per-byte `append`, so without a reservation it
    reallocates geometrically: the final doubling holds the old buffer (N) and
    the new one (2N) at the same instant, so a body of N bytes transiently costs
    up to 3N resident. `Content-Length` is a number the client already told us;
    accumulating without using it pays that 3x peak for information we were
    handed.

    ⚠ THIS DOES NOT HELP A `git push`, AND SAYING SO IS THE POINT. Measured with
    `GIT_TRACE_CURL` against stock git 2.50.1: the receive-pack POST that
    carries the packfile is sent `Transfer-Encoding: chunked` (only the tiny
    4-byte probe POST that precedes it uses Content-Length). A chunked body
    declares no length, so this reservation never fires on the push path and the
    3x doubling transient there is still live — see
    `accumulate_chunked_body`.
    This helper is correct and worth having for Content-Length clients; it is
    not the git-push lever and must not be cited as one.

    Guarded: only a positive declared length is honoured. The parser has already
    rejected anything over `limits.max_body_bytes` with a 413, so this cannot be
    turned into an allocation oracle by a lying `Content-Length` — but the
    `<= 0` guard keeps it honest independently of that.
    """
    if content_length > 0:
        out_body.reserve(content_length)


def accumulate_body_remainder(
    fd: Int32, mut out_body: List[UInt8], needed: Int
) -> Bool:
    """Read `needed` more body bytes from `fd` into `out_body`, across as many
    recvs as it takes (the M-2 cross-recv accumulation).

    Returns True once all `needed` bytes are appended; False if the peer closed
    the read side (clean EOF / `got==0`) or a hard recv error occurred before
    the full body arrived (a truncated request — caller drops the conn).

    The socket is non-blocking; on WOULD_BLOCK we `sched_yield` and retry up to
    a bounded spin budget (the body is already in flight, so it lands quickly).
    Exceeding the budget returns False (a stalled client — drop, don't hang)."""
    var remaining = needed
    var empty_spins = 0
    var scratch = Array[UInt8, _BODY_RECV_CHUNK](fill=UInt8(0))
    while remaining > 0:
        var want = remaining
        if want > _BODY_RECV_CHUNK:
            want = _BODY_RECV_CHUNK
        var span = Span[UInt8](scratch)[0:want]
        var rr = try_io_read(fd, span)
        if rr.is_would_block():
            empty_spins = empty_spins + 1
            if empty_spins > _BODY_RECV_MAX_EMPTY_SPINS:
                return False
            _ = external_call["sched_yield", Int32]()
            continue
        if rr.is_error():
            return False
        var got = Int(rr.value())
        if got <= 0:
            # Peer closed the read side before sending the full body.
            return False
        var k = 0
        while k < got:
            out_body.append(scratch[k])
            k = k + 1
        remaining = remaining - got
        empty_spins = 0
    return True


# -----------------------------------------------------------------------------
# §0b — Transfer-Encoding: chunked REQUEST bodies.
# -----------------------------------------------------------------------------
#
# ★ WHY THIS EXISTS. `parse_request_head` DETECTS chunked framing
# (`HeadersParseOutcome.is_chunked`) and `codec/h1/chunked.mojo` carries a
# complete RFC 7230 §4.1 decoder — and a SERVER round must drive the
# two together. A transport that reads `content_length` only sees a chunked
# request arrive with `content_length == -1`, never reads the body, and its
# pipelining `advance` then re-parses the chunk-size line (`1ffb\r\n...`) as a
# fresh request line -> 400.
#
# That is not a corner case: **stock `git push` switches to
# `Transfer-Encoding: chunked` for any push whose payload exceeds
# `http.postBuffer` (1 MiB by default)**, so without this every real-sized push
# is answered `HTTP 400` with `fatal: the remote end hung up
# unexpectedly`. Measured on git 2.50.1: a 900 KiB push succeeds, a 2 MiB push
# is refused; the SAME 2 MiB push with `-c http.postBuffer=64m` (which forces
# Content-Length framing) succeeds — the payload is not the problem, the
# framing is.
#
# NOT the same concern as `Content-Encoding: gzip`. Transfer-Encoding is HOP-BY-HOP FRAMING and belongs
# here in the transport; Content-Encoding is an END-TO-END payload
# representation and belongs to whoever consumes the payload. Both surface as a
# 400 on a body-carrying POST, but a fix in either layer alone leaves the other
# request shape broken.

# `accumulate_chunked_body` return codes. Deliberately NOT a Bool: the caller
# must distinguish a client FRAMING error (answer 400 — the request was
# malformed) from a TRANSPORT failure (drop the conn — there is nobody to
# answer). Collapsing the two is how a malformed body becomes a silent hangup.
comptime CHUNKED_BODY_OK: Int = 0
comptime CHUNKED_BODY_MALFORMED: Int = 1
comptime CHUNKED_BODY_TRANSPORT_FAILED: Int = -1


def accumulate_chunked_body(
    fd: Int32,
    seed: Span[UInt8, _],
    limits: ParseLimits,
    mut out_body: List[UInt8],
) -> Int:
    """Decode a `Transfer-Encoding: chunked` request body into `out_body`.

    `seed` is the portion of the chunked body already sitting in the current
    recv buffer (possibly empty). The remainder is drained from `fd` across as
    many recvs as it takes, exactly like `accumulate_body_remainder` does for a
    split Content-Length body — the difference is that a chunked body has NO
    declared length, so the terminating `0\\r\\n\\r\\n` is what ends the read.

    Returns one of `CHUNKED_BODY_OK` / `CHUNKED_BODY_MALFORMED` /
    `CHUNKED_BODY_TRANSPORT_FAILED`.

    Body size is bounded by `limits.max_body_bytes` — `decode_block` counts
    emitted bytes and fails the decode past the cap, so an endless chunk stream
    cannot exhaust memory (this is the one bound a chunked body has, since the
    client declares no length up front).

    PIPELINING: bytes recv'd PAST the terminating chunk are dropped. Neither
    `git` nor `curl` pipelines a second request behind a chunked body, and this
    round already declines cross-recv head buffering (`err.is_need_more()` drops
    the conn), so this does not narrow what the transport supports. The caller
    marks `body_split` so the in-buffer pipelining scan stops.

    ENCAPSULATION: `pending` / `out_body` are plain `List[UInt8]` locals owned by
    this frame and the caller's request; the recv lands in a stack `InlineArray`.
    No UnsafePointer crosses a boundary; nothing here is stored in a byte-slab.
    """
    var dec = ChunkedDecoder.init()
    var pending = List[UInt8]()
    for i in range(len(seed)):
        pending.append(seed[i])

    var empty_spins = 0
    var scratch = Array[UInt8, _BODY_RECV_CHUNK](fill=UInt8(0))
    while True:
        if len(pending) > 0:
            var res = decode_block(dec, Span[UInt8](pending), limits, out_body)
            if res.outcome == CHUNKED_RES_ERROR:
                return CHUNKED_BODY_MALFORMED
            if res.consumed > 0:
                # Drop the consumed prefix; the decoder is incremental and only
                # the unconsumed tail must be re-offered with the next recv.
                var tail = List[UInt8](capacity=len(pending) - res.consumed)
                for i in range(res.consumed, len(pending)):
                    tail.append(pending[i])
                pending = tail^
            if res.outcome == CHUNKED_RES_DONE:
                return CHUNKED_BODY_OK

        # NEED_MORE — the decoder wants bytes that have not arrived yet.
        var span = Span[UInt8](scratch)
        var rr = try_io_read(fd, span)
        if rr.is_would_block():
            empty_spins = empty_spins + 1
            if empty_spins > _BODY_RECV_MAX_EMPTY_SPINS:
                return CHUNKED_BODY_TRANSPORT_FAILED
            _ = external_call["sched_yield", Int32]()
            continue
        if rr.is_error():
            return CHUNKED_BODY_TRANSPORT_FAILED
        var got = Int(rr.value())
        if got <= 0:
            # Peer closed before the terminating chunk — a truncated request.
            return CHUNKED_BODY_TRANSPORT_FAILED
        for k in range(got):
            pending.append(scratch[k])
        empty_spins = 0


# =============================================================================
# §1 — RequestDispatcher: the application request→response surface.
# =============================================================================


trait RequestDispatcher(Movable, Deinitable):
    """The application's per-request handler surface — the leaf the server
    invokes once a request has been parsed.

    A conformer inspects `req.method` / `req.path` (and body / headers),
    routes to the right handler, and returns the `HttpResponse`. It owns ALL
    routing + handler logic; the server only owns transport. Errors surface
    via `raises` — the dispatcher is responsible for mapping its own domain
    errors to HTTP status codes (the server does NOT have a domain-error
    mapper; an uncaught raise becomes a 500 by the round's catch).

    The single method takes `mut self` so a stateful dispatcher (e.g. one
    owning a `JobManager` that mutates a DB) can drive its state on each
    request.

    `dispatch` is `[RT: Runtime]`-parametric and
    receives `mut reactor: Reactor[RT.Sink]` — the SERVER'S OWN reactor (the
    one its accept loop is already polling on). A handler that performs async
    I/O (e.g. a heartbeat handler driving `[RT]` DB reads) PARKS on the SAME
    reactor that serves HTTP, instead of standing up an internal runtime. So a
    slow DB write yields to serving other requests (under a non-blocking
    runtime) rather than blocking on a disjoint event loop. A no-I/O handler
    (a `/health` 200) simply ignores the reactor. The `[RT]` is supplied by the
    server's `serve_*_dispatch[D, RT]` call site; `RT.Sink` must match the
    server's reactor sink type (today `NoopSink`).
    """

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        ...


# =============================================================================
# §1b — CtxRequestDispatcher: the middleware-aware dispatch surface.
# =============================================================================
#
# the plain `RequestDispatcher`
# above receives ONLY `(reactor, req)` — so a `RequestDispatcher` that needs an
# identity had to resolve the `Authorization: Bearer` token
# ITSELF inside `dispatch`, duplicating what an `AuthMiddleware` already does.
# That is the gap this trait closes: a `CtxRequestDispatcher` ADDITIONALLY
# accepts the per-request `RequestContext` the middleware chain has already
# populated (`ctx.authed_user` set by an auth middleware's `before`, or a 401
# short-circuit that means `dispatch_with_ctx` is never reached at all). The
# dispatcher then READS `ctx.authed_user` instead of re-resolving the token.
#
# It REFINES `RequestDispatcher` (a `CtxRequestDispatcher` IS a
# `RequestDispatcher`), so a conformer that opts into the middleware path
# implements BOTH `dispatch` (the chain-less path, unchanged) AND
# `dispatch_with_ctx` (the chained path). The chain-less serve variants keep
# calling `dispatch`; the new chained serve variant calls `dispatch_with_ctx`.
# Conformers that do NOT need middleware (JobDispatcher, McpHttpDispatcher) stay
# on plain `RequestDispatcher` and are completely untouched — this is purely
# additive, no existing conformer changes.
#
# ENCAPSULATION: `ctx` is a value-typed `RequestContext` (a POD — scalars +
# an `Optional[AuthedUser]`, itself two inline `Uuid`s; no heap, no pointer). It
# is passed by `read` (immutable borrow) — the dispatcher reads the identity but
# does not own or mutate the chain's context.


trait CtxRequestDispatcher(RequestDispatcher):
    """A `RequestDispatcher` that ALSO accepts the middleware-populated
    `RequestContext` (the identity the auth middleware resolved). Conform to
    this (instead of bare `RequestDispatcher`) when the dispatcher's handlers
    read `ctx.authed_user` rather than resolving the bearer themselves.

    A conformer implements BOTH:
      * `dispatch[RT](reactor, req)` — the chain-less path (RequestDispatcher).
      * `dispatch_with_ctx[RT](reactor, req, ctx)` — the chained path: the
        middleware chain has already run its `before` legs (auth resolved
        `ctx.authed_user` or short-circuited 401 before this is reached), so
        the dispatcher reads the identity off `ctx` instead of re-resolving.

    The two are usually trivially related — `dispatch` builds an empty/anon
    `RequestContext` and calls `dispatch_with_ctx`; the chained serve path
    supplies the populated one.
    """

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        ...


# -----------------------------------------------------------------------------
# `consumable_request_for` — the chained seam's BORROW -> OWNED adapter, for a
# dispatcher whose sub-dispatchers CONSUME the request.
#
# WHY IT IS NEEDED. `dispatch_with_ctx` takes `mut req` because the chain must
# keep the request alive for its `after` legs; `dispatch` takes `var req` because
# a composite hands it DOWN to an owning sub-dispatcher. `HttpRequest` is Movable
# but deliberately NOT Copyable, so a composite bridging the two needs one
# explicit, deliberate split — and this is it, in ONE place with ONE rationale
# rather than re-derived at each app.
#
# WHAT IT MOVES AND WHAT IT COPIES, AND WHY THAT SPLIT AND NOT ANOTHER:
#   * `body` + `path_params` are MOVED. The body is the expensive field (a
#     packfile push is tens of MiB) and NO `after` leg reads either one.
#   * `method`, `path`, `query_string`, `headers` are COPIED, so `req` is still
#     INTACT for the legs that run after the dispatcher returns:
#     `LoggingMiddleware.after` / `TracingMiddleware.after` read `req.method` +
#     `req.path`, and the ErrorMapper path reads both plus `trace_header_of(req)`
#     — the `X-Cloud-Trace-Context` that correlates a 500 with Cloud Logging.
#     Moving the headers out to save a small dict copy would silently drop that
#     correlation on exactly the responses that need it most.
# -----------------------------------------------------------------------------


def consumable_request_for(mut req: HttpRequest) -> HttpRequest:
    """Split a chain-borrowed `req` into an OWNED `HttpRequest` a consuming
    `RequestDispatcher` can take, leaving `req` intact for the chain's `after`
    legs (method / path / query / headers preserved; body + path_params moved).

    For a `CtxRequestDispatcher` whose routing fans out to sub-dispatchers that
    take `var req` — a composite of several services is the worked example."""
    var owned = HttpRequest()
    owned.method = req.method
    owned.path = String(req.path)
    owned.query_string = String(req.query_string)
    owned.headers = req.headers.copy()
    swap(owned.body, req.body)
    swap(owned.path_params, req.path_params)
    return owned^


# =============================================================================
# §2 — serve_read_round_dispatch[D] — parse → dispatch → serialize → write.
# =============================================================================


def serve_read_round_dispatch[
    D: RequestDispatcher,
    RT: Runtime,
](
    mut entry: ConnEntry,
    mut reactor: Reactor[RT.Sink],
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut dispatcher: D,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
    trace_project: String,
) -> Bool:
    """One round of activity on a connection, routing parser-success through
    `dispatcher.dispatch[RT](reactor, req)` instead of writing canned bytes.

    Structurally identical to `serve_read_round` (recv → parse-loop over the
    buffer for pipelining → per-request response → EWOULDBLOCK-buffer the
    tail), with the canned-response leaf swapped for the real dispatch:
      1. Build an `HttpRequest` from the parser outcome.
      2. `response = dispatcher.dispatch[RT](reactor, req)` — if it raises,
         emit a 500.
      3. `serialize_response(response)` → bytes → `_write_all_or_buffer`.

    `reactor` is the SERVER'S reactor (the one
    the accept loop polls), threaded in so the handler's async I/O parks on it
    — a single event loop serving HTTP + DB. The `[RT]` is supplied by the
    caller (`HttpServer.serve_*_dispatch[D, RT]`); `RT.Sink` must equal the
    server reactor's sink type.

    `trace_project` qualifies the trace on the fault and error-response log
    lines (`HttpServerConfig.trace_project`); empty omits the canonical trace
    field.

    Returns:
      * True  — conn remains alive in the table.
      * False — caller should drop the conn.
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
                # Partial request: no cross-recv buffering at this layer.
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
                    return True
                if iw < 0:
                    keep_alive = False
                    break

            # Build the HttpRequest from the parsed outcome (move the
            # heap-owning fields out via swap — `outcome` is a local that
            # is not reused on this iteration after consumption).
            var req = HttpRequest()
            swap(req.method, outcome.request.method)
            swap(req.path, outcome.request.path)
            swap(req.query_string, outcome.request.query_string)
            swap(req.headers, outcome.request.headers)

            # CHUNKED-RESPONSE SEAM. Capture the two request facts
            # the framing gate needs BEFORE `req` is moved into the dispatcher.
            # This round is the ONLY layer that holds them: `HttpRequest` carries
            # no HTTP version, and by the time a response exists the request is
            # gone. See `codec/response_framing.mojo` for why the gate cannot
            # live with the handler.
            var req_http_minor = outcome.http_version_minor
            var req_is_head = req.method.code == HTTP_METHOD_HEAD

            # `parse_request_head` parses only the HEAD; the body lives in the
            # recv buffer at `[off + headers_end_off : ... + content_length]`.
            # Copy it into the request so the handler sees the body.
            #
            # M-2 fix: a Content-Length body may be SPLIT across recvs (large
            # body, or a slow/segmented client). The parser validated the head
            # and already rejected over-`max_body_bytes` Content-Length with a
            # 413 (PARSE_ERR_BODY_TOO_LARGE), so the declared length here is
            # bounded. We copy whatever body bytes are present in `io_buf`, then
            # — if the full declared length is NOT yet buffered — accumulate the
            # remainder across additional recvs into `req.body` before
            # dispatching. Previously a split body was dropped (handler saw an
            # empty body) and the conn was closed, so any large heartbeat
            # failure report (`stderr_tail` can be many KB) never completed.
            #
            # `body_split` records that we drained body bytes from recvs PAST the
            # current `io_buf`; when set, the pipelining loop must stop after this
            # request (the original buffer holds no further pipelined requests —
            # those bytes were consumed by the dedicated body reads below).
            var body_split = False
            if outcome.content_length > 0:
                reserve_declared_body(req.body, outcome.content_length)
                var body_start = off + outcome.headers_end_off
                # Bytes of the body already sitting in the current io_buf window.
                var present_end = body_end_in_buf(
                    body_start, outcome.content_length, got
                )
                var bi = body_start
                while bi < present_end:
                    req.body.append(io_buf[bi])
                    bi = bi + 1

                var still_needed = outcome.content_length - (
                    present_end - body_start
                )
                if still_needed > 0:
                    # The body is split across recvs — read the remainder into
                    # `req.body`. `req.body` is a heap-owning List[UInt8] owned by
                    # `req` (a stack local, moved into dispatch below); appending
                    # here is pointer-safe — it is NOT a field of any byte-slab.
                    body_split = True
                    if not accumulate_body_remainder(
                        fd, req.body, still_needed
                    ):
                        # Peer closed or hard error before the full body arrived
                        # (a truncated request). Drop the conn rather than
                        # dispatch a partial body.
                        keep_alive = False
                        break
            elif outcome.is_chunked:
                # `Transfer-Encoding: chunked` — no declared length, so
                # drive the RFC 7230 §4.1 decoder to the terminating chunk. This
                # is the framing stock `git push` uses above `http.postBuffer`
                # (1 MiB), so before this arm every real-sized push got a 400.
                # `body_split` is unconditional: a chunked body has no in-buffer
                # length to advance past, so the pipelining scan must stop.
                body_split = True
                var seed_start = off + outcome.headers_end_off
                var chunk_rc = accumulate_chunked_body(
                    fd,
                    Span[UInt8](io_buf)[seed_start:got],
                    limits,
                    req.body,
                )
                if chunk_rc == CHUNKED_BODY_MALFORMED:
                    # The client's framing was bad — SAY so (400) rather than
                    # hanging up, which is what a Bool-returning helper would
                    # have forced.
                    var cerr_buf = List[UInt8]()
                    build_error_response_bytes(UInt16(400), cerr_buf)
                    var cw = _write_all_or_buffer(entry, cerr_buf, bytes_sent)
                    if cw == 1:
                        return True
                    keep_alive = False
                    break
                if chunk_rc == CHUNKED_BODY_TRANSPORT_FAILED:
                    keep_alive = False
                    break

            # Dispatch to the application handler. An uncaught raise → an
            # ATTRIBUTED 500 (the dispatcher is still responsible for mapping
            # its own domain errors to specific 4xx/409/etc. status codes — a
            # deliberate refusal RETURNS its own response and never lands here).
            #
            # ⛔ THIS ARM MUST NOT BE `except e: _ = e`. That discards the one
            # artifact naming the cause and answers a 500 with
            # `content-length: 0` — an unexplainable 500. `req` is consumed by `dispatch`, so the method +
            # path are captured BEFORE the call.
            var response: HttpResponse
            var fault_method = req.method.name()
            var fault_path = String(req.path)
            var fault_trace = trace_header_of(req)
            var reported_as_fault = False
            try:
                response = dispatcher.dispatch[RT](reactor, req^)
            except e:
                reported_as_fault = True
                response = report_fault(
                    e,
                    Int32(500),
                    FAULT_CODE_TRANSPORT,
                    fault_method,
                    fault_path,
                    String("Internal Server Error"),
                    WIRING_UNWIRED_UNKNOWN,
                    fault_trace,
                    trace_project,
                )

            # ARM 2 — a 5xx the dispatcher RETURNED. A deliberate,
            # correct, operator-actionable 503 RETURNS rather than raises,
            # so a diagnostic hung off the `except` arm above misses it
            # entirely, and silence in the logs reads as a defect.
            #
            # OBSERVED, NEVER REWRITTEN: `observe_error_response` takes the
            # response by `ref` and returns nothing. `reported_as_fault` stops
            # a raise-path 500 being logged twice under two different `source`
            # values, which would make the two arms indistinguishable again.
            if not reported_as_fault:
                observe_error_response(
                    response,
                    fault_method,
                    fault_path,
                    fault_trace,
                    trace_project,
                )

            var resp_list = List[UInt8]()
            # A response that never called `mark_chunked()` serializes
            # BYTE-IDENTICALLY to `serialize_response`, so the gate changes
            # nothing for a handler that does not ask for chunking.
            serialize_response_framed(
                response,
                response_may_be_chunked(
                    response.status, req_http_minor, req_is_head
                ),
                resp_list,
            )
            var rw = _write_all_or_buffer(entry, resp_list, bytes_sent)
            if rw == 1:
                reqs_handled = reqs_handled + Int64(1)
                return True
            if rw < 0:
                keep_alive = False
                break
            reqs_handled = reqs_handled + Int64(1)

            if outcome.connection_close:
                keep_alive = False
                break

            # M-2: if the body was accumulated across recvs (body_split), the
            # current io_buf does NOT contain the trailing body bytes (they were
            # drained by `accumulate_body_remainder` from later recvs), so there
            # is no in-buffer offset to advance to a next pipelined request.
            # Re-enter the outer recv loop for the next request on this conn.
            if body_split:
                break

            var advance = outcome.headers_end_off
            if outcome.content_length > 0:
                advance = advance + outcome.content_length
                if off + advance > got:
                    # Body wholly in-buffer was expected but isn't fully present
                    # AND wasn't split-accumulated — defensive: drop. (With the
                    # M-2 accumulation above this branch is unreachable for
                    # content_length > 0, since any shortfall set body_split.)
                    keep_alive = False
                    break

            off = off + advance

    return keep_alive


# =============================================================================
# §3 — run the chain AROUND the dispatcher.
# =============================================================================
#
# `_drive_chain_dispatch[D, M, RT]` is the leaf that wires the chain in:
# the middleware chain's `before` legs run (CORS / Tracing / Logging, then the
# auth middleware which resolves `ctx.authed_user` OR short-circuits 401), and
# ONLY IF NOT short-circuited does the `CtxRequestDispatcher` run — with the
# populated `ctx` handed to it. Then the `after` legs run in reverse. The whole
# thing is wrapped in the chain's ErrorMapper try (an uncaught raise from any
# leg or the dispatcher → a sanitized 500 via `chain.map_chain_error`).
#
# The dispatcher invocation lives HERE (in the transport module) rather than in
# the chain, because the chain cannot depend on the transport's
# `RequestDispatcher` trait without a module cycle (the transport already
# imports the chain). The chain exposes `run_before_legs` / `run_after_legs` /
# `map_chain_error` so the ordering + ErrorMapper contract stay owned by the
# chain; this driver only owns the "run the dispatcher between the legs" step.


def _drive_chain_dispatch[
    D: CtxRequestDispatcher,
    M: Middleware,
    RT: Runtime,
](
    mut chain: MiddlewareChain,
    mut auth_mw: M,
    mut dispatcher: D,
    mut reactor: Reactor[RT.Sink],
    var req: HttpRequest,
) -> HttpResponse:
    """Drive the chain AROUND `dispatcher.dispatch_with_ctx[RT]`.

    Order:  ErrorMapper(outermost try)
            → CORS.before → Tracing.before → Logging.before → auth.before
            → (dispatcher, only if no short-circuit)
            → auth.after → Logging.after → Tracing.after → CORS.after

    The auth middleware's `before` either attaches `ctx.authed_user` (continue
    → the dispatcher runs and reads the identity off `ctx`) or short-circuits
    `Some(401)` (the dispatcher is NEVER reached). ALWAYS returns a response.
    """
    var ctx = RequestContext.new()
    var response: HttpResponse
    var auth_before_ran = False
    # ARM-2 BOOKKEEPING (see the `observe_error_response` call below). A raise
    # that `map_chain_error` already reported must NOT be observed a second
    # time under a different `source`, which would make the two arms
    # indistinguishable again — the same guard `serve_read_round_dispatch`
    # spells as `reported_as_fault`.
    var reported_as_fault = False

    try:
        var sc = chain.run_before_legs[M](req, ctx, auth_mw, auth_before_ran)
        if sc:
            # A leg short-circuited (auth 401, or a CORS preflight, etc.) — the
            # dispatcher is NEVER reached.
            response = sc.take()
        else:
            # Not short-circuited — run the dispatcher WITH the populated ctx
            # (auth attached `ctx.authed_user`; the dispatcher reads it). `req`
            # is a MUT BORROW here (not consumed) so it stays alive for the
            # `after` legs below.
            response = dispatcher.dispatch_with_ctx[RT](reactor, req, ctx)

        # After phase (reverse), unconditional. `auth_before_ran` precisely
        # gates the auth `after` to the case its `before` actually ran.
        chain.run_after_legs[M](req, response, ctx, auth_mw, auth_before_ran)
    except e:
        # The method + path ride onto the fault log line. `req` is a MUT BORROW
        # throughout this driver (never consumed), so it is alive here.
        # `query_string` is deliberately NOT passed — see `fault_report.mojo`.
        reported_as_fault = True
        response = chain.map_chain_error(
            e, req.method.name(), String(req.path), trace_header_of(req)
        )
        ctx.short_circuit = True
        # Best-effort after-chain on the error response (metrics consistency);
        # swallow any after raise (the original error already won).
        try:
            chain.run_after_legs[M](
                req, response, ctx, auth_mw, auth_before_ran
            )
        except e2:
            _ = e2

    # ⭐ ARM 2 — A 5xx THE CHAIN *RETURNED*. `map_chain_error` -> `report_fault`
    # covers a RAISE; this covers a response the dispatcher (or a middleware
    # short-circuit) RETURNED carrying a 5xx — the same rule
    # `serve_read_round_dispatch` applies on the UNCHAINED path. It is the wider
    # of the two: `_drive_chain_dispatch` is the leaf under every chained
    # service, so without it a returned 5xx on ANY of them is invisible.
    #
    # ⛔ THE OBSERVATION LIVES HERE, IN THE DRIVER, AND NOT IN
    # `serve_read_round_dispatch_chained`. Every chained caller reaches the
    # serve loop's round, but NOT every chained caller is that round — the
    # an in-process module dispatcher calls this driver directly, with no
    # transport under it at all. Observing at the round would have left that
    # entire surface silent while looking covered.
    #
    # OBSERVED, NEVER REWRITTEN: `observe_error_response` takes the response by
    # `ref` and returns nothing, so this cannot become a rewrite. It self-gates
    # on `status >= 500`, so a 401 short-circuit and every 2xx emit nothing.
    if not reported_as_fault:
        observe_error_response(
            response,
            req.method.name(),
            String(req.path),
            trace_header_of(req),
            chain.trace_project(),
        )

    return response^


def serve_read_round_dispatch_chained[
    D: CtxRequestDispatcher,
    M: Middleware,
    RT: Runtime,
](
    mut entry: ConnEntry,
    mut reactor: Reactor[RT.Sink],
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut chain: MiddlewareChain,
    mut auth_mw: M,
    mut dispatcher: D,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """One round of activity on a connection, routing parser-success through the
    MIDDLEWARE CHAIN and THEN the `CtxRequestDispatcher` (the chain's `before` legs — incl. auth — run BEFORE the dispatcher; a
    401 short-circuit means the dispatcher is never reached).

    Structurally identical to `serve_read_round_dispatch` (recv → parse-loop for
    pipelining → per-request response → EWOULDBLOCK-buffer the tail), with the
    bare-dispatch leaf swapped for `_drive_chain_dispatch[D, M, RT]`.

    `reactor` is the SERVER'S reactor, threaded in
    so the dispatcher's handler async I/O parks on it. `RT.Sink` must equal the
    server reactor's sink type (enforced at the server call site).

    Returns:
      * True  — conn remains alive in the table.
      * False — caller should drop the conn.
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
                    return True
                if iw < 0:
                    keep_alive = False
                    break

            var req = HttpRequest()
            swap(req.method, outcome.request.method)
            swap(req.path, outcome.request.path)
            swap(req.query_string, outcome.request.query_string)
            swap(req.headers, outcome.request.headers)

            # CHUNKED-RESPONSE SEAM — identical to `serve_read_round_dispatch`.
            # Applied here too so a middleware-chained service does not keep the
            # hole the un-chained one just lost (the same reasoning the
            # chunked-REQUEST arm records a few lines below).
            var req_http_minor = outcome.http_version_minor
            var req_is_head = req.method.code == HTTP_METHOD_HEAD

            var body_split = False
            if outcome.content_length > 0:
                reserve_declared_body(req.body, outcome.content_length)
                var body_start = off + outcome.headers_end_off
                var present_end = body_end_in_buf(
                    body_start, outcome.content_length, got
                )
                var bi = body_start
                while bi < present_end:
                    req.body.append(io_buf[bi])
                    bi = bi + 1

                var still_needed = outcome.content_length - (
                    present_end - body_start
                )
                if still_needed > 0:
                    body_split = True
                    if not accumulate_body_remainder(
                        fd, req.body, still_needed
                    ):
                        keep_alive = False
                        break
            elif outcome.is_chunked:
                # Same arm as `serve_read_round_dispatch` — see the
                # `accumulate_chunked_body` docstring. Applied here too so a
                # middleware-chained service has the same body handling.
                body_split = True
                var seed_start = off + outcome.headers_end_off
                var chunk_rc = accumulate_chunked_body(
                    fd,
                    Span[UInt8](io_buf)[seed_start:got],
                    limits,
                    req.body,
                )
                if chunk_rc == CHUNKED_BODY_MALFORMED:
                    var cerr_buf = List[UInt8]()
                    build_error_response_bytes(UInt16(400), cerr_buf)
                    var cw = _write_all_or_buffer(entry, cerr_buf, bytes_sent)
                    if cw == 1:
                        return True
                    keep_alive = False
                    break
                if chunk_rc == CHUNKED_BODY_TRANSPORT_FAILED:
                    keep_alive = False
                    break

            # The middleware-in-path leaf: run the chain `before` legs (auth
            # resolves `ctx.authed_user` or short-circuits 401), then — only if
            # not short-circuited — the dispatcher WITH the populated ctx, then
            # the `after` legs. `_drive_chain_dispatch` ALWAYS returns a
            # response (the ErrorMapper turns any raise into a 500).
            var response = _drive_chain_dispatch[D, M, RT](
                chain, auth_mw, dispatcher, reactor, req^
            )

            var resp_list = List[UInt8]()
            serialize_response_framed(
                response,
                response_may_be_chunked(
                    response.status, req_http_minor, req_is_head
                ),
                resp_list,
            )
            var rw = _write_all_or_buffer(entry, resp_list, bytes_sent)
            if rw == 1:
                reqs_handled = reqs_handled + Int64(1)
                return True
            if rw < 0:
                keep_alive = False
                break
            reqs_handled = reqs_handled + Int64(1)

            if outcome.connection_close:
                keep_alive = False
                break

            if body_split:
                break

            var advance = outcome.headers_end_off
            if outcome.content_length > 0:
                advance = advance + outcome.content_length
                if off + advance > got:
                    keep_alive = False
                    break

            off = off + advance

    return keep_alive


# =============================================================================
# §4 — SUSPENDABLE DISPATCH — the per-conn read round that ADMITS a request to
#       the per-worker suspendable driver.
# =============================================================================
#
# The suspendable serve seam (additive, beside `serve_read_round_dispatch`). A
# request is not dispatched-and-written inline; instead it is turned into a
# `SuspendedFrame[H]` and ADMITTED to a per-worker `SuspendableHandlerDriver`.
# A migrated handler may PARK on its awaited I/O (the worker serves other conns
# meanwhile); an un-migrated handler runs one-step-DONE (via SyncToSuspendable
# in the caller) and is delivered immediately. The HttpServer's
# `serve_one_iteration_dispatch_suspendable` owns the demux + writes delivered
# responses back to their originating conns.
#
# LAYERING: this lives in `komira_http` (parametric over the handler `H` /
# dispatcher `SD`), which already depends on `komira_async`
# (`SuspendableHandler` / `SuspendedFrame` / `SuspendableHandlerDriver`). It does
# NOT import any upstack package — the concrete `H` (and the SyncToSuspendable
# wrapping of un-migrated handlers) is supplied by the caller's
# `SuspendableDispatcher` conformer.


trait SuspendableDispatcher(Movable, Deinitable):
    """The application surface for the suspendable serve loop: turn a parsed
    request into a `SuspendedFrame[Self.Handler]` that the per-worker driver
    multiplexes. The associated `Handler: SuspendableHandler` is the handler
    state-machine type this dispatcher produces (its `Handler.Resp` is the
    response type — `HttpResponse` for HTTP).

    A conformer's `make_frame` builds the frame for a request: for a MIGRATED
    route it constructs the route's suspendable state machine (which may park on
    its I/O); for an UN-MIGRATED route it wraps the synchronous handler via
    `SyncToSuspendable` (one-step-DONE, never parks). `request_id` is the conn
    fd the response must be written back to (the driver tags the delivered
    response with it). The reactor is threaded per-call (never stored).

    The trait is non-parameterized with an associated `Handler` alias (Mojo
    1.0.0b1 rejects parameterized trait declarations — same shape as
    `SuspendableHandler.Resp` / `Runtime.Sink`)."""

    comptime Handler: SuspendableHandler

    def make_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> SuspendedFrame[Self.Handler]:
        ...


def write_delivered_to_conn[
    Resp: Movable & Deinitable,
](
    mut entry: ConnEntry,
    ref [_] response: Resp,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Int:
    """Serialize `response` (by BORROW — `serialize_response` reads it) and write
    it back to `entry`'s connection (the EWOULDBLOCK-buffer machinery handles a
    full send buffer). Returns the `_write_all_or_buffer` code: 0 = fully
    written, 1 = partial (pending-write state set; caller arms EPOLLOUT), -1 =
    hard error (caller drops the conn). Increments `reqs_handled` on a
    fully/partially written response.

    Parametric over `Resp` (the driver's delivered-response type, statically
    `SD.Handler.Resp`). `Resp` MUST be `HttpResponse` — enforced by the
    constraint below; the caller's seam has the same constraint. `serialize_
    response` wants a concrete `HttpResponse` BORROW; we reinterpret the
    proven-equal `Resp` borrow via a concrete-origin `UnsafePointer` reinterpret
    (the documented internal escape for a `_type_is_eq`-proven generic→concrete
    borrow that `rebind[T]` cannot serve — `rebind` requires `T:
    ImplicitlyCopyable`, but `HttpResponse` is Movable-only). No pointer crosses
    a module boundary; the reinterpret is confined to this body.

    The seam calls this to deliver a finished suspendable frame's response back
    to the RIGHT connection (the one whose fd == the frame's request_id) — which
    may be a DIFFERENT conn than the one whose read event triggered the resume.

    ⚠ CHUNKED FRAMING IS NOT AVAILABLE ON THIS PATH, AND THAT IS A REAL LIMIT,
    NOT AN OVERSIGHT. `response_may_be_chunked` needs the originating request's
    HTTP version and method; a delivered frame carries ONLY its conn fd
    (`request_id`), and by delivery time the request that produced it is long
    gone — it may have been parsed several event-loop cycles ago. So a handler
    on the SUSPENDABLE or ERASED loop that calls `mark_chunked()` is DOWNGRADED
    to `content-length` here (correct HTTP, but the Cloud Run 32 MiB response
    cap still applies to it). Closing this needs the frame to carry the two
    request facts alongside `request_id`; it is deliberately NOT done in the
    same change as the framing seam itself. A git host that runs
    `serve_one_iteration_dispatch` -> `serve_read_round_dispatch` is
    unaffected: that path DOES gate and honour the framing."""
    comptime assert (Resp == HttpResponse), ("write_delivered_to_conn: Resp must be HttpResponse.")
    var resp_list = List[UInt8]()
    # SAFETY: `(Resp == HttpResponse)` (the constraint above) proves
    # `Resp` IS `HttpResponse`, so the address of the `response` borrow is a
    # valid `HttpResponse*`. We form a concrete-origin pointer to the borrow and
    # reinterpret it as `HttpResponse` to call `serialize_response` (which reads
    # it). The pointer is dereferenced once, synchronously, on this stack; it
    # never escapes this function and no module boundary is crossed.
    var p = UnsafePointer(to=response).bitcast[HttpResponse]()
    serialize_response(p[], resp_list)
    var rw = _write_all_or_buffer(entry, resp_list, bytes_sent)
    if rw >= 0:
        reqs_handled = reqs_handled + Int64(1)
    return rw


def serve_read_round_suspendable[
    SD: SuspendableDispatcher,
    RT: Runtime,
](
    mut entry: ConnEntry,
    mut reactor: Reactor[RT.Sink],
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut dispatcher: SD,
    mut driver: SuspendableHandlerDriver[RT.Sink, SD.Handler],
    request_id: Int64,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) raises -> Bool:
    """One read round on a connection in the SUSPENDABLE loop: recv → parse →
    build a `SuspendedFrame` via `dispatcher.make_frame[RT]` → ADMIT to the
    `driver`. The frame either parks (the driver keeps it; the worker is free to
    serve other conns — this conn is NOT written this round) or finishes
    one-step (the driver delivers it; the SEAM writes the delivered response back
    afterwards, keyed by request_id).

    `request_id` is this conn's fd (the response's routing key). Returns whether
    the conn remains alive in the READ-PARSE loop sense; a conn whose request
    PARKED returns True but is left WITHOUT a written response (the seam will
    deliver it on resume).

    Structurally mirrors `serve_read_round_dispatch` for the recv/parse/body
    machinery (so an un-migrated handler is byte-identical), but the per-request
    leaf is `make_frame` + `driver.admit` instead of inline dispatch+write. To
    keep the demux simple, this round admits AT MOST ONE request per call (no
    in-buffer pipelining of a second request while the first is parked — the
    pipelined-request case is a Stage-6 refinement; un-migrated one-step handlers
    are unaffected because they finish before the next recv)."""
    var fd = entry._fd
    var read_span = Span[UInt8](io_buf)
    var rr = try_io_read(fd, read_span)
    if rr.is_would_block():
        return True
    if rr.is_error():
        return False
    var got = Int(rr.value())
    if got <= 0:
        return False

    var parse_span = Span[UInt8](io_buf)[0:got]
    var outcome = parse_request_head(parse_span, limits)

    if outcome.err.is_need_more():
        return False

    if not outcome.err.is_ok():
        var err_buf = List[UInt8]()
        build_error_response_bytes(outcome.err.status, err_buf)
        var w = _write_all_or_buffer(entry, err_buf, bytes_sent)
        return w == 1

    if outcome.expects_continue:
        if not enable_expect_continue:
            var err_buf = List[UInt8]()
            build_error_response_bytes(UInt16(417), err_buf)
            var ew = _write_all_or_buffer(entry, err_buf, bytes_sent)
            return ew == 1
        var interim_buf = List[UInt8]()
        build_100_continue_bytes(interim_buf)
        var iw = _write_all_or_buffer(entry, interim_buf, bytes_sent)
        if iw == 1:
            return True
        if iw < 0:
            return False

    var req = HttpRequest()
    swap(req.method, outcome.request.method)
    swap(req.path, outcome.request.path)
    swap(req.query_string, outcome.request.query_string)
    swap(req.headers, outcome.request.headers)

    if outcome.content_length > 0:
        reserve_declared_body(req.body, outcome.content_length)
        var body_start = outcome.headers_end_off
        var present_end = body_end_in_buf(
            body_start, outcome.content_length, got
        )
        var bi = body_start
        while bi < present_end:
            req.body.append(io_buf[bi])
            bi = bi + 1
        var still_needed = outcome.content_length - (present_end - body_start)
        if still_needed > 0:
            if not accumulate_body_remainder(fd, req.body, still_needed):
                return False
    elif outcome.is_chunked:
        # `Transfer-Encoding: chunked`, the same arm as
        # `serve_read_round_dispatch` and `serve_read_round_dispatch_chained`.
        # Without it a service on the SUSPENDABLE loop drops every chunked
        # request body on the floor.
        #
        # ⚠ AND IT WOULD FAIL SILENTLY, unlike the dispatch round. That round
        # has an in-buffer pipelining scan which re-parses the chunk-size line
        # as a request line and answers 400 — loud. This round admits at most
        # one request per call, so there is nothing to mis-parse: the handler
        # would simply be handed an EMPTY body and its ordinary 200 would go
        # back (`HTTP/1.1 200 OK ... len=0 sum=0` for an 11-byte chunked body).
        var seed_start = outcome.headers_end_off
        var chunk_rc = accumulate_chunked_body(
            fd, Span[UInt8](io_buf)[seed_start:got], limits, req.body
        )
        if chunk_rc == CHUNKED_BODY_MALFORMED:
            # A client FRAMING error gets a 400, not a hangup — the whole reason
            # `accumulate_chunked_body` returns a code instead of a Bool.
            var cerr_buf = List[UInt8]()
            build_error_response_bytes(UInt16(400), cerr_buf)
            var cw = _write_all_or_buffer(entry, cerr_buf, bytes_sent)
            return cw == 1
        if chunk_rc == CHUNKED_BODY_TRANSPORT_FAILED:
            return False

    # Build the suspended frame from the parsed request + ADMIT it. An uncaught
    # raise from make_frame → drop the conn (defensive; a migrated handler that
    # raises during construction is a bug). For an un-migrated handler the frame
    # is a one-step SyncToSuspendable that already ran the synchronous dispatch.
    var frame = dispatcher.make_frame[RT](reactor, req^, request_id)
    # PROCESS-SURVIVAL: `driver.admit` runs the frame's FIRST
    # `step()`, where a parkable handler issues its first non-blocking I/O. That
    # I/O can RAISE rather than return a step-result error — e.g. an S3 conformer's
    # `TcpStream.connect: connect failed (errno=61)` when the object store is
    # transiently unreachable. WITHOUT this catch the raise propagates out of the
    # serve loop and KILLS the whole server process (the broker COORDINATOR crash:
    # one S3 blip on the first reassign heartbeat -> "Unhandled exception" exit).
    # A transient store error MUST NOT be fatal — drop THIS conn defensively (the
    # peer retries next tick); the serve loop survives to serve every other conn.
    try:
        var parked = driver.admit(frame^, reactor)
        # The seam (HttpServer) drains driver.take_delivered() after this returns
        # and writes each delivered response back to its conn. A parked frame
        # writes nothing this round (the worker serves other conns); a one-step
        # frame is already in the delivered slab. Either way the conn stays alive.
        _ = parked
        return True
    except admit_err:
        # A handler step()/construction raise: the frame was consumed by `admit`
        # before it raised, or never parked. Drop this conn (the seam closes a
        # conn whose round returns False) rather than crashing the process.
        _ = admit_err
        return False


# =============================================================================
# §ERASED — the TYPE-ERASED suspendable dispatch surface.
# =============================================================================
# The scalable counterpart of `SuspendableDispatcher` + `serve_read_round_
# suspendable`: instead of producing a `SuspendedFrame[Self.Handler]` (which
# forces one driver per handler type `H`, hence a SUM handler + per-route demux),
# a conformer produces an `ErasedHandlerFrame[RT.Sink]` directly via
# `make_erased_handler_frame[ConcreteH, RT.Sink]` (the routing wrapper around the
# ONE folded `ErasedHandle[Reactor[RT.Sink]]`). The per-worker driver is
# `ErasedHandlerDriver[RT.Sink, Self.Resp]` — parametric over the reactor sink +
# ONE concrete delivered-response type (`HttpResponse`), NOT over the handler. One
# driver multiplexes N distinct route handlers with no sum and no per-route
# dispatcher field threading; adding a route becomes "a factory + a router.add",
# with no dispatcher / driver / serve-loop edit.


trait ErasedDispatcher(Movable, Deinitable):
    """The TYPE-ERASED application surface for the suspendable serve loop: turn a
    parsed request into an `ErasedHandlerFrame[RT.Sink]` that the per-worker
    `ErasedHandlerDriver` multiplexes BLIND. The associated `Resp` is the single
    delivered-response type the driver reconstructs at delivery (`HttpResponse`
    for HTTP).

    A conformer's `make_erased_frame` builds the erased frame for a request: for
    each route it constructs the route's concrete suspendable state machine (which
    may park on its I/O) and `make_erased_handler_frame[ConcreteH, RT.Sink]`'s it;
    for an un-migrated route it constructs a one-step concrete sync handler the
    same way. `request_id` is the conn fd the response must be written back to. The
    reactor is threaded per-call (never stored).

    The trait is non-parameterized with associated `Sink` + `Resp` aliases (Mojo
    1.0.0b1 rejects parameterized trait declarations — same shape as
    `SuspendableHandler.Resp` / `Runtime.Sink`). `Sink` is the reactor sink the
    dispatcher pins (so the returned `ErasedHandlerFrame[Self.Sink]` type does NOT
    depend on the method's `RT` — the same shape `SuspendableDispatcher.make_frame`
    returns `SuspendedFrame[Self.Handler]`, Self-parametric). `make_erased_frame`'s
    `RT.Sink` MUST equal `Self.Sink` (the server pins one runtime). The driver is
    keyed off `Resp`, not the handler type — that is what kills the sum."""

    comptime Sink: WakerSink & Movable & Deinitable
    comptime Resp: Movable & Deinitable

    def make_erased_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> ErasedHandlerFrame[Self.Sink]:
        ...


def serve_read_round_erased[
    ED: ErasedDispatcher,
    RT: Runtime,
](
    mut entry: ConnEntry,
    mut reactor: Reactor[RT.Sink],
    mut io_buf: Array[UInt8, REQ_BUF_BYTES],
    limits: ParseLimits,
    enable_expect_continue: Bool,
    mut dispatcher: ED,
    mut driver: ErasedHandlerDriver[ED.Sink, ED.Resp],
    request_id: Int64,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) raises -> Bool:
    """One read round on a connection in the TYPE-ERASED suspendable loop: recv →
    parse → build an `ErasedHandlerFrame` via `dispatcher.make_erased_frame[RT]` →
    ADMIT to the `driver`. Structurally IDENTICAL to
    `serve_read_round_suspendable` (the recv/parse/body machinery is byte-for-byte
    the same); the only delta is the per-request leaf produces an erased handler
    frame instead of a `SuspendedFrame[Self.Handler]`. The frame either parks (the
    driver keeps it; the worker is free to serve other conns) or finishes one-step
    (the driver delivers it; the SEAM writes the delivered response back
    afterwards, keyed by request_id).

    `RT.Sink` MUST equal `ED.Sink` (the server pins one runtime; both are
    `NoopSink`) — enforced below so the `make_erased_frame` frame
    (`ErasedHandlerFrame[ED.Sink]`) admits to the `ED.Sink`-typed driver and the
    `RT.Sink`-typed reactor rebinds to the `ED.Sink` the driver/frame want.

    `request_id` is this conn's fd (the response's routing key). Admits AT MOST
    ONE request per call (no in-buffer pipelining of a second request while the
    first is parked — same scope limit as the suspendable round)."""
    comptime assert (RT.Sink == ED.Sink), ("serve_read_round_erased: RT.Sink must equal ED.Sink (the server pins " "one runtime sink across the dispatcher driver reactor).")
    var fd = entry._fd
    var read_span = Span[UInt8](io_buf)
    var rr = try_io_read(fd, read_span)
    if rr.is_would_block():
        return True
    if rr.is_error():
        return False
    var got = Int(rr.value())
    if got <= 0:
        return False

    var parse_span = Span[UInt8](io_buf)[0:got]
    var outcome = parse_request_head(parse_span, limits)

    if outcome.err.is_need_more():
        return False

    if not outcome.err.is_ok():
        var err_buf = List[UInt8]()
        build_error_response_bytes(outcome.err.status, err_buf)
        var w = _write_all_or_buffer(entry, err_buf, bytes_sent)
        return w == 1

    if outcome.expects_continue:
        if not enable_expect_continue:
            var err_buf = List[UInt8]()
            build_error_response_bytes(UInt16(417), err_buf)
            var ew = _write_all_or_buffer(entry, err_buf, bytes_sent)
            return ew == 1
        var interim_buf = List[UInt8]()
        build_100_continue_bytes(interim_buf)
        var iw = _write_all_or_buffer(entry, interim_buf, bytes_sent)
        if iw == 1:
            return True
        if iw < 0:
            return False

    var req = HttpRequest()
    swap(req.method, outcome.request.method)
    swap(req.path, outcome.request.path)
    swap(req.query_string, outcome.request.query_string)
    swap(req.headers, outcome.request.headers)

    if outcome.content_length > 0:
        reserve_declared_body(req.body, outcome.content_length)
        var body_start = outcome.headers_end_off
        var present_end = body_end_in_buf(
            body_start, outcome.content_length, got
        )
        var bi = body_start
        while bi < present_end:
            req.body.append(io_buf[bi])
            bi = bi + 1
        var still_needed = outcome.content_length - (present_end - body_start)
        if still_needed > 0:
            if not accumulate_body_remainder(fd, req.body, still_needed):
                return False
    elif outcome.is_chunked:
        # see the identical arm in
        # `serve_read_round_suspendable`. The TYPE-ERASED round is documented as
        # "structurally IDENTICAL … the recv/parse/body machinery is
        # byte-for-byte the same", and it was not: it was missing the chunked
        # arm too. A comment claiming two code paths are identical is not a
        # mechanism that keeps them identical.
        var seed_start = outcome.headers_end_off
        var chunk_rc = accumulate_chunked_body(
            fd, Span[UInt8](io_buf)[seed_start:got], limits, req.body
        )
        if chunk_rc == CHUNKED_BODY_MALFORMED:
            var cerr_buf = List[UInt8]()
            build_error_response_bytes(UInt16(400), cerr_buf)
            var cw = _write_all_or_buffer(entry, cerr_buf, bytes_sent)
            return cw == 1
        if chunk_rc == CHUNKED_BODY_TRANSPORT_FAILED:
            return False

    # Build the ERASED frame from the parsed request + ADMIT it. An uncaught raise
    # from make_erased_frame → drop the conn (defensive). A one-step sync frame is
    # already in the delivered slab; a parked frame writes nothing this round.
    var frame = dispatcher.make_erased_frame[RT](reactor, req^, request_id)
    # The reactor is Reactor[RT.Sink]; admit wants Reactor[ED.Sink]. The constraint
    # above proves RT.Sink == ED.Sink, so the rebind is a compile-time no-op.
    # PROCESS-SURVIVAL: mirror the SuspendableDispatcher path —
    # `admit` runs the frame's first `step()`, whose first non-blocking I/O can
    # RAISE (a transiently-unreachable store -> `connect failed`). A raise here
    # must NOT escape the serve loop and kill the process; drop this conn
    # defensively (the peer retries) and keep serving every other conn.
    try:
        var parked = driver.admit(
            frame^, rebind[Reactor[ED.Sink]](reactor)
        )
        _ = parked
        return True
    except admit_err:
        _ = admit_err
        return False
