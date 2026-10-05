# =============================================================================
# src/komira_http_client/client.mojo — HttpClient (the L7 surface)
# =============================================================================
#
# HttpClient is the L7 surface. It is a long-lived object.
# ClientRequest[B] / ClientResponse[RB] use the typed surfaces — Url,
# HeaderMap, Body-trait conformers — not stringly-typed fields, and are
# parametric over their body conformer because Body is a trait.
#
# Shape:
#   * `send()` dials a fresh connection via the Connector and closes after
#     the response; the pooled entry points reuse connections through
#     `PerCorePool` (h1) and `H2ClientPool` (h2).
#   * TLS through `TlsConnector`; HTTP/2 through the h2 client.
#   * Retry / redirect / timeout are layers over the `service.mojo` seam
#     (HttpService + HttpLayer + NoopLayer).
#   * Request body is fully buffered (BytesBody / EmptyBody); streaming
#     body is.
#   * Response body is fully buffered (List[UInt8]); RecvRingBody
#     pull-stream is.
#
# `HttpClient[C: Connector]` is parametric over the connector type, so
# the TlsConnector wrapping (TlsConnector[KernelTcpConnector]) is a
# 1-line type change at the consumer call site — no HttpClient
# restructuring.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * Connector is a value (Movable struct); HttpClient owns its copy
#     and passes it `mut` to send.
# =============================================================================

from std.memory import OwnedPointer

from komira_collections.slab import Slab
from komira_async.cancellation.token import CancellationToken
from komira_net.dns import parse_ip_literal, resolve_host_be
from komira_clock import now_ns as _mono_now_ns
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_client.body import BytesBody, EmptyBody, RequestBody
# ⛔ THE OUTBOUND-BUDGET RULE. A budget may not exceed the deadline of the
# context it runs inside; a serving process builds its clients from
# `HttpClientConfig.for_serving_ceiling(ceiling)`, which derives the budget
# from that deadline. Pure module, no state, no pointer.
from komira_http_client.outbound_budget import (
    OUTBOUND_CEILING_NONE,
    outbound_budget_us,
    tighter_budget_us,
)
from komira_http_client.response_body import (
    BufferedResponseBody,
    RecvRingBody,
    collect_body,
)
from komira_http_client.h2_client import (
    H2ClientConnectionState,
    allocate_client_stream_id_or_raise,
    is_h2_retryable_transport,
    drive_h2_streams_to_completion,
    h2_drive_wall_us,
    encode_request_data_frame,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    extract_trailers_for_stream,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http_client.h2_pool import (
    H2_OUTCOME_FOUND,
    H2_OUTCOME_NEEDS_DIAL,
    H2_OUTCOME_PENDING,
    H2ClientPool,
    H2CheckoutResult,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.slow_phase import (
    SLOW_PHASE_DNS,
    elapsed_ms_since,
    note_slow_phase,
)
from komira_http_client.request_writer import (
    drain_body_into,
    method_get,
    method_head,
    method_delete,
    serialize_request_head,
)
from komira_http_client.service import (
    ClientRequest,
    HttpService,
)
from komira_http_client.pool import (
    ALPN_H2,
    ClientConn,
    PerCorePool,
    PoolKey,
    PoolSizingKnobs,
    VERIFY_PEER,
)
from komira_http_client.state_machine import (
    ClientResponse,
    HTTP_NOTHING_WRITTEN_TOKEN,
    OutboundDriver,
    OUTBOUND_STEP_ERROR,
    OUTBOUND_STEP_HEAD_DONE,
    OUTBOUND_STEP_NOT_READY,
)
from komira_http_client.url import Url
from komira_http_core.codec.types import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PUT,
    HttpMethod,
)
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_2,
)


# =============================================================================
# §1 — HttpClientConfig.
# =============================================================================
# cheap, immutable, globally-shared. Holds NO
# connections / fds / reactor refs. The surface is intentionally
# small.


