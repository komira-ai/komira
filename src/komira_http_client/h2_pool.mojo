# =============================================================================
# src/komira_http_client/h2_pool.mojo — HTTP/2 client pool (multiplex-aware)
# =============================================================================
#
# ship H2ClientPool as a SIBLING
# of the existing PerCorePool — h2 stream-multiplexing semantics live
# here without touching the h1 pool path.
#
# Key differences from PerCorePool[S]:
#   * One TCP connection can serve N concurrent streams (RFC 9113 §5.1).
#   * Checkout policy: pick the first non-draining conn with
#     open_streams < max_concurrent_streams_peer (Go #34944 avoidance).
#     Otherwise: dial new conn (until max_conns_per_host) or block.
#   * GOAWAY handling: on GOAWAY frame received, mark the conn draining;
#     reject new checkouts on it; complete in-flight requests where
#     stream_id <= last_processed_stream_id.
#   * Pool keyed on (scheme, host, port, verify_mode) — same shape as h1.
#
# Encapsulation:
#   * H2PooledConn holds OwnedPointer[ClientConn[S]] + H2ClientConnectionState
#     by value (heap-Movable + safe in Optional/Slab).
#   * No UnsafePointer in any sig. No wildcard. No additive parallel API
#     (this is a sibling pool, not a parallel "h1+h2 fast-path" on the
#     existing PerCorePool — they serve different protocols).
# =============================================================================

from std.memory import ArcPointer, OwnedPointer

from komira_async.sync.select import SelectFirstNotify
from komira_core.collections.slab import Slab

from komira_http_client.h2_client import (
    H2ClientConnectionState,
    drive_h2_streams_to_completion,
    h2_drive_wall_us,
)
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_client.pool import (
    ClientConn,
    PoolKey,
    PoolSizingKnobs,
)
from komira_http_core.transport.io_stream import IoStream


# =============================================================================
# §1 — H2PooledConn — per-conn h2 multiplex state.
# =============================================================================


struct H2PooledConn[S: IoStream](Movable, Deinitable):
    """A single h2 connection in the pool: owns the underlying ClientConn +
    its H2ClientConnectionState. Tracks draining state for GOAWAY handling.

    Fields:
      _client_conn   — owns the IoStream (TLS-wrapped TCP for HTTPS).
      _h2_state      — per-conn HpackEncoder/Decoder + flow controllers +
                       streams list + recv/pending byte buffers.
      _draining      — set True when SERVER emits GOAWAY (h2_state.is_goaway_received()
                       is the source of truth; this field is a cached
                       copy for the bucket's iteration without unpacking
                       the Optional).
      _key           — back-pointer to the bucket's PoolKey.
    """

    var _client_conn: ClientConn[Self.S]
    var _h2_state: H2ClientConnectionState
    var _draining: Bool
    var _key: PoolKey

    @staticmethod
    def new(
        var client_conn: ClientConn[Self.S],
        var h2_state: H2ClientConnectionState,
        var key: PoolKey,
    ) -> H2PooledConn[Self.S]:
        return H2PooledConn[Self.S](
            _client_conn=client_conn^,
            _h2_state=h2_state^,
            _draining=False,
            _key=key^,
        )

    def __init__(
        out self,
        var _client_conn: ClientConn[Self.S],
        var _h2_state: H2ClientConnectionState,
        _draining: Bool,
        var _key: PoolKey,
    ):
        self._client_conn = _client_conn^
        self._h2_state = _h2_state^
        self._draining = _draining
        self._key = _key^

    def is_draining(self) -> Bool:
        return self._draining or self._h2_state.is_goaway_received()

    def mark_draining(mut self):
        self._draining = True

    def open_streams(self) -> UInt32:
        return self._h2_state.open_streams_count()

    def max_concurrent_streams(self) -> UInt32:
        return self._h2_state.max_concurrent_streams_peer

    def can_accept_new_stream(self) -> Bool:
        """Go #34944 avoidance: only accept a new stream if this conn is
        not draining AND has not reached max_concurrent_streams_peer.

        Per RFC 9113 §5.1.2: a peer can lower this via SETTINGS at any
        time; the conn enforces by RST_STREAM(REFUSED_STREAM) on new
        streams beyond the limit. Our local-side check avoids the
        round-trip rejection by gating dial-side.
        """
        if self.is_draining():
            return False
        return self.open_streams() < self.max_concurrent_streams()

    def key(self) -> PoolKey:
        return self._key

    def h2_state_ref(ref self) -> ref [self._h2_state] H2ClientConnectionState:
        return self._h2_state

    def client_conn_ref(ref self) -> ref [self._client_conn] ClientConn[Self.S]:
        return self._client_conn


