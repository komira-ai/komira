# =============================================================================
# src/komira_http/client/state_machine.mojo — Outbound per-conn state machine
# =============================================================================
#
#
#   "A ClientConn's lifecycle on the reactor:
#      Dialing ── connect IN_PROGRESS ──> ConnectWritable
#       ── SO_ERROR ok ──> [TlsHandshaking]
#       ── s2n_negotiate loop ──> Idle
#       ── checkout ──> WritingRequestHeaders
#       ── ──> [WaitingForContinue] ──>
#       WritingRequestBody ── body sent ──>
#       ReadingResponse ── response complete ──> Idle(pooled) ──or──> Closing"
#
# Conditional states:
#   * `Dialing` / `ConnectWritable` are SKIPPED for the client because
#     `Connector.connect[RT]` drives the dial-+-park itself and
#     returns an already-connected IoStream. The OutboundDriver begins
#     in `Idle` and operates on an already-connected stream.
#   * `TlsHandshaking` is RESERVED — stub-only (TLS lives in the connector).
#   * `WaitingForContinue` is RESERVED — stub-only.
#
# The driver runs ONE request-response cycle on ONE IoStream conformer.
# After the response completes, it either closes the
# stream (Connection: close on response, or connection-close override)
# or leaves it in `Idle` for a pool to check out.
#
# Mojo 1.0.0b1 idiom: the state machine is a single `while True:` over
# a `state: UInt8` discriminator with if/elif branches. NO method
# dispatch on state — direct if-tree, fully monomorphizable. Parametric
# over `[S: IoStream, RT: Runtime]` — the conformer's body monomorphizes
# against the concrete stream + runtime; zero fn-ptr table.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * The driver holds the stream by `mut self` ref through the run; no
#     long-lived borrowed-pointer fields.
# =============================================================================


from komira_async.cancellation.token import CancellationToken
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_obs.clock import now_ns as _system_now_ns
from komira_http.client.body import EmptyBody, RequestBody
from komira_http.client.error import HttpError
from komira_http.client.header_map import HeaderMap
from komira_http.client.response_body import (
    BufferedResponseBody,
    RecvRingBody,
    ResponseBody,
    collect_body,
)
from komira_http.client.response_parser import (
    ResponseHead,
    ResponseParseLimits,
    parse_response_head,
)
from komira_http.codec.h1.chunked import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    CHUNKED_RES_NEED_MORE,
    ChunkedDecoder,
    decode_block,
)
from komira_http.codec.h1.limits import (
    PARSE_ERR_BODY_TOO_LARGE,
    ParseLimits,
)
from komira_http.transport.stream_park import park_on_pending
from komira_http.transport.io_stream import (
    IoStream,
    STREAM_IO_EOF,
    STREAM_IO_ERROR,
    STREAM_IO_PENDING,
    STREAM_IO_READY,
    StreamIo,
)


# =============================================================================
# §1 — State constants (UInt8 sentinel namespace).
# =============================================================================

comptime OUTBOUND_STATE_IDLE: UInt8 = 0
"""Stream is connected, no request in flight. Initial state of the
driver (the Connector already produced a connected stream). Pool
checkout would also land here."""

comptime HTTP_NOTHING_WRITTEN_TOKEN: String = "[NOTHING-WRITTEN]"
"""★ GO'S THIRD RETRY TERM, AS A TOKEN ON THE MESSAGE.

`persistConn.shouldRetryRequest` (`net/http/transport.go`) is THREE terms:

    reused-connection AND no-response-header-data-yet
                      AND (nothing-was-written OR request-is-replayable)

`HttpError[RETRYABLE_TRANSPORT]` already carries term 2 — every branch that
emits it has PROVEN `len(recv_buf) == 0`, i.e. the peer sent no response byte.
⚠ **THAT IS NOT TERM 3.** A peer can read a whole request, execute it, and die
before writing its first response byte; zero response bytes does not prove
zero EFFECT. Go's own `nothingWrittenError` exists for exactly that gap: when
the write failed having put NOTHING on the wire, the request provably never
reached the peer, and a non-idempotent verb is then safe to re-issue.

This token marks that stronger fact, and it is emitted from ONE branch —
`OutboundDriver._write_error` with `_write_cursor == 0` — so, like the class
name it rides on, it is a PROOF and not a label. ⛔ Do not emit it anywhere
that has not established `_write_cursor == 0`.

Read by `komira_http.client.client._h1_pooled_retry_is_safe`."""

comptime OUTBOUND_STATE_TLS_HANDSHAKING: UInt8 = 1
"""RESERVED — TLS handshake state. Driver enters here when
the configured connector stack includes a TlsConnector; The driver
skips this state entirely."""

comptime OUTBOUND_STATE_WRITING_REQUEST_HEADERS: UInt8 = 2
"""Draining the serialized request head into the wire via
IoStream.try_write. Loop continues until all bytes have been
written. On Pending: reactor.poll_completions and retry."""

comptime OUTBOUND_STATE_WAITING_FOR_CONTINUE: UInt8 = 3
"""RESERVED — Expect: 100-continue interim wait. Driver
enters here after headers are written IF the request had Expect:
100-continue. The driver skips this state."""

comptime OUTBOUND_STATE_WRITING_REQUEST_BODY: UInt8 = 4
"""Draining the request body into the wire. Loop continues until
body.read_chunk returns 0. On Pending: park."""

comptime OUTBOUND_STATE_READING_RESPONSE_HEAD: UInt8 = 5
"""Reading bytes from the wire into the recv buffer until
parse_response_head returns OK (parsed) or hard error."""

comptime OUTBOUND_STATE_READING_RESPONSE_BODY: UInt8 = 6
"""Reading the response body — either Content-Length-framed or
chunked-decoded. Loop until done or hard error."""

comptime OUTBOUND_STATE_DONE: UInt8 = 7
"""Request-response cycle complete. The driver returns the parsed
ClientResponse."""

comptime OUTBOUND_STATE_ERROR: UInt8 = 8
"""Hard error path — the driver returns the typed HttpError."""

comptime _MAX_INTERIM_RESPONSES: Int = 8
"""Upper bound on 1xx interim responses skipped before the final one.

RFC 9110 15.2 puts no ceiling on "one or more" 1xx responses, so without a
bound here a peer that emits 1xx forever parks this driver in
READING_RESPONSE_HEAD indefinitely -- a denial of service that costs the
peer one small write per iteration. Go bounds the same loop at 5
(`max1xxResponses`, net/http/transport.go); we allow 8 because Google's GFE
emits `103 Early Hints` repeatedly as it learns of further preloads, and
exceeding the bound is a hard error rather than a silent truncation."""


# =============================================================================
# §1b — Non-blocking step-result sentinels.
# =============================================================================
# The blocking `run` / `run_with_body` spin on Pending inside an inner
# `while True:` loop, so they cannot overlap the dial+send+head round-trips
# of K concurrent streams. adds `step_send_head_nonblocking`, which
# does ONE non-blocking iteration (try_write / try_read once, then
# `reactor.poll_completions(timeout_us=0)`) and returns one of these
# sentinels. The caller (a per-K round-robin in s3_fs) drives all K drivers
# so the head-read RTTs OVERLAP rather than serialize. NO runtime-core
# change — only the existing per-pthread reactor's non-blocking poll.

comptime OUTBOUND_STEP_NOT_READY: UInt8 = 0
"""One non-blocking step made no terminal progress: the fd was not
write-ready (head still being sent) or not read-ready (head not yet on the
wire). Caller should poll the NEXT stream and revisit this one later."""

comptime OUTBOUND_STEP_HEAD_DONE: UInt8 = 1
"""The response head has been fully parsed. The driver is in
OUTBOUND_STATE_DONE; caller calls `finish_into_response` to extract the
ClientResponse[RecvRingBody[S]] (body deferred to poll_frame)."""

comptime OUTBOUND_STEP_ERROR: UInt8 = 2
"""A hard error occurred during the non-blocking step. The driver's
`_final_error_detail` carries the HttpError message; caller raises."""


# =============================================================================
# §1c — head/write drive: spin-then-park + wall-clock deadline.
# =============================================================================
# The blocking `run` / `run_with_body` head-read + head-write loops drive the
# state machine by re-calling `_drive_read_head` / `_drive_write` every
# iteration. Those helpers are NON-BLOCKING — on EWOULDBLOCK they return
# without making progress (try_read/try_write returns Pending). Re-issuing
# the syscall IMMEDIATELY with no park and no yield is a pure
# busy-spin that pins a core for the entire network/server wait.
#
# For a fast loopback server the head arrives within microseconds and the
# spin is invisible. But for a server that holds the connection open while
# it WORKS before replying — e.g. an MLX / local-LLM chat-completions
# generation that takes seconds before the first response byte — such a loop
# spins through its hard `max_iterations` cap (1M for `run`, 10M for
# `run_with_body`) and then RAISES "state-machine iteration cap exceeded",
# failing the request even though the server is healthy and still working.
#
# The loops mirror the `collect_body` pattern (response_body.mojo):
# after a small spin budget of consecutive no-progress
# iterations, PARK on the stream's fd (epoll/kqueue readiness) until it's
# ready or the park timeout elapses, then resume. Fast-local I/O resolves
# within the spin budget and never parks. A slow server
# parks and reclaims the CPU instead of burning it.
#
# The hard iteration cap is REPLACED by a wall-clock DEADLINE so that a
# slow-BUT-progressing server is no longer killed by an arbitrary iteration
# count — the only legitimate reason to abandon the request is that too
# much real TIME has elapsed (a genuinely stuck/dead peer), which a
# monotonic deadline captures correctly. The deadline is configurable per
# request (`set_request_timeout_us`); 0 selects the generous default below.

comptime _HEAD_DRIVE_SPIN_BUDGET: Int = 64
"""Consecutive no-progress iterations to spin before parking on the stream
fd. Matches the intent of collect_body's spin budget (a handful of fast
re-polls catch a byte that's already on the socket / in the kernel recv
buffer; beyond that, park instead of burning CPU)."""

comptime _HEAD_DRIVE_PARK_TIMEOUT_US: Int32 = 50_000
"""Per-park bound (50 ms). Level-triggered readiness makes a byte already on
the socket return the park immediately (lost-wakeup-safe); the bound caps
how long a single park blocks so the wall-clock deadline is re-checked at
least every 50 ms."""

comptime _DEADLINE_SATURATE_US: Int = (1 << 62)
"""Ceiling for an absolute request deadline (~146,000 years). Keeps an absurd
configured budget reading as "generous" instead of wrapping
`started_us + budget` into a past instant. Mirrors
`response_body.mojo:_BODY_DEADLINE_SATURATE_US`, which clamps the same value
on the receiving side -- both ends clamp because either end can be handed a
number by a caller."""


