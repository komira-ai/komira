# =============================================================================
# src/komira_http_client/response_body.mojo — ResponseBody trait + Buffered
# =============================================================================
#
# The READ-direction
# (response) body trait, walking back the unified-Body claim from:
# the WRITE-direction (request) trait is `RequestBody` (in body.mojo) and
# the READ-direction (response) trait is `ResponseBody` (this file).
#
# the ResponseBody trait yields BodyFrame envelopes
# from `poll_frame`:
#   * Data(chunk)    — one body chunk
#   * Trailers(hdrs) — trailing HEADERS block (chunked TE / HTTP/2 trailers)
#   * Pending        — no bytes available; caller parks
#   * End            — end-of-body
#   * Error(detail)  — hard error; map to typed HttpError
#
# ships ONE conformer:
#   * `BufferedResponseBody` — the v1-bridge default. Holds the slurped
#     `List[UInt8]` body. poll_frame yields ONE Data frame (the full body)
#     + then End idempotently.
#
# Reserved for:
#   * `RecvRingBody` — the recv-ring pull-stream zero-copy conformer.
#     Conforms to the same ResponseBody trait. The state machine flips
#     to RecvRingBody as default in; BufferedResponseBody remains
#     available for callers explicitly requesting the slurp shape.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * BufferedResponseBody owns its `_buf: List[UInt8]`. Movable, NOT
#     Copyable.
# =============================================================================

from std.builtin.swap import swap

from komira_clock import now_ns as _system_now_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_core.collections.slab import Slab
from komira_http_client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
    BodyFrame,
)
from komira_http_client.header_map import HeaderMap
from komira_http_core.codec.h1.chunked import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    CHUNKED_RES_NEED_MORE,
    ChunkedDecoder,
    decode_block,
)
from komira_http_core.codec.h1.limits import (
    PARSE_ERR_BODY_TOO_LARGE,
    ParseLimits,
)
from komira_http_core.transport.io_stream import (
    IoStream,
    STREAM_IO_EOF,
    STREAM_IO_ERROR,
    STREAM_IO_PENDING,
    STREAM_IO_READY,
)


# =============================================================================
# §1 — ResponseBody trait.
# =============================================================================


