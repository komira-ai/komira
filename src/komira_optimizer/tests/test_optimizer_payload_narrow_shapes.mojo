# =============================================================================
# test_optimizer_payload_narrow_shapes -- side shapes, refusals, the walk
# =============================================================================
#
# Companion to `test_optimizer_payload_narrow.mojo`, which pins the width
# ladder and the hc4 join. These tests pin what that file does not reach:
# a side behind a Filter or a pure Project, the side shapes the rule refuses,
# every per-column refusal, the join-level refusals, and the walk that finds a
# join under every node kind. As there, each refusal is checked against a
# sibling that still narrows, so a test cannot pass because nothing fired.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.payload_narrow import PayloadNarrowSpec, PAYLOAD_NARROW_2B
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP, DTAG_I64
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_TOPN,
    PLAN_DISTINCT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)

from komira_optimizer.optimizer_payload_narrow import (
    narrow_join_payload,
    narrow_join_payload_inplace,
    _stamp_scan_specs,
    _scan_stats_min_max,
    _narrow_one_side,
    _peel_to_parquet_scan,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema(key: String, pay: String, pay_type: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(key, ArrowType.INT64, False))
    sb.add_field(Field(pay, pay_type, False))
    return sb.build()


def _int_stats(lo: Int64, hi: Int64) -> ColumnStats:
    return ColumnStats(
        None,
        Optional[ScalarValue](ScalarValue.from_int64(lo)),
        Optional[ScalarValue](ScalarValue.from_int64(hi)),
        Optional[Int](0),
    )


def _stats(key: String, var key_cs: ColumnStats, pay: String, var pay_cs: ColumnStats) -> TableStats:
    var names = List[String]()
    var stats = List[ColumnStats]()
    names.append(key)
    stats.append(key_cs^)
    names.append(pay)
    stats.append(pay_cs^)
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _scan_with(
    path: String, key: String, pay: String, pay_type: ArrowType, var pay_cs: ColumnStats,
    stats_pay_name: String,
) -> LogicalPlan:
    return LogicalPlan.scan(
        path,
        SOURCE_PARQUET,
        _schema(key, pay, pay_type),
        None,
        None,
        None,
        Optional[TableStats](_stats(key, _int_stats(0, 24999999), stats_pay_name, pay_cs^)),
    )


def _good(path: String, pay: String) -> LogicalPlan:
    """A parquet side whose INT64 payload [1, 999] narrows to 2 bytes."""
    return _scan_with(path, "key", pay, ArrowType.INT64, _int_stats(1, 999), pay)


def _keys() -> List[String]:
    var k = List[String]()
    k.append(String("key"))
    return k^


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _keys(), _keys(), JOIN_INNER)


def _hc4() -> LogicalPlan:
    return _join(_good("probe.parquet", "pv"), _good("build.parquet", "bv"))


def _specs_at_bottom(imm node: LogicalPlan) raises -> List[String]:
    """The stamped specs of the SCAN under Filters / Projects, as name:bytes:base."""
    if node.tag == PLAN_SCAN:
        var out = List[String]()
        ref pn = node.scan_data_ref().payload_narrow
        for i in range(len(pn)):
            out.append(
                pn[i].column_name + String(":") + String(Int(pn[i].target_bytes))
                + String(":") + String(pn[i].base)
            )
        return out^
    if node.is_filter():
        return _specs_at_bottom(node.filter_data_ref().child[])
    if node.is_project():
        return _specs_at_bottom(node.project_data_ref().child[])
    return List[String]()


def _pure_project(var child: LogicalPlan, aliased: Bool) -> LogicalPlan:
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    if aliased:
        pe.append(Expr.alias(Expr.col_ref("pv"), String("pv")))
    else:
        pe.append(Expr.col_ref("pv"))
    return LogicalPlan.project(pe^, child^)


# =============================================================================
# Side shapes
# =============================================================================


def test_a_side_behind_a_filter_or_a_pure_project_narrows() raises:
    # Filter -> scan, Project(col refs) -> scan, Project(alias of a col ref)
    # -> Filter -> scan. Catches: the Filter or Project arm dropped from any
    # of the three side walks (peel, stamp, stats): that side would narrow 0.
    var f = LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(3))),
        _good("probe.parquet", "pv"),
    )
    var plan = _join(f^, _pure_project(_good("b.parquet", "pv"), False))
    assert_equal(narrow_join_payload_inplace(plan), 2)
    assert_equal(_specs_at_bottom(plan.join_data_ref().left[])[0], String("pv:2:1"))
    assert_equal(_specs_at_bottom(plan.join_data_ref().right[])[0], String("pv:2:1"))

    var f2 = LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(3))),
        _good("probe.parquet", "pv"),
    )
    var plan2 = _join(_pure_project(f2^, True), _good("b.parquet", "bv"))
    assert_equal(narrow_join_payload_inplace(plan2), 2)


