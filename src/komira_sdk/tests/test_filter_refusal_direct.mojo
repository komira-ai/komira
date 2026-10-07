# =============================================================================
# filter_refusal: the refusals a verb that cannot raise carries in its plan,
# and keeping the innermost one at the plan's root.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * `unknown_column_refusal` names the first missing column and every valid
#     one, and skips the empty name a COUNT(*) window carries;
#   * `filter_refusal` checks, in order, a refused `.over()`, an unknown
#     column, and an aggregate of a computed operand, the last only when the
#     filter is not directly above an aggregate (an order swapped, a check
#     dropped, the above-aggregate exemption inverted);
#   * `refused_plan` / `refused_filter_plan` / `refuse_duplicate_names` build
#     a PROJECT of one column named `<verb><why>`, and only on a duplicate;
#   * `_is_refusal` accepts exactly that shape;
#   * `keep_refusal_at_root` finds a refusal under every node kind with an
#     input, prefers the innermost one and the left side of a join, and
#     returns a plan with no refusal as it is (an arm that stops descending,
#     an outermost-first search, the right side searched first).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_MEAN
from komira_plan_expr.expr import (
    Expr,
    BIN_GT,
    BIN_MUL,
    OVER_REFUSED_PREFIX,
)
from komira_plan_expr.partition_expr import PartitionExpr, PF_COUNT, PF_SUM
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    AsofTolerance,
    ExprArray,
    LogicalPlan,
    ASOF_BACKWARD,
    JOIN_INNER,
    PLAN_AGGREGATE,
    PLAN_ASOF_JOIN,
    PLAN_CAST_TO_VARCHAR,
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
    SOURCE_PARQUET,
)

