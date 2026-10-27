# =============================================================================
# lower_untyped_expr_ops.mojo: the leaf and operator arms of the translator
# =============================================================================
#
# The arms `lower_untyped_expr._translate_node` dispatches to: column
# references, literals, binary operators, unary operators, the LIKE family
# and IN lists. Each appends its node to `pool` and returns its slot; each
# raises `UnsupportedByLowerUntypedExpr:` on a shape it has no node for.
# =============================================================================

from std.collections import Dict

from komira_eval.expression_executor import DecimalSpec
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    EXPR_COL_STRING,
    EXPR_EQ_I64,
    EXPR_GT_F64,
    EXPR_GT_I64,
    make_add_decimal128,
    make_add_f64,
    make_add_i64,
    make_and,
    make_col,
    make_col_binary,
    make_col_bool,
    make_col_decimal128,
    make_col_string,
    make_div_f64,
    make_div_i64,
    make_eq_decimal128,
    make_eq_f64,
    make_eq_f64_mixed,
    make_eq_string,
    make_ge_decimal128,
    make_ge_f64,
    make_ge_f64_mixed,
    make_ge_i64,
    make_ge_string,
    make_gt_decimal128,
    make_gt_f64_mixed,
    make_gt_string,
    make_in_list,
    make_is_not_null_string,
    make_is_null_string,
    make_le_decimal128,
    make_le_f64,
    make_le_f64_mixed,
    make_le_i64,
    make_le_string,
    make_like_string,
    make_lit_bool,
    make_lit_decimal128,
    make_lit_f64,
    make_lit_i64,
    make_lit_string,
    make_lt_decimal128,
    make_lt_f64,
    make_lt_f64_mixed,
    make_lt_i64,
    make_lt_string,
    make_mul_decimal128,
    make_mul_f64,
    make_mul_i64,
    make_ne_f64,
    make_ne_i64,
    make_neq_decimal128,
    make_neq_string,
    make_not_bool,
    make_or,
    make_sub_decimal128,
    make_sub_f64,
    make_sub_i64,
)
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    STR_CONTAINS,
    STR_STARTS_WITH,
    STR_ENDS_WITH,
    STR_LIKE,
)
from komira_plan_expr.scalar_value import (
    ScalarValue,
    SCALAR_KIND_DTYPE,
    SCALAR_KIND_DATE32,
    SCALAR_KIND_TIMESTAMP,
    SCALAR_KIND_DECIMAL128,
)

from .lower_untyped_expr import (
    _translate_node,
    RUNTIME_DTYPE_BINARY,
    RUNTIME_DTYPE_BOOL_COL,
    RUNTIME_DTYPE_DECIMAL128,
    RUNTIME_DTYPE_DICTIONARY,
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_STRING,
    RUNTIME_DTYPE_UNSUPPORTED,
)
from .lower_untyped_expr_dtype import _infer_runtime_dtype


# =============================================================================
# Leaf: EXPR_COL_REF
# =============================================================================


def _translate_col_ref(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
) raises -> Int:
    """Translate EXPR_COL_REF to the column leaf its family reads through.

    The position comes from `col_name_to_idx` (a missing name raises); the
    family from `col_name_to_dtype` picks the leaf kind: EXPR_COL_BOOL,
    EXPR_COL_STRING (also for a DICTIONARY column, whose string accessor
    decodes it), EXPR_COL_DECIMAL128 (precision and scale come from the
    column at read time), EXPR_COL_BINARY, or EXPR_COL for every other family.
    A name absent from the family map reads as EXPR_COL.
    """
    var name = e._col_ref.value().name
    if name not in col_name_to_idx:
        raise Error(
            "UnsupportedByLowerUntypedExpr: EXPR_COL_REF name '"
            + name
            + "' not in caller-provided col_name_to_idx map.  The"
            + " caller is responsible for emitting a dict covering"
            + " every column referenced in the predicate / project"
            + " expression."
        )
    var idx = col_name_to_idx[name]
    var dt = RUNTIME_DTYPE_I64
    if name in col_name_to_dtype:
        dt = col_name_to_dtype[name]
    if dt == RUNTIME_DTYPE_BOOL_COL:
        pool.append(make_col_bool(idx))
    elif dt == RUNTIME_DTYPE_STRING:
        pool.append(make_col_string(idx))
    elif dt == RUNTIME_DTYPE_DECIMAL128:
        pool.append(make_col_decimal128(idx))
    elif dt == RUNTIME_DTYPE_BINARY:
        pool.append(make_col_binary(idx))
    elif dt == RUNTIME_DTYPE_DICTIONARY:
        pool.append(make_col_string(idx))
    else:
        pool.append(make_col(idx))
    return len(pool) - 1


