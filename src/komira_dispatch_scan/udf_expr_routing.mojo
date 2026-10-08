# =============================================================================
# udf_expr_routing.mojo — "does THIS node need the UDF pre-pass?"
# =============================================================================
#
# The router that decides whether a plan takes the UDF path is the thing a
# wrong answer hides behind, so it is written down once, in its own module (as
# `udf_execution_refusal.mojo` is), and read by one caller rather than inlined
# at each.
#
# There are TWO questions and this file answers BOTH, because collapsing them
# into one is a defect: a router that asks only about the ROOT node hands a
# plan whose UDF sits lower down (`SELECT k FROM t WHERE u(v) > 8`, a projection
# without a UDF over a filter with one) to the walker with no UDF arm, and the
# caller gets `the UDF 'X' was not materialized onto this batch`.
#
#   1. `plan_root_carries_udf_expr` — CAN THE ARM SERVE THIS NODE? PROJECT and
#      FILTER only, because those are the only two node kinds the UDF arm of
#      the column materializer has a route for.
#   2. `plan_carries_udf_expr` — IS THERE A UDF ANYWHERE IN THIS SUBTREE? The
#      question the router has to ask before it may hand a plan to a walker
#      with no UDF arm.
#      ⚠ "IN THIS SUBTREE" MEANS THIS PLAN TREE'S OWN NODES AND THEIR OWN
#      EXPRESSIONS. It does NOT mean the plan hanging off an
#      `EXPR_CORRELATED_SUBQUERY` — the one cross-edge from the expression
#      tree back into the plan tree, which neither walk enters, and which is
#      how the frontend spells every scalar subquery / EXISTS / IN(subquery)
#      whether or not it is correlated. That is the router's ONE residual and
#      it fails closed; `node_own_exprs_carry_udf_expr`'s docstring carries
#      the detail.
#
# When (2) is yes while (1) is no, the column materializer EXECUTES each
# UDF-carrying child and re-roots the result as an in-memory scan, one level at
# a time.
#
# ⚠ `plan_carries_udf_expr` IS TOTAL AND RAISES ON A TAG IT DOES NOT MODEL, for
# the reason `collect_udf_calls` does: this walk's FALSE is what authorises
# handing a plan to an evaluator with no UDF arm. A fall-through default would
# report "no UDF under here" about a subtree it never entered — which is the
# defect above, generalised to every future plan tag.
# =============================================================================

from komira_plan_ir.expr_udf_sites import (
    expr_carries_udf_call,
    exprs_carry_udf_call,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_ASOF_JOIN,
    PLAN_CAST_TO_VARCHAR,
    PLAN_CSE_REF,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    plan_tag_name,
)


def plan_root_carries_udf_expr(imm plan: LogicalPlan) raises -> Bool:
    """Can the column materializer's UDF-expression ARM serve this node?

    True for a `PLAN_PROJECT` whose `exprs` contain an `EXPR_UDF_CALL`
    (`with_columns` / `select`) and for a `PLAN_FILTER` whose predicate does.
    Those are the two node kinds that hold customer expressions AND that the
    arm has a route for.

    ⛔ THIS IS A SERVABILITY QUESTION, NOT A PRESENCE ONE, AND CONFLATING THE
    TWO IS THE DEFECT IN THE MODULE HEADER. A `False` here does NOT mean "this
    subtree holds no UDF" — an AGGREGATE over a UDF-carrying FILTER answers False and holds
    two. `plan_carries_udf_expr` is the presence question; every caller that is
    about to hand the plan somewhere with no UDF arm must ask THAT one.

    ⛔ IT RAISES RATHER THAN ANSWERING FALSE when the walk meets an expression
    tag it does not know. A router that answers "no UDF here" about a subtree
    it could not read sends the plan to a walker with no UDF arm, which
    evaluates the projection WITHOUT the customer's function and returns a
    wrong answer with a success code. `collect_udf_calls` is total for exactly
    this reason and this function inherits it.
    """
    if plan.tag == PLAN_PROJECT and plan._project:
        return exprs_carry_udf_call(plan._project.value()[].exprs)
    if plan.tag == PLAN_FILTER and plan._filter:
        return expr_carries_udf_call(plan._filter.value()[].predicate)
    return False


