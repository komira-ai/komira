# =============================================================================
# test_optimizer_udf_node_opacity.mojo — A UDF NODE IS OPAQUE TO PREDICATE
#                                        PUSHDOWN, AND WAS NOT.
# =============================================================================
#
# The UDF design notes
# asserted — from reading, not from measurement — that a handle bolted beside a
# `lit(true)` placeholder is deleted by `push_predicates_down`. This file is
# that assertion MEASURED, and it turned out to be understated in one arm and
# to have a second, worse arm nobody had named.
#
# ── THE TWO DEFECTS ─────────────────────────────────────────────────────────
#
# 1. **A UDF-CARRYING PROJECT LOSES ITS UDF WHEN A FILTER IS PUSHED THROUGH
#    IT.** Every reconstruction in the Project arm of `push_predicates_down`
#    calls `LogicalPlan.project(...)` — the NON-UDF factory — so the rebuilt
#    node simply does not have the payload the original had. Not "the filter
#    moved to a place it should not be": the customer's function is GONE, and
#    the Project's `exprs` are the placeholder col-refs the UDF path stamps, so
#    the plan then executes the placeholder and returns wrong rows quietly.
#
#    ⚠ IT USED TO BE GUARDED. The comment block above that arm still explains
#    exactly why a UDF-Project must be a pushdown barrier ("pushing changes the
#    cardinality the UDF sees, which is illegal for non-stateless UDFs"), and
#    then says: "UDF-Project barrier removed
#    — ProjectData no longer carries `udf`." **A LATER CHANGE PUT THE FIELD BACK ONE DAY
#    LATER AND THE BARRIER WAS NEVER RESTORED.** The rationale for
#    the guard outlived the guard by fifteen months.
#
# 2. **A UDF-CARRYING FILTER IS DELETED OUTRIGHT** when its predicate is fully
#    absorbed by the scan (`if len(kept) == 0: return new_scan^`). The UDF path
#    stamps `lit(true)` as the predicate precisely because the real work is in
#    the UDF — and a `lit(true)` is the most pushable predicate there is.
#
# ── WHY THIS IS LATENT TODAY AND WHY IT STILL HAS TO BE FIXED FIRST ─────────
# `materialize_plan` refuses a UDF-carrying plan at the door
# (plan materialization refuses it), ABOVE the optimizer, so neither defect can
# produce a wrong answer right now. That refusal is what
# UDF execution would NARROW. Narrowing it before this is
# fixed converts a loud refusal into a silent wrong answer, which is the one
# outcome that must never happen.
#
# ── THE FIX, AND WHY IT IS THE CONSERVATIVE DIRECTION ───────────────────────
# A UDF-carrying Filter or Project is OPAQUE: pushdown recurses INTO its child
# and leaves the node itself alone. No-pushdown over a UDF node is correct and
# slower; pushdown over one is wrong. There is no third option that is fast and
# correct without teaching pushdown what each UDF's parallelism contract
# permits, which is a much larger design and buys nothing until a UDF plan can
# execute at all.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_SCAN,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
)
from komira_optimizer.optimizer_filter import push_predicates_down
from komira_plan_ir.plan_helpers import _copy_plan


def _scan() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    var schema = sb.build()
    return LogicalPlan.scan(
        String("/nonexistent/udf_opacity.parquet"),
        0,  # SOURCE_PARQUET
        schema^,
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )


def _udf(kind: UInt8, var name: String) -> UdfData:
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("a", UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    return UdfData(
        kind=kind,
        name=name^,
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(9301),
        call_site_salt=UInt32(5),
        # ★ A REGISTERED HANDLE, because that is the shape UDF execution would
        # let through. Losing THIS is losing the customer's function.
        registered_handle_id=Optional(Int(3)),
    )


def _project_with_udf(var child: LogicalPlan) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    return LogicalPlan.project_with_udf(
        exprs^, child^, OwnedPointer[UdfData](_udf(UDF_KIND_MAP, String("margin")))
    )


def _count_udfs(plan: LogicalPlan) raises -> Int:
    """UDF-carrying nodes anywhere in the tree. Counting the WHOLE tree, not
    just the root, is deliberate: a rewrite that moves a node without dropping
    it must not read as a loss."""
    var n = 1 if plan.has_udf() else 0
    if plan.tag == PLAN_FILTER:
        n += _count_udfs(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        n += _count_udfs(plan._project.value()[].child[])
    return n


# --- 1. ★ A UDF-CARRYING PROJECT KEEPS ITS UDF ------------------------------


def test_a_filter_pushed_through_a_udf_project_does_not_drop_the_udf() raises:
    """`Filter(a > 3) over Project[udf](Scan)`.

    `a` IS in the under-Project schema, so the pushdown arm fires and rebuilds
    the Project — with the NON-UDF factory. That rebuild is the defect."""
    var plan = LogicalPlan.filter(
        Expr.binary(
            BIN_GT,
            Expr.col_ref(String("a")),
            Expr.literal(ScalarValue.from_int64(Int64(3))),
        ),
        _project_with_udf(_scan()),
    )
    # ⚠ ANTI-VACUITY: the fixture must actually carry a UDF, or "still carries
    # one" below is trivially satisfiable by carrying none at either end.
    assert_equal(
        _count_udfs(plan), 1, "VACUOUS: the fixture carries no UDF at all"
    )

    var out = push_predicates_down(plan^)
    assert_equal(
        _count_udfs(out),
        1,
        "★ THE OPTIMIZER DROPPED THE CUSTOMER'S UDF. Every reconstruction in"
        + " push_predicates_down's Project arm uses the NON-UDF factory"
        + " `LogicalPlan.project(...)`, so the rebuilt node loses the payload."
        + " The Project's `exprs` are the PLACEHOLDER col-refs the UDF path"
        + " stamps, so the plan would then execute the placeholder and return"
        + " wrong rows with rc=0.",
    )


# --- 2. ★★ A UDF-CARRYING FILTER IS NOT DELETED ----------------------------


def test_a_udf_filters_placeholder_predicate_does_not_delete_the_node() raises:
    """`Filter[udf](lit(true)) over Scan`.

    The UDF-filter path stamps `lit(true)` as the predicate — the real work is
    in the UDF — and `lit(true)` is the most absorbable predicate there is. If
    the scan takes it, `len(kept) == 0` returns the BARE SCAN."""
    var plan = LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        OwnedPointer[UdfData](_udf(UDF_KIND_FILTER, String("cheap"))),
    )
    assert_equal(
        _count_udfs(plan), 1, "VACUOUS: the fixture carries no UDF at all"
    )

    var out = push_predicates_down(plan^)
    assert_equal(
        _count_udfs(out),
        1,
        "★ THE OPTIMIZER DELETED THE UDF-CARRYING FILTER NODE. Its predicate"
        + " is a PLACEHOLDER; the customer's predicate is the UDF. Returning"
        + " the bare scan returns EVERY ROW, silently.",
    )
    assert_true(
        out.tag != PLAN_SCAN,
        "the rewrite collapsed the plan to a bare Scan — the Filter node is"
        + " gone entirely",
    )


# --- 3. ★★★ THE ROOT CAUSE: `_copy_plan` ITSELF DROPPED THE UDF -------------


def test_copy_plan_preserves_the_udf_on_all_three_carriers() raises:
    """★★★ THIS IS THE REAL DEFECT; pushdown was one of ~60 symptoms.

    `_copy_plan_body`'s Filter, Project and Aggregate arms each rebuilt through
    the NON-UDF factory, under a comment saying the field no longer existed —
    removed one day, field restored the next, note never updated. Every
    `_take_*_child` helper routes through `_copy_plan`, and `_copy_plan` is
    called from ~60 sites across six optimizer rule modules plus
    `EngineContext.explain_analyze`.

    ⚠ AND `_copy_plan`'s EXISTING POST-CONDITION PASSED OVER IT. It checks that
    the VARIANT payload is present — and a Filter whose `_filter` is populated
    and whose `udf` is gone satisfies that perfectly. A node can be
    structurally intact and have lost the customer's function."""
    var f = LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        OwnedPointer[UdfData](_udf(UDF_KIND_FILTER, String("cheap"))),
    )
    assert_true(f.has_udf(), "VACUOUS: the filter fixture carries no UDF")
    var f2 = _copy_plan(f)
    assert_true(
        f2.has_udf(),
        "★ _copy_plan DROPPED the UDF from a FILTER. Its `predicate` is the"
        + " `lit(true)` PLACEHOLDER, so the copy returns EVERY ROW silently.",
    )

    var p = _project_with_udf(_scan())
    assert_true(p.has_udf(), "VACUOUS: the project fixture carries no UDF")
    var p2 = _copy_plan(p)
    assert_true(
        p2.has_udf(),
        "★ _copy_plan DROPPED the UDF from a PROJECT. Its `exprs` are"
        + " PLACEHOLDER col-refs, so the copy is a valid-looking projection of"
        + " the wrong columns — harder to diagnose than an empty node.",
    )

    # ...and the copy is INDEPENDENT, not aliased: the whole point of a deep
    # copy. A shared `OwnedPointer` would be a double-free, not a wrong answer,
    # but it would also make the assertion above pass for the wrong reason.
    assert_equal(
        String(p2),
        String(p),
        "the preserved copy does not render identically to its source, so"
        + " something else in the node changed on the way through",
    )


# --- 4. the barrier must not break ordinary pushdown ------------------------


def test_pushdown_still_works_when_no_udf_is_present() raises:
    """★ THE CONTROL. A barrier that stopped ALL pushdown would pass tests 1
    and 2 while destroying the optimizer. This is the same shape as test 1 with
    the UDF removed, and the filter MUST still reach below the Project."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    var plan = LogicalPlan.filter(
        Expr.binary(
            BIN_GT,
            Expr.col_ref(String("a")),
            Expr.literal(ScalarValue.from_int64(Int64(3))),
        ),
        LogicalPlan.project(exprs^, _scan()),
    )
    var out = push_predicates_down(plan^)
    assert_equal(
        Int(out.tag),
        Int(PLAN_PROJECT),
        "★ THE CONTROL FAILED: with no UDF present the Filter did NOT move"
        + " below the Project, so the barrier is over-broad and has disabled"
        + " ordinary predicate pushdown.",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_filter_pushed_through_a_udf_project_does_not_drop_the_udf]()
    suite.test[test_a_udf_filters_placeholder_predicate_does_not_delete_the_node]()
    suite.test[test_copy_plan_preserves_the_udf_on_all_three_carriers]()
    suite.test[test_pushdown_still_works_when_no_udf_is_present]()
    suite^.run()
