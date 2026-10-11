# =============================================================================
# test_plan_wire_vocabulary_names.mojo — the Mojo vocabulary, held to protoc.
# =============================================================================
#
# `plan_wire_vocabulary.mojo` and `komira_plan_proto/plan_vocabulary.proto`
# publish the same 32 enumerated spaces: one is what this package encodes and
# decodes with, the other is what every non-Mojo producer reads. The .proto's
# header says they are kept in step by hand. test_plan_wire_vocabulary.mojo
# holds the Mojo side to the ENGINE (counts, wire = engine + 1); nothing held
# it to the .proto, and most of its name ladders (`write_*_wire_name`, the
# names a non-Mojo frontend keys on) were never run by any test.
#
# THE ORACLE IS protoc, NOT THIS PACKAGE. `komira_plan_proto.plan_vocabulary`
# is generated at build time by protoc-gen-mojo from the .proto itself: each
# enum's `json_name()` returns the value NAME protoc declares, and for a
# number the .proto does not declare it returns the number as text. The
# vocabulary generator never saw that module, so agreement between the two is
# evidence, not a tautology.
#
# WHAT EACH TEST PROVES, AND THE DEFECT IT CATCHES:
#
#   test_every_name_agrees_with_protoc
#       Every space, every wire value from -3 to 260 and five far ones: the
#       dispatched name (`plan_wire_name`) equals the space's own wrapper
#       (`<space>_wire_name`), and equals protoc's name wherever the .proto
#       declares the number. Anywhere it does not, the name is the fallback
#       `<Space>#<n>`, except the four numbers of `_exempt` below.
#       Catches: a renamed or swapped arm in any ladder, a dispatcher arm
#       pointing at another space's ladder, a fallback that drops the number.
#
#   test_membership_agrees_with_protoc
#       Every space, every wire value 1 to 256: `plan_wire_from_wire` accepts
#       it exactly when the .proto declares it, decodes it to wire - 1, and
#       `plan_wire_to_wire` maps that back. A number in `_exempt` is declared
#       by the engine and refused in both directions as reserved. The member
#       count and highest engine value each space publishes are recomputed
#       from protoc's view plus `_exempt`, not read from the file under test.
#       Catches: a run boundary off by one in `*_is_declared`, a space that
#       accepts a number the .proto never named or reserves (or refuses one
#       it declares), a stale `plan_wire_space_member_count` /
#       `plan_wire_space_engine_max` row.
#
#   test_from_wire_refusals_say_why
#       The five refusals of every `*_from_wire` (negative, zero, past a
#       UInt8, undeclared, reserved), each with its full message, on every
#       space.
#       Catches: swapped or merged guards (a value above 256 reported as
#       merely unknown, a 0 reported as unknown, a negative value reported as
#       wire 0), a message naming another space or the wrong UNSPECIFIED name,
#       a reserved number decoded or reported as unknown.
#
#   test_to_wire_refuses_every_undeclared_engine_tag_by_name
#       Every engine value 0 to 255 a space does not declare: `*_to_wire`
#       refuses it with its message; every `_exempt` engine value: refused as
#       reserved.
#
#   test_space_names_are_the_proto_enum_names
#       `plan_wire_space_name` for all 32 spaces equals the enum's name in the
#       .proto (`_proto_types`, a ledger in .proto declaration order), and the
#       fallbacks for an index no space has.
#
#   test_bad_space_index_is_refused_by_every_dispatcher
#       -1 and 32 against all five raising dispatchers, by message, and the
#       name dispatcher's total fallback.
#
# `_exempt`: the .proto RESERVES ExprTag 11 and 12 (EXPR_BETWEEN,
# EXPR_SORT_KEY) and SourceVariantTag 1 and 2 (SOURCE_VARIANT_PARQUET,
# SOURCE_VARIANT_IN_MEMORY) as "declared by the engine, deliberately NOT on the
# wire". The Mojo vocabulary declares and names all four, because the engine
# does, and refuses them in both directions as reserved. The ledger keeps the
# set from growing silently; a tag that leaves the engine, or gets a wire
# number back, removes its row here.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_proto.plan_vocabulary import (
    AggFn,
    ArrowType,
    AsofDirection,
    AsofToleranceKind,
    BinaryOp,
    ColSide,
    CorrelatedKind,
    ExprTag,
    ExtractField,
    FrameBound,
    FrameUnits,
    JoinAlgo,
    JoinType,
    MathFn1,
    MathFn2,
    ParamTag,
    PlanTag,
    PushdownGateMode,
    RegexpOp,
    ScalarKind,
    ScalarTimeUnit,
    SnapshotPolicy,
    SourceOrientation,
    SourceType,
    SourceVariantTag,
    StringFn,
    StringFnN,
    StringOp,
    UnaryOp,
    WindowFn,
    WriteCompression,
    WriteFormat,
)
from komira_plan_wire.plan_wire_vocabulary import (
    PLAN_WIRE_SPACE_COUNT,
    PLAN_WIRE_VOCABULARY_MEMBERS,
    plan_wire_space_name,
    plan_wire_space_member_count,
    plan_wire_space_engine_max,
    plan_wire_is_declared,
    plan_wire_to_wire,
    plan_wire_from_wire,
    plan_wire_name,
    plan_tag_wire_name,
    expr_tag_wire_name,
    agg_fn_wire_name,
    window_fn_wire_name,
    frame_units_wire_name,
    frame_bound_wire_name,
    join_type_wire_name,
    join_algo_wire_name,
    asof_direction_wire_name,
    asof_tolerance_kind_wire_name,
    correlated_kind_wire_name,
    source_type_wire_name,
    source_orientation_wire_name,
    source_variant_tag_wire_name,
    binary_op_wire_name,
    unary_op_wire_name,
    string_op_wire_name,
    string_fn_wire_name,
    string_fn_n_wire_name,
    col_side_wire_name,
    math_fn1_wire_name,
    math_fn2_wire_name,
    extract_field_wire_name,
    regexp_op_wire_name,
    arrow_type_wire_name,
    write_format_wire_name,
    write_compression_wire_name,
    scalar_kind_wire_name,
    scalar_time_unit_wire_name,
    param_tag_wire_name,
    pushdown_gate_mode_wire_name,
    snapshot_policy_wire_name,
)


