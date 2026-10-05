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
# on return. Instead, the caller hands the kernel the gid and data buffers as
# borrowed `Span`s and the kernel's private thunk passes the trait method the
# raw element pointers and the element offset. No address is ever carried as
# an `Int`, and the public surface names no pointer type.
#
# Hot-path usage:
#   for a in range(n_kernels):
#       acc_set.update(a, gids, col_data, col_offset, n)
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

from komira_op_agg_state.accumulator_trait import Accumulator
from komira_core.collections.dyn_value import DynValue
from .dyn_accumulator import DynAccumulator, MAX_ACC_SIZE, _cast_acc


# =============================================================================
# MonomorphicKernel -- one monomorphized process_batch per agg expression
# =============================================================================

# The type-erased kernel entry. PRIVATE to this file: it is the one fn-ptr
# shape of the SoA hot path, and the only place that names raw element
# pointers. fn-ptr types cannot carry origin parameters, so the pointer origins
# are the untracked one; the public `call` below builds them from borrowed
# `Span`s inside its own body, the thunk turns them back into spans for the
# `Accumulator.update_batch` trait method (which takes spans), and nothing
# public mentions this alias. The Ints are the value column's byte length, the
# element offset and the row count.
comptime _SoaKernelFn = def(
    mut DynValue[MAX_ACC_SIZE],
    UnsafePointer[Int, MutUntrackedOrigin],
    UnsafePointer[UInt8, MutUntrackedOrigin],
    Int,
    Int,
    Int,
) raises thin -> None


