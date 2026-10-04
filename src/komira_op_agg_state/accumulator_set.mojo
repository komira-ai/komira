# =============================================================================
# AccumulatorSet -- unified container for monomorphic kernels + DynAccumulators
# =============================================================================
#
# ADR: an internal doc S2-S4
#
# Holds N monomorphic hot-path kernels (one per agg expression) and N
# DynAccumulators (for cold-path finalize/merge). The plan compiler wires
# both at plan-compile time via the factory table.
#
# IMPORTANT: Column is NOT passed through the fn-ptr boundary. Mojo
# has a JIT bug where moving a Column into a fn-ptr call corrupts memory
# on return. Instead, the caller extracts the raw data pointer + offset
# before dispatch and passes them as Int. The thunk reconstructs a
# Slab[Int] for gids and calls the trait-conforming update_batch
# with a Column built from the raw pointers. This avoids the bug.
#
# Hot-path usage:
#   for a in range(n_kernels):
#       kernels[a].call(gids_raw, col_data_raw, col_offset, n)
#
# Cold-path usage:
#   for a in range(n_accs):
#       var col = dyn_accs[a].finalize()
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

from komira_core.arrow import Column
from komira_core.collections.slab import Slab

from komira_core.accumulator_trait import Accumulator
from .dyn_accumulator import DynAccumulator, MAX_ACC_SIZE, _cast_acc


# =============================================================================
# MonomorphicKernel -- one monomorphized process_batch per agg expression
# =============================================================================

struct MonomorphicKernel(Movable, Copyable):
    """One monomorphized update_batch invocation.

    fn-ptr signature: (acc_ptr, gids_ptr, col_data_ptr, col_offset, n) -> None
    All arguments are Int (raw addresses / scalars). This avoids passing
    Column (Movable, heap-owning) through the fn-ptr boundary which triggers
    a Mojo JIT bug.

    PERF-CRITICAL: This is the innermost loop of aggregation.
    """
    var _fn: def(Int, Int, Int, Int, Int) raises thin -> None
    var _acc_ptr: Int
    var _value_col_index: Int

    def __init__(
        out self,
        _fn: def(Int, Int, Int, Int, Int) raises thin -> None,
        _acc_ptr: Int,
        _value_col_index: Int,
    ):
        self._fn = _fn
        self._acc_ptr = _acc_ptr
        self._value_col_index = _value_col_index

    def call(self, gids_raw: Int, col_data_raw: Int, col_offset: Int, n: Int) raises:
        """Execute the monomorphic kernel.

        Args:
            gids_raw: Raw address of Int gid elements. Caller owns buffer.
            col_data_raw: Raw address of column data buffer.
            col_offset: Element offset into the column data.
            n: Number of rows in this batch.
        """
        self._fn(self._acc_ptr, gids_raw, col_data_raw, col_offset, n)


