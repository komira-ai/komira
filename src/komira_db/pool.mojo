# =============================================================================
# komira_db/pool.mojo — a generic, resource-agnostic bounded connection pool.
# =============================================================================
#
# The resource-agnostic cheap-vacate pool. `PgDatabase` is just ONE type of
# connection, and a user may not be using Postgres at all: a handler's leased
# resource could be a Postgres connection, a Redis connection,
# an HTTP-backend connection, a gRPC channel — anything pooled. The cheap-vacate
# + own/lease/release machinery must NOT be Postgres-specific. So this module
# holds it ONCE, over a minimal `PooledResource` trait, and `PgPool` becomes a
# thin `Pool[PgDatabase]` specialization.
#
# ── THE `PooledResource` TRAIT (kept MINIMAL — exactly what the pool needs) ────
# The pool needs only three things from a pooled resource `T`:
#   1. STORAGE-SAFETY: `Movable & Deinitable` so it can live in a
#      `Slab[Optional[T]]` (the relocation-safe owning container — see the
#      RELOCATION note below). The Slab moves each `Optional[T]` in/out and runs its destructor
#      per live slot at teardown.
#   2. A CONFIG-DRIVEN FACTORY: a `Config` associated type + a
#      `@staticmethod connect(var config: Config) raises -> Self`. The pool
#      establishes `size` resources eagerly at construction from one config
#      (copied per resource — `Config: Copyable`), and retains the config so a
#      dead slot can be reconnected (health follow-on) without re-plumbing
#      credentials. `PgDatabase` builds via `connect_blocking(PgConfig)`; a Redis
#      resource would build via its own `connect(RedisConfig)`; etc.
#   3. TEARDOWN: `close(mut self)` — graceful resource shutdown (a pg Terminate +
#      TLS shutdown + fd close; a Redis QUIT; an HTTP keep-alive socket close).
# Nothing else. The pool does NOT touch the resource's QUERY/EXECUTE surface —
# that is the consumer's concern (a `Store[PgDatabase]` over a leased pg conn, a
# Redis command over a leased redis conn). The pool is pure lifecycle: establish,
# lease, vacate, restore, give back, close. The `Config` associated type is the
# ONLY resource-specific knob, and it is opaque to the pool (it just copies it
# into the factory).
#
# ── WHY `Slab[Optional[T]]` (the cheap-vacate primitive) ──────────────────────
# A Slab requires every live slot (`idx < len`) to hold a valid, destructor-safe
# `T`. Honoring that by SWAPPING IN a fabricated placeholder resource (a full
# handshake then immediate close) when a connection is moved out is strictly
# WORSE than holding it, for a streaming frame that releases + re-takes its
# connection on EVERY idle gap (a handshake per idle cycle). So each slot is
# an `Optional[T]`: a vacated slot holds `None` — a
# zero-cost, socket-free, destructor-safe placeholder — so `vacate`/`take` cost
# one move + one `None` install (no network), and `restore`/`give_back` cost one
# move back. No resource is ever reconnected across an idle cycle; the
# `connects_made()` instrument proves it (bumped ONLY at eager `connect`/reconnect,
# NEVER on vacate/restore/take/give_back).
#
# ── THE 1.0.0b1 WALL CARRIED FORWARD (generic, not pg-specific) ───────────────
# `Slab[Optional[T]]` CANNOT offer a tracked borrow-in-place `ref` to the inner
# `T`. Mojo 1.0.0b1's `ref [self.field._value] T` origin narrowing composes
# through an `Optional.value()` deref ONLY for a DIRECT NAMED Optional field;
# reached through a Slab SUBSCRIPT (a container element, not a named field),
# `Optional.value()` returns `MutAnyOrigin` — a WILDCARD ref, banned crossing a
# public boundary. This is a property of the storage shape, not of
# `PgDatabase`, so it holds for ANY conforming `T`. Consequence: the pool exposes
# MOVE-based access (`take`/`give_back`/`vacate`/`restore` — ownership moves by
# value, `^`), NOT a `conn(lease) -> ref T` borrow. A run-a-query-and-return flow
# is `var r = pool.take(lease); use(r); pool.give_back(lease, r^)`.
#
# ── ENCAPSULATION ──────────────────────────────────────────────────
# ZERO UnsafePointer / wildcard origin / unsafe_from_address crosses this
# boundary, for ANY conforming `T`. The N owned resources live in a
# `Slab[Optional[T]]`; the public surface hands out an OPAQUE Int LEASE (an index
# into the pool), never a raw pointer. The free-list bookkeeping (`_FreeList`) is
# fully encapsulated.
#
# ── RELOCATION ──────────────────────────────────────────────────────────────────────
# `Slab[Optional[T]]` is relocation-clean for any conforming `T`: the Slab's
# Movable-gated API moves each `Optional[T]` in/out with `init_pointee_move` /
# `take_pointee` and runs `destroy_pointee` per live slot at teardown — the
# canonical owning container. A `None` slot's `destroy_pointee` is a no-op; a
# `Some(t)` slot's runs `T`'s destructor. No wildcard origin is stored as a FIELD
# here; the only wildcard-origin use is INTERNAL to Slab (its init_fn seam),
# already encapsulated + SAFETY-commented in slab.mojo. The constraint that keeps
# this relocation-clean is on the CALLER of `Pool[T]`: a conforming `T` must itself be
# relocation-clean as a Movable slab element (no wildcard-origin pointer field). The
# trait does not — cannot — enforce that, but it is the same audit any Movable
# struct entering a slab requires. `_in_use` / `_live: List[Bool]` are
# Copyable-element lists (POD), relocation-clean.
#
# ── FOLLOW-ONS (not built here; identical to komira_db_postgres/pg_pool.mojo's) ──────────────
#  (1) MULTI-PTHREAD LOCKING. `_FreeList.checkout/return_lease` are correct for a
#      single-threaded control loop. For N threads sharing ONE pool, checkout/
#      return must run under a mutex and block-on-condvar when full. The
#      "where a mutex/condvar goes" markers are on `_FreeList.checkout` /
#      `return_lease`.
#  (2) CONNECTION HEALTH / RECONNECT. `discard(lease)` marks a poisoned slot dead;
#      a full reconnect (re-`T.connect(config)` into the slot) is the follow-on.
#      The `_config` field is retained precisely so a slot can be reconnected
#      without re-plumbing credentials.
# =============================================================================

