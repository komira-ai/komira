# =============================================================================
# test_plan_wire_vocabulary.mojo — the plan wire vocabulary, DRIVEN.
# =============================================================================
#
# The vocabulary generator's `--check` mode is the drift gate: it proves the
# committed `.proto` and `.mojo` are what the engine's tag declarations derive
# to. It is a TEXT comparison, and it cannot answer two questions that decide
# whether the vocabulary is usable:
#
#   1. Does the generated Mojo COMPILE AND RUN? A generated library that
#      compiles green and cannot be instantiated is not hypothetical: generated
#      protobuf Mojo can package cleanly and still fail with "struct has
#      recursive reference to itself" the moment a driver CONSTRUCTS the types.
#      A build is not proof that generated code is usable.
#
#   2. Is the vocabulary COMPLETE against the engine's OWN count constants?
#      The Python gate derives both sides from the same parse, so it cannot
#      catch a parser that is systematically wrong. This file imports
#      `PLAN_TAG_COUNT` and `EXPR_TAG_COUNT` — the engine's own numbers,
#      written by hand next to the tags — and asserts the wire vocabulary
#      publishes exactly that many. Two independent oracles, the second being
#      the engine itself.
#
# THIS IS A DRIVE, NOT A PIN, AND IT IS SELF-WIDENING. The loops below walk
# `range(PLAN_WIRE_SPACE_COUNT)` × `range(0, 256)` — EVERY space × EVERY value
# a `UInt8` tag field can hold. A space added to the generator tomorrow is
# driven by this file with no edit here. That matters: a hand-listed set of
# spaces is precisely the enumeration whose omissions are the bug the whole
# generator exists to prevent, and writing one in the test would reintroduce it
# in the one place nobody looks.
#
# WHY WIRE 0 RAISING IS THE LOAD-BEARING CASE. proto3 cannot distinguish an
# absent enum field from an explicit zero, and engine tag 0 is a REAL tag in
# every one of these spaces (PLAN_SCAN, EXPR_COL_REF, AGG_SUM, JOIN_INNER, ...).
# Without the +1 wire offset, a plan message with a MISSING tag field would
# decode as a valid plan node — a silent wrong plan, which is the failure the
# format exists to prevent. The offset is only worth anything if the reader
# refuses 0, so that refusal is asserted in every space, not once.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_ir.logical_plan import PLAN_TAG_COUNT
from komira_plan_expr.expr import EXPR_TAG_COUNT
from komira_plan_wire.plan_wire_vocabulary import (
    PLAN_WIRE_SPACE_COUNT,
    PLAN_WIRE_VOCABULARY_MEMBERS,
    PLAN_TAG_WIRE_MEMBERS,
    PLAN_TAG_ENGINE_MAX,
    EXPR_TAG_WIRE_MEMBERS,
    EXPR_TAG_ENGINE_MAX,
    AGG_FN_WIRE_MEMBERS,
    ARROW_TYPE_WIRE_MEMBERS,
    JOIN_TYPE_WIRE_MEMBERS,
    SOURCE_VARIANT_TAG_WIRE_MEMBERS,
    PLAN_WIRE_SPACE_PLAN_TAG,
    PLAN_WIRE_SPACE_EXPR_TAG,
    PLAN_WIRE_SPACE_JOIN_TYPE,
    PLAN_WIRE_SPACE_WINDOW_FN,
    PLAN_WIRE_SPACE_BINARY_OP,
    PLAN_WIRE_SPACE_UNARY_OP,
    PLAN_WIRE_SPACE_EXTRACT_FIELD,
    PLAN_WIRE_SPACE_SOURCE_ORIENTATION,
    plan_wire_space_name,
    plan_wire_space_member_count,
    plan_wire_space_engine_max,
    plan_wire_is_declared,
    plan_wire_to_wire,
    plan_wire_from_wire,
    plan_wire_name,
    plan_tag_wire_name,
    expr_tag_wire_name,
    join_type_wire_name,
    binary_op_wire_name,
    window_fn_wire_name,
    source_orientation_to_wire,
    source_orientation_from_wire,
    source_orientation_is_declared,
)


# ---------------------------------------------------------------------------
# COMPLETENESS — against the ENGINE's own count constants, which the generator
# never wrote. This is the second, independent oracle.
# ---------------------------------------------------------------------------


