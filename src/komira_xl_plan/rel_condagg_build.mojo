# =============================================================================
# rel_condagg_build.mojo — ★ SUMIF / COUNTIF / AVERAGEIF, WITH NO ENGINE.
#                            The SINGULAR conditional aggregates, which are the
#                            spelling real spreadsheets use.
# =============================================================================
#
# ⇒ THE CORRECTNESS ARGUMENT IS THEREFORE A DIFFERENT ONE, AND IT IS WORTH
# STATING RATHER THAN INHERITING. It is not "the plan built here is the plan
# Excel executes"; it is that every PART of the plan is a part the two existing
# builders already emit:
#
#     the leaf + the filter   `rel_filter_build.filtered_scan`   (shared, ONE
#                                                                 spelling)
#     the aggregate           `rel_agg_build._agg_expr_for_name` (shared, and
#                                                                 it reads the
#                                                                 table's tag)
#
# so this file assembles, and assembles only. The only thing it OWNS is the
# criteria parse, which no other site in the tree has.
#
# ============ ★ WHY THIS SHAPE IS EXECUTABLE AND THE INLINE ONE IS NOT =======
#
# The plan is `AGGREGATE <- FILTER <- SCAN`. `fn_rel_dynarray.
# lower_agg_over_filter` already BUILDS and RUNS exactly that shape for
# `SUM(FILTER(...))` — over a RESIDENT batch, through
# `materialize_inmem_agg_plan`. Its own docstring records that **both** narrow
# terminals refuse the named-arm version: `materialize_scalar_agg_plan` requires
# a BARE scan under the aggregate and `materialize_filter_project_plan` refuses
# an aggregate anywhere in the chain.
#
# ⇒ SO THESE THREE NAMES CARRY `XLR_PLAN` AND NOTHING ELSE. The C door runs on
# `ctx.materialize_plan`, the GENERAL walker, which serves an aggregate over a
# filter. Giving them `XLR_INLINE_REL` would route them at a terminal that
# refuses the shape and convert a clean `#NAME?` into a Mojo exception — the
# same reasoning `xl_fn_table._plan_only_note` states for MEDIAN/STDEV/VAR.
#
# ==================== ⛔ EXCEL CRITERIA ARE NOT SQL PREDICATES ===============
#
# The divergences are REAL, they are SILENT, and each one is written into the
# census row rather than resolved by picking a side. See `_condif_note()` in
# `xl_fn_table.mojo` for the reader-facing statement; the reasons live here:
#
# Encapsulation rule : values only. No `UnsafePointer` in any
# signature, no wildcard origins, no `unsafe_from_address`.
# =============================================================================

from komira_core.plan.expr import (
    Expr, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
)
from komira_core.plan.logical_plan import LogicalPlan, ExprArray, AggExprArray
from komira_core.plan.scalar_value import ScalarValue

from .bound_relation import BoundRelation
from .formula_ast import FormulaAst, NODE_NUMBER, NODE_STRING
from .rel_agg_build import _agg_expr_for_name
from .rel_filter_build import filtered_scan
from .xl_text_compare import excel_comparison
from .xl_fn_table import (
    xl_agg_needs_column,
    xl_plan_agg_tag,
    XLA_COUNT,
    XLA_NONE,
)


struct _Criteria(Copyable, Movable):
    """An Excel criteria string, split: the comparison operator it names and the
    OPERAND text after it. Modelled on `fn_rel_args._SortSpec` — a struct rather
    than a tuple, because this package's `Optional[...]` returns are read with
    `.value().copy()` throughout and a `String` field needs the explicit copy."""

    var op: UInt8
    var operand: String

    def __init__(out self, op: UInt8, var operand: String):
        self.op = op
        self.operand = operand^

    def copy(self) -> Self:
        return Self(self.op, self.operand.copy())


