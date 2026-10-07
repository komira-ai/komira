# =============================================================================
# komira_eval.filter_state — Per-worker FilterState for OpFilter
#
#
# Each `OpFilter` instance owns a `Slab[FilterState]` keyed by worker_id.
# Each FilterState wraps the per-worker scratch state required by the
# ExpressionExecutor's hot path: the surviving-rows selection vector (`sel`)
# plus the per-conjunction AdaptiveFilter state used to dynamically reorder
# predicate evaluation.
#
# Structure
# ---------
#   - `ConjunctionState` owns a single `AdaptiveFilter` for the conjunction at
#     the root level. The conjunction-aware walker is recursive over EXPR_AND,
#     so nested ANDs could each get their own ConjunctionState; a single root
#     covers the flattened-AND chain.
#   - `FilterState.conjunction_state` holds the ConjunctionState (behind an
#     OwnedPointer; see FilterState's docstring).
#   - `FilterState.with_conjunction(n_predicates, worker_id)` factory —
#     builds a FilterState with the AdaptiveFilter pre-allocated for
#     n_predicates conjuncts, seeded by the worker_id.
#   - The adaptive walker reuses the parent FilterState's stack-local scratch
#     rather than a per-conjunct `temp_false` SelectionVector.
#
# Size budget
# -----------
# AdaptiveFilter ≈ 2 * sizeof(List[UInt32]) (perm + swap_likeliness, each
# 24-byte header + 4-byte payload × n_predicates) + 32 bytes of POD scalars
# + XorShift64 (8 bytes). For n_predicates=4: 2 * (24 + 16) + 32 + 8 = 120
# bytes inline + ~80 bytes heap. Well under a 700-900 byte per-worker budget.
#
# Destroy-recreate safety
# -----------------------
# `ConjunctionState` holds `AdaptiveFilter` (OwnedPointer-backed throughout:
# `permutation` and `swap_likeliness` are `List[UInt32]` POD-element). NO
# wildcard origins; NO byte-slab + wildcard cast. A destroy-recreate stress
# test exercises a non-trivial FilterState (with conjunction_state populated)
# across 100 cycles.
#
# Cross-references:
#   - `komira_eval.expression_executor` — adaptive-walker entry
#     point `select_expression_adaptive`.
#   - `komira_eval.adaptive_filter` — the AdaptiveFilter state
#     machine.
#   - `komira_arrow.selection_vector_row` — RowSelectionVector type.
#   - `komira_engine_operators.op_filter` — owns
#     `Slab[FilterState]` + ExpressionExecutor.
# =============================================================================

from std.memory import OwnedPointer

from komira_eval.adaptive_filter import AdaptiveFilter
from komira_arrow.selection_vector_row import (
    STANDARD_VECTOR_SIZE,
    RowSelectionVector,
)


# Default upper bound on the per-handle Slab size. OpFilter's __init__
# takes the actual size from `num_physical_cores()`; this constant is
# referenced by the destroy-recreate stress test as the canonical slot count.
comptime MAX_WORKERS_DEFAULT: Int = 16


# -----------------------------------------------------------------------------
# ConjunctionState — per-conjunction adaptive ordering state.
# -----------------------------------------------------------------------------
#
# Owns one AdaptiveFilter for the conjunction. ConjunctionState lives as a field of FilterState (NOT as a
# separate local on OpFilter / ExpressionExecutor). This preserves the
# one-outer-struct lifetime invariant (FilterState owns the
# ConjunctionState).
#
# Fields:
#   - `adaptive`: AdaptiveFilter state machine. begin_filter / end_filter
#     are called from inside the conjunction-evaluation loop in
#     ExpressionExecutor.
#   - `n_predicates`: the number of conjuncts. Constant for the lifetime
#     of this state. Mirrors adaptive.n_predicates() but kept as a struct
#     field for cheap access.
#
# Destroy-recreate safety: AdaptiveFilter is `Movable, Deinitable` with
# `List[UInt32]` fields (POD-element). XorShift64 is 8-byte POD. No
# wildcard origins, no byte-slab + cast.
#
# Movable, Deinitable — fits any container (Slab, Optional).


