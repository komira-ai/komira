# =============================================================================
# Every plan node kind through the three generic node walks: `LogicalPlan.copy`
# (the `*Data.copy()` arms), `_copy_plan` (the rebuild through the factories)
# and `validate_plan_integrity`; and every aggregate function's base name.
# =============================================================================
#
# The decision tests (test_plan_decisions, test_plan_exchange) reach these
# walks for a join, an aggregate, a scan and an exchange only. A walk is total
# over plan tags, so each arm is checked here once:
#
#   * a well-formed node of every kind, with its optional fields set, copies
#     to a node with the same render and hash both ways, keeps the fields the
#     render does not show (asserted directly), and passes integrity;
#   * a node of every kind whose payload is missing is refused by integrity
#     and by `_copy_plan` (which says the payload is MISSING), and so are a
#     consumed plan (sentinel tag 255) and a retired tag;
#   * a Project whose expression reads a sibling output, a Project with fewer
#     expressions than output columns, and a Union with no branch are refused.
#
# Mutants each test catches are named in its docstring.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_GT, BIN_LT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats, ColumnStats

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AggGroupTopK,
    AsofTolerance,
    ASOF_BACKWARD,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    EXCHANGE_KIND_HASH,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    PLAN_EXCHANGE,
    agg_func_base_name,
)
from komira_plan_ir.plan_helpers import _copy_plan, validate_plan_integrity


# =============================================================================
# Fixtures
# =============================================================================


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.INT64, True))
    return sb.build()


def _gt(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(c), Expr.literal(ScalarValue.from_int(v)))


def _scan(path: String = "t.parquet", a: String = "a", b: String = "b") -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _full_scan() -> LogicalPlan:
    """A scan with a projection, a pushed filter, a row count and table
    stats: every optional field `ScanData.copy` has an arm for, but
    payload narrowing."""
    var proj: List[String] = ["a", "b"]
    return LogicalPlan.scan(
        "full.parquet", SOURCE_PARQUET, _schema("a", "b"), Optional(proj^),
        Optional(_gt("a", 1)), Optional(42),
        Optional(TableStats(42, List[String](), List[ColumnStats]())),
    )


def _l(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


def _f() -> List[Bool]:
    var o = List[Bool]()
    o.append(False)
    return o^


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


comptime N_KINDS: Int = 16


def _kind(i: Int) raises -> LogicalPlan:
    """A well-formed node of each kind, its optional fields set."""
    if i == 0:
        return _full_scan()
    if i == 1:
        return LogicalPlan.filter(_gt("a", 2), _scan())
    if i == 2:
        var e = ExprArray()
        e.append(Expr.alias(Expr.col_ref("a"), "x"))
        e.append(Expr.col_ref("b"))
        return LogicalPlan.project(e^, _scan())
    if i == 3:
        var gb = ExprArray()
        gb.append(Expr.col_ref("a"))
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("s"))))
        var p = LogicalPlan.aggregate(gb^, aggs^, _scan())
        p._aggregate.value()[].estimated_groups = Optional(7)
        p._aggregate.value()[].group_topk = Optional(AggGroupTopK(_l("s"), _f(), 3))
        return p^
    if i == 4:
        var res = Optional[OwnedPointer[Expr]](OwnedPointer(
            Expr.binary(BIN_LT, Expr.col_ref("b"), Expr.col_ref("d"))
        ))
        return LogicalPlan.join(
            _scan(), _scan("u.parquet", "c", "d"), _l("a"), _l("c"), JOIN_INNER,
            JOIN_ALGO_AUTO, res^,
        )
    if i == 5:
        return LogicalPlan.sort(_l("a"), _f(), _scan())
    if i == 6:
        return LogicalPlan.limit(5, _scan(), offset=2)
    if i == 7:
        var d = LogicalPlan.distinct(Optional(_l("a")), _scan())
        d._distinct.value()[].estimated_groups = Optional(9)
        return d^
    if i == 8:
        return LogicalPlan.topn(_l("a"), _f(), 4, _scan())
    if i == 9:
        var pe = List[PartitionExpr]()
        pe.append(PartitionExpr.row_number())
        return LogicalPlan.partition_by(_l("a"), _l("b"), _f(), pe^, _scan())
    if i == 10:
        return LogicalPlan.partition_topn(
            _l("a"), _l("b"), _f(), 2, _scan(), output_rank_col_name=Optional(String("rk"))
        )
    if i == 11:
        return LogicalPlan.asof_join(
            _scan(), _scan("u.parquet", "c", "d"), _l("a"), _l("c"), String("b"),
            String("d"), ASOF_BACKWARD, AsofTolerance.none(),
        )
    if i == 12:
        var kids = List[OwnedPointer[LogicalPlan]]()
        kids.append(OwnedPointer(_scan()))
        kids.append(OwnedPointer(_scan("t2.parquet")))
        return LogicalPlan.union(kids^, _schema("a", "b"))
    if i == 13:
        return LogicalPlan.view_ref(String("v"), _schema("a", "b"))
    if i == 14:
        return LogicalPlan.cse_ref(UInt64(12345), _schema("a", "b"))
    return LogicalPlan.cast_to_varchar(_scan())