def test_plan_tag_vocabulary_is_complete_against_engine_count() raises:
    """`PLAN_TAG_COUNT` is written by hand beside the tags in logical_plan.mojo.

    If someone adds a plan tag and does not regenerate, this goes RED even
    if the text drift check were bypassed entirely.
    """
    assert_equal(
        PLAN_TAG_WIRE_MEMBERS,
        PLAN_TAG_COUNT,
        "the wire vocabulary must publish exactly PLAN_TAG_COUNT plan tags",
    )
    assert_equal(
        Int(PLAN_TAG_ENGINE_MAX),
        PLAN_TAG_COUNT - 1,
        (
            "the highest published plan tag must be PLAN_TAG_COUNT - 1. A gap"
            " here means a tag exists in no declaration site the generator"
            " reads (PLAN_* is declared in logical_plan.mojo)"
        ),
    )


def test_expr_tag_vocabulary_is_complete_against_engine_count() raises:
    assert_equal(
        EXPR_TAG_WIRE_MEMBERS,
        EXPR_TAG_COUNT,
        "the wire vocabulary must publish exactly EXPR_TAG_COUNT expr tags",
    )
    assert_equal(
        Int(EXPR_TAG_ENGINE_MAX),
        EXPR_TAG_COUNT - 1,
        "the highest published expr tag must be EXPR_TAG_COUNT - 1",
    )


def test_countless_space_totals_are_pinned() raises:
    """A pin, and labelled as one.

    `AGG_*`, `JOIN_*` and `SOURCE_VARIANT_*` have NO count constant in the
    engine, which is a drift hazard.
    For those spaces the only in-Mojo tripwire available is a total, so here it
    is. Adding a member to any of them turns this red and says which.
    """
    # ⚠ THIS PIN CANNOT SEE THE FAILURE THAT MATTERS, AND SAYING SO IS HALF ITS
    # VALUE. `PLAN_WIRE_SPACE_COUNT` is `len(SPACES)` — the size of the
    # REGISTERED set. It fires when a registered space is REMOVED, and never for
    # a vocabulary that was never registered, which is the only way a wire
    # vocabulary actually goes missing (a discriminator such as
    # `SCALAR_KIND_*` on `WireScalar.kind` is the dangerous case: an
    # unregistered one is narrowed by the decoder with no check at all). Seeing
    # that needs a coverage check over the codec's import closure, not a total.
    #
    # HOW THE TOTAL MOVES:
    #   * A new member of an existing op space (`StringFn`, `UnaryOp`,
    #     `ExtractField`, `AGG_*`, ...) moves the total by its member count and
    #     leaves the SPACE COUNT unchanged.
    #   * A new expr VARIANT whose payload is `{op, child}` / `{op, args}` is a
    #     member of TWO vocabularies: the `ExprTag` space grows by one AND a new
    #     op space arrives, so the total moves by (ops + 1) and the space count
    #     by one. A change that moved only one of the two would mean an expr tag
    #     with no payload space, or a payload space no tag reaches.
    #   * A new expr variant whose payload is all VALUES (e.g. `EXPR_UDF_CALL`:
    #     a name, a handle, two `ArrowType`s and a child) joins the `ExprTag`
    #     space only. Moving the space count too would mean an invented enum.
    #   * These spaces count ENGINE OPS / TAGS, not SQL spellings: an alias
    #     (`to_hex` for `hex`, `fsum` / `sumkahan` for `kahan_sum`) shares its
    #     op and adds nothing.
    #
    # ⚠ THE NUMBER IS DERIVED, NOT GUESSED: it is the generated
    # `plan_wire_vocabulary.mojo`'s own published constant. A change that adds
    # a member regenerates that file AND moves this literal in the same change,
    # or this library's build goes red. If this line collides in a merge,
    # ⛔ DO NOT PICK A SIDE — both sides' numbers are wrong; re-run the
    # generator over the MERGED sources and read the constant.
    assert_equal(PLAN_WIRE_VOCABULARY_MEMBERS, 352, "total published members")
    assert_equal(AGG_FN_WIRE_MEMBERS, 37, "AGG_* has no engine count constant")
    assert_equal(PLAN_WIRE_SPACE_COUNT, 32, "enumerated tag spaces")
    # ArrowType has no engine count constant either, and it is the space LEG 2
    # of the round trip compares. Its members are declared in a shape a
    # module-level regex matches zero of — `    comptime NULL = ArrowType(0)`:
    # indented, inside the struct body, no type annotation, a ctor call rather
    # than a literal — so the space is registered explicitly.
    assert_equal(
        ARROW_TYPE_WIRE_MEMBERS, 50, "ArrowType has no engine count constant"
    )
    assert_equal(JOIN_TYPE_WIRE_MEMBERS, 7, "JOIN_* has no engine count constant")
    assert_equal(
        SOURCE_VARIANT_TAG_WIRE_MEMBERS,
        10,
        "SOURCE_VARIANT_* has no engine count constant",
    )