trait ResponseBody(Movable, Deinitable):
    """READ-direction (inbound response) body
    abstraction. Conformers expose a `poll_frame` method that yields
    BodyFrame envelopes — one Data(chunk) per body chunk, an optional
    Trailers(hdrs) on chunked-TE / HTTP/2 trailing-headers, Pending when
    no bytes are available, End at EOB, and Error on hard failures.

    NOTE: the WRITE-direction trait (`RequestBody`)
    is a separate trait: one unified Body for both directions does not fit.
    The WRITE-direction trait
    keeps the write-shape (`read_chunk(dst)`); the READ-direction
    trait gets the FRAME-shape `poll_frame`.

    Method:
      `poll_frame[RT: Runtime](mut self, mut reactor, ref token) -> BodyFrame`
        Drive the runtime's reactor to read more bytes from the
        underlying source; honor framing (Content-Length / chunked);
        yield a BodyFrame. The body's state is owned by the conformer;
        `poll_frame` is a mutating method.

    `ref token: CancellationToken`: the conformer
    polls token.is_cancelled() at sensible cadence and yields
    BodyFrame.error("CANCELLED") if cancellation is requested.
    BufferedResponseBody (one-shot Data + End) does NOT need to poll
    the token — the body is already buffered locally; cancellation
    matters at the wire-read layer, which happens BEFORE the buffered
    conformer is constructed.

    ships ONE conformer (`BufferedResponseBody`). RecvRingBody
    will conform to this same trait with the recv-ring
    pull-stream semantic — `poll_frame` then DOES drive the reactor +
    poll the token, and a Data chunk's bytes are memcpy'd out of the
    recv ring into the owned List[UInt8] returned in the BodyFrame.
    (The zero-copy ByteView-in-Data shape is deferred to+; see
    `body_frame.mojo` header comment for the rationale.)
    """

    def poll_frame[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> BodyFrame:
        ...


# =============================================================================
# §2 — BufferedResponseBody — the v1-bridge conformer.
# =============================================================================


struct BufferedResponseBody(ResponseBody, Movable, Deinitable):
    """The buffered response
    body conformer. Holds the already-slurped body bytes; `poll_frame`
    yields one Data(chunk) frame + then End frames idempotently.

    This is NOT an additive parallel API — it is the
    bridge conformer that the OutboundDriver can populate,
    preserving the slurp semantic for downstream callers. The default
    is RecvRingBody (the recv-ring pull-stream
    conformer); BufferedResponseBody remains the explicit
    "slurp" opt-in (e.g. for small bodies under the fast path,
    or as a convenience wrapper).

    Construction:
      * `BufferedResponseBody.from_bytes(bs)` — take ownership of `bs`.
      * `BufferedResponseBody.empty()`        — empty body (HEAD / 204
                                                 / 304 / framing-implied-
                                                 empty); first poll
                                                 yields End directly.

    State:
      _buf            — owned body bytes (slurped at construction).
      _data_emitted   — flag: True once the single Data frame has been
                        returned; subsequent poll_frame calls yield
                        End.

    Movable, NOT Copyable — owns the buffer.
    """

    var _buf: List[UInt8]
    var _data_emitted: Bool

    def __init__(out self):
        """Empty body. First poll_frame returns End directly (no Data
        emitted)."""
        self._buf = List[UInt8]()
        self._data_emitted = True  # No Data to emit for empty body.

    @staticmethod
    def empty() -> BufferedResponseBody:
        """Construct an empty body. poll_frame returns End on first
        call."""
        return BufferedResponseBody()

    @staticmethod
    def from_bytes(var bs: List[UInt8]) -> BufferedResponseBody:
        """Construct from slurped body bytes. The first poll_frame
        returns Data(bs) (ownership transferred); subsequent calls
        return End."""
        var rb = BufferedResponseBody()
        rb._buf = bs^
        # An empty buf has no Data frame to emit; treat as already-emitted.
        rb._data_emitted = rb._buf.__len__() == 0
        return rb^

    # ----- The ResponseBody trait method -----------------------------------

    def poll_frame[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> BodyFrame:
        """Yield one Data frame containing the full buffered body, then
        End frames idempotently.

        BufferedResponseBody does NOT drive the reactor — the body has
        already been read off the wire by the state-machine's
        OutboundDriver before this conformer is constructed. The
        `reactor` + `token` parameters are present for trait conformance
        (the RecvRingBody conformer will use them).

        Note on token + reactor: the body is already buffered, so
        cancellation cannot interrupt the read (there is no in-flight
        read). The conformer ignores both parameters; this is correct.

        For chunk-sized bodies (e.g. an SDK response), the entire body
        is transferred in ONE poll. This is the slurp semantic
        preserved verbatim through the new trait surface.
        """
        if self._data_emitted:
            return BodyFrame.end()
        # First poll: emit the full body as ONE Data frame.
        self._data_emitted = True
        var chunk = List[UInt8]()
        swap(chunk, self._buf)
        return BodyFrame.data(chunk^)

    # ----- Read-only accessors (for tests + convenience) -------------------

    @always_inline
    def bytes_remaining(self) -> Int:
        """Bytes still un-emitted (i.e. if poll_frame has not yet been
        called on a non-empty body). For tests."""
        if self._data_emitted:
            return 0
        return self._buf.__len__()

    @always_inline
    def data_emitted(self) -> Bool:
        """Whether the single Data frame has been consumed."""
        return self._data_emitted

    @always_inline
    def take_bytes(mut self) -> List[UInt8]:
        """Move the underlying body buffer OUT, leaving an empty `List`
        behind.

        OBJECTSTORE-READ: the previous consumer pattern
        (`bytes_ref()` + scalar `out.append(src[i])` per byte in
        `S3Store._copy_response_body`) copied the full body one byte at a
        time — a 298 MB scalar memcpy on the SF1 lineitem read. Since the
        buffered body is consumed exactly once by the S3 read path, hand
        the owned `List[UInt8]` over by move. Drop semantics are preserved:
        `_buf` is left in the empty state via `swap`, so `self`'s own
        destructor frees nothing twice.
        """
        var out = List[UInt8]()
        swap(self._buf, out)
        return out^

    @always_inline
    def bytes_ref(ref self) -> ref [self._buf] List[UInt8]:
        """Borrowed-ref accessor on the underlying buffer.
        Used by ObjectStoreHttp.get_ranges_into for scatter-write
        memcpy into a caller-supplied dst Span. The buffer is only
        live before `poll_frame` has consumed it; bytes_remaining()
        > 0 implies the buffer still holds the body bytes.

        Origin spec: `ref [self._buf] List[UInt8]` — typed-origin
        through the field chain per the Mojo 1.0.0b1 capability
        matrix (Repro 5/5b)."""
        return self._buf


# =============================================================================
# §3 — RecvRingBody — the zero-buffered streaming conformer.
# =============================================================================
#
# RecvRingBody is the default ResponseBody conformer. Unlike
# BufferedResponseBody (which holds the entire body slurped at
# construction), RecvRingBody holds:
#   * the IoStream conformer over the wire (parametric `[S: IoStream]`),
#   * a bounded recv-buf scratch area (List[UInt8], default 64 KiB —
#     matches `PoolSizingKnobs.defaults().recv_ring_size`),
#   * a per-chunk decoded-output staging buffer,
#   * the chunked decoder state (if Transfer-Encoding: chunked) or a
#     content-length cursor (if Content-Length: N),
#   * any trailing-HEADERS HeaderMap parsed from the chunked decoder's
#     trailer-part.
#
# poll_frame's contract:
#   * On first poll, drains any "pre-body" bytes that the head-parse left
#     past `_headers_end_off` into the chunked decoder / CL cursor,
#     then proceeds to read more bytes from the wire if needed.
#   * Returns BodyFrame.data(chunk) on each successful chunk read,
#     where `chunk` is an owned `List[UInt8]` carrying body bytes
#     accumulated since the prior poll_frame call. By design,
#     the chunk is OWNED bytes copied from recv-ring scratch — the
#     zero-copy ByteView-in-Data shape is the+ escape hatch.
#   * Returns BodyFrame.trailers(hdrs) AFTER the body is fully drained
#     AND the chunked decoder reports DONE with non-empty trailers
#     parsed from trailer-part. For CL-framed responses or chunked
#     responses without trailers, this frame is SKIPPED.
#   * Returns BodyFrame.end() once all body bytes (+ optional trailers)
#     have been emitted. End is idempotent on subsequent calls.
#   * Returns BodyFrame.pending() when stream.try_read returns Pending
#     and no bytes are buffered for emission. Caller parks on the
#     reactor and re-polls.
#   * Returns BodyFrame.error(detail) on hard I/O / framing failures.
#
# Cancellation: at the START of every poll_frame call, RecvRingBody
# checks `token.is_cancelled()`. If True, returns
# BodyFrame.error("CANCELLED"). This honors sketch's
# cancellation discipline.
#
# Trailers handling (RFC 7230 §4.1.2 + RFC 9110): for v1 the
# chunked decoder ignores trailers (parses-and-discards). The Trailers
# variant is RESERVED for an+ enhancement that surfaces parsed
# trailing HEADERS (e.g. S3 x-amz-checksum-*); for, poll_frame
# transitions Data -> End directly. The BodyFrame.trailers variant
# remains in the trait/type surface for forward compatibility.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * ZERO unsafe_from_address.
#   * Internal fields are owned (List[UInt8], ChunkedDecoder POD, Int
#     cursors, Bool flags, HeaderMap). The IoStream conformer `_stream`
#     is owned by-value (Movable) — RecvRingBody takes ownership at
#     construction.
# =============================================================================

comptime _RECV_RING_DEFAULT_SCRATCH: Int = 64 * 1024
"""Default recv-ring scratch size (bytes). Matches
PoolSizingKnobs.defaults().recv_ring_size. The scratch is used for
in-flight wire bytes that have not yet been decoded; the decoder
drains them into per-poll owned chunks."""

comptime _RECV_RING_DEFAULT_MAX_BODY: Int = 100 * 1024 * 1024
"""Default cap on total decoded body bytes — 100 MiB. Same default as
the OutboundDriver."""


comptime _BODY_FRAMING_CHUNKED: UInt8 = 0
"""Body is Transfer-Encoding: chunked — decode via ChunkedDecoder."""

comptime _BODY_FRAMING_CONTENT_LENGTH: UInt8 = 1
"""Body is Content-Length: N framed — consume up to N bytes."""

comptime _BODY_FRAMING_EMPTY: UInt8 = 2
"""Body is known empty (HEAD response, 204, 304, Content-Length: 0)."""

comptime _BODY_FRAMING_READ_UNTIL_EOF: UInt8 = 3
"""Body has no CL and no chunked TE — RFC 7230 §3.3.3 rule 7 read-
until-peer-close. For we treat this as a hard error if the
peer closes mid-body; was conservative about this too."""

comptime _BODY_FRAMING_PREBUFFERED: UInt8 = 4
"""The body bytes are
ALREADY fully materialized (no wire stream attached). Used when an h2
multiplex codec has driven a stream to END_STREAM and produced the whole
response body as one List[UInt8] — the gRPC drain layer still wants a
RecvRingBody it can `poll_frame`, so we wrap the buffered bytes in a
stream-less RecvRingBody. `poll_frame` emits the seeded `_accum` as ONE
Data frame, then End — it NEVER issues a wire read (there is no stream),
so the conn stays pooled for the next multiplexed RPC. This is the
read-direction analog of BufferedResponseBody, but typed as
RecvRingBody[S] so it slots into the streaming ClientResponse[RecvRingBody]
shape that HttpClient.send returns."""

# spin-then-park budgets for the body-drain
# helpers (collect_body single-body, drain_bodies_round_robin K-body). A small
# budget of consecutive no-progress (all-Pending) passes before parking on the
# in-flight fd(s) via the reactor's epoll. See the Reactor.park_on_fds header
# for the lost-wakeup-safety argument. Kept small so fast-local I/O (resolves
# in µs within the budget) never parks — that path is byte-for-byte unchanged.
comptime _COLLECT_BODY_SPIN_BUDGET: Int = 4
comptime _COLLECT_BODY_PARK_TIMEOUT_US: Int32 = 50_000
comptime _DRAIN_RR_SPIN_BUDGET: Int = 4
comptime _DRAIN_RR_PARK_TIMEOUT_US: Int32 = 50_000


comptime _UNSTAMPED_DRAIN_BACKSTOP_US: Int = (
    8 * Int(_COLLECT_BODY_PARK_TIMEOUT_US)
)
"""The wall-clock bound
the slurp helpers apply to a body carrying NO stamped deadline. 400 ms.

WHAT IT REPLACED, AND WHY THE REPLACEMENT IS THE WHOLE POINT. Both helpers
used to stop on `max_iter = 1_000_000` (`* k` in the round-robin, i.e.
LOOSER the more streams were in flight). AN ITERATION COUNT IS NOT A BOUND
IN TIME: on the scripted fixture (fd -1, a park returns immediately) one
million polls is ~18 s, and on a real socket where each park costs its full
`_COLLECT_BODY_PARK_TIMEOUT_US` it is `(1_000_000 / 4) * 50 ms` ~ 12,500 s
~ 3.5 HOURS -- the same constant, four orders of magnitude apart, decided by
the peer. It also fires the wrong way round: a legitimate LARGE download over
a slow peer reaches a million polls in seconds of real work and is killed
with a message that says TIMEOUT while having measured no time.

WHY THIS VALUE. The unit is the drain loop's OWN park slice -- the resolution
at which it notices anything -- and the multiple is eight. Measured across
every `collect_body` call in the `komira_http` suite, the
slowest drain of an UNSTAMPED body is ONE park slice (49 ms:
`test_recv_ring_body`, a fixture that goes Pending long enough to park once);
every other unstamped drain in the tree is under 3.5 ms. Eight slices is 8x
the measured worst case.

⛔ AND IT IS A BUG DETECTOR, NOT A SERVICE-LEVEL TIMEOUT. Read `_NO_DEADLINE`
below: a body over a LIVE stream is built by the `OutboundDriver`, and the
driver always stamps. The only unstamped shapes that exist are hand-built
test bodies and the stream-less PREBUFFERED h2 body, which performs no wire
wait at all and costs microseconds. So an unstamped body still waiting after
400 ms means its CONSTRUCTION SITE FORGOT TO STAMP, and the raise says so by
name. Unbounded, that failure is a 3.5-hour silence; bounded, it is a loud error
in 400 ms, which is the direction a timeout mechanism must degrade in."""


comptime _NO_DEADLINE: Int = 0
"""The
`_deadline_us` value meaning "no deadline was ever stamped on this body".

UNSTAMPED MEANS "NOBODY ENFORCES THIS BODY'S OWN DEADLINE, BECAUSE IT HAS
NONE" -- `poll_frame` returns from `_check_body_deadline` immediately. That is
still right: there is nothing to enforce. What it NO LONGER means is
UNBOUNDED. The slurp helpers carry `_UNSTAMPED_DRAIN_BACKSTOP_US` above, a
wall-clock bound on a drain whose body was never stamped, in place of an
iteration cap (which bounds nothing in time).

The sentinel is reachable at all only by HAND-CONSTRUCTED bodies (tests, and
the stream-less PREBUFFERED h2 shape, which performs no wire wait at all):
every body the OutboundDriver builds is stamped at its construction site, in
all three of `run`, `run_with_body` and `finish_into_response`, before it is
moved into the ClientResponse. A body that exists with a live `_stream` was
built by the driver, and the driver always has a deadline. THAT ARGUMENT IS
WHY THE BACKSTOP CAN BE TIGHT: it does not bound any real body, it catches a
construction site that forgot -- the class of defect this mechanism is
about -- and turns it from a 3.5-hour silence into a named error.

DO NOT MAKE THIS SENTINEL MEAN "USE A DEFAULT". The budget has exactly one
source of truth -- `OutboundDriver._effective_deadline_us`, itself already
clamped below the platform request ceiling by `outbound_budget.mojo`. A
second default here would be a second number to keep in sync, and the body
would stop inheriting the head's REMAINING time (see `set_deadline_us`)."""


comptime _BODY_DEADLINE_SATURATE_US: Int = (1 << 62)
"""Ceiling for a stamped absolute deadline. A caller passing an absurd budget
must read as "generous", never wrap `started_us + budget` into a PAST instant
and fail instantly -- the overflow case reqwest pins as
`big_timeout_duration_does_not_overflow`. 2^62 us is ~146,000 years; every
real deadline is far below it and is unaffected."""


struct RecvRingBody[S: IoStream](
    ResponseBody, Movable, Deinitable,
):
    """ResponseBody conformer — the recv-ring pull-stream
    streaming body. The default conformer; replaces
    BufferedResponseBody as the OutboundDriver's slurp-into-List
    construction.

    Parametric over the IoStream conformer `[S: IoStream]` — at
    HttpClient.send call sites this monomorphizes to the concrete
    stream type (TcpIoStream / TlsClientStream / ScriptedStream).

    Construction:
      * `RecvRingBody.new_chunked(stream, recv_scratch, ...)` — chunked
        framing.
      * `RecvRingBody.new_content_length(stream, recv_scratch, cl, ...)`
        — CL-N framing.
      * `RecvRingBody.new_empty(stream)` — known-empty body
        (HEAD/204/304/CL=0).
      * `RecvRingBody.new_read_until_eof(stream, recv_scratch, ...)` —
        no CL + no chunked.

    Each ctor accepts a `pre_body_bytes: List[UInt8]` argument that
    represents bytes ALREADY READ from the wire (the bytes the head
    parser left in the OutboundDriver's recv_buf past
    `_headers_end_off`). These are seeded into the appropriate decoder
    state before any new wire reads happen.

    State:
      _stream         — IoStream conformer over the connection. Owned.
      _framing        — _BODY_FRAMING_* sentinel discriminator.
      _decoder        — chunked decoder; only valid when framing=CHUNKED.
      _cl_total       — total CL bytes expected; only valid when
                        framing=CONTENT_LENGTH.
      _cl_received    — running count of bytes received against _cl_total.
      _accum          — accumulated decoded body bytes waiting for next
                        poll_frame. Each poll_frame returns this chunk
                        and resets it to empty.
      _max_body_bytes — cap on total decoded bytes; emits Error if
                        exceeded.
      _emitted_bytes  — total bytes already emitted in prior poll_frame
                        calls (NOT yet pulled from wire — that's
                        _cl_received).
      _done           — True iff body fully consumed and End/Trailers
                        already emitted. Subsequent polls return End.
      _eof_seen       — True iff stream.try_read returned Eof and we
                        have nothing left to decode. Drives the
                        "transition to Done" check.
      _scratch_size   — size of the per-read scratch buffer; defaults
                        to 64 KiB.
      _trailers       — parsed trailers from chunked decoder (trailers
                        reserved for a later surface).
      _trailers_emitted — flag: whether the Trailers frame has been
                          returned.

    Movable, NOT Copyable — owns _stream + internal buffers.
    """

    # `_stream` is
    # wrapped in Optional so `take_stream()` can move it out after the
    # body has been fully consumed (enabling h1 keepalive-reuse cache
    # on HttpClient). Optional<Movable> is the canonical move-out
    # primitive in Mojo 1.0.0b1 (the pointer rules preferred
    # replacement for partial-move-via-take_pointee).
    var _stream: Optional[Self.S]
    var _framing: UInt8
    var _decoder: ChunkedDecoder
    var _cl_total: Int
    var _cl_received: Int
    var _accum: List[UInt8]
    var _max_body_bytes: Int
    var _emitted_bytes: Int
    var _done: Bool
    var _eof_seen: Bool
    var _scratch_size: Int
    var _trailers: HeaderMap
    var _trailers_emitted: Bool

    # THE BODY'S OWN ABSOLUTE WALL-CLOCK DEADLINE (microseconds, same
    # monotonic epoch as `komira_clock.now_ns`), or `_NO_DEADLINE`.
    #
    # WARNING: IT RIDES THE BODY, NOT THE CALL SITE, AND THAT IS THE WHOLE
    # DESIGN. `collect_body` deliberately does NOT take a deadline parameter.
    # The drain has THREE consumers -- `collect_body`,
    # `drain_bodies_round_robin` (the parquet K-stream path, which calls
    # `collect_body` never), and any caller driving `poll_frame` directly --
    # and a deadline expressed as a parameter has to be remembered at every
    # one of them, and a forgotten one leaves the drain unbounded: a
    # `CancellationToken.never()` bounds nothing. The result is a
    # multi-minute stall, with requests ending only at the hosting
    # platform's own request ceiling.
    #
    # Stamping the OBJECT makes it structurally unforgettable: a
    # `RecvRingBody` carrying a live stream was built by the OutboundDriver,
    # and the driver always has a deadline. A drain loop written tomorrow
    # inherits the bound without knowing it exists.
    #
    # This is reqwest's `self.total_timeout.take()` in our idiom -- the
    # already-armed deadline MOVED across the head/body boundary with the
    # body, never recomputed after it. See `set_deadline_us`.
    var _deadline_us: Int

    # ⛔ THE CHUNKED DECODER HAS NO BUFFER OF ITS OWN — THIS IS IT.
    # `decode_block` is INCREMENTAL and states its caller
    # NEED_MORE the caller "should call again with more bytes appended to
    # `src`". Its entire state is (state, current_chunk_remaining,
    # bytes_emitted, err) — there is nowhere for a PARTIAL framing token to
    # live inside it. So every byte it declines must be re-presented by us,
    # or it is gone.
    #
    # Driving the decoder over a FRESH per-poll
    # scratch and discarding the result is wrong: a `try_read` ending inside a framing
    # token — a chunk-size line, the CRLF after chunk data, a trailer line —
    # would drop that partial token; the decoder resumed mid-token, mis-framed,
    # never reached the 0-length chunk, and on the peer's close reported
    # "EOF_MID_RESPONSE: chunked body unterminated" over a response that was
    # well-formed on the wire. A boundary inside chunk DATA is always safe
    # (CHUNK_DATA consumes everything available), which is why a chunked
    # test split only at a CHUNK boundary misses it.
    #
    # ⚠ BOUNDED BY CONSTRUCTION, so this is not a new DoS surface: the only
    # states that decline bytes are CHUNK_SIZE (capped at
    # DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES before decode_block errors),
    # CHUNK_DATA_CRLF (at most 1 byte), and TRAILER (capped at
    # limits.max_total_header_bytes). CHUNK_DATA consumes everything it is
    # given, so a large body never accumulates here.
    var _carry: List[UInt8]

    # ⛔ THE BYTES THAT ARE NOT OURS. Whatever arrived in the same read as
    # the end of THIS message and lies PAST its terminator -- the next
    # response on a connection the peer or an intermediary put on the wire
    # ahead of our drain.
    #
    # A body reader does not choose where a read boundary falls; the kernel
    # (or s2n) does. `_carry` holds bytes the DECODER declined and we must
    # re-present; `_leftover` holds bytes the decoder correctly refused
    # because the message was over, and they must go back to the CONNECTION
    # (`take_stream` -> `IoStream.unread`). Dropping either loses bytes.
    #
    # ⚠ A LOSS HERE DOES NOT FAIL WHERE IT HAPPENS. `client.mojo` reclaims the stream
    # into the h1 keepalive cache the moment `collect_body` returns
    # (the `send` paths); the loss would surface on the NEXT request over that
    # cached connection as a truncated status line, charged to a peer that
    # sent correct bytes — a framing error attributed to the wrong party. That
    # is why h11
    # asserts the leftover on EVERY body-reader case (`t_body_reader`) and
    # hyper's `Decoder::decode` returns the unconsumed tail to the
    # connection rather than swallowing it.
    #
    # Bounded: at most one over-delivered read (the scratch size).
    var _leftover: List[UInt8]

    def __init__(out self, var stream: Self.S):
        """Default-construct an empty-body RecvRingBody bound to a
        stream. Use the factory ctors for typed construction."""
        self._stream = Optional[Self.S](stream^)
        self._framing = _BODY_FRAMING_EMPTY
        self._decoder = ChunkedDecoder.init()
        self._cl_total = 0
        self._cl_received = 0
        self._accum = List[UInt8]()
        self._max_body_bytes = _RECV_RING_DEFAULT_MAX_BODY
        self._emitted_bytes = 0
        self._done = False
        self._eof_seen = False
        self._scratch_size = _RECV_RING_DEFAULT_SCRATCH
        self._trailers = HeaderMap()
        self._trailers_emitted = False
        self._carry = List[UInt8]()
        self._leftover = List[UInt8]()
        self._deadline_us = _NO_DEADLINE

    @staticmethod
    def new_empty(var stream: Self.S) -> RecvRingBody[Self.S]:
        """Body known to be empty (HEAD response, 204, 304,
        Content-Length: 0). First poll yields End directly.

        ⚠ PREFER THE TWO-ARGUMENT FORM FROM ANY SITE THAT PARSED A HEAD.
        This one asserts there is nothing buffered past the header
        terminator, which is true only when the caller can see that there
        is not. See the overload below."""
        return RecvRingBody[Self.S](stream^)

    @staticmethod
    def new_empty(
        var stream: Self.S, var pre_body_bytes: List[UInt8],
    ) -> RecvRingBody[Self.S]:
        """Body known to be empty, WITH the bytes the head parse read past
        the header terminator.

        ⛔ FOR AN EMPTY-BODY RESPONSE THOSE BYTES ARE 100% SOMEBODY ELSE'S,
        AND THAT IS EXACTLY WHY THE ARM LOST THEM. Every other framing gets
        `pre_body_bytes` because part of it is body; this arm has no body,
        so the parameter looked like it had no purpose and the three
        `state_machine.mojo` call sites simply dropped the value on the
        floor. But a 204 / 304 / HEAD / CL=0 response is 25-60 bytes against
        a 4 KiB head read: it is the framing MOST likely to pull the next
        response in with it, not least, and the h1 keepalive cache reclaims
        the connection between the two. The loss lands on the very next
        request the client itself makes -- no pipelining peer required.

        The bytes go straight to `_leftover`; `take_stream` returns them to
        the connection via `IoStream.unread`."""
        var rb = RecvRingBody[Self.S](stream^)
        rb._leftover = pre_body_bytes^
        return rb^

    @staticmethod
    def new_content_length(
        var stream: Self.S,
        cl_total: Int,
        var pre_body_bytes: List[UInt8],
        max_body_bytes: Int,
    ) -> RecvRingBody[Self.S]:
        """Body is Content-Length-framed. `pre_body_bytes` is the
        already-buffered prefix from the head parse.

        `max_body_bytes` is the caller's cap
        (`HttpClientConfig.max_response_body_bytes` at every
        `state_machine.mojo` site), REQUIRED like `new_chunked`'s and
        `new_read_until_eof`'s: a defaulted cap is how this constructor
        silently kept the 100 MiB default for every Content-Length body.
        A declared length over the cap fails the first `poll_frame` with
        BODY_TOO_LARGE before any byte is delivered (see `poll_frame`)."""
        var rb = RecvRingBody[Self.S](stream^)
        rb._framing = _BODY_FRAMING_CONTENT_LENGTH
        rb._cl_total = cl_total
        rb._max_body_bytes = max_body_bytes
        # Seed any pre-body bytes into the accum (capped by cl_total).
        var n_pre = pre_body_bytes.__len__()
        if n_pre > 0:
            var to_take = n_pre
            if to_take > cl_total:
                to_take = cl_total
            var i = 0
            while i < to_take:
                rb._accum.append(pre_body_bytes[i])
                i = i + 1
            rb._cl_received = to_take
            # ⚠ THE HEAD PARSER'S READ BOUNDARY IS AS ARBITRARY AS OURS.
            # `pre_body_bytes` is whatever one 64 KiB head read left past
            # the header terminator, so for any response shorter than that
            # read it contains the WHOLE body and can contain the start of
            # the next one. The clamp above is right -- those bytes are not
            # this body's -- but the old code then let them fall off the
            # end of the function. They belong to the connection.
            var j = to_take
            while j < n_pre:
                rb._leftover.append(pre_body_bytes[j])
                j = j + 1
        return rb^

    @staticmethod
    def new_chunked(
        var stream: Self.S,
        var pre_body_bytes: List[UInt8],
        max_body_bytes: Int,
    ) -> RecvRingBody[Self.S]:
        """Body is Transfer-Encoding: chunked. `pre_body_bytes` is the
        already-buffered prefix from the head parse; runs through the
        chunked decoder immediately."""
        var rb = RecvRingBody[Self.S](stream^)
        rb._framing = _BODY_FRAMING_CHUNKED
        rb._max_body_bytes = max_body_bytes
        # Drive the chunked decoder over the pre-body bytes.
        #
        # ⚠ THIS SEAM IS AS ARBITRARY AS A BODY READ BOUNDARY, AND USED TO
        # LOSE BYTES THE SAME WAY. `pre_body_bytes` is whatever the HEAD
        # parse left in recv_buf past the header terminator — an offset set
        # by where the HEAD read happened to stop, which lands inside the
        # first chunk-size line just as readily as anywhere else. The old
        # form discarded `dec_res` and reasoned "there is no unread tail to
        # handle"; that is true of the STREAM and false of the DECODER,
        # which declines a partial framing token and keeps no copy of it.
        # `_drive_chunked` retains it in `_carry`.
        var n_pre = pre_body_bytes.__len__()
        if n_pre > 0:
            rb._drive_chunked(pre_body_bytes, n_pre)
        return rb^

    def __init__(out self, var prebuffered: List[UInt8], no_stream: Bool):
        """No-stream
        constructor for the PREBUFFERED shape. `no_stream` is a tag
        parameter that disambiguates this overload from `__init__(stream)`
        — it must always be True. `_stream` is left empty (Optional.None),
        the framing is PREBUFFERED, and `prebuffered` is seeded into
        `_accum` so the first poll_frame emits it as ONE Data frame."""
        _ = no_stream
        self._stream = Optional[Self.S]()
        self._framing = _BODY_FRAMING_PREBUFFERED
        self._decoder = ChunkedDecoder.init()
        self._cl_total = 0
        self._cl_received = 0
        self._accum = prebuffered^
        self._max_body_bytes = _RECV_RING_DEFAULT_MAX_BODY
        self._emitted_bytes = 0
        # Empty body → already done (first poll_frame yields End).
        self._done = self._accum.__len__() == 0
        self._eof_seen = False
        self._scratch_size = _RECV_RING_DEFAULT_SCRATCH
        self._trailers = HeaderMap()
        self._trailers_emitted = False
        self._carry = List[UInt8]()
        self._leftover = List[UInt8]()
        self._deadline_us = _NO_DEADLINE

    @staticmethod
    def from_buffered_bytes(
        var body_bytes: List[UInt8],
    ) -> RecvRingBody[Self.S]:
        """Build a
        STREAM-LESS RecvRingBody pre-loaded with already-materialized body
        bytes. `poll_frame` emits these as ONE Data frame then End, and
        never touches the wire (there is no `_stream`).

        This is the bridge between the h2 multiplex codec (which drives a
        stream to END_STREAM and produces the whole response body as one
        List[UInt8] — see `extract_response_for_stream`) and the
        ResponseBody-trait drain layer that the gRPC client uses. The h2
        conn stays pooled (its stream is owned by the H2ClientPool, NOT
        moved into this body), so N concurrent gRPC RPCs can multiplex on
        ONE conn while each still yields a streaming ClientResponse.

        Encapsulation: `_stream = None`; no UnsafePointer, no wildcard
        origin, no unsafe_from_address. The seeded bytes are owned
        (consumed by move). Behaviorally identical to
        `BufferedResponseBody.from_bytes` for the poll_frame sequence
        (one Data + End for non-empty; End-only for empty) — this is the
        A/B-safety guarantee for buffered gRPC callers."""
        return RecvRingBody[Self.S](body_bytes^, no_stream=True)

    @staticmethod
    def new_read_until_eof(
        var stream: Self.S,
        var pre_body_bytes: List[UInt8],
        max_body_bytes: Int,
    ) -> RecvRingBody[Self.S]:
        """Body has no CL and no chunked TE — RFC 7230 §3.3.3 rule 7.
        Read all bytes until peer-close."""
        var rb = RecvRingBody[Self.S](stream^)
        rb._framing = _BODY_FRAMING_READ_UNTIL_EOF
        rb._max_body_bytes = max_body_bytes
        # Seed any pre-body bytes into the accum.
        var n_pre = pre_body_bytes.__len__()
        var i = 0
        while i < n_pre:
            rb._accum.append(pre_body_bytes[i])
            i = i + 1
        return rb^

    def set_max_body_bytes(mut self, n: Int):
        """Override the default 100 MiB body cap. Used by tests."""
        self._max_body_bytes = n

    def set_scratch_size(mut self, n: Int):
        """Override the default 64 KiB scratch size. Used by tests."""
        self._scratch_size = n

    def set_deadline_us(mut self, us: Int):
        """Stamp this body's
        ABSOLUTE wall-clock deadline (microseconds on `komira_clock`'s
        monotonic epoch). Called by `OutboundDriver` at every site that
        constructs a body over a live stream; `poll_frame` enforces it.

        POD `Int` in, POD `Int` out -- no pointer, no origin, nothing crosses
        the module boundary but a number.

        IT ONLY EVER TIGHTENS. This is Go's deference rule
        (`Client.setRequestCancel`, client.go:366-369, which returns
        `nop, alwaysFalse` when the caller's context deadline is already the
        tighter one): a client's budget may TIGHTEN a caller's deadline and
        may never LOOSEN it. A second stamp that is later than the one
        already held is DROPPED, so a layer added above this one cannot
        silently widen the bound a layer below it already committed to.

        `us <= 0` is a no-op (it is `_NO_DEADLINE`, i.e. "nothing to arm"),
        which is what lets an unconfigured driver stamp unconditionally.
        Values are saturated at `_BODY_DEADLINE_SATURATE_US` so an absurd
        budget reads as "generous" instead of wrapping into the past."""
        if us <= 0:
            return
        var v = us
        if v > _BODY_DEADLINE_SATURATE_US:
            v = _BODY_DEADLINE_SATURATE_US
        if self._deadline_us == _NO_DEADLINE:
            self._deadline_us = v
            return
        if v < self._deadline_us:
            self._deadline_us = v

    @always_inline
    def deadline_us(self) -> Int:
        """The absolute deadline stamped on this body, or `_NO_DEADLINE`
        (0) if none. Read by the drain loops ONLY to CLAMP THEIR PARK --
        never to enforce. There is exactly one enforcement site
        (`poll_frame`); two would be two sources of truth."""
        return self._deadline_us

    def remaining_deadline_us(self) -> Int:
        """Microseconds left before this body's deadline, or -1 when no
        deadline is stamped (meaning "unbounded -- use your full park").
        Returns 0 when the deadline has already passed.

        This exists so a drain loop's park cannot OVERSHOOT the deadline by
        up to a whole park slice: the park timeout is the RESOLUTION at
        which the deadline is noticed, it is not the bound."""
        if self._deadline_us == _NO_DEADLINE:
            return -1
        var now_us = Int(_system_now_ns() // UInt64(1000))
        var rem = self._deadline_us - now_us
        if rem < 0:
            return 0
        return rem

    # ----- The ResponseBody trait method -----------------------------------

    def poll_frame[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> BodyFrame:
        """Drive one chunk read from the wire + decode + emit.

        Algorithm:
          1. If cancellation requested: return error.
          2. If already Done: return End.
          3. If framing=EMPTY: mark Done, return End on next call.
          4. If we have decoded bytes buffered in _accum, AND either
             (a) the body is fully drained (transition to End/Trailers)
             OR (b) we are about to fall through to a read step where
             a Pending could lose us the buffered bytes:
             emit the accumulated chunk as Data and reset _accum.
          5. Otherwise: pull bytes from stream.try_read; on Ready, feed
             to decoder; on Pending, return Pending; on Eof, finalize.
          6. Repeat from (2).

        Returns:
          BodyFrame.data(chunk)  — accumulated decoded bytes.
          BodyFrame.pending()    — stream needs to park before more bytes.
          BodyFrame.end()        — body fully consumed.
          BodyFrame.error(d)     — hard failure.
          BodyFrame.trailers(h)  — RESERVED+ (currently never emitted).
        """
        # 1. Cancellation.
        #
        # LEAVE THE TOKEN ALONE. Cancellation and deadline are DIFFERENT
        # QUESTIONS and conflating them makes both worse.
        # `CancellationToken.never()` is the correct *cancellation* token at
        # the drain call sites -- nothing about it was ever a deadline, and
        # the fix for an unbounded drain is not to overload it.
        if token.is_cancelled():
            return BodyFrame.error(String("CANCELLED"))

        # THE DEADLINE IS EVALUATED HERE, BEFORE ANY STATE WORK, AND THE ONLY
        # THINGS IT IS GATED ON ARE STATES **WE** CONTROL.
        #
        # See `state_machine.mojo` (the head loop's `run` / `run_with_body`):
        # a deadline gated behind
        # `no_progress >= _HEAD_DRIVE_SPIN_BUDGET`, and every arriving byte
        # resets that counter -- so a peer dribbling one byte often enough keeps
        # the check UNREACHABLE forever and the request has no bound at all.
        # A deadline the peer can defeat by dribbling is not a deadline.
        #
        # WHY A DRIBBLER CANNOT DEFEAT THIS ONE. The predicate reads exactly
        # two pieces of state and the peer can steer NEITHER:
        #   * `_framing` is fixed at construction from the parsed response
        #     head and never changes afterwards.
        #   * `_done` becomes True only at End -- the body completed, so
        #     there is nothing left to bound.
        # There is NO COUNTER in the predicate. That is the entire difference
        # from the defect above. Every arm below either advances or does not;
        # none of them can suppress the check, because the check already ran.
        #
        # THE THREE EXEMPTIONS ARE PRINCIPLED, AND THE PRINCIPLE IS: exempt
        # only states the PEER cannot steer us into, and only where this call
        # performs NO WIRE WAIT AT ALL.
        #   * `_done`      -- End must stay idempotent; nothing is in flight.
        #   * EMPTY        -- HEAD/204/304/CL=0; returns End without touching
        #                     the stream.
        #   * PREBUFFERED  -- the GCS-gRPC-h2 Gap-A shape has no wire stream
        #                     at all; failing it would discard bytes already
        #                     in hand for zero benefit, since no wait can
        #                     occur.
        #
        # AND THE ONE THAT MUST *NOT* BE EXEMPT, WHICH IS WHERE THE TRAP
        # LIVES. The obvious fourth exemption -- `if self._accum.__len__() >
        # 0: return self._emit_accum()`, a few lines below -- is the one the
        # peer DOES control: a dribbler keeps `_accum` non-empty on every
        # poll. Exempting it recreates the defect byte-for-byte one layer
        # down. That is why this check sits ABOVE the accum emit, and why the
        # guard is a whitelist of OUR OWN states rather than "skip if we have
        # work to do".
        #
        # Falsifier: `tests/test_body_drain_deadline_survives_byte_dribble`.
        if (
            not self._done
            and self._framing != _BODY_FRAMING_EMPTY
            and self._framing != _BODY_FRAMING_PREBUFFERED
        ):
            self._check_body_deadline()

        # 2. Already Done.
        if self._done:
            return BodyFrame.end()

        # 3. Empty body fast path.
        if self._framing == _BODY_FRAMING_EMPTY:
            self._done = True
            return BodyFrame.end()

        # 3a. A Content-Length body declares its size up front: over the cap
        # it is refused before any byte is delivered. The per-read guard in
        # step 4 cannot see this case: a body shorter than one head read
        # arrives whole in `pre_body_bytes`, is seeded into `_accum`, and the
        # emit just below hands it over without reaching that guard.
        if (
            self._framing == _BODY_FRAMING_CONTENT_LENGTH
            and self._cl_total > self._max_body_bytes
        ):
            return BodyFrame.error(String("BODY_TOO_LARGE"))

        # If we already have accumulated bytes from a prior pre-body
        # seed or a prior read, emit them now as one Data frame.
        if self._accum.__len__() > 0:
            return self._emit_accum()

        # the PREBUFFERED shape has NO
        # wire stream. Once its seeded `_accum` is drained (emitted above),
        # the body is complete — transition to End WITHOUT touching the
        # (absent) stream. Guarding here is load-bearing: the wire-read
        # path below dereferences `self._stream.value()`, which would
        # panic for a stream-less body.
        if self._framing == _BODY_FRAMING_PREBUFFERED:
            self._done = True
            return BodyFrame.end()

        # ⛔ A DECODER IN _DECODE_STATE_ERROR MUST NOT REACH ANOTHER WIRE
        # READ. Discarding `decode_block`'s outcome would leave
        # CHUNKED_RES_ERROR parking the decoder in ERROR with nothing
        # reporting it — `is_done()` stays False, `_accum` is empty, and a
        # fall-through to `BodyFrame.pending()` makes `collect_body`
        # spin-and-park
        # (4 spins, 50ms park, up to 1_000_000 iterations)
        # against a decoder that can never make progress, until the peer
        # closes or the enclosing request wall fires. An EOF observable at
        # once would cost a multi-minute stall, and the error finally reported
        # would name TRUNCATION over what is really a PARSE failure.
        if self._framing == _BODY_FRAMING_CHUNKED and self._decoder.is_error():
            return BodyFrame.error(self._chunked_error_detail())

        # Check whether the framing has already exhausted itself before
        # we issue any read (a fully-buffered CL body might have been
        # seeded by pre_body_bytes covering all expected bytes).
        if self._body_is_done():
            self._done = True
            return BodyFrame.end()

        # 4. Pull one read from the wire into scratch.
        #
        # ⛔ NEVER ASK THE WIRE FOR MORE BYTES THAN THIS MESSAGE CAN OWN.
        # Under Content-Length the boundary is a NUMBER we already have, so
        # over-reading is not forced on us by the delivery shape -- it was
        # purely a too-big `dst`. This is Go's framing verbatim:
        # `transfer.go` wraps the connection in
        # `io.LimitReader(r, realLength)` and `io.LimitedReader.Read`
        # narrows every read to `p[0:l.N]`, so a CL body physically cannot
        # take the next response off the socket. Chunked has no such number
        # (the terminator is discovered, not known), which is why it needs
        # the `_leftover` + `unread` path instead.
        var want = self._scratch_size
        if self._framing == _BODY_FRAMING_CONTENT_LENGTH:
            var cl_left = self._cl_total - self._cl_received
            if cl_left < want:
                want = cl_left
        var scratch = List[UInt8]()
        var i = 0
        while i < want:
            scratch.append(UInt8(0))
            i = i + 1
        # _stream is Optional;
        # `.value()` returns a ref directly (NOT a Pointer — that's the
        # OwnedPointer pattern). `_stream` is guaranteed populated for
        # any poll_frame call (take_stream's precondition is `_done`,
        # which is checked at the top of poll_frame).
        var res = self._stream.value().try_read[RT](reactor, Span[UInt8](scratch))
        if res._state == STREAM_IO_PENDING:
            return BodyFrame.pending()
        if res._state == STREAM_IO_ERROR:
            return BodyFrame.error(
                String("IO_ERROR: errno=") + String(Int(res._payload))
            )
        if res._state == STREAM_IO_EOF:
            # Peer closed. Finalize per framing.
            self._eof_seen = True
            return self._finalize_on_eof()
        # READY: consume `n` bytes from scratch.
        var n = Int(res._payload)
        if n <= 0:
            # Spurious zero-byte ready; equivalent to Pending.
            return BodyFrame.pending()
        # Drive the framing decoder over scratch[:n].
        self._consume_scratch(scratch, n)
        # Surface a parse failure on the POLL THAT PRODUCED IT — not on the
        # next one, and not as an EOF three minutes later. Checked after the
        # decode so any bytes this same call did decode are still emitted
        # first (the `_accum` arms below), and before the done/pending arms
        # so an ERROR can never be reported as "no progress yet".
        if self._framing == _BODY_FRAMING_CHUNKED and self._decoder.is_error():
            if self._accum.__len__() > 0:
                return self._emit_accum()
            return BodyFrame.error(self._chunked_error_detail())
        # Cap on accum size (guards against runaway).
        if self._accum.__len__() > self._max_body_bytes - self._emitted_bytes:
            return BodyFrame.error(String("BODY_TOO_LARGE"))
        # If decoder finished, emit the final Data + queue End for next call.
        if self._framing == _BODY_FRAMING_CHUNKED and self._decoder.is_done():
            if self._accum.__len__() > 0:
                return self._emit_accum()
            self._done = True
            return BodyFrame.end()
        if self._framing == _BODY_FRAMING_CONTENT_LENGTH:
            if self._cl_received >= self._cl_total:
                if self._accum.__len__() > 0:
                    return self._emit_accum()
                self._done = True
                return BodyFrame.end()
        # Otherwise we have new bytes in accum — emit them.
        if self._accum.__len__() > 0:
            return self._emit_accum()
        # No bytes accumulated yet (e.g. chunked decoder consumed
        # framing bytes only). Tell caller to poll again.
        return BodyFrame.pending()

    # ----- Internal helpers ------------------------------------------------

    def _emit_accum(mut self) -> BodyFrame:
        """Transfer ownership of self._accum into a Data frame. Resets
        accum to empty for the next poll's accumulation."""
        var chunk = List[UInt8]()
        swap(chunk, self._accum)
        self._emitted_bytes = self._emitted_bytes + chunk.__len__()
        return BodyFrame.data(chunk^)

    def _check_body_deadline(mut self) raises:
        """Raise a typed TIMEOUT if this body's stamped wall-clock deadline
        has passed. Called UNCONDITIONALLY from `poll_frame` for every
        framing that can perform a wire wait -- independent of the accum, of
        the pending counters, of whether the peer is sending.

        WHY IT FAILS A PARTIALLY-DRAINED BODY, rather than transplanting the
        head loop's DONE/ERROR carve-out. That carve-out is argued from a
        specific fact -- "the head is already parsed by then, and failing a
        request whose response we are holding would trade a hang for data
        loss" -- and DONE/ERROR are states in which NOTHING IS IN FLIGHT, so
        skipping the check there costs nothing. The body has no such state:
        every mid-drain moment is partway through. A rule written for a state
        where waiting cannot occur, applied to a loop that is entirely
        waiting, becomes an exemption with no condition.

        And for the slurp helpers there is no data-loss tradeoff to weigh at
        all: `collect_body` / `drain_bodies_round_robin` either return a
        COMPLETE `List[UInt8]` or raise, so the accumulated prefix is never
        visible to the caller under any outcome. Go makes the same call --
        `TestClientTimeout`'s handler writes "Hello", flushes, then blocks,
        and the client's `io.ReadAll(res.Body)` is REQUIRED to fail; Envoy's
        `Filter::onResponseTimeout` resets in-flight upstream requests even
        when response headers were already seen.

        A caller driving `poll_frame` directly keeps every frame it has
        ALREADY been handed -- the timeout arrives as the NEXT frame's raise,
        never as a retraction. That is reqwest's fail-forward property, and
        we get it for free by putting the check here rather than in the
        loops.

        DELIBERATELY NOT COPIED: grpc-go appends its deadline error to the
        TAIL of the recv buffer (`transport.go:331-340`) so bytes already
        received are delivered and the call fails after. Here that would be
        "emit the accum first, then fail next poll" -- and `_accum` is a
        condition the PEER controls, so it is a one-poll extension a dribbler
        could renew forever. gRPC can afford it because its deadline fires in
        a `select` the peer cannot steer; ours fires in a predicate, and the
        predicate must stay peer-independent. We take the byte loss; it is at
        most one scratch read.

        THE MESSAGE IS DELIBERATELY DISTINCT FROM EVERY NEIGHBOURING
        TIMEOUT. It must be tellable apart, by an operator reading one log
        line, from (a) a connect timeout, (b) the head loop's "while driving
        the request" text, and (c) the iteration cap's
        `collect_body iteration cap exceeded` -- which says TIMEOUT while
        measuring no time and may be matched on by external log checks.
        So this one names the PHASE (`response
        body`), carries the BYTES DRAINED SO FAR (the single most useful
        number for telling "the peer never started" from "the peer started
        and stalled"), and states the deadline it was measured against."""
        if self._deadline_us == _NO_DEADLINE:
            return
        var now_us = Int(_system_now_ns() // UInt64(1000))
        if now_us < self._deadline_us:
            return
        var drained = self._emitted_bytes + self._accum.__len__()
        raise Error(
            String("HttpError[TIMEOUT]: response body deadline exceeded")
            + String(" after ")
            + String(drained)
            + String(" body bytes (deadline_us=")
            + String(self._deadline_us)
            + String(", now_us=")
            + String(now_us)
            + String(")")
        )

    def _consume_scratch(mut self, ref scratch: List[UInt8], n: Int):
        """Append the first `n` bytes of `scratch` into the appropriate
        framing decoder + emit decoded bytes into self._accum."""
        if self._framing == _BODY_FRAMING_CONTENT_LENGTH:
            # CL: copy at most (cl_total - cl_received) bytes.
            var remaining = self._cl_total - self._cl_received
            var to_take = n
            if remaining < to_take:
                to_take = remaining
            if to_take <= 0:
                return
            var k = 0
            while k < to_take:
                self._accum.append(scratch[k])
                k = k + 1
            self._cl_received = self._cl_received + to_take
            return
        if self._framing == _BODY_FRAMING_CHUNKED:
            self._drive_chunked(scratch, n)
            return
        if self._framing == _BODY_FRAMING_READ_UNTIL_EOF:
            var k = 0
            while k < n:
                self._accum.append(scratch[k])
                k = k + 1
            return
        # EMPTY framing should never get here (Done-fast-path catches it).

    def _drive_chunked(mut self, ref src: List[UInt8], n: Int):
        """Feed `src[:n]` to the chunked decoder, PREPENDING whatever the
        previous call declined to consume and RETAINING whatever this call
        declines. This is the caller half of `decode_block`'s documented
        contract ("consumed" = what it processed; re-present the rest), and
        it is the whole fix for —
        see the `_carry` field comment for what dropping the tail cost.

        Only NEED_MORE retains a tail. On DONE the remainder is not ours (a
        pipelined next response), and on ERROR the decoder is terminal and
        `poll_frame` surfaces it before anything else is read."""
        var merged = List[UInt8]()
        var c = 0
        var n_carry = self._carry.__len__()
        while c < n_carry:
            merged.append(self._carry[c])
            c = c + 1
        var k = 0
        while k < n:
            merged.append(src[k])
            k = k + 1
        var view = Span[UInt8](merged).as_imm()
        # ⛔ THE CEILING THE CALLER ASKED FOR IS THE CEILING THAT IS ENFORCED.
        # Passing `ParseLimits.defaults()` here — whose `max_body_bytes`
        # is a hardcoded 10 MiB — while `_max_body_bytes` holds the number the
        # caller actually configured would be a defect in BOTH directions:
        #
        #   * `HttpClientConfig.max_response_body_bytes` defaults to 100 MiB
        #     and is threaded to every `new_chunked` site in
        #     `state_machine.mojo`, so EVERY chunked response over 10 MiB would be
        #     rejected at the chunk-size line with no malformed byte on the
        #     wire, and a rejection left parked in _DECODE_STATE_ERROR
        #     (`is_done()` False,
        #     `poll_frame` returning Pending, `collect_body` spinning against
        #     it) is
        #     a multi-minute wall ending in a 504, reached purely because the
        #     response was big.
        #   * A caller asking for a ceiling BELOW 10 MiB would not get one at
        #     all: a chunk declaring 5 MiB under a 4 MiB ceiling would be admitted
        #     at the size line and partially delivered.
        var limits = ParseLimits.defaults()
        limits.max_body_bytes = self._max_body_bytes
        var res = decode_block(
            self._decoder,
            view,
            limits,
            self._accum,
        )
        var next_carry = List[UInt8]()
        if res.outcome == CHUNKED_RES_NEED_MORE:
            var j = res.consumed
            var total = merged.__len__()
            while j < total:
                next_carry.append(merged[j])
                j = j + 1
        elif res.outcome == CHUNKED_RES_DONE:
            # THE MESSAGE IS OVER AND THESE BYTES ARE PAST ITS TERMINATOR.
            # `decode_block` reports `consumed` through the final CRLF of
            # the trailer, so the remainder is EXACTLY the surplus -- the
            # decoder already told us where the boundary was and the old
            # code threw the answer away. Retained for `take_stream` to
            # hand back to the connection.
            var d = res.consumed
            var dtotal = merged.__len__()
            while d < dtotal:
                self._leftover.append(merged[d])
                d = d + 1
        self._carry = next_carry^

    def _chunked_error_detail(self) -> String:
        """The Error-frame detail for a decoder that has entered
        _DECODE_STATE_ERROR. Distinct from EOF_MID_RESPONSE on purpose: a
        malformed chunk-size line and a truncated stream are two different
        things to go look at, and the old code reported the first as the
        second (after a multi-minute wait).

        ⚠ AND "TOO LARGE" IS A THIRD THING, NOT A MALFORMED ONE. Once the
        caller's ceiling is threaded into the decoder's `ParseLimits`, an
        oversized body is caught at the CHUNK-SIZE LINE -- before its bytes
        are read, which is the point of checking there -- instead of by
        `poll_frame`'s accumulator guard afterwards. Both are the same
        verdict and must carry the same word: reporting a size violation as
        `MALFORMED_CHUNKED` is precisely the conflation the paragraph above
        exists to prevent, and it would send a reader looking for a bad byte
        on a wire that has none."""
        if self._decoder.err.kind == PARSE_ERR_BODY_TOO_LARGE:
            return String("BODY_TOO_LARGE")
        return (
            String("MALFORMED_CHUNKED: parse error kind=")
            + String(Int(self._decoder.err.kind))
            + String(" at offset=")
            + String(self._decoder.err.offset)
        )

    def _chunked_truncation_detail(self) -> String:
        """The Error-frame detail for a chunked body whose stream closed
        before the decoder reached the last chunk + trailer terminator.

        ⛔ THE POSITION IS THE POINT. Without it the whole report is:

            HttpError[EOF_MID_RESPONSE: chunked body unterminated]

        That sentence is EQUALLY TRUE of a
        wire cut at byte 0 and of one cut a single byte before the final
        CRLF, and those are not the same failure: the first is "the peer
        never answered", the second is "the peer answered in full and the
        connection died at the very end". Nothing in the line separates
        them, so nothing in the logs can rank them, and the defect reads as
        one undifferentiated smear.

        Four numbers close that, and every one is read from state that
        already exists here — this adds no field and no work on any path but
        the failing one:
          * `decoded`   — body bytes the decoder emitted. 0 vs. non-zero is
                          "never started" vs. "died partway".
          * `chunk_remaining` — bytes still owed on the chunk in flight.
                          Non-zero pins the cut INSIDE chunk data.
          * `undecodable_carry` — bytes held back because they are a PARTIAL
                          framing token (see the `_carry` field). Non-zero
                          means the cut landed inside a size line, a data
                          CRLF or a trailer line.
          * `emitted`   — bytes already handed to the caller, so a reader can
                          tell a short body from an empty one.

        `state` is the raw `_DECODE_STATE_*` ordinal from
        `komira_http_core/codec/h1/chunked.mojo` §1. It is a number because those
        constants are module-private there; rendering it as a NAME wants a
        `state_name()` on `ChunkedDecoder`, which is that module's change to
        make. The four named numbers above are self-describing and are what
        actually separate the failures.

        ⚠ The leading sentence is UNCHANGED and stays the prefix, on purpose:
        every existing assertion matches on it (`startswith`/`find`), and the
        operators' log searches use it."""
        return (
            String("EOF_MID_RESPONSE: chunked body unterminated")
            + String(" (state=")
            + String(Int(self._decoder.state))
            + String(" decoded=")
            + String(self._decoder.bytes_emitted)
            + String(" chunk_remaining=")
            + String(self._decoder.current_chunk_remaining)
            + String(" undecodable_carry=")
            + String(self._carry.__len__())
            + String(" emitted=")
            + String(self._emitted_bytes)
            + String(")")
        )

    def _body_is_done(self) -> Bool:
        """Whether the framing decoder reports body fully received."""
        if self._framing == _BODY_FRAMING_EMPTY:
            return True
        if self._framing == _BODY_FRAMING_PREBUFFERED:
            # No wire stream; "done" once the seeded accum has been
            # emitted (the poll_frame accum-emit + the PREBUFFERED guard
            # above handle the transition).
            return self._accum.__len__() == 0
        if self._framing == _BODY_FRAMING_CONTENT_LENGTH:
            return self._cl_received >= self._cl_total
        if self._framing == _BODY_FRAMING_CHUNKED:
            return self._decoder.is_done()
        # READ_UNTIL_EOF: done only when EOF actually arrives.
        return False

    def _finalize_on_eof(mut self) -> BodyFrame:
        """Stream closed. Decide End vs Error per framing."""
        # Anything still in accum gets emitted before End.
        if self._accum.__len__() > 0:
            # Keep _done=False; the next poll will see body_is_done()
            # depending on framing.
            return self._emit_accum()
        if self._framing == _BODY_FRAMING_READ_UNTIL_EOF:
            self._done = True
            return BodyFrame.end()
        if self._framing == _BODY_FRAMING_CONTENT_LENGTH:
            if self._cl_received >= self._cl_total:
                self._done = True
                return BodyFrame.end()
            return BodyFrame.error(
                String("EOF_MID_RESPONSE: short body — CL=")
                + String(self._cl_total)
                + String(" got=")
                + String(self._cl_received)
            )
        if self._framing == _BODY_FRAMING_CHUNKED:
            if self._decoder.is_done():
                self._done = True
                return BodyFrame.end()
            return BodyFrame.error(self._chunked_truncation_detail())
        # EMPTY framing — End.
        self._done = True
        return BodyFrame.end()

    # -----: stream extraction ----
    #
    # `take_stream` moves the underlying IoStream out of the RecvRingBody
    # so the caller can cache it for h1 keepalive-reuse. The caller MUST
    # have driven poll_frame to End (or used `collect_body` which does
    # so) before calling; the precondition check raises if violated.
    # Optional<Movable> + .take() is the canonical move-out primitive in
    # Mojo 1.0.0b1.

    def take_stream(mut self) raises -> Self.S:
        """Extract the underlying IoStream after the body has been
        fully consumed. The caller takes ownership of the stream and
        may close it (drop) OR cache it for keepalive reuse.

        Precondition: `self._done == True` (poll_frame drove to End,
        or `collect_body` ran). Raises if violated.

        Postcondition: self._stream is `None`; subsequent poll_frame
        calls will fail (the value-deref panics). The expected usage
        is: drive collect_body → take_stream → drop self.

        THIS PRECONDITION IS ALSO THE POOLING GUARD, AND IT IS LOAD-BEARING
        FOR CORRECTNESS, NOT TIDINESS. An HTTP/1.1 connection whose body
        drain was ABANDONED -- by the new response-body deadline, by a
        cancellation, by any raise out of the drain -- sits at an UNKNOWN
        BYTE OFFSET. Returning it to the keepalive cache makes the NEXT
        request on it parse the previous response's leftover body bytes as
        its own status line: one slow request converted into silent
        cross-request corruption for every subsequent user of that
        connection. That is strictly worse than the hang it replaced.

        `_done` is False for every abandoned drain, so this raise is what
        makes the bad reuse unreachable -- the same guarantee Go gets
        structurally from `alive = alive && bodyEOF && ...` in
        `tryPutIdleConn` (transport.go), where the `&&` short-circuits and
        the readLoop's `defer pc.close()` destroys the socket. reqwest pins
        it separately as `timeout_closes_connection`; ours is pinned by
        `test_body_drain_deadline_survives_byte_dribble`'s
        `..._timed_out_body_refuses_to_surrender_its_stream`.
        """
        if not self._done:
            raise Error(
                "RecvRingBody.take_stream: body not fully consumed"
                " (call collect_body or drive poll_frame to End first)"
            )
        if not self._stream.__bool__():
            raise Error(
                "RecvRingBody.take_stream: stream already taken"
            )
        # ⛔ HAND THE SURPLUS BACK BEFORE HANDING THE CONNECTION BACK. This
        # is the ONLY moment at which it can be done: after this line the
        # body no longer owns the stream, and the keepalive cache stores a
        # STREAM, not a (stream, leftover) pair -- so a surplus still held
        # here when the move happens is a surplus that is gone. Doing it
        # here rather than at the moment of detection also means a body
        # whose stream is DROPPED (no reuse) pays nothing: the bytes die
        # with the connection they belonged to, which is correct.
        #
        # It runs BEFORE the move and can raise (`IoStream.unread`'s default
        # body does, for a conformer with no pushback buffer). That raise is
        # the fail-CLOSED direction and matches the `_done` precondition
        # above: the caller does not get a stream it would cache while the
        # next response's first bytes are missing from it. `client.mojo`'s
        # reclaim sites already treat a raising `take_stream` as "drop the
        # connection".
        if self._leftover.__len__() > 0:
            var surplus = List[UInt8]()
            swap(surplus, self._leftover)
            self._stream.value().unread(Span[UInt8](surplus).as_imm())
        return self._stream.take()

    def has_stream(self) -> Bool:
        """Whether the underlying stream is still owned by this body
        (vs. having been take_stream'd out). Used as a defensive check
        by HttpClient's keepalive-cache logic."""
        return self._stream.__bool__()

    def stream_fd(self) -> Int32:
        """The underlying socket fd of the
        body's stream, for transient registration with the reactor during
        a parked round-robin drain. Returns -1 if the stream has been
        taken (keepalive reclaim) or the conformer has no pollable kernel
        fd (e.g. ScriptedStream). POD return — no pointer crosses the
        module boundary (IoStream.fd() is a POD Int32 accessor)."""
        if not self._stream.__bool__():
            return Int32(-1)
        return self._stream.value().fd()

    def stream_has_buffered_readable(self) -> Bool:
        """TLS-BUFFERED-PLAINTEXT LOST-WAKEUP GUARD: True
        iff the underlying stream holds decrypted plaintext that the next
        try_read would return WITHOUT touching the socket fd. For a TLS
        conformer this is `s2n_peek(conn) > 0` — s2n decrypts in ~16KB
        TLS-RECORD units while the body drain reads in 4096-byte chunks, so
        one decrypt can drain a whole record off the socket and leave the
        remainder buffered inside s2n, invisible to a park on socket
        fd-readiness. The body-drain loops check this BEFORE parking on a
        Pending and re-poll instead of parking on a fd that will never
        wake. Default-False for kernel-socket conformers (TcpIoStream),
        so this is a no-op on the plaintext path.

        Returns False if the stream has been taken (keepalive reclaim).
        POD return — no pointer crosses the module boundary
        (IoStream.has_buffered_readable() is a POD Bool accessor; the
        s2n_peek FFI is confined to s2n_shim). Why: TLS can hold decrypted
        bytes that socket readiness cannot see."""
        if not self._stream.__bool__():
            return False
        return self._stream.value().has_buffered_readable()

    # ----- Read-only accessors --------------------------------------------

    @always_inline
    def is_done(self) -> Bool:
        """Whether poll_frame has finalized to End."""
        return self._done

    @always_inline
    def framing(self) -> UInt8:
        """The framing sentinel discriminator."""
        return self._framing

    @always_inline
    def emitted_bytes(self) -> Int:
        """Total bytes emitted in prior Data frames."""
        return self._emitted_bytes


# =============================================================================
# §4 — collect_body helper — explicit-slurp convenience for RecvRingBody.
# =============================================================================
#
# RecvRingBody is the default conformer, and this helper
# preserves the "give me the whole body as a List" affordance:
# it drives poll_frame to completion and concatenates all
# Data chunks. Existing tests / consumers that want the slurp shape can
# use `var body_bytes = collect_body[RT, S](resp.body, reactor, token)`.
#
# This is NOT an additive parallel API — RecvRingBody is the primary
# conformer; this is a one-line convenience that runs the public
# poll_frame loop. The "explicit-slurp" callers
# use this; the BufferedResponseBody conformer remains
# available for callers that explicitly want the slurp-AT-driver-time
# shape (e.g. tests).


def _clamped_park_us(park_us: Int32, remaining_us: Int) -> Int32:
    """Clamp a drain loop's park slice so it cannot OUTLIVE the deadline the
    body already carries.

    `remaining_us < 0` means the body carries no deadline -- use the full
    slice (byte-for-byte the prior behaviour). Otherwise take the smaller of
    the two, with a floor of 1 us so a park is never asked to block forever
    (`park_on_fds` treats a negative timeout as "block indefinitely", which
    is exactly the wrong answer when the deadline has just passed).

    THE PARK TIMEOUT IS THE *RESOLUTION* AT WHICH THE DEADLINE IS NOTICED;
    IT IS NOT THE BOUND. Without this clamp the last park overshoots by up to
    a whole 50 ms slice. The bound itself is enforced in exactly one place --
    `RecvRingBody.poll_frame` -- and these loops never enforce it; two
    enforcement sites would be two sources of truth."""
    if remaining_us < 0:
        return park_us
    if remaining_us <= 0:
        return Int32(1)
    if Int(park_us) <= remaining_us:
        return park_us
    return Int32(remaining_us)


def collect_body[RT: Runtime, S: IoStream](
    mut body: RecvRingBody[S],
    mut reactor: Reactor[RT.Sink],
    ref token: CancellationToken,
) raises -> List[UInt8]:
    """Drive `body.poll_frame` to completion, concatenating every Data
    frame into one owned List[UInt8]. Treats Pending the same way the
    OutboundDriver's read loop does — re-issue immediately (synchronous;
    replaces with reactor.park).

    Returns the full body bytes on success; raises HttpError-shaped
    Error on Error frame or cancellation. Trailers are
    ignored by this helper -- use poll_frame directly if you need them.

    THE LOOP'S OWN RUNAWAY GUARD IS A CLOCK, NOT A POLL COUNT.
    It used to be `max_iter = 1_000_000`, which is not a bound in time --
    see `_UNSTAMPED_DRAIN_BACKSTOP_US`. A body that carries a stamped
    deadline needs no loop guard at all: `poll_frame` raises at that
    deadline, and every state `poll_frame` exempts from the check
    (done / EMPTY / PREBUFFERED) returns End or Data on the spot, so the
    loop cannot fail to terminate. A body that carries NONE is bounded by
    the backstop, which is the only case the old cap could ever have fired
    in without killing a legitimate slow download.

    THERE IS DELIBERATELY NO `deadline_us` PARAMETER, AND ADDING ONE WOULD
    BE A REGRESSION. The bound rides the BODY (`RecvRingBody._deadline_us`,
    stamped by the OutboundDriver at every construction site) and is
    enforced inside `poll_frame`. A parameter here would bound ONE of the
    three drain paths: `drain_bodies_round_robin` -- the parquet K-stream
    drain, the loosest bound in the tree -- calls this helper NEVER, and a
    streaming caller drives `poll_frame` directly. Expressing the fix as
    "add an argument at the call sites" would have re-created the
    drop-at-the-boundary bug one layer up.

    Caller pattern:
        var bytes = collect_body[PerCoreAsyncRuntime[NoopSink],
                                  ScriptedStream](
            resp.body, reactor, token,
        )
    """
    var out = List[UInt8]()
    # read the stamp ONCE. Nothing
    # stamps a body mid-drain (`set_deadline_us` is called at construction),
    # so a stamped body pays no clock read here -- `poll_frame` is already
    # reading the clock on its behalf, and a second reader would be a second
    # source of truth.
    var unstamped = body.deadline_us() == _NO_DEADLINE
    var backstop_us = 0
    if unstamped:
        backstop_us = (
            Int(_system_now_ns() // UInt64(1000)) + _UNSTAMPED_DRAIN_BACKSTOP_US
        )
    # consecutive-Pending counter. A single-body
    # drain that keeps returning Pending is busy-spinning the network RTT;
    # after a small spin budget we park on the body's fd (epoll) until it's
    # readable, then resume. Fast-local I/O resolves within the budget and
    # never parks (path unchanged); slow network parks and reclaims CPU.
    # Lost-wakeup-safe: we only park after a real WouldBlock, and EPOLLIN is
    # level-triggered so a byte already on the socket returns park immediately.
    var pending_run = 0
    while True:
        if unstamped:
            var now_us = Int(_system_now_ns() // UInt64(1000))
            if now_us >= backstop_us:
                raise Error(
                    String(
                        "HttpError[TIMEOUT]: response body deadline exceeded"
                        " after "
                    )
                    + String(out.__len__())
                    + String(
                        " body bytes -- no deadline was stamped on this body,"
                        " so the drain fell back to its unstamped backstop of "
                    )
                    + String(_UNSTAMPED_DRAIN_BACKSTOP_US)
                    + String(
                        " us (collect_body). A body over a live stream is"
                        " built by the OutboundDriver and the driver always"
                        " stamps: fix the construction site, do not widen this"
                        " backstop."
                    )
                )
        var frame = body.poll_frame[RT](reactor, token)
        if frame.is_end():
            break
        if frame.is_error():
            raise Error(
                "HttpError[" + frame.error_detail() + "]: collect_body"
            )
        if frame.is_trailers():
            # doesn't surface trailers; consume + discard.
            _ = frame
            pending_run = 0
            continue
        if frame.is_pending():
            # Spin-then-park. After _COLLECT_BODY_SPIN_BUDGET consecutive
            # Pendings, park on the single body fd instead of re-polling.
            pending_run = pending_run + 1
            if pending_run >= _COLLECT_BODY_SPIN_BUDGET:
                # LOST-WAKEUP GUARD:
                # if s2n already holds decrypted plaintext buffered above
                # the socket fd (a >4KB TLS record drained off the socket,
                # only a 4096-byte chunk handed back), the fd has no more
                # bytes — parking on its readiness would hang until the
                # park deadline fires. SKIP the park and re-poll: the next
                # poll_frame re-reads the buffered remainder. Default-False
                # on the plaintext path (no-op). Why: TLS can hold decrypted
                # bytes that socket readiness cannot see.
                if not body.stream_has_buffered_readable():
                    var park_fds = List[Int32]()
                    park_fds.append(body.stream_fd())
                    # CLAMP THE PARK TO WHAT IS LEFT OF THE BODY'S DEADLINE.
                    # Reading it here is the ONLY thing this loop does with
                    # the deadline -- enforcement lives in `poll_frame`.
                    _ = reactor.park_on_fds(
                        park_fds,
                        _clamped_park_us(
                            _COLLECT_BODY_PARK_TIMEOUT_US,
                            body.remaining_deadline_us(),
                        ),
                    )
                pending_run = 0
            continue
        if frame.is_data():
            pending_run = 0
            var chunk = frame.take_data_chunk()
            var k = 0
            var n = chunk.__len__()
            while k < n:
                out.append(chunk[k])
                k = k + 1
    return out^


# =============================================================================
# §4.1 — drain_bodies_round_robin — K-stream prefetch drain
# =============================================================================
#
# The CPU-efficiency lever for
# the cloud-read path. `collect_body` (above) drains ONE body to completion;
# when that single stream returns Pending it re-polls IMMEDIATELY (line ~830
# `continue`) — under a per-core spin runtime each Pending is a wasted
# `recvfrom`→EWOULDBLOCK (a storm of tens of thousands per read). `drain_bodies_round_robin` holds K already-issued in-flight
# `RecvRingBody` streams and ROTATES: on a Pending for stream i it advances
# to stream i+1 (whose bytes may already be on the socket) instead of
# spinning on i. The spin self-resolves into useful drain — `is_pending` is
# rare because some OTHER stream is almost always ready.
#
# This is PURE caller-side scheduling over the EXISTING non-blocking
# `poll_frame`→Pending primitive. It does NOT touch the runtime's wait/spin
# behavior (make is_pending rare via prefetch; runtime
# untouched).
#
# ORDER PRESERVATION (load-bearing for parquet column decode): the output
# Slab is indexed by the INPUT stream index. `out[i]` is the full body of
# input stream `i`, regardless of the order the K streams happened to
# complete in. The caller (parquet per-column loop) requires column ranges
# back in requested order.
#
# Ownership: `bodies` is borrowed mut (the caller owns the Slab of streams);
# this helper drains them in place and returns a fresh `Slab[List[UInt8]]`
# of the concatenated bytes, one entry per input stream, in input order.


def drain_bodies_round_robin[RT: Runtime, S: IoStream](
    mut bodies: Slab[RecvRingBody[S]],
    mut reactor: Reactor[RT.Sink],
    ref token: CancellationToken,
) raises -> Slab[List[UInt8]]:
    """Round-robin drain of K in-flight `RecvRingBody` streams into K owned
    `List[UInt8]` bodies, preserving input order.

    Algorithm: maintain a per-stream accumulator + a per-stream `done` flag.
    Sweep the K streams; for each not-yet-done stream call ONE `poll_frame`.
    On Data, append the chunk; on End, mark done; on Pending, leave the
    stream for the next sweep (advance to the next stream — do NOT re-poll
    this one). Repeat sweeps until every stream is done. Because a Pending
    on one stream yields immediately to the next (likely-ready) stream, the
    aggregate spin collapses vs. draining each stream to completion serially.

    Returns a `Slab[List[UInt8]]` of size K; entry `i` is the full body of
    input stream `i` (input order preserved).
    """
    var k = bodies.__len__()
    var out = Slab[List[UInt8]]()
    var done = List[Bool]()
    var i = 0
    while i < k:
        out.append(List[UInt8]())
        done.append(False)
        i = i + 1

    if k == 0:
        return out^

    # the runaway guard
    # here used to be `max_iter = 1_000_000 * k` -- an iteration count that
    # got LOOSER the more streams were in flight, which is the wrong
    # direction and, at 50 ms per park, ~3.5 hours PER STREAM. It is now the
    # same wall-clock backstop `collect_body` carries, and for the same
    # reason: it applies ONLY to a stream whose body carries no stamped
    # deadline. A stamped stream raises from its own `poll_frame` at its own
    # deadline, which may differ per stream -- so the test is PER STREAM,
    # evaluated where that stream is polled, and the raise names it.
    var backstop_us = (
        Int(_system_now_ns() // UInt64(1000)) + _UNSTAMPED_DRAIN_BACKSTOP_US
    )
    var remaining = k
    # consecutive-no-progress sweep counter.
    # After _DRAIN_RR_SPIN_BUDGET sweeps where every not-done stream returned
    # Pending (no data drained, no stream completed), park on the not-done
    # streams' fds instead of busy-spinning the network RTT. Lost-wakeup-safe:
    # park only after real WouldBlocks; level-triggered EPOLLIN returns park
    # immediately if a byte is already on any socket.
    var no_progress_sweeps = 0
    while remaining > 0:
        var s = 0
        var made_progress = False
        while s < k:
            if not done[s]:
                if bodies[s].deadline_us() == _NO_DEADLINE:
                    var now_us = Int(_system_now_ns() // UInt64(1000))
                    if now_us >= backstop_us:
                        raise Error(
                            String(
                                "HttpError[TIMEOUT]: response body deadline"
                                " exceeded after "
                            )
                            + String(out[s].__len__())
                            + String(
                                " body bytes -- no deadline was stamped on"
                                " this body, so the drain fell back to its"
                                " unstamped backstop of "
                            )
                            + String(_UNSTAMPED_DRAIN_BACKSTOP_US)
                            + String(
                                " us (drain_bodies_round_robin, stream "
                            )
                            + String(s)
                            + String(
                                "). A body over a live stream is built by the"
                                " OutboundDriver and the driver always"
                                " stamps: fix the construction site, do not"
                                " widen this backstop."
                            )
                        )
                var frame = bodies[s].poll_frame[RT](reactor, token)
                if frame.is_end():
                    done[s] = True
                    remaining = remaining - 1
                    made_progress = True
                elif frame.is_error():
                    raise Error(
                        "HttpError[" + frame.error_detail()
                        + "]: drain_bodies_round_robin (stream "
                        + String(s) + ")"
                    )
                elif frame.is_trailers():
                    # doesn't surface trailers; consume + discard.
                    _ = frame
                elif frame.is_pending():
                    # Advance to the next stream instead of re-polling this
                    # one — the prefetch win. Some other stream is likely
                    # ready; this stream's bytes will be there next sweep.
                    pass
                elif frame.is_data():
                    var chunk = frame.take_data_chunk()
                    if chunk.__len__() > 0:
                        made_progress = True
                    var c = 0
                    var n = chunk.__len__()
                    while c < n:
                        out[s].append(chunk[c])
                        c = c + 1
            s = s + 1
        # spin-then-park after a no-progress sweep.
        if made_progress:
            no_progress_sweeps = 0
        else:
            no_progress_sweeps = no_progress_sweeps + 1
            if no_progress_sweeps >= _DRAIN_RR_SPIN_BUDGET:
                # LOST-WAKEUP GUARD:
                # if ANY in-flight body's stream already holds decrypted
                # plaintext buffered above its socket fd (a >4KB TLS record
                # drained off the socket, only a 4096-byte chunk handed
                # back), that fd has no more bytes — parking the whole set
                # on fd-readiness could hang until the deadline fires while
                # decrypted bytes sit waiting. SKIP the park and re-sweep:
                # the round-robin will re-poll the buffered body and drain
                # the remainder. Default-False on the plaintext path
                # (no-op). Why: TLS can hold decrypted bytes that socket
                # readiness cannot see.
                var any_buffered = False
                var bf = 0
                while bf < k:
                    if not done[bf] and bodies[bf].stream_has_buffered_readable():
                        any_buffered = True
                        break
                    bf = bf + 1
                if not any_buffered:
                    var park_fds = List[Int32]()
                    # CLAMP THE PARK TO THE *SOONEST* DEADLINE among the
                    # streams still in flight -- one park covers all of them,
                    # so it may not outlive the tightest of them. Each body
                    # still ENFORCES its own deadline in its own
                    # `poll_frame`; this only sets how promptly the sweep
                    # comes back to ask.
                    var min_rem = -1
                    var pf = 0
                    while pf < k:
                        if not done[pf]:
                            park_fds.append(bodies[pf].stream_fd())
                            var rem = bodies[pf].remaining_deadline_us()
                            if rem >= 0 and (min_rem < 0 or rem < min_rem):
                                min_rem = rem
                        pf = pf + 1
                    _ = reactor.park_on_fds(
                        park_fds,
                        _clamped_park_us(_DRAIN_RR_PARK_TIMEOUT_US, min_rem),
                    )
                no_progress_sweeps = 0
    return out^
