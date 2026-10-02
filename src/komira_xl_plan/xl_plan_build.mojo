# =============================================================================
# xl_plan_build.mojo — ★ A FORMULA IN, A `LogicalPlan` OUT, WITH NO ENGINE.
# =============================================================================
#
# ================== THE MEASUREMENT THAT PRODUCED THIS FILE ==================
#
#     plan_producer.mojo        a PlanCarrier -> bytes
#     scan_frame_producer.mojo  a ScanFrame   -> bytes
#     sql_producer.mojo         SQL text      -> bytes
#     — no xl_producer —        `git grep xl_producer` returned NOTHING
#
# ============ ★★ THE SIGNATURE IS THE CLAIM — THERE IS NO `ctx` HERE ========
#
# ============== ⚠⚠ IT DISPATCHES ONLY TO BUILDERS THE EXECUTOR USES =========
#
# THIS IS THE WHOLE CORRECTNESS ARGUMENT AND IT IS A STRUCTURAL ONE, not a
# tested one. The wrong shape for this file is a second lowering tree: a
# `SUM(name)` arm here that builds `AGGREGATE(SUM(col)) <- SCAN(source)` its own
# way would be byte-identical to `fn_rel_agg`'s TODAY and free to drift
# tomorrow, and the drift would be a WRONG ANSWER on the wire while every test
# of the inline path stayed green. So this file builds NOTHING. Every arm calls
# the SAME `build_*_plan` the corresponding `lower_*` calls, so "the plan Excel
# executes" and "the plan a caller with no engine obtains" are ONE expression.
#
# ⚠ AND THE THIRTEEN `require_resident` SITES ARE OUT OF SCOPE PERMANENTLY-ISH,
# not pending: SUMIFS / COUNTIFS / XLOOKUP / VLOOKUP / MATCH / INDEX / UNIQUE
# and the whole-sheet batch path bind a RESIDENT `RecordBatch`, whose leaf is
# `from_record_batch_typed(ctx, ...)` — a leaf that NEEDS the engine, and which
# `plan_wire_codec._source_to_wire` refuses by name anyway
# (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`). A resident binding is refused here
# as `_XL_BUILD_RESIDENT`, which is a DIFFERENT edit for the caller than an
# un-extracted verb: bind the name through a catalog table.
#
# Encapsulation rule : values only. No `UnsafePointer` in any
# signature, no wildcard origins, no `unsafe_from_address`, no partial-move
# take_pointee — the plan leaves through `Optional.take()`.
# =============================================================================

from komira_core.plan.expr import Expr, BIN_AND
from komira_core.plan.logical_plan import LogicalPlan

from .bound_relation import BoundRelation
from .formula_ast import FormulaAst, NODE_CALL
from .formula_bindings import FormulaBindings
from .formula_parser import parse_formula
from .rel_agg_build import build_rel_agg_plan, build_bivar_agg_plan
from .rel_condagg_build import build_cond_agg_plan, build_criteria_predicate
from .rel_filter_build import build_filter_plan, build_filter_predicate
from .fn_rel_args import _bound_array
from .xl_agg_identity import (
    excel_cond_value_range_is_text,
    excel_range_is_text,
    excel_zero_cell_plan,
    excel_zero_when_empty,
)
from .xl_fn_table import (
    xl_condagg_is_plural,
    xl_fn_lookup,
    xl_plan_agg_tag,
    xl_plan_family,
    xl_plan_reaches,
    XLA_COUNT,
    XLA_MAX,
    XLA_MIN,
    XLA_NONE,
    XLA_SUM,
    XLF_AGG,
    XLF_BIVAR_AGG,
    XLF_CONDAGG,
)


# =============================================================================
# THE THREE OUTCOMES — and why a refusal is a VALUE here rather than an `Error`
# =============================================================================

comptime XL_BUILD_OK: Int32 = 0
"""A plan was built. `take_plan()` returns it."""

comptime XL_BUILD_NO_PLAN: Int32 = 1
"""The formula lowers to NO PLAN AT ALL on a ctx-free path.

Three different things reach this, deliberately under one status because the
caller's edit is the same one (rewrite the formula, or extract the builder):
    engine, which is exactly what makes them reachable here."""

comptime XL_BUILD_RESIDENT: Int32 = 2
"""The relation is bound to a RESIDENT `RecordBatch`, not to a catalog table.

★ A SEPARATE STATUS BECAUSE IT SENDS THE CALLER TO A DIFFERENT EDIT. A resident
binding's leaf is `from_record_batch_typed(ctx, batch)` — live heap data inside
the IR — so there is no ctx-free builder for it EVEN IN PRINCIPLE, and the wire
would refuse the result anyway (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`). The
fix is not to rewrite the formula: it is to bind the name through a catalog
table (`SqlCatalog.add_parquet`), which is the arm this whole track added."""


