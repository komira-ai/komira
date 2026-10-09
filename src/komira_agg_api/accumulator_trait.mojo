# =============================================================================
# Accumulator trait -- contract for columnar (SoA) accumulators
# =============================================================================
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

    `gids_ptr` is an `UnsafePointer[Int, MutUntrackedOrigin]`, and
    `col_data_ptr` an `UnsafePointer[UInt8, MutUntrackedOrigin]` plus
    `col_offset`. Raw pointers avoid passing a Column through the fn-ptr
    boundary (the Mojo JIT corrupts Movable values passed through
    fn-ptrs). Each concrete impl casts `col_data_ptr` to the right typed
    pointer internally.
    """

    # Encapsulation exception: this trait signature takes raw
    # UnsafePointers across the module boundary, which the pointer rules
    # otherwise forbid. It is accepted here because the Mojo JIT corrupts
    # Movable (Column) values round-tripped through the fn-ptr that
    # implements vtable dispatch for DynAccumulator. Passing a raw pointer
    # + offset sidesteps the corruption.
    #
    # Lifetime contract (caller MUST uphold):
    #   - `gids_ptr` points to `n` valid `Int` group IDs, contiguous, owned
    #     by the caller. Read-only from update_batch's perspective.
    #   - `col_data_ptr` + `col_offset` points into an Arrow column buffer
    #     the caller has kept alive (typical call path: Column extracted
    #     from a RecordBatch that the consumer pins via `_ = batch`).
    #   - Both pointers MUST remain valid for the duration of the
    #     update_batch call. After return, the callee MUST NOT stash them.
    # Implementation contract:
    #   - Must not cache either pointer on the accumulator struct. The
    #     caller may pass different pointers on the next call.
    #   - Must interpret `col_data_ptr` as the same Scalar type the
    #     plan compiler classified. A type mismatch is UB.
    # Once the JIT corruption is fixed this can become
    # `ref [origin] Column`; until then UnsafePointer is the only shape
    # that works.
    def update_batch(
        mut self,
        gids_ptr: UnsafePointer[Int, MutUntrackedOrigin],
        col_data_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        col_offset: Int,
        n: Int,
    ) raises: ...

    def finalize_to_column(mut self) raises -> Column[HeapRegion]: ...

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]: ...

    def ensure_capacity(mut self, n_groups: Int) raises: ...

    def num_groups(self) -> Int: ...