def _kernel_thunk[T: Accumulator](
    acc_raw: Int,
    gids_raw: Int,
    col_data_raw: Int,
    col_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel thunk for accumulator type T.

    PERF-CRITICAL: Instantiated once per concrete type T. T.update_batch
    is a direct call with the full body visible to the Mojo compiler.

    All arguments are Int (raw pointers/scalars). The thunk builds a
    Slab[Int] for gids and a minimal Column wrapper for the trait
    method. This avoids passing Column through the fn-ptr boundary.
    """
    # SAFETY: acc_raw is the address of a live T inside DynValue storage.
    # See _cast_acc for the full safety contract.
    var ptr = _cast_acc[T](acc_raw)
    # SAFETY: gids_raw is a caller-owned buffer of Int group IDs, valid for
    # n elements. The caller (AccumulatorSet.call) owns the buffer and keeps
    # it alive for the duration of this call.
    var gids_ptr = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=gids_raw)
    # SAFETY: col_data_raw is a pointer to the Arrow column's raw data buffer.
    # The caller owns the Column and keeps it alive for the duration of this
    # call. col_offset is the element offset into the buffer.
    var col_data_ptr = UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=col_data_raw)
    # Pass raw pointers directly to the accumulator. No Column construction
    # needed -- avoids Mojo JIT bug with Movable types in fn-ptrs.
    ptr[].update_batch(gids_ptr, col_data_ptr, col_offset, n)


# =============================================================================
# AccDescriptor -- metadata per accumulator for output assembly
# =============================================================================

struct AccDescriptor(Movable, Copyable):
    """Per-accumulator metadata wired at plan-compile time."""
    var acc_kind: UInt8
    var value_col_index: Int
    var output_field_index: Int

    def __init__(out self, acc_kind: UInt8, value_col_index: Int, output_field_index: Int):
        self.acc_kind = acc_kind
        self.value_col_index = value_col_index
        self.output_field_index = output_field_index


# =============================================================================
# AccumulatorSet -- the unified container
# =============================================================================

struct AccumulatorSet(Movable):
    """Holds N monomorphic kernels + N DynAccumulators + N descriptors."""
    var kernels: List[MonomorphicKernel]
    var dyn_accs: Slab[DynAccumulator]
    var descriptors: List[AccDescriptor]

    def __init__(out self):
        self.kernels = List[MonomorphicKernel]()
        self.dyn_accs = Slab[DynAccumulator]()
        self.descriptors = List[AccDescriptor]()

    def add[T: Accumulator](
        mut self,
        var acc: T,
        value_col_index: Int,
        output_field_index: Int,
        acc_kind: UInt8,
    ):
        """Add an accumulator to the set (plan-compile time)."""
        var dyn_acc = DynAccumulator.create[T](acc^)
        self.dyn_accs.append(dyn_acc^)

        var kernel = MonomorphicKernel(
            _fn=_kernel_thunk[T],
            _acc_ptr=0,
            _value_col_index=value_col_index,
        )
        self.kernels.append(kernel^)
        self.descriptors.append(AccDescriptor(
            acc_kind=acc_kind,
            value_col_index=value_col_index,
            output_field_index=output_field_index,
        ))

    def finalize_wiring(mut self):
        """Patch kernel _acc_ptrs to their final DynAccumulator addresses.

        SAFETY: Each kernel's _acc_ptr is set to the raw address of the
        concrete accumulator inside the DynAccumulator's DynValue storage.
        This is safe because AccumulatorSet owns both the kernels and the
        dyn_accs — the DynAccumulator (and its storage) outlives the kernel.
        The address is stable because DynValue uses inline InlineArray storage
        (no heap indirection that could relocate).

        IMPORTANT: This must be called AFTER all add() calls are complete
        and BEFORE any kernel.call() invocations. Slab does not
        relocate elements after append, so addresses are stable.
        """
        for i in range(len(self.kernels)):
            self.kernels[i]._acc_ptr = self.dyn_accs.get_mut_interior(i).raw_ptr()

    def num_accumulators(self) -> Int:
        return len(self.kernels)


# =============================================================================
# AosAccKernel -- AoS variant of MonomorphicKernel for variable-width slots
# =============================================================================
#
# PERF-CRITICAL (Session 5 -- accumulator layout port, atom 1):
#
# The SoA `MonomorphicKernel` above receives a `gids_raw` pointer into a
# dense `Vec<T>` indexed by group_id. The AoS path (FlatHashAggregator) has
# no dense gid array -- the caller probes the HT once per row and obtains a
# per-row `EntryHandle`. The accumulator kernel then writes into the entry's
# per-slot region at a plan-time-known `agg_slot_offset`.
#
# Signature:
#     fn(entries_raw, col_data_raw, col_offset, agg_slot_offset, n) -> None
#
# All arguments are Int for the same Mojo JIT-compatibility reason
# that MonomorphicKernel uses Int-only args.
#
# This is the first step in extending `MonomorphicKernel` to the AoS path
# per an internal doc §3.3 (Option C). Session 5 ships one
# thunk (`sum_count_f64_aos_thunk`) for the ACC_SUM_COUNT_F64 16B slot, used
# by B-2 / D-1 / Q3 / Q9 / Q18 narrow layouts. Future thunks (sum_f64_aos,
# count_star_aos, sum_count_min_max_f64_aos) follow the same signature.
#
# Scatter rows remain 32B quartet (Option Q, §4). The AoS kernel signature
# is for HT-side commit; merge reads 32B source into variable-width dst via
# `_fold_agg_slots`.
# =============================================================================

struct AosAccKernel(Movable, Copyable):
    """One monomorphized AoS commit-batch invocation.

    fn-ptr signature: (entries_raw, col_data_raw, col_offset,
                       agg_slot_offset, n) -> None

    `entries_raw` is the base address of a contiguous `EntryHandle` buffer
    (one per row). `col_data_raw + col_offset` is the base of the value
    column in Arrow layout. `agg_slot_offset` is the byte offset of the
    current agg slot within an entry (= `aggs_offset + layout.offsets[a]`).

    PERF-CRITICAL: Innermost loop of AoS aggregation. The fn-ptr
    indirection cost is ~5 cycles per agg per batch (not per row); the
    per-row body lives inside the thunk.
    """
    var _fn: def(Int, Int, Int, Int, Int) raises thin -> None
    var _agg_slot_offset: Int
    var _value_col_index: Int

    def __init__(
        out self,
        _fn: def(Int, Int, Int, Int, Int) raises thin -> None,
        _agg_slot_offset: Int,
        _value_col_index: Int,
    ):
        self._fn = _fn
        self._agg_slot_offset = _agg_slot_offset
        self._value_col_index = _value_col_index

    def call(
        self,
        entries_raw: Int,
        col_data_raw: Int,
        col_offset: Int,
        n: Int,
    ) raises:
        """Execute the AoS commit kernel for `n` rows.

        Args:
            entries_raw: Raw address of a contiguous EntryHandle buffer.
                Caller owns the buffer.
            col_data_raw: Raw address of the value column's data buffer.
            col_offset: Element offset into the column data.
            n: Number of rows in this batch.
        """
        self._fn(entries_raw, col_data_raw, col_offset, self._agg_slot_offset, n)


# PERF-CRITICAL thunk: ACC_SUM_COUNT_F64 16B AoS slot.
# Writes two fields per row: [sum:f64 @+0][count:i64 @+8].
# Supersedes the quartet 32B path's four stores (sum/count/min/max) when
# the planner selects `AggLayout.sum_count_f64(n)`.
#
# Called via `AosAccKernel.call(entries_raw, col_data_raw, col_offset, n)`.
# entries_raw points to a buffer of EntryHandle values -- one per row --
# produced by the caller's find_or_create loop. col_data_raw + col_offset
# points into the value column's Arrow buffer (Float64).
def sum_count_f64_aos_thunk(
    entries_raw: Int,
    col_data_raw: Int,
    col_offset: Int,
    agg_slot_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel thunk for ACC_SUM_COUNT_F64 AoS slots.

    PERF-CRITICAL: Inner loop writes 2 stores/row (sum + count) instead of
    the 4 stores/row of the 32B quartet. Also halves HT footprint
    (16B/slot vs 32B/slot) so the table fits in L2 at 2x more groups.
    """
    # SAFETY: entries_raw is a caller-owned buffer of EntryHandle values,
    # valid for `n` elements. The caller (sink commit loop) keeps both the
    # handle buffer and the HT alive for the duration of this call.
    var entries_ptr = UnsafePointer[Int, MutUntrackedOrigin](
        unsafe_from_address=entries_raw
    )
    # SAFETY: col_data_raw + col_offset points into an Arrow Float64 buffer
    # the caller owns.  col_offset is the element offset (not byte offset).
    var col_f64 = UnsafePointer[Float64, MutUntrackedOrigin](
        unsafe_from_address=col_data_raw
    ) + col_offset

    # PERF-CRITICAL: Hot loop. Each iteration:
    #   1. Load handle ptr (= entry base address) from entries buffer.
    #   2. Load Float64 value from column.
    #   3. Write sum += value at (entry + agg_slot_offset + 0).
    #   4. Write count += 1 at (entry + agg_slot_offset + 8).
    # EntryHandle in v0.4 is a TrivialRegisterPassable wrapper around an
    # `UnsafePointer[UInt8, MutExternalOrigin]`. Its raw layout is a single
    # pointer-sized Int, so reading it as Int is byte-identical. (See
    # `EntryHandle` in flat_hash_agg.mojo for the TrivialRegisterPassable
    # contract and zero-cost shape.)
    for row in range(n):
        var entry_addr = (entries_ptr + row)[]
        var slot = UnsafePointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=entry_addr
        ) + agg_slot_offset
        var sum_p = slot.bitcast[Float64]()
        var count_p = (slot + 8).bitcast[Int64]()
        sum_p[] = sum_p[] + (col_f64 + row)[]
        count_p[] = count_p[] + Int64(1)


