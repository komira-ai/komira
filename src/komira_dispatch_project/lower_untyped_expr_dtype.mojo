# =============================================================================
# lower_untyped_expr_dtype.mojo: the runtime dtype family of an expression
# =============================================================================
#
# `_infer_runtime_dtype` answers which `RUNTIME_DTYPE_*` family a plan
# expression evaluates in, the way the translator in `lower_untyped_expr`
# will lower it. The translator uses it to pick a node per operand family and
# a CASE's output family; `compute_project` uses it to pick the walker
# channel of a computed column.
# =============================================================================

from std.collections import Dict

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_STRING_OP,
    EXPR_ALIAS,
    EXPR_CAST,
    EXPR_WHEN,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
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
)
from komira_plan_expr.scalar_value import (
    SCALAR_KIND_DTYPE,
    SCALAR_KIND_DATE32,
    SCALAR_KIND_TIMESTAMP,
    SCALAR_KIND_DECIMAL128,
)

from .lower_untyped_expr import (
    RUNTIME_DTYPE_BOOL,
    RUNTIME_DTYPE_DECIMAL128,
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_STRING,
    RUNTIME_DTYPE_UNSUPPORTED,
)


def _infer_runtime_dtype(
    e: Expr, col_name_to_dtype: Dict[String, Int]
) raises -> Int:
    """The runtime dtype family `e` evaluates in.

    * EXPR_COL_REF: `col_name_to_dtype[name]`, UNSUPPORTED when absent.
    * EXPR_LITERAL: DATE32 and TIMESTAMP are I64, DECIMAL128 is DECIMAL128,
      a string is STRING; a plain DType value is I64 when it fits the int64
      family, F64 for float64 and float32, BOOL for bool; anything else is
      UNSUPPORTED.
    * EXPR_BINARY_OP: a comparison or AND / OR is BOOL. An arithmetic
      operator is F64 when either operand is F64, else the left operand's
      family (so I64 / I64 division is I64: the walker's I64 division widens
      inside the node and writes the I64 channel). MOD is UNSUPPORTED.
    * EXPR_UNARY_OP: NOT and the null tests are BOOL; every other op is
      UNSUPPORTED.
    * EXPR_STRING_OP: BOOL. EXPR_MATH_FN and EXPR_MATH_FN2: F64.
    * EXPR_ALIAS: its child's family.
    * EXPR_CAST: F64 for a FLOAT64 target over an I64 or F64 operand, the one
      cast the translator lowers; UNSUPPORTED otherwise, so this answer and
      the translator agree on every cast.
    * EXPR_WHEN: F64 when any THEN or the ELSE is F64, else I64.
    * Any other tag: UNSUPPORTED.

    Declared `raises` for the Dict accessor; every read is guarded by a
    membership test, so it does not raise.
    """
    if e.tag == EXPR_COL_REF:
        var name = e._col_ref.value().name
        if name not in col_name_to_dtype:
            return RUNTIME_DTYPE_UNSUPPORTED
        return col_name_to_dtype[name]
    if e.tag == EXPR_LITERAL:
        ref lit = e._literal.value()
        ref sv = lit.value
        if sv._kind == SCALAR_KIND_DATE32:
            return RUNTIME_DTYPE_I64
        if sv._kind == SCALAR_KIND_TIMESTAMP:
            return RUNTIME_DTYPE_I64
        if sv._kind == SCALAR_KIND_DECIMAL128:
            return RUNTIME_DTYPE_DECIMAL128
        # A string carries a kind other than SCALAR_KIND_DTYPE, so this arm
        # comes before the kind check below.
        if sv.is_string():
            return RUNTIME_DTYPE_STRING
        if sv._kind != SCALAR_KIND_DTYPE:
            return RUNTIME_DTYPE_UNSUPPORTED
        if sv.fits_int64_family():
            return RUNTIME_DTYPE_I64
        if sv.dtype == DType.float64 or sv.dtype == DType.float32:
            return RUNTIME_DTYPE_F64
        if sv.dtype == DType.bool:
            return RUNTIME_DTYPE_BOOL
        return RUNTIME_DTYPE_UNSUPPORTED
    if e.tag == EXPR_BINARY_OP:
        ref b = e._binary.value()
        var op = b.op
        if (
            op == BIN_EQ
            or op == BIN_NE
            or op == BIN_LT
            or op == BIN_LE
            or op == BIN_GT
            or op == BIN_GE
            or op == BIN_AND
            or op == BIN_OR
        ):
            return RUNTIME_DTYPE_BOOL
        if (
            op == BIN_ADD
            or op == BIN_SUB
            or op == BIN_MUL
            or op == BIN_DIV
        ):
            var l = _infer_runtime_dtype(b.left[], col_name_to_dtype)
            var r = _infer_runtime_dtype(b.right[], col_name_to_dtype)
            if l == RUNTIME_DTYPE_F64 or r == RUNTIME_DTYPE_F64:
                return RUNTIME_DTYPE_F64
            return l
        return RUNTIME_DTYPE_UNSUPPORTED
    if e.tag == EXPR_UNARY_OP:
        var op = e.unary_op()
        if op == UN_NOT or op == UN_IS_NULL or op == UN_IS_NOT_NULL:
            return RUNTIME_DTYPE_BOOL
        return RUNTIME_DTYPE_UNSUPPORTED
    if e.tag == EXPR_STRING_OP:
        return RUNTIME_DTYPE_BOOL
    if e.tag == EXPR_MATH_FN or e.tag == EXPR_MATH_FN2:
        return RUNTIME_DTYPE_F64
    if e.tag == EXPR_ALIAS:
        return _infer_runtime_dtype(e.alias_child_ref(), col_name_to_dtype)
    if e.tag == EXPR_CAST:
        if not (
            e.cast_target() == DType.float64
            and e.cast_target_arrow() == ArrowType.FLOAT64
        ):
            return RUNTIME_DTYPE_UNSUPPORTED
        var cast_child_fam = _infer_runtime_dtype(
            e.cast_child_ref(), col_name_to_dtype
        )
        if (
            cast_child_fam == RUNTIME_DTYPE_I64
            or cast_child_fam == RUNTIME_DTYPE_F64
        ):
            return RUNTIME_DTYPE_F64
        return RUNTIME_DTYPE_UNSUPPORTED
    if e.tag == EXPR_WHEN:
        var n_cases = e.when_num_cases()
        for i in range(n_cases):
            if (
                _infer_runtime_dtype(e.when_case_result_ref(i), col_name_to_dtype)
                == RUNTIME_DTYPE_F64
            ):
                return RUNTIME_DTYPE_F64
        if (
            _infer_runtime_dtype(e.when_default_ref(), col_name_to_dtype)
            == RUNTIME_DTYPE_F64
        ):
            return RUNTIME_DTYPE_F64
        return RUNTIME_DTYPE_I64
    return RUNTIME_DTYPE_UNSUPPORTED