struct XlPlanBuild(Movable):
    """The outcome of `build_xl_plan`: a plan, or a named refusal.

    ⚠ MOVABLE, NOT `Copyable`, and forced rather than chosen — `LogicalPlan` is
    a recursive tree with an explicit `.copy()`, so `Optional[LogicalPlan]`
    synthesizes no copy constructor. That is the right shape anyway: an implicit
    copy here is a deep copy of a plan tree.
    """

    var _plan: Optional[LogicalPlan]
    var _status: Int32
    var _detail: String

    def __init__(out self, var plan: Optional[LogicalPlan], status: Int32, var detail: String):
        self._plan = plan^
        self._status = status
        self._detail = detail^

    @staticmethod
    def built(var plan: LogicalPlan) -> Self:
        return Self(Optional[LogicalPlan](plan^), XL_BUILD_OK, String(""))

    @staticmethod
    def no_plan(var detail: String) -> Self:
        return Self(Optional[LogicalPlan](), XL_BUILD_NO_PLAN, detail^)

    @staticmethod
    def resident(var detail: String) -> Self:
        return Self(Optional[LogicalPlan](), XL_BUILD_RESIDENT, detail^)

    @always_inline
    def status(self) -> Int32:
        return self._status

    @always_inline
    def is_built(self) -> Bool:
        return self._status == XL_BUILD_OK

    def detail(self) -> String:
        """Why this formula built no plan. Empty on `XL_BUILD_OK`."""
        return self._detail.copy()

    def refusal_message(self, formula: String) -> String:
        """★ THE ONE PROSE SPELLING OF A REFUSAL, so a second caller cannot
        drift from the first.

        ⚠ TOTAL BY CONSTRUCTION, AND THE FALLBACK IS NOT A THIRD MEANING. An
        unrecognised status is a defect in this build, not in the formula, and
        it says so — a producer that returned a plan for a status it did not
        understand is the failure this whole file is against.
        """
        var name = String("XL_BUILD_UNRECOGNISED")
        if self._status == XL_BUILD_OK:
            name = String("XL_BUILD_OK")
        elif self._status == XL_BUILD_NO_PLAN:
            name = String("XL_BUILD_NO_PLAN")
        elif self._status == XL_BUILD_RESIDENT:
            name = String("XL_BUILD_RESIDENT")
        return (
            name
            + String("(")
            + String(Int(self._status))
            + String("): ")
            + self._detail
            + String(" formula: `")
            + formula
            + String("`")
        )

    def take_plan(mut self) raises -> LogicalPlan:
        """The plan, MOVED out. Raises on either refusal status rather than
        returning an empty plan — a caller that skipped the status check must
        find out here and not encode a default."""
        if not self._plan:
            raise Error(
                "XlPlanBuild.take_plan: this build carries NO plan (status "
                + String(Int(self._status))
                + "). Check `is_built()` first; the reason is in `detail()`: "
                + self._detail
            )
        return self._plan.take()


