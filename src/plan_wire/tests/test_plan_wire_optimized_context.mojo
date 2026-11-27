# =============================================================================
# test_plan_wire_optimized_context.mojo — the fields an optimizer fills in, in
# the RAW and the OPTIMIZED context (docs/design/optimized_plan.md §5.2).
# =============================================================================
#
# A RAW plan (an envelope: `plan_to_bytes`, `plan_from_bytes`) has no recorded
# optimizer decisions. An OPTIMIZED plan (`optimized_plan_to_bytes`,
# `optimized_plan_from_bytes`, and the struct forms `optimized_plan_to_wire`,
# `optimized_plan_from_wire`) carries a build side on every join and the
# group-count estimate of an aggregate or distinct, and carries no scan
# statistic. Every join in a plan is checked, not only the root.
#
# WHAT EACH TEST PROVES:
#
#   test_optimized_round_trip_keeps_each_build_side
#       A join recorded LEFT or RIGHT comes back with the same recorded side,
#       and the bytes carry it in WireJoinNode field 9 as 1 (LEFT) or 2
#       (RIGHT), read back with `decode_proto[WirePlan]`.
#       Catches: a side that decodes as the other one or as UNSET, a field
#       written under another number.
#
#   test_every_join_of_a_plan_keeps_its_own_side
#       A join under a join, and a join under a project and an aggregate, each
#       keep the side recorded on them, in the IR and on the wire.
#       Catches: a codec that handles the root join only.
#
#   test_optimized_encode_refuses_a_join_with_no_build_side
#       An UNSET join is refused `OPTIMIZED_JOIN_BUILD_SIDE_MISSING` as the
#       root, as a child of a recorded join and under a project.
#       Catches: an UNSET side written as the unspecified value, a check on
#       the root only.
#
#   test_optimized_decode_refuses_an_unspecified_build_side
#       A wire join whose build_side is the unspecified value (the root, and a
#       nested one) is refused `OPTIMIZED_JOIN_BUILD_SIDE_MISSING`.
#       Catches: a decoder that defaults an absent side to UNSET, LEFT or
#       RIGHT.
#
#   test_optimized_decode_refuses_a_build_side_the_vocabulary_does_not_declare
#       Wire value 3 is refused by name, with the number in the text.
#       Catches: an undeclared number folded onto a side.
#
#   test_raw_encode_refuses_a_recorded_build_side_and_writes_none_otherwise
#       `plan_to_bytes` of a LEFT or RIGHT join, at the root and nested, is
#       refused `PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION` naming
#       JoinData.build_side; an UNSET join writes the unspecified value and
#       decodes UNSET.
#       Catches: a raw encoder that writes the side, a raw encoder that writes
#       a side for an undecided join.
#
#   test_raw_decode_refuses_a_set_build_side
#       An envelope whose join carries build_side 1, 2 or 3 (root and nested)
#       is refused `PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION` naming
#       WireJoinNode.build_side.
#       Catches: a raw decoder that admits a recorded decision, a raw decoder
#       that checks the root only.
#
#   test_optimized_round_trip_keeps_estimated_groups
#       The estimate on an aggregate and on a distinct comes back; the bytes
#       carry it. A negative value in a body is refused
#       `PLAN_WIRE_NEGATIVE_COUNT`.
#       Catches: a hint dropped by the optimized codec, a negative hint
#       reaching the IR.
#
#   test_raw_decode_still_refuses_estimated_groups
#       A raw envelope carrying the estimate on an aggregate or a distinct is
#       refused `PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS`.
#       Catches: the optimized rule leaking into the raw decoder.
#
#   test_optimized_context_refuses_scan_statistics
#       Decoding a scan that carries row_count is refused
#       `OPTIMIZED_FIELD_UNSUPPORTED`; encoding a scan whose IR holds a
#       row_count, and one that holds table_stats, is refused the same way,
#       also under a parent.
#       Catches: a statistic reaching the digest through a body.
#
#   test_raw_round_trip_still_admits_row_count
#       A raw scan keeps its row_count through `plan_to_bytes`/`plan_from_bytes`.
#       Catches: the optimized refusal applied to raw plans.
#
#   test_struct_forms_agree_with_the_bytes_forms
#       `optimized_plan_to_wire` encodes to the bytes `optimized_plan_to_bytes`
#       returns; `optimized_plan_from_wire` returns the plan
#       `optimized_plan_from_bytes` returns; both refuse what the bytes forms
#       refuse (an UNSET join on encode, an unspecified side on decode).
#       Catches: a struct form that skips a check its bytes form runs.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.agg_expr import AggExpr, AGG_SUM
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
)
from plan_ir.udf_ref import UdfRef
from plan_stats.table_stats import TableStats, ColumnStats
from proto_codec import decode_proto, encode_proto
from plan_proto.plan import WirePlan, WirePlanEnvelope
from plan_proto.plan_vocabulary import JoinBuildSide

