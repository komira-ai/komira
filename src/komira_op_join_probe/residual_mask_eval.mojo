# =============================================================================
# residual_mask_eval -- evaluating a join's residual predicate (the non-equi
# part of its condition) over candidate (probe, build) pairs.
# =============================================================================
#
# The candidates' joined rows are assembled and the predicate evaluated by
# `komira_batch_eval`; a NULL result does not pass (a join condition that is
# NULL is not a match). When the predicate names its columns, only those
# columns are assembled (late materialisation); the mask is the same.
# =============================================================================

from std.collections import Set

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_IN_LIST,
    EXPR_REGEXP,
    EXPR_AGG_FN,
    EXPR_WHEN,
)
from komira_join_assembly.compiler_join_assembly import (
    assemble_join_result, assemble_join_result_projected,
)

from komira_batch_eval.eval_predicate import _eval_predicate

from .residual_latemat_counter import residual_mask_cells_incr


def _joined_schema(
    left_schema: Schema, right_schema: Schema,
    left_nullable: Bool = False, right_nullable: Bool = False,
) raises -> Schema:
    var sb = SchemaBuilder()
    var left_names = Set[String]()
    for i in range(left_schema.num_columns()):
        left_names.add(left_schema.field_name(i))
        var lf = left_schema.field_at(i)
        if left_nullable:
            lf.nullable = True
        sb.add_field(lf^)
    for i in range(right_schema.num_columns()):
        var rname = right_schema.field_name(i)
        var rf = right_schema.field_at(i)
        if rname in left_names:
            rf.name = rname + "_right"
        if right_nullable:
            rf.nullable = True
        sb.add_field(rf^)
    return sb.build()


def _residual_pass_mask(residual: Expr, joined: RecordBatch) raises -> List[Bool]:
    """Evaluate `residual` against the assembled matched-pair batch `joined`
    and return a per-row "passes" mask. A NULL predicate result is treated as
    "does not pass" (SQL: a join condition evaluating to NULL is not a match).
    """
    var n = joined.num_rows()
    var out = List[Bool](capacity=n)
    if n == 0:
        return out^
    var ba = _eval_predicate(residual, joined)
    for i in range(n):
        if ba.is_null(i):
            out.append(False)
        else:
            out.append(ba.get(i))
    return out^


def _collect_residual_col_names(imm e: Expr, mut out: List[String]) raises -> Bool:
    """Collect the joined-schema column names `e` references, descending as
    `_eval_predicate` does. Returns False on a node kind whose columns it
    cannot enumerate, so the caller assembles every column instead.
    """
    var t = e.tag
    if t == EXPR_COL_REF:
        out.append(e.col_ref_name())
        return True
    if t == EXPR_LITERAL:
        return True
    if t == EXPR_BINARY_OP:
        return _collect_residual_col_names(e.binary_left_ref(), out) and (
            _collect_residual_col_names(e.binary_right_ref(), out)
        )
    if t == EXPR_UNARY_OP:
        return _collect_residual_col_names(e.unary_child_ref(), out)
    if t == EXPR_CAST:
        return _collect_residual_col_names(e.cast_child_ref(), out)
    if t == EXPR_ALIAS:
        return _collect_residual_col_names(e.alias_child_ref(), out)
    if t == EXPR_STRING_OP:
        return _collect_residual_col_names(e.string_op_child_ref(), out)
    if t == EXPR_IN_LIST:
        return _collect_residual_col_names(e.in_list_child_ref(), out)
    if t == EXPR_REGEXP:
        return _collect_residual_col_names(e.regexp_child_ref(), out)
    if t == EXPR_AGG_FN:
        return _collect_residual_col_names(e.agg_fn_child_ref(), out)
    if t == EXPR_WHEN:
        var num = e.when_num_cases()
        for i in range(num):
            if not _collect_residual_col_names(e.when_case_condition_ref(i), out):
                return False
            if not _collect_residual_col_names(e.when_case_result_ref(i), out):
                return False
        return _collect_residual_col_names(e.when_default_ref(), out)
    return False


def _residual_referenced_names(residual: Expr) raises -> Optional[List[String]]:
    """The deduped list of joined-schema column names `residual` references, or
    None if the residual has a variant the collector cannot fully enumerate (->
    caller falls back to the eager full-assembly path). Returns None on an empty
    result too: a residual referencing NO column is degenerate and not worth a
    projected assembly (the eager path handles it identically).
    """
    var raw = List[String]()
    if not _collect_residual_col_names(residual, raw):
        return None
    if len(raw) == 0:
        return None
    var uniq = List[String]()
    for i in range(len(raw)):
        var seen = False
        for j in range(len(uniq)):
            if uniq[j] == raw[i]:
                seen = True
                break
        if not seen:
            uniq.append(raw[i])
    return Optional(uniq^)


def _compute_residual_pass_mask(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    cand_probe: List[Int],
    cand_build: List[Int],
    residual: Expr,
    late_mat: Bool = True,
) raises -> List[Bool]:
    """Compute the per-candidate-pair residual pass mask. With `late_mat`, and
    when every node of `residual` names its columns, only those columns of the
    candidate pairs are assembled; otherwise the full joined rows are. Both
    give the same mask.
    """
    var n_cand = len(cand_probe)

    var names_opt = Optional[List[String]](None)
    if late_mat:
        names_opt = _residual_referenced_names(residual)

    if names_opt:
        ref names = names_opt.value()
        residual_mask_cells_incr(n_cand * len(names))
        var residual_joined = assemble_join_result_projected(
            probe_batch, build_batch, cand_probe, cand_build, names,
            left_nullable=False, right_nullable=False,
        )
        return _residual_pass_mask(residual, residual_joined^)

    var full_cols = probe_batch.num_columns() + build_batch.num_columns()
    residual_mask_cells_incr(n_cand * full_cols)
    var joined_schema = _joined_schema(probe_batch.schema, build_batch.schema)
    var joined = assemble_join_result(
        probe_batch, build_batch, cand_probe, cand_build, joined_schema,
    )
    return _residual_pass_mask(residual, joined^)