def test_refused_side_shapes_narrow_nothing_on_that_side() raises:
    # A computed Project, a UDF Project and an Aggregate side. Catches: a
    # computed column narrowed (its evaluator knows nothing of the base), or
    # a side the fused join leaf (not in this tree) would not recognise
    # being stamped.
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    pe.append(Expr.binary(BIN_ADD, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(1))))
    var computed = LogicalPlan.project(pe^, _good("p.parquet", "pv"))
    var p1 = _join(computed^, _good("b.parquet", "bv"))
    assert_equal(narrow_join_payload_inplace(p1), 1)

    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append((String("pv"), DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((String("pv"), DTAG_I64))
    var udf = OwnedPointer(UdfData(UDF_KIND_MAP, String("m"), in_cols^, out_cols^, 1, 1))
    var pe2 = ExprArray()
    pe2.append(Expr.col_ref("key"))
    pe2.append(Expr.col_ref("pv"))
    var with_udf = LogicalPlan.project_with_udf(pe2^, _good("p.parquet", "pv"), udf^)
    var p2 = _join(with_udf^, _good("b.parquet", "bv"))
    assert_equal(narrow_join_payload_inplace(p2), 1)

    var gb = ExprArray()
    gb.append(Expr.col_ref("key"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("pv")))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _good("p.parquet", "pv"))
    var p3 = _join(agg^, _good("b.parquet", "bv"))
    assert_equal(narrow_join_payload_inplace(p3), 1)


# =============================================================================
# Per-column refusals
# =============================================================================


def _refused_side(c: Int) -> LogicalPlan:
    """A parquet side with exactly one reason not to narrow its payload."""
    if c == 0:
        return _scan_with("l.parquet", "key", "pv", ArrowType.INT32, _int_stats(1, 9), "pv")
    if c == 1:
        return _scan_with(
            "l.parquet", "key", "pv", ArrowType.INT64, _int_stats(0, 4294967296), "pv"
        )
    if c == 2:
        return _scan_with("l.parquet", "key", "pv", ArrowType.INT64, _int_stats(1, 9), "other")
    if c == 3:
        var no_max = ColumnStats(
            None, Optional[ScalarValue](ScalarValue.from_int64(1)), None, Optional[Int](0)
        )
        return _scan_with("l.parquet", "key", "pv", ArrowType.INT64, no_max^, "pv")
    var float_bounds = ColumnStats(
        None,
        Optional[ScalarValue](ScalarValue.from_float(1.0)),
        Optional[ScalarValue](ScalarValue.from_float(9.0)),
        Optional[Int](0),
    )
    return _scan_with("l.parquet", "key", "pv", ArrowType.INT64, float_bounds^, "pv")


def test_column_refusals() raises:
    # Each left side has one reason not to narrow its payload; the right side
    # is the good control. Catches, in order: a non-INT64 payload narrowed
    # (two reconstruction types); a span that needs 8 bytes narrowed; stats
    # read off a column of another name; a missing min or max guessed; a
    # non-integer bound used.
    for c in range(5):
        var plan = _join(_refused_side(c), _good("b.parquet", "bv"))
        assert_equal(narrow_join_payload_inplace(plan), 1)
        assert_equal(len(_specs_at_bottom(plan.join_data_ref().left[])), 0)
        assert_equal(_specs_at_bottom(plan.join_data_ref().right[])[0], String("bv:2:1"))


def test_a_side_whose_only_column_is_the_key_returns_zero() raises:
    # Catches: an empty spec list stamped (it would replace a previous stamp
    # with nothing) or counted.
    var keys = _keys()
    var side = _good("p.parquet", "key2")
    var k2 = List[String]()
    k2.append(String("key"))
    k2.append(String("key2"))
    assert_equal(_narrow_one_side(side, k2), 0)
    assert_equal(len(_specs_at_bottom(side)), 0)
    assert_equal(_narrow_one_side(side, keys), 1)


# =============================================================================
# Join-level refusals
# =============================================================================


def test_a_residual_or_a_multi_key_join_is_refused() raises:
    # Catches: narrowing under a residual (evaluated by name over the joined
    # batch), or under a multi-key join, which the leaf this rule is designed
    # for (not in this tree) does not take.
    var residual = Optional[OwnedPointer[Expr]](
        OwnedPointer(
            Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("bv"))
        )
    )
    var with_res = LogicalPlan.join(
        _good("p.parquet", "pv"), _good("b.parquet", "bv"), _keys(), _keys(),
        JOIN_INNER, residual=residual^,
    )
    assert_equal(narrow_join_payload_inplace(with_res), 0)

    var two = List[String]()
    two.append(String("key"))
    two.append(String("pv"))
    var two_r = List[String]()
    two_r.append(String("key"))
    two_r.append(String("bv"))
    var multi = LogicalPlan.join(
        _good("p.parquet", "pv"), _good("b.parquet", "bv"), two^, two_r^, JOIN_INNER
    )
    assert_equal(narrow_join_payload_inplace(multi), 0)
    # The control: the same sides, one key, no residual.
    var control = _hc4()
    assert_equal(narrow_join_payload_inplace(control), 2)


