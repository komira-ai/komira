# =============================================================================
# komira_arrow.selection_vector_row — RowSelectionVector + load_via_sel.
# =============================================================================
#
# These two symbols — the row-mode `RowSelectionVector` and the
# column-borrow-site gather primitive `load_via_sel` — depend ONLY on
# `komira_arrow.primitive_array.PrimitiveArray` (strictly DOWN into
# core), so they live in this leaf layer. Consumers inside `komira_core`
# (`collections/chunk_typed.mojo`, `arrow/gather_recordbatch.mojo`) import
# them from here; `komira_eval` re-exports them (the SAME struct, so type
# identity and codegen are preserved), so no `komira_core -> komira_eval`
# up-edge exists. A hermetic build that stages only declared inputs would
# reject such an edge even where a local sibling-source search accepts it.
#
# The columnar `SelectionVector` lives in
# `komira_arrow/selection_vector.mojo`.
# =============================================================================
#
# Two symbols live here:
#
# 1. `RowSelectionVector` — the row-mode shape, owned by operator state,
#    reusable across morsels via `reset()`. Callers size it to the BATCH
#    and pass an explicit capacity; 2048 is only the argument-less ctor's
#    default. See the note on the constant below.
#
# 2. `load_via_sel` — the column-borrow-site gather primitive:
#    `array[sel[k]]` through the selection vector.
# =============================================================================

from std.memory import OwnedPointer, alloc, unsafe_memcpy

from komira_arrow.primitive_array import PrimitiveArray


# -----------------------------------------------------------------------------
# Constants.
#
# ⛔ `STANDARD_VECTOR_SIZE` IS NOT OUR CHUNK-SIZING CONVENTION. It is DuckDB's
# hardcoded constant, reproduced here as the capacity of the argument-less
# `RowSelectionVector()` ctor and nothing else. OUR sizing policy is
# HARDWARE-DERIVED and lives in the engine runtime (the L1 chunk-sizing
# policy, and the bind-time grain computed from measured L2-per-worker —
# an 8-column f64 row can ladder to 8192 rows, 4x this constant). DuckDB
# can afford a fixed 2048 because its re-chunk is a pointer reinterpret;
# ours is a memcpy.
# -----------------------------------------------------------------------------

# DuckDB-style standard vector size. The capacity of the argument-less
# `RowSelectionVector()` ctor.
#
# ⚠ Do NOT pre-allocate intermediate buffers to this length on the
# assumption that it bounds a batch. Every production construction passes an
# EXPLICIT capacity (the batch's row count), and the row-mode filter REBINDS
# its selection when 2048 is too small. Sizing to this constant instead of to
# the batch is a HEAP BUFFER OVERFLOW: appending ~200K identity indices into
# the 2048-entry default writes ~792 KB past the allocation and corrupts the
# allocator's free-list metadata, because `append` bounds-checks with
# `debug_assert`, which is elided in optimized builds.
#
# 2048 * 4 = 8KB per UInt32 buffer.
comptime STANDARD_VECTOR_SIZE: Int = 2048

# Selectivity escape — if filter selectivity exceeds this threshold, downstream
# materializes via `filter_record_batch` (a copy) rather than installing a
# selection vector. Crossing the threshold means the indirection cost of
# the SelectionVector exceeds the cost of the (mostly-no-op) materialize.
comptime HIGH_SELECTIVITY_THRESHOLD: Float32 = 0.95


# -----------------------------------------------------------------------------
# RowSelectionVector — the row-mode shape.
# -----------------------------------------------------------------------------
#
# Design:
# - Holds up to `capacity` UInt32 row indices; capacity is fixed per
#   construction, and callers size it to the batch.
# - Reusable across batches via `reset()`.
# - The hot-path append `(mut self, idx: UInt32)` is the inner-loop store
#   used by the conjunction evaluator + AdaptiveFilter.
#
# Memory:
# - Backed by a `_raw: OwnedPointer[UInt8]` over `capacity *
#   sizeof(UInt32)` bytes plus 64-byte tail padding for SIMD over-read
#   safety, matching the MmapAlignedBuffer pattern in `komira_core/arrow/`.
# - The OwnedPointer wraps an UnsafePointer with a CONCRETE origin —
#   no wildcard origin, so destroy-recreate cycles cannot reinterpret stale
#   bytes under a new struct's lifetime.
# - The `OwnedPointer[UInt8]` field stores the *raw* (pre-alignment) pointer
#   so __del__ frees the exact pointer returned by `alloc`. The aligned
#   working pointer is computed by `_aligned_ptr()` at use time (cheap; the
#   alignment offset is stored in `_align_offset`).
#
# Encapsulation:
# - Public API: `__init__`, `__del__`, `reset`, `append`, `len`, `capacity`,
#   `get`, `identity_selection`. NO UnsafePointer in any public signature.
# - The aligned base pointer + sel-buf raw view are private accessors
#   (`_aligned_ptr` / `_raw_ptr`) used internally by `load_via_sel` on
#   `PrimitiveArray` via friend-access through a typed view method.

