# =============================================================================
# expr_udf_sites.mojo — finding the `EXPR_UDF_CALL` nodes in an expression tree
# =============================================================================
#

# ── THE PROBLEM THIS SOLVES, WHICH IS A PACKAGE CYCLE ────────────────────────
#
# `EXPR_UDF_CALL` is evaluated by calling a thunk out of the `UdfRegistry`. The
# registry lives in `komira_engine_operators`, and the column evaluator
# (`compiler_eval_column._eval_column_expr`) lives in `komira_compiler` — which
# `komira_engine_operators` DEPENDS ON. So the evaluator cannot reach the
# registry: `komira_compiler -> komira_engine_operators` would be a cycle.
#
# ★ THE ANSWER IS TO SPLIT THE WORK ACROSS THE SEAM RATHER THAN CROSS IT.
#
#   1. The SDK (which CAN see both) walks the expression, finds every UDF call,
#      runs each one's thunk, and APPENDS the result to the batch under a
#      derived name.
#   2. `_eval_column_expr`'s `EXPR_UDF_CALL` arm then just READS that column.
#      It needs no registry, no thunk and no new parameter — so no resolver
#      is threaded through the evaluator's many call sites and recursive
#      calls, and a large recursive function is not parameterized (which
#      would multiply its comptime-instantiation cost).
#
# `udf_call_column_key` is the contract between the two halves: ONE function,
# called by both, so the producer and the consumer cannot disagree about the
# name. It is derived from `_expr_fingerprint`, which already encodes the UDF's
# identity (name + handle + output type + argument) — so:
#
#   * NESTING works. `upper(affine(col("x")))` collects `affine(col("x"))`,
#     materializes it, and the outer `upper` evaluates over a batch that now
#     holds it.
#   * REPETITION works AND IS DEDUPLICATED. Two occurrences of `affine(x)`
#     produce the same key, so the thunk runs once. That is not an optimization
#     bolted on: the fingerprint IS the identity, so sharing the column is the
#     same claim CSE already makes about every other expression.
#
# ── ⛔ THE TWO HALVES CHECK EACH OTHER, AND THAT IS DELIBERATE ───────────────
#
# If this collector MISSES a UDF node, the evaluator's arm looks for a column
# that is not there and RAISES BY NAME. It cannot compute a wrong value. That
# is why the collector is allowed to be a hand-written ladder at all — the
# failure mode of an incomplete arm set here is a loud refusal downstream, not
# a silent wrong answer, which is the opposite of `_collect_expr_columns`
# (whose missing arm silently prunes a scan column).
#
# It is ALSO why this walk RAISES on a tag it does not know instead of falling
# through. A no-op fall-through would say "this subtree holds no UDF" about a
# subtree it never entered.
# =============================================================================

from std.collections import List

from komira_collections.slab import Slab

from komira_plan_expr.expr import (
    Expr,
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BETWEEN,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_EXTRACT,
    EXPR_IN_LIST,
    EXPR_JSON_EXTRACT,
    EXPR_LITERAL,
    EXPR_MAP_GET,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_REGEXP,
    EXPR_SORT_KEY,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_STRING_OP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_SUBSTRING,
    EXPR_UDF_CALL,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    EXPR_WINDOW_FN,
    expr_tag_name,
)
from komira_plan_ir.plan_helpers import _expr_fingerprint


comptime UDF_COLUMN_PREFIX: String = "__udf:"
"""The prefix every materialized UDF-output column carries.

⚠ `:` MAKES IT UNSPELLABLE IN SQL TEXT, AND THAT IS ALL IT BUYS. A `:` cannot
appear in an unquoted SQL identifier, so no customer can WRITE a name that
collides with this one; a prefix of `__udf_` would be a legal identifier and a
customer column called `__udf_0` would be reachable from query text.

⛔ TWO THINGS THIS PREFIX DOES NOT BUY (both handled elsewhere):

  * ⛔ IT IS NOT COLLISION-PROOF. Column names come from the DATA FILE, not
    from query text, and any UTF-8 string is a legal Parquet field name. A
    parquet whose column is literally `__udf:UDF:12:affine_int64:0:5(C:1:v)` would
    shadow the pre-pass's output, because `Schema.column_index` returns the
    FIRST match — the customer's function would never be applied and rc
    would be 0. `_append_udf_columns` REFUSES that shadow by name
    (`UDF_SCRATCH_NAME_TAKEN`).
  * ⛔ COLLISION-PROOF WOULD NOT BE ENOUGH ANYWAY. A column that cannot
    collide can still ESCAPE: `SELECT *` over a UDF predicate would hand this
    name straight to the customer's output schema when the plan ROOT is the
    Filter and no PROJECT above drops it. Visibility is a different question
    from collision and needs its own answer — the scope in
    `komira_engine_dispatch.udf_scratch_scope`."""