# =============================================================================
# §2 — H2PoolBucket — per-PoolKey storage.
# =============================================================================


struct _H2PoolBucket[S: IoStream](Movable, Deinitable):
    """Per-PoolKey storage for h2 multiplex connections.

    Unlike `_PoolBucket[S]` (h1) which has separate idle/in-use semantics,
    h2 conns are continuously in-use (one conn serves many streams). We
    track them in one Slab; the multiplex-checkout policy walks them
    looking for `can_accept_new_stream`.
    """

    var _key: PoolKey
    var _conns: Slab[OwnedPointer[H2PooledConn[Self.S]]]

    def __init__(out self, var _key: PoolKey):
        self._key = _key^
        self._conns = Slab[OwnedPointer[H2PooledConn[Self.S]]]()

    def key(self) -> PoolKey:
        return self._key

    def conn_count(self) -> Int:
        return self._conns.len()


# =============================================================================
# §3 — H2 checkout outcome.
# =============================================================================


comptime H2_CHECKOUT_FOUND: UInt8 = 0
"""An existing conn has capacity for a new stream; checkout returns its
slab index. Caller uses it via the pool's accessor."""

comptime H2_CHECKOUT_NEEDS_DIAL: UInt8 = 1
"""No conn for this key has capacity; bucket is below max_conns_per_host.
Caller dials a fresh conn + calls insert_dialed_h2."""

comptime H2_CHECKOUT_AT_CAPACITY: UInt8 = 2
"""Bucket is at max_conns_per_host AND all conns are at their
max_concurrent_streams_peer. Caller must wait (a
PendingCheckout-style waiter is the shape; this raises an HttpError)."""


