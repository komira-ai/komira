# =============================================================================
# Chunk / ChunkVector / ChunkView -- the reset-not-reconstruct chunk container
# =============================================================================
#
# A `Chunk` is the persistent per-(worker, pipeline) container: constructed
# ONCE at bind, its arena-backed column vectors FILLED per pull, consumed via a
# `ChunkView`, and RESET at O(1) per pull (arena bump-reset + generation bump)
# -- NEVER reconstructed inside the pull loop. That removes the per-batch
# RecordBatch construction cost on a streaming-aggregate pipeline by
# construction, not by amortization.
#
# THREE types, THREE roles (this is what lets one fold read both a chunk and a
# RecordBatch through the same seam):
#   * Chunk       -- the persistent RESET-not-reconstruct OWNER (source role:
#                    filled per pull, reset per pull, never constructed in the
#                    loop). Owned by exactly one worker; NO ArcPointer, NO
#                    cross-thread share.
#   * ChunkVector -- a POD tagged descriptor per live column (kind + dtype +
#                    arena handle + length). Lives in an inline array -- so it
#                    MUST carry no heap field (an inline-array element type is
#                    fixed at the Chunk definition site and cannot store a
#                    tracked origin). Handle is an arena byte-offset, not a
#                    pointer.
#   * ChunkView   -- the origin-tracked BORROW the fold consumes (fold role:
#                    `Pointer[Chunk, origin]`, re-derives per call like
#                    BatchView). Carries the generation stamp -- the stale-view
#                    guard: a view that survives a `reset()` is CAUGHT (debug
#                    trap, or bounded garbage a value oracle catches), never
#                    silent undefined behaviour.
#
# Current scope: the FLAT arena-resident numeric arm (fill numeric values into
# the arena, read them back through a ChunkView). The DICTIONARY code arm, the
# FLAT zero-copy page-window view arm and a full validity mask are not here
# yet -- this module provides the container, the reset and the generation
# guard, not the generator that fills it.
#
# Safety: `arena` is an `OwnedPointer[BumpArena]` (a stable heap address the
# view derives from). `vectors` is `Array[ChunkVector, MAX_LIVE_COLS]` (POD,
# inline-stored -- no heap to dangle). NO owning wildcard-origin field.
# `tests/test_chunk_destroy_recreate_stress.mojo` exercises destroy-recreate
# safety.
# =============================================================================

from std.collections import Array
from std.memory import OwnedPointer

from komira_arrow.morsel_view import MorselView, NumericColView

from komira_bump_arena.bump_arena import BumpArena, ARENA_DECLINE


# Max live columns a single pipeline's chunk carries. A comptime cap so the
# `ChunkVector` descriptor array is inline-stored (no heap slab to dangle).
# A typical aggregate projects under ten columns; 32 leaves generous headroom
# for wider shapes.
comptime MAX_LIVE_COLS: Int = 32

# Vector kinds. Only FLAT (arena-resident numeric) is filled today;
# DICTIONARY / CONSTANT / SEQUENCE are declared here so the tag space is pinned,
# but nothing produces them yet.
comptime CHUNK_KIND_UNBOUND: UInt8 = 0    # slot not yet bound this pipeline
comptime CHUNK_KIND_FLAT: UInt8 = 1       # arena-resident dense numeric
comptime CHUNK_KIND_DICTIONARY: UInt8 = 2  # RLE_DICTIONARY codes
comptime CHUNK_KIND_CONSTANT: UInt8 = 3    # single value + run length
comptime CHUNK_KIND_SEQUENCE: UInt8 = 4    # base + step