from komira_collections.slab import Slab


# =============================================================================
# 1 — PooledResource — the MINIMAL trait the generic pool needs from a resource.
# =============================================================================
# Kept deliberately small: storage-safety (Movable & Deinitable, so
# it lives in `Slab[Optional[T]]`), a config-driven factory (the `Config`
# associated type + `connect`), and teardown (`close`). The pool does NOT depend
# on the resource's query/execute surface — that is the consumer's concern. A
# Postgres connection, a Redis connection, an HTTP-backend connection, or a gRPC
# channel all conform by exposing exactly these three things.


trait PooledResource(Movable, Deinitable):
    """The minimal contract the generic `Pool[T]` needs from a pooled resource.

    Conformers: `PgDatabase` (Config = PgConfig, connect = connect_blocking,
    close = Terminate+TLS shutdown). A Redis/HTTP/gRPC resource conforms by
    exposing its own `Config` + `connect` + `close`. The pool treats `Config` as
    opaque — it just copies it into the factory per eager establishment.

    `Config` must be `Copyable & Movable` so the pool can establish `size`
    resources from one config (copied per resource) and retain the config for a
    reconnect (health follow-on) without re-plumbing credentials."""

    comptime Config: Copyable & Movable & Deinitable

    @staticmethod
    def pooled_connect(var config: Self.Config) raises -> Self:
        """Establish ONE resource (the full handshake) from the config. Called
        `size` times eagerly at `Pool.connect`, and at a genuine reconnect
        (health follow-on). Each call is a real establishment and bumps the
        pool's `connects_made()` instrument; the cheap-vacate cycle never calls
        it.

        Named `pooled_connect` (not `connect`) so a conformer like `PgDatabase`
        — which already has a runtime-parametric `connect[RT](reactor, config)`
        AND a `connect_blocking(config)` — can implement the pool factory without
        a name collision. `PgDatabase.pooled_connect` delegates to
        `connect_blocking`."""
        ...

    def close(mut self):
        """Graceful resource teardown (pg: Terminate + TLS shutdown + fd close;
        redis: QUIT; http: keep-alive socket close). Run per live slot at
        `Pool.close()` and by the Slab destructor at pool teardown."""
        ...


