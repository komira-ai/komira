# =============================================================================
# test_plan_wire_udf_tier.mojo — THE TWO-TIER UDF SEAM, BOTH SIDES.
# =============================================================================
#
# A codec that refused EVERY UDF-carrying node would make "a plan with a live
# UDF is refused at the wire" true VACUOUSLY — no test could tell a working
# tier from a blanket refusal. This file is what makes the claim falsifiable:
#
#     DESCRIBABLE  -> CROSSES, losslessly, MINUS the handle.
#     LIVE CLOSURE -> REFUSED, by name, on BOTH encode and decode.
#
# ⚠ A TEST THAT ONLY SHOWED THE REFUSAL WOULD PASS AGAINST A BLANKET REFUSAL.
# Every refusal assertion here is therefore paired with a crossing assertion
# over the SAME shape, and the two differ in exactly one field: the name.
#
# ★ THE HANDLE IS THE POINT OF THE MINUS. `registered_handle_id` is a
# slot+generation into a `UdfRegistry` that exists in ONE process. A LOW SLOT AT
# GENERATION 0 EXISTS IN ALMOST ANY REGISTRY, so a carried handle would not
# merely be stale — it would PLAUSIBLY RESOLVE, to a different function. That is
# why `test_the_handle_does_not_cross` asserts absence rather than equality: an
# equal handle on both sides would be the bug, not the property.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
    UDF_NULL_PROPAGATE,
    UDF_NULL_SKIP_NULL_FAST_PATH,
    UDF_STABILITY_VOLATILE,
    UDF_PAR_PARTITION_LOCAL,
)
from komira_plan_wire import plan_to_bytes, plan_from_bytes
from komira_plan_wire.plan_wire_codec import (
    PLAN_WIRE_UDF_NOT_DESCRIBABLE,
    PLAN_WIRE_UNSUPPORTED_UDF,
)
from komira_proto_codec import encode_proto, decode_proto
from komira_plan_proto.plan import WirePlanEnvelope


def _scan() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    var schema = sb.build()
    return LogicalPlan.scan(
        String("/nonexistent/udf_tier.parquet"),
        0,  # SOURCE_PARQUET
        schema^,
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )


def _udf(var name: String, handle: Optional[Int]) -> UdfData:
    """A MAP UdfData exercising every axis `WireUdf` carries — two input
    columns, one output, non-default null / stability / parallelism tags, and
    non-empty partition and order keys. A field dropped on the wire shows up as
    a render diff in `test_a_describable_udf_crosses_losslessly`; a field
    carried but MISREAD shows up there too, because the render is the hash."""
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("a", UInt8(2)))
    ic.append(("b", UInt8(4)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(4)))
    var pk = List[String]()
    pk.append("a")
    var ok = List[String]()
    ok.append("b")
    return UdfData(
        kind=UDF_KIND_MAP,
        name=name^,
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(9301),
        call_site_salt=UInt32(77),
        null_mode=UDF_NULL_SKIP_NULL_FAST_PATH,
        stability=UDF_STABILITY_VOLATILE,
        parallelism_tag=UDF_PAR_PARTITION_LOCAL,
        partition_keys=pk^,
        order_keys=ok^,
        has_vector_path=True,
        registered_handle_id=handle,
    )


def _project_with(var udf: UdfData) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    return LogicalPlan.project_with_udf(
        exprs^, _scan(), OwnedPointer[UdfData](udf^)
    )


def _filter_with(var udf: UdfData) raises -> LogicalPlan:
    return LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        OwnedPointer[UdfData](udf^),
    )


# --- 1. ★ THE CROSSING HALF. Without this the refusal proves nothing. -------