def _criteria_op(text: String) -> _Criteria:
    """Split an Excel criteria STRING into its leading comparison operator and
    the operand text. A criteria with no leading operator is EQUALITY, which is
    what `COUNTIF(range, "shipped")` means.

    ⚠ THE TWO-CHARACTER OPERATORS MUST BE TESTED FIRST. `">="` starts with
    `">"`, so a ladder that checks the one-character forms first parses `">=5"`
    as `> "=5"` — a comparison against a text operand that begins with an equals
    sign. That is not a refusal, it is a WRONG ROW SET, which is the failure
    mode this whole file is written against.

    ⚠ IT IS TOTAL — every string names an operator, defaulting to `BIN_EQ`. The
    EMPTY OPERAND is what the caller refuses on: `"<>"` and `"="` alone are
    Excel's non-blank / blank tests, and comparing against `""` selects a
    different set of rows."""
    var bs = text.as_bytes()
    var n = len(bs)
    if n >= 2:
        var b0 = bs[0]
        var b1 = bs[1]
        if b0 == UInt8(0x3E) and b1 == UInt8(0x3D):  # >=
            return _Criteria(BIN_GE, _drop(text, 2))
        if b0 == UInt8(0x3C) and b1 == UInt8(0x3D):  # <=
            return _Criteria(BIN_LE, _drop(text, 2))
        if b0 == UInt8(0x3C) and b1 == UInt8(0x3E):  # <>
            return _Criteria(BIN_NE, _drop(text, 2))
    if n >= 1:
        var c0 = bs[0]
        if c0 == UInt8(0x3E):  # >
            return _Criteria(BIN_GT, _drop(text, 1))
        if c0 == UInt8(0x3C):  # <
            return _Criteria(BIN_LT, _drop(text, 1))
        if c0 == UInt8(0x3D):  # =
            return _Criteria(BIN_EQ, _drop(text, 1))
    return _Criteria(BIN_EQ, text.copy())


def _drop(s: String, k: Int) -> String:
    """`s` with its first `k` BYTES removed. The dropped bytes are always ASCII
    comparison operators chosen by `_criteria_op`, so this never splits a UTF-8
    sequence."""
    var bs = s.as_bytes()
    var buf = List[UInt8]()
    for i in range(k, len(bs)):
        buf.append(bs[i])
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _has_wildcard(s: String) -> Bool:
    """True if the operand contains an Excel wildcard (`*` or `?`).

    ⛔ THE PRESENCE OF ONE IS A REFUSAL, NOT AN ESCAPE. Excel matches `"a*"` as
    a pattern; comparing it as a literal string answers a different question and
    returns a number that looks right. The engine HAS a pattern kernel
    (`STR_LIKE`), so this is a widening someone can do on purpose — it is not
    done accidentally here."""
    var bs = s.as_bytes()
    for i in range(len(bs)):
        if bs[i] == UInt8(0x2A) or bs[i] == UInt8(0x3F):
            return True
    return False


def _operand_literal(operand: String) -> Optional[ScalarValue]:
    """The engine literal an Excel criteria OPERAND denotes.

    ⚠ A NUMERIC-LOOKING OPERAND IS A NUMBER, and that is Excel's rule rather
    than a convenience: `COUNTIF(qty, "25")` matches the numeric cell 25, not
    the text "25". The same coercion `FormulaValue.coerce_number` applies to a
    numeric-looking text in a numeric context.

    Returns None for a wildcard operand and for an EMPTY one (see
    `_criteria_op`)."""
    if operand.byte_length() == 0:
        return Optional[ScalarValue]()
    if _has_wildcard(operand):
        return Optional[ScalarValue]()
    try:
        return Optional[ScalarValue](ScalarValue.from_float(Float64(operand)))
    except:
        return Optional[ScalarValue](ScalarValue.from_string(operand))


