# =============================================================================
# Rule 17, `select_join_build_side`: every input of the INNER decision.
# =============================================================================
#
# `_decide_build_left` reads, for an INNER join with no residual: each side's
# estimated row count, each side's estimated row width, and (on a single-key
# join) whether each side carries a wide STRING build payload, which reads
# that side's column names against that side's own key list and each payload
# column's type. Each test here holds every input but one fixed so that
# dropping, swapping or shifting that input changes the recorded side; each
# names the mutant it catches. The arms (join type, residual, key count, the
# override's arms, a stale recorded side, child joins) are pinned in
# `test_optimizer_join_build_side_arms.mojo`.
#
# Costs, from `estimate_row_width`: an INT64 column is 9 bytes, an INT16 3,
# an INT8 2, a STRING 17, plus 32 per row; cost = rows * width.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_JOIN,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
)
from komira_optimizer.optimizer_join import (
    select_join_build_side,
    _side_has_wide_string_build_payload,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _scan(path: String, names: List[String], types: List[ArrowType], rows: Int) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, sb.build(), None, None, Optional[Int](rows)
    )


def _ints(path: String, names: List[String], rows: Int) -> LogicalPlan:
    var types = List[ArrowType]()
    for _ in range(len(names)):
        types.append(ArrowType.INT64)
    return _scan(path, names, types, rows)


def _decides(var l: LogicalPlan, var r: LogicalPlan, want: UInt8, what: String) raises:
    """INNER(l, r) on keys `a` = `b` records `want`, and nothing else changes:
    with the build side cleared the output hashes like the input."""
    var lo: List[String] = ["a"]
    var ro: List[String] = ["b"]
    var j = LogicalPlan.join(l^, r^, lo^, ro^, JOIN_INNER)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].build_side), Int(want), what)
    out._join.value()[].build_side = JOIN_BUILD_SIDE_UNSET
    assert_equal(out.structural_hash(), before, what + ": plan changed")


# -----------------------------------------------------------------------------
# Row count against row width
# -----------------------------------------------------------------------------


def test_a_wide_left_side_with_fewer_rows_builds_right() raises:
    """L: 10 rows of six INT64 columns (width 86, cost 860). R: 20 rows of
    one INT64 column (width 41, cost 820). Row counts alone say LEFT; the
    cost says RIGHT. No STRING column, so the override is off. Catches the
    width dropped from the cost (`left_card < right_card`), the left width
    dropped (`left_card < right_card * right_width`) and the widths swapped
    (`left_card * right_width < right_card * left_width`)."""
    var ln: List[String] = ["a", "l1", "l2", "l3", "l4", "l5"]
    var rn: List[String] = ["b"]
    _decides(_ints("l", ln, 10), _ints("r", rn, 20), JOIN_BUILD_SIDE_RIGHT, "wide left")


def test_a_wide_right_side_with_fewer_rows_builds_left() raises:
    """The mirror: L 20 rows of one INT64 column (cost 820), R 10 rows of six
    INT64 columns (cost 860): LEFT, where row counts alone say RIGHT. Catches
    the width dropped from the cost, the right width dropped
    (`left_card * left_width < right_card`) and the widths swapped."""
    var ln: List[String] = ["a"]
    var rn: List[String] = ["b", "r1", "r2", "r3", "r4", "r5"]
    _decides(_ints("l", ln, 20), _ints("r", rn, 10), JOIN_BUILD_SIDE_LEFT, "wide right")


def test_a_one_byte_cost_gap_decides_in_both_directions() raises:
    """One row each. [INT64, INT16] costs 44 and [INT64, INT8, INT8] costs 45.
    The 44-byte side on the left builds LEFT; on the right it builds RIGHT.
    Catches the comparison's bound moved by one toward the left
    (`left_cost + 1 < right_cost`), which the equal-cost test cannot see;
    the other direction (`<=`) is `test_an_equal_cost_inner_join_builds_right`
    in the arms file."""
    var narrow_n: List[String] = ["a", "x"]
    var narrow_t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT16]
    var wide_n: List[String] = ["b", "y", "z"]
    var wide_t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT8, ArrowType.INT8]
    _decides(
        _scan("l", narrow_n, narrow_t, 1), _scan("r", wide_n, wide_t, 1),
        JOIN_BUILD_SIDE_LEFT, "44 vs 45",
    )
    var narrow_r: List[String] = ["b", "x"]
    var wide_l: List[String] = ["a", "y", "z"]
    _decides(
        _scan("l", wide_l, wide_t, 1), _scan("r", narrow_r, narrow_t, 1),
        JOIN_BUILD_SIDE_RIGHT, "45 vs 44",
    )


