# =============================================================================
# binary_fn_op.mojo — BinaryFnOp[F: BinaryFn]: the comptime-monomorphized
#                     MorselOperatorImpl adapter for binary arithmetic kernels
#                     (EXECUTOR-KERNEL-COMPTIME Phase 1.a)
# =============================================================================
#
# EXECUTOR-KERNEL-COMPTIME Phase 1.a (synthesis memo
# an internal agent note).
# Mirrors `MapFnOp[F: MapFn]` (`map_fn_op.mojo`, outside this package)
# but for the BINARY arithmetic kernel layer: two named input columns,
# one new appended output column, the kernel monomorphized at the
# operator's comptime via `F: BinaryFn`.
#
# Differences from `MapFnOp`
# --------------------------
# - `MapFnOp[F]` takes N input columns (variadic arity 1..4) and one
#   output. `BinaryFnOp[F]` takes EXACTLY two input columns.
# - The kernel `F.eval_chunk` is non-raising (Phase 1.a's Option 1
#   constraint per the synthesis memo). The operator wraps the kernel
#   call in raising context (`execute` is still `def`, matching the
#   existing trait surface — Option 2 / non-raising operator-trait is
#   Phase 1.f-impl scope).
# - The output column NAME is supplied at operator-init (e.g.
#   "lineitem_total"), not derived from a `OutputSchema` (BinaryFn
#   doesn't carry one — it's pure-arithmetic on physical types).
# - Null handling is PROPAGATE: out.validity = AND(lhs.validity,
#   rhs.validity). Computed once per chunk in the operator, BEFORE
#   handing `out` to the kernel.
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any public signature.
# - No wildcard origins anywhere on the struct.
# - Field `f: F` by value (`Copyable` via BinaryFn).
# - File < 1000 LOC.
# - The in-place `morsel.batch` swap mirrors `MapFnOp.execute`
#   (canonical MapOp pattern, with a `# SAFETY:` comment).
# =============================================================================

from std.memory import OwnedPointer
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_kernels.binary_fn import BinaryFn
from komira_column_kernels.compiler_helpers import copy_column
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    new_owned_metrics_set,
)


# =============================================================================
# BinaryFnOp[F]
# =============================================================================