struct ChunkVector(Copyable, Movable, ImplicitlyCopyable):
    """A POD tagged descriptor for one live column's vector in a `Chunk`.

    NO heap field (this type is the element of an inline array, so it is
    fixed at the Chunk definition site and cannot carry a tracked origin). The
    payload lives in the Chunk's arena addressed by `handle`; this struct only
    records where/how.

    Fields:
        kind:       CHUNK_KIND_* tag (runtime data -- vector KIND is never a
                    comptime kernel axis).
        dtype_code: A DType tag (UInt8) for diagnostics/routing. The typed
                    load takes DType at COMPTIME (the only comptime axis);
                    this is the runtime shadow for validation.
        handle:     Arena byte-offset handle (>= 0), or `ARENA_DECLINE` (-1)
                    if this column DECLINED at bind.
        length:     Rows currently in this vector (<= grain).
        elem_bytes: Bytes per element (the runtime width feeding the arena
                    addressing).
        all_valid:  True == every row present (the uniform all-present
                    validity of the FLAT arm; a column with actual nulls
                    DECLINES at bind).
    """

    var kind: UInt8
    var dtype_code: UInt8
    var handle: Int
    var length: Int
    var elem_bytes: Int
    var all_valid: Bool

    @always_inline
    def __init__(out self):
        """An UNBOUND slot (default state before `Chunk.bind_column`)."""
        self.kind = CHUNK_KIND_UNBOUND
        self.dtype_code = 0
        self.handle = ARENA_DECLINE
        self.length = 0
        self.elem_bytes = 0
        self.all_valid = True

    @always_inline
    def __init__(
        out self,
        kind: UInt8,
        dtype_code: UInt8,
        handle: Int,
        elem_bytes: Int,
    ):
        """A bound vector descriptor. `length` starts at 0 (filled per pull)."""
        self.kind = kind
        self.dtype_code = dtype_code
        self.handle = handle
        self.length = 0
        self.elem_bytes = elem_bytes
        self.all_valid = True

    @always_inline
    def is_bound(self) -> Bool:
        """True iff this slot was successfully bound (did not DECLINE)."""
        return self.kind != CHUNK_KIND_UNBOUND and self.handle >= 0