# PERF-CRITICAL thunk: ACC_SUM_F64 8B AoS slot.
# Writes one field per row: [sum:f64 @+0].
# Used by Q18 (SUM-only shape) when the planner selects a layout that
# includes ACC_SUM_F64 slots.
def sum_f64_aos_thunk(
    entries_raw: Int,
    col_data_raw: Int,
    col_offset: Int,
    agg_slot_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel thunk for ACC_SUM_F64 AoS slots.

    PERF-CRITICAL: Inner loop is a single f64 accumulate (1 store/row).
    Half the memory footprint of ACC_SUM_COUNT_F64 (8B vs 16B).
    """
    # SAFETY: entries_raw is a caller-owned buffer of EntryHandle values,
    # valid for `n` elements. The caller keeps the handle buffer and HT
    # alive for the duration of this call.
    var entries_ptr = UnsafePointer[Int, MutUntrackedOrigin](
        unsafe_from_address=entries_raw
    )
    # SAFETY: col_data_raw + col_offset points into an Arrow Float64 buffer
    # the caller owns. col_offset is the element offset (not byte offset).
    var col_f64 = UnsafePointer[Float64, MutUntrackedOrigin](
        unsafe_from_address=col_data_raw
    ) + col_offset

    for row in range(n):
        var entry_addr = (entries_ptr + row)[]
        var sum_p = (UnsafePointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=entry_addr
        ) + agg_slot_offset).bitcast[Float64]()
        sum_p[] = sum_p[] + (col_f64 + row)[]


# PERF-CRITICAL thunk: ACC_COUNT_STAR 8B AoS slot.
# Writes one field per row: [count:i64 @+0]. Ignores the value column --
# COUNT(*) counts rows regardless of null-ness.
# Used by CB-02 / CB-03 (COUNT(*) shape) when the planner selects a layout
# that includes ACC_COUNT_STAR slots. col_data_raw + col_offset may be 0
# (the caller can pass null pointers since we never dereference the column).
def count_star_aos_thunk(
    entries_raw: Int,
    col_data_raw: Int,
    col_offset: Int,
    agg_slot_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel thunk for ACC_COUNT_STAR AoS slots.

    PERF-CRITICAL: Inner loop bumps count++ -- no column read. Used by
    COUNT(*) shapes (CB-02/CB-03). The two "col_data_raw"/"col_offset"
    parameters are unused but kept in the signature for fn-ptr
    compatibility with the generic AosAccKernel dispatch.
    """
    _ = col_data_raw  # intentionally unused -- COUNT(*) ignores value column
    _ = col_offset
    # SAFETY: entries_raw is a caller-owned buffer of EntryHandle values.
    var entries_ptr = UnsafePointer[Int, MutUntrackedOrigin](
        unsafe_from_address=entries_raw
    )
    for row in range(n):
        var entry_addr = (entries_ptr + row)[]
        var count_p = (UnsafePointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=entry_addr
        ) + agg_slot_offset).bitcast[Int64]()
        count_p[] = count_p[] + Int64(1)


