# =============================================================================
# spill_arbitrator.mojo — variadic `SpillArbitrator[S, *Ops]` + OLDEST_FIRST.
# =============================================================================
#
# # Role
#
# Coordinates spill across multiple `SpillableOp`s sharing one budget.
# When `pressure_check_and_arbitrate(grow_bytes)` finds that the
# requested allocation would push live bytes past the budget, it
# consults the policy (default OLDEST_FIRST) to pick ONE op to spill,
# routes the spill through that op's `spill_to_storage` method, and
# returns the bytes freed.
#
# v0.4 P-1.C ships the SKELETON: arbitrator construction + ops
# enumeration + `pressure_check_and_arbitrate` driving the OLDEST_FIRST
# policy + per-op `spill_to_storage` invocation. The two other reserved
# policies (LARGEST_FIRST, PROPORTIONAL_RESERVATION) raise from inside
# `pressure_check_and_arbitrate` when selected.
#
# Production wiring (`MemoryReservation.with_arbitrator` ctor +
# EngineContext field + 3 production conformers) lands in P-1.D / P-1.E
# per the design
#
# # Variadic ops
#
# The arbitrator's ops field is `Tuple[*Self.Ops]` — one
# canonical primitive that covers arity 1 through N without sibling
# clones. Construction goes through `SpillableOpBlock[*Ops]` (single-pack
# ctor wrapper, mirror of `PayloadBlock[*Payload]` in
# `stage_primitives/join_build.mojo:340`); iteration is via
# `@parameter for i in range(Self.Ops.__len__())`.
#
# P-1.C's skeleton owns the ops BY VALUE (the arbitrator is the sole
# owner during a dispatch). P-1.D will re-evaluate whether ops register
# as borrowed Pointer-refs once production reservation wiring fixes the
# call sites' lifetime constraints.
#
# # Encapsulation rule
#
# - Public method surface uses `Int64`, `Bool`, `ChunkId`, `ArbitratorPolicy`,
#   and parametric `S: SpillStorage`. NO `UnsafePointer` at the trait
#   boundary. NO wildcard origins on any struct field.
# - Internal `@parameter for` iteration over `self._ops[i]` is comptime-
#   monomorphized; no fn-ptr dispatch, no `dyn` boxing.
# =============================================================================

from .policies import ArbitratorPolicy
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


# =============================================================================
# SpillableOpBlock — single-pack ctor wrapper
# =============================================================================
#
# Mojo allows only ONE `*` marker per parameter list. The arbitrator ctor takes the
# `*Ops` pack pre-wrapped in this one-pack `SpillableOpBlock` so its own
# ctor parameter list can also carry the budget Int64 + policy
# ArbitratorPolicy + storage S.
#
# `Optional`-wrap so the inner Tuple lifts out via `Optional.take()` —
# never via `UnsafePointer.take_pointee`.


struct SpillableOpBlock[*Ops: SpillableOp](Movable):
    """Single-pack wrapper carrying the SpillableOp pack into the
    `SpillArbitrator` ctor. `Optional`-wraps `Tuple[*Self.Ops]` so the
    inner pack lifts out via `Optional.take()`.

    Mirror of `PayloadBlock[*Payload]` (join_build.mojo:340): the canonical
    single-pack-block pattern for variadic ops.
    """

    var _ops: Optional[Tuple[*Self.Ops]]

    def __init__(out self, var *ops: *Self.Ops):
        self._ops = Tuple(*ops^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Ops]:
        """Lift the SpillableOp Tuple out (one-shot consume — Optional.take,
        NOT UnsafePointer.take_pointee).
        """
        return self._ops.take()


# =============================================================================
# SpillArbitrator
# =============================================================================
#
# Sentinel for "no victim chosen this pass" (OLDEST_FIRST has no candidate
# satisfying `can_spill()`). The arbitrator returns 0 bytes-freed in this
# case — best-effort spill, no error per `SpillableOp.can_spill` docstring.


comptime _NO_VICTIM_INDEX: Int = -1