struct MonomorphicKernel(Movable, Copyable):
    """One monomorphized update_batch invocation.

    The kernel names no accumulator: `call` is handed the DynAccumulator it
    updates, so a kernel is never stale after the accumulator (or the set
    holding it) moves, and it cannot outlive it.

    PERF-CRITICAL: This is the innermost loop of aggregation.
    """
    var _fn: _SoaKernelFn
    var _value_col_index: Int

    def __init__(out self, value_col_index: Int):
        """An UNWIRED kernel: `call` raises until built by `for_accumulator`.
        The fn-ptr is private, so the only way to wire one is the type-keyed
        constructor below."""
        self._fn = _unwired_kernel_thunk
        self._value_col_index = value_col_index

    @staticmethod
    def for_accumulator[T: Accumulator](value_col_index: Int) -> Self:
        """The kernel for accumulator type `T`: `T.update_batch` is a direct
        call inside the thunk, instantiated once per concrete type."""
        var kernel = Self(value_col_index)
        kernel._fn = _kernel_thunk[T]
        return kernel^

    def call[
        og: Origin, oc: Origin
    ](
        self,
        mut acc: DynAccumulator,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Execute the monomorphic kernel against `acc`.

        Args:
            acc: The accumulator this kernel was built for (same `T`).
            gids: Group ids, one per row; at least `n` elements.
            col_data: The value column's data buffer in bytes; the kernel
                reads `n` elements starting `col_offset` elements in.
            col_offset: Element offset into the column data.
            n: Number of rows in this batch.
        """
        if n < 0 or n > len(gids):
            raise Error("MonomorphicKernel.call: n exceeds the gid buffer")
        # SAFETY: the pointers are formed from spans the caller keeps borrowed
        # for this whole call (`og`/`oc` are tracked on the parameters); the
        # untracked origin exists only because the fn-ptr signature cannot
        # name them, and `update_batch` must not stash either span (trait
        # contract). The mutable cast is nominal: the SoA kernels only read the
        # gid and data buffers.
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        self._fn(acc._value, gids_ptr, col_ptr, len(col_data), col_offset, n)


def _unwired_kernel_thunk(
    mut box: DynValue[MAX_ACC_SIZE],
    gids_ptr: UnsafePointer[Int, MutUntrackedOrigin],
    col_data_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    col_len: Int,
    col_offset: Int,
    n: Int,
) raises -> None:
    raise Error("MonomorphicKernel: not wired to an accumulator type")


def _kernel_thunk[T: Accumulator](
    mut box: DynValue[MAX_ACC_SIZE],
    gids_ptr: UnsafePointer[Int, MutUntrackedOrigin],
    col_data_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    col_len: Int,
    col_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel thunk for accumulator type T.

    PERF-CRITICAL: Instantiated once per concrete type T. T.update_batch
    is a direct call with the full body visible to the Mojo compiler.

    The thunk hands the trait method spans over the element buffers; no
    Column is built (avoids the Mojo JIT bug with Movable types in fn-ptrs).
    """
    # SAFETY: `box` holds a live T (see _cast_acc) and is borrowed `mut` for
    # this call. `gids_ptr` is valid for n Int group ids and `col_data_ptr`
    # for `col_len` bytes; both are borrowed by MonomorphicKernel.call for the
    # duration of this call, and the spans built here are not stashed.
    var ptr = _cast_acc[T](box)
    var gids = Span[Int, MutUntrackedOrigin](unsafe_ptr=gids_ptr, length=n)
    var col_data = Span[UInt8, MutUntrackedOrigin](
        unsafe_ptr=col_data_ptr, length=col_len
    )
    ptr[].update_batch(gids, col_data, col_offset, n)


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

        self.kernels.append(MonomorphicKernel.for_accumulator[T](value_col_index))
        self.descriptors.append(AccDescriptor(
            acc_kind=acc_kind,
            value_col_index=value_col_index,
            output_field_index=output_field_index,
        ))

    def update[
        og: Origin, oc: Origin
    ](
        mut self,
        index: Int,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Run accumulator `index`'s kernel over one batch (hot path).

        The kernel and the accumulator are looked up together here, so a
        set that was moved since `add` still updates the right state.
        """
        if index < 0 or index >= len(self.kernels):
            raise Error("AccumulatorSet.update: accumulator index out of range")
        self.kernels[index].call(
            self.dyn_accs[index], gids, col_data, col_offset, n
        )

    def num_accumulators(self) -> Int:
        return len(self.kernels)


# =============================================================================
# AosAccKernel -- AoS variant of MonomorphicKernel for variable-width slots
# =============================================================================
#
# PERF-CRITICAL (Session 5 -- accumulator layout port, atom 1):
#
# The SoA `MonomorphicKernel` above receives a gid buffer indexed by row and
# updates a dense per-group array. The AoS path (FlatHashAggregator) has no
# dense gid array -- the caller probes the HT once per row and learns where the
# row's entry is. The accumulator kernel then writes into the entry's per-slot
# region at a plan-time-known `agg_slot_offset`.
#
# Contract: the caller hands over the entry table as one mutable byte span
# (`table`) and, per row, the byte offset of that row's entry inside it
# (`entry_offsets`). Where the previous contract was a buffer of entry
# ADDRESSES that the kernel turned back into pointers, the offsets are plain
# integers resolved against a span the compiler tracks, so no address is ever
# rebuilt into a pointer here. The per-row arithmetic is the same single add
# (`base + offset`) the address-load path did.
#
# Kernels (a closed set, selected once per batch, not per row):
#   AOS_KERNEL_SUM_COUNT_F64  ACC_SUM_COUNT_F64 16B slot [sum:f64][count:i64]
#   AOS_KERNEL_SUM_F64        ACC_SUM_F64 8B slot [sum:f64]
#   AOS_KERNEL_COUNT_STAR     ACC_COUNT_STAR 8B slot [count:i64]; the value
#                             column is never read (it may be empty)
#
# Scatter rows remain 32B quartet (Option Q, §4). The AoS kernel signature
# is for HT-side commit; merge reads 32B source into variable-width dst via
# `_fold_agg_slots`.
# =============================================================================

comptime AOS_KERNEL_SUM_COUNT_F64: UInt8 = 0
comptime AOS_KERNEL_SUM_F64: UInt8 = 1
comptime AOS_KERNEL_COUNT_STAR: UInt8 = 2


struct AosAccKernel(Movable, Copyable):
    """One monomorphized AoS commit-batch invocation.

    `table` is the entry table (one mutable byte span over every entry),
    `entry_offsets[row]` the byte offset of row `row`'s entry in it,
    `col_data` the value column in Arrow layout (read `col_offset` elements
    in), and `agg_slot_offset` the byte offset of the current agg slot within
    an entry (= `aggs_offset + layout.offsets[a]`).

    PERF-CRITICAL: Innermost loop of AoS aggregation. The kind is dispatched
    once per batch (not per row); the per-row body lives in the kernel.
    """
    var _kind: UInt8
    var _agg_slot_offset: Int
    var _value_col_index: Int

    def __init__(
        out self,
        kind: UInt8,
        agg_slot_offset: Int,
        value_col_index: Int,
    ):
        self._kind = kind
        self._agg_slot_offset = agg_slot_offset
        self._value_col_index = value_col_index

    def call[
        ot: Origin[mut=True], oe: Origin, oc: Origin
    ](
        self,
        table: Span[UInt8, ot],
        entry_offsets: Span[Int, oe],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Execute the AoS commit kernel for `n` rows.

        Args:
            table: The entry table. The caller keeps it alive and unmoved.
            entry_offsets: Byte offset of each row's entry in `table`.
            col_data: The value column's data buffer, in bytes.
            col_offset: Element offset into the column data.
            n: Number of rows in this batch.
        """
        if self._kind == AOS_KERNEL_SUM_COUNT_F64:
            sum_count_f64_aos_thunk(
                table, entry_offsets, col_data, col_offset,
                self._agg_slot_offset, n,
            )
        elif self._kind == AOS_KERNEL_SUM_F64:
            sum_f64_aos_thunk(
                table, entry_offsets, col_data, col_offset,
                self._agg_slot_offset, n,
            )
        elif self._kind == AOS_KERNEL_COUNT_STAR:
            count_star_aos_thunk(
                table, entry_offsets, col_data, col_offset,
                self._agg_slot_offset, n,
            )
        else:
            raise Error("AosAccKernel.call: unknown kernel kind")


@always_inline
def _check_aos_batch(
    name: StringLiteral,
    n: Int,
    n_offsets: Int,
    col_bytes: Int,
    col_offset: Int,
    elem_bytes: Int,
) raises:
    """Per-batch bounds the per-row loop then relies on (checked once)."""
    if n < 0 or n > n_offsets:
        raise Error(String(name) + ": n exceeds the entry_offsets span")
    if elem_bytes > 0 and (col_offset < 0 or (col_offset + n) * elem_bytes > col_bytes):
        raise Error(String(name) + ": value column span is shorter than col_offset + n")


# PERF-CRITICAL kernel: ACC_SUM_COUNT_F64 16B AoS slot.
# Writes two fields per row: [sum:f64 @+0][count:i64 @+8].
# Supersedes the quartet 32B path's four stores (sum/count/min/max) when
# the planner selects `AggLayout.sum_count_f64(n)`.
def sum_count_f64_aos_thunk[
    ot: Origin[mut=True], oe: Origin, oc: Origin
](
    table: Span[UInt8, ot],
    entry_offsets: Span[Int, oe],
    col_data: Span[UInt8, oc],
    col_offset: Int,
    agg_slot_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel for ACC_SUM_COUNT_F64 AoS slots.

    PERF-CRITICAL: Inner loop writes 2 stores/row (sum + count) instead of
    the 4 stores/row of the 32B quartet. Also halves HT footprint
    (16B/slot vs 32B/slot) so the table fits in L2 at 2x more groups.
    """
    _check_aos_batch(
        "sum_count_f64_aos_thunk", n, len(entry_offsets),
        len(col_data), col_offset, 8,
    )
    # SAFETY: the pointers below are views of the three spans, which the
    # caller keeps borrowed for the whole call (their origins are tracked on
    # the parameters). `entry_offsets[row]` plus `agg_slot_offset` plus the 16
    # slot bytes must lie inside `table` -- the caller's find_or_create loop
    # produced the offsets from that table, and the per-batch check above
    # covers the other two spans. The entry table is 8-byte aligned.
    var base = table.unsafe_ptr()
    var offs = entry_offsets.unsafe_ptr()
    var col_f64 = col_data.unsafe_ptr().bitcast[Float64]() + col_offset

    # PERF-CRITICAL: Hot loop. Each iteration:
    #   1. Load the row's entry offset.
    #   2. Load Float64 value from column.
    #   3. Write sum += value at (entry + agg_slot_offset + 0).
    #   4. Write count += 1 at (entry + agg_slot_offset + 8).
    for row in range(n):
        var slot = base + (offs[row] + agg_slot_offset)
        var sum_p = slot.bitcast[Float64]()
        var count_p = (slot + 8).bitcast[Int64]()
        sum_p[] = sum_p[] + (col_f64 + row)[]
        count_p[] = count_p[] + Int64(1)


# PERF-CRITICAL kernel: ACC_SUM_F64 8B AoS slot.
# Writes one field per row: [sum:f64 @+0].
# Used by Q18 (SUM-only shape) when the planner selects a layout that
# includes ACC_SUM_F64 slots.
def sum_f64_aos_thunk[
    ot: Origin[mut=True], oe: Origin, oc: Origin
](
    table: Span[UInt8, ot],
    entry_offsets: Span[Int, oe],
    col_data: Span[UInt8, oc],
    col_offset: Int,
    agg_slot_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel for ACC_SUM_F64 AoS slots.

    PERF-CRITICAL: Inner loop is a single f64 accumulate (1 store/row).
    Half the memory footprint of ACC_SUM_COUNT_F64 (8B vs 16B).
    """
    _check_aos_batch(
        "sum_f64_aos_thunk", n, len(entry_offsets),
        len(col_data), col_offset, 8,
    )
    # SAFETY: as sum_count_f64_aos_thunk, with an 8-byte slot.
    var base = table.unsafe_ptr()
    var offs = entry_offsets.unsafe_ptr()
    var col_f64 = col_data.unsafe_ptr().bitcast[Float64]() + col_offset

    for row in range(n):
        var sum_p = (base + (offs[row] + agg_slot_offset)).bitcast[Float64]()
        sum_p[] = sum_p[] + (col_f64 + row)[]


# PERF-CRITICAL kernel: ACC_COUNT_STAR 8B AoS slot.
# Writes one field per row: [count:i64 @+0]. Ignores the value column --
# COUNT(*) counts rows regardless of null-ness.
# Used by CB-02 / CB-03 (COUNT(*) shape) when the planner selects a layout
# that includes ACC_COUNT_STAR slots. The value column span may be empty (the
# kernel never reads it).
def count_star_aos_thunk[
    ot: Origin[mut=True], oe: Origin, oc: Origin
](
    table: Span[UInt8, ot],
    entry_offsets: Span[Int, oe],
    col_data: Span[UInt8, oc],
    col_offset: Int,
    agg_slot_offset: Int,
    n: Int,
) raises -> None:
    """Monomorphic kernel for ACC_COUNT_STAR AoS slots.

    PERF-CRITICAL: Inner loop bumps count++ -- no column read. Used by
    COUNT(*) shapes (CB-02/CB-03). `col_data` / `col_offset` are unused but
    kept in the signature so every kernel shares the AosAccKernel dispatch.
    """
    _ = col_data  # intentionally unused -- COUNT(*) ignores value column
    _ = col_offset
    _check_aos_batch(
        "count_star_aos_thunk", n, len(entry_offsets), 0, 0, 0,
    )
    # SAFETY: as sum_count_f64_aos_thunk, with an 8-byte slot and no column.
    var base = table.unsafe_ptr()
    var offs = entry_offsets.unsafe_ptr()
    for row in range(n):
        var count_p = (base + (offs[row] + agg_slot_offset)).bitcast[Int64]()
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
# Row-thunk entry: a borrowed byte span, not an address.
# -----------------------------------------------------------------------------
#
# PERF-CRITICAL / SAFETY (audit §4 Fix B for gap7):
#
# The public face of a row thunk, `AosRowThunk.call`, takes the entry as a
# mutable `Span[UInt8]` over the entry's bytes. The first version took an
# `Int` and rebuilt the pointer from it, which "severs lifetime tracking
# entirely" (the internal development notes Mojo Pointer Rules); the second
# took an untracked-origin pointer in a public signature, which is the same
# hole one step removed. A span carries its origin, so the compiler anchors
# the thunk's write to the aggregator's `_entries` buffer, closing the UAF
# hazard that narrow-layout enabled at high HT-resize cadence.
#
# The fn-ptr beneath still takes an untracked-origin pointer, because Mojo
# cannot parameterize fn-ptr signatures over a caller-chosen origin. That
# fn-ptr type, the `_row_*` functions of that type, and the `_fn` field are
# all private to this file; `call` forms the pointer from the span inside its
# own body and nothing public names it.


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

from komira_op_agg_state.aggregators_builtin import (
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
def _row_sum_count_min_max_f64(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for the 32B quartet slot.

    Phase G-pre: kernel math delegated to Aggregator trait impls
    (SumF64 / MinF64 / MaxF64). After @always_inline propagation, the
    machine code is byte-identical to the pre-retrofit thunk.
    """
    # SAFETY: `entry_ptr` is the pointer of the entry span AosRowThunk.call
    # was given; the slot at `agg_slot_offset` (32 bytes) lies inside that entry,
    # a layout contract the AggCommitPlan that resolved this thunk upholds.
    # The pointer is used within this call only.
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
def _row_sum_count_f64(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for the 16B sum+count slot.

    Phase G-pre: kernel math for SUM delegated to SumF64.update; COUNT
    remains inline (Int64-slot vs UInt64-State type bridging deferred).
    """
    # SAFETY: `entry_ptr` is the pointer of the entry span AosRowThunk.call
    # was given; the slot at `agg_slot_offset` (16 bytes) lies inside that entry,
    # a layout contract the AggCommitPlan that resolved this thunk upholds.
    # The pointer is used within this call only.
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
def _row_sum_f64(
    entry_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    agg_slot_offset: Int,
    value: Float64,
) -> None:
    """Monomorphic row thunk for the 8B sum-only slot.

    Phase G-pre: SumF64.update — the canonical 1:1 trait retrofit shape.
    """
    # SAFETY: `entry_ptr` is the pointer of the entry span AosRowThunk.call
    # was given; the slot at `agg_slot_offset` (8 bytes) lies inside that entry,
    # a layout contract the AggCommitPlan that resolved this thunk upholds.
    # The pointer is used within this call only.
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
def _row_count_star(
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
    # SAFETY: `entry_ptr` is the pointer of the entry span AosRowThunk.call
    # was given; the slot at `agg_slot_offset` (8 bytes) lies inside that entry,
    # a layout contract the AggCommitPlan that resolved this thunk upholds.
    # The pointer is used within this call only.
    var count_p = (entry_ptr + agg_slot_offset).bitcast[Int64]()
    # COUNT-EQUIV: CountStar.update on Int64 slot.
    count_p[] = count_p[] + Int64(1)


# The row thunk's fn-ptr type. Every `_row_*` function above matches it.
# PRIVATE: it names the untracked-origin pointer the fn-ptr boundary needs
# (see the note above); `AosRowThunk` is the public handle.
comptime _RowFn = def(
    UnsafePointer[UInt8, MutUntrackedOrigin], Int, Float64
) thin -> None


struct AosRowThunk(ImplicitlyCopyable, Movable):
    """A pre-resolved per-slot row kernel (see `resolve_row_thunk`).

    Stored inline inside AggCommitPlan's per-bucket
    InlineArray[AosRowThunk, MAX_AGGS] fields (see agg_commit.mojo). The
    handle is one fn-ptr wide, so it costs what the bare fn-ptr did.
    """
    var _fn: _RowFn

    def __init__(out self, tag: UInt8):
        """Resolve `tag` to its monomorphic row kernel (plan time).

        Keep in lockstep with AccTag additions in agg_layout.mojo.
        """
        from komira_core.agg_layout import (
            ACC_SUM_COUNT_MIN_MAX_F64,
            ACC_SUM_COUNT_F64,
            ACC_SUM_F64,
            ACC_COUNT_STAR,
            ACC_COUNT_NONNULL,
        )
        if tag == ACC_SUM_COUNT_MIN_MAX_F64:
            self._fn = _row_sum_count_min_max_f64
        elif tag == ACC_SUM_COUNT_F64:
            self._fn = _row_sum_count_f64
        elif tag == ACC_SUM_F64:
            self._fn = _row_sum_f64
        elif tag == ACC_COUNT_STAR:
            self._fn = _row_count_star
        elif tag == ACC_COUNT_NONNULL:
            self._fn = _row_count_star
        else:
            # Fallback: treat unknown tags as quartet (safe default that
            # preserves the pre-port byte-identical behavior).
            self._fn = _row_sum_count_min_max_f64

    @always_inline
    def call[
        o: Origin[mut=True]
    ](self, entry: Span[UInt8, o], agg_slot_offset: Int, value: Float64):
        """Apply `value` to the slot at `agg_slot_offset` inside `entry`.

        `entry` spans the row's entry bytes; the slot (up to 32 bytes, per
        the kernel's tag) must lie inside it. `value` is ignored by the
        count-only kernel -- the caller passes 0.0 by convention.
        """
        # SAFETY: the pointer is the span's own, valid while the caller
        # keeps `entry` borrowed (it is borrowed for this call). The
        # untracked origin exists only because the fn-ptr signature cannot
        # name `o`; the kernel does not stash the pointer.
        self._fn(
            entry.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            agg_slot_offset,
            value,
        )


def resolve_row_thunk(tag: UInt8) -> AosRowThunk:
    """Plan-time dispatch: map an AccTag to its monomorphic row thunk.

    Called once per agg slot during AggCommitPlan construction. Never
    called from a hot path.
    """
    return AosRowThunk(tag)