# ---------------------------------------------------------------------------
# protoc's view: the generated enum of each space, in .proto declaration order
# (the vocabulary's space index order).
# ---------------------------------------------------------------------------


def _proto_name(space: Int, w: Int) -> String:
    """protoc's name for wire `w` of `space`; the number as text if undeclared."""
    if space == 0:
        return PlanTag(w).json_name()
    if space == 1:
        return ExprTag(w).json_name()
    if space == 2:
        return AggFn(w).json_name()
    if space == 3:
        return WindowFn(w).json_name()
    if space == 4:
        return FrameUnits(w).json_name()
    if space == 5:
        return FrameBound(w).json_name()
    if space == 6:
        return JoinType(w).json_name()
    if space == 7:
        return JoinAlgo(w).json_name()
    if space == 8:
        return AsofDirection(w).json_name()
    if space == 9:
        return AsofToleranceKind(w).json_name()
    if space == 10:
        return CorrelatedKind(w).json_name()
    if space == 11:
        return SourceType(w).json_name()
    if space == 12:
        return SourceOrientation(w).json_name()
    if space == 13:
        return SourceVariantTag(w).json_name()
    if space == 14:
        return BinaryOp(w).json_name()
    if space == 15:
        return UnaryOp(w).json_name()
    if space == 16:
        return StringOp(w).json_name()
    if space == 17:
        return StringFn(w).json_name()
    if space == 18:
        return StringFnN(w).json_name()
    if space == 19:
        return ColSide(w).json_name()
    if space == 20:
        return MathFn1(w).json_name()
    if space == 21:
        return MathFn2(w).json_name()
    if space == 22:
        return ExtractField(w).json_name()
    if space == 23:
        return RegexpOp(w).json_name()
    if space == 24:
        return ArrowType(w).json_name()
    if space == 25:
        return WriteFormat(w).json_name()
    if space == 26:
        return WriteCompression(w).json_name()
    if space == 27:
        return ScalarKind(w).json_name()
    if space == 28:
        return ScalarTimeUnit(w).json_name()
    if space == 29:
        return ParamTag(w).json_name()
    if space == 30:
        return PushdownGateMode(w).json_name()
    if space == 31:
        return SnapshotPolicy(w).json_name()
    return "no proto enum for space " + String(space)


def _proto_declares(space: Int, w: Int) -> Bool:
    return _proto_name(space, w) != String(w)


