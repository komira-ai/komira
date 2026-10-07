# =============================================================================
# komira_async.runtime.for_each_morsel — morsel-stealing dispatch
# =============================================================================
#
# `for_each_morsel` is a higher-level dispatch shape on top of
# `LocalDispatcher.run_with_state`. It dispatches a per-morsel
# `body.process(state, wid, morsel)` invocation across the worker pool
# with two adaptive shapes:
#
#   * STATIC (n_morsels <= W): one task per morsel; task_id = morsel
#     index. Cheapest path — no MorselPool overhead, no MPMC traffic.
#     The plain fork-join shape.
#
#   * POOLED (n_morsels >  W): MorselPool[MorselT] populated with every
#     morsel; W drain-tasks dispatched (one per worker); each drain-task
#     loops `pool.try_claim()` until empty. DuckDB-style work-stealing
#     at the data level — under skewed kernels, fast workers steal
#     additional morsels from slow workers' partition (measured: a large
#     wall reduction at batch=16 vs static partition on 10:1 skew).
#
# Cancellation is wired from the get-go:
# the body's drain loop polls `cancel_token.is_cancelled()` between
# morsels. On cancel, the loop exits cleanly (decrementing in_flight)
# and the dispatcher's first-error-wins path surfaces a
# "CancelledError: <reason>" message back to the driver.
#
# `MorselBody` trait shape:
#   * `process[State: KeepAlive, MorselT: Movable](self, mut state,
#      wid: Int, var morsel: MorselT) raises`
#   * Both `State` and `MorselT` are method-level parameters (Mojo 0.26.3
#     traits don't accept top-level parameters — see
#     worker_pool_traits.mojo for the same shape on Segment).
#
# Pointer discipline:
#   * `MorselBody` is the public surface — no UnsafePointer / wildcards.
#   * `_ForEachState` is per-dispatch (NOT a struct field of any long-
#     lived type), constructed inside `for_each_morsel`, dropped at
#     return. Wildcard-origin pointers (`outer_state_ptr`,
#     `cancel_token_ptr`, `pool_ptr`) follow the same per-dispatch
#     carve-out as `_DispatchShard` in local_dispatcher.mojo.
#
#   * Pattern A migration attempted:
#     Mojo 1.0.0b1's aliasing analyzer rejects the dispatch shape
#     `run_with_state(wrapper, seg)` AND the body-extraction
#     `init_pointee_move(wrapper^)` when the wrapper carries
#     parametric-origin pointer fields (`Pointer` OR `UnsafePointer`
#     with concrete origins). The analyzer treats parametric-origin
#     pointer fields as "embedded references" that alias the live
#     `mut state` / `var pool` / `var cancel_token` args.
#     The `mut state` parameter cannot be consumed pre-extraction,
#     making the aliasing-conflict structurally unfixable under
#     Pattern A.
#
# This file holds the trait + helper structs + _next_pow2_ge helper.
# The `for_each_morsel` / `for_each_index` METHODS live on
# `LocalDispatcher` (same module) — methods must be defined alongside
# their struct in Mojo 0.26.3.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer

from komira_async.cancellation.token import CancellationToken
from komira_async.morsel.morsel_pool import MorselPool
from komira_async.runtime.nested_borrow_bundle import NestedBorrowBundle
from komira_async_api.worker_pool_traits import KeepAlive, Segment


# =============================================================================
# MorselBody — public per-morsel work trait
# =============================================================================


trait MorselBody(Movable, Deinitable):
    """Per-morsel work body — invoked once per morsel across the worker
    pool by `LocalDispatcher.for_each_morsel`.

    The body is
    MOVED into the dispatcher for the dispatch window and returned to
    the caller on success. The body's `process` method receives the
    user's borrowed State, the worker id (0-indexed), and ownership of
    one morsel.

    `State` is a method-level parameter (mirrors `Segment.execute`); the
    body extracts its concrete State via the standard one-line bitcast
    at the top of `process`:

        def process[State: KeepAlive, MorselT: Movable & Copyable & ...](
            mut self, mut state: State, wid: Int, var morsel: MorselT,
        ) raises:
            var s = UnsafePointer(to=state).bitcast[MyConcreteState]()
            # ...do work with s[] + morsel...

    `MorselT` is also a method-level parameter so a single body can
    process Int / Morsel / shard-id / file-URL morsels through the same
    surface (matches the existing MorselPool[T] generic shape).

    Movable is required because the body is moved into the dispatcher's
    per-dispatch state slab and (on success) moved back to the caller.
    """

    def process[
        State: KeepAlive,
        MorselT: Copyable & ImplicitlyCopyable
            & Movable & Deinitable,
    ](
        mut self, mut state: State, wid: Int, var morsel: MorselT,
    ) raises: ...


