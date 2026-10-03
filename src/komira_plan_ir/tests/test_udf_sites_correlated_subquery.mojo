# =============================================================================
# test_udf_sites_correlated_subquery — the ROUTING predicate must ANSWER, not
# refuse, when it meets a correlated subquery it cannot enter.
# =============================================================================
#
# ⛔ THE CONTRACT THIS PINS.
#
# `udf_expr_routing.plan_root_carries_udf_expr` is called UNCONDITIONALLY from
# `EngineContext._materialize_column_plan` on every plan, BEFORE
# `_prepare_plan` runs the optimizer. Because the router runs before
# decorrelation, a correlated subquery is GUARANTEED to still be present when
# the walk meets one. If the router refused there — with
#
#   "collect_udf_calls: a UDF inside a SUBQUERY EXPRESSION is not supported"
#
# — every plan whose root is a `FILTER` over a correlated-subquery predicate
# would raise, including plans containing NO UDF AT ALL. That is a routing
# predicate declining to answer a question it was asked and CAN answer: "does
# the OUTER expression tree carry a UDF call?"
#
# ⭐ WHAT IS PRESERVED, and why this file has four tests rather than one.
# The refusal is right to exist — it must not fire from the ROUTER.
# `collect_udf_calls` keeps refusing BY DEFAULT, so the SITE COLLECTOR
# (`udf_expr_execution.materialize_udf_columns`, which runs only AFTER the
# router has already said "yes, this tree carries a UDF") still refuses a
# subquery expression by name — the case the message actually describes.
# `test_the_collector_still_refuses` is the half that would go red if a later
# edit deleted the guard outright.
#
# ⚠ THE RESIDUAL, STATED RATHER THAN HIDDEN: a UDF living ONLY inside a
# correlated subquery is invisible to the router, so such a plan takes the
# ordinary path. It does NOT return a wrong answer — `compiler_eval_column`
# refuses an `EXPR_UDF_CALL` whose `__udf:` column is not on the batch, by
# name, with the producer named in the message. Fails closed, one layer later.
# =============================================================================

from std.collections import Optional
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import SchemaBuilder, Field
from komira_plan_ir.logical_plan import (
    CORR_KIND_EXISTS,
    LogicalPlan,
    SOURCE_PARQUET,
)
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_ir.expr_udf_sites import (
    collect_udf_calls,
    expr_carries_udf_call,
    exprs_carry_udf_call,
)
from komira_collections.slab import Slab


# ===========================================================================
# Fixtures — one correlated subquery, one UDF call, and the pairing of both.
# ===========================================================================