from plan_wire import (
    plan_to_bytes,
    plan_from_bytes,
    optimized_plan_to_bytes,
    optimized_plan_from_bytes,
    optimized_plan_to_wire,
    optimized_plan_from_wire,
    OPTIMIZED_JOIN_BUILD_SIDE_MISSING,
    OPTIMIZED_FIELD_UNSUPPORTED,
    PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION,
    PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS,
    PLAN_WIRE_NEGATIVE_COUNT,
)


# ---------------------------------------------------------------------------
# Plans
# ---------------------------------------------------------------------------


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.FLOAT64, True))
    return sb.build()


def _scan(path: String, a: String, b: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _join_of(
    var left: LogicalPlan, var right: LogicalPlan, lo: String, ro: String, side: UInt8
) -> LogicalPlan:
    var lon: List[String] = [lo]
    var ron: List[String] = [ro]
    return LogicalPlan.join(
        left^, right^, lon^, ron^, JOIN_INNER, JOIN_ALGO_AUTO, None, side, False
    )


def _join(side: UInt8) -> LogicalPlan:
    return _join_of(
        _scan("/d/l.parquet", "a", "b"), _scan("/d/r.parquet", "c", "d"),
        "a", "c", side,
    )


def _join_over_join(outer: UInt8, inner: UInt8) -> LogicalPlan:
    """`(l JOIN r) JOIN t`: the inner join is the outer join's left child."""
    return _join_of(
        _join(inner), _scan("/d/t.parquet", "e", "f"), "a", "e", outer
    )


def _aggregate_over_project_over_join(side: UInt8) -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("a"))
    exprs.append(Expr.col_ref("d"))
    var project = LogicalPlan.project(exprs^, _join(side))
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("d")), Optional(String("t"))))
    return LogicalPlan.aggregate(gb^, ax^, project^)


def _aggregate(estimate: Int) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("t"))))
    var p = LogicalPlan.aggregate(gb^, ax^, _scan("/d/t.parquet", "a", "b"))
    p.set_estimated_groups(Optional(estimate))
    return p^


def _distinct(estimate: Int) -> LogicalPlan:
    var cols: List[String] = ["a"]
    var p = LogicalPlan.distinct(Optional(cols^), _scan("/d/t.parquet", "a", "b"))
    p.set_estimated_groups(Optional(estimate))
    return p^


def _scan_with_row_count() -> LogicalPlan:
    return LogicalPlan.scan(
        "/d/t.parquet", SOURCE_PARQUET, _schema("a", "b"), None, None, Optional(12)
    )


def _scan_with_table_stats() -> LogicalPlan:
    var stats = TableStats(7, List[String](), List[ColumnStats]())
    return LogicalPlan.scan(
        "/d/t.parquet", SOURCE_PARQUET, _schema("a", "b"),
        None, None, None, Optional(stats^),
    )