struct Chunk(Movable, Deinitable):
    """The persistent per-(worker, pipeline) chunk container.

    Bind once (`__init__` + `bind_column` per live column), FILL per pull
    (`store` + `set_n_rows`), consume via `ChunkView`, `reset()` at O(1), repeat.
    The arena and geometry are set once and never reconstructed in the pull loop.

    Fields:
        arena:          The 64-aligned bump region behind a stable
                        `OwnedPointer`. Owns all FLAT vector bytes.
        grain:          Bind-time-constant rows/vector (see `grain`) -- the reset
                        granularity. NEVER varies within the pull loop (that is
                        what makes reset O(1)).
        live_col_count: Projected columns this pipeline touches.
        vectors:        One POD descriptor per live column (inline-stored).
        n_rows:         Rows currently in the chunk (<= grain).
        generation:     Bumped on every `reset()` -- the stale-view guard.
    """

    var arena: OwnedPointer[BumpArena]
    var grain: Int
    var live_col_count: Int
    var vectors: Array[ChunkVector, MAX_LIVE_COLS]
    var n_rows: Int
    var generation: UInt64

    def __init__(out self, grain: Int, arena_capacity: Int):
        """Construct a chunk with a fixed `grain` and an arena of
        `arena_capacity` usable bytes, allocated ONCE. Columns are bound
        afterward via `bind_column`.
        """
        self.arena = OwnedPointer(BumpArena(arena_capacity))
        self.grain = grain if grain > 0 else 1
        self.live_col_count = 0
        self.vectors = Array[ChunkVector, MAX_LIVE_COLS](
            fill=ChunkVector()
        )
        self.n_rows = 0
        self.generation = 0

    # -------------------------------------------------------------------------
    # Bind-time: reserve arena space for each live column (grain x elem_bytes).
    # -------------------------------------------------------------------------

    def bind_column(
        mut self, dtype_code: UInt8, elem_bytes: Int
    ) -> Bool:
        """Bind the next live column as a FLAT arena-resident vector of
        `grain x elem_bytes` bytes. Returns True on success; False if the arena
        DECLINEd (the arena never grows) or the column cap is hit.

        The bound column's index is `live_col_count` at call time (columns are
        bound in projection order).
        """
        if self.live_col_count >= MAX_LIVE_COLS:
            return False
        var nbytes = self.grain * elem_bytes
        var handle = self.arena[].alloc(nbytes)
        if handle == ARENA_DECLINE:
            return False
        self.vectors[self.live_col_count] = ChunkVector(
            CHUNK_KIND_FLAT, dtype_code, handle, elem_bytes
        )
        self.live_col_count += 1
        return True

    # -------------------------------------------------------------------------
    # Per-pull mutation.
    # -------------------------------------------------------------------------

    def reset(mut self):
        """O(1) reset: arena bump-reset + n_rows=0 + generation++.
        The column BINDINGS (handles/geometry) survive -- only the fill state is
        cleared. Any `ChunkView` leaked past this point is invalidated by the
        generation bump.
        """
        self.arena[].reset()
        self.n_rows = 0
        self.generation += 1
        # Re-bind the same geometry after the arena rewind so handles stay valid
        # for the next fill. The per-column descriptors keep their (kind, dtype,
        # elem_bytes); we re-alloc identical extents at the identical offsets
        # (deterministic bump order), and clear per-vector length.
        var ncols = self.live_col_count
        self.live_col_count = 0
        for i in range(ncols):
            var v = self.vectors[i]
            _ = self.bind_column(v.dtype_code, v.elem_bytes)

    @always_inline
    def set_n_rows(mut self, n: Int):
        """Set the number of live rows in this chunk (clamped to `[0, grain]`),
        and stamp each bound vector's length to match."""
        var rows = n
        if rows < 0:
            rows = 0
        if rows > self.grain:
            rows = self.grain
        self.n_rows = rows
        for i in range(self.live_col_count):
            self.vectors[i].length = rows

    @always_inline
    def store[dt: DType, W: Int](
        mut self, col_idx: Int, row_i: Int, val: SIMD[dt, W]
    ):
        """Store `W` lanes of `dt` at `row_i` into bound column `col_idx`.
        PANICS (debug) if the column is unbound or the range exceeds grain."""
        debug_assert(
            col_idx >= 0 and col_idx < self.live_col_count,
            "Chunk.store: column index out of bound range",
        )
        var handle = self.vectors[col_idx].handle
        self.arena[].store_simd[dt, W](handle, row_i, val)

    @always_inline
    def store_scalar[dt: DType](mut self, col_idx: Int, row_i: Int, val: Scalar[dt]):
        """Scalar sibling of `store[dt, 1]`."""
        self.store[dt, 1](col_idx, row_i, SIMD[dt, 1](val))

    # -------------------------------------------------------------------------
    # Read-only geometry accessors (POD scalars).
    # -------------------------------------------------------------------------

    @always_inline
    def num_rows(self) -> Int:
        return self.n_rows

    @always_inline
    def grain_rows(self) -> Int:
        return self.grain

    @always_inline
    def num_live_cols(self) -> Int:
        return self.live_col_count

    @always_inline
    def gen(self) -> UInt64:
        """Current generation (bumped by every `reset()`)."""
        return self.generation

    @always_inline
    def is_generation_current(self, g: UInt64) -> Bool:
        """True iff `g` matches the live generation -- i.e. a view/handle stamped
        at `g` has NOT been invalidated by a `reset()` since. The VALUE-level
        form of `ChunkView.is_valid()`: it lets a driver validate a STORED
        generation stamp (a leaked/persisted view) without holding a live borrow
        across a reset, which the borrow checker forbids for a direct hold. This
        is the stale-view guard's runtime belt for exactly the cases the
        compiler cannot see."""
        return g == self.generation

    @always_inline
    def col_kind(self, col_idx: Int) -> UInt8:
        return self.vectors[col_idx].kind

    @always_inline
    def col_is_bound(self, col_idx: Int) -> Bool:
        return self.vectors[col_idx].is_bound()

    @always_inline
    def load[dt: DType, W: Int](self, col_idx: Int, row_i: Int) -> SIMD[dt, W]:
        """Load `W` lanes of `dt` at `row_i` from bound column `col_idx`.
        The read primitive `ChunkView.col_load` re-hosts. PANICS (debug) if the
        column is unbound or the range exceeds grain."""
        debug_assert(
            col_idx >= 0 and col_idx < self.live_col_count,
            "Chunk.load: column index out of bound range",
        )
        var handle = self.vectors[col_idx].handle
        return self.arena[].load_simd[dt, W](handle, row_i)


# =============================================================================
# ChunkColView[dtype, origin] -- the arena-resident NumericColView (the chunk
# seam). The structural isomorph of `ColView[dtype, origin]` (RecordBatch-backed)
# but re-derives its bytes from the Chunk-owned arena per call. A numeric-column
# kernel written over `C: NumericColView` monomorphizes to THIS reader for a
# `ChunkView` fold and to `ColView` for a `BatchView` fold, sharing `load[W]`.
# =============================================================================


