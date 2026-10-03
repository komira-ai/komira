# =============================================================================
# komira_db_postgres/pg_pool.mojo — PgPool: the Postgres specialization of Pool[T].
# =============================================================================
#
# `PgPool` is a THIN
# specialization of the generic, resource-agnostic `Pool[T: PooledResource]`
# (pool.mojo) over `PgDatabase`. The cheap-vacate + own/lease/release machinery
# (the `Slab[Optional[T]]` storage, `take`/`give_back`/`vacate`/`restore`/
# `connects_made`/`in_use_count`) lives ONCE in `Pool[T]`; `PgPool` wraps a
# `Pool[PgDatabase]` and exposes the pg-named surface its consumers call.
#
# `PgDatabase` is just ONE type of connection: a handler's leased resource could
# be a Postgres connection, a Redis connection, an HTTP-backend connection, a
# gRPC channel — anything pooled. So the machinery is generic (`Pool[T]`);
# `PgPool` is the Postgres face of it.
#
# ── WHY A WRAPPER, NOT A BARE ALIAS ───────────────────────────────────────────
# `comptime PgPool = Pool[PgDatabase]` would ALSO compile, but a thin wrapper
# struct is preferred for three reasons the consumers depend on:
#   (1) The pg-named `connect(config, size)` factory (the generic is
#       `Pool[PgDatabase].connect`, same shape) + the pg-named `return_conn`
#       method (the generic is `return_lease`).
#   (2) `PgPool` stays a NOMINAL type — `ArcPointer[PgPool]` / `Pointer[PgPool,
#       origin]` / `ref [origin] PgPool` in consumers (handlers, pooled
#       dispatchers, scoped lease guards) all resolve against the same named
#       struct. An alias would expose `Pool[PgDatabase]` and force those call
#       sites to spell the generic.
#   (3) A home for pg-specific follow-ons (the multi-pthread mutex/condvar; the
#       health-check/reconnect using the stored `PgConfig`) without widening the
#       generic `Pool[T]` surface.
#
# ── ENCAPSULATION ──────────────────────────────────────────────────
# ZERO UnsafePointer / wildcard origin / unsafe_from_address crosses this
# boundary. All storage + safety lives in `Pool[T]` (relocation-clean
# `Slab[Optional[PgDatabase]]`; the only wildcard-origin use is INTERNAL to Slab,
# already encapsulated + SAFETY-commented in slab.mojo). The public surface hands
# out an OPAQUE Int LEASE; the move-based `take`/`give_back`/`vacate`/`restore`
# carry ownership by value (`^`), never a pointer. The `conn(lease) -> ref T`
# borrow is UNEXPRESSIBLE for `Slab[Optional[T]]` storage (see "THE 1.0.0b1
# WALL" in pool.mojo); the move API is the contract.
#
# ── SCOPE: the SIMPLE, SYNCHRONOUS pool ──────────────────────────────
# This pool is the blocking-checkout-only shape (each connection a fully
# independent blocking session; concurrency from N separate connections, not from
# interleaving requests on one). Async/pipelined reads — TRUE
# parallel/concurrent pg reads pipelined on the reactor — belong to the
# runtime-parametric `PgDatabase` methods, not here. DO NOT add async
# pipelining here.
#
# ── FOLLOW-ONS (mostly live in Pool[T]) ──────────────────────────
#  (1) MULTI-PTHREAD LOCKING — a mutex/condvar guarding checkout/return for an
#      N-thread shared pool (the markers are on `Pool._FreeList`).
#  (2) HEALTH / RECONNECT — `discard(lease)` marks a poisoned slot dead; a full
#      reconnect (re-`PgDatabase.pooled_connect(config)` into the slot) is the
#      follow-on; the `Pool._config` (PgConfig) is retained for it.
#  (3) SCOPED LEASE WRAPPER — a consumer-side RAII guard is the sugar over the
#      Int-lease surface.
# =============================================================================

from komira_db_postgres.pg_driver import PgDatabase
from komira_db.pool import Pool

from komira_db_postgres.wire.connection import PgConfig


