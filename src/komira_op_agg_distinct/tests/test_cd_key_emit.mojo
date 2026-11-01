# =============================================================================
# The grouped COUNT(DISTINCT) driver's string key emit
# (`agg_cd_key_emit.cd_emit_string_key_column`)
# =============================================================================
#
# The emit turns each output group's dict id into that id's bytes. What each
# test proves:
#   * full emit: a group emitted with another id's bytes, or in another order
#     (the oracle is computed here from the raw values);
#   * prefetch on vs off: the software prefetch changes the emitted column
#     (it must be a hint only; both runs must be byte-identical);
#   * the bounded arm: it emits the groups `emit_gids` names, in that order,
#     and no other;
#   * `gk_identity`: output group g is dict id g, and `gk` is not read (an
#     empty `gk` must not be indexed);
#   * an id outside [0, len(starts)) emits an empty value instead of reading
#     out of bounds;
#   * the span's origin: the source can be any byte span (an arena or a
#     column's value buffer), so the bytes come from `bytes[starts[id]:...]`.

from std.collections import List
from std.testing import TestSuite, assert_equal

from komira_op_agg_distinct.agg_cd_key_emit import cd_emit_string_key_column


struct _Arena(Movable):
    """A byte arena holding `vals` back to back, with each value's start and
    length. Values are stored in REVERSE order so a start computed from the
    id's position (instead of read from `starts`) reads the wrong value."""

    var bytes: List[UInt8]
    var starts: List[Int]
    var lens: List[Int]

    def __init__(out self, imm vals: List[String]):
        self.bytes = List[UInt8]()
        self.starts = List[Int](length=len(vals), fill=0)
        self.lens = List[Int](length=len(vals), fill=0)
        var i = len(vals) - 1
        while i >= 0:
            self.starts[i] = len(self.bytes)
            self.lens[i] = vals[i].byte_length()
            for b in vals[i].as_bytes():
                self.bytes.append(b)
            i -= 1


def _vals(n: Int) -> List[String]:
    var out = List[String](capacity=n)
    for i in range(n):
        if i % 11 == 0:
            out.append(String(""))
        elif i % 7 == 0:
            out.append(String("ÄÖÜ-") + String(i))
        else:
            out.append(String("v") + String(i * 31))
    return out^


def _column_strings(imm gk: List[Int], imm a: _Arena, bounded: Bool,
                    imm emit_gids: List[Int], prefetch_on: Bool,
                    identity: Bool, num_groups: Int) raises -> List[String]:
    var c = cd_emit_string_key_column(
        Span(a.bytes),
        gk,
        a.starts,
        a.lens,
        emit_gids,
        bounded,
        num_groups,
        prefetch_on,
        identity,
    )
    var sa = c.as_string()
    var out = List[String](capacity=len(sa))
    for i in range(len(sa)):
        out.append(sa.get(i))
    return out^


def test_full_emit_matches_the_values_in_output_order() raises:
    var n = 2_000
    var vals = _vals(n)
    var a = _Arena(vals)
    # Output order: a permutation of the ids.
    var gk = List[Int](capacity=n)
    for g in range(n):
        gk.append((g * 1_237) % n)
    var none = List[Int]()
    for pf in [False, True]:
        var got = _column_strings(gk, a, False, none, pf, False, n)
        assert_equal(len(got), n, "one row per group")
        for g in range(n):
            if got[g] != vals[gk[g]]:
                assert_equal(got[g], vals[gk[g]], "group " + String(g))


def test_prefetch_does_not_change_the_column() raises:
    var n = 3_000
    var vals = _vals(n)
    var a = _Arena(vals)
    var gk = List[Int](capacity=n)
    for g in range(n):
        gk.append(n - 1 - g)
    var none = List[Int]()
    var off = _column_strings(gk, a, False, none, False, False, n)
    var on = _column_strings(gk, a, False, none, True, False, n)
    assert_equal(len(off), len(on), "row count")
    for g in range(n):
        if off[g] != on[g]:
            assert_equal(on[g], off[g], "row " + String(g))


def test_bounded_arm_emits_only_the_named_groups_in_order() raises:
    var n = 500
    var vals = _vals(n)
    var a = _Arena(vals)
    var gk = List[Int](capacity=n)
    for g in range(n):
        gk.append((g * 7) % n)
    var emit: List[Int] = [499, 0, 13, 250, 13]
    var got = _column_strings(gk, a, True, emit, True, False, n)
    assert_equal(len(got), len(emit), "only the named groups are emitted")
    for i in range(len(emit)):
        assert_equal(got[i], vals[gk[emit[i]]], "bounded row " + String(i))


def test_identity_mode_does_not_read_gk() raises:
    var n = 400
    var vals = _vals(n)
    var a = _Arena(vals)
    var empty_gk = List[Int]()
    var none = List[Int]()
    var got = _column_strings(empty_gk, a, False, none, True, True, n)
    assert_equal(len(got), n, "one row per id")
    for g in range(n):
        assert_equal(got[g], vals[g], "identity: group g is id g")
    var emit: List[Int] = [3, 1]
    var got_b = _column_strings(empty_gk, a, True, emit, False, True, n)
    assert_equal(got_b[0], vals[3], "identity, bounded: row 0")
    assert_equal(got_b[1], vals[1], "identity, bounded: row 1")


def test_an_out_of_range_id_emits_an_empty_value() raises:
    var vals: List[String] = ["a", "bb", "ccc"]
    var a = _Arena(vals)
    var gk: List[Int] = [2, -1, 3, 0, 1_000_000]
    var none = List[Int]()
    for pf in [False, True]:
        var got = _column_strings(gk, a, False, none, pf, False, len(gk))
        assert_equal(len(got), 5, "every group is emitted")
        assert_equal(got[0], "ccc", "id 2")
        assert_equal(got[1], "", "id -1 is out of range")
        assert_equal(got[2], "", "id 3 == len(starts) is out of range")
        assert_equal(got[3], "a", "id 0")
        assert_equal(got[4], "", "a large id is out of range")
    var emit: List[Int] = [1, 2]
    var got_b = _column_strings(gk, a, True, emit, False, False, len(gk))
    assert_equal(got_b[0], "", "bounded: id -1")
    assert_equal(got_b[1], "", "bounded: id 3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