struct ConjunctionState(Movable, Deinitable):
    """Per-conjunction adaptive-ordering state.

    Wraps an `AdaptiveFilter` (5/20/10 WARMUP/EXPLORE/OBSERVE state
    machine) for one conjunction. Lives at the end of
    an OwnedPointer chain anchored on `FilterState.conjunction_state`
    (see FilterState's docstring for the heap-pinning rationale).

    Fields:
        adaptive: The AdaptiveFilter state machine. Inline here; the
            outer OwnedPointer on FilterState provides the heap-pinned
            address that protects this struct's inline heap-owning
            fields from move-induced corruption.
        n_predicates: Cached predicate count (== adaptive.n_predicates()).

    Lifetime:
        Allocated once at FilterState construction (via
        `FilterState.with_conjunction(n_predicates, worker_id)`); reused
        across all batches processed by this worker.
    """

    var adaptive: AdaptiveFilter
    var n_predicates: Int

    def __init__(out self, n_predicates: Int, worker_id: Int):
        """Build a fresh ConjunctionState for `n_predicates` predicates.

        Args:
            n_predicates: Number of conjuncts in the AND-chain (>= 1).
                For n == 1 the AdaptiveFilter degenerates to a no-op
                state machine (no swaps possible) — still safe to use
                via begin_filter / end_filter.
            worker_id: Worker index for the RNG seed.
        """
        self.adaptive = AdaptiveFilter(
            n_predicates=n_predicates, worker_id=worker_id
        )
        self.n_predicates = n_predicates


# -----------------------------------------------------------------------------
# FilterState — per-worker scratch for OpFilter / ExpressionExecutor.
# -----------------------------------------------------------------------------
#
# One FilterState per worker thread, allocated at `OpFilter.__init__` and
# placed into a `Slab[FilterState]` indexed by `OpExecCtx.worker_id`.
#
# Fields:
#   - `sel`: pre-allocated `RowSelectionVector` sized to
#     `STANDARD_VECTOR_SIZE` (2048). `ExpressionExecutor.select_expression`
#     writes surviving row indices into this buffer; `OpFilter.execute_op`
#     reads the length to drive the gather-batch materialization.
#   - `conjunction_state`: the AdaptiveFilter-bearing per-conjunction
#     state. `Optional` so callers that don't (yet) build it — including
#     the non-adaptive walker — can still construct a FilterState.