# =============================================================================
# Helper: next power-of-2 (>= n) for MorselPool capacity
# =============================================================================


@always_inline
def _next_pow2_ge(n: Int) -> UInt:
    """Round n UP to the next power of 2 (>= 2). MorselPool requires a
    power-of-2 capacity for the Vyukov ring's index-mask path."""
    if n <= 2:
        return UInt(2)
    var v = UInt(n)
    var r: UInt = UInt(2)
    while r < v:
        r = r << 1
    return r


# =============================================================================
# _ForEachState[State, MorselT, B] — per-dispatch wrapper state
# =============================================================================
#
# Lives on the caller's stack frame for the duration of one
# `for_each_morsel` call. Holds OwnedPointer-wrapped body + (static
# mode) morsels list, plus the THREE per-dispatch borrows (outer State,
# NON-Movable MorselPool, CancellationToken) ENCAPSULATED behind ONE
# `NestedBorrowBundle` primitive (the `_ForEachState`
# encapsulation).
#
# Conformance: `KeepAlive, Movable` so it can pass through
# `run_with_state[State, T]` as the State arg. The user's "real" State,
# the pool, and the cancel token are reached via the `borrows` bundle's
# pointer-free accessors (`outer_ref` / `pool_ref` / `cancel_ref`).
#
# ZERO BESPOKE WILDCARD FIELDS:
# the THREE scattered bespoke wildcard pointer FIELDS that lived here
# (`outer_state_ptr`, `pool_ptr`, `cancel_token_ptr`) are now COLLAPSED
# into the ONE `NestedBorrowBundle` primitive (nested_borrow_bundle.mojo),
# which holds the SOLE allowlisted `MutExternalOrigin` FIELD of the whole
# encapsulation. `_ForEachState` itself now carries ZERO wildcard fields.
# The wildcard CANNOT be eliminated (the nested-dispatch alias wall —
# the aliasing wall reproduces for every shape tried — a direct pointer, a
# concrete-origin frame, and the borrow/owned split), but
# it IS now encapsulated behind one named, allowlisted, tested primitive
# so this wrapper — and `for_each_morsel` — carry ZERO bespoke wildcard.


struct _ForEachState[
    State: KeepAlive,
    MorselT: Copyable & ImplicitlyCopyable
        & Movable & Deinitable,
    B: MorselBody,
](KeepAlive, Movable):
    """Per-dispatch wrapper state for for_each_morsel.

    Field rationale (per encapsulation rule + per-dispatch carve-out):
      * `body`: OwnedPointer so we can `take()` it back on the success
        path and return to the caller (POD 8-byte handle, partial-move
        safe).
      * `morsels`: OwnedPointer-wrapped List[Optional[T]] for static-
        mode (each index is taken at most once across disjoint
        task_ids).
      * `use_pool`: dispatch-mode discriminator (POD Bool).
      * `borrows`: the ONE `NestedBorrowBundle` primitive encapsulating
        the THREE per-dispatch borrows (outer State, NON-Movable
        MorselPool, CancellationToken) behind one blessed wildcard
        handle. `_ForEachState` carries ZERO bespoke wildcard fields —
        the SOLE allowlisted `MutExternalOrigin` FIELD lives inside the
        primitive (nested_borrow_bundle.mojo). The pool is borrowed (it
        is NOT Movable, so cannot live in an OwnedPointer; its lifetime
        is bounded by the wake-word barrier).
    """

    var body: OwnedPointer[Self.B]
    # Static-mode morsels: List[Optional[T]] so we can take() each by
    # index without partial-move from a struct field.
    var morsels: OwnedPointer[List[Optional[Self.MorselT]]]
    var use_pool: Bool
    # The ONE encapsulated borrow bundle — ZERO bespoke wildcard on this
    # wrapper. The three borrows (outer State, NON-Movable MorselPool,
    # CancellationToken) are reached via the bundle's pointer-free
    # accessors; the SOLE allowlisted wildcard FIELD lives inside the
    # primitive (nested_borrow_bundle.mojo), NOT here.
    var borrows: NestedBorrowBundle[Self.State, Self.MorselT]

    def __init__(
        out self,
        var body: Self.B,
        var morsels: List[Optional[Self.MorselT]],
        use_pool: Bool,
        var borrows: NestedBorrowBundle[Self.State, Self.MorselT],
    ):
        self.body = OwnedPointer[Self.B](value=body^)
        self.morsels = OwnedPointer[List[Optional[Self.MorselT]]](
            value=morsels^,
        )
        self.use_pool = use_pool
        self.borrows = borrows^


