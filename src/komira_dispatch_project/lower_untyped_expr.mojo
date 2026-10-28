# =============================================================================
# lower_untyped_expr.mojo: the plan `Expr` -> `RuntimeExpr` pool translator
# =============================================================================
#
# Lowers one plan expression (a filter predicate, a project output expression
# or an aggregate input) into the flat `List[RuntimeExpr]` pool that
# `komira_eval.ExpressionExecutor` walks. The lowering is deterministic: the
# same expression and the same two column maps always append the same nodes in
# the same order, and nothing here rewrites or optimizes the expression.
#
# A shape outside the translator's subset RAISES an error whose message starts
# with `UnsupportedByLowerUntypedExpr:`. The caller decides what a raise means
# (the computed-projection evaluator, a later slice of this package, turns
# it into a decline).
#
# Column resolution is the caller's: `col_name_to_idx` maps a column name to
# the position the walker reads, and `col_name_to_dtype` maps it to a
# `RUNTIME_DTYPE_*` family. The translator does not consult a schema.
#
# The subset:
#
#   * EXPR_COL_REF -> a column leaf whose kind follows the column's family
#     (EXPR_COL, EXPR_COL_BOOL, EXPR_COL_STRING, EXPR_COL_DECIMAL128,
#     EXPR_COL_BINARY; a DICTIONARY column reads as EXPR_COL_STRING).
#   * EXPR_LITERAL -> EXPR_LIT_I64 (every integer that fits int64, DATE32 days,
#     TIMESTAMP microseconds), EXPR_LIT_F64, EXPR_LIT_BOOL, EXPR_LIT_STRING
#     (interned into `string_pool`), EXPR_LIT_DECIMAL128 (into `decimal_pool`).
#     A NULL literal raises.
#   * EXPR_BINARY_OP -> AND / OR, the six comparisons and the four arithmetic
#     operators, per operand family (`lower_untyped_expr_ops`). Mixed
#     F64 / I64 operands widen to the F64 tags; any other family mismatch
#     raises.
#   * EXPR_UNARY_OP -> NOT, and IS [NOT] NULL over a STRING operand.
#   * EXPR_ALIAS -> its child (the name is irrelevant to the pool).
#   * EXPR_STRING_OP -> LIKE (CONTAINS / STARTS_WITH / ENDS_WITH become LIKE
#     patterns).
#   * EXPR_IN_LIST -> one EXPR_IN_LIST node; the values go to `in_list_pool`.
#   * EXPR_MATH_FN / EXPR_MATH_FN2 -> the F64 math nodes.
#   * EXPR_WHEN -> EXPR_CASE_I64 / EXPR_CASE_F64; the branch slots go to
#     `when_pool`.
#   * EXPR_CAST to FLOAT64 over an I64 or F64 operand -> EXPR_I64_TO_F64 (or
#     the operand itself when it is already F64).
#
# Everything else raises. `count_and_conjuncts` counts the conjuncts of a
# translated AND chain.
#
# The operator arms are in `lower_untyped_expr_ops`; the family inference is
# in `lower_untyped_expr_dtype`. The three modules call one another.
# =============================================================================

from std.collections import Dict

from komira_arrow.arrow_types import ArrowType
from komira_eval.expression_executor import DecimalSpec
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    EXPR_AND,
    make_asin_f64,
    make_atan2_f64,
    make_case_f64,
    make_case_i64,
    make_cos_f64,
    make_i64_to_f64,
    make_math_unary_f64,
    make_pow_f64,
    make_radians_f64,
    make_sin_f64,
    make_sqrt_f64,
)
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_STRING_OP,
    EXPR_ALIAS,
    EXPR_CAST,
    EXPR_IN_LIST,
    EXPR_WHEN,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    MATH_SIN,
    MATH_COS,
    MATH_SQRT,
    MATH_ASIN,
    MATH_RADIANS,
    MATH_GAMMA,
    MATH2_ATAN2,
    MATH2_POW,
)
from komira_plan_expr.scalar_value import ScalarValue

from .lower_untyped_expr_dtype import _infer_runtime_dtype
from .lower_untyped_expr_ops import (
    _translate_binary,
    _translate_col_ref,
    _translate_in_list,
    _translate_literal,
    _translate_string_op,
    _translate_unary,
)