struct FilterState(Movable, Deinitable):
    """Per-worker scratch state for `OpFilter` + `ExpressionExecutor`.

    Each worker thread that dispatches into a given `OpFilter` operator
    instance reads its own FilterState by `worker_id` index into the
    OpFilter's `Slab[FilterState]`. The FilterState owns a pre-allocated
    `RowSelectionVector` for surviving rows and an always-populated
    `ConjunctionState` (a no-op n_predicates=1 default when the caller
    doesn't use the adaptive walker).

    Why ALWAYS-POPULATED (not Optional)
    -----------------------------------
    `Optional[ConjunctionState]` does not work here — when paired with
    OpFilter's `num_physical_cores()`-sized `Slab[FilterState]` and the
    embedded heap-owning `AdaptiveFilter.permutation: List[UInt32]`, the
    None-niche of Optional interacts poorly with Slab's element-move
    during construction (a SIGSEGV in tcmalloc). So a FilterState ALWAYS
    allocates a
    ConjunctionState (the default ctor uses n_predicates=1, which makes
    AdaptiveFilter a no-op state machine — zero swap slots, zero
    convergence work). Per-worker storage is reused; the cost is one
    AdaptiveFilter per worker (~120 bytes inline + 12 bytes heap for
    n_predicates=1's permutation list).

    Lifetime model:
        - Allocated once at `OpFilter.__init__` time, one per worker, into
          the parent `Slab[FilterState]`.
        - Reused for every batch on that worker; never re-allocated.
        - Destroyed when the parent `OpFilter` drops (handle teardown).
        - Disjoint across workers — worker_id `i` reads only slot `i`,
          so no cross-worker aliasing; safe under `parallelize`.

    Fields:
        sel: Surviving rows from `ExpressionExecutor.select_expression`.
             Pre-allocated `STANDARD_VECTOR_SIZE = 2048` slots.
        conjunction_state: Per-conjunction AdaptiveFilter state. Default
             is n_predicates=1 (a no-op state machine). The adaptive
             walker path uses `with_conjunction(n_predicates, worker_id)`
             to allocate with the real n_predicates.
    """

    var sel: RowSelectionVector
    # Heap-pinned (OwnedPointer) so FilterState's INLINE size stays
    # ~32 bytes (RowSelectionVector header only). The ConjunctionState +
    # AdaptiveFilter heap lives behind a single 8-byte pointer; this
    # keeps `Slab[FilterState]`'s per-slot stride small and matches the
    # base byte layout (slot reads remain stable with multi-worker slabs).
    # Inlining ConjunctionState directly on FilterState (without
    # OwnedPointer) corrupts slot reads in `Slab[FilterState]` with
    # num_physical_cores slots. OwnedPointer indirection
    # eliminates that hazard by anchoring the heap-owning fields at a
    # stable heap address.
    var conjunction_state: OwnedPointer[ConjunctionState]

    def __init__(out self):
        """Allocate an empty FilterState with a no-op default conjunction.

        For callers using the adaptive walker, prefer
        `with_conjunction(n_predicates, worker_id)`. The default ctor
        provides a stand-in ConjunctionState with n_predicates=1 so the
        non-adaptive `select_expression(batch, sel)` path can still pass
        a FilterState through without conditional unwrapping.
        """
        self.sel = RowSelectionVector()
        self.conjunction_state = OwnedPointer[ConjunctionState](
            value=ConjunctionState(n_predicates=1, worker_id=0)
        )

    @staticmethod
    def with_conjunction(n_predicates: Int, worker_id: Int) -> FilterState:
        """Build a FilterState with the conjunction state pre-allocated.

        Used by the adaptive walker path (`select_expression_adaptive`).
        Each per-worker FilterState carries its own ConjunctionState; the
        AdaptiveFilter seeds its RNG from worker_id per the per-worker
        combiner.

        Args:
            n_predicates: Number of conjuncts the executor's root AND
                expands to. For non-AND roots, pass 1 (the state machine
                is a no-op for n == 1).
            worker_id: This worker's index in OpFilter's Slab.

        Returns:
            A FilterState ready for the adaptive walker.
        """
        var fs = FilterState()
        fs.conjunction_state = OwnedPointer[ConjunctionState](
            value=ConjunctionState(
                n_predicates=n_predicates, worker_id=worker_id
            )
        )
        return fs^


# -----------------------------------------------------------------------------
# Size assertion helper — lets a test verify the
# in-source size matches the design doc estimate.
# -----------------------------------------------------------------------------


def filter_state_inline_size_bytes() -> Int:
    """Return the in-line size of FilterState (the struct header itself).

    The header contains a `RowSelectionVector` (POD wrapper around an
    `OwnedPointer[UInt8]` + length + capacity Ints) plus an
    `Optional[ConjunctionState]` (sum-type wrapper around the
    ConjunctionState header — which holds AdaptiveFilter + Int). The
    heap-backed buffers (selection vector storage, AdaptiveFilter's
    List[UInt32] fields) live outside this size.

    Lets a test assert the struct doesn't accrete
    fields beyond the design budget.
    """
    from std.sys import size_of
    return size_of[FilterState]()