# =============================================================================
# Leaf: EXPR_LITERAL
# =============================================================================


def _translate_literal(
    e: Expr,
    mut pool: List[RuntimeExpr],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
) raises -> Int:
    """Translate EXPR_LITERAL by its `ScalarValue` kind.

    DATE32 lowers to EXPR_LIT_I64 days since the epoch and TIMESTAMP to
    EXPR_LIT_I64 microseconds (the walker reads both on the I64 channel).
    DECIMAL128 interns (value, precision, scale) into `decimal_pool`; a string
    (the empty string included) interns its text into `string_pool`. A plain
    DType value lowers to EXPR_LIT_I64 when it fits the int64 family, to
    EXPR_LIT_F64 for float64 and float32, and to EXPR_LIT_BOOL. A NULL or any
    other kind raises.
    """
    ref lit = e._literal.value()
    ref sv = lit.value
    if sv._kind == SCALAR_KIND_DATE32:
        pool.append(make_lit_i64(Int64(Int(sv.date32_val))))
        return len(pool) - 1
    if sv._kind == SCALAR_KIND_TIMESTAMP:
        pool.append(make_lit_i64(sv.ts_micros))
        return len(pool) - 1
    if sv._kind == SCALAR_KIND_DECIMAL128:
        var pool_idx = len(decimal_pool)
        decimal_pool.append(
            DecimalSpec(
                sv.decimal_value_i128(),
                sv.dec128_precision,
                sv.dec128_scale,
            )
        )
        pool.append(make_lit_decimal128(pool_idx))
        return len(pool) - 1
    # A string carries a kind other than SCALAR_KIND_DTYPE, so this arm comes
    # before the kind check below.
    if sv.is_string():
        var pool_idx = len(string_pool)
        string_pool.append(sv.string_val.copy())
        pool.append(make_lit_string(pool_idx))
        return len(pool) - 1
    if sv._kind != SCALAR_KIND_DTYPE:
        raise Error(
            "UnsupportedByLowerUntypedExpr: ScalarValue._kind "
            + String(Int(sv._kind))
            + " (unknown extended-kind variant) not in lower_untyped_expr"
            + " in-scope subset."
        )
    if sv.fits_int64_family():
        pool.append(make_lit_i64(sv.int_val))
        return len(pool) - 1
    if sv.dtype == DType.float64 or sv.dtype == DType.float32:
        pool.append(make_lit_f64(sv.float_val))
        return len(pool) - 1
    if sv.dtype == DType.bool:
        pool.append(make_lit_bool(sv.bool_val))
        return len(pool) - 1
    raise Error(
        "UnsupportedByLowerUntypedExpr: ScalarValue DType "
        + String(sv.dtype)
        + " (null / other) not in lower_untyped_expr in-scope"
        + " subset (only int64/int32, float64/float32, bool, date32,"
        + " timestamp_*, utf8-string today)."
    )


# =============================================================================
# Binary operators
# =============================================================================