# =============================================================================
# Row-level thunks for AggCommitPlan.commit_row hot path (Session 5.5)
# =============================================================================
#
# PERF-CRITICAL (Session 5.5 -- kernel dispatch for per-row commit):
#
# `AggCommitPlan.commit_row` is the per-row hot path called from
# `agg_hash.mojo`, `agg_radix.mojo`, `agg_hash_parallel.mojo`, etc. Today
# it dispatches through `agg._update_agg(entry, agg_idx, value)` which
# loads `agg._layout.tags[agg_idx]` at runtime (InlineArray field read,
# ~1-2 cycles + ~1 cycle branch). At 6M rows * 4 aggs that's 48M per-row
# tag-checks.
#
# The fix: pre-resolve the per-slot thunk at plan construction time, store
# the fn-ptr + slot byte offset in the plan, and have commit_row call the
# thunk directly with zero per-row tag check. The thunk body is
# monomorphic (sum+count / sum-only / count-only / quartet) and reads the
# slot offset from the plan's own cache-hot storage.
#
# Signature (non-raising):
#     fn(entry_addr: Int, agg_slot_offset: Int, value: Float64) -> None
#
# The thunks are declared `fn` (not `def`) and non-raising because the
# bodies are pure pointer writes that cannot raise. This matches the
# `AosRowThunk` fn-ptr type and keeps the per-row hot path free of
# exception-propagation plumbing. All arguments are Int/Float64 (no struct
# pass-through) for the same Mojo JIT-compatibility reason that
# AosAccKernel uses Int-only args.
# =============================================================================