def _limit_over(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.limit(5, child^)


# ---------------------------------------------------------------------------
# Running a context and reading what it said
# ---------------------------------------------------------------------------


def _no_udfs() -> List[UdfRef]:
    return List[UdfRef]()


def _optimized_encode_error(p: LogicalPlan) raises -> String:
    try:
        _ = optimized_plan_to_bytes(p, _no_udfs())
    except e:
        return String(e)
    return String("")


def _optimized_decode_error(var wire_bytes: List[UInt8]) raises -> String:
    try:
        _ = optimized_plan_from_bytes(wire_bytes^, _no_udfs())
    except e:
        return String(e)
    return String("")


def _raw_encode_error(p: LogicalPlan) raises -> String:
    try:
        _ = plan_to_bytes(p)
    except e:
        return String(e)
    return String("")


def _raw_decode_error(var envelope: List[UInt8]) raises -> String:
    try:
        _ = plan_from_bytes(envelope^)
    except e:
        return String(e)
    return String("")


def _assert_refused(what: String, text: String, token: String, needle: String) raises:
    assert_true(text != "", what + ": not refused")
    assert_true(
        text.startswith(token), what + ": refused by another token: " + text
    )
    assert_true(needle in text, what + ": the text lacks '" + needle + "': " + text)


def _wire(p: LogicalPlan) raises -> WirePlan:
    return decode_proto[WirePlan](optimized_plan_to_bytes(p, _no_udfs()))


def _with_build_side_set(
    var w: WirePlan, side: Int, nested: Bool
) raises -> List[UInt8]:
    """The bytes of `w` with the build side of its root join, or of the
    join under it, set to `side`."""
    if nested:
        w.join[0].left[0].join[0].build_side = JoinBuildSide(side)
    else:
        w.join[0].build_side = JoinBuildSide(side)
    return encode_proto[WirePlan](w)


def _envelope_with_build_side(
    p: LogicalPlan, side: Int, nested: Bool
) raises -> List[UInt8]:
    """A RAW envelope for `p` (an undecided join), with the join's build side
    overwritten on the wire."""
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(p))
    var w = env.plan.value().copy()
    if nested:
        w.join[0].left[0].join[0].build_side = JoinBuildSide(side)
    else:
        w.join[0].build_side = JoinBuildSide(side)
    env.plan = Optional(w^)
    return encode_proto[WirePlanEnvelope](env)


def _optimized_round_trip(p: LogicalPlan) raises -> LogicalPlan:
    return optimized_plan_from_bytes(optimized_plan_to_bytes(p, _no_udfs()), _no_udfs())


# ---------------------------------------------------------------------------
# build_side
# ---------------------------------------------------------------------------


def test_optimized_round_trip_keeps_each_build_side() raises:
    var left = _optimized_round_trip(_join(JOIN_BUILD_SIDE_LEFT))
    assert_equal(Int(left.join_data_ref().build_side), Int(JOIN_BUILD_SIDE_LEFT))
    var right = _optimized_round_trip(_join(JOIN_BUILD_SIDE_RIGHT))
    assert_equal(Int(right.join_data_ref().build_side), Int(JOIN_BUILD_SIDE_RIGHT))
    assert_equal(_wire(_join(JOIN_BUILD_SIDE_LEFT)).join[0].build_side.number(), 1)
    assert_equal(_wire(_join(JOIN_BUILD_SIDE_RIGHT)).join[0].build_side.number(), 2)
    assert_equal(
        left.structural_hash(), _join(JOIN_BUILD_SIDE_LEFT).structural_hash()
    )


def test_every_join_of_a_plan_keeps_its_own_side() raises:
    var nested = _optimized_round_trip(
        _join_over_join(JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_RIGHT)
    )
    assert_equal(Int(nested.join_data_ref().build_side), Int(JOIN_BUILD_SIDE_LEFT))
    assert_equal(
        Int(nested.join_data_ref().left[].join_data_ref().build_side),
        Int(JOIN_BUILD_SIDE_RIGHT),
    )
    var w = _wire(_join_over_join(JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_RIGHT))
    assert_equal(w.join[0].build_side.number(), 1)
    assert_equal(w.join[0].left[0].join[0].build_side.number(), 2)

    var under = _optimized_round_trip(
        _aggregate_over_project_over_join(JOIN_BUILD_SIDE_RIGHT)
    )
    assert_equal(
        Int(
            under.aggregate_data_ref().child[].project_data_ref().child[]
            .join_data_ref().build_side
        ),
        Int(JOIN_BUILD_SIDE_RIGHT),
    )
    var uw = _wire(_aggregate_over_project_over_join(JOIN_BUILD_SIDE_RIGHT))
    assert_equal(
        uw.aggregate[0].child[0].project[0].child[0].join[0].build_side.number(), 2
    )


