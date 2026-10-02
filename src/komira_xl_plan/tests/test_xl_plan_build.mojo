# =============================================================================
# =============================================================================
#
# ★ AND THE ENGINE-FREEDOM IS ITSELF THE SUBJECT, not merely a convenience.
# `build_xl_plan`'s signature names no context, and the only way to assert the
# ABSENCE of an argument is for a caller to compile without supplying one —
# a runtime test cannot observe it. This whole file is that caller.
#
# ⚠ THE ORACLE IS HAND-BUILT FROM `komira_core`, NOT READ BACK FROM THE
# BUILDER. Asserting `String(built) == String(built)` would pass through any
# mutation of the builder; the plan below is assembled independently out of
# `LogicalPlan.aggregate` / `agg_sum` / `col` / `scan_from_source`, so a
# changed aggregate kind, a lost group-by or a swapped leaf is a RED.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr, UN_IS_NULL, WhenCaseData
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
)
from komira_core.plan.agg_expr import (
    sum as agg_sum,
    count as agg_count,
    min as agg_min,
    max as agg_max,
    mean as agg_mean,
)
from komira_core.source.parquet_source import ParquetSource
from komira_core.source.source_variant import SourceVariant

from komira_xl_plan.bound_relation import BoundRelation, NamedTable
from komira_xl_plan.formula_bindings import FormulaBindings
from komira_xl_plan.rel_agg_build import build_rel_agg_plan
from komira_xl_plan.rel_filter_build import (
    build_filter_plan,
    build_filter_predicate,
)
from komira_xl_plan.formula_parser import parse_formula
from komira_xl_plan.xl_plan_build import (
    build_xl_plan,
    XL_BUILD_OK,
    XL_BUILD_NO_PLAN,
    XL_BUILD_RESIDENT,
)


# =============================================================================
# The fixture, which is a SCHEMA and a PATH — no bytes, no file, no engine.
# =============================================================================
#
# ⚠ THE PATH NEED NOT EXIST AND MUST NOT BE READ. `build_xl_plan` is a plan
# BUILDER: it names the work, it does not do it. A test here that needed a real
# parquet file would be asserting something about the reader.


def _schema() raises -> Schema:
    """⚠ `status` IS A STRING COLUMN AND IT IS HERE FOR THE CONDITIONAL
    AGGREGATES. Every oracle in this file assembles its leaf from THIS function,
    so widening the schema moves both sides of every comparison together — the
    plan renders are unaffected. What it buys is a column a TEXT criteria can be
    tested against, which no numeric column can stand in for: the text and
    numeric criteria arms of `_operand_literal` produce DIFFERENT
    `ScalarValue`s, and a suite with only numeric columns cannot separate
    them."""
    var sb = SchemaBuilder()
    sb.add_field(Field("qty", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("status", ArrowType.STRING, False))
    return sb.build()


def _source() raises -> SourceVariant:
    return SourceVariant(
        ParquetSource(String("/nonexistent/door.parquet"), _schema())
    )


def _named(column: String) raises -> BoundRelation:
    """The Excel name `qty` bound to the `qty` COLUMN of table `door`, or — with
    an empty `column` — to the WHOLE table (a 2D range)."""
    return BoundRelation(
        NamedTable(String("door"), _schema(), _source()), column
    )


def _bindings() raises -> FormulaBindings:
    var b = FormulaBindings()
    b.bind_relation(String("qty"), _named(String("qty")))
    b.bind_relation(String("price"), _named(String("price")))
    b.bind_relation(String("status"), _named(String("status")))
    b.bind_relation(String("door"), _named(String("")))
    return b^


def _resident_bindings() raises -> FormulaBindings:
    var b = FormulaBindings()
    b.bind_relation(
        String("qty"), BoundRelation(ArcPointer(RecordBatch()), String("qty"))
    )
    return b^


def _sheet_zero(var agg: LogicalPlan, name: String) raises -> LogicalPlan:
    """★ EXCEL'S EMPTY-RANGE IDENTITY, HAND-ASSEMBLED:
    `Project([CASE WHEN <name> IS NULL THEN 0 ELSE <name> END AS <name>]) <- agg`.

    ⚠ THE ZERO HERE IS AN INT64 `0` — every aggregate asserted through THIS
    helper is over `qty`, an INT64 column. `_oracle_sum` is the one caller over
    another column (`price`, FLOAT64, in
    `test_the_column_selector_is_what_picks_the_column`) and passes its own
    zero through `_sheet_zero_of`. The claim that the literal's type FOLLOWS THE
    AGGREGATE (a FLOAT64 sum takes `0.0`; an INT32 column's sum promotes to
    INT64 and takes an INT64 `0`) is asserted in `test_xl_agg_identity.mojo`,
    over a fixture built for exactly that.

    ⛔ IT IS ASSEMBLED FROM `komira_core`, NOT BY CALLING
    `xl_agg_identity.excel_zero_when_empty`. An oracle that called the function
    under test would be green through any mutation of it."""
    return _sheet_zero_of(agg^, name, ScalarValue.from_int(0))


def _sheet_zero_of(
    var agg: LogicalPlan, name: String, var zero: ScalarValue
) raises -> LogicalPlan:
    """`_sheet_zero` with the ZERO LITERAL named by the caller.
    from `komira_core` and never read off the function under test."""
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.unary(UN_IS_NULL, Expr.col_ref(name)),
            Expr.literal(zero^),
        )
    )
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.when(cases^, Expr.col_ref(name)), name))
    return LogicalPlan.project(exprs^, agg^)