# -----------------------------------------------------------------------------
# Row-thunk entry pointer: typed, not Int-laundered.
# -----------------------------------------------------------------------------
#
# PERF-CRITICAL / SAFETY (audit §4 Fix B for gap7):
#
# Row thunks take the entry pointer as a typed
# `UnsafePointer[UInt8, MutExternalOrigin]`. The prior version took `Int`
# and reconstructed the pointer via `unsafe_from_address=entry_addr`;
# that pattern "severs lifetime tracking entirely"
# (the internal development notes Mojo Pointer Rules). With the typed pointer threaded
# through, the compiler anchors the thunk's write to the aggregator's
# `_entries` buffer via `EntryHandle._ptr`'s origin chain, closing the
# UAF hazard that narrow-layout enabled at high HT-resize cadence.
#
# The origin is still `MutExternalOrigin` (wildcard) at the fn-ptr
# boundary -- Mojo cannot parameterize fn-ptr signatures over a
# caller-chosen origin. But "typed wildcard pointer" is materially
# different from "Int round-trip": the compiler still knows the callee
# writes through a pointer (not a raw integer), and the call-site
# caller `commit_row` holds the `EntryHandle` live across the call,
# which anchors the underlying allocation's liveness.


# =============================================================================
# Row thunks — Phase G-pre retrofit (Wave 9 v4.1.3)
# =============================================================================
#
# Per plan §6.8a: kernel math moves INTO `Aggregator` trait impls; the
# AosRowThunk bodies become thin wrappers that load-update-store via the
# trait's static `update` method. Wave 9 v4.1.3 Phase G-pre lands the
# retrofit; the chunk-major OPT-A13 outer loop in `commit_batch` is
# preserved unchanged (the thunk fn-ptr signature is byte-identical).
#
# Retrofit shape (same for all 4 thunks):
#   var p = (entry_ptr + slot_off).bitcast[T]()
#   var s = p[]
#   AggImpl.update(s, value)        # @always_inline trait method
#   p[] = s
#
# After Mojo's @always_inline propagation through the static method
# call, the resulting machine code is byte-identical to the prior
# `p[] = p[] + value` direct form. AoS hot path commit-phase wall is
# expected to remain at ±2% vs Phase E.1.0 baseline (the Phase G-pre
# acceptance gate). If regression >5% surfaces, the mitigation is
# documented in plan §6.8a HALT condition (per-trait-impl macro
# expansion).
#
# Per `aggregators_builtin.mojo`, the Aggregator-side methods are:
#   SumF64.update(s: Float64, x: Float64)        # s += x
#   MinF64.update(s: Float64, x: Float64)        # if x < s: s = x
#   MaxF64.update(s: Float64, x: Float64)        # if x > s: s = x
#
# The COUNT field in composite slots (and ACC_COUNT_STAR / ACC_COUNT_NONNULL)
# remains an Int64 store inline. CountStar's State is UInt64 (matches the
# Aggregator trait's vectorization-friendly DType bound), but the existing
# AggLayout count slot is sized as Int64. Type-punning across UInt64↔Int64
# would require either a sibling `CountI64` Aggregator or a bitcast at
# the load/store boundary. Phase G-pre keeps the count increment inline
# with a `# COUNT-EQUIV:` comment documenting the kernel-math equivalence
# to `CountStar.update` (which is `s += 1`); a future cleanup task can
# add `CountI64` if the AggLayout count slot type unification is in
# scope. The current shape preserves existing storage semantics
# byte-for-byte.
# =============================================================================

