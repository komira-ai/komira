# =============================================================================
# test_payload_narrow_walk: side shapes, the walk, scan pre-order, refusals
# =============================================================================
#
# The per-column conditions are in test_payload_narrow_columns. Here the
# columns are fixed (left `key`, `pv` footer [1, 999]; right `key`, `bv` footer
# [1, 9999]: `0:pv:2:1 | 1:bv:2:1` when nothing else intervenes) and what
# varies is the plan around them. Results are rendered whole, one slot per
# scan in pre-order, so a scan counted in the wrong place shows as a spec in
# the wrong slot.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.payload_narrow import PayloadNarrowSpec
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP, DTAG_I64
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    SOURCE_PARQUET,
    SOURCE_CSV,
    JOIN_INNER,
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
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)

from komira_lowering_rules.payload_narrow import (
    derive_payload_narrow,
    LOWERING_PAYLOAD_NARROW_FOOTER_COUNT,
    LOWERING_SCAN_ORDER_UNKNOWN_TAG,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema(pay: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field(pay, ArrowType.INT64, False))
    return sb.build()


def _footer(pay: String, hi: Int64) -> TableStats:
    var names = List[String]()
    var stats = List[ColumnStats]()
    names.append("key")
    stats.append(
        ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_int64(0)),
            Optional[ScalarValue](ScalarValue.from_int64(24999999)),
            Optional[Int](0),
        )
    )
    names.append(pay)
    stats.append(
        ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_int64(1)),
            Optional[ScalarValue](ScalarValue.from_int64(hi)),
            Optional[Int](0),
        )
    )
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _scan(pay: String, source_type: UInt8 = SOURCE_PARQUET) -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", source_type, _schema(pay))


def _keys() -> List[String]:
    var k = List[String]()
    k.append("key")
    return k^


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _keys(), _keys(), JOIN_INNER)


def _hc4() -> LogicalPlan:
    return _join(_scan("pv"), _scan("bv"))


def _render(specs: List[List[PayloadNarrowSpec]]) -> String:
    """`scan:name:bytes:base` per spec, scans separated by ` | `."""
    var out = String()
    for s in range(len(specs)):
        if s > 0:
            out += " | "
        for i in range(len(specs[s])):
            if i > 0:
                out += " "
            ref p = specs[s][i]
            out += String(s) + ":" + p.column_name + ":" + String(Int(p.target_bytes)) + ":" + String(p.base)
    return out^


struct Footers:
    """A footer list built in scan pre-order."""

    var items: List[Optional[TableStats]]

    def __init__(out self):
        self.items = List[Optional[TableStats]]()

    def pay(mut self, pay: String, hi: Int64):
        self.items.append(Optional[TableStats](_footer(pay, hi)))

    def none(mut self):
        self.items.append(None)


def _derive(plan: LogicalPlan, footers: Footers) raises -> String:
    return _render(derive_payload_narrow(plan, footers.items))


def _hc4_footers(mut f: Footers):
    f.pay("pv", 999)
    f.pay("bv", 9999)


def _eq(got: String, want: String) raises:
    assert_equal(got, want)


# =============================================================================
# Side shapes
# =============================================================================


def _filter(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(3))),
        child^,
    )


def _pure_project(var child: LogicalPlan, aliased: Bool) -> LogicalPlan:
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    if aliased:
        pe.append(Expr.alias(Expr.col_ref("pv"), String("pv")))
    else:
        pe.append(Expr.col_ref("pv"))
    return LogicalPlan.project(pe^, child^)


