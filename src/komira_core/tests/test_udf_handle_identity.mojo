# =============================================================================
# test_udf_handle_identity.mojo — the plan-cache half of the UDF ABA hazard
# =============================================================================
#
# `UdfRegistry`'s own generation check closes the RESOLUTION half of the ABA
# hazard (`komira_engine_operators`' registry ABA test). This closes
# the half you cannot see from the registry: **the plan-compile cache key.**
#
# ⚠⚠ THE RENDER IS THE HASH. `LogicalPlan.structural_hash` is an FNV-1a fold of
# `write_to`'s TEXT — its own docstring says "THERE IS NO SECOND SOURCE OF
# IDENTITY", and a field missing from the render causes a collision that can be
# a silent WRONG ANSWER, not a perf miss.
#
# `UdfData.write_to` renders `registered_handle_id`. So with a BARE SLOT INDEX:
#
#     register A -> node renders `registered_handle_id=3`
#     A evicted, B re-mints slot 3
#     register B -> node renders `registered_handle_id=3`   <- IDENTICAL TEXT
#
# ...and the plan-compile cache hands back **A's compiled plan for a query that
# now means B**. The generation in the handle is what makes the two texts
# differ. Every assertion below is a guard on that.
#
# ⚠ AND THE CONVERSE IS DELIBERATE. Rendering a process-local value makes the
# same logical plan hash differently across processes / re-mints, which costs
# cache MISSES. That is the correct trade: a miss is a performance bug, a false
# hit is a wrong answer.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.logical_plan import LogicalPlan, ExprArray
from komira_core.plan.expr import Expr
from komira_core.plan.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_IMMUTABLE,
    UDF_PAR_STATELESS,
)


# The registry's packing, restated here ON PURPOSE rather than imported.
# `komira_core` is a LOWER layer than `komira_engine_operators`, so it cannot
# import `udf_registry`. Restating it means a divergence between the two shows
# up as a failing assertion below instead of as a silent mis-decode — and the
# constants are a wire-shape fact, not an implementation detail.
comptime _SLOT_BITS: Int = 31


def _handle(slot: Int, generation: Int) -> Int:
    return slot | (generation << _SLOT_BITS)


