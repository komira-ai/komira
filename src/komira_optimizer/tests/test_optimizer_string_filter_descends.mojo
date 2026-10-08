# =============================================================================
# TPC-H q9 stranded string filter regression guard
# =============================================================================
#
# Bug class: a single-table STRING predicate (`col LIKE ...` / `.contains` /
# `.starts_with` / `.ends_with`) over a comma-join FROM-list was NEVER pushed
# to its owning scan — it stayed as a Filter above the ENTIRE join tree, so the
# multi-way join processed every row and applied the (typically ~5% selective)
# string filter LAST. On TPC-H q9 (`p_name LIKE '%green%'`) this left the
# ~800K-partsupp / 6M-lineitem join chain running at full width instead of
# filtering `part` first.
#
# TWO root causes, both in `optimizer_filter.push_predicates_down` /
# `_predicate_refs_in_schema`:
#   (1) `_predicate_refs_in_schema` had NO `EXPR_STRING_OP` arm, so a string
#       predicate fell through to the `return True` fallback and evaluated as
#       `refs_left == refs_right == True` (references EVERY schema) in the
#       Filter-through-Join arm -> "spans both sides" -> parked at the top.
#   (2) Even once (1) let it descend through the outer joins, the string filter
#       was PARKED above the both-sides bridging equi-conjunct (`p_partkey =
#       l_partkey`, which correctly can't descend the join) by the Filter-
#       through-Filter anti-recursion guard. The conditional swap now pushes the
#       single-table filter PAST the (commuting) bridging filter to its scan.
#
# FAILS ON PRE-FIX CODE: `_string_filter_child_tag` returns PLAN_JOIN
# (the green filter sits above the folded `part x lineitem` INNER join) instead
# of PLAN_SCAN — both guard tests below assert PLAN_SCAN, so both fail on the
# pre-fix commit.
#
# =============================================================================
# THE SAME HOLE, ONE TAG OVER: EXPR_REGEXP
# =============================================================================
#
# `_predicate_refs_in_schema` is a CLOSED walker with an OPEN fallback: a run
# of `elif` arms and `return True` for everything else. Fixing EXPR_STRING_OP in
# its own change fixed one tag, not the fallback, so the identical bug stayed live
# for EXPR_REGEXP (tag 15) — and EXPR_REGEXP is not exotic: it is what BOTH
# Python skins (not in this tree) emit for an interior-wildcard LIKE, because `%a%b%` is not
# `contains(a) AND contains(b)` (that loses the order) and lowers to
# `.str.contains("a.*b")` in pandas and polars alike (the skins' LIKE
# lowering, its `"regex"` arm).
#
# WHAT LED HERE — AND NOT WHAT THIS FIXES. For tpch/q13
# (`o_comment NOT LIKE '%special%requests%'`) and tpch/q16
# (`s_comment LIKE '%Customer%Complaints%'`) the sql and mojo surfaces (not in
# this tree) emit
# `StringOp(LIKE, ...)` while the two Python skins emit `Regexp`, so the
# surfaces author two different predicate nodes for one question. This file
# guards only where the `Regexp` filter lands (the pushdown); it says nothing
# about how either node is evaluated.
#
# The other three TPC-H LIKEs (q2 `%BRASS`, q9 `%green%`, q20 `forest%`) are
# single-wildcard and lower to STRING_OP's contains/starts_with/ends_with.
#
# The sibling column-need walker (`plan_helpers._collect_expr_columns` in
# komira_plan_ir) grew its EXPR_REGEXP arm earlier, which is why this defect
# costs TIME and not CORRECTNESS: that walk still reports the column, so the
# answer is the same while one plan reads far more rows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.memory import OwnedPointer

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, EXPR_STRING_OP, EXPR_REGEXP, STR_LIKE, BIN_AND, BIN_EQ, UN_NOT
from komira_plan_ir.logical_plan import (
    JOIN_ALGO_AUTO,
    JOIN_CROSS,
    JOIN_INNER,
    JOIN_LEFT,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan import PLAN_FILTER
from komira_optimizer.optimizer_filter import (
    push_predicates_down,
    decompose_filters,
    eliminate_cross_join,
    push_join_residual_to_side,
)


def _part_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("p_partkey", ArrowType.INT64, False))
    b.add_field(Field("p_name", ArrowType.STRING, False))
    return b.build()


def _line_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("l_partkey", ArrowType.INT64, False))
    b.add_field(Field("l_extendedprice", ArrowType.FLOAT64, False))
    return b.build()


def _scan(path: String, var schema: Schema) -> LogicalPlan:
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    var none_rc: Optional[Int] = None
    return LogicalPlan.scan(path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, none_rc^)


