# =============================================================================
# test_plan_wire_unnest.mojo — PLAN_UNNEST on the wire.
# =============================================================================
#
# `WireUnnestNode` (plan.proto field 23, arm 19) carries the child, the list
# column's name and `keep_empty`. The decoder rebuilds the node through
# `LogicalPlan.unnest`, so the column is resolved against the decoded child,
# and the output schema the wire carries is held to the one that derives.
#
# A reader that does not know the arm sees a WirePlan with no arm it knows:
# `test_a_plan_with_only_an_unknown_arm_is_refused` is how an older reader
# treats the new node.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_ir.logical_plan import LogicalPlan, PLAN_UNNEST, SOURCE_PARQUET
from plan_wire import (
    PLAN_WIRE_FORMAT_VERSION,
    PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
    plan_from_bytes,
    plan_to_bytes,
)
from plan_wire.plan_wire_vocabulary import plan_tag_from_wire, plan_tag_to_wire
from proto_codec import decode_proto, encode_proto
from plan_proto.plan import WirePlan, WirePlanEnvelope


def _scan() raises -> LogicalPlan:
    """(id: INT64 not null, tags: LIST<STRING>, n: FLOAT64 nullable)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field.list_of_string("tags", True, item_nullable=False))
    sb.add_field(Field("n", ArrowType.FLOAT64, True))
    return LogicalPlan.scan("/d/t.parquet", SOURCE_PARQUET, sb.build())


def _env(p: LogicalPlan) raises -> WirePlanEnvelope:
    return decode_proto[WirePlanEnvelope](plan_to_bytes(p))


def _refusal(var env: WirePlanEnvelope) -> String:
    try:
        _ = plan_from_bytes(encode_proto[WirePlanEnvelope](env^))
    except e:
        return String(e)
    return String("")


def _round_trips(keep_empty: Bool) raises:
    var p = LogicalPlan.unnest(_scan(), "tags", keep_empty)
    var back = plan_from_bytes(plan_to_bytes(p))
    assert_equal(Int(back.tag), Int(PLAN_UNNEST))
    assert_equal(back.structural_hash(), p.structural_hash())
    assert_equal(String(back), String(p))
    assert_equal(back.unnest_data_ref().column, "tags")
    assert_equal(back.unnest_data_ref().keep_empty, keep_empty)
    assert_equal(back.output_schema.num_columns(), 3)
    assert_true(back.output_schema.field_arrow_type(1) == ArrowType.STRING)
    assert_equal(back.output_schema.field_nullable(1), keep_empty)


def test_an_unnest_plan_round_trips_with_keep_empty_false() raises:
    _round_trips(False)


def test_an_unnest_plan_round_trips_with_keep_empty_true() raises:
    _round_trips(True)


def test_the_two_keep_empty_values_encode_to_different_bytes() raises:
    var drop = plan_to_bytes(LogicalPlan.unnest(_scan(), "tags", False))
    var keep = plan_to_bytes(LogicalPlan.unnest(_scan(), "tags", True))
    assert_true(drop != keep)


def test_the_node_is_arm_19_and_wire_tag_22() raises:
    var env = _env(LogicalPlan.unnest(_scan(), "tags", True))
    var w = env.plan.value().copy()
    assert_equal(w._oneof0_case, 19)
    assert_equal(len(w.unnest), 1)
    assert_equal(w.unnest[0].column, "tags")
    assert_true(w.unnest[0].keep_empty)
    assert_equal(Int(plan_tag_to_wire(PLAN_UNNEST)), 22)
    assert_equal(Int(plan_tag_from_wire(Int32(22))), Int(PLAN_UNNEST))


def test_a_non_list_column_on_the_wire_is_refused_by_name() raises:
    var env = _env(LogicalPlan.unnest(_scan(), "tags", False))
    var w = env.plan.value().copy()
    w.unnest[0].column = "id"
    env.plan = Optional(w^)
    var text = _refusal(env^)
    assert_true(
        "unnest: column 'id' is " + String(ArrowType.INT64) + ", not a list" in text,
        text,
    )


def test_an_unknown_column_on_the_wire_is_refused_by_name() raises:
    var env = _env(LogicalPlan.unnest(_scan(), "tags", False))
    var w = env.plan.value().copy()
    w.unnest[0].column = "nope"
    env.plan = Optional(w^)
    var text = _refusal(env^)
    assert_true("unnest: no column 'nope' in its input" in text, text)


def test_an_unnest_with_no_child_is_refused() raises:
    var env = _env(LogicalPlan.unnest(_scan(), "tags", False))
    var w = env.plan.value().copy()
    w.unnest[0].child = List[WirePlan]()
    env.plan = Optional(w^)
    var text = _refusal(env^)
    assert_true("WireUnnestNode.child carries 0 children" in text, text)


def test_an_output_schema_that_is_not_the_derived_one_is_refused() raises:
    var env = _env(LogicalPlan.unnest(_scan(), "tags", False))
    var w = env.plan.value().copy()
    var sch = w.output_schema.value().copy()
    # The element column is not nullable when keep_empty is False; the wire
    # claims it is.
    var f = sch.fields[1].copy()
    f.nullable = True
    sch.fields[1] = f^
    w.output_schema = Optional(sch^)
    env.plan = Optional(w^)
    var text = _refusal(env^)
    assert_true(text.startswith(PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED), text)


def test_a_plan_with_only_an_unknown_arm_is_refused() raises:
    """A WirePlan whose only field is number 24, which no arm declares, has
    no node arm this reader knows; it is refused rather than guessed at."""
    var bytes = List[UInt8]()
    bytes.append(UInt8(0x08))  # WirePlanEnvelope.format_version
    bytes.append(UInt8(PLAN_WIRE_FORMAT_VERSION))
    bytes.append(UInt8(0x12))  # WirePlanEnvelope.plan, length-delimited
    bytes.append(UInt8(3))
    bytes.append(UInt8(0xC2))  # field 24, wire type 2 (length-delimited)
    bytes.append(UInt8(0x01))
    bytes.append(UInt8(0))  # empty payload
    var text = String("")
    try:
        _ = plan_from_bytes(bytes^)
    except e:
        text = String(e)
    assert_true("NO `node` arm set" in text, text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