comptime _HEAD_DRIVE_DEFAULT_TIMEOUT_US: Int = 600_000_000
"""Default request deadline (600 s = 10 min) when no explicit timeout is
set. Generous on purpose: a local-LLM generation can legitimately run for
many seconds-to-minutes before the first response byte, and the prior
iteration cap is exactly what this default must NOT reintroduce. Callers
that want a tighter bound set one via `set_request_timeout_us`."""


def _write_state_name[W: Writer](mut writer: W, s: UInt8):
    """WRITE what `state_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
    CROSSED takes the process down with it."""
    if s == OUTBOUND_STATE_IDLE:
        writer.write(String("IDLE"))
        return
    if s == OUTBOUND_STATE_TLS_HANDSHAKING:
        writer.write(String("TLS_HANDSHAKING"))
        return
    if s == OUTBOUND_STATE_WRITING_REQUEST_HEADERS:
        writer.write(String("WRITING_REQUEST_HEADERS"))
        return
    if s == OUTBOUND_STATE_WAITING_FOR_CONTINUE:
        writer.write(String("WAITING_FOR_CONTINUE"))
        return
    if s == OUTBOUND_STATE_WRITING_REQUEST_BODY:
        writer.write(String("WRITING_REQUEST_BODY"))
        return
    if s == OUTBOUND_STATE_READING_RESPONSE_HEAD:
        writer.write(String("READING_RESPONSE_HEAD"))
        return
    if s == OUTBOUND_STATE_READING_RESPONSE_BODY:
        writer.write(String("READING_RESPONSE_BODY"))
        return
    if s == OUTBOUND_STATE_DONE:
        writer.write(String("DONE"))
        return
    if s == OUTBOUND_STATE_ERROR:
        writer.write(String("ERROR"))
        return
    writer.write(String("UNKNOWN"))
    return


def state_name(s: UInt8) -> String:
    """Symbolic name for the state sentinel. For log lines + test
    assertions."""
    var out = String()
    _write_state_name(out, s)
    return out^


# =============================================================================
# §2 — ClientResponse — the result of a successful run.
# =============================================================================
# The L7 client surface — owned headers + status + ResponseBody-trait
# conformer body. parametrizes the
# response body over a `ResponseBody` conformer:
#   `struct ClientResponse[RB: ResponseBody](Movable, Deinitable)`
# The OutboundDriver populates ClientResponse[BufferedResponseBody] for
# will flip the default to
# RecvRingBody.


struct ClientResponse[RB: ResponseBody](Movable, Deinitable):
    """Parsed HTTP response — status + headers + ResponseBody-trait-typed
    body.

    Movable, NOT Copyable. Parametric on the response-body conformer
    `RB: ResponseBody`.
    default conformer is `BufferedResponseBody` (the v1-bridge
    slurp); flips to `RecvRingBody` (zero-copy recv-ring
    pull-stream).

    Fields:
      status   — RFC 9110 status code (200, 404, 500, ...).
      reason   — Status reason phrase. May be empty.
      headers  — Response HeaderMap. The HEAD section only: the fields the
                 origin committed to BEFORE it sent the body.
      trailers — The TRAILER section (RFC 9110 §6.5 / RFC 9113 §8.1). Empty
                 for the overwhelming majority of responses.
                 ⚠ SEPARATE FROM `headers` ON PURPOSE. Were trailer fields
                 appended into the SAME map as the
                 head's, a caller reading `grpc-status` beside
                 `content-type` could not tell which half of the message the
                 origin had committed to before the body — and a trailer could
                 overwrite an already-delivered `:status`. Telling the two
                 apart is the entire reason a trailer section exists.
                 ⛔ A CONSUMER OF A TRAILER FIELD MUST READ IT HERE, and must
                 NOT fall back to `headers` — that fallback is what the split
                 exists to prevent. The TRAILERS-ONLY response (no body, the
                 fields ride in the INITIAL HEADERS block) is genuinely a head
                 and correctly stays on `headers`; `komira_grpc` reads both,
                 each from the section that actually carries it.
      body     — Response body conformer. Caller drives via
                 `body.poll_frame[RT](reactor, token)`. For
                 BufferedResponseBody, one Data frame contains the full
                 body + then End idempotently — preserves the slurp
                 semantic.
      connection_close  — True iff the server requested close (or this
                          was HTTP/1.0 without keep-alive).

    Access pattern for-compatible "fully buffered" callers:
      `var chunk = resp.body.take_first_chunk()` or via:
      `var frame = resp.body.poll_frame[RT](reactor, token);
       var bytes = frame.take_data_chunk()`
    """

    var status: Int32
    var reason: String
    var headers: HeaderMap
    var trailers: HeaderMap
    var body: Self.RB
    var connection_close: Bool

    def __init__(out self, var body: Self.RB):
        self.status = Int32(0)
        self.reason = String()
        self.headers = HeaderMap()
        # Empty unless an h2 response actually carried a trailer section. The
        # h1 path has no trailer surface yet (RecvRingBody._trailers is
        # declared and written by nothing), so it leaves this empty — which is
        # the correct answer for every h1 response that has no trailers, and
        # an honest "we do not surface them" for the ones that do.
        self.trailers = HeaderMap()
        self.body = body^
        self.connection_close = False


# =============================================================================
# §3 — OutboundDriver.
# =============================================================================
# The driver consumes:
#   * `stream`     — IoStream conformer (parametric); the dial result.
#   * `reactor`    — the Runtime's Reactor[RT.Sink]; passed per call.
#   * `req_bytes`  — pre-serialized request head + body bytes; the
#                     driver writes them as one contiguous block.
#   * `recv_buf`   — caller's scratch recv buffer; the driver appends
#                     wire bytes here as they arrive.
#
# `run[RT]()` returns a ClientResponse on success, raises Error on
# failure (the Error carries an HttpError detail). The driver does NOT
# close the stream on success — the caller decides whether to keep
# (pool) or close.