def build_xl_plan(
    formula: String, bindings: FormulaBindings
) raises -> XlPlanBuild:
    """★ THE EXCEL SURFACE'S PLAN BUILDER — a formula to a `LogicalPlan`, with
    no engine in frame.

        var b = FormulaBindings()
        b.bind_relation(String("amount"), BoundRelation(named_table, "o_amount"))
        var built = build_xl_plan(String("SUM(amount)"), b)
        if built.is_built():
            var plan = built^.take_plan()        # SCAN(parquet) -> AGGREGATE

    THE ENVELOPE, and it is small on purpose — see the header's *"only builders
    the executor uses"* argument:

      `SUM|AVERAGE|COUNT|MIN|MAX(<name>)` where `<name>` is bound to a NAMED
      (catalog-table) relation, lowering through `fn_rel_agg.build_rel_agg_plan`
      — the SAME function `_lower_rel_agg_named` calls, so the plan built here
      is the plan Excel executes, by construction and not by comparison.

    EVERYTHING ELSE IS REFUSED, and the status says which kind:
      `XL_BUILD_NO_PLAN`   not a relational verb, or a verb whose builder has
                           not been extracted, or arguments out of envelope
      `XL_BUILD_RESIDENT`  the binding is a resident `RecordBatch`

    ⚠ THE REFUSAL ORDER MATTERS AND MIRRORS THE EXECUTOR'S. `lower_rel_agg`
    dispatches `is_named()` FIRST and only then applies the two pure refusals
    (`fn_rel_agg.mojo:140`), so a NAMED `SUM` with no column selector must be
    `NO_PLAN` (the column-less `#NAME?`) and a RESIDENT `SUM` must be
    `RESIDENT` whatever its selector — which is what the order below produces.
    Reversing it would report a resident binding as an out-of-envelope formula
    and send the caller to rewrite a formula that is correct.

    ⚠ IT DOES NOT PARSE A SECOND TIME IN A SECOND WAY. `parse_formula` is the
    one parser the evaluator uses; a parse failure RAISES out of here (a
    malformed formula is not a refusal status — there is no plan question yet).
    """
    var src = parse_formula(formula)
    var root = src.get(src.root)
    if root.tag != NODE_CALL:
        return XlPlanBuild.no_plan(
            String(
                "this formula's root is not a function call, so it lowers to no"
                " relational plan. Most Excel formulas are SCALAR (`=1+1`,"
                " `=IF(A>0,1,2)`) and have nothing for"
                " `komira.plan.v1.WirePlanEnvelope` to carry — that is not a"
                " defect in the formula. A plan needs a relational verb over a"
                " name bound to a catalog table."
            )
        )

    var up = root.text.upper()
    if _is_rel_agg_name(up):
        return _build_rel_agg(src, root.args, bindings, up)
    # ★ THE THIRD ARM (2026-09-04). SUMIF / COUNTIF / AVERAGEIF.
    #
    # ⚠⚠ IT IS DISPATCHED ON THE **FAMILY**, AND IT HAD TO COME BEFORE THE
    # FILTER ARM AND AFTER THE AGGREGATE ONE — but the ordering is NOT what
    # makes it correct. `SUMIF` carries `XLA_SUM`, so a tag-keyed
    # `_is_rel_agg_name` would have claimed it FIRST and refused it for taking
    # three arguments; `xl_plan_family` is what keeps the two apart. See
    # `xl_fn_table.xl_plan_family`.
    if xl_plan_family(up) == Int(XLF_CONDAGG):
        return _build_cond_agg(src, root.args, bindings, up)
    # ★ THE FOURTH ARM (2026-09-04). CORREL — the first BIVARIATE aggregate
    # any surface exposes through the C door.
    if xl_plan_family(up) == Int(XLF_BIVAR_AGG):
        return _build_bivar_agg(src, root.args, bindings, up)
    # ★ THE SECOND ARM (2026-09-04). It is dispatched on `xl_plan_reaches` and
    # NOT on the aggregate tag, because FILTER is the first plan-reaching verb
    # that is not an aggregate — see `xl_fn_table.xl_plan_reaches`.
    if up == String("FILTER") and xl_plan_reaches(up):
        return _build_filter(src, root.args, bindings)

    return XlPlanBuild.no_plan(
        String("the verb `")
        + up
        + String(
            "` has no ctx-free plan BUILDER yet, so this producer cannot"
            " obtain its plan without executing it. Excel's named arms whose"
            " builder is still inside the lowering that runs it: CHOOSECOLS,"
            " GROUPBY, SORT, TAKE, MERGE."
            " Verbs over a RESIDENT batch"
            " (SUMIFS, COUNTIFS, XLOOKUP, VLOOKUP, MATCH, INDEX, UNIQUE)"
            " cannot have one: their leaf needs the engine. ⚠ DO NOT READ THE"
            " CURRENT ENVELOPE OFF THIS SENTENCE — it is"
            " `xl_fn_table`'s `XLR_PLAN` rows, which"
            " `komira_xl_functions` renders for a caller with no Mojo."
        ),
    )


def _is_rel_agg_name(up: String) -> Bool:
    """★ THE ONE QUESTION THIS FILE ASKS ABOUT A NAME, and since 2026-09-04 it
    is not answered here.

    ⚠ IT STILL ONLY DECIDES WHICH ARM TO DISPATCH TO. `build_rel_agg_plan`
    remains the authority on whether a plan exists — a disagreement between the
    two is a `NO_PLAN` refusal and not a wrong plan, which is the property the
    old spelling had for the same reason and must keep.

    ⚠⚠ AND IT ASKS THE **FAMILY** AS WELL AS THE TAG, SINCE 2026-09-04. It was
    `xl_plan_agg_tag(up) != XLA_NONE` while every tag-carrying name was a plain
    `SUM(<name>)`. `SUMIF` carries `XLA_SUM` as its payload and takes two or
    three arguments over a FILTER, so the tag-only form would have claimed it
    here and refused it in `_build_rel_agg`'s arity guard — the census
    advertising a verb the door refuses, which is precisely what
    `test_every_plan_reaching_row_is_DISPATCHABLE_by_build_xl_plan` exists to
    catch."""
    return (
        xl_plan_family(up) == Int(XLF_AGG) and xl_plan_agg_tag(up) != XLA_NONE
    )


