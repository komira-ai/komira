# =============================================================================
# RecordBatch scalar extraction — the host-language boundary for scalar subqueries
# =============================================================================
#
# Free-function form of `RecordBatch.scalar()` / `.scalar_list()`. It lives
# outside `komira_arrow` because `ScalarValue` lives in `komira_plan_expr`, and
# `arrow → plan` would introduce a cycle (plan already imports from arrow). The
# function form is the Mojo-native equivalent of an extension method:
#
#   var s = scalar(batch)             # 1×1 batch → ScalarValue
#   var xs = scalar_list(batch)       # N×1 batch → List[ScalarValue]
#
# Usage (Q11 / Q22 shapes — a host-language let-binding: materialize the
# inner query, extract its value, feed it back to the outer query as a literal):
#
#   var threshold_value = scalar(inner_batch)
#   var threshold = Expr.literal(threshold_value)
#   # ... the outer query filters on `col > threshold` and is materialized
#
# Empty-input semantics — matches DuckDB / SQL standard:
#   scalar()       on 0×1 → ScalarValue.null(dtype)
#   scalar_list()  on 0×1 → empty List[ScalarValue]
#
# Multi-shape errors raise:
#   scalar()       on N>1 × 1 → "scalar: expected 1 row, got N"
#   scalar()       on 1 × M>1 → "scalar: expected 1 column, got M"
#   scalar_list()  on _ × M≠1 → "scalar_list: expected 1 column, got M"
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_plan_expr.scalar_value import ScalarValue
from komira_arrow.dtype_sentinel import DTYPE_NONE


def _extract_one(batch: RecordBatch, row: Int) raises -> ScalarValue:
    """Read a single typed scalar from `batch.column_at(0)` row `row`.

    Dispatches on the column's `arrow_type`. The returned `ScalarValue`
    is self-contained — for STRING it owns its String copy; numerics
    are by value.

    NULL handling: if the row is null, returns a typed NULL via
    `ScalarValue.null(dtype)` matching the column's logical dtype.
    """
    var atype = batch.column_arrow_type(0)

    # NULL fast path — typed null preserves dtype for downstream Expr.literal.
    if atype == ArrowType.INT64:
        var arr = batch.column_as_primitive_int64(0)
        if arr.is_null(row):
            return ScalarValue.null(DType.int64)
        return ScalarValue.from_int64(arr.get(row))
    elif atype == ArrowType.INT32:
        var arr = batch.column_as_primitive_int32(0)
        if arr.is_null(row):
            return ScalarValue.null(DType.int32)
        return ScalarValue.from_int32(arr.get(row))
    elif atype == ArrowType.FLOAT64:
        var arr = batch.column_as_primitive_float64(0)
        if arr.is_null(row):
            return ScalarValue.null(DType.float64)
        return ScalarValue.from_float(arr.get(row))
    elif atype == ArrowType.STRING:
        var arr = batch.column_as_string(0)
        # StringArray.is_null is unrise-able (no raises annotation).
        if arr.is_null(row):
            return ScalarValue.null(DTYPE_NONE)
        return ScalarValue.from_string(arr.get(row))
    elif atype == ArrowType.BOOL:
        var arr = batch.column_at(0).as_boolean()
        if arr.is_null(row):
            return ScalarValue.null(DType.bool)
        return ScalarValue.from_bool(arr.get(row))
    elif atype == ArrowType.DATE32:
        # DATE32 is stored as Int32 days since epoch; treat as Int64
        # for the ScalarValue boundary (Expr.literal layer is dtype-aware).
        var arr = batch.column_as_primitive_int32(0)
        if arr.is_null(row):
            return ScalarValue.null(DType.int32)
        return ScalarValue.from_int32(arr.get(row))
    else:
        raise Error(
            "scalar: unsupported arrow_type " + String(atype)
            + " for column 0; supported: INT64/INT32/FLOAT64/STRING/BOOL/DATE32"
        )


