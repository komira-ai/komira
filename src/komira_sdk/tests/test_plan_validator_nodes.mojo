# =============================================================================
# plan_validator, the plan-node half: the report, the RANGE root rule, and
# every node arm with each of its refusals.
# =============================================================================
#
# Each `*_refusals` test plants one defect per guard in an otherwise valid
# node and requires the named error, so a guard that is dropped, inverted or
# moved to the wrong node fails here. The RANGE tests put an offset LIMIT under
# every node kind `_subtree_has_offset_limit` descends, so an arm that stops
# descending passes a nested offset and fails `test_offset_under_every_node`.
# The expression walk is `test_plan_validator_exprs`.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM, AGG_CORR
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr, PF_ROW_NUMBER
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    AsofTolerance,
    ExprArray,
    LogicalPlan,
    ASOF_BACKWARD,
    JOIN_INNER,
    SOURCE_PARQUET,
)

from komira_sdk.plan_validator import (
    PlanValidationReport,
    assert_offset_limit_is_root,
    plan_contains_range_offset,
    validate_plan,
    validate_plan_report,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _col(n: String) -> Expr:
    return Expr.col_ref(n)


def _gt(n: String) -> Expr:
    return Expr.binary(BIN_GT, _col(n), Expr.literal(ScalarValue.from_int(0)))


def _keys(a: String) -> List[String]:
    var k = List[String]()
    k.append(a)
    return k^


def _desc(n: Int) -> List[Bool]:
    var d = List[Bool]()
    for _ in range(n):
        d.append(False)
    return d^


def _raises(plan: LogicalPlan, want: String) raises:
    var raised = False
    try:
        validate_plan(plan)
    except e:
        raised = True
        assert_true(String(e).find(want) != -1, "want '" + want + "', got: " + String(e))
    assert_true(raised, "validate_plan raises: " + want)


def _offset(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.limit(5, child^, offset=2)


# ---- the report -------------------------------------------------------------


def test_report() raises:
    var r = PlanValidationReport()
    assert_true(r.fully_validated())
    assert_equal(r.num_unvalidated(), 0)
    assert_equal(r.summary(), "")
    r.note_unvalidated("first")
    r.note_unvalidated("second")
    assert_false(r.fully_validated())
    assert_equal(r.num_unvalidated(), 2)
    assert_equal(r.note(1), "second")
    assert_equal(
        r.summary(),
        "NOT VALIDATED (2 expression site(s) the validator does not model):"
        " first; second",
    )
    var c = r.copy()
    r.note_unvalidated("third")
    assert_equal(c.num_unvalidated(), 2, "the copy is independent")
    assert_equal(c.note(0), "first")


# ---- the RANGE root rule ------------------------------------------------------


def test_offset_at_the_root_is_allowed() raises:
    var p = _offset(_scan())
    assert_offset_limit_is_root(p)
    assert_true(plan_contains_range_offset(p))
    validate_plan(p)
    # A plain LIMIT (offset 0) is unrestricted anywhere.
    var plain = LogicalPlan.filter(_gt("a"), LogicalPlan.limit(3, _scan()))
    assert_false(plan_contains_range_offset(plain))
    validate_plan(plain)


def test_offset_below_a_root_offset() raises:
    var p = _offset(LogicalPlan.limit(1, _offset(_scan())))
    _raises(p, "a second offset LIMIT was found below the root")


def _nested(var p: LogicalPlan, what: String) raises:
    assert_true(plan_contains_range_offset(p), what + ": found")
    var raised = False
    try:
        assert_offset_limit_is_root(p)
    except e:
        raised = True
        assert_true(String(e).find("nested below another operator") != -1, String(e))
    assert_true(raised, what + ": refused")


def test_offset_under_every_node() raises:
    _nested(LogicalPlan.filter(_gt("a"), _offset(_scan())), "filter")
    var ex = ExprArray()
    ex.append(_col("a"))
    _nested(LogicalPlan.project(ex^, _offset(_scan())), "project")
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    _nested(LogicalPlan.aggregate(ExprArray(), aggs^, _offset(_scan())), "aggregate")
    _nested(
        LogicalPlan.join(_offset(_scan()), _scan(), _keys("a"), _keys("a"), JOIN_INNER),
        "join left",
    )
    _nested(
        LogicalPlan.join(_scan(), _offset(_scan()), _keys("a"), _keys("a"), JOIN_INNER),
        "join right",
    )
    _nested(LogicalPlan.sort(_keys("a"), _desc(1), _offset(_scan())), "sort")
    _nested(LogicalPlan.distinct(None, _offset(_scan())), "distinct")
    _nested(LogicalPlan.topn(_keys("a"), _desc(1), 2, _offset(_scan())), "topn")
    _nested(
        LogicalPlan.partition_by(
            _keys("a"), List[String](), List[Bool](), List[PartitionExpr](),
            _offset(_scan()),
        ),
        "partition_by",
    )
    _nested(
        LogicalPlan.partition_topn(_keys("a"), _keys("b"), _desc(1), 1, _offset(_scan())),
        "partition_topn",
    )
    _nested(
        LogicalPlan.asof_join(
            _offset(_scan()), _scan(), _keys("a"), _keys("a"), "b", "b",
            ASOF_BACKWARD, AsofTolerance.none(),
        ),
        "asof left",
    )
    _nested(
        LogicalPlan.asof_join(
            _scan(), _offset(_scan()), _keys("a"), _keys("a"), "b", "b",
            ASOF_BACKWARD, AsofTolerance.none(),
        ),
        "asof right",
    )
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan()))
    kids.append(OwnedPointer(_offset(_scan())))
    _nested(LogicalPlan.union(kids^, _schema()), "union")
    _nested(LogicalPlan.cast_to_varchar(_offset(_scan())), "cast_to_varchar")
    # A union with no offset in any branch, and a cast over a plain scan.
    var clean = List[OwnedPointer[LogicalPlan]]()
    clean.append(OwnedPointer(_scan()))
    clean.append(OwnedPointer(_scan()))
    assert_false(plan_contains_range_offset(LogicalPlan.union(clean^, _schema())))
    assert_false(plan_contains_range_offset(LogicalPlan.cast_to_varchar(_scan())))