def _build_rel_agg(
    src: FormulaAst, args: List[Int], bindings: FormulaBindings, up: String
) raises -> XlPlanBuild:
    """`SUM|AVERAGE|COUNT|MIN|MAX(<name>)` over a NAMED relation.

    ⚠ ONE ARGUMENT EXACTLY. `rel_fold` reads `args[0]` for this family and the
    fusion arm it also handles (`SUM(FILTER(...))`) is a CALL argument, which
    `_bound_array` rejects because it is not a `NODE_NAME` — so the fused shape
    lands on the `NO_PLAN` refusal below rather than silently losing the filter.
    That matters: `SUM(FILTER(ord, amount>25))` dropping its predicate would be
    a wrong NUMBER on the wire, which no schema check can catch."""
    if len(args) != 1:
        return XlPlanBuild.no_plan(
            String("`")
            + up
            + String("` takes exactly one relation argument here; got ")
            + String(len(args))
            + String(
                ". A multi-argument Excel aggregate (`SUM(a, b)`) is a sum of"
                " ADDENDS, which is a scalar expression and not one plan."
            )
        )

    var rel_opt = _bound_array(src, args[0], bindings)
    if not rel_opt:
        return XlPlanBuild.no_plan(
            String("the argument of `")
            + up
            + String(
                "` is not a bare NAME bound to a relation. A nested call"
                " (`SUM(FILTER(ord, amount>25))` — the fusion arm) or a scalar"
                " expression has no ctx-free builder; bind a name to a catalog"
                " table and aggregate it directly."
            )
        )
    var rel = rel_opt.value().copy()

    # ★ THE ARM ORDER IS `lower_rel_agg`'s: NAMED-vs-RESIDENT first, the two
    # pure refusals second. See this function's caller docstring.
    if not rel.is_named():
        return XlPlanBuild.resident(
            String("the relation bound to this `")
            + up
            + String(
                "` is a RESIDENT RecordBatch. Its plan leaf would be"
                " `from_record_batch_typed(ctx, batch)` — live heap data inside"
                " the IR, which needs an engine to build and which the codec"
                " refuses by name (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`)."
                " Bind the name through a catalog table"
                " (`SqlCatalog.add_parquet`) and the leaf becomes a"
                " `ParquetSource` the wire already carries."
            )
        )

    # THE SHARED BUILDER. Not a re-derivation — this is the function
    # `_lower_rel_agg_named` calls, which is what makes the produced plan the
    # executed plan.
    var plan_opt = build_rel_agg_plan(up, rel)
    if not plan_opt:
        return XlPlanBuild.no_plan(
            String("`")
            + up
            + String(
                "` over this named relation is refused by"
                " `build_rel_agg_plan` before any plan exists — the same"
                " `#NAME?` the inline path returns. Either the binding carries"
                " no COLUMN selector (every aggregate but COUNT needs one), or"
                " the name is not a REL-capable aggregate."
            )
        )

    # =====================================================================
    # ★ THE FORMULA STOPS BEING A RELATION HERE AND BECOMES A **CELL**.
    # =====================================================================
    #
    # Everything above is the relational plan, shared byte for byte with the
    # inline arm. The two lines below are the only place this package applies
    # the semantics that are about a spreadsheet CELL rather than about a
    # query: a numeric aggregate reads only the NUMERIC cells of its range,
    # and over an empty set of them it is 0 and not NULL.
    # `xl_agg_identity.mojo` owns both, states which aggregates are excluded
    # BY NAME (`AVERAGE` — its empty answer is `#DIV/0!`, which this door
    # cannot return) and records why the wrap may not move down into
    # `build_rel_agg_plan` (the inline arm's narrow terminal REFUSES a
    # `PLAN_PROJECT` root, and does not need the wrap anyway).
    if excel_range_is_text(up, rel):
        return XlPlanBuild.built(excel_zero_cell_plan(plan_opt.take()))
    var agg_tag = xl_plan_agg_tag(up)
    if agg_tag == XLA_SUM or agg_tag == XLA_MIN or agg_tag == XLA_MAX:
        return XlPlanBuild.built(excel_zero_when_empty(plan_opt.take()))
    return XlPlanBuild.built(plan_opt.take())