# =============================================================================
# Runtime dtype families
# =============================================================================
#
# A `RuntimeExpr` node carries no dtype field; its family is implied by its
# kind (EXPR_GE_I64 against EXPR_GE_F64). These tags name the families: the
# caller's `col_name_to_dtype` values and the answers of
# `_infer_runtime_dtype`.
#
# Tags 0 to 5 are the families the translator reads and emits. Tags 6 to 23
# name narrower physical types; the caller's dtype mapper is expected to emit only
# RUNTIME_DTYPE_I32 of them, and the translator treats the rest like an
# unknown family. RUNTIME_DTYPE_BINARY and RUNTIME_DTYPE_DICTIONARY select a
# column leaf kind.

comptime RUNTIME_DTYPE_UNSUPPORTED: Int = -1
comptime RUNTIME_DTYPE_I64: Int = 0
comptime RUNTIME_DTYPE_F64: Int = 1
# An expression that PRODUCES a Bool (a comparison, a logical op, a Bool
# literal).
comptime RUNTIME_DTYPE_BOOL: Int = 2
# A column whose data type IS Bool (the leaf reads it as EXPR_COL_BOOL).
comptime RUNTIME_DTYPE_BOOL_COL: Int = 3
# A STRING column (EXPR_COL_STRING) or a string literal (EXPR_LIT_STRING, its
# text interned in `string_pool`).
comptime RUNTIME_DTYPE_STRING: Int = 4
# A DECIMAL128 column (EXPR_COL_DECIMAL128) or literal (EXPR_LIT_DECIMAL128,
# its value, precision and scale interned in `decimal_pool`).
comptime RUNTIME_DTYPE_DECIMAL128: Int = 5
comptime RUNTIME_DTYPE_I32: Int = 6
comptime RUNTIME_DTYPE_F32: Int = 7
comptime RUNTIME_DTYPE_I16: Int = 8
comptime RUNTIME_DTYPE_I8: Int = 9
comptime RUNTIME_DTYPE_U8: Int = 10
comptime RUNTIME_DTYPE_U16: Int = 11
comptime RUNTIME_DTYPE_U32: Int = 12
comptime RUNTIME_DTYPE_U64: Int = 13
comptime RUNTIME_DTYPE_DATE32: Int = 14
comptime RUNTIME_DTYPE_DATE64: Int = 15
comptime RUNTIME_DTYPE_TIMESTAMP_NS: Int = 16
comptime RUNTIME_DTYPE_TIMESTAMP_US: Int = 17
comptime RUNTIME_DTYPE_TIMESTAMP_MS: Int = 18
comptime RUNTIME_DTYPE_TIMESTAMP_S: Int = 19
# A BINARY column (EXPR_COL_BINARY, read byte for byte).
comptime RUNTIME_DTYPE_BINARY: Int = 20
comptime RUNTIME_DTYPE_LIST: Int = 21
comptime RUNTIME_DTYPE_STRUCT: Int = 22
comptime RUNTIME_DTYPE_MAP: Int = 23
# A DICTIONARY<STRING> column: the leaf is EXPR_COL_STRING, whose accessor
# decodes the dictionary to per-row values.
comptime RUNTIME_DTYPE_DICTIONARY: Int = 24


# =============================================================================
# Entry points
# =============================================================================


def translate_expr(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
) raises -> Int:
    """`translate_expr` without a `when_pool`, for a tree that holds no CASE.

    A CASE node's `col_idx` indexes the `when_pool` the executor is built
    with, and this overload's `when_pool` is a local the caller never sees.
    So it raises when the translated tree filled that local: a caller whose
    tree may hold a CASE uses the overload that takes `when_pool` and hands it
    to the executor."""
    var when_pool = List[List[Int]]()
    var root = _translate_node(
        e, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
    )
    if len(when_pool) > 0:
        raise Error(
            "UnsupportedByLowerUntypedExpr: EXPR_WHEN (CASE) reached the"
            " 7-arg translate_expr overload, whose throwaway when_pool is"
            " not threaded into the ExpressionExecutor. The caller must use"
            " the 8-arg translate_expr(..., mut when_pool) overload and"
            " forward when_pool^ to the executor ctor."
        )
    return root