# The enum names of plan_vocabulary.proto, in declaration order (DTypeCode,
# the 33rd, is the codec's own and is not a vocabulary space).
def _proto_types() -> List[String]:
    return [
        "PlanTag",
        "ExprTag",
        "AggFn",
        "WindowFn",
        "FrameUnits",
        "FrameBound",
        "JoinType",
        "JoinAlgo",
        "AsofDirection",
        "AsofToleranceKind",
        "CorrelatedKind",
        "SourceType",
        "SourceOrientation",
        "SourceVariantTag",
        "BinaryOp",
        "UnaryOp",
        "StringOp",
        "StringFn",
        "StringFnN",
        "ColSide",
        "MathFn1",
        "MathFn2",
        "ExtractField",
        "RegexpOp",
        "ArrowType",
        "WriteFormat",
        "WriteCompression",
        "ScalarKind",
        "ScalarTimeUnit",
        "ParamTag",
        "PushdownGateMode",
        "SnapshotPolicy",
    ]


# Numbers the .proto reserves and the Mojo vocabulary declares:
# "<Space> <wire> <Mojo name>". See the header.
def _exempt() -> List[String]:
    return [
        "ExprTag 11 EXPR_BETWEEN",
        "ExprTag 12 EXPR_SORT_KEY",
        "SourceVariantTag 1 SOURCE_VARIANT_PARQUET",
        "SourceVariantTag 2 SOURCE_VARIANT_IN_MEMORY",
    ]


def _reserved_from_wire(space_name: String, w: Int, name: String) -> String:
    return (
        space_name + ": wire value " + String(w) + " (" + name
        + ") is reserved: plan_vocabulary.proto keeps it off the wire"
    )


def _reserved_to_wire(space_name: String, t: Int, name: String) -> String:
    return (
        space_name + ": engine tag " + String(t) + " (" + name
        + ") is reserved on the wire: plan_vocabulary.proto keeps it off"
    )


def _exempt_name(space: Int, w: Int) -> String:
    """The Mojo name `_exempt` gives (space, w), or empty."""
    var prefix = _proto_types()[space] + " " + String(w) + " "
    var rows = _exempt()
    for i in range(len(rows)):
        if rows[i].startswith(prefix):
            return String(rows[i][byte = prefix.byte_length() :])
    return String()


# ---------------------------------------------------------------------------
# The file under test, by space: each space's own String wrapper.
# ---------------------------------------------------------------------------


def _direct_name(space: Int, w: Int32) -> String:
    if space == 0:
        return plan_tag_wire_name(w)
    if space == 1:
        return expr_tag_wire_name(w)
    if space == 2:
        return agg_fn_wire_name(w)
    if space == 3:
        return window_fn_wire_name(w)
    if space == 4:
        return frame_units_wire_name(w)
    if space == 5:
        return frame_bound_wire_name(w)
    if space == 6:
        return join_type_wire_name(w)
    if space == 7:
        return join_algo_wire_name(w)
    if space == 8:
        return asof_direction_wire_name(w)
    if space == 9:
        return asof_tolerance_kind_wire_name(w)
    if space == 10:
        return correlated_kind_wire_name(w)
    if space == 11:
        return source_type_wire_name(w)
    if space == 12:
        return source_orientation_wire_name(w)
    if space == 13:
        return source_variant_tag_wire_name(w)
    if space == 14:
        return binary_op_wire_name(w)
    if space == 15:
        return unary_op_wire_name(w)
    if space == 16:
        return string_op_wire_name(w)
    if space == 17:
        return string_fn_wire_name(w)
    if space == 18:
        return string_fn_n_wire_name(w)
    if space == 19:
        return col_side_wire_name(w)
    if space == 20:
        return math_fn1_wire_name(w)
    if space == 21:
        return math_fn2_wire_name(w)
    if space == 22:
        return extract_field_wire_name(w)
    if space == 23:
        return regexp_op_wire_name(w)
    if space == 24:
        return arrow_type_wire_name(w)
    if space == 25:
        return write_format_wire_name(w)
    if space == 26:
        return write_compression_wire_name(w)
    if space == 27:
        return scalar_kind_wire_name(w)
    if space == 28:
        return scalar_time_unit_wire_name(w)
    if space == 29:
        return param_tag_wire_name(w)
    if space == 30:
        return pushdown_gate_mode_wire_name(w)
    if space == 31:
        return snapshot_policy_wire_name(w)
    return "no wrapper for space " + String(space)


def _sweep() -> List[Int]:
    """-3 to 260, then five far values on both sides of the Int32 range."""
    var ws = List[Int]()
    for w in range(-3, 261):
        ws.append(w)
    ws.append(1000)
    ws.append(65537)
    ws.append(100000)
    ws.append(2147483647)
    ws.append(-2147483648)
    return ws^