def build_criteria_predicate(
    src: FormulaAst, crit_idx: Int, crit_rel: BoundRelation
) raises -> Optional[Expr]:
    """★ THE ONE PIECE THIS FILE OWNS: an Excel CRITERIA argument to an engine
    filter predicate over `crit_rel`'s column.

        SUMIF(status, "shipped", amount)   ->  lower(status) = 'shipped'
        SUMIF(qty,    ">25",     amount)   ->  qty           > 25
        COUNTIF(qty,  25)                  ->  qty           = 25

    ⭐ THE `lower()` ON THE TEXT ARM IS EXCEL'S CASE-INSENSITIVE TEXT
    COMPARISON AND IT IS NOT AN OPTIMISATION. `"acme"` matches `ACME` in a
    spreadsheet; the engine's `BIN_EQ` over strings is byte-exact. This file's
    header carried that as a written-down, UNFIXED divergence until 2026-09-11.
    The lowering belongs to `xl_text_compare.excel_comparison`, which both this
    builder and `rel_filter_build` call — read its header for why the operand
    is folded in Mojo rather than by a second `lower()` in the plan, and for
    the ASCII envelope it refuses outside of.

    ⚠⚠ IT IS NOT `rel_filter_build.build_filter_predicate` AND IT COULD NOT BE.
    A `FILTER` condition is a BINOP NODE — `FILTER(ord, amount>25)` — whose
    operator the parser has already recognised. A conditional-aggregate criteria
    is a single LITERAL node whose operator is INSIDE A STRING, and the criteria
    range is named by a DIFFERENT argument. Two different parses of two
    different Excel grammars; sharing one function would mean one of them
    accepting the other's shape.

    Returns None — an out-of-envelope criteria — for: a non-literal criteria
    node (a call, a nested comparison, a bound name), a wildcard operand, an
    empty operand (`"<>"` / `"="` alone), a TEXT operand carrying a non-ASCII
    byte (`excel_comparison`'s header states why that one is a refusal rather
    than a comparison), and a criteria range with no column selector."""
    if not crit_rel.has_column():
        return Optional[Expr]()

    var node = src.get(crit_idx)
    var bop = BIN_EQ
    var lit: ScalarValue
    if node.tag == NODE_NUMBER:
        # A bare numeric criteria is equality. `COUNTIF(qty, 25)`.
        lit = ScalarValue.from_float(node.num)
    elif node.tag == NODE_STRING:
        var split = _criteria_op(node.text)
        bop = split.op
        var lit_opt = _operand_literal(split.operand)
        if not lit_opt:
            return Optional[Expr]()
        lit = lit_opt.value().copy()
    else:
        # ⚠ A CELL REFERENCE, A CALL OR AN EXPRESSION. Excel admits all three as
        # a criteria; folding one needs an EVALUATOR, which a ctx-free builder
        # does not have — the same reason `build_filter_predicate` refuses
        # `DATE(y,m,d)` on its right side.
        return Optional[Expr]()

    return excel_comparison(bop, crit_rel.column, lit^)


