# =============================================================================
# Rule 11, `convert_inner_to_semi`: every arm of the rewrite, the DISTINCT
# licence and the structural key-uniqueness prover.
# =============================================================================
#
# The rule turns `Project(INNER(L, R))` into `Project(SEMI(L, R))` when the
# projection reads no right column AND either the right side is provably unique
# on the join keys or a `DISTINCT` directly above the projection hides row
# multiplicity. Converting without one of those two proofs drops the join's
# fan-out: a silent wrong answer. Each test names the defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_ADD
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_SCAN,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
    JOIN_ANTI,
)
from komira_optimizer.optimizer_join import (
    convert_inner_to_semi,
    _distinct_absorbs_child_multiplicity,
    _right_side_is_key_unique_on,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return sb.build()


def _scan(path: String, names: List[String]) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names))


def _left() -> LogicalPlan:
    var n: List[String] = ["lk", "lv"]
    return _scan("l.parquet", n)


def _right_scan() -> LogicalPlan:
    var n: List[String] = ["rk", "rv"]
    return _scan("r.parquet", n)


def _grouped_on_rk() -> LogicalPlan:
    """Aggregate(rk; sum(rv)) over the right scan: unique on `rk`."""
    var keys = ExprArray()
    keys.append(Expr.col_ref("rk"))
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("rv")), Optional[String](String("s")))
    )
    return LogicalPlan.aggregate(keys^, aggs^, _right_scan())


