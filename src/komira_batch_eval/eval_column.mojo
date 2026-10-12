# =============================================================================
# eval_column: the projection evaluator (Expr -> Column)
# =============================================================================
#
# `_eval_column_expr` is the ladder over the `EXPR_*` tags. The small arms are
# inline; every large arm is a function in a `project_*` module, and the
# kernels the arms share are in `column_compare`, `column_arith`,
# `column_decimal`, `string_metrics` and `string_bytes`.
#
# `eval_column`, `eval_predicate` and `eval_case` call one another (a CASE arm
# projects, a predicate projects a computed operand, a projection of a
# predicate-shaped expression evaluates it as a predicate), so the modules of
# that cycle import each other; Mojo compiles the package as one unit.
#
# The Unicode simple case mapping the string arms use is
# `komira_column_kernels.unicode_case`, shared with every package that folds a
# literal, so a literal and a column are folded by the same mapping.
#
# The raw `eval_col_*` comparison kernels are deliberately not used here: the
# only column-vs-column comparison is `column_compare._col_cmp_nullable`, which
# honours validity.
# =============================================================================

from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import broadcast_scalar, copy_column, resolve_col_index
from komira_column_kernels.scalar_math import eval_math_binary, eval_math_unary
from komira_plan_expr.expr import (
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_REF,
    EXPR_EXTRACT,
    EXPR_IN_LIST,
    EXPR_JSON_EXTRACT,
    EXPR_LITERAL,
    EXPR_MAP_GET,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_REGEXP,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_STRING_OP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_SUBSTRING,
    EXPR_UDF_CALL,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    Expr,
)

from .column_compare import _column_to_float64
from .column_decimal import _reduce_agg_scalar
from .eval_case import _eval_when_expr
from .eval_in_list import _eval_in_list
from .project_access import (
    _project_extract,
    _project_json_extract,
    _project_map_get,
    _project_struct_field,
    _project_struct_field_idx,
)
from .project_cast import _project_cast
from .project_ops import _project_binary_op, _project_unary_op
from .project_string import (
    _project_regexp,
    _project_string_fn,
    _project_string_op,
    _project_substring,
)
from .project_string_n import _project_string_fn_n, _project_udf_call