def _udf(name: String, handle: Optional[Int]) -> UdfData:
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("a", UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    return UdfData(
        kind=UDF_KIND_MAP,
        name=name,
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(9301),
        call_site_salt=UInt32(1),
        null_mode=UDF_NULL_PROPAGATE,
        stability=UDF_STABILITY_IMMUTABLE,
        parallelism_tag=UDF_PAR_STATELESS,
        registered_handle_id=handle,
    )


def _plan_with(var udf: UdfData) raises -> LogicalPlan:
    """A Project-with-UDF over a dummy scan. The path is never opened — this
    file only exercises the plan-IR render and its hash."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.INT64, True))
    var schema = sb.build()
    var child = LogicalPlan.scan(
        String("/nonexistent/test_udf_handle_identity.parquet"),
        0,  # SOURCE_PARQUET
        schema^,
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    return LogicalPlan.project_with_udf(
        exprs^, child^, OwnedPointer[UdfData](udf^)
    )


# --- 1. ★ THE FALSIFIER: same slot, different generation, different hash -----


def test_same_slot_different_generation_does_not_collide() raises:
    # Slot 3 twice — the exact re-mint the registry performs after an eviction.
    var a = _plan_with(_udf("scale", Optional(_handle(3, 0))))
    var b = _plan_with(_udf("scale", Optional(_handle(3, 1))))

    # ⚠ ANTI-VACUITY. The two nodes must be identical in EVERY other axis, or a
    # difference elsewhere would be doing the work and this would prove nothing
    # about the generation. `name`, columns, factory id and salt are all equal
    # by construction in `_udf`; assert the slots really are the same one.
    assert_equal(
        Int(3),
        _handle(3, 0) & ((1 << _SLOT_BITS) - 1),
        "VACUOUS: arm A does not name slot 3",
    )
    assert_equal(
        Int(3),
        _handle(3, 1) & ((1 << _SLOT_BITS) - 1),
        "VACUOUS: arm B does not name slot 3 — the two arms do not share a"
        + " slot, so this test says nothing about ABA",
    )

    if String(a) == String(b):
        raise Error(
            "FAIL: two DIFFERENT registered UDFs sharing slot 3 render"
            + " IDENTICALLY. The plan-compile cache would return the first"
            + " plan's compiled form for the second query."
        )
    if a.structural_hash() == b.structural_hash():
        raise Error(
            "FAIL: same structural_hash for two different registered UDFs on"
            + " one slot — the plan-compile cache key collides."
        )
    print("    PASS test_same_slot_different_generation_does_not_collide")


# --- 2. the handle IS in the render, deliberately ---------------------------


def test_handle_participates_in_the_render() raises:
    var unregistered = _plan_with(_udf("scale", None))
    var registered = _plan_with(_udf("scale", Optional(_handle(3, 0))))

    # Suppressed when None, so every pre-existing plan's render text is
    # byte-unchanged by this field ever having existed.
    if "registered_handle_id" in String(unregistered):
        raise Error(
            "FAIL: an UNREGISTERED UdfData rendered the handle field. Every"
            + " existing plan's render text would change."
        )
    if "registered_handle_id" not in String(registered):
        raise Error(
            "FAIL: the handle is NOT in the render. It must be — see the"
            + " header: not rendering it is a FALSE CACHE HIT, which is a"
            + " wrong answer, where rendering it is only a cache miss."
        )
    if unregistered.structural_hash() == registered.structural_hash():
        raise Error(
            "FAIL: registering a UDF did not change the plan hash, so a plan"
            + " compiled BEFORE registration would be reused after it."
        )
    print("    PASS test_handle_participates_in_the_render")


# --- 3. the handle needs more than 32 bits, which is why it is an Int -------


def test_handle_is_wider_than_a_uint32() raises:
    # A generation-carrying handle at any generation >= 2 exceeds UInt32 for a
    # nonzero slot, so `Optional[UInt32]` could not have held it. This is the
    # assertion that fails first if anyone narrows the field back.
    var h = _handle(1, 2)
    if h <= Int(0xFFFFFFFF):
        raise Error(
            "FAIL: the packed handle fits in 32 bits at generation 2, so the"
            + " slot/generation split is not what this file assumes."
        )
    var p = _plan_with(_udf("scale", Optional(h)))
    if String(h) not in String(p):
        raise Error(
            "FAIL: a >32-bit handle did not survive into the render intact —"
            + " it was truncated somewhere, which re-aliases two generations."
        )
    # And bit 63 is never written, so a handle is never negative.
    if _handle((1 << 31) - 1, Int(0xFFFFFFFF)) < 0:
        raise Error("FAIL: a maximal handle came out negative")
    print("    PASS test_handle_is_wider_than_a_uint32")


# --- 4. describability is derived from the NAME -----------------------------


def test_is_describable_is_derived_from_the_name() raises:
    var named = _udf("scale", Optional(_handle(3, 0)))
    if not named.is_describable():
        raise Error("FAIL: a named UDF is not describable")

    # A live closure: no resolvable name. It must be refused at the wire, and
    # `is_describable` is what the codec keys on.
    var closure = _udf("", Optional(_handle(4, 0)))
    if closure.is_describable():
        raise Error(
            "FAIL: a live-closure UDF reports DESCRIBABLE. The peer has no"
            + " name to resolve, so it cannot re-mint a handle for it."
        )
    # ⚠ And describability must NOT be readable off the handle: a live closure
    # has a perfectly good handle. Handle-ness and describability are different
    # questions, and conflating them is how a closure reaches the wire.
    if not closure.has_registered_handle():
        raise Error(
            "FAIL: the closure UDF has no handle, so this test cannot show"
            + " that a HANDLE does not imply DESCRIBABILITY."
        )
    print("    PASS test_is_describable_is_derived_from_the_name")


def main() raises:
    print("Running UDF handle identity tests...")
    test_same_slot_different_generation_does_not_collide()
    test_handle_participates_in_the_render()
    test_handle_is_wider_than_a_uint32()
    test_is_describable_is_derived_from_the_name()
    print("All UDF handle identity tests passed (4/4)")