def _inner(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    var lk: List[String] = ["lk"]
    var rk: List[String] = ["rk"]
    return LogicalPlan.join(l^, r^, lk^, rk^, JOIN_INNER)


def _project_cols(names: List[String], var child: LogicalPlan) -> LogicalPlan:
    var e = ExprArray()
    for i in range(len(names)):
        e.append(Expr.col_ref(names[i]))
    return LogicalPlan.project(e^, child^)


def _left_only_project(var child: LogicalPlan) -> LogicalPlan:
    var n: List[String] = ["lk", "lv"]
    return _project_cols(n, child^)


def _convertible() -> LogicalPlan:
    """Project([lk, lv], INNER(L, Aggregate grouped on rk)): the rule fires."""
    return _left_only_project(_inner(_left(), _grouped_on_rk()))


def _udf() -> UdfData:
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("lk", UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("lk", UInt8(2)))
    return UdfData(
        kind=UDF_KIND_MAP,
        name=String("f"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(1),
        call_site_salt=UInt32(1),
        registered_handle_id=Optional(Int(1)),
    )


def _join_type_under_project(p: LogicalPlan) -> UInt8:
    return p._project.value()[].child[]._join.value()[].join_type


# -----------------------------------------------------------------------------
# The PROJECT arm
# -----------------------------------------------------------------------------


def test_left_only_project_over_unique_right_becomes_semi() raises:
    """The firing case: the join turns SEMI and its cached schema narrows to the
    left columns. Catches a rule that stops converting, and one that flips the
    join type but leaves the stale `left ++ right` schema on the node."""
    var out = convert_inner_to_semi(_convertible())
    assert_equal(Int(_join_type_under_project(out)), Int(JOIN_SEMI))
    ref js = out._project.value()[].child[].output_schema
    assert_equal(js.num_columns(), 2)
    assert_equal(js.field_name(0), "lk")
    assert_equal(js.field_name(1), "lv")


def test_project_reading_a_right_column_stays_inner() raises:
    """`rv` is a right column, so a SEMI (left columns only) cannot serve the
    projection. Catches the `uses_right` scan being skipped or inverted."""
    var n: List[String] = ["lk", "s"]
    var out = convert_inner_to_semi(
        _project_cols(n, _inner(_left(), _grouped_on_rk()))
    )
    assert_equal(Int(_join_type_under_project(out)), Int(JOIN_INNER))


def test_left_only_project_over_non_unique_right_stays_inner() raises:
    """A bare scan on the right is not provably unique on `rk`: converting
    would drop the fan-out of a key with several right rows. Catches the
    key-uniqueness precondition being removed (the wrong-answer defect)."""
    var out = convert_inner_to_semi(_left_only_project(_inner(_left(), _right_scan())))
    assert_equal(Int(_join_type_under_project(out)), Int(JOIN_INNER))


def test_project_over_a_non_inner_join_or_a_scan_is_untouched() raises:
    """Only INNER converts. Catches the join-type test widened to LEFT (which
    null-extends) and a project over a scan being mistaken for a join."""
    var lk: List[String] = ["lk"]
    var rk: List[String] = ["rk"]
    var left_join = LogicalPlan.join(_left(), _grouped_on_rk(), lk^, rk^, JOIN_LEFT)
    var out = convert_inner_to_semi(_left_only_project(left_join^))
    assert_equal(Int(_join_type_under_project(out)), Int(JOIN_LEFT))
    var out2 = convert_inner_to_semi(_left_only_project(_left()))
    assert_equal(Int(out2._project.value()[].child[].tag), Int(PLAN_SCAN))


def test_distinct_over_project_licenses_a_non_unique_right_side() raises:
    """`DISTINCT(Project(INNER(L, scan R)))`: the DISTINCT hides multiplicity,
    so the rewrite needs no uniqueness proof. Catches the licence not being
    passed down the DISTINCT edge (q20's shape would stop converting)."""
    var p = _left_only_project(_inner(_left(), _right_scan()))
    var out = convert_inner_to_semi(LogicalPlan.distinct(None, p^))
    ref proj = out._distinct.value()[].child[]
    assert_equal(Int(_join_type_under_project(proj)), Int(JOIN_SEMI))


def test_distinct_licence_stops_at_the_projection_it_was_granted_for() raises:
    """`DISTINCT(Project(Filter(Project(INNER(L, scan R)))))`: the licence is
    for the outer projection only; the inner one must still prove uniqueness.
    Catches the project arm forwarding `dup_insensitive` to its child."""
    var inner_p = _left_only_project(_inner(_left(), _right_scan()))
    var f = LogicalPlan.filter(Expr.col_ref("lk"), inner_p^)
    var outer = _left_only_project(f^)
    var out = convert_inner_to_semi(LogicalPlan.distinct(None, outer^))
    ref inner_after = out._distinct.value()[].child[]._project.value()[].child[]._filter.value()[].child[]
    assert_equal(Int(_join_type_under_project(inner_after)), Int(JOIN_INNER))


# -----------------------------------------------------------------------------
# The recursion arms: every wrapper reaches the convertible project below it
# -----------------------------------------------------------------------------


def test_filter_aggregate_sort_limit_topn_arms_recurse() raises:
    """A convertible project under each single-child wrapper is converted.
    Catches a recursion arm dropped from the walk."""
    var f = convert_inner_to_semi(LogicalPlan.filter(Expr.col_ref("lk"), _convertible()))
    assert_equal(Int(_join_type_under_project(f._filter.value()[].child[])), Int(JOIN_SEMI))

    var keys = ExprArray()
    keys.append(Expr.col_ref("lk"))
    var a = convert_inner_to_semi(
        LogicalPlan.aggregate(keys^, AggExprArray(), _convertible())
    )
    assert_equal(Int(_join_type_under_project(a._aggregate.value()[].child[])), Int(JOIN_SEMI))

    var sk: List[String] = ["lk"]
    var sd: List[Bool] = [False]
    var s = convert_inner_to_semi(LogicalPlan.sort(sk^, sd^, _convertible()))
    assert_equal(Int(_join_type_under_project(s._sort.value()[].child[])), Int(JOIN_SEMI))

    var l = convert_inner_to_semi(LogicalPlan.limit(5, _convertible()))
    assert_equal(Int(_join_type_under_project(l._limit.value()[].child[])), Int(JOIN_SEMI))

    var tk: List[String] = ["lk"]
    var td: List[Bool] = [True]
    var t = convert_inner_to_semi(LogicalPlan.topn(tk^, td^, 3, _convertible()))
    assert_equal(Int(_join_type_under_project(t._topn.value()[].child[])), Int(JOIN_SEMI))


def test_join_arm_recurses_into_both_sides() raises:
    """A convertible project on each side of an enclosing INNER join is
    converted. Catches the join arm recursing into one side only."""
    var lk: List[String] = ["lk"]
    var rk: List[String] = ["lk"]
    var j = LogicalPlan.join(_convertible(), _convertible(), lk^, rk^, JOIN_INNER)
    var out = convert_inner_to_semi(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(_join_type_under_project(out._join.value()[].left[])), Int(JOIN_SEMI))
    assert_equal(Int(_join_type_under_project(out._join.value()[].right[])), Int(JOIN_SEMI))


def test_a_scan_root_is_returned_unchanged() raises:
    """A leaf falls through every arm. Catches a walk that raises on a node
    it does not handle, or changes its tag or arity."""
    var out = convert_inner_to_semi(_left())
    assert_equal(Int(out.tag), Int(PLAN_SCAN))
    assert_equal(out.output_schema.num_columns(), 2)


# -----------------------------------------------------------------------------
# `_distinct_absorbs_child_multiplicity`: every clause declines on its own
# -----------------------------------------------------------------------------


def test_licence_requires_a_distinct_node() raises:
    """Catches the tag check dropped: a project is not a licence."""
    assert_false(_distinct_absorbs_child_multiplicity(_convertible()))


def test_licence_requires_the_projection_directly_below() raises:
    """DISTINCT over a FILTER: an operator in between reads multiplicity.
    Catches the adjacency check dropped."""
    var f = LogicalPlan.filter(Expr.col_ref("lk"), _convertible())
    var d = LogicalPlan.distinct(None, f^)
    assert_false(_distinct_absorbs_child_multiplicity(d))


def test_licence_refuses_a_udf_projection() raises:
    """A typed-UDF projection may be impure, so its row count is observable.
    Catches the UDF refusal dropped."""
    var e = ExprArray()
    e.append(Expr.col_ref("lk"))
    var p = LogicalPlan.project_with_udf(
        e^, _inner(_left(), _right_scan()), OwnedPointer[UdfData](_udf())
    )
    var d = LogicalPlan.distinct(None, p^)
    assert_false(_distinct_absorbs_child_multiplicity(d))


def test_licence_refuses_a_zero_column_projection() raises:
    """A projection with no output column is declined. Catches the `n_out == 0`
    check dropped (a vacuous cover would grant the licence)."""
    var p = LogicalPlan.project(ExprArray(), _left())
    var d = LogicalPlan.distinct(None, p^)
    assert_false(_distinct_absorbs_child_multiplicity(d))


def test_licence_for_select_distinct_over_the_whole_row() raises:
    """`columns == None` dedups the whole row: the licence holds."""
    var d = LogicalPlan.distinct(None, _convertible())
    assert_true(_distinct_absorbs_child_multiplicity(d))


def test_licence_with_explicit_columns_needs_every_output_column() raises:
    """An explicit list naming every output column grants it; a subset (a
    DISTINCT ON) and an empty list do not. Catches the cover direction being
    reversed and the empty-list check dropped."""
    var all_cols: List[String] = ["lv", "lk"]
    var d_all = LogicalPlan.distinct(Optional(all_cols^), _convertible())
    assert_true(_distinct_absorbs_child_multiplicity(d_all))

    var subset: List[String] = ["lk"]
    var d_sub = LogicalPlan.distinct(Optional(subset^), _convertible())
    assert_false(_distinct_absorbs_child_multiplicity(d_sub))

    var empty = List[String]()
    var d_empty = LogicalPlan.distinct(Optional(empty^), _convertible())
    assert_false(_distinct_absorbs_child_multiplicity(d_empty))


# -----------------------------------------------------------------------------
# `_right_side_is_key_unique_on`: what it can prove, and every decline
# -----------------------------------------------------------------------------


def test_prover_declines_with_no_keys() raises:
    """A keyless join is a cross product. Catches the empty-key guard dropped
    (an ungrouped aggregate would otherwise answer True)."""
    var keys = ExprArray()
    var one_row = LogicalPlan.aggregate(keys^, AggExprArray(), _right_scan())
    assert_false(_right_side_is_key_unique_on(one_row, List[String]()))


def test_prover_aggregate_arms() raises:
    """Ungrouped: one row, unique on anything. Grouped on rk: unique on [rk]
    and on a superset, not on a key set missing the group key. Catches each
    aggregate branch inverted."""
    var k: List[String] = ["rv"]
    var none_keys = ExprArray()
    var ungrouped = LogicalPlan.aggregate(none_keys^, AggExprArray(), _right_scan())
    assert_true(_right_side_is_key_unique_on(ungrouped, k))

    var rk: List[String] = ["rk"]
    assert_true(_right_side_is_key_unique_on(_grouped_on_rk(), rk))
    var sup: List[String] = ["s", "rk"]
    assert_true(_right_side_is_key_unique_on(_grouped_on_rk(), sup))
    var other: List[String] = ["s"]
    assert_false(_right_side_is_key_unique_on(_grouped_on_rk(), other))


def test_prover_aggregate_with_fewer_columns_than_group_keys() raises:
    """A stale output schema narrower than the group-key list is declined, not
    read past its end. Catches the `n_group > num_columns` guard dropped."""
    var g = _grouped_on_rk()
    g.output_schema = _schema(List[String]())
    var rk: List[String] = ["rk"]
    assert_false(_right_side_is_key_unique_on(g, rk))


def test_prover_distinct_with_columns() raises:
    """DISTINCT ON [rk] is unique on [rk]; a key set missing `rk` is not; an
    empty column list is declined. Catches each branch of the explicit-column
    arm."""
    var c1: List[String] = ["rk"]
    var d = LogicalPlan.distinct(Optional(c1^), _right_scan())
    var rk: List[String] = ["rk"]
    assert_true(_right_side_is_key_unique_on(d, rk))
    var rv: List[String] = ["rv"]
    assert_false(_right_side_is_key_unique_on(d, rv))
    var empty = List[String]()
    var d0 = LogicalPlan.distinct(Optional(empty^), _right_scan())
    assert_false(_right_side_is_key_unique_on(d0, rk))


def test_prover_distinct_star() raises:
    """DISTINCT * is unique only on a key set covering the whole row, and a
    zero-column DISTINCT is declined. Catches the whole-row arm inverted."""
    var d = LogicalPlan.distinct(None, _right_scan())
    var both: List[String] = ["rk", "rv"]
    assert_true(_right_side_is_key_unique_on(d, both))
    var rk: List[String] = ["rk"]
    assert_false(_right_side_is_key_unique_on(d, rk))
    var d0 = LogicalPlan.distinct(None, LogicalPlan.project(ExprArray(), _right_scan()))
    assert_false(_right_side_is_key_unique_on(d0, rk))


def test_prover_passes_through_filter_sort_limit_topn() raises:
    """Each order/subset operator inherits its child's uniqueness. Catches an
    arm that answers False (or True) without recursing."""
    var rk: List[String] = ["rk"]
    var f = LogicalPlan.filter(Expr.col_ref("rk"), _grouped_on_rk())
    assert_true(_right_side_is_key_unique_on(f, rk))
    var sk: List[String] = ["rk"]
    var sd: List[Bool] = [False]
    var s = LogicalPlan.sort(sk^, sd^, _grouped_on_rk())
    assert_true(_right_side_is_key_unique_on(s, rk))
    var l = LogicalPlan.limit(3, _grouped_on_rk())
    assert_true(_right_side_is_key_unique_on(l, rk))
    var tk: List[String] = ["rk"]
    var td: List[Bool] = [False]
    var t = LogicalPlan.topn(tk^, td^, 2, _grouped_on_rk())
    assert_true(_right_side_is_key_unique_on(t, rk))
    var f2 = LogicalPlan.filter(Expr.col_ref("rk"), _right_scan())
    assert_false(_right_side_is_key_unique_on(f2, rk))


def test_prover_project_transparent_only_for_same_name_col_refs() raises:
    """A rename-free col-ref projection is transparent; a computed column, a
    UDF projection, an empty projection, an arity mismatch and a col-ref under
    another output name all decline. Catches each project guard dropped."""
    var rk: List[String] = ["rk"]
    var n: List[String] = ["rk"]
    assert_true(_right_side_is_key_unique_on(_project_cols(n, _grouped_on_rk()), rk))

    var ce = ExprArray()
    ce.append(Expr.binary(BIN_ADD, Expr.col_ref("rk"), Expr.col_ref("s")))
    var computed = LogicalPlan.project(ce^, _grouped_on_rk())
    assert_false(_right_side_is_key_unique_on(computed, rk))

    var ue = ExprArray()
    ue.append(Expr.col_ref("rk"))
    var with_udf = LogicalPlan.project_with_udf(
        ue^, _grouped_on_rk(), OwnedPointer[UdfData](_udf())
    )
    assert_false(_right_side_is_key_unique_on(with_udf, rk))

    var empty = LogicalPlan.project(ExprArray(), _grouped_on_rk())
    assert_false(_right_side_is_key_unique_on(empty, rk))

    var arity = _project_cols(n, _grouped_on_rk())
    var two: List[String] = ["rk", "s"]
    arity.output_schema = _schema(two)
    assert_false(_right_side_is_key_unique_on(arity, rk))

    var renamed = _project_cols(n, _grouped_on_rk())
    var other: List[String] = ["rk2"]
    renamed.output_schema = _schema(other)
    assert_false(_right_side_is_key_unique_on(renamed, rk))


def test_prover_join_arms() raises:
    """SEMI and ANTI emit a subset of their left rows: uniqueness is the left
    side's. INNER multiplies rows: declined. A bare scan: declined. Catches the
    SEMI/ANTI arm reading the wrong side and INNER being admitted."""
    var rk: List[String] = ["rk"]
    var lk: List[String] = ["rk"]
    var ok: List[String] = ["lk"]
    var semi = LogicalPlan.join(_grouped_on_rk(), _left(), lk.copy(), ok.copy(), JOIN_SEMI)
    assert_true(_right_side_is_key_unique_on(semi, rk))
    var anti = LogicalPlan.join(_grouped_on_rk(), _left(), lk.copy(), ok.copy(), JOIN_ANTI)
    assert_true(_right_side_is_key_unique_on(anti, rk))
    var semi_scan = LogicalPlan.join(_right_scan(), _left(), lk.copy(), ok.copy(), JOIN_SEMI)
    assert_false(_right_side_is_key_unique_on(semi_scan, rk))
    var inner = LogicalPlan.join(_grouped_on_rk(), _left(), lk.copy(), ok.copy(), JOIN_INNER)
    assert_false(_right_side_is_key_unique_on(inner, rk))
    assert_false(_right_side_is_key_unique_on(_right_scan(), rk))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