def node_own_exprs_carry_udf_expr(imm plan: LogicalPlan) raises -> Bool:
    """Do THIS NODE's own expressions carry an `EXPR_UDF_CALL` — for EVERY node
    kind, not only the two the arm can serve?

    ⚠ THE PLAN-NODE HALF OF THIS LADDER IS THE SAME ONE
    `komira_plan_ir.scan_binding_bind_pass` WALKS, and deliberately so: that
    pass enumerates every `Expr` a plan node can hold for the same class of
    reason (a site it misses is a payload nothing binds). ⛔ THE TWO WALKS ARE **NOT** THE SAME ONE LEVEL
    FURTHER IN — see the block below. Five node kinds hold an
    `Expr`:

        SCAN       `ScanData.filter`     (a pushed-down predicate)
        FILTER     `FilterData.predicate`
        PROJECT    `ProjectData.exprs`
        AGGREGATE  `group_by` + all FOUR `AggExpr` child slots
        JOIN       `JoinData.residual`   (the non-equi condition)

    Every other node kind carries column NAMES (`List[String]`) or scalars —
    SORT / TOPN / PARTITION_BY / PARTITION_TOPN keys, DISTINCT columns, ASOF
    keys — so there is no expression site to read. That is a fact about the
    variant structs (`komira_plan_ir.logical_plan_variants`), re-derived here
    rather than assumed; if one of them grows an `Expr` field it must grow an
    arm here.

    ⚠ ALL FOUR AggExpr SLOTS, NOT `num_children()` — that accessor STOPS at the
    first empty slot, so a sparsely populated AggExpr would hide the later
    ones.

    ⛔⛔ AND HERE IS WHERE THE TWO WALKS DIVERGE. They agree about which NODE
    KIND holds an `Expr`. They disagree about how far INTO an `Expr` each may
    go, at ONE tag: `EXPR_CORRELATED_SUBQUERY` — the single cross-edge from the
    expression tree back into the plan tree, and the spelling SQL uses for
    EVERY scalar subquery, `EXISTS`, and `IN (subquery)`, whether or not it is
    actually correlated.

        bind pass   FOLLOWS it, because an in-memory scan inside a subquery
                    that nothing binds is a node the readers cannot serve.
        this walk   STOPS there. `expr_carries_udf_call` calls
                    `collect_udf_calls(..., refuse_correlated_subquery=False)`,
                    whose cross-edge arm contributes no site in EITHER mode.
                    Also deliberate: the router runs BEFORE `decorrelate`, so
                    an unconditional raise there would refuse every
                    subquery-carrying plan holding no UDF at all.

    ⇒ ⚠ THIS FUNCTION IS TOTAL OVER PLAN TAGS, NOT OVER "WHERE A UDF CAN LIVE".
    A UDF whose only occurrence is inside ANY subquery expression answers
    `False` here and `False` from `plan_carries_udf_expr`, so the router
    neither serves nor splices it and the plan goes to a walker with no UDF
    arm. The subquery need not be correlated:

        SELECT k FROM t WHERE v > (SELECT MAX(u(s2.v)) FROM t s2)
          -> the UDF `u` was not materialized onto this batch
        SELECT k FROM t WHERE v > (SELECT MAX(3 * s2.v + 5) FROM t s2)
          -> ANSWERS

    It fails CLOSED — the column evaluator refuses the `EXPR_UDF_CALL` by name
    when its `__udf:` column is absent — and that refusal, not this walk, is
    what keeps a wrong answer off the wire.

    RAISES on a plan tag it does not model. See the module header.
    """
    var tag = plan.tag

    if tag == PLAN_SCAN:
        if not plan._scan:
            return False
        ref sd = plan._scan.value()[]
        if sd.filter:
            return expr_carries_udf_call(sd.filter.value())
        return False
    if tag == PLAN_FILTER:
        if not plan._filter:
            return False
        return expr_carries_udf_call(plan._filter.value()[].predicate)
    if tag == PLAN_PROJECT:
        if not plan._project:
            return False
        return exprs_carry_udf_call(plan._project.value()[].exprs)
    if tag == PLAN_AGGREGATE:
        if not plan._aggregate:
            return False
        ref a = plan._aggregate.value()[]
        if exprs_carry_udf_call(a.group_by):
            return True
        for i in range(len(a.agg_exprs)):
            ref ae = a.agg_exprs[i]
            if ae.child and expr_carries_udf_call(ae.child.value()):
                return True
            if ae.child1 and expr_carries_udf_call(ae.child1.value()):
                return True
            if ae.child2 and expr_carries_udf_call(ae.child2.value()):
                return True
            if ae.child3 and expr_carries_udf_call(ae.child3.value()):
                return True
        return False
    if tag == PLAN_JOIN:
        if not plan._join:
            return False
        ref j = plan._join.value()[]
        if j.residual:
            return expr_carries_udf_call(j.residual.value()[])
        return False

    # ---- GENUINE EXPRESSION-FREE NODES, ENUMERATED RATHER THAN DEFAULTED ----
    # "has no expression site" is a FACT about these tags, checked against
    # the variant structs, not the absence of an arm.
    if (
        tag == PLAN_SORT
        or tag == PLAN_LIMIT
        or tag == PLAN_DISTINCT
        or tag == PLAN_TOPN
        or tag == PLAN_PARTITION_BY
        or tag == PLAN_PARTITION_TOPN
        or tag == PLAN_CAST_TO_VARCHAR
        or tag == PLAN_ASOF_JOIN
        or tag == PLAN_UNION
        or tag == PLAN_VIEW_REF
        or tag == PLAN_CSE_REF
    ):
        return False

    raise Error(
        "UDF_ROUTING_UNMODELLED_PLAN_TAG: the UDF presence walk has no arm for"
        " plan tag "
        + String(Int(tag))
        + " ("
        + plan_tag_name(tag)
        + "). ⛔ REFUSED RATHER THAN ANSWERED `False`: a `False` from this walk"
        " is what authorises handing the plan to an evaluator with NO UDF arm,"
        " so a fall-through would report 'no UDF under here' about a node it"
        " never read — the customer's function silently skipped, with a success"
        " code. Add the arm: name the node's `Expr` sites, or return False with"
        " a comment saying it has none."
    )