def translate_expr(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Translate `e` into `pool` and return the root pool slot index.

    Every node appends one or more `RuntimeExpr` entries to `pool`; a parent
    names its children by pool slot (`left`, `right`). The translator only
    appends, so a caller may translate several expressions into one pool.

    Args:
        e: The plan expression to translate.
        pool: The RuntimeExpr arena; nodes are appended to it.
        col_name_to_idx: Column name -> the position the walker reads.
        col_name_to_dtype: Column name -> a `RUNTIME_DTYPE_*` family.
        string_pool: Receives string literals and LIKE patterns.
        decimal_pool: Receives DECIMAL128 literals.
        in_list_pool: Receives the value list of each IN list.
        when_pool: Receives the branch slots of each CASE.

    Returns:
        The pool slot index of the translated root.

    Raises:
        An error starting `UnsupportedByLowerUntypedExpr:` on any shape
        outside the subset in the module header.
    """
    return _translate_node(
        e, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
    )


# =============================================================================
# Per-tag dispatch
# =============================================================================


def _translate_node(
    e: Expr,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Tag-dispatch one Expr node.  Raises on out-of-scope tags."""
    if e.tag == EXPR_COL_REF:
        return _translate_col_ref(e, pool, col_name_to_idx, col_name_to_dtype)
    if e.tag == EXPR_LITERAL:
        return _translate_literal(e, pool, string_pool, decimal_pool)
    if e.tag == EXPR_BINARY_OP:
        return _translate_binary(
            e, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
    if e.tag == EXPR_UNARY_OP:
        return _translate_unary(
            e, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
    # An alias is a name only; the walker addresses columns by position, so
    # the child is translated in its place (nested aliases unwrap the same
    # way).
    if e.tag == EXPR_ALIAS:
        return _translate_node(
            e.alias_child_ref(),
            pool,
            col_name_to_idx,
            col_name_to_dtype,
            string_pool,
            decimal_pool,
            in_list_pool,
            when_pool,
        )
    if e.tag == EXPR_STRING_OP:
        return _translate_string_op(
            e, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
    # One EXPR_IN_LIST node; the walker dispatches on the column's type when
    # it evaluates, and handles an empty and a one-value list itself.
    if e.tag == EXPR_IN_LIST:
        return _translate_in_list(
            e, pool, col_name_to_idx, col_name_to_dtype, string_pool, decimal_pool, in_list_pool, when_pool
        )
    # Unary F64 math. SIN, COS, SQRT, ASIN and RADIANS have node kinds of
    # their own; every other op up to MATH_GAMMA rides the generic
    # EXPR_MATH_UNARY_F64, which carries the op code to the kernel's ladder.
    # An integer operand is widened by the F64 walker.
    if e.tag == EXPR_MATH_FN:
        var child_idx = _translate_node(
            e.math_fn_child_ref(), pool, col_name_to_idx, col_name_to_dtype,
            string_pool, decimal_pool, in_list_pool, when_pool,
        )
        var mop = e.math_fn_op()
        if mop == MATH_SIN:
            pool.append(make_sin_f64(child_idx))
        elif mop == MATH_COS:
            pool.append(make_cos_f64(child_idx))
        elif mop == MATH_SQRT:
            pool.append(make_sqrt_f64(child_idx))
        elif mop == MATH_ASIN:
            pool.append(make_asin_f64(child_idx))
        elif mop == MATH_RADIANS:
            pool.append(make_radians_f64(child_idx))
        elif mop <= MATH_GAMMA:
            # MATH_GAMMA is the top of the op space the kernel's ladder
            # names. That ladder's last branch is RADIANS, not a default, so
            # a code above it would be computed as a degrees-to-radians
            # conversion; the range check refuses it instead.
            pool.append(make_math_unary_f64(Int(mop), child_idx))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: unary math op "
                + String(Int(mop))
                + " is above MATH_GAMMA ("
                + String(Int(MATH_GAMMA))
                + "), the top of the op space the unary math kernel"
                + " covers. Add its branch there (and its `MATH_*` alias in"
                + " `komira_plan_expr.expr`) before lowering it here:"
                + " the kernel's last branch is RADIANS, not a default, so an"
                + " unnamed code would return a plausible wrong number."
            )
        return len(pool) - 1
    if e.tag == EXPR_MATH_FN2:
        var l_idx = _translate_node(
            e.math_fn2_left_ref(), pool, col_name_to_idx, col_name_to_dtype,
            string_pool, decimal_pool, in_list_pool, when_pool,
        )
        var r_idx = _translate_node(
            e.math_fn2_right_ref(), pool, col_name_to_idx, col_name_to_dtype,
            string_pool, decimal_pool, in_list_pool, when_pool,
        )
        var mop2 = e.math_fn2_op()
        if mop2 == MATH2_ATAN2:
            pool.append(make_atan2_f64(l_idx, r_idx))
        elif mop2 == MATH2_POW:
            pool.append(make_pow_f64(l_idx, r_idx))
        else:
            raise Error(
                "UnsupportedByLowerUntypedExpr: unknown binary math op "
                + String(Int(mop2))
            )
        return len(pool) - 1
    # CASE. Each condition is a Bool sub-tree; each THEN and the ELSE is a
    # value sub-tree translated at the CASE's output family, which is F64 when
    # any THEN or the ELSE is F64 and I64 otherwise. The branch slots flatten
    # into one `when_pool` entry, `[cond0, then0, ..., condK-1, thenK-1,
    # else]`, and the CASE node carries that entry's index in `col_idx`.
    if e.tag == EXPR_WHEN:
        var n_cases = e.when_num_cases()
        if n_cases <= 0:
            raise Error(
                "UnsupportedByLowerUntypedExpr: EXPR_WHEN with zero cases"
                + " (a CASE must carry at least one WHEN/THEN pair)."
            )
        var case_is_float = False
        for i in range(n_cases):
            if (
                _infer_runtime_dtype(e.when_case_result_ref(i), col_name_to_dtype)
                == RUNTIME_DTYPE_F64
            ):
                case_is_float = True
        if (
            _infer_runtime_dtype(e.when_default_ref(), col_name_to_dtype)
            == RUNTIME_DTYPE_F64
        ):
            case_is_float = True
        var slots = List[Int]()
        for i in range(n_cases):
            var cond_slot = _translate_node(
                e.when_case_condition_ref(i),
                pool,
                col_name_to_idx,
                col_name_to_dtype,
                string_pool,
                decimal_pool,
                in_list_pool,
                when_pool,
            )
            var then_slot = _translate_when_branch(
                e.when_case_result_ref(i),
                case_is_float,
                pool,
                col_name_to_idx,
                col_name_to_dtype,
                string_pool,
                decimal_pool,
                in_list_pool,
                when_pool,
            )
            slots.append(cond_slot)
            slots.append(then_slot)
        var else_slot = _translate_when_branch(
            e.when_default_ref(),
            case_is_float,
            pool,
            col_name_to_idx,
            col_name_to_dtype,
            string_pool,
            decimal_pool,
            in_list_pool,
            when_pool,
        )
        slots.append(else_slot)
        var when_idx = len(when_pool)
        when_pool.append(slots^)
        if case_is_float:
            pool.append(make_case_f64(when_idx))
        else:
            pool.append(make_case_i64(when_idx))
        return len(pool) - 1
    # CAST to FLOAT64, the widening direction only. Integer `/` truncates in
    # this engine, so a front end that wants SQL division wraps the left
    # operand in `CAST(x AS DOUBLE)`; this arm lowers that to
    # EXPR_I64_TO_F64. An F64 operand needs no node. The target is checked on
    # both its DType and its Arrow type, because a DECIMAL128 cast carries its
    # precision and scale in the Arrow slot. The narrowing direction (F64 to
    # I64) is not admitted: its rounding, overflow and TRY_CAST behaviour
    # would each need an answer this node does not give. The I64 family
    # includes DATE32 and TIMESTAMP columns, so their cast answers the stored
    # integer as a double. Any other target or operand falls to the raise
    # below.
    if e.tag == EXPR_CAST:
        if (
            e.cast_target() == DType.float64
            and e.cast_target_arrow() == ArrowType.FLOAT64
        ):
            var cast_child_family = _infer_runtime_dtype(
                e.cast_child_ref(), col_name_to_dtype
            )
            if cast_child_family == RUNTIME_DTYPE_F64:
                return _translate_node(
                    e.cast_child_ref(),
                    pool,
                    col_name_to_idx,
                    col_name_to_dtype,
                    string_pool,
                    decimal_pool,
                    in_list_pool,
                    when_pool,
                )
            if cast_child_family == RUNTIME_DTYPE_I64:
                var cast_child_slot = _translate_node(
                    e.cast_child_ref(),
                    pool,
                    col_name_to_idx,
                    col_name_to_dtype,
                    string_pool,
                    decimal_pool,
                    in_list_pool,
                    when_pool,
                )
                pool.append(make_i64_to_f64(cast_child_slot))
                return len(pool) - 1

    # Every other tag (EXPR_COL_IDX, any other cast, EXPR_REGEXP, the nested
    # and temporal extracts, aggregate and window calls, subqueries) has no
    # runtime node.
    raise Error(
        "UnsupportedByLowerUntypedExpr: Expr tag "
        + String(Int(e.tag))
        + " not in lower_untyped_expr in-scope subset (only "
        + "EXPR_COL_REF, EXPR_LITERAL, EXPR_BINARY_OP,"
        + " EXPR_UNARY_OP (NOT, IS [NOT] NULL over a string),"
        + " EXPR_ALIAS (transparent unwrap), EXPR_STRING_OP (LIKE family),"
        + " EXPR_IN_LIST, EXPR_MATH_FN, EXPR_MATH_FN2,"
        + " EXPR_WHEN (Bool conditions, I64/F64 branches)"
        + " and EXPR_CAST to FLOAT64 over an I64/F64 operand)."
    )


# =============================================================================
# CASE branch translation
# =============================================================================


def _translate_when_branch(
    e: Expr,
    case_is_float: Bool,
    mut pool: List[RuntimeExpr],
    col_name_to_idx: Dict[String, Int],
    col_name_to_dtype: Dict[String, Int],
    mut string_pool: List[String],
    mut decimal_pool: List[DecimalSpec],
    mut in_list_pool: List[List[ScalarValue]],
    mut when_pool: List[List[Int]],
) raises -> Int:
    """Translate one CASE THEN/ELSE branch at the CASE's output family.

    A branch outside the I64 and F64 families is refused. When the CASE is
    F64 and the branch is an I64-family sub-tree, the branch
    slot is wrapped in EXPR_I64_TO_F64 so the F64 walker reads a Float64 from
    every branch. (The F64 walker also widens a bare I64 leaf on its own; the
    wrap is the general form and gives the same value for those leaves.)
    """
    var branch_family = _infer_runtime_dtype(e, col_name_to_dtype)
    if branch_family != RUNTIME_DTYPE_I64 and branch_family != RUNTIME_DTYPE_F64:
        raise Error(
            "UnsupportedByLowerUntypedExpr: EXPR_WHEN branch is not in the"
            + " I64 or F64 family (family tag "
            + String(branch_family)
            + "); the CASE nodes carry integer and float branches only."
        )
    var slot = _translate_node(
        e,
        pool,
        col_name_to_idx,
        col_name_to_dtype,
        string_pool,
        decimal_pool,
        in_list_pool,
        when_pool,
    )
    if case_is_float and branch_family == RUNTIME_DTYPE_I64:
        pool.append(make_i64_to_f64(slot))
        return len(pool) - 1
    return slot


def count_and_conjuncts(pool: List[RuntimeExpr], root_idx: Int) -> Int:
    """Count the leaf conjuncts under an AND chain rooted at `root_idx`.

    A non-AND root counts 1; `AND(AND(p0, p1), AND(p2, p3))` counts 4. Reads
    `pool` only. The caller guarantees `0 <= root_idx < len(pool)`.
    """
    var node = pool[root_idx]
    if node.kind != EXPR_AND:
        return 1
    return count_and_conjuncts(pool, node.left) + count_and_conjuncts(
        pool, node.right
    )