def _build_filter(
    src: FormulaAst, args: List[Int], bindings: FormulaBindings
) raises -> XlPlanBuild:
    """`FILTER(<name>, <col> <cmp> <literal>)` over a NAMED relation.

    ⚠ THE REFUSAL ORDER IS `_lower_filter_named`'s, ARM FOR ARM, and it has to
    be: this builder and that lowering must refuse on the same inputs or "the
    plan Excel executes" and "the plan a caller with no engine obtains" stop
    being one expression on the refusal boundary as well as on the plan.
      1. arity — exactly two arguments
      2. array — a bare NAME bound to a relation
      3. NAMED vs RESIDENT (a different edit for the caller)
      4. the predicate envelope

    ⚠ EXCEL'S OWN `FILTER` TAKES THREE ARGUMENTS. The optional `if_empty` is a
    VALUE substituted when nothing matches, which is a spreadsheet display
    decision and not part of the plan — a producer must hand back the empty
    relation and let the sheet decide. Refusing arity 3 rather than IGNORING it
    is the point: silently dropping an argument the user wrote is how a formula
    stops meaning what it says.
    """
    if len(args) != 2:
        return XlPlanBuild.no_plan(
            String("`FILTER` takes exactly two arguments here — an array and")
            + String(" one condition — and got ")
            + String(len(args))
            + String(
                ". Excel's third argument (`if_empty`) is a value substituted"
                " when nothing matches, which is a decision for the sheet and"
                " not part of the plan; it is refused rather than dropped,"
                " because silently ignoring an argument the user wrote makes"
                " the formula stop meaning what it says."
            )
        )

    var rel_opt = _bound_array(src, args[0], bindings)
    if not rel_opt:
        return XlPlanBuild.no_plan(
            String(
                "`FILTER`'s first argument is not a bare NAME bound to a"
                " relation. A nested call or a scalar expression has no"
                " ctx-free builder; bind a name to a catalog table"
                " (`SqlCatalog.add_parquet`) and filter it directly."
            )
        )
    var rel = rel_opt.value().copy()

    # ★ NAMED-vs-RESIDENT FIRST, exactly as the aggregate arm does it, so a
    # resident FILTER reports the binding problem rather than being reported as
    # an out-of-envelope condition and sending the caller to rewrite a formula
    # that is correct.
    if not rel.is_named():
        return XlPlanBuild.resident(
            String(
                "the relation bound to this `FILTER` is a RESIDENT"
                " RecordBatch. Its plan leaf would be"
                " `from_record_batch_typed(ctx, batch)` — live heap data inside"
                " the IR, which needs an engine to build and which the codec"
                " refuses by name (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`)."
                " Bind the name through a catalog table"
                " (`SqlCatalog.add_parquet`) and the leaf becomes a"
                " `ParquetSource` the wire already carries."
            )
        )

    var pred_opt = build_filter_predicate(src, args[1], bindings, rel)
    if not pred_opt:
        return XlPlanBuild.no_plan(
            String(
                "`FILTER`'s condition is outside the v1 envelope, which is ONE"
                " comparison of the form `<name> <cmp> <literal>` where"
                " `<name>` is bound to a COLUMN of the SAME catalog table as"
                " the array and `<literal>` is numeric or text. Out of"
                " envelope: an arithmetic or AND/OR root, an unbound or"
                " column-less left side, a cross-table condition, and any"
                " non-literal right side — including `DATE(y,m,d)`, which is a"
                " CALL rather than a literal and cannot be folded without an"
                " evaluator. ⚠ A TEXT literal carrying a NON-ASCII byte is NO"
                " LONGER out of envelope (2026-09-11): the operand and the"
                " column are now folded by ONE function"
                " (`komira_core.eval.unicode_case.unicode_lower_bytes`, which"
                " is what the column's `STRFN_LOWER` kernel calls), so there is"
                " no operand this builder can fold out of agreement with the"
                " engine. This is the SAME predicate builder the executing"
                " lowering uses, so a condition refused here is refused there."
            )
        )

    # THE SHARED BUILDER — the function `_lower_filter_named` calls, which is
    # what makes the produced plan the executed plan.
    return XlPlanBuild.built(build_filter_plan(rel, pred_opt.take()))