# =============================================================================
# The walk
# =============================================================================


def _wrap(kind: Int) raises -> LogicalPlan:
    """A node of the given kind with the hc4 join below it."""
    var keys = List[String]()
    keys.append(String("pv"))
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        return LogicalPlan.filter(Expr.col_ref("pv"), _hc4())
    if kind == 1:
        var pe = ExprArray()
        pe.append(Expr.col_ref("pv"))
        return LogicalPlan.project(pe^, _hc4())
    if kind == 2:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("s")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, _hc4())
    if kind == 3:
        return LogicalPlan.sort(keys^, desc^, _hc4())
    if kind == 4:
        return LogicalPlan.limit(5, _hc4())
    if kind == 5:
        return LogicalPlan.topn(keys^, desc^, 5, _hc4())
    if kind == 6:
        return LogicalPlan.distinct(None, _hc4())
    if kind == 7:
        return LogicalPlan.partition_by(
            List[String](), keys^, desc^, List[PartitionExpr](), _hc4()
        )
    if kind == 8:
        return LogicalPlan.partition_topn(_keys(), keys^, desc^, 1, _hc4())
    if kind == 9:
        return LogicalPlan.asof_join(
            _hc4(), _good("r.parquet", "rv"), List[String](), List[String](),
            String("key"), String("key"), ASOF_BACKWARD, AsofTolerance.none(),
        )
    # A join nested under a join: both inner sides narrow, the outer join's
    # left side is not a scan and narrows nothing, its right side narrows 1.
    return _join(_hc4(), _good("o.parquet", "ov"))


def test_the_walk_finds_a_join_under_every_node_kind() raises:
    # Catches: a recursion arm dropped (the join below that kind narrows 0),
    # or a nested join not visited before its parent.
    for kind in range(11):
        var plan = _wrap(kind)
        var n = narrow_join_payload_inplace(plan)
        if kind == 10:
            assert_equal(n, 3)
        else:
            assert_equal(n, 2)
    # A bare scan is not a join.
    var scan = _good("p.parquet", "pv")
    assert_equal(narrow_join_payload_inplace(scan), 0)
    # The value-taking wrapper stamps the same way.
    var out = narrow_join_payload(_hc4())
    assert_equal(_specs_at_bottom(out.join_data_ref().left[])[0], String("pv:2:1"))


# =============================================================================
# The side walks, called directly
# =============================================================================


def test_stamp_and_stats_refuse_what_peel_refuses() raises:
    # The two walks are called only after the peel succeeds; called directly
    # they must still refuse a non-parquet scan and a non-scan node. Catches:
    # a stamp on an in-memory scan, or stats read through an Aggregate.
    var specs = List[PayloadNarrowSpec]()
    specs.append(PayloadNarrowSpec(String("pv"), PAYLOAD_NARROW_2B, 1))
    var mem = LogicalPlan.scan("mem", SOURCE_IN_MEMORY, _schema("key", "pv", ArrowType.INT64))
    assert_false(_stamp_scan_specs(mem, specs.copy()))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("pv")))
    var agg = LogicalPlan.aggregate(ExprArray(), aggs^, _good("p.parquet", "pv"))
    assert_false(_stamp_scan_specs(agg, specs.copy()))
    assert_false(Bool(_scan_stats_min_max(agg, String("pv"))))
    var good = _good("p.parquet", "pv")
    assert_true(_stamp_scan_specs(good, specs^))
    var mm = _scan_stats_min_max(good, String("pv"))
    assert_true(Bool(mm))
    assert_equal(Int(mm.value()[0]), 1)
    assert_equal(Int(mm.value()[1]), 999)


def test_a_tag_without_its_payload_is_a_dead_end() raises:
    # `LogicalPlan(tag, schema)` builds a node whose payload is unset. Every
    # walk guards the payload as well as the tag. Catches: a guard dropped
    # (the walk would dereference an empty payload).
    var tags = List[UInt8]()
    tags.append(PLAN_JOIN)
    tags.append(PLAN_FILTER)
    tags.append(PLAN_PROJECT)
    tags.append(PLAN_AGGREGATE)
    tags.append(PLAN_SORT)
    tags.append(PLAN_LIMIT)
    tags.append(PLAN_TOPN)
    tags.append(PLAN_DISTINCT)
    tags.append(PLAN_PARTITION_BY)
    tags.append(PLAN_PARTITION_TOPN)
    tags.append(PLAN_ASOF_JOIN)
    tags.append(PLAN_SCAN)
    for i in range(len(tags)):
        var bare = LogicalPlan(tags[i], _schema("key", "pv", ArrowType.INT64))
        assert_equal(narrow_join_payload_inplace(bare), 0)
        assert_false(_peel_to_parquet_scan(bare))
        assert_false(_stamp_scan_specs(bare, List[PayloadNarrowSpec]()))
        assert_false(Bool(_scan_stats_min_max(bare, String("pv"))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