def plan_carries_udf_expr(imm plan: LogicalPlan) raises -> Bool:
    """Does ANY node in this subtree carry an `EXPR_UDF_CALL`?

    ★ THE PRESENCE QUESTION. `plan_root_carries_udf_expr` answers the
    SERVABILITY one; a router that asks only that one has the defect in the
    module header.

    Total over plan tags (`node_own_exprs_carry_udf_expr` raises on a tag it
    does not model) and over expression tags (`collect_udf_calls` raises on
    one it does not model), so a `False` from here means the walk READ the
    whole subtree and found nothing — never that it could not read it.

    ⚠ A UDF living ONLY inside a SUBQUERY EXPRESSION is invisible to this walk,
    exactly as it is to `plan_root_carries_udf_expr`, and for the same reason:
    both call the collector with `refuse_correlated_subquery=False`, because
    this runs BEFORE `decorrelate` and an unconditional raise there would
    refuse every subquery-carrying plan holding no UDF at all. It fails
    CLOSED: such a plan takes the ordinary path and the column evaluator
    refuses the `EXPR_UDF_CALL` by name when its column is absent.

    ⛔ "CORRELATED" IS THE TAG'S NAME, NOT THE SCOPE OF THE GAP.
    `EXPR_CORRELATED_SUBQUERY` is how the SQL frontend spells EVERY scalar
    subquery, `EXISTS` and `IN (subquery)` — an UNCORRELATED one carries an
    empty `outer_refs` and the SAME tag. See `node_own_exprs_carry_udf_expr`
    for the ladder that diverges here.
    """
    if node_own_exprs_carry_udf_expr(plan):
        return True

    var tag = plan.tag
    if tag == PLAN_FILTER and plan._filter:
        return plan_carries_udf_expr(plan._filter.value()[].child[])
    if tag == PLAN_PROJECT and plan._project:
        return plan_carries_udf_expr(plan._project.value()[].child[])
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return plan_carries_udf_expr(plan._aggregate.value()[].child[])
    if tag == PLAN_SORT and plan._sort:
        return plan_carries_udf_expr(plan._sort.value()[].child[])
    if tag == PLAN_LIMIT and plan._limit:
        return plan_carries_udf_expr(plan._limit.value()[].child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return plan_carries_udf_expr(plan._distinct.value()[].child[])
    if tag == PLAN_TOPN and plan._topn:
        return plan_carries_udf_expr(plan._topn.value()[].child[])
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return plan_carries_udf_expr(plan._partition_by.value()[].child[])
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return plan_carries_udf_expr(plan._partition_topn.value()[].child[])
    if tag == PLAN_CAST_TO_VARCHAR and plan._cast_to_varchar:
        return plan_carries_udf_expr(plan._cast_to_varchar.value()[].child[])
    if tag == PLAN_JOIN and plan._join:
        ref j = plan._join.value()[]
        # BOTH sides, always — a UDF on the build side is the shape a left-only
        # walk would miss.
        if plan_carries_udf_expr(j.left[]):
            return True
        return plan_carries_udf_expr(j.right[])
    if tag == PLAN_ASOF_JOIN and plan._asof_join:
        ref a = plan._asof_join.value()[]
        if plan_carries_udf_expr(a.left[]):
            return True
        return plan_carries_udf_expr(a.right[])
    if tag == PLAN_UNION and plan._union:
        ref u = plan._union.value()[]
        for i in range(u.num_children()):
            if plan_carries_udf_expr(u.children[i][]):
                return True
        return False
    # PLAN_SCAN / PLAN_VIEW_REF / PLAN_CSE_REF are genuine leaves of this
    # walk, and so is a node whose payload is absent. A SCAN's own `filter`
    # was already read by `node_own_exprs_carry_udf_expr` above.
    return False


def first_udf_carrying_node_tag(imm plan: LogicalPlan) raises -> Int:
    """Pre-order: the tag of the FIRST node whose own expressions carry a UDF,
    or `-1` if none does.

    Exists so a refusal can NAME the node kind that stopped it. A message that
    says only "a UDF is somewhere in this plan" sends the reader back to the
    query text with no way to tell an aggregand from a join residual, and those
    two have different answers.
    """
    if node_own_exprs_carry_udf_expr(plan):
        return Int(plan.tag)

    var tag = plan.tag
    if tag == PLAN_FILTER and plan._filter:
        return first_udf_carrying_node_tag(plan._filter.value()[].child[])
    if tag == PLAN_PROJECT and plan._project:
        return first_udf_carrying_node_tag(plan._project.value()[].child[])
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return first_udf_carrying_node_tag(plan._aggregate.value()[].child[])
    if tag == PLAN_SORT and plan._sort:
        return first_udf_carrying_node_tag(plan._sort.value()[].child[])
    if tag == PLAN_LIMIT and plan._limit:
        return first_udf_carrying_node_tag(plan._limit.value()[].child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return first_udf_carrying_node_tag(plan._distinct.value()[].child[])
    if tag == PLAN_TOPN and plan._topn:
        return first_udf_carrying_node_tag(plan._topn.value()[].child[])
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return first_udf_carrying_node_tag(
            plan._partition_by.value()[].child[]
        )
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return first_udf_carrying_node_tag(
            plan._partition_topn.value()[].child[]
        )
    if tag == PLAN_CAST_TO_VARCHAR and plan._cast_to_varchar:
        return first_udf_carrying_node_tag(
            plan._cast_to_varchar.value()[].child[]
        )
    if tag == PLAN_JOIN and plan._join:
        ref j = plan._join.value()[]
        var l = first_udf_carrying_node_tag(j.left[])
        if l >= 0:
            return l
        return first_udf_carrying_node_tag(j.right[])
    if tag == PLAN_ASOF_JOIN and plan._asof_join:
        ref a = plan._asof_join.value()[]
        var l2 = first_udf_carrying_node_tag(a.left[])
        if l2 >= 0:
            return l2
        return first_udf_carrying_node_tag(a.right[])
    if tag == PLAN_UNION and plan._union:
        ref u = plan._union.value()[]
        for i in range(u.num_children()):
            var c = first_udf_carrying_node_tag(u.children[i][])
            if c >= 0:
                return c
        return -1
    return -1