def test_filter_and_pure_project_sides_reach_their_scan() raises:
    # Filter over a scan; a column-reference project; an alias project over a
    # filter over a column-reference project over a filter. Catches: the
    # FILTER or PROJECT arm of the side check removed, or an alias of a column
    # reference refused (the alias arm of the purity check).
    var f = Footers()
    _hc4_footers(f)
    _eq(_derive(_join(_filter(_scan("pv")), _scan("bv")), f), "0:pv:2:1 | 1:bv:2:1")
    _eq(_derive(_join(_pure_project(_scan("pv"), False), _scan("bv")), f), "0:pv:2:1 | 1:bv:2:1")
    var chain = _pure_project(_filter(_pure_project(_filter(_scan("pv")), False)), True)
    _eq(_derive(_join(chain^, _scan("bv")), f), "0:pv:2:1 | 1:bv:2:1")


def test_sides_that_do_not_reach_a_parquet_scan_narrow_nothing() raises:
    # A computed project, a UDF project, an aggregate, a CSV scan, and a SCAN,
    # FILTER and PROJECT whose payload is unset. The right side narrows in
    # every case. Catches: a computed or UDF project admitted, a side that is
    # not FILTER/PROJECT/SCAN admitted, a non-Parquet scan admitted, or an
    # unset payload dereferenced.
    var f = Footers()
    _hc4_footers(f)

    # The computed project also passes `pv` through unchanged, so admitting
    # the side would narrow `pv`.
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    pe.append(Expr.col_ref("pv"))
    pe.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(1))), String("z")))
    _eq(_derive(_join(LogicalPlan.project(pe^, _scan("pv")), _scan("bv")), f), " | 1:bv:2:1")

    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append((String("pv"), DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((String("pv"), DTAG_I64))
    var udf = OwnedPointer(UdfData(UDF_KIND_MAP, String("m"), in_cols^, out_cols^, 1, 1))
    var pe2 = ExprArray()
    pe2.append(Expr.col_ref("key"))
    pe2.append(Expr.col_ref("pv"))
    var with_udf = LogicalPlan.project_with_udf(pe2^, _scan("pv"), udf^)
    _eq(_derive(_join(with_udf^, _scan("bv")), f), " | 1:bv:2:1")

    var gb = ExprArray()
    gb.append(Expr.col_ref("key"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("pv")))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan("pv"))
    _eq(_derive(_join(agg^, _scan("bv")), f), " | 1:bv:2:1")

    _eq(_derive(_join(_scan("pv", SOURCE_CSV), _scan("bv")), f), " | 1:bv:2:1")
    # A FILTER, a pure PROJECT, and a chain of both, over a CSV scan: the
    # side check recurses to the scan rather than admitting at the first
    # FILTER or PROJECT. Catches: the FILTER or the PROJECT arm returning
    # True instead of looking below.
    _eq(_derive(_join(_filter(_scan("pv", SOURCE_CSV)), _scan("bv")), f), " | 1:bv:2:1")
    _eq(_derive(_join(_pure_project(_scan("pv", SOURCE_CSV), True), _scan("bv")), f), " | 1:bv:2:1")
    var csv_chain = _pure_project(_filter(_pure_project(_filter(_scan("pv", SOURCE_CSV)), False)), True)
    _eq(_derive(_join(csv_chain^, _scan("bv")), f), " | 1:bv:2:1")

    # A bare SCAN tag is still a scan in the order: it takes slot 0.
    _eq(_derive(_join(LogicalPlan(PLAN_SCAN, _schema("pv")), _scan("bv")), f), " | 1:bv:2:1")
    # A bare FILTER or PROJECT has no child, so no scan: the right side is slot 0.
    var one = Footers()
    one.pay("bv", 9999)
    _eq(_derive(_join(LogicalPlan(PLAN_FILTER, _schema("pv")), _scan("bv")), one), "0:bv:2:1")
    _eq(_derive(_join(LogicalPlan(PLAN_PROJECT, _schema("pv")), _scan("bv")), one), "0:bv:2:1")


# =============================================================================
# The walk finds a join under every node kind it descends
# =============================================================================


def _over(kind: UInt8, var child: LogicalPlan) raises -> LogicalPlan:
    """A node of kind `kind` with `child` below it."""
    var keys = List[String]()
    keys.append("pv")
    var desc = List[Bool]()
    desc.append(False)
    if kind == PLAN_FILTER:
        return LogicalPlan.filter(Expr.col_ref("pv"), child^)
    if kind == PLAN_PROJECT:
        var pe = ExprArray()
        pe.append(Expr.col_ref("pv"))
        return LogicalPlan.project(pe^, child^)
    if kind == PLAN_AGGREGATE:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("s")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, child^)
    if kind == PLAN_SORT:
        return LogicalPlan.sort(keys^, desc^, child^)
    if kind == PLAN_LIMIT:
        return LogicalPlan.limit(5, child^)
    if kind == PLAN_TOPN:
        return LogicalPlan.topn(keys^, desc^, 5, child^)
    if kind == PLAN_DISTINCT:
        return LogicalPlan.distinct(None, child^)
    if kind == PLAN_PARTITION_BY:
        return LogicalPlan.partition_by(List[String](), keys^, desc^, List[PartitionExpr](), child^)
    if kind == PLAN_PARTITION_TOPN:
        return LogicalPlan.partition_topn(_keys(), keys^, desc^, 1, child^)
    raise Error("no fixture for kind " + String(Int(kind)))


