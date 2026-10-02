# =============================================================================
# rel_filter_build.mojo — ★ SCAN -> FILTER -> (PROJECT?), WITH NO ENGINE.
#                           The SECOND ctx-free builder, and the first that is
#                           not an aggregate.
# =============================================================================
#
#   * `_lower_filter_named`'s refusals are properties of the AST and the BINDING
#     — a non-comparison root, an unbound LHS, a cross-relation condition, a
#     non-literal RHS. Every one of them is decidable with no engine, which is
#     exactly what makes the extraction total.
#
# ⚠ THE PROJECT GOES **ABOVE** THE FILTER. A projection under the predicate
# drops the predicate's own column whenever the caller did not select it, which
# is a wrong ROW SET rather than a wrong shape — invisible to a schema check.
#
# ⚠ AN EMPTY RESULT IS NOT DECIDED HERE. `_lower_filter_named` maps zero rows to
# `#CALC!`, which is a fact about the SPREADSHEET's value model and not about
# the plan; a wire producer must hand back the empty relation. Keeping that
# decision at the executing caller is what lets the two arms differ where they
# genuinely should.
#
# Encapsulation rule : values only. No `UnsafePointer` in any
# signature, no wildcard origins.
# =============================================================================

from komira_core.plan.expr import (
    Expr, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
)
from komira_core.plan.logical_plan import LogicalPlan, ExprArray
from komira_core.plan.scalar_value import ScalarValue

from .bound_relation import BoundRelation
from .xl_text_compare import excel_comparison
from .formula_ast import (
    FormulaAst,
    FormulaNode,
    NODE_BINOP,
    NODE_CALL,
    NODE_NAME,
    NODE_NUMBER,
    NODE_STRING,
    OP_EQ,
    OP_NE,
    OP_LT,
    OP_LE,
    OP_GT,
    OP_GE,
)
from .formula_bindings import FormulaBindings
from .rel_agg_build import _named_scan


def is_filter_over_relation(
    src: FormulaAst, node: FormulaNode, bindings: FormulaBindings
) -> Bool:
    """True if `node` is a `FILTER(array, cond)` call whose `array` (arg 0) is a
    NAME bound to a relation — the REL-in-REL fusion trigger the fold pass keys
    on so that `SUM(FILTER(...))` / `COUNT(FILTER(...))` routes to
    `lower_agg_over_filter` rather than folding the FILTER independently and
    re-scanning.

    ⚠ MOVED HERE FROM `fn_rel_dynarray` (2026-09-04) WITH ITS CALLERS INTACT.
    `rel_fold`, `fn_rel_dynarray` and now `xl_plan_build` all ask this question;
    there must be ONE spelling of it, or the fold pass and the plan builder can
    disagree about what a FILTER *is*."""
    if node.tag != NODE_CALL:
        return False
    if node.text.upper() != String("FILTER"):
        return False
    if len(node.args) < 1:
        return False
    var a0 = src.get(node.args[0])
    if a0.tag == NODE_NAME and bindings.lookup_relation(a0.text):
        return True
    return False


def build_filter_predicate(
    src: FormulaAst,
    cond_idx: Int,
    bindings: FormulaBindings,
    array_rel: BoundRelation,
) raises -> Optional[Expr]:
    """Parse a v1 FILTER condition into an engine filter predicate. The envelope
    is a single `col OP scalar-literal` comparison, where `col` is a NAME bound
    to a relation that is the SAME relation as `array_rel` and the RHS is a
    numeric or text literal. Returns None (-> `#VALUE!` at the caller) for any
    out-of-envelope shape:
      * a non-comparison root (an arithmetic/AND/OR/nested op -> a multi-clause
        or computed condition);
      * a LHS that is not a bound COLUMN of the SAME relation as `array_rel`
        (`same_relation` — a cross-relation condition is out of envelope);
      * a RHS that is not a numeric/text literal.

    ⚠ A TEXT LITERAL CARRYING A NON-ASCII BYTE USED TO BE ON THAT LIST and was
    removed 2026-09-11. The operand and the column are now folded by ONE
    function — `komira_core.eval.unicode_case.unicode_lower_bytes`, which is
    what the column's `STRFN_LOWER` kernel calls — so there is no text operand
    this builder can fold out of agreement with the engine.

    ⭐ A TEXT COMPARISON IS CASE-INSENSITIVE HERE AND IT IS EXCEL'S RULE, NOT
    A CONVENIENCE. `FILTER(ord, status="acme")` keeps the `ACME` rows in a
    spreadsheet, and it did not here until 2026-09-11 — the same divergence
    `rel_condagg_build`'s header carried WRITTEN DOWN and unfixed for the
    conditional aggregates, which `FILTER` shares because it shares the
    question rather than the code. Both now lower through ONE function,
    `xl_text_compare.excel_comparison`; ⛔ do not re-inline the comparison
    here, because two spellings of "what does Excel mean by `=`" are free to
    drift and the drift is a wrong ROW SET no schema check can see.

    ⚠ THE FOLD IS ON THE LITERAL ARM ONLY, BY CONSTRUCTION. `col OP col` is
    not in this envelope (the RHS must be a literal), so there is no second
    shape to remember.

    ⚠ `same_relation` IS NOT AN ADDRESS TEST ON THE NAMED ARM — it compares the
    CATALOG NAME. Two named bindings over one table hold two distinct
    placeholder batches, so an address test would call them different relations
    and refuse every named FILTER whose predicate column was bound separately
    from its array. See `BoundRelation.same_relation`.

    ⚠ THERE IS NO DATE OR BOOLEAN LITERAL IN THIS ENVELOPE, and that is a
    SURFACE fact rather than an engine one: an Excel formula writes a date as a
    serial number or as `DATE(y,m,d)`, and the second is a CALL — not a literal
    node — so a ctx-free builder cannot fold it. A date-typed predicate is
    therefore refused rather than mis-parsed."""
    var cond = src.get(cond_idx)
    if cond.tag != NODE_BINOP:
        return Optional[Expr]()
    var bop_opt = _map_cmp_op(cond.op)
    if not bop_opt:
        return Optional[Expr]()  # not a comparison operator -> out of envelope
    var bop = bop_opt.value()

    # LHS: a NAME bound to a relation (the condition column), SAME relation as
    # `array`.
    var lnode = src.get(cond.left)
    if lnode.tag != NODE_NAME:
        return Optional[Expr]()
    var col_rel_opt = bindings.lookup_relation(lnode.text)
    if not col_rel_opt:
        return Optional[Expr]()
    var col_rel = col_rel_opt.value().copy()
    if not col_rel.has_column():
        return Optional[Expr]()
    if not array_rel.same_relation(col_rel):
        return Optional[Expr]()  # cross-relation condition -> out of envelope

    # RHS: a numeric or text literal.
    var rnode = src.get(cond.right)
    var lit: ScalarValue
    if rnode.tag == NODE_NUMBER:
        lit = ScalarValue.from_float(rnode.num)
    elif rnode.tag == NODE_STRING:
        lit = ScalarValue.from_string(rnode.text)
    else:
        return Optional[Expr]()

    return excel_comparison(bop, col_rel.column, lit^)