def _translate_binary(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Translate EXPR_BINARY_OP.

    - AND / OR: both operands, then `make_and` / `make_or`.
    - The comparisons and the arithmetic operators: one node per operand
      family. Both operands must infer the same family, except F64 against
      I64, which lowers to the F64 node (the F64 walker widens the I64
      operand). DECIMAL / DECIMAL division and MOD raise.
    """
    ref b = e._binary.value()
    var op = b.op
    ref left = b.left[]
    ref right = b.right[]

    if op == BIN_AND:
        var li = _translate_node(
            left, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        var ri = _translate_node(
            right, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        pool.append(make_and(li, ri))
        return len(pool) - 1

    if op == BIN_OR:
        var li = _translate_node(
            left, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        var ri = _translate_node(
            right, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        pool.append(make_or(li, ri))
        return len(pool) - 1

    var left_family = _infer_runtime_dtype(left, col_name_to_dtype)
    var right_family = _infer_runtime_dtype(right, col_name_to_dtype)
    if (
        left_family == RUNTIME_DTYPE_UNSUPPORTED
        or right_family == RUNTIME_DTYPE_UNSUPPORTED
    ):
        raise Error(
            "UnsupportedByLowerUntypedExpr: binary-op operand has unsupported"
            + " runtime-dtype-family (string / decimal / null / other)."
        )
    # F64 against I64: the walker has no cast node, so the mixed pair lowers
    # to the F64 node and the F64 walker widens the I64 operand (a column, a
    # literal or I64 arithmetic) to Float64. Only the five comparisons other
    # than NE and the four arithmetic operators take this route; every other
    # family mismatch raises.
    if left_family != right_family:
        var is_mixed_f64_i64 = (
            (left_family == RUNTIME_DTYPE_F64 and right_family == RUNTIME_DTYPE_I64)
            or (left_family == RUNTIME_DTYPE_I64 and right_family == RUNTIME_DTYPE_F64)
        )
        var is_compare_op = (
            op == BIN_LT
            or op == BIN_LE
            or op == BIN_GT
            or op == BIN_GE
            or op == BIN_EQ
        )
        var is_arith_op = (
            op == BIN_ADD
            or op == BIN_SUB
            or op == BIN_MUL
            or op == BIN_DIV
        )
        if not (is_mixed_f64_i64 and (is_compare_op or is_arith_op)):
            raise Error(
                "UnsupportedByLowerUntypedExpr: binary-op operand runtime-dtype"
                + " mismatch (left="
                + String(left_family)
                + " right="
                + String(right_family)
                + " op="
                + String(Int(op))
                + ").  The runtime walker does not implicit-cast at compare/arith"
                + " time for this op-kind; in-scope mixed F64/I64 widening covers"
                + " comparison + arithmetic (BIN_LT/LE/GT/GE/EQ + BIN_ADD/SUB/MUL/DIV)."
            )
        var li_mixed = _translate_node(
            left, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        var ri_mixed = _translate_node(
            right, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        if op == BIN_LT:
            pool.append(make_lt_f64_mixed(li_mixed, ri_mixed))
        elif op == BIN_LE:
            pool.append(make_le_f64_mixed(li_mixed, ri_mixed))
        elif op == BIN_GT:
            pool.append(make_gt_f64_mixed(li_mixed, ri_mixed))
        elif op == BIN_GE:
            pool.append(make_ge_f64_mixed(li_mixed, ri_mixed))
        elif op == BIN_EQ:
            pool.append(make_eq_f64_mixed(li_mixed, ri_mixed))
        elif op == BIN_ADD:
            pool.append(make_add_f64(li_mixed, ri_mixed))
        elif op == BIN_SUB:
            pool.append(make_sub_f64(li_mixed, ri_mixed))
        elif op == BIN_MUL:
            pool.append(make_mul_f64(li_mixed, ri_mixed))
        else:  # BIN_DIV
            # IEEE-754 division of the widened operands: x/0 is +-Inf or NaN,
            # never a raise.
            pool.append(make_div_f64(li_mixed, ri_mixed))
        return len(pool) - 1
    var family = left_family

    var li = _translate_node(
        left, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
    )
    var ri = _translate_node(
        right, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
    )

    # Comparisons. STRING compares byte-wise; a NULL operand is skipped (SQL
    # three-valued logic, in the walker).
    if op == BIN_GT:
        if family == RUNTIME_DTYPE_I64:
            pool.append(_make_gt_i64_node(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(_make_gt_f64_node(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_gt_decimal128(li, ri))
        elif family == RUNTIME_DTYPE_STRING:
            pool.append(make_gt_string(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_GT on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128, String today)."
            )
        return len(pool) - 1

    if op == BIN_GE:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_ge_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_ge_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_ge_decimal128(li, ri))
        elif family == RUNTIME_DTYPE_STRING:
            pool.append(make_ge_string(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_GE on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128, String today)."
            )
        return len(pool) - 1

    if op == BIN_LT:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_lt_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_lt_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_lt_decimal128(li, ri))
        elif family == RUNTIME_DTYPE_STRING:
            pool.append(make_lt_string(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_LT on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128, String today)."
            )
        return len(pool) - 1

    if op == BIN_LE:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_le_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_le_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_le_decimal128(li, ri))
        elif family == RUNTIME_DTYPE_STRING:
            pool.append(make_le_string(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_LE on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128, String supported)."
            )
        return len(pool) - 1

    if op == BIN_EQ:
        if family == RUNTIME_DTYPE_I64:
            pool.append(_make_eq_i64_node(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_eq_f64(li, ri))
        elif family == RUNTIME_DTYPE_STRING:
            pool.append(make_eq_string(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_eq_decimal128(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_EQ on dtype-family "
                + String(family)
                + " (only I64, F64, String, Decimal128 supported)."
            )
        return len(pool) - 1

    if op == BIN_NE:
        if family == RUNTIME_DTYPE_STRING:
            pool.append(make_neq_string(li, ri))
            return len(pool) - 1
        if family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_neq_decimal128(li, ri))
            return len(pool) - 1
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_ne_i64(li, ri))
            return len(pool) - 1
        if family == RUNTIME_DTYPE_F64:
            pool.append(make_ne_f64(li, ri))
            return len(pool) - 1
        raise Error(
            "UnsupportedByLowerUntypedExpr: BIN_NE on dtype-family "
            + String(family)
            + " (I64 / F64 / String / Decimal128 supported)."
        )

    # Arithmetic.
    if op == BIN_ADD:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_add_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_add_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_add_decimal128(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_ADD on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128 today)."
            )
        return len(pool) - 1

    if op == BIN_SUB:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_sub_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_sub_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_sub_decimal128(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_SUB on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128 today)."
            )
        return len(pool) - 1

    if op == BIN_MUL:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_mul_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_mul_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            pool.append(make_mul_decimal128(li, ri))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_MUL on dtype-family "
                + String(family)
                + " (only I64, F64, Decimal128 today)."
            )
        return len(pool) - 1

    # Division. EXPR_DIV_I64 widens both operands to Float64 before it
    # divides; both I64 and F64 division follow IEEE-754 (x/0 is +-Inf or
    # NaN, never a raise).
    if op == BIN_DIV:
        if family == RUNTIME_DTYPE_I64:
            pool.append(make_div_i64(li, ri))
        elif family == RUNTIME_DTYPE_F64:
            pool.append(make_div_f64(li, ri))
        elif family == RUNTIME_DTYPE_DECIMAL128:
            # DECIMAL / DECIMAL is DOUBLE in DuckDB, and the declared output
            # field says FLOAT64. The decimal division node answers DECIMAL128
            # bytes, and this translator has no DECIMAL -> DOUBLE node, so it
            # refuses rather than publish decimal bytes as doubles.
            raise Error(
                "UnsupportedByLowerUntypedExpr: DECIMAL / DECIMAL divides as"
                + " DOUBLE (DuckDB 1.5.3's type), and this post-breaker"
                + " translator has no DECIMAL -> DOUBLE conversion node."
            )
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: BIN_DIV on dtype-family "
                + String(family)
                + " (only I64, F64 today)."
            )
        return len(pool) - 1

    # BIN_MOD and any other op code.
    raise Error(
        "UnsupportedByLowerUntypedExpr: binary-op code "
        + String(Int(op))
        + " not in lower_untyped_expr in-scope subset (supported:"
        + " BIN_AND, BIN_OR, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,"
        + " BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV)."
    )


# =============================================================================
# Unary operators
# =============================================================================


def _translate_unary(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Translate EXPR_UNARY_OP: NOT, and IS [NOT] NULL over an operand of the
    STRING family (the walker's null tests read a string column's validity).
    Every other unary op, and a null test over any other family, raises."""
    var op = e.unary_op()
    if op == UN_NOT:
        ref child = e.unary_child_ref()
        var ci = _translate_node(
            child, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        pool.append(make_not_bool(ci))
        return len(pool) - 1
    if op == UN_IS_NULL or op == UN_IS_NOT_NULL:
        ref child = e.unary_child_ref()
        var child_family = _infer_runtime_dtype(child, col_name_to_dtype)
        if child_family != RUNTIME_DTYPE_STRING:
            raise Error(
                "UnsupportedByLowerUntypedExpr: EXPR_UNARY_OP with op "
                + String(Int(op))
                + " (UN_IS_NULL/UN_IS_NOT_NULL) on non-String child"
                + " (child_family=" + String(child_family) + "). Only"
                + " a STRING child operand has a runtime null test."
            )
        var ci = _translate_node(
            child, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
        if op == UN_IS_NULL:
            pool.append(make_is_null_string(ci))
        else:
            pool.append(make_is_not_null_string(ci))
        return len(pool) - 1
    raise Error(
        "UnsupportedByLowerUntypedExpr: EXPR_UNARY_OP with op "
        + String(Int(op))
        + " (UN_NOT, UN_IS_NULL, UN_IS_NOT_NULL supported;"
        + " UN_NEGATE / other unary ops out of scope)."
    )


# =============================================================================
# The LIKE family: EXPR_STRING_OP
# =============================================================================


def _translate_string_op(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Translate EXPR_STRING_OP to EXPR_LIKE_STRING.

    The operand must lower to a string column leaf (EXPR_COL_STRING). The
    pattern is interned into `string_pool` as an EXPR_LIT_STRING node:
      * STR_LIKE        "p" -> LIKE "p"
      * STR_CONTAINS    "x" -> LIKE "%x%"
      * STR_STARTS_WITH "x" -> LIKE "x%"
      * STR_ENDS_WITH   "x" -> LIKE "%x"
    The wrapped forms do not escape the pattern: a `%` or `_` inside a
    CONTAINS / STARTS_WITH / ENDS_WITH argument is read as a wildcard.
    """
    var op = e.string_op_type()
    if (
        op != STR_LIKE
        and op != STR_CONTAINS
        and op != STR_STARTS_WITH
        and op != STR_ENDS_WITH
    ):
        raise Error(
            "UnsupportedByLowerUntypedExpr: EXPR_STRING_OP op "
            + String(Int(op))
            + " not in lower_untyped_expr in-scope subset (supported:"
            + " STR_LIKE, STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH)."
        )

    var col_slot = _translate_node(
        e.string_op_child_ref(),
        pool,
        col_name_to_idx,
        col_name_to_dtype,
        string_pool,
        decimal_pool,
        in_list_pool,
        when_pool,
    )
    var child_node = pool[col_slot]
    if child_node.kind != EXPR_COL_STRING:
        raise Error(
            "UnsupportedByLowerUntypedExpr: EXPR_STRING_OP STR_LIKE"
            " child must resolve to EXPR_COL_STRING (kind="
            + String(child_node.kind) + ")."
        )

    var raw_pattern = e.string_op_pattern()
    var rewritten_pattern: String
    if op == STR_CONTAINS:
        rewritten_pattern = String("%") + raw_pattern + String("%")
    elif op == STR_STARTS_WITH:
        rewritten_pattern = raw_pattern + String("%")
    elif op == STR_ENDS_WITH:
        rewritten_pattern = String("%") + raw_pattern
    else:  # STR_LIKE
        rewritten_pattern = raw_pattern^

    var pattern_idx = len(string_pool)
    string_pool.append(rewritten_pattern^)
    pool.append(make_lit_string(pattern_idx))
    var lit_slot = len(pool) - 1

    pool.append(make_like_string(col_slot, lit_slot))
    return len(pool) - 1


# =============================================================================
# IN lists
# =============================================================================


def _translate_in_list(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Translate EXPR_IN_LIST to one EXPR_IN_LIST node.

    The operand is translated first; a copy of the value list is appended to
    `in_list_pool`, and the node carries the operand's slot in `left` and the
    list's index in `col_idx`. The walker picks the comparison by the
    column's type when it evaluates; an operand that is not a column leaf is
    refused there, by the walker.
    """
    ref child = e.in_list_child_ref()
    ref values = e.in_list_values_ref()

    var child_slot = _translate_node(
        child,
        pool,
        col_name_to_idx,
        col_name_to_dtype,
        string_pool,
        decimal_pool,
        in_list_pool,
        when_pool,
    )

    var values_copy = List[ScalarValue](capacity=len(values))
    for i in range(len(values)):
        values_copy.append(values[i].copy())
    var pool_idx = len(in_list_pool)
    in_list_pool.append(values_copy^)

    pool.append(make_in_list(child_slot, pool_idx))
    return len(pool) - 1


# =============================================================================
# Node constructors for kinds with no public factory
# =============================================================================


@always_inline
def _make_gt_i64_node(left: Int, right: Int) -> RuntimeExpr:
    """An EXPR_GT_I64 node."""
    return RuntimeExpr(EXPR_GT_I64, 0, 0.0, False, 0, left, right)


@always_inline
def _make_gt_f64_node(left: Int, right: Int) -> RuntimeExpr:
    """An EXPR_GT_F64 node."""
    return RuntimeExpr(EXPR_GT_F64, 0, 0.0, False, 0, left, right)


@always_inline
def _make_eq_i64_node(left: Int, right: Int) -> RuntimeExpr:
    """An EXPR_EQ_I64 node."""
    return RuntimeExpr(EXPR_EQ_I64, 0, 0.0, False, 0, left, right)