def _eval_column_expr(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """Evaluate an Expr to produce a Column[HeapRegion] for projection.

    Handles ColRef (copy column), Literal (broadcast), BinaryOp (arithmetic),
    UnaryOp, Alias (evaluate child, rename), and Cast.

    ⚠ THIS IS THE THIRD LADDER OVER THE `EXPR_*` TAG UNIVERSE, and it is in
    the same defect class as the two that `komira_plan_expr/expr_walk.mojo`
    replaced. `MapOp.execute` pairs THIS function (the column's DATA) with
    `walk_expr_field` (the column's TYPE); a tag armed in one and not the
    other is either an unexportable `null` column or a raise, and it has
    happened here twice already — EXPR_IN_LIST ("had a
    predicate-context arm but was missing from the projection-context
    dispatch") and EXPR_UNARY_OP. A new tag must arm both walkers.

    ⛔ THIS LADDER RAISES WHERE IT HAS NO ARM, WHICH IS WHY IT IS THE LEAST
    DANGEROUS OF THE THREE — but a tag it lacks that `walk_expr_field` HAS is
    still a plan the optimizer will happily build and the executor will
    refuse. `EXPR_STRING_OP` WAS exactly that (typed BOOL, unevaluable here);
    both directions of the cross-ladder comparison are pinned now, so the
    next one cannot arrive unmeasured.

    # DERIVED FACTS — re-derive with the gate, never hand-count.
    # arms: 22
    # unwalked: EXPR_BETWEEN EXPR_COL_IDX EXPR_CORRELATED_SUBQUERY EXPR_SORT_KEY EXPR_WINDOW_FN

    `EXPR_COL_IDX` is handled inside the EXPR_COL_REF arm via
    `resolve_col_index`; `EXPR_SORT_KEY` / `EXPR_BETWEEN` carry no payload;
    `EXPR_WINDOW_FN` / `EXPR_CORRELATED_SUBQUERY` are lowered away by the
    optimizer before a projection sees them.

    Args:
        expr: The expression to evaluate.
        batch: The input RecordBatch.

    Returns:
        A Column containing the evaluated result.
    """
    if expr.tag == EXPR_COL_REF:
        var col_idx = resolve_col_index(expr, batch.schema)
        return copy_column(batch, col_idx)

    elif expr.tag == EXPR_STRUCT_FIELD:
        return _project_struct_field(expr, batch)

    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        return _project_struct_field_idx(expr, batch)

    elif expr.tag == EXPR_MAP_GET:
        return _project_map_get(expr, batch)

    elif expr.tag == EXPR_JSON_EXTRACT:
        return _project_json_extract(expr, batch)

    elif expr.tag == EXPR_EXTRACT:
        return _project_extract(expr, batch)

    elif expr.tag == EXPR_MATH_FN:
        # unary scalar math
        # (sin / cos / sqrt / asin / radians).  Coerce the child to FLOAT64,
        # apply element-wise, emit a FLOAT64 column.  Null in -> null out.
        var math_child = _eval_column_expr(expr.math_fn_child_ref(), batch)
        var farr = _column_to_float64(math_child)
        var out = eval_math_unary(expr.math_fn_op(), farr)
        return Column.from_primitive[DType.float64](out)

    elif expr.tag == EXPR_MATH_FN2:
        # binary scalar math
        # (atan2).  Coerce both children to FLOAT64, apply element-wise,
        # emit FLOAT64.  A row is null if EITHER operand is null.
        var math_left = _eval_column_expr(expr.math_fn2_left_ref(), batch)
        var math_right = _eval_column_expr(expr.math_fn2_right_ref(), batch)
        var l_arr = _column_to_float64(math_left)
        var r_arr = _column_to_float64(math_right)
        var out2 = eval_math_binary(expr.math_fn2_op(), l_arr, r_arr)
        return Column.from_primitive[DType.float64](out2)

    elif expr.tag == EXPR_ALIAS:
        # Evaluate the child expression; the alias name is handled by the schema
        return _eval_column_expr(expr.alias_child_ref(), batch)

    elif expr.tag == EXPR_LITERAL:
        var lit_val = expr.literal_value()
        return broadcast_scalar(lit_val, batch.num_rows())

    elif expr.tag == EXPR_AGG_FN:
        # The typed-frame lowering for `col == col.agg`.
        # An EXPR_AGG_FN reaching the projection evaluator is the post-agg
        # scalar-broadcast shape (TPC-H Q15 `total_revenue == total_revenue
        # .max`): the generic `DataFrame[O]` path resolves it
        # via the optimizer's eager-fold (`optimizer_scalar_broadcast`), but the
        # typed frame path does NOT run that rewrite, so the `EXPR_AGG_FN` node
        # survives to here. Reduce the aggregated CHILD column over the WHOLE
        # resident batch to a single scalar and BROADCAST it to a length-N column
        # (the enclosing `col CMP <this>` comparison then runs col-vs-col). The
        # resident batch is the full agg-breaker output (the walker's POST-BREAKER
        # FILTER arm decoded it before evaluating the predicate), so the reduction
        # is a correct GLOBAL aggregate across all groups — byte-equiv to the
        # generic path's folded literal, minus the double base-scan.
        var agg_child_col = _eval_column_expr(expr.agg_fn_child_ref(), batch)
        var agg_scalar = _reduce_agg_scalar(agg_child_col, expr.agg_fn_op())
        return broadcast_scalar(agg_scalar, batch.num_rows())

    elif expr.tag == EXPR_BINARY_OP:
        return _project_binary_op(expr, batch)

    elif expr.tag == EXPR_UNARY_OP:
        return _project_unary_op(expr, batch)

    elif expr.tag == EXPR_CAST:
        return _project_cast(expr, batch)

    elif expr.tag == EXPR_WHEN:
        # CASE WHEN ... THEN ... ELSE ... END
        # Scalar evaluation: for each row, evaluate conditions in order.
        # Return the value of the first matching condition (or otherwise).
        #
        # This is per-row branching. SIMD CASE/WHEN is a future
        # optimization.
        return _eval_when_expr(expr, batch)

    elif expr.tag == EXPR_IN_LIST:
        # IN-list projection arm. EXPR_IN_LIST has a predicate-context arm
        # in `eval_predicate._eval_predicate` and needs this
        # projection-context one too
        # dispatch — when the optimizer hoists an IN-list predicate into
        # a `with_column`/projection (or when the SDK's `_eval_column_expr`
        # is reached via `_eval_short_circuit_and`/`_eval_short_circuit_or`
        # while materializing an OR-tree containing IN-list branches),
        # the projection path raised "unsupported projection expression
        # tag: 9". This arm delegates to the same typed kernel as the
        # predicate path (`_eval_in_list`) and boxes the resulting
        # BooleanArray as a Bool Column. Identical semantics to the
        # predicate-context call site; cost is one extra BooleanArray ->
        # Column wrapping (zero-copy, just a Column header construction).
        var ba = _eval_in_list(expr, batch)

        # ⛔ THE NULL CONTRACT LIVES IN `_eval_in_list`, NOT HERE. Re-imposing
        # the child's validity on a copy of the answer here, on the
        # argument that the FILTER context does not need it — "`NULL IN (...)` is
        # UNKNOWN, which does not select" — is false twice: a NULL row would
        # answer a definite FALSE there, which `NOT` selects (`WHERE NOT (k IN
        # (1, 2))`: DuckDB 1 row), and a NULL row whose raw payload
        # equalled a member would answer TRUE (`WHERE k IN (0, 1)` over the parquet
        # decode's 0-filled slot). One mechanism, at the one dispatcher both
        # contexts call; it also answers a NULL MEMBER (`x IN (1, NULL)`).
        # Falsifier: `tests/test_in_list_null_contract.mojo`.
        return Column.from_boolean(ba^)

    elif expr.tag == EXPR_STRING_OP:
        return _project_string_op(expr, batch)

    elif expr.tag == EXPR_REGEXP:
        return _project_regexp(expr, batch)

    elif expr.tag == EXPR_SUBSTRING:
        return _project_substring(expr, batch)

    elif expr.tag == EXPR_STRING_FN:
        return _project_string_fn(expr, batch)

    elif expr.tag == EXPR_STRING_FN_N:
        return _project_string_fn_n(expr, batch)

    elif expr.tag == EXPR_UDF_CALL:
        return _project_udf_call(expr, batch)

    else:
        raise Error("PipelineCompiler: unsupported projection expression tag: " + String(Int(expr.tag)))