# =============================================================================
# 2 — _FreeList — the resource-independent checkout/return bookkeeping core.
# =============================================================================
# Fully resource-agnostic (it only tracks slot indices), so it is shared
# verbatim between the generic `Pool[T]` and the pg surface. Single-
# threaded-correct; the multi-pthread mutex/condvar is the follow-on.


struct _FreeList(Movable):
    """The pool's free-list: an in-use bitset + a liveness bitset over `size`
    slots. Encapsulated inside `Pool[T]`. Single-threaded-correct: `checkout`
    returns the lowest free + live index or raises when full; `return_lease`
    frees a slot or raises on a double-return / out-of-range lease (both
    programming errors in the single-threaded contract).

    MULTI-PTHREAD FOLLOW-ON: for a pool shared across N threads, `checkout` /
    `return_lease` must run under a mutex, and `checkout`-when-full must BLOCK on
    a condvar (park until a `return_lease` signals) rather than raise."""

    var _in_use: List[Bool]  # _in_use[i] == True  -> slot i is leased out
    var _live: List[Bool]  # _live[i]   == False -> slot i is discarded (dead)

    def __init__(out self, size: Int):
        self._in_use = List[Bool]()
        self._live = List[Bool]()
        for _ in range(size):
            self._in_use.append(False)
            self._live.append(True)

    @always_inline
    def size(self) -> Int:
        return len(self._in_use)

    def in_use_count(self) -> Int:
        var n = 0
        for i in range(len(self._in_use)):
            if self._in_use[i]:
                n += 1
        return n

    def checkout(mut self) raises -> Int:
        """Reserve and return the lowest free + live slot index.

        MULTI-PTHREAD FOLLOW-ON: lock the mutex here; if no slot is free,
        WAIT on the condvar (park) instead of raising; re-scan after wake."""
        for i in range(len(self._in_use)):
            if (not self._in_use[i]) and self._live[i]:
                self._in_use[i] = True
                return i
        raise Error(
            "Pool exhausted: all "
            + String(len(self._in_use))
            + " resources are in use (single-threaded pool: a real"
            " multi-pthread pool would block on a condvar here)"
        )

    def return_lease(mut self, lease: Int) raises:
        """Mark `lease` available again.

        MULTI-PTHREAD FOLLOW-ON: lock the mutex, flip the bit, then SIGNAL the
        condvar so a parked `checkout` wakes."""
        if lease < 0 or lease >= len(self._in_use):
            raise Error("Pool.return: lease " + String(lease) + " out of range")
        if not self._in_use[lease]:
            raise Error(
                "Pool.return: lease " + String(lease) + " was not checked out"
            )
        self._in_use[lease] = False

    def discard(mut self, lease: Int) raises:
        """Mark `lease`'s slot DEAD (a poisoned/errored resource) so it is not
        handed out again. The slot stays leased-out from the free-list's view
        until a reconnect (follow-on) revives it via `revive`."""
        if lease < 0 or lease >= len(self._live):
            raise Error("Pool.discard: lease " + String(lease) + " out of range")
        self._live[lease] = False

    def revive(mut self, lease: Int) raises:
        """Mark a previously-discarded slot live + available again (used by the
        reconnect follow-on after a fresh resource is installed)."""
        if lease < 0 or lease >= len(self._live):
            raise Error("Pool.revive: lease " + String(lease) + " out of range")
        self._live[lease] = True
        self._in_use[lease] = False


# =============================================================================
# 3 — Pool[T] — the generic bounded cheap-vacate connection pool.
# =============================================================================


