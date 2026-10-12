# =============================================================================
# hash_fn_op.mojo — HashFnOp[F: HashFn] / StringHashFnOp[F: StringHashFn]:
#                   comptime-monomorphized MorselOperatorImpl adapters for
#                   hash kernels (EXECUTOR-KERNEL-COMPTIME Phase 1.c)
# =============================================================================
#
# EXECUTOR-KERNEL-COMPTIME Phase 1.c (synthesis memo
# an internal agent note).
# Mirrors `BinaryFnOp[F: BinaryFn]` / `MatchFnOp[F: MatchFn]` but for hash
# kernels: ONE named input column, kernel produces a `PrimitiveArray[UInt64]`
# of per-row hashes, operator APPENDS the hash column to the batch (the
# downstream hash-join probe / hash-agg key-hash consumer reads from a
# fixed-name output column).
#
# Semantics
# ---------
# 1:1 operator (row count unchanged). Always returns NEED_MORE_INPUT. The
# output column is appended to the input batch (new col at index
# num_columns); the input columns pass through unchanged. The output
# column is non-nullable (hashes are never null — null inputs hash to
# NULL_HASH sentinel; the downstream consumer discriminates by the
# sentinel value, not by validity bitmap).
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any public signature.
# - No wildcard origins anywhere on the struct.
# - Field `_f: F` by value (`Copyable` via HashFn / StringHashFn).
# - File < 1000 LOC.
# - The in-place `morsel.batch` swap mirrors `BinaryFnOp.execute`
#   (canonical MapOp pattern, with a `# SAFETY:` comment).
# =============================================================================

from std.memory import OwnedPointer
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_column_kernels.compiler_helpers import copy_column
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_kernels.hash_fn import HashFn, StringHashFn
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    new_owned_metrics_set,
)


# =============================================================================
# HashFnOp[F: HashFn] — fixed-width primitive hash operator
# =============================================================================