struct OutboundDriver(Movable, Deinitable):
    """Per-conn outbound state machine driver.0 shape:
    request bytes are pre-serialized, response body is fully buffered.

    Construct with `OutboundDriver.new(req_bytes)`; then call
    `run[S, RT](stream, reactor)` to drive a single request-response.

    Internal storage: recv buffer (List[UInt8]), state discriminator,
    write cursor over req_bytes, parsed-head-end offset.
    """

    var _req_bytes: List[UInt8]
    """Pre-serialized request bytes (head + body), drained linearly."""

    var _write_cursor: Int
    """Bytes from _req_bytes already accepted by IoStream.try_write."""

    var _recv_buf: List[UInt8]
    """Bytes pulled from IoStream.try_read; the response parser scans
    this for the CRLFCRLF terminator. After head parse, body bytes
    accumulate here from headers_end_off onward."""

    var _state: UInt8

    var _headers_end_off: Int
    """Offset in _recv_buf where the head ends (body starts). -1 until
    parsed."""

    var _content_length: Int
    """-1 until parsed; -1 = chunked or read-until-EOF; >=0 = CL value."""

    var _is_chunked: Bool

    var _connection_close: Bool

    var _body_bytes_received: Int
    """Body bytes pulled past headers_end_off."""

    var _chunked_decoder_state: ChunkedDecoder

    var _decoded_body: List[UInt8]
    """For chunked: the decoded payload bytes (chunk data only, no
    sizes / CRLF). For CL: the same buffer (we slice _recv_buf into
    it). For empty-body: stays empty."""

    var _max_response_body_bytes: Int
    """Cap on the decoded response body size. Defaults to 100 MiB."""

    var _is_head_request: Bool
    """Set by
    the caller via `set_is_head_request(True)` BEFORE `run` /
    `run_with_body` when the request method is HEAD. Per RFC 7230 §3.3.2
    / RFC 7231 §4.3.2, HEAD responses MUST NOT contain a message body
    even when `Content-Length` is present (CL describes what the GET
    would have returned, not what is on the wire). When True, the
    body-decision block short-circuits to `RecvRingBody.new_empty`
    regardless of the CL / chunked headers."""

    var _final_status: Int32
    """Parsed response status code. Populated after head parse."""

    var _final_reason: String
    """Parsed reason phrase. Populated after head parse."""

    var _interim_responses_seen: Int
    """How many 1xx INTERIM responses have been skipped on this exchange.

    RFC 9110 15.2 requires a client to parse "one or more" 1xx responses
    before the final one, so the count is unbounded in the spec and must be
    bounded here: a peer that emits 1xx forever would otherwise hold this
    driver in READING_RESPONSE_HEAD for as long as it likes. Capped by
    `_MAX_INTERIM_RESPONSES`."""

    var _final_headers: HeaderMap
    """Parsed response headers. Populated after head parse."""

    var _final_error_detail: String
    """When a non-blocking step
    (`step_send_head_nonblocking`) hits a hard error, it records the
    HttpError message here and returns OUTBOUND_STEP_ERROR rather than
    raising — raising would unwind the round-robin caller's stack and
    abort the other K-1 in-flight streams. The caller reads this and
    raises at a safe point."""

    var _request_timeout_us: Int
    """Wall-clock budget in
    microseconds for the blocking `run` / `run_with_body` drive loops. 0
    selects `_HEAD_DRIVE_DEFAULT_TIMEOUT_US`. The loops park-then-poll and
    fail with a TIMEOUT only when this much REAL time has elapsed — never
    on an iteration count (the prior cap busy-spun and killed healthy but
    slow servers, e.g. multi-second local-LLM generations)."""

    var _deadline_us: Int
    """The ABSOLUTE monotonic
    deadline (microseconds) for THIS ENTIRE REQUEST -- head AND body -- or 0
    if the driver has not been armed yet.

    WARNING: A FIELD, NOT A LOCAL, AND THAT IS THE POINT. A local in
    `run` / `run_with_body` would die at the head/body
    seam: the moment the driver handed the stream to a `RecvRingBody` the
    bound would cease to exist, and the body drain would run with no deadline
    at all. As a field it can be STAMPED ONTO
    THE BODY at each of the three construction sites, so the already-armed
    deadline is MOVED across that seam rather than recomputed after it.

    ONE BUDGET SPANS BOTH PHASES -- Envoy's `route.timeout` shape ("spans
    between the point at which the entire downstream request has been
    processed and when the upstream response has been completely
    processed"), NOT a fresh budget for the body. If the body got its own
    `_HEAD_DRIVE_DEFAULT_TIMEOUT_US`, a request could burn 295 s in the head
    and then start a second 295 s in the body, and the composed total would
    still be unbounded-by-composition. That is exactly why it is moved and
    not recomputed.

    ARMED ONCE, NEVER RE-ARMED, including across `_reset_response_parse_
    state` -- an Expect-100-continue interim response spends the SAME budget
    as the final one, for the same composition reason."""

    var _park_pending_token: Int64
    """ONE-PARK-PRIMITIVE: the payload of the MOST RECENT
    `StreamIo.pending` this driver received, carried from the I/O site to the
    park site.

    ⚠ WHY A FIELD AND NOT A PARAMETER. This driver's park is DECOUPLED from
    the I/O that caused it: `_drive_write` / `_drive_read_head` return on a
    Pending, the caller then infers no-progress by comparing a cursor, and only
    after `_HEAD_DRIVE_SPIN_BUDGET` such iterations does `_tick_no_progress`
    park. So by the time we park, the `StreamIo` that told us WHY we are
    waiting is three frames gone. h2 has no such gap — it parks in the same
    branch that saw the Pending — which is exactly why h2 could ask the stream
    from day one and this file could not. The token is the smallest thing that
    closes the gap; it is a transient POD Int64, never a pointer, and it is
    re-stamped on every I/O."""

    var _park_pending_is_write: Bool
    """Which method produced `_park_pending_token` (`try_write` -> True). A
    FACT ABOUT THE CALL, not a wait direction — it is `park_on_pending`'s
    `call_is_write`, which the conformer is free to disagree with."""

    var _park_pending_valid: Bool
    """False when the last I/O did not end in a Pending (a zero-byte READY, or
    no I/O attempted). `_tick_no_progress` then does NOT park — there is
    nothing to park ON — but still runs its deadline check, so a driver that
    somehow spins on zero-byte READYs still fails with a typed TIMEOUT rather
    than waiting on a direction nobody stated. Previously this case parked on
    the STATE's direction, which is a guess."""

    def __init__(out self, var req_bytes: List[UInt8]):
        self._req_bytes = req_bytes^
        self._park_pending_token = Int64(0)
        self._park_pending_is_write = False
        self._park_pending_valid = False
        self._write_cursor = 0
        self._recv_buf = List[UInt8]()
        self._state = OUTBOUND_STATE_IDLE
        self._headers_end_off = -1
        self._content_length = -1
        self._is_chunked = False
        self._connection_close = False
        self._body_bytes_received = 0
        self._chunked_decoder_state = ChunkedDecoder.init()
        self._decoded_body = List[UInt8]()
        self._max_response_body_bytes = 100 * 1024 * 1024
        self._is_head_request = False
        self._final_status = Int32(0)
        self._final_reason = String()
        self._final_headers = HeaderMap()
        self._final_error_detail = String()
        self._interim_responses_seen = 0
        self._request_timeout_us = 0
        self._deadline_us = 0

    @staticmethod
    def new(var req_bytes: List[UInt8]) -> OutboundDriver:
        return OutboundDriver(req_bytes^)

    def set_max_response_body_bytes(mut self, n: Int):
        """Override the default 100 MiB body cap. Used by tests."""
        self._max_response_body_bytes = n

    def set_request_timeout_us(mut self, us: Int):
        """Set the wall-clock
        budget for this request. `us <= 0` resets to the generous default
        (`_HEAD_DRIVE_DEFAULT_TIMEOUT_US`). The loops park cooperatively
        while the server works and fail with a TIMEOUT only after this much
        REAL time elapses -- they never cap on an iteration count. Caller
        MUST invoke before `run` / `run_with_body`.

        THE SCOPE OF THIS NUMBER IS DELIBERATE. It bounds HEAD PLUS BODY out
        of ONE budget (Envoy's `route.timeout` shape). A head-only bound
        ceases to exist the moment the driver hands the stream to a
        `RecvRingBody`, and a body drain with no deadline means a request can
        never terminate.

        So a caller who authored 20 s meaning "time to first byte", and who
        spends 19.9 s in the head, has 100 ms left for the body. That is
        the intended reading: the field is named `request_timeout_us`, not
        `head_timeout_us`, and `outbound_budget_us` sizes it against the
        platform REQUEST ceiling -- i.e. as a total. DO NOT "fix" a caller
        surprised by this by giving the body a budget of its own; that is
        precisely the composition hole this closes."""
        if us <= 0:
            self._request_timeout_us = 0
        else:
            self._request_timeout_us = us

    def _effective_deadline_us(self, started_us: Int) -> Int:
        """Absolute monotonic deadline (microseconds) for the drive loop:
        `started_us + budget`, where budget is the configured request timeout
        or the generous default when none is set.

        SATURATING. An absurd budget must read as "generous", never wrap
        `started_us + budget` into a PAST instant and fail instantly (the
        overflow case reqwest pins as
        `big_timeout_duration_does_not_overflow`)."""
        var budget = self._request_timeout_us
        if budget <= 0:
            budget = _HEAD_DRIVE_DEFAULT_TIMEOUT_US
        if budget > _DEADLINE_SATURATE_US - started_us:
            return _DEADLINE_SATURATE_US
        return started_us + budget

    def _arm_deadline(mut self):
        """Stamp this request's
        absolute deadline, ONCE. Idempotent -- a driver already armed keeps
        the deadline it has, so the budget can never be restarted partway
        through a request (which is how a composed head+body total silently
        becomes two totals).

        Called from every verb that begins driving a request:
        `run`, `run_with_body`, `begin_send_head_nonblocking` and
        (defensively, because it is the one entry that cannot be bypassed)
        the first `step_send_head_nonblocking`."""
        if self._deadline_us != 0:
            return
        var started_us = Int(_system_now_ns() // UInt64(1000))
        self._deadline_us = self._effective_deadline_us(started_us)

    def deadline_us(self) -> Int:
        """The absolute deadline armed for this request, or 0 if unarmed.
        POD Int -- nothing crosses the module boundary but a number."""
        return self._deadline_us

    def set_is_head_request(mut self, b: Bool):
        """Mark
        this request as HEAD so the body-decision block in `run` /
        `run_with_body` short-circuits to `RecvRingBody.new_empty`
        regardless of the response's Content-Length / Transfer-Encoding
        headers. Per RFC 7230 §3.3.2 / RFC 7231 §4.3.2, HEAD responses
        MUST NOT contain a message body even with CL set (CL reflects
        what GET would have returned, not what is on the wire). Caller
        MUST invoke before `run` / `run_with_body`."""
        self._is_head_request = b

    # =========================================================================
    # non-blocking send + head-read stepper.
    # =========================================================================

    def begin_send_head_nonblocking(mut self):
        """Arm the driver for the non-blocking send+head path. The
        caller has an ALREADY-CONNECTED stream (dialed, or keepalive-reused,
        or connect-completed) and `_req_bytes` carries the pre-serialized
        signed HEAD (GET → EmptyBody, no request body). Transitions IDLE →
        WRITING_REQUEST_HEADERS so the first `step_send_head_nonblocking`
        starts draining the request bytes."""
        # ARM HERE: this is when the request starts, and
        # `finish_into_response` stamps whatever we arm onto the body it
        # builds. Without it the / K-stream path -- the objectstore +
        # parquet prefetch drain, which reaches `drain_bodies_round_robin`
        # and calls `collect_body` NEVER -- would carry `_NO_DEADLINE` and
        # stay unbounded while the `collect_body` sites looked fixed. It is
        # the highest-value single line in this change and it is invisible
        # from every named `collect_body` call site.
        self._arm_deadline()
        self._state = OUTBOUND_STATE_WRITING_REQUEST_HEADERS

    def step_send_head_nonblocking[
        S: IoStream, RT: Runtime, scratch_o: Origin[mut=True],
    ](
        mut self,
        mut stream: S,
        mut reactor: Reactor[RT.Sink],
        scratch: Span[UInt8, scratch_o],
    ) -> UInt8:
        """Do ONE non-blocking iteration of the send+head state
        machine for an EmptyBody (GET) request. Returns:
          * OUTBOUND_STEP_NOT_READY — no terminal progress this step; the
            fd was not ready (write would block, or head not yet on wire).
            The caller round-robins to another stream and revisits later.
          * OUTBOUND_STEP_HEAD_DONE — the head parsed; driver is in DONE.
            Caller invokes `finish_into_response` to build the response.
          * OUTBOUND_STEP_ERROR — hard error; `last_error_detail()` carries
            the message.

        Unlike `run_with_body`'s inner `while True:` (which SPINS on Pending
        and so serializes the K head-RTTs), this does a SINGLE try_io per
        call and returns NOT_READY when the fd would block. The caller's
        round-robin over K streams is what overlaps the RTTs: while stream
        A's request is in flight and its head not yet on the wire, the
        caller steps B, C, ... whose sockets are filling concurrently. The
        kernel recv buffers fill independent of epoll registration, so this
        busy-poll model (the same one used for the body drain)
        needs NO reactor registration and NO blocking park.

        EmptyBody only — there is no WRITING_REQUEST_BODY phase (GET has no
        payload), so the path is WRITING_REQUEST_HEADERS → READING_RESPONSE_
        HEAD → DONE.

        Does NOT raise — errors are recorded in `_final_error_detail` and
        surfaced via the OUTBOUND_STEP_ERROR sentinel, so a fault on one
        stream never unwinds the caller's other in-flight streams.
        """
        # Defensive second arm: `begin_send_head_nonblocking` is the
        # documented arm point, but THIS is the entry no stepping caller can
        # bypass. Idempotent -- an armed driver keeps its deadline.
        self._arm_deadline()
        try:
            if self._state == OUTBOUND_STATE_WRITING_REQUEST_HEADERS:
                self._drive_write[S, RT](stream, reactor)
                if self._write_cursor >= self._req_bytes.__len__():
                    self._state = OUTBOUND_STATE_READING_RESPONSE_HEAD
                    # Fall through to attempt a head read THIS step — the
                    # response may already be on the wire (loopback / fast
                    # server), avoiding a wasted round-robin pass.
                else:
                    # Head not fully written; yield so the caller round-robins
                    # to another stream (whose socket is also draining).
                    return OUTBOUND_STEP_NOT_READY

            if self._state == OUTBOUND_STATE_READING_RESPONSE_HEAD:
                var maybe_done = self._drive_read_head[S, RT](
                    stream, reactor, scratch,
                )
                if maybe_done:
                    # RFC 9110 15.2: a 1xx does not terminate the exchange.
                    # Yield NOT_READY rather than looping here -- this
                    # stepper's contract is ONE try_io per call, and the
                    # caller's next step re-enters with the interim head
                    # already drained from _recv_buf, so `_drive_read_head`'s
                    # fast path parses the real head with no further io.
                    # Progress is guaranteed (an interim head is always
                    # consumed) and bounded by `_MAX_INTERIM_RESPONSES`.
                    if self._head_was_interim():
                        return OUTBOUND_STEP_NOT_READY
                    self._state = OUTBOUND_STATE_DONE
                    return OUTBOUND_STEP_HEAD_DONE
                # Head not yet fully on the wire; yield to the caller's
                # round-robin (other streams' heads arrive concurrently).
                return OUTBOUND_STEP_NOT_READY

            if self._state == OUTBOUND_STATE_DONE:
                return OUTBOUND_STEP_HEAD_DONE

            # ERROR or unexpected state.
            if self._final_error_detail.byte_length() == 0:
                self._final_error_detail = String(
                    "HttpError[INTERNAL]: non-blocking step in state "
                    + state_name(self._state)
                )
            return OUTBOUND_STEP_ERROR
        except e:
            self._state = OUTBOUND_STATE_ERROR
            self._final_error_detail = String(e)
            return OUTBOUND_STEP_ERROR

    def last_error_detail(self) -> String:
        """The HttpError message recorded by a failed
        `step_send_head_nonblocking`. Valid only after a step returned
        OUTBOUND_STEP_ERROR."""
        return self._final_error_detail

    def finish_into_response[S: IoStream](
        mut self, var stream: S,
    ) -> ClientResponse[RecvRingBody[S]]:
        """Build the ClientResponse from a driver that has reached
        OUTBOUND_STATE_DONE via the non-blocking stepper. Identical SEAM to
        `run` / `run_with_body`'s tail — extract pre-body bytes, choose the
        framing, and hand the stream off to a RecvRingBody whose body is
        drained later via `poll_frame`. The caller owns the stream and
        moves it in here once the head is parsed."""
        var pre_body = self._extract_pre_body_bytes()
        var resp_body: RecvRingBody[S]
        # HEAD / empty-status / CL=0 short-circuit (mirrors run_with_body).
        if (
            self._is_head_request
            or self._content_length == 0
            or self._is_empty_status_body()
        ):
            # HAND THE PRE-BODY BYTES OVER EVEN THOUGH THERE IS NO BODY.
            # They are 100% the NEXT message's, and this arm used to be
            # the one that dropped them -- see `new_empty`'s two-arg
            # overload for why an empty-body response is the shape most
            # likely to carry them.
            resp_body = RecvRingBody[S].new_empty(
                stream^, pre_body_bytes=pre_body^,
            )
        elif self._is_chunked:
            resp_body = RecvRingBody[S].new_chunked(
                stream^,
                pre_body_bytes=pre_body^,
                max_body_bytes=self._max_response_body_bytes,
            )
        elif self._content_length > 0:
            resp_body = RecvRingBody[S].new_content_length(
                stream^,
                cl_total=self._content_length,
                pre_body_bytes=pre_body^,
            )
        else:
            resp_body = RecvRingBody[S].new_read_until_eof(
                stream^,
                pre_body_bytes=pre_body^,
                max_body_bytes=self._max_response_body_bytes,
            )
        # STAMP THE DEADLINE ONTO THE BODY. This one line is what moves
        # the bound across the head/body seam. `set_deadline_us` is a
        # no-op for an unarmed driver (0) and only ever TIGHTENS.
        resp_body.set_deadline_us(self._deadline_us)
        var resp = ClientResponse[RecvRingBody[S]](resp_body^)
        resp.status = self._final_status
        var reason_tmp = String()
        swap(reason_tmp, self._final_reason)
        resp.reason = reason_tmp^
        var hdrs_tmp = HeaderMap()
        swap(hdrs_tmp, self._final_headers)
        resp.headers = hdrs_tmp^
        resp.connection_close = self._connection_close
        return resp^

    def run[
        S: IoStream, RT: Runtime, scratch_o: Origin[mut=True],
    ](
        mut self,
        var stream: S,
        mut reactor: Reactor[RT.Sink],
        scratch: Span[UInt8, scratch_o],
    ) raises -> ClientResponse[RecvRingBody[S]]:
        """Drive the request-write + head-read phases of the
        request-response cycle. The body is NOT drained here — instead,
        the stream + any pre-body bytes are moved into a `RecvRingBody`
        conformer carried by the returned `ClientResponse`. Caller drives
        the body via `resp.body.poll_frame[RT](reactor, token)` or via
        the `collect_body[RT, S](resp.body, reactor, token)` helper.


        `scratch` is a caller-owned 4 KB+ byte span used for the response
        head's `stream.try_read` call. Long-lived owners (HttpClient)
        amortize the 4 KB allocation across all send_buffered calls.

        SEAM FLIP: this method replaces's slurp-then-construct
        BufferedResponseBody shape. The OutboundDriver no longer owns
        the body-read loop — that responsibility moves to RecvRingBody.
        The 2 GB-flat-RSS contract is honored by design:
        the OutboundDriver buffers only the response head, not the body.

         state ordering for the default path:
          IDLE ->
          WRITING_REQUEST_HEADERS (drains the entire req_bytes blob —
            for now the head + the body are pre-serialized into one
            buffer; splits them so streaming bodies can flow without
            re-buffering) ->
          READING_RESPONSE_HEAD ->
          DONE (body deferred to RecvRingBody).

        On Pending from try_read / try_write: park via the reactor
        retry pattern — for now synchronous tests we treat Pending
        as a "no progress, try again next iteration" (the underlying
        try_io_* paths handle the non-blocking retry internally on
        macOS; the reactor.poll_completions path is the production park
        mechanism but ScriptedStream needs a synchronous loop to make
        progress).

        Stream ownership: `var stream` is moved into this method; on
        success the stream is moved INTO the returned RecvRingBody so
        the body conformer can drive subsequent try_read calls; on
        error the stream is dropped (RAII close).
        """
        self._state = OUTBOUND_STATE_WRITING_REQUEST_HEADERS

        #
        # spin-then-park + wall-clock deadline. `_drive_write` / `_drive_read_
        # head` are non-blocking — on EWOULDBLOCK they make NO progress. We
        # track consecutive no-progress iterations and, after a small spin
        # budget, park on the stream fd until it's ready (reclaiming the CPU
        # during a slow server's work) instead of busy-spinning. The loop
        # fails only when the configured wall-clock deadline elapses — NOT on
        # an iteration count (the prior hard cap killed healthy-but-slow
        # servers, e.g. a multi-second local-LLM generation).
        # ARM THE REQUEST DEADLINE ON THE DRIVER, not in a local: the
        # body construction sites at the tail of this method STAMP IT
        # ONTO THE BODY, so the same budget bounds the body drain. See
        # `OutboundDriver._deadline_us`.
        self._arm_deadline()
        var deadline_us = self._deadline_us
        var no_progress = 0

        while True:
            # ⭐ THE DEADLINE IS EVALUATED HERE, ON EVERY ITERATION, AND
            # NOWHERE ELSE CAN BE TRUSTED TO DO IT. A clock read only inside
            # `_tick_no_progress`, behind
            # its `no_progress >= _HEAD_DRIVE_SPIN_BUDGET` gate, is defeated by
            # every branch below resetting `no_progress` to 0 the instant the peer
            # delivers a byte. A peer trickling one byte more often than every
            # 64 iterations would keep the counter under the budget
            # forever, the deadline check would never be REACHED, and the request
            # would hang with no bound at all: not the configured budget, not the
            # 600 s default — hours of 504s at the platform ceiling with the
            # process alive at a steady low CPU (64 spins plus one 50 ms
            # park per cycle, the signature of this loop).
            #
            # A deadline the peer can defeat by dribbling is not a deadline.
            # Checking it here — before any state work, gated on nothing —
            # is what makes it one. Falsifier:
            # `tests/test_head_drive_deadline_survives_byte_dribble.mojo`.
            #
            # DONE / ERROR are terminal and are skipped deliberately: the head
            # is already parsed by then, and failing a request whose response
            # we are holding would trade a hang for data loss.
            if (
                self._state != OUTBOUND_STATE_DONE
                and self._state != OUTBOUND_STATE_ERROR
            ):
                self._check_deadline(deadline_us)
            if self._state == OUTBOUND_STATE_WRITING_REQUEST_HEADERS:
                # one combined req_bytes blob. splits
                # headers vs body for streaming-body support.
                var before_cursor = self._write_cursor
                self._drive_write[S, RT](stream, reactor)
                if self._write_cursor >= self._req_bytes.__len__():
                    self._state = OUTBOUND_STATE_READING_RESPONSE_HEAD
                    no_progress = 0
                elif self._write_cursor > before_cursor:
                    no_progress = 0
                else:
                    self._tick_no_progress[S, RT](
                        stream, reactor, no_progress, deadline_us,
                    )
                continue

            elif self._state == OUTBOUND_STATE_READING_RESPONSE_HEAD:
                # Pull bytes; try parse; loop until OK or hard error.
                var before_recv = self._recv_buf.__len__()
                var maybe_done = self._drive_read_head[S, RT](
                    stream, reactor, scratch,
                )
                if maybe_done:
                    # Head parsed; flip — transition straight to DONE.
                    # Body bytes that arrived along with the head live in
                    # _recv_buf past _headers_end_off; they get seeded
                    # into RecvRingBody below.
                    # RFC 9110 15.2: an interim (1xx) response does NOT
                    # terminate the exchange -- skip it and stay in this
                    # state to parse the real one. `_head_was_interim`
                    # preserves the bytes after the interim head, and
                    # `_drive_read_head`'s fast path re-parses them
                    # without touching the stream. 101 is NOT interim.
                    if not self._head_was_interim():
                        self._state = OUTBOUND_STATE_DONE
                    no_progress = 0
                elif self._recv_buf.__len__() > before_recv:
                    no_progress = 0
                else:
                    self._tick_no_progress[S, RT](
                        stream, reactor, no_progress, deadline_us,
                    )
                continue

            elif self._state == OUTBOUND_STATE_DONE:
                break

            elif self._state == OUTBOUND_STATE_ERROR:
                # _drive_* set this and already raised; defensive.
                raise Error("HttpError: state machine in ERROR state")

            else:
                # Unknown state — defensive.
                self._state = OUTBOUND_STATE_ERROR
                raise Error("HttpError[INTERNAL]: unknown state")

        # SEAM: extract any pre-body bytes from recv_buf
        # (everything past _headers_end_off) and hand the stream +
        # pre-body bytes off to a RecvRingBody conformer.
        var pre_body = self._extract_pre_body_bytes()
        var resp_body: RecvRingBody[S]
        # HEAD
        # responses MUST NOT have a body even when Content-Length is
        # present (RFC 7230 §3.3.2 / RFC 7231 §4.3.2). Check FIRST so
        # we never route a HEAD response through the CL / chunked /
        # read-until-EOF branches.
        if (
            self._is_head_request
            or self._content_length == 0
            or self._is_empty_status_body()
        ):
            # Empty body — RecvRingBody.new_empty.
            # HAND THE PRE-BODY BYTES OVER EVEN THOUGH THERE IS NO BODY.
            # They are 100% the NEXT message's, and this arm used to be
            # the one that dropped them -- see `new_empty`'s two-arg
            # overload for why an empty-body response is the shape most
            # likely to carry them.
            resp_body = RecvRingBody[S].new_empty(
                stream^, pre_body_bytes=pre_body^,
            )
        elif self._is_chunked:
            resp_body = RecvRingBody[S].new_chunked(
                stream^,
                pre_body_bytes=pre_body^,
                max_body_bytes=self._max_response_body_bytes,
            )
        elif self._content_length > 0:
            resp_body = RecvRingBody[S].new_content_length(
                stream^,
                cl_total=self._content_length,
                pre_body_bytes=pre_body^,
            )
        else:
            # No CL, no chunked, non-empty status: read-until-EOF.
            resp_body = RecvRingBody[S].new_read_until_eof(
                stream^,
                pre_body_bytes=pre_body^,
                max_body_bytes=self._max_response_body_bytes,
            )

        # STAMP THE DEADLINE ONTO THE BODY. This one line is what moves
        # the bound across the head/body seam. `set_deadline_us` is a
        # no-op for an unarmed driver (0) and only ever TIGHTENS.
        resp_body.set_deadline_us(self._deadline_us)
        var resp = ClientResponse[RecvRingBody[S]](resp_body^)
        resp.status = self._final_status
        var reason_tmp = String()
        swap(reason_tmp, self._final_reason)
        resp.reason = reason_tmp^
        # Move out the headers without partial-moving self.
        var hdrs_tmp = HeaderMap()
        swap(hdrs_tmp, self._final_headers)
        resp.headers = hdrs_tmp^
        resp.connection_close = self._connection_close
        return resp^

    def _reset_response_parse_state(mut self):
        """Discard the parsed 100 Continue interim response so the
        driver can parse the FINAL response after the body is written.

        Drains _recv_buf up to _headers_end_off (the bytes that were
        the 100 Continue head); any bytes after that point are
        preserved (they may be the start of the final response head
        which arrived early). Resets all parse-state fields.
        """
        if self._headers_end_off > 0:
            var new_buf = List[UInt8]()
            var n = self._recv_buf.__len__()
            var i = self._headers_end_off
            while i < n:
                new_buf.append(self._recv_buf[i])
                i = i + 1
            self._recv_buf = new_buf^
        self._headers_end_off = -1
        self._content_length = -1
        self._is_chunked = False
        self._connection_close = False
        self._body_bytes_received = 0
        self._chunked_decoder_state = ChunkedDecoder.init()
        self._decoded_body = List[UInt8]()
        self._final_status = Int32(0)
        self._final_reason = String()
        self._final_headers = HeaderMap()

    def _extract_pre_body_bytes(mut self) -> List[UInt8]:
        """Pull any bytes from self._recv_buf that lie past
        self._headers_end_off — these are body bytes that arrived along
        with the head and must be seeded into the RecvRingBody."""
        var out = List[UInt8]()
        if self._headers_end_off < 0:
            return out^
        var n_recv = self._recv_buf.__len__()
        var start = self._headers_end_off
        if start >= n_recv:
            return out^
        var i = start
        while i < n_recv:
            out.append(self._recv_buf[i])
            i = i + 1
        return out^

    def _head_was_interim(mut self) raises -> Bool:
        """RFC 9110 15.2, a MUST on the CLIENT: "A client MUST be able to
        parse one or more 1xx responses received prior to a final response,
        even if the client does not expect one."

        Call this immediately after `_drive_read_head` reports a parsed head.
        Returns True iff that head was an INTERIM response, in which case the
        parse state has been reset and the caller must STAY in
        READING_RESPONSE_HEAD to parse the real one. Returns False for a
        final response, leaving all parse state untouched.

        ⭐ 101 IS NOT INTERIM HERE, AND THAT IS THE WHOLE SUBTLETY. A 101
        Switching Protocols terminates the HTTP/1.1 message stream: the bytes
        after it belong to the upgraded protocol (WebSocket, h2c), so reading
        "the next response" off that connection is a protocol confusion, not a
        recovery. It is returned to the caller as the final response with an
        empty body, which is what `_is_empty_status_body` already arranges.
        Pinned by `test_101_with_{content_length,transfer_encoding}_has_no_body`.

        ⚠ THE BYTES OF THE REAL RESPONSE ARE NOT LOST BY THIS PATH.
        `_reset_response_parse_state` drains `_recv_buf` only up to
        `_headers_end_off` and PRESERVES everything after it, and
        `_drive_read_head`'s fast path re-parses that remainder before
        issuing another `try_read`. So an interim response and its successor
        arriving in one read is handled without touching the stream again --
        which is the case `103 Early Hints` from a GFE actually produces.

        Pinned by `test_L2_special_status_framing.mojo` §4
        (`test_unsolicited_100_continue_is_not_the_final_response`,
        `test_103_early_hints_is_not_the_final_response`,
        `test_two_consecutive_1xx_then_the_final_response`).
        """
        var status = Int(self._final_status)
        if status < 100 or status >= 200:
            return False
        if status == 101:
            return False
        self._interim_responses_seen = self._interim_responses_seen + 1
        if self._interim_responses_seen > _MAX_INTERIM_RESPONSES:
            self._state = OUTBOUND_STATE_ERROR
            raise Error(
                "HttpError[PROTOCOL_ERROR]: more than "
                + String(_MAX_INTERIM_RESPONSES)
                + " consecutive 1xx interim responses before a final one"
            )
        self._reset_response_parse_state()
        return True

    def _is_empty_status_body(self) -> Bool:
        """Per RFC 7230 §3.3.3, responses with status 1xx, 204, or 304
        MUST NOT contain a message body, regardless of headers. This
        check covers the RESPONSE-SIDE conditions only.

        The REQUEST-SIDE condition (HEAD responses MUST NOT have a
        body even with `Content-Length` set, per RFC 7230 §3.3.2 / RFC
        7231 §4.3.2) is handled by the `_is_head_request` flag, set by
        the caller via `set_is_head_request(True)` BEFORE `run` /
        `run_with_body`. The body-decision block in both methods checks
        both `_is_head_request` AND `_is_empty_status_body()`.
        """
        var s = Int(self._final_status)
        if s >= 100 and s < 200:
            return True
        if s == 204:
            return True
        if s == 304:
            return True
        return False

    def run_buffered[
        S: IoStream, RT: Runtime, scratch_o: Origin[mut=True],
    ](
        mut self,
        var stream: S,
        mut reactor: Reactor[RT.Sink],
        scratch: Span[UInt8, scratch_o],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """Backward-compat convenience that wraps `run` + drains the
        body via `collect_body` into one BufferedResponseBody. Preserves
        the slurp semantic for callers (especially tests) that
        explicitly want the fully-buffered shape.

        This is NOT an additive parallel API — it's a one-line
        convenience that runs `run` then collects the body. Production
        consumers that want streaming use `run` directly.
        """
        var resp = self.run[S, RT](stream^, reactor, scratch)
        # Drain the RecvRingBody using collect_body. Use a never-cancellable
        # token; cancellation must be threaded by the caller if needed.
        #
        # THE DEADLINE ARRIVES ON THE BODY, NOT THROUGH THIS CALL. `run`
        # armed `_deadline_us` and stamped it onto `resp.body`; `poll_frame`
        # enforces it. This method is bounded here
        # for free, because an unbounded path is a template.
        var tok = CancellationToken.never()
        var body_bytes = collect_body[RT, S](resp.body, reactor, tok)
        # Repackage into a BufferedResponseBody.
        var resp_body = BufferedResponseBody.from_bytes(body_bytes^)
        var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
        buf_resp.status = resp.status
        var reason_tmp = String()
        swap(reason_tmp, resp.reason)
        buf_resp.reason = reason_tmp^
        var hdrs_tmp = HeaderMap()
        swap(hdrs_tmp, resp.headers)
        buf_resp.headers = hdrs_tmp^
        buf_resp.connection_close = resp.connection_close
        return buf_resp^

    def run_with_body[
        S: IoStream, RT: Runtime, B: RequestBody, scratch_o: Origin[mut=True],
    ](
        mut self,
        var stream: S,
        var body: B,
        mut reactor: Reactor[RT.Sink],
        scratch: Span[UInt8, scratch_o],
        expect_continue: Bool = False,
    ) raises -> ClientResponse[RecvRingBody[S]]:
        """Streaming entry point. After writing the HEAD bytes
        (which the caller pre-serialized into `req_bytes`), this method
        drains the request body via `body.read_chunk(dst)` repeatedly
        into the wire — without slurping the body into RAM. This is the
        flat-RSS path for large PUT uploads.

        Algorithm:
          1. WRITING_REQUEST_HEADERS — drain `_req_bytes` (the HEAD).
          2. WRITING_REQUEST_BODY — pull chunks from `body.read_chunk`
             into a small scratch, write each chunk to the stream.
             Loop until read_chunk returns 0.
          3. READING_RESPONSE_HEAD / DONE — same as `run`.

        For buffered bodies (EmptyBody / drained-BytesBody),
        `read_chunk` returns 0 immediately so the body-write phase is a
        no-op (one method call) — semantically equivalent to `run` for
        those cases.

        Stream ownership: same as `run` — `var stream` is moved in,
        moved into the returned RecvRingBody on success.
        """
        self._state = OUTBOUND_STATE_WRITING_REQUEST_HEADERS
        #
        # spin-then-park + wall-clock deadline (same fix as `run` above). The
        # head-write / Expect-100 head-read / final head-read phases all drive
        # non-blocking helpers that make NO progress on EWOULDBLOCK; without a
        # park this loop pinned a core for the entire server wait and then
        # raised an iteration-cap TIMEOUT — failing healthy-but-slow servers
        # (e.g. a multi-second local-LLM chat-completion generation). We park
        # cooperatively after a small spin budget and bound the loop by REAL
        # time, never by an iteration count.
        # ARM THE REQUEST DEADLINE ON THE DRIVER, not in a local: the
        # body construction sites at the tail of this method STAMP IT
        # ONTO THE BODY, so the same budget bounds the body drain. See
        # `OutboundDriver._deadline_us`.
        self._arm_deadline()
        var deadline_us = self._deadline_us
        var no_progress = 0

        while True:
            # ⭐ THE DEADLINE IS EVALUATED HERE, ON EVERY ITERATION, AND
            # NOWHERE ELSE CAN BE TRUSTED TO DO IT. A clock read only inside
            # `_tick_no_progress`, behind
            # its `no_progress >= _HEAD_DRIVE_SPIN_BUDGET` gate, is defeated by
            # every branch below resetting `no_progress` to 0 the instant the peer
            # delivers a byte. A peer trickling one byte more often than every
            # 64 iterations would keep the counter under the budget
            # forever, the deadline check would never be REACHED, and the request
            # would hang with no bound at all: not the configured budget, not the
            # 600 s default — hours of 504s at the platform ceiling with the
            # process alive at a steady low CPU (64 spins plus one 50 ms
            # park per cycle, the signature of this loop).
            #
            # A deadline the peer can defeat by dribbling is not a deadline.
            # Checking it here — before any state work, gated on nothing —
            # is what makes it one. Falsifier:
            # `tests/test_head_drive_deadline_survives_byte_dribble.mojo`.
            #
            # DONE / ERROR are terminal and are skipped deliberately: the head
            # is already parsed by then, and failing a request whose response
            # we are holding would trade a hang for data loss.
            if (
                self._state != OUTBOUND_STATE_DONE
                and self._state != OUTBOUND_STATE_ERROR
            ):
                self._check_deadline(deadline_us)
            if self._state == OUTBOUND_STATE_WRITING_REQUEST_HEADERS:
                var before_cursor = self._write_cursor
                self._drive_write[S, RT](stream, reactor)
                if self._write_cursor >= self._req_bytes.__len__():
                    if expect_continue:
                        # wait for 100 Continue before sending body.
                        self._state = OUTBOUND_STATE_WAITING_FOR_CONTINUE
                    else:
                        self._state = OUTBOUND_STATE_WRITING_REQUEST_BODY
                    no_progress = 0
                elif self._write_cursor > before_cursor:
                    no_progress = 0
                else:
                    self._tick_no_progress[S, RT](
                        stream, reactor, no_progress, deadline_us,
                    )
                continue

            elif self._state == OUTBOUND_STATE_WAITING_FOR_CONTINUE:
                # read one response head; check status.
                # 100 Continue → reset parser state and proceed to body
                # write. Any other status → skip body, transition to
                # DONE with that response.
                var before_recv = self._recv_buf.__len__()
                var maybe_done = self._drive_read_head[S, RT](
                    stream, reactor, scratch,
                )
                if maybe_done:
                    var status = Int(self._final_status)
                    if status == 100:
                        # Discard the 100 Continue interim response and
                        # reset parser state to read the FINAL response
                        # after body-write.
                        self._reset_response_parse_state()
                        self._state = OUTBOUND_STATE_WRITING_REQUEST_BODY
                    else:
                        # Server rejected (4xx) or sent a final
                        # response without waiting (RFC 7231 §5.1.1).
                        # Skip body, return the response we got.
                        self._state = OUTBOUND_STATE_DONE
                    no_progress = 0
                elif self._recv_buf.__len__() > before_recv:
                    no_progress = 0
                else:
                    self._tick_no_progress[S, RT](
                        stream, reactor, no_progress, deadline_us,
                    )
                continue

            elif self._state == OUTBOUND_STATE_WRITING_REQUEST_BODY:
                # Drain `body` chunk-by-chunk to the wire. Uses a
                # 64 KiB scratch buffer; RSS cost is BOUNDED by scratch
                # size regardless of body size. `_drive_write_body` pulls a
                # body chunk and writes it (its inner write-spin self-bounds
                # on a finite chunk), so each call makes deterministic
                # progress — no park needed here.
                var done = self._drive_write_body[S, RT, B](
                    stream, body, reactor,
                )
                if done:
                    self._state = OUTBOUND_STATE_READING_RESPONSE_HEAD
                no_progress = 0
                continue

            elif self._state == OUTBOUND_STATE_READING_RESPONSE_HEAD:
                var before_recv = self._recv_buf.__len__()
                var maybe_done = self._drive_read_head[S, RT](
                    stream, reactor, scratch,
                )
                if maybe_done:
                    # RFC 9110 15.2: an interim (1xx) response does NOT
                    # terminate the exchange -- skip it and stay in this
                    # state to parse the real one. `_head_was_interim`
                    # preserves the bytes after the interim head, and
                    # `_drive_read_head`'s fast path re-parses them
                    # without touching the stream. 101 is NOT interim.
                    if not self._head_was_interim():
                        self._state = OUTBOUND_STATE_DONE
                    no_progress = 0
                elif self._recv_buf.__len__() > before_recv:
                    no_progress = 0
                else:
                    self._tick_no_progress[S, RT](
                        stream, reactor, no_progress, deadline_us,
                    )
                continue

            elif self._state == OUTBOUND_STATE_DONE:
                break

            elif self._state == OUTBOUND_STATE_ERROR:
                raise Error("HttpError: state machine in ERROR state")

            else:
                self._state = OUTBOUND_STATE_ERROR
                raise Error("HttpError[INTERNAL]: unknown state")

        # SEAM as in `run`: hand stream + pre-body bytes off to RecvRingBody.
        var pre_body = self._extract_pre_body_bytes()
        var resp_body: RecvRingBody[S]
        # see
        # mirroring check in `run`. HEAD responses MUST NOT have a body
        # even when Content-Length is present (RFC 7230 §3.3.2 / RFC
        # 7231 §4.3.2). Check FIRST.
        if (
            self._is_head_request
            or self._content_length == 0
            or self._is_empty_status_body()
        ):
            # HAND THE PRE-BODY BYTES OVER EVEN THOUGH THERE IS NO BODY.
            # They are 100% the NEXT message's, and this arm used to be
            # the one that dropped them -- see `new_empty`'s two-arg
            # overload for why an empty-body response is the shape most
            # likely to carry them.
            resp_body = RecvRingBody[S].new_empty(
                stream^, pre_body_bytes=pre_body^,
            )
        elif self._is_chunked:
            resp_body = RecvRingBody[S].new_chunked(
                stream^,
                pre_body_bytes=pre_body^,
                max_body_bytes=self._max_response_body_bytes,
            )
        elif self._content_length > 0:
            resp_body = RecvRingBody[S].new_content_length(
                stream^,
                cl_total=self._content_length,
                pre_body_bytes=pre_body^,
            )
        else:
            resp_body = RecvRingBody[S].new_read_until_eof(
                stream^,
                pre_body_bytes=pre_body^,
                max_body_bytes=self._max_response_body_bytes,
            )

        # STAMP THE DEADLINE ONTO THE BODY. This one line is what moves
        # the bound across the head/body seam. `set_deadline_us` is a
        # no-op for an unarmed driver (0) and only ever TIGHTENS.
        resp_body.set_deadline_us(self._deadline_us)
        var resp = ClientResponse[RecvRingBody[S]](resp_body^)
        resp.status = self._final_status
        var reason_tmp = String()
        swap(reason_tmp, self._final_reason)
        resp.reason = reason_tmp^
        var hdrs_tmp = HeaderMap()
        swap(hdrs_tmp, self._final_headers)
        resp.headers = hdrs_tmp^
        resp.connection_close = self._connection_close
        # Body is now empty (drained); drop it.
        _ = body^
        return resp^

    def _drive_write_body[
        S: IoStream, RT: Runtime, B: RequestBody,
    ](
        mut self,
        mut stream: S,
        mut body: B,
        mut reactor: Reactor[RT.Sink],
    ) raises -> Bool:
        """Drain one chunk from body.read_chunk and write it to the
        wire. Returns True iff the body is fully drained (read_chunk
        returned 0). Returns False if more bytes remain (caller loops).

        Uses a 64 KiB scratch buffer — RSS cost is bounded by this
        regardless of total body size.
        """
        var SCRATCH: Int = 65536
        var scratch = List[UInt8]()
        var i = 0
        while i < SCRATCH:
            scratch.append(UInt8(0))
            i = i + 1
        var n = body.read_chunk(Span[UInt8](scratch))
        if n == 0:
            return True
        # Write `scratch[:n]` to the wire. May need multiple try_write
        # calls if the stream accepts a partial.
        var written = 0
        while written < n:
            var src_view = Span[UInt8](scratch).as_imm()
            var src_slice = src_view[written:n]
            var res = stream.try_write[RT](reactor, src_slice)
            if res._state == STREAM_IO_READY:
                written = written + Int(res._payload)
            elif res._state == STREAM_IO_PENDING:
                # In synchronous loop mode, treat as "try again next iter".
                # The caller's run loop re-enters _drive_write_body which
                # would re-pull from body — but the body's cursor has
                # advanced and we have un-written bytes in scratch.
                # Workaround: spin until ready.
                continue
            elif res._state == STREAM_IO_ERROR:
                self._state = OUTBOUND_STATE_ERROR
                raise self._write_error(res._payload)
            else:
                self._state = OUTBOUND_STATE_ERROR
                raise Error("HttpError[IO_ERROR]: write returned EOF")
        # Chunk written. Caller loops to pull the next chunk.
        return False

    def _write_error(self, errno_payload: Int64) -> Error:
        """Classify a write-side `STREAM_IO_ERROR` — THE CLASS IS THE
        DISPOSITION.

        ★ SYMMETRY WITH `_drive_read_head`. The read side
        distinguishes "peer closed before any response byte"
        (`RETRYABLE_TRANSPORT` — re-issuable) from "peer closed during head"
        (`EOF_MID_RESPONSE`). Collapsing both on the write
        side into a bare `IO_ERROR` would put them in NO
        connection-level retry set (the GCS and S3 clients' retryable sets in
        `komira_gcp_bridge` / `komira_aws_s3`).

        Over TLS this matters because `s2n_shim` reports a `write(2)`
        EPIPE/ECONNRESET as an error rather than laundering it into
        BLOCKED_ON_WRITE (which would park-and-respin until
        `HttpError[TIMEOUT]: request deadline exceeded waiting for the server
        (no progress)`). A shim that reports the error WITHOUT this
        classification would convert a retried fault into a hard one.

        `len(self._recv_buf) == 0` is the same discriminator `_drive_read_head`
        uses, read at the same altitude: zero bytes off the wire means the peer
        never answered, so the request got no verdict and re-issuing it on a
        fresh connection cannot duplicate an effect this peer reported."""
        if self._recv_buf.__len__() == 0:
            # ★ TERM 3 OF GO'S RULE, AND IT IS A DIFFERENT FACT FROM TERM 2.
            # `_write_cursor == 0` means not one request byte was accepted by
            # the kernel, so the peer cannot have seen — let alone executed —
            # this request. That is Go's `nothingWrittenError`, and it is what
            # licenses re-issuing a NON-IDEMPOTENT verb. The `else` arm below
            # it is still RETRYABLE_TRANSPORT (the peer answered nothing), but
            # it carries only term 2: bytes DID reach the wire, so a POST may
            # have been executed and `_h1_pooled_retry_is_safe` will refuse it.
            var nothing_written = self._write_cursor == 0
            var tail = String("")
            if nothing_written:
                tail = (
                    String(" ") + HTTP_NOTHING_WRITTEN_TOKEN
                    + ": zero request bytes reached the wire, so the peer"
                    " cannot have executed this request"
                )
            return Error(
                "HttpError[RETRYABLE_TRANSPORT]: write errno="
                + String(Int(errno_payload))
                + " before any response byte — the peer went away while the"
                " request was still being written (the"
                " reaped-pooled-connection race); the request got no verdict"
                + tail
            )
        return Error(
            "HttpError[IO_ERROR]: errno=" + String(Int(errno_payload))
            + " after " + String(self._recv_buf.__len__())
            + " response bytes — the peer answered before the write failed, so"
            " the request MAY have been executed and this is deliberately not"
            " in the connection-level retry set"
        )

    # ----- Internal: write side -------------------------------------------

    def _drive_write[S: IoStream, RT: Runtime](
        mut self,
        mut stream: S,
        mut reactor: Reactor[RT.Sink],
    ) raises:
        """Drain one try_write call. Advances _write_cursor. Raises on
        hard error. Returns when:
          * all bytes accepted (cursor == req_bytes.len)
          * one Pending happens (caller's loop will retry)
        """
        var n_to_write = self._req_bytes.__len__() - self._write_cursor
        if n_to_write <= 0:
            return
        # Build a Span over the un-written tail.
        var src = Span[UInt8](self._req_bytes).as_imm()
        var src_slice = src[self._write_cursor:]
        var res = stream.try_write[RT](reactor, src_slice)
        if res._state == STREAM_IO_READY:
            var n = Int(res._payload)
            self._write_cursor = self._write_cursor + n
            self._park_pending_valid = False
            return
        if res._state == STREAM_IO_PENDING:
            # ONE-PARK-PRIMITIVE: carry the Pending to the park site. The park
            # is several frames away (see `_park_pending_token`), so without
            # this the only thing left there is "the state machine was
            # writing" — a guess about the CALL, which is not the same
            # question as which direction to WAIT on.
            self._park_pending_token = res._payload
            self._park_pending_is_write = True
            self._park_pending_valid = True
            return
        if res._state == STREAM_IO_ERROR:
            self._state = OUTBOUND_STATE_ERROR
            raise self._write_error(res._payload)
        # STREAM_IO_EOF on write side is impossible.
        self._state = OUTBOUND_STATE_ERROR
        raise Error("HttpError[IO_ERROR]: write returned EOF")

    # ----- Internal: cooperative park -------------------------------------

    # =====================================================================
    # `_park_on_stream_fd` is DELETED.
    # =====================================================================
    #
    # It was the third of four independent park helpers, and the only one on
    # a DIFFERENT mechanism: `Reactor.park_on_fds` rather than a transient
    # op-id registration. Nothing about this driver needed that mechanism —
    # it parks on exactly ONE fd, which is the op-id path's whole domain —
    # and using it cost two properties that
    # `komira_http.transport.stream_park.park_on_pending` now supplies:
    #
    #   * `park_on_fds` returns `epoll_wait`'s raw event count on the SHARED
    #     reactor epoll fd, so a FOREIGN fd's readiness ended this park and
    #     was counted as ours (invariant (ii) — the
    #     defect). It never surfaced HERE because this park is gated by a
    #     spin budget and a wall clock rather than an iteration budget, so a
    #     premature return cost latency, not a spurious TIMEOUT.
    #   * `want_write` was a LITERAL, taken from which state the machine was
    #     in. Note the asymmetry that hid half of it:
    #     `park_on_fds(want_write=True)` arms `EPOLLIN | EPOLLOUT` — BOTH
    #     directions — so the two write-side sites were direction-inversion-
    #     immune BY ACCIDENT, while the three read-side sites armed EPOLLIN
    #     only and would have waited out a full slice for a wake that could
    #     not come. Being right by accident in half the cases is precisely
    #     the state this collapse exists to end.
    #
    # The buffered-plaintext lost-wakeup guard this helper carried inline
    # (`if not want_write and stream.has_buffered_readable(): return`) is
    # DERIVED inside the primitive from the same expression, so it cannot be
    # dropped by a future copy. Why the guard exists: a TLS stream can hold
    # decrypted bytes that socket readiness cannot see, so a park would miss
    # its wakeup.
    # =====================================================================

    def _check_deadline(mut self, deadline_us: Int) raises:
        """Raise a typed TIMEOUT if the wall-clock deadline has passed.

        Called UNCONDITIONALLY at the head of every `run` / `run_with_body`
        iteration. It is deliberately independent of the no-progress counter,
        of whether any I/O was attempted, and of whether the peer is sending:
        a peer that keeps the connection fed with bytes it never finishes a
        response with is precisely the case the budget exists to bound, and it
        is the one case the counter-gated check could not see."""
        var now_us = Int(_system_now_ns() // UInt64(1000))
        if now_us >= deadline_us:
            self._state = OUTBOUND_STATE_ERROR
            raise Error(
                "HttpError[TIMEOUT]: request deadline exceeded while driving"
                " the request (the peer may be delivering bytes without ever"
                " completing a response head)"
            )

    def _tick_no_progress[S: IoStream, RT: Runtime](
        mut self,
        ref stream: S,
        mut reactor: Reactor[RT.Sink],
        mut no_progress: Int,
        deadline_us: Int,
    ) raises:
        """One no-progress tick
        of the drive loop. Increments the consecutive-no-progress counter;
        after `_HEAD_DRIVE_SPIN_BUDGET` consecutive no-progress iterations,
        parks on the stream fd (cooperative wait) and resets the counter. The
        wall-clock deadline is checked AFTER any park, so a genuinely stuck
        peer fails with a TIMEOUT rather than blocking forever; a healthy
        slow server (still working, no bytes yet) keeps parking until it
        replies. Raises (and sets ERROR state) on deadline expiry.

        ⚠ `want_write` IS GONE. Every caller
        passed a literal derived from which state the machine was in — an
        assertion about the CALL, offered as the answer to a different
        question (which direction to WAIT on). The park now reads the Pending
        this driver actually received (`_park_pending_*`, stamped at the I/O
        site) and lets `park_on_pending` ask the conformer. Deleting the
        parameter is the point: there is no longer anywhere at a call site to
        state a direction.

        When the last I/O did NOT end in a Pending (`_park_pending_valid ==
        False` — a zero-byte READY, or no I/O attempted this pass) we do not
        park: there is no Pending to park on, and parking on a guessed
        direction is what this change removes. The deadline check still runs,
        so such a loop still terminates with a typed TIMEOUT."""
        no_progress = no_progress + 1
        if no_progress >= _HEAD_DRIVE_SPIN_BUDGET:
            if self._park_pending_valid:
                _ = park_on_pending[S, RT](
                    stream, reactor,
                    pending_token=self._park_pending_token,
                    call_is_write=self._park_pending_is_write,
                    slice_us=_HEAD_DRIVE_PARK_TIMEOUT_US,
                )
            no_progress = 0
            # Re-check the deadline after parking. A park can block up to
            # _HEAD_DRIVE_PARK_TIMEOUT_US, so the deadline is honored to
            # within one park interval.
            var now_us = Int(_system_now_ns() // UInt64(1000))
            if now_us >= deadline_us:
                self._state = OUTBOUND_STATE_ERROR
                raise Error(
                    "HttpError[TIMEOUT]: request deadline exceeded waiting"
                    " for the server (no progress)"
                )

    # ----- Internal: head read --------------------------------------------

    def _drive_read_head[
        S: IoStream, RT: Runtime, scratch_o: Origin[mut=True],
    ](
        mut self,
        mut stream: S,
        mut reactor: Reactor[RT.Sink],
        scratch: Span[UInt8, scratch_o],
    ) raises -> Bool:
        """Pull bytes; attempt parse. Returns True iff the head was
        parsed (transition to body reading). Otherwise False (retry on
        next iteration).


        `scratch` is a caller-owned 4 KB+ byte span used for `stream.try_read`.
        The caller (typically `OutboundDriver.run` / `run_with_body` /
        `run_buffered`) supplies a borrowed span — eliminates the prior
        per-iter `var scratch = List[UInt8](); 4096× scratch.append(0)`
        which dominated _drive_read_head self-time on a loopback
        benchmark (~35% self, ~98 µs/iter).
        """
        # if _recv_buf already has bytes (e.g. from a
        # prior 100 Continue read that left the next response's head
        # in the buffer), attempt parse FIRST before issuing another
        # stream.try_read. Otherwise the stream may have EOF'd already
        # and we'd lose a valid in-buffer head.
        if self._recv_buf.__len__() > 0:
            var limits_fast = ResponseParseLimits.defaults()
            var head_fast = parse_response_head(
                Span[UInt8](self._recv_buf), limits_fast,
            )
            if not head_fast.is_need_more():
                if head_fast.is_error():
                    self._state = OUTBOUND_STATE_ERROR
                    var err_detail = String()
                    swap(err_detail, head_fast.err.detail)
                    raise Error(
                        "HttpError[" + head_fast.err.kind_name() + "]: "
                        + err_detail
                    )
                # OK — stash fields onto self and return done.
                self._headers_end_off = head_fast.headers_end_off
                self._content_length = head_fast.content_length
                self._is_chunked = head_fast.is_chunked
                self._connection_close = head_fast.connection_close
                self._final_status = head_fast.status
                var reason_tmp_fast = String()
                swap(reason_tmp_fast, head_fast.reason)
                self._final_reason = reason_tmp_fast^
                var hdrs_tmp_fast = HeaderMap()
                swap(hdrs_tmp_fast, head_fast.headers)
                self._final_headers = hdrs_tmp_fast^
                return True
        var res = stream.try_read[RT](reactor, scratch)
        if res._state == STREAM_IO_PENDING:
            # No data this iteration; loop. ONE-PARK-PRIMITIVE: carry the
            # Pending to the park site (see `_park_pending_token`).
            self._park_pending_token = res._payload
            self._park_pending_is_write = False
            self._park_pending_valid = True
            return False
        if res._state == STREAM_IO_ERROR:
            # ★★ THE SAME DISCRIMINATOR THE EOF BRANCH DIRECTLY BELOW ALREADY
            # HAD, AND THIS BRANCH DID NOT. Read the two together:
            # `len(self._recv_buf) == 0` means the peer sent NO response byte,
            # so the request got no verdict and re-issuing it on a fresh
            # connection cannot duplicate an effect. The EOF branch has said so
            # since the h1 side was classified; this one raised a bare
            # `HttpError[IO_ERROR]`, which is in NO retry set
            # (the GCS client's retryable-connection set in `komira_gcp_bridge`).
            #
            # ⇒ FOR ONE AND THE SAME EVENT — "the peer reaped this pooled
            # connection before answering" — a FIN was RETRIED and an RST was
            # FAILED OUTRIGHT. The only difference between them is which
            # syscall result the kernel chose to report it with.
            #
            # A peer FIN arrives as EOF; a peer **RST** — what a load balancer
            # or a GFE actually sends when it reaps a pooled connection —
            # arrives HERE, as ECONNRESET. The h2 driver has the mirror rule.
            #
            # ⚠ THE BODY-READ BRANCH LOWER DOWN IS DELIBERATELY NOT CHANGED. By
            # the time it runs, response bytes HAVE arrived — the peer was
            # talking to us and the request may have been executed — so
            # `IO_ERROR` (not retryable) is the correct class there, exactly as
            # in `_write_error`'s "after N response bytes" arm.
            self._state = OUTBOUND_STATE_ERROR
            if self._recv_buf.__len__() == 0:
                raise Error(
                    "HttpError[RETRYABLE_TRANSPORT]: read errno="
                    + String(Int(res._payload))
                    + " before any response byte — the peer went away before"
                    " answering (the reaped-pooled-connection race; a TCP RST"
                    " lands here rather than on the EOF path). The request got"
                    " no verdict, so re-issuing it on a fresh connection is"
                    " safe."
                )
            raise Error(
                "HttpError[IO_ERROR]: errno=" + String(Int(res._payload))
                + " after " + String(self._recv_buf.__len__())
                + " response bytes — the peer had already answered, so the"
                " request MAY have been executed and this is deliberately not"
                " in the connection-level retry set"
            )
        if res._state == STREAM_IO_EOF:
            # If we have a partial head in recv_buf, this is mid-response
            # close.
            if self._recv_buf.__len__() == 0:
                self._state = OUTBOUND_STATE_ERROR
                raise Error(
                    "HttpError[RETRYABLE_TRANSPORT]: peer closed before"
                    + " any response byte"
                )
            self._state = OUTBOUND_STATE_ERROR
            raise Error("HttpError[EOF_MID_RESPONSE]: peer closed during head")
        # READY — copy scratch[:n] into recv_buf.
        self._park_pending_valid = False
        var n = Int(res._payload)
        var k = 0
        while k < n:
            self._recv_buf.append(scratch[k])
            k = k + 1

        # Try to parse.
        var limits = ResponseParseLimits.defaults()
        var head = parse_response_head(Span[UInt8](self._recv_buf), limits)
        if head.is_need_more():
            return False
        if head.is_error():
            self._state = OUTBOUND_STATE_ERROR
            var err_detail = String()
            swap(err_detail, head.err.detail)
            raise Error(
                "HttpError[" + head.err.kind_name() + "]: " + err_detail
            )
        # OK — stash fields onto self.
        self._headers_end_off = head.headers_end_off
        self._content_length = head.content_length
        self._is_chunked = head.is_chunked
        self._connection_close = head.connection_close
        self._final_status = head.status
        var reason_tmp = String()
        swap(reason_tmp, head.reason)
        self._final_reason = reason_tmp^
        var hdrs_tmp = HeaderMap()
        swap(hdrs_tmp, head.headers)
        self._final_headers = hdrs_tmp^
        # pre-body bytes (recv_buf past _headers_end_off) are
        # extracted by `_extract_pre_body_bytes()` at construction time
        # of the RecvRingBody. The driver no longer drains the body
        # itself; that responsibility moves to the body conformer.
        return True

    # ----- Internal: body read --------------------------------------------

    def _drive_read_body[S: IoStream, RT: Runtime](
        mut self,
        mut stream: S,
        mut reactor: Reactor[RT.Sink],
    ) raises -> Bool:
        """Drive body reception. Returns True iff body is fully
        received (transition to DONE)."""
        # Check terminal conditions first.
        if self._body_is_done():
            return True

        # Pull more bytes.
        var scratch_size: Int = 4096
        var scratch = List[UInt8]()
        var i = 0
        while i < scratch_size:
            scratch.append(UInt8(0))
            i = i + 1
        var res = stream.try_read[RT](reactor, Span[UInt8](scratch))
        if res._state == STREAM_IO_PENDING:
            return False
        if res._state == STREAM_IO_ERROR:
            self._state = OUTBOUND_STATE_ERROR
            raise Error(
                "HttpError[IO_ERROR]: errno=" + String(Int(res._payload))
            )
        if res._state == STREAM_IO_EOF:
            # CL-known body with shortfall is mid-response close.
            if self._content_length >= 0 and not self._body_is_done():
                self._state = OUTBOUND_STATE_ERROR
                raise Error(
                    "HttpError[EOF_MID_RESPONSE]: peer closed before body"
                    + " completion"
                )
            if self._is_chunked and not self._chunked_decoder_state.is_done():
                self._state = OUTBOUND_STATE_ERROR
                raise Error(
                    "HttpError[EOF_MID_RESPONSE]: peer closed before"
                    + " chunked terminator"
                )
            # If CL absent + non-chunked: read-until-EOF semantics
            # (RFC 7230 §3.3.3 rule 7). This version only supports CL or chunked;
            # surfacing this is debatable. For now treat as done.
            return True
        # READY: append + consume.
        var n = Int(res._payload)
        var k = 0
        while k < n:
            self._recv_buf.append(scratch[k])
            k = k + 1
        self._consume_body_bytes_from_recv()
        if self._body_is_done():
            return True
        return False

    def _consume_body_bytes_from_recv(mut self) raises:
        """Move bytes from _recv_buf[headers_end_off + _body_bytes_received:]
        into _decoded_body via the appropriate framing strategy."""
        var n_avail = (
            self._recv_buf.__len__()
            - self._headers_end_off
            - self._body_bytes_received
        )
        if n_avail <= 0:
            return
        if self._content_length >= 0:
            # CL framing: copy at most (CL - already_received) bytes.
            var remaining = self._content_length - self._body_bytes_received
            var n_to_copy = n_avail
            if remaining < n_to_copy:
                n_to_copy = remaining
            if n_to_copy <= 0:
                return
            # Cap by body size.
            if (
                self._decoded_body.__len__() + n_to_copy
                > self._max_response_body_bytes
            ):
                self._state = OUTBOUND_STATE_ERROR
                raise Error(
                    "HttpError[BODY_TOO_LARGE]: exceeds configured limit"
                )
            var src_off = (
                self._headers_end_off + self._body_bytes_received
            )
            var j = 0
            while j < n_to_copy:
                self._decoded_body.append(self._recv_buf[src_off + j])
                j = j + 1
            self._body_bytes_received = self._body_bytes_received + n_to_copy
            return
        if self._is_chunked:
            # Chunked decoder over the new tail of recv_buf.
            var src_off = (
                self._headers_end_off + self._body_bytes_received
            )
            # Build a Span over the un-decoded tail.
            var tail = Span[UInt8](self._recv_buf).as_imm()
            var subview = tail[src_off:]
            # ⛔ THE SECOND COPY OF THE CEILING DEFECT. `_drive_chunked` in
            # `response_body.mojo` had it too: `ParseLimits.defaults()` pins
            # `max_body_bytes` at a hardcoded 10 MiB while the configured
            # ceiling sits in `_max_response_body_bytes` (100 MiB by default)
            # and is only consulted AFTERWARDS, against the accumulated body.
            # So every chunked response between 10 MiB and 100 MiB was
            # rejected inside the decoder -- and then surfaced by the
            # `CHUNKED_RES_ERROR` arm below as RESPONSE_FRAMING, sending a
            # reader to hunt a malformed byte on a wire that has none.
            # Fixing only the `RecvRingBody` path would have left this one
            # live on exactly the same input.
            var limits = ParseLimits.defaults()
            limits.max_body_bytes = self._max_response_body_bytes
            var dec_res = decode_block(
                self._chunked_decoder_state,
                subview,
                limits,
                self._decoded_body,
            )
            self._body_bytes_received = (
                self._body_bytes_received + dec_res.consumed
            )
            # Cap on decoded body size.
            if (
                self._decoded_body.__len__()
                > self._max_response_body_bytes
            ):
                self._state = OUTBOUND_STATE_ERROR
                raise Error(
                    "HttpError[BODY_TOO_LARGE]: exceeds configured limit"
                )
            if dec_res.outcome == CHUNKED_RES_ERROR:
                self._state = OUTBOUND_STATE_ERROR
                # "Too large" is a size verdict, not a framing one, and it
                # must carry the same word the explicit cap above raises --
                # otherwise threading the ceiling into the decoder silently
                # RENAMES the error a caller already handles.
                if (
                    self._chunked_decoder_state.err.kind
                    == PARSE_ERR_BODY_TOO_LARGE
                ):
                    raise Error(
                        "HttpError[BODY_TOO_LARGE]: exceeds configured limit"
                    )
                raise Error(
                    "HttpError[RESPONSE_FRAMING]: chunked decoder error"
                )
            return
        # No CL, no chunked. Append to decoded_body as-is.
        var src_off = (
            self._headers_end_off + self._body_bytes_received
        )
        if (
            self._decoded_body.__len__() + n_avail
            > self._max_response_body_bytes
        ):
            self._state = OUTBOUND_STATE_ERROR
            raise Error(
                "HttpError[BODY_TOO_LARGE]: exceeds configured limit"
            )
        var j = 0
        while j < n_avail:
            self._decoded_body.append(self._recv_buf[src_off + j])
            j = j + 1
        self._body_bytes_received = self._body_bytes_received + n_avail

    def _body_is_done(self) -> Bool:
        if self._content_length >= 0:
            return self._body_bytes_received >= self._content_length
        if self._is_chunked:
            return self._chunked_decoder_state.is_done()
        # No CL, no chunked: we treat the body as empty (caller relies on
        # connection_close + EOF). This version is conservative — only CL or
        # chunked are framed bodies.
        return self._content_length == -1 and not self._is_chunked

    @always_inline
    def state(self) -> UInt8:
        """Read-only state accessor for tests + log lines."""
        return self._state
