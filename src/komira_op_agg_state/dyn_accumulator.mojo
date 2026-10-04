# =============================================================================
# DynAccumulator -- cold-path type-erased accumulator wrapper
# =============================================================================
#
# ADR: an internal doc S4
#
# DynAccumulator wraps a concrete Accumulator impl inside DynValue[MAX_ACC_SIZE]
# with a vtable of function pointers for cold-path operations (finalize, merge,
# ensure_capacity, flush_partial, destroy, num_groups) PLUS per-gid readback
# and merge operations needed by the production ColumnarAggMap pipeline.
#
# The hot path (update_batch) does NOT flow through DynAccumulator -- it goes
# through MonomorphicKernel (see accumulator_set.mojo). This is the key change
# from ADR Rev 2.
#
# Cold-path operations that use this:
#   - finalize: once per query (returns full Column)
#   - finalize_int64 / finalize_utf8 / finalize_f64: per-gid readback for
#     combine output building and flush-to-partitions
#   - merge_at: per-gid fold for cross-worker combine
#   - merge_aligned: full-column SIMD merge (same-gid-space workers)
#   - flush_partial: once per abandon cycle
#   - ensure_capacity: before each morsel (could be hot, but N is small)
#   - num_groups: cold readback
#
# Phase 4: vtable extended with per-gid finalize + merge_at + merge_aligned
# to support the full production pipeline (ColumnarAggMap, columnar_agg_sink_
# combine, streaming_s3_agg). These were placeholders in Phase 3; now wired
# with real per-type thunks.
#
# =============================================================================
# SAFETY NOTE — Int-based vtable pointer passing
# =============================================================================
# All vtable fn-ptr signatures use `Int` for accumulator pointers rather than
# `UnsafePointer[T, ...]`. This is NOT integer laundering for its own sake;
# it is the ONLY viable pattern because:
#
#   1. Mojo fn-ptr type signatures cannot carry generic type params.
#      `fn(UnsafePointer[T, ...]) -> Column` is invalid in a stored fn-ptr.
#   2. The vtable must be type-erased (one struct for all accumulator types).
#   3. Mojo has a JIT bug where passing Movable types (like Column)
#      through fn-ptr calls corrupts memory on return (see accumulator_set.mojo
#      header). Int is immune.
#
# The safety contract: every `raw_ptr: Int` argument to a vtable fn-ptr is
# the address of a live, initialized concrete accumulator T stored inside a
# DynValue[MAX_ACC_SIZE]._storage. The DynAccumulator that owns the DynValue
# MUST outlive any use of the raw_ptr. The `_cast_acc[T]` helper below
# centralizes the unsafe cast so the invariant is documented in one place.
# =============================================================================