def test_the_walk_finds_a_join_under_every_one_child_node() raises:
    # Catches: a recursion arm dropped (the join below that kind would narrow
    # nothing).
    var kinds = List[UInt8]()
    kinds.append(PLAN_FILTER)
    kinds.append(PLAN_PROJECT)
    kinds.append(PLAN_AGGREGATE)
    kinds.append(PLAN_SORT)
    kinds.append(PLAN_LIMIT)
    kinds.append(PLAN_TOPN)
    kinds.append(PLAN_DISTINCT)
    kinds.append(PLAN_PARTITION_BY)
    kinds.append(PLAN_PARTITION_TOPN)
    var f = Footers()
    _hc4_footers(f)
    for i in range(len(kinds)):
        _eq(_derive(_over(kinds[i], _hc4()), f), "0:pv:2:1 | 1:bv:2:1")


def _asof(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.asof_join(
        l^, r^, List[String](), List[String](),
        String("key"), String("key"), ASOF_BACKWARD, AsofTolerance.none(),
    )


def test_joins_below_an_asof_join_or_a_join_are_decided() raises:
    # A join on each side of an as-of join, and a join as a join's left side
    # (whose right side is a scan and narrows). Catches: an as-of side not
    # walked, a nested join not walked, or a nested join's side indices
    # taken from the outer join.
    var f = Footers()
    _hc4_footers(f)
    _hc4_footers(f)
    _eq(
        _derive(_asof(_hc4(), _hc4()), f),
        "0:pv:2:1 | 1:bv:2:1 | 2:pv:2:1 | 3:bv:2:1",
    )
    var g = Footers()
    _hc4_footers(g)
    g.pay("ov", 999)
    _eq(_derive(_join(_hc4(), _scan("ov")), g), "0:pv:2:1 | 1:bv:2:1 | 2:ov:2:1")


def test_a_join_below_a_union_or_a_cast_to_varchar_is_not_decided() raises:
    # The optimizer rule's walk stops at both; parity keeps that. Their scans
    # still take their slots. Catches: either walked as a live arm.
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_hc4()))
    children.append(OwnedPointer(_hc4()))
    var u = LogicalPlan.union(children^, _hc4().output_schema.copy())
    var f = Footers()
    _hc4_footers(f)
    _hc4_footers(f)
    _eq(_derive(u, f), " |  |  | ")
    var g = Footers()
    _hc4_footers(g)
    _eq(_derive(LogicalPlan.cast_to_varchar(_hc4()), g), " | ")