struct H2CheckoutResult(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Outcome of H2ClientPool.try_checkout.

    For FOUND: `bucket_idx` + `conn_idx` index into the pool's buckets +
    bucket._conns; caller uses pool accessors with these indices.
    For NEEDS_DIAL / AT_CAPACITY: indices are -1 (programmer-error check).
    """

    var state: UInt8
    var bucket_idx: Int
    var conn_idx: Int

    @staticmethod
    def found(bucket_idx: Int, conn_idx: Int) -> H2CheckoutResult:
        return H2CheckoutResult(
            state=H2_CHECKOUT_FOUND,
            bucket_idx=bucket_idx,
            conn_idx=conn_idx,
        )

    @staticmethod
    def needs_dial() -> H2CheckoutResult:
        return H2CheckoutResult(
            state=H2_CHECKOUT_NEEDS_DIAL,
            bucket_idx=-1,
            conn_idx=-1,
        )

    @staticmethod
    def at_capacity() -> H2CheckoutResult:
        return H2CheckoutResult(
            state=H2_CHECKOUT_AT_CAPACITY,
            bucket_idx=-1,
            conn_idx=-1,
        )

    def __init__(out self, state: UInt8, bucket_idx: Int, conn_idx: Int):
        self.state = state
        self.bucket_idx = bucket_idx
        self.conn_idx = conn_idx

    def is_found(self) -> Bool:
        return self.state == H2_CHECKOUT_FOUND

    def is_needs_dial(self) -> Bool:
        return self.state == H2_CHECKOUT_NEEDS_DIAL

    def is_at_capacity(self) -> Bool:
        return self.state == H2_CHECKOUT_AT_CAPACITY


# =============================================================================
# §4 — H2ClientPool — multiplex-aware connection pool.
# =============================================================================


struct H2ClientPool[S: IoStream](Movable, Deinitable):
    """Per-pthread, multiplex-aware HTTP/2 client pool.

    Single-thread-access (no atomics). The h1 PerCorePool is unchanged;
    this is a SIBLING pool for HTTPS+h2 connections.

    Methods:
      * `try_checkout(key)` — find a conn with capacity for one more
        stream, or signal needs_dial / at_capacity.
      * `insert_dialed_h2(key, client_conn, h2_state)` — register a
        fresh h2 conn returned by the caller's dial + handshake.
      * `release_drained(bucket_idx, conn_idx)` — remove a draining +
        all-streams-closed conn from the bucket.
      * Pool-level accessors (h2_state_at, client_conn_at) return ref
        into the bucket's stored OwnedPointer.

    checkout does NOT block (no PendingCheckout shape). The
    refactor will add the SelectFirstNotify-backed waiter.
    """

    var _buckets: Slab[_H2PoolBucket[Self.S]]
    var _sizing: PoolSizingKnobs
    var _dials_total: Int
    var _pending_waiters: Slab[ArcPointer[_H2PendingCheckoutShared]]

    @staticmethod
    def new(sizing: PoolSizingKnobs) -> H2ClientPool[Self.S]:
        return H2ClientPool[Self.S](
            _buckets=Slab[_H2PoolBucket[Self.S]](),
            _sizing=sizing,
            _dials_total=0,
            _pending_waiters=Slab[ArcPointer[_H2PendingCheckoutShared]](),
        )

    @staticmethod
    def with_defaults() -> H2ClientPool[Self.S]:
        return H2ClientPool[Self.S].new(PoolSizingKnobs.defaults())

    def __init__(
        out self,
        var _buckets: Slab[_H2PoolBucket[Self.S]],
        _sizing: PoolSizingKnobs,
        _dials_total: Int,
        var _pending_waiters: Slab[ArcPointer[_H2PendingCheckoutShared]],
    ):
        self._buckets = _buckets^
        self._sizing = _sizing
        self._dials_total = _dials_total
        self._pending_waiters = _pending_waiters^

    def dials_total(self) -> Int:
        return self._dials_total

    def bucket_count(self) -> Int:
        return self._buckets.len()

    # ----- Internal: linear-scan bucket lookup -----------------------------

    def _find_bucket_idx(self, key: PoolKey) -> Int:
        var n = self._buckets.len()
        var i = 0
        while i < n:
            if self._buckets[i].key() == key:
                return i
            i = i + 1
        return -1

    def _ensure_bucket(mut self, var key: PoolKey) -> Int:
        var idx = self._find_bucket_idx(key)
        if idx >= 0:
            return idx
        self._buckets.append(_H2PoolBucket[Self.S](key^))
        return self._buckets.len() - 1

    # ----- Checkout / dial / release ---------------------------------------

    def try_checkout(
        mut self, var key: PoolKey,
    ) -> H2CheckoutResult:
        """Find a conn with capacity for one more stream. Walks the
        bucket's `_conns` Slab linearly; first conn with
        `can_accept_new_stream()` wins.

        Returns:
          * H2CheckoutResult.found(b_idx, c_idx) — use this conn
          * H2CheckoutResult.needs_dial()        — caller dials + inserts
          * H2CheckoutResult.at_capacity()       — caller blocks / raises
        """
        var b_idx = self._ensure_bucket(key^)
        # Linear scan for a non-draining conn with capacity.
        ref bucket = self._buckets[b_idx]
        var n = bucket._conns.len()
        var i = 0
        while i < n:
            ref conn = bucket._conns[i][]
            if conn.can_accept_new_stream():
                return H2CheckoutResult.found(b_idx, i)
            i = i + 1
        # No conn has capacity; check bucket capacity.
        if n < self._sizing.max_conns_per_host:
            return H2CheckoutResult.needs_dial()
        # All conns at capacity AND bucket at max — block.
        return H2CheckoutResult.at_capacity()

    def insert_dialed_h2(
        mut self,
        var key: PoolKey,
        var client_conn: ClientConn[Self.S],
        var h2_state: H2ClientConnectionState,
    ) -> H2CheckoutResult:
        """Register a freshly dialed + handshaken h2 connection.

        Returns H2CheckoutResult.found(b_idx, c_idx) referencing the
        newly-inserted slot — caller can immediately drive a request on
        it (the caller dialed BECAUSE they wanted to send a request).
        """
        var b_idx = self._ensure_bucket(key^)
        var key2 = self._buckets[b_idx].key()
        var pooled = H2PooledConn[Self.S].new(
            client_conn^, h2_state^, key2,
        )
        var owned = OwnedPointer[H2PooledConn[Self.S]](pooled^)
        self._buckets[b_idx]._conns.append(owned^)
        self._dials_total = self._dials_total + 1
        var c_idx = self._buckets[b_idx]._conns.len() - 1
        return H2CheckoutResult.found(b_idx, c_idx)

    def h2_state_at(
        mut self, b_idx: Int, c_idx: Int,
    ) -> ref [
        origin_of(self._buckets[b_idx]._conns[c_idx][]._h2_state)
    ] H2ClientConnectionState:
        """Borrowed access to the H2ClientConnectionState at (b_idx, c_idx).

        The caller uses this for one round of frame-emit / frame-drain;
        the conn stays pooled across requests.

        Origin spec: the ref's origin is the inner H2ClientConnectionState
        field of the OwnedPointer'd H2PooledConn inside the bucket's
        _conns Slab. Per the Mojo 0.26.3 capability matrix (Repro 5/5b),
        `ref [self.<field-chain>] T` is the spelling that compiles.
        """
        return self._buckets[b_idx]._conns[c_idx][]._h2_state

    def client_conn_at(
        mut self, b_idx: Int, c_idx: Int,
    ) -> ref [
        origin_of(self._buckets[b_idx]._conns[c_idx][]._client_conn)
    ] ClientConn[Self.S]:
        return self._buckets[b_idx]._conns[c_idx][]._client_conn

    def mark_conn_draining(mut self, b_idx: Int, c_idx: Int):
        """External-trigger drain mark — e.g. caller observed
        is_goaway_received() and decides to retire this conn after
        in-flight streams complete."""
        self._buckets[b_idx]._conns[c_idx][].mark_draining()

    def release_drained_conn(mut self, b_idx: Int, c_idx: Int) raises:
        """Remove a draining conn whose open_streams_count() == 0 from
        the bucket. Drops the OwnedPointer, RAII-closing the stream.

        Caller invariant: only call when conn.is_draining() && conn.open_streams() == 0.
        """
        ref bucket = self._buckets[b_idx]
        var n = bucket._conns.len()
        if c_idx < 0 or c_idx >= n:
            raise Error(
                "release_drained_conn: c_idx out of range"
            )
        # Take + drop (Slab.swap_remove preserves no-shift for the others).
        var _dropped = bucket._conns.swap_remove(c_idx)

    def conn_count_at(self, b_idx: Int) -> Int:
        return self._buckets[b_idx].conn_count()

    def pending_waiters_count(self) -> Int:
        """Diagnostic: number of registered H2PendingCheckout waiters
        across all keys."""
        return self._pending_waiters.len()

    # -----: late-binding multiplex checkout ----------------------

    def try_checkout_or_pending(
        mut self, var key: PoolKey,
    ) -> H2CheckoutOrPending:
        """Late-binding multiplex checkout. Returns either:
          * `from_found(result)`     — existing conn has stream-slot capacity
          * `from_needs_dial()`      — caller must dial + insert_dialed_h2
          * `from_pending(handle)`   — registered waiter; caller awaits via
                                       `handle.await_slot()`

        The pending path is taken when:
          (a) no conn for this key has stream-slot capacity, AND
          (b) the bucket is at `max_conns_per_host` (so no new conn can
              be dialed without exceeding the cap).

        Wake fires when ANY in-flight stream on a matching-key conn
        releases via `release_stream_slot(b_idx, c_idx)`.
        """
        # Walk the regular checkout path first.
        var key_for_check = key
        var b_idx = self._ensure_bucket(key^)
        ref bucket = self._buckets[b_idx]
        var n = bucket._conns.len()
        var i = 0
        while i < n:
            ref conn = bucket._conns[i][]
            if conn.can_accept_new_stream():
                return H2CheckoutOrPending.from_found(
                    H2CheckoutResult.found(b_idx, i)
                )
            i = i + 1
        if n < self._sizing.max_conns_per_host:
            return H2CheckoutOrPending.from_needs_dial()
        # AT_CAPACITY → register a pending waiter.
        var p = H2PendingCheckout._new(key_for_check)
        # Stash a clone for the pool's wake-side fulfillment.
        var pool_clone = p._shared
        self._pending_waiters.append(pool_clone)
        return H2CheckoutOrPending.from_pending(p^)

    def release_stream_slot(mut self, b_idx: Int, c_idx: Int):
        """Notify the pool that a stream on (b_idx, c_idx) has
        completed (END_STREAM or RST_STREAM). If any H2PendingCheckout
        is waiting on a matching key + this conn now `can_accept_new_stream`,
        fulfill it (write the slot + fire source 0).

        Caller invariant: this method is called by the driver / dispatch
        after a stream's end_stream_seen transitions to True (or after
        RST_STREAM). The bucket's open_streams_count is recomputed via
        the live H2ClientConnectionState; the pool's check uses
        can_accept_new_stream which reads it.
        """
        # Bounds check.
        var nb = self._buckets.len()
        if b_idx < 0 or b_idx >= nb:
            return
        ref bucket = self._buckets[b_idx]
        var nc = bucket._conns.len()
        if c_idx < 0 or c_idx >= nc:
            return
        var conn_key = bucket._conns[c_idx][].key()
        var can_take = bucket._conns[c_idx][].can_accept_new_stream()
        if not can_take:
            return
        # Walk waiters; find the FIRST whose key matches + fulfill.
        var nw = self._pending_waiters.len()
        var wi = 0
        while wi < nw:
            if self._pending_waiters[wi][]._key == conn_key:
                # Fulfill: write the slot + fire source 0. Same pattern
                # as pool.mojo's checkin path for h1 waiters.
                self._pending_waiters[wi][]._slot = Optional[H2CheckoutResult](
                    H2CheckoutResult.found(b_idx, c_idx)
                )
                self._pending_waiters[wi][]._race.fire_source_0()
                # Remove from waiters slab (FIFO oldest-first per
                # SelectFirstNotify semantics).
                var _dropped = self._pending_waiters.take_at(wi)
                return
            wi = wi + 1

    # -----: pool-internal request driver --------------------------
    #
    # `drive_request_on_pooled_conn[RT]` is the production-wired analog of
    # the client.mojo `_run_one_request_h2_buffered` (which constructs
    # its own throwaway H2ClientConnectionState + dialed stream).
    #
    # The method body extracts BOTH `mut h2` and `mut stream` refs from the
    # pool's bucket-conn `OwnedPointer[H2PooledConn[S]]` via SEPARATE
    # `ref` declarations through disjoint field chains
    # (`._h2_state` vs `._client_conn._stream`). The driver call is then
    # made with both refs in the same scope. Containing the dual-ref
    # within ONE pool method keeps the borrow-check inside one borrow root
    # (the bucket-conn OwnedPointer) and prevents the dispatch-from-
    # client problem where two simultaneous refs through `pool_owned[]`
    # would collide at the HttpClient.send call site.
    #
    # Encapsulation: no UnsafePointer in sig; no wildcard origins; the
    # method takes a `var await_stream_ids` for forward-compat with future
    # multi-stream concurrent driving (today callers pass a single-id
    # list).

    def drive_request_on_pooled_conn[RT: Runtime](
        mut self,
        b_idx: Int,
        c_idx: Int,
        mut reactor: Reactor[RT.Sink],
        var await_stream_ids: List[UInt32],
        max_iterations: Int = 100_000,
        request_timeout_us: Int = 0,
    ) raises:
        """Drive in-flight h2 streams to completion on the
        pooled conn at (b_idx, c_idx) without exposing dual refs at the
        caller site.

        The method body holds both `mut h2` (the H2ClientConnectionState)
        and `mut stream` (the IoStream) refs in one scope; the borrow
        check operates locally on the field chains
        `self._buckets[b_idx]._conns[c_idx][]._h2_state` and
        `self._buckets[b_idx]._conns[c_idx][]._client_conn._stream`,
        which are disjoint at the leaf despite sharing the parent
        H2PooledConn[S].

        Bounds: b_idx/c_idx asserted in range; the conn must already be
        registered (insert_dialed_h2 returned the indices).

        ★ `request_timeout_us` — the CALLER's authored per-request budget
        (`HttpClientConfig.request_timeout_us`; `0` = none authored). Resolved
        to this drive's wall bound by `h2_drive_wall_us`, which takes the MIN
        with the driver's own default so an authored value can only TIGHTEN.

        ⛔ IT IS DELIBERATELY NOT A `max_wall_us` PARAMETER. This method's
        callers hold a `request_timeout_us` whose "unauthored" spelling is `0`,
        and `drive_h2_streams_to_completion` reads a `max_wall_us <= 0` as
        DISABLE THE WALL BOUND — so forwarding the raw value under that name
        would turn every unauthored pooled drive into an UNBOUNDED one. Taking
        the caller's unit and resolving it here makes that mistake unspellable.
        """
        var nb = self._buckets.len()
        if b_idx < 0 or b_idx >= nb:
            raise Error(
                "H2ClientPool.drive_request_on_pooled_conn: b_idx OOB"
            )
        var nc = self._buckets[b_idx]._conns.len()
        if c_idx < 0 or c_idx >= nc:
            raise Error(
                "H2ClientPool.drive_request_on_pooled_conn: c_idx OOB"
            )
        # Both refs through disjoint leaf field chains rooted in the
        # bucket-conn OwnedPointer. The driver mutates each independently
        # (h2 buffers + stream IO) and Mojo's borrow checker accepts the
        # local refs because their typed origins are independent at
        # the .leaf level.
        #
        # MOJO 1.0.0: both `ref`s must be projected out of ONE interior
        # reference. Re-walking `self._buckets[...]._conns[...][]` a second
        # time forms a NEW origin over the same storage, and 1.0.0 rejects the
        # first `ref` at the call below with "use of invalidated interior
        # reference" (b2 accepted it). Binding the conn once and projecting
        # both leaves out of that single origin is the same program with one
        # borrow instead of two.
        ref conn = self._buckets[b_idx]._conns[c_idx][]
        ref h2 = conn._h2_state
        ref stream = conn._client_conn._stream
        drive_h2_streams_to_completion[Self.S, RT](
            h2, stream, reactor, await_stream_ids^, max_iterations,
            h2_drive_wall_us(request_timeout_us),
        )


# =============================================================================
# §5 — H2 PendingCheckout
# =============================================================================
#
# When `try_checkout(key)` returns AT_CAPACITY (all existing h2 conns are at
# their `max_concurrent_streams_peer` AND the bucket is at `max_conns_per_host`),
# the caller can opt for the late-binding waiter shape: register an
# H2PendingCheckout, await, and wake when ANY stream on a matching conn
# releases (END_STREAM or RST_STREAM).
#
# Shape parallels's `_PendingCheckoutShared` / `PendingCheckout` —
# ArcPointer-shared with SelectFirstNotify for the wake gate. The "slot"
# here is an H2CheckoutResult (b_idx, c_idx) — the consumer drives a new
# stream on the conn pointed-to by the resolved indices.
#
# Encapsulation:
#   * ArcPointer is justified per the pointer rules — genuine
#     multi-owner state (pool's clone + waiter's clone). Matches
#     `_PendingCheckoutShared` precedent.
#   * No new UnsafePointer, no wildcard origins, no unsafe_from_address.


struct _H2PendingCheckoutShared(
    Movable, Deinitable,
):
    """Heap-allocated shared state for an H2PendingCheckout.

    Fields:
      _race      — SelectFirstNotify handle for the single-source wake
                   (source 0 = a stream slot on a matching-key conn became
                   available via release_stream_slot).
      _slot      — the resolved H2CheckoutResult — bucket_idx + conn_idx
                   of the conn with newly-available capacity. The pool
                   writes this BEFORE firing source 0.
      _key       — back-pointer for sanity checks (the pool only fulfills
                   with a matching-key conn).
    """

    var _race: SelectFirstNotify
    var _slot: Optional[H2CheckoutResult]
    var _key: PoolKey

    def __init__(out self, var _key: PoolKey):
        self._race = SelectFirstNotify.new()
        self._slot = Optional[H2CheckoutResult]()
        self._key = _key^


struct H2PendingCheckout(Movable, Deinitable):
    """Late-binding multiplex checkout handle.

    Returned by `H2ClientPool.try_checkout_or_pending(key)` when the bucket
    has no conn with stream-slot capacity. The caller awaits via
    `await_slot(mut self)`; the pool fulfills via its
    `release_stream_slot` path when any in-flight stream completes.

    Construction is pool-internal. Movable; NOT Copyable. The handle
    holds an ArcPointer to shared state; the pool holds another
    ArcPointer clone in its waiters list.

    NOTE: H2PendingCheckout is NOT parametric on S (the IoStream
    conformer) because the resolved slot is just (b_idx, c_idx) indices
    — the type-level connection is via the H2ClientPool[S] that holds
    the bucket.
    """

    var _shared: ArcPointer[_H2PendingCheckoutShared]

    @staticmethod
    def _new(var key: PoolKey) -> H2PendingCheckout:
        return H2PendingCheckout(
            _shared=ArcPointer[_H2PendingCheckoutShared](
                _H2PendingCheckoutShared(key^),
            ),
        )

    def __init__(
        out self,
        var _shared: ArcPointer[_H2PendingCheckoutShared],
    ):
        self._shared = _shared^

    def key(self) -> PoolKey:
        return self._shared[]._key

    def is_fired(self) -> Bool:
        """Diagnostic: True iff the wake has fired (the pool wrote a
        slot and called fire_source_0)."""
        return self._shared[]._slot.__bool__()

    def await_slot(mut self) raises -> H2CheckoutResult:
        """Park until the race fires (source 0 — release_stream_slot
        wakes us). Returns the H2CheckoutResult pointing at the conn
        with newly-available stream-slot capacity.

        Raises if the slot is empty after the wake (should not happen
        in correct usage — release_stream_slot fills the slot BEFORE
        fire_source_0).
        """
        var _winner = self._shared[]._race.await_first()
        if not self._shared[]._slot.__bool__():
            raise Error(
                "H2PendingCheckout.await_slot: slot empty after wake;"
                " pool fulfillment is buggy"
            )
        return self._shared[]._slot.take()


# =============================================================================
# §6 — H2CheckoutOrPending — the late-binding checkout outcome
# =============================================================================


comptime H2_OUTCOME_FOUND: UInt8 = 0
"""Existing conn has stream-slot capacity; checkout returns (b_idx, c_idx)
immediately."""

comptime H2_OUTCOME_NEEDS_DIAL: UInt8 = 1
"""No conn for this key has capacity; bucket is below max_conns_per_host.
Caller dials + inserts."""

comptime H2_OUTCOME_PENDING: UInt8 = 2
"""Bucket is at max_conns_per_host AND all conns are at their
max_concurrent_streams_peer. An H2PendingCheckout was registered; caller
awaits + drives on the resolved slot."""


struct H2CheckoutOrPending(Movable, Deinitable):
    """Outcome of `H2ClientPool.try_checkout_or_pending`. Carries either
    an immediate H2CheckoutResult or a registered H2PendingCheckout
    waiter.

    Mojo 1.0.0b1 has no tagged-union, so we use a discriminator + two
    Optional payloads — at most one is occupied.
    """

    var outcome: UInt8
    var found: Optional[H2CheckoutResult]
    var pending: Optional[H2PendingCheckout]

    def __init__(
        out self,
        outcome: UInt8,
        var found: Optional[H2CheckoutResult],
        var pending: Optional[H2PendingCheckout],
    ):
        self.outcome = outcome
        self.found = found^
        self.pending = pending^

    @staticmethod
    def from_found(result: H2CheckoutResult) -> H2CheckoutOrPending:
        return H2CheckoutOrPending(
            outcome=H2_OUTCOME_FOUND,
            found=Optional[H2CheckoutResult](result),
            pending=Optional[H2PendingCheckout](),
        )

    @staticmethod
    def from_needs_dial() -> H2CheckoutOrPending:
        return H2CheckoutOrPending(
            outcome=H2_OUTCOME_NEEDS_DIAL,
            found=Optional[H2CheckoutResult](),
            pending=Optional[H2PendingCheckout](),
        )

    @staticmethod
    def from_pending(var p: H2PendingCheckout) -> H2CheckoutOrPending:
        return H2CheckoutOrPending(
            outcome=H2_OUTCOME_PENDING,
            found=Optional[H2CheckoutResult](),
            pending=Optional[H2PendingCheckout](p^),
        )

    def is_found(self) -> Bool:
        return self.outcome == H2_OUTCOME_FOUND

    def is_needs_dial(self) -> Bool:
        return self.outcome == H2_OUTCOME_NEEDS_DIAL

    def is_pending(self) -> Bool:
        return self.outcome == H2_OUTCOME_PENDING
