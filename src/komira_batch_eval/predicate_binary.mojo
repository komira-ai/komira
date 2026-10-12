# =============================================================================
# predicate_binary: the predicate arm for binary operators
# =============================================================================
#
# Comparisons of a column (or a computed operand) against a literal or another
# column, and AND/OR, which delegate to the short-circuit evaluators. One arm
# of `eval_predicate._eval_predicate`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.schema import RecordBatch
from komira_column_kernels.compiler_helpers import (
    broadcast_scalar,
    copy_column,
    expr_resolves_to_column,
    resolve_col_index,
)
from komira_column_kernels.dict_filter import (
    DictFilterOp,
    dict_filter_eval_bool_mask,
    dict_filter_eval_bool_mask_column,
)
from komira_column_kernels.string_comparison import (
    eval_large_string_eq,
    eval_large_string_ge,
    eval_large_string_gt,
    eval_large_string_le,
    eval_large_string_lt,
    eval_large_string_ne,
    eval_string_eq,
    eval_string_ge,
    eval_string_gt,
    eval_string_le,
    eval_string_lt,
    eval_string_ne,
)
from komira_kernels.comparison_kleene import (
    NullPolicy,
    kleene_all_null_predicate,
    kleene_cmp_finalize_scalar,
)
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    EXPR_COL_REF,
    Expr,
)

from .column_compare import _eval_col_vs_col_promoted
from .eval_column import _eval_column_expr
from .integer_literal_value import (
    integer_literal_value,
    mirror_comparison,
    number_dtype_of,
    read_integer_literal_for_column,
)
from .literal_arm_domain import check_literal_against_column
from .predicate_compare import (
    _eval_bool_col_vs_literal,
    _eval_col_vs_col,
    _eval_decimal_col_vs_col,
    _eval_decimal_col_vs_literal,
    _eval_float32_col_vs_literal,
    _eval_narrow_int_arm,
    _eval_temporal_col_vs_literal,
    _scalar_cmp,
    _scalar_cmp_i32_widening,
)
from .predicate_logic import (
    USE_KERNEL_COMPTIME_FILTER,
    _broadcast_to_array_float64,
    _broadcast_to_array_int64,
    _dispatch_float64_via_kernel,
    _dispatch_int64_via_kernel,
    _eval_short_circuit_and,
    _eval_short_circuit_or,
    _is_comparison_op,
    _u64_cmp_vs_float_literal,
)
from .predicate_numeric_dict import _numeric_dict_filter_dispatch
from .string_bytes import string_array_of