from komira_engine_operators.unified.agg.storage.aggregators_builtin import (
    SumF64 as _SumF64,
    MinF64 as _MinF64,
    MaxF64 as _MaxF64,
)


# PERF-CRITICAL row thunk: ACC_SUM_COUNT_MIN_MAX_F64 (32B quartet).
# Writes 4 fields: sum += value, count += 1, min = min(min, value),
# max = max(max, value).
#
# Phase G-pre retrofit: kernel math for sum / min / max
# delegated to `SumF64.update` / `MinF64.update` / `MaxF64.update`. Count
# remains inline (`# COUNT-EQUIV: CountStar.update on Int64 slot`).
def row_sum_count_min_max_f64(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for the 32B quartet slot.

    Phase G-pre: kernel math delegated to Aggregator trait impls
    (SumF64 / MinF64 / MaxF64). After @always_inline propagation, the
    machine code is byte-identical to the pre-retrofit thunk.
    """
    var ap = entry_ptr + agg_slot_offset
    var sum_p = ap.bitcast[Float64]()
    var count_p = (ap + 8).bitcast[Int64]()
    var min_p = (ap + 16).bitcast[Float64]()
    var max_p = (ap + 24).bitcast[Float64]()
    # SUM: load-update-store via SumF64.update
    var s_sum = sum_p[]
    _SumF64.update(s_sum, value)
    sum_p[] = s_sum
    # COUNT-EQUIV: CountStar.update on Int64 slot (kept inline; UInt64
    # State of CountStar would require a sibling CountI64 Aggregator
    # or a UInt64↔Int64 bitcast at the load/store boundary).
    count_p[] = count_p[] + 1
    # MIN: load-update-store via MinF64.update
    var s_min = min_p[]
    _MinF64.update(s_min, value)
    min_p[] = s_min
    # MAX: load-update-store via MaxF64.update
    var s_max = max_p[]
    _MaxF64.update(s_max, value)
    max_p[] = s_max


# PERF-CRITICAL row thunk: ACC_SUM_COUNT_F64 (16B narrow).
# Writes 2 fields: sum += value, count += 1. Used by B-2 / D-1 / Q9 / Q18
# SUM+COUNT shapes when the narrow-slot gate is enabled.
#
# Phase G-pre retrofit: SUM via SumF64.update; COUNT inline (see quartet thunk).
def row_sum_count_f64(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for the 16B sum+count slot.

    Phase G-pre: kernel math for SUM delegated to SumF64.update; COUNT
    remains inline (Int64-slot vs UInt64-State type bridging deferred).
    """
    var ap = entry_ptr + agg_slot_offset
    var sum_p = ap.bitcast[Float64]()
    var count_p = (ap + 8).bitcast[Int64]()
    # SUM: load-update-store via SumF64.update
    var s_sum = sum_p[]
    _SumF64.update(s_sum, value)
    sum_p[] = s_sum
    # COUNT-EQUIV: CountStar.update on Int64 slot.
    count_p[] = count_p[] + 1


# PERF-CRITICAL row thunk: ACC_SUM_F64 (8B sum-only).
# Writes 1 field: sum += value.
#
# Phase G-pre retrofit: kernel math fully delegated to SumF64.update.
def row_sum_f64(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for the 8B sum-only slot.

    Phase G-pre: SumF64.update — the canonical 1:1 trait retrofit shape.
    """
    var sum_p = (entry_ptr + agg_slot_offset).bitcast[Float64]()
    var s = sum_p[]
    _SumF64.update(s, value)
    sum_p[] = s


# PERF-CRITICAL row thunk: ACC_COUNT_STAR / ACC_COUNT_NONNULL (8B count-only).
# Writes 1 field: count += 1. Ignores `value` -- caller can pass 0.0.
#
# Phase G-pre retrofit: COUNT-EQUIV-only — the Int64 slot type vs
# CountStar's UInt64 State requires a sibling CountI64 Aggregator
# or a UInt64↔Int64 bitcast at the load/store boundary. Plan §6.8a
# documents this as the in-scope-but-deferred type-bridging cleanup.
# Increment kept inline; semantically equivalent to CountStar.update.
def row_count_star(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for 8B count-only slots.

    `value` is unused -- COUNT(*) ignores the value column. The caller
    passes Float64(0.0) as a convention.

    Phase G-pre: kernel math is `s += 1`, semantically equivalent to
    `CountStar.update` (which uses UInt64 State). Int64-slot inline
    increment preserves storage semantics byte-for-byte.
    """
    _ = value  # intentionally unused
    var count_p = (entry_ptr + agg_slot_offset).bitcast[Int64]()
    # COUNT-EQUIV: CountStar.update on Int64 slot.
    count_p[] = count_p[] + Int64(1)


# Type alias for the row thunk fn-ptr. Every row thunk must match this
# signature. Stored inline inside AggCommitPlan's per-bucket
# InlineArray[AosRowThunk, MAX_AGGS] fields (see agg_commit.mojo).
#
# Signature change (audit §4 Fix B): first argument is
# `UnsafePointer[UInt8, MutExternalOrigin]` (typed) rather than `Int`
# (laundered). Callers pass `EntryHandle._ptr` directly; the typed
# pointer preserves the compiler's liveness chain to the aggregator's
# `_entries` buffer.
comptime AosRowThunk = def(
    UnsafePointer[UInt8, MutUntrackedOrigin], Int, Float64
) thin -> None


def resolve_row_thunk(tag: UInt8) -> AosRowThunk:
    """Plan-time dispatch: map an AccTag to its monomorphic row thunk.

    Called once per agg slot during AggCommitPlan construction. Never
    called from a hot path. Keep in lockstep with AccTag additions in
    agg_layout.mojo.
    """
    from komira_core.agg_layout import (
        ACC_SUM_COUNT_MIN_MAX_F64,
        ACC_SUM_COUNT_F64,
        ACC_SUM_F64,
        ACC_COUNT_STAR,
        ACC_COUNT_NONNULL,
    )
    if tag == ACC_SUM_COUNT_MIN_MAX_F64:
        return row_sum_count_min_max_f64
    if tag == ACC_SUM_COUNT_F64:
        return row_sum_count_f64
    if tag == ACC_SUM_F64:
        return row_sum_f64
    if tag == ACC_COUNT_STAR:
        return row_count_star
    if tag == ACC_COUNT_NONNULL:
        return row_count_star
    # Fallback: treat unknown tags as quartet (safe default that preserves
    # the pre-port byte-identical behavior).
    return row_sum_count_min_max_f64