# =============================================================================
# PgPool — the bounded blocking connection pool over PgDatabase.
# =============================================================================
struct PgPool(Movable):
    """A bounded N-connection blocking checkout/return pool over `PgDatabase`. A
    THIN specialization of the generic `Pool[PgDatabase]` (pool.mojo): all the
    cheap-vacate machinery is in `Pool[T]`; this wrapper exposes the
    pg-named surface (`connect` / `return_conn`). The public surface hands out opaque Int
    leases; no UnsafePointer / wildcard origin crosses the boundary.

    See the module banner for the SCOPE note (this is the SIMPLE synchronous
    pool; async/pipelined reads are not its job), the
    why-a-wrapper rationale, and the multi-pthread-locking + connection-health
    follow-ons (now mostly living in `Pool[T]`)."""

    var _inner: Pool[PgDatabase]

    def __init__(out self, var inner: Pool[PgDatabase]):
        self._inner = inner^

    @staticmethod
    def connect(var config: PgConfig, size: Int) raises -> PgPool:
        """Open `size` independent connections eagerly (each a full
        TCP->TLS->SCRAM->ReadyForQuery handshake via
        `PgDatabase.pooled_connect`) and build the pool. If any connection fails,
        the already-opened ones are dropped by the Slab's destructor as the inner
        pool unwinds — no leak."""
        return PgPool(Pool[PgDatabase].connect(config^, size))

    # ---- size / introspection ----

    @always_inline
    def size(self) -> Int:
        """Total number of connections in the pool."""
        return self._inner.size()

    def in_use_count(self) -> Int:
        """Number of connections currently checked out."""
        return self._inner.in_use_count()

    @always_inline
    def connects_made(self) -> Int:
        """The number of full connection handshakes this pool has established over
        its lifetime (eager `connect` + any reconnect). The cheap-vacate / restore
        / take / give_back cycle does NOT increment this — the no-reconnect guard
        test asserts it stays flat across an idle re-park."""
        return self._inner.connects_made()

    # ---- the checkout / return surface ----

    def checkout(mut self) raises -> Int:
        """Reserve a connection and return its opaque lease. Raises when the pool
        is exhausted (single-threaded contract — a multi-pthread pool would block
        on a condvar; see the module banner follow-on #1)."""
        return self._inner.checkout()

    def return_conn(mut self, lease: Int) raises:
        """Return a borrowed lease (one used via `take` whose connection was given
        back separately) to the pool's free-list. For a connection moved out via
        `take`, use `give_back` (it moves the connection back AND frees the
        lease). The pg-named alias of the generic `Pool.return_lease`."""
        self._inner.return_lease(lease)

    # ---- take-out / give-back (move) ----
    #
    # There is no `conn(lease) -> ref PgDatabase`
    # borrow-in-place. The `Slab[Optional[PgDatabase]]` storage makes that ref
    # UNEXPRESSIBLE relocation-clean (the 1.0.0b1 wall — `Optional.value()` reached
    # through a Slab subscript returns a `MutAnyOrigin` WILDCARD; see pool.mojo).
    # So the pool offers the move-based `take` / `give_back`
    # (borrow-by-take): cheap (no reconnect) AND relocation-clean. A run-a-query flow is
    # `var db = pool.take(lease); use(db); pool.give_back(lease, db^)`.

    def take(mut self, lease: Int) raises -> PgDatabase:
        """Move the leased connection OUT of the pool (e.g. to build a transient
        `Store[PgDatabase]` / `JobStore[PgDatabase]` that consumes it by value).
        The slot is left `None`-but-leased until `give_back` reinstalls a
        connection. Pairs with `give_back(lease, db^)`.

        CHEAP-VACATE: the vacated slot holds `None` — a zero-cost, socket-free
        placeholder — instead of a fabricated `connect_blocking()`-then-`close()`
        connection. No handshake, no socket, no worker re-park."""
        return self._inner.take(lease)

    def give_back(mut self, lease: Int, var db: PgDatabase) raises:
        """Reinstall a connection (recovered from a transient `Store`/`JobStore`
        via `js^.into_store()` -> `store^.into_db()`) into its slot and mark the
        lease available. Pairs with `take(lease)`. The vacated slot was `None`, so
        this just installs `Some(db)` — no placeholder to drop."""
        self._inner.give_back(lease, db^)

    # ---- streaming cheap-vacate / restore ----

    def vacate(mut self, lease: Int) raises -> PgDatabase:
        """STREAMING: move the leased connection OUT of the pool for the idle gap
        while KEEPING the lease checked out (the slot stays reserved for this
        frame). The slot is left `None` — NO placeholder handshake. Pairs with
        `restore(lease, db^)` on wake. `vacate`/`restore` keep the lease held
        across the idle (the streaming frame owns the SLOT for the stream's whole
        multi-wake lifetime, only releasing the CONNECTION object)."""
        return self._inner.vacate(lease)

    def restore(mut self, lease: Int, var db: PgDatabase) raises:
        """STREAMING: reinstall a vacated connection on wake. The lease was held
        across the idle (never returned), so this ONLY installs `Some(db)` — it
        does NOT touch the free-list. Pairs with `vacate(lease)`. No reconnect."""
        self._inner.restore(lease, db^)

    @always_inline
    def is_vacated(self, lease: Int) raises -> Bool:
        """True iff the slot is currently `None` (connection moved out via
        `vacate`/`take`). Used by tests + the streaming frame's `__del__` safety
        net to know whether it currently holds the connection."""
        return self._inner.is_vacated(lease)

    # ---- connection-health (minimal; reconnect is a follow-on) ----

    def discard(mut self, lease: Int) raises:
        """Mark a leased connection's slot DEAD (use after a connection errored
        mid-use — its protocol state may be desynced, so it must not be handed
        back live). The slot is excluded from future checkouts until a reconnect
        (follow-on) revives it. The discarded connection is closed by the Slab
        destructor at pool teardown."""
        self._inner.discard(lease)

    # ---- lifecycle ----

    def close(mut self):
        """Close every connection (graceful Terminate + TLS shutdown + fd close)
        on all live slots. A `None` (vacated) slot has no connection to close —
        the connection it once held is owned by whoever vacated it (a streaming
        frame mid-idle), whose own teardown closes it."""
        self._inner.close()