struct ChunkColView[dtype: DType, origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, NumericColView
):
    """Arena-resident typed borrow over ONE FLAT numeric column of a `Chunk`.

    Holds `Pointer[Chunk, Self.origin]` + the live column index; re-derives the
    arena bytes per `load[W]` (byte-identical shape to `ColView.load[W]`, only
    the backing store differs -- BumpArena vs Arrow MmapAlignedBuffer). FLAT
    columns are uniformly all-present (`all_valid == True`), so `has_validity()`
    is False and `validity_load` is all-True (a column with actual nulls
    DECLINES at bind)."""

    comptime DT: DType = Self.dtype

    var _chunk: Pointer[Chunk, Self.origin]
    var _idx: Int

    @always_inline
    def __init__(out self, ptr: Pointer[Chunk, Self.origin], idx: Int):
        """Borrow FLAT column `idx` from the Chunk under `Self.origin`.
        Constructed by `ChunkView.col_numeric`; not normally built directly."""
        self._chunk = ptr
        self._idx = idx

    @always_inline
    def load[W: Int](self, i: Int) -> SIMD[Self.dtype, W]:
        """SIMD bulk load: `W` contiguous elements of `Self.dtype` at row `i`
        from the arena (the `ColView.load[W]` re-host over BumpArena)."""
        return self._chunk[].load[Self.dtype, W](self._idx, i)

    @always_inline
    def has_validity(self) -> Bool:
        """FLAT columns are uniformly all-present -> no validity bitmap."""
        return not self._chunk[].vectors[self._idx].all_valid

    def validity_load[W: Int](self, i: Int) raises -> SIMD[DType.bool, W]:
        """All rows present -> all-True (a column with actual nulls DECLINEs
        at bind)."""
        return SIMD[DType.bool, W](fill=True)

    @always_inline
    def length(self) -> Int:
        """Logical row count of this column's arena vector."""
        return self._chunk[].vectors[self._idx].length


# =============================================================================
# ChunkView[origin] -- the origin-tracked borrow the fold consumes.
# The structural isomorph of BatchView: `Pointer[Chunk, origin]` re-derived per
# call, so the compiler tracks the borrow end-to-end through `Self.origin`. It
# additionally carries the generation stamp (the stale-view guard).
#
# THE SEAM: `ChunkView` conforms to `MorselView` (komira_arrow), so the
# ONE genericized fold `process_chunk(cv) == <fold>[ChunkView](cv)` reads a
# Chunk through the SAME trait surface it reads a `BatchView` through -- the
# format-blind operator feed. The `MorselView` surface (`n_rows` /
# `has_selection_mask` / `selection_mask_get` / `col_is_null` / `col_scalar*`)
# is implemented over the arena below; a chunk carries no selection mask + no nulls,
# so those degrade to identity (every row live, non-null).
# =============================================================================


