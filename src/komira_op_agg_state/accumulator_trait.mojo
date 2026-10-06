# =============================================================================
# Accumulator trait -- contract for columnar (SoA) accumulators
# =============================================================================
#
# This is the trait every accumulator of this package conforms to. Its
# `update_batch` takes borrowed spans, so no raw pointer appears in the public
# signature. (The older pointer-taking `Accumulator` in `komira_agg_api` has
# no remaining implementer or caller.)
#
# The trait defines the minimum surface required by the monomorphic kernel
# thunks and cold-path vtable thunks:
#
#   update_batch  -- HOT PATH (millions of rows per query). Called via
#                    MonomorphicKernel._fn -> _kernel_thunk[T] which is
#                    monomorphized per concrete type. The Mojo compiler sees
#                    the full body and can inline + auto-vectorize.
#
#   finalize      -- COLD PATH (once per query). Called via
#                    DynAccumulator._vtable.finalize -> _thunk_finalize[T].
#
#   flush_partial -- COLD PATH (once per abandon cycle). Arrow-columnar dump
#                    of raw accumulator state for partition flush.
#
#   ensure_capacity -- Called before each update_batch to grow group slots.
#
#   num_groups    -- Cold-path readback for combine/merge.
#
# `merge` is NOT in the trait because Mojo does not support `Self`-typed
# parameters in trait method signatures (the concrete type must be visible
# at the call site). Instead, merge is called directly by the cold-path
# thunk `_thunk_merge[T]` which monomorphizes per T and calls
# `T.merge_aligned(other)`. This is correct because the plan compiler
# guarantees type alignment across worker accumulators.
#
# Key design decisions:
#   - Group ids are 8-byte `Int`. 4-byte scalar types (UInt32) corrupt on
#     an Int round-trip through a raw address under the Mojo JIT; Int is
#     immune. The 2x buffer cost (16KB->32KB per worker) is negligible.
#   - The value column is type-erased; each impl extracts its own type.
#   - CountI64Acc ignores the value column (COUNT always increments by 1).
#   - No __init__ in the trait (construction params differ per variant).
# =============================================================================

from komira_arrow.column import Column
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


trait Accumulator(Movable, Deinitable):
    """Contract for a columnar (SoA) accumulator over dense group IDs.

    Implementations extract their own value type from Column internally.
    This enables a uniform trait signature across all accumulator types
    while keeping value materialization inside the accumulator.

    `gids` is a borrowed `Span[Int]` of group ids and `col_data` a borrowed
    `Span[UInt8]` over the value column's data buffer, plus `col_offset`.
    Spans avoid passing a Column through the fn-ptr boundary (the Mojo JIT
    corrupts Movable values passed through fn-ptrs) without putting a raw
    pointer in the public signature. Each concrete impl reads `col_data` as
    the right element type internally.
    """

    # Contract (caller MUST uphold):
    #   - `gids` holds at least `n` valid `Int` group IDs, contiguous, owned
    #     by the caller. Read-only from update_batch's perspective.
    #   - `col_data` is an Arrow column buffer the caller has kept alive
    #     (typical call path: Column extracted from a RecordBatch that the
    #     consumer pins via `_ = batch`); `col_offset` is an element offset
    #     into it. Both spans are borrowed for the duration of the call.
    # Implementation contract:
    #   - Must not stash either span or a pointer derived from it. The caller
    #     may pass different buffers on the next call.
    #   - Must interpret `col_data` as the same Scalar type the plan
    #     compiler classified. A type mismatch is UB.
    # The origin parameters keep the borrow tracked on the caller's side; an
    # implementation that wants a typed pointer forms it inside its own body.
    def update_batch[
        og: Origin, oc: Origin
    ](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises: ...

    def finalize_to_column(mut self) raises -> Column[HeapRegion]: ...

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]: ...

    def ensure_capacity(mut self, n_groups: Int) raises: ...

    def num_groups(self) -> Int: ...