def _deep_chain() raises -> LogicalPlan:
    """Every pass-through arm stacked over joins that would narrow if decided.

    Bottom: an as-of join whose left side is a join of `_hc4()` and a scan of
    `ov`, and whose right side is a join of a scan of `ov` and `_hc4()`. The
    two outer joins each have one qualifying scan side, the two `_hc4()`s
    both. Above it, one node of every one-child kind. Scans in pre-order:
    pv, bv, ov, ov, pv, bv.
    """
    var left = _join(_hc4(), _scan("ov"))
    var right = _join(_scan("ov"), _hc4())
    var node = _asof(left^, right^)
    var kinds = List[UInt8]()
    kinds.append(PLAN_FILTER)
    kinds.append(PLAN_PARTITION_TOPN)
    kinds.append(PLAN_PARTITION_BY)
    kinds.append(PLAN_SORT)
    kinds.append(PLAN_LIMIT)
    kinds.append(PLAN_TOPN)
    kinds.append(PLAN_DISTINCT)
    kinds.append(PLAN_PROJECT)
    kinds.append(PLAN_AGGREGATE)
    for i in range(len(kinds)):
        node = _over(kinds[i], node^)
    return node^


def _deep_footers(mut f: Footers):
    _hc4_footers(f)
    f.pay("ov", 999)
    f.pay("ov", 999)
    _hc4_footers(f)


def test_a_join_deep_below_a_union_or_a_cast_to_varchar_is_not_decided() raises:
    # `_deep_chain()` decided on its own narrows all six scans. Below a UNION
    # (as its first child) or a CAST_TO_VARCHAR it narrows none: every node
    # between them and the joins passes the not-decided state down. Catches:
    # any one pass-through arm (FILTER, PROJECT, AGGREGATE, SORT, LIMIT,
    # DISTINCT, TOPN, PARTITION_BY, PARTITION_TOPN, either as-of side, either
    # join side) walking its child as decided, which the depth-one cases
    # above cannot see.
    var f = Footers()
    _deep_footers(f)
    _eq(
        _derive(_deep_chain(), f),
        "0:pv:2:1 | 1:bv:2:1 | 2:ov:2:1 | 3:ov:2:1 | 4:pv:2:1 | 5:bv:2:1",
    )
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_deep_chain()))
    kids.append(OwnedPointer(_scan("x")))
    var u = LogicalPlan.union(kids^, _schema("x"))
    var g = Footers()
    _deep_footers(g)
    g.none()
    _eq(_derive(u, g), " |  |  |  |  |  | ")
    var h = Footers()
    _deep_footers(h)
    _eq(_derive(LogicalPlan.cast_to_varchar(_deep_chain()), h), " |  |  |  |  | ")


# =============================================================================
# Scan pre-order
# =============================================================================


def test_scans_before_a_join_shift_its_slots() raises:
    # An as-of join whose left side holds scans the rule does not narrow, and
    # whose right side is the join: a union of two scans (slots 0, 1), a
    # CAST_TO_VARCHAR over a scan (slot 0), a VIEW_REF and a CSE_REF (no
    # slot). Catches: union children or a cast's child not counted, a leaf
    # counted, a left index taken after the left side is walked, or the
    # right index taken before it.
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan("x")))
    kids.append(OwnedPointer(_scan("x")))
    var u = LogicalPlan.union(kids^, _schema("x"))
    var f = Footers()
    f.none()
    f.none()
    _hc4_footers(f)
    _eq(_derive(_asof(u^, _hc4()), f), " |  | 2:pv:2:1 | 3:bv:2:1")

    var g = Footers()
    g.none()
    _hc4_footers(g)
    _eq(_derive(_asof(LogicalPlan.cast_to_varchar(_scan("x")), _hc4()), g), " | 1:pv:2:1 | 2:bv:2:1")

    var h = Footers()
    _hc4_footers(h)
    _eq(_derive(_asof(LogicalPlan.view_ref("v", _schema("x")), _hc4()), h), "0:pv:2:1 | 1:bv:2:1")
    _eq(_derive(_asof(LogicalPlan.cse_ref(7, _schema("x")), _hc4()), h), "0:pv:2:1 | 1:bv:2:1")

    # A join's right side holding the left side's scan count: the left side
    # is a filter over a join (two scans, not a side that qualifies).
    var k = Footers()
    _hc4_footers(k)
    k.pay("ov", 999)
    _eq(_derive(_join(_filter(_hc4()), _scan("ov")), k), "0:pv:2:1 | 1:bv:2:1 | 2:ov:2:1")