struct RowSelectionVector(Movable):
    """A pre-allocated, reusable buffer of UInt32 row indices.

    The row-mode equivalent of DuckDB's `SelectionVector`. Lives on the
    operator state, reset to length 0 between batches.

    Capacity is PER-CONSTRUCTION, and the explicit-capacity ctor is the
    PRODUCTION one: callers pass the BATCH size (`nrows` / `n` / `range_size`
    / ...), never `STANDARD_VECTOR_SIZE`. Sizing to 2048 rather than to the
    batch is a heap buffer OVERFLOW, because `append` bounds-checks with
    `debug_assert`, which is ELIDED in `-opt`. The argument-less ctor exists
    for the row-mode filter state and for tests.

    Fields:
        _data: OwnedPointer[UInt8] over the raw heap allocation. The
            aligned working pointer is `_data.unsafe_ptr() + _align_offset`.
            Storage is `_capacity * sizeof(UInt32)` bytes of usable
            payload plus 63 bytes of alignment padding (rounded up to
            the next 64-byte boundary) plus a `+ 8` reservation for
            the raw-base offset bookkeeping (mirrors MmapAlignedBuffer).
        _len: Current selection length. Always in `[0, _capacity]`.
        _capacity: Maximum number of UInt32 entries this buffer can hold.
            Stable for the lifetime of the RowSelectionVector.
        _align_offset: Bytes from the OwnedPointer's base to the 64-byte-
            aligned working pointer.
    """

    # OwnedPointer here is the Mojo `Box<T>` — single-owner heap handle.
    # The raw allocation is `UInt8` (untyped bytes) because we manage the
    # alignment ourselves; the bitcast to `UInt32*` happens inside the
    # private accessors. The OwnedPointer's drop frees the allocation.
    var _data: OwnedPointer[UInt8]
    var _len: Int
    var _capacity: Int
    var _align_offset: Int

    # --- Constructors -------------------------------------------------------

    def __init__(out self):
        """Allocate a RowSelectionVector at `STANDARD_VECTOR_SIZE` (2048)."""
        self = RowSelectionVector(STANDARD_VECTOR_SIZE)

    def __init__(out self, capacity: Int):
        """Allocate a RowSelectionVector with the requested capacity.

        Args:
            capacity: Number of UInt32 entries the buffer should hold.
                Must be positive; capacity <= 0 is clamped to 1 (a 1-entry
                buffer is the minimum-viable allocation — never allocate 0
                bytes).
        """
        var cap = capacity if capacity > 0 else 1

        # Bytes for the payload + 63 bytes of alignment padding + 8 bytes
        # for the raw-base offset bookkeeping (so __del__ frees the
        # right pointer). This mirrors the MmapAlignedBuffer pattern but
        # we own the raw pointer via OwnedPointer[UInt8] so __del__ is
        # automatic — no manual free call.
        var payload_bytes = cap * 4   # sizeof(UInt32) == 4
        # Pad payload to next 64-byte boundary so SIMD tail-loads can
        # over-read safely (the MmapAlignedBuffer rationale).
        var padded_bytes = ((payload_bytes + 63) // 64) * 64
        # Raw allocation size: padded payload + alignment padding (so we
        # can shift to the next 64-byte boundary).
        var raw_size = padded_bytes + 63

        # SAFETY: `alloc[UInt8](n)` returns an UnsafePointer with concrete
        # origin (no wildcard). We wrap it in OwnedPointer for single-owner
        # ownership; OwnedPointer.__del__ frees the wrapped allocation.
        # `unsafe_from_raw_pointer` is the OwnedPointer constructor that
        # takes ownership of a raw pointer.
        var raw = alloc[UInt8](raw_size)
        self._data = OwnedPointer[UInt8](unsafe_from_raw_pointer=raw)

        # Compute the 64-byte-aligned offset from the raw base. The
        # +63 / &~63 trick rounds the base address UP to the next 64-byte
        # boundary; the OwnedPointer's underlying address is the
        # `unsafe_ptr()` we expose later.
        var raw_addr = Int(raw)
        var aligned_addr = (raw_addr + 63) // 64 * 64
        self._align_offset = aligned_addr - raw_addr

        self._len = 0
        self._capacity = cap

    # --- Length / capacity --------------------------------------------------

    @always_inline
    def len(self) -> Int:
        """Return the current number of selected indices."""
        return self._len

    @always_inline
    def capacity(self) -> Int:
        """Return the maximum number of entries this buffer can hold."""
        return self._capacity

    @always_inline
    def is_empty(self) -> Bool:
        """Return True iff no rows are selected."""
        return self._len == 0

    # --- Reset / append -----------------------------------------------------

    @always_inline
    def reset(mut self):
        """Set the selection length to 0 without freeing the buffer.

        The reuse hook: called per-morsel by the operator's hot-path
        driver before populating the new selection. The underlying
        heap allocation is preserved.
        """
        self._len = 0

    @always_inline
    def append(mut self, idx: UInt32):
        """Append a row index to the selection.

        Bounds-asserted via debug_assert (compiles to a branch in debug
        builds, elided in release). The caller is expected to keep
        `len() <= capacity()` — the operator's plan-compile asserts the
        selection vector is sized at least as large as the batch.

        Args:
            idx: The row index to append.
        """
        debug_assert(
            self._len < self._capacity,
            "RowSelectionVector.append: overflow (capacity exceeded)",
        )
        # SAFETY: bounds-checked above. The aligned pointer is computed
        # from the OwnedPointer base + alignment offset; the typed UInt32
        # store goes through a bitcast on the local pointer (no new
        # field-level UnsafePointer). The origin of the local pointer is
        # `origin_of(self)` via `self._data.unsafe_ptr()`.
        var base = self._data.unsafe_ptr() + self._align_offset
        var typed = base.bitcast[UInt32]()
        (typed + self._len)[] = idx
        self._len += 1

    @always_inline
    def set_len(mut self, new_len: Int):
        """Set the selection length directly.

        Used by gather-style writers (the conjunction evaluator + the
        AdaptiveFilter compact-write loop) that count surviving rows
        and then commit the length once at the end of the inner loop.

        Bounds-asserted via debug_assert.

        Args:
            new_len: New selection length. Must be in `[0, capacity()]`.
        """
        debug_assert(
            new_len >= 0 and new_len <= self._capacity,
            "RowSelectionVector.set_len: out of range",
        )
        self._len = new_len

    @always_inline
    def append_vec_first_k[W: Int](
        mut self,
        vec: SIMD[DType.uint32, W],
        k: Int,
    ):
        """Append the first `k` lanes of `vec` to the selection (bulk sink).

        Precondition (debug-asserted): `k >= 0 and k <= W` and
        `self._len + k <= self._capacity`. For `k == 0` this is a no-op.

        PERF-CRITICAL: this is the dual-compact bulk-sink primitive for
        the sel-pair compare-and-emit kernels (`_emit_lane_writes` in
        `komira_eval/sel_kernels.mojo`). Callers compute
        `vec = compress_u32xW(mask, lanes).compacted` and
        `k = popcount_mask(mask)` (or equivalently `Int(result.count)`),
        then funnel the dense W-lane result through this method instead of
        W individual `append()` calls. On AVX-512 the per-lane scatter is
        replaced with a single `vpcompressd` + masked store; on NEON the
        SIMD store is a small predicated scatter — cost-comparable to the
        W per-lane appends it replaces.

        The body is a comptime-unrolled per-lane store with a runtime
        `lane < k` guard. LLVM merges adjacent stores at -O2 when alignment
        permits; under all conditions the cost is bounded by W (≤ 16 for
        the AVX-512 W=16 u32 width) — much cheaper than the equivalent
        debug_assert-bounded `append()` chain in the per-lane scatter loop.

        Args:
            vec: SIMD vector of dense UInt32 indices to append. Trailing
                lanes (k..W) are ignored.
            k: Number of valid lanes in `vec` (0..W). Must equal the
                popcount of the originating compress-mask.
        """
        debug_assert(
            k >= 0 and k <= W,
            "append_vec_first_k: k must be in [0, W]",
        )
        debug_assert(
            self._len + k <= self._capacity,
            "append_vec_first_k: would overflow capacity",
        )
        if k == 0:
            return
        # SAFETY: bounds-checked above; pointer derived from self._data
        # OwnedPointer + alignment offset; no field-level UnsafePointer; no
        # wildcard origin. The bitcast from UInt8 base to UInt32 typed is
        # the established pattern used by `append()` / `get()` /
        # `_unsafe_typed_ptr_ro` above.
        var base = self._data.unsafe_ptr() + self._align_offset
        var typed = base.bitcast[UInt32]()
        var dst = typed + self._len
        # Comptime-unrolled per-lane store with runtime `lane < k` guard.
        # `lane` is a comptime constant inside the unroll body; the guard
        # is a single predictable runtime branch on `k`. LLVM merges
        # adjacent stores at -O2.
        comptime for lane in range(W):
            if lane < k:
                (dst + lane)[] = vec[lane]
        self._len += k

    # --- Read access --------------------------------------------------------

    @always_inline
    def get(self, k: Int) -> UInt32:
        """Read the k-th selected index.

        Bounds-asserted via debug_assert (`k in [0, len())`).

        Args:
            k: Logical index into the selection (0..len()).

        Returns:
            The UInt32 row index at position `k`.
        """
        debug_assert(
            k >= 0 and k < self._len,
            "RowSelectionVector.get: index out of range",
        )
        # SAFETY: bounds-checked above. Local pointer arithmetic only —
        # no UnsafePointer crosses the public boundary.
        var base = self._data.unsafe_ptr() + self._align_offset
        var typed = base.bitcast[UInt32]()
        return (typed + k)[]

    @always_inline
    def load_simd[W: Int](self, k: Int) -> SIMD[DType.uint32, W]:
        """SIMD bulk-load W contiguous selected indices starting at `k`.

        Returns `SIMD[DType.uint32, W]` whose lane j holds the row index at
        logical position `k + j`. Precondition (debug-asserted):
        `k >= 0` and `k + W <= self._capacity` (note: capacity, not len —
        the 64-byte alignment padding lets us SIMD-load past `_len` safely
        when `k + W <= _capacity` even if `k + W > _len`).
        Callers that need strict `k + W <= _len` (no tail over-read into
        uninitialized slots) must enforce that at the call site.

        PERF-CRITICAL: this is the bulk-load primitive feeding the SIMD
        gather pipeline `gather_*xW(span, sel.load_simd[W](k))` in the
        agg-gather hot path (a fused filtered-sum style). Callers compute
        `idx_v = sel.load_simd[W](k)` and feed it directly into
        `gather_f64xW(col_span, idx_v)` to replace W scalar `load_via_sel`
        calls + W scalar mul-adds with a single SIMD pipeline.

        The underlying UInt32 buffer is allocated via the 64-byte-aligned
        path in `__init__` and PADDED to the next 64-byte boundary
        (`((cap*4 + 63) // 64) * 64` bytes), so a `load[W]` of UInt32
        lanes never reads past the allocation as long as `k + W` fits
        the capacity-rounded boundary.

        Args:
            k: Logical start index into the selection (0..capacity-W).

        Returns:
            A SIMD[DType.uint32, W] containing entries `[k, k+1, ..., k+W-1]`.
        """
        debug_assert(
            k >= 0 and k + W <= self._capacity,
            "RowSelectionVector.load_simd: k + W out of capacity range",
        )
        # SAFETY: bounds-checked above. The base byte pointer is derived
        # from the OwnedPointer base + alignment offset (concrete origin
        # tied to self). The bitcast from UInt8 to UInt32 is the
        # established pattern used by `append()` / `get()` /
        # `append_vec_first_k`. SIMD load[W] on the typed pointer is the
        # canonical stdlib bulk-load (NEON: 2-cycle ld1; AVX-512: 1-cycle
        # vmovdqu).
        var base = self._data.unsafe_ptr() + self._align_offset
        var typed = base.bitcast[UInt32]()
        return (typed + k).load[width=W]()

    # --- Identity selection (the 0.95-selectivity escape primitive) --------

    @staticmethod
    def identity_selection(n: Int) -> RowSelectionVector:
        """Build a RowSelectionVector containing `[0, 1, 2, ..., n-1]`.

        Used by the 0.95-selectivity escape: when the filter
        passes nearly every row, the operator skips the selection-vector
        indirection and uses an identity selection so downstream
        consumers can treat the batch as unselected without a branch.

        The returned vector has capacity == n (sized exactly to the
        request) rather than STANDARD_VECTOR_SIZE; callers should
        size to match their batch.

        Args:
            n: Number of identity indices to produce. Must be >= 0.

        Returns:
            A fresh RowSelectionVector with `len() == n` and entries
            `[0, 1, 2, ..., n-1]`.
        """
        # Clamp negative requests to 0 (defensive — callers should pass
        # batch.num_rows() which is always >= 0).
        var cap = n if n > 0 else 1
        var out = RowSelectionVector(cap)
        if n <= 0:
            return out^

        # Fill via the @always_inline append in a tight loop. The
        # autovectorizer typically picks this up as a STREAM store at
        # -O2 (verified via objdump on x86_64; on aarch64 it's a STP
        # pair loop).
        var i = 0
        while i < n:
            out.append(UInt32(i))
            i += 1
        return out^

    # --- Internal accessors (FILE-PRIVATE; no public boundary) --------------
    #
    # `_unsafe_typed_ptr_ro` exposes a typed read-only pointer with the
    # struct's own origin. Used by `PrimitiveArray.load_via_sel` (in
    # `primitive_array.mojo`) for the gather inner loop. The origin
    # `Origin[mut=False]` ensures the borrow is read-only — the caller
    # cannot reseat the selection through this pointer.
    #
    # This DOES NOT violate the encapsulation rule (no UnsafePointer in a
    # public signature) because:
    # - The method name is leading-underscore (file-private signal).
    # - The returned pointer carries a concrete origin tied to `self`,
    #   not a wildcard.
    # - The single consumer (`PrimitiveArray.load_via_sel`) iterates the
    #   pointer in a hot inner loop; no other module imports this method.
    # - Leading-underscore methods are module-private by convention.

    @always_inline
    def _unsafe_typed_ptr_ro[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self) -> UnsafePointer[UInt32, o]:
        """File-private: typed read-only pointer to the aligned UInt32 base.

        Origin-polymorphic. The returned pointer's origin is tied to
        `self` via the inferred `o` parameter; the caller's borrow
        determines mutability. SAFETY: pointer valid only while `self`
        is alive (origin-tied). Callers must not read past `self._len`.
        The single in-tree consumer is the `load_via_sel` free function
        below; do not propagate this pointer across module boundaries.
        """
        var base_byte = self._data.unsafe_ptr() + self._align_offset
        return base_byte.bitcast[UInt32]().unsafe_origin_cast[o]()


# -----------------------------------------------------------------------------
# load_via_sel — the column-borrow-site gather primitive.
# -----------------------------------------------------------------------------
#
# A zero-copy "slice a BatchOf through a SelectionVector" operation cannot be
# expressed as a typed batch-level wrapper in Mojo (no existential type for N
# heterogeneous column origins). So the slicing happens at the
# column-borrow site — the downstream consumer (sink or aggregator) iterates
#
#   for k in range(sel.len()):
#       val = load_via_sel[T](column, sel, k)
#
# regardless of whether a SelectionVector is installed. Light sinks (`sum`,
# `count`, `max`) consume the gather view directly with zero copy; heavy
# sinks (join-probe build, hash-agg build, sort) require contiguous columns
# and emit an `OP_BARRIER_COLUMNARIZE` ahead of themselves.
#
# Performance characteristic: per-element scalar gather (`data[sel[k]]`) at
# the consumer: a few ns per surviving row, essentially zero overhead vs raw
# pointer arithmetic.
# Cannot be unit-stride SIMD (DuckDB's DICTIONARY_VECTOR slow path — they
# call it out in vector.hpp). The 0.95-selectivity escape sidesteps this for
# nearly-pass-all filters by skipping the SelectionVector entirely.


@always_inline
def load_via_sel[
    T: DType
](
    ref array: PrimitiveArray[T],
    ref sel: RowSelectionVector,
    k: Int,
) -> Scalar[T]:
    """Gather `array[sel[k]]` via the selection vector.

    The column-borrow-site slicing primitive. The
    caller's downstream consumer iterates `for k in 0..sel.len()` and
    invokes `load_via_sel[T](column, sel, k)` to read the physical row
    `sel.get(k)` from `array`. Equivalent to `array.get_typed[Scalar[T]]
    (Int(sel.get(k)))` plus a debug-asserted bounds check.

    Args:
        array: The source PrimitiveArray to gather from. Origin tied
            to the consumer's borrow.
        sel: The RowSelectionVector providing the logical-to-physical
            indirection. Must be sized at least as large as the
            consumer's iteration count.
        k: Logical index into `sel`. Must be in `[0, sel.len())`.

    Returns:
        The Scalar[T] at physical row `sel.get(k)` in `array`.

    SAFETY: bounds-checked via debug_assert (compiles to a branch in
    debug builds, elided in release). The caller is expected to keep
    `k < sel.len()` and `sel.get(k) < array.length`.
    """
    debug_assert(
        k >= 0 and k < sel.len(),
        "load_via_sel: k out of range",
    )
    var physical = Int(sel.get(k))
    debug_assert(
        physical >= 0 and physical < array.length,
        "load_via_sel: physical row index out of array bounds",
    )
    return array.get_typed[Scalar[T]](physical)