@fieldwise_init
struct HttpClientConfig(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Cheap immutable config shared across all HttpClient instances in
    a process (or per-pthread under PerCoreAsync).

    Fields:
      tcp_nodelay  — Whether to set SO_NODELAY on the connected socket
                     (default True; survey #4 — Nagle's hurts request
                     latency).
      max_response_body_bytes — Cap on decoded response body. Default
                     100 MiB.
      pool_sizing —: per-host pool sizing tunables
                     (max_conns_per_host / max_idle_per_host /
                     recv_ring_size / idle_threshold_us). HttpClient
                     consumers that construct a PerCorePool typically
                     read these knobs from the config.
      request_timeout_us —: the wall-clock
                     deadline (microseconds) the per-request drive loop
                     (`OutboundDriver`) enforces between send-start and
                     head-parsed. `0` (the default) selects the generous
                     600s `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` — UNCHANGED
                     behavior for every existing caller. A positive value
                     bounds the request so a slow / non-responsive server
                     fails FAST with a TIMEOUT instead of wedging the
                     calling thread for the full 600s default. The Cloud
                     Run flush-before-freeze sets a SHORT value (a few
                     seconds) so the SYNCHRONOUS SIGTERM flush cannot block
                     past the 10s SIGTERM->SIGKILL grace (where a SIGKILL
                     would lose the buffered records). See
                     `S3Client.set_request_timeout_us` /
                     `S3ConditionalStore` flush wiring.

    Future fields:
      connect_timeout / write_timeout / TLS trust
      store + verify mode / layer stack config / retry policy.
    """

    var tcp_nodelay: Bool
    var max_response_body_bytes: Int
    var pool_sizing: PoolSizingKnobs
    # per-request drive-loop deadline (µs); 0 == the 600s default.
    #
    # ⛔ ON A REQUEST-SCOPED PROCESS THIS IS NOT `0`: `for_serving_ceiling`
    # DERIVES it from the deadline of the context the process serves inside;
    # `0`/600s survives only where there is no such deadline (a job, a pod, a
    # CLI, a bench, a test), which is exactly where the 600s default is
    # correct. See `outbound_budget.mojo`.
    var request_timeout_us: Int
    # The deadline of the context this client's calls run inside (µs), or 0 when
    # there is none. Supplied by the process from its platform configuration —
    # never authored by a call site, because a library client is built the same
    # way in a service, a job and a CLI, and only one of those three is inside a
    # request. Carried as a FIELD so the clamp is OBSERVABLE
    # (`budget_was_clamped`) rather than an invisible substitution.
    var context_ceiling_us: Int

    @staticmethod
    def for_serving_ceiling(ceiling_us: Int) -> HttpClientConfig:
        """The default config for a process whose containing request has the
        deadline `ceiling_us` (0 = none).

        A request-scoped serving process computes its ceiling once at startup
        from its platform configuration (`serving_request_ceiling_us` in
        `outbound_budget.mojo`) and builds its clients from this config.
        `defaults()` is this function with no ceiling — they are one API, not
        two."""
        return HttpClientConfig(
            tcp_nodelay=True,
            max_response_body_bytes=100 * 1024 * 1024,
            pool_sizing=PoolSizingKnobs.defaults(),
            request_timeout_us=outbound_budget_us(0, ceiling_us),
            context_ceiling_us=ceiling_us,
        )

    @staticmethod
    def defaults() -> HttpClientConfig:
        """The default config for a process with NO containing request
        deadline (a job, a pod, a CLI, a bench, a test): `request_timeout_us`
        is the generous 600s default.

        ⛔ A process serving requests under a platform deadline must NOT use this:
        a budget that exceeds its container is not a budget, because past the
        ceiling the answer cannot be delivered while the work still holds the
        serve loop. Such a process builds its clients from
        `for_serving_ceiling(ceiling)` instead. See `outbound_budget.mojo`."""
        return HttpClientConfig.for_serving_ceiling(OUTBOUND_CEILING_NONE)

    def budget_was_clamped(self) -> Bool:
        """True iff this config's budget was DERIVED from a containing deadline
        rather than inherited from the generous default — i.e. iff this client
        lives inside a request.

        The "loud" half of the clamp, and deliberately a cheap one: a raise here
        would need `raises` on `defaults()`, hence on `with_defaults`, hence on
        every caller. A predicate costs nothing and is what a diagnostic route
        or a boot log reports."""
        return self.context_ceiling_us > 0


# =============================================================================
# depth bound for the streaming idle pool.
# Sized to the S3 prefetch batch width (parquet projects N columns per RG
# chunk; lineitem ~16). 64 matches `S3Fs.prefetch_depth()` so a full prefetch
# batch's reclaimed streams all fit, giving ~N_workers×(batch reuse) instead
# of a fresh dial per GET.
comptime _STREAMING_IDLE_POOL_DEPTH: Int = 64


# §1.5 — _H1CacheEntry[S] — keepalive-reuse cache entry.
# =============================================================================
#
# tiny Movable
# struct that bundles a stream (in an Optional for take-out) together
# with the PoolKey used to dial it. The HttpClient's _h1_idle_conn
# field is `Optional[OwnedPointer[_H1CacheEntry[Self.C.Stream]]]`;
# `OwnedPointer` keeps the entry on the heap (pointer-safe — stable
# handle), and the inner `Optional<S>` lets us move the stream out on
# cache-hit while keeping the key around for the equality check.
#
# Why not reuse `ClientConn[S]`: ClientConn's `_stream: Self.S` field
# is NOT Optional and the partial-move-of-field-into-Stream pattern is
# banned by the pointer rules. _H1CacheEntry's Optional<S>
# resolves this cleanly via the canonical `.take()` primitive.


struct _H1CacheEntry[S: IoStream](Movable, Deinitable):
    """Per-HttpClient h1 keepalive-reuse cache entry. Bundles
    (stream, key) so the cache lookup can do a key-equality check
    before moving the stream out.

    Fields:
      _stream — Optional<S> so the cache can `take()` the inner stream
                on cache hit. After take, the entry's stream slot is
                empty; the entire entry is dropped.
      _key    — PoolKey the stream was dialed for; used by
                `HttpClient._take_h1_idle_conn_for(key)` to validate
                that the cached conn matches the requested origin.
    """

    var _stream: Optional[Self.S]
    var _key: PoolKey

    def __init__(out self, var stream: Self.S, var key: PoolKey):
        self._stream = Optional[Self.S](stream^)
        self._key = key^

    def key(self) -> PoolKey:
        return self._key

    def take_stream(mut self) raises -> Self.S:
        """Move the inner stream out. Raises if already taken (caller
        bug)."""
        if not self._stream.__bool__():
            raise Error(
                "_H1CacheEntry.take_stream: stream already taken"
            )
        return self._stream.take()


# =============================================================================
# §1c — PendingStreamingGet.
# =============================================================================
# A non-blocking in-flight streaming GET. Owns the dialed/reused stream +
# the OutboundDriver send+head state machine + the per-GET read-head
# scratch. `poll[RT](reactor)` advances ONE non-blocking step; once the
# head parses, `finish()` produces the ClientResponse[RecvRingBody[S]] whose
# BODY is drained later via the caller's existing poll_frame round-robin.
#
# This is the K-stream handle: the s3_fs prefetch loop issues K of these
# (each fires its request bytes without blocking on the head), then
# round-robins `poll` across all K so the head-read RTTs OVERLAP rather than
# serialize. Parametric over the IoStream conformer `S` (the per-call
# connector's stream type). Movable, NOT Copyable — owns the stream + driver.
#
# Pointer discipline: ZERO UnsafePointer in any signature. The
# stream is held in an Optional[S] (the canonical move-out primitive); the
# driver + scratch are owned by-value. NO wildcard origin, NO
# unsafe_from_address.

struct PendingStreamingGet[S: IoStream](Movable, Deinitable):
    """An in-flight, non-blocking streaming GET. See §1c."""

    var _driver: OutboundDriver
    var _stream: Optional[Self.S]
    var _scratch: List[UInt8]
    var _key: PoolKey
    var _done: Bool
    """True once the head has parsed (driver reached DONE). After this,
    `finish()` is the only valid call."""

    def __init__(
        out self,
        var driver: OutboundDriver,
        var stream: Self.S,
        var key: PoolKey,
    ):
        self._driver = driver^
        self._stream = Optional[Self.S](stream^)
        self._scratch = _allocate_local_read_head_scratch()
        self._key = key^
        self._done = False

    def key(self) -> PoolKey:
        """The origin PoolKey this GET was issued for (for keepalive
        reclaim once the body is drained)."""
        return self._key

    def is_head_done(self) -> Bool:
        """True iff the response head has been fully parsed and `finish()`
        is ready to be called."""
        return self._done

    def poll[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) -> UInt8:
        """Advance ONE non-blocking step of the send+head state machine.
        Returns OUTBOUND_STEP_NOT_READY / OUTBOUND_STEP_HEAD_DONE /
        OUTBOUND_STEP_ERROR. On HEAD_DONE, sets `_done`; the caller then
        calls `finish()`. Does NOT raise (the driver records errors
        internally); the caller checks the sentinel + `last_error_detail()`.
        """
        if self._done:
            return OUTBOUND_STEP_HEAD_DONE
        # `_stream` is guaranteed populated until finish() takes it; poll is
        # only called before finish.
        var step = self._driver.step_send_head_nonblocking[Self.S, RT](
            self._stream.value(), reactor, Span[UInt8](self._scratch),
        )
        if step == OUTBOUND_STEP_HEAD_DONE:
            self._done = True
        return step

    def last_error_detail(self) -> String:
        """The HttpError message recorded if `poll` returned
        OUTBOUND_STEP_ERROR."""
        return self._driver.last_error_detail()

    def fd(self) -> Int32:
        """The underlying socket fd of the
        in-flight GET's stream, for transient registration with the
        reactor when a round-robin drain parks. Returns -1 if the stream
        has been taken (after finish()) or the conformer has no pollable
        kernel fd (e.g. ScriptedStream). POD return — IoStream.fd() is a
        POD Int32 accessor; no pointer crosses the module boundary."""
        if not self._stream.__bool__():
            return Int32(-1)
        return self._stream.value().fd()

    def finish(mut self) raises -> ClientResponse[RecvRingBody[Self.S]]:
        """Build the ClientResponse once the head has parsed. Moves the
        stream into the RecvRingBody (body drained later via poll_frame).
        Raises if called before the head is done (caller bug)."""
        if not self._done:
            raise Error(
                "PendingStreamingGet.finish: head not yet parsed"
            )
        if not self._stream.__bool__():
            raise Error(
                "PendingStreamingGet.finish: stream already taken"
            )
        var stream = self._stream.take()
        return self._driver.finish_into_response[Self.S](stream^)


# =============================================================================
# §2 — HttpClient.
# =============================================================================


struct HttpClient[C: Connector](HttpService, Movable, Deinitable):
    """L7 HTTP client. Parametric over the Connector conformer.

    Lifecycle: one client per worker (per-pthread under
    PerCoreAsync). Each `send` opens ONE connection via the Connector,
    runs one request-response cycle, and closes. introduces
    the connection pool; the call-site surface is unchanged (HttpClient.send
    interface is stable across ->).

    HttpClient conforms to the HttpService trait — the `call` method is
    the base of any Service/Layer composition stack.

    Construction:
      * `HttpClient(config, connector)` — owned config + owned connector.
      * `HttpClient.with_defaults(connector)` — default config.

    Movable, NOT Copyable — the connector is owned (the connector is
    POD-shaped but reserves the right to hold non-Copyable state in
    future variants).
    """

    var _config: HttpClientConfig
    var _connector: Self.C
    # pool-stateful refactor:
    #   * `_h1_pool` is the per-pthread h1 PerCorePool, lazy-init on first
    #     h1 dial / acceptance test.
    #   * `_h2_pool` is the per-pthread h2 multiplex pool, lazy-init on first
    #     h2 dial (so multiple `send` calls share a single TLS+TCP conn
    #     via h2 streams — the load-bearing fd-count=1 invariant for
    #     §10.3 ObjectStore range fan-out).
    # Both are Optional[OwnedPointer[...]] —
    # the `Optional.take` + restash pattern resolves the
    # `mut self + mut self._h2_pool` aliasing barrier without
    # introducing ArcPointer.
    # Lazy-init: a fresh HttpClient has both Optional.None until first
    # h1/h2 dial — the / per-call dial path stays the
    # fallback if pool wiring is bypassed by a caller (preserves
    # existing test behavior).
    var _h1_pool: Optional[OwnedPointer[PerCorePool[Self.C.Stream]]]
    var _h2_pool: Optional[OwnedPointer[H2ClientPool[Self.C.Stream]]]
    #
    # Per-client read-head scratch buffer. The OutboundDriver's
    # _drive_read_head per-request `var scratch = List[UInt8]()` +
    # 4096-iter zero-init was 35.48% self-time = 98 µs/iter on
    # hc01-loopback. Hoisting the buffer
    # to a per-HttpClient `Optional[OwnedPointer[InlineArray[UInt8,
    # 4096]]]` eliminates per-request alloc.
    #
    # Design choices:
    # - `Optional` for lazy-init — a fresh HttpClient that never sends
    #   pays zero cost.
    # - `OwnedPointer[InlineArray]` (not raw `InlineArray`) keeps the
    #   HttpClient struct itself small (8-byte handle, not 4 KB inline).
    #   Future cross-call-frame moves of HttpClient memcpy 8 bytes,
    #   not 4 KB. The prior attempt's per-OutboundDriver inline field
    #   regressed by +34 µs/iter exactly because of 4 KB Movable-move
    #   memcpy ( revert).
    # - `Span[UInt8, _]` is threaded through the dispatch path; the
    #   InlineArray is reached as `self._read_head_scratch.value()[]`
    #   and Spanned over via `Span[UInt8](self._read_head_scratch.value()[])`.
    var _read_head_scratch: Optional[OwnedPointer[Array[UInt8, 4096]]]
    #
    # Per-HttpClient single-conn cache for h1 keepalive-reuse. On a
    # successful response with `connection_close=False` (the HTTP/1.1
    # default — see response_parser.mojo §"Connection toggle"), the
    # underlying stream is wrapped in a ClientConn and stashed here.
    # The next same-origin send_buffered extracts the cached ClientConn
    # and skips the connector.connect dial — eliminating per-request
    # socket() + connect() + epoll_ctl kernel chatter (~20-30 µs/iter
    # on hc01-loopback).
    #
    # Cache discipline (MVP single-conn):
    #   * At most ONE cached conn per HttpClient at a time.
    #   * Key invalidation: on take, the cached ClientConn's key is
    #     compared to the requested PoolKey. Mismatch → drop + dial fresh.
    #   * Connection: close → cache NOT populated after this response.
    #   * Concurrent same-host requests (more than 1 in flight): the
    #     second one's `Optional.take()` sees None → dials fresh.
    #     Degrades to current behavior, NOT a correctness issue.
    #
    # Storage shape: `Optional[OwnedPointer[_H1CacheEntry[Self.C.Stream]]]`
    # where `_H1CacheEntry[S]` is a small POD bundling
    # `(stream: Optional[S], key: PoolKey)`. The inner Optional<S> +
    # Optional<OwnedPointer> double-wrap is intentional:
    #   - Optional<S> inside the entry lets us `take()` the stream out
    #     on cache hit while preserving the `key: PoolKey` for the
    #     key-equality check at lookup time.
    #   - Outer Optional<OwnedPointer> mirrors the existing _h1_pool /
    #     _h2_pool / _read_head_scratch field shape — pointer-safe
    #     (OwnedPointer is the stable heap handle).
    # ClientConn isn't reused here because its `_stream: Self.S` field
    # is NOT Optional and the partial-move-of-field-into-stream is
    # banned (the pointer rules) — needing an Optional<S> for take semantics.
    var _h1_idle_conn: Optional[OwnedPointer[_H1CacheEntry[Self.C.Stream]]]
    # per-HttpClient idle
    # stream POOL for the STREAMING (RecvRingBody) path. The single-conn
    # `_h1_idle_conn` MVP above serves the BUFFERED `send_buffered` path; it
    # cannot pool the K concurrent in-flight GETs that the prefetch
    # (`S3Fs.read_ranges_prefetched`) issues per batch. This depth-bounded
    # Slab caches the streams reclaimed (via `RecvRingBody.take_stream()`)
    # after each prefetch batch drains, so the NEXT batch of streaming GETs
    # checks out a live keepalive connection instead of dialing fresh.
    #
    # Root cause this closes: BOTH the connector-driven `.call` path
    # (S3Store.get_range → HttpClient.call → _run_one_request_buffered_with_
    # dispatch) AND the streaming prefetch path (send_streaming_with_connector
    # → _run_one_request_streaming) ALWAYS call `connector.connect` — one
    # fresh socket()+connect()+epoll per ranged GET (strace: 1072 connect per
    # 298MB read). The keepalive cache existed but only `send_buffered` (NOT
    # used by S3) consulted it.
    #
    # Pool discipline (per-pthread by construction — the owning S3Fs transport
    # is per-worker; no cross-pthread sharing, no Arc, pointer-safe — OwnedPointer
    # is the stable heap handle, Slab[_H1CacheEntry[S]] holds Movable entries
    # with no wildcard/heap-owning pointer field):
    #   * Bounded to `_STREAMING_IDLE_POOL_DEPTH` entries (oldest dropped on
    #     overflow — its stream's drop closes the fd).
    #   * Checkout (`_take_streaming_idle_conn_for(key)`) pops a key-matching
    #     entry; non-matching popped entries are dropped (stale origin).
    #   * Stash (`_stash_streaming_idle_stream`) only happens for streams
    #     reclaimed from a `connection_close=False` response (keepalive robustness:
    #     a server-closed keepalive conn is NOT stashed; the next GET dials
    #     fresh — and `_run_one_request_streaming_on_stream` transparently
    #     reconnect-retries if a stashed conn turns out dead).
    var _streaming_idle_pool: Optional[
        OwnedPointer[Slab[_H1CacheEntry[Self.C.Stream]]]
    ]
    # ★★ THE DIAL-ADDRESS RESOLVE COUNTER — WHAT MAKES "DID THIS REQUEST
    # RESOLVE?" ASSERTABLE WITHOUT A NAMESERVER.
    #
    # Every dial coordinate this client produces comes from ONE step,
    # `_ip_be_from_host` — the function holding the ONLY unbounded
    # blocking libc call on this path (`getaddrinfo`, in `komira_async`'s
    # DNS module). Run EAGERLY at the top of the pooled entry
    # points, it would cost once per REQUEST — including a request that reused a warm
    # h2/h1 connection and dialled nothing at all. The resolve is lazy (it
    # sits at the dial points), and the only honest proof of
    # laziness is a COUNT of how many times the step was entered.
    #
    # ⚠ WHAT IT COUNTS, EXACTLY: ENTRIES INTO THE RESOLVE STEP — not
    # `getaddrinfo` calls. The two differ only by the IP-LITERAL FAST PATH
    # inside `_ip_be_from_host`: for a DNS-name host one entry IS one
    # getaddrinfo; for a literal it is a parse. Keeping that distinction
    # OUTSIDE the counter is deliberate and is what makes the property
    # hermetically testable — a test dials `127.0.0.1` through a
    # ScriptedConnector, touches no nameserver, and still measures exactly
    # the quantity laziness changes. A counter that fired only on the DNS
    # branch could not be asserted without a live resolver, which is how
    # this defect survived: the behaviour had no observable.
    #
    # ⚠ SCOPE: the METHOD dial paths on this struct. The three free-function
    # dial helpers (`_run_one_request_streaming`,
    # `_run_one_request_buffered_with_dispatch`, `_run_one_request_buffered`)
    # hold no `self` and are NOT counted — they consult no pool and dial
    # unconditionally, so there is no laziness for them to have.
    var _dial_resolves: Int

    def __init__(out self, config: HttpClientConfig, var connector: Self.C):
        self._config = config
        self._connector = connector^
        self._h1_pool = Optional[OwnedPointer[PerCorePool[Self.C.Stream]]]()
        self._h2_pool = Optional[OwnedPointer[H2ClientPool[Self.C.Stream]]]()
        self._read_head_scratch = Optional[
            OwnedPointer[Array[UInt8, 4096]]
        ]()
        self._h1_idle_conn = Optional[
            OwnedPointer[_H1CacheEntry[Self.C.Stream]]
        ]()
        self._streaming_idle_pool = Optional[
            OwnedPointer[Slab[_H1CacheEntry[Self.C.Stream]]]
        ]()
        self._dial_resolves = 0

    @staticmethod
    def with_defaults(var connector: Self.C) -> HttpClient[Self.C]:
        """A client built from `HttpClientConfig.defaults()`: no containing
        request deadline, so the per-request budget is the generous 600s
        default.

        ⛔ A process serving requests under a platform deadline must NOT use this
        constructor: its budget would exceed its container. Build that client with
        `HttpClient(config=HttpClientConfig.for_serving_ceiling(ceiling),
        connector=...)` instead. See `outbound_budget.mojo`."""
        return HttpClient[Self.C](
            config=HttpClientConfig.defaults(),
            connector=connector^,
        )

    @staticmethod
    def with_request_timeout_us(
        var connector: Self.C, request_timeout_us: Int
    ) -> HttpClient[Self.C]:
        """Like `with_defaults` but with the per-request
        drive-loop deadline set (0 = the 600s default — identical to
        `with_defaults`). Used by the S3 transport builder when the store's
        `S3Config` carries a positive `request_timeout_us` (the Cloud Run
        flush sink), so a non-responsive store fails FAST rather than wedging
        the calling thread.

        ⚠ THIS CONSTRUCTOR HAS NO CONTAINING DEADLINE (it starts from
        `HttpClientConfig.defaults()`), so the authored value passes through
        VERBATIM and is never clamped. A serving process that must keep a
        budget inside its container sets `request_timeout_us` on a config from
        `HttpClientConfig.for_serving_ceiling(ceiling)`, where
        `outbound_budget_us` resolves it against the ceiling and
        `budget_was_clamped()` / `outbound_budget_exceeds_ceiling` report a
        budget bigger than the container."""
        var cfg = HttpClientConfig.defaults()
        cfg.request_timeout_us = outbound_budget_us(
            request_timeout_us, cfg.context_ceiling_us
        )
        return HttpClient[Self.C](config=cfg, connector=connector^)

    @always_inline
    def config(self) -> HttpClientConfig:
        return self._config

    # ----- The dial-address resolve step ---------------------------------

    def _resolve_dial_ip_be(
        mut self, host: String, port: UInt16
    ) raises -> UInt32:
        """ENTER the dial-address resolve step once, COUNTING the entry.

        ⛔ CALL THIS ONLY WHERE A DIAL IS ABOUT TO HAPPEN — that is the
        entire point of its existence. `_ip_be_from_host` can block for an
        unbounded time on a DNS name (`getaddrinfo(3)` takes no timeout and
        cannot be cancelled), so a request that reuses a pooled connection
        must never reach it. Every `connect[RT]` site on this struct
        resolves through here, in the statement immediately before the dial;
        NOTHING on this struct resolves ahead of a pool probe.

        Two statements, never one expression: `self._connector.connect(...,
        ip_be=self._resolve_dial_ip_be(...))` borrows `self` mutably twice and
        is rejected by the Mojo 1.0.0b2 aliasing diagnostic (the same barrier
        §2.5 documents for the dispatch helpers).
        """
        self._dial_resolves = self._dial_resolves + 1
        return _ip_be_from_host(host, port)

    @always_inline
    def dial_resolve_steps_total(self) -> Int:
        """How many times THIS client has entered the dial-address resolve
        step — the observable that makes "a pooled hit performs no resolve"
        a testable claim rather than a timing impression.

        Pair it with `self._connector.connect_call_count()`: the two together
        assert a CEILING (a reuse hit adds no resolve) *and* a FLOOR (a cold
        dial adds exactly one, so a change that broke dialling outright —
        which would also show zero resolves — is not mistaken for the fix).

        Counts resolve-step ENTRIES, not `getaddrinfo` calls; see the
        `_dial_resolves` field comment for why that distinction is deliberate
        and which dial paths are out of its scope."""
        return self._dial_resolves

    # -----: pool field accessors ----------------------------------
    # The `_h1_pool` / `_h2_pool` fields are Optional[OwnedPointer[...]];
    # callers that want to perform pool-state-aware operations
    # (checkout/checkin, dials_total diagnostic for hc03, GOAWAY drain
    # for h2) lazy-init the pool via `ensure_h1_pool` / `ensure_h2_pool`.
    # The accessors return a `ref` through the field chain.

    def ensure_h1_pool(mut self):
        """Lazy-init the h1 pool. Idempotent: a no-op if already init.
        After this returns, `self._h1_pool.__bool__() == True`."""
        if not self._h1_pool.__bool__():
            var pool = PerCorePool[Self.C.Stream].new(self._config.pool_sizing)
            self._h1_pool = Optional[
                OwnedPointer[PerCorePool[Self.C.Stream]]
            ](OwnedPointer(pool^))

    def ensure_h2_pool(mut self):
        """Lazy-init the h2 pool. Idempotent., the h2 pool
        is a SIBLING of the h1 pool; they share the (scheme, host, port,
        verify_mode) PoolKey shape but with disjoint `negotiated_alpn`
        discriminators."""
        if not self._h2_pool.__bool__():
            var pool = H2ClientPool[Self.C.Stream].new(self._config.pool_sizing)
            self._h2_pool = Optional[
                OwnedPointer[H2ClientPool[Self.C.Stream]]
            ](OwnedPointer(pool^))

    def h1_pool_is_init(self) -> Bool:
        return self._h1_pool.__bool__()

    def h2_pool_is_init(self) -> Bool:
        return self._h2_pool.__bool__()

    def _note_h1_dial(mut self):
        """Count one h1 dial performed OUTSIDE the pool's connection
        bookkeeping (the `call_pooled` keepalive path and the stale-conn redial
        arms), so `h1_pool_dials_total()` sees it.

        ⚠ THIS IS OBSERVABILITY, AND IT IS THE POINT OF THE WHOLE RETRY ARM.
        A transparent redial that nothing counts makes a pool that is churning
        one connection per request indistinguishable from a warm one — a
        service can degrade for a long time inside exactly that
        blind spot. Go exposes it as `httptrace.GotConn{Reused, WasIdle}`,
        urllib3 as `Retry.history`; `dials_total` is this client's only seam."""
        self.ensure_h1_pool()
        var pool_owned = self._h1_pool.take()
        pool_owned[].note_dial()
        self._h1_pool = Optional[
            OwnedPointer[PerCorePool[Self.C.Stream]]
        ](pool_owned^)

    def h1_pool_dials_total(self) -> Int:
        """Diagnostic: total h1 dials performed (insert_dialed calls).
        Returns 0 if the h1 pool is not yet init.
        Used by connection-reuse checks (e.g. ≥95% reuse warm)."""
        if not self._h1_pool.__bool__():
            return 0
        return self._h1_pool.value()[].dials_total()

    def h2_pool_bucket_count(self) -> Int:
        """Diagnostic: how many distinct h2 PoolKeys this client has
        seen. Used by the e2e fd-count gate to verify N concurrent
        requests to one origin landed on ONE bucket (and therefore
        one conn, since h2 multiplexes)."""
        if not self._h2_pool.__bool__():
            return 0
        return self._h2_pool.value()[].bucket_count()

    def h2_pool_dials_total(self) -> Int:
        """Diagnostic: total h2 conns dialed + registered
        (insert_dialed_h2 calls) across all buckets. Returns 0 if the h2
        pool is not yet init. (Gap A): the
        multiplex gate asserts this stays at 1 while N gRPC RPCs run to
        the same authority (N streams, ONE dial)."""
        if not self._h2_pool.__bool__():
            return 0
        return self._h2_pool.value()[].dials_total()

    def h2_pool_conn_count_at(self, b_idx: Int) -> Int:
        """Diagnostic: number of h2 conns in bucket `b_idx`. For the
        Gap A multiplex gate — after N gRPC RPCs to one authority this is
        1 (all N streams shared one conn). Returns 0 if the pool is not
        init."""
        if not self._h2_pool.__bool__():
            return 0
        if b_idx < 0 or b_idx >= self._h2_pool.value()[].bucket_count():
            return 0
        return self._h2_pool.value()[].conn_count_at(b_idx)

    # ----- accessors -----
    # Per-client read-head scratch (one allocation per HttpClient
    # lifetime; reused across all send_buffered calls). Lazy-init on
    # first send-buffered call; existing HttpClient consumers that
    # don't send pay zero cost.

    def ensure_read_head_scratch(mut self):
        """Lazy-init the per-client read-head scratch buffer.
        Idempotent: a no-op if already init. After this returns,
        `read_head_scratch_is_init() == True`. The 4 KB
        `InlineArray[UInt8, 4096]` is heap-once-allocated via
        OwnedPointer."""
        if not self._read_head_scratch.__bool__():
            var arr = Array[UInt8, 4096](fill=UInt8(0))
            self._read_head_scratch = Optional[
                OwnedPointer[Array[UInt8, 4096]]
            ](OwnedPointer(arr^))

    def read_head_scratch_is_init(self) -> Bool:
        """Diagnostic: True iff the lazy-init scratch has been
        allocated. Used by the regression test to verify the
        architectural invariant that the scratch is allocated ONCE
        and reused across all send_buffered calls (not per-request)."""
        return self._read_head_scratch.__bool__()

    # -----: cache helpers -----
    # The hot-path h1 dispatch consults `_take_h1_idle_conn_for(key)`
    # before dialing. On response complete with connection_close=False,
    # it calls `_stash_h1_idle_conn(conn)` to populate the cache for
    # the next same-origin send.

    def h1_idle_conn_is_cached(self) -> Bool:
        """Diagnostic: True iff an h1 idle conn is currently cached for
        reuse. Used by the regression tests to verify the cache
        lifecycle (populated after keepalive response; empty after
        Connection: close or fresh client)."""
        return self._h1_idle_conn.__bool__()

    def _take_h1_idle_conn_for(
        mut self, key: PoolKey,
    ) -> Optional[OwnedPointer[_H1CacheEntry[Self.C.Stream]]]:
        """Take the cached h1 idle entry IFF its PoolKey matches `key`.
        Returns None if no entry cached OR if the cached entry's key
        doesn't match — in which case the mismatched entry is DROPPED
        (its stream's drop closes the fd).

        Single-conn cache discipline: at most one idle entry per
        HttpClient at a time; the MVP fits the hc01-loopback (and
        many real workloads) shape of sequential same-origin
        requests."""
        if not self._h1_idle_conn.__bool__():
            return Optional[OwnedPointer[_H1CacheEntry[Self.C.Stream]]]()
        var cached = self._h1_idle_conn.take()
        if cached[].key() == key:
            return Optional[
                OwnedPointer[_H1CacheEntry[Self.C.Stream]]
            ](cached^)
        # Key mismatch — drop the cached entry; return None.
        _ = cached^
        return Optional[OwnedPointer[_H1CacheEntry[Self.C.Stream]]]()

    def _stash_h1_idle_stream(
        mut self,
        var stream: Self.C.Stream,
        var key: PoolKey,
    ):
        """Stash `stream` as the per-client idle cache, keyed by
        `key`. Replaces any previously-cached entry (which is dropped —
        single-conn discipline). The stream's drop is deferred until
        the cache is dropped/replaced."""
        if self._h1_idle_conn.__bool__():
            var _old = self._h1_idle_conn.take()
            _ = _old^
        var entry = _H1CacheEntry[Self.C.Stream](stream^, key^)
        self._h1_idle_conn = Optional[
            OwnedPointer[_H1CacheEntry[Self.C.Stream]]
        ](OwnedPointer(entry^))

    # -----: streaming idle pool ----------
    #
    # The streaming (RecvRingBody) analog of the single-conn _h1_idle_conn
    # cache. A depth-bounded Slab so the K concurrent prefetch GETs each
    # reclaim + reuse a live keepalive connection. Per-pthread by
    # construction (the owning S3Fs transport is per-worker). Lazy-init on
    # first stash — a client that never streams pays zero cost.

    def ensure_streaming_idle_pool(mut self):
        """Lazy-init the streaming idle pool Slab on first use."""
        if not self._streaming_idle_pool.__bool__():
            self._streaming_idle_pool = Optional[
                OwnedPointer[Slab[_H1CacheEntry[Self.C.Stream]]]
            ](
                OwnedPointer(
                    Slab[_H1CacheEntry[Self.C.Stream]].with_capacity(
                        _STREAMING_IDLE_POOL_DEPTH
                    )
                )
            )

    def streaming_idle_pool_len(self) -> Int:
        """Diagnostic: number of idle streaming conns currently pooled."""
        if not self._streaming_idle_pool.__bool__():
            return 0
        return self._streaming_idle_pool.value()[].__len__()

    def _take_streaming_idle_conn_for(
        mut self, key: PoolKey,
    ) -> Optional[Self.C.Stream]:
        """Pop a pooled idle stream whose PoolKey matches `key`, scanning
        from the back. Non-matching popped entries are DROPPED (stale
        origin — its stream's drop closes the fd). Returns None if the
        pool is empty or holds no key-matching entry.

        The scan walks from the tail (`pop()` is O(1)); since the S3
        prefetch hits a single origin per worker, the first pop is almost
        always a match. The mismatch-drop path only fires across a
        host/port change (rare for the read workload)."""
        if not self._streaming_idle_pool.__bool__():
            return Optional[Self.C.Stream]()
        var pool = self._streaming_idle_pool.take()
        var result = Optional[Self.C.Stream]()
        # Walk the pool tail-first; keep non-matching entries in a holdover
        # list to re-stash, drop nothing prematurely on a key mismatch
        # other than the matched-and-extracted one.
        var holdover = Slab[_H1CacheEntry[Self.C.Stream]].with_capacity(
            _STREAMING_IDLE_POOL_DEPTH
        )
        while pool[].__len__() > 0:
            var popped = pool[].pop()
            var entry = popped.take()
            if not result.__bool__() and entry.key() == key:
                try:
                    result = Optional[Self.C.Stream](entry.take_stream())
                except:
                    # Entry already taken (shouldn't happen for pooled
                    # idle entries) — drop it.
                    _ = entry^
            else:
                holdover.append(entry^)
        # Re-stash the holdover (preserves the remaining idle conns).
        var hk = 0
        while holdover.__len__() > 0:
            var ho_popped = holdover.pop()
            pool[].append(ho_popped.take())
            hk = hk + 1
        self._streaming_idle_pool = Optional[
            OwnedPointer[Slab[_H1CacheEntry[Self.C.Stream]]]
        ](pool^)
        return result^

    def _stash_streaming_idle_stream(
        mut self,
        var stream: Self.C.Stream,
        var key: PoolKey,
    ):
        """Return a drained, keepalive-safe stream to the idle pool. If the
        pool is at `_STREAMING_IDLE_POOL_DEPTH`, the oldest (front) entry is
        dropped to make room (its stream's drop closes the fd). Caller MUST
        only stash streams reclaimed from a `connection_close=False`
        response (keepalive robustness — server-closed conns are dropped, not
        pooled)."""
        self.ensure_streaming_idle_pool()
        var pool = self._streaming_idle_pool.take()
        if pool[].__len__() >= _STREAMING_IDLE_POOL_DEPTH:
            # Pool full — drop the tail entry to make room (its stream's drop
            # closes the fd). Bounded eviction; keeps the pool at depth.
            var _evicted = pool[].pop()
            _ = _evicted^
        var entry = _H1CacheEntry[Self.C.Stream](stream^, key^)
        pool[].append(entry^)
        self._streaming_idle_pool = Optional[
            OwnedPointer[Slab[_H1CacheEntry[Self.C.Stream]]]
        ](pool^)

    # ----- The per-call budget ---------------------------------------------

    @always_inline
    def _budget_for[B: RequestBody](self, ref req: ClientRequest[B]) -> Int:
        """The wall-clock budget (µs) that actually binds THIS call: the
        TIGHTER of what the request carries and what this client is configured
        for. `0` from both means "neither party stated one" and the driver's
        own generous default applies, because every request builder produces a
        request carrying 0.

        ⭐ WHY THIS EXISTS AT ALL, AND WHY IT IS ONE METHOD AND NOT A DOZEN
        OPEN-CODED READS. If each entry point read `self._config.request_timeout_us`
        itself and handed it to the drive loop, a `TimeoutLayer`
        above us would have no way to reach any of them — it composes over an
        arbitrary `HttpService` — so its deadline could only be applied AFTER
        the call returned, which labels the overrun instead of bounding it.
        Routing every one of those reads through here means a deadline stated
        on the request binds on EVERY entry point, and a new entry point that
        forgets it is a read of the config the reviewer can see.

        ⚠ THE DEFECT CLASS THIS IS SHAPED AGAINST: a dispatcher that drops a
        trailing `request_timeout_us` argument on one arm turns an 8 s budget
        into a ~300 s block. A deadline is only as good as the last frame that
        forwards it, which is why this composes rather than substitutes:
        `tighter_budget_us` is idempotent, so a frame that re-composes cannot
        drift, and it never LOOSENS, so a per-request number can never escape
        the ceiling `outbound_budget_us` clamped the config to."""
        return tighter_budget_us(
            self._config.request_timeout_us, req.request_budget_us()
        )

    # ----- The HttpService trait method ----------------------------------

    def call[RT: Runtime, C2: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C2,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """The base HttpService.call. Drives one request-response cycle
        end-to-end, slurping the full body into a BufferedResponseBody.

        This is the LAYERED surface — the HttpService trait method that
        retry/timeout/redirect layers wrap. Layers operate on
        fully-buffered responses for replay/inspection semantics.

        For streaming consumers, see `HttpClient.send` which returns
        ClientResponse[RecvRingBody[...]] without slurping.

        after `connector.connect[RT]`, the call
        inspects `stream.negotiated_protocol()`. If `NEGOTIATED_HTTP_2`,
        the request is driven through the h2 codec
        (`_run_one_request_buffered_h2`); otherwise the existing h1 path
        (`_run_one_request_buffered`). Existing h1 callers are unchanged
        because the default ALPN sentinel is NEGOTIATED_HTTP_1_1.
        """
        var max_body = self._config.max_response_body_bytes
        var req_timeout = self._budget_for(req)
        var body = req.body.take()
        return _run_one_request_buffered_with_dispatch[RT, C2, B](
            req^, body^, connector, reactor, max_body, req_timeout,
        )

    def call_pooled[RT: Runtime, C2: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C2,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """The HttpService
        `call_pooled` override. The buffered keepalive cache is typed on
        `Self.C.Stream`; pooling is only type-safe when the per-call connector
        `C2 == Self.C`. This override comptime-branches:
          * `C2 == Self.C` → the real keepalive path (`_call_pooled_self_c`),
            reusing an idle conn for the request's origin. This is the broker
            path (`SigV4SignedTransport[C]` threads its own `C`).
          * `C2 != Self.C` → fall back to the non-pooled `call` (a foreign
            connector type can't reuse this client's `Self.C.Stream` cache).

        The `comptime if (C2 == Self.C)` branch is sound because
        under it the two types are statically identical; we form a
        concrete-origin pointer to the `connector` borrow and reinterpret it as
        `Self.C` to call the keepalive path mutably. `rebind` is NOT usable here
        — it requires `T: ImplicitlyCopyable`, but a Connector is Movable-only;
        the confined `UnsafePointer` reinterpret is the documented internal
        escape for a `_type_is_eq`-proven generic→concrete borrow (same idiom
        as `transport/dispatch.mojo:write_delivered_to_conn`). The pointer is
        dereferenced synchronously on this stack, never escapes this function,
        and crosses NO module boundary."""
        comptime if (C2 == Self.C):
            # SAFETY: `(C2 == Self.C)` (the comptime branch) proves
            # `C2` IS `Self.C`, so the address of the `connector` borrow is a
            # valid `Self.C*`. The reinterpret is dereferenced once,
            # synchronously, on this stack; the resulting mutable ref is passed
            # to `_call_pooled_self_c` (which dials on it) and the pointer never
            # escapes this frame. No module boundary is crossed; this is the
            # internal-confinement carve-out (pointer-hierarchy
            # item 4), not a signature-level UnsafePointer.
            var conn_p = UnsafePointer(to=connector).bitcast[Self.C]()
            return self._call_pooled_self_c[RT, B](
                req^, conn_p[], reactor,
            )
        else:
            var max_body_fb = self._config.max_response_body_bytes
            var req_timeout_fb = self._budget_for(req)
            var body_fb = req.body.take()
            return _run_one_request_buffered_with_dispatch[RT, C2, B](
                req^, body_fb^, connector, reactor, max_body_fb,
                req_timeout_fb,
            )

    def _call_pooled_self_c[RT: Runtime, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: Self.C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """The KEEPALIVE-AWARE
        buffered path, using an EXPLICIT per-call connector pinned to `Self.C`
        (the S3 / broker write path threads its own per-worker `connector`).
        Internal — reached via the `call_pooled` trait override after the
        comptime `C2 == Self.C` check.

        Unlike `call` (which routes to the free fn
        `_run_one_request_buffered_with_dispatch`, dialing fresh every call
        and DROPPING the stream), this CHECKS OUT an idle keepalive stream for
        the request's origin from the per-HttpClient `_h1_idle_conn` cache; on
        hit, it drives the request on the reused stream (NO `connector.connect`
        — no fresh socket / connect / epoll). On miss it dials fresh. After a
        keepalive-safe response (connection_close=False) it STASHES the stream
        back for the next same-origin call. This is what collapses the
        broker's per-produce dial latency: a single `_append_inner` does
        successive `get` / `head` / `conditional_put` ops on ONE per-worker
        store/connector, and they now reuse ONE TCP conn instead of N fresh
        dials.

        CONSTRAINED to `Self.C` (the cache's stream type is `Self.C.Stream`).
        The generic `call[RT, C2, B]` cannot pool because `C2 != Self.C` is
        permitted in general (the cached stream type might not match) — the
        `Self.C` constraint is exact for the broker path (its
        `S3Store[SigV4SignedTransport[C]]` inner HttpClient[C] and the per-call
        connector are the SAME `C`).

        Plaintext-http h1 only: https / h2 fall back to the existing free-fn
        dispatch (the broker is plaintext, so it never takes that path; this
        keeps the method total for any caller). h1-over-TLS keepalive is a
        follow-up (same restriction as the `send_buffered` MVP).

        robustness (don't regress the closed-keepalive race): a reused
        keepalive conn the server silently closed surfaces as a transport
        error on the head-read; this method CATCHES it and transparently
        retries with a FRESH dial. The signed wire bytes (`req.request_bytes`,
        Copyable) are captured BEFORE the reuse attempt consumes `req`, so the
        retry replays the exact bytes (the broker write ops are idempotent
        under replay — see `_drive_buffered_on_stream_bytes`).

        # THREAD-SAFETY: per-pthread — the `_h1_idle_conn` cache is
        # per-HttpClient (per-worker); the connector dials on the caller's
        # single-thread-access stream. No cross-worker sharing.
        """
        var is_http = req.url.is_http()
        _scheme_check_or_raise[Self.C](req.url.is_https(), is_http, connector)
        var max_body = self._config.max_response_body_bytes
        # the drive-loop deadline (0 = the 600s default —
        # unchanged for every existing caller); a positive value (the Cloud Run
        # flush sets a short one) fails FAST on a non-responsive server.
        var req_timeout = self._budget_for(req)
        if not is_http:
            # https / h2 — no buffered keepalive cache (MVP). Fall back to
            # the existing free-fn dispatch on the per-call connector.
            var body_fb = req.body.take()
            return _run_one_request_buffered_with_dispatch[RT, Self.C, B](
                req^, body_fb^, connector, reactor, max_body, req_timeout,
            )

        # Plaintext h1 keepalive path. Capture everything the request-drive +
        # the dial-fresh retry need BEFORE `req` is consumed: the signed wire
        # bytes (Copyable), the HEAD flag, and the dial coords.
        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        # ★ PER-REQUEST SNI: tell the connector which HOST this dial is FOR,
        # not just which ADDRESS. Resolving the address and then dropping the
        # NAME makes a connector reused across two hosts present the
        # FIRST host's SNI to the second. Full statement of that defect + why
        # an explicitly-pinned SNI wins: `Connector.set_dial_host`
        # (transport/io_stream.mojo).
        # ⚠ COSTS NO HANDSHAKE *AND NO RESOLVE*. This writes one field; every
        # pooled-reuse path below returns without reaching `connect` at all,
        # and without resolving an address either — the two
        # dial points each resolve
        # for themselves.
        # ⛔ A blocking `getaddrinfo` on every pooled-reuse hit is easy to miss
        # in review because the cost hides behind a claim about the
        # HANDSHAKE. Do not hoist a resolve back above
        # the pool probe. Falsifier: `test_dial_resolve_is_lazy`.
        connector.set_dial_host(host_str.copy())
        var is_head = Int(req.method.code) == Int(HTTP_METHOD_HEAD)
        var method_code = req.method.code
        var saved_req_bytes = req.request_bytes.copy()
        _ = req^
        var key = pool_key_for_origin(host_str, port, True)

        var idle = self._take_h1_idle_conn_for(key)
        if idle.__bool__():
            var cached_entry = idle.take()
            var cached_stream = cached_entry[].take_stream()
            _ = cached_entry^
            var stash_key = key.copy()
            var did_redial = False
            var bundle: _H1BufferedResult[Self.C.Stream]
            try:
                bundle = _drive_buffered_on_stream_bytes[RT, Self.C.Stream](
                    saved_req_bytes.copy(), cached_stream^, reactor,
                    max_body, is_head, req_timeout,
                )
            except e:
                # ⛔ THIS ARM MUST NOT BE `except e: _ = e` — CATCH EVERYTHING,
                # REDIAL, REPLAY. An
                # `EOF_MID_RESPONSE: chunked body unterminated` is by
                # construction a truncation AFTER a complete response head, so
                # the server HAS run the request, and replaying it executes the
                # caller's POST a second time.
                # `_h1_pooled_retry_is_safe` is Go's rule; term 1 (`reused`) is
                # held by this arm being on the cache-HIT branch only.
                var first_err = String(e)
                if not _h1_pooled_retry_is_safe(
                    first_err, method_code, saved_req_bytes
                ):
                    raise Error(first_err)
                # ⛔ THE ARM THAT MAKES THIS A LAZINESS AND NOT A
                # MOVE. A dead pooled conn means a REAL dial, which
                # needs a REAL address — the one the reuse attempt
                # above deliberately did not compute. A single resolve
                # below the probe would leave
                # exactly this arm naming a value its path never
                # computed.
                # ⚠ THE DIAL IS INSIDE THE INNER `try` ON PURPOSE: a connect
                # that itself fails must not erase the POOLED connection's
                # error, which is the one that says WHY the pool went stale.
                try:
                    var ip_be_dial1 = self._resolve_dial_ip_be(host_str, port)
                    var retry_stream = connector.connect[RT](
                        reactor=reactor, ip_be=ip_be_dial1, port=port,
                    )
                    self._note_h1_dial()
                    bundle = _drive_buffered_on_stream_bytes[
                        RT, Self.C.Stream
                    ](
                        saved_req_bytes.copy(), retry_stream^, reactor,
                        max_body, is_head, req_timeout,
                    )
                    did_redial = True
                except redial_err:
                    raise _h1_retry_gave_up(first_err, String(redial_err))
            # ★ THE STALE 408, same rule and same reason as the `send_buffered`
            # arm (Go issue 32310 — see HTTP_STATUS_REQUEST_TIMEOUT). The body
            # is already serialized into `saved_req_bytes` on this path, so the
            # `replayable()` term the other arm carries is satisfied by
            # construction here.
            if (
                not did_redial
                and Int(bundle.response.status) == HTTP_STATUS_REQUEST_TIMEOUT
            ):
                var ip_be_408 = self._resolve_dial_ip_be(host_str, port)
                var stream_408 = connector.connect[RT](
                    reactor=reactor, ip_be=ip_be_408, port=port,
                )
                self._note_h1_dial()
                bundle = _drive_buffered_on_stream_bytes[RT, Self.C.Stream](
                    saved_req_bytes.copy(), stream_408^, reactor,
                    max_body, is_head, req_timeout,
                )
            var resp_out = ClientResponse[BufferedResponseBody](
                BufferedResponseBody.from_bytes(List[UInt8]())
            )
            swap(resp_out, bundle.response)
            if bundle.reusable_stream.__bool__():
                var reused = bundle.reusable_stream.take()
                self._stash_h1_idle_stream(reused^, stash_key^)
            return resp_out^

        # Cache miss — dial fresh, so resolve now and only now. The
        # pool probe above returned empty; every path that returned a
        # response instead entered no resolve step at all.
        var ip_be_dial2 = self._resolve_dial_ip_be(host_str, port)
        var fresh_stream = connector.connect[RT](
            reactor=reactor, ip_be=ip_be_dial2, port=port,
        )
        # The `call_pooled` path dials its own sockets and stashes them on the
        # client's `_h1_idle_conn` slot, so the pool never learns of them by
        # itself — count the dial explicitly or `h1_pool_dials_total()` reads
        # ZERO for this entire entry point.
        self._note_h1_dial()
        var stash_key_dial = key.copy()
        var bundle_dial = _drive_buffered_on_stream_bytes[RT, Self.C.Stream](
            saved_req_bytes^, fresh_stream^, reactor, max_body, is_head,
            req_timeout,
        )
        var resp_dial = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(List[UInt8]())
        )
        swap(resp_dial, bundle_dial.response)
        if bundle_dial.reusable_stream.__bool__():
            var reused_dial = bundle_dial.reusable_stream.take()
            self._stash_h1_idle_stream(reused_dial^, stash_key_dial^)
        return resp_dial^

    # ----- Streaming shortcut: send() ------------------------------------
    # default. Returns the response with the body as a streaming
    # RecvRingBody conformer; caller drives via poll_frame / collect_body.

    def send[RT: Runtime, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """Send a request using the client's own configured connector.
        Returns a streaming ClientResponse — the body is a RecvRingBody
        conformer. default.

        Caller drives the body via:
          * `resp.body.poll_frame[RT](reactor, token)` — per-chunk pull.
          * `collect_body[RT, S](resp.body, reactor, token)` — slurp into
            one List[UInt8] (semantics equivalent to the default).

        For the slurp-on-send / HttpService.call semantic, use
        `send_buffered` instead.
        """
        var max_body = self._config.max_response_body_bytes
        var req_timeout = self._budget_for(req)
        var body = req.body.take()
        return _run_one_request_streaming[RT, Self.C, B](
            req^, body^,
            self._connector, reactor, max_body, req_timeout,
        )

    def send_grpc_pooled[RT: Runtime, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """The
        h2-multiplex-pooled streaming send for gRPC.

        gRPC over HTTP/2 can multiplex N concurrent RPC streams on ONE
        connection (RFC 9113 §5.1). Today the gRPC client funnels every RPC
        through `send` → `_run_one_request_streaming` → `connector.connect`
        (one fresh socket + TLS handshake per RPC). This entry routes
        https+h2 RPCs through the `H2ClientPool` checkout → drive → release
        dance instead, so N RPCs to the same authority SHARE one fd — a latency win
        for in-datacenter gRPC paths.

        Behavioral contract (the A/B-safety guarantee for the gRPC layer):
        the returned ClientResponse[RecvRingBody] yields EXACTLY the same
        status / headers / body bytes the fresh-dial `send` produced. The
        body is a stream-less RecvRingBody pre-loaded with the h2-drained
        response bytes — `poll_frame` emits one Data frame + End, identical
        to the buffered conformer the gRPC drain loop already handles. So a
        gRPC caller that switches from `send` to `send_grpc_pooled` observes
        no change in response bytes or error mapping.

        Routing:
          * https + ALPN h2  → pool multiplex (the new path).
          * https + ALPN h1  → fall back to fresh-dial streaming `send`
            (byte-identical to today; h1-over-TLS pooling is out of scope).
          * plaintext http   → fall back to fresh-dial streaming `send`
            (h2c is not negotiated here; cleartext gRPC is not the GCP
            target).

        AT_CAPACITY: the bucket can serve `max_conns_per_host *
        max_concurrent_streams_peer` concurrent streams to one authority
        (defaults 32 * 100 = 3200) before saturation. Beyond that, this
        method AWAITS a freed stream slot via `H2PendingCheckout.await_slot`
        (driven by `release_stream_slot`) rather than raising — so the
        shared gRPC send path never spuriously fails a caller under burst.
        """
        var is_https = req.url.is_https()
        # Scheme/connector check UP FRONT, before any dial: a plaintext
        # connector must never reach the https branch (and a connector that
        # merely REPORTS NEGOTIATED_HTTP_2 must not skip the check).
        _scheme_check_or_raise[Self.C](is_https, req.url.is_http(), self._connector)
        if not is_https:
            # Plaintext / non-h2 → identical to the fresh-dial streaming
            # path (no behavioral change for non-h2 gRPC callers). A caller
            # that KNOWS the plaintext endpoint speaks h2c (cleartext HTTP/2 —
            # e.g. a local Cloud Tasks emulator) must opt in explicitly via
            # `send_grpc_pooled_h2c`; the default
            # plaintext path stays h1 so existing plaintext-h1 gRPC callers
            # (the broker, the scripted-transport tests) are unaffected.
            return self.send[RT, B](req^, reactor)

        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        # ★ PER-REQUEST SNI — the host, not just the address. COSTS NO
        # HANDSHAKE *AND NO RESOLVE*: this writes one field, every pooled-reuse
        # path below returns without reaching `connect` at all, and
        # without entering the resolve step either — the dial
        # address is resolved AT the dial points (`_resolve_dial_ip_be`), never
        # here.
        # ⛔ DO NOT HOIST A RESOLVE BACK ABOVE THE POOL PROBE. Until that date
        # one sat on the line above this comment, and the comment's true claim
        # about the HANDSHAKE read as reassurance about it: a request that
        # reused a warm connection still paid a blocking, uncancellable
        # `getaddrinfo` (the one unbounded phase of a dial). Falsifier:
        # `test_dial_resolve_is_lazy`. See `Connector.set_dial_host`.
        self._connector.set_dial_host(host_str.copy())
        var max_body = self._config.max_response_body_bytes
        # ★ THE AUTHORED PER-REQUEST BUDGET, READ ONCE FOR ALL THREE DRIVE ARMS
        # BELOW (FOUND / PENDING-resolved / freshly-dialed). As an H1-ONLY
        # bound (consumed only by `OutboundDriver.set_request_timeout_us`,
        # which NO h2 arm reaches) a caller that authored a deadline and then
        # spoke to an h2 peer (GCS gRPC is ALWAYS h2, see the ALPN fallback
        # comment below) would silently get the h2 driver's own 120s wall
        # instead, and a 20s budget would bound NOTHING.
        var req_timeout = self._budget_for(req)

        # --- Probe / await an h2 stream slot for this authority ---
        self.ensure_h2_pool()
        var probe_key = PoolKey.https_h2(
            String(host_str), port, VERIFY_PEER,
        )
        var pool_owned = self._h2_pool.take()
        var outcome = pool_owned[].try_checkout_or_pending(probe_key^)

        if outcome.outcome == H2_OUTCOME_FOUND:
            var found = outcome.found.take()
            return self._drive_grpc_pooled_found[RT, B](
                pool_owned^, found.bucket_idx, found.conn_idx,
                req^, reactor, max_body, req_timeout,
            )
        elif outcome.outcome == H2_OUTCOME_PENDING:
            # Bucket saturated — park until a stream slot frees, then drive
            # on the resolved conn. release_stream_slot (fired at the end of
            # any in-flight RPC's drive) wakes us.
            var pending = outcome.pending.take()
            var slot = pending.await_slot()
            return self._drive_grpc_pooled_found[RT, B](
                pool_owned^, slot.bucket_idx, slot.conn_idx,
                req^, reactor, max_body, req_timeout,
            )

        # NEEDS_DIAL — re-stash the pool, dial fresh, check ALPN.
        self._h2_pool = Optional[
            OwnedPointer[H2ClientPool[Self.C.Stream]]
        ](pool_owned^)
        # Resolve ONLY here: this IS the dial. Every
        # pooled-reuse return above leaves without entering
        # the (unbounded, uncancellable) resolve step.
        var ip_be_dial = self._resolve_dial_ip_be(host_str, port)
        var stream = self._connector.connect[RT](
            reactor=reactor, ip_be=ip_be_dial, port=port,
        )
        var alpn = stream.negotiated_protocol()
        if Int(alpn) != Int(NEGOTIATED_HTTP_2):
            # Server did not negotiate h2 (does not happen for GCS, which
            # always speaks h2). Drop the probe stream + fall back to the
            # fresh-dial streaming path — byte-identical to `send`. The
            # extra dial is acceptable on this never-fires-for-GCS edge.
            _ = stream^
            return self.send[RT, B](req^, reactor)

        # h2 negotiated — register the conn + drive the first stream.
        var insert_key = PoolKey.https_h2(
            String(host_str), port, VERIFY_PEER,
        )
        var pool_owned2 = self._h2_pool.take()
        var client_conn = ClientConn[Self.C.Stream].new(
            stream^, insert_key.copy(), 0,
        )
        var h2_state = H2ClientConnectionState()
        queue_client_preface_and_settings(h2_state)
        var ins = pool_owned2[].insert_dialed_h2(
            insert_key^, client_conn^, h2_state^,
        )
        return self._drive_grpc_pooled_found[RT, B](
            pool_owned2^, ins.bucket_idx, ins.conn_idx,
            req^, reactor, max_body, req_timeout,
        )

    def _drive_grpc_pooled_found[RT: Runtime, B: RequestBody](
        mut self,
        var pool_owned: OwnedPointer[H2ClientPool[Self.C.Stream]],
        b_idx: Int,
        c_idx: Int,
        var req: ClientRequest[B],
        mut reactor: Reactor[RT.Sink],
        max_body: Int,
        request_timeout_us: Int,
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """Drive one gRPC request on the
        pooled conn at (b_idx, c_idx), then re-stash the pool into
        `self._h2_pool` and return the streaming response. Factored out so
        the FOUND / PENDING-resolved / freshly-dialed paths share one drive
        and re-stash body."""
        var body = req.body.take()
        var result = _drive_one_h2_streaming_on_pool[RT, Self.C, B](
            pool_owned^, b_idx, c_idx, req^, body^, reactor, max_body,
            request_timeout_us,
        )
        # swap-extract the (response, pool) pair (Mojo 1.0.0b1 rejects
        # `result.field^` partial-moves — the pointer rules).
        var out_response = ClientResponse[RecvRingBody[Self.C.Stream]](
            RecvRingBody[Self.C.Stream].from_buffered_bytes(List[UInt8]())
        )
        var out_pool = OwnedPointer[H2ClientPool[Self.C.Stream]](
            H2ClientPool[Self.C.Stream].with_defaults()
        )
        swap(out_response, result.response)
        swap(out_pool, result.pool_owned)
        self._h2_pool = Optional[
            OwnedPointer[H2ClientPool[Self.C.Stream]]
        ](out_pool^)
        return out_response^

    def send_grpc_pooled_h2c[RT: Runtime, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """Drive ONE gRPC request over a PLAINTEXT
        (cleartext) HTTP/2 connection — h2c PRIOR KNOWLEDGE.

        OPT-IN sibling of `send_grpc_pooled`: a caller invokes THIS method only
        when it KNOWS the (http://) endpoint speaks h2c — `send_grpc_pooled`'s
        own plaintext branch stays h1 (so existing plaintext-h1 gRPC callers are
        unaffected).

        h2c prior knowledge (RFC 9113 §3.3 / §3.4): the client KNOWS the server
        speaks HTTP/2 cleartext, so it skips ALPN + the HTTP/1.1 Upgrade dance
        and writes the HTTP/2 connection preface (24-byte PRI) + SETTINGS
        directly. This is exactly the wire the `aertje/cloud-tasks-emulator`
        (a `grpc.insecure_channel` server) expects — and exactly what
        `queue_client_preface_and_settings` + `_drive_one_h2_streaming_on_pool`
        already emit (the h2 codec is TLS-agnostic; it emits `:scheme: http`
        for an http:// URL).

        The ONLY difference vs the https+h2 dial path in `send_grpc_pooled` is:
          * the pool bucket key is `PoolKey.http_h2` (scheme=SCHEME_HTTP) — so
            plaintext h2c conns never alias TLS h2 conns, and
          * there is NO post-dial ALPN check (prior knowledge ASSUMES h2 —
            a plaintext `KernelTcpConnector` always reports NEGOTIATED_HTTP_1_1,
            which is meaningless here since no ALPN happened).

        Returns the SAME streaming RecvRingBody response shape the https+h2
        path returns, so the gRPC drain loop slots in unchanged.
        """
        # h2c prior knowledge is PLAINTEXT-only: refuse https:// on a
        # plaintext connector (cleartext h2c frames + Authorization header)
        # and http:// on a TLS connector, before set_dial_host / any dial.
        _scheme_check_or_raise[Self.C](
            req.url.is_https(), req.url.is_http(), self._connector
        )
        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        var max_body = self._config.max_response_body_bytes
        # The authored per-request budget — same read, same reason, as the
        # https+h2 sibling above. h2c is the SAME drive loop with a different
        # bucket key; an authored deadline that binds on one and not the other
        # would re-open the asymmetry one scheme lower down.
        var req_timeout = self._budget_for(req)

        # Probe / await an h2c stream slot for this authority (plaintext bucket).
        self.ensure_h2_pool()
        var probe_key = PoolKey.http_h2(String(host_str), port)
        var pool_owned = self._h2_pool.take()
        var outcome = pool_owned[].try_checkout_or_pending(probe_key^)

        if outcome.outcome == H2_OUTCOME_FOUND:
            var found = outcome.found.take()
            return self._drive_grpc_pooled_found[RT, B](
                pool_owned^, found.bucket_idx, found.conn_idx,
                req^, reactor, max_body, req_timeout,
            )
        elif outcome.outcome == H2_OUTCOME_PENDING:
            var pending = outcome.pending.take()
            var slot = pending.await_slot()
            return self._drive_grpc_pooled_found[RT, B](
                pool_owned^, slot.bucket_idx, slot.conn_idx,
                req^, reactor, max_body, req_timeout,
            )

        # NEEDS_DIAL — re-stash the pool, dial the plaintext stream fresh, and
        # register it as an h2 conn WITHOUT an ALPN check (prior knowledge).
        self._h2_pool = Optional[
            OwnedPointer[H2ClientPool[Self.C.Stream]]
        ](pool_owned^)
        # ★ PER-REQUEST SNI — the host, not just the address. See
        # `Connector.set_dial_host`.
        self._connector.set_dial_host(host_str.copy())
        # Resolve ONLY here: this is a dial. The resolve sits adjacent to
        # its `connect` so that the invariant is readable in one glance (and
        # assertable: `test_dial_resolve_is_lazy` gate 7 reads exactly that).
        var ip_be = self._resolve_dial_ip_be(host_str, port)
        var stream = self._connector.connect[RT](
            reactor=reactor, ip_be=ip_be, port=port,
        )
        var insert_key = PoolKey.http_h2(String(host_str), port)
        var pool_owned2 = self._h2_pool.take()
        var client_conn = ClientConn[Self.C.Stream].new(
            stream^, insert_key.copy(), 0,
        )
        var h2_state = H2ClientConnectionState()
        queue_client_preface_and_settings(h2_state)
        var ins = pool_owned2[].insert_dialed_h2(
            insert_key^, client_conn^, h2_state^,
        )
        return self._drive_grpc_pooled_found[RT, B](
            pool_owned2^, ins.bucket_idx, ins.conn_idx,
            req^, reactor, max_body, req_timeout,
        )

    def get_range[RT: Runtime](
        mut self,
        var url: Url,
        range_start: Int,
        range_end_opt: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """Send a GET request with a `Range: bytes=N-M` (or
        `Range: bytes=N-`) header. The server SHOULD respond with
        `206 Partial Content` carrying only the requested byte range;
        if it returns `200 OK` instead (RFC 7233 §3.1 — servers MAY
        ignore Range), this method raises HttpError[RANGE_NOT_HONORED].

        Arguments:
          url             — the resource to GET.
          range_start     — first byte (inclusive), zero-based.
          range_end_opt   — last byte (inclusive). Pass -1 for an
                            open-ended `bytes=N-` request (read from
                            range_start to end-of-resource).

        Caller drives the response body via `resp.body.poll_frame` or
        `collect_body` exactly as for normal `send`.
        """
        # Build the Range header value.
        var range_value = String("bytes=") + String(range_start) + String("-")
        if range_end_opt >= 0:
            range_value = range_value + String(range_end_opt)
        var hdrs = HeaderMap()
        hdrs.append(String("Range"), range_value^)
        var req = build_get_request(url^, hdrs^)
        var max_body = self._config.max_response_body_bytes
        # Composed like every other entry even though the request is built
        # RIGHT HERE and therefore provably carries 0: a reader who later
        # threads a caller-supplied request through this method must not have
        # to notice that this one line was the exception.
        var req_timeout = self._budget_for(req)
        var body = req.body.take()
        var resp = _run_one_request_streaming[RT, Self.C, EmptyBody](
            req^, body^,
            self._connector, reactor, max_body, req_timeout,
        )
        # surface 200-instead-of-206 as RANGE_NOT_HONORED.
        # 206 = OK partial; any other 2xx (typically 200) means the
        # server ignored Range.
        if Int(resp.status) != 206:
            raise Error(
                "HttpError[RANGE_NOT_HONORED]: server returned status="
                + String(Int(resp.status))
                + " (expected 206 Partial Content)"
            )
        return resp^

    def send_streaming_with_connector[RT: Runtime, C2: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C2,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[C2.Stream]]:
        """Issue a streaming
        request using an EXPLICIT per-call connector (not `self._connector`),
        returning the head-read response with the body deferred to
        `poll_frame`. Identical to `send`, except the connector is the
        caller's (so the S3 prefetch path can dial each of its K in-flight
        GETs on the per-call connector that `S3Store.get_range` already
        threads through). The connect + head-read happen synchronously
        inside this call; only the BODY transfer is deferred — which is
        exactly what the K-stream round-robin drain overlaps.

        Note the stream type is `C2.Stream` (the passed connector's stream),
        matching `_run_one_request_streaming[RT, C2, B]`.
        """
        var max_body = self._config.max_response_body_bytes
        var req_timeout = self._budget_for(req)
        var body = req.body.take()
        return _run_one_request_streaming[RT, C2, B](
            req^, body^, connector, reactor, max_body, req_timeout,
        )

    def send_streaming_pooled_get[RT: Runtime](
        mut self,
        var req: ClientRequest[EmptyBody],
        mut connector: Self.C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """The keepalive-aware
        streaming GET (EmptyBody — GET/HEAD have no request payload). CHECK
        OUT an idle keepalive stream for this request's origin from
        `_streaming_idle_pool`; on hit, drive the request on the reused stream
        (NO `connector.connect` — no fresh socket/connect/epoll). On miss,
        dial fresh via `connector`. The caller reclaims the drained stream via
        `reclaim_streaming_stream` after draining the body, IFF the response
        was `connection_close=False`.

        robustness (don't regress the closed-keepalive race): a reused
        keepalive conn the server silently closed surfaces as a transport
        error on the head-read; this method CATCHES it and transparently
        retries with a FRESH dial (idempotent ranged GET — safe to retry).
        The retry is clean because the body is `EmptyBody` (zero-byte,
        trivially replayable via `EmptyBody.new()`) and the SIGNED wire bytes
        (List[UInt8], already carrying the serialized HEAD + signature) are
        captured BEFORE the reuse attempt consumes `req`.

        Restricted to `Self.C` (the pool's stream type) — the S3 prefetch
        path's per-call connector IS the client's own `C` (SigV4SignedTransport
        [C] wraps HttpClient[C]); keying the pool on `Self.C.Stream` is exact.
        """
        var max_body = self._config.max_response_body_bytes
        # Capture everything the request-drive + the dial-fresh retry need
        # BEFORE `req` is consumed: the signed wire bytes (Copyable), the
        # HEAD flag, and the dial coords (host/port/ip_be).
        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        var is_http = req.url.is_http()
        # Refuse a scheme/connector mismatch BEFORE any dial or write: an
        # `https://` URL on a plaintext connector would otherwise go out in
        # cleartext, credentials included.
        _scheme_check_or_raise[Self.C](req.url.is_https(), is_http, connector)
        # ★ PER-REQUEST SNI — the host, not just the address. COSTS NO
        # HANDSHAKE *AND NO RESOLVE*: this writes one field, every pooled-reuse
        # path below returns without reaching `connect` at all, and
        # without entering the resolve step either — the dial
        # address is resolved AT the dial points (`_resolve_dial_ip_be`), never
        # here.
        # ⛔ DO NOT HOIST A RESOLVE BACK ABOVE THE POOL PROBE. Until that date
        # one sat on the line above this comment, and the comment's true claim
        # about the HANDSHAKE read as reassurance about it: a request that
        # reused a warm connection still paid a blocking, uncancellable
        # `getaddrinfo` (the one unbounded phase of a dial). Falsifier:
        # `test_dial_resolve_is_lazy`. See `Connector.set_dial_host`.
        connector.set_dial_host(host_str.copy())
        var is_head = Int(req.method.code) == Int(HTTP_METHOD_HEAD)
        var method_code = req.method.code
        var saved_req_bytes = req.request_bytes.copy()
        _ = req^

        var key = pool_key_for_origin(host_str, port, is_http)

        var idle = self._take_streaming_idle_conn_for(key)
        if idle.__bool__():
            var reused = idle.take()
            try:
                return _drive_streaming_get_on_stream_bytes[
                    RT, Self.C.Stream
                ](
                    saved_req_bytes.copy(), reused^, reactor,
                    max_body, is_head,
                )
            except e:
                # Same rule, same reason as the two buffered arms: an `except
                # e: _ = e` here replayed anything that raised. This arm's
                # error window is narrower (the body is streamed to the CALLER,
                # so a mid-body truncation surfaces later out of `poll_frame`,
                # not here) — but a malformed head, an oversize head and a
                # deadline all still land in it, and none of those is a stale
                # connection to redial around.
                var first_err = String(e)
                if not _h1_pooled_retry_is_safe(
                    first_err, method_code, saved_req_bytes
                ):
                    raise Error(first_err)
                # Resolve ONLY here: this IS the dial. Every
                # pooled-reuse return above leaves without entering
                # the (unbounded, uncancellable) resolve step.
                try:
                    var ip_be_dial1 = self._resolve_dial_ip_be(host_str, port)
                    var retry_stream = connector.connect[RT](
                        reactor=reactor, ip_be=ip_be_dial1, port=port,
                    )
                    self._note_h1_dial()
                    return _drive_streaming_get_on_stream_bytes[
                        RT, Self.C.Stream
                    ](
                        saved_req_bytes.copy(), retry_stream^, reactor,
                        max_body, is_head,
                    )
                except redial_err:
                    raise _h1_retry_gave_up(first_err, String(redial_err))

        # Cache miss — dial fresh (identical to the non-pooled streaming path).
        # Resolve ONLY here: this IS the dial. Every
        # pooled-reuse return above leaves without entering
        # the (unbounded, uncancellable) resolve step.
        var ip_be_dial2 = self._resolve_dial_ip_be(host_str, port)
        var fresh_stream = connector.connect[RT](
            reactor=reactor, ip_be=ip_be_dial2, port=port,
        )
        return _drive_streaming_get_on_stream_bytes[RT, Self.C.Stream](
            saved_req_bytes^, fresh_stream^, reactor, max_body, is_head,
        )

    def issue_streaming_get_nonblocking[RT: Runtime](
        mut self,
        var req: ClientRequest[EmptyBody],
        mut connector: Self.C,
        mut reactor: Reactor[RT.Sink],
        force_fresh_dial: Bool = False,
    ) raises -> PendingStreamingGet[Self.C.Stream]:
        """Issue a streaming GET
        WITHOUT blocking on the response head. CHECK OUT an idle keepalive
        stream for this origin or dial fresh, ARM an
        OutboundDriver for the non-blocking send+head path, and return a
        `PendingStreamingGet` immediately. The head is NOT read here — the
        caller drives `pending.poll[RT](reactor)` round-robin across the K
        in-flight GETs, so the K dial+send+head RTTs OVERLAP rather than
        serialize (the ceiling).

        Unlike `send_streaming_pooled_get` (which calls
        `_drive_streaming_get_on_stream_bytes` → blocks on the head inside
        `run_with_body`), this returns BEFORE any byte of the response head
        is read. The actual connect(2) on a fresh dial still completes
        inside `connector.connect` (eager on loopback; for cross-host the
        connect overlap is a follow-on lever), but the head-read
        — the bottleneck — is fully deferred.

        keepalive robustness: the dead-conn-server-closed race surfaces
        as an OUTBOUND_STEP_ERROR during `poll` (not here). The s3_fs caller
        handles it by re-issuing the same range with `force_fresh_dial=True`
        (idempotent ranged GET → safe to replay). `force_fresh_dial=True`
        skips the keepalive pool and dials a guaranteed-fresh socket.

        EmptyBody only (GET has no payload). Per-pthread: the pool is
        per-HttpClient (per-worker); the connector dials on the caller's
        single-thread-access stream.
        """
        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        var is_http = req.url.is_http()
        # Refuse a scheme/connector mismatch BEFORE any dial or write: an
        # `https://` URL on a plaintext connector would otherwise go out in
        # cleartext, credentials included.
        _scheme_check_or_raise[Self.C](req.url.is_https(), is_http, connector)
        # ★ PER-REQUEST SNI — the host, not just the address. COSTS NO
        # HANDSHAKE *AND NO RESOLVE*: this writes one field, every pooled-reuse
        # path below returns without reaching `connect` at all, and
        # without entering the resolve step either — the dial
        # address is resolved AT the dial points (`_resolve_dial_ip_be`), never
        # here.
        # ⛔ DO NOT HOIST A RESOLVE BACK ABOVE THE POOL PROBE. Until that date
        # one sat on the line above this comment, and the comment's true claim
        # about the HANDSHAKE read as reassurance about it: a request that
        # reused a warm connection still paid a blocking, uncancellable
        # `getaddrinfo` (the one unbounded phase of a dial). Falsifier:
        # `test_dial_resolve_is_lazy`. See `Connector.set_dial_host`.
        connector.set_dial_host(host_str.copy())
        var is_head = Int(req.method.code) == Int(HTTP_METHOD_HEAD)
        var max_body = self._config.max_response_body_bytes
        var saved_req_bytes = req.request_bytes.copy()
        _ = req^
        var key = pool_key_for_origin(host_str, port, is_http)

        # Pick the stream: a reused keepalive conn (unless forced fresh) or a
        # fresh dial. NB: we do NOT drive any head-read here — the
        # PendingStreamingGet owns the stream + the driver and steps later.
        var stream: Self.C.Stream
        if force_fresh_dial:
            # Resolve ONLY here: this IS the dial. Every
            # pooled-reuse return above leaves without entering
            # the (unbounded, uncancellable) resolve step.
            var ip_be_dial1 = self._resolve_dial_ip_be(host_str, port)
            stream = connector.connect[RT](
                reactor=reactor, ip_be=ip_be_dial1, port=port,
            )
        else:
            var idle = self._take_streaming_idle_conn_for(key)
            if idle.__bool__():
                var reused = idle.take()
                stream = reused^
            else:
                # Resolve ONLY here: this IS the dial. Every
                # pooled-reuse return above leaves without entering
                # the (unbounded, uncancellable) resolve step.
                var ip_be_dial2 = self._resolve_dial_ip_be(host_str, port)
                stream = connector.connect[RT](
                    reactor=reactor, ip_be=ip_be_dial2, port=port,
                )

        var driver = OutboundDriver.new(saved_req_bytes^)
        driver.set_max_response_body_bytes(max_body)
        driver.set_is_head_request(is_head)
        driver.begin_send_head_nonblocking()
        return PendingStreamingGet[Self.C.Stream](
            driver^, stream^, key.copy(),
        )

    def issue_streaming_put_nonblocking[RT: Runtime](
        mut self,
        var req: ClientRequest[BytesBody],
        mut connector: Self.C,
        mut reactor: Reactor[RT.Sink],
        force_fresh_dial: Bool = False,
    ) raises -> PendingStreamingGet[Self.C.Stream]:
        """The PUT analog of
        `issue_streaming_get_nonblocking` — issue a streaming PUT (BytesBody
        request payload, e.g. an S3 multipart part) WITHOUT blocking on the
        response head. CHECK OUT an idle keepalive stream for this origin
        (the keepalive pool, shared with the GET path — PUT and GET share the
        host:port PoolKey) or dial fresh, ARM an OutboundDriver for the
        non-blocking send+head path, and return a `PendingStreamingGet`
        immediately. The caller drives `pending.poll[RT](reactor)` round-robin
        across the K in-flight PUTs, so the K dial+send+head RTTs OVERLAP
        rather than serialize.

        Why this reuses the GET non-blocking stepper unchanged: the PUT's
        request body is PRE-SERIALIZED into `req.request_bytes` (head + body
        concatenated — see `ClientRequest.request_bytes` in service.mojo). A
        SigV4 signing layer re-serializes request_bytes
        with the body re-appended and the correct signed Content-Length,
        so by the time this method captures
        `req.request_bytes`, the buffer carries the full signed HEAD+BODY.
        The non-blocking stepper (`step_send_head_nonblocking`) drains the
        ENTIRE `_req_bytes` buffer in its WRITING_REQUEST_HEADERS phase
        before reading the head (`_write_cursor >= _req_bytes.__len__()` in
        state_machine.mojo), so it sends the body too —
        it is body-agnostic by construction. The response (the part's ETag
        header + an empty/short body) flows through the same
        `PendingStreamingGet.finish()` → `ClientResponse[RecvRingBody]` shape.

        keepalive robustness: a dead reused keepalive conn surfaces as an
        OUTBOUND_STEP_ERROR during `poll` (not here). The s3_fs write caller
        re-issues the same part with `force_fresh_dial=True`. Idempotency:
        S3 UploadPart is idempotent within an UploadId — replaying the same
        (part_number, data) tuple is safe (the new ETag replaces the prior),
        and the signed wire bytes (request_bytes) carry the full body so the
        replay is byte-identical.

        Per-pthread: the pool is per-HttpClient (per-worker); the connector
        dials on the caller's single-thread-access stream.
        """
        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        var is_http = req.url.is_http()
        # Refuse a scheme/connector mismatch BEFORE any dial or write: an
        # `https://` URL on a plaintext connector would otherwise go out in
        # cleartext, credentials included.
        _scheme_check_or_raise[Self.C](req.url.is_https(), is_http, connector)
        # ★ PER-REQUEST SNI — the host, not just the address. COSTS NO
        # HANDSHAKE *AND NO RESOLVE*: this writes one field, every pooled-reuse
        # path below returns without reaching `connect` at all, and
        # without entering the resolve step either — the dial
        # address is resolved AT the dial points (`_resolve_dial_ip_be`), never
        # here.
        # ⛔ DO NOT HOIST A RESOLVE BACK ABOVE THE POOL PROBE. Until that date
        # one sat on the line above this comment, and the comment's true claim
        # about the HANDSHAKE read as reassurance about it: a request that
        # reused a warm connection still paid a blocking, uncancellable
        # `getaddrinfo` (the one unbounded phase of a dial). Falsifier:
        # `test_dial_resolve_is_lazy`. See `Connector.set_dial_host`.
        connector.set_dial_host(host_str.copy())
        # A PUT is NOT a HEAD request — its response carries a (small) body
        # (the empty/short UploadPart 200 body); the ETag is a header.
        var is_head = False
        var max_body = self._config.max_response_body_bytes
        # request_bytes already carries the signed HEAD + BODY (see docstring).
        var saved_req_bytes = req.request_bytes.copy()
        _ = req^
        var key = pool_key_for_origin(host_str, port, is_http)

        var stream: Self.C.Stream
        if force_fresh_dial:
            # Resolve ONLY here: this IS the dial. Every
            # pooled-reuse return above leaves without entering
            # the (unbounded, uncancellable) resolve step.
            var ip_be_dial1 = self._resolve_dial_ip_be(host_str, port)
            stream = connector.connect[RT](
                reactor=reactor, ip_be=ip_be_dial1, port=port,
            )
        else:
            var idle = self._take_streaming_idle_conn_for(key)
            if idle.__bool__():
                var reused = idle.take()
                stream = reused^
            else:
                # Resolve ONLY here: this IS the dial. Every
                # pooled-reuse return above leaves without entering
                # the (unbounded, uncancellable) resolve step.
                var ip_be_dial2 = self._resolve_dial_ip_be(host_str, port)
                stream = connector.connect[RT](
                    reactor=reactor, ip_be=ip_be_dial2, port=port,
                )

        var driver = OutboundDriver.new(saved_req_bytes^)
        driver.set_max_response_body_bytes(max_body)
        driver.set_is_head_request(is_head)
        driver.begin_send_head_nonblocking()
        return PendingStreamingGet[Self.C.Stream](
            driver^, stream^, key.copy(),
        )

    def reclaim_streaming_stream[RT: Runtime](
        mut self,
        var resp: ClientResponse[RecvRingBody[Self.C.Stream]],
        var key: PoolKey,
    ):
        """After the caller has drained the
        body (poll_frame to End), reclaim the underlying keepalive stream and
        return it to the idle pool IFF the response indicated keepalive
        (`connection_close == False`). On `connection_close == True` (or if
        the body isn't fully consumed / stream already taken), the stream
        drops with `resp` (closing the fd) — the-safe default.

        Idempotent w.r.t. consuming `resp`: the response is moved in and
        dropped here regardless of the keepalive decision."""
        var keepalive = not resp.connection_close
        if keepalive and resp.body.is_done() and resp.body.has_stream():
            try:
                var stream = resp.body.take_stream()
                self._stash_streaming_idle_stream(stream^, key^)
            except:
                # take_stream precondition failed — drop resp (closes fd).
                pass
        # resp drops here: if the stream was reclaimed, the body's
        # Optional<S> is None (no-op drop); else the stream drops (close).
        _ = resp^

    # =========================================================================
    # pool-aware dispatch helpers.
    # =========================================================================
    #
    # `_dispatch_pooled_buffered` is the production-wired analog of the
    # free function `_run_one_request_buffered_with_dispatch`. The
    # difference: this method has access to `self._h1_pool` /
    # `self._h2_pool` and can consult them BEFORE dialing.
    #
    # h2 wiring (load-bearing for fd-count=1 invariant):
    #   1. `try_checkout_or_pending(key=https_h2)` →
    #     - FOUND(b_idx, c_idx): reuse the pooled multiplex conn.
    #     - NEEDS_DIAL: dial fresh + insert_dialed_h2 → (b_idx, c_idx).
    #     - PENDING: v1 raises HTTP_ERROR_POOL_AT_CAPACITY; the
    #       full wake-await path is+ (requires reactor.poll cycle
    #       integration). The PENDING outcome only fires when
    #       max_conns_per_host AND every conn at max_concurrent_streams_peer
    #       — extremely rare for the default sizing of 32/100.
    #   2. Build request frames + drive via
    #      `pool.drive_request_on_pooled_conn[RT]` (which extracts both
    #      h2 + stream refs in one scope internally — see h2_pool.mojo
    #      `drive_request_on_pooled_conn`).
    #   3. Extract response from the h2 state for the awaited stream_id.
    #   4. release_stream_slot(b_idx, c_idx) — wakes any pending waiter
    #      whose key matches and whose conn now has stream-slot capacity.
    #
    # h1 wiring:
    #   * Consults the pool for `try_checkout`; if NEEDS_DIAL, calls
    #     `insert_dialed` so `dials_total` is bumped (hc03 diagnostic).
    #   * Does NOT yet checkin the conn after the response — the
    #     existing free-function dispatch (`_run_one_request_buffered`)
    #     still owns the stream-to-RecvRingBody-to-drop lifecycle.
    #   * Full h1 keepalive requires `RecvRingBody.take_stream()` to
    #     extract the stream back from the body after collect_body —
    #     that refactor is along with `OutboundDriver.run_with_body`
    #     accepting `mut stream: S` instead of `var stream: S`.
    #
    # Borrow-check pattern (the deferred concern):
    #   * `self._h2_pool` is `Optional[OwnedPointer[H2ClientPool[Self.C.Stream]]]`.
    #   * To call a method on the inner pool requires `mut` borrow; in
    #     a `mut self` method, simultaneous `mut self.foo` + `mut self.bar`
    #     borrows would normally collide. The pattern: `Optional.take()`
    #     MOVES the OwnedPointer OUT of the field; the borrow scope on
    #     `self._h2_pool` ends; subsequent work operates on the local
    #     `pool_owned`; at end, re-stash via `self._h2_pool = Optional(pool_owned^)`.
    #
    # This pattern is the workaround that
    # closes the borrow-check barrier without ArcPointer.

    def _dispatch_pooled_buffered[RT: Runtime, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        var body: B,
        mut reactor: Reactor[RT.Sink],
        max_body_bytes: Int,
    ) raises -> ClientResponse[BufferedResponseBody]:
        """Dial-or-checkout, drive, slurp.

        Pre-dial: scheme check.
        Dial: `connector.connect[RT]` produces a fresh stream.
        ALPN check: `stream.negotiated_protocol()` decides h1 vs h2.
        Pool consult:
          * h2 ALPN → store conn in `_h2_pool` if not yet pooled; drive
            via `pool.drive_request_on_pooled_conn`; release_stream_slot.
          * h1 ALPN → bump h1 pool dials_total via insert_dialed; drive
            via existing `_run_one_request_buffered_h1`; drop conn.
        """
        var is_https = req.url.is_https()
        var is_http = req.url.is_http()
        _scheme_check_or_raise[Self.C](is_https, is_http, self._connector)
        # ONE read for all FOUR arms below (h2-found, h2-dialed, h1-cached,
        # h1-dialed). Two of those four have already shipped a dropped
        # `request_timeout_us` argument — see the ⛔ blocks at the cached and
        # dialed h1 arms — so the value they forward is deliberately a single
        # named local rather than four independent reads.
        var req_timeout = self._budget_for(req)

        var host_str = req.url.host_copy()
        var port = req.url.effective_port()
        # ★ PER-REQUEST SNI — the host, not just the address. COSTS NO
        # HANDSHAKE *AND NO RESOLVE*: this writes one field, every pooled-reuse
        # path below returns without reaching `connect` at all, and
        # without entering the resolve step either — the dial
        # address is resolved AT the dial points (`_resolve_dial_ip_be`), never
        # here.
        # ⛔ DO NOT HOIST A RESOLVE BACK ABOVE THE POOL PROBE. Until that date
        # one sat on the line above this comment, and the comment's true claim
        # about the HANDSHAKE read as reassurance about it: a request that
        # reused a warm connection still paid a blocking, uncancellable
        # `getaddrinfo` (the one unbounded phase of a dial). Falsifier:
        # `test_dial_resolve_is_lazy`. See `Connector.set_dial_host`.
        self._connector.set_dial_host(host_str.copy())

        # for h2 multiplex, consult the pool BEFORE dialing.
        # If a conn for this origin already exists with stream-slot
        # capacity, reuse it (fd-count=1 invariant).
        #
        # Strategy: probe the h2 pool first. If FOUND, route through the
        # pooled h2 path. Else: dial, check ALPN, and route accordingly.
        if is_https:
            # Probe h2 pool for an existing conn first.
            self.ensure_h2_pool()
            var probe_key = PoolKey.https_h2(
                String(host_str), port, VERIFY_PEER,
            )
            var pool_owned = self._h2_pool.take()
            var probe_outcome = pool_owned[].try_checkout_or_pending(
                probe_key^
            )
            if probe_outcome.outcome == H2_OUTCOME_FOUND:
                var found = probe_outcome.found.take()
                var resp = _drive_one_h2_buffered_on_pool[RT, Self.C, B](
                    pool_owned^,
                    found.bucket_idx,
                    found.conn_idx,
                    req^, body^, reactor, max_body_bytes, req_timeout,
                )
                # Re-stash the pool + return the response. swap() each
                # field out of `resp` (Mojo 1.0.0b1 rejects `resp.field^`
                # partial-moves per the pointer rules — the
                # universal "var x = struct.field^ REJECTED" idiom).
                var out_response = ClientResponse[BufferedResponseBody](
                    BufferedResponseBody.from_bytes(List[UInt8]())
                )
                var out_pool = OwnedPointer[H2ClientPool[Self.C.Stream]](
                    H2ClientPool[Self.C.Stream].with_defaults()
                )
                swap(out_response, resp.response)
                swap(out_pool, resp.pool_owned)
                self._h2_pool = Optional[
                    OwnedPointer[H2ClientPool[Self.C.Stream]]
                ](out_pool^)
                return out_response^
            elif probe_outcome.outcome == H2_OUTCOME_PENDING:
                # Re-stash + raise; a production wake-await is not wired.
                self._h2_pool = Optional[
                    OwnedPointer[H2ClientPool[Self.C.Stream]]
                ](pool_owned^)
                raise Error(
                    "HttpError[POOL_AT_CAPACITY]: h2 multiplex bucket"
                    " saturated; wake-await is not implemented"
                )
            # NEEDS_DIAL — re-stash the pool empty and dial fresh below.
            # We need to put the pool back before the dial because the
            # dial may take a long time (real TCP). The pool is local,
            # not yet associated with any conn — safe to re-stash.
            self._h2_pool = Optional[
                OwnedPointer[H2ClientPool[Self.C.Stream]]
            ](pool_owned^)

        # for
        # plaintext http://, check the h1 idle-conn cache BEFORE
        # dialing. If a cached stream exists for THIS (host, port),
        # skip the dial entirely + skip ALPN (cached conn is h1 by
        # construction — h2 lives in _h2_pool's multiplex bucket).
        # The cache lookup also drops a stale conn from a different
        # origin (the _take_h1_idle_conn_for key-mismatch path).
        if is_http:
            var h1_cache_key = PoolKey.http(String(host_str), port)
            var cached_opt = self._take_h1_idle_conn_for(h1_cache_key^)
            if cached_opt.__bool__():
                # CACHE HIT — extract the stream from the cached entry,
                # ensure scratch, run the request, and stash the stream
                # back if keepalive holds.
                var cached_entry = cached_opt.take()
                var cached_stream = cached_entry[].take_stream()
                # Cached entry is now empty; drop it.
                _ = cached_entry^
                self.ensure_read_head_scratch()
                ref scratch_arr_cached = self._read_head_scratch.value()[]
                var stash_key = PoolKey.http(String(host_str), port)
                # ⛔ THE TRAILING ARGUMENT IS LOAD-BEARING. Omitting
                # `request_timeout_us` here does not fail to compile — it
                # defaults to 0, which the helper reads as "use the generous
                # 600 s default" and the caller's explicitly configured budget
                # is silently discarded — an 8 s budget becomes a ~300 s block
                # against a wedged peer. Falsifier:
                # `test_client_send_buffered_honors_request_timeout.mojo`.
                # ★ THE STALE-CONN RECOVERY ARM. Before this,
                # the cache-HIT branch drove the reused stream with NO
                # try/except at all, so the canonical benign event — the server
                # reaped an idle keepalive conn, and the next request on it gets
                # a FIN before a single response byte — reached the CALLER as
                # `HttpError[RETRYABLE_TRANSPORT]: peer closed before any
                # response byte`. `call_pooled` recovered from the identical
                # event, so whether a reaped connection was survivable depended
                # on which method the caller happened to pick. Go recovers on
                # every path because the retry lives in `persistConn.roundTrip`,
                # BELOW the entry points rather than in one of them.
                #
                # Everything the one permitted redial needs is captured HERE,
                # before `req^`/`body^` are consumed by the drive.
                var retry_bytes = req.request_bytes.copy()
                var retry_method = req.method.code
                var retry_is_head = Int(req.method.code) == Int(
                    HTTP_METHOD_HEAD
                )
                # ⛔ TERM 0, WHICH IS OURS AND NOT GO'S. The replay re-drives
                # from `request_bytes` with an EmptyBody, which is byte-
                # identical ONLY for a body already drained into that blob
                # (`build_request_with_body` does exactly that for EmptyBody /
                # BytesBody, both `replayable()`). A STREAMING body is drained
                # ON THE WIRE and reports `replayable() == False`; replaying its
                # head alone would send a Content-Length promising N bytes and
                # then zero, wedging the server on a read that never completes.
                # So a non-replayable body gets no retry — it surfaces, exactly
                # as it did before this arm existed.
                var body_is_replayable = body.replayable()
                var did_redial = False
                var bundle_cached: _H1BufferedResult[Self.C.Stream]
                try:
                    bundle_cached = _run_one_request_buffered_h1[
                        RT, Self.C.Stream, B
                    ](
                        req^, body^, cached_stream^, reactor, max_body_bytes,
                        Span[UInt8](scratch_arr_cached),
                        req_timeout,
                    )
                except e:
                    var first_err = String(e)
                    if not (
                        body_is_replayable
                        and _h1_pooled_retry_is_safe(
                            first_err, retry_method, retry_bytes
                        )
                    ):
                        raise Error(first_err)
                    try:
                        var ip_be = self._resolve_dial_ip_be(host_str, port)
                        var retry_stream = self._connector.connect[RT](
                            reactor=reactor, ip_be=ip_be, port=port,
                        )
                        self._note_h1_dial()
                        bundle_cached = _drive_buffered_on_stream_bytes[
                            RT, Self.C.Stream
                        ](
                            retry_bytes.copy(), retry_stream^, reactor,
                            max_body_bytes, retry_is_head,
                            req_timeout,
                        )
                        did_redial = True
                    except redial_err:
                        raise _h1_retry_gave_up(
                            first_err, String(redial_err)
                        )
                # ★ THE STALE 408 (Go issue 32310 — see
                # HTTP_STATUS_REQUEST_TIMEOUT). This response came off a
                # connection the pool had been holding IDLE, so a 408 on it is
                # far more likely to be the server's idle-timeout notice,
                # written before this request existed, than an answer to it.
                # Discard it and re-issue ONCE on a connection we dialled —
                # where a 408 can only be about this request, and is returned
                # untouched. `did_redial` keeps the budget at one dial: if the
                # bytes already came from a fresh dial there is no earlier
                # message they could be.
                if (
                    not did_redial
                    and body_is_replayable
                    and Int(bundle_cached.response.status)
                    == HTTP_STATUS_REQUEST_TIMEOUT
                ):
                    var ip_be_408 = self._resolve_dial_ip_be(host_str, port)
                    var stream_408 = self._connector.connect[RT](
                        reactor=reactor, ip_be=ip_be_408, port=port,
                    )
                    self._note_h1_dial()
                    bundle_cached = _drive_buffered_on_stream_bytes[
                        RT, Self.C.Stream
                    ](
                        retry_bytes^, stream_408^, reactor,
                        max_body_bytes, retry_is_head,
                        req_timeout,
                    )
                # Move out the response (Optional<S> drops with bundle
                # scope if connection_close=True).
                var resp_cached = ClientResponse[BufferedResponseBody](
                    BufferedResponseBody.from_bytes(List[UInt8]())
                )
                swap(resp_cached, bundle_cached.response)
                if bundle_cached.reusable_stream.__bool__():
                    var reused = bundle_cached.reusable_stream.take()
                    self._stash_h1_idle_stream(reused^, stash_key^)
                return resp_cached^

        # Dial path. After this, we know whether the conn is h1 or h2
        # via stream.negotiated_protocol().
        # Resolve ONLY here: this IS the dial. Every
        # pooled-reuse return above leaves without entering
        # the (unbounded, uncancellable) resolve step.
        var ip_be_dial = self._resolve_dial_ip_be(host_str, port)
        var stream = self._connector.connect[RT](
            reactor=reactor, ip_be=ip_be_dial, port=port,
        )
        var alpn = stream.negotiated_protocol()
        if Int(alpn) == Int(NEGOTIATED_HTTP_2):
            # h2 path — register the newly-dialed conn in the pool +
            # drive the first request.
            self.ensure_h2_pool()
            var insert_key = PoolKey.https_h2(
                String(host_str), port, VERIFY_PEER,
            )
            var pool_owned2 = self._h2_pool.take()
            # Build ClientConn + fresh H2ClientConnectionState; insert.
            var client_conn = ClientConn[Self.C.Stream].new(
                stream^, insert_key.copy(), 0,
            )
            var h2_state = H2ClientConnectionState()
            queue_client_preface_and_settings(h2_state)
            var ins = pool_owned2[].insert_dialed_h2(
                insert_key^, client_conn^, h2_state^,
            )
            var resp = _drive_one_h2_buffered_on_pool[RT, Self.C, B](
                pool_owned2^,
                ins.bucket_idx,
                ins.conn_idx,
                req^, body^, reactor, max_body_bytes, req_timeout,
            )
            # Same swap-extract pattern as the FOUND branch above.
            var out_response2 = ClientResponse[BufferedResponseBody](
                BufferedResponseBody.from_bytes(List[UInt8]())
            )
            var out_pool2 = OwnedPointer[H2ClientPool[Self.C.Stream]](
                H2ClientPool[Self.C.Stream].with_defaults()
            )
            swap(out_response2, resp.response)
            swap(out_pool2, resp.pool_owned)
            self._h2_pool = Optional[
                OwnedPointer[H2ClientPool[Self.C.Stream]]
            ](out_pool2^)
            return out_response2^

        # h1 path — bump dials_total in the h1 pool (diagnostic for hc03)
        # then drive via the existing free-function helper.
        # after
        # the response completes with connection_close=False, stash the
        # stream into the per-HttpClient cache for next-same-origin
        # reuse. NB: this is the DIAL path (cache miss above); only h1
        # plaintext currently populates the cache (h1-over-TLS is a
        # follow-up).
        self.ensure_h1_pool()
        var h1_key = PoolKey.http(
            String(host_str), port
        ) if is_http else PoolKey.https(
            String(host_str), port, VERIFY_PEER
        )
        var h1_pool_owned = self._h1_pool.take()
        h1_pool_owned[].insert_dialed(h1_key^)
        self._h1_pool = Optional[
            OwnedPointer[PerCorePool[Self.C.Stream]]
        ](h1_pool_owned^)
        # hot path uses
        # the per-HttpClient read-head scratch (one alloc per client
        # lifetime, reused across all send_buffered calls). lazy-init
        # on first call.
        self.ensure_read_head_scratch()
        ref scratch_arr = self._read_head_scratch.value()[]
        # Build the stash-key BEFORE the call so it survives the borrow
        # of `host_str` consumed by the dispatch helper.
        var stash_key_dial: PoolKey
        if is_http:
            stash_key_dial = PoolKey.http(String(host_str), port)
        else:
            stash_key_dial = PoolKey.https(
                String(host_str), port, VERIFY_PEER,
            )
        # ⛔ SAME DROPPED ARGUMENT AS THE CACHED-CONN ARM ABOVE, AND THIS IS THE
        # ARM PRODUCTION TAKES: every caller that builds a fresh connector per
        # call dials here. `request_timeout_us` must be forwarded or the
        # configured budget becomes the 600 s default.
        var bundle_dial = _run_one_request_buffered_h1[
            RT, Self.C.Stream, B
        ](
            req^, body^, stream^, reactor, max_body_bytes,
            Span[UInt8](scratch_arr),
            req_timeout,
        )
        var resp_dial = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(List[UInt8]())
        )
        swap(resp_dial, bundle_dial.response)
        # Stash the stream IFF the response was keepalive AND we're on
        # plaintext http (the MVP restricts the cache to http). For
        # https (h1-over-TLS), the stream drops naturally — follow-up.
        if is_http and bundle_dial.reusable_stream.__bool__():
            var reused_dial = bundle_dial.reusable_stream.take()
            self._stash_h1_idle_stream(reused_dial^, stash_key_dial^)
        return resp_dial^

    def send_buffered[RT: Runtime, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """Backward-compat: send + slurp. Calls `send` and then drains
        the RecvRingBody into a BufferedResponseBody via collect_body.

        Preserves the default shape for callers that want the
        slurp semantic without restructuring around streaming. This is
        NOT an additive parallel API; it's a one-line convenience.

        dispatches on negotiated ALPN — h2 endpoints route
        through the h2 codec, h1 endpoints stay on OutboundDriver.

        dispatches through the POOL-AWARE path
        (`_dispatch_pooled_buffered`). For h2, the pool's bucket holds
        the conn for its lifetime (multiplex); the second call to
        send_buffered with the same origin reuses the existing conn
        (fd-count=1 invariant). For h1, the pool's `dials_total` counter
        is bumped on each dial (for hc03 diagnostic); the conn itself is
        dropped after the response — h1 keepalive checkin is
        (requires RecvRingBody.take_stream() refactor).
        """
        var max_body = self._config.max_response_body_bytes
        var body = req.body.take()
        return self._dispatch_pooled_buffered[RT, B](
            req^, body^, reactor, max_body,
        )

    def send_buffered_batch[RT: Runtime, B: RequestBody](
        mut self,
        var reqs: List[ClientRequest[B]],
        mut reactor: Reactor[RT.Sink],
    ) raises -> List[ClientResponse[BufferedResponseBody]]:
        """Send K requests CONCURRENTLY as K
        multiplexed h2 streams on ONE pooled connection, and return their
        responses (`responses[i]` <-> `reqs[i]`).

        This is the bounded-concurrent analog of `send_buffered`: instead of one
        blocking request at a time, it opens all K streams on the one conn and
        drives them together via the h2 multiplex driver (which interleaves the K
        streams to END_STREAM). The whole point of HTTP/2 is N concurrent streams
        on one connection; this exposes it. Callers BOUND K (e.g. a
        bulk mirror uses 32) and wave large batches through in K-sized
        chunks.

        Contract: ALL `reqs` MUST target the SAME https authority (one pooled
        conn) and negotiate h2. Empty `reqs` returns an empty list. A per-request
        transient-fault RETRY / a wedged-conn re-dial is the CALLER's policy
        (`GeneratedStorageApi.rewrite_object_batch` owns it) — this method is the
        mechanism: drive K streams once, return K responses, raise on a
        conn-level drive failure (GOAWAY / wall-deadline) so the caller can
        re-dial + resubmit.
        """
        var n = len(reqs)
        if n == 0:
            return List[ClientResponse[BufferedResponseBody]]()

        var max_body = self._config.max_response_body_bytes

        # THE TIGHTEST MEMBER OF THE BATCH BINDS THE WHOLE BATCH, because
        # there is exactly ONE drive loop over the ONE pooled connection and
        # it has one wall. Folding with `tighter_budget_us` (`0` == "states
        # none", so it never widens) means a batch in which nobody stated a
        # budget resolves to the configured one, byte-identically to before.
        # ⛔ NOT a per-stream budget: `drive_request_on_pooled_conn` drives K
        # streams to completion together, so a per-member deadline is not
        # expressible at this altitude and pretending otherwise would be a
        # deadline nothing enforces.
        var batch_timeout = self._config.request_timeout_us
        var ti = 0
        while ti < n:
            batch_timeout = tighter_budget_us(
                batch_timeout, reqs[ti].request_budget_us()
            )
            ti = ti + 1

        # Take each request's body out of its Optional (same as send_buffered),
        # building the parallel `bodies` List the batch driver consumes.
        var bodies = List[B]()
        var bi = 0
        while bi < n:
            bodies.append(reqs[bi].body.take())
            bi = bi + 1

        # All requests share one authority — derive it from reqs[0].
        var is_https = reqs[0].url.is_https()
        var is_http = reqs[0].url.is_http()
        _scheme_check_or_raise[Self.C](is_https, is_http, self._connector)
        # Every member must carry the same scheme/host/port as reqs[0]: one
        # pooled conn, one scheme check. A mixed batch is refused, not dialed.
        var ci = 1
        while ci < n:
            _scheme_check_or_raise[Self.C](
                reqs[ci].url.is_https(), reqs[ci].url.is_http(), self._connector
            )
            if (
                reqs[ci].url.is_https() != is_https
                or reqs[ci].url.host_copy() != reqs[0].url.host_copy()
                or reqs[ci].url.effective_port() != reqs[0].url.effective_port()
            ):
                raise Error(
                    "HttpError[URL_INVALID]: send_buffered_batch requires all"
                    " requests to share one https authority"
                )
            ci = ci + 1
        if not is_https:
            raise Error(
                "HttpError[URL_INVALID]: send_buffered_batch requires https h2"
                " (batch multiplexing is an h2-only capability)"
            )
        var host_str = reqs[0].url.host_copy()
        var port = reqs[0].url.effective_port()
        # ★ PER-REQUEST SNI — the host, not just the address. COSTS NO
        # HANDSHAKE *AND NO RESOLVE*: this writes one field, every pooled-reuse
        # path below returns without reaching `connect` at all, and
        # without entering the resolve step either — the dial
        # address is resolved AT the dial points (`_resolve_dial_ip_be`), never
        # here.
        # ⛔ DO NOT HOIST A RESOLVE BACK ABOVE THE POOL PROBE. Until that date
        # one sat on the line above this comment, and the comment's true claim
        # about the HANDSHAKE read as reassurance about it: a request that
        # reused a warm connection still paid a blocking, uncancellable
        # `getaddrinfo` (the one unbounded phase of a dial). Falsifier:
        # `test_dial_resolve_is_lazy`. See `Connector.set_dial_host`.
        self._connector.set_dial_host(host_str.copy())

        # ---- Checkout-or-dial ONE h2 conn for this authority. ----
        self.ensure_h2_pool()
        var key = PoolKey.https_h2(String(host_str), port, VERIFY_PEER)
        var pool_owned = self._h2_pool.take()
        var outcome = pool_owned[].try_checkout_or_pending(key^)
        var b_idx: Int
        var c_idx: Int
        if outcome.outcome == H2_OUTCOME_FOUND:
            var found = outcome.found.take()
            b_idx = found.bucket_idx
            c_idx = found.conn_idx
        elif outcome.outcome == H2_OUTCOME_PENDING:
            self._h2_pool = Optional[
                OwnedPointer[H2ClientPool[Self.C.Stream]]
            ](pool_owned^)
            raise Error(
                "HttpError[POOL_AT_CAPACITY]: h2 multiplex bucket saturated;"
                " wake-await is not implemented"
            )
        else:
            # NEEDS_DIAL — dial a fresh conn + register it.
            var insert_key = PoolKey.https_h2(
                String(host_str), port, VERIFY_PEER,
            )
            # Resolve ONLY here: this IS the dial. Every
            # pooled-reuse return above leaves without entering
            # the (unbounded, uncancellable) resolve step.
            var ip_be_dial = self._resolve_dial_ip_be(host_str, port)
            var stream = self._connector.connect[RT](
                reactor=reactor, ip_be=ip_be_dial, port=port,
            )
            var client_conn = ClientConn[Self.C.Stream].new(
                stream^, insert_key.copy(), 0,
            )
            var h2_state = H2ClientConnectionState()
            queue_client_preface_and_settings(h2_state)
            var ins = pool_owned[].insert_dialed_h2(
                insert_key^, client_conn^, h2_state^,
            )
            b_idx = ins.bucket_idx
            c_idx = ins.conn_idx

        # ---- Drive the batch of K streams on the one conn. ----
        var batch = _drive_batch_h2_buffered_on_pool[RT, Self.C, B](
            pool_owned^, b_idx, c_idx, reqs^, bodies^, reactor, max_body,
            batch_timeout,
        )
        # Re-stash the pool + return the responses (swap-out-of-result idiom).
        var out_responses = List[ClientResponse[BufferedResponseBody]]()
        var out_pool = OwnedPointer[H2ClientPool[Self.C.Stream]](
            H2ClientPool[Self.C.Stream].with_defaults()
        )
        swap(out_responses, batch.responses)
        swap(out_pool, batch.pool_owned)
        self._h2_pool = Optional[
            OwnedPointer[H2ClientPool[Self.C.Stream]]
        ](out_pool^)
        return out_responses^


# =============================================================================
# §2.5 — _run_one_request helper.
# =============================================================================
# Shared one-shot driver invoked by both HttpClient.call (with a
# caller-supplied connector) and HttpClient.send (with the client's
# own). The helper exists to side-step the Mojo 1.0.0b1 aliasing
# diagnostic: a method that took `mut self` AND `mut self._connector`
# (via delegation to another method) is rejected. Splitting the body
# into a free helper means `send` can hand the helper its own
# `mut self._connector` borrow without the method-self also being
# borrowed mut.


# =============================================================================
# ★ GO'S THREE-TERM RETRY RULE FOR THE h1 KEEPALIVE POOL.
# =============================================================================
#
# `persistConn.shouldRetryRequest` (Go, `net/http/transport.go`):
#
#     reused-connection  AND  no-response-header-data-yet
#                        AND  (nothing-was-written  OR  request-is-replayable)
#
# EVERY TERM IS LOAD-BEARING AND EACH GUARDS A DIFFERENT DISASTER:
#   * `reused`          — a FRESH connection that fails must NEVER be retried,
#                         or a genuinely-dead endpoint loops forever (Go's own
#                         comment: "if we retried now, we could loop forever").
#                         Held STRUCTURALLY here: the retry arm exists only on
#                         the pool-cache-HIT branch of each pooled entry point;
#                         the dial branch has none.
#   * `no header data`  — once ANY response byte has arrived the server HAS run
#                         the request; replaying double-executes it. For
#                         example:
#                         `EOF_MID_RESPONSE: chunked body unterminated` is BY
#                         CONSTRUCTION a truncation AFTER a complete 200 head.
#   * `nothing written
#      OR replayable`   — a POST that reached the wire may have been executed
#                         even though we never saw a byte back.
#
# ⛔ BEFORE THIS EXISTED ALL THREE POOLED ENTRY POINTS CAUGHT `except e: _ = e`
# AND REPLAYED. One bare `except` cannot hold three terms, and the one it was
# actually holding was none of them: it replayed a POST whose response had been
# truncated four frames into the body and returned a cheerful 200 for a request
# the server had already executed twice.


comptime HTTP_STATUS_REQUEST_TIMEOUT: Int = 408
"""★ THE STATUS A SERVER USES TO REAP AN **IDLE** KEEPALIVE CONNECTION.

Go carries the same special case as `is408Message` + `readLoopPeekFailLocked`
(golang.org/issue/32310), and it is not a courtesy: a server that times out an
idle pooled connection commonly writes `408 Request Timeout` and closes. A
client with no reader on its idle connections finds those bytes at the head of
the connection the NEXT time it reuses it and parses them as THAT request's
response — so request N is answered by a message the server wrote before
request N was ever sent. That is a RESPONSE MIX-UP, not a status code, and with
one more queued response on the wire it becomes request N receiving request
N-1's BODY.

RFC 9110 §15.5.9 is the licence for the fix, in the same paragraph that defines
the status: *"If the client has an outstanding request in transit, the client
MAY repeat that request on a new connection."* So a 408 read off a REUSED
connection is discarded and the request is re-issued once on a fresh one — and
a 408 from a connection this request DIALLED is returned untouched, because
there is no earlier message it could be."""


def _h1_method_is_replay_safe(method_code: UInt8) -> Bool:
    """Term 3b — is re-issuing this verb on a fresh connection safe when the
    request's bytes ARE known to have reached the wire?

    THE SET IS RFC 9110 §9.2.1's **SAFE** METHODS, WHICH IS ALSO GO'S SHIPPED
    `Request.isReplayable` SET: GET, HEAD, OPTIONS (TRACE completes Go's four
    and is simply absent from this codec's verb table). POST, PATCH, **PUT and
    DELETE** are all excluded.

    ⚠ PUT AND DELETE ARE EXCLUDED DELIBERATELY, AND THAT IS THE HALF THAT
    LOOKS WRONG UNTIL RFC 9110 §9.2.2 IS READ CLOSELY. They ARE idempotent
    there — but idempotency is defined as a property of *the intended effect
    on the origin server*: a promise the RESOURCE makes, which the CLIENT
    cannot verify and did not make. A client reading "PUT is idempotent" as a
    licence to replay is asserting something about a server it has never seen
    (a PUT behind an appending handler, or one whose `If-Match` precondition
    the first attempt already consumed, is idempotent in neither). That same
    section only ever grants the client the NEGATIVE — *"a client SHOULD NOT
    automatically retry a request with a non-idempotent method"* — and never
    obliges anyone to retry an idempotent one, so the narrow set is fully
    conformant. The cost of being wrong is asymmetric, which settles it: a
    missed retry is ONE surfaced transport error the caller can re-issue, a
    wrong retry is a resource written twice with nobody able to tell.

    ⚠ THE OPT-IN IS THE ANSWER FOR A PUT THAT REALLY IS REPLAYABLE. The caller
    states it per-request with `Idempotency-Key` (see
    `_h1_request_carries_idempotency_key`) — Go's own escape hatch, and it puts
    the claim where the knowledge actually is.

    ⛔ DO NOT ADD PUT/DELETE HERE, as urllib3's
    `Retry.DEFAULT_ALLOWED_METHODS` (GET/HEAD/PUT/DELETE/OPTIONS) does.
    `test_row1_not_replay_safe_with_bytes_written_is_not_retried`
    (`komira_http_client/tests/test_h1_pool_stale_conn_retry_safety.mojo`) is the
    falsifier: a PUT whose bytes had reached the wire on a
    reaped keepalive connection would be replayed onto a fresh one and answer a
    cheerful 200, for a request the server may already have executed."""
    var c = Int(method_code)
    return (
        c == Int(HTTP_METHOD_GET)
        or c == Int(HTTP_METHOD_HEAD)
        or c == Int(HTTP_METHOD_OPTIONS)
    )


def _ascii_bytes(s: String) -> List[UInt8]:
    """The bytes of an ASCII literal, as an owned List. Used for the two
    header names the replay opt-in recognises."""
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _ascii_lower_byte(b: UInt8) -> UInt8:
    """ASCII-only case fold. Field names are `token`s (RFC 9112 §5), so no
    multi-byte case mapping can arise here."""
    if b >= UInt8(65) and b <= UInt8(90):
        return b + UInt8(32)
    return b


def _h1_head_end_index(ref req_bytes: List[UInt8]) -> Int:
    """Index one past the head's terminating CRLFCRLF in a serialized request.

    ⛔ RETURNS 0 — "scan nothing" — WHEN THERE IS NO TERMINATOR, WHICH IS THE
    FAIL-CLOSED DIRECTION AND THE WHOLE POINT OF THIS FUNCTION. A serialized
    `ClientRequest.request_bytes` is head + CRLFCRLF + body, so the body is in
    the same blob; a header scan that ran to the end of it would let a request
    whose BODY happened to contain the bytes `idempotency-key:` license its own
    replay. Degrading to "found no header" costs a retry; degrading to "scan
    the body" costs a double execution."""
    var n = req_bytes.__len__()
    var i = 0
    while i + 3 < n:
        if (
            req_bytes[i] == UInt8(13)
            and req_bytes[i + 1] == UInt8(10)
            and req_bytes[i + 2] == UInt8(13)
            and req_bytes[i + 3] == UInt8(10)
        ):
            return i + 4
        i = i + 1
    return 0


def _h1_field_line_is(
    ref req_bytes: List[UInt8],
    start: Int,
    line_end: Int,
    ref name: List[UInt8],
) -> Bool:
    """Does the field-line at `[start, line_end)` carry field-name `name`
    (given lowercase, no colon) AND a non-empty field-value?

    ⚠ NO WHITESPACE IS PERMITTED BETWEEN THE FIELD-NAME AND THE COLON (RFC
    9112 §5.1, which requires a server to REJECT such a message), so the colon
    is required at exactly `start + len(name)` — a prefix match alone would
    also accept `idempotency-key-hint:`."""
    var nlen = name.__len__()
    if start + nlen >= line_end:
        return False
    var k = 0
    while k < nlen:
        if _ascii_lower_byte(req_bytes[start + k]) != name[k]:
            return False
        k = k + 1
    if req_bytes[start + nlen] != UInt8(58):  # ':'
        return False
    var v = start + nlen + 1
    while v < line_end:
        var b = req_bytes[v]
        if b != UInt8(32) and b != UInt8(9):  # OWS
            return True
        v = v + 1
    return False


def _h1_request_carries_idempotency_key(ref req_bytes: List[UInt8]) -> Bool:
    """Term 3c — THE CALLER'S EXPLICIT, PER-REQUEST REPLAY LICENCE.

    Go carries exactly this in `Request.isReplayable`, over the same two
    spellings, with the same rationale (golang.org/issue/19943): idempotency
    for a non-safe verb is a fact about the HANDLER, so the only party who can
    assert it is the one that wrote the request. `Idempotency-Key` is the
    header the industry converged on for that assertion
    (draft-ietf-httpapi-idempotency-key-header), and `X-Idempotency-Key` is
    the legacy spelling still emitted by deployed clients.

    Presence alone is not enough here: the value must be non-empty. An empty
    key identifies no operation, so a server could not deduplicate on it even
    if it wanted to, and honouring one would turn a header a proxy stripped to
    `Idempotency-Key:` into a licence to double-execute.

    ⚠ SCANNED OVER THE HEAD ONLY — see `_h1_head_end_index`."""
    var head_end = _h1_head_end_index(req_bytes)
    if head_end == 0:
        return False
    var plain = _ascii_bytes(String("idempotency-key"))
    var legacy = _ascii_bytes(String("x-idempotency-key"))

    # Step over the request-line: it is not a field-line, and matching against
    # it would be meaningless.
    var i = 0
    var found_request_line_end = False
    while i + 1 < head_end:
        if req_bytes[i] == UInt8(13) and req_bytes[i + 1] == UInt8(10):
            i = i + 2
            found_request_line_end = True
            break
        i = i + 1
    if not found_request_line_end:
        return False

    while i + 1 < head_end:
        if req_bytes[i] == UInt8(13) and req_bytes[i + 1] == UInt8(10):
            break  # the empty line that terminates the head
        var line_end = i
        while line_end + 1 < head_end:
            if (
                req_bytes[line_end] == UInt8(13)
                and req_bytes[line_end + 1] == UInt8(10)
            ):
                break
            line_end = line_end + 1
        if _h1_field_line_is(req_bytes, i, line_end, plain):
            return True
        if _h1_field_line_is(req_bytes, i, line_end, legacy):
            return True
        i = line_end + 2
    return False


def _h1_pooled_retry_is_safe(
    ref msg: String, method_code: UInt8, ref req_bytes: List[UInt8],
) -> Bool:
    """Terms 2 and 3 of the rule above, over the error a pooled-reuse attempt
    raised. Term 1 (`reused`) is the caller's structural obligation: call this
    ONLY from a pool-cache-hit arm.

    * TERM 2 is `is_h2_retryable_transport(msg)`. That class name is a PROOF,
      not a label — every branch that emits it has already established
      `len(recv_buf) == 0` (or RFC 9113 §8.7 REFUSED_STREAM). Its complement is
      what makes this function safe: `IO_ERROR`,
      `EOF_MID_RESPONSE` (chunked-unterminated, short-body), every framing and
      parse error, and `TIMEOUT` all answer False, so none of them is replayed.
    * TERM 3 is `HTTP_NOTHING_WRITTEN_TOKEN` (Go's `nothingWrittenError` —
      provably zero request bytes on the wire, so ANY verb is safe) OR the verb
      being SAFE (`_h1_method_is_replay_safe`) OR the caller having stated a
      replay licence for this one request
      (`_h1_request_carries_idempotency_key`).

    ⛔ DO NOT RELAX THIS TO "the message says retryable". `RETRYABLE_TRANSPORT`
    alone is term 2 only, and term 2 does not imply term 3: a peer can read a
    whole request, execute it, and die before writing its first response
    byte."""
    if not is_h2_retryable_transport(msg):
        return False
    if HTTP_NOTHING_WRITTEN_TOKEN in msg:
        return True
    if _h1_method_is_replay_safe(method_code):
        return True
    return _h1_request_carries_idempotency_key(req_bytes)


def _h1_retry_gave_up(ref first_err: String, ref redial_err: String) -> Error:
    """The error for "the pooled conn failed AND the one permitted redial
    failed too".

    ⚠ THE FIRST ERROR LEADS, DELIBERATELY. It is the one that describes the
    POOLED connection — the RST errno, the FIN, the write failure — and that is
    the fact an operator needs to tell a load balancer reaping connections from
    a server that is simply down. Surfacing only the redial's error (Go's
    choice, which has a background read loop to attribute the first one
    elsewhere) would erase it: it turns
    `read errno=104 ... (RST)` into `peer closed before any response byte`, two
    different causes rendered identically. The redial's error is appended, not
    dropped — "at most one retry" is a claim about dials, not about evidence."""
    return Error(
        first_err + "  [the one permitted redial also failed: "
        + redial_err + "]"
    )


def _url_scheme_copy(ref u: Url) -> String:
    """Read u.scheme as an owned String copy. Avoids the Mojo 1.0.0b1
    borrow-check error where consuming `url.scheme` via `==`
    partial-moves the Url before its drop."""
    return String(u.scheme)


def _url_host_copy(ref u: Url) -> String:
    """Read u.host as an owned String copy. Same rationale as
    _url_scheme_copy."""
    return String(u.host)


def _scheme_check_or_raise[C2: Connector](
    is_https: Bool, is_http: Bool, ref connector: C2,
) raises:
    """Scheme-check: refuse a scheme/connector mismatch up front.
    `https://` requires a TLS-capable connector; `http://` requires a
    plaintext connector. Mixing them is a user-side configuration bug
    that this defensive check turns into a typed error before any
    bytes hit the wire."""
    var connector_is_tls = connector.is_tls()
    if is_https and not connector_is_tls:
        raise Error(
            "HttpError[URL_INVALID]: https:// URL requires a TLS "
            "connector (e.g., TlsConnector[KernelTcpConnector]); got "
            "a plaintext connector"
        )
    if is_http and connector_is_tls:
        raise Error(
            "HttpError[URL_INVALID]: http:// URL requires a plaintext "
            "connector (e.g., KernelTcpConnector); got a TLS connector"
        )


def _allocate_local_read_head_scratch() -> List[UInt8]:
    """
    Allocate a 4 KB byte buffer for OutboundDriver._drive_read_head's
    stream.try_read scratch. Used by non-hot callers
    (`_run_one_request_streaming`, `_run_one_request_buffered_with_dispatch`)
    that don't have access to a long-lived owner — the hot path
    (`_dispatch_pooled_buffered`) uses HttpClient's per-client scratch
    via `ensure_read_head_scratch` + the OwnedPointer-backed field
    instead. One alloc per top-level driver call (was: one alloc per
    `_drive_read_head` inner-loop iteration)."""
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _run_one_request_streaming[
    RT: Runtime, C2: Connector, B: RequestBody,
](
    var req: ClientRequest[B],
    var body: B,
    mut connector: C2,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> ClientResponse[RecvRingBody[C2.Stream]]:
    """Streaming default. Dial via the connector, drive the
    OutboundDriver through head-write + body-write (via
    `driver.run_with_body` so a streaming-body conformer flows without
    slurping) + head-read; hand the stream off to a RecvRingBody. The
    caller drives response body reads via `resp.body.poll_frame[RT]` or
    `collect_body`.

    Stream ownership: the connector's `connect` produces the stream;
    we move it into `driver.run_with_body`; on success the stream
    lives inside the returned ClientResponse[RecvRingBody[C2.Stream]]
    and is dropped (RAII close) when the response is dropped.

    NOTE: `body` is passed alongside `req` so the caller's
    `req.body.take()` happens BEFORE this function sees req. That
    leaves req.body in `None` state — the borrow-check is then
    permissive about subsequent reads of req.url / req.request_bytes,
    since the Optional[B] field's destructor is a no-op.

    ⛔ `request_timeout_us` — THE STREAMING TWIN OF THE SAME GAP.
    `_run_one_request_buffered_h1` / `_drive_buffered_on_stream_bytes` have
    called `driver.set_request_timeout_us` since; this function
    built its own `OutboundDriver` and never did, so an authored budget bound
    the BUFFERED h1 arm and silently not the STREAMING one — `send`,
    `get_range` and `send_streaming_with_connector` all took the 600s default
    whatever the caller stated. 0 = none authored (unchanged 600s)."""
    var is_https = req.url.is_https()
    var is_http = req.url.is_http()
    _scheme_check_or_raise[C2](is_https, is_http, connector)
    var host_str = req.url.host_copy()
    var port = req.url.effective_port()
    var ip_be = _ip_be_from_host(host_str, port)
    # ★ PER-REQUEST SNI — the host, not just the address. See
    # `Connector.set_dial_host`.
    # ⚠ THIS HELPER CONSULTS NO POOL AND ALWAYS DIALS, so the resolve
    # above it is unconditional BY CONSTRUCTION and there is nothing here
    # to make lazy. The `HttpClient` methods that DO probe a pool resolve
    # at their dial points instead (`_resolve_dial_ip_be`); do not copy
    # this shape into one of them.
    connector.set_dial_host(host_str.copy())
    var stream = connector.connect[RT](
        reactor=reactor, ip_be=ip_be, port=port,
    )
    # capture
    # the HEAD-method flag BEFORE swapping out request_bytes, so the
    # OutboundDriver can short-circuit the body-collect path per RFC
    # 7230 §3.3.2 / RFC 7231 §4.3.2.
    var is_head = Int(req.method.code) == Int(HTTP_METHOD_HEAD)
    # Swap out request_bytes (rather than partial-move via `^`) so the
    # field is left in a destructor-safe (empty) state. Same pattern
    # for Optional.take() on body — the borrow-check is then permissive
    # at function exit.
    var req_bytes = List[UInt8]()
    swap(req_bytes, req.request_bytes)
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_max_response_body_bytes(max_body_bytes)
    driver.set_is_head_request(is_head)
    # Streaming arm: bound the drive loop when a positive
    # timeout was authored (0 = the 600s default for every caller
    # that authors none). Mirrors `_run_one_request_buffered_h1`.
    if request_timeout_us > 0:
        driver.set_request_timeout_us(request_timeout_us)
    # allocate a local
    # 4 KB scratch ONCE per top-level driver call (was: per inner-loop iter).
    var scratch_buf = _allocate_local_read_head_scratch()
    # drain body alongside the head via run_with_body.
    # For buffered bodies (EmptyBody / drained BytesBody), read_chunk
    # returns 0 immediately so the body-write phase is a single
    # method-call no-op.
    var resp = driver.run_with_body[C2.Stream, RT, B](
        stream^, body^, reactor, Span[UInt8](scratch_buf),
    )
    return resp^


def _drive_streaming_get_on_stream_bytes[
    RT: Runtime, S: IoStream,
](
    var req_bytes: List[UInt8],
    var stream: S,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    is_head: Bool,
) raises -> ClientResponse[RecvRingBody[S]]:
    """Drive a streaming GET
    (EmptyBody) from already-signed wire bytes on a stream (PRE-DIALED
    keepalive-reused OR freshly-dialed by the caller) — no `connector.connect`
    inside. The OutboundDriver begins in `Idle` and operates on an
    already-connected stream (see `OutboundDriver` in state_machine.mojo), so a reused
    keepalive conn flows through unchanged.

    The body is `EmptyBody` (GET has no payload) — built fresh here so the
    caller can retry on a dead keepalive conn without replaying body state.

    robustness: if the server silently closed a reused keepalive conn, the
    head-read fails as a transport error and `run_with_body` raises; the
    CALLER (`send_streaming_pooled_get`) catches and retries with a fresh
    dial. Idempotent ranged GET → safe to retry."""
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_max_response_body_bytes(max_body_bytes)
    driver.set_is_head_request(is_head)
    var scratch_buf = _allocate_local_read_head_scratch()
    var body = EmptyBody.new()
    var resp = driver.run_with_body[S, RT, EmptyBody](
        stream^, body^, reactor, Span[UInt8](scratch_buf),
    )
    return resp^


def _run_one_request_buffered_with_dispatch[
    RT: Runtime, C2: Connector, B: RequestBody,
](
    var req: ClientRequest[B],
    var body: B,
    mut connector: C2,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> ClientResponse[BufferedResponseBody]:
    """Dial via the connector, check the negotiated
    ALPN, and route through either the h1 OutboundDriver path or the h2
    codec path. Returns a BufferedResponseBody in both cases.

    For h2, body collection is sync — `drive_h2_streams_to_completion`
    runs until END_STREAM on this request's stream, then
    `extract_response_for_stream` builds the ClientResponse.

    Stream ownership: dialed stream is moved into the helper for both
    branches; on h1 it lives inside the returned streaming-then-drained
    response shape; on h2 it lives inside the H2ClientConnectionState's
    surrounding scope until conn close (this path is one-shot
    h2 — no pool reuse across HttpClient.send calls).

    `request_timeout_us` (0 = the 600s default) bounds the
    h1 drive loop so a non-responsive server fails FAST. Threaded to the h1
    helper AND to the h2 one.

    ⛔ "The h2 one-shot path is unaffected (it drives to END_STREAM, not the
    spin-then-park drive loop)" WOULD BE A DEFECT STATED AS A PROPERTY.
    "Drives to END_STREAM" is exactly what a
    peer that accepts a stream and then goes silent never lets happen;
    `drive_h2_streams_to_completion` IS a spin-then-park drive loop, with its
    own 120s wall. Dropping the caller's budget would make one authored deadline
    silently mean two different numbers depending on which protocol the peer
    negotiated. See `h2_drive_wall_us`.
    """
    var is_https = req.url.is_https()
    var is_http = req.url.is_http()
    _scheme_check_or_raise[C2](is_https, is_http, connector)
    var host_str = req.url.host_copy()
    var port = req.url.effective_port()
    var ip_be = _ip_be_from_host(host_str, port)
    # ★ PER-REQUEST SNI — the host, not just the address. See
    # `Connector.set_dial_host`.
    # ⚠ THIS HELPER CONSULTS NO POOL AND ALWAYS DIALS, so the resolve
    # above it is unconditional BY CONSTRUCTION and there is nothing here
    # to make lazy. The `HttpClient` methods that DO probe a pool resolve
    # at their dial points instead (`_resolve_dial_ip_be`); do not copy
    # this shape into one of them.
    connector.set_dial_host(host_str.copy())
    var stream = connector.connect[RT](
        reactor=reactor, ip_be=ip_be, port=port,
    )
    # read the negotiated ALPN sentinel on the dialed
    # stream. For h1 / plaintext, this is NEGOTIATED_HTTP_1_1; for h2 over
    # TLS+ALPN, this is NEGOTIATED_HTTP_2.
    var alpn = stream.negotiated_protocol()
    if Int(alpn) == Int(NEGOTIATED_HTTP_2):
        return _run_one_request_h2_buffered[RT, C2.Stream, B](
            req^, body^, stream^, reactor, max_body_bytes,
            request_timeout_us,
        )
    # Default h1 path — unchanged scope (legacy non-pool-aware path).
    # legacy callers don't
    # cache the reusable stream; extract `.response` from the bundle
    # and let `reusable_stream` drop (closing the fd via stream's
    # __del__). Hot-path caller (`HttpClient._dispatch_pooled_buffered`)
    # is the one that uses keepalive.
    var scratch_buf_h1 = _allocate_local_read_head_scratch()
    var bundle = _run_one_request_buffered_h1[RT, C2.Stream, B](
        req^, body^, stream^, reactor, max_body_bytes,
        Span[UInt8](scratch_buf_h1), request_timeout_us,
    )
    # Move out the response; let reusable_stream drop with bundle scope.
    var resp_out = ClientResponse[BufferedResponseBody](
        BufferedResponseBody.from_bytes(List[UInt8]())
    )
    swap(resp_out, bundle.response)
    return resp_out^


struct _H1BufferedResult[S: IoStream](Movable, Deinitable):
    """Bundles
    the buffered response together with an Optional[S] holding the
    underlying stream IFF it is safe to reuse for h1 keepalive (i.e.,
    the response had connection_close=False AND the body was fully
    consumed). On connection_close=True, the stream is consumed by the
    drop of the local RecvRingBody and `reusable_stream` is None.

    Mojo 1.0.0b1 does not support multi-value returns natively for
    non-Copyable types; bundling in a Movable struct is the canonical
    workaround (same shape as _PooledH2DriveResult)."""

    var response: ClientResponse[BufferedResponseBody]
    var reusable_stream: Optional[Self.S]

    def __init__(
        out self,
        var response: ClientResponse[BufferedResponseBody],
        var reusable_stream: Optional[Self.S],
    ):
        self.response = response^
        self.reusable_stream = reusable_stream^


def _run_one_request_buffered_h1[
    RT: Runtime, S: IoStream, B: RequestBody, scratch_o: Origin[mut=True],
](
    var req: ClientRequest[B],
    var body: B,
    var stream: S,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    scratch: Span[UInt8, scratch_o],
    request_timeout_us: Int = 0,
) raises -> _H1BufferedResult[S]:
    """The h1 buffered branch after stream is dialed +
    ALPN known. Mirrors the original `_run_one_request_buffered` body
    minus the connector.connect call (the caller did the dial).

    `request_timeout_us` (0 = the 600s default) bounds the
    `OutboundDriver` spin-then-park drive loop so a non-responsive server
    fails FAST with a TIMEOUT instead of wedging the calling thread.

    `scratch` is a
    caller-owned 4 KB+ byte span passed down to OutboundDriver. The hot
    path (`HttpClient._dispatch_pooled_buffered`) sources this from a
    per-HttpClient long-lived InlineArray-backed scratch (zero alloc
    per request). Non-hot callers (`_run_one_request_buffered_with_dispatch`)
    allocate a local List once per call.

    returns a
    bundle `_H1BufferedResult[S]` whose `reusable_stream` field holds
    the stream IFF the response is keepalive-safe (connection_close
    was False on the parsed response). The caller (HttpClient's hot
    path) caches the returned stream on the HttpClient for the next
    same-origin send_buffered. Non-keepalive callers ignore the
    `reusable_stream` field (drop = stream.close())."""
    # capture
    # the HEAD-method flag BEFORE swapping out request_bytes so the
    # OutboundDriver can short-circuit the body-collect path. Per
    # RFC 7230 §3.3.2 a HEAD response MUST NOT have a body even
    # with `Content-Length` set.
    var is_head = Int(req.method.code) == Int(HTTP_METHOD_HEAD)
    var req_bytes = List[UInt8]()
    swap(req_bytes, req.request_bytes)
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_max_response_body_bytes(max_body_bytes)
    driver.set_is_head_request(is_head)
    # bound the drive loop when a positive timeout was
    # configured (0 = the generous 600s default — unchanged for every
    # existing caller).
    if request_timeout_us > 0:
        driver.set_request_timeout_us(request_timeout_us)
    var streaming_resp = driver.run_with_body[S, RT, B](
        stream^, body^, reactor, scratch,
    )
    # THE BODY DRAIN'S DEADLINE IS ALREADY HERE -- DO NOT ADD A SECOND ONE.
    # `set_request_timeout_us` above armed the driver, and `run_with_body`
    # STAMPED that same absolute deadline onto `streaming_resp.body` at the
    # moment it built it. `collect_body` therefore needs no deadline
    # argument: `RecvRingBody.poll_frame` enforces the stamped one, on every
    # poll, gated on nothing the peer can steer.
    #
    # `CancellationToken.never()` STAYS, and stays deliberately. Cancellation
    # and deadline are different questions -- this call site genuinely has no
    # cancellation source to thread, and overloading the token with a
    # deadline would make both worse. The unbounded drain was never a missing
    # token; it was a missing deadline.
    var tok = CancellationToken.never()
    var body_bytes = collect_body[RT, S](
        streaming_resp.body, reactor, tok,
    )
    var resp_body = BufferedResponseBody.from_bytes(body_bytes^)
    var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
    buf_resp.status = streaming_resp.status
    var reason_tmp = String()
    swap(reason_tmp, streaming_resp.reason)
    buf_resp.reason = reason_tmp^
    var hdrs_tmp = HeaderMap()
    swap(hdrs_tmp, streaming_resp.headers)
    buf_resp.headers = hdrs_tmp^
    buf_resp.connection_close = streaming_resp.connection_close
    # extract the underlying
    # stream from the streaming response's RecvRingBody IFF the response
    # indicated keepalive (connection_close=False). The body has been
    # driven to End by collect_body above (its precondition is
    # `_done=True`), so take_stream succeeds.
    var reusable_opt: Optional[S]
    if not streaming_resp.connection_close:
        # Body fully consumed; safe to take the stream out.
        reusable_opt = Optional[S](streaming_resp.body.take_stream())
    else:
        # Connection: close — the stream must be dropped (its drop closes
        # the fd). Leave reusable_opt empty; the streaming_resp falls
        # out of scope at function exit and the stream drops.
        reusable_opt = Optional[S]()
    return _H1BufferedResult[S](
        response=buf_resp^,
        reusable_stream=reusable_opt^,
    )


def _drive_buffered_on_stream_bytes[
    RT: Runtime, S: IoStream,
](
    var req_bytes: List[UInt8],
    var stream: S,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    is_head: Bool,
    request_timeout_us: Int = 0,
) raises -> _H1BufferedResult[S]:
    """The BUFFERED analog of
    `_drive_streaming_get_on_stream_bytes` — drive one request from
    already-signed wire bytes on a PRE-DIALED (keepalive-reused OR
    freshly-dialed) stream, slurp the body into a BufferedResponseBody, and
    return the `_H1BufferedResult[S]` bundle so the CALLER can stash the
    reusable stream back into the keepalive cache IFF the response was
    keepalive-safe (connection_close=False).

    Why a fresh `EmptyBody` is byte-identical for the broker write path: the
    broker's S3 verbs (`conditional_put` / `compare_and_swap` / segment PUT /
    HEAD) carry the body PRE-SERIALIZED into `req_bytes` (head + body
    concatenated — `build_request_with_body` drains the BytesBody at build
    time; the SigV4 layer re-serializes request_bytes with the body
    re-appended + the correct signed Content-Length). The
    OutboundDriver's WRITING_REQUEST_HEADERS phase drains the ENTIRE
    `_req_bytes` blob, and the WRITING_REQUEST_BODY
    phase calls `body.read_chunk` which returns 0 immediately for a drained
    BytesBody / EmptyBody — a one-call no-op. So
    driving with a fresh `EmptyBody` reproduces the SAME wire bytes, which is
    exactly what lets the dead-conn retry replay the request from the saved
    bytes without rewinding any body state.

    robustness: if the server silently closed a reused keepalive conn, the
    head-read fails as a transport error and `run_with_body` raises; the
    CALLER (`HttpClient.call_pooled`) catches and retries with a FRESH dial.
    The broker write ops are idempotent under replay (conditional_put is
    conditioned on an etag/If-None-Match → a now-committed write surfaces as a
    412 the caller's CAS-retry handles; segment PUT is idempotent by key)."""
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_max_response_body_bytes(max_body_bytes)
    driver.set_is_head_request(is_head)
    # bound the drive loop when a positive timeout was
    # configured (0 = the 600s default — unchanged for every existing caller).
    if request_timeout_us > 0:
        driver.set_request_timeout_us(request_timeout_us)
    var scratch_buf = _allocate_local_read_head_scratch()
    var body = EmptyBody.new()
    var streaming_resp = driver.run_with_body[S, RT, EmptyBody](
        stream^, body^, reactor, Span[UInt8](scratch_buf),
    )
    # THE BODY DRAIN'S DEADLINE IS ALREADY HERE -- DO NOT ADD A SECOND ONE.
    # `set_request_timeout_us` above armed the driver, and `run_with_body`
    # STAMPED that same absolute deadline onto `streaming_resp.body` at the
    # moment it built it. `collect_body` therefore needs no deadline
    # argument: `RecvRingBody.poll_frame` enforces the stamped one, on every
    # poll, gated on nothing the peer can steer.
    #
    # `CancellationToken.never()` STAYS, and stays deliberately. Cancellation
    # and deadline are different questions -- this call site genuinely has no
    # cancellation source to thread, and overloading the token with a
    # deadline would make both worse. The unbounded drain was never a missing
    # token; it was a missing deadline.
    var tok = CancellationToken.never()
    var body_bytes = collect_body[RT, S](
        streaming_resp.body, reactor, tok,
    )
    var resp_body = BufferedResponseBody.from_bytes(body_bytes^)
    var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
    buf_resp.status = streaming_resp.status
    var reason_tmp = String()
    swap(reason_tmp, streaming_resp.reason)
    buf_resp.reason = reason_tmp^
    var hdrs_tmp = HeaderMap()
    swap(hdrs_tmp, streaming_resp.headers)
    buf_resp.headers = hdrs_tmp^
    buf_resp.connection_close = streaming_resp.connection_close
    var reusable_opt: Optional[S]
    if not streaming_resp.connection_close:
        reusable_opt = Optional[S](streaming_resp.body.take_stream())
    else:
        reusable_opt = Optional[S]()
    return _H1BufferedResult[S](
        response=buf_resp^,
        reusable_stream=reusable_opt^,
    )


struct _PooledH2DriveResult[S: IoStream](Movable, Deinitable):
    """Bundles the (response, pool_owned) outparam pair
    that `_drive_one_h2_buffered_on_pool` returns. Mojo 1.0.0b1 does not
    support multi-value returns natively for non-Copyable types; bundling
    in a Movable struct is the canonical workaround.

    Both fields are owned-move on construction; both move out via `^`
    at the call site. The receiving HttpClient.method re-stashes
    `pool_owned` into `self._h2_pool` and returns `response`."""

    var response: ClientResponse[BufferedResponseBody]
    var pool_owned: OwnedPointer[H2ClientPool[Self.S]]

    def __init__(
        out self,
        var response: ClientResponse[BufferedResponseBody],
        var pool_owned: OwnedPointer[H2ClientPool[Self.S]],
    ):
        self.response = response^
        self.pool_owned = pool_owned^


struct _PooledH2BatchDriveResult[S: IoStream](Movable, Deinitable):
    """Bundles the (responses, pool_owned) pair the
    batch-multiplex drive returns — the K-concurrent-stream analog of
    `_PooledH2DriveResult`. `responses[i]` corresponds to `reqs[i]`. Same
    move-in / move-out-via-`^` contract; the HttpClient method re-stashes
    `pool_owned` and returns `responses`."""

    var responses: List[ClientResponse[BufferedResponseBody]]
    var pool_owned: OwnedPointer[H2ClientPool[Self.S]]

    def __init__(
        out self,
        var responses: List[ClientResponse[BufferedResponseBody]],
        var pool_owned: OwnedPointer[H2ClientPool[Self.S]],
    ):
        self.responses = responses^
        self.pool_owned = pool_owned^


# =============================================================================
# pooled STREAMING h2 drive.
# =============================================================================
#
# The buffered analog above (`_drive_one_h2_buffered_on_pool`) returns a
# ClientResponse[BufferedResponseBody]. The gRPC client's `send` path wants a
# ClientResponse[RecvRingBody[S]] (it drives `resp.body.poll_frame`), so this
# variant wraps the h2-drained body bytes in a STREAM-LESS
# `RecvRingBody.from_buffered_bytes` (the conn's stream stays in the pool).
# The multiplex win is identical to the buffered path: the h2 conn is reused
# across N RPCs to the same authority via one fd; this variant only changes
# the response-body conformer the caller receives.


struct _PooledH2StreamDriveResult[S: IoStream](Movable, Deinitable):
    """Bundles (RecvRingBody-response, pool_owned) for the streaming pooled
    h2 drive — the gRPC-facing analog of `_PooledH2DriveResult`."""

    var response: ClientResponse[RecvRingBody[Self.S]]
    var pool_owned: OwnedPointer[H2ClientPool[Self.S]]

    def __init__(
        out self,
        var response: ClientResponse[RecvRingBody[Self.S]],
        var pool_owned: OwnedPointer[H2ClientPool[Self.S]],
    ):
        self.response = response^
        self.pool_owned = pool_owned^


def _drive_one_h2_streaming_on_pool[
    RT: Runtime, C2: Connector, B: RequestBody,
](
    var pool_owned: OwnedPointer[H2ClientPool[C2.Stream]],
    b_idx: Int,
    c_idx: Int,
    var req: ClientRequest[B],
    var body: B,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> _PooledH2StreamDriveResult[C2.Stream]:
    """Drive one h2 request on the pooled
    conn at (b_idx, c_idx), returning a ClientResponse whose body is a
    STREAM-LESS RecvRingBody pre-loaded with the drained response bytes.

    Identical wire behavior to `_drive_one_h2_buffered_on_pool` (same
    frame encode → drive_request_on_pooled_conn → extract_response_for_stream
    → release_stream_slot sequence); the ONLY difference is the response-body
    conformer (RecvRingBody[S] instead of BufferedResponseBody) so the gRPC
    drain layer's `poll_frame` loop slots in unchanged. The conn STAYS in the
    pool (its stream is never moved into the body).

    ★ `request_timeout_us` — THE CALLER'S AUTHORED PER-REQUEST BUDGET, AND THE
    ONLY THING THAT BOUNDS THIS DRIVE. Everything a gRPC caller can state about
    a deadline lands here or nowhere:
      * `CallOptions.deadline` reaches the wire as the `Grpc-Timeout` HEADER —
        a request the PEER is asked to honour, and the peer that matters is
        exactly the one that accepts a stream and then goes silent.
      * the `CancellationToken` that `komira_grpc`'s client names as "the
        ONE client-side deadline trip" is read by `RecvRingBody.poll_frame` —
        and on THIS path the body is already fully materialized before any
        `RecvRingBody` exists (`from_buffered_bytes`, below), so that check runs
        over finished bytes and can bound nothing. The stall happens INSIDE
        `drive_request_on_pooled_conn`, upstream of the token's only reader.
    `0` = none authored (the driver's own 120s wall stands). See
    `h2_drive_wall_us` for why an authored value may only TIGHTEN.

    CLEANUP WHEN IT TRIPS: `drive_h2_streams_to_completion` RAISES
    `HttpError[TIMEOUT]`, which unwinds through this function — and this
    function owns `pool_owned` BY VALUE, so the pooled conn (and its fd) drops
    on the unwind rather than staying in the pool holding a half-consumed
    stream. The next send's `ensure_h2_pool` therefore takes the NEEDS_DIAL path
    and dials fresh. That is the same unwind-and-drop the GOAWAY re-issue
    already relies on and documents, at `komira_grpc/client.mojo`'s
    `_send_server_stream_bounded_goaway_retry`.
    """
    # ---- Build pseudo-headers and frames ------------------------------
    var scheme_local: String = String("https") if req.url.is_https() else String(
        "http"
    )
    var host_for_authority = req.url.host_copy()
    var authority_str = host_for_authority^
    var port_int = req.url.effective_port()
    var default_port: UInt16 = UInt16(443) if req.url.is_https() else UInt16(80)
    if port_int != default_port:
        authority_str = authority_str + String(":") + String(Int(port_int))
    var path_str = String(req.url.path)
    if req.url.query.byte_length() > 0:
        path_str = path_str + String("?") + String(req.url.query)
    var method_str = req.method.name()

    var body_bytes = List[UInt8]()
    var cl = body.content_length()
    if cl > 0:
        # DOUBLE-DRAIN FIX (h2 POST-with-body body-loss). `build_request_with_body`
        # pre-drains the body conformer's cursor to EOF to serialize the h1
        # `request_bytes`, then stores the (now-exhausted) conformer. The h1
        # transport consumes that pre-serialized body; the h2 transport rebuilds its
        # own frames FROM the conformer and re-drains it — so a REPLAYABLE (fully
        # buffered) body MUST be rewound first, else `read_chunk` returns 0, the DATA
        # frame is omitted, and the server receives a body-LESS POST (empty request
        # body). This is why the ONLY affected caller was the GCS JSON object API —
        # the sole `alpn_h2=True` + `build_request_with_body` + `send_buffered` user;
        # every other POST-with-body caller dials the default h1 connector, whose
        # path reads the correct body from `request_bytes`. A NON-replayable
        # (streaming) body is never pre-drained (build_streaming_request skips the
        # drain), so it is drained as-is.
        if body.replayable():
            body.rewind()
        _ = drain_body_into[B](body, body_bytes)
    var has_body = len(body_bytes) > 0
    var end_stream_on_headers = not has_body

    var hdrs_copy = HeaderMap()
    swap(hdrs_copy, req.headers)

    # ---- Encode frames into the h2 state (mutates pool internals) ----
    ref h2_for_encode = pool_owned[].h2_state_at(b_idx, c_idx)
    var sid = allocate_client_stream_id_or_raise(h2_for_encode)
    _ = h2_for_encode.create_stream(sid)
    encode_request_headers_to_frames(
        h2_for_encode, sid,
        method_str^,
        scheme_local^,
        authority_str^,
        path_str^,
        hdrs_copy^,
        end_stream=end_stream_on_headers,
    )
    if has_body:
        encode_request_data_frame(
            h2_for_encode, sid, body_bytes^, end_stream=True
        )

    # ---- Drive the request via the pool's internal driver -------------
    var awaited = List[UInt32]()
    awaited.append(sid)
    pool_owned[].drive_request_on_pooled_conn[RT](
        b_idx, c_idx, reactor, awaited^,
        request_timeout_us=request_timeout_us,
    )

    # ---- Extract response ---------------------------------------------
    var resp_hdrs = HeaderMap()
    var resp_body_bytes = List[UInt8]()
    ref h2_for_extract = pool_owned[].h2_state_at(b_idx, c_idx)
    var resp_tuple = extract_response_for_stream(h2_for_extract, sid)
    var status = UInt32(Int(resp_tuple[0]))
    swap(resp_hdrs, resp_tuple[1])
    swap(resp_body_bytes, resp_tuple[2])
    # retire the completed stream's
    # per-connection state (frees its response Lists, recycles slots, heals the
    # conn send window, drops the POD entry) so a long-lived REUSED conn does not
    # accumulate O(N) closed-stream state and wedge on the 120s wall bound.
    # ⛔ THE TRAILER SECTION MUST BE PULLED BEFORE `retire_stream`, which frees
    # the stream's trailer slot along with its header and body Lists.
    var resp_trailers = extract_trailers_for_stream(h2_for_extract, sid)
    h2_for_extract.retire_stream(sid)

    # Release stream slot (END_STREAM reached) — wakes pending waiters.
    pool_owned[].release_stream_slot(b_idx, c_idx)

    # Enforce max_body_bytes.
    if len(resp_body_bytes) > max_body_bytes:
        raise Error(
            "HttpError[BODY_TOO_LARGE]: h2 response body "
            + String(len(resp_body_bytes))
            + " bytes exceeds max " + String(max_body_bytes)
        )

    # Wrap the drained bytes in a stream-less RecvRingBody — the gRPC
    # drain layer polls one Data frame + End; the conn stays pooled.
    var stream_body = RecvRingBody[C2.Stream].from_buffered_bytes(
        resp_body_bytes^
    )
    var resp = ClientResponse[RecvRingBody[C2.Stream]](stream_body^)
    resp.status = Int32(Int(status))
    resp.reason = String("")
    resp.headers = resp_hdrs^
    resp.trailers = resp_trailers^
    # Multiplex semantics: the conn lives in the pool; NOT connection-close.
    resp.connection_close = False
    return _PooledH2StreamDriveResult[C2.Stream](
        response=resp^,
        pool_owned=pool_owned^,
    )


def _drive_one_h2_buffered_on_pool[
    RT: Runtime, C2: Connector, B: RequestBody,
](
    var pool_owned: OwnedPointer[H2ClientPool[C2.Stream]],
    b_idx: Int,
    c_idx: Int,
    var req: ClientRequest[B],
    var body: B,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> _PooledH2DriveResult[C2.Stream]:
    """Drive one h2 request on a pooled conn at (b_idx, c_idx)
    in `pool_owned`. Builds frames, calls
    `pool_owned[].drive_request_on_pooled_conn[RT]` (which extracts both
    h2 + stream refs internally), extracts the response, releases the
    stream slot.

    Returns (response, pool_owned) — the pool is returned to the caller
    so the HttpClient.method can re-stash it into `self._h2_pool`.

    NOTE: pool_owned is `var` (moved in). On every exit path
    (success or raise) the pool must be either returned-via-result OR
    dropped — we use try/except to ensure the pool is restoreable to
    the caller on failure as well. For v1, on raise we drop the
    pool (the conn it holds is dead); the HttpClient.method then sees
    the field as None on next call, which lazy-re-inits. This is the
    simplest correct behavior.

    `request_timeout_us`: the caller's authored per-request budget (0 = none),
    resolved to this drive's wall bound by `h2_drive_wall_us`. Present for the
    same reason as on the STREAMING twin above — an authored budget that binds
    on one h2 arm and not the other is the asymmetry this whole change closes.
    """
    # ---- Build pseudo-headers and frames ------------------------------
    var scheme_local: String = String("https") if req.url.is_https() else String(
        "http"
    )
    var host_for_authority = req.url.host_copy()
    var authority_str = host_for_authority^
    var port_int = req.url.effective_port()
    var default_port: UInt16 = UInt16(443) if req.url.is_https() else UInt16(80)
    if port_int != default_port:
        authority_str = authority_str + String(":") + String(Int(port_int))
    var path_str = String(req.url.path)
    if req.url.query.byte_length() > 0:
        path_str = path_str + String("?") + String(req.url.query)
    var method_str = req.method.name()

    var body_bytes = List[UInt8]()
    var cl = body.content_length()
    if cl > 0:
        # DOUBLE-DRAIN FIX (h2 POST-with-body body-loss). `build_request_with_body`
        # pre-drains the body conformer's cursor to EOF to serialize the h1
        # `request_bytes`, then stores the (now-exhausted) conformer. The h1
        # transport consumes that pre-serialized body; the h2 transport rebuilds its
        # own frames FROM the conformer and re-drains it — so a REPLAYABLE (fully
        # buffered) body MUST be rewound first, else `read_chunk` returns 0, the DATA
        # frame is omitted, and the server receives a body-LESS POST (empty request
        # body). This is why the ONLY affected caller was the GCS JSON object API —
        # the sole `alpn_h2=True` + `build_request_with_body` + `send_buffered` user;
        # every other POST-with-body caller dials the default h1 connector, whose
        # path reads the correct body from `request_bytes`. A NON-replayable
        # (streaming) body is never pre-drained (build_streaming_request skips the
        # drain), so it is drained as-is.
        if body.replayable():
            body.rewind()
        _ = drain_body_into[B](body, body_bytes)
    var has_body = len(body_bytes) > 0
    var end_stream_on_headers = not has_body

    var hdrs_copy = HeaderMap()
    swap(hdrs_copy, req.headers)

    # ---- Encode frames into the h2 state (mutates pool internals) ----
    # The ref borrow lives across the encode calls; Mojo's borrow check
    # accepts back-to-back fn-call mutations on the same ref source.
    ref h2_for_encode = pool_owned[].h2_state_at(b_idx, c_idx)
    var sid = allocate_client_stream_id_or_raise(h2_for_encode)
    _ = h2_for_encode.create_stream(sid)
    encode_request_headers_to_frames(
        h2_for_encode, sid,
        method_str^,
        scheme_local^,
        authority_str^,
        path_str^,
        hdrs_copy^,
        end_stream=end_stream_on_headers,
    )
    if has_body:
        encode_request_data_frame(
            h2_for_encode, sid, body_bytes^, end_stream=True
        )

    # ---- Drive the request via the pool's internal driver -------------
    var awaited = List[UInt32]()
    awaited.append(sid)
    pool_owned[].drive_request_on_pooled_conn[RT](
        b_idx, c_idx, reactor, awaited^,
        request_timeout_us=request_timeout_us,
    )

    # ---- Extract response ---------------------------------------------
    var resp_hdrs = HeaderMap()
    var resp_body_bytes = List[UInt8]()
    ref h2_for_extract = pool_owned[].h2_state_at(b_idx, c_idx)
    var resp_tuple = extract_response_for_stream(h2_for_extract, sid)
    var status = UInt32(Int(resp_tuple[0]))
    swap(resp_hdrs, resp_tuple[1])
    swap(resp_body_bytes, resp_tuple[2])
    # retire the completed stream's
    # per-connection state (frees its response Lists, recycles slots, heals the
    # conn send window, drops the POD entry) so a long-lived REUSED conn does not
    # accumulate O(N) closed-stream state and wedge on the 120s wall bound. This
    # is the path `send_buffered` -> the GCS JSON object API -> `rewrite_object`
    # drives ~1867 times on ONE pooled conn during `GcpWebFrontend._publish`.
    # ⛔ Trailer section before the retire — see the sibling arm above.
    var resp_trailers = extract_trailers_for_stream(h2_for_extract, sid)
    h2_for_extract.retire_stream(sid)

    # Release stream slot (END_STREAM reached) — wakes pending waiters.
    pool_owned[].release_stream_slot(b_idx, c_idx)

    # Enforce max_body_bytes.
    if len(resp_body_bytes) > max_body_bytes:
        raise Error(
            "HttpError[BODY_TOO_LARGE]: h2 response body "
            + String(len(resp_body_bytes))
            + " bytes exceeds max " + String(max_body_bytes)
        )

    var resp_body = BufferedResponseBody.from_bytes(resp_body_bytes^)
    var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
    buf_resp.status = Int32(Int(status))
    buf_resp.reason = String("")
    buf_resp.headers = resp_hdrs^
    buf_resp.trailers = resp_trailers^
    # h2 conns LIVE in the pool; the response does NOT
    # represent connection-close (multiplex semantics — other streams
    # may still be in flight). v1 set connection_close=True (single-
    # shot); flips to False for proper multiplex semantics.
    buf_resp.connection_close = False
    return _PooledH2DriveResult[C2.Stream](
        response=buf_resp^,
        pool_owned=pool_owned^,
    )


def _drive_batch_h2_buffered_on_pool[
    RT: Runtime, C2: Connector, B: RequestBody,
](
    var pool_owned: OwnedPointer[H2ClientPool[C2.Stream]],
    b_idx: Int,
    c_idx: Int,
    var reqs: List[ClientRequest[B]],
    var bodies: List[B],
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> _PooledH2BatchDriveResult[C2.Stream]:
    """Drive K concurrent h2 requests on ONE pooled
    conn at (b_idx, c_idx) — the multiplexed analog of
    `_drive_one_h2_buffered_on_pool`. `reqs[i]` / `bodies[i]` are the i-th
    request; `responses[i]` is its response.

    Phases (each is a straight loop-lift of the single-request path, using the
    exact same per-iteration `ref h2 = pool_owned[].h2_state_at(b,c)` borrow
    scope so no `ref` is held across the drive call):

      1. ENCODE-loop: for each request, allocate a stream-id + create_stream +
         encode HEADERS(+DATA) into the shared `pending_out`. Collect the sids.
      2. DRIVE-ONCE: `drive_request_on_pooled_conn` with the FULL awaited-sids
         list — the driver interleaves the K streams to END_STREAM (proven by
         `test_h2_driver_multiplex_three_streams_interleaved`). This is what h2
         multiplexing is for: K concurrent in-flight streams on one connection.
      3. EXTRACT-loop: for each sid, extract the response, `retire_stream(sid)`
         (frees per-stream state + heals the conn send window), and
         `release_stream_slot`.

    Caller invariant: all `reqs` target the SAME authority (one pooled conn) and
    K <= the peer's max_concurrent_streams. Callers bound K (the mirror uses 32).

    `request_timeout_us`: the caller's authored per-request budget (0 = none),
    resolved by `h2_drive_wall_us`. ⚠ IT BOUNDS THE WHOLE K-STREAM DRIVE, not
    each stream — this is ONE `drive_request_on_pooled_conn` call awaiting K
    sids, so K concurrent streams share one wall. That is the honest reading of
    a per-REQUEST budget applied to a batched send, and it is stated rather than
    silently assumed.
    """
    var n = len(reqs)
    var sids = List[UInt32]()

    # Consume the request + body Lists front-to-back via a reverse-then-pop:
    # `List.pop()` removes the LAST element (a clean owned move-out, no
    # non-Copyable index-move); reversing first makes pop() yield the requests in
    # their original order. This is the canonical owned-List-drain idiom.
    reqs.reverse()
    bodies.reverse()

    # ---- Phase 1: encode all K requests into pending_out. ----
    var qi = 0
    while qi < n:
        # Move out req + body for THIS iteration (consume-per-send, same as the
        # single-request path).
        var req_local = reqs.pop()
        var body_local = bodies.pop()

        var scheme_local: String = String("https") if req_local.url.is_https() else String(
            "http"
        )
        var host_for_authority = req_local.url.host_copy()
        var authority_str = host_for_authority^
        var port_int = req_local.url.effective_port()
        var default_port: UInt16 = UInt16(443) if req_local.url.is_https() else UInt16(80)
        if port_int != default_port:
            authority_str = authority_str + String(":") + String(Int(port_int))
        var path_str = String(req_local.url.path)
        if req_local.url.query.byte_length() > 0:
            path_str = path_str + String("?") + String(req_local.url.query)
        var method_str = req_local.method.name()

        var body_bytes = List[UInt8]()
        var cl = body_local.content_length()
        if cl > 0:
            # DOUBLE-DRAIN FIX (see the single-request path): rewind a replayable
            # body before draining so its DATA frame reaches the wire.
            if body_local.replayable():
                body_local.rewind()
            _ = drain_body_into[B](body_local, body_bytes)
        var has_body = len(body_bytes) > 0
        var end_stream_on_headers = not has_body

        var hdrs_copy = HeaderMap()
        swap(hdrs_copy, req_local.headers)

        ref h2_for_encode = pool_owned[].h2_state_at(b_idx, c_idx)
        var sid = allocate_client_stream_id_or_raise(h2_for_encode)
        _ = h2_for_encode.create_stream(sid)
        encode_request_headers_to_frames(
            h2_for_encode, sid,
            method_str^,
            scheme_local^,
            authority_str^,
            path_str^,
            hdrs_copy^,
            end_stream=end_stream_on_headers,
        )
        if has_body:
            encode_request_data_frame(
                h2_for_encode, sid, body_bytes^, end_stream=True
            )
        sids.append(sid)
        _ = req_local^
        _ = body_local^
        qi = qi + 1

    # ---- Phase 2: drive the ONE conn to completion for ALL K streams. ----
    var awaited = List[UInt32]()
    var wi = 0
    while wi < len(sids):
        awaited.append(sids[wi])
        wi = wi + 1
    pool_owned[].drive_request_on_pooled_conn[RT](
        b_idx, c_idx, reactor, awaited^,
        request_timeout_us=request_timeout_us,
    )

    # ---- Phase 3: extract + retire each completed stream. ----
    var responses = List[ClientResponse[BufferedResponseBody]]()
    var xi = 0
    while xi < len(sids):
        var sid = sids[xi]
        var resp_hdrs = HeaderMap()
        var resp_body_bytes = List[UInt8]()
        ref h2_for_extract = pool_owned[].h2_state_at(b_idx, c_idx)
        var resp_tuple = extract_response_for_stream(h2_for_extract, sid)
        var status = UInt32(Int(resp_tuple[0]))
        swap(resp_hdrs, resp_tuple[1])
        swap(resp_body_bytes, resp_tuple[2])
        # Retire this stream's per-connection state (prune + heal send window) —
        # keeps the conn bounded across an arbitrarily large batch.
        # ⛔ Trailer section before the retire — see `_drive_one_h2_on_pool`.
        var resp_trailers = extract_trailers_for_stream(h2_for_extract, sid)
        h2_for_extract.retire_stream(sid)
        pool_owned[].release_stream_slot(b_idx, c_idx)

        if len(resp_body_bytes) > max_body_bytes:
            raise Error(
                "HttpError[BODY_TOO_LARGE]: h2 batch response body "
                + String(len(resp_body_bytes))
                + " bytes exceeds max " + String(max_body_bytes)
            )
        var resp_body = BufferedResponseBody.from_bytes(resp_body_bytes^)
        var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
        buf_resp.status = Int32(Int(status))
        buf_resp.reason = String("")
        buf_resp.headers = resp_hdrs^
        buf_resp.trailers = resp_trailers^
        buf_resp.connection_close = False
        responses.append(buf_resp^)
        xi = xi + 1

    return _PooledH2BatchDriveResult[C2.Stream](
        responses=responses^,
        pool_owned=pool_owned^,
    )


def _run_one_request_h2_buffered[
    RT: Runtime, S: IoStream, B: RequestBody,
](
    var req: ClientRequest[B],
    var body: B,
    var stream: S,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> ClientResponse[BufferedResponseBody]:
    """The h2 branch. Drives the h2 codec on a freshly
    dialed + ALPN-h2 stream:

      1. queue_client_preface_and_settings (24-byte PRI + initial SETTINGS)
      2. allocate stream_id + create_stream
      3. encode_request_headers_to_frames (and DATA if body has bytes)
      4. drive_h2_streams_to_completion until END_STREAM
      5. extract_response_for_stream -> (status, headers, body)

    v1: one h2 stream per send call, conn lives only for this call
    (no pool reuse across calls; that's). The 8-concurrent-streams
    multiplex gate is satisfied by `send_concurrent_h2` (see below) which
    drives N streams on ONE conn within one call.

    max_body_bytes is checked AFTER extract — h2 doesn't pre-cap body
    accumulation during drain (that's a v2 hardening item).
    """
    # Build an h2 conn state on the stack — single-owner, no pool yet.
    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    # Allocate stream_id + register stream.
    var sid = allocate_client_stream_id_or_raise(h2)
    _ = h2.create_stream(sid)

    # Pseudo-headers from the request's URL.
    var scheme_local: String = String("https") if req.url.is_https() else String(
        "http"
    )
    var host_for_authority = req.url.host_copy()
    var authority_str = host_for_authority^
    # If non-default port, include it in :authority.
    var port_int = req.url.effective_port()
    var default_port: UInt16 = UInt16(443) if req.url.is_https() else UInt16(80)
    if port_int != default_port:
        authority_str = authority_str + String(":") + String(Int(port_int))
    var path_str = String(req.url.path)
    if req.url.query.byte_length() > 0:
        path_str = path_str + String("?") + String(req.url.query)
    # Method as :method pseudo-header.
    var method_str = req.method.name()

    # v1 body shape: drain into a buffer (EmptyBody returns 0 bytes
    # immediately; BytesBody returns its drained bytes). Streaming bodies
    # are for h2.
    var body_bytes = List[UInt8]()
    var cl = body.content_length()
    if cl > 0:
        # DOUBLE-DRAIN FIX (h2 POST-with-body body-loss). `build_request_with_body`
        # pre-drains the body conformer's cursor to EOF to serialize the h1
        # `request_bytes`, then stores the (now-exhausted) conformer. The h1
        # transport consumes that pre-serialized body; the h2 transport rebuilds its
        # own frames FROM the conformer and re-drains it — so a REPLAYABLE (fully
        # buffered) body MUST be rewound first, else `read_chunk` returns 0, the DATA
        # frame is omitted, and the server receives a body-LESS POST (empty request
        # body). This is why the ONLY affected caller was the GCS JSON object API —
        # the sole `alpn_h2=True` + `build_request_with_body` + `send_buffered` user;
        # every other POST-with-body caller dials the default h1 connector, whose
        # path reads the correct body from `request_bytes`. A NON-replayable
        # (streaming) body is never pre-drained (build_streaming_request skips the
        # drain), so it is drained as-is.
        if body.replayable():
            body.rewind()
        _ = drain_body_into[B](body, body_bytes)
    var has_body = len(body_bytes) > 0
    var end_stream_on_headers = not has_body

    # Stash a copy of headers so we don't move req's owned HeaderMap
    # twice; we still want req.url accessible later for diagnostics.
    var hdrs_copy = HeaderMap()
    swap(hdrs_copy, req.headers)
    encode_request_headers_to_frames(
        h2, sid,
        method_str^,
        scheme_local^,
        authority_str^,
        path_str^,
        hdrs_copy^,
        end_stream=end_stream_on_headers,
    )
    if has_body:
        encode_request_data_frame(h2, sid, body_bytes^, end_stream=True)

    # Drive the conn until END_STREAM on our stream.
    var awaited = List[UInt32]()
    awaited.append(sid)
    drive_h2_streams_to_completion[S, RT](
        h2, stream, reactor, awaited^,
        max_wall_us=h2_drive_wall_us(request_timeout_us),
    )

    # Extract response from h2 state.
    var resp_tuple = extract_response_for_stream(h2, sid)
    var status = resp_tuple[0]
    var resp_hdrs = HeaderMap()
    swap(resp_hdrs, resp_tuple[1])
    var resp_body_bytes = List[UInt8]()
    swap(resp_body_bytes, resp_tuple[2])
    # The trailer section, kept apart from the head — see `ClientResponse`.
    # This arm does not retire the stream (single-shot conn), so there is no
    # ordering hazard here; the spelling matches the pooled arms deliberately.
    var resp_trailers = extract_trailers_for_stream(h2, sid)

    # Enforce max_body_bytes after the fact (v1).
    if len(resp_body_bytes) > max_body_bytes:
        raise Error(
            "HttpError[BODY_TOO_LARGE]: h2 response body "
            + String(len(resp_body_bytes))
            + " bytes exceeds max " + String(max_body_bytes)
        )

    var resp_body = BufferedResponseBody.from_bytes(resp_body_bytes^)
    var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
    buf_resp.status = Int32(Int(status))
    buf_resp.reason = String("")  # h2 has no reason phrase per RFC 9113 §8.1.2.4
    buf_resp.headers = resp_hdrs^
    buf_resp.trailers = resp_trailers^
    # h2 conn is single-shot in v1; treat as connection-close for
    # caller's purposes.
    buf_resp.connection_close = True
    return buf_resp^


def _run_one_request_buffered[
    RT: Runtime, C2: Connector, B: RequestBody,
](
    var req: ClientRequest[B],
    var body: B,
    mut connector: C2,
    mut reactor: Reactor[RT.Sink],
    max_body_bytes: Int,
    request_timeout_us: Int = 0,
) raises -> ClientResponse[BufferedResponseBody]:
    """Shape. Dial via the connector, drive head-write +
    body-write + head-read + body-slurp into one BufferedResponseBody.
    The stream is dropped after the body is fully collected (RAII
    close). Same field-access pattern as _run_one_request_streaming.

    Every real dispatch goes through `_run_one_request_buffered_h1` /
    `..._with_dispatch`, which are different functions. This one is kept
    BOUNDED anyway, because a dead unbounded path is
    the template the next author copies."""
    var is_https = req.url.is_https()
    var is_http = req.url.is_http()
    _scheme_check_or_raise[C2](is_https, is_http, connector)
    var host_str = req.url.host_copy()
    var port = req.url.effective_port()
    var ip_be = _ip_be_from_host(host_str, port)
    # ★ PER-REQUEST SNI — the host, not just the address. See
    # `Connector.set_dial_host`.
    # ⚠ THIS HELPER CONSULTS NO POOL AND ALWAYS DIALS, so the resolve
    # above it is unconditional BY CONSTRUCTION and there is nothing here
    # to make lazy. The `HttpClient` methods that DO probe a pool resolve
    # at their dial points instead (`_resolve_dial_ip_be`); do not copy
    # this shape into one of them.
    connector.set_dial_host(host_str.copy())
    var stream = connector.connect[RT](
        reactor=reactor, ip_be=ip_be, port=port,
    )
    # capture
    # the HEAD-method flag BEFORE swapping out request_bytes so the
    # OutboundDriver can short-circuit the body-collect path. Per
    # RFC 7230 §3.3.2 a HEAD response MUST NOT have a body even
    # with `Content-Length` set.
    var is_head = Int(req.method.code) == Int(HTTP_METHOD_HEAD)
    # Swap out request_bytes (rather than partial-move via `^`) so the
    # field is left in a destructor-safe (empty) state. Same pattern
    # for Optional.take() on body — the borrow-check is then permissive
    # at function exit.
    var req_bytes = List[UInt8]()
    swap(req_bytes, req.request_bytes)
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_max_response_body_bytes(max_body_bytes)
    driver.set_is_head_request(is_head)
    # Bound BOTH phases. 0 keeps the generous driver default; any positive
    # value bounds head+body out of one budget (see
    # `OutboundDriver.set_request_timeout_us`).
    if request_timeout_us > 0:
        driver.set_request_timeout_us(request_timeout_us)
    # stream the request body via run_with_body, then drain the
    # response into a BufferedResponseBody via collect_body.
    var scratch_buf_sp5 = _allocate_local_read_head_scratch()
    var streaming_resp = driver.run_with_body[C2.Stream, RT, B](
        stream^, body^, reactor, Span[UInt8](scratch_buf_sp5),
    )
    var tok = CancellationToken.never()
    var body_bytes = collect_body[RT, C2.Stream](
        streaming_resp.body, reactor, tok,
    )
    var resp_body = BufferedResponseBody.from_bytes(body_bytes^)
    var buf_resp = ClientResponse[BufferedResponseBody](resp_body^)
    buf_resp.status = streaming_resp.status
    var reason_tmp = String()
    swap(reason_tmp, streaming_resp.reason)
    buf_resp.reason = reason_tmp^
    var hdrs_tmp = HeaderMap()
    swap(hdrs_tmp, streaming_resp.headers)
    buf_resp.headers = hdrs_tmp^
    buf_resp.connection_close = streaming_resp.connection_close
    return buf_resp^


# =============================================================================
# §3 — Host → ip_be resolution helper (IP-literal fast path + DNS fallback).
# =============================================================================
# DNS is now a GENERAL HttpClient capability. This single
# helper is the chokepoint EVERY dial site routes through (`call`, `send`,
# `_call_pooled_self_c`, `send_streaming_pooled_get`,
# `issue_streaming_*_nonblocking`, …), so wiring resolution HERE makes
# hostname-dialing work for every HttpClient consumer (the LLM client, broker,
# S3, future connectors) with zero per-consumer change.
#
# Resolution policy:
#   1. IP-LITERAL FAST PATH — if `host` is a loopback alias ("", "localhost",
#      "127.0.0.1") or a dotted-quad IPv4 literal, parse it directly with ZERO
#      DNS latency and ZERO getaddrinfo call. This preserves the existing
#      loopback / IP-literal behavior BYTE-FOR-BYTE (the broker, S3 SigV4, and
#      the local-LLM 127.0.0.1 path are unchanged).
#   2. DNS FALLBACK — otherwise `host` is a DNS name; resolve it via
#      `resolve_host_be` (blocking getaddrinfo on the calling thread, never on
#      a reactor thread — see dns.mojo §2.2). Returns the first A record's
#      network-byte-order ip_be, exactly the shape this dial path already
#      consumed for literals.
#
# Both branches return the SAME UInt32 ip_be the Connector.connect path wants,
# so no dial site changes. `port` is threaded for getaddrinfo's service hint.


def _ip_be_from_host(host: String, port: UInt16 = UInt16(0)) raises -> UInt32:
    """Resolve `host` to a network-byte-order IPv4 `ip_be`.

    IP-LITERAL FAST PATH: a loopback alias ("", "localhost", "127.0.0.1") or a
    dotted-quad IPv4 literal is parsed directly (no DNS). DNS FALLBACK: any
    other host is treated as a DNS name and resolved via getaddrinfo
    (`resolve_host_be`) — A/AAAA lookup, first A record wins.

    Examples:
      "127.0.0.1"        -> 0x0100007F (little-endian view of [127,0,0,1]).
      "localhost"        -> loopback (fast path, no getaddrinfo).
      "api.example.com"  -> first A record's ip_be (getaddrinfo).

    Raises Error on a malformed IP literal OR on DNS failure (NXDOMAIN /
    transient / no A record). IPv6 is NOT yet dialable (the Connector interface
    accepts only UInt32 ip_be; an IPv6 connector variant would extend this).

    `port` is forwarded to getaddrinfo as the service hint; it does not affect
    the IP-literal fast path. Callers that already hold the dial port should
    pass it; the 0 default keeps the literal-only call sites source-compatible.
    """
    # IP-LITERAL FAST PATH: loopback aliases + dotted-quad literals.
    # `parse_ip_literal` returns Some(IpAddr) for a literal, None for a name
    # (→ needs DNS), and raises only on a MALFORMED literal (octet > 255, bad
    # dot count). This is the exact classification the dial path needs.
    var lit = parse_ip_literal(host)
    if lit:
        return lit.value().v4_be

    # DNS FALLBACK: `host` is a DNS name. Resolve it (blocking getaddrinfo on
    # the calling thread — correct-by-construction for the per-core
    # run-to-completion model; never executes inside poll_completions).
    #
    # ⛔⛔ THIS IS THE UNBOUNDED PHASE OF EVERY COLD DIAL, AND THE BREADCRUMB
    # BELOW DOES NOT BOUND IT. `getaddrinfo(3)` is a BLOCKING libc call with no
    # timeout argument and no cancellation: the ONLY thing that ends it is the
    # resolver's own `options timeout:N attempts:M`, which no caller here
    # states. A `deadline_us` parameter checked around this line would be a
    # measurement wearing a deadline's name — the thread is still inside libc
    # when it fires. A REAL bound needs a resolve this runtime can abandon (a
    # reactor-driven resolver), not a check at this call site.
    #
    # ⚠ AND THE DEADLINE CANNOT COME FROM `Connector.connect` EITHER. That
    # trait takes `ip_be: UInt32` — an ALREADY-RESOLVED address — so DNS
    # happens HERE, strictly BEFORE the connector is entered. Threading a
    # deadline through its 22 conformers would bound the TCP connect (already
    # 5s) and the TLS handshake (already 30s) and would change NO worst case.
    var dns_start_ns = Int64(_mono_now_ns())
    try:
        var ip_be = resolve_host_be(host, port)
        _ = note_slow_phase(
            SLOW_PHASE_DNS,
            host,
            elapsed_ms_since(dns_start_ns, Int64(_mono_now_ns())),
        )
        return ip_be
    except resolve_err:
        # A resolve that RAISES after a long wall is the SAME finding as one
        # that succeeds slowly — a 30s NXDOMAIN is wedge evidence too. Report
        # before re-raising, so the breadcrumb is not conditional on success.
        _ = note_slow_phase(
            SLOW_PHASE_DNS,
            host,
            elapsed_ms_since(dns_start_ns, Int64(_mono_now_ns())),
        )
        raise resolve_err


def _ipv4_literal_be(host: String) raises -> UInt32:
    """LEGACY IPv4-literal-ONLY parse (no DNS, no loopback alias). Retained for
    callers / tests that want the strict dotted-quad parse with the historical
    `HttpError[URL_INVALID]` messages and reject anything non-numeric. The
    general dial path uses `_ip_be_from_host` (literal fast path + DNS)
    instead. Returns the network-byte-order packed UInt32.

    Examples:
      "127.0.0.1" -> 0x0100007F (little-endian view of [127,0,0,1]).
      "0.0.0.0"   -> 0
    Raises Error on invalid format.
    """
    var bytes_ref = host.as_bytes()
    var n = len(bytes_ref)
    if n == 0:
        raise Error("HttpError[URL_INVALID]: empty host")
    # Find 3 '.' separators -> 4 octets.
    var octets = Array[UInt32, 4](fill=UInt32(0))
    var octet_idx = 0
    var v: UInt32 = UInt32(0)
    var digits_in_octet = 0
    var i = 0
    while i < n:
        var b = bytes_ref[i]
        if b == UInt8(ord(".")):
            if digits_in_octet == 0:
                raise Error("HttpError[URL_INVALID]: bad IPv4 literal")
            if octet_idx >= 3:
                raise Error("HttpError[URL_INVALID]: too many dots")
            octets[octet_idx] = v
            octet_idx = octet_idx + 1
            v = UInt32(0)
            digits_in_octet = 0
        else:
            var c = Int(b)
            if c < Int(ord("0")) or c > Int(ord("9")):
                raise Error("HttpError[URL_INVALID]: non-digit in IPv4 octet")
            v = v * UInt32(10) + UInt32(c - Int(ord("0")))
            if v > UInt32(255):
                raise Error("HttpError[URL_INVALID]: IPv4 octet > 255")
            digits_in_octet = digits_in_octet + 1
        i = i + 1
    # Final octet.
    if octet_idx != 3 or digits_in_octet == 0:
        raise Error("HttpError[URL_INVALID]: incomplete IPv4 literal")
    octets[3] = v
    # Pack network-byte-order: octets[0] is the high byte on the wire
    # (the most significant octet). In big-endian byte order on a
    # little-endian arch, ip_be expected by komira_async TcpStream is
    # the "as it sits in memory" UInt32 reading [o0,o1,o2,o3] in
    # network order. The matching helper in
    # src/komira_async/reactor/socket_setup.mojo:inet_loopback_be()
    # returns the loopback 127.0.0.1 encoded as 0x0100007F on
    # little-endian — i.e. the bytes in memory are [127,0,0,1] read in
    # ascending address order. We follow that convention here.
    return (
        octets[0]
        | (octets[1] << UInt32(8))
        | (octets[2] << UInt32(16))
        | (octets[3] << UInt32(24))
    )


def pool_key_for_origin(host: String, port: UInt16, is_http: Bool) -> PoolKey:
    """The single origin->key
    derivation used by BOTH the streaming pooled checkout and the caller-side
    reclaim, so the checkout key and the reclaim key are byte-identical.
    Plaintext http → `PoolKey.http`; else https with peer verification."""
    if is_http:
        return PoolKey.http(host, port)
    return PoolKey.https(host, port, VERIFY_PEER)


# =============================================================================
# §4 — Convenience builders for ClientRequest from typed surfaces.
# =============================================================================
# These are the most common call shapes — wrap a Url + headers + body
# into a ClientRequest. The writer call is hidden so the caller doesn't
# have to plumb the request_bytes List separately.


def build_get_request(
    var url: Url, var headers: HeaderMap,
) -> ClientRequest[EmptyBody]:
    """Build a GET request. No body."""
    var bytes = List[UInt8]()
    serialize_request_head(method_get(), url, headers, 0, bytes)
    return ClientRequest[EmptyBody](
        method=method_get(),
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=EmptyBody.new(),
    )


def build_head_request(
    var url: Url, var headers: HeaderMap,
) -> ClientRequest[EmptyBody]:
    """Build a HEAD request. No body."""
    var bytes = List[UInt8]()
    serialize_request_head(method_head(), url, headers, 0, bytes)
    return ClientRequest[EmptyBody](
        method=method_head(),
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=EmptyBody.new(),
    )


def build_delete_request(
    var url: Url, var headers: HeaderMap,
) -> ClientRequest[EmptyBody]:
    """Build a DELETE request. No body (the REST DELETE resource endpoints — e.g.
    Postmark `DELETE /servers/{id}` / `DELETE /domains/{id}` — take an empty body).
    The bodyless-verb twin of `build_get_request` / `build_head_request`."""
    var bytes = List[UInt8]()
    serialize_request_head(method_delete(), url, headers, 0, bytes)
    return ClientRequest[EmptyBody](
        method=method_delete(),
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=EmptyBody.new(),
    )


def build_request_with_body[B: RequestBody](
    method: HttpMethod,
    var url: Url,
    var headers: HeaderMap,
    var body: B,
) -> ClientRequest[B]:
    """Build a request with a body conformer. The body's bytes are
    drained into the request_bytes buffer after the head.

    The body conformer is also stored in the returned ClientRequest's
    `body` field — for now this field is reserved (StreamingBody
    in activates it for wire-time draining). For BytesBody /
    EmptyBody, request_bytes already carries the body bytes so the
    field is effectively a typed marker."""
    var bytes = List[UInt8]()
    var cl = body.content_length()
    serialize_request_head(method, url, headers, cl, bytes)
    # The body must be drained BEFORE the parameter is moved; for
    # BytesBody (the buffered case) draining empties the cursor
    # and the conformer is then a typed-only marker for ClientRequest's
    # B parameter binding. A StreamingBody skips this drain — the
    # body field carries the stream and gets drained on the wire.
    var _drained = drain_body_into[B](body, bytes)
    return ClientRequest[B](
        method=method,
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=body^,
    )


def build_streaming_request[B: RequestBody](
    method: HttpMethod,
    var url: Url,
    var headers: HeaderMap,
    var body: B,
) -> ClientRequest[B]:
    """Build a request with a STREAMING body conformer.

    Unlike `build_request_with_body`, this builder does NOT drain the
    body upfront. The HEAD is serialized into `request_bytes` (with the
    body's `content_length()` reflected in the Content-Length header);
    the body field carries the un-drained conformer; `HttpClient.send`
    drains it on the wire via `OutboundDriver.run_with_body`.

    Result: RSS stays flat at scratch-buffer size (64 KiB) regardless
    of body size. The body is never copied; bytes flow directly from
    `body.read_chunk(dst)` to `stream.try_write(dst)`.

    Use for StreamingBody / large PUT uploads where slurping the full
    body into a List[UInt8] would blow the RSS gate.
    """
    var bytes = List[UInt8]()
    var cl = body.content_length()
    serialize_request_head(method, url, headers, cl, bytes)
    # NOTE: NO drain_body_into call here — that's the whole point of
    # streaming. The body field carries the un-drained conformer; the
    # OutboundDriver's run_with_body drives `body.read_chunk` to the
    # wire post-head-write.
    return ClientRequest[B](
        method=method,
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=body^,
    )