struct SpillArbitrator[S: SpillStorage, *Ops: SpillableOp](
    Movable, Deinitable
):
    """Coordinates spill across a fixed pack of `SpillableOp`s under one
    shared byte budget.

    # Lifetime

    v0.4 P-1.C owns the `*Ops` pack by value via `Tuple[*Self.Ops]`. The
    arbitrator is constructed at EngineContext init (when
    the host offers a spill tier; its budget is the host profile's memory
    budget) and dropped at session teardown.

    # Threading

    P-1.C is single-arbitrator-per-session, single-threaded-arbitrate-call.
    The arbitrator does not own concurrency primitives — the caller (today:
    test fixture; production: `MemoryReservation.with_arbitrator` in
    P-1.D) is responsible for serializing pressure_check calls.

    # Parameters

        S:   the `SpillStorage` backend (today: `LocalDiskSpillStorage`;
             v0.6+: cloud variants). Monomorphized at arbitrator
             construction.
        Ops: variadic pack of `SpillableOp` conformers — one entry per
             registered breaker. Zero overhead at runtime; full per-pack-
             element type info is preserved at comptime.

    # Fields

        _storage:     the spill backend, OWNED by the arbitrator. Spill
                      victim's `spill_to_storage` receives this `mut`-ref
                      and routes its THSPILL2 bytes through.
        _budget_bytes: the shared budget. A `pressure_check_and_arbitrate
                      (grow_bytes)` call returns >0 (bytes freed) when
                      `_total_resident() + grow_bytes > _budget_bytes`.
        _ops:         the variadic pack of SpillableOp conformers.
                      Iterated via `@parameter for`.
        _policy:      victim-pick rule (default OLDEST_FIRST).

    # Encapsulation

    No `UnsafePointer` on the public surface;
    no wildcard origins on any field. The `_ops` field's pack-element
    origins are tied to construction-site lifetimes (caller passes ops
    by-value via the `SpillableOpBlock` wrapper).
    """

    var _storage: Self.S
    var _budget_bytes: Int64
    var _ops: Tuple[*Self.Ops]
    var _policy: ArbitratorPolicy

    def __init__(
        out self,
        var storage: Self.S,
        budget_bytes: Int64,
        var ops_block: SpillableOpBlock[*Self.Ops],
        policy: ArbitratorPolicy = ArbitratorPolicy.oldest_first(),
    ):
        """Construct an arbitrator with `budget_bytes` shared across the
        ops in `ops_block`.

        The caller pre-builds the ops block (`SpillableOpBlock[*Ops](op0,
        op1, ...)`) so the ctor parameter list carries only ONE `*`
        marker (the ops_block field) — the budget / policy / storage
        live on the surrounding non-variadic args. This is the
        canonical single-pack-block ctor pattern.

        Args:
            storage:      `SpillStorage` backend the arbitrator hands to
                          each spill victim's `spill_to_storage` call.
                          Consumed.
            budget_bytes: Shared byte budget. Pressure fires strictly
                          GREATER-than (`>`), not `>=`, so a request
                          that exactly fills the budget does NOT trigger
                          spill (matches the existing
                          `MemoryReservation.try_grow` semantics).
            ops_block:    Pre-built `SpillableOpBlock[*Ops]` wrapping the
                          variadic ops pack. Consumed.
            policy:       Victim-pick policy. Default OLDEST_FIRST; v0.4
                          P-1.C only OLDEST_FIRST works at runtime —
                          LARGEST_FIRST / PROPORTIONAL_RESERVATION raise
                          from `pressure_check_and_arbitrate`.
        """
        self._storage = storage^
        self._budget_bytes = budget_bytes
        self._ops = ops_block.take()
        self._policy = policy

    @staticmethod
    @always_inline
    def op_arity() -> Int:
        """Comptime count of registered SpillableOps. Returns the pack
        cardinality at the arbitrator's construction site.
        """
        return Self.Ops.__len__()

    @always_inline
    def budget_bytes(self) -> Int64:
        """The shared spill budget (Int64; bytes)."""
        return self._budget_bytes

    @always_inline
    def policy(self) -> ArbitratorPolicy:
        """The currently-selected victim-pick policy."""
        return self._policy

    def total_resident_bytes(self) -> Int64:
        """Sum of `memory_usage_bytes()` across every registered op.

        Used by `pressure_check_and_arbitrate` and exposed publicly for
        test assertions + telemetry. O(Ops.__len__()) — fully unrolled at
        comptime via `@parameter for`.
        """
        var total: Int64 = 0

        comptime for i in range(Self.Ops.__len__()):
            total += self._ops[i].memory_usage_bytes()
        return total

    def pressure_check_and_arbitrate(
        mut self, grow_bytes: Int64
    ) raises -> Int64:
        """Check if `grow_bytes` would exceed the budget; spill ONE victim
        if so. Returns bytes freed.

        Decision shape:

          1. Sum every op's `memory_usage_bytes()` → `current`.
          2. If `current + grow_bytes > _budget_bytes` (strict GT), invoke
             the policy to pick a victim:
               * OLDEST_FIRST: scan ops with `can_spill() == True` and
                 pick the smallest `age_ticks`. If NO op can spill,
                 return 0 (no error — best-effort).
               * LARGEST_FIRST: RESERVED v0.5+; raises today.
               * PROPORTIONAL_RESERVATION: RESERVED v0.5+; raises today.
          3. Call the victim's `spill_to_storage[Self.S](self._storage)`.
          4. Return the victim's bytes-freed value.

          If no pressure: return 0 immediately (the happy path; one Int64
          add + one cmp).

        Args:
            grow_bytes: Requested additional allocation, in bytes. The
                        check is strict GT — exact-fit at the budget
                        does NOT trigger spill.

        Returns:
            Bytes freed by the spill (0 if no pressure OR no spillable
            candidate found).

        Raises:
            * From the victim's `spill_to_storage` (e.g. storage EIO).
            * From the arbitrator's policy arm when an unimplemented
              policy (LARGEST_FIRST / PROPORTIONAL_RESERVATION) is
              selected.
        """
        # Happy path: under budget. ZERO iteration cost on no-pressure.
        var current = self.total_resident_bytes()
        if current + grow_bytes <= self._budget_bytes:
            return 0

        # Pressure fired. Policy dispatch.
        if self._policy.is_oldest_first():
            return self._spill_oldest_first()
        elif self._policy.is_largest_first():
            raise Error(
                "SpillArbitrator: LARGEST_FIRST policy not yet implemented"
                ""
            )
        elif self._policy.is_proportional_reservation():
            raise Error(
                "SpillArbitrator: PROPORTIONAL_RESERVATION policy not yet"
                " implemented"
            )
        else:
            raise Error(
                "SpillArbitrator: unknown ArbitratorPolicy tag="
                + String(Int(self._policy.tag()))
            )

    def _spill_oldest_first(mut self) raises -> Int64:
        """OLDEST_FIRST policy: scan ops with `can_spill() == True`, pick
        the smallest `age_ticks`, spill that op. Returns bytes freed.

        Internal helper called from `pressure_check_and_arbitrate` after
        pressure is established. Splits out so the policy-dispatch arm
        remains readable.

        Mojo note: heterogeneous-pack iteration via `@parameter
        for` does NOT permit deferred per-element work across iterations
        (each loop body monomorphizes to a concrete pack element's type).
        We pre-scan all ops to find `(victim_idx, victim_age)` and then
        re-scan to invoke `spill_to_storage` on the chosen index. The
        re-scan is fully unrolled at comptime; the runtime path is
        `Ops.__len__()` * (one cmp + one `can_spill`) on the first pass +
        ONE `spill_to_storage` call on the second pass.
        """
        var victim_idx: Int = _NO_VICTIM_INDEX
        var victim_age: UInt64 = 0  # initial value irrelevant; gated by
                                    # `victim_idx == _NO_VICTIM_INDEX`

        comptime for i in range(Self.Ops.__len__()):
            if self._ops[i].can_spill():
                var age = self._ops[i].age_ticks()
                if (victim_idx == _NO_VICTIM_INDEX) or (age < victim_age):
                    victim_idx = i
                    victim_age = age

        # No spillable op — best-effort: return 0 (matches docstring).
        if victim_idx == _NO_VICTIM_INDEX:
            return 0

        # Second pass: invoke `spill_to_storage` on the chosen index.
        # The `@parameter for` body is comptime-monomorphized; the
        # runtime branch on `i == victim_idx` selects the one op to spill.
        var bytes_freed: Int64 = 0

        comptime for i in range(Self.Ops.__len__()):
            if i == victim_idx:
                bytes_freed = self._ops[i].spill_to_storage(self._storage)

        return bytes_freed

    def restore_all(mut self) raises:
        """Drive `restore_from_storage` on every registered op. Used at
        finalize when each op needs its spilled state back.

        v0.4 P-1.C exposes this as a convenience for tests + the future
        P-1.D wiring. Production callers may prefer per-op
        `restore_from_storage` invocation (e.g. from inside the op's
        finalize chain) — both shapes are supported by the trait.

        Iterates the ops pack via `@parameter for`; each restore call
        runs sequentially (no concurrency).

        Raises:
            From any op's `restore_from_storage` (storage EIO, schema
            mismatch, etc.). Subsequent ops in the pack are NOT
            restored — the caller is responsible for cleanup.
        """

        comptime for i in range(Self.Ops.__len__()):
            self._ops[i].restore_from_storage(self._storage)

    @always_inline
    def storage_ref(ref self) -> ref [self._storage] Self.S:
        """Borrow the underlying `SpillStorage`. Used by tests + future
        wiring that needs to inspect `nbytes_in_use()` outside an
        arbitrate pass.
        """
        return self._storage

    @always_inline
    def op_memory_usage_bytes[i: Int](self) -> Int64:
        """Read a specific op's `memory_usage_bytes()` by comptime index.
        Used by tests for per-op assertions without exposing a `ref` to
        the pack element (which would require expressing `Self.Ops[i]`
        — a pack-type-level access shape not directly spellable in
        Mojo).

        The `i` must be a comptime literal (`arb.op_memory_usage_bytes[0]()`)
        — pinned to a concrete pack element at the access site, mirroring
        the `payload[p].read_slot_f64(slot)` shape in
        `join_build.mojo:1264`.
        """
        return self._ops[i].memory_usage_bytes()

    @always_inline
    def op_age_ticks[i: Int](self) -> UInt64:
        """Read a specific op's `age_ticks()` by comptime index. Test
        convenience; same shape rationale as `op_memory_usage_bytes`.
        """
        return self._ops[i].age_ticks()

    @always_inline
    def op_can_spill[i: Int](self) -> Bool:
        """Read a specific op's `can_spill()` by comptime index. Test
        convenience; same shape rationale as `op_memory_usage_bytes`.
        """
        return self._ops[i].can_spill()