def _map_cmp_op(op: UInt8) -> Optional[UInt8]:
    """Map a formula-AST comparison operator to the engine `BIN_*` predicate op.
    Returns None for a non-comparison operator (arithmetic / concat)."""
    if op == OP_EQ:
        return Optional[UInt8](BIN_EQ)
    if op == OP_NE:
        return Optional[UInt8](BIN_NE)
    if op == OP_LT:
        return Optional[UInt8](BIN_LT)
    if op == OP_LE:
        return Optional[UInt8](BIN_LE)
    if op == OP_GT:
        return Optional[UInt8](BIN_GT)
    if op == OP_GE:
        return Optional[UInt8](BIN_GE)
    return Optional[UInt8]()


def filtered_scan(rel: BoundRelation, var pred: Expr) raises -> LogicalPlan:
    """★ `FILTER(pred) <- SCAN(<named table>)` — THE ONE SPELLING OF THE
    FILTERED SCAN, with no projection above it.

    ⚠ IT IS A FILE-LEVEL FUNCTION AND NOT AN INLINE PAIR OF CALLS BECAUSE IT
    HAS TWO CALLERS AND THEY DIFFER IN WHAT GOES **ABOVE** IT.
    `build_filter_plan` puts the column selector's PROJECT on top;
    `rel_condagg_build.build_cond_agg_plan` puts an AGGREGATE on top and must
    NOT project, because the aggregate names its own column and a projection of
    the CRITERIA column would drop the summed one. Two callers spelling
    `LogicalPlan.filter(pred, _named_scan(rel))` by hand would be byte-identical
    today and free to drift tomorrow, and the drift would be a wrong ROW SET
    that no schema check can see — the same argument this file's header makes
    about re-deriving the plan."""
    return LogicalPlan.filter(pred^, _named_scan(rel))


def build_filter_plan(
    array_rel: BoundRelation, var pred: Expr
) raises -> LogicalPlan:
    """★ `SCAN(<named table>) -> FILTER(pred) -> PROJECT?` — the plan
    `FILTER(<name>, <cond>)` denotes, with NO `EngineContext` in the signature.

    ⚠ **THE SIGNATURE IS THE CLAIM**, exactly as in `build_rel_agg_plan`: a
    landing that adds a context parameter breaks
    `test_build_filter_plan_needs_no_engine_constructed_at_all` at COMPILE time,
    which is the only way "needs no engine" can be asserted — a runtime test
    cannot observe the ABSENCE of an argument.

    ⚠ IT RAISES ON A RESIDENT BINDING rather than returning an `Optional`, via
    `_named_scan` -> `BoundRelation.named_table`. A resident leaf cannot be
    built here EVEN IN PRINCIPLE (it is `from_record_batch_typed(ctx, batch)`),
    so it is not a refusal this function can express — the caller checks
    `is_named()` and reports `XL_BUILD_RESIDENT`, which sends the user to a
    DIFFERENT edit than an out-of-envelope formula does.

    ⚠ THE PROJECTION IS THE COLUMN SELECTOR AND IT GOES ABOVE THE FILTER, for
    the reason this file's header states. An empty selector emits the whole
    table — a 2D range, which is what `FILTER(<table>, …)` means."""
    var plan = filtered_scan(array_rel, pred^)
    if array_rel.has_column():
        var exprs = ExprArray()
        exprs.append(Expr.col_ref(array_rel.column))
        plan = LogicalPlan.project(exprs^, plan^)
    return plan^