# =============================================================================
# _ForEachStaticSegment / _ForEachPooledSegment
# =============================================================================
#
# Both POD; bitcast inside `execute` to reach _ForEachState.
# Static seg: task_id == morsel index; ONE morsel per task.
# Pooled seg: task_id == drain index; loop pool.try_claim() until empty.


@fieldwise_init
struct _ForEachStaticSegment[
    State: KeepAlive,
    MorselT: Copyable & ImplicitlyCopyable
        & Movable & Deinitable,
    B: MorselBody,
](Segment, Deinitable):
    """Static-mode segment — task_id is the morsel index."""

    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64,
    ) raises:
        # State-slot recover stays INLINE in execute (Mojo 1.0.0b1 rejects
        # hoisting a method-param-origin ref return — POC3 finding).
        var sp = UnsafePointer(to=state).bitcast[
            _ForEachState[Self.State, Self.MorselT, Self.B]
        ]()
        # Cancel poll BETWEEN morsels (we have only one here, so check
        # before invoking body). The cancel token is reached through the
        # encapsulated bundle's pointer-free accessor.
        if sp[].borrows.cancel_ref().is_cancelled():
            raise Error(
                String("CancelledError: ")
                + sp[].borrows.cancel_ref().reason()
            )
        var idx = Int(task_id)
        # Take the morsel out of the per-dispatch slot. The List[Optional[T]]
        # contract guarantees each index is taken AT MOST ONCE under the
        # static dispatch shape (one task per morsel, disjoint task_ids).
        var morsel = sp[].morsels[][idx].take()
        sp[].body[].process[Self.State, Self.MorselT](
            sp[].borrows.outer_ref(), Int(worker_id), morsel^,
        )


@fieldwise_init
struct _ForEachPooledSegment[
    State: KeepAlive,
    MorselT: Copyable & ImplicitlyCopyable
        & Movable & Deinitable,
    B: MorselBody,
](Segment, Deinitable):
    """Pooled-mode segment — drain pool.try_claim() until empty."""

    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64,
    ) raises:
        # State-slot recover stays INLINE in execute (Mojo 1.0.0b1 rejects
        # hoisting a method-param-origin ref return — POC3 finding).
        var sp = UnsafePointer(to=state).bitcast[
            _ForEachState[Self.State, Self.MorselT, Self.B]
        ]()
        var wid = Int(worker_id)
        # Drain loop. Cancel-polled per iteration. Cancel token + pool are
        # reached through the encapsulated bundle's pointer-free accessors.
        while True:
            if sp[].borrows.cancel_ref().is_cancelled():
                raise Error(
                    String("CancelledError: ")
                    + sp[].borrows.cancel_ref().reason()
                )
            var claimed = sp[].borrows.pool_ref().try_claim()
            if not claimed.__bool__():
                # Pool drained at point-of-observation. With a single
                # producer (the for_each_morsel driver) that finished
                # populating BEFORE dispatching drain-tasks, an empty
                # claim means truly drained — exit clean.
                return
            sp[].body[].process[Self.State, Self.MorselT](
                sp[].borrows.outer_ref(), wid, claimed.value(),
            )