def _string_filter_child_tag(plan: LogicalPlan) -> Int:
    """Return the plan tag of the CHILD of the first Filter whose predicate is a
    string op (LIKE/contains/...). -1 if there is no such filter. This is the
    load-bearing probe: after pushdown, the string filter's child MUST be a Scan
    (the filter landed on its owning scan); if it is a Join the filter is
    stranded above the join (the bug)."""
    if plan.is_filter():
        ref fd = plan.filter_data_ref()
        if fd.predicate.tag == EXPR_STRING_OP:
            return Int(fd.child[].tag)
        return _string_filter_child_tag(fd.child[])
    if plan.is_join():
        ref jd = plan.join_data_ref()
        var l = _string_filter_child_tag(jd.left[])
        if l >= 0:
            return l
        return _string_filter_child_tag(jd.right[])
    return -1


def test_string_filter_descends_to_scan_through_bridging_conjunct() raises:
    """q9 shape: `p_name LIKE '%green%'` AND `p_partkey = l_partkey` over
    `part CROSS lineitem`. After decompose -> push -> eliminate_cross -> push,
    the string filter MUST sit directly above the `part` scan (child tag ==
    PLAN_SCAN), NOT above the folded INNER join.

    FAILS ON PRE-FIX CODE: the string filter parks above the join
    (child tag == PLAN_JOIN) because `_predicate_refs_in_schema` lacked the
    EXPR_STRING_OP arm AND the Filter-through-Filter guard parked it above the
    bridging conjunct."""
    var part = _scan("part.parquet", _part_schema())
    var line = _scan("lineitem.parquet", _line_schema())

    # Raw comma-join shape: CROSS join + a top AND filter carrying the bridging
    # equi-conjunct + the single-table LIKE (the shape a SQL binder, not in this
    # tree, produces for `FROM part, lineitem WHERE p_partkey = l_partkey AND
    # p_name LIKE ...`).
    var empty_l = List[String]()
    var empty_r = List[String]()
    var cross = LogicalPlan.join(part^, line^, empty_l^, empty_r^, JOIN_CROSS)

    var green = Expr.string_op(STR_LIKE, Expr.col_ref("p_name"), "%green%")
    var bridging = Expr.binary(
        BIN_EQ, Expr.col_ref("p_partkey"), Expr.col_ref("l_partkey")
    )
    var combined = Expr.binary(BIN_AND, bridging^, green^)
    var plan = LogicalPlan.filter(combined^, cross^)

    # The filter/join sequence these passes are designed to run in
    # (komira_optimizer has no driver that orders its passes).
    plan = decompose_filters(plan^)
    plan = push_predicates_down(plan^)
    plan = eliminate_cross_join(plan^)
    plan = push_predicates_down(plan^)

    var child_tag = _string_filter_child_tag(plan)
    assert_true(
        child_tag >= 0,
        "the p_name LIKE filter must still be present after pushdown",
    )
    assert_equal(
        child_tag,
        Int(PLAN_SCAN),
        "p_name LIKE must be pushed DIRECTLY onto its owning scan (PLAN_SCAN),"
        " not stranded above the join",
    )


def test_string_filter_over_inner_join_pushes_to_side() raises:
    """Minimal STRING_OP-arm guard: `Filter(p_name LIKE, INNER(part, line))`
    with a real key. After push_predicates_down the top is the JOIN (the string
    filter descended into the part side), not a Filter parked above it.

    FAILS ON PRE-FIX CODE: `_predicate_refs_in_schema` returns True
    for BOTH sides on the STRING_OP (missing arm) -> "spans both" -> parked ->
    the top stays a Filter."""
    var part = _scan("part.parquet", _part_schema())
    var line = _scan("lineitem.parquet", _line_schema())
    var lk = List[String]()
    lk.append("l_partkey")
    var rk = List[String]()
    rk.append("p_partkey")
    var joined = LogicalPlan.join(line^, part^, lk^, rk^, JOIN_INNER)

    var green = Expr.string_op(STR_LIKE, Expr.col_ref("p_name"), "%green%")
    var plan = LogicalPlan.filter(green^, joined^)
    plan = push_predicates_down(plan^)

    assert_true(
        plan.is_join(),
        "a single-table string filter over an INNER join must descend into the"
        " owning side, leaving the JOIN at the top (not a parked Filter)",
    )
    assert_equal(_string_filter_child_tag(plan), Int(PLAN_SCAN))