def scalar(batch: RecordBatch) raises -> ScalarValue:
    """Extract a single scalar value from a 1-row 1-column RecordBatch.

    The entry point for scalar subqueries bound in the host language
    (Q11, Q22). The user materializes the inner pipeline, then calls
    `scalar(batch)` to extract the scalar. The returned
    `ScalarValue` is self-contained — the caller can drop the batch
    immediately after extraction.

    Args:
        batch: A materialized RecordBatch. Must have exactly 1 row and
               1 column. Empty (0×1) batches are accepted and return a
               typed NULL — matches SQL `(SELECT max(x) FROM empty)`
               semantics.

    Returns:
        A ScalarValue carrying the extracted value (numerics by value;
        STRING via owned String). For 0×1 inputs, returns
        `ScalarValue.null(dtype)`.

    Raises:
        Error("scalar: expected 1 column, got M") when n_cols != 1.
        Error("scalar: expected 1 row, got N") when n_rows > 1.
        Error("scalar: unsupported arrow_type ...") for unsupported dtypes.

    Examples:
        ```mojo
        from komira_dispatch_scan.record_batch_extract import scalar
        from komira_plan_expr.expr import Expr
        # materialize a 1x1 aggregate, extract it, feed it back as a literal
        var threshold_batch = ctx.materialize(inner^)   # 1 row, 1 column
        var sv = scalar(threshold_batch^)
        var kept = ctx.materialize(outer^.filter(Expr.col_ref("v") > Expr.literal(sv))^)
        ```
    """
    var n_cols = batch.num_columns()
    if n_cols != 1:
        raise Error(
            "scalar: expected 1 column, got " + String(n_cols)
        )
    var n_rows = batch.num_rows()
    if n_rows > 1:
        raise Error("scalar: expected 1 row, got " + String(n_rows))
    if n_rows == 0:
        # Empty: return typed NULL based on the schema dtype.
        var atype = batch.column_arrow_type(0)
        if atype == ArrowType.INT64:
            return ScalarValue.null(DType.int64)
        elif atype == ArrowType.INT32 or atype == ArrowType.DATE32:
            return ScalarValue.null(DType.int32)
        elif atype == ArrowType.FLOAT64:
            return ScalarValue.null(DType.float64)
        elif atype == ArrowType.BOOL:
            return ScalarValue.null(DType.bool)
        else:
            return ScalarValue.null(DTYPE_NONE)
    return _extract_one(batch, 0)


def scalar_list(batch: RecordBatch) raises -> List[ScalarValue]:
    """Extract a column of typed scalars from a 1-column RecordBatch.

    The IN-subquery sibling of `scalar`. The user materializes the inner
    pipeline, then calls `scalar_list(batch)` to
    bind the column as a typed `List[ScalarValue]`. The list is
    self-contained — the caller can drop the batch after extraction.

    Args:
        batch: A materialized 1-column RecordBatch with N rows
               (N >= 0). Each row contributes one ScalarValue.

    Returns:
        A List[ScalarValue] with one entry per row, in row order. For
        0-row batches, returns an empty list — callers building
        `Expr.in_list(col, empty)` should fold to `Expr.literal(False)`
        (matches SQL `IN (empty)` → FALSE).

    Raises:
        Error("scalar_list: expected 1 column, got M") when n_cols != 1.
        Error("scalar_list: unsupported arrow_type ...") for
        unsupported dtypes.

    Examples:
        ```mojo
        from komira_dispatch_scan.record_batch_extract import scalar_list
        # bind a 1-column result as a typed List[ScalarValue] (IN-subquery keys)
        var keys_batch = ctx.materialize(inner^)   # N rows, 1 column
        var keys = scalar_list(keys_batch^)
        ```
    """
    var n_cols = batch.num_columns()
    if n_cols != 1:
        raise Error(
            "scalar_list: expected 1 column, got " + String(n_cols)
        )
    var n_rows = batch.num_rows()
    var out = List[ScalarValue]()
    if n_rows > 0:
        out.reserve(n_rows)
    for i in range(n_rows):
        out.append(_extract_one(batch, i))
    return out^