def test_optimized_encode_refuses_a_join_with_no_build_side() raises:
    var needle = "JoinData.build_side is UNSET"
    _assert_refused(
        "root", _optimized_encode_error(_join(JOIN_BUILD_SIDE_UNSET)),
        OPTIMIZED_JOIN_BUILD_SIDE_MISSING, needle,
    )
    _assert_refused(
        "child of a recorded join",
        _optimized_encode_error(
            _join_over_join(JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_UNSET)
        ),
        OPTIMIZED_JOIN_BUILD_SIDE_MISSING, needle,
    )
    _assert_refused(
        "under a project and an aggregate",
        _optimized_encode_error(
            _aggregate_over_project_over_join(JOIN_BUILD_SIDE_UNSET)
        ),
        OPTIMIZED_JOIN_BUILD_SIDE_MISSING, needle,
    )


def test_optimized_decode_refuses_an_unspecified_build_side() raises:
    var needle = "states no build_side"
    var root = _with_build_side_set(_wire(_join(JOIN_BUILD_SIDE_LEFT)), 0, False)
    _assert_refused(
        "root", _optimized_decode_error(root^),
        OPTIMIZED_JOIN_BUILD_SIDE_MISSING, needle,
    )
    var inner = _with_build_side_set(
        _wire(_join_over_join(JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_RIGHT)), 0, True
    )
    _assert_refused(
        "nested", _optimized_decode_error(inner^),
        OPTIMIZED_JOIN_BUILD_SIDE_MISSING, needle,
    )


def test_optimized_decode_refuses_a_build_side_the_vocabulary_does_not_declare() raises:
    var bytes = _with_build_side_set(_wire(_join(JOIN_BUILD_SIDE_LEFT)), 3, False)
    var text = _optimized_decode_error(bytes^)
    assert_true(text != "", "wire value 3 was admitted")
    assert_equal(text, "JoinBuildSide: wire value 3 is unknown to this reader")


def test_raw_encode_refuses_a_recorded_build_side_and_writes_none_otherwise() raises:
    var needle = "JoinData.build_side"
    _assert_refused(
        "LEFT", _raw_encode_error(_join(JOIN_BUILD_SIDE_LEFT)),
        PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION, needle,
    )
    _assert_refused(
        "RIGHT", _raw_encode_error(_join(JOIN_BUILD_SIDE_RIGHT)),
        PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION, needle,
    )
    _assert_refused(
        "nested",
        _raw_encode_error(_join_over_join(JOIN_BUILD_SIDE_UNSET, JOIN_BUILD_SIDE_RIGHT)),
        PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION, needle,
    )
    var undecided = _join(JOIN_BUILD_SIDE_UNSET)
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(undecided))
    assert_equal(env.plan.value().join[0].build_side.number(), 0)
    var back = plan_from_bytes(plan_to_bytes(undecided))
    assert_equal(Int(back.join_data_ref().build_side), Int(JOIN_BUILD_SIDE_UNSET))


def test_raw_decode_refuses_a_set_build_side() raises:
    var needle = "WireJoinNode.build_side"
    var sides: List[Int] = [1, 2, 3]
    for i in range(len(sides)):
        var side = sides[i]
        _assert_refused(
            "root " + String(side),
            _raw_decode_error(
                _envelope_with_build_side(_join(JOIN_BUILD_SIDE_UNSET), side, False)
            ),
            PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION, needle,
        )
        _assert_refused(
            "nested " + String(side),
            _raw_decode_error(
                _envelope_with_build_side(
                    _join_over_join(JOIN_BUILD_SIDE_UNSET, JOIN_BUILD_SIDE_UNSET),
                    side, True,
                )
            ),
            PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION, needle,
        )


# ---------------------------------------------------------------------------
# estimated_groups
# ---------------------------------------------------------------------------