# ---------------------------------------------------------------------------
# THE DRIVE — every space × every UInt8 value. Self-widening.
# ---------------------------------------------------------------------------


def _reserved_on_wire(space: Int, engine_tag: Int) -> Bool:
    """The engine tags plan_vocabulary.proto reserves: ExprTag (space 1)
    EXPR_BETWEEN and EXPR_SORT_KEY, SourceVariantTag (space 13)
    SOURCE_VARIANT_PARQUET and SOURCE_VARIANT_IN_MEMORY. Declared by the
    engine, refused in both directions."""
    if space == 1:
        return engine_tag == 10 or engine_tag == 11
    if space == 13:
        return engine_tag == 0 or engine_tag == 1
    return False


def test_every_space_round_trips_every_declared_tag() raises:
    """EVERY space, EVERY value 0..255. No space is named here on purpose,
    except in `_reserved_on_wire`."""
    var total_declared = 0
    var total_reserved = 0
    for space in range(PLAN_WIRE_SPACE_COUNT):
        var name = plan_wire_space_name(space)
        var declared_here = 0
        for i in range(0, 256):
            var t = UInt8(i)
            if _reserved_on_wire(space, i):
                # Declared, counted as a member, and refused both ways: the
                # .proto reserves the number.
                assert_true(plan_wire_is_declared(space, t), name + ": declared")
                declared_here += 1
                total_reserved += 1
                var to_raised = False
                try:
                    _ = plan_wire_to_wire(space, t)
                except:
                    to_raised = True
                assert_true(
                    to_raised, name + ": to_wire must refuse reserved " + String(i)
                )
                var from_raised = False
                try:
                    _ = plan_wire_from_wire(space, Int32(i + 1))
                except:
                    from_raised = True
                assert_true(
                    from_raised,
                    name + ": from_wire must refuse reserved " + String(i + 1),
                )
            elif plan_wire_is_declared(space, t):
                declared_here += 1
                var w = plan_wire_to_wire(space, t)
                assert_equal(
                    Int(w),
                    i + 1,
                    name + ": wire number must be engine value + 1",
                )
                assert_equal(
                    Int(plan_wire_from_wire(space, w)),
                    i,
                    name + ": round-trip must be the identity",
                )
            else:
                # NOT declared: encoding must REFUSE. Without this half the
                # round-trip is satisfied by `+1` / `-1` with no membership
                # test at all, and every sparse space silently over-accepts.
                var raised = False
                try:
                    _ = plan_wire_to_wire(space, t)
                except:
                    raised = True
                assert_true(
                    raised,
                    (
                        name
                        + ": to_wire must RAISE on engine value "
                        + String(i)
                        + ", which the engine does not declare"
                    ),
                )
        assert_equal(
            declared_here,
            plan_wire_space_member_count(space),
            name + ": the drive must find exactly the published member count",
        )
        total_declared += declared_here

    assert_equal(
        total_declared,
        PLAN_WIRE_VOCABULARY_MEMBERS,
        "the drive must cover every published member of every space",
    )
    assert_equal(total_reserved, 4, "four reserved engine tags")


