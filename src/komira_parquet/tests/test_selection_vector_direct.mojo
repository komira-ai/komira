# Direct tests of `selection_vector.mojo` beside the welded
# test_selection_interval: the byte tail of the word walk (whole bytes past
# the last full 64-bit word: all-zero, all-one and mixed bytes, with and
# without a run in flight), the empty mask, and a sweep of every length from 0
# to 200 bits over fixed and pseudo-random patterns. The expected intervals
# are computed here from the mask's bits by the definition: each maximal run
# of set bits is one interval whose `skip` is the count of clear bits since
# the previous run; clear bits after the last run make no interval. The word
# walk, the scalar reference and `from_bool_mask` must each equal it, and
# `boolean_to_indices` must list exactly the set bits.
from std.testing import TestSuite, assert_equal

from komira_arrow.boolean_array import BooleanArray

from komira_parquet.selection_vector import (
    SelectionInterval,
    _boolean_to_intervals_scalar,
    _boolean_to_intervals_simd,
    boolean_to_indices,
    boolean_to_intervals,
)


def _mask(bits: List[Bool]) -> BooleanArray:
    var arr = BooleanArray.allocate(len(bits))
    for i in range(len(bits)):
        if bits[i]:
            arr.data.set(i)
    return arr^


def _expected(bits: List[Bool]) -> List[SelectionInterval]:
    var out = List[SelectionInterval]()
    var skip = 0
    var run = 0
    for i in range(len(bits)):
        if bits[i]:
            run += 1
        else:
            if run > 0:
                out.append(SelectionInterval(UInt32(skip), UInt32(run)))
                skip = 0
                run = 0
            skip += 1
    if run > 0:
        out.append(SelectionInterval(UInt32(skip), UInt32(run)))
    return out^


def _same(
    got: List[SelectionInterval], want: List[SelectionInterval], what: String
) raises:
    assert_equal(len(got), len(want), what + ": interval count")
    for i in range(len(want)):
        assert_equal(Int(got[i].skip), Int(want[i].skip), what + ": skip " + String(i))
        assert_equal(
            Int(got[i].select), Int(want[i].select), what + ": select " + String(i)
        )


def _check(bits: List[Bool], what: String) raises:
    var want = _expected(bits)
    var mask = _mask(bits)
    var simd = List[SelectionInterval]()
    _boolean_to_intervals_simd(mask, simd)
    _same(simd, want, what + " (word walk)")
    var scalar = List[SelectionInterval]()
    _boolean_to_intervals_scalar(mask, scalar)
    _same(scalar, want, what + " (scalar)")
    var public = List[SelectionInterval]()
    boolean_to_intervals(mask, public)
    _same(public, want, what + " (boolean_to_intervals)")
    _same(SelectionInterval.from_bool_mask(mask), want, what + " (from_bool_mask)")
    var idx = boolean_to_indices(mask)
    var k = 0
    for i in range(len(bits)):
        if bits[i]:
            assert_equal(Int(idx[k]), i, what + ": index " + String(k))
            k += 1
    assert_equal(len(idx), k, what + ": index count")


def _bits(n: Int, pattern: Int) -> List[Bool]:
    """Bit i of pattern `pattern`, for i < n."""
    var out = List[Bool]()
    var state = UInt64(0x9E3779B97F4A7C15) + UInt64(pattern)
    for i in range(n):
        var b: Bool
        if pattern == 0:
            b = False
        elif pattern == 1:
            b = True
        elif pattern == 2:
            b = i % 2 == 0
        elif pattern == 3:
            b = (i // 8) % 2 == 0  # whole bytes of ones, then of zeros
        elif pattern == 4:
            b = (i // 8) % 3 == 1  # zero byte, one byte, zero byte
        elif pattern == 5:
            b = (i // 64) % 2 == 1  # whole words of zeros, then of ones
        elif pattern == 6:
            b = i % 9 < 4
        else:
            state = state * UInt64(6364136223846793005) + UInt64(
                1442695040888963407
            )
            # Patterns 7, 8, 9: about 1/2, 1/8 and 7/8 set.
            var r = Int((state >> UInt64(33)) % UInt64(8))
            if pattern == 7:
                b = r < 4
            elif pattern == 8:
                b = r == 0
            else:
                b = r != 0
        out.append(b)
    return out^


def test_every_length_to_200_bits_every_pattern() raises:
    """Lengths 0..200 cover no word, one to three words, every byte-tail
    length (0..7 whole bytes) and every bit-tail length (0..7 bits)."""
    for n in range(201):
        for p in range(10):
            _check(_bits(n, p), "n=" + String(n) + " pattern=" + String(p))


def _cat(parts: List[List[Bool]]) -> List[Bool]:
    var out = List[Bool]()
    for i in range(len(parts)):
        for j in range(len(parts[i])):
            out.append(parts[i][j])
    return out^


def _fill(n: Int, b: Bool) -> List[Bool]:
    return List[Bool](length=n, fill=b)


def test_byte_tail_arms() raises:
    """One full word, then whole bytes: a zero byte closes a run carried in
    from the word; a zero byte with no run in flight only adds to the skip; a
    0xFF byte extends a run; a mixed byte opens and closes runs."""
    # Word of ones, then a zero byte: the run of 64 is closed by the byte.
    var a = _cat([_fill(64, True), _fill(8, False), _fill(3, True)])
    _check(a, "ones word + zero byte")
    _same(
        _expected(a),
        [SelectionInterval(0, 64), SelectionInterval(8, 3)],
        "ones word + zero byte (definition)",
    )
    # Word of zeros, then a zero byte (no run), then 0xFF bytes.
    var b = _cat([_fill(64, False), _fill(8, False), _fill(16, True)])
    _check(b, "zero word + zero byte + 0xFF bytes")
    _same(
        _expected(b),
        [SelectionInterval(72, 16)],
        "zero word + zero byte + 0xFF bytes (definition)",
    )
    # Mixed bytes in the tail, a run crossing from the word into them.
    var tail: List[Bool] = [False, True, True, False]
    var c = _cat(
        [_fill(60, False), _fill(7, True), tail^, _fill(9, False), _fill(5, True)]
    )
    _check(c, "mixed bytes")


def test_empty_mask() raises:
    """A mask of length 0 makes no interval and no index, and appending its
    intervals leaves a list as it was."""
    _check(List[Bool](), "empty")
    var out: List[SelectionInterval] = [SelectionInterval(2, 3)]
    boolean_to_intervals(_mask(List[Bool]()), out)
    assert_equal(len(out), 1)
    assert_equal(len(SelectionInterval.all(0)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