def test_optimized_round_trip_keeps_estimated_groups() raises:
    var agg = _optimized_round_trip(_aggregate(42))
    assert_equal(agg.aggregate_data_ref().estimated_groups.value(), 42)
    var dist = _optimized_round_trip(_distinct(9))
    assert_equal(dist.distinct_data_ref().estimated_groups.value(), 9)
    var aw = _wire(_aggregate(42))
    assert_true(aw.aggregate[0].has_estimated_groups, "aggregate hint not written")
    assert_equal(Int(aw.aggregate[0].estimated_groups), 42)
    var dw = _wire(_distinct(9))
    assert_true(dw.distinct[0].has_estimated_groups, "distinct hint not written")
    assert_equal(Int(dw.distinct[0].estimated_groups), 9)

    var w = _wire(_aggregate(42))
    w.aggregate[0].estimated_groups = -1
    _assert_refused(
        "negative aggregate", _optimized_decode_error(encode_proto[WirePlan](w)),
        PLAN_WIRE_NEGATIVE_COUNT, "estimated_groups = -1",
    )
    var wd = _wire(_distinct(9))
    wd.distinct[0].estimated_groups = -4
    _assert_refused(
        "negative distinct", _optimized_decode_error(encode_proto[WirePlan](wd)),
        PLAN_WIRE_NEGATIVE_COUNT, "estimated_groups = -4",
    )


def test_raw_decode_still_refuses_estimated_groups() raises:
    _assert_refused(
        "aggregate", _raw_decode_error(plan_to_bytes(_aggregate(42))),
        PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS, "decoded WireAggregateNode",
    )
    _assert_refused(
        "distinct", _raw_decode_error(plan_to_bytes(_distinct(9))),
        PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS, "decoded WireDistinctNode",
    )


# ---------------------------------------------------------------------------
# scan statistics
# ---------------------------------------------------------------------------


def test_optimized_context_refuses_scan_statistics() raises:
    # A wire scan that carries row_count: the raw encoder writes it.
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(_scan_with_row_count()))
    var carried = encode_proto[WirePlan](env.plan.value())
    _assert_refused(
        "decode", _optimized_decode_error(carried^),
        OPTIMIZED_FIELD_UNSUPPORTED, "carries row_count",
    )
    _assert_refused(
        "encode row_count", _optimized_encode_error(_scan_with_row_count()),
        OPTIMIZED_FIELD_UNSUPPORTED, "ScanData.row_count for '/d/t.parquet'",
    )
    _assert_refused(
        "encode table_stats", _optimized_encode_error(_scan_with_table_stats()),
        OPTIMIZED_FIELD_UNSUPPORTED, "ScanData.table_stats for '/d/t.parquet'",
    )
    _assert_refused(
        "encode under a parent",
        _optimized_encode_error(_limit_over(_scan_with_row_count())),
        OPTIMIZED_FIELD_UNSUPPORTED, "ScanData.row_count",
    )
    assert_equal(
        _optimized_encode_error(_scan("/d/t.parquet", "a", "b")), String(""),
        "a scan with no statistic encodes",
    )


def test_raw_round_trip_still_admits_row_count() raises:
    var back = plan_from_bytes(plan_to_bytes(_scan_with_row_count()))
    assert_equal(back.scan_data_ref().row_count.value(), 12)


# ---------------------------------------------------------------------------
# The struct forms
# ---------------------------------------------------------------------------


def test_struct_forms_agree_with_the_bytes_forms() raises:
    var p = _aggregate_over_project_over_join(JOIN_BUILD_SIDE_LEFT)
    var from_bytes = optimized_plan_to_bytes(p, _no_udfs())
    var w = optimized_plan_to_wire(p, _no_udfs())
    assert_true(encode_proto[WirePlan](w) == from_bytes, "the bytes differ")
    var a = optimized_plan_from_wire(w, _no_udfs())
    var b = optimized_plan_from_bytes(from_bytes.copy(), _no_udfs())
    assert_equal(a.structural_hash(), b.structural_hash())
    assert_equal(a.structural_hash(), p.structural_hash())

    var refused_encode = String("")
    try:
        _ = optimized_plan_to_wire(_join(JOIN_BUILD_SIDE_UNSET), _no_udfs())
    except e:
        refused_encode = String(e)
    _assert_refused(
        "to_wire", refused_encode, OPTIMIZED_JOIN_BUILD_SIDE_MISSING,
        "JoinData.build_side is UNSET",
    )
    var unspecified = _wire(_join(JOIN_BUILD_SIDE_RIGHT))
    unspecified.join[0].build_side = JoinBuildSide(0)
    var refused_decode = String("")
    try:
        _ = optimized_plan_from_wire(unspecified, _no_udfs())
    except e:
        refused_decode = String(e)
    _assert_refused(
        "from_wire", refused_decode, OPTIMIZED_JOIN_BUILD_SIDE_MISSING,
        "states no build_side",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
