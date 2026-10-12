# =============================================================================
# match_fn_op.mojo — MatchFnOp[F: MatchFn] / UnaryMatchFnOp[F: UnaryMatchFn]:
#                     comptime-monomorphized MorselOperatorImpl adapters for
#                     binary / unary predicate kernels
#                     (EXECUTOR-KERNEL-COMPTIME Phase 1.b)
# =============================================================================
#
# EXECUTOR-KERNEL-COMPTIME Phase 1.b (synthesis memo
# an internal agent note).
# Mirrors `BinaryFnOp[F: BinaryFn]` (`komira_operator_api/binary_fn_op.mojo`)
# but for predicate kernels: two named input columns (or one for the unary case),
# kernel produces a `Bitmap` of matched rows, operator narrows the morsel batch
# via `filter_to_indices` + `gather_batch`.
#
# Naming: this is the kernel-level filter operator (column-vs-column comparison).
# Distinguish from `FilterFnOp[F: FilterFn]` in `filter_fn_op.mojo`, which is the
# UDF-userspace filter (row-shaped, het-pack input arity 1..4).
#
# `NO_MATCH_SEL` handling
# -----------------------
# The kernel always produces a `Bitmap` (packed 1 bit per row). When the
# kernel's `NO_MATCH_SEL == True`, the operator additionally materializes
# the selection vector of NON-matching rows (P2-reserved, today reflected
# in test (f) — verifies that `filter_to_indices(bitmap)` is consistent
# with the equivalent sel-vector). The operator's user-facing semantics
# (narrow the batch to matched rows + return `NEED_MORE_INPUT`) are
# identical across both modes; only the metric "non_match_count" differs.
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any public signature.
# - No wildcard origins anywhere on the struct.
# - Field `_f: F` by value (`Copyable` via MatchFn).
# - File < 1000 LOC.
# - The in-place `morsel.batch` swap mirrors `BinaryFnOp.execute`
#   (canonical MapOp pattern, with a `# SAFETY:` comment).
# =============================================================================

from std.memory import OwnedPointer
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_column_kernels.comparison import filter_to_indices
from komira_column_kernels.compiler_helpers import gather_batch
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_kernels.match_fn import MatchFn, UnaryMatchFn
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    new_owned_metrics_set,
)


# =============================================================================
# MatchFnOp[F: MatchFn] — binary-comparison filter operator
# =============================================================================