def test_every_space_refuses_the_four_bad_wire_values() raises:
    """The controls, in every space. These are what make the drive mean anything."""
    for space in range(PLAN_WIRE_SPACE_COUNT):
        var name = plan_wire_space_name(space)

        var zero_raised = False
        try:
            _ = plan_wire_from_wire(space, 0)
        except:
            zero_raised = True
        assert_true(
            zero_raised,
            (
                name
                + ": wire 0 MUST raise. It is what an ABSENT proto3 enum field"
                + " decodes to, and engine tag 0 is a real tag in this space."
            ),
        )

        var negative_raised = False
        try:
            _ = plan_wire_from_wire(space, -1)
        except:
            negative_raised = True
        assert_true(negative_raised, name + ": a negative wire value MUST raise")

        var past_raised = False
        try:
            _ = plan_wire_from_wire(
                space, Int32(Int(plan_wire_space_engine_max(space))) + 2
            )
        except:
            past_raised = True
        assert_true(
            past_raised,
            name + ": one past the highest published wire number MUST raise",
        )

        var far_raised = False
        try:
            _ = plan_wire_from_wire(space, 100000)
        except:
            far_raised = True
        assert_true(far_raised, name + ": a wildly out-of-range value MUST raise")


def test_unknown_space_index_raises() raises:
    """A space index nothing publishes must RAISE, not answer False.

    A False would let a codec that addressed the wrong space silently skip the
    field — the same shape as the unknown-tag rule, one level up.
    """
    var raised = False
    try:
        _ = plan_wire_is_declared(PLAN_WIRE_SPACE_COUNT, 0)
    except:
        raised = True
    assert_true(raised, "an out-of-range space index must raise")

    var raised2 = False
    try:
        _ = plan_wire_space_member_count(-1)
    except:
        raised2 = True
    assert_true(raised2, "a negative space index must raise")


def test_the_sparse_gaps_are_refused() raises:
    """The specific gaps, named.

    `WindowFn` runs 0-5, 10-14, 20-24. `BinaryOp` runs 0-4, 10-15, 20-21.
    `ExtractField` runs 0-14, 16-25. A membership test written as `t <= max`
    would accept PF 6, BIN 5 and EXTRACT 15 — none of which the engine declares
    — and encode plans that nothing can execute. A regression here is not "a
    test failed", it is "the vocabulary accepts a tag the engine never made".
    """
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_WINDOW_FN, 6), "PF 6 is a gap"
    )
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_WINDOW_FN, 9), "PF 9 is a gap"
    )
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_WINDOW_FN, 15), "PF 15 is a gap"
    )
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_BINARY_OP, 5), "BIN 5 is a gap"
    )
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_BINARY_OP, 16), "BIN 16 is a gap"
    )
    # The extraction run is 0-14 and 16-25; the reserved hole is the SINGLE
    # value 15.
    # ⛔ THE POSITIVE ASSERTIONS ARE NOT DECORATION AND MUST NOT BE DROPPED WHEN
    # THIS MOVES AGAIN. A gap assertion on its own is satisfied by a space that
    # refuses EVERYTHING, so "re-point the gap until the test passes" is a real
    # and easy way to turn this census into a test about nothing. Every time the
    # run grows, the gap moves AND a positive lands on the new top.
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_EXTRACT_FIELD, 15),
        "EXTRACT 15 is a gap (the whole reserved hole)",
    )
    assert_true(
        plan_wire_is_declared(PLAN_WIRE_SPACE_EXTRACT_FIELD, 7),
        "EXTRACT_DAYOFWEEK = 7",
    )
    assert_true(
        plan_wire_is_declared(PLAN_WIRE_SPACE_EXTRACT_FIELD, 9),
        "EXTRACT_DAYOFYEAR = 9",
    )
    assert_true(
        plan_wire_is_declared(PLAN_WIRE_SPACE_EXTRACT_FIELD, 14),
        "EXTRACT_MICROSECOND = 14 — the top of the extraction run",
    )

    # And the ones that ARE declared either side of a gap, so the assertions
    # above are not passing because the whole space is refused.
    assert_true(
        plan_wire_is_declared(PLAN_WIRE_SPACE_WINDOW_FN, 5), "PF_NTILE = 5"
    )
    assert_true(
        plan_wire_is_declared(PLAN_WIRE_SPACE_WINDOW_FN, 10), "PF_LAG = 10"
    )
    assert_true(plan_wire_is_declared(PLAN_WIRE_SPACE_BINARY_OP, 4), "BIN_MOD = 4")
    assert_true(plan_wire_is_declared(PLAN_WIRE_SPACE_BINARY_OP, 10), "BIN_EQ = 10")
    # UN_BIT_COUNT — the top of the UnaryOp run. A POSITIVE
    # beside the gap below it, for the reason stated above the EXTRACT block:
    # a gap assertion alone is satisfied by a space that refuses everything.
    assert_true(
        plan_wire_is_declared(PLAN_WIRE_SPACE_UNARY_OP, 8), "UN_BIT_COUNT = 8"
    )
    assert_true(
        not plan_wire_is_declared(PLAN_WIRE_SPACE_UNARY_OP, 9),
        "UnaryOp 9 is past the top of the run",
    )