def _from_wire_error(space: Int, w: Int32) -> String:
    """The message `plan_wire_from_wire` raises, or empty when it accepts."""
    try:
        _ = plan_wire_from_wire(space, w)
    except e:
        return String(e)
    return String()


def _to_wire_error(space: Int, t: UInt8) -> String:
    try:
        _ = plan_wire_to_wire(space, t)
    except e:
        return String(e)
    return String()


# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------


def test_every_name_agrees_with_protoc() raises:
    var exempt_seen = 0
    var checked = 0
    var ws = _sweep()
    for space in range(PLAN_WIRE_SPACE_COUNT):
        var space_name = plan_wire_space_name(space)
        for i in range(len(ws)):
            var w = ws[i]
            var mojo = plan_wire_name(space, Int32(w))
            var where = space_name + " wire " + String(w)
            assert_equal(
                _direct_name(space, Int32(w)),
                mojo,
                where + ": the space's own wrapper and the dispatcher disagree",
            )
            var exempt = _exempt_name(space, w)
            if _proto_declares(space, w):
                assert_equal(mojo, _proto_name(space, w), where + ": protoc's name")
            elif exempt.byte_length() > 0:
                exempt_seen += 1
                assert_equal(mojo, exempt, where + ": the _exempt ledger's name")
            else:
                assert_equal(
                    mojo,
                    space_name + "#" + String(w),
                    where + ": the .proto declares no such number",
                )
            checked += 1
    assert_equal(exempt_seen, len(_exempt()), "every _exempt row met")
    assert_equal(checked, PLAN_WIRE_SPACE_COUNT * 269, "the sweep ran in full")


def test_space_names_are_the_proto_enum_names() raises:
    var types = _proto_types()
    assert_equal(len(types), PLAN_WIRE_SPACE_COUNT)
    for space in range(PLAN_WIRE_SPACE_COUNT):
        assert_equal(
            plan_wire_space_name(space),
            types[space],
            "space " + String(space),
        )
    assert_equal(plan_wire_space_name(32), "PlanWireSpace#32")
    assert_equal(plan_wire_space_name(-1), "PlanWireSpace#-1")


# ---------------------------------------------------------------------------
# Membership
# ---------------------------------------------------------------------------


def test_membership_agrees_with_protoc() raises:
    var total = 0
    for space in range(PLAN_WIRE_SPACE_COUNT):
        var space_name = plan_wire_space_name(space)
        var members = 0
        var top = -1
        for w in range(1, 257):
            var where = space_name + " wire " + String(w)
            var exempt = _exempt_name(space, w)
            var err = _from_wire_error(space, Int32(w))
            var t = UInt8(w - 1)
            if exempt.byte_length() > 0:
                assert_equal(
                    err,
                    _reserved_from_wire(space_name, w, exempt),
                    where + ": reserved, so refused",
                )
                assert_true(plan_wire_is_declared(space, t), where + ": declared")
                assert_equal(
                    _to_wire_error(space, t),
                    _reserved_to_wire(space_name, w - 1, exempt),
                    where + ": reserved, so not encoded",
                )
                members += 1
                top = w - 1
            elif _proto_declares(space, w):
                assert_equal(err, String(), where + ": must decode")
                assert_equal(
                    Int(plan_wire_from_wire(space, Int32(w))),
                    w - 1,
                    where + ": engine value is wire - 1",
                )
                assert_true(plan_wire_is_declared(space, t), where + ": declared")
                assert_equal(
                    Int(plan_wire_to_wire(space, t)), w, where + ": encodes back"
                )
                members += 1
                top = w - 1
            else:
                assert_true(err.byte_length() > 0, where + ": the .proto names no such value")
                assert_true(
                    not plan_wire_is_declared(space, t), where + ": not declared"
                )
        assert_equal(
            plan_wire_space_member_count(space), members, space_name + ": members"
        )
        assert_equal(
            Int(plan_wire_space_engine_max(space)), top, space_name + ": engine max"
        )
        total += members
    assert_equal(total, PLAN_WIRE_VOCABULARY_MEMBERS, "every member, every space")