def _tags() -> List[UInt8]:
    var t: List[UInt8] = [
        PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_JOIN,
        PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN, PLAN_PARTITION_BY,
        PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN, PLAN_UNION, PLAN_VIEW_REF,
        PLAN_CSE_REF, PLAN_CAST_TO_VARCHAR, PLAN_EXCHANGE,
    ]
    return t^


# =============================================================================
# Well-formed nodes
# =============================================================================


def test_every_kind_copies_both_ways_and_passes_integrity() raises:
    """Each of the 16 kinds (an exchange is test_plan_exchange's) keeps its
    tag, render and hash through `copy()` and `_copy_plan`, and is accepted
    by `validate_plan_integrity`. Catches a `copy()` arm that leaves the
    payload out (the copy renders as a shell), a `_copy_plan` arm missing
    (it raises), and an integrity arm that refuses a well-formed node."""
    var tags = _tags()
    for i in range(N_KINDS):
        var p = _kind(i)
        assert_equal(Int(p.tag), Int(tags[i]), "kind " + String(i))
        assert_true(validate_plan_integrity(p), "kind " + String(i) + "\n" + _render(p))
        var c = p.copy()
        assert_equal(_render(c), _render(p), "copy() kind " + String(i))
        assert_equal(c.structural_hash(), p.structural_hash(), "copy() kind " + String(i))
        var r = _copy_plan(p)
        assert_equal(_render(r), _render(p), "_copy_plan kind " + String(i))
        assert_equal(r.structural_hash(), p.structural_hash(), "_copy_plan kind " + String(i))


def test_copy_keeps_the_fields_the_render_does_not_show() raises:
    """`copy()` keeps a scan's table stats, an aggregate's `estimated_groups`
    and `group_topk`, a distinct's `estimated_groups` and a partition top-N's
    rank column name. Catches the matching `*Data.copy()` dropping one (no
    render or hash would change)."""
    # Each Optional is checked for presence before it is read, so a dropped
    # field fails this test by name instead of aborting the binary.
    var s = _kind(0).copy()
    assert_true(Bool(s._scan.value()[].table_stats), "scan table_stats dropped")
    assert_equal(s._scan.value()[].table_stats.value().row_count, 42)
    assert_true(Bool(s._scan.value()[].row_count), "scan row_count dropped")
    assert_equal(s._scan.value()[].row_count.value(), 42)
    var a = _kind(3).copy()
    assert_true(Bool(a._aggregate.value()[].estimated_groups), "aggregate estimated_groups dropped")
    assert_equal(a._aggregate.value()[].estimated_groups.value(), 7)
    assert_true(Bool(a._aggregate.value()[].group_topk), "aggregate group_topk dropped")
    assert_equal(a._aggregate.value()[].group_topk.value().k, 3)
    var d = _kind(7).copy()
    assert_true(Bool(d._distinct.value()[].estimated_groups), "distinct estimated_groups dropped")
    assert_equal(d._distinct.value()[].estimated_groups.value(), 9)
    assert_true(Bool(d._distinct.value()[].columns), "distinct columns dropped")
    assert_equal(d._distinct.value()[].columns.value()[0], "a")
    var t = _kind(10).copy()
    assert_true(Bool(t._partition_topn.value()[].output_rank_col_name), "rank column dropped")
    assert_equal(t._partition_topn.value()[].output_rank_col_name.value(), "rk")
    var l = _kind(6).copy()
    assert_equal(l._limit.value()[].offset, 2)