def test_source_orientation_unset_is_255_and_survives() raises:
    """`SOURCE_KIND_UNSET` is 255, not 2.

    This is why the wire number is derived from the ENGINE VALUE and not from
    declaration order: an ordinal scheme would have published UNSET as 3 and
    disagreed, silently, with every producer that writes the constant.
    """
    assert_true(source_orientation_is_declared(255), "SOURCE_KIND_UNSET = 255")
    assert_equal(Int(source_orientation_to_wire(255)), 256, "wire = engine + 1")
    assert_equal(Int(source_orientation_from_wire(256)), 255, "round-trip")
    assert_true(
        not source_orientation_is_declared(2),
        "engine value 2 is NOT declared in the SOURCE_KIND_ space",
    )


# ---------------------------------------------------------------------------
# THE DIAGNOSTIC PATH — total, never raising.
# ---------------------------------------------------------------------------


def test_wire_names_are_total_and_stable() raises:
    """`*_wire_name` is used inside error handling, so it may never raise.

    It also carries the STABLE identifier a non-Mojo frontend keys on: the
    engine's `UInt8` values are internal, these names are the contract.
    """
    assert_equal(plan_tag_wire_name(0), "PLAN_WIRE_UNSPECIFIED", "sentinel")
    assert_equal(plan_tag_wire_name(1), "PLAN_SCAN", "engine 0 -> wire 1")
    assert_equal(plan_tag_wire_name(5), "PLAN_JOIN", "engine 4 -> wire 5")
    assert_equal(expr_tag_wire_name(15), "EXPR_CORRELATED_SUBQUERY", "engine 14")
    assert_equal(join_type_wire_name(1), "JOIN_INNER", "engine 0 -> wire 1")
    assert_equal(binary_op_wire_name(11), "BIN_EQ", "engine 10 -> wire 11")
    assert_equal(window_fn_wire_name(11), "PF_LAG", "engine 10 -> wire 11")

    # Unknown RENDERS, does not raise.
    assert_equal(plan_tag_wire_name(9999), "PlanTag#9999", "unknown renders")
    assert_equal(join_type_wire_name(200), "JoinType#200", "unknown renders")

    # Dispatched by space index, the names agree with the direct calls.
    assert_equal(
        plan_wire_name(PLAN_WIRE_SPACE_PLAN_TAG, 1), "PLAN_SCAN", "dispatch"
    )
    assert_equal(
        plan_wire_name(PLAN_WIRE_SPACE_EXPR_TAG, 15),
        "EXPR_CORRELATED_SUBQUERY",
        "dispatch",
    )
    assert_equal(
        plan_wire_name(PLAN_WIRE_SPACE_JOIN_TYPE, 1), "JOIN_INNER", "dispatch"
    )
    assert_equal(
        plan_wire_space_name(PLAN_WIRE_SPACE_SOURCE_ORIENTATION),
        "SourceOrientation",
        "space name",
    )

    # Every space's name is distinct — a duplicate would make a diagnostic
    # ambiguous about which vocabulary refused the value.
    for a in range(PLAN_WIRE_SPACE_COUNT):
        for b in range(a + 1, PLAN_WIRE_SPACE_COUNT):
            assert_true(
                plan_wire_space_name(a) != plan_wire_space_name(b),
                "space names must be distinct: " + plan_wire_space_name(a),
            )


def main() raises:
    var suite = TestSuite()
    suite.test[test_plan_tag_vocabulary_is_complete_against_engine_count]()
    suite.test[test_expr_tag_vocabulary_is_complete_against_engine_count]()
    suite.test[test_countless_space_totals_are_pinned]()
    suite.test[test_every_space_round_trips_every_declared_tag]()
    suite.test[test_every_space_refuses_the_four_bad_wire_values]()
    suite.test[test_unknown_space_index_raises]()
    suite.test[test_the_sparse_gaps_are_refused]()
    suite.test[test_source_orientation_unset_is_255_and_survives]()
    suite.test[test_wire_names_are_total_and_stable]()
    suite^.run()