def test_a_tag_without_its_payload_has_no_children() raises:
    # Every tag but SCAN takes no slot when its payload is unset; SCAN takes
    # one. Catches: an unset payload dereferenced, or a bare tag counted
    # wrong.
    var tags = List[UInt8]()
    tags.append(PLAN_FILTER)
    tags.append(PLAN_PROJECT)
    tags.append(PLAN_AGGREGATE)
    tags.append(PLAN_JOIN)
    tags.append(PLAN_SORT)
    tags.append(PLAN_LIMIT)
    tags.append(PLAN_DISTINCT)
    tags.append(PLAN_TOPN)
    tags.append(PLAN_PARTITION_BY)
    tags.append(PLAN_PARTITION_TOPN)
    tags.append(PLAN_ASOF_JOIN)
    tags.append(PLAN_UNION)
    tags.append(PLAN_VIEW_REF)
    tags.append(PLAN_CSE_REF)
    tags.append(PLAN_CAST_TO_VARCHAR)
    var empty = List[Optional[TableStats]]()
    for i in range(len(tags)):
        var bare = LogicalPlan(tags[i], _schema("pv"))
        assert_equal(len(derive_payload_narrow(bare, empty)), 0)
    var one = List[Optional[TableStats]]()
    one.append(None)
    assert_equal(len(derive_payload_narrow(LogicalPlan(PLAN_SCAN, _schema("pv")), one)), 1)


# =============================================================================
# Refusals
# =============================================================================


def test_a_footer_count_that_is_not_the_scan_count_is_refused() raises:
    # One footer short, one too many, and none for a lone scan. Catches: the
    # count check removed (a short list would be indexed past its end) or
    # turned into a lower bound.
    var short = Footers()
    short.pay("pv", 999)
    var long = Footers()
    _hc4_footers(long)
    long.none()
    var cases = List[String]()
    for c in range(3):
        try:
            if c == 0:
                _ = _derive(_hc4(), short)
            elif c == 1:
                _ = _derive(_hc4(), long)
            else:
                _ = _derive(_scan("pv"), Footers())
            cases.append("accepted")
        except e:
            cases.append(String(e))
    _eq(cases[0], String(LOWERING_PAYLOAD_NARROW_FOOTER_COUNT) + ": the plan has 2 scans and footer_stats has 1 entries")
    _eq(cases[1], String(LOWERING_PAYLOAD_NARROW_FOOTER_COUNT) + ": the plan has 2 scans and footer_stats has 3 entries")
    _eq(cases[2], String(LOWERING_PAYLOAD_NARROW_FOOTER_COUNT) + ": the plan has 1 scans and footer_stats has 0 entries")


def test_an_unknown_tag_is_refused() raises:
    # At the root and below a filter. Catches: an unknown tag read as a leaf
    # (the scan order below it would be unknown).
    var got = List[String]()
    for c in range(2):
        try:
            if c == 0:
                _ = derive_payload_narrow(LogicalPlan(UInt8(99), _schema("pv")), List[Optional[TableStats]]())
            else:
                _ = derive_payload_narrow(_filter(LogicalPlan(UInt8(16), _schema("pv"))), List[Optional[TableStats]]())
            got.append("accepted")
        except e:
            got.append(String(e))
    _eq(got[0], String(LOWERING_SCAN_ORDER_UNKNOWN_TAG) + ": plan tag 99 is no PLAN_* tag")
    _eq(got[1], String(LOWERING_SCAN_ORDER_UNKNOWN_TAG) + ": plan tag 16 is no PLAN_* tag")
    assert_true(len(got) == 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