def test_from_wire_refusals_say_why() raises:
    var ws = _sweep()
    var refused_reserved = 0
    for space in range(PLAN_WIRE_SPACE_COUNT):
        var space_name = plan_wire_space_name(space)
        var unspecified = space_name + ": wire 0 is " + _proto_name(space, 0)
        unspecified += " — an absent proto3 enum field is not a tag"
        var refused_unknown = 0
        for i in range(len(ws)):
            var w = ws[i]
            var err = _from_wire_error(space, Int32(w))
            var where = space_name + " wire " + String(w)
            if w < 0:
                assert_equal(
                    err,
                    space_name
                    + ": wire value "
                    + String(w)
                    + " is negative; no "
                    + space_name
                    + " value has a negative wire number",
                    where,
                )
            elif w == 0:
                assert_equal(err, unspecified, where)
            elif w > 256:
                assert_equal(
                    err,
                    space_name
                    + ": wire value "
                    + String(w)
                    + " is out of range for a UInt8 engine tag",
                    where,
                )
            elif not plan_wire_is_declared(space, UInt8(w - 1)):
                refused_unknown += 1
                assert_equal(
                    err,
                    space_name
                    + ": wire value "
                    + String(w)
                    + " is unknown to this reader",
                    where,
                )
            elif _exempt_name(space, w).byte_length() > 0:
                refused_reserved += 1
                assert_equal(
                    err,
                    _reserved_from_wire(space_name, w, _exempt_name(space, w)),
                    where,
                )
            else:
                assert_equal(err, String(), where)
        # Every space leaves some wire value in 1..256 undeclared, so the third
        # refusal ran in each.
        assert_equal(
            refused_unknown,
            256 - plan_wire_space_member_count(space),
            space_name + ": undeclared values in 1..256",
        )
    assert_equal(refused_reserved, len(_exempt()), "every _exempt row refused")


def test_to_wire_refuses_every_undeclared_engine_tag_by_name() raises:
    var refused = 0
    var reserved = 0
    for space in range(PLAN_WIRE_SPACE_COUNT):
        var space_name = plan_wire_space_name(space)
        for i in range(256):
            var t = UInt8(i)
            var err = _to_wire_error(space, t)
            var exempt = _exempt_name(space, i + 1)
            if exempt.byte_length() > 0:
                reserved += 1
                assert_equal(
                    err,
                    _reserved_to_wire(space_name, i, exempt),
                    space_name + " engine " + String(i),
                )
            elif plan_wire_is_declared(space, t):
                assert_equal(err, String(), space_name + " engine " + String(i))
            else:
                refused += 1
                assert_equal(
                    err,
                    space_name
                    + ": engine tag "
                    + String(i)
                    + " is not in the plan wire vocabulary",
                )
    assert_equal(
        refused,
        PLAN_WIRE_SPACE_COUNT * 256 - PLAN_WIRE_VOCABULARY_MEMBERS,
        "every undeclared engine value refused",
    )
    assert_equal(reserved, len(_exempt()), "every _exempt row refused")


# ---------------------------------------------------------------------------
# A space index no space has
# ---------------------------------------------------------------------------


def _space_error(which: Int, space: Int) -> String:
    try:
        if which == 0:
            _ = plan_wire_space_member_count(space)
        elif which == 1:
            _ = plan_wire_space_engine_max(space)
        elif which == 2:
            _ = plan_wire_is_declared(space, 0)
        elif which == 3:
            _ = plan_wire_to_wire(space, 0)
        else:
            _ = plan_wire_from_wire(space, 1)
    except e:
        return String(e)
    return String()


def test_bad_space_index_is_refused_by_every_dispatcher() raises:
    var bad: List[Int] = [-1, PLAN_WIRE_SPACE_COUNT, 1000]
    for i in range(len(bad)):
        var space = bad[i]
        for which in range(5):
            assert_equal(
                _space_error(which, space),
                "plan wire: no such space index " + String(space),
                "dispatcher " + String(which) + ", space " + String(space),
            )
        assert_equal(
            plan_wire_name(space, 7),
            "PlanWireSpace#" + String(space) + "/7",
            "the name dispatcher is total",
        )
    # Space 31, the last arm of every dispatcher, is a real space: the index
    # past it is the first refused one, not 31 itself.
    assert_equal(_space_error(0, PLAN_WIRE_SPACE_COUNT - 1), String())


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_name_agrees_with_protoc]()
    suite.test[test_space_names_are_the_proto_enum_names]()
    suite.test[test_membership_agrees_with_protoc]()
    suite.test[test_from_wire_refusals_say_why]()
    suite.test[test_to_wire_refuses_every_undeclared_engine_tag_by_name]()
    suite.test[test_bad_space_index_is_refused_by_every_dispatcher]()
    suite^.run()