def _regexp_filter_child_tag(plan: LogicalPlan) -> Int:
    """The EXPR_REGEXP twin of `_string_filter_child_tag`. Deliberately a second
    function rather than a tag parameter on the first: the two STRING_OP guards
    above must keep failing/passing on their own evidence, independent of any
    edit made for the REGEXP arm."""
    if plan.is_filter():
        ref fd = plan.filter_data_ref()
        if fd.predicate.tag == EXPR_REGEXP:
            return Int(fd.child[].tag)
        return _regexp_filter_child_tag(fd.child[])
    if plan.is_join():
        ref jd = plan.join_data_ref()
        var l = _regexp_filter_child_tag(jd.left[])
        if l >= 0:
            return l
        return _regexp_filter_child_tag(jd.right[])
    return -1


def test_regexp_filter_over_inner_join_pushes_to_side() raises:
    """Minimal EXPR_REGEXP-arm guard, the exact twin of the STRING_OP one above:
    `Filter(regexp_like(p_name, ...), INNER(line, part))`. After
    push_predicates_down the top MUST be the JOIN (the regexp filter descended
    into the `part` side), not a Filter parked above it.

    FAILS ON PRE-FIX CODE: `_predicate_refs_in_schema` has no EXPR_REGEXP arm,
    so the predicate hits the `return True` fallback and reads as referencing
    EVERY schema -> `refs_left == refs_right == True` -> "spans both sides" ->
    parked at the top, and `plan.is_join()` is False."""
    var part = _scan("part.parquet", _part_schema())
    var line = _scan("lineitem.parquet", _line_schema())
    var lk = List[String]()
    lk.append("l_partkey")
    var rk = List[String]()
    rk.append("p_partkey")
    var joined = LogicalPlan.join(line^, part^, lk^, rk^, JOIN_INNER)

    # What both skins author for `p_name LIKE '%spec%req%'` — an interior
    # wildcard, so `like_shape` returns its "regex" arm rather than contains.
    var rx = Expr.regexp_like(Expr.col_ref("p_name"), "(?s)spec.*req")
    var plan = LogicalPlan.filter(rx^, joined^)
    plan = push_predicates_down(plan^)

    # PROBE (not decoration): a test runner that catches each member's
    # exception may print ONLY the member name, discarding the message.
    # Without these prints a RED here is indistinguishable from a member
    # that never ran.
    print("REGEXP-PROBE inner_join: top.is_join =", plan.is_join(),
          " regexp_filter_child_tag =", _regexp_filter_child_tag(plan),
          " (PLAN_SCAN =", Int(PLAN_SCAN), ", PLAN_JOIN =", Int(PLAN_JOIN), ")")

    assert_true(
        plan.is_join(),
        "a single-table REGEXP filter over an INNER join must descend into the"
        " owning side, leaving the JOIN at the top (not a parked Filter)",
    )
    assert_equal(
        _regexp_filter_child_tag(plan),
        Int(PLAN_SCAN),
        "regexp_like(p_name) must land directly on its owning scan",
    )


def test_regexp_filter_descends_to_scan_through_bridging_conjunct() raises:
    """The tpch/q13 + q16 shape: an interior-wildcard LIKE as the skins lower it
    (`Regexp`) sitting next to a bridging equi-conjunct over a comma-join. After
    decompose -> push -> eliminate_cross -> push the regexp filter MUST sit
    directly above its owning scan, not above the folded INNER join.

    FAILS ON PRE-FIX CODE: `_regexp_filter_child_tag` returns PLAN_JOIN — the
    filter is stranded above the join, so the join runs at full width and the
    selective predicate is applied LAST.

    ⚠ THIS IS THE PREDICATE SHAPE q13 AND q16 HAVE. The test guards where the
    filter lands, never how the predicate is evaluated."""
    var part = _scan("part.parquet", _part_schema())
    var line = _scan("lineitem.parquet", _line_schema())

    var empty_l = List[String]()
    var empty_r = List[String]()
    var cross = LogicalPlan.join(part^, line^, empty_l^, empty_r^, JOIN_CROSS)

    var rx = Expr.regexp_like(Expr.col_ref("p_name"), "(?s)spec.*req")
    var bridging = Expr.binary(
        BIN_EQ, Expr.col_ref("p_partkey"), Expr.col_ref("l_partkey")
    )
    var combined = Expr.binary(BIN_AND, bridging^, rx^)
    var plan = LogicalPlan.filter(combined^, cross^)

    plan = decompose_filters(plan^)
    plan = push_predicates_down(plan^)
    plan = eliminate_cross_join(plan^)
    plan = push_predicates_down(plan^)

    var child_tag = _regexp_filter_child_tag(plan)
    print("REGEXP-PROBE comma_join: regexp_filter_child_tag =", child_tag,
          " (PLAN_SCAN =", Int(PLAN_SCAN), ", PLAN_JOIN =", Int(PLAN_JOIN), ")")
    assert_true(
        child_tag >= 0,
        "the regexp filter must still be present after pushdown",
    )
    assert_equal(
        child_tag,
        Int(PLAN_SCAN),
        "an interior-wildcard LIKE (which both skins lower to Regexp) must be"
        " pushed DIRECTLY onto its owning scan (PLAN_SCAN), not stranded above"
        " the join. This guards the PUSHDOWN, not the q13/q16 corpus ratio —"
        " that gap is the regexp KERNEL and survives this fix",
    )


