# =============================================================================
# project_decline_census.mojo: the facts a computed-projection refusal names
# =============================================================================
#
# When `compute_project.eval_project_exprs_over_batch` declines, the caller's
# refusal can say which output expression it was and what the batch held only
# if it reports them. `format_project_decline_census` renders those facts as
# lines a caller appends to its error:
#
#   * per output expression: its index, its tag (and the tag under an alias),
#     its output name, the declared type and nullability, and, for a column
#     reference or an alias of one, the source column it names with that
#     column's type and nullability in the incoming batch (or that the column
#     is absent);
#   * the incoming batch's whole schema: per column, name, type and
#     nullability;
#   * the two declines the evaluator takes before it looks at any
#     expression: an empty expression list, and an expression count that
#     differs from the declared column count.
#
# It is a printer. It does not re-run the evaluator's routing and does not
# say which arm declined: a second copy of the routing could disagree with
# the first. The reader compares the declared and source types.
#
# A type prints as `<name>(id=<n>)`: names such as `string` and
# `large_string` differ by a prefix, and the numeric id is the exact half a
# search matches. Nullability prints as `0` / `1`.
#
# It takes a `Schema`, not a `RecordBatch`: the evaluator takes the batch by
# value, so a caller copies the schema before the call.
#
# No UnsafePointer anywhere in this module.
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_COL_REF,
    expr_tag_name,
)
from komira_plan_ir.logical_plan import ExprArray


# The per-line prefix: one token, so a search for `project-decline` returns
# the whole census and nothing else.
comptime _LINE = "\n  [project-decline] "

# An expression rendering longer than this is reported by its length, so one
# large tree cannot bury the other lines.
comptime _MAX_EXPR_RENDER: Int = 512


def _at_str(imm at: ArrowType) -> String:
    """`<name>(id=<n>)`: the type's name and its numeric id."""
    var out = String()
    at.write_to(out)
    out += "(id=" + String(Int(at.type_id)) + ")"
    return out^


def _bit(b: Bool) -> String:
    return String("1") if b else String("0")


def _colref_name(imm e: Expr) -> Optional[String]:
    """The column name when `e` is a column reference under any number of
    aliases: the shape `compute_project_routes._passthrough_col_index`
    matches, read without a batch. It says only whether `e` names a column."""
    if e.tag == EXPR_ALIAS:
        return _colref_name(e.alias_child_ref())
    if e.tag == EXPR_COL_REF:
        return Optional[String](e._col_ref.value().name.copy())
    return None


def _schema_index_of(imm schema: Schema, imm name: String) -> Int:
    var n = schema.num_columns()
    for i in range(n):
        if schema.field_name(i) == name:
            return i
    return -1


def format_project_decline_census(
    imm in_schema: Schema, imm exprs: ExprArray, imm out_schema: Schema
) raises -> String:
    """The census a caller appends to a computed-projection refusal (see the
    module header).

    Args:
        in_schema: The schema of the batch the projection was to be evaluated
          over, copied before the batch was moved into the evaluator.
        exprs: The projection's output expressions, in output order.
        out_schema: The declared output schema of those expressions.

    Returns:
        A multi-line string, each line prefixed `[project-decline]`. An odd
        input (a count mismatch, an absent column) is reported as a line, not
        raised: the census is read on a path that is already failing.
    """
    var n_exprs = len(exprs)
    var n_out = out_schema.num_columns()
    var n_in = in_schema.num_columns()

    var out = String(_LINE) + "CENSUS out_exprs=" + String(n_exprs)
    out += " out_schema_cols=" + String(n_out)
    out += " in_batch_cols=" + String(n_in)

    # The evaluator declines these two before it examines any expression, so
    # without these lines a reader would look for a bad expression that does
    # not exist.
    if n_exprs == 0:
        out += _LINE + "⚠ EMPTY EXPR LIST — the evaluator declines a"
        out += " zero-expr projection before examining anything."
    if n_out != n_exprs:
        out += _LINE + "⚠ ARITY MISMATCH — out_schema declares " + String(n_out)
        out += " column(s) for " + String(n_exprs) + " expr(s). The evaluator"
        out += " declines on this ALONE, before examining any expr."

    for i in range(n_exprs):
        ref e = exprs[i]
        var line = _LINE + "expr[" + String(i) + "] tag=" + expr_tag_name(e.tag)
        if e.tag == EXPR_ALIAS:
            line += ">" + expr_tag_name(e.alias_child_ref().tag)
        if i < n_out:
            line += " out_name='" + out_schema.field_name(i) + "'"
            line += " declared=" + _at_str(out_schema.field_arrow_type(i))
            line += " declared_nullable=" + _bit(out_schema.field_nullable(i))
        else:
            line += " out_name=<NO out_schema COLUMN AT THIS INDEX>"
        # A column reference puts the declared type beside the source
        # column's type in this batch.
        var cr = _colref_name(e)
        if cr:
            var nm = cr.take()
            var si = _schema_index_of(in_schema, nm)
            if si >= 0:
                line += " src='" + nm + "'@in[" + String(si) + "]"
                line += " src_type=" + _at_str(in_schema.field_arrow_type(si))
                line += " src_nullable=" + _bit(in_schema.field_nullable(si))
            else:
                line += " src='" + nm + "' ⚠ ABSENT FROM THE INCOMING BATCH"
        else:
            line += " src=<computed>"
        var rendered = String()
        e.write_to(rendered)
        if rendered.byte_length() <= _MAX_EXPR_RENDER:
            line += " expr=" + rendered
        else:
            line += " expr=<" + String(rendered.byte_length())
            line += " bytes, omitted>"
        out += line

    for c in range(n_in):
        out += _LINE + "in_batch[" + String(c) + "] name='"
        out += in_schema.field_name(c) + "'"
        out += " type=" + _at_str(in_schema.field_arrow_type(c))
        out += " nullable=" + _bit(in_schema.field_nullable(c))

    return out^