def _inner_plan() raises -> LogicalPlan:
    """A minimal subquery body. Its SHAPE is irrelevant to these walks."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    return LogicalPlan.scan(String("inner.parquet"), SOURCE_PARQUET, sb.build())


def _corr_subquery() raises -> Expr:
    """`EXISTS (SELECT ... WHERE inner.a = outer.o)` — NO UDF anywhere in it."""
    var refs = List[String]()
    refs.append(String("o"))
    return Expr.correlated_subquery(_inner_plan(), refs^, CORR_KIND_EXISTS)


def _udf_call() raises -> Expr:
    """`affine(col("x"))` as the core-level factory spells it."""
    return Expr.udf_call(
        String("affine"),
        Optional[Int](7),
        ArrowType.INT64,
        ArrowType.INT64,
        Expr.col_ref("x"),
    )


# ===========================================================================
# THE ROUTER ANSWERS.
# ===========================================================================


def test_routing_predicate_answers_false_for_a_correlated_subquery() raises:
    """⭐ The router must ANSWER, not raise.

    This is the exact expression `EngineContext._materialize_column_plan`
    hands the router for `LogicalPlan.filter(EXISTS(...), scan)` — the shape
    of a correlated-subquery query such as TPC-H Q17.
    """
    var cs = _corr_subquery()
    assert_false(
        expr_carries_udf_call(cs),
        (
            "a correlated subquery carries no UDF CALL in the OUTER tree, and"
            " the router must say so rather than refuse"
        ),
    )
    _ = cs^


def test_routing_predicate_sees_a_udf_beside_a_correlated_subquery() raises:
    """POSITIVE CONTROL for the test above.

    ⛔ WITHOUT THIS, `assert_false` above is satisfied by a walk that answers
    False for EVERYTHING — the vacuous-green shape. Same tree shape, one UDF
    added on the other side of the `AND`, and the answer must FLIP.
    """
    var combined = Expr.binary(BIN_GT, _udf_call(), _corr_subquery())
    assert_true(
        expr_carries_udf_call(combined),
        (
            "a UDF OUTSIDE the subquery is in this batch's rows and must still"
            " be routed to the UDF arm"
        ),
    )
    _ = combined^


def test_the_collector_still_refuses_a_correlated_subquery() raises:
    """⛔ THE GUARD THAT MUST NOT BE DELETED.

    `collect_udf_calls` is the SITE COLLECTOR and runs only after the router
    said the tree carries a UDF. There, a subquery it cannot enter really can
    hide a call that would have to be materialized against another plan's
    batches — so the default still refuses, by name.

    ⭐⭐ AND THE NAME IT REFUSES BY IS ASSERTED HERE, DELIBERATELY, BECAUSE
    THIS IS THE ONLY GATE OVER THE WORDING A CUSTOMER READS.
    `EXPR_CORRELATED_SUBQUERY` is the tag the frontend emits for EVERY scalar
    subquery / `EXISTS` / `IN (subquery)`, correlated or not, so the message
    says `SUBQUERY EXPRESSION`, not `CORRELATED SUBQUERY`, and does not tell
    the customer to `Decorrelate first`: on an UNCORRELATED subquery that
    advice cannot be followed. A future edit that reverts the message goes red
    HERE, at the string, not in a comment nobody runs.
    """
    var cs = _corr_subquery()
    var sites = List[Expr]()
    with assert_raises(contains="SUBQUERY EXPRESSION"):
        collect_udf_calls(cs, sites)
    _ = cs^


def test_the_refusal_does_not_tell_an_uncorrelated_caller_to_decorrelate(
) raises:
    """⛔ THE OTHER HALF OF THE SAME CORRECTION, AND IT IS A SEPARATE CLAIM.

    Renaming the hazard is not the same as withdrawing the instruction.
    `Decorrelate first` is an ACTION — and for the
    majority of the tag's population (an uncorrelated scalar subquery, `EXISTS`,
    `IN (subquery)`) there is nothing to decorrelate, so a customer who follows
    it changes nothing and the query still refuses.

    Asserted as an ABSENCE, which is weak on its own, so it is paired with the
    presence of the rewrite that DOES clear the refusal (move the call out of
    the subquery). Absence + presence together cannot both be satisfied by a
    message that simply lost its tail.
    """
    var cs = _corr_subquery()
    var sites = List[Expr]()
    var msg = String("")
    try:
        collect_udf_calls(cs, sites)
    except e:
        msg = String(e)
    assert_true(
        msg.byte_length() > 0,
        "the collector did not refuse at all — see the test above",
    )
    assert_true(
        "Decorrelate first" not in msg,
        (
            "the refusal still says `Decorrelate first`. That is unfollowable"
            " advice for the uncorrelated majority of this tag's population"
            " (a scalar subquery / EXISTS / IN(subquery) carries"
            " EXPR_CORRELATED_SUBQUERY with an EMPTY outer_refs). Message: "
        )
        + msg,
    )
    assert_true(
        "OUT of the subquery" in msg,
        (
            "the refusal does not name the rewrite that actually clears it, so"
            " it reports a dead end rather than a route. Message: "
        )
        + msg,
    )
    _ = cs^


def test_the_collector_collects_a_plain_udf_call() raises:
    """POSITIVE CONTROL for the collector: it is not refusing everything."""
    var e = _udf_call()
    var sites = List[Expr]()
    collect_udf_calls(e, sites)
    assert_equal(len(sites), 1, "one UDF call, one site")
    assert_equal(sites[0].udf_call_name(), String("affine"))
    _ = e^


def test_the_slab_form_answers_for_a_correlated_subquery_too() raises:
    """`exprs_carry_udf_call` is the PROJECT door; the filter door is the
    single-expression form above. Both reach the same walk and both had the
    same contract, so both are pinned — a fix applied to one is not a fix."""
    var xs = Slab[Expr]()
    xs.append(Expr.col_ref("a"))
    xs.append(_corr_subquery())
    assert_false(
        exprs_carry_udf_call(xs),
        "no UDF in the outer tree of any member",
    )
    xs.append(_udf_call())
    assert_true(
        exprs_carry_udf_call(xs),
        "POSITIVE CONTROL: the same list, one UDF added, must flip",
    )
    _ = xs^


def main() raises:
    var ts = TestSuite()
    ts.test[test_routing_predicate_answers_false_for_a_correlated_subquery]()
    ts.test[test_routing_predicate_sees_a_udf_beside_a_correlated_subquery]()
    ts.test[test_the_collector_still_refuses_a_correlated_subquery]()
    ts.test[
        test_the_refusal_does_not_tell_an_uncorrelated_caller_to_decorrelate
    ]()
    ts.test[test_the_collector_collects_a_plain_udf_call]()
    ts.test[test_the_slab_form_answers_for_a_correlated_subquery_too]()
    ts^.run()