struct HashFnOp[F: HashFn](MorselOperatorImpl):
    """MorselOperatorImpl adapter for a typed `HashFn` conformer `F`.

    Fields
    ------
    _f               : the user's `HashFn` instance (Copyable per HashFn).
    _input_col_name  : the input column name to hash.
    _out_col_name    : the output column name appended to the batch
                       (UInt64 hashes).
    _metrics         : per-instance MetricsSet (rows_processed,
                       elapsed_compute, valid_count).

    Semantics
    ---------
    1:1 operator (always NEED_MORE_INPUT). Output column appended.
    Output is non-nullable UInt64 (nulls hash to NULL_HASH).
    """

    var _f: Self.F
    var _input_col_name: String
    var _out_col_name: String
    var _metrics: OwnedPointer[MetricsSet]

    def __init__(
        out self,
        var f: Self.F,
        var input_col_name: String,
        var out_col_name: String,
    ) raises:
        """Construct a `HashFnOp` wrapping the given `HashFn` kernel."""
        self._f = f^
        self._input_col_name = input_col_name^
        self._out_col_name = out_col_name^
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_counter["valid_count"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^

    def metrics_snapshot(self) -> MetricsSnapshot:
        return self._metrics[].reduce()

    # -------------------------------------------------------------------------
    # Hash output construction.
    #
    # Resolve the input column by NAME, validate arrow type matches kernel
    # T, allocate the output UInt64 array, dispatch the non-raising kernel.
    # -------------------------------------------------------------------------

    def _compute_hash(
        mut self, batch: RecordBatch, mut out: PrimitiveArray[DType.uint64]
    ) raises -> Int:
        """Resolve input, dispatch the kernel into caller-allocated `out`.
        Returns the count of non-null cells processed."""
        var idx = batch.column_by_name(self._input_col_name)

        var at = batch.column_arrow_type(idx)
        var want = ArrowType.from_dtype(Self.F.T)
        if at != want:
            raise Error(
                "HashFnOp: column '"
                + self._input_col_name
                + "' arrow type "
                + String(at)
                + " does not match kernel T = "
                + String(want)
            )

        ref col = batch.column_at(idx)
        var n = col.length()
        var arr = col.as_primitive[Self.F.T]()

        # Hot path — non-raising kernel call.
        var valid_count = self._f.hash_chunk(arr, out, n)
        return valid_count

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Compute the hash column, append it to morsel.batch, swap in-place.

        Always returns NEED_MORE_INPUT (1:1 operator)."""
        var _t0 = perf_counter_ns()
        var _rows_in = morsel.num_rows()

        var n = morsel.num_rows()
        var out = PrimitiveArray[DType.uint64].allocate(n)
        var valid_count = self._compute_hash(morsel.batch, out)

        # Build new batch: all input columns + appended hash column.
        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()
        var nin = morsel.batch.num_columns()
        for i in range(nin):
            # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: preserve metadata.
            sb.add_field(morsel.batch.schema.field_at(i))
            var c = copy_column(morsel.batch, i)
            builder.add_column(c^)
        sb.add_field(
            Field(self._out_col_name, ArrowType.from_dtype(DType.uint64), False)
        )
        builder.add_column(Column.from_primitive[DType.uint64](out^))
        var schema = sb.build()
        var new_batch = builder.build(schema^)

        # Replace the batch; the old one is dropped.
        morsel.replace_batch(new_batch^)

        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(_rows_in), worker_id=0
        )
        self._metrics[].counter["valid_count"]().inc_in_pipeline(
            Int64(valid_count), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - _t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)


# =============================================================================
# StringHashFnOp[F: StringHashFn] — variable-length string hash operator
# =============================================================================


struct StringHashFnOp[F: StringHashFn](MorselOperatorImpl):
    """MorselOperatorImpl adapter for a typed `StringHashFn` conformer `F`."""

    var _f: Self.F
    var _input_col_name: String
    var _out_col_name: String
    var _metrics: OwnedPointer[MetricsSet]

    def __init__(
        out self,
        var f: Self.F,
        var input_col_name: String,
        var out_col_name: String,
    ) raises:
        self._f = f^
        self._input_col_name = input_col_name^
        self._out_col_name = out_col_name^
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_counter["valid_count"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^

    def metrics_snapshot(self) -> MetricsSnapshot:
        return self._metrics[].reduce()

    def _compute_hash(
        mut self, batch: RecordBatch, mut out: PrimitiveArray[DType.uint64]
    ) raises -> Int:
        var idx = batch.column_by_name(self._input_col_name)

        var at = batch.column_arrow_type(idx)
        var want = ArrowType.STRING
        if at != want:
            raise Error(
                "StringHashFnOp: column '"
                + self._input_col_name
                + "' arrow type "
                + String(at)
                + " is not STRING (kernel handles UTF-8 strings)"
            )

        ref col = batch.column_at(idx)
        var n = col.length()
        var arr = col.as_string()
        var valid_count = self._f.hash_chunk(arr, out, n)
        return valid_count

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        var _t0 = perf_counter_ns()
        var _rows_in = morsel.num_rows()

        var n = morsel.num_rows()
        var out = PrimitiveArray[DType.uint64].allocate(n)
        var valid_count = self._compute_hash(morsel.batch, out)

        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()
        var nin = morsel.batch.num_columns()
        for i in range(nin):
            # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: preserve metadata.
            sb.add_field(morsel.batch.schema.field_at(i))
            var c = copy_column(morsel.batch, i)
            builder.add_column(c^)
        sb.add_field(
            Field(self._out_col_name, ArrowType.from_dtype(DType.uint64), False)
        )
        builder.add_column(Column.from_primitive[DType.uint64](out^))
        var schema = sb.build()
        var new_batch = builder.build(schema^)

        # Replace the batch; the old one is dropped.
        morsel.replace_batch(new_batch^)

        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(_rows_in), worker_id=0
        )
        self._metrics[].counter["valid_count"]().inc_in_pipeline(
            Int64(valid_count), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - _t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)
