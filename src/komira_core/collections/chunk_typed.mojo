# =============================================================================
# chunk_typed.mojo — ChunkTyped[bo, Has_Sel] inner-loop primitive
# =============================================================================
#
# Inner-loop primitive for the single-materialize discipline.
#
# `ChunkTyped[bo: Origin[mut=False], Has_Sel: Bool]`: the
# `comptime if Self.Has_Sel:` branch in `row_index` ELIDES the Optional
# check + Chunk indirection at codegen — the Has_Sel=False specialization
# compiles to `return k` literally, and Has_Sel=True costs one `sel.get(k)`
# indirection per row.
#
# Why a separate primitive (not just a Chunk[bo] with runtime sel-flag)?
# The inner-loop hot path of `Stage[Program].process_batch`
# cannot afford an Optional-runtime-check per row. Path A (typed-SDK
# comptime) uses `ChunkTyped[bo, Has_Sel=False]` BEFORE filter (no sel)
# and `ChunkTyped[bo, Has_Sel=True]` AFTER filter (sel produced by the
# filter stage). Path B (untyped, `Stage[RuntimeProgram]`) uses
# `ChunkTyped[bo, Has_Sel=True]` always — selection always present, identity
# if no filter applied. The Has_Sel comptime Bool makes the per-row branch
# choice STATIC at codegen time.
#
# Compatibility:
# - `bo: Origin[mut=False]` mirrors `BatchView[bo]`'s origin parametricity.
#   ChunkTyped cannot outlive its parent RecordBatch; the borrow chain is
#   compiler-tracked through `view: BatchView[Self.bo]`.
# - `RowSelectionVector` (`komira_core.eval.selection_vector_row`) is the
#   canonical sel storage; it carries an aligned `OwnedPointer[UInt8]`-backed
#   UInt32 buffer at STANDARD_VECTOR_SIZE=2048.
#
# Encapsulation:
# - Public API: `n_rows`, `row_index`, `view`. NO `UnsafePointer` in any
#   public signature. NO wildcard origins.
# - `sel: Optional[RowSelectionVector]` — when `Has_Sel=False` the field
#   is unused at runtime; the comptime branch in `n_rows` / `row_index`
#   never reads it. We still carry the storage for trait-uniformity at
#   the surface (callers can construct from a uniform factory).
#
# =============================================================================

from std.collections import Optional

from komira_core.collections.batch_view import BatchView
from komira_core.eval.selection_vector_row import RowSelectionVector


struct ChunkTyped[bo: Origin[mut=False], Has_Sel: Bool](Movable):
    """Inner-loop primitive carrying a typed BatchView + comptime-typed
    selection presence.

    The `Has_Sel` comptime Bool selects the no-sel fast path AT CODEGEN
    TIME — `row_index(k)` resolves to `return k` literally when
    `Has_Sel=False`, with no Optional check, no branch, no indirection.

    Parameters:
        bo: Origin[mut=False] of the borrowed parent RecordBatch.
        Has_Sel: Comptime Bool — True when a RowSelectionVector is
            composed in; False for the unselected fast path.
    """

    var view: BatchView[Self.bo]
    var sel: Optional[RowSelectionVector]

    @always_inline
    def __init__(
        out self,
        view: BatchView[Self.bo],
        var sel: Optional[RowSelectionVector],
    ):
        """Generic constructor. Prefer the free-function factories
        `chunk_typed_from_view` / `chunk_typed_from_view_with_sel`
        which fix the Has_Sel slot statically.
        """
        self.view = view
        self.sel = sel^

    @always_inline
    def n_rows(self) -> Int:
        """Logical row count.

        Comptime-branches on Has_Sel: True path reads `sel.value().len()`;
        False path returns `view.n_rows()` directly.
        """
        comptime if Self.Has_Sel:
            return self.sel.value().len()
        else:
            return self.view.n_rows()

    @always_inline
    def row_index(self, k: Int) -> Int:
        """Map the k-th logical row → physical row in the underlying view.

        Hot-path per-row helper consumed by `Stage[Program].process_batch`
        inner loops. The `comptime if` elides the Optional check entirely
        when Has_Sel=False — codegen resolves to `return k`.
        """
        comptime if Self.Has_Sel:
            return Int(self.sel.value().get(k))
        else:
            return k


# =============================================================================
# Free-function factories
# =============================================================================
#
# Mojo 1.0.0b1 cannot infer the parent struct's `bo` parameter from a
# `@staticmethod` ref-param alone (see `batch_view_over` in
# `batch_view.mojo`). Free functions are the canonical
# idiom for parametric struct construction.
# =============================================================================


@always_inline
def chunk_typed_from_view[
    bo: Origin[mut=False]
](view: BatchView[bo]) -> ChunkTyped[bo, False]:
    """Construct a no-sel chunk: `Has_Sel=False`, `sel=None`.

    Used at the source side of Path A typed pipelines (pre-filter) and
    by no-filter Path A queries.
    """
    return ChunkTyped[bo, False](view, Optional[RowSelectionVector](None))


@always_inline
def chunk_typed_from_view_with_sel[
    bo: Origin[mut=False]
](
    view: BatchView[bo], var sel: RowSelectionVector
) -> ChunkTyped[bo, True]:
    """Construct a selected chunk: `Has_Sel=True`, `sel=Some(...)`.

    Used after a filter stage emits its survivor selection vector, and by
    Path B `Stage[RuntimeProgram]` always (Has_Sel=True universally —
    identity sel if no filter).
    """
    return ChunkTyped[bo, True](view, Optional[RowSelectionVector](sel^))