def test_a_scan_fingerprint_sees_projection_filter_and_row_count() raises:
    """Two scans of one source differing only in projection, pushed filter or
    row count have different fingerprints, and the full scan's fingerprint
    survives `copy()`. Catches a fingerprint that leaves one narrowing out (two
    narrowings of one file would share a cache entry)."""
    var base = _scan("full.parquet").scan_data_ref().fingerprint()
    var full = _full_scan()
    var fp = full.scan_data_ref().fingerprint()
    assert_true(fp != base)
    var only_rows = LogicalPlan.scan(
        "full.parquet", SOURCE_PARQUET, _schema("a", "b"), None, None, Optional(42)
    )
    var only_filter = LogicalPlan.scan(
        "full.parquet", SOURCE_PARQUET, _schema("a", "b"), None, Optional(_gt("a", 1))
    )
    var only_proj = LogicalPlan.scan(
        "full.parquet", SOURCE_PARQUET, _schema("a", "b"), Optional(_l("a"))
    )
    var fps: List[UInt64] = [
        base,
        only_rows.scan_data_ref().fingerprint(),
        only_filter.scan_data_ref().fingerprint(),
        only_proj.scan_data_ref().fingerprint(),
    ]
    for x in range(len(fps)):
        for y in range(x + 1, len(fps)):
            assert_true(fps[x] != fps[y], String(x) + " vs " + String(y))
    var c = full.copy()
    assert_equal(c.scan_data_ref().fingerprint(), fp)


# =============================================================================
# Malformed nodes
# =============================================================================


def test_every_tag_without_its_payload_is_refused() raises:
    """A node of each tag with no payload is refused by integrity, and
    `_copy_plan` raises naming the missing payload rather than copying a
    shell. Catches an integrity arm that skips its payload check and a
    `_copy_plan` that copies the shell."""
    var tags = _tags()
    for i in range(len(tags)):
        var shell = LogicalPlan(tags[i], _schema("a", "b"))
        assert_false(validate_plan_integrity(shell), "tag " + String(Int(tags[i])))
        var msg = String("")
        try:
            _ = _copy_plan(shell)
        except e:
            msg = String(e)
        assert_true("MISSING" in msg, "tag " + String(Int(tags[i])) + ": " + msg)


def test_a_consumed_plan_and_a_retired_tag_are_refused() raises:
    """Catches the sentinel check (255, a plan already moved from) and the
    unknown-tag fallback each answering True."""
    assert_false(validate_plan_integrity(LogicalPlan(UInt8(255), _schema("a", "b"))))
    assert_false(validate_plan_integrity(LogicalPlan(UInt8(16), _schema("a", "b"))))


def test_malformed_projects_and_an_empty_union_are_refused() raises:
    """A Project whose second expression reads its own first output `x` (a
    sibling, not a column of its child), a Project whose schema has a column
    more than its expressions, and a Union with no branch. Catches the
    sibling-scope check, the expression-count check and the zero-branch check
    each dropped."""
    var p = _kind(2)
    var sib = ExprArray()
    sib.append(Expr.alias(Expr.col_ref("a"), "x"))
    sib.append(Expr.col_ref("x"))
    p._project.value()[].exprs = sib^
    assert_false(validate_plan_integrity(p))
    var q = _kind(2)
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("z", ArrowType.INT64, True))
    q.output_schema = sb.build()
    assert_false(validate_plan_integrity(q))
    var u = LogicalPlan.union(List[OwnedPointer[LogicalPlan]](), _schema("a", "b"))
    assert_false(validate_plan_integrity(u))


# =============================================================================
# Aggregate base names
# =============================================================================


def test_every_aggregate_function_has_its_own_base_name() raises:
    """Every AGG_* tag 0..36 has a base name of its own (none is the `agg`
    fallback, no two are equal), and an id past the last falls back to
    `agg`. Catches an arm dropped (that function's unaliased output column
    would be named `agg`) and two arms sharing a name."""
    var names = List[String]()
    for f in range(37):
        var n = String(agg_func_base_name(UInt8(f)))
        assert_true(n != "agg", "func " + String(f))
        for k in range(len(names)):
            assert_true(names[k] != n, n)
        names.append(n)
    assert_equal(String(agg_func_base_name(UInt8(37))), "agg")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