struct BinaryFnOp[F: BinaryFn](MorselOperatorImpl):
    """MorselOperatorImpl adapter for a typed `BinaryFn` conformer `F`.

    Fields
    ------
    _f               : the user's `BinaryFn` instance (Copyable per BinaryFn).
    _lhs_col_name    : the LEFT input column name (resolved against
                       `morsel.batch.schema` at each call).
    _rhs_col_name    : the RIGHT input column name (resolved per call).
    _out_col_name    : the output column name appended to the batch.
    _metrics         : per-instance MetricsSet (Counter "rows_processed",
                       Time "elapsed_compute"); each per-worker op owns
                       its own (worker_id=0 disjoint by construction).

    Semantics
    ---------
    1:1 operator (row count unchanged). Always returns NEED_MORE_INPUT.
    Output column is APPENDED to the input batch (new col at index
    num_columns); the input columns pass through unchanged. Null
    propagation: a row is null iff lhs or rhs is null.
    """

    var _f: Self.F
    var _lhs_col_name: String
    var _rhs_col_name: String
    var _out_col_name: String
    var _metrics: OwnedPointer[MetricsSet]

    def __init__(
        out self,
        var f: Self.F,
        var lhs_col_name: String,
        var rhs_col_name: String,
        var out_col_name: String,
    ) raises:
        """Construct a `BinaryFnOp` wrapping the given `BinaryFn` kernel.

        Args
        ----
        f                : the user's `BinaryFn` instance. Ownership
                           transferred (the driver builds N copies, one
                           per worker).
        lhs_col_name     : name of the LEFT input column in the input
                           RecordBatch.
        rhs_col_name     : name of the RIGHT input column.
        out_col_name     : name for the appended output column.
        """
        self._f = f^
        self._lhs_col_name = lhs_col_name^
        self._rhs_col_name = rhs_col_name^
        self._out_col_name = out_col_name^
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^

    # __moveinit__ / __del__ synthesized by the compiler.

    def metrics_snapshot(self) -> MetricsSnapshot:
        return self._metrics[].reduce()

    # -------------------------------------------------------------------------
    # Output column construction.
    #
    # Resolve the two input columns by NAME, validate their arrow types
    # match the kernel's TA / TB, build the merged validity bitmap once,
    # allocate the output PrimitiveArray (nullable if either side is
    # nullable; non-nullable otherwise), call the non-raising kernel,
    # and wrap into a Column.
    # -------------------------------------------------------------------------

    def _compute_output(mut self, batch: RecordBatch) raises -> Column[HeapRegion]:
        """Resolve inputs, allocate output, dispatch the kernel, return a
        Column. Raises on type mismatch or missing column."""
        var lhs_idx = batch.column_by_name(self._lhs_col_name)
        var rhs_idx = batch.column_by_name(self._rhs_col_name)

        var lhs_at = batch.column_arrow_type(lhs_idx)
        var rhs_at = batch.column_arrow_type(rhs_idx)
        var want_lhs = ArrowType.from_dtype(Self.F.TA)
        var want_rhs = ArrowType.from_dtype(Self.F.TB)
        if lhs_at != want_lhs:
            raise Error(
                "BinaryFnOp: lhs column '"
                + self._lhs_col_name
                + "' arrow type "
                + String(lhs_at)
                + " does not match kernel TA = "
                + String(want_lhs)
            )
        if rhs_at != want_rhs:
            raise Error(
                "BinaryFnOp: rhs column '"
                + self._rhs_col_name
                + "' arrow type "
                + String(rhs_at)
                + " does not match kernel TB = "
                + String(want_rhs)
            )

        ref lhs_col = batch.column_at(lhs_idx)
        ref rhs_col = batch.column_at(rhs_idx)
        if lhs_col.length() != rhs_col.length():
            raise Error("BinaryFnOp: lhs / rhs column length mismatch")

        var n = lhs_col.length()
        var lhs_arr = lhs_col.as_primitive[Self.F.TA]()
        var rhs_arr = rhs_col.as_primitive[Self.F.TB]()

        # PROPAGATE: validity = lhs.validity AND rhs.validity.
        # Build the bitmap BEFORE allocating `out` so we can pick the
        # nullable / non-nullable shape per the result.
        var out: PrimitiveArray[Self.F.TR]
        var nulls = 0
        if Bool(lhs_arr.validity) or Bool(rhs_arr.validity):
            out = PrimitiveArray[Self.F.TR].allocate_nullable(n)
            # `allocate_nullable` starts all-valid; build the merged
            # validity from lhs + rhs and assign into out.validity.
            var bm = Bitmap.create_all_valid(n)
            for i in range(n):
                var ok = True
                if lhs_arr.validity:
                    if not lhs_arr.validity.value().test(i):
                        ok = False
                if ok and rhs_arr.validity:
                    if not rhs_arr.validity.value().test(i):
                        ok = False
                if not ok:
                    bm.clear(i)
                    nulls += 1
            out.validity = bm^
            out.null_count = nulls
        else:
            out = PrimitiveArray[Self.F.TR].allocate(n)

        # Hot path — non-raising kernel call. Writes data buffer only.
        self._f.eval_chunk(lhs_arr, rhs_arr, out)

        return Column.from_primitive[Self.F.TR](out^)

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Evaluate the binary kernel over `morsel.batch`'s two named
        input columns, append the resulting output column, and swap the
        new RecordBatch into `morsel.batch`. Map-like 1:1 — always
        returns NEED_MORE_INPUT."""
        var _t0 = perf_counter_ns()
        var _rows_in = morsel.num_rows()

        var out_col = self._compute_output(morsel.batch)

        # Build the new batch = all input columns + the kernel output column.
        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()
        var nin = morsel.batch.num_columns()
        for i in range(nin):
            # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: preserve metadata.
            sb.add_field(morsel.batch.schema.field_at(i))
            var c = copy_column(morsel.batch, i)
            builder.add_column(c^)
        # Computed binary-kernel output column — fresh Field.
        sb.add_field(Field(self._out_col_name, ArrowType.from_dtype(Self.F.TR), True))
        builder.add_column(out_col^)
        var schema = sb.build()
        var new_batch = builder.build(schema^)

        # Replace the batch; the old one is dropped.
        morsel.replace_batch(new_batch^)

        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(_rows_in), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - _t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)