# ---- node arms ----------------------------------------------------------------


def test_unmodelled_node_tag_raises() raises:
    """The node walk has no UNION / ASOF / CAST arm: it raises naming the tag."""
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan()))
    _raises(LogicalPlan.union(kids^, _schema()), "unknown plan tag 12")


def test_scan_filter() raises:
    validate_plan(_scan())
    var ok = LogicalPlan.scan(
        "t.parquet", SOURCE_PARQUET, _schema(), filter=Optional[Expr](_gt("a"))
    )
    validate_plan(ok)
    var bad = LogicalPlan.scan(
        "t.parquet", SOURCE_PARQUET, _schema(), filter=Optional[Expr](_gt("nope"))
    )
    _raises(bad, "Scan filter: column 'nope' not found. Available: [a, b, s]")


def test_filter_and_project() raises:
    validate_plan(LogicalPlan.filter(_gt("b"), _scan()))
    _raises(LogicalPlan.filter(_gt("nope"), _scan()), "Filter predicate: column 'nope'")
    # The child is validated first: a bad filter under a good one.
    _raises(
        LogicalPlan.filter(_gt("a"), LogicalPlan.filter(_gt("zz"), _scan())),
        "column 'zz'",
    )
    var ex = ExprArray()
    ex.append(_col("a"))
    ex.append(_col("nope"))
    _raises(LogicalPlan.project(ex^, _scan()), "Project expression 1: column 'nope'")


def _agg_plan(var ae: AggExpr) -> LogicalPlan:
    var aggs = AggExprArray()
    aggs.append(ae^)
    var gb = ExprArray()
    gb.append(_col("s"))
    return LogicalPlan.aggregate(gb^, aggs^, _scan())


