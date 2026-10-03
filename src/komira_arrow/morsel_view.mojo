# =============================================================================
# morsel_view.mojo -- NumericColView + MorselView traits (operator-feed seam)
# =============================================================================
#
# The FORMAT-BLIND, non-reconstructing operator-feed seam foundation.
# Two traits let the fused fold (scalar / hash
# aggregate) read its input through a COMPTIME view TYPE parameter instead of a
# concrete `BatchView`, so ANY fill (RecordBatch / arena-resident Chunk / future
# CSV / JSON / Arrow-map) feeds the SAME operator kernels with O(1)
# reset-not-reconstruct.
#
# # Why a trait, not a `_v2` sibling operator
#
# Genericizing over the view TYPE is COMPTIME-monomorphized: the `BatchView`
# monomorph of a `V: MorselView` fold is byte-identical to a hand-written
# `BatchView`-concrete fold (same `col_*` methods resolved, same arithmetic
# after the read). So the RecordBatch path is not regressed and the fused-agg
# arithmetic is untouched -- only the view TYPE it reads through becomes a
# comptime parameter. The `ChunkView` monomorph reads the arena; the arithmetic
# is shared. This is the exact structural isomorph of the existing
# `BandView` fold siblings (`consume_band` / `update_band`), generalized to a
# trait so N fill formats share ONE kernel.
#
# # The moat guarantee (verify, do not assume)
#
# The genericized fold reads EXCLUSIVELY through the `MorselView` /
# `NumericColView` trait surface below. For `V == BatchView` every method
# resolves to the pre-existing `BatchView` / `ColView` method (this file adds NO
# behavior to `BatchView`; it only declares the bound `BatchView` already
# satisfies). So the `BatchView` fold monomorph is byte-for-byte the concrete
# fold. A byte-oracle test
# proves the `BatchView` monomorph == the concrete path AND the `ChunkView`
# monomorph == the same result on identical data.
#
# # Encapsulation invariants
#   - NO `UnsafePointer` in any trait method signature (views return typed
#     scalars / typed SIMD / typed sub-views, never raw pointers).
#   - NO wildcard origins -- each conformer carries its own concrete origin.
#   - Traits only; no storage, no partial-move, no ArcPointer.
#
# Cross-references:
#   - collections/batch_view.mojo -- `BatchView` / `ColView` (conform here).
#   - the engine's `ChunkView` / `ChunkColView` (conform).
# =============================================================================


trait NumericColView(Copyable, Movable):
    """A typed borrow-view over ONE fixed-width numeric column.

    The narrow column-read surface the fused fold's per-column readers consume.
    `ColView[dtype, origin]` (RecordBatch-backed) and `ChunkColView[dtype,
    origin]` (arena / page-window-backed) both conform -- so a numeric-column
    kernel written over `C: NumericColView` monomorphizes to the RecordBatch
    reader for a `BatchView` fold and to the arena reader for a `ChunkView`
    fold, with the SAME `load[W]` arithmetic after the read.

    Members:
      - `DT`  : the column's fixed-width element DType (comptime). Lets a
                generic reader `rebind` a `load[W]` result to the caller DType.

    The `load[W]` / `has_validity` / `validity_load[W]` / `length` surface
    mirrors `PrimitiveArray[dtype]` exactly (so `ColView` conforms as-is)."""

    comptime DT: DType

    def load[W: Int](self, i: Int) -> SIMD[Self.DT, W]:
        """SIMD bulk load: read `W` contiguous elements of `Self.DT` starting at
        logical row `i`. Caller honors `[i, i + W) <= length()`."""
        ...

    def has_validity(self) -> Bool:
        """True iff this column carries a validity bitmap (may contain nulls).
        False == every row valid (no-null fast path)."""
        ...

    def validity_load[W: Int](self, i: Int) raises -> SIMD[DType.bool, W]:
        """SIMD validity load: lane `j` is True iff row `i + j` is VALID (not
        null). All-True for a column without a validity bitmap."""
        ...

    def length(self) -> Int:
        """Logical row count of this column."""
        ...


trait MorselView(Copyable, Movable):
    """A typed borrow-view over ONE morsel of columnar rows -- the seam the
    fused fold consumes.

    `BatchView[origin]` (RecordBatch-backed) and `ChunkView[origin]`
    (arena-resident Chunk-backed) both conform. A fold written over `V:
    MorselView` monomorphizes per view type: `process_chunk(cv)` is
    literally `<the generic fold>[ChunkView]`, and the `BatchView` monomorph is
    byte-identical to the concrete `process_batch` fold (the moat).

    The surface is the exact intersection the scalar / hash-aggregate fold +
    the predicate filter need:
      - geometry: `n_rows` / `num_columns`
      - selection mask: `has_selection_mask` / `selection_mask_get` (the
        reader-deferred mask -- False/identity when unset)
      - null probe: `col_is_null`
      - scalar reads: `col_scalar[dt]` (raising, bool-capable) /
        `col_scalar_nonraising[dt]` (numeric, non-raising) /
        `col_scalar_simd[dt, W]` (SIMD numeric, non-raising)

    Every method here already exists on `BatchView` with the identical
    signature, so `BatchView` conforms with ZERO body change (this file only
    declares the bound). `ChunkView` implements them over its arena."""

    def n_rows(self) -> Int:
        """Number of rows in this morsel."""
        ...

    def num_columns(self) -> Int:
        """Number of columns in this morsel."""
        ...

    def has_selection_mask(self) -> Bool:
        """True iff this morsel carries a reader-deferred selection mask the
        fold MUST honor. False == every row live."""
        ...

    def selection_mask_get(self, row: Int) raises -> Bool:
        """Is `row` LIVE under the selection mask? True when no mask is set
        (identity -- every row live)."""
        ...

    def col_is_null(self, idx: Int, row: Int) -> Bool:
        """Is cell (`idx`, `row`) SQL NULL? False for a column with no validity
        bitmap (all-valid fast path). Offset-aware, DType-agnostic."""
        ...

    def col_scalar[dt: DType](self, idx: Int, row: Int) raises -> Scalar[dt]:
        """Read the scalar of fixed-width DType `dt` at `row` from column `idx`.
        No i64 else-fallthrough -- an unhandled DType is a compile error. bool
        arm is bit-packed (hence `raises`)."""
        ...

    def col_scalar_nonraising[
        dt: DType
    ](self, idx: Int, row: Int) -> Scalar[dt]:
        """Non-raising sibling of `col_scalar[dt]` over the fixed-width NUMERIC
        matrix (bool excluded -- bit-packed). The per-agg / per-key hot-path
        read the fold's `update_scalar` siblings consume."""
        ...

    def col_scalar_simd[
        dt: DType, W: Int
    ](self, idx: Int, i: Int) -> SIMD[dt, W]:
        """SIMD-W non-raising read: `W` contiguous values of fixed-width numeric
        DType `dt` from column `idx` starting at row `i`. Caller honors
        `i + W <= n_rows`."""
        ...
