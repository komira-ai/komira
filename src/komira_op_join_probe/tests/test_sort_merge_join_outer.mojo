# The LEFT, RIGHT and FULL OUTER sort-merge merges (`sort_merge_join_outer`):
# every emitted (left, right) pair, in order, for partial, total and no
# overlap, empty sides, duplicate runs on either side, and NULL keys. A NULL
# key matches nothing, not even a NULL or a real key equal to its slot value,
# and each NULL row is emitted exactly once as an unmatched row of its side.

from std.testing import TestSuite, assert_equal

from komira_arrow.primitive_array import PrimitiveArray

from komira_op_join_probe.sort_merge_join_outer import (
    sort_merge_join_left_into,
    sort_merge_join_right_into,
    sort_merge_join_full_into,
)


comptime LEFT = 0
comptime RIGHT = 1
comptime FULL = 2


def _keys(values: List[Int64]) -> PrimitiveArray[DType.int64]:
    return PrimitiveArray[DType.int64].from_list(values)


def _flags(v: List[Bool]) -> Optional[List[Bool]]:
    return Optional[List[Bool]](v.copy())


def _merge(
    kind: Int,
    left: List[Int64],
    right: List[Int64],
    left_null: Optional[List[Bool]] = None,
    right_null: Optional[List[Bool]] = None,
) raises -> List[Int]:
    """The merge's pairs, flattened `[l0, r0, l1, r1, ...]`."""
    var lm = List[Int]()
    var rm = List[Int]()
    var lk = _keys(left)
    var rk = _keys(right)
    if kind == LEFT:
        sort_merge_join_left_into(lk, rk, lm, rm, left_null, right_null)
    elif kind == RIGHT:
        sort_merge_join_right_into(lk, rk, lm, rm, left_null, right_null)
    else:
        sort_merge_join_full_into(lk, rk, lm, rm, left_null, right_null)
    assert_equal(len(lm), len(rm), "the two index lists pair up")
    var out = List[Int]()
    for i in range(len(lm)):
        out.append(lm[i])
        out.append(rm[i])
    return out^


def _assert_pairs(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": pair count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": entry " + String(i))


def test_left_partial_all_and_no_match() raises:
    _assert_pairs(
        _merge(LEFT, [1, 2, 3, 4], [2, 4]), [0, -1, 1, 0, 2, -1, 3, 1],
        "LEFT partial",
    )
    _assert_pairs(_merge(LEFT, [1, 2, 3], [1, 2, 3]), [0, 0, 1, 1, 2, 2], "LEFT all")
    _assert_pairs(
        _merge(LEFT, [1, 3, 5], [2, 4]), [0, -1, 1, -1, 2, -1], "LEFT none"
    )


def test_right_partial_and_empty_left() raises:
    _assert_pairs(
        _merge(RIGHT, [2, 4], [1, 2, 3, 4]), [-1, 0, 0, 1, -1, 2, 1, 3],
        "RIGHT partial",
    )
    _assert_pairs(
        _merge(RIGHT, List[Int64](), [10, 20, 30]), [-1, 0, -1, 1, -1, 2],
        "RIGHT, empty left",
    )
    _assert_pairs(
        _merge(RIGHT, [1, 2], List[Int64]()), List[Int](),
        "RIGHT, empty right",
    )


def test_full_disjoint_partial_all() raises:
    _assert_pairs(
        _merge(FULL, [1, 3], [2, 4]), [0, -1, -1, 0, 1, -1, -1, 1],
        "FULL disjoint",
    )
    _assert_pairs(
        _merge(FULL, [1, 2, 3], [2, 3, 4]), [0, -1, 1, 0, 2, 1, -1, 2],
        "FULL partial",
    )
    _assert_pairs(
        _merge(FULL, [10, 20, 30], [10, 20, 30]), [0, 0, 1, 1, 2, 2],
        "FULL all",
    )


def test_empty_sides() raises:
    _assert_pairs(
        _merge(LEFT, [1, 2, 3], List[Int64]()), [0, -1, 1, -1, 2, -1],
        "LEFT, empty right",
    )
    _assert_pairs(
        _merge(LEFT, List[Int64](), [1, 2]), List[Int](), "LEFT, empty left"
    )
    _assert_pairs(
        _merge(FULL, List[Int64](), List[Int64]()), List[Int](),
        "FULL, both empty",
    )


def test_duplicate_runs() raises:
    _assert_pairs(
        _merge(LEFT, [1, 1, 2], [1, 3]), [0, 0, 1, 0, 2, -1],
        "LEFT, left duplicates",
    )
    # key 1: the 2 x 2 cross product; key 2: right unmatched; key 3: left.
    _assert_pairs(
        _merge(FULL, [1, 1, 3], [1, 1, 2]),
        [0, 0, 0, 1, 1, 0, 1, 1, -1, 2, 2, -1],
        "FULL, N:M duplicates",
    )


def test_null_left_key_matches_nothing() raises:
    # Left row 1 is NULL; its slot holds 2, the right side's key.
    var ln = _flags([False, True, False])
    _assert_pairs(
        _merge(LEFT, [1, 2, 3], [2], ln), [0, -1, 1, -1, 2, -1],
        "LEFT, a NULL left key",
    )
    ln = _flags([False, True, False])
    _assert_pairs(
        _merge(FULL, [1, 2, 3], [2], ln), [0, -1, 1, -1, -1, 0, 2, -1],
        "FULL, a NULL left key",
    )


def test_null_right_key_in_an_equal_run() raises:
    # Right rows 0..2 all hold 5; row 1 is NULL. Left row 0 holds 5.
    var rn = _flags([False, True, False])
    _assert_pairs(
        _merge(RIGHT, [5], [5, 5, 5], None, rn), [0, 0, 0, 2, -1, 1],
        "RIGHT, the run's NULL row unmatched once",
    )
    rn = _flags([False, True, False])
    _assert_pairs(
        _merge(LEFT, [5], [5, 5, 5], None, rn), [0, 0, 0, 2],
        "LEFT drops the NULL right row",
    )


def test_run_of_only_null_right_rows() raises:
    # Every right row holding 5 is NULL: each is an unmatched right row, and
    # the left row 5 has no match.
    var rn = _flags([True, True])
    _assert_pairs(
        _merge(FULL, [5], [5, 5], None, rn), [-1, 0, -1, 1, 0, -1],
        "FULL, an all-NULL run",
    )
    rn = _flags([True, True])
    _assert_pairs(
        _merge(LEFT, [5], [5, 5], None, rn), [0, -1], "LEFT, an all-NULL run"
    )


def test_null_on_both_sides_never_pairs() raises:
    # Two NULLs holding the same slot value do not match each other.
    var ln = _flags([True])
    var rn = _flags([True])
    _assert_pairs(
        _merge(FULL, [0], [0], ln, rn), [0, -1, -1, 0], "FULL, NULL vs NULL"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
