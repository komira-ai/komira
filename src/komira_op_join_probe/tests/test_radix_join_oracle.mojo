# `RadixPartitionedHashJoin` against a nested-loop oracle for every probe kind it
# has (INNER, LEFT, SEMI, ANTI): duplicate keys on both sides, NULL keys on
# both sides (a NULL never matches, a NULL probe row is unmatched for LEFT and
# ANTI), a hot key, every key in one radix partition, the extreme keys, and
# empty sides. The build and probe sides differ in length and in which rows
# match, so a pair list with its two index lists swapped, or a row dropped or
# repeated, differs from the oracle's.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_probe.radix_join import RadixPartitionedHashJoin


comptime I64 = DType.int64
comptime _MIN: Int64 = Int64(-9223372036854775807 - 1)
comptime _MAX: Int64 = Int64(9223372036854775807)
comptime _FIB: UInt64 = 0x9E3779B97F4A7C15


def _radix_partition(key: Int64) -> Int:
    """The radix join's partition of `key`: the top 8 bits of its hash."""
    var h = UInt64(key) * _FIB
    h = h ^ (h >> 32)
    if h == 0:
        h = 1
    return Int((h >> 56) & 0xFF)


def _column(imm keys: List[Int64], imm nulls: List[Bool]) -> PrimitiveArray[I64]:
    """A key column; `nulls` is empty (no validity) or one flag per row."""
    var n = len(keys)
    var any_null = False
    for i in range(len(nulls)):
        if nulls[i]:
            any_null = True
    var arr: PrimitiveArray[I64]
    if any_null:
        arr = PrimitiveArray[I64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    for i in range(len(nulls)):
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _pair_code(build_row: Int, probe_row: Int, probe_len: Int) -> Int:
    return (build_row + 1) * (probe_len + 1) + probe_row


def _oracle_pairs(
    imm build: List[Int64],
    imm build_nulls: List[Bool],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    left: Bool,
) -> List[Int]:
    """Sorted codes of the (build row, probe row) matches; with `left` an
    unmatched probe row pairs with build row -1."""
    var out = List[Int]()
    for pi in range(len(probe)):
        var probe_null = len(probe_nulls) > 0 and probe_nulls[pi]
        var found = False
        if not probe_null:
            for bi in range(len(build)):
                var build_null = len(build_nulls) > 0 and build_nulls[bi]
                if not build_null and build[bi] == probe[pi]:
                    found = True
                    out.append(_pair_code(bi, pi, len(probe)))
        if left and not found:
            out.append(_pair_code(-1, pi, len(probe)))
    sort(out)
    return out^


def _oracle_rows(
    imm build: List[Int64],
    imm build_nulls: List[Bool],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    anti: Bool,
) -> List[Int]:
    var out = List[Int]()
    for pi in range(len(probe)):
        var probe_null = len(probe_nulls) > 0 and probe_nulls[pi]
        var found = False
        if not probe_null:
            for bi in range(len(build)):
                var build_null = len(build_nulls) > 0 and build_nulls[bi]
                if not build_null and build[bi] == probe[pi]:
                    found = True
                    break
        if found != anti:
            out.append(pi)
    return out^


def _codes(
    imm build_rows: List[Int], imm probe_rows: List[Int], probe_len: Int
) raises -> List[Int]:
    assert_equal(len(build_rows), len(probe_rows), "index lists differ in length")
    var out = List[Int]()
    for i in range(len(build_rows)):
        out.append(_pair_code(build_rows[i], probe_rows[i], probe_len))
    sort(out)
    return out^


def _assert_same(imm got: List[Int], imm want: List[Int], imm what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error(
                what + ": entry " + String(i) + " is " + String(got[i])
                + ", the oracle has " + String(want[i])
            )


def _check(
    imm what: String,
    imm build: List[Int64],
    imm build_nulls: List[Bool],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
) raises:
    var rj = RadixPartitionedHashJoin.build(_column(build, build_nulls))
    var probe_col = _column(probe, probe_nulls)
    var plen = len(probe)

    var inner = rj.probe_inner(probe_col)
    _assert_same(
        _codes(inner[0], inner[1], plen),
        _oracle_pairs(build, build_nulls, probe, probe_nulls, False),
        what + " INNER",
    )
    var left = rj.probe_left(probe_col)
    _assert_same(
        _codes(left[0], left[1], plen),
        _oracle_pairs(build, build_nulls, probe, probe_nulls, True),
        what + " LEFT",
    )
    var semi = rj.probe_semi(probe_col)
    sort(semi)
    _assert_same(
        semi, _oracle_rows(build, build_nulls, probe, probe_nulls, False),
        what + " SEMI",
    )
    var anti = rj.probe_anti(probe_col)
    sort(anti)
    _assert_same(
        anti, _oracle_rows(build, build_nulls, probe, probe_nulls, True),
        what + " ANTI",
    )
    assert_equal(len(semi) + len(anti), plen, what + ": SEMI + ANTI cover the probe")


def _lcg_keys(n: Int, distinct: Int, seed: Int) -> List[Int64]:
    var out = List[Int64]()
    var s = UInt64(seed)
    for _ in range(n):
        s = s * 6364136223846793005 + 1442695040888963407
        out.append(Int64(Int((s >> 33) % UInt64(distinct))) - Int64(distinct // 3))
    return out^


def _flags(n: Int, every: Int, offset: Int) -> List[Bool]:
    var out = List[Bool]()
    for i in range(n):
        out.append((i + offset) % every == 0)
    return out^


def test_duplicates_on_both_sides() raises:
    _check(
        "duplicates", _lcg_keys(400, 60, 1), List[Bool](),
        _lcg_keys(700, 90, 2), List[Bool](),
    )


def test_null_keys_on_both_sides() raises:
    """NULL rows hold key values that other rows match; they must not."""
    var build = _lcg_keys(300, 40, 3)
    var probe = _lcg_keys(500, 55, 4)
    _check("nulls both", build, _flags(300, 7, 2), probe, _flags(500, 5, 1))
    _check("null build only", build, _flags(300, 4, 0), probe, List[Bool]())
    _check("null probe only", build, List[Bool](), probe, _flags(500, 3, 0))


def test_every_row_null() raises:
    var build = _lcg_keys(50, 10, 5)
    var probe = _lcg_keys(80, 10, 6)
    _check("all null build", build, _flags(50, 1, 0), probe, List[Bool]())
    _check("all null probe", build, List[Bool](), probe, _flags(80, 1, 0))


def test_one_hot_key() raises:
    var build = List[Int64]()
    for _ in range(257):
        build.append(Int64(42))
    var probe: List[Int64] = [42, 7, 42, 42, -3, 42]
    _check("hot key", build, List[Bool](), probe, List[Bool]())


def test_every_key_in_one_partition() raises:
    """Distinct keys that all hash to radix partition 0: one table holds the
    whole build side; probes of absent keys in the same partition find none."""
    var members = List[Int64]()
    var absent = List[Int64]()
    var k = Int64(1)
    while len(members) < 300 or len(absent) < 200:
        if _radix_partition(k) == 0:
            if len(members) < 300:
                members.append(k)
            else:
                absent.append(k)
        k += 1
    var probe = List[Int64]()
    for i in range(0, 300, 2):
        probe.append(members[i])
    for i in range(len(absent)):
        probe.append(absent[i])
    _check("one partition", members, List[Bool](), probe, List[Bool]())


def test_extreme_keys() raises:
    var build: List[Int64] = [_MIN, _MAX, 0, -1, 1, _MIN, _MAX]
    var probe: List[Int64] = [_MAX, 5, _MIN, -1, _MIN, 0, 1, 2]
    _check("extreme", build, List[Bool](), probe, List[Bool]())


def test_empty_sides() raises:
    var some: List[Int64] = [1, 2, 3]
    var none = List[Int64]()
    _check("empty build", none, List[Bool](), some, List[Bool]())
    _check("empty probe", some, List[Bool](), none, List[Bool]())
    _check("both empty", none, List[Bool](), none, List[Bool]())


def test_single_row_sides() raises:
    var one: List[Int64] = [9]
    var other: List[Int64] = [9, 10]
    _check("one build row", one, List[Bool](), other, List[Bool]())
    _check("one probe row", other, List[Bool](), one, List[Bool]())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