struct MatchFnOp[F: MatchFn](MorselOperatorImpl):
    """MorselOperatorImpl adapter for a typed `MatchFn` conformer `F`.

    Fields
    ------
    _f               : the user's `MatchFn` instance (Copyable per MatchFn).
    _lhs_col_name    : the LEFT input column name.
    _rhs_col_name    : the RIGHT input column name.
    _metrics         : per-instance MetricsSet (rows_processed, elapsed_compute,
                       match_count).

    Semantics
    ---------
    ≤1:1 filter operator. Always returns NEED_MORE_INPUT. The morsel batch
    is narrowed in-place to matched rows. Null propagation is comptime-
    chosen at kernel monomorphization time via `F.LHS_VALID` / `F.RHS_VALID`.
    """

    var _f: Self.F
    var _lhs_col_name: String
    var _rhs_col_name: String
    var _metrics: OwnedPointer[MetricsSet]

    def __init__(
        out self,
        var f: Self.F,
        var lhs_col_name: String,
        var rhs_col_name: String,
    ) raises:
        """Construct a `MatchFnOp` wrapping the given `MatchFn` kernel."""
        self._f = f^
        self._lhs_col_name = lhs_col_name^
        self._rhs_col_name = rhs_col_name^
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_counter["match_count"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^

    def metrics_snapshot(self) -> MetricsSnapshot:
        return self._metrics[].reduce()

    # -------------------------------------------------------------------------
    # Mask construction.
    #
    # Resolve the two input columns by NAME, validate their arrow types match
    # the kernel's T, allocate the output bitmap, dispatch the kernel.
    # -------------------------------------------------------------------------

    def _build_mask(
        mut self, batch: RecordBatch, mut out_mask: Bitmap[HeapRegion]
    ) raises -> Int:
        """Resolve inputs, validate types, dispatch the non-raising kernel.
        Writes into the caller-allocated `out_mask` and returns match_count.
        """
        var lhs_idx = batch.column_by_name(self._lhs_col_name)
        var rhs_idx = batch.column_by_name(self._rhs_col_name)

        var lhs_at = batch.column_arrow_type(lhs_idx)
        var rhs_at = batch.column_arrow_type(rhs_idx)
        var want = ArrowType.from_dtype(Self.F.T)
        if lhs_at != want:
            raise Error(
                "MatchFnOp: lhs column '"
                + self._lhs_col_name
                + "' arrow type "
                + String(lhs_at)
                + " does not match kernel T = "
                + String(want)
            )
        if rhs_at != want:
            raise Error(
                "MatchFnOp: rhs column '"
                + self._rhs_col_name
                + "' arrow type "
                + String(rhs_at)
                + " does not match kernel T = "
                + String(want)
            )

        ref lhs_col = batch.column_at(lhs_idx)
        ref rhs_col = batch.column_at(rhs_idx)
        if lhs_col.length() != rhs_col.length():
            raise Error("MatchFnOp: lhs / rhs column length mismatch")

        var lhs_arr = lhs_col.as_primitive[Self.F.T]()
        var rhs_arr = rhs_col.as_primitive[Self.F.T]()

        # Hot path — non-raising kernel call. Writes data bits and returns count.
        var match_count = self._f.eval_chunk(lhs_arr, rhs_arr, out_mask)
        return match_count

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Evaluate the predicate kernel over `morsel.batch`'s two named input
        columns, build a selection mask, narrow the batch via gather, and
        swap into `morsel.batch`. Map-like ≤1:1 — always returns NEED_MORE_INPUT."""
        var _t0 = perf_counter_ns()
        var _rows_in = morsel.num_rows()

        var n = morsel.num_rows()
        var mask = Bitmap.create(n)
        var match_count = self._build_mask(morsel.batch, mask)
        var bool_arr = BooleanArray.from_bitmap(mask^)
        var indices = filter_to_indices(bool_arr)
        var new_batch = gather_batch(morsel.batch, indices)

        # Replace the batch; the old one is dropped.
        morsel.replace_batch(new_batch^)

        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(_rows_in), worker_id=0
        )
        self._metrics[].counter["match_count"]().inc_in_pipeline(
            Int64(match_count), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - _t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)


# =============================================================================
# UnaryMatchFnOp[F: UnaryMatchFn] — IS_NULL / IS_NOT_NULL filter operator
# =============================================================================


struct UnaryMatchFnOp[F: UnaryMatchFn](MorselOperatorImpl):
    """MorselOperatorImpl adapter for a typed `UnaryMatchFn` conformer `F`."""

    var _f: Self.F
    var _input_col_name: String
    var _metrics: OwnedPointer[MetricsSet]

    def __init__(
        out self,
        var f: Self.F,
        var input_col_name: String,
    ) raises:
        """Construct a `UnaryMatchFnOp`."""
        self._f = f^
        self._input_col_name = input_col_name^
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_counter["match_count"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^

    def metrics_snapshot(self) -> MetricsSnapshot:
        return self._metrics[].reduce()

    def _build_mask(
        mut self, batch: RecordBatch, mut out_mask: Bitmap[HeapRegion]
    ) raises -> Int:
        """Resolve input, validate type, dispatch the unary kernel. Writes
        into the caller-allocated `out_mask`; returns match_count."""
        var idx = batch.column_by_name(self._input_col_name)
        var at = batch.column_arrow_type(idx)
        var want = ArrowType.from_dtype(Self.F.T)
        if at != want:
            raise Error(
                "UnaryMatchFnOp: column '"
                + self._input_col_name
                + "' arrow type "
                + String(at)
                + " does not match kernel T = "
                + String(want)
            )
        ref col = batch.column_at(idx)
        var arr = col.as_primitive[Self.F.T]()
        var match_count = self._f.eval_chunk(arr, out_mask)
        return match_count

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        var _t0 = perf_counter_ns()
        var _rows_in = morsel.num_rows()

        var n = morsel.num_rows()
        var mask = Bitmap.create(n)
        var match_count = self._build_mask(morsel.batch, mask)
        var bool_arr = BooleanArray.from_bitmap(mask^)
        var indices = filter_to_indices(bool_arr)
        var new_batch = gather_batch(morsel.batch, indices)

        # Replace the batch; the old one is dropped.
        morsel.replace_batch(new_batch^)

        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(_rows_in), worker_id=0
        )
        self._metrics[].counter["match_count"]().inc_in_pipeline(
            Int64(match_count), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - _t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)