def test_a_describable_udf_crosses_losslessly() raises:
    """A NAMED UDF survives plan -> bytes -> plan' byte-for-byte in the render,
    which IS plan identity (`LogicalPlan.structural_hash` is FNV-1a over it)."""
    var plan = _project_with(_udf(String("margin"), None))
    var text = String(plan)
    var h = plan.structural_hash()

    assert_true(
        "udf<MAP>" in text,
        "the fixture does not actually carry a UDF — the round trip below"
        + " would then prove nothing about UDFs at all",
    )

    var bytes = plan_to_bytes(plan)
    assert_true(
        len(bytes) > 0,
        "the encoder produced ZERO bytes; a codec that encoded nothing and"
        + " decoded a default plan could otherwise satisfy both legs",
    )
    var back = plan_from_bytes(bytes^)

    assert_true(
        back.has_udf(),
        "the decoded plan LOST its UDF. The node decoded as an ordinary"
        + " Project, whose `exprs` are the PLACEHOLDER the UDF path stamps —"
        + " so it would have executed the placeholder and returned wrong rows.",
    )
    assert_equal(
        String(back),
        text,
        "the decoded plan RENDERS DIFFERENTLY. Every field the render emits is"
        + " part of plan identity; this diff names the one that did not survive.",
    )
    assert_equal(
        String(back.structural_hash()),
        String(h),
        "text is equal but structural_hash is not — the render has stopped"
        + " being the sole input to plan identity",
    )


def test_a_describable_filter_udf_crosses_too() raises:
    """The three carriers are three separate encode arms and three separate
    decode arms. Project passing says nothing about Filter."""
    var u = _udf(String("cheap"), None)
    var uf = UdfData(
        kind=UDF_KIND_FILTER,
        name=String("cheap"),
        input_columns=u.input_columns.copy(),
        output_columns=u.output_columns.copy(),
        operator_factory_id=UInt32(7001),
        call_site_salt=UInt32(3),
    )
    var plan = _filter_with(uf^)
    var text = String(plan)
    var bytes = plan_to_bytes(plan)
    var back = plan_from_bytes(bytes^)
    assert_true(back.has_udf(), "the decoded FILTER plan lost its UDF")
    assert_equal(String(back), text, "FILTER carrier render diverged")


# --- 2. ★★ THE HANDLE DOES NOT CROSS ----------------------------------------


def test_the_handle_does_not_cross() raises:
    """★ ABSENCE, not equality, is the property.

    A handle is a slot+generation into a registry that exists in ONE process.
    Carrying it would let the decoded plan name a slot in a registry that never
    existed — and name it PLAUSIBLY, because a low slot at generation 0 exists
    in almost any registry. The decoded UDF must come back UNBOUND, exactly as
    a decoded `ScanBinding` does."""
    var plan = _project_with(_udf(String("margin"), Optional(Int(3))))
    assert_true(
        "registered_handle_id" in String(plan),
        "VACUOUS: the fixture does not carry a handle, so this test cannot"
        + " observe whether one crosses",
    )

    var bytes = plan_to_bytes(plan)
    var back = plan_from_bytes(bytes^)

    assert_true(back.has_udf(), "the decoded plan lost its UDF entirely")
    assert_false(
        "registered_handle_id" in String(back),
        "★ THE HANDLE CROSSED THE WIRE. The decoded plan names a slot in a"
        + " registry that does not exist on this side, and slot 3 generation 0"
        + " exists in almost any registry — so it would resolve, to a"
        + " DIFFERENT function, rather than fail.",
    )

    # ...and the rest of the description is intact: same plan, no handle.
    var unbound = _project_with(_udf(String("margin"), None))
    assert_equal(
        String(back),
        String(unbound),
        "the decoded plan differs from the same plan built WITHOUT a handle,"
        + " so something other than the handle was dropped or added",
    )


# --- 3. ★★ THE REFUSAL HALF, ENCODE ----------------------------------------