struct Pool[T: PooledResource](Movable):
    """A bounded N-resource blocking checkout/return pool over any
    `T: PooledResource`. Constructs N resources eagerly at `Pool.connect(config,
    size)` and holds them in a relocation-safe `Slab[Optional[T]]`. The public surface
    hands out opaque Int leases; no UnsafePointer / wildcard origin crosses the
    boundary.

    `PgPool` (komira_db_postgres/pg_pool.mojo) is the thin `Pool[PgDatabase]` specialization. The
    same `Pool[T]` drives a Redis/HTTP/gRPC pool by swapping `T` — the
    cheap-vacate machinery is identical. See the module banner for the SCOPE note
    (the SIMPLE synchronous pool; async/pipelined upgrade DEFERRED) and the
    multi-pthread-locking + connection-health follow-ons."""

    var _resources: Slab[Optional[Self.T]]
    var _free: _FreeList
    # Retained so a dead slot can be reconnected (health/reconnect follow-on)
    # without re-plumbing credentials through the caller. `Config: Copyable`.
    var _config: Self.T.Config
    # The number of FULL resource establishments (`T.connect`) this pool has made
    # over its lifetime — incremented ONLY at eager `connect` (N up front) and at
    # a genuine reconnect. The cheap-vacate / restore / take / give_back cycle
    # does NOT touch this counter (pure ownership move, no establishment). The
    # streaming no-reconnect guard asserts this stays flat across an idle
    # vacate->park->restore cycle. POD Int (relocation-clean).
    var _connects_made: Int

    def __init__(
        out self,
        var resources: Slab[Optional[Self.T]],
        var free: _FreeList,
        var config: Self.T.Config,
        connects_made: Int,
    ):
        self._resources = resources^
        self._free = free^
        self._config = config^
        self._connects_made = connects_made

    @staticmethod
    def connect(var config: Self.T.Config, size: Int) raises -> Self:
        """Establish `size` independent resources eagerly (each a full handshake
        via `T.connect`) and build the pool. If any establishment fails, the
        already-opened ones are dropped by the Slab's destructor as `resources`
        unwinds — no leak."""
        if size <= 0:
            raise Error(
                "Pool.connect: size must be > 0 (got " + String(size) + ")"
            )
        var resources = Slab[Optional[Self.T]](size)
        var connects_made = 0
        for _ in range(size):
            # `T.connect` consumes its Config by value; pass a copy per resource
            # (`Config: Copyable`) and keep the original for the pool field.
            # NOTE (1.0.0b1): bind the copy to a named `var` BEFORE the call —
            # passing `config.copy()` inline to a generic `Copyable`-bound param
            # trips "Unhandled explicit_destroy type Copyable" (the compiler
            # cannot place the temporary's destructor when the source `config` is
            # later moved). The named `var` gives the temporary an explicit scope.
            var cfg_i = config.copy()
            var r = Self.T.pooled_connect(cfg_i^)
            connects_made += 1
            resources.append(Optional[Self.T](r^))
        var free = _FreeList(size)
        return Self(resources^, free^, config^, connects_made)

    # ---- size / introspection ----

    @always_inline
    def size(self) -> Int:
        """Total number of resources in the pool."""
        return self._free.size()

    def in_use_count(self) -> Int:
        """Number of resources currently checked out."""
        return self._free.in_use_count()

    @always_inline
    def connects_made(self) -> Int:
        """The number of full resource establishments this pool has made over its
        lifetime (eager `connect` + any reconnect). The cheap-vacate / restore /
        take / give_back cycle does NOT increment this — the no-reconnect guard
        asserts it stays flat across an idle re-park."""
        return self._connects_made

    # ---- the checkout / return surface ----

    def checkout(mut self) raises -> Int:
        """Reserve a resource and return its opaque lease. Raises when the pool
        is exhausted (single-threaded contract — a multi-pthread pool would block
        on a condvar; see the module banner follow-on #1)."""
        return self._free.checkout()

    def return_lease(mut self, lease: Int) raises:
        """Return a borrowed lease to the pool's free-list (no resource move).
        For a resource moved out via `take`, use `give_back` instead (it moves
        the resource back AND frees the lease)."""
        self._free.return_lease(lease)

    # ---- take-out / give-back (move) ----

    def take(mut self, lease: Int) raises -> Self.T:
        """Move the leased resource OUT of the pool (e.g. to drive a transient
        consumer that takes it by value). The slot is left `None`-but-leased
        until `give_back` reinstalls a resource. Pairs with `give_back(lease,
        r^)`.

        CHEAP-VACATE: the vacated slot holds `None` — a zero-cost, socket-free
        placeholder — instead of a fabricated handshake-then-close resource. No
        handshake, no socket, no worker re-park."""
        if lease < 0 or lease >= self._resources.__len__():
            raise Error("Pool.take: lease " + String(lease) + " out of range")
        var slot = self._resources.replace(lease, Optional[Self.T]())
        if not slot:
            raise Error(
                "Pool.take: lease " + String(lease)
                + " is already vacated (no resource in slot)"
            )
        return slot.take()

    def give_back(mut self, lease: Int, var resource: Self.T) raises:
        """Reinstall a resource into its slot and mark the lease available. Pairs
        with `take(lease)`. The vacated slot was `None`, so this installs
        `Some(resource)` — no placeholder to drop — then frees the lease."""
        if lease < 0 or lease >= self._resources.__len__():
            raise Error(
                "Pool.give_back: lease " + String(lease) + " out of range"
            )
        _ = self._resources.replace(lease, Optional[Self.T](resource^))
        self._free.return_lease(lease)

    # ---- streaming cheap-vacate / restore ----

    def vacate(mut self, lease: Int) raises -> Self.T:
        """STREAMING: move the leased resource OUT of the pool for the idle gap
        while KEEPING the lease checked out (the slot stays reserved for this
        frame). The slot is left `None` — NO placeholder handshake. Pairs with
        `restore(lease, r^)` on wake.

        The difference from `take`: `vacate`/`restore` keep the lease held across
        the idle (the streaming frame owns the SLOT for the stream's whole
        multi-wake lifetime, only releasing the RESOURCE object), whereas
        `take`/`give_back` is the move-out-then-return-the-lease shape. Both are
        cheap (no reconnect). `vacate` is `take` with intent-naming +
        documentation that the lease is deliberately retained."""
        if lease < 0 or lease >= self._resources.__len__():
            raise Error("Pool.vacate: lease " + String(lease) + " out of range")
        var slot = self._resources.replace(lease, Optional[Self.T]())
        if not slot:
            raise Error(
                "Pool.vacate: lease " + String(lease)
                + " is already vacated (double-vacate)"
            )
        return slot.take()

    def restore(mut self, lease: Int, var resource: Self.T) raises:
        """STREAMING: reinstall a vacated resource on wake. The lease was held
        across the idle (never returned), so this ONLY installs `Some(resource)`
        — it does NOT touch the free-list. Pairs with `vacate(lease)`. No
        reconnect."""
        if lease < 0 or lease >= self._resources.__len__():
            raise Error(
                "Pool.restore: lease " + String(lease) + " out of range"
            )
        _ = self._resources.replace(lease, Optional[Self.T](resource^))

    @always_inline
    def is_vacated(self, lease: Int) raises -> Bool:
        """True iff the slot is currently `None` (resource moved out via
        `vacate`/`take`). Used by tests + a streaming frame's `__del__` safety
        net to know whether it currently holds the resource."""
        if lease < 0 or lease >= self._resources.__len__():
            raise Error(
                "Pool.is_vacated: lease " + String(lease) + " out of range"
            )
        return not self._resources[lease]

    # ---- connection-health (minimal; reconnect is a follow-on) ----

    def discard(mut self, lease: Int) raises:
        """Mark a leased resource's slot DEAD (use after a resource errored
        mid-use — its protocol state may be desynced, so it must not be handed
        back live). The slot is excluded from future checkouts until a reconnect
        (follow-on) revives it. The discarded resource itself is closed by the
        Slab destructor at pool teardown."""
        self._free.discard(lease)

    # ---- lifecycle ----

    def close(mut self):
        """Close every resource (`T.close`) on all live slots. A `None` (vacated)
        slot has no resource to close — the resource it once held is owned by
        whoever vacated it (a streaming frame mid-idle), whose own teardown closes
        it. The Slab's destructor also drops each `Some` resource, but an explicit
        close releases server sessions promptly."""
        for i in range(self._resources.__len__()):
            if self._resources[i]:
                self._resources[i].value().close()
