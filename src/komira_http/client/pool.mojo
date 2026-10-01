# =============================================================================
# src/komira_http/client/pool.mojo — Connection pool
# =============================================================================
#
# This file ships the connection-pool surface:
#   * `PoolKey` — 4-field identity (scheme + host + port + verify_mode).
#   * `ClientConn[S: IoStream]` — per-connection state owned by the pool.
#   * `ConnectionPool` — trait (associated `Stream` type) for the pool surface.
#   * `PerCorePool[S: IoStream]` — per-pthread, lock-free conformer.
#   * `PendingCheckout[S: IoStream]` — late-binding race handle.
#   * `PoolSizingKnobs` — POD config (max_conns_per_host / max_idle_per_host /
#     idle_threshold_us / recv_ring_size).
#
# Design:
#   * The pool is runtime-model-dependent. PerCorePool is the
#     critical path; a work-stealing SharedPool is a separate shape.
#   * Per-pthread, lock-free — every operation is single-thread access
#     under PerCoreAsync. ClientConn is non-Copyable (owns an fd via
#     TcpStream / TlsStream), so the buckets are Slab-backed.
#   * PoolKey carries `verify_mode` — a connection
#     opened with verify=true MUST NEVER be returned to a checkout
#     expecting verify=false (silent security downgrade).
#   * PendingCheckout is the late-binding race winner — backed by
#     `SelectFirstNotify` from `komira_async.sync.select`.
#
# Why ClientConn is parametric on `S: IoStream`:
#   The same pool shape works for KernelTcpConnector.Stream (production),
#   ScriptedConnector.Stream (tests), and TlsConnector[
#   KernelTcpConnector].Stream (HTTPS). Single-trait monomorphization
#   per call site; ZERO fn-ptr indirection per the zero-`blr` rule.
#
# Why ConnectionPool is a trait with `comptime Stream: IoStream`:
#   A `trait ConnectionPool[RT: Runtime]` with a `PerCorePool` conformer
#   was the starting point. Empirical Mojo 1.0.0b1 finding: the cleanest shape is a trait that carries
#   the Stream as an associated type — single-pool-instance per Stream
#   type, no RT parameter on the trait itself (the RT.RUNTIME_MODEL
#   selection happens at the consumer call site via `@parameter if`).
#   Adding `alias Pool: ConnectionPool` to the Runtime trait is deferred
#   to when SharedPool also needs it.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee` (the `swap` / Optional.take / OwnedPointer.into_inner
#     patterns suffice).
#   * ZERO ArcPointer (the one ArcPointer in this slot's surface lives
#     INSIDE SelectFirstNotify — we consume the handle, never the inner
#     Arc).
#   * ZERO additive parallel API.
#   * Pointer audit: ClientConn[S] owns a heap-owning S field
#     (TcpStream / TlsStream); IF stored in a byte-slab via wildcard
#     origin, this is the stale-pointer shape. We use Slab[OwnedPointer[ClientConn[S]]]
#     — OwnedPointer is the stable heap handle the slab cannot defeat
#     lifetime-tracking on. specifically
#     specifies this shape.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer

from komira_core.collections.slab import Slab

from komira_async.sync.select import SelectFirstNotify

from komira_http.client.clock import Clock
from komira_http.transport.io_stream import IoStream


# =============================================================================
# §1 — Scheme + verify_mode sentinels
# =============================================================================
#
# UInt8 namespaces; comptime values. No comptime enums in Mojo 1.0.0b1
# (same pattern as TRANSPORT_KIND_* and RUNTIME_MODEL_*).

comptime SCHEME_HTTP: UInt8 = 0
"""Plaintext HTTP. Default for `http://...` URLs."""

comptime SCHEME_HTTPS: UInt8 = 1
"""TLS-secured HTTP. Default for `https://...` URLs. wires the
HTTPS-scheme dispatch."""

comptime VERIFY_PEER: UInt8 = 0
"""Standard cert-chain + hostname verification. The default. Connections
opened with VERIFY_PEER live in their own PoolKey bucket — never shared
with VERIFY_SKIP."""

comptime VERIFY_SKIP: UInt8 = 1
"""Skip verification entirely (the dev-MinIO / self-signed-cert path,
). MUST NEVER be returned to a checkout expecting VERIFY_PEER —
that is a silent security downgrade."""

# -----------------------------------------------------------------------------
# §1a — Negotiated-ALPN discriminator.
# -----------------------------------------------------------------------------
#
# PoolKey carries a `negotiated_alpn` discriminator so h1 and h2 connections
# pool into DISJOINT buckets even on the same (scheme, host, port,
# verify_mode) tuple. This is the cleanest way to keep the sibling pool
# architecture (PerCorePool for h1, H2ClientPool for h2) safe from
# accidental cross-protocol bucket-key collisions.
#
# Values are UInt8 (compact, struct-packed):
#   * ALPN_UNKNOWN (0) — used by the h1 path which does not consult ALPN
#     and by direct `PoolKey.http()` / `PoolKey.https()` factories.
#   * ALPN_H1 (1)      — reserved for explicit h1-on-https keys (used by
#     a caller that wants to force-segment).
#   * ALPN_H2 (2)      — h2 multiplex bucket. The H2ClientPool's lookups
#     pass this value so h1 conns are NEVER mistakenly found.

comptime ALPN_UNKNOWN: UInt8 = 0
"""Default; used by h1-path and existing callers. h2 keys MUST
override to ALPN_H2."""

comptime ALPN_H1: UInt8 = 1
"""Explicit "this connection is h1 over TLS" (rare;+ reserved
for cases where the caller wants to force-segment h1+h2 even on the
same origin tuple)."""

comptime ALPN_H2: UInt8 = 2
"""Explicit "this connection is h2 over TLS". H2ClientPool's keys
always carry this value. Disjoint from ALPN_UNKNOWN at hash + eq
time → guarantees h1 and h2 buckets never collide."""


