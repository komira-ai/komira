# =============================================================================
# test_physical_plan_ir_version_door — THE FALSIFIER for the version door
# =============================================================================
#
# `assert_physical_plan_ir_version_compatible` checks the `ir_version` field
# every `SegmentDescPod` carries against this build's
# `PHYSICAL_PLAN_IR_VERSION`. This file is the falsifier for that door.
#
# ⛔ WHAT GOES RED WITHOUT THE DOOR. Every refusal case here calls the door and
# requires it to RAISE. Against a no-op body — one that only asserts
# `PHYSICAL_PLAN_IR_VERSION >= 1` — every one of them returns normally and this
# file fails. Against a `SegmentDescPod` with no `ir_version` field it does not
# even compile.
#
# ⚠ AND THE POSITIVE CONTROL IS NOT DECORATION. A door that refused
# EVERYTHING would pass all four refusal cases while breaking every query;
# `test_door_accepts_a_correctly_stamped_plan` is what tells those two apart.
#
# What this file does NOT prove: that the CUTTER stamps the field, and that
# the segment cutter still CALLS the door. The stamp is asserted by the
# cutter's own tests. ⛔ THE CALL ITSELF IS PROVEN BY NO TEST: producer and
# consumer are one binary at one IR revision, so no in-process test can inject
# a version a cut did not mint, and deleting the call leaves every test green.
# The door earns its keep once the optimizer and the engine ship as separate
# `.so`s.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_collections.slab import Slab
from komira_physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    PHYSICAL_PLAN_IR_VERSION,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_BATCH,
    SegmentDescPod,
    SourceSpecPod,
    assert_physical_plan_ir_version_compatible,
)


# ---------------------------------------------------------------------------
# Fixtures. The SHAPE is irrelevant to the door — only `ir_version` is read —
# so the leaf collect segment is used throughout and the version is the ONE
# thing that varies between cases.
# ---------------------------------------------------------------------------
def _seg(seg_id: Int) raises -> SegmentDescPod:
    """A leaf collect segment stamped by the ctor DEFAULT (i.e. exactly what a
    producer compiled against THIS revision emits)."""
    return SegmentDescPod(
        seg_id=seg_id,
        source_kind=SOURCE_BATCH,
        source_spec=SourceSpecPod.batch(-1),
        ops=Slab[MorselOp](),
        sink_kind=SINK_COLLECT,
        sink_key_dtype=KEY_DTYPE_NONE,
        sink_orientation=SINK_ORIENT_COLUMNAR,
        sink_param_id=seg_id,
        sink_state_id=seg_id,
        deps=List[Int](),
        edge_tags=List[UInt8](),
    )


def _seg_at_version(seg_id: Int, version: Int) raises -> SegmentDescPod:
    """The same segment, stamped EXPLICITLY — the in-process stand-in for a pod
    minted by a `.so` built against a different revision of physical_plan.mojo.
    In production nothing passes this argument; the ctor default does."""
    return SegmentDescPod(
        seg_id=seg_id,
        source_kind=SOURCE_BATCH,
        source_spec=SourceSpecPod.batch(-1),
        ops=Slab[MorselOp](),
        sink_kind=SINK_COLLECT,
        sink_key_dtype=KEY_DTYPE_NONE,
        sink_orientation=SINK_ORIENT_COLUMNAR,
        sink_param_id=seg_id,
        sink_state_id=seg_id,
        deps=List[Int](),
        edge_tags=List[UInt8](),
        ir_version=version,
    )


def _refusal_message(var segs: List[SegmentDescPod]) -> String:
    """Call the door and RETURN what it refused with; empty string = it did not
    refuse. Returning the message (rather than a Bool) is what lets each case
    assert the refusal is the one it meant to provoke — a door that raised for
    some other reason would otherwise read as a pass."""
    try:
        assert_physical_plan_ir_version_compatible(segs)
    except e:
        return String(e)
    return String("")


# ---------------------------------------------------------------------------
# THE POSITIVE CONTROL.
# ---------------------------------------------------------------------------
def test_default_stamp_is_the_current_ir_version() raises:
    """The ctor DEFAULT stamps `PHYSICAL_PLAN_IR_VERSION`. This is the whole
    mechanism: a pod minted by a `.so` built at IR vN carries N with no
    producer-side code, so a consumer built at vM can tell.

    Goes red if the default is dropped, or wired to a literal that stops
    tracking the constant."""
    var s = _seg(0)
    assert_equal(
        s.ir_version,
        PHYSICAL_PLAN_IR_VERSION,
        "ctor default must stamp PHYSICAL_PLAN_IR_VERSION",
    )
    _ = s^