def build_cond_agg_plan(
    up: String,
    crit_rel: BoundRelation,
    value_rel: BoundRelation,
    var pred: Expr,
) raises -> Optional[LogicalPlan]:
    """★ `SCAN(<named table>) -> FILTER(criteria) -> AGGREGATE(<agg>)` — the
    plan `SUMIF` / `COUNTIF` / `AVERAGEIF` denotes, with NO `EngineContext` in
    the signature.

    ⚠ **THE SIGNATURE IS THE CLAIM**, exactly as in `build_rel_agg_plan` and
    `build_filter_plan`: a landing that adds a context parameter breaks
    `test_build_cond_agg_plan_needs_no_engine_constructed_at_all` at COMPILE
    time, which is the only way "needs no engine" can be asserted.

    ⚠ THE AGGREGATE COMES FROM `_agg_expr_for_name`, KEYED ON THE `IF` NAME
    ITSELF. `xl_fn_table` gives SUMIF the tag `XLA_SUM`, COUNTIF `XLA_COUNT` and
    AVERAGEIF `XLA_MEAN`, so the mapping onto `komira_core.plan.agg_expr` is the
    SAME ladder the unconditional aggregates use and there is no second one to
    forget. ⇒ COUNTIF inherits `XLA_COUNT`'s selector-less arm — `count(*)` over
    the FILTERED rows, which is exactly what COUNTIF counts, and which is why it
    is the one of the three that needs no value range.

    ⚠ THERE IS NO PROJECTION. `filtered_scan` is used rather than
    `build_filter_plan` precisely because the latter projects the array's column
    — which here is the CRITERIA column — and projecting it would drop the
    summed column underneath the aggregate. A wrong SCHEMA, silently, from a
    node whose only purpose was a column selector.

    ⛔⛔ THE COLUMN-LESS GUARD IS HERE AND IT WAS MISSING ON THE FIRST BUILD.
    `_agg_expr_for_name` does NOT check it — its own docstring records that the
    refusal deliberately lives in the CALLER, so that the refusal ORDER stays
    identical between the named and resident arms of `build_rel_agg_plan`.
    Omitting it here did not refuse and did not raise: `SUMIF(qty, ">25", door)`
    over a SELECTOR-LESS value binding built `sum(col(""))` — a plan naming a
    column that does not exist, which no schema check in this package can see
    and which the executor would meet as a resolution failure far from its
    cause. Caught by `test_a_column_less_value_range_is_refused_before_any_plan_
    exists` on the first run of this file's gate; the guard reads
    `xl_agg_needs_column`, which is the SAME predicate `build_rel_agg_plan`
    uses, so COUNTIF inherits `XLA_COUNT`'s exemption for free.

    Returns None when the name carries no aggregate tag on the plan surface, or
    when a value-taking aggregate has no column selector on its value range."""
    var tag = xl_plan_agg_tag(up)
    if tag != XLA_NONE and xl_agg_needs_column(tag) and not value_rel.has_column():
        return Optional[LogicalPlan]()

    # ⭐⭐ COUNTIF / COUNTIFS COUNT **ROWS**, SO THE AGGREGATE IS `count(*)` AND
    # NOT `count(<the criteria column>)`. THIS FUNCTION'S OWN DOCSTRING HAS SAID
    # SO SINCE IT LANDED; THE CODE DID NOT, AND THE DIFFERENCE WAS NOT COSMETIC.
    #
    # `_agg_expr_for_name` builds `count(*)` from an EMPTY selector and
    # `count(<col>)` from a non-empty one — the distinction Excel's
    # unconditional COUNT needs (`COUNT(qty)` is the non-null count, `COUNT(2D
    # range)` is the row count). A CONDITIONAL count has no such choice: there
    # is no separate value range in either layout, so the selector reaching here
    # is the CRITERIA column, and passing it made the plan `count(<criteria
    # col>)`.
    #
    # ⚠ THE TWO ARE THE SAME NUMBER AND THE OLD PLAN WAS NOT A WRONG ANSWER.
    # Every criteria predicate is a COMPARISON, comparisons are NULL-rejecting
    # under 3VL, so no row surviving the filter has a NULL criteria cell and the
    # non-null count equals the row count. `test_countif_lowers_to_count_not_sum`
    # already states exactly that.
    #
    # ⛔ IT WAS AN UNEXECUTABLE PLAN, WHICH IS WORSE THAN A DIFFERENT ONE.
    # MEASURED 2026-09-11 over a parquet `status` STRING column through
    # `ctx.materialize_plan`, `COUNTIF(status, "acme")` raised:
    #
    #     agg_node_exec: out-of-envelope 0-key scalar agg over a
    #     FILTER?->SCAN(parquet) (every agg must be SUM/COUNT/MIN/MAX/MEAN over
    #     a plain col_ref input — or COUNT(*) — with an int/float input DType …)
    #
    # `count(<col>)` over a non-int/float column is declined by the 0-key
    # executor; `count(*)` is IN the envelope, by that message's own words. So
    # the singular spelling real sheets use most — a COUNTIF over a TEXT
    # range — could not execute at all, whatever the predicate said. ⚠ THE
    # ENGINE-SIDE GAP IS REAL AND IS NOT CLOSED BY THIS LINE: `count(<string
    # col>)`, i.e. COUNTA, is still unexecutable in that envelope. What this
    # closes is a lowering that walked into it for no reason.
    var agg_column = value_rel.column
    if tag == XLA_COUNT:
        agg_column = String("")
    var agg_opt = _agg_expr_for_name(up, agg_column)
    if not agg_opt:
        return Optional[LogicalPlan]()

    var aggs = AggExprArray()
    aggs.append(agg_opt.take())
    return Optional[LogicalPlan](
        LogicalPlan.aggregate(
            ExprArray(), aggs^, filtered_scan(crit_rel, pred^)
        )
    )
