# =============================================================================
# project_ops: projection arms for binary and unary operators
# =============================================================================
#
# Arithmetic and comparison between columns and literals, and the unary
# operators (negation, NOT, the null tests and the numeric classifications).
# Each is one arm of `eval_column._eval_column_expr`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import (
    eval_add,
    eval_div,
    eval_mul,
    eval_not,
    eval_sub,
)
from komira_column_kernels.compiler_helpers import (
    broadcast_scalar,
    int64_to_float64,
    merge_binary_arith_validity,
)
from komira_column_kernels.interval_mdn_kernels import add_interval_mdn, eval_eq_interval_mdn, sub_interval_mdn
from komira_column_kernels.numeric_unary import (
    eval_bit_count_int,
    eval_numeric_unary_float,
    eval_numeric_unary_int,
    eval_sign_float,
    eval_sign_int,
    numeric_unary_kernel_tag,
)
from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_AND,
    BIN_DIV,
    BIN_EQ,
    BIN_MOD,
    BIN_MUL,
    BIN_NE,
    BIN_OR,
    BIN_SUB,
    EXPR_LITERAL,
    Expr,
    UN_ABS,
    UN_BIT_COUNT,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NEGATE,
    UN_NOT,
    UN_ROUND,
    UN_SIGN,
    UN_TRUNC,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.int_overflow import is_int_overflow_error

from .column_arith import _eval_binary_col_scalar, _mod_trunc_cc
from .column_compare import _eval_col_vs_col_promoted
from .column_decimal import _eval_decimal_binary_pair, _expr_name_hint
from .eval_column import _eval_column_expr
from .eval_predicate import (_eval_predicate)
from .predicate_logic import (_is_comparison_op)