# -----------------------------------------------------------------------------
# Key names: each side's columns against its own key list
# -----------------------------------------------------------------------------


def _key_and_three(key: String, p: String) -> Tuple[List[String], List[ArrowType]]:
    """A key plus exactly three non-key columns, one of them STRING: not a
    wide payload when the key is recognised, wide when the key is counted."""
    var n: List[String] = [key, p + "_s", p + "_x", p + "_y"]
    var t: List[ArrowType] = [
        ArrowType.INT64, ArrowType.STRING, ArrowType.INT64, ArrowType.INT64
    ]
    return (n^, t^)


def test_the_right_side_is_read_against_the_right_keys() raises:
    """Keys `a` = `b`. R: 10 rows of `b` plus three columns, one STRING (cost
    760); L: 1000 rows of two INT64 columns (cost 50000). Against `right_on`
    R has three payload columns, not wide, so the cost decides: RIGHT. Read
    against `left_on`, `b` would count as a fourth payload column and the
    override would build LEFT. Catches the right side's predicate called
    with `jd.left_on`."""
    var ln: List[String] = ["a", "lv"]
    var r = _key_and_three("b", "r")
    _decides(
        _ints("l", ln, 1000), _scan("r", r[0], r[1], 10),
        JOIN_BUILD_SIDE_RIGHT, "right key named b",
    )


def test_the_left_side_is_read_against_the_left_keys() raises:
    """The mirror: L is 10 rows of `a` plus three columns, one STRING; R is
    1000 rows. Against `left_on` L is not wide and the cost builds LEFT; read
    against `right_on`, `a` would be payload and the override would build
    RIGHT. Catches the left side's predicate called with `jd.right_on`."""
    var rn: List[String] = ["b", "rv"]
    var l = _key_and_three("a", "l")
    _decides(
        _scan("l", l[0], l[1], 10), _ints("r", rn, 1000),
        JOIN_BUILD_SIDE_LEFT, "left key named a",
    )


# -----------------------------------------------------------------------------
# Column types in the predicate
# -----------------------------------------------------------------------------


def _string_key_and_four_ints(key: String) -> Tuple[List[String], List[ArrowType]]:
    var n: List[String] = [key, "p", "q", "s", "t"]
    var t: List[ArrowType] = [
        ArrowType.STRING, ArrowType.INT64, ArrowType.INT64, ArrowType.INT64,
        ArrowType.INT64,
    ]
    return (n^, t^)


def test_a_string_key_is_not_a_string_payload() raises:
    """A STRING key with four INT64 payload columns is not a wide STRING
    payload: the predicate says False, and at the call site the cost decides
    on both sides (a cheaper such R builds RIGHT, a cheaper such L builds
    LEFT). Catches the STRING check made before the key check, so a STRING
    key marks the side wide."""
    var keys: List[String] = ["k"]
    var s = _string_key_and_four_ints("k")
    assert_false(
        _side_has_wide_string_build_payload(_scan("s", s[0], s[1], 1), keys)
    )
    var ln: List[String] = ["a", "lv"]
    var r = _string_key_and_four_ints("b")
    _decides(
        _ints("l", ln, 1000), _scan("r", r[0], r[1], 10),
        JOIN_BUILD_SIDE_RIGHT, "STRING right key",
    )
    var rn: List[String] = ["b", "rv"]
    var l = _string_key_and_four_ints("a")
    _decides(
        _scan("l", l[0], l[1], 10), _ints("r", rn, 1000),
        JOIN_BUILD_SIDE_LEFT, "STRING left key",
    )


def test_only_a_utf8_string_payload_counts() raises:
    """The predicate tests for Arrow STRING (Utf8 with Int32 offsets) only. A
    key plus four payload columns holding BINARY, LARGE_STRING and
    LARGE_BINARY but no STRING is not a wide STRING payload. Pins the
    predicate to the one type it names; catches a check widened to the other
    variable-length types."""
    var keys: List[String] = ["k"]
    var n: List[String] = ["k", "b", "ls", "lb", "x"]
    var t: List[ArrowType] = [
        ArrowType.INT64, ArrowType.BINARY, ArrowType.LARGE_STRING,
        ArrowType.LARGE_BINARY, ArrowType.INT64,
    ]
    assert_false(_side_has_wide_string_build_payload(_scan("v", n, t, 1), keys))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