def _customer_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("c_custkey", ArrowType.INT64, False))
    return b.build()


def _orders_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("o_custkey", ArrowType.INT64, False))
    b.add_field(Field("o_orderkey", ArrowType.INT64, False))
    b.add_field(Field("o_comment", ArrowType.STRING, False))
    return b.build()


def test_regexp_left_join_residual_pushes_to_right_side() raises:
    """★ THE tpch/q13 SHAPE ITSELF, and the one the two tests above do NOT
    cover. q13's interior-wildcard LIKE is not in a WHERE — it is a conjunct of
    a LEFT OUTER JOIN's ON clause:

        customer LEFT JOIN orders
          ON c_custkey = o_custkey
         AND o_comment NOT LIKE '%special%requests%'

    so the rule that must move it is `push_join_residual_to_side` /
    `_split_join_residual_to_side`, NOT `push_predicates_down`. Both call the
    same `_predicate_refs_in_schema`, which is why one missing arm reaches both.

    The conjunct is `NOT(Regexp(o_comment, ...))` — RIGHT-side only, and the
    right child is the null-supplying side of a LEFT join, which is exactly the
    case `_split_join_residual_to_side` licenses (`refs_right and not
    refs_left` pushes for INNER *and* LEFT). So it MUST leave the residual and
    land as a Filter on the `orders` side.

    FAILS ON PRE-FIX CODE: with no EXPR_REGEXP arm the walker returns True for
    BOTH schemas, so the conjunct is classified "both-sides / neither" and
    takes the `else: kept.append(...)` branch — the residual survives, the LEFT
    join carries a per-row regex, and `orders` is scanned unfiltered with its
    `o_comment` column materialised for every row.

    ⚠ DO NOT DELETE THIS AS DEAD CODE. Both Python skins (not in this tree)
    are designed to pre-push q13's ON-conjunct themselves (their own residual
    pushdown), so from that path the
    optimizer would not see the residual. The fix is REAL but
    LATENT — it is the rule that catches this shape from any OTHER author (a
    hand-built plan, a future skin that does not pre-push, SQL that reaches
    `push_join_residual_to_side` first), and this test is the only thing
    holding it. Its greenness is therefore NOT evidence about q13."""
    var cust = _scan("customer.parquet", _customer_schema())
    var orders = _scan("orders.parquet", _orders_schema())
    var lk = List[String]()
    lk.append("c_custkey")
    var rk = List[String]()
    rk.append("o_custkey")

    var resid = Expr.unary(
        UN_NOT,
        Expr.regexp_like(
            Expr.col_ref("o_comment"), "(?s)special.*requests"
        ),
    )
    var plan = LogicalPlan.join(
        cust^, orders^, lk^, rk^, JOIN_LEFT, JOIN_ALGO_AUTO,
        OwnedPointer(resid^),
    )
    plan = push_join_residual_to_side(plan^)

    print("REGEXP-PROBE left_residual: is_join =", plan.is_join(),
          " has_residual =", plan.join_data_ref().has_residual(),
          " right.tag =", Int(plan.join_data_ref().right[].tag),
          " (PLAN_FILTER =", Int(PLAN_FILTER), ")")

    assert_true(plan.is_join(), "the LEFT join must survive the rewrite")
    assert_false(
        plan.join_data_ref().has_residual(),
        "the right-only NOT-Regexp conjunct must LEAVE the residual — a LEFT"
        " join carrying it evaluates the regex per probed row instead of"
        " filtering `orders` once",
    )
    assert_equal(
        Int(plan.join_data_ref().right[].tag),
        Int(PLAN_FILTER),
        "the NOT-Regexp conjunct must land as a Filter on the `orders` (right)"
        " side of the LEFT join, instead of being evaluated per probed row as a"
        " join residual. This guards the RESIDUAL SPLIT, not the q13 ratio —"
        " see this test's docstring",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