def _build_cond_agg(
    src: FormulaAst, args: List[Int], bindings: FormulaBindings, up: String
) raises -> XlPlanBuild:
    """⭐ THE WHOLE CONDITIONAL-AGGREGATE FAMILY, SINGULAR AND PLURAL:

        SUMIF(<crit>, <criteria>, [<values>])          COUNTIF(<crit>, <crit>)
        AVERAGEIF(<crit>, <criteria>, [<values>])
        SUMIFS(<values>, <crit1>, <c1>, [<crit2>, <c2>, ...])
        COUNTIFS(<crit1>, <c1>, [...])                 AVERAGEIFS(<values>, ...)

    ⛔⛔ THE TWO LAYOUTS ARE REVERSED AND THAT IS EXCEL, NOT A SPELLING.
    `SUMIF` puts the aggregate range LAST and optional; `SUMIFS` puts it FIRST
    and required. A builder that read one layout for both would AGGREGATE the
    criteria column and FILTER on the value column — a confidently wrong number
    out of a perfectly well-formed plan. `xl_fn_table.xl_condagg_is_plural` is
    where that fact is written down.

    ⚠ THE VALUE RANGE DEFAULTS TO THE FIRST CRITERIA RANGE for the singular
    forms (`SUMIF(qty, ">25")` sums `qty`), and COUNTIF/COUNTIFS have no value
    range in either layout — they count the rows the criteria select. Their
    `XLA_COUNT` tag with a column selector lowers to `count(<col>)`, which over
    the FILTERED rows is the same row set as `count(*)`: a NULL never satisfies
    a comparison, so the predicate has already removed every row `count(<col>)`
    would skip.

    ⚠ THE CRITERIA ARE CONJOINED WITH `BIN_AND`, LEFT-ASSOCIATIVELY. Excel's
    plural forms are an AND of every (range, criteria) pair; there is no OR
    form, and inventing one would answer a question the formula does not ask.

    ⚠ THE ARITY GUARD READS THE TABLE (`XlFnRow.arity_ok`) and the PARITY guard
    is here. Three names with two arity windows is exactly where a hand-written
    ladder goes stale, and the table is what `komira_xl_functions` renders to
    a caller with no Mojo — a guard that disagreed with it would refuse a call
    the census advertises. The table cannot express "an ODD number of
    arguments", so that half stays in code, next to the reason.

    THE REFUSAL ORDER IS THE OTHER ARMS', ARM FOR ARM:
      1. arity, then parity
      2. every range — a bare NAME bound to a relation
      3. NAMED vs RESIDENT (a different edit for the caller)
      4. one catalog table across every range (ONE scan leaf)
      5. the criteria envelope
    """
    var row_opt = xl_fn_lookup(up)
    if not row_opt:
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "` was dispatched to the conditional-aggregate arm and then did"
                " not resolve in `xl_fn_table`. That is a DEFECT in this build,"
                " not in the formula — the dispatch and the table have gone out"
                " of step."
            )
        )
    if not row_opt.value().arity_ok(len(args)):
        return XlPlanBuild.no_plan(
            String("`") + up + String("` takes ")
            + String(Int(row_opt.value().min_arity))
            + String("..") + String(Int(row_opt.value().max_arity))
            + String(" arguments and got ") + String(len(args))
            + String(
                ". The window is the census row's, so a call this refuses is a"
                " call `komira_xl_functions` also reports as out of arity."
            )
        )

    var tag = xl_plan_agg_tag(up)
    var plural = xl_condagg_is_plural(up)
    var takes_values = tag != XLA_COUNT

    # ★★ WHERE THE (range, criteria) PAIRS LIVE, AND THE TWO LAYOUTS SPLIT HERE.
    #
    #   SINGULAR  `NAME(<range>, <criteria>[, <aggregate range>])`
    #             -> exactly ONE pair at [0, 2); the OPTIONAL aggregate range
    #                is the LAST argument.
    #   PLURAL    `NAME([<aggregate range>,] <range1>, <crit1>, ...)`
    #             -> every argument after the aggregate range is a pair, and
    #                the aggregate range is the FIRST.
    #
    # ⛔ COMPUTING ONE `pair_start` AND PAIRING TO THE END FOR BOTH IS THE BUG
    # THIS COMMENT EXISTS TO PREVENT: a three-argument `SUMIF` would then have
    # THREE pair arguments, fail the parity check, and be refused — a formula
    # Excel accepts, reported as malformed.
    var pair_start = 0
    var pair_end = 2
    if plural:
        pair_start = 1 if takes_values else 0
        pair_end = len(args)
    var n_pair_args = pair_end - pair_start
    if n_pair_args < 2 or n_pair_args % 2 != 0:
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "`'s criteria arrive in (range, criteria) PAIRS and this call"
                " has an odd one out. "
            )
            + (
                String(
                    "The plural forms are `NAME(<aggregate range>, <range1>,"
                    " <criteria1>, ...)` — the aggregate range comes FIRST,"
                    " which is the reverse of the singular forms."
                )
                if plural
                else String(
                    "The singular forms are `NAME(<range>, <criteria>"
                    "[, <aggregate range>])`."
                )
            )
        )

    # ---- the criteria pairs -> one conjunctive predicate -------------------
    var first_crit = Optional[BoundRelation]()
    var pred = Optional[Expr]()
    var i = pair_start
    while i + 1 < pair_end:
        var crit_opt = _bound_array(src, args[i], bindings)
        if not crit_opt:
            return XlPlanBuild.no_plan(
                String("`") + up + String(
                    "`'s criteria RANGE at argument "
                ) + String(i + 1) + String(
                    " is not a bare NAME bound to a relation. Bind a name to a"
                    " catalog table (`SqlCatalog.add_parquet`) and test it"
                    " directly."
                )
            )
        var crit_rel = crit_opt.value().copy()
        if not crit_rel.is_named():
            return XlPlanBuild.resident(
                String("a criteria range bound to this `") + up + String(
                    "` is a RESIDENT RecordBatch. Its plan leaf would be"
                    " `from_record_batch_typed(ctx, batch)` — live heap data"
                    " inside the IR, which needs an engine to build and which"
                    " the codec refuses by name"
                    " (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`). Bind the name"
                    " through a catalog table (`SqlCatalog.add_parquet`) and the"
                    " leaf becomes a `ParquetSource` the wire already carries."
                )
            )
        if not first_crit:
            first_crit = Optional[BoundRelation](crit_rel.copy())
        elif not first_crit.value().same_relation(crit_rel):
            return XlPlanBuild.no_plan(
                String("`") + up + String(
                    "`'s criteria ranges are bound to DIFFERENT catalog tables."
                    " This plan has ONE scan leaf, so a cross-table pair would"
                    " filter rows that were never scanned together — a wrong"
                    " number rather than a wrong shape. Excel requires every"
                    " range of a SUMIFS to be the same size for the same"
                    " reason."
                )
            )

        var p_opt = build_criteria_predicate(src, args[i + 1], crit_rel)
        if not p_opt:
            return XlPlanBuild.no_plan(
                String("`") + up + String(
                    "`'s criteria at argument "
                ) + String(i + 2) + String(
                    " is outside the v1 envelope, which is a NUMBER or a STRING"
                    " literal optionally prefixed by one of `>` `<` `>=` `<=`"
                    " `<>` `=`. Out of envelope, deliberately: a WILDCARD"
                    " operand (`*` / `?`), which Excel pattern-matches and which"
                    " a literal comparison would silently answer differently; an"
                    " EMPTY operand (`\"<>\"` / `\"=\"` alone), which are"
                    " Excel's non-blank / blank tests; a criteria that is a cell"
                    " reference, a call or an expression, which needs an"
                    " evaluator to fold; and a criteria range with no COLUMN"
                    " selector. ⚠ A TEXT operand carrying a NON-ASCII byte was"
                    " out of envelope until 2026-09-11 and is NOT any more:"
                    " operand and column are folded by ONE function"
                    " (`komira_core.eval.unicode_case.unicode_lower_bytes`,"
                    " which is what the column's `STRFN_LOWER` kernel calls),"
                    " so the two sides cannot disagree."
                )
            )
        # ★ LEFT-ASSOCIATIVE `AND`. Excel's plural forms are a conjunction of
        # every pair; there is no OR form to choose between.
        if not pred:
            pred = Optional[Expr](p_opt.take())
        else:
            pred = Optional[Expr](
                Expr.binary(BIN_AND, pred.take(), p_opt.take())
            )
        i += 2

    var crit_rel = first_crit.value().copy()

    # ---- the aggregate range ------------------------------------------------
    var value_rel = crit_rel.copy()
    var value_idx = -1
    if takes_values:
        if plural:
            value_idx = 0
        elif len(args) >= 3:
            value_idx = 2
    if value_idx >= 0:
        var val_opt = _bound_array(src, args[value_idx], bindings)
        if not val_opt:
            return XlPlanBuild.no_plan(
                String("`") + up + String(
                    "`'s aggregate range is not a bare NAME bound to a relation."
                )
            )
        value_rel = val_opt.value().copy()
        if not value_rel.is_named():
            return XlPlanBuild.resident(
                String("the aggregate range bound to this `") + up + String(
                    "` is a RESIDENT RecordBatch; bind it through a catalog"
                    " table so its leaf is a `ParquetSource`."
                )
            )
        # ⚠ ONE TABLE, NOT TWO. This plan has ONE scan leaf, so a value range
        # over a different table would be aggregated out of rows the predicate
        # never saw — a confident wrong number rather than a shape error. The
        # test is `same_relation`, which compares the CATALOG NAME and not the
        # address, for the reason `BoundRelation.same_relation` records: two
        # named bindings over one table hold two distinct placeholder batches.
        if not crit_rel.same_relation(value_rel):
            return XlPlanBuild.no_plan(
                String("`") + up + String(
                    "`'s criteria range and aggregate range are bound to"
                    " DIFFERENT catalog tables. This plan has one scan leaf, so"
                    " a cross-table pair would aggregate rows the predicate"
                    " never filtered — a wrong number, not a wrong shape."
                )
            )

    var plan_opt = build_cond_agg_plan(up, crit_rel, value_rel, pred.take())
    if not plan_opt:
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "` over these ranges is refused by `build_cond_agg_plan` before"
                " any plan exists: the aggregate range carries no COLUMN"
                " selector, so there is nothing to aggregate."
            )
        )

    # ★ THE SAME CELL SEMANTICS AS `_build_rel_agg`, one family over.
    #
    # ⚠ THE TEXT ARM IS `excel_cond_value_range_is_text` AND **NOT**
    # `excel_range_is_text`, AND THE DIFFERENCE IS A WRONG ANSWER.
    # `COUNTIF` counts MATCHING cells of any type where the unconditional
    # `COUNT` counts NUMERIC ones, and the two share the `XLA_COUNT` tag
    # because they share one lowering ladder — so the tag alone cannot tell
    # them apart, and `COUNTIF(status,"acme")` over a TEXT range (the
    # commonest spelling a real sheet has) would come back 0. Read that
    # function's docstring before touching either.
    if excel_cond_value_range_is_text(up, value_rel):
        return XlPlanBuild.built(excel_zero_cell_plan(plan_opt.take()))
    var agg_tag = xl_plan_agg_tag(up)
    if agg_tag == XLA_SUM or agg_tag == XLA_MIN or agg_tag == XLA_MAX:
        return XlPlanBuild.built(excel_zero_when_empty(plan_opt.take()))
    return XlPlanBuild.built(plan_opt.take())