from komira_sdk.filter_refusal import (
    _has_name,
    _is_refusal,
    duplicate_name_refusal,
    filter_refusal,
    keep_refusal_at_root,
    refuse_duplicate_names,
    refused_filter_plan,
    refused_plan,
    unknown_column_refusal,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _two() -> Expr:
    return Expr.literal(ScalarValue.from_int(2))


def _gt(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_GT, l^, r^)


def _only_col_name(plan: LogicalPlan) -> String:
    return plan.project_data_ref().exprs[0].col_ref_name()


def _refusal(why: String) -> LogicalPlan:
    return refused_filter_plan(why, _scan())


def _one(n: String) -> List[String]:
    var l = List[String]()
    l.append(n)
    return l^


def _f() -> List[Bool]:
    var l = List[Bool]()
    l.append(False)
    return l^


# ---- the reasons ------------------------------------------------------------


def test_has_name() raises:
    assert_true(_has_name(_schema(), "b"))
    assert_false(_has_name(_schema(), "c"))


def test_unknown_column_refusal() raises:
    assert_equal(unknown_column_refusal(_gt(_c("a"), _c("b")), _schema()), "")
    assert_equal(
        unknown_column_refusal(_gt(_c("a"), _c("nope")), _schema()),
        "unable to find column \"nope\"; valid columns: [\"a\", \"b\"]"
        " (polars: ColumnNotFoundError)",
    )
    var count_star = Expr.window_fn(
        PF_COUNT, "", 0, PartitionFrame.default_unordered()
    ).over(List[String]())
    assert_equal(
        unknown_column_refusal(_gt(count_star^, _two()), _schema()), "",
        "an empty window argument is not a reference",
    )


def test_filter_refusal_order() raises:
    var refused_window = Expr.window_fn(
        PF_SUM, String(OVER_REFUSED_PREFIX) + "why", 0,
        PartitionFrame.default_unordered(),
    )
    # A refused `.over()` wins over the unknown column beside it.
    var both = Expr.binary(BIN_GT, refused_window^, _c("nope"))
    var why = filter_refusal(both, _schema(), False)
    assert_true(why.startswith(OVER_REFUSED_PREFIX), why)
    assert_true(
        filter_refusal(_gt(_c("nope"), _two()), _schema(), False).startswith(
            "unable to find column \"nope\""
        )
    )
    # An aggregate of a computed operand: refused unless above an aggregate.
    var computed = _gt(
        _c("a"),
        Expr.agg_fn(AGG_MEAN, Expr.binary(BIN_MUL, _c("a"), _two())),
    )
    var r = filter_refusal(computed, _schema(), False)
    assert_true(r.find("an aggregate of a COMPUTED expression") != -1, r)
    assert_equal(filter_refusal(computed, _schema(), True), "")
    # An aggregate of a plain column, and no aggregate at all, are served.
    var plain = _gt(_c("a"), Expr.agg_fn(AGG_MEAN, _c("b")))
    assert_equal(filter_refusal(plain, _schema(), False), "")
    assert_equal(filter_refusal(_gt(_c("a"), _two()), _schema(), False), "")


# ---- the carried refusal ----------------------------------------------------


def test_refused_plans() raises:
    var p = refused_plan("select(): ", "why", _scan())
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_equal(len(p.project_data_ref().exprs), 1)
    assert_equal(_only_col_name(p), "select(): why")
    assert_equal(_only_col_name(_refusal("x")), "filter(): x")


def test_duplicate_names() raises:
    assert_equal(duplicate_name_refusal(_schema()), "")
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var dup = sb.build()
    assert_equal(
        duplicate_name_refusal(dup),
        "projections contained duplicate output name 'v' (polars:"
        " DuplicateError); name one of them with `.alias(\"...\")`",
    )
    var kept = refuse_duplicate_names(_scan())
    assert_equal(Int(kept.tag), Int(PLAN_SCAN), "no duplicate: the plan as it is")
    var refused = refuse_duplicate_names(
        LogicalPlan.scan("d.parquet", SOURCE_PARQUET, dup^)
    )
    assert_true(_only_col_name(refused).startswith("select(): projections"))


def test_is_refusal() raises:
    assert_true(_is_refusal(_refusal("x")))
    assert_true(_is_refusal(refused_plan("select(): ", "y", _scan())))
    assert_false(_is_refusal(_scan()), "not a project")
    var two = ExprArray()
    two.append(_c("filter(): x"))
    two.append(_c("a"))
    assert_false(_is_refusal(LogicalPlan.project(two^, _scan())), "two columns")
    var computed = ExprArray()
    computed.append(Expr.alias(_c("a"), "filter(): x"))
    assert_false(_is_refusal(LogicalPlan.project(computed^, _scan())), "not a column")
    var other = ExprArray()
    other.append(_c("a"))
    assert_false(_is_refusal(LogicalPlan.project(other^, _scan())), "another name")
    var hollow = _scan()
    hollow.tag = PLAN_PROJECT
    assert_false(_is_refusal(hollow), "a project tag with no payload")


# ---- keep_refusal_at_root ---------------------------------------------------


def _kept_reason(var plan: LogicalPlan) -> String:
    var r = keep_refusal_at_root(plan^)
    if r.tag != PLAN_PROJECT:
        return String("(not a refusal)")
    return _only_col_name(r)


def _agg_over(var child: LogicalPlan) -> LogicalPlan:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(ExprArray(), aggs^, child^)


def test_no_refusal_returns_the_plan() raises:
    var p = keep_refusal_at_root(LogicalPlan.filter(_gt(_c("a"), _two()), _scan()))
    assert_equal(Int(p.tag), Int(PLAN_FILTER))
    assert_equal(Int(keep_refusal_at_root(_scan()).tag), Int(PLAN_SCAN))
    var ex = ExprArray()
    ex.append(_c("a"))
    assert_equal(
        Int(keep_refusal_at_root(LogicalPlan.project(ex^, _scan())).tag),
        Int(PLAN_PROJECT),
    )


def test_refusal_under_every_node_kind() raises:
    var w = String("filter(): w")
    assert_equal(_kept_reason(_refusal("w")), w, "at the root")
    var ex = ExprArray()
    ex.append(_c("a"))
    assert_equal(_kept_reason(LogicalPlan.project(ex^, _refusal("w"))), w, "project")
    assert_equal(
        _kept_reason(LogicalPlan.filter(_gt(_c("a"), _two()), _refusal("w"))), w, "filter"
    )
    assert_equal(_kept_reason(_agg_over(_refusal("w"))), w, "aggregate")
    assert_equal(_kept_reason(LogicalPlan.sort(_one("a"), _f(), _refusal("w"))), w, "sort")
    assert_equal(_kept_reason(LogicalPlan.limit(3, _refusal("w"))), w, "limit")
    assert_equal(_kept_reason(LogicalPlan.distinct(None, _refusal("w"))), w, "distinct")
    assert_equal(_kept_reason(LogicalPlan.topn(_one("a"), _f(), 2, _refusal("w"))), w, "topn")
    assert_equal(
        _kept_reason(
            LogicalPlan.partition_by(
                List[String](), List[String](), List[Bool](), List[PartitionExpr](),
                _refusal("w"),
            )
        ),
        w,
        "partition_by",
    )
    assert_equal(
        _kept_reason(LogicalPlan.partition_topn(_one("a"), _one("b"), _f(), 1, _refusal("w"))),
        w,
        "partition_topn",
    )
    assert_equal(_kept_reason(LogicalPlan.cast_to_varchar(_refusal("w"))), w, "cast")


def test_join_sides_and_union_branches() raises:
    assert_equal(
        _kept_reason(LogicalPlan.join(_refusal("L"), _refusal("R"), _one("a"), _one("a"), JOIN_INNER)),
        "filter(): L",
        "the left side first",
    )
    assert_equal(
        _kept_reason(LogicalPlan.join(_scan(), _refusal("R"), _one("a"), _one("a"), JOIN_INNER)),
        "filter(): R",
        "the right side when the left has none",
    )
    assert_equal(
        _kept_reason(
            LogicalPlan.asof_join(
                _refusal("L"), _refusal("R"), _one("a"), _one("a"), "b", "b",
                ASOF_BACKWARD, AsofTolerance.none(),
            )
        ),
        "filter(): L",
    )
    assert_equal(
        _kept_reason(
            LogicalPlan.asof_join(
                _scan(), _refusal("R"), _one("a"), _one("a"), "b", "b",
                ASOF_BACKWARD, AsofTolerance.none(),
            )
        ),
        "filter(): R",
    )
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan()))
    kids.append(OwnedPointer(_refusal("U")))
    kids.append(OwnedPointer(_refusal("V")))
    assert_equal(_kept_reason(LogicalPlan.union(kids^, _schema())), "filter(): U")
    var clean = List[OwnedPointer[LogicalPlan]]()
    clean.append(OwnedPointer(_scan()))
    assert_equal(
        Int(keep_refusal_at_root(LogicalPlan.union(clean^, _schema())).tag), Int(PLAN_UNION)
    )


def test_innermost_refusal_wins() raises:
    var inner = _refusal("first")
    var outer = refused_filter_plan("second", LogicalPlan.limit(1, inner^))
    assert_equal(_kept_reason(outer^), "filter(): first")


def test_node_tags_without_a_payload() raises:
    """A node tag whose payload is absent is not descended (each arm checks
    the payload, not only the tag)."""
    var tags: List[UInt8] = [
        PLAN_PROJECT, PLAN_FILTER, PLAN_AGGREGATE, PLAN_SORT, PLAN_LIMIT,
        PLAN_DISTINCT, PLAN_TOPN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN,
        PLAN_CAST_TO_VARCHAR, PLAN_JOIN, PLAN_ASOF_JOIN, PLAN_UNION,
    ]
    for i in range(len(tags)):
        var p = _scan()
        p.tag = tags[i]
        var r = keep_refusal_at_root(p^)
        assert_equal(Int(r.tag), Int(tags[i]), "tag " + String(Int(tags[i])))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
