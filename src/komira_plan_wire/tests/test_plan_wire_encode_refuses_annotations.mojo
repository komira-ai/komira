# =============================================================================
# test_plan_wire_encode_refuses_annotations.mojo — the two IR fields
# `plan.proto` has no slot for: `ScanData.payload_narrow` and
# `AggregateData.group_topk`.
# =============================================================================
#
# Each is stamped onto a plan by a later stage (the compressed-materialization
# rule, the TopN root) by direct field assignment, so a plan a caller hands to
# `plan_to_bytes` can carry either. The wire cannot, so the encoder must:
#
#   REFUSE BY NAME   a non-empty `payload_narrow` / a set `group_topk`, with the
#                    `PLAN_WIRE_UNSUPPORTED_*` token and the field's name in
#                    the text. Without the refusal the encoder returns bytes
#                    and the decoded plan has the field empty: a different
#                    plan from the one encoded, with no error anywhere.
#   CARRY            the empty list and the unset hint, which are the only
#                    values the decoder produces. The plan round-trips and the
#                    decoded fields are read back.
#
# The refusals are checked both on the root node and on a node below it, so a
# refusal placed only on the root arm (or only on a recursive path) is caught.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr
from komira_plan_expr.payload_narrow import (
    PayloadNarrowSpec,
    PAYLOAD_NARROW_2B,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AggGroupTopK,
    SOURCE_PARQUET,
)

from komira_plan_wire import (
    plan_to_bytes,
    plan_from_bytes,
    PLAN_WIRE_UNSUPPORTED_PAYLOAD_NARROW,
    PLAN_WIRE_UNSUPPORTED_GROUP_TOPK,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan(String("/data/t.parquet"), SOURCE_PARQUET, _schema())


def _narrowed_scan() raises -> LogicalPlan:
    """A scan as the narrowing rule leaves it: one spec, stamped by field."""
    var p = _scan()
    var specs = List[PayloadNarrowSpec]()
    specs.append(PayloadNarrowSpec(String("b"), PAYLOAD_NARROW_2B, Int64(100)))
    p._scan.value()[].payload_narrow = specs^
    return p^


def _aggregate(var child: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("a")))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_SUM, Optional(Expr.col_ref(String("b"))), Optional(String("s")))
    )
    return LogicalPlan.aggregate(gb^, ax^, child^)


def _topk_aggregate() raises -> LogicalPlan:
    """An aggregate as a TopN root leaves it: the hint stamped by field."""
    var p = _aggregate(_scan())
    var order = List[String]()
    order.append(String("s"))
    var desc = List[Bool]()
    desc.append(True)
    p._aggregate.value()[].group_topk = Optional(
        AggGroupTopK(order^, desc^, 7)
    )
    return p^


def _assert_encode_refused(
    what: String, p: LogicalPlan, token: String, field: String
) raises:
    var text = String("")
    try:
        _ = plan_to_bytes(p)
    except e:
        text = String(e)
    assert_true(
        text != "",
        what + ": plan_to_bytes returned bytes. The wire has no slot for `"
        + field + "`, so the decoded plan would silently lose it.",
    )
    assert_true(
        text.startswith(token),
        what + ": refused, but not by " + token + ". Got: " + text,
    )
    assert_true(
        field in text,
        what + ": the refusal does not name `" + field + "`. Got: " + text,
    )


# =============================================================================
# Refused
# =============================================================================


def test_a_scan_with_payload_narrow_is_refused_at_encode() raises:
    _assert_encode_refused(
        String("scan root"), _narrowed_scan(),
        PLAN_WIRE_UNSUPPORTED_PAYLOAD_NARROW, String("ScanData.payload_narrow"),
    )


def test_payload_narrow_below_an_aggregate_is_refused_at_encode() raises:
    _assert_encode_refused(
        String("scan under an aggregate"), _aggregate(_narrowed_scan()),
        PLAN_WIRE_UNSUPPORTED_PAYLOAD_NARROW, String("ScanData.payload_narrow"),
    )


def test_an_aggregate_with_group_topk_is_refused_at_encode() raises:
    _assert_encode_refused(
        String("aggregate root"), _topk_aggregate(),
        PLAN_WIRE_UNSUPPORTED_GROUP_TOPK, String("AggregateData.group_topk"),
    )


def test_group_topk_below_a_limit_is_refused_at_encode() raises:
    _assert_encode_refused(
        String("aggregate under a limit"),
        LogicalPlan.limit(7, _topk_aggregate()),
        PLAN_WIRE_UNSUPPORTED_GROUP_TOPK, String("AggregateData.group_topk"),
    )


# =============================================================================
# Carried: the empty list and the unset hint
# =============================================================================


def test_a_scan_with_no_payload_narrow_round_trips() raises:
    var plan = _scan()
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())
    assert_equal(len(back.scan_data_ref().payload_narrow), 0)


def test_an_aggregate_with_no_group_topk_round_trips() raises:
    var plan = _aggregate(_scan())
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())
    assert_false(
        Bool(back.aggregate_data_ref().group_topk),
        "the decoder invented a group_topk hint",
    )
    assert_equal(
        len(back.aggregate_data_ref().child[].scan_data_ref().payload_narrow), 0
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