# =============================================================================
# CLUSTER-Z TODO: scheduled migration per an internal doc
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed in Cluster Z (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# See an internal doc §5 for canonical API shapes
# and an internal doc §8 for the Cluster Z schedule.
# The baseline at scripts/mut_external_origin_allowlist.txt is
# monotonic-shrinking; do NOT add new wildcard sites to this file.
# =============================================================================

from std.sys import size_of

from komira_core.arrow import Column
from komira_core.collections.dyn_value import DynValue

from komira_core.accumulator_trait import Accumulator
from komira_core.io.heap_region import HeapRegion


# PERF-CRITICAL: MAX_ACC_SIZE must be large enough for the largest accumulator.
# PercentileAcc has: List[List[Float64]] + List[Bool] + Float64 = ~80 bytes.
# SumF64KahanAcc: List[Float64] + List[Float64] = ~48 bytes.
# CountDistinctAcc: List[List[Int64]] = ~24 bytes.
# Safe ceiling with margin:
comptime MAX_ACC_SIZE: Int = 256


# =============================================================================
# AccumulatorVTable -- cold-path fn-ptrs
# =============================================================================

struct AccumulatorVTable(ImplicitlyCopyable, Movable, Copyable, Deinitable):
    """Function pointers for cold-path accumulator operations.

    NOT used for update_batch (that is monomorphic via MonomorphicKernel).

    Phase 4 additions:
      - finalize_int64: per-gid Int64 readback (SUM/COUNT/MIN/MAX Int64)
      - finalize_utf8: per-gid Optional[String] readback (MIN/MAX UTF8)
      - finalize_f64: per-gid Float64 readback (PERCENTILE)
      - merge_at: per-gid fold (self_ptr, dst_gid, other_ptr, src_gid)
      - merge_aligned: full-column fold (self_ptr, other_ptr)
    """
    var finalize: def(Int) raises thin -> Column[HeapRegion]
    var flush_partial: def(Int) raises thin -> Column[HeapRegion]
    var merge_at: def(Int, Int, Int, Int) raises thin -> None
    var merge_aligned: def(Int, Int) raises thin -> None
    var ensure_cap: def(Int, Int) raises thin -> None
    var num_groups: def(Int) thin -> Int
    var finalize_int64: def(Int, Int) thin -> Int64
    var finalize_utf8: def(Int, Int) thin -> Optional[String]
    var finalize_f64: def(Int, Int) thin -> Float64
    var finalize_f64_opt: def(Int, Int) thin -> Optional[Float64]

    def __init__(
        out self,
        finalize: def(Int) raises thin -> Column[HeapRegion],
        flush_partial: def(Int) raises thin -> Column[HeapRegion],
        merge_at: def(Int, Int, Int, Int) raises thin -> None,
        merge_aligned: def(Int, Int) raises thin -> None,
        ensure_cap: def(Int, Int) raises thin -> None,
        num_groups: def(Int) thin -> Int,
        finalize_int64: def(Int, Int) thin -> Int64,
        finalize_utf8: def(Int, Int) thin -> Optional[String],
        finalize_f64: def(Int, Int) thin -> Float64,
        finalize_f64_opt: def(Int, Int) thin -> Optional[Float64],
    ):
        self.finalize = finalize
        self.flush_partial = flush_partial
        self.merge_at = merge_at
        self.merge_aligned = merge_aligned
        self.ensure_cap = ensure_cap
        self.num_groups = num_groups
        self.finalize_int64 = finalize_int64
        self.finalize_utf8 = finalize_utf8
        self.finalize_f64 = finalize_f64
        self.finalize_f64_opt = finalize_f64_opt


# =============================================================================
# _cast_acc — centralized unsafe cast for vtable thunks
# =============================================================================

@always_inline
def _cast_acc[T: Accumulator](raw_ptr: Int) -> UnsafePointer[T, MutUntrackedOrigin]:
    """Cast a raw Int address back to a typed accumulator pointer.

    SAFETY: `raw_ptr` must be the address of a live, initialized T value
    stored inside a DynValue[MAX_ACC_SIZE]._storage buffer. The owning
    DynAccumulator must outlive any use of the returned pointer. The
    concrete type T must match the type originally passed to
    DynValue.create[T]() — the caller (vtable wiring in accumulator_factory)
    guarantees this by monomorphizing one thunk per concrete type.

    Uses MutExternalOrigin because fn-ptr signatures cannot carry origin
    parameters — the origin is "external" (owned by DynAccumulator, not
    by this thunk's stack frame).
    """
    return UnsafePointer[T, MutUntrackedOrigin](unsafe_from_address=raw_ptr)


# =============================================================================
# Cold-path thunks (one set per concrete type)
# =============================================================================

def _thunk_finalize[T: Accumulator](raw_ptr: Int) raises -> Column[HeapRegion]:
    var ptr = _cast_acc[T](raw_ptr)
    return ptr[].finalize_to_column()


def _thunk_flush_partial[T: Accumulator](raw_ptr: Int) raises -> Column[HeapRegion]:
    var ptr = _cast_acc[T](raw_ptr)
    return ptr[].flush_partial_to_column()


def _thunk_ensure_cap[T: Accumulator](raw_ptr: Int, n: Int) raises -> None:
    var ptr = _cast_acc[T](raw_ptr)
    ptr[].ensure_capacity(n)


def _thunk_num_groups[T: Accumulator](raw_ptr: Int) -> Int:
    var ptr = _cast_acc[T](raw_ptr)
    return ptr[].num_groups()


# --- Per-gid finalize thunks (Phase 4) ---
# Default implementations return sentinel values. Concrete per-type thunks
# are wired via _make_vtable_for_* factories below.

def _thunk_finalize_int64_default(raw_ptr: Int, gid: Int) -> Int64:
    """Default: return 0 (sentinel for non-int64 accumulators)."""
    return Int64(0)


def _thunk_finalize_utf8_default(raw_ptr: Int, gid: Int) -> Optional[String]:
    """Default: return None (sentinel for non-utf8 accumulators)."""
    return Optional[String](None)


def _thunk_finalize_f64_default(raw_ptr: Int, gid: Int) -> Float64:
    """Default: return 0.0 (sentinel for non-f64 accumulators)."""
    return Float64(0.0)


def _thunk_finalize_f64_opt_default(raw_ptr: Int, gid: Int) -> Optional[Float64]:
    """Default: return None (sentinel for non-percentile accumulators)."""
    return Optional[Float64](None)


# --- merge_at / merge_aligned thunks (Phase 4) ---
# Default raises -- overridden per concrete type in _make_vtable_for_*.

def _thunk_merge_at_default(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int
) raises -> None:
    raise Error("DynAccumulator.merge_at: not wired for this accumulator type")


def _thunk_merge_aligned_default(self_ptr: Int, other_ptr: Int) raises -> None:
    raise Error("DynAccumulator.merge_aligned: not wired for this accumulator type")


def _make_vtable[T: Accumulator]() -> AccumulatorVTable:
    """Build a vtable for a specific concrete accumulator type.

    Uses default (sentinel/raising) thunks for per-gid finalize and merge.
    For production wiring, use _make_vtable_for_* which supplies the real
    per-type thunks. This generic version is kept for test code that only
    exercises the trait-conforming hot path (monomorphic kernel).
    """
    return AccumulatorVTable(
        finalize=_thunk_finalize[T],
        flush_partial=_thunk_flush_partial[T],
        merge_at=_thunk_merge_at_default,
        merge_aligned=_thunk_merge_aligned_default,
        ensure_cap=_thunk_ensure_cap[T],
        num_groups=_thunk_num_groups[T],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )


# =============================================================================
# DynAccumulator
# =============================================================================

struct DynAccumulator(Movable):
    """Type-erased accumulator for cold-path operations.

    The hot path (update_batch) does NOT flow through this struct -- it goes
    through MonomorphicKernel. DynAccumulator is used for finalize, merge,
    flush_partial, ensure_capacity, and ownership of the concrete accumulator.

    Ownership model (OQ-14 Option A): DynAccumulator owns the concrete
    accumulator storage via DynValue. MonomorphicKernel borrows it via
    raw Int pointer (_acc_ptr). The kernel MUST NOT outlive its DynAccumulator.
    """

    var _value: DynValue[MAX_ACC_SIZE]
    var _vtable: AccumulatorVTable
    # Phase 4: tag stored alongside for callers that need ACC_* dispatch
    # (flush_to_partitions, output building). Same byte as AccumulatorEnum.tag.
    var tag: UInt8

    def __init__(out self, var value: DynValue[MAX_ACC_SIZE], vtable: AccumulatorVTable, tag: UInt8 = 0):
        self._value = value^
        self._vtable = vtable
        self.tag = tag

    @staticmethod
    def create[T: Accumulator](var impl: T) -> Self:
        """Create a DynAccumulator wrapping a concrete accumulator.

        Uses the generic vtable with default (sentinel) per-gid thunks.
        For production use, prefer create_with_tag which also stores the
        ACC_* tag needed by ColumnarAggMap callers.
        """
        var vtable = _make_vtable[T]()
        var value = DynValue[MAX_ACC_SIZE].create[T](impl^)
        return Self(value^, vtable)

    @staticmethod
    def create_with_vtable[T: Accumulator](
        var impl: T, vtable: AccumulatorVTable, tag: UInt8,
    ) -> Self:
        """Create a DynAccumulator with a caller-supplied vtable and tag.

        Used by the production factory (_make_acc_set) which wires per-type
        merge + finalize thunks.
        """
        var value = DynValue[MAX_ACC_SIZE].create[T](impl^)
        return Self(value^, vtable, tag)

    def raw_ptr(self) -> Int:
        """Return the raw address of the concrete accumulator storage.

        Used by MonomorphicKernel to borrow the accumulator. The returned
        Int is an opaque pointer that the kernel thunk reconstructs via
        UnsafePointer[T] with `unsafe_from_address=raw_ptr`.

        SAFETY: The returned address is only valid while this DynAccumulator
        is alive. Do NOT cache across DynAccumulator moves or drops.

        NOTE: For external callers that immediately want a typed pointer
        (e.g. the tag-dispatch sites in columnar_agg_map.mojo), prefer
        `as_mut[T]()` -- it delegates to the DynValue storage's
        `_as_ptr[T]` and avoids the `unsafe_from_address=Int(...)`
        laundering at the call site.
        """
        return Int(self._value._as_ptr[UInt8]())

    @always_inline
    def as_mut[
        _mut: Bool, o: Origin[mut=_mut], //, T: Accumulator,
    ](ref [o] self) -> UnsafePointer[T, o]:
        """Return a typed pointer to the concrete accumulator of type T with
        ORIGIN TIED to `self`.

        This is the ONE call-site-facing entry for tag-dispatched access to
        the concrete accumulator inside a DynAccumulator. Every tag-dispatch
        helper in columnar_agg_map.mojo / streaming_s3_agg.mojo funnels
        through this method, which in turn delegates to
        `DynValue._as_ptr[T]()`. The `_value` field is a `DynValue` stored
        INLINE in `self`, so the delegated pointer inherits `self`'s origin
        and the compiler tracks every deref site against `self`'s liveness.

        CLUSTER-Z: previously returned a wildcard-origin
        (MutExternalOrigin) pointer by delegating to a `DynValue._as_ptr`
        that round-tripped the storage address through `Int(...)` (hard-ban
        #4 + hard-ban #3). The raw-address round-trip and wildcard are now
        gone — `_as_ptr` returns a `self`-origin-tied pointer and that origin
        propagates through here.

        SAFETY CONTRACT (caller must honor):
          1. Caller MUST verify `self.tag == <T-matching tag>` before
             calling. Mismatched T is immediate UB (type-punned read
             of the wrong concrete accumulator state).
          2. The returned pointer's origin `o` is tied to the receiver borrow,
             so the compiler keeps `self` alive across every deref. Caller must
             still not cache the pointer across a move or drop of the owning
             DynAccumulator.

        WHY A METHOD AND NOT INLINE AT CALL SITES:
          Consolidating the cast in one place means the SAFETY comment
          sits on one function, not on 13 duplicated arms in
          columnar_agg_map.mojo.
        """
        # `_value` is inline in self, so `_value._as_ptr[T]()` ties to the
        # `_value` sub-origin; re-tie to the whole-self origin `o` (mirrors
        # RecordBatch._column_ref) so the returned type matches the signature.
        return self._value._as_ptr[T]().unsafe_origin_cast[o]()

    def finalize(mut self) raises -> Column[HeapRegion]:
        return self._vtable.finalize(self.raw_ptr())

    def flush_partial(mut self) raises -> Column[HeapRegion]:
        return self._vtable.flush_partial(self.raw_ptr())

    def merge_at(
        mut self, dst_gid: Int, imm other: Self, src_gid: Int,
    ) raises:
        """Per-gid merge: fold other[src_gid] into self[dst_gid].

        Used by ColumnarAggMap.merge_from / merge_from_partition /
        merge_from_flush for cross-worker combine.
        SAFETY: `read other` is sufficient — the vtable thunk casts the raw
        address to the concrete type and reads src state. The concrete
        merge_at takes `read src` for the source operand.
        """
        self._vtable.merge_at(self.raw_ptr(), dst_gid, other.raw_ptr(), src_gid)

    def merge_aligned(mut self, imm other: Self) raises:
        """Full-column merge: fold other into self (same gid space).

        Used by AccumulatorEnum.merge fast path (cross-worker S3 aggregators).
        PRECONDITION: self.num_groups() == other.num_groups().
        """
        self._vtable.merge_aligned(self.raw_ptr(), other.raw_ptr())

    def ensure_capacity(mut self, n_groups: Int) raises:
        self._vtable.ensure_cap(self.raw_ptr(), n_groups)

    def num_groups(self) -> Int:
        return self._vtable.num_groups(self.raw_ptr())

    # --- Per-gid finalize (Phase 4) ---

    def finalize_int64(self, gid: Int) -> Int64:
        """Read a single Int64 value at gid. Returns 0 for unseen/OOB."""
        return self._vtable.finalize_int64(self.raw_ptr(), gid)

    def finalize_utf8(self, gid: Int) -> Optional[String]:
        """Read a single Optional[String] at gid. Returns None for unseen/OOB."""
        return self._vtable.finalize_utf8(self.raw_ptr(), gid)

    def finalize_f64(self, gid: Int) -> Float64:
        """Read a single Float64 at gid. Returns 0.0 for unseen/OOB."""
        return self._vtable.finalize_f64(self.raw_ptr(), gid)

    def finalize_f64_optional(self, gid: Int) -> Optional[Float64]:
        """Nullable readback for percentile finalize. Returns None for
        unseen groups (matches v0.3 SQL NULL semantics for an empty /
        all-NaN group). Dispatches through dedicated vtable slot.
        """
        return self._vtable.finalize_f64_opt(self.raw_ptr(), gid)