def _predicate_binary_op(expr: Expr, batch: RecordBatch) raises -> BooleanArray:
    """The `EXPR_BINARY_OP` arm of `_eval_predicate`."""
    var op = expr.binary_op()

    # Logical AND/OR: delegate to the short-circuit evaluators
    # implementations). PERF-CRITICAL: sub-trees of OR/NOT predicates that
    # the conjunction-flattener can't see still benefit from the four-case
    # selective evaluation (skip-right-when-left-all-false, etc.).
    if op == BIN_AND:
        return _eval_short_circuit_and(
            expr.binary_left_ref(), expr.binary_right_ref(), batch
        )

    if op == BIN_OR:
        return _eval_short_circuit_or(
            expr.binary_left_ref(), expr.binary_right_ref(), batch
        )

    # the LHS of a comparison
    # may itself be a compound expression, e.g. `a * b > 100` (the shared
    # `a * b` subtree the CSE demo produces when Axis-2 CSE does not fire
    # because the subtree is only depth-2). Gap C generalized
    # the *RHS* to accept an arbitrary Expr but left the LHS assuming a bare
    # column — so `resolve_col_index(binary_left_ref)` below raised
    # "cannot resolve column index from expression tag: 3" for any
    # non-column LHS. Mirror Gap C here for the LHS: when the left side does
    # NOT resolve to a column, materialize BOTH sides into columns and route
    # through `_eval_col_vs_col_promoted` (SQL-standard numeric promotion).
    # This is general for any comparison whose operands are arbitrary
    # arithmetic expressions, not just the N-conjunct-shared-subtree shape.
    if _is_comparison_op(op) and not expr_resolves_to_column(
        expr.binary_left_ref()
    ):
        # ★ A BARE INTEGER LITERAL ON THE **LEFT** (`3 < v`). It would be
        # materialized by `_eval_column_expr` -> `broadcast_scalar`, whose
        # arms test `dtype == int64 / float64 / int32 / float32` and turn
        # every OTHER integer tag into a column of INT64 ZEROS — measured
        # `f64 [0.5,3,10]  3 (uint8) < v  ->  011`, want 001. `lit OP v` is
        # `v MIRROR(OP) lit`, so the literal is read by THE ONE RULE at the
        # other side's type, exactly as the right-literal path below does,
        # and only then broadcast.
        ref lhs_lit_ref = expr.binary_left_ref()
        if lhs_lit_ref.is_literal():
            var llit = lhs_lit_ref.literal_value()
            if llit.is_any_integer():
                var rcol = _eval_column_expr(expr.binary_right_ref(), batch)
                var mop = mirror_comparison(op)
                read_integer_literal_for_column(
                    number_dtype_of(rcol.arrow_type), llit, mop
                )
                var lcol = broadcast_scalar(llit, batch.num_rows())
                return _eval_col_vs_col_promoted(
                    lcol^, rcol^, mirror_comparison(mop)
                )
        var lhs_col = _eval_column_expr(expr.binary_left_ref(), batch)
        ref rhs_ref = expr.binary_right_ref()
        if rhs_ref.is_literal():
            var rhs_lit = rhs_ref.literal_value()
            # `<expr> OP NULL` is NULL for every row under SQL 3VL. Mirrors
            # the bare-column `col OP NULL` gate below — see it for why the
            # answer is ALL-NULL and not all-FALSE.
            if rhs_lit.is_null():
                return kleene_all_null_predicate(
                    batch.num_rows(), NullPolicy.three_valued()
                )
            # ★ A COMPUTED **STRING** LHS, WHICH `_eval_col_vs_col_promoted`
            # REFUSES BY NAME ("unsupported same-type pair: string"), so
            # without a computed-operand arm NO computed string
            # predicate was executable AT ALL — not `upper(name) = 'ACME'`,
            # and not `substring(c_phone, 1, 2) = '13'`, which has been
            # buildable and unrunnable in a WHERE ever
            # since. The promotion helper is about NUMERIC widening and has
            # no business growing a string arm; the right kernels already
            # exist one screen down, where a BARE string column meets a
            # string literal, and they carry the NULL contract
            # (`_apply_validity`) with them.
            #
            # ⚠ THE OPERAND ORDER IS NOT SYMMETRIC AND IS NOT CHECKED BY
            # THESE KERNELS. They are `column OP scalar`; the LHS here is
            # the computed column and the RHS the literal, which is the
            # order the caller already has, so `>` stays `>`. Reversing the
            # pair silently inverts every inequality.
            var lhs_at = lhs_col.arrow_type
            if lhs_at == ArrowType.STRING and rhs_lit.is_string():
                var lhs_sa = string_array_of(lhs_col)
                var rhs_str = rhs_lit.string_val
                if op == BIN_EQ:
                    return eval_string_eq(lhs_sa, rhs_str)
                elif op == BIN_NE:
                    return eval_string_ne(lhs_sa, rhs_str)
                elif op == BIN_GT:
                    return eval_string_gt(lhs_sa, rhs_str)
                elif op == BIN_LT:
                    return eval_string_lt(lhs_sa, rhs_str)
                elif op == BIN_GE:
                    return eval_string_ge(lhs_sa, rhs_str)
                elif op == BIN_LE:
                    return eval_string_le(lhs_sa, rhs_str)
                else:
                    raise Error(
                        "PipelineCompiler: unsupported comparison op for a"
                        + " computed string LHS: " + String(Int(op))
                    )
            # ★ THE ONE RULE, at the COMPUTED column's type, BEFORE the
            # broadcast. `broadcast_scalar` knows int64/float64/int32/
            # float32 tags and makes every other integer tag an INT64 ZERO
            # (measured: `f64 (v + 0.0) > 3 (uint8)` answered 111, want
            # 001; `i64 (v + 0) > 2**64-1 (uint64)` answered 001, want
            # 000). After this call the literal is int64- or float64-tagged,
            # or its above-the-domain comparison has been rewritten.
            var cop = op
            read_integer_literal_for_column(
                number_dtype_of(lhs_col.arrow_type), rhs_lit, cop
            )
            var rhs_col = broadcast_scalar(rhs_lit.copy(), batch.num_rows())
            return _eval_col_vs_col_promoted(lhs_col^, rhs_col^, cop)
        var rhs_expr_col = _eval_column_expr(rhs_ref, batch)
        return _eval_col_vs_col_promoted(lhs_col^, rhs_expr_col^, op)

    # Comparison: column op literal OR column op column OR column op <expr>
    # Resolve column index from left side
    var col_idx = resolve_col_index(expr.binary_left_ref(), batch.schema)
    ref col_ptr = batch.column_at(col_idx)
    var col_at = col_ptr.arrow_type

    # PERF-CRITICAL: column-vs-column comparison support.
    # Enables the decorrelation pattern (join-back + col-vs-col filter)
    # that eliminates correlated subqueries in Q17/Q20. Without this,
    # the engine must fall back to manual loops with double scans.
    # NOTE: same-type col-vs-col still fast-paths
    # through `_eval_col_vs_col`; mixed-type col-vs-col falls through
    # to the general RHS path below for promotion.
    if expr.binary_right_ref().tag == EXPR_COL_REF:
        var right_idx = resolve_col_index(expr.binary_right_ref(), batch.schema)
        ref right_col_ref = batch.column_at(right_idx)
        if col_at == ArrowType.DECIMAL128 and right_col_ref.arrow_type == ArrowType.DECIMAL128:
            # scale-aligned col-vs-col compare.
            return _eval_decimal_col_vs_col(batch, col_idx, right_idx, op)
        if right_col_ref.arrow_type == col_at:
            return _eval_col_vs_col(batch, col_idx, right_idx, col_at, op)
        # Mixed types — fall through to the general path with promotion.

    # General RHS path — accept arbitrary Expr on
    # the RHS (EXPR_BINARY_OP, EXPR_CAST, EXPR_UNARY_OP, …) by
    # materializing it through `_eval_column_expr`. Routes into
    # `_eval_col_vs_col_promoted`, which handles SQL-standard
    # numeric promotion (INT64 vs FLOAT64, INT32 vs INT64, …).
    # Pre-Gap-C this path raised "predicate RHS must be a literal
    # (got tag=3)" and forced bench-side `with_column` workarounds
    # for shapes like `col("ps_availqty") > col("qty_sum") * 0.5`.
    if not expr.binary_right_ref().is_literal():
        var rhs_col = _eval_column_expr(expr.binary_right_ref(), batch)
        return _eval_col_vs_col_promoted(
            copy_column(batch, col_idx), rhs_col^, op
        )

    var lit_val = expr.binary_right_ref().literal_value()

    # `col OP NULL` is
    # NULL for every row under SQL 3VL, so the predicate never holds ->
    # drop all rows. Without this gate the int/float arms below read
    # `lit_val.int_val` / `.float_val` (both 0 for a typed null) and
    # WRONGLY compared `col == 0` — e.g. `x = (SELECT max(y) FROM empty)`
    # (an empty scalar subquery resolves to a NULL literal) matched the
    # x=0 rows.
    #
    # ⛔ ALL-**NULL**, NOT ALL-FALSE (three-valued logic). A bare
    # `Bitmap.create(n)` with no validity is
    # the right ROW SET for a bare WHERE and the wrong VALUE for anything
    # that reads it: `NOT (x = NULL)` became TRUE on every row (DuckDB:
    # NULL, nothing selected), and the projection arm routes every
    # comparison against a literal through here, so `x = NULL` projected
    # FALSE. SQL's `x NOT IN (1, NULL)` desugars to exactly that NOT. The
    # decimal arm (`_eval_decimal_col_vs_literal`) already answered
    # `kleene_all_null_predicate`; now both do.
    # Falsifier: `komira_batch_eval/tests/test_null_literal_comparison_is_null.mojo`.
    if lit_val.is_null():
        return kleene_all_null_predicate(
            batch.num_rows(), NullPolicy.three_valued()
        )

    # route temporal comparisons to
    # the dedicated helper BEFORE the numeric arms. Fires when EITHER the
    # column is a temporal int-storage type (DATE32/DATE64/TIMESTAMP*/TIME*/
    # DURATION*) OR the literal is a temporal scalar (date32/timestamp) — the
    # latter catches the LIVE bug where a physically-INT32-stamped date column
    # + a date32 literal would otherwise hit the INT32 arm and read int_val==0
    # (all-false). A plain int column + int literal is NOT temporal on either
    # side, so it stays on the fast int arm below (no behavior change). See
    # `_eval_temporal_col_vs_literal` for the full root-cause narrative.
    var col_is_temporal_intlike = (
        col_at == ArrowType.DATE32
        or col_at == ArrowType.DATE64
        or col_at.is_timestamp()
        or col_at.is_time()
        or col_at.is_duration()
    )
    if (
        col_is_temporal_intlike
        or lit_val.is_date32()
        or lit_val.is_timestamp()
    ):
        return _eval_temporal_col_vs_literal(
            batch, col_idx, lit_val, op, col_at
        )

    # =====================================================================
    # ★★ EVAL_INCOMPARABLE_LITERAL — THE
    #    ARM LADDER BELOW SELECTS A `ScalarValue` FIELD FROM THE COLUMN'S
    #    TYPE ALONE, AND AN UNPOPULATED FIELD READS AS A WELL-FORMED ZERO.
    # =====================================================================
    #
    # MEASURED: `WHERE l_shipmode > 5` over a 210-row fixture answered
    # `count = 210` — the WHOLE TABLE. Not a dropped predicate: the STRING
    # arm 130 lines below read `lit_val.string_val`, which is `""` for a
    # literal built by `ScalarValue.from_int(5)`, and evaluated
    # `l_shipmode > ''` — true for every non-empty string. The same read
    # makes `l_shipmode < 5` answer ZERO rows. Both are silent wrong
    # answers, and under the rule "slower OK, wrong not" neither is
    # admissible.
    #
    # ⚠ IT GOES **AFTER** THE TEMPORAL DISPATCH ON PURPOSE. A temporal
    # column takes `_eval_temporal_col_vs_literal` on the strength of the
    # COLUMN alone and legitimately reads an INTEGER literal (a DATE32
    # column is int32 days-since-epoch); refusing before that routing would
    # delete a working query. See `plan_wire_values.
    # _temporal_column_reads_int_literal` for the measurement that made the
    # plan-wire door stop refusing that same pair.
    #
    # ⚠ THE REFUSAL IS THE EXECUTOR'S OWN AND ITS TOKEN IS NOT THE DOOR'S.
    # `plan_wire_values._refuse_if_incomparable` already refuses this pair
    # with `PLAN_WIRE_INCOMPARABLE_LITERAL` on the PLAN-WIRE ingress, which
    # is why the DataFrame spellings are graded CLEAR-ERROR and the SQL one
    # (`komira_sql_stream`, a different ingress with no such walk) was
    # not. See `literal_arm_domain.mojo`'s header.
    check_literal_against_column(
        col_at,
        lit_val,
        col_ptr.is_numeric_dict(),
        String("filter predicate"),
    )

    # =====================================================================
    # ★★ THE ONE RULE — AN INTEGER LITERAL'S VALUE IS READ BY ITS **TAG**
    #    (`integer_literal_value.mojo`; the semantics and the DuckDB
    #    measurements behind them are in that module's header).
    # =====================================================================
    #
    # Every arm below picks the `ScalarValue` field it reads from the
    # COLUMN. For an integer literal that was right only for the tags each
    # arm happened to expect. Without the decode:
    #   int64 col [-5,0,3,MAX]  v > 2**64-1 (uint64)  -> 0111, want 0000
    #   f64   col [0.5,3,10]    v > 3 (uint8)         -> 111,  want 001
    # — a uint64 above Int64.MAX read SIGNED, and the FLOAT64 promotion an
    # ALLOW-LIST over the literal's tag (int64/int32) with every other tag
    # falling through to `float_val`, a well-formed ZERO. After this call
    # an integer literal is, for the arm about to read it: a FLOAT literal
    # holding DuckDB's cast to the column's float type (FLOAT64/FLOAT32
    # and float dictionaries); an INT64-tagged literal of the same value
    # (every integer column but UINT64), with a value above the column's
    # whole domain rewritten to `v <= Int64.MAX` / `v > Int64.MAX`; or,
    # for UINT64, untouched — that arm decodes the tag itself below.
    #
    # ⚠ AFTER `check_literal_against_column`, so a pair with no arm is still
    # refused by that check's own token, and AFTER the temporal routing, so
    # a DATE32 column's int literal is still days-since-epoch.
    var lit_value_dt = number_dtype_of(col_at)
    if col_at == ArrowType.DICTIONARY and col_ptr.is_numeric_dict():
        lit_value_dt = col_ptr.dict_value_dtype()
    read_integer_literal_for_column(lit_value_dt, lit_val, op)

    # Implicit numeric promotion for INT-col vs
    # FLOAT-literal. Taking `lit_val.int_val` (which is 0
    # for a float literal) and silently produced wrong results. The
    # promotion casts the column once and routes into the float64
    # kernel.
    # ⚠ THE NARROW WIDTHS ARE DELIBERATELY **NOT** LISTED HERE. Their own arm
    # below handles a float literal itself (`_eval_narrow_int_col_vs_literal`
    # branches on `lit.is_float`), which keeps one type's answer in one
    # place; routing them through this promotion too would give the same
    # question two implementations.
    if (col_at == ArrowType.INT64 or col_at == ArrowType.INT32) and (
        lit_val.dtype == DType.float64 or lit_val.dtype == DType.float32
    ):
        var int_col_copy = copy_column(batch, col_idx)
        var rhs_col = broadcast_scalar(lit_val.copy(), batch.num_rows())
        return _eval_col_vs_col_promoted(int_col_copy^, rhs_col^, op)

    # (The symmetric FLOAT-col vs INT-literal case used to be a block here
    # that promoted an integer literal ONLY when it was tagged int64 or
    # int32 — an allow-list over the literal's tag, past which every other
    # integer tag was read as `float_val`, zero. It is gone because it is
    # unreachable: the one rule above has already turned every integer
    # literal against a FLOAT64 column into a float one.)

    if col_at == ArrowType.INT64:
        var arr = col_ptr.as_primitive[DType.int64]()
        var threshold = Scalar[DType.int64](lit_val.int_val)

        # comptime kernel
        # dispatch when the flag is True. Synthesizes a length-N RHS
        # column filled with the threshold and dispatches through the
        # MatchFn kernel. The broadcast cost is intrinsic
        # to routing col-vs-literal through a col-vs-col kernel surface.
        # It is a DATA-only kernel like `_scalar_cmp`, so it finalizes
        # through the same seam — the flag must not change null semantics.
        comptime if USE_KERNEL_COMPTIME_FILTER:
            var rhs = _broadcast_to_array_int64(lit_val.int_val, arr.length)
            var kraw = _dispatch_int64_via_kernel(op, arr, rhs^)
            return kleene_cmp_finalize_scalar(
                kraw^, arr.validity, NullPolicy.three_valued(), arr.offset
            )

        var raw_i64 = _scalar_cmp[DType.int64](arr, threshold, op)
        return kleene_cmp_finalize_scalar(
            raw_i64^, arr.validity, NullPolicy.three_valued(), arr.offset
        )

    elif col_at == ArrowType.FLOAT64:
        var arr = col_ptr.as_primitive[DType.float64]()
        var threshold = Scalar[DType.float64](lit_val.float_val)

        # same shape as INT64 arm above.
        comptime if USE_KERNEL_COMPTIME_FILTER:
            var rhs = _broadcast_to_array_float64(lit_val.float_val, arr.length)
            var kraw_f = _dispatch_float64_via_kernel(op, arr, rhs^)
            return kleene_cmp_finalize_scalar(
                kraw_f^, arr.validity, NullPolicy.three_valued(), arr.offset
            )

        var raw_f64 = _scalar_cmp[DType.float64](arr, threshold, op)
        return kleene_cmp_finalize_scalar(
            raw_f64^, arr.validity, NullPolicy.three_valued(), arr.offset
        )

    elif col_at == ArrowType.INT32:
        var arr = col_ptr.as_primitive[DType.int32]()
        # the literal is an Int64 and
        # this column is int32. `_scalar_cmp_i32_widening` compares in a
        # domain holding both; the pre-fix `Int32(Int(lit_val.int_val))`
        # kept the LOW 32 BITS and answered a different question.
        var raw_i32 = _scalar_cmp_i32_widening(arr, lit_val.int_val, op)
        return kleene_cmp_finalize_scalar(
            raw_i32^, arr.validity, NullPolicy.three_valued(), arr.offset
        )

    elif col_at == ArrowType.UINT64:
        # This arm did not exist: a predicate
        # over a UINT64 column fell to the ladder's `else` and raised
        # `unsupported column type for predicate: uint64` at a door that sends
        # the filter straight here. The other
        # three doors never saw the refusal, because the ROW GROUP was
        # pruned first (`rg_pruner`, fixed in the same change) and they
        # got ZERO ROWS instead — the same defect wearing two faces.
        #
        # ⚠ NO SINGLE INTEGER TYPE HOLDS BOTH OPERANDS, which is why this
        # is not `_scalar_cmp_i32_widening` with another width. The column
        # is UInt64; the literal is `ScalarValue.int_val`, an Int64.
        # Widening the column to Int64 is the bug (a value above
        # `Int64.MAX` reads negative); narrowing the literal wraps a
        # negative one onto a huge positive. So a NEGATIVE literal is
        # answered on its own terms below, and only a non-negative one is
        # converted — the sign of the literal's EXACT, TAG-decoded value
        # (`integer_literal_value`) is exactly that question.
        var arr_u64 = col_ptr.as_primitive[DType.uint64]()
        var raw_u64: BooleanArray
        if lit_val.is_float():
            # `int_val` is a well-formed ZERO
            # for a literal built by `ScalarValue.from_float`, so reading
            # it here answered `v > 0` for `v > 2.0` — the whole table.
            # This is not a corner case reachable only from SQL: a
            # spreadsheet formula has NO integer literal at all, so that
            # front end sends a float for EVERY numeric predicate.
            #
            # ⚠ AND IT IS **NOT** THE INT64 REPAIR WITH ANOTHER WIDTH. The
            # INT64/INT32 pair a few lines up promotes the COLUMN to
            # Float64; above 2**53 that is lossy in exactly the region a
            # UInt64 column exists to reach (`2**64-1` and `2**64-2` are
            # the same Float64), so the reduction below keeps the DATA in
            # the unsigned domain and moves the THRESHOLD instead.
            raw_u64 = _u64_cmp_vs_float_literal(
                arr_u64, lit_val.float_val, op
            )
        else:
            # ★★ THE ONE RULE (`integer_literal_value.mojo`): the literal's
            # EXACT value, decoded by its TAG — the uint64 tag zero-extends
            # its bit pattern, every other tag sign-extends `int_val`.
            #
            # ⛔ A SILENT WRONG ANSWER WITHOUT IT.
            # `ScalarValue.from_uint64` stores the unsigned value as its
            # TWO'S-COMPLEMENT BIT PATTERN in `int_val`, and this arm read
            # `int_val` SIGNED: `2**64-1` arrived as `-1`, took the negative
            # branch below, and `v = 18446744073709551615` selected ZERO
            # ROWS. "fix(compiler): a UINT64 predicate reads an
            # UNSIGNED-TAGGED literal unsigned" repaired it here by asking
            # `is_uint` before the bits; the same misread lived in every OTHER arm
            # that meets an integer literal, which is why the tag is now
            # decoded in one function instead of per arm. Pinned by §6 of
            # `tests/test_predicate_over_uint64_column.mojo`.
            #
            # ⚠ THE DISCRIMINATOR IS THE TAG, NEVER THE SIGN OF THE BITS.
            # `int_val == -1` is `2**64-1` tagged uint64 and `-1` tagged
            # int64, and they want OPPOSITE answers. The decode separates
            # them; §3 of the same test is the control on the signed side.
            var lit_exact = integer_literal_value(lit_val)
            if lit_exact >= SIMD[DType.int128, 1](0):
                raw_u64 = _scalar_cmp[DType.uint64](
                    arr_u64,
                    Scalar[DType.uint64](lit_exact.cast[DType.uint64]()),
                    op,
                )
            else:
                # A NEGATIVE literal — necessarily a signed tag, since the
                # decode never makes an unsigned one negative. Every unsigned
                # value is strictly above it, so `>`/`>=`/`!=` hold for
                # every row and `<`/`<=`/`=` for none. Both are spelled as
                # a REAL compare against 0 in the unsigned domain rather
                # than a synthesized constant mask, so the raw bits, the
                # lane order and the offset handling are the kernel's own
                # and this arm adds no second way to build a mask.
                var all_rows = (op == BIN_GT or op == BIN_GE or op == BIN_NE)
                raw_u64 = _scalar_cmp[DType.uint64](
                    arr_u64,
                    Scalar[DType.uint64](UInt64(0)),
                    BIN_GE if all_rows else BIN_LT,
                )
        return kleene_cmp_finalize_scalar(
            raw_u64^,
            arr_u64.validity,
            NullPolicy.three_valued(),
            arr_u64.offset,
        )

    elif col_at == ArrowType.INT8:
        # ★ THE FIVE NARROW INTEGER WIDTHS, one arm each because the storage
        # DType is a COMPTIME parameter of the widening. See
        # `_eval_narrow_int_arm`: an integer literal widens the COLUMN to
        # int64 (never narrows the literal), and a FLOAT literal widens it to
        # float64 — exact for these five widths, which is why this is NOT the
        # UINT64 threshold-move.
        return _eval_narrow_int_arm[DType.int8](
            col_ptr.as_primitive[DType.int8](), lit_val, op
        )

    elif col_at == ArrowType.INT16:
        return _eval_narrow_int_arm[DType.int16](
            col_ptr.as_primitive[DType.int16](), lit_val, op
        )

    elif col_at == ArrowType.UINT8:
        return _eval_narrow_int_arm[DType.uint8](
            col_ptr.as_primitive[DType.uint8](), lit_val, op
        )

    elif col_at == ArrowType.UINT16:
        return _eval_narrow_int_arm[DType.uint16](
            col_ptr.as_primitive[DType.uint16](), lit_val, op
        )

    elif col_at == ArrowType.UINT32:
        return _eval_narrow_int_arm[DType.uint32](
            col_ptr.as_primitive[DType.uint32](), lit_val, op
        )

    elif col_at == ArrowType.FLOAT32:
        # ★ FLOAT32 compares in FLOAT64, because the literal IS a Float64 and
        # rounding the threshold into float32 merges two distinct thresholds.
        return _eval_float32_col_vs_literal(
            col_ptr.as_primitive[DType.float32](), lit_val, op
        )

    elif col_at == ArrowType.BOOL:
        # ★ 40 of the 80 refused cross-surface units are this one cell. BOOL
        # is bit-packed, so it is ranked to int8 0/1 and compared there.
        return _eval_bool_col_vs_literal(col_ptr, lit_val, op)

    elif col_at == ArrowType.DECIMAL128:
        # scale-aligned col-vs-decimal-literal
        # compare (literal may be a decimal / int / float — promoted).
        return _eval_decimal_col_vs_literal(batch, col_idx, lit_val, op)

    elif col_at == ArrowType.DICTIONARY and col_ptr.is_numeric_dict():
        # NUMERIC dictionary
        # `col OP literal` predicate -> compute-over-codes LUT
        # (`numeric_dict_filter_bool_mask`), mirroring the production STRING
        # dict-filter LUT (`dict_filter_eval_bool_mask`, below). Resolve each
        # of the <= dict_size DISTINCT entries ONCE, build a keep-bit LUT,
        # then scan the N codes against it. This DELETES the v1
        # densification band-aid (`resolve_numeric_dict_to_flat` per-row
        # gather AT FILTER TIME). `_numeric_dict_filter_dispatch` runs the
        # LUT unconditionally (_VERIFY = also run the flat oracle and assert
        # byte-equal).
        #
        # Only the `col OP literal` shape reaches here. A numeric-dict-col vs
        # numeric-dict-col compare routes to `_eval_col_vs_col` (both cols
        # are DICTIONARY) which RAISES — code-vs-code across distinct per-RG
        # dicts is structurally declined to the value domain.
        return _numeric_dict_filter_dispatch(col_ptr, op, lit_val)

    elif col_at == ArrowType.DICTIONARY:
        # Dict-aware filter: evaluate predicate against D dictionary
        # entries instead of N rows. For low-cardinality strings (D=5,
        # N=1M), this is 200,000x fewer string comparisons.
        var str_val = lit_val.string_val
        var dict_op: DictFilterOp
        if op == BIN_EQ:
            dict_op = DictFilterOp.EQ
        elif op == BIN_NE:
            dict_op = DictFilterOp.NE
        elif op == BIN_GT:
            dict_op = DictFilterOp.GT
        elif op == BIN_LT:
            dict_op = DictFilterOp.LT
        elif op == BIN_GE:
            dict_op = DictFilterOp.GE
        elif op == BIN_LE:
            dict_op = DictFilterOp.LE
        else:
            raise Error("PipelineCompiler: unsupported comparison op for dictionary: " + String(Int(op)))
        if col_ptr._dict_index_byte_width == 4:
            # read the codes IN PLACE and build the
            # mask branch-free (`dict_filter_eval_bool_mask_column`) — no
            # `as_dictionary` copy of the whole code buffer per batch —
            # and apply the SAME null policy every other comparison arm in
            # this ladder applies (`kleene_cmp_finalize_scalar`): a NULL row
            # is NULL, never whatever its placeholder code happens to match.
            # The arm below it returned the raw code verdict for NULL rows.
            var raw_d = dict_filter_eval_bool_mask_column(
                col_ptr, dict_op, str_val
            )
            return kleene_cmp_finalize_scalar(
                raw_d^,
                col_ptr._validity,
                NullPolicy.three_valued(),
                col_ptr._offset,
            )
        var dict_arr = col_ptr.as_dictionary()
        return dict_filter_eval_bool_mask(dict_arr, dict_op, str_val)

    elif col_at == ArrowType.STRING:
        # ⭐ READ IN PLACE. `as_string` copied the whole
        # column to feed a kernel that only reads it — cbq27's `url <> ''`
        # paid a full `url` copy per batch for it (C-pred, 7.1% of CPU).
        var arr = string_array_of(col_ptr)
        var str_val = lit_val.string_val
        if op == BIN_EQ:
            return eval_string_eq(arr, str_val)
        elif op == BIN_NE:
            return eval_string_ne(arr, str_val)
        elif op == BIN_GT:
            return eval_string_gt(arr, str_val)
        elif op == BIN_LT:
            return eval_string_lt(arr, str_val)
        elif op == BIN_GE:
            return eval_string_ge(arr, str_val)
        elif op == BIN_LE:
            return eval_string_le(arr, str_val)
        else:
            raise Error("PipelineCompiler: unsupported comparison op for string: " + String(Int(op)))

    elif col_at == ArrowType.LARGE_STRING:
        # LARGE_STRING
        # predicate parity.  Pre-fix, this branch fell into the else and
        # raised — making any predicate on a LARGE_STRING column impossible.
        # The Int64-offset kernels in komira_column_kernels.string_comparison share
        # one `@parameter fn _string_*_kernel[OffsetType]` body with the
        # StringArray path; byte-identical semantics, only the offset
        # element width differs.
        var arr = col_ptr.as_large_string()
        var str_val = lit_val.string_val
        if op == BIN_EQ:
            return eval_large_string_eq(arr, str_val)
        elif op == BIN_NE:
            return eval_large_string_ne(arr, str_val)
        elif op == BIN_GT:
            return eval_large_string_gt(arr, str_val)
        elif op == BIN_LT:
            return eval_large_string_lt(arr, str_val)
        elif op == BIN_GE:
            return eval_large_string_ge(arr, str_val)
        elif op == BIN_LE:
            return eval_large_string_le(arr, str_val)
        else:
            raise Error("PipelineCompiler: unsupported comparison op for large string: " + String(Int(op)))

    else:
        raise Error("PipelineCompiler: unsupported column type for predicate: " + String(col_at))