def _build_bivar_agg(
    src: FormulaAst, args: List[Int], bindings: FormulaBindings, up: String
) raises -> XlPlanBuild:
    """`CORREL(<x>, <y>)` over two COLUMNS of one NAMED relation.

    ★★ THE REACHABLE-BUT-UNBOUND FINDING, AND IT IS THE SAME SHAPE AS
    MEDIAN'S. `AGG_CORR` had a plan-IR tag, a plan-wire vocabulary member
    (wire 10 — no vocabulary bump was needed), a SQL binding, and a 0-KEY
    executor arm that a NULL-semantics change fixed on 2026-09-01. Excel had
    no NAME for it. Adding the name is the whole change; `build_bivar_agg_plan`
    assembles a two-child `AggExpr` and nothing else is new.

    ⚠ IT IS NOT `_build_rel_agg` WITH A SECOND ARGUMENT. That arm reads exactly
    one relation and calls `_agg_expr_for_name`, which builds a UNARY
    `AggExpr`; routing CORREL there refuses it for its arity, and forcing it
    through would need a second column parameter on a function every
    unary aggregate uses. The FAMILY is what keeps them apart.

    THE REFUSAL ORDER, matching every other arm:
      1. arity — exactly two
      2. both ranges — bare NAMEs bound to relations
      3. NAMED vs RESIDENT
      4. SAME catalog table (one scan leaf; the pairing is by ROW)
      5. both carry a COLUMN selector
    """
    if len(args) != 2:
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "` is BIVARIATE and takes exactly two range arguments; got "
            ) + String(len(args))
        )

    var x_opt = _bound_array(src, args[0], bindings)
    var y_opt = _bound_array(src, args[1], bindings)
    if not x_opt or not y_opt:
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "` needs BOTH arguments to be bare NAMEs bound to relations."
                " Bind each column of a catalog table"
                " (`SqlCatalog.add_parquet`) and correlate them directly."
            )
        )
    var rel_x = x_opt.value().copy()
    var rel_y = y_opt.value().copy()

    if not rel_x.is_named() or not rel_y.is_named():
        return XlPlanBuild.resident(
            String("a range bound to this `") + up + String(
                "` is a RESIDENT RecordBatch, whose leaf"
                " (`from_record_batch_typed(ctx, batch)`) needs an engine and"
                " which the codec refuses by name"
                " (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`). Bind the names"
                " through a catalog table."
            )
        )

    if not rel_x.same_relation(rel_y):
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "`'s two ranges are bound to DIFFERENT catalog tables. This"
                " plan has ONE scan leaf and pairs the columns by ROW — which"
                " is what Excel's positional pairing means over a table — so"
                " two tables have no row correspondence at all. Excel's own"
                " CORREL is `#N/A` when the two arrays differ in size, for the"
                " same reason."
            )
        )

    var plan_opt = build_bivar_agg_plan(up, rel_x, rel_y)
    if not plan_opt:
        return XlPlanBuild.no_plan(
            String("`") + up + String(
                "` is refused by `build_bivar_agg_plan` before any plan"
                " exists: at least one range carries no COLUMN selector, and a"
                " correlation of one 2D range against another has no meaning"
                " here."
            )
        )
    return XlPlanBuild.built(plan_opt.take())