def test_door_accepts_a_correctly_stamped_plan() raises:
    """POSITIVE CONTROL. Without this, a door that refused EVERYTHING would
    satisfy all four refusal cases below while breaking every query."""
    var segs = List[SegmentDescPod]()
    segs.append(_seg(0))
    segs.append(_seg(1))
    segs.append(_seg(2))
    var msg = _refusal_message(segs^)
    assert_equal(msg, String(""), "a correctly stamped plan must be ACCEPTED")


# ---------------------------------------------------------------------------
# THE REFUSALS.
# ---------------------------------------------------------------------------
def test_door_refuses_an_older_ir_version_by_name() raises:
    """A pod emitted at v(N-1) — the shape a stale `komira_optimizer.so` mints.
    REFUSED, and the message must NAME the failure, the segment and BOTH
    versions: a bare raise leaves an operator staring at a struct-layout skew
    with nothing to search for."""
    var segs = List[SegmentDescPod]()
    segs.append(_seg_at_version(0, PHYSICAL_PLAN_IR_VERSION - 1))
    var msg = _refusal_message(segs^)
    assert_false(
        msg == String(""), "an older IR version must be REFUSED, not accepted"
    )
    assert_true(
        String("PHYSICAL_PLAN_IR_VERSION_MISMATCH") in msg,
        "the refusal must name PHYSICAL_PLAN_IR_VERSION_MISMATCH; got: " + msg,
    )
    assert_true(
        String("seg_id=0") in msg, "the refusal must name the segment; got: " + msg
    )
    assert_true(
        (String("v") + String(PHYSICAL_PLAN_IR_VERSION - 1)) in msg,
        "the refusal must report the version SEEN; got: " + msg,
    )
    assert_true(
        (String("v") + String(PHYSICAL_PLAN_IR_VERSION)) in msg,
        "the refusal must report the version EXPECTED; got: " + msg,
    )


def test_door_refuses_a_newer_ir_version() raises:
    """Skew is refused in BOTH directions. A `>=` comparison would pass a plan
    from a NEWER optimizer whose struct has grown a field — a layout
    disagreement that corrupts allocator state with no diagnostic."""
    var segs = List[SegmentDescPod]()
    segs.append(_seg_at_version(0, PHYSICAL_PLAN_IR_VERSION + 1))
    var msg = _refusal_message(segs^)
    assert_true(
        String("PHYSICAL_PLAN_IR_VERSION_MISMATCH") in msg,
        "a NEWER IR version must be refused too; got: " + msg,
    )


def test_door_checks_every_segment_not_just_the_first() raises:
    """THE LOOP IS LOAD-BEARING. Segments 0 and 1 are correct; segment 2 is
    skewed. A door that read `segments[0]` — the obvious 'simplification' — is
    green on this fixture and blind to a plan whose build side came from the
    stale `.so`.

    Goes red the moment the loop is replaced by a single read."""
    var segs = List[SegmentDescPod]()
    segs.append(_seg(0))
    segs.append(_seg(1))
    segs.append(_seg_at_version(2, PHYSICAL_PLAN_IR_VERSION - 1))
    var msg = _refusal_message(segs^)
    assert_true(
        String("PHYSICAL_PLAN_IR_VERSION_MISMATCH") in msg,
        "a skew on a NON-FIRST segment must be refused; got: " + msg,
    )
    assert_true(
        String("seg_id=2") in msg,
        "the refusal must name the OFFENDING segment, not the first; got: " + msg,
    )


def test_door_refuses_an_empty_plan_rather_than_passing_it() raises:
    """AN EMPTY PLAN IS NOT CHECKABLE AND IS NOT A PASS. Zero segments means
    nothing was compared, and a door that returns OK there is
    indistinguishable from a door that was never called — the vacuous-gate
    failure class.

    Goes red if the loop is left to iterate zero times and return."""
    var segs = List[SegmentDescPod]()
    var msg = _refusal_message(segs^)
    assert_true(
        String("PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE") in msg,
        "an empty plan must be a REFUSAL, not a vacuous pass; got: " + msg,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_default_stamp_is_the_current_ir_version]()
    suite.test[test_door_accepts_a_correctly_stamped_plan]()
    suite.test[test_door_refuses_an_older_ir_version_by_name]()
    suite.test[test_door_refuses_a_newer_ir_version]()
    suite.test[test_door_checks_every_segment_not_just_the_first]()
    suite.test[test_door_refuses_an_empty_plan_rather_than_passing_it]()
    suite^.run()
