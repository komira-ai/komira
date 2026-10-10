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
# SAFETY NOTE — the vtable passes the typed storage box, not an address
# =============================================================================
# Every vtable fn-ptr takes the accumulator's storage box,
# `DynValue[MAX_ACC_SIZE]`, by ordinary argument convention (`mut` for the
# operations that change the accumulator, borrowed for the readbacks). No
# address crosses the fn-ptr boundary as an `Int` and no pointer is rebuilt
# from one: the compiler sees every vtable call borrow the box, so the
# accumulator can neither be moved nor dropped while a thunk runs, and a
# `DynAccumulator` that was moved since it was built is still found at its
# new place on the next call.
#
# Each thunk is monomorphised for one concrete `T` and recovers the typed
# view with `_cast_acc[T](box)`, which delegates to `DynValue.get[T]` (the
# checked, origin-tied reference) and widens the origin inside its own body
# only. The one remaining contract is the type match: the `T` a thunk is
# instantiated with must be the `T` the box was created with, which the wiring
# in accumulator_factory.mojo guarantees by instantiating the whole vtable for
# one concrete type; `get` checks it on every call and a mismatch aborts.
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

from std.os import abort
from std.sys import size_of

from komira_arrow.column import Column
from komira_collections.dyn_value import DynValue

from komira_op_agg_state.accumulator_trait import Accumulator
from komira_buffer.heap_region import HeapRegion


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
    var finalize: def(mut DynValue[MAX_ACC_SIZE]) raises thin -> Column[HeapRegion]
    var flush_partial: def(mut DynValue[MAX_ACC_SIZE]) raises thin -> Column[HeapRegion]
    var merge_at: def(
        mut DynValue[MAX_ACC_SIZE], Int, DynValue[MAX_ACC_SIZE], Int
    ) raises thin -> None
    var merge_aligned: def(
        mut DynValue[MAX_ACC_SIZE], DynValue[MAX_ACC_SIZE]
    ) raises thin -> None
    var ensure_cap: def(mut DynValue[MAX_ACC_SIZE], Int) raises thin -> None
    var num_groups: def(DynValue[MAX_ACC_SIZE]) thin -> Int
    var finalize_int64: def(DynValue[MAX_ACC_SIZE], Int) thin -> Int64
    var finalize_utf8: def(DynValue[MAX_ACC_SIZE], Int) thin -> Optional[String]
    var finalize_f64: def(DynValue[MAX_ACC_SIZE], Int) thin -> Float64
    var finalize_f64_opt: def(DynValue[MAX_ACC_SIZE], Int) thin -> Optional[Float64]

    def __init__(
        out self,
        finalize: def(mut DynValue[MAX_ACC_SIZE]) raises thin -> Column[HeapRegion],
        flush_partial: def(mut DynValue[MAX_ACC_SIZE]) raises thin -> Column[HeapRegion],
        merge_at: def(
            mut DynValue[MAX_ACC_SIZE], Int, DynValue[MAX_ACC_SIZE], Int
        ) raises thin -> None,
        merge_aligned: def(
            mut DynValue[MAX_ACC_SIZE], DynValue[MAX_ACC_SIZE]
        ) raises thin -> None,
        ensure_cap: def(mut DynValue[MAX_ACC_SIZE], Int) raises thin -> None,
        num_groups: def(DynValue[MAX_ACC_SIZE]) thin -> Int,
        finalize_int64: def(DynValue[MAX_ACC_SIZE], Int) thin -> Int64,
        finalize_utf8: def(DynValue[MAX_ACC_SIZE], Int) thin -> Optional[String],
        finalize_f64: def(DynValue[MAX_ACC_SIZE], Int) thin -> Float64,
        finalize_f64_opt: def(DynValue[MAX_ACC_SIZE], Int) thin -> Optional[Float64],
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


# _cast_acc — the one typed view of a storage box, for the vtable thunks
# =============================================================================

@always_inline
def _cast_acc[T: Accumulator](
    ref box: DynValue[MAX_ACC_SIZE],
) -> UnsafePointer[T, MutUntrackedOrigin]:
    """The typed view of the accumulator stored in `box`.

    Private to the package: it is the one place a thunk widens the
    reference the checked `DynValue.get[T]` returns, and the result never
    leaves the thunk body that asked for it (the fn-ptr boundary carries the
    box, not this pointer).

    SAFETY: `box` must hold a live, initialised T, created with
    `DynValue.create[T]`; the vtable wiring in accumulator_factory
    instantiates every thunk of a vtable with that one T. `box` is borrowed
    for the thunk's whole run, so the storage cannot move or drop under the
    returned pointer while the thunk body uses it; the pointer must not be
    stored. The origin is widened (and the mutability asserted) because the
    readback thunks borrow the box read-only while the accumulator types
    expose their readbacks as `mut` methods; the readbacks do not change the
    accumulator's observable state.
    """
    try:
        return (
            UnsafePointer(to=box.get[T]())
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
    except e:
        # A box that does not hold a T is a wiring bug (the SAFETY contract
        # above): a vtable from another type passed to the public
        # create_with_vtable lands here. The thunks cannot raise, so it aborts.
        abort(String("_cast_acc: ") + String(e))  # cov: unreachable reached only by a vtable wired to another type (create_with_vtable is public), which aborts the process; no welded test survives it


# =============================================================================
# =============================================================================
# Cold-path thunks (one set per concrete type)
# =============================================================================

def _thunk_finalize[T: Accumulator](mut acc: DynValue[MAX_ACC_SIZE]) raises -> Column[HeapRegion]:
    var ptr = _cast_acc[T](acc)
    return ptr[].finalize_to_column()


def _thunk_flush_partial[T: Accumulator](mut acc: DynValue[MAX_ACC_SIZE]) raises -> Column[HeapRegion]:
    var ptr = _cast_acc[T](acc)
    return ptr[].flush_partial_to_column()


def _thunk_ensure_cap[T: Accumulator](mut acc: DynValue[MAX_ACC_SIZE], n: Int) raises -> None:
    var ptr = _cast_acc[T](acc)
    ptr[].ensure_capacity(n)


def _thunk_num_groups[T: Accumulator](acc: DynValue[MAX_ACC_SIZE]) -> Int:
    var ptr = _cast_acc[T](acc)
    return ptr[].num_groups()


# --- Per-gid finalize thunks (Phase 4) ---
# Default implementations return sentinel values. Concrete per-type thunks
# are wired via _make_vtable_for_* factories below.

def _thunk_finalize_int64_default(acc: DynValue[MAX_ACC_SIZE], gid: Int) -> Int64:
    """Default: return 0 (sentinel for non-int64 accumulators)."""
    return Int64(0)


def _thunk_finalize_utf8_default(acc: DynValue[MAX_ACC_SIZE], gid: Int) -> Optional[String]:
    """Default: return None (sentinel for non-utf8 accumulators)."""
    return Optional[String](None)


def _thunk_finalize_f64_default(acc: DynValue[MAX_ACC_SIZE], gid: Int) -> Float64:
    """Default: return 0.0 (sentinel for non-f64 accumulators)."""
    return Float64(0.0)


def _thunk_finalize_f64_opt_default(acc: DynValue[MAX_ACC_SIZE], gid: Int) -> Optional[Float64]:
    """Default: return None (sentinel for non-percentile accumulators)."""
    return Optional[Float64](None)


# --- merge_at / merge_aligned thunks (Phase 4) ---
# Default raises -- overridden per concrete type in _make_vtable_for_*.

def _thunk_merge_at_default(
    mut dst: DynValue[MAX_ACC_SIZE], dst_gid: Int,
    src: DynValue[MAX_ACC_SIZE], src_gid: Int,
) raises -> None:
    raise Error("DynAccumulator.merge_at: not wired for this accumulator type")


def _thunk_merge_aligned_default(
    mut dst: DynValue[MAX_ACC_SIZE], src: DynValue[MAX_ACC_SIZE],
) raises -> None:
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
    accumulator storage via DynValue. MonomorphicKernel holds no reference
    to it: every `call` is handed the DynAccumulator, so the kernel can be
    neither stale after a move nor outlive it.
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

    @always_inline
    def as_mut[
        _mut: Bool, o: Origin[mut=_mut], //, T: Accumulator,
    ](ref [o] self) -> ref [o] T:
        """Return a reference to the concrete accumulator of type T, with
        the borrow tied to `self`.

        This is the ONE call-site-facing entry for tag-dispatched access to
        the concrete accumulator inside a DynAccumulator. Every tag-dispatch
        helper in columnar_agg_map.mojo / streaming_s3_agg.mojo funnels
        through this method, which in turn delegates to the checked
        `DynValue.get[T]()`. The `_value` field is a `DynValue` stored
        INLINE in `self`, so the delegated pointer inherits `self`'s origin
        and the compiler tracks every deref site against `self`'s liveness.

        CLUSTER-Z: previously returned a wildcard-origin
        (MutExternalOrigin) pointer by delegating to a `DynValue._as_ptr`
        that round-tripped the storage address through `Int(...)`. The raw-address round-trip and wildcard are now
        gone: `DynValue.get[T]` returns a reference tied to the storage of
        `self` and that origin propagates through here.

        SAFETY CONTRACT (caller must honor):
          1. Caller MUST verify `self.tag == <T-matching tag>` before
             calling. A mismatched T aborts (`DynValue.get` checks the
             stored type), so it is a crash, not a type-punned read.
          2. The returned reference's origin `o` is tied to the receiver
             borrow, so the compiler keeps `self` alive across every use.

        WHY A METHOD AND NOT INLINE AT CALL SITES:
          Consolidating the cast in one place means the SAFETY comment
          sits on one function, not on 13 duplicated arms in
          columnar_agg_map.mojo.
        """
        # `_value` is inline in self, so `_value.get[T]()` ties to the
        # `_value` storage sub-origin; re-tie to the whole-self origin `o`
        # (mirrors RecordBatch._column_ref) so the returned type matches the
        # signature. `get` checks the stored type: a mismatch aborts here
        # instead of reading the wrong accumulator's bytes.
        try:
            return UnsafePointer(to=self._value.get[T]()).unsafe_origin_cast[o]()[]
        except e:
            abort(String("DynAccumulator.as_mut: ") + String(e))  # cov: unreachable a type mismatch is a caller bug that aborts the process, which no welded test can survive

    def finalize(mut self) raises -> Column[HeapRegion]:
        return self._vtable.finalize(self._value)

    def flush_partial(mut self) raises -> Column[HeapRegion]:
        return self._vtable.flush_partial(self._value)

    def merge_at(
        mut self, dst_gid: Int, imm other: Self, src_gid: Int,
    ) raises:
        """Per-gid merge: fold other[src_gid] into self[dst_gid].

        Used by ColumnarAggMap.merge_from / merge_from_partition /
        merge_from_flush for cross-worker combine.
        SAFETY: `read other` is sufficient — the vtable thunk views the
        borrowed box as the concrete type and reads src state. The concrete
        merge_at takes `read src` for the source operand.
        """
        self._vtable.merge_at(self._value, dst_gid, other._value, src_gid)

    def merge_aligned(mut self, imm other: Self) raises:
        """Full-column merge: fold other into self (same gid space).

        Used by AccumulatorEnum.merge fast path (cross-worker S3 aggregators).
        PRECONDITION: self.num_groups() == other.num_groups().
        """
        self._vtable.merge_aligned(self._value, other._value)

    def ensure_capacity(mut self, n_groups: Int) raises:
        self._vtable.ensure_cap(self._value, n_groups)

    def num_groups(self) -> Int:
        return self._vtable.num_groups(self._value)

    # --- Per-gid finalize (Phase 4) ---

    def finalize_int64(self, gid: Int) -> Int64:
        """Read a single Int64 value at gid. Returns 0 for unseen/OOB."""
        return self._vtable.finalize_int64(self._value, gid)

    def finalize_utf8(self, gid: Int) -> Optional[String]:
        """Read a single Optional[String] at gid. Returns None for unseen/OOB."""
        return self._vtable.finalize_utf8(self._value, gid)

    def finalize_f64(self, gid: Int) -> Float64:
        """Read a single Float64 at gid. Returns 0.0 for unseen/OOB."""
        return self._vtable.finalize_f64(self._value, gid)

    def finalize_f64_optional(self, gid: Int) -> Optional[Float64]:
        """Nullable readback for percentile finalize. Returns None for
        unseen groups (matches v0.3 SQL NULL semantics for an empty /
        all-NaN group). Dispatches through dedicated vtable slot.
        """
        return self._vtable.finalize_f64_opt(self._value, gid)