def udf_call_column_key(expr: Expr) raises -> String:
    """The batch column name a UDF call's output is materialized under.

    ★ THE ONE CONTRACT BETWEEN THE SDK PRODUCER AND THE EVALUATOR CONSUMER.
    Both call THIS function; neither spells the name. A second spelling would
    be the two-names bug that `register_scalar` exists to make unrepresentable,
    one layer down.

    Derived from `_expr_fingerprint`, so it encodes the UDF's name, its
    process-local handle, its output type AND its argument subtree. Two
    occurrences of the same call therefore share one column (the thunk runs
    once) and two different UDFs over the same argument do not.

    Raises:
        If `expr` is not an `EXPR_UDF_CALL` node. A key for anything else has
        no meaning and returning one would let a caller look up a column that
        can never exist.
    """
    if expr.tag != EXPR_UDF_CALL:
        raise Error(
            "udf_call_column_key: not a UDF call node (tag "
            + expr_tag_name(expr.tag)
            + ")"
        )
    return UDF_COLUMN_PREFIX + _expr_fingerprint(expr)


def collect_udf_calls(
    expr: Expr,
    mut out: List[Expr],
    refuse_correlated_subquery: Bool = True,
) raises:
    """Append every `EXPR_UDF_CALL` node in `expr`, INNERMOST FIRST.

    ★ POST-ORDER IS THE WHOLE CORRECTNESS ARGUMENT FOR NESTING. A caller runs
    the collected calls in list order, and an inner call's output column must
    already be in the batch when the outer call evaluates its argument. For
    `upper(affine(col("x")))` there is one UDF; for `affine(double(col("x")))`
    there are two and `double` MUST come first. Emitting parent-first would run
    `affine` against a column that does not exist yet — a refusal, not a wrong
    answer, but a refusal on a query that is correct.

    ⚠ DUPLICATES ARE NOT FILTERED HERE. Two occurrences of one call appear
    twice; the caller deduplicates by `udf_call_column_key`, which is the value
    that decides whether they ARE the same call. Filtering here would need this
    walk to know that, and the key is the caller's contract, not this walk's.

    ⛔ THIS WALK RAISES ON AN UNKNOWN TAG RATHER THAN FALLING THROUGH. A no-op
    default would report "no UDF in this subtree" about a subtree it never
    entered — the silent-wrong-answer shape (an open fall-through in a column
    collector silently prunes a scan column); this one cannot, and the cost
    of the strictness is one arm per new tag, which
    `test_expr_walk_unification.mojo` makes impossible to skip by walking
    `[0, EXPR_TAG_COUNT)`.

    Args:
        expr: The expression to walk.
        out: Accumulator, appended to in post-order.
        refuse_correlated_subquery: What to do on meeting an
            `EXPR_CORRELATED_SUBQUERY`, which this walk never enters either
            way. `True` (COLLECTING, the default) raises; `False` (ROUTING)
            returns, contributing no site. The full argument, and why an
            unconditional raise would be a REGRESSION rather than a guard, is
            at the arm itself — read it before changing a caller's choice.
    """
    var tag = expr.tag

    # ---- LEAVES: no child Expr to descend into ------------------------------
    # Each is listed explicitly rather than swept up by a default, so that a
    # future tag cannot join this set by omission.
    if (
        tag == EXPR_COL_REF
        or tag == EXPR_COL_IDX
        or tag == EXPR_LITERAL
        or tag == EXPR_WINDOW_FN
        or tag == EXPR_BETWEEN
        or tag == EXPR_SORT_KEY
    ):
        # ⚠ EXPR_WINDOW_FN IS A LEAF *HERE*, and that is not an oversight: its
        # children are column NAMES (`arg_col`, `partition_by`, `order_by`),
        # not `Expr`s, so there is no subtree to enter. `EXPR_BETWEEN` and
        # `EXPR_SORT_KEY` carry no payload field on `Expr` at all.
        return

    # ---- ONE CHILD ----------------------------------------------------------
    if tag == EXPR_UNARY_OP:
        collect_udf_calls(expr.unary_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_CAST:
        collect_udf_calls(expr.cast_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_ALIAS:
        collect_udf_calls(expr.alias_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_IN_LIST:
        collect_udf_calls(expr.in_list_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_AGG_FN:
        collect_udf_calls(expr.agg_fn_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_EXTRACT:
        collect_udf_calls(expr.extract_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_MATH_FN:
        collect_udf_calls(expr.math_fn_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_SUBSTRING:
        collect_udf_calls(expr.substring_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_STRING_OP:
        collect_udf_calls(expr.string_op_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_STRING_FN:
        collect_udf_calls(expr.string_fn_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_REGEXP:
        collect_udf_calls(expr.regexp_child_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_STRUCT_FIELD:
        collect_udf_calls(
            expr._struct_field.value().parent[], out, refuse_correlated_subquery
        )
        return
    if tag == EXPR_STRUCT_FIELD_IDX:
        collect_udf_calls(
            expr._struct_field_idx.value().parent[], out, refuse_correlated_subquery
        )
        return
    if tag == EXPR_JSON_EXTRACT:
        collect_udf_calls(
            expr._json_extract.value().parent[], out, refuse_correlated_subquery
        )
        return

    # ---- TWO CHILDREN -------------------------------------------------------
    if tag == EXPR_MAP_GET:
        # ⚠ TWO CHILDREN, NOT ONE — `parent` AND `key`. The three nested-access
        # tags above look alike and this one is not: `map_get(m, k)` takes an
        # expression for the KEY, so a UDF can hide in either operand.
        # Grouping it with them would silently skip
        # `m[affine(col("i"))]`.
        collect_udf_calls(
            expr._map_get.value().parent[], out, refuse_correlated_subquery
        )
        collect_udf_calls(expr._map_get.value().key[], out, refuse_correlated_subquery)
        return
    if tag == EXPR_BINARY_OP:
        collect_udf_calls(expr.binary_left_ref(), out, refuse_correlated_subquery)
        collect_udf_calls(expr.binary_right_ref(), out, refuse_correlated_subquery)
        return
    if tag == EXPR_MATH_FN2:
        collect_udf_calls(expr.math_fn2_left_ref(), out, refuse_correlated_subquery)
        collect_udf_calls(expr.math_fn2_right_ref(), out, refuse_correlated_subquery)
        return

    # ---- N CHILDREN ---------------------------------------------------------
    if tag == EXPR_STRING_FN_N:
        # Every argument, IN ORDER, and the
        # order is load-bearing for the same post-order reason the docstring
        # gives — `concat(affine(a), double(b))` needs both inner outputs on
        # the batch, and left-to-right is the order a reader expects them to
        # have been evaluated in.
        for i in range(expr.string_fn_n_num_args()):
            collect_udf_calls(
                expr.string_fn_n_arg_ref(i), out, refuse_correlated_subquery
            )
        return
    if tag == EXPR_WHEN:
        for i in range(expr.when_num_cases()):
            collect_udf_calls(
                expr.when_case_condition_ref(i), out, refuse_correlated_subquery
            )
            collect_udf_calls(
                expr.when_case_result_ref(i), out, refuse_correlated_subquery
            )
        collect_udf_calls(expr.when_default_ref(), out, refuse_correlated_subquery)
        return

    # ---- THE CROSS-EDGE INTO THE PLAN TREE ----------------------------------
    if tag == EXPR_CORRELATED_SUBQUERY:
        # ⛔ NEVER WALKED. The child is a whole `LogicalPlan`, and a UDF inside
        # a correlated subquery would have to be materialized against THAT
        # plan's batches, not the outer node's — a different batch, a different
        # schema, and a column key that would resolve against the wrong rows.
        # So this arm contributes NO SITES either way; the only question is
        # whether not being able to look inside is an ERROR.
        #
        # ⭐ AND THAT ANSWER DEPENDS ON WHO IS ASKING — which is the whole of
        # `refuse_correlated_subquery`:
        #
        #   COLLECTING (default True) — `udf_expr_execution` is about to
        #     materialize `__udf:` columns for THIS batch. It only ever runs
        #     after the router already answered "yes, this tree carries a UDF",
        #     so a subquery it cannot enter really can hide a call that would
        #     resolve against the wrong rows. Refuse, at the cause.
        #
        #   ROUTING (False) — `exprs_carry_udf_call` / `expr_carries_udf_call`
        #     are asked one question: does the OUTER tree carry a UDF call?
        #     That question is ANSWERABLE without entering the subquery, and
        #     the answer is "not from in here".
        #
        # ⛔ WHY THE SPLIT IS NOT OPTIONAL. `plan_root_carries_udf_expr` runs
        # from `EngineContext._materialize_column_plan` BEFORE `_prepare_plan`,
        # i.e. before `decorrelate` — so a correlated subquery is GUARANTEED to
        # still be here when the router walks. An unconditional raise would
        # refuse EVERY plan whose root predicate is a correlated subquery,
        # with a message about a UDF, on plans holding no UDF at all. Pinned by
        # `komira_plan_ir/tests/test_udf_sites_correlated_subquery.mojo`, both
        # directions.
        #
        # ⚠ THE RESIDUAL, AND IT FAILS CLOSED. A UDF living ONLY inside a
        # subquery expression is invisible to the router, so such a plan takes
        # the ordinary path. It does not produce a wrong answer:
        # `compiler_eval_column` refuses an `EXPR_UDF_CALL` whose `__udf:`
        # column is absent from the batch, by name, naming the producer that
        # should have run. One layer later than here, still a refusal.
        #
        # ⛔⛔ THE MESSAGE BELOW MUST NOT SAY "CORRELATED SUBQUERY".
        # `EXPR_CORRELATED_SUBQUERY` is the tag the frontend emits for EVERY
        # scalar subquery, `EXISTS` and `IN (subquery)` — an UNCORRELATED one
        # carries an empty `outer_refs` and the SAME tag:
        #
        #     SELECT k FROM t WHERE u(v) > 8
        #       AND v > (SELECT MAX(s2.v) FROM t s2)      -- NO correlation
        #
        # reaches THIS raise. Telling the customer to `Decorrelate first` on an
        # uncorrelated subquery is advice that cannot be followed: there is no
        # correlation to remove and no rewrite that clears the refusal. Name
        # the tag's real scope, and say the thing that IS actionable (lift the
        # call out of the subquery).
        if refuse_correlated_subquery:
            raise Error(
                "collect_udf_calls: a UDF inside a SUBQUERY EXPRESSION is not"
                " supported — the subquery's rows are not the rows this batch"
                " holds, so the UDF's output column would resolve against the"
                " wrong ones. ⚠ THIS COVERS EVERY SUBQUERY EXPRESSION, NOT"
                " ONLY A CORRELATED ONE: a scalar subquery, `EXISTS` and"
                " `IN (subquery)` all carry the same"
                " `EXPR_CORRELATED_SUBQUERY` tag whether or not they reference"
                " the outer query, so there may be no correlation to remove."
                " Move the UDF call OUT of the subquery (compute it in the"
                " outer SELECT or the outer WHERE) — that is the rewrite that"
                " clears this refusal"
            )
        return

    # ---- THE NODE ITSELF ----------------------------------------------------
    if tag == EXPR_UDF_CALL:
        # POST-ORDER: the argument's own UDF calls are emitted BEFORE this one.
        collect_udf_calls(expr.udf_call_child_ref(), out, refuse_correlated_subquery)
        out.append(expr.copy())
        return

    raise Error(
        "collect_udf_calls: no arm for expression tag "
        + expr_tag_name(tag)
        + ". ⛔ This walk is TOTAL by design: a fall-through would report"
        " 'no UDF in this subtree' about a subtree it never entered. Add the"
        " arm."
    )


def exprs_carry_udf_call(imm exprs: Slab[Expr]) raises -> Bool:
    """Does any expression in `exprs` contain an `EXPR_UDF_CALL` node?

    ⚠ TAKES A `Slab[Expr]`, WHICH IS WHAT `ExprArray` IS. Spelled as the
    underlying type rather than the alias so this module does not have to
    import `logical_plan` — `expr_udf_sites` sits below the plan tree on
    purpose, so that `komira_compiler`'s evaluator can import
    `udf_call_column_key` without dragging one in.

    The cheap routing predicate. Total for the same reason `collect_udf_calls`
    is — it IS `collect_udf_calls`, so the two cannot disagree about what
    "carries a UDF" means, which is the failure mode of a hand-written second
    detector.

    ⭐ THE ONE DOCUMENTED DIFFERENCE, and it is a POLICY argument to the same
    walk rather than a second walk: `refuse_correlated_subquery=False`. A
    router is asked whether the OUTER tree carries a UDF call, and that
    question is answerable without entering a subquery this walk never enters
    anyway. Raising there would refuse every plan whose root predicate is a
    correlated subquery — see the arm in `collect_udf_calls`, and
    `komira_plan_ir/tests/test_udf_sites_correlated_subquery.mojo`.
    """
    var sites = List[Expr]()
    for i in range(len(exprs)):
        collect_udf_calls(exprs[i], sites, refuse_correlated_subquery=False)
    return len(sites) > 0


def expr_carries_udf_call(expr: Expr) raises -> Bool:
    """Single-expression form of `exprs_carry_udf_call` (predicates).

    Carries the same `refuse_correlated_subquery=False`, and for the same
    reason — the FILTER door is where it matters most, because a
    correlated subquery is a PREDICATE."""
    var sites = List[Expr]()
    collect_udf_calls(expr, sites, refuse_correlated_subquery=False)
    return len(sites) > 0