def _project_binary_op(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_BINARY_OP` arm of `_eval_column_expr`."""
    var op = expr.binary_op()

    # ★★ BOOLEAN-VALUED BINARY OPS AS AN OUTPUT COLUMN.
    #
    # Everything below this block is an ARITHMETIC ladder: it dispatches
    # ADD/SUB/MUL/DIV per operand-type pair and raises on anything else.
    # So a comparison was executable as a FILTER PREDICATE and NOT as a
    # projection — `SELECT a > b` / `SELECT isfinite(v)` came back
    #
    #     unsupported float64 scalar binary op: 14     (BIN_GT, literal RHS)
    #     PipelineCompiler: unsupported float64 binary op: 14   (col-col)
    #
    # ⚠ THIS IS THE SAME DEFECT CLASS THE `EXPR_UNARY_OP` AND
    # `EXPR_IN_LIST` ARMS BELOW EACH CARRY A NOTE ABOUT: predicate-context
    # and projection-context dispatch are two ladders over one tag
    # universe, and `walk_expr_field` has typed every comparison and
    # AND/OR as BOOL "whatever their operands" since the two field-inference
    # copies converged. The TYPE half was armed; only the DATA half was not.
    #
    # ⛔ IT IS NOT A SECOND IMPLEMENTATION OF FLOAT COMPARISON, and it must
    # not become one. `_eval_predicate` reaches the same
    # `_col_cmp_nullable` / `kleene_cmp_finalize_scalar` seam the filter
    # path uses, which is the ONLY reason the NULL contract comes for free:
    # a row with a NULL operand comes back DATA BIT 0 with its validity bit
    # cleared, i.e. NULL rather than FALSE. DuckDB v1.5.3 propagates NULL
    # through `isfinite`/`isinf`/`isnan`, and a hand-rolled arm here would
    # have had to re-derive that.
    #
    # AND / OR first, and unconditionally: no arm anywhere below evaluates
    # a Bool ⊗ Bool pair, so this cannot take work away from one.
    if op == BIN_AND or op == BIN_OR:
        var logical_ba = _eval_predicate(expr, batch)
        return Column.from_boolean(logical_ba^)

    # --- Scalar-aware fast path ---
    # Detect when one operand is a literal to avoid materializing a full
    # N-element array for a constant value. Routes to SIMD scalar kernels
    # (eval_mul_scalar, eval_add_scalar, etc.) that broadcast the scalar
    # in registers — zero allocation, no memory bandwidth waste.
    var right_is_scalar = expr.binary_right_ref().tag == EXPR_LITERAL
    var left_is_scalar = expr.binary_left_ref().tag == EXPR_LITERAL

    # A comparison against a LITERAL — the shape `isfinite`/`isinf`/`isnan`
    # desugar to (`x > -inf`, `x < inf`, `x = inf`). Routed BEFORE the
    # arithmetic fast path because `_eval_binary_col_scalar` has no arm for
    # it; an INTERVAL_MDN operand cannot reach here (there is no interval
    # literal), so the eq/ne arm further down keeps its only caller.
    if _is_comparison_op(op) and (right_is_scalar or left_is_scalar):
        var cmp_lit_ba = _eval_predicate(expr, batch)
        return Column.from_boolean(cmp_lit_ba^)

    if right_is_scalar:
        var left_col = _eval_column_expr(expr.binary_left_ref(), batch)
        var sv = expr.binary_right_ref().literal_value()
        if left_col.arrow_type == ArrowType.DECIMAL128 or sv.is_decimal128():
            # ⭐ A DECIMAL ON EITHER SIDE OF A LITERAL:
            # `_eval_binary_col_scalar` has no decimal arm (`dc * 2` failed
            # with engine text `unsupported type 18`) and read a DECIMAL
            # literal through the wrong union member (`v + CAST(1 AS
            # DECIMAL(18,0))` answered 368934881474191032330). Broadcast the
            # literal and take the ONE decimal arm the column path takes.
            var rlit = broadcast_scalar(sv, left_col.length())
            return _eval_decimal_binary_pair(
                left_col, rlit, op, batch,
                _expr_name_hint(expr.binary_left_ref()), String(""),
            )
        return _eval_binary_col_scalar(left_col, op, sv)

    if left_is_scalar:
        var sv = expr.binary_left_ref().literal_value()
        var right_col = _eval_column_expr(expr.binary_right_ref(), batch)
        if right_col.arrow_type == ArrowType.DECIMAL128 or sv.is_decimal128():
            # The mirror of the arm above (`120 / dc`, `1 - dp`).
            var llit = broadcast_scalar(sv, right_col.length())
            return _eval_decimal_binary_pair(
                llit, right_col, op, batch,
                String(""), _expr_name_hint(expr.binary_right_ref()),
            )
        # For commutative ops, swap to col-scalar. For non-commutative, negate.
        if op == BIN_ADD or op == BIN_MUL:
            return _eval_binary_col_scalar(right_col, op, sv)
        elif op == BIN_SUB:
            # scalar - col, evaluated AS `scalar - col` (`eval_rsub_scalar`).
            #
            # ⛔ IT WAS `-(col - scalar)`, a negation by `eval_mul_scalar(-1)`,
            # and that rewrite was wrong three ways. (1) The fresh product
            # carried NO validity, so `100 - v` over a NULL row answered the
            # LITERAL (`proj_reflected_arith`;
            # `test_scalar_left_sub_keeps_nulls` pins it). (2) Once INT64
            # arithmetic RAISES on overflow, `-1 - MAX`
            # — whose answer MIN exists — raised, because `MAX - (-1)` does
            # not. (3) `1.0 - 1.0` answered -0.0. `_eval_binary_col_scalar`
            # clones the column's validity onto the result, as for every op.
            return _eval_binary_col_scalar(right_col, BIN_SUB, sv, True)
        # Fallthrough for scalar / col — use broadcast path below

    # --- Column-column path (both sides are column expressions) ---
    var left_col = _eval_column_expr(expr.binary_left_ref(), batch)
    var right_col = _eval_column_expr(expr.binary_right_ref(), batch)

    # The col-col half of the boolean-op block above. `_eval_col_vs_col_
    # promoted` is the SAME entry point `_eval_predicate`'s computed-operand
    # path uses, so the operands are consumed once and the promotion rules
    # (FLOAT64 ⊕ INT64 → FLOAT64, INT64 ⊕ INT32 → INT64) are stated in one
    # place. Calling `_eval_predicate` here instead would evaluate both
    # subtrees a SECOND time.
    #
    # ⚠ THE INTERVAL_MDN PAIR IS EXCLUDED BY NAME and must stay excluded:
    # its `BIN_EQ`/`BIN_NE` arm below is the only thing that serves it
    # (`_eval_col_vs_col_promoted` refuses the type), and
    # `test_arrow_nested_compute_x4_interval_mdn_engine` T9 drives exactly
    # that shape through THIS function.
    if _is_comparison_op(op) and not (
        left_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
        or right_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
    ):
        var cmp_cc_ba = _eval_col_vs_col_promoted(
            left_col^, right_col^, op
        )
        return Column.from_boolean(cmp_cc_ba^)

    # Determine type and perform arithmetic.
    # NOTE: the SIMD arithmetic kernels
    # are pure compute (no validity touch) — they allocate a fresh
    # result with no null mask. Nullable arithmetic must produce NULL
    # wherever either input is NULL, so we merge AND(left.validity,
    # right.validity) onto `result` and recompute null_count before
    # wrapping. `merge_binary_arith_validity` is a no-op when neither
    # input has validity (the common case — zero cost on the hot path).
    if left_col.arrow_type == ArrowType.INT64 and right_col.arrow_type == ArrowType.INT64:
        var left_arr = left_col.as_primitive[DType.int64]()
        var right_arr = right_col.as_primitive[DType.int64]()
        var result: PrimitiveArray[DType.int64]
        if op == BIN_ADD:
            result = eval_add[DType.int64](left_arr, right_arr)
        elif op == BIN_SUB:
            result = eval_sub[DType.int64](left_arr, right_arr)
        elif op == BIN_MUL:
            result = eval_mul[DType.int64](left_arr, right_arr)
        elif op == BIN_DIV:
            result = eval_div[DType.int64](left_arr, right_arr)
        elif op == BIN_MOD:
            result = _mod_trunc_cc[DType.int64](left_arr, right_arr)
        else:
            raise Error("PipelineCompiler: unsupported int64 binary op: " + String(Int(op)))
        merge_binary_arith_validity[DType.int64](left_col, right_col, result)
        return Column.from_primitive[DType.int64](result)

    elif left_col.arrow_type == ArrowType.FLOAT64 and right_col.arrow_type == ArrowType.FLOAT64:
        var left_arr = left_col.as_primitive[DType.float64]()
        var right_arr = right_col.as_primitive[DType.float64]()
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add[DType.float64](left_arr, right_arr)
        elif op == BIN_SUB:
            result = eval_sub[DType.float64](left_arr, right_arr)
        elif op == BIN_MUL:
            result = eval_mul[DType.float64](left_arr, right_arr)
        elif op == BIN_DIV:
            result = eval_div[DType.float64](left_arr, right_arr)
        elif op == BIN_MOD:
            result = _mod_trunc_cc[DType.float64](left_arr, right_arr)
        else:
            raise Error("PipelineCompiler: unsupported float64 binary op: " + String(Int(op)))
        merge_binary_arith_validity[DType.float64](left_col, right_col, result)
        return Column.from_primitive[DType.float64](result)

    elif left_col.arrow_type == ArrowType.INT64 and right_col.arrow_type == ArrowType.FLOAT64:
        # Promote left int64 to float64
        var left_arr = left_col.as_primitive[DType.int64]()
        var right_arr = right_col.as_primitive[DType.float64]()
        # Cast left to float64
        var left_f64 = int64_to_float64(left_arr)
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add[DType.float64](left_f64, right_arr)
        elif op == BIN_SUB:
            result = eval_sub[DType.float64](left_f64, right_arr)
        elif op == BIN_MUL:
            result = eval_mul[DType.float64](left_f64, right_arr)
        elif op == BIN_DIV:
            result = eval_div[DType.float64](left_f64, right_arr)
        elif op == BIN_MOD:
            result = _mod_trunc_cc[DType.float64](left_f64, right_arr)
        else:
            raise Error("PipelineCompiler: unsupported mixed binary op: " + String(Int(op)))
        merge_binary_arith_validity[DType.float64](left_col, right_col, result)
        return Column.from_primitive[DType.float64](result)

    elif left_col.arrow_type == ArrowType.FLOAT64 and right_col.arrow_type == ArrowType.INT64:
        # Promote right int64 to float64
        var left_arr = left_col.as_primitive[DType.float64]()
        var right_arr = right_col.as_primitive[DType.int64]()
        var right_f64 = int64_to_float64(right_arr)
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add[DType.float64](left_arr, right_f64)
        elif op == BIN_SUB:
            result = eval_sub[DType.float64](left_arr, right_f64)
        elif op == BIN_MUL:
            result = eval_mul[DType.float64](left_arr, right_f64)
        elif op == BIN_DIV:
            result = eval_div[DType.float64](left_arr, right_f64)
        elif op == BIN_MOD:
            result = _mod_trunc_cc[DType.float64](left_arr, right_f64)
        else:
            raise Error("PipelineCompiler: unsupported mixed binary op: " + String(Int(op)))
        merge_binary_arith_validity[DType.float64](left_col, right_col, result)
        return Column.from_primitive[DType.float64](result)

    elif left_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO and right_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO:
        # INTERVAL_MONTH_DAY_NANO componentwise
        # add/sub.  Per Arrow spec (Schema.fbs IntervalUnit::MONTH_DAY_NANO),
        # each field is independent; result Column carries
        # ArrowType.INTERVAL_MONTH_DAY_NANO.  Validity AND'd by the kernel.
        var l_arr = left_col.as_interval_mdn()
        var r_arr = right_col.as_interval_mdn()
        if op == BIN_ADD:
            var result = add_interval_mdn(l_arr, r_arr)
            return Column.from_interval_mdn(result^)
        elif op == BIN_SUB:
            var result = sub_interval_mdn(l_arr, r_arr)
            return Column.from_interval_mdn(result^)
        elif op == BIN_EQ:
            var bm = eval_eq_interval_mdn(l_arr, r_arr)
            # Wrap Bitmap into a BooleanArray-backed column.
            var ba = BooleanArray.from_bitmap(bm^)
            return Column.from_boolean(ba^)
        elif op == BIN_NE:
            var bm = eval_eq_interval_mdn(l_arr, r_arr)
            var ba = BooleanArray.from_bitmap(bm^)
            return Column.from_boolean(eval_not(ba))
        else:
            raise Error(
                "PipelineCompiler: INTERVAL_MONTH_DAY_NANO supports only"
                " add/sub/eq/ne; Arrow spec does not define ordering on"
                " this type (got op=" + String(Int(op)) + ")"
            )

    elif left_col.arrow_type == ArrowType.DECIMAL128 or right_col.arrow_type == ArrowType.DECIMAL128:
        return _eval_decimal_binary_pair(
            left_col,
            right_col,
            op,
            batch,
            _expr_name_hint(expr.binary_left_ref()),
            _expr_name_hint(expr.binary_right_ref()),
        )

    else:
        raise Error(
            "PipelineCompiler: unsupported column types for binary op: "
            + String(left_col.arrow_type) + " and " + String(right_col.arrow_type)
        )


def _project_unary_op(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_UNARY_OP` arm of `_eval_column_expr`."""
    # ★ THE PROJECTION ARM FOR `NOT x` / `-x`. `EXPR_UNARY_OP` has a
    # PREDICATE arm (`eval_predicate._eval_predicate`); without a
    # PROJECTION arm, `SELECT NOT flag` / `SELECT -x` raised
    # "unsupported projection expression tag: 4" — and BOTH output-field
    # inference copies were also unarmed, so even once the data existed
    # the column would have exported as Arrow type `null`.
    #
    # ⚠ THIS IS THE SAME DEFECT CLASS IN A THIRD LADDER, and it has bitten
    # here before: the EXPR_IN_LIST arm below carries the identical story
    # ("had a predicate-context arm ... but was missing from the
    # projection-context dispatch"). Predicate-context and
    # projection-context dispatch are two ladders over one tag universe;
    # a tag armed in one is not armed in the other.
    var uop = expr.unary_op()
    if uop == UN_NOT:
        # Element-wise logical NOT over a BOOL column. The child must
        # evaluate to a Bool COLUMN — `NOT (a > b)` is a comparison in
        # projection context, which this ladder does not evaluate
        # (arithmetic only), and raises in the child call with its own
        # message rather than silently here.
        var child_col = _eval_column_expr(expr.unary_child_ref(), batch)
        var child_ba = child_col.as_boolean()
        return Column.from_boolean(eval_not(child_ba))
    elif uop == UN_NEGATE:
        # `-x` is `x * -1` — routed through the SAME tested scalar path
        # the BIN_SUB scalar-swap above uses, so it inherits that path's
        # validity preservation (`clone_array_validity`) and its INT32 /
        # INT64 / FLOAT64 width rules for free. Deliberately NOT a
        # hand-rolled negate loop: a second implementation of a width
        # rule is how the widths drift apart.
        #
        # ⛔ `-MIN` OVERFLOWS: the checked `* -1`
        # raises, and the raise is re-worded to DuckDB 1.5.3's own sentence
        # for a NEGATION (`Out of Range Error: Overflow in negation of
        # numeric value!`, measured) rather than the multiplication this arm
        # happens to be spelled as.
        var neg_child = _eval_column_expr(expr.unary_child_ref(), batch)
        try:
            return _eval_binary_col_scalar(
                neg_child, BIN_MUL, ScalarValue.from_int(-1)
            )
        except err:
            if is_int_overflow_error(String(err)):
                raise Error(
                    "Out of Range Error: Overflow in negation of numeric value!"
                )
            raise err^
    elif (
        uop == UN_ABS or uop == UN_SIGN
        or uop == UN_TRUNC or uop == UN_ROUND
        or uop == UN_BIT_COUNT
    ):
        # `abs` / `sign` / `trunc` / `round`.
        #
        # THE OUTPUT WIDTH IS THE INPUT WIDTH (except `sign`, which is
        # INT8 always), and this dispatch is the DATA half of a pair whose
        # TYPE half is `walk_expr_field`'s EXPR_UNARY_OP arm. The two must
        # agree column by column — `test_projection_type_matches_data` is
        # what says so, and it is the reason a widening "just promote to
        # FLOAT64 and be done" arm is NOT written here: that would compute
        # a correct VALUE under a schema that declares a different TYPE,
        # which is the shape the Arrow C-ABI export refuses.
        var num_child = _eval_column_expr(expr.unary_child_ref(), batch)
        var knum = numeric_unary_kernel_tag(uop)
        var nat = num_child.arrow_type
        if uop == UN_BIT_COUNT:
            # INT8 out for every width, like
            # `sign` — but the VALUE depends on the operand's width, so
            # each width goes to the kernel instantiated at THAT width.
            #
            # ⛔ NO FLOAT ARM, AND THAT IS THE POINT. DuckDB v1.5.3 has
            # FIVE integer overloads of `bit_count` and NO floating one:
            # `SELECT bit_count(1.5)` is a BINDER ERROR there. Casting a
            # FLOAT column to an integer here would
            # answer a number for an expression the oracle refuses to run,
            # which is worse than the raise below — so a FLOAT operand
            # falls through to the error and names the cast the caller has
            # to write themselves.
            if nat == ArrowType.INT64:
                return Column.from_primitive[DType.int8](
                    eval_bit_count_int[DType.int64](
                        num_child.as_primitive[DType.int64]()
                    )
                )
            elif nat == ArrowType.INT32:
                return Column.from_primitive[DType.int8](
                    eval_bit_count_int[DType.int32](
                        num_child.as_primitive[DType.int32]()
                    )
                )
            elif nat == ArrowType.INT16:
                return Column.from_primitive[DType.int8](
                    eval_bit_count_int[DType.int16](
                        num_child.as_primitive[DType.int16]()
                    )
                )
            elif nat == ArrowType.INT8:
                return Column.from_primitive[DType.int8](
                    eval_bit_count_int[DType.int8](
                        num_child.as_primitive[DType.int8]()
                    )
                )
            raise Error(
                "PipelineCompiler: bit_count() supports INT8 / INT16 /"
                " INT32 / INT64 columns; got arrow type "
                + String(Int(nat.type_id))
                + ". DuckDB v1.5.3 has NO floating or decimal overload of"
                " bit_count -- bit_count(1.5) is a bind error there -- so"
                " this engine refuses rather than casting. CAST the column"
                " to BIGINT if a popcount over its integer value is what"
                " you want; the answer then counts 64 bits, not the"
                " column's original width."
            )
        if uop == UN_SIGN:
            if nat == ArrowType.FLOAT64:
                return Column.from_primitive[DType.int8](
                    eval_sign_float[DType.float64](
                        num_child.as_primitive[DType.float64]()
                    )
                )
            elif nat == ArrowType.FLOAT32:
                return Column.from_primitive[DType.int8](
                    eval_sign_float[DType.float32](
                        num_child.as_primitive[DType.float32]()
                    )
                )
            elif nat == ArrowType.INT64:
                return Column.from_primitive[DType.int8](
                    eval_sign_int[DType.int64](
                        num_child.as_primitive[DType.int64]()
                    )
                )
            elif nat == ArrowType.INT32:
                return Column.from_primitive[DType.int8](
                    eval_sign_int[DType.int32](
                        num_child.as_primitive[DType.int32]()
                    )
                )
            elif nat == ArrowType.INT16:
                return Column.from_primitive[DType.int8](
                    eval_sign_int[DType.int16](
                        num_child.as_primitive[DType.int16]()
                    )
                )
            elif nat == ArrowType.INT8:
                return Column.from_primitive[DType.int8](
                    eval_sign_int[DType.int8](
                        num_child.as_primitive[DType.int8]()
                    )
                )
            raise Error(
                "PipelineCompiler: sign() supports INT8 / INT16 / INT32 /"
                " INT64 / FLOAT32 / FLOAT64 columns; got arrow type "
                + String(Int(nat.type_id))
                + ". DECIMAL128 has its own arithmetic module and no"
                " sign kernel yet — CAST to DOUBLE to get DuckDB's value,"
                " which is TINYINT either way."
            )
        if nat == ArrowType.FLOAT64:
            return Column.from_primitive[DType.float64](
                eval_numeric_unary_float[DType.float64](
                    knum, num_child.as_primitive[DType.float64]()
                )
            )
        elif nat == ArrowType.FLOAT32:
            return Column.from_primitive[DType.float32](
                eval_numeric_unary_float[DType.float32](
                    knum, num_child.as_primitive[DType.float32]()
                )
            )
        elif nat == ArrowType.INT64:
            return Column.from_primitive[DType.int64](
                eval_numeric_unary_int[DType.int64](
                    knum, num_child.as_primitive[DType.int64]()
                )
            )
        elif nat == ArrowType.INT32:
            return Column.from_primitive[DType.int32](
                eval_numeric_unary_int[DType.int32](
                    knum, num_child.as_primitive[DType.int32]()
                )
            )
        elif nat == ArrowType.INT16:
            return Column.from_primitive[DType.int16](
                eval_numeric_unary_int[DType.int16](
                    knum, num_child.as_primitive[DType.int16]()
                )
            )
        elif nat == ArrowType.INT8:
            return Column.from_primitive[DType.int8](
                eval_numeric_unary_int[DType.int8](
                    knum, num_child.as_primitive[DType.int8]()
                )
            )
        # ⛔ A NAMED REFUSAL, NOT A PROMOTION. Promoting a DECIMAL128 to
        # FLOAT64 here would answer a query DuckDB answers in DECIMAL, and
        # `walk_expr_field` has already declared DECIMAL128 for it — so
        # the promotion would be a schema/data disagreement on top of a
        # precision loss. The user's fix is one CAST and it is stated.
        raise Error(
            "PipelineCompiler: abs() / trunc() / round() support INT8 /"
            " INT16 / INT32 / INT64 / FLOAT32 / FLOAT64 columns; got"
            " arrow type " + String(Int(nat.type_id))
            + ". These are TYPE-PRESERVING functions, so a DECIMAL128"
            " operand needs a DECIMAL128 kernel (not yet written) rather"
            " than a promotion — CAST to DOUBLE if a DOUBLE answer is"
            " acceptable."
        )

    elif uop == UN_IS_NULL or uop == UN_IS_NOT_NULL:
        # ★★ `SELECT x IS NULL AS is_missing`. The kernel is reached
        # through `from .eval_predicate import _eval_predicate,
        # _is_comparison_op` at the top of this file — the same import the
        # `EXPR_BINARY_OP` arm delegates AND/OR and the six comparisons
        # through — so there is no cycle to defend and no reason to refuse
        # `x IS NULL` in a SELECT list.
        #
        # ⛔ STILL NOT A SECOND COPY, AND THAT IS THE WHOLE POINT. The
        # validity-bitmap -> BooleanArray conversion is intricate (a
        # bytewise `~validity`, a trailing-bit mask so the slack bits of the
        # last byte are not phantom nulls, and a separate general-child
        # fallback that materialises a computed child) and it lives in ONE
        # place. `_eval_predicate` is handed THIS node, unchanged, so both
        # polarities and the COL_REF fast path come across intact.
        #
        # ⚠ THE DECLARED TYPE ALREADY AGREED: `walk_expr_field`'s
        # EXPR_UNARY_OP arm has typed these BOOL (and NON-nullable — `x IS
        # NULL` is total). The TYPE half was armed and only
        # the DATA half was not, which is this file's recurring shape: a
        # predicate-context ladder and a projection-context ladder over one
        # tag universe.
        var null_ba = _eval_predicate(expr, batch)
        return Column.from_boolean(null_ba^)
    else:
        raise Error(
            "PipelineCompiler: unknown unary op in projection: "
            + String(Int(uop))
        )
