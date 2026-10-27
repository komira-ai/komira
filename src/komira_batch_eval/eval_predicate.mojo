# =============================================================================
# eval_predicate: the predicate evaluator (Expr -> BooleanArray)
# =============================================================================
#
# `_eval_predicate` is the ladder over the `EXPR_*` tags in predicate context.
# The binary-operator arm is `predicate_binary._predicate_binary_op`; the
# comparison kernels are in `predicate_compare`, the dictionary-encoded numeric
# predicates in `predicate_numeric_dict`, and the AND/OR short-circuit with the
# shared helpers in `predicate_logic`.
#
# NULL CONTRACT: a row whose predicate value is UNKNOWN comes back with data
# bit 0 and, when any operand was nullable, a cleared validity bit. The filter
# boundary (`conjunction`) is what turns UNKNOWN into FALSE.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import eval_not
from komira_column_kernels.compiler_helpers import expr_resolves_to_column, resolve_col_index
from komira_column_kernels.regexp_functions import (
    compile_full_match_program,
    eval_regexp_full_match,
    eval_regexp_like,
    split_g_flag,
)
from komira_column_kernels.regexp_nfa import RegexProgram
from komira_plan_expr.expr import (
    BIN_EQ,
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_IN_LIST,
    EXPR_LITERAL,
    EXPR_REGEXP,
    EXPR_STRING_OP,
    EXPR_UNARY_OP,
    Expr,
    REGEXP_FULL_MATCH,
    REGEXP_LIKE,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue

from .eval_column import _eval_column_expr
from .eval_dict import _materialize_dict_to_string
from .eval_in_list import _eval_in_list
from .predicate_binary import _predicate_binary_op
from .predicate_compare import _eval_bool_col_vs_literal
from .predicate_logic import _eval_string_op_on_column, _null_mask_of
from .string_bytes import string_array_of


def _eval_predicate(expr: Expr, batch: RecordBatch) raises -> BooleanArray:
    """Evaluate an Expr predicate against a RecordBatch, producing a BooleanArray mask.

    Handles comparison operators (>, <, ==, !=, >=, <=) with literal RHS,
    and logical combinators (AND, OR, NOT).

    NULL CONTRACT: a row whose predicate value is UNKNOWN comes back with DATA
    BIT 0, and (when any operand was nullable) a cleared validity bit saying
    why; the filter boundary in `conjunction` collapses UNKNOWN to FALSE.

    Args:
        expr: The predicate expression.
        batch: The input RecordBatch.

    Returns:
        A BooleanArray where True indicates rows that pass the predicate.
    """
    if expr.tag == EXPR_BINARY_OP:
        return _predicate_binary_op(expr, batch)

    elif expr.tag == EXPR_ALIAS:
        # ★ AN ALIAS IS A NAME, NOT A VALUE. `_eval_column_expr` unwraps
        # `EXPR_ALIAS`; a ladder that refused it
        # with `unsupported predicate expression
        # not executable as a PROJECTION at all: the moment the projection arm
        # started delegating comparisons here, the plan-matrix cell
        # `proj_float_class/float64/{full,nanmix}` moved from
        # `unsupported float64 scalar binary op: 14` straight onto this wall.
        #
        # ⚠ IT IS NOT A THEORETICAL SHAPE, AND IT IS NOT AT THE TOP OF THE
        # EXPRESSION. `isfinite(v)` and `isnan(v)` in one SELECT share the
        # subtree `v > -inf AND v < inf`; CSE hoists it under an alias and
        # `merge_projects` inlines the aliased node back into its consumers, so
        # the surviving tree carries `NOT(Alias(AND(...), "<cse>"))` — an
        # ALIAS BELOW a `UN_NOT`, which the arm below hands straight back to
        # this function.
        #
        # The alias renames the OUTPUT COLUMN; in predicate position there is
        # no column to name, so the child's mask IS the answer. Same one-line
        # body `_eval_column_expr`'s `EXPR_ALIAS` arm has carried all along.
        return _eval_predicate(expr.alias_child_ref(), batch)

    elif expr.tag == EXPR_UNARY_OP:
        var op = expr.unary_op()
        if op == UN_NOT:
            var child_mask = _eval_predicate(expr.unary_child_ref(), batch)
            return eval_not(child_mask)
        elif op == UN_IS_NULL:
            # IS_NULL(col_ref) — emit a nullable BooleanArray where
            # data[r]=1 iff input row r is NULL, validity all-ones.
            # The COL_REF path is the fast one (no materialization); a
            # computed child takes the fallback immediately below.
            # ★ GENERAL-CHILD FALLBACK. The COL_REF
            # fast path below reads the resident column's validity bitmap with
            # no materialization; ANY OTHER child is materialized through
            # `_eval_column_expr` and its validity read the same way. This is
            # what makes `coalesce(...)`'s desugar reachable — the desugar
            # emits `<arg> IS NOT NULL` conditions and only its first argument
            # is ever a bare column, so a COL_REF-only arm would refuse
            # `coalesce(a, upper(b), 'z')` and every all-literal form
            # (`coalesce(NULL, NULL, 3)`) with a tag number.
            if expr.unary_child_ref().tag != EXPR_COL_REF:
                var gen_null = _eval_column_expr(expr.unary_child_ref(), batch)
                return _null_mask_of(gen_null, batch.num_rows(), True)
            var col_idx = resolve_col_index(expr.unary_child_ref(), batch.schema)
            ref col_ptr = batch.column_at(col_idx)
            var num_rows = batch.num_rows()
            var ba = BooleanArray.allocate_nullable(num_rows)
            # If the column has no validity bitmap, every row is non-null -> data stays all-zero.
            # Otherwise, set ba.data[r] = 1 where validity[r] = 0 (null).
            # Bytewise: data_byte = ~validity_byte (masked for trailing bits).
            if col_ptr._validity:
                var n_bytes = (num_rows + 7) >> 3
                # Origin-tied via function-scope view locals; the views
                # are bound on the same `if` arm so NLL releases the
                # borrows at last-use (the trailing-bit mask write) before
                # `return ba^` move-returns.
                var v_view = col_ptr._validity.value().buffer.view_ro()
                var d_view = ba.data.buffer.view_mut()
                var v_ptr = v_view._unsafe_ptr()
                var d_ptr = d_view._unsafe_ptr()
                for b in range(n_bytes):
                    (d_ptr + b)[] = ~(v_ptr + b)[]
                # Clear trailing bits in the last byte beyond `num_rows` bits
                # so they don't appear as phantom nulls.
                var trailing = num_rows & 7
                if trailing > 0 and n_bytes > 0:
                    var mask = UInt8((1 << trailing) - 1)
                    (d_ptr + n_bytes - 1)[] = (d_ptr + n_bytes - 1)[] & mask
            return ba^
        elif op == UN_IS_NOT_NULL:
            # =============================================================
            # ★ IS NOT NULL — THE POLARITY TWIN, AND IT DID NOT EXIST.
            # =============================================================
            #
            # `WHERE col IS NOT NULL` raised `PipelineCompiler: unsupported
            # unary predicate op: 3` — the arm directly above has served
            # `IS NULL` and its opposite fell into the `else`.
            #
            # ⚠ IT TOOK A FIX TO ANOTHER DEFECT TO MAKE THIS VISIBLE, which is
            # why it is landing here rather than having been found earlier.
            # `test_is_null_finds_exactly_the_missing_values` asserts
            # BOTH polarities in one body precisely because "the pair must
            # partition the six rows" — but its FIRST leg (`IS NULL`) returned
            # zero rows and failed at the row-count assertion, so the second
            # leg was never executed. The self-checking pair could not check
            # itself while its first half was broken. Both halves are green
            # now, and the partition is a real assertion for the first time.
            #
            # SEMANTICS: `data[r] = 1` iff row r is NOT null; validity
            # all-ones (the answer is never itself unknown). A computed child
            # takes the same materialize-then-read-validity fallback as
            # `IS NULL`; it is no longer refused.
            # ★ GENERAL-CHILD FALLBACK — see the `IS NULL` twin above. Same
            # materialize-then-read-validity shape, opposite polarity.
            if expr.unary_child_ref().tag != EXPR_COL_REF:
                var gen_nn = _eval_column_expr(expr.unary_child_ref(), batch)
                return _null_mask_of(gen_nn, batch.num_rows(), False)
            var nn_idx = resolve_col_index(
                expr.unary_child_ref(), batch.schema
            )
            ref nn_col = batch.column_at(nn_idx)
            var nn_rows = batch.num_rows()
            var nn_ba = BooleanArray.allocate_nullable(nn_rows)
            var nn_bytes = (nn_rows + 7) >> 3
            var nn_trailing = nn_rows & 7
            if nn_col._validity:
                # data_byte = validity_byte (NOT `~validity_byte` — that is
                # the arm above). Origin-tied views, same shape as `IS NULL`.
                var nv_view = nn_col._validity.value().buffer.view_ro()
                var nd_view = nn_ba.data.buffer.view_mut()
                var nv_ptr = nv_view._unsafe_ptr()
                var nd_ptr = nd_view._unsafe_ptr()
                for b in range(nn_bytes):
                    (nd_ptr + b)[] = (nv_ptr + b)[]
                if nn_trailing > 0 and nn_bytes > 0:
                    var nmask = UInt8((1 << nn_trailing) - 1)
                    (nd_ptr + nn_bytes - 1)[] = (
                        nd_ptr + nn_bytes - 1
                    )[] & nmask
            else:
                # ⚠ NO VALIDITY BITMAP MEANS EVERY ROW IS VALID, so every row
                # answers TRUE. `allocate_nullable` zero-fills the data, which
                # is the correct default for `IS NULL` and the WRONG one here
                # — the asymmetry is exactly why this cannot be spelled as
                # "the arm above with the `~` removed" and left at that.
                var nd_view2 = nn_ba.data.buffer.view_mut()
                var nd_ptr2 = nd_view2._unsafe_ptr()
                for b in range(nn_bytes):
                    (nd_ptr2 + b)[] = UInt8(0xFF)
                if nn_trailing > 0 and nn_bytes > 0:
                    var nmask2 = UInt8((1 << nn_trailing) - 1)
                    (nd_ptr2 + nn_bytes - 1)[] = (
                        nd_ptr2 + nn_bytes - 1
                    )[] & nmask2
            return nn_ba^
        else:
            raise Error("PipelineCompiler: unsupported unary predicate op: " + String(Int(op)))

    elif expr.tag == EXPR_IN_LIST:
        # set-membership predicate. Dispatch
        # to the typed kernel in `eval_in_list.mojo`. Single
        # batch sweep + inline value-table probe per row.
        return _eval_in_list(expr, batch)

    elif expr.tag == EXPR_STRING_OP:
        # String operations: CONTAINS, STARTS_WITH, ENDS_WITH, LIKE
        # ★ A COMPUTED OPERAND — `lower(s) LIKE 'a%'`,
        # `starts_with(trim(s), 'x')` — is MATERIALIZED first, the way the
        # computed-LHS arm above materializes `a * b > 100`. Without this every
        # such predicate raised `cannot resolve column index from expression
        # tag: 24` (through the SQL door, where DuckDB
        # v1.5.3 answers all of them), and SQL `ILIKE` — which IS
        # `lower(x) LIKE lower(p)` in DuckDB — could not run at all.
        if not expr_resolves_to_column(expr.string_op_child_ref()):
            var computed = _eval_column_expr(expr.string_op_child_ref(), batch)
            return _eval_string_op_on_column(
                computed, expr.string_op_type(), expr.string_op_pattern()
            )
        var col_idx = resolve_col_index(expr.string_op_child_ref(), batch.schema)
        return _eval_string_op_on_column(
            batch.column_at(col_idx), expr.string_op_type(), expr.string_op_pattern()
        )


    elif expr.tag == EXPR_REGEXP:
        # regexp_like / regexp_matches / `~` and
        # regexp_full_match are Bool-producing and so usable as a
        # filter predicate.  Every other regexp op (regexp_extract / match /
        # split_to_array / extract_all / replace / count / instr / substr)
        # produces a non-boolean value -> can't be a predicate.
        var rop = expr.regexp_op()
        if rop != REGEXP_LIKE and rop != REGEXP_FULL_MATCH:
            raise Error("PipelineCompiler: regexp_extract / regexp_match / regexp_split_to_array / regexp_extract_all / regexp_replace / regexp_count / regexp_instr / regexp_substr produce non-boolean values; cannot be used as a predicate (use them in a projection)")
        var col_idx = resolve_col_index(expr.regexp_child_ref(), batch.schema)
        ref col_ptr = batch.column_at(col_idx)
        var col_at = col_ptr.arrow_type
        if col_at != ArrowType.STRING and col_at != ArrowType.DICTIONARY:
            raise Error("PipelineCompiler: regexp_like / regexp_full_match require a STRING or DICTIONARY column, got " + String(col_at))
        var arr: StringArray[HeapRegion]
        if col_at == ArrowType.DICTIONARY:
            arr = _materialize_dict_to_string(col_ptr)
        else:
            # Lane G L1: read in place, as the comparison arm above does.
            arr = string_array_of(col_ptr)
        # `g` (replace-all) is not a pattern flag — strip it (harmless here).
        var gsplit = split_g_flag(expr.regexp_flags())
        var pattern_flags = gsplit[0]
        if rop == REGEXP_FULL_MATCH:
            var fm_prog = compile_full_match_program(expr.regexp_pattern(), pattern_flags)
            return eval_regexp_full_match(arr, fm_prog)
        var prog = RegexProgram.compile(expr.regexp_pattern(), pattern_flags)
        return eval_regexp_like(arr, prog)

    elif expr.tag == EXPR_LITERAL:
        # Literal boolean: broadcast to all rows
        var lit_val = expr.literal_value()
        var num_rows = batch.num_rows()
        var bm = Bitmap.create(num_rows)
        if lit_val.bool_val:
            for i in range(num_rows):
                bm.set(i)
        # else: all bits already clear (False)
        return BooleanArray.from_bitmap(bm^)

    elif expr.tag == EXPR_COL_REF or expr.tag == EXPR_COL_IDX:
        # =====================================================================
        # ★ `WHERE flag` — A BARE BOOLEAN COLUMN IS ITSELF A PREDICATE.
        # =====================================================================
        #
        # This ladder had no arm for a bare column reference, so the plainest
        # boolean filter in SQL died at the receiver with
        # `unsupported predicate expression tag: 0` (tag 1, `EXPR_COL_IDX`, for
        # the bound twin the optimizer substitutes). MEASURED through the real
        # binary from a TypeScript e2e chain as
        # PLAN_ENDPOINT_EXECUTION_FAILED(20): `lf.filter(col("flag"))` and
        # `lf.filter(col("flag").not)` both reported tag 0 — the second
        # because `UN_NOT` recurses into this function on its child and hit the
        # same wall one frame down. ONE arm therefore fixes BOTH spellings.
        #
        # ⛔ IT BELONGS HERE, NOT IN A FRONTEND DESUGAR. Every skin that can
        # build a plan — the TypeScript SDK, the SQL binder, the Mojo
        # DataFrame API, the plan wire — lands on this one evaluator. A
        # `col -> col = TRUE` rewrite at admission would fix the door it was
        # written in and leave the other three encoding the same dead plan;
        # an arm here is reached by all of them, and by anything that reaches
        # `_eval_predicate` through the optimizer after a rewrite has already
        # run (which is precisely where an admission-time desugar is no longer
        # in the path).
        #
        # SEMANTICS: `WHERE flag` is `flag = TRUE` under SQL three-valued
        # logic — TRUE passes, FALSE fails, NULL is UNKNOWN and is dropped —
        # so this delegates to the ONE bool arm rather than re-reading the
        # bits. `_eval_bool_col_vs_literal` is offset-aware (a sliced BOOL
        # column post-join / post-concat) and imposes 3VL through the single
        # `kleene_cmp_finalize_scalar` seam; a second hand-rolled bitmap copy
        # here would be a second place for that to drift.
        #
        # ⛔ A NON-BOOL COLUMN STAYS A REFUSAL. There is no implicit
        # int-to-bool truthiness here and inventing one would turn a loud
        # refusal into a silent wrong answer; what changes is that the message
        # now names the COLUMN and its TYPE instead of an opaque tag number.
        var bare_idx = resolve_col_index(expr, batch.schema)
        ref bare_col = batch.column_at(bare_idx)
        var bare_at = bare_col.arrow_type
        if bare_at != ArrowType.BOOL:
            raise Error(
                "PipelineCompiler: a column used directly as a predicate"
                " requires a BOOL column; '"
                + batch.schema.field_name(bare_idx)
                + "' is "
                + String(bare_at)
                + " (write an explicit comparison, e.g. `col != 0`)"
            )
        return _eval_bool_col_vs_literal(
            bare_col, ScalarValue.from_bool(True), BIN_EQ
        )

    elif expr.tag == EXPR_AGG_FN:
        # EXPR_AGG_FN is a placeholder consumed by
        # the optimizer's `optimizer_scalar_broadcast` rule before eval
        # ever sees it. Reaching here means the rule did NOT fire (the
        # `Filter(<EXPR_AGG_FN>) over Aggregate` shape requirement was
        # not met) — surfacing loudly so the diagnostic is immediate.
        raise Error(
            "agg-fn outside filter-over-aggregate context — Pattern B"
            " requires Filter directly above Aggregate. For"
            " `.with_column(...)` / `.agg(...)` use cases use the"
            " existing `agg.max(col(\"x\"))` factory instead."
        )

    else:
        raise Error("PipelineCompiler: unsupported predicate expression tag: " + String(Int(expr.tag)))