# =============================================================================
# §2 — PoolKey — 5-field bucket identity
# =============================================================================
#
# Connections are poolable iff ALL fields match. Never pool across
# origins (host:port mismatch), and never pool across incompatible TLS
# verification contexts.
#
# Copyable + Movable: PoolKey is a value type the bucket-map / checkout
# / checkin all copy freely. The `host` field is a String (heap), so
# the actual copy cost is one allocation per PoolKey-by-value pass; for
# the hot path the pool maintains a Slab indexed by a hash + scans for
# equality (NOT a Dict — Mojo 1.0.0b1 Dict-value Copyable requirement
# would force OwnedPointer-vs-Movable arithmetic;).


struct PoolKey(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Identity of a connection-pool bucket. Connections are poolable
    iff ALL FIVE fields match.

    Fields:
      scheme           — SCHEME_HTTP / SCHEME_HTTPS.
      host             — string-form host (IP-literal in; DNS-resolved
                         name). Copyable, so the bucket map can store
                         by value.
      port             — UInt16 (TCP port). Zero is invalid.
      verify_mode      — VERIFY_PEER / VERIFY_SKIP. Separates pools so a
                         verify=true checkout never receives a verify=false
                         connection.
      negotiated_alpn  — ALPN_UNKNOWN / ALPN_H1 / ALPN_H2.
                         discriminator: keeps h1 + h2 buckets disjoint
                         even when the same (scheme, host, port,
                         verify_mode) tuple holds connections for both
                         protocols. Existing callers via
                         `.http()` / `.https()` factories default this to
                         ALPN_UNKNOWN; the h2-dispatch path passes
                         ALPN_H2 via `.https_h2()`.
    """

    var scheme: UInt8
    var host: String
    var port: UInt16
    var verify_mode: UInt8
    var negotiated_alpn: UInt8

    def __init__(
        out self,
        scheme: UInt8,
        var host: String,
        port: UInt16,
        verify_mode: UInt8,
        negotiated_alpn: UInt8 = ALPN_UNKNOWN,
    ):
        self.scheme = scheme
        self.host = host^
        self.port = port
        self.verify_mode = verify_mode
        self.negotiated_alpn = negotiated_alpn

    @staticmethod
    def http(var host: String, port: UInt16) -> PoolKey:
        """Construct an HTTP PoolKey with VERIFY_PEER (irrelevant for
        plaintext, but consistent — keeps the default-bucket invariant).
        negotiated_alpn=ALPN_UNKNOWN (h1-by-default)."""
        return PoolKey(
            scheme=SCHEME_HTTP, host=host^, port=port,
            verify_mode=VERIFY_PEER,
            negotiated_alpn=ALPN_UNKNOWN,
        )

    @staticmethod
    def https(var host: String, port: UInt16, verify_mode: UInt8) -> PoolKey:
        """Construct an HTTPS PoolKey with explicit verify_mode.
        negotiated_alpn=ALPN_UNKNOWN (h1-by-default; callers wanting
        h2-multiplex buckets must use `.https_h2()`)."""
        return PoolKey(
            scheme=SCHEME_HTTPS, host=host^, port=port,
            verify_mode=verify_mode,
            negotiated_alpn=ALPN_UNKNOWN,
        )

    @staticmethod
    def https_h2(
        var host: String, port: UInt16, verify_mode: UInt8,
    ) -> PoolKey:
        """Construct an HTTPS PoolKey tagged for the h2 multiplex
        bucket. H2ClientPool.try_checkout calls this; the discriminator
        ensures h1 conns are never matched against an h2 lookup."""
        return PoolKey(
            scheme=SCHEME_HTTPS, host=host^, port=port,
            verify_mode=verify_mode,
            negotiated_alpn=ALPN_H2,
        )

    @staticmethod
    def http_h2(var host: String, port: UInt16) -> PoolKey:
        """Construct a PLAINTEXT (cleartext) PoolKey
        tagged for the h2 multiplex bucket — i.e. h2c PRIOR KNOWLEDGE (no ALPN,
        no HTTP/1.1 Upgrade; the client speaks HTTP/2 from the first byte). Used
        ONLY by the gRPC-to-a-plaintext-emulator path (`send_grpc_pooled`'s
        http:// branch); production GCP gRPC is always https_h2.

        scheme=SCHEME_HTTP keeps these conns in a DISTINCT bucket from any
        https_h2 bucket (so a plaintext h2c conn is never matched against a
        TLS h2 lookup, and vice-versa); negotiated_alpn=ALPN_H2 is the same
        h2-multiplex discriminator https_h2 uses. verify_mode=VERIFY_PEER is a
        don't-care for plaintext (kept consistent with `.http()`)."""
        return PoolKey(
            scheme=SCHEME_HTTP, host=host^, port=port,
            verify_mode=VERIFY_PEER,
            negotiated_alpn=ALPN_H2,
        )

    def __eq__(self, other: PoolKey) -> Bool:
        """Equality: all 5 fields match."""
        if self.scheme != other.scheme:
            return False
        if self.port != other.port:
            return False
        if self.verify_mode != other.verify_mode:
            return False
        if self.negotiated_alpn != other.negotiated_alpn:
            return False
        # String equality.
        if self.host.byte_length() != other.host.byte_length():
            return False
        var n = self.host.byte_length()
        var a = self.host.as_bytes()
        var b = other.host.as_bytes()
        var i = 0
        while i < n:
            if a[i] != b[i]:
                return False
            i = i + 1
        return True

    def __ne__(self, other: PoolKey) -> Bool:
        return not (self == other)

    def hash_u64(self) -> UInt64:
        """FNV-1a-style hash of the 5 fields. Used by the bucket map's
        linear-probe lookup (Mojo 1.0.0b1 Dict has Copyable-value
        constraints incompatible with OwnedPointer storage — see RFC
        §6.1; the in-tree pool uses a Slab + linear scan for;
        the hash is a fast-path discriminator).

        extends the fold to include `negotiated_alpn` so h1 and
        h2 keys hash to disjoint values even at the same host:port.
        """
        var h: UInt64 = UInt64(0xCBF29CE484222325)  # FNV offset basis
        var prime: UInt64 = UInt64(0x100000001B3)
        h = (h ^ UInt64(self.scheme)) * prime
        # 16-bit port -> 2 byte mixes.
        h = (h ^ UInt64(self.port & UInt16(0xFF))) * prime
        h = (h ^ UInt64((self.port >> UInt16(8)) & UInt16(0xFF))) * prime
        h = (h ^ UInt64(self.verify_mode)) * prime
        # ALPN discriminator (one extra byte mix).
        h = (h ^ UInt64(self.negotiated_alpn)) * prime
        var n = self.host.byte_length()
        var bytes = self.host.as_bytes()
        var i = 0
        while i < n:
            h = (h ^ UInt64(bytes[i])) * prime
            i = i + 1
        return h


# =============================================================================
# §3 — Pool-sizing knobs
# =============================================================================
#
# All knobs live in one POD struct so HttpClientConfig can carry one
# `pool_sizing: PoolSizingKnobs` field rather than 4+ scalars.
#
# Defaults match except where's "test-level (a) gate"
# carve-out narrows them (the production max_conns_per_host=256 is
# replaced by a smaller default of 32 here; the higher value is's
# concern once HTTPS + real TCP are wired).


@fieldwise_init
struct PoolSizingKnobs(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Pool sizing tunables.

    Fields:
      max_conns_per_host    — hard cap on total in-use+idle conns per
                              PoolKey. Default 32. Beyond this, checkouts
                              queue via PendingCheckout. (Production
                              loads may want 256.)
      max_idle_per_host     — cap on idle (reusable) conns kept in the
                              bucket. Default 16. Excess idle conns past
                              checkin are closed instead of pooled.
      recv_ring_size        — per-connection recv-ring size in bytes.
                              Default 65536 (64 KiB). NOT load-bearing in
                              (no recv-ring consumer here yet);
                              shipped for forward-compat with.
      idle_threshold_us     — eviction threshold; conns idle longer than
                              this are closed on the next evict_idle
                              sweep. Default 60_000_000 us (60s).
    """

    var max_conns_per_host: Int
    var max_idle_per_host: Int
    var recv_ring_size: Int
    var idle_threshold_us: Int

    @staticmethod
    def defaults() -> PoolSizingKnobs:
        return PoolSizingKnobs(
            max_conns_per_host=32,
            max_idle_per_host=16,
            recv_ring_size=64 * 1024,
            idle_threshold_us=60_000_000,
        )


# =============================================================================
# §4 — ClientConn[S: IoStream] — per-connection state
# =============================================================================
#
# "ClientConn is the per-connection object — the IoStream
# (a TcpIoStream or TlsStream), the L2 protocol state (H1 or H2), the
# per-connection recv ring, and the outbound state machine."
#
# ships the IoStream + idle metadata (last_used_us, healthy flag).
# The L2 / recv-ring / state-machine integration is scope.
#
# Parametric on `S: IoStream` so KernelTcpConnector / ScriptedConnector /
# TlsConnector[KernelTcpConnector] all share the pool shape with ZERO
# code duplication. Mojo 1.0.0b1 monomorphizes per S.
#
# Movable, NOT Copyable — owns S (which is non-Copyable; TcpStream /
# ScriptedStream / TlsStream all own fds or scripts that move-only).


struct ClientConn[S: IoStream](Movable, Deinitable):
    """Per-connection state owned by the connection pool.

    Parametric on `S: IoStream` so the same pool shape covers
    KernelTcpConnector.Stream, ScriptedConnector.Stream, and
    TlsConnector[KernelTcpConnector].Stream.

    Fields:
      _stream         — the live IoStream (consumed on close()).
      _key            — back-pointer to the bucket's PoolKey for
                        sanity checks on checkin.
      _last_used_us   — monotonic timestamp set by `mark_used`; the
                        idle-eviction sweep compares against the pool's
                        Clock.
      _is_healthy     — set False by checkin if the response indicated
                        a broken connection (Connection: close, framing
                        error, IO error). Broken conns are dropped, not
                        pooled.

    Construction:
      * `ClientConn.new(stream, key, now_us)` — fresh conn returned
        from a Connector.connect; pool marks it used at construction.
    """

    var _stream: Self.S
    var _key: PoolKey
    var _last_used_us: Int
    var _is_healthy: Bool

    @staticmethod
    def new(
        var stream: Self.S, var key: PoolKey, now_us: Int,
    ) -> ClientConn[Self.S]:
        return ClientConn[Self.S](
            _stream=stream^,
            _key=key^,
            _last_used_us=now_us,
            _is_healthy=True,
        )

    def __init__(
        out self,
        var _stream: Self.S,
        var _key: PoolKey,
        _last_used_us: Int,
        _is_healthy: Bool,
    ):
        self._stream = _stream^
        self._key = _key^
        self._last_used_us = _last_used_us
        self._is_healthy = _is_healthy

    def mark_used(mut self, now_us: Int):
        """Bump last_used to `now_us`. Called by checkin so the next
        eviction sweep starts the idle clock from this point."""
        self._last_used_us = now_us

    def mark_unhealthy(mut self):
        """Mark this connection as broken. The pool will drop it on
        checkin instead of returning it to the idle slab."""
        self._is_healthy = False

    def is_healthy(self) -> Bool:
        return self._is_healthy

    def last_used_us(self) -> Int:
        return self._last_used_us

    def key(self) -> PoolKey:
        return self._key

    def stream_ref(ref self) -> ref [self._stream] Self.S:
        """Borrowed reference to the underlying IoStream — used by
        the consumer to drive a request-response cycle without
        relinquishing pool ownership.

        Per the ref-return reframe / RUNTIME-MENU §4.0 capability
        matrix #5, `ref [self._stream] Self.S` is the spelling that
        compiles on Mojo 1.0.0b1 (a `ref [self]` return is rejected
        because the receiver origin might expand to a register-passable
        type).
        """
        return self._stream

    # NOTE: `into_stream(var self) -> Self.S` would partial-move
    # `self._stream`; Mojo 1.0.0b1's borrow checker rejects that
    # (per the pointer rules — partial-move via take_pointee /
    # field-take is banned outside primitive modules). When a
    # ClientConn is dropped (not pooled), the OwnedPointer wrapper
    # drops it normally, which drops `_stream` via Self.S's __del__.
    # Stream.close() runs through that path.


# =============================================================================
# §4a — _PendingCheckoutShared[S] + PendingCheckout[S]
# =============================================================================
#
# (the late-binding race): "If a checkout has to dial, but
# a pooled connection becomes free before the dial completes, the
# request takes the pooled connection and the in-progress dial either
# backfills the pool or is dropped. This is fundamentally a RACE of two
# events — {a freed pooled conn, a completed dial} — and the checkout
# must await whichever resolves first."
#
# wires the FIRST source — "a freed pooled conn" — via SelectFirstNotify's
# fire_source_0 path. The bucket holds a FIFO queue of pending waiters; on
# checkin (when waiters exist and conn is healthy), the bucket installs the
# conn into the oldest waiter's shared slot + fires source 0.
#
# Source 1 (fresh-dial wins) is wired in's SharedPool, where the
# dial-in-progress lives on a peer worker; for PerCorePool (single-thread
# access), the dial completion is synchronous on the same pthread, so
# the consumer doesn't park on a race with itself. The SelectFirstNotify
# API supports source 1 by construction; just calls fire_source_1.
#
# Shared state lifecycle:
#   * Constructor allocates _PendingCheckoutShared on the heap via
#     ArcPointer (ArcPointer is the last resort
#     for shared ownership; here the bucket writes + awaiter reads —
#     genuine multi-owner state).
#   * PendingCheckout (the public handle) holds one ArcPointer clone.
#   * The bucket's `_waiters` Slab holds another ArcPointer clone (kept
#     until checkin fulfills + removes).
#   * On checkin: bucket fills the slot, fires source 0, removes from
#     queue. The bucket's clone drops; only the PendingCheckout's clone
#     remains.
#   * On await(): the PendingCheckout calls SelectFirstNotify.await_first;
#     when it returns, takes the conn from the slot.


struct _PendingCheckoutShared[S: IoStream](
    Movable, Deinitable,
):
    """Heap-allocated shared state for a PendingCheckout.

    Fields:
      _race      — SelectFirstNotify handle for the two-source first-fires
                   gate (source 0 = freed-from-checkin; source 1 = fresh
                   dial wins —). Tracks the wake-by-address protocol.
      _slot      — the resolved ClientConn slot. The bucket writes into
                   this via swap when checkin fires source 0; the awaiter
                   takes it after await_first returns.
      _key       — back-pointer for sanity checks (the bucket only
                   fulfills with a matching-key conn).
    """

    var _race: SelectFirstNotify
    var _slot: Optional[OwnedPointer[ClientConn[Self.S]]]
    var _key: PoolKey

    def __init__(out self, var _key: PoolKey):
        self._race = SelectFirstNotify.new()
        self._slot = Optional[OwnedPointer[ClientConn[Self.S]]]()
        self._key = _key^


struct PendingCheckout[S: IoStream](Movable, Deinitable):
    """Late-binding checkout handle.

    Returned by `PerCorePool.checkout_or_pending` when the bucket is at
    capacity. The caller awaits via `await_conn(mut self)`; the bucket
    fulfills via its checkin path (source 0) or its peer-dial completion
    in (source 1).

    Construction is pool-internal. Movable; NOT Copyable. The handle
    holds an ArcPointer to shared state; the bucket holds another
    ArcPointer clone in its `_waiters` slab.

    Methods:
      * `await_conn(mut self) raises -> OwnedPointer[ClientConn[Self.S]]`
        — park until source 0 (or source 1) fires; then take the
        conn from the shared slot.
      * `key(self) -> PoolKey` — diagnostic.
    """

    var _shared: ArcPointer[_PendingCheckoutShared[Self.S]]

    @staticmethod
    def _new(var key: PoolKey) -> PendingCheckout[Self.S]:
        return PendingCheckout[Self.S](
            _shared=ArcPointer[_PendingCheckoutShared[Self.S]](
                _PendingCheckoutShared[Self.S](key^),
            ),
        )

    def __init__(
        out self,
        var _shared: ArcPointer[_PendingCheckoutShared[Self.S]],
    ):
        self._shared = _shared^

    def key(self) -> PoolKey:
        return self._shared[]._key

    def await_conn(mut self) raises -> OwnedPointer[ClientConn[Self.S]]:
        """Park until the race fires (source 0 = freed-from-checkin,
        source 1 = fresh-dial). Returns the OwnedPointer to the
        ClientConn that was installed.

        Raises if the slot is empty after the wake (should not happen
        in correct usage — the firing context fills the slot BEFORE
        fire_source_*).
        """
        var _winner = self._shared[]._race.await_first()
        if not self._shared[]._slot.__bool__():
            raise Error(
                "PendingCheckout.await_conn: race fired but slot empty"
            )
        var conn = self._shared[]._slot.take()
        return conn^

    def _clone_handle_for_bucket(self) -> ArcPointer[
        _PendingCheckoutShared[Self.S]
    ]:
        """Pool-internal: clone the inner ArcPointer for the bucket's
        `_waiters` slab. Both handles point at the same heap state."""
        return ArcPointer[_PendingCheckoutShared[Self.S]](
            copy=self._shared,
        )


# =============================================================================
# §5 — _PoolBucket[S] — per-PoolKey storage
# =============================================================================
#
# Holds the idle list + an in-use counter + a FIFO waiter queue for one
# bucket. Movable, NOT Copyable.
#
# Pointer audit: ClientConn[S] owns a heap-owning S field. The
# slab stores OwnedPointer[ClientConn[S]] — OwnedPointer is the stable
# heap handle the slab cannot defeat lifetime-tracking on (
# #3). Stale-pointer-safe.


struct _PoolBucket[S: IoStream](Movable, Deinitable):
    """Idle + in-use connections for one PoolKey. Movable, NOT
    Copyable.

    The idle slab stores OwnedPointer-wrapped ClientConn so the
    parent slab is pointer-safe.

    `_in_use_count` is an Int (not Atomic) because PerCorePool is
    SINGLE-THREAD-ACCESS — every operation runs on the owning pthread.
    SharedPool would use Atomic + sharded locks.
    """

    var _key: PoolKey
    var _idle: Slab[OwnedPointer[ClientConn[Self.S]]]
    var _in_use_count: Int
    # FIFO queue of pending checkouts. Each entry is a shared
    # `_PendingCheckoutShared[S]` handle (ArcPointer-backed) that
    # both the bucket (writer of the resolved conn slot + fire_source_0
    # caller) and the awaiting PendingCheckout (reader of the conn
    # slot + await_first caller) hold. Drained by checkin when a
    # conn is freed.
    var _waiters: Slab[ArcPointer[_PendingCheckoutShared[Self.S]]]

    def __init__(out self, var _key: PoolKey):
        self._key = _key^
        self._idle = Slab[OwnedPointer[ClientConn[Self.S]]]()
        self._in_use_count = 0
        self._waiters = Slab[ArcPointer[_PendingCheckoutShared[Self.S]]]()

    def key(self) -> PoolKey:
        return self._key

    def in_use(self) -> Int:
        return self._in_use_count

    def idle_count(self) -> Int:
        return self._idle.len()

    def waiter_count(self) -> Int:
        return self._waiters.len()

    def total_count(self) -> Int:
        return self._in_use_count + self._idle.len()


# =============================================================================
# §6 — CheckoutOutcome — discriminated result of a checkout attempt
# =============================================================================
#
# `PerCorePool.try_checkout` returns ONE of:
#   * Ready(conn)    — an idle conn is available; consumer drives it.
#   * NeedsDial      — bucket is below max_conns; caller should dial
#                      via the Connector and call `insert_dialed`.
#   * AtCapacity     — bucket is at max_conns_per_host; caller must
#                      wait via PendingCheckout.
#
# POD discriminated union; the conn payload is owned by the caller
# when state == READY.

comptime CHECKOUT_READY: UInt8 = 0
"""Idle connection available; conn returned by value."""

comptime CHECKOUT_NEEDS_DIAL: UInt8 = 1
"""No idle conn but bucket has capacity; caller dials + calls
insert_dialed."""

comptime CHECKOUT_AT_CAPACITY: UInt8 = 2
"""Bucket at max_conns_per_host; caller must wait via
PendingCheckout."""


struct CheckoutOutcome[S: IoStream](Movable, Deinitable):
    """Outcome of PerCorePool.try_checkout.

    Use the discriminator (`is_ready` / `is_needs_dial` / `is_at_capacity`)
    to decide the next step.

    For READY: call `take_conn()` to consume the ClientConn (the
    OwnedPointer of which is returned). The outcome must be discarded
    after take.

    For NEEDS_DIAL / AT_CAPACITY: no payload to extract.
    """

    var _state: UInt8
    var _conn: Optional[OwnedPointer[ClientConn[Self.S]]]

    @staticmethod
    def ready(
        var conn: OwnedPointer[ClientConn[Self.S]],
    ) -> CheckoutOutcome[Self.S]:
        return CheckoutOutcome[Self.S](
            _state=CHECKOUT_READY,
            _conn=Optional[OwnedPointer[ClientConn[Self.S]]](conn^),
        )

    @staticmethod
    def needs_dial() -> CheckoutOutcome[Self.S]:
        return CheckoutOutcome[Self.S](
            _state=CHECKOUT_NEEDS_DIAL,
            _conn=Optional[OwnedPointer[ClientConn[Self.S]]](),
        )

    @staticmethod
    def at_capacity() -> CheckoutOutcome[Self.S]:
        return CheckoutOutcome[Self.S](
            _state=CHECKOUT_AT_CAPACITY,
            _conn=Optional[OwnedPointer[ClientConn[Self.S]]](),
        )

    def __init__(
        out self,
        _state: UInt8,
        var _conn: Optional[OwnedPointer[ClientConn[Self.S]]],
    ):
        self._state = _state
        self._conn = _conn^

    def is_ready(self) -> Bool:
        return self._state == CHECKOUT_READY

    def is_needs_dial(self) -> Bool:
        return self._state == CHECKOUT_NEEDS_DIAL

    def is_at_capacity(self) -> Bool:
        return self._state == CHECKOUT_AT_CAPACITY

    def state(self) -> UInt8:
        return self._state

    def take_conn(mut self) raises -> OwnedPointer[ClientConn[Self.S]]:
        """Take the ClientConn from a READY outcome. Raises if not
        READY (programmer error — call is_ready first)."""
        if self._state != CHECKOUT_READY:
            raise Error("CheckoutOutcome.take_conn: not in READY state")
        if not self._conn.__bool__():
            raise Error("CheckoutOutcome.take_conn: payload already taken")
        var c = self._conn.take()
        return c^


# =============================================================================
# §7 — ConnectionPool trait + PerCorePool[S] conformer
# =============================================================================
#
# The trait surface — `try_checkout` returns a CheckoutOutcome; `checkin`
# takes a conn back. `insert_dialed` adds a freshly-dialed conn. The
# race API (`checkout_or_pending`) wraps the trait surface with the
# SelectFirstNotify-backed PendingCheckout.
#
# Why not a parametric `[RT: Runtime]` on the trait: per the
# preflight D1, the comptime selection happens at the consumer call
# site via `@parameter if RT.RUNTIME_MODEL == MODEL_SHARE_NOTHING_PER_CORE`
# — the trait itself stays minimal. Adding `alias Pool: ConnectionPool`
# to Runtime is work (when SharedPool also needs it).


trait ConnectionPool(Movable, Deinitable):
    """Connection-pool surface. Conformers: PerCorePool,
    SharedPool.

    Associated type `Stream`: the IoStream type buckets store. One
    pool instance = one Stream type;'s HTTPS path constructs a
    second pool instance bound to TlsConnector[KernelTcpConnector].Stream.

    Methods are non-blocking (no parking — that's PendingCheckout's
    job). Single-thread-access for PerCorePool; SharedPool will add
    sharded locks under the same surface.
    """

    comptime Stream: IoStream & Movable & Deinitable

    def try_checkout(
        mut self, var key: PoolKey, now_us: Int,
    ) raises -> CheckoutOutcome[Self.Stream]:
        """Attempt to check out a connection for `key`.

        Returns:
          * CheckoutOutcome.ready(conn)  — idle conn available.
          * CheckoutOutcome.needs_dial() — caller should dial via
            Connector and call insert_dialed.
          * CheckoutOutcome.at_capacity() — bucket at
            max_conns_per_host; caller must wait via PendingCheckout


        `now_us` is passed in so the caller's clock controls the
        eviction window.
        """
        ...

    def checkin(
        mut self,
        var conn: OwnedPointer[ClientConn[Self.Stream]],
        now_us: Int,
    ) raises:
        """Return `conn` to the pool. If unhealthy or the bucket
        exceeds max_idle_per_host, the conn is dropped instead of
        pooled. The conn's last_used_us is set to `now_us`.
        """
        ...

    def insert_dialed(mut self, var key: PoolKey) raises:
        """Record a freshly-dialed connection in the pool's in-use
        counter for `key`. The caller HOLDS the conn (the pool
        doesn't take ownership at dial time — only at checkin).
        This bumps `_in_use_count` and `_dials_total`.

        Call flow:
          1. try_checkout(key) -> NEEDS_DIAL.
          2. var stream = connector.connect(...).
          3. var conn = OwnedPointer(ClientConn.new(stream, key, now)).
          4. pool.insert_dialed(key).
          5. ... caller uses conn ...
          6. pool.checkin(conn, now) when done.
        """
        ...

    def evict_idle(mut self, now_us: Int, idle_threshold_us: Int) -> Int:
        """Evict idle connections that have been idle longer than
        `idle_threshold_us`. Returns the number of evicted conns.

        Single-pass sweep across all buckets. The caller's clock is
        consulted via `now_us`."""
        ...

    def release_in_use(mut self, var key: PoolKey):
        """Decrement the in-use counter for `key`. Called when a
        conn was checked out (via try_checkout READY) but the
        caller does NOT want to return it to the pool (drop path).
        """
        ...


struct PerCorePool[S: IoStream](
    ConnectionPool, Movable, Deinitable,
):
    """Per-pthread, lock-free connection pool.

    Storage: a flat Slab of `_PoolBucket[S]`, indexed by linear scan
    on PoolKey. The PoolKey count is small (1-16 distinct origins
    in any realistic load) so linear scan is cheaper than the Dict
    workaround (the in-tree Dict has Copyable-value constraints
    that conflict with `OwnedPointer[_PoolBucket]`).

    Single-thread-access by design. NO atomics. NO locks. Every
    operation is single-thread-access under PerCoreAsync.

    Parametric on `S: IoStream` — one pool instance per IoStream type
    (production HTTPS path constructs a separate PerCorePool[TlsStream
    [TcpIoStream]] in).

    Fields:
      _buckets       — Slab of buckets (linear-scan resolved by key).
      _sizing        — PoolSizingKnobs (max_conns / max_idle / etc.).
      _dials_total   — diagnostic counter; a reuse check uses this to
                       verify ≥95% reuse warm.
    """

    comptime Stream = Self.S

    var _buckets: Slab[_PoolBucket[Self.S]]
    var _sizing: PoolSizingKnobs
    var _dials_total: Int

    @staticmethod
    def new(sizing: PoolSizingKnobs) -> PerCorePool[Self.S]:
        return PerCorePool[Self.S](
            _buckets=Slab[_PoolBucket[Self.S]](),
            _sizing=sizing,
            _dials_total=0,
        )

    @staticmethod
    def with_defaults() -> PerCorePool[Self.S]:
        return PerCorePool[Self.S].new(PoolSizingKnobs.defaults())

    def __init__(
        out self,
        var _buckets: Slab[_PoolBucket[Self.S]],
        _sizing: PoolSizingKnobs,
        _dials_total: Int,
    ):
        self._buckets = _buckets^
        self._sizing = _sizing
        self._dials_total = _dials_total

    def sizing(self) -> PoolSizingKnobs:
        return self._sizing

    def dials_total(self) -> Int:
        """Diagnostic: total dials performed (insert_dialed calls).
        Used by the pool-reuse test to verify reuse ratio."""
        return self._dials_total

    def bucket_count(self) -> Int:
        return self._buckets.len()

    # ----- Internal: linear-scan bucket lookup -------------------------------

    def _find_bucket_idx(self, key: PoolKey) -> Int:
        """Return the slab index of the bucket for `key`, or -1 if
        no bucket exists yet."""
        var n = self._buckets.len()
        var i = 0
        while i < n:
            if self._buckets[i].key() == key:
                return i
            i = i + 1
        return -1

    def _ensure_bucket(mut self, var key: PoolKey) -> Int:
        """Return the slab index of the bucket for `key`, creating
        an empty bucket if none exists. Returns the index of the
        possibly-newly-created bucket."""
        var idx = self._find_bucket_idx(key)
        if idx >= 0:
            return idx
        self._buckets.append(_PoolBucket[Self.S](key^))
        return self._buckets.len() - 1

    # ----- Public surface ----------------------------------------------------

    def try_checkout(
        mut self, var key: PoolKey, now_us: Int,
    ) raises -> CheckoutOutcome[Self.Stream]:
        """Attempt to check out a connection for `key`.

        Algorithm:
          1. Find the bucket (creating empty if absent).
          2. If idle has any conn (and the conn is healthy), pop the
             newest one (LIFO — cache-warm), bump in_use, mark used,
             return READY.
          3. Else if (in_use + 0) < max_conns_per_host, return NEEDS_DIAL.
          4. Else return AT_CAPACITY (caller waits via PendingCheckout).
        """
        var idx = self._ensure_bucket(key^)
        # Pop a healthy idle conn (LIFO for cache locality).
        # We pop until we hit a healthy one OR the idle slab is empty.
        while self._buckets[idx]._idle.len() > 0:
            var maybe = self._buckets[idx]._idle.pop()
            if not maybe.__bool__():
                break
            # Optional[OwnedPointer].take() moves out (OwnedPointer is
            # Movable not Copyable; .value() would try to copy).
            var conn_ptr = maybe.take()
            if conn_ptr[].is_healthy():
                # Mark used; bump in_use; return.
                conn_ptr[].mark_used(now_us)
                self._buckets[idx]._in_use_count = (
                    self._buckets[idx]._in_use_count + 1
                )
                return CheckoutOutcome[Self.Stream].ready(conn_ptr^)
            # Unhealthy idle conn — let it drop here (conn_ptr drops).
            _ = conn_ptr^
        # No idle conn; check capacity.
        var total = self._buckets[idx].total_count()
        if total < self._sizing.max_conns_per_host:
            return CheckoutOutcome[Self.Stream].needs_dial()
        return CheckoutOutcome[Self.Stream].at_capacity()

    def insert_dialed(mut self, var key: PoolKey) raises:
        """A fresh dial completed — bump in_use for `key`. The caller
        HOLDS the conn (the pool doesn't take ownership at dial time);
        the conn comes back to the pool only via checkin.

        This records the dial in `dials_total` for the reuse-ratio
        diagnostic + bumps the bucket's in_use counter so the bucket's
        capacity math is correct.
        """
        var idx = self._ensure_bucket(key^)
        self._buckets[idx]._in_use_count = (
            self._buckets[idx]._in_use_count + 1
        )
        self._dials_total = self._dials_total + 1

    def note_dial(mut self):
        """Record one h1 dial that this pool does NOT manage the connection
        for — `_dials_total` only, no bucket and no `_in_use_count`.

        ★ WHY THIS IS NOT `insert_dialed`. That one also bumps the bucket's
        `_in_use_count`, on the contract "the caller HOLDS the conn and returns
        it via `checkin`". The keepalive paths that call THIS one
        (`HttpClient._call_pooled_self_c`, and the stale-conn redial arm of
        `_dispatch_pooled_buffered`) never check a connection in — they stash it
        on the client's own `_h1_idle_conn` slot — so `insert_dialed` there
        would ratchet `_in_use_count` up forever against a bucket nothing ever
        releases.

        `dials_total` is the client's ONLY dial counter, and a dial it cannot
        see is an observability hole that lets a client churn its
        pool for a long time while reading exactly like a healthy one:
        a stale-connection redial is otherwise INVISIBLE. Counting the dial and
        declining to fake the bucket accounting is the honest half."""
        self._dials_total = self._dials_total + 1

    def checkin(
        mut self,
        var conn: OwnedPointer[ClientConn[Self.Stream]],
        now_us: Int,
    ) raises:
        """Return `conn` to the pool. If unhealthy OR the bucket's
        idle list is at max_idle_per_host, drop the conn instead of
        pooling.

        Late-binding: if the bucket has pending waiters AND
        the conn is healthy, the conn is handed to the oldest waiter
        (FIFO) via its shared slot + fire_source_0. The waiter's
        `await_conn` then takes the conn. The in_use counter stays the
        same (the conn moved from this caller to the waiter; both count
        as in_use).

        Decrements in_use_count when the conn is NOT handed to a
        waiter (the normal pool-back-to-idle or drop path).
        """
        var k = conn[].key()
        var idx = self._find_bucket_idx(k)
        if idx < 0:
            # No bucket -- conn must have come from outside the pool;
            # drop it.
            return
        # Healthy + waiter present -> hand to waiter (no in_use change;
        # conn ownership transfers from this caller to the waiter).
        if (
            conn[].is_healthy()
            and self._buckets[idx]._waiters.len() > 0
        ):
            # Pop oldest waiter (FIFO -- the queue is push-back, so
            # the head is index 0).
            var waiter = self._buckets[idx]._waiters.take_at(0)
            # Install conn in the waiter's shared slot.
            conn[].mark_used(now_us)
            waiter[]._slot = Optional[
                OwnedPointer[ClientConn[Self.Stream]]
            ](conn^)
            # Fire source 0 -- the awaiter wakes up.
            waiter[]._race.fire_source_0()
            # Drop the bucket's ArcPointer clone; the awaiter's clone
            # remains.
            _ = waiter^
            return
        # No waiter (or unhealthy) -- standard path.
        self._buckets[idx]._in_use_count = (
            self._buckets[idx]._in_use_count - 1
        )
        if not conn[].is_healthy():
            # Drop unhealthy.
            return
        if self._buckets[idx]._idle.len() >= self._sizing.max_idle_per_host:
            # Idle list full -- drop.
            return
        # Mark used + push to idle.
        conn[].mark_used(now_us)
        self._buckets[idx]._idle.append(conn^)

    def release_in_use(mut self, var key: PoolKey):
        """Decrement in_use without inserting a conn. Used when the
        caller intentionally drops a checked-out conn (e.g. response
        framing error)."""
        var idx = self._find_bucket_idx(key)
        if idx < 0:
            return
        if self._buckets[idx]._in_use_count > 0:
            self._buckets[idx]._in_use_count = (
                self._buckets[idx]._in_use_count - 1
            )

    def evict_idle(mut self, now_us: Int, idle_threshold_us: Int) -> Int:
        """Evict idle conns whose last_used_us + idle_threshold_us <
        now_us. Returns the count of evicted conns.

        Sweep is per-bucket: for each bucket, scan idle slab and
        swap-remove evicted conns. The order within a bucket is
        rearranged (LIFO → out-of-order), which is fine — pool order
        is not load-bearing.
        """
        var evicted: Int = 0
        var nb = self._buckets.len()
        var bi = 0
        while bi < nb:
            # Walk idle slab in reverse so swap_remove(i) doesn't
            # invalidate indices we still need to visit.
            var ni = self._buckets[bi]._idle.len()
            var i = ni - 1
            while i >= 0:
                var lu = self._buckets[bi]._idle[i][].last_used_us()
                if (now_us - lu) > idle_threshold_us:
                    var _evicted_conn = (
                        self._buckets[bi]._idle.swap_remove(i)
                    )
                    # OwnedPointer drops the ClientConn (which closes
                    # the stream).
                    _ = _evicted_conn^
                    evicted = evicted + 1
                i = i - 1
            bi = bi + 1
        return evicted

    def idle_count_for(self, key: PoolKey) -> Int:
        """Diagnostic: how many idle conns the bucket for `key` holds.
        Returns 0 if no bucket exists."""
        var idx = self._find_bucket_idx(key)
        if idx < 0:
            return 0
        return self._buckets[idx]._idle.len()

    def in_use_for(self, key: PoolKey) -> Int:
        """Diagnostic: how many in-use conns the bucket for `key`
        records. Returns 0 if no bucket exists."""
        var idx = self._find_bucket_idx(key)
        if idx < 0:
            return 0
        return self._buckets[idx]._in_use_count

    def total_for(self, key: PoolKey) -> Int:
        """Diagnostic: total conns (in-use + idle) for `key`."""
        var idx = self._find_bucket_idx(key)
        if idx < 0:
            return 0
        return self._buckets[idx].total_count()

    def waiter_count_for(self, key: PoolKey) -> Int:
        """Diagnostic: how many pending checkouts the bucket for `key`
        currently queues."""
        var idx = self._find_bucket_idx(key)
        if idx < 0:
            return 0
        return self._buckets[idx]._waiters.len()

    def checkout_or_pending(
        mut self, var key: PoolKey, now_us: Int,
    ) raises -> CheckoutOrPendingOutcome[Self.Stream]:
        """The race-aware checkout primitive.

        Algorithm:
          * try_checkout(key) -> READY  -> return ready(conn).
          * try_checkout(key) -> NEEDS_DIAL -> return needs_dial();
            caller dials + calls insert_dialed.
          * try_checkout(key) -> AT_CAPACITY -> create a PendingCheckout,
            push the bucket-side clone of its shared ArcPointer to the
            bucket's FIFO waiter queue, and return pending(handle).
            The caller awaits via PendingCheckout.await_conn.

        Acceptance gate (g) is exercised by saturating the bucket past
        max_conns_per_host and verifying that the second checkout
        returns PENDING. Gate (f) is exercised by then checking in a
        conn and verifying the PENDING's await_conn resolves with
        the freed conn.
        """
        var outcome = self.try_checkout(key.copy(), now_us)
        if outcome.is_ready():
            var conn = outcome.take_conn()
            return CheckoutOrPendingOutcome[Self.Stream].ready(conn^)
        if outcome.is_needs_dial():
            return CheckoutOrPendingOutcome[Self.Stream].needs_dial()
        # AT_CAPACITY -> register a waiter on the bucket.
        var idx = self._ensure_bucket(key.copy())
        var pending = PendingCheckout[Self.Stream]._new(key^)
        # Clone for the bucket side.
        self._buckets[idx]._waiters.append(
            pending._clone_handle_for_bucket()
        )
        return CheckoutOrPendingOutcome[Self.Stream].pending(pending^)


# =============================================================================
# §8 — CheckoutOrPendingOutcome[S] — discriminated result of checkout_or_pending
# =============================================================================
#
# Three states:
#   * READY(conn)         -> consumer drives the conn.
#   * NEEDS_DIAL          -> consumer dials via Connector + insert_dialed.
#   * PENDING(handle)     -> consumer awaits via PendingCheckout.await_conn.
#
# Tests use the discriminator + appropriate take_* to extract payloads.

comptime COP_READY: UInt8 = 0
comptime COP_NEEDS_DIAL: UInt8 = 1
comptime COP_PENDING: UInt8 = 2


struct CheckoutOrPendingOutcome[S: IoStream](
    Movable, Deinitable,
):
    """Result of PerCorePool.checkout_or_pending — one of READY /
    NEEDS_DIAL / PENDING.

    For READY: call take_conn() to consume the ClientConn.
    For PENDING: call take_pending() to consume the PendingCheckout
    handle; then await_conn on it.
    For NEEDS_DIAL: no payload.
    """

    var _state: UInt8
    var _conn: Optional[OwnedPointer[ClientConn[Self.S]]]
    var _pending: Optional[PendingCheckout[Self.S]]

    @staticmethod
    def ready(
        var conn: OwnedPointer[ClientConn[Self.S]],
    ) -> CheckoutOrPendingOutcome[Self.S]:
        return CheckoutOrPendingOutcome[Self.S](
            _state=COP_READY,
            _conn=Optional[OwnedPointer[ClientConn[Self.S]]](conn^),
            _pending=Optional[PendingCheckout[Self.S]](),
        )

    @staticmethod
    def needs_dial() -> CheckoutOrPendingOutcome[Self.S]:
        return CheckoutOrPendingOutcome[Self.S](
            _state=COP_NEEDS_DIAL,
            _conn=Optional[OwnedPointer[ClientConn[Self.S]]](),
            _pending=Optional[PendingCheckout[Self.S]](),
        )

    @staticmethod
    def pending(
        var handle: PendingCheckout[Self.S],
    ) -> CheckoutOrPendingOutcome[Self.S]:
        return CheckoutOrPendingOutcome[Self.S](
            _state=COP_PENDING,
            _conn=Optional[OwnedPointer[ClientConn[Self.S]]](),
            _pending=Optional[PendingCheckout[Self.S]](handle^),
        )

    def __init__(
        out self,
        _state: UInt8,
        var _conn: Optional[OwnedPointer[ClientConn[Self.S]]],
        var _pending: Optional[PendingCheckout[Self.S]],
    ):
        self._state = _state
        self._conn = _conn^
        self._pending = _pending^

    def is_ready(self) -> Bool:
        return self._state == COP_READY

    def is_needs_dial(self) -> Bool:
        return self._state == COP_NEEDS_DIAL

    def is_pending(self) -> Bool:
        return self._state == COP_PENDING

    def state(self) -> UInt8:
        return self._state

    def take_conn(mut self) raises -> OwnedPointer[ClientConn[Self.S]]:
        """Take the conn from READY state. Raises otherwise."""
        if self._state != COP_READY:
            raise Error(
                "CheckoutOrPendingOutcome.take_conn: not in READY"
            )
        if not self._conn.__bool__():
            raise Error(
                "CheckoutOrPendingOutcome.take_conn: payload already taken"
            )
        var c = self._conn.take()
        return c^

    def take_pending(mut self) raises -> PendingCheckout[Self.S]:
        """Take the PendingCheckout from PENDING state. Raises
        otherwise."""
        if self._state != COP_PENDING:
            raise Error(
                "CheckoutOrPendingOutcome.take_pending: not in PENDING"
            )
        if not self._pending.__bool__():
            raise Error(
                "CheckoutOrPendingOutcome.take_pending: payload already taken"
            )
        var p = self._pending.take()
        return p^