struct ChunkView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, MorselView
):
    """Typed borrow over a `Chunk` (the `process_chunk(ChunkView)` seam input).

    Mirrors `BatchView`: holds `Pointer[Chunk, Self.origin]` and re-derives the
    column read per call, so the Chunk's lifetime bounds the view (the compiler
    forbids the view outliving the borrowed Chunk). Additionally stamps the
    Chunk's `generation` at construction -- `is_valid()` compares it to the live
    generation so a view leaked past a `reset()` is CAUGHT.

    Parameters:
        origin: Origin[mut=False] under which the borrowed Chunk lives.
    """

    var _chunk: Pointer[Chunk, Self.origin]
    var _gen: UInt64

    @always_inline
    def __init__(out self, ref [Self.origin] chunk: Chunk):
        """Borrow `chunk` under `Self.origin`, stamping its current generation."""
        self._chunk = Pointer(to=chunk)
        self._gen = chunk.generation

    @always_inline
    def n_rows(self) -> Int:
        """Live row count of the borrowed chunk."""
        return self._chunk[].n_rows

    @always_inline
    def num_live_cols(self) -> Int:
        return self._chunk[].live_col_count

    @always_inline
    def generation(self) -> UInt64:
        """The generation this view was stamped at (at construction)."""
        return self._gen

    @always_inline
    def is_valid(self) -> Bool:
        """True iff the borrowed chunk has NOT been `reset()` since this view was
        created (the stale-view guard: generation stamp == live generation).
        A False here means the view is stale -- reading it would return
        bounded garbage (a value oracle catches it; never silently wrong at a
        correct row count)."""
        return self._gen == self._chunk[].generation

    @always_inline
    def col_length(self, col_idx: Int) -> Int:
        """Rows in column `col_idx`'s vector."""
        return self._chunk[].vectors[col_idx].length

    @always_inline
    def col_kind(self, col_idx: Int) -> UInt8:
        return self._chunk[].vectors[col_idx].kind

    @always_inline
    def col_load[dt: DType, W: Int](self, col_idx: Int, row_i: Int) -> SIMD[
        dt, W
    ]:
        """SIMD read: `W` lanes of `dt` at `row_i` from column `col_idx` (the
        byte-identical re-host of `BatchView.col_*.load[W]`). Re-derives from the
        Chunk-owned arena per call under `Self.origin`. PANICS (debug) on a stale
        view (generation mismatch) or an out-of-range read."""
        debug_assert(
            self.is_valid(),
            "ChunkView.col_load: stale view -- chunk was reset since this view"
            " was created (generation guard)",
        )
        return self._chunk[].load[dt, W](col_idx, row_i)

    @always_inline
    def col_load_scalar[dt: DType](self, col_idx: Int, row_i: Int) -> Scalar[dt]:
        """Scalar sibling of `col_load[dt, 1]`."""
        return self.col_load[dt, 1](col_idx, row_i)[0]

    @always_inline
    def col_numeric[
        dt: DType
    ](self, col_idx: Int) -> ChunkColView[dt, Self.origin]:
        """Borrow FLAT column `col_idx` as a typed `NumericColView` at comptime
        DType `dt` (the arena analogue of `BatchView.col_typed[dt]`)."""
        return ChunkColView[dt, Self.origin](self._chunk, col_idx)

    # -------------------------------------------------------------------------
    # MorselView conformance (the chunk seam) -- the format-blind fold surface.
    # A chunk carries no selection mask + no nulls, so those degrade to identity.
    # -------------------------------------------------------------------------

    @always_inline
    def num_columns(self) -> Int:
        """MorselView: live column count (= `num_live_cols`)."""
        return self._chunk[].live_col_count

    @always_inline
    def has_selection_mask(self) -> Bool:
        """MorselView: chunks carry no reader-deferred selection mask."""
        return False

    @always_inline
    def selection_mask_get(self, row: Int) raises -> Bool:
        """MorselView: no mask -> every row live (identity)."""
        return True

    @always_inline
    def col_is_null(self, idx: Int, row: Int) -> Bool:
        """MorselView: FLAT columns are uniformly all-present -> never null."""
        return not self._chunk[].vectors[idx].all_valid

    @always_inline
    def col_scalar[dt: DType](self, idx: Int, row: Int) raises -> Scalar[dt]:
        """MorselView: read the scalar of DType `dt` at `row` from arena column
        `idx`. The arena load is DType-generic (`Chunk.load`), so no per-DType
        ladder is needed -- byte-identical value to `BatchView.col_scalar[dt]`
        on identical data."""
        return self.col_load[dt, 1](idx, row)[0]

    @always_inline
    def col_scalar_nonraising[
        dt: DType
    ](self, idx: Int, row: Int) -> Scalar[dt]:
        """MorselView: non-raising scalar read (the per-agg hot-path read)."""
        return self.col_load[dt, 1](idx, row)[0]

    @always_inline
    def col_scalar_simd[
        dt: DType, W: Int
    ](self, idx: Int, i: Int) -> SIMD[dt, W]:
        """MorselView: SIMD-W non-raising numeric read from arena column `idx`."""
        return self.col_load[dt, W](idx, i)


@always_inline
def chunk_view_over[
    o: Origin[mut=False]
](ref [o] chunk: Chunk) -> ChunkView[o]:
    """Module-level factory (mirrors `batch_view_over`). Mojo 1.0.0b2 cannot
    infer the parent struct's `origin` from a `@staticmethod`'s ref-parameter,
    so the free function is the documented workaround. Usage:

        var cv = chunk_view_over(chunk)
        for var i in range(0, cv.n_rows(), W):
            var lane = cv.col_load[DType.float64, W](0, i)
    """
    return ChunkView[o](chunk)