def test_aggregate_every_slot() raises:
    validate_plan(_agg_plan(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n"))))
    var gb = ExprArray()
    gb.append(_col("nope"))
    _raises(
        LogicalPlan.aggregate(gb^, AggExprArray(), _scan()),
        "Aggregate group_by 0: column 'nope'",
    )
    _raises(
        _agg_plan(AggExpr(AGG_SUM, Optional[Expr](_col("nope")), Optional[String]("x"))),
        "Aggregate agg_expr 0: column 'nope'",
    )
    var two = AggExpr(
        AGG_CORR, Optional[Expr](_col("a")), Optional[Expr](_col("nope")),
        Optional[String]("c"),
    )
    _raises(_agg_plan(two^), "Aggregate agg_expr 0 arg 1: column 'nope'")
    var three = AggExpr(AGG_SUM, Optional[Expr](_col("a")), Optional[String]("x"))
    three.child2 = Optional[Expr](_col("nope"))
    _raises(_agg_plan(three^), "Aggregate agg_expr 0 arg 2: column 'nope'")
    var four = AggExpr(AGG_SUM, Optional[Expr](_col("a")), Optional[String]("x"))
    four.child3 = Optional[Expr](_col("nope"))
    _raises(_agg_plan(four^), "Aggregate agg_expr 0 arg 3: column 'nope'")
    var all_ok = AggExpr(
        AGG_CORR, Optional[Expr](_col("a")), Optional[Expr](_col("b")),
        Optional[String]("c"),
    )
    all_ok.child2 = Optional[Expr](_col("a"))
    all_ok.child3 = Optional[Expr](_col("b"))
    validate_plan(_agg_plan(all_ok^))


def _join_plan(lk: List[String], rk: List[String]) -> LogicalPlan:
    return LogicalPlan.join(_scan(), _scan(), lk.copy(), rk.copy(), JOIN_INNER)


def test_join_refusals_and_residual() raises:
    var r = validate_plan_report(_join_plan(_keys("b"), _keys("b")))
    assert_true(r.fully_validated(), "a plain join is fully checked")
    var two: List[String] = ["a", "b"]
    _raises(_join_plan(_keys("a"), two), "left_on has 1 keys but right_on has 2")
    _raises(_join_plan(_keys("nope"), _keys("a")), "left key 'nope' not found in left schema")
    _raises(_join_plan(_keys("a"), _keys("nope")), "right key 'nope' not found in right schema")
    var res = LogicalPlan.join(
        _scan(), _scan(), _keys("a"), _keys("a"), JOIN_INNER,
        residual=Optional[OwnedPointer[Expr]](OwnedPointer(_gt("b"))),
    )
    var rr = validate_plan_report(res)
    assert_equal(rr.num_unvalidated(), 1, "the residual is noted, not checked")
    assert_true(rr.note(0).startswith("Join residual"), rr.note(0))


def test_sort_refusals() raises:
    validate_plan(LogicalPlan.sort(_keys("s"), _desc(1), _scan()))
    _raises(LogicalPlan.sort(_keys("nope"), _desc(1), _scan()), "sort key 'nope' not found")
    var p = LogicalPlan.sort(_keys("a"), _desc(1), _scan())
    p._sort.value()[].descending.append(True)
    _raises(p, "Sort validation: keys has 1 entries but descending has 2")


def test_limit_refusals() raises:
    _raises(LogicalPlan.limit(-1, _scan()), "n must be >= 0, got -1")
    _raises(LogicalPlan.limit(1, _scan(), offset=-3), "offset must be >= 0, got -3")


def test_distinct() raises:
    validate_plan(LogicalPlan.distinct(None, _scan()))
    validate_plan(LogicalPlan.distinct(Optional[List[String]](_keys("b")), _scan()))
    _raises(
        LogicalPlan.distinct(Optional[List[String]](_keys("nope")), _scan()),
        "Distinct validation: column 'nope'",
    )


def test_topn_refusals() raises:
    validate_plan(LogicalPlan.topn(_keys("b"), _desc(1), 3, _scan()))
    _raises(LogicalPlan.topn(_keys("a"), _desc(1), -2, _scan()), "TopN validation: n must be >= 0")
    _raises(LogicalPlan.topn(_keys("nope"), _desc(1), 2, _scan()), "TopN validation: sort key 'nope'")
    var p = LogicalPlan.topn(_keys("a"), _desc(1), 2, _scan())
    p._topn.value()[].descending.append(True)
    _raises(p, "TopN validation: keys has 1 entries but descending has 2")


def _pexpr(column: String) -> PartitionExpr:
    return PartitionExpr(
        PF_ROW_NUMBER, column, 0, ScalarValue(), False,
        PartitionFrame.default_unordered(), "rn",
    )


def _pby(var pk: List[String], var ok: List[String], n_desc: Int, column: String) raises -> LogicalPlan:
    var exprs = List[PartitionExpr]()
    exprs.append(_pexpr(column))
    return LogicalPlan.partition_by(pk^, ok^, _desc(n_desc), exprs^, _scan())


def test_partition_by_refusals() raises:
    validate_plan(_pby(_keys("s"), _keys("a"), 1, ""))
    validate_plan(_pby(_keys("s"), _keys("a"), 1, "b"))
    _raises(_pby(_keys("nope"), _keys("a"), 1, ""), "partition key 'nope' not found")
    _raises(_pby(_keys("s"), _keys("nope"), 1, ""), "order key 'nope' not found")
    _raises(_pby(_keys("s"), _keys("a"), 1, "nope"), "expression column 'nope' not found")
    var p = _pby(_keys("s"), _keys("a"), 1, "")
    p._partition_by.value()[].descending.append(True)
    _raises(p, "order_keys and descending have mismatched lengths")


def test_partition_topn_refusals() raises:
    validate_plan(LogicalPlan.partition_topn(_keys("s"), _keys("a"), _desc(1), 2, _scan()))
    _raises(
        LogicalPlan.partition_topn(_keys("s"), _keys("a"), _desc(1), -1, _scan()),
        "PartitionTopN validation: k must be >= 0, got -1",
    )
    _raises(
        LogicalPlan.partition_topn(_keys("s"), _keys("a"), _desc(2), 1, _scan()),
        "sort_keys has 1 entries but descending has 2",
    )
    _raises(
        LogicalPlan.partition_topn(_keys("nope"), _keys("a"), _desc(1), 1, _scan()),
        "PartitionTopN validation: partition key 'nope'",
    )
    _raises(
        LogicalPlan.partition_topn(_keys("s"), _keys("nope"), _desc(1), 1, _scan()),
        "PartitionTopN validation: sort key 'nope'",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
