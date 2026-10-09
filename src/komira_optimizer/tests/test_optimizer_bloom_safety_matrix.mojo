# =============================================================================
# Unit test: the Bloom-safety matrix encoding.
# =============================================================================
#
# This file pins the
# Bloom-safety matrix encoded in `_is_safe_to_push_dyn_filter` against
# the formal per-join-type argument in its docstring.
#
# Matrix (the helper admits INNER + SEMI only):
#
# | Join type | build_is_left=True | build_is_left=False |
# |-----------|--------------------|---------------------|
# | INNER     | SAFE (admitted)    | SAFE (admitted)     |
# | SEMI      | SAFE (admitted)    | SAFE (admitted)     |
# | ANTI      | SAFE (formal) /    | UNSAFE              |
# |           | NOT-ADMITTED       |                     |
# | LEFT      | SAFE (formal) /    | UNSAFE              |
# |           | NOT-ADMITTED       |                     |
# | RIGHT     | UNSAFE             | SAFE (formal) /     |
# |           |                    | NOT-ADMITTED        |
# | FULL      | UNSAFE             | UNSAFE              |
# | CROSS     | UNSAFE             | UNSAFE              |
#
# The helper conservatively returns SAFE only when the matrix says
# SAFE AND the join type is INNER or SEMI. So ANTI/LEFT/RIGHT all
# return False. A change to `_is_safe_to_push_dyn_filter` that admits
# another join type turns this test red.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_RIGHT, JOIN_FULL,
    JOIN_SEMI, JOIN_ANTI, JOIN_CROSS,
)

from komira_optimizer.optimizer_scan_share import _is_safe_to_push_dyn_filter


def test_inner_safe_both_directions() raises:
    """INNER joins: matched-rows-only semantics. Filtering either
    side's probe scan to BF(other-side) preserves the matched set.
    """
    assert_true(
        _is_safe_to_push_dyn_filter(JOIN_INNER, build_is_left=True),
        "INNER + build=LEFT must be SAFE (probe RIGHT narrowed)",
    )
    assert_true(
        _is_safe_to_push_dyn_filter(JOIN_INNER, build_is_left=False),
        "INNER + build=RIGHT must be SAFE (probe LEFT narrowed)",
    )
    print("[TEST 1 PASS] inner_safe_both_directions")


def test_semi_safe_both_directions() raises:
    """SEMI joins: emit LEFT-rows-with-≥1-match. Narrowing either
    side preserves the SEMI emit set (filtering LEFT to BF(RIGHT)
    keeps left-rows-that-could-match; filtering RIGHT to BF(LEFT)
    narrows the matched-key universe — a LEFT row that would emit
    SEMI MUST have ≥1 key in RIGHT; that key is in BF(LEFT) by
    construction, so it's kept post-filter).
    """
    assert_true(
        _is_safe_to_push_dyn_filter(JOIN_SEMI, build_is_left=True),
        "SEMI + build=LEFT must be SAFE (probe RIGHT narrowed)",
    )
    assert_true(
        _is_safe_to_push_dyn_filter(JOIN_SEMI, build_is_left=False),
        "SEMI + build=RIGHT must be SAFE (probe LEFT narrowed)",
    )
    print("[TEST 2 PASS] semi_safe_both_directions")


def test_anti_not_admitted_today() raises:
    """ANTI joins: emit LEFT-rows-with-ZERO-matches. Formally:
      - build=LEFT (filter probe=RIGHT): SAFE (a LEFT row not in
        RIGHT stays not in narrowed-RIGHT).
      - build=RIGHT (filter probe=LEFT): UNSAFE (filtering LEFT to
        BF(RIGHT) keeps only left rows with a key in RIGHT, so it removes
        EXACTLY the rows ANTI emits).

    The helper admits INNER + SEMI only.
    Helper must return False for both ANTI directions.
    """
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_ANTI, build_is_left=True),
        "ANTI + build=LEFT: formal SAFE but runtime not admitted; helper False",
    )
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_ANTI, build_is_left=False),
        "ANTI + build=RIGHT: formal UNSAFE; helper False",
    )
    print("[TEST 3 PASS] anti_not_admitted_today")


def test_left_outer_not_admitted_today() raises:
    """LEFT outer joins: emit ALL left rows (matched + NULL-padded
    unmatched). Formally:
      - build=LEFT (filter probe=RIGHT): SAFE (unmatched-left rows
        still emit with NULL right cols; just narrows right).
      - build=RIGHT (filter probe=LEFT): UNSAFE (would remove
        unmatched-left rows that should emit with NULL).

    The helper admits INNER + SEMI only. Helper False for both.
    """
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_LEFT, build_is_left=True),
        "LEFT + build=LEFT: formal SAFE but runtime not admitted; helper False",
    )
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_LEFT, build_is_left=False),
        "LEFT + build=RIGHT: formal UNSAFE; helper False",
    )
    print("[TEST 4 PASS] left_outer_not_admitted_today")


def test_right_outer_not_admitted_today() raises:
    """RIGHT outer joins: symmetric to LEFT. Formally:
      - build=LEFT (filter probe=RIGHT): UNSAFE (would remove
        unmatched-right rows that should emit).
      - build=RIGHT (filter probe=LEFT): SAFE.
    Not admitted → helper False both directions.
    """
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_RIGHT, build_is_left=True),
        "RIGHT + build=LEFT: formal UNSAFE; helper False",
    )
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_RIGHT, build_is_left=False),
        "RIGHT + build=RIGHT: formal SAFE but runtime not admitted; helper False",
    )
    print("[TEST 5 PASS] right_outer_not_admitted_today")


def test_full_unsafe_both_directions() raises:
    """FULL outer: emits unmatched rows from BOTH sides. Bloom
    rejection on either probe side drops would-be-NULL-padded rows.
    UNSAFE both directions per matrix.
    """
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_FULL, build_is_left=True),
        "FULL + build=LEFT: UNSAFE",
    )
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_FULL, build_is_left=False),
        "FULL + build=RIGHT: UNSAFE",
    )
    print("[TEST 6 PASS] full_unsafe_both_directions")


def test_cross_unsafe() raises:
    """CROSS: no key correspondence; Bloom membership undefined.
    UNSAFE always.
    """
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_CROSS, build_is_left=True),
        "CROSS + build=LEFT: UNSAFE",
    )
    assert_false(
        _is_safe_to_push_dyn_filter(JOIN_CROSS, build_is_left=False),
        "CROSS + build=RIGHT: UNSAFE",
    )
    print("[TEST 7 PASS] cross_unsafe")


def main() raises:
    test_inner_safe_both_directions()
    test_semi_safe_both_directions()
    test_anti_not_admitted_today()
    test_left_outer_not_admitted_today()
    test_right_outer_not_admitted_today()
    test_full_unsafe_both_directions()
    test_cross_unsafe()
    print("ALL BLOOM-SAFETY MATRIX TESTS PASSED")
