# =============================================================================
# test_plan_wire_optimizer_decisions.mojo — the recorded optimizer decisions
# on a LogicalPlan do not cross the wire silently.
# =============================================================================
#
# `JoinData.build_side`, `JoinData.adaptive_allowed`, `AggregateData.mode` and
# `ScanData.boundedness` have no `plan.proto` field yet, and a PLAN_EXCHANGE
# node has no message arm. Encoding any of them as if it were absent would
# decode as the default: a join that builds on the right, a single aggregate,
# a bounded scan, no exchange — a smaller plan than the one built, with
# nothing raised. So each is refused by name, and a node holding the default
# still encodes and round-trips (the control: a refusal that fired on the
# default would be a codec that refuses every join).
#
# Mutants: delete any one refusal in `_plan_to_wire`; the matching test sees
# bytes where it expects `PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
    AGG_MODE_SINGLE,
    AGG_MODE_PARTIAL,
    AGG_MODE_FINAL,
    AGG_MODE_UNSET,
    SCAN_UNBOUNDED,
    EXCHANGE_KIND_GATHER,
)

from komira_plan_wire import plan_to_bytes, plan_from_bytes
from komira_plan_wire.plan_wire_codec import (
    PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION,
)


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.FLOAT64, True))
    return sb.build()


def _scan(path: String, a: String, b: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _join(build_side: UInt8, adaptive: Bool) -> LogicalPlan:
    var lo: List[String] = ["a"]
    var ro: List[String] = ["c"]
    return LogicalPlan.join(
        _scan("/d/l.parquet", "a", "b"), _scan("/d/r.parquet", "c", "d"),
        lo^, ro^, JOIN_INNER, JOIN_ALGO_AUTO, None, build_side, adaptive,
    )


def _agg(mode: UInt8) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("t"))))
    return LogicalPlan.aggregate(gb^, ax^, _scan("/d/t.parquet", "a", "b"), mode)


def _encode_error(p: LogicalPlan) raises -> String:
    try:
        _ = plan_to_bytes(p)
    except e:
        return String(e)
    return String("")


def _assert_refused(what: String, p: LogicalPlan, field: String) raises:
    var text = _encode_error(p)
    assert_true(text != "", what + ": encoded to bytes")
    assert_true(
        text.startswith(PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION),
        what + ": refused by another token: " + text,
    )
    assert_true(field in text, what + ": does not name " + field + ": " + text)


def _assert_round_trips(what: String, p: LogicalPlan) raises:
    var back = plan_from_bytes(plan_to_bytes(p))
    assert_equal(back.structural_hash(), p.structural_hash(), what)


def test_a_recorded_build_side_is_refused_either_way() raises:
    """LEFT and RIGHT are both decisions; neither may decode as UNSET."""
    _assert_refused("LEFT", _join(JOIN_BUILD_SIDE_LEFT, False), "JoinData.build_side")
    _assert_refused("RIGHT", _join(JOIN_BUILD_SIDE_RIGHT, False), "JoinData.build_side")


def test_adaptive_allowed_is_refused() raises:
    _assert_refused(
        "adaptive", _join(JOIN_BUILD_SIDE_UNSET, True), "JoinData.adaptive_allowed"
    )


def test_an_undecided_join_still_round_trips() raises:
    """The control: UNSET and not adaptive encode as every join did."""
    _assert_round_trips("undecided join", _join(JOIN_BUILD_SIDE_UNSET, False))


def test_every_recorded_aggregate_mode_is_refused() raises:
    var modes: List[UInt8] = [AGG_MODE_SINGLE, AGG_MODE_PARTIAL, AGG_MODE_FINAL]
    for i in range(len(modes)):
        _assert_refused(
            "mode " + String(Int(modes[i])), _agg(modes[i]), "AggregateData.mode"
        )
    _assert_round_trips("undecided aggregate", _agg(AGG_MODE_UNSET))


def test_an_unbounded_scan_is_refused() raises:
    var src = _scan("/d/t.parquet", "a", "b").scan_data_ref().source.copy()
    var s = LogicalPlan.scan_from_source(
        src^, _schema("a", "b"), boundedness=SCAN_UNBOUNDED
    )
    _assert_refused("unbounded scan", s, "ScanData.boundedness")
    _assert_round_trips("bounded scan", _scan("/d/t.parquet", "a", "b"))


def test_a_decision_below_the_root_is_refused() raises:
    """The refusal is per node, so the walk reaches it under a parent."""
    var f = LogicalPlan.filter(Expr.col_ref("a"), _join(JOIN_BUILD_SIDE_LEFT, False))
    _assert_refused("join under a filter", f, "JoinData.build_side")


def test_an_exchange_node_does_not_encode() raises:
    """No `exchange` arm exists and the vocabulary reserves wire 19, so the
    encode raises and names the tag."""
    var e = LogicalPlan.exchange(_scan("/d/t.parquet", "a", "b"), EXCHANGE_KIND_GATHER)
    var text = _encode_error(e)
    assert_true(text != "", "an exchange encoded to bytes")
    assert_true("engine tag 18" in text, text)
    assert_true("PLAN_EXCHANGE" in text, text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