def test_a_live_closure_udf_is_refused_at_encode() raises:
    """The SAME shape as test 1, differing in ONE field: the name is empty.

    ⚠ THAT SINGLE-FIELD DIFFERENCE IS WHAT MAKES THIS TEST MEAN ANYTHING. A
    refusal test whose fixture differs from the crossing fixture in several
    ways cannot say which difference caused the refusal."""
    var plan = _project_with(_udf(String(""), None))
    var refused = False
    try:
        var b = plan_to_bytes(plan)
        _ = b
    except e:
        refused = True
        assert_true(
            PLAN_WIRE_UDF_NOT_DESCRIBABLE in String(e),
            "refused with the WRONG token — a frontend author branching on it"
            + " would be told to give up rather than to name the function: "
            + String(e),
        )
        assert_false(
            String(e).startswith(PLAN_WIRE_UNSUPPORTED_UDF),
            "refused with the BLANKET token. That is the pre-`WireUdf`"
            + " behaviour, and it would mean the tier is not working.",
        )
    assert_true(
        refused,
        "★ A LIVE-CLOSURE UDF WAS ENCODED. The peer has no name to resolve, so"
        + " the plan would decode cleanly and then be unable to run — strictly"
        + " worse than a refusal.",
    )


# --- 4. ★★ THE REFUSAL HALF, DECODE ----------------------------------------


def test_a_nameless_udf_is_refused_at_decode_too() raises:
    """★ THE DECODER DOES NOT GET TO ASSUME THE ENCODER WAS OURS.

    A language-agnostic format is BY DEFINITION parsed from bytes some other
    program produced, so the encode-side refusal in test 3 is not a decode-side
    guarantee. This forges the exact message a foreign producer would emit —
    a `WireUdf` with an empty `name` — by decoding a GOOD one, blanking the
    field, and re-encoding.

    ⚠ It asserts the tampered bytes DIFFER from the good ones first. A tamper
    that produced byte-identical output would make the rest of this vacuous."""
    var good = plan_to_bytes(_project_with(_udf(String("margin"), None)))
    var env = decode_proto[WirePlanEnvelope](good.copy())
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    var plan = env.plan.value().copy()
    if not plan.project:
        raise Error("fixture: the plan root is not a PROJECT")
    var node = plan.project[0].copy()
    if not node.has_udf or not node.udf:
        raise Error(
            "fixture: the encoded PROJECT carries no UDF, so blanking its name"
            + " below tampers with nothing"
        )
    var u = node.udf.value().copy()
    assert_true(
        u.name.byte_length() > 0,
        "fixture: the encoded UDF already has an empty name, so this test"
        + " tampers with nothing and is vacuous",
    )
    u.name = String("")
    node.udf = Optional(u^)
    # RECURSION BOX: the plan->project edge is SINGULAR. Replace slot 0, never
    # `append` — an appended copy lands where the encoder never looks and the
    # tamper silently does nothing.
    plan.project[0] = node^
    env.plan = Optional(plan^)
    var bad = encode_proto[WirePlanEnvelope](env)
    assert_true(
        bad != good,
        "the tamper produced BYTE-IDENTICAL output. The message shape moved"
        + " and this test is no longer testing what it says it is.",
    )

    var refused = False
    try:
        var back = plan_from_bytes(bad^)
        _ = back^
    except e:
        refused = True
        assert_true(
            PLAN_WIRE_UDF_NOT_DESCRIBABLE in String(e),
            "the decoder refused with the WRONG token: " + String(e),
        )
    assert_true(
        refused,
        "★ A NAMELESS UDF DECODED. It would have become a `UdfData` nothing"
        + " can resolve — indistinguishable downstream from a live closure"
        + " this process minted, and unrunnable.",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_describable_udf_crosses_losslessly]()
    suite.test[test_a_describable_filter_udf_crosses_too]()
    suite.test[test_the_handle_does_not_cross]()
    suite.test[test_a_live_closure_udf_is_refused_at_encode]()
    suite.test[test_a_nameless_udf_is_refused_at_decode_too]()
    suite^.run()