def _zero_for_column(column: String) raises -> ScalarValue:
    """Excel's empty-range zero for a `SUM` over `column`, typed off THIS
    FILE'S FIXTURE (`_schema()`), never off the plan under test.

    Only the two numeric fixture columns are answered, and each is its own
    SUM's output type (`sum(<INT64>)` is INT64, `sum(<FLOAT64>)` is FLOAT64 —
    neither promotes). Any other column RAISES: a promoting type would need the
    promotion rule restated here, and that belongs to `test_xl_agg_identity`."""
    var at = _schema().get_field_arrow_type(column)
    if at == ArrowType.INT64:
        return ScalarValue.from_int(0)
    if at == ArrowType.FLOAT64:
        return ScalarValue.from_float(0.0)
    raise Error(
        "_zero_for_column: fixture column `"
        + column
        + "` is neither INT64 nor FLOAT64 — state its SUM's zero explicitly"
    )


def _oracle_sum(column: String) raises -> String:
    """`Project(<Excel zero identity>) <- Aggregate(group_by=[], aggs=[SUM(col)])
    <- Scan(ParquetSource)`, assembled out of `komira_core` and nothing else —
    the zero typed off the fixture column (`_zero_for_column`)."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(column)))
    return String(
        _sheet_zero_of(
            LogicalPlan.aggregate(
                ExprArray(),
                aggs^,
                LogicalPlan.scan_from_source(_source(), _schema()),
            ),
            String("sum"),
            _zero_for_column(column),
        )
    )


# =============================================================================
# THE ENVELOPE — five aggregate names over a name bound to a catalog table
# =============================================================================


def test_sum_over_a_named_column_builds_the_scan_aggregate() raises:
    """★ THE CENTRAL CLAIM, and the one a mutation of the builder must break.

    The render is compared to a plan built INDEPENDENTLY from `komira_core`;
    comparing the builder to itself would be green through any mutation."""
    var built = build_xl_plan(String("SUM(qty)"), _bindings())
    assert_true(
        built.is_built(),
        "SUM over a NAMED relation carrying a column selector must build a"
        " plan. A refusal on an in-envelope input makes every other assertion"
        " in this file vacuous. detail: " + built.detail(),
    )
    assert_equal(built.status(), XL_BUILD_OK, "a built plan carries status 0")
    var plan = built.take_plan()
    assert_equal(
        String(plan),
        _oracle_sum(String("qty")),
        "the ctx-free builder did not build SCAN -> AGGREGATE(SUM(qty)) token"
        " for token against a plan assembled from komira_core alone. A"
        " different AggExpr, a non-empty group-by or a different leaf all land"
        " here",
    )


def test_the_five_aggregate_names_each_build_their_own_expression() raises:
    """SUM/AVERAGE/MIN/MAX each denote a DIFFERENT `AggExpr` over the same leaf.

    ⚠ A LADDER THAT RETURNED `SUM` FOR ALL FOUR WOULD PASS
    `test_sum_over_a_named_column_...` — this is the arm that separates them,
    and each expected render is built independently."""
    var leaf = LogicalPlan.scan_from_source(_source(), _schema())

    var a_avg = AggExprArray()
    a_avg.append(agg_mean(col(String("qty"))))
    var a_min = AggExprArray()
    a_min.append(agg_min(col(String("qty"))))
    var a_max = AggExprArray()
    a_max.append(agg_max(col(String("qty"))))
    var a_cnt = AggExprArray()
    a_cnt.append(agg_count())

    var b_avg = build_xl_plan(String("AVERAGE(qty)"), _bindings())
    assert_true(b_avg.is_built(), "AVERAGE is in the envelope")
    assert_equal(
        String(b_avg.take_plan()),
        String(LogicalPlan.aggregate(ExprArray(), a_avg^, leaf.copy())),
        "AVERAGE(qty) must lower to MEAN, not to SUM",
    )

    var b_min = build_xl_plan(String("MIN(qty)"), _bindings())
    assert_true(b_min.is_built(), "MIN is in the envelope")
    assert_equal(
        String(b_min.take_plan()),
        String(
            _sheet_zero(
                LogicalPlan.aggregate(ExprArray(), a_min^, leaf.copy()),
                String("min"),
            )
        ),
        "MIN(qty) must lower to MIN under Excel's empty-range zero identity",
    )

    var b_max = build_xl_plan(String("MAX(qty)"), _bindings())
    assert_true(b_max.is_built(), "MAX is in the envelope")
    assert_equal(
        String(b_max.take_plan()),
        String(
            _sheet_zero(
                LogicalPlan.aggregate(ExprArray(), a_max^, leaf.copy()),
                String("max"),
            )
        ),
        "MAX(qty) must lower to MAX under Excel's empty-range zero identity",
    )

    var b_cnt = build_xl_plan(String("COUNT(door)"), _bindings())
    assert_true(
        b_cnt.is_built(),
        "★ COUNT over a SELECTOR-LESS binding must build: COUNT counts ROWS and"
        " is the one aggregate that does not need a column. If this refuses,"
        " the column-less guard has stopped exempting COUNT and a whole-table"
        " row count is unreachable. detail: " + b_cnt.detail(),
    )
    assert_equal(
        String(b_cnt.take_plan()),
        String(LogicalPlan.aggregate(ExprArray(), a_cnt^, leaf^)),
        "COUNT(door) must lower to COUNT() over the whole table",
    )


def test_the_column_selector_is_what_picks_the_column() raises:
    """`SUM(price)` and `SUM(qty)` are bound to the SAME table and differ only
    in the selector — so a builder that ignored the selector would pass every
    single-column test above."""
    var b = build_xl_plan(String("SUM(price)"), _bindings())
    assert_true(b.is_built(), "SUM(price) is in the envelope")
    assert_equal(
        String(b.take_plan()),
        _oracle_sum(String("price")),
        "SUM(price) built an aggregate over a different column than the one its"
        " binding selects",
    )


def test_lowercase_and_mixed_case_verbs_resolve() raises:
    """Excel function names are case-insensitive; the builder upper-cases before
    dispatch. `sum(qty)` and `Sum(qty)` are the same formula."""
    var lower = build_xl_plan(String("sum(qty)"), _bindings())
    assert_true(lower.is_built(), "`sum` must resolve: " + lower.detail())
    assert_equal(String(lower.take_plan()), _oracle_sum(String("qty")))
    var mixed = build_xl_plan(String("Sum(qty)"), _bindings())
    assert_true(mixed.is_built(), "`Sum` must resolve: " + mixed.detail())
    assert_equal(String(mixed.take_plan()), _oracle_sum(String("qty")))


def test_a_leading_equals_is_accepted() raises:
    """`=SUM(qty)` is how the formula arrives from a sheet. `parse_formula`
    strips the leading `=`; the builder must not care which spelling it got."""
    var b = build_xl_plan(String("=SUM(qty)"), _bindings())
    assert_true(b.is_built(), "a leading '=' must not refuse: " + b.detail())
    assert_equal(String(b.take_plan()), _oracle_sum(String("qty")))


# =============================================================================
# THE REFUSALS — each one a DIFFERENT edit for the caller
# =============================================================================


def test_a_scalar_formula_is_no_plan_and_not_an_error() raises:
    """★ THE MAJORITY OF EXCEL. `=1+1` is a correct formula with NO plan, and
    saying so is not the same as saying it is wrong. A producer that answered
    this with empty bytes or a degenerate plan would be inventing a query the
    user never wrote."""
    var b = build_xl_plan(String("=1+1"), _bindings())
    assert_false(b.is_built(), "`=1+1` has no relational plan")
    assert_equal(
        b.status(),
        XL_BUILD_NO_PLAN,
        "a scalar formula is NO_PLAN, never RESIDENT — the caller's edit is to"
        " write a relational verb, not to rebind a name",
    )
    assert_true(
        b.detail().byte_length() > 0,
        "a refusal with no detail sends the caller nowhere",
    )


def test_an_unextracted_verb_is_refused_by_name() raises:
    """CHOOSECOLS's builder is still inside the lowering that executes it, so it
    is refused HERE rather than half-built. The detail must NAME the verb: a
    refusal that does not say which word was the problem is a guess.

    ⚠ THE STRAWMAN WAS `FILTER` AND IT WENT RED ON GOOD NEWS on 2026-09-04 —
    FILTER's builder was extracted (`rel_filter_build.build_filter_plan`) and
    the verb now BUILDS. The replacement is drawn from the same remainder list
    and will expire the same way, which is correct: this test is about the
    refusal SHAPE, and the list it draws from is supposed to shrink."""
    var b = build_xl_plan(String("CHOOSECOLS(door, 1)"), _bindings())
    assert_false(b.is_built(), "CHOOSECOLS has no ctx-free builder yet")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)
    assert_true(
        b.detail().find(String("CHOOSECOLS")) >= 0,
        "the refusal must name the verb it refused; got: " + b.detail(),
    )


# =============================================================================
# ★ FILTER — the SECOND extracted builder, and the first non-aggregate verb
# =============================================================================


def test_filter_over_a_named_table_builds_scan_filter() raises:
    """`FILTER(door, qty>1)` -> `Filter(qty > 1) <- Scan(door)`.

    ⚠ NO PROJECTION, because `door` is bound to the WHOLE table — a 2D range,
    whose FILTER keeps every column. The projection is the COLUMN SELECTOR and
    the next cell is its twin."""
    var b = build_xl_plan(String("FILTER(door, qty>1)"), _bindings())
    assert_true(b.is_built(), "FILTER over a named table must build")
    var rendered = String(b.take_plan())
    assert_true(
        rendered.find(String("Filter(")) >= 0,
        "the plan has no Filter node: " + rendered,
    )
    assert_true(
        rendered.find(String("Project(")) < 0,
        "a whole-table FILTER must not project; got: " + rendered,
    )
    assert_true(
        rendered.find(String("door.parquet")) >= 0,
        "the leaf does not name the catalog table's source: " + rendered,
    )


def test_a_column_bound_filter_projects_that_column_ABOVE_the_predicate() raises:
    """★ THE NODE ORDER IS THE WHOLE CORRECTNESS ARGUMENT AND IT IS NOT AN
    IMPLEMENTATION DETAIL. A projection UNDER the filter drops the predicate's
    own column whenever the caller did not select it — a wrong ROW SET, which
    no schema check can catch. `Project` must be the ROOT."""
    var b = build_xl_plan(String("FILTER(price, qty>1)"), _bindings())
    assert_true(b.is_built(), "a column-bound FILTER must build")
    var rendered = String(b.take_plan())
    var proj_at = rendered.find(String("Project("))
    var filt_at = rendered.find(String("Filter("))
    assert_true(proj_at >= 0, "no Project node: " + rendered)
    assert_true(filt_at >= 0, "no Filter node: " + rendered)
    assert_true(
        proj_at < filt_at,
        "the Project is BELOW the Filter, so the predicate's column is dropped"
        " before it is read: " + rendered,
    )


def test_the_shared_filter_builder_is_the_one_build_xl_plan_dispatches_to() raises:
    """`build_xl_plan` must not be a second lowering tree — the same assertion
    the aggregate family carries, for the arm that was extracted second.
    Calling `build_filter_plan` DIRECTLY with the same relation and predicate
    must produce the same plan."""
    var src = parse_formula(String("FILTER(door, qty>1)"))
    var root = src.get(src.root)
    var bindings = _bindings()
    var rel = _named(String(""))
    var pred_opt = build_filter_predicate(src, root.args[1], bindings, rel)
    assert_true(Bool(pred_opt), "the shared predicate builder accepts qty>1")
    var direct = build_filter_plan(rel, pred_opt.take())
    var viaformula = build_xl_plan(String("FILTER(door, qty>1)"), bindings)
    assert_true(viaformula.is_built(), "the formula path builds it too")
    assert_equal(
        String(viaformula.take_plan()),
        String(direct),
        "build_xl_plan built a DIFFERENT plan than build_filter_plan does for"
        " the same relation and predicate, which means the formula path has"
        " grown its own lowering and can now drift from the one that executes",
    )


def test_excels_third_filter_argument_is_refused_not_dropped() raises:
    """★ EXCEL'S OWN `FILTER` TAKES `(array, include, [if_empty])`. The third
    argument is a VALUE substituted when nothing matches — a sheet's display
    decision, not part of the plan. Refusing it is deliberate: silently
    ignoring an argument the user WROTE makes the formula stop meaning what it
    says, and the row set would be right while the cell was wrong."""
    var b = build_xl_plan(
        String("FILTER(door, qty>1, \"none\")"), _bindings()
    )
    assert_false(b.is_built(), "the 3-argument form must refuse")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)
    assert_true(
        b.detail().find(String("if_empty")) >= 0,
        "the refusal must say WHICH argument and why; got: " + b.detail(),
    )


def test_a_cross_table_filter_condition_is_out_of_envelope() raises:
    """The predicate column must be bound to the SAME catalog table as the
    array. A cross-relation condition would build a Filter naming a column the
    scan does not produce — an engine error far from its cause."""
    var b2 = FormulaBindings()
    b2.bind_relation(String("door"), _named(String("")))
    b2.bind_relation(
        String("other"),
        BoundRelation(
            NamedTable(String("elsewhere"), _schema(), _source()), String("qty")
        ),
    )
    var b = build_xl_plan(String("FILTER(door, other>1)"), b2)
    assert_false(b.is_built(), "a cross-table condition must refuse")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_resident_filter_is_the_resident_status_not_an_envelope_refusal() raises:
    """★ THE ARM ORDER, ASSERTED. A resident binding must be reported as
    `XL_BUILD_RESIDENT` even though its condition is also unbuildable here,
    because the two statuses send the caller to DIFFERENT edits: rebind through
    a catalog table, versus rewrite the formula."""
    var b = build_xl_plan(String("FILTER(qty, qty>1)"), _resident_bindings())
    assert_false(b.is_built())
    assert_equal(b.status(), XL_BUILD_RESIDENT)


def test_build_filter_plan_needs_no_engine_constructed_at_all() raises:
    """★ THE SIGNATURE IS THE CLAIM. This function COMPILES without an
    `EngineContext` in scope, which is the only way the absence of an argument
    can be asserted — a runtime test cannot observe it. A landing that adds a
    context parameter to `build_filter_plan` breaks this file at COMPILE time.
    """
    var src = parse_formula(String("FILTER(door, qty>1)"))
    var root = src.get(src.root)
    var rel = _named(String(""))
    var pred = build_filter_predicate(src, root.args[1], _bindings(), rel)
    assert_true(Bool(pred), "the predicate builds with no engine")
    var plan = build_filter_plan(rel, pred.take())
    assert_true(String(plan).find(String("Filter(")) >= 0)


def test_an_unknown_aggregate_name_is_refused() raises:
    """A name no Excel dispatch surface has ever heard of is `NO_PLAN`, never a
    plan built out of a guess.

    ⚠ THE STRAWMAN USED TO BE `MEDIAN` AND THAT WENT RED ON 2026-09-04 —
    correctly, on GOOD news: MEDIAN gained a row in `xl_fn_table` and now
    builds `AGGREGATE([], [MEDIAN(col)])`. The replacement is a name that
    cannot become real by anybody implementing anything, because it is not an
    Excel function. A strawman drawn from the "not yet" pile expires the day
    the pile shrinks, which is the wrong failure for a test whose subject is
    the REFUSAL and not the roster.

    ⚠ `_is_rel_agg_name` and `_agg_expr_for_name` are no longer two spellings
    of one set — both read `xl_fn_table.xl_plan_agg_tag` — so the disagreement
    this arm used to guard against is now unrepresentable. It still guards the
    outcome: an unrecognised name refuses rather than reaching a builder."""
    var b = build_xl_plan(String("FLIMBLE(qty)"), _bindings())
    assert_false(b.is_built(), "an invented name is outside every envelope")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_median_now_builds_and_that_is_what_replaced_the_old_strawman() raises:
    """★ THE OTHER HALF OF THE LINE ABOVE, stated positively so the swap cannot
    be read as weakening the refusal test. `AGG_MEDIAN` had a plan-IR tag, a
    wire-vocabulary member, a 0-key executor arm and a SQL binding; what it did
    not have was an Excel NAME. That is the entire 2026-09-04 change."""
    var b = build_xl_plan(String("MEDIAN(qty)"), _bindings())
    assert_true(b.is_built(), "MEDIAN(qty) must now build a plan")
    var rendered = String(b.take_plan())
    assert_true(
        rendered.find(String("MEDIAN")) >= 0,
        "the built plan does not name MEDIAN, so the name resolved to some"
        " OTHER aggregate — a wrong plan, which is worse than a refusal",
    )


def test_a_column_less_sum_is_refused_before_any_plan_exists() raises:
    """`SUM` over a binding with no column selector is `#NAME?` on the inline
    path, and the SAME decision here — reachable with no engine, which is what
    makes it the BUILDER's decision and not the executor's.

    ⚠ CONTRAST WITH `COUNT(door)` ABOVE, which is the same binding and BUILDS.
    The pair is the assertion: the guard must exempt COUNT and only COUNT."""
    var b = build_xl_plan(String("SUM(door)"), _bindings())
    assert_false(
        b.is_built(),
        "SUM over a selector-less binding must refuse — a whole-table SUM has"
        " no column to sum and silently picking one would be a wrong number",
    )
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_nested_call_argument_is_refused_not_silently_dropped() raises:
    """★ THE FUSION ARM, AND WHY IT MUST REFUSE. `SUM(FILTER(door, qty>25))`
    that dropped its predicate would be a WRONG NUMBER on the wire, and no
    schema check downstream can catch a plan that is well-formed and means
    something else."""
    var b = build_xl_plan(String("SUM(FILTER(door, qty>25))"), _bindings())
    assert_false(b.is_built(), "the fused shape has no ctx-free builder")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_multi_argument_aggregate_is_refused() raises:
    """`SUM(a, b)` is a sum of ADDENDS — a scalar expression, not one plan."""
    var b = build_xl_plan(String("SUM(qty, price)"), _bindings())
    assert_false(b.is_built(), "a two-argument SUM is not one relational plan")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_an_unbound_name_is_refused() raises:
    """A name nothing bound is not a relation. `lookup_relation` is an exact
    byte compare, so `QTY` is NOT `qty` and must not resolve."""
    var b = build_xl_plan(String("SUM(QTY)"), _bindings())
    assert_false(
        b.is_built(),
        "`QTY` is bound to nothing — FormulaBindings.lookup_relation matches"
        " exactly and must not case-fold a NAME the way the verb is folded",
    )
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_resident_binding_is_its_own_status() raises:
    """★ A DIFFERENT STATUS BECAUSE IT SENDS THE CALLER TO A DIFFERENT EDIT.
    A resident `RecordBatch` leaf needs an engine to build even in principle and
    the wire codec refuses it by name; the fix is to bind the name through a
    catalog table, NOT to rewrite the formula.

    ⚠ AND THE ARM ORDER IS THE EXECUTOR'S. This binding also carries a column
    selector, so reporting it as NO_PLAN would send the caller to fix a formula
    that is correct."""
    var b = build_xl_plan(String("SUM(qty)"), _resident_bindings())
    assert_false(b.is_built(), "a resident binding builds no ctx-free plan")
    assert_equal(
        b.status(),
        XL_BUILD_RESIDENT,
        "a resident binding must be RESIDENT and not NO_PLAN — the two statuses"
        " exist precisely because the caller's next action differs",
    )


def test_take_plan_on_a_refusal_raises_rather_than_returning_a_default() raises:
    """A caller that skipped the status check must find out here. Returning an
    empty plan would let a refusal be ENCODED as a query."""
    var b = build_xl_plan(String("=1+1"), _bindings())
    var raised = False
    try:
        var _p = b.take_plan()
    except:
        raised = True
    assert_true(
        raised,
        "take_plan() on a build carrying no plan must raise; a default plan"
        " here is how a refusal reaches the wire as a query",
    )


def test_a_malformed_formula_raises_it_is_not_a_refusal_status() raises:
    """There is no plan QUESTION yet for a formula that does not parse, so it
    raises rather than occupying one of the two refusal statuses."""
    var raised = False
    try:
        var _b = build_xl_plan(String("SUM(qty"), _bindings())
    except:
        raised = True
    assert_true(raised, "an unbalanced parenthesis must raise out of the parser")


def test_the_three_statuses_are_distinct() raises:
    """The status space is what a non-Mojo frontend branches on; two equal
    constants would make the branch unreachable."""
    assert_true(XL_BUILD_OK != XL_BUILD_NO_PLAN)
    assert_true(XL_BUILD_OK != XL_BUILD_RESIDENT)
    assert_true(XL_BUILD_NO_PLAN != XL_BUILD_RESIDENT)


def test_the_shared_builder_is_the_one_build_xl_plan_dispatches_to() raises:
    """★★ `build_xl_plan` MUST NOT BE A SECOND **RELATIONAL** LOWERING TREE —
    and since 2026-09-11 that sentence needs the word RELATIONAL in it.

    The claim was, and still is, that "the plan Excel executes" and "the plan a
    caller with no engine obtains" are ONE expression. What changed is that
    `build_xl_plan` now applies Excel's CELL-value semantics on top of the
    relational plan (a numeric aggregate over no numeric cells is 0, not NULL —
    `xl_agg_identity.mojo`), and it applies them THERE rather than inside
    `build_rel_agg_plan` because the INLINE arm calls that builder too and ends
    at a terminal that refuses a `PLAN_PROJECT` root.

    ⇒ SO THE ASSERTION IS SHARPENED, NOT WEAKENED, and it is written in two
    halves so that neither can go vacuous:

      * `AVERAGE(qty)` — a name the wrap does NOT touch — must be BYTE-IDENTICAL
        through both entry points. That is the half that would catch a second
        lowering tree, and it is unaffected by any of this.
      * `SUM(qty)` — a name the wrap DOES touch — must be exactly
        `build_rel_agg_plan`'s plan with the ONE documented wrapper on it and
        nothing else. A formula path that had re-derived its own aggregate,
        leaf or predicate would not match this either.

    ⛔ THE WRAPPER IN THE ORACLE IS HAND-ASSEMBLED (`_sheet_zero`), never
    obtained by calling `excel_zero_when_empty` — the point of comparing two
    entry points is lost if both sides call the same third function."""
    var avg_direct_opt = build_rel_agg_plan(
        String("AVERAGE"), _named(String("qty"))
    )
    assert_true(Bool(avg_direct_opt), "the shared builder builds AVERAGE")
    var avg_via = build_xl_plan(String("AVERAGE(qty)"), _bindings())
    assert_true(avg_via.is_built(), "the formula path builds AVERAGE too")
    assert_equal(
        String(avg_via.take_plan()),
        String(avg_direct_opt.take()),
        "AVERAGE carries no Excel cell-semantics wrapper, so the two entry"
        " points must produce the IDENTICAL plan. A difference here is the"
        " formula path having grown its own lowering",
    )

    var direct_opt = build_rel_agg_plan(String("SUM"), _named(String("qty")))
    assert_true(Bool(direct_opt), "the shared builder builds this relation")
    var direct = direct_opt.take()
    var viaformula = build_xl_plan(String("SUM(qty)"), _bindings())
    assert_true(viaformula.is_built(), "the formula path builds it too")
    assert_equal(
        String(viaformula.take_plan()),
        String(_sheet_zero(direct^, String("sum"))),
        "build_xl_plan's SUM is not `build_rel_agg_plan`'s plan plus exactly"
        " the Excel zero-identity wrapper. Either the formula path has grown"
        " its own relational lowering, or the wrapper has changed shape",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
