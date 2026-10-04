# =============================================================================
# The `%lit%` LIKE / `contains()` COLUMN SCAN === the per-row reference,
# bit-for-bit — and the scan ARM is really the one production takes.
# =============================================================================
#
# `komira_core.eval.string_contains_scan` answers a bare `%lit%` (and the
# `contains()` function) with ONE SIMD substring scan over the column's
# contiguous data buffer, mapping each hit back to its row, instead of one libc
# `memmem` per row (a large share of CPU on ClickBench Q20). It is
# value-identical to the per-row path by construction, which is why this file
# checks two different things:
#
#   1. VALUES. Every case diffs the production answer (`eval_string_like` with
#      the argument omitted) against the generic backtracking `_like_match`
#      (`use_fastpath=False`) — a reference that knows nothing about buffers,
#      offsets or the scan. The cases that matter are the ones ONLY the scan
#      can get wrong: a hit that STRADDLES a row boundary (`["goo", "gle"]`
#      concatenates to `google`), a straddle across EMPTY rows, a straddle
#      followed by a real match in the next row, a column whose offsets do not
#      start at 0, a NULL slot that holds matching bytes, and a seeded corpus
#      long enough to cross every SIMD block and tail boundary.
#
#   2. THE ARM. `contains_scan_call_count` moves for a `%lit%` pattern and does
#      NOT move for an anchored / multi-segment / 1-byte / reference-arm call.
#      Without leg 2, leg 1 would pass just as green if the routing were
#      deleted, because the per-row path gives the same answers.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.string_array import StringArray
from komira_core.arrow.large_string_array import LargeStringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.eval.string_comparison import (
    eval_string_like,
    eval_large_string_like,
    eval_string_contains,
    eval_large_string_contains,
)
from komira_core.eval.string_contains_scan import (
    contains_scan_call_count,
    reset_contains_scan_call_count,
)


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _assert_masks_equal(a: BooleanArray, b: BooleanArray, what: String) raises:
    assert_equal(a.length, b.length, "length mismatch: " + what)
    for i in range(a.length):
        assert_equal(
            a.is_null(i), b.is_null(i), "validity diverges row " + String(i) + ": " + what
        )
        if not a.is_null(i):
            assert_equal(a.get(i), b.get(i), "value diverges row " + String(i) + ": " + what)


def _check(arr: StringArray[HeapRegion], pattern: String, what: String) raises:
    """Production LIKE === the backtracking reference over `arr`."""
    var reference = eval_string_like(arr, pattern, use_fastpath=False)
    var production = eval_string_like(arr, pattern)
    _assert_masks_equal(reference, production, what + " pattern='" + pattern + "'")


def _expect(arr: StringArray[HeapRegion], pattern: String, want: List[Bool]) raises:
    """Production LIKE against hand-computed truth (all rows valid)."""
    var m = eval_string_like(arr, pattern)
    assert_equal(m.length, len(want))
    for i in range(len(want)):
        assert_equal(
            m.get(i), want[i], "pattern='" + pattern + "' row " + String(i)
        )


struct _Lcg(Movable):
    """Deterministic generator, so a red here reproduces byte-for-byte."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self, bound: Int) -> Int:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return Int((self.state >> 33) % UInt64(bound))


def _seeded_corpus(seed: UInt64, rows: Int, max_len: Int) -> List[String]:
    # A small alphabet dense in the needles' own bytes, so hits, near-misses
    # and boundary straddles are all common, plus lengths long enough to cross
    # several 16/32/64-byte SIMD blocks and their scalar tails.
    var alphabet = String("googleGOe.ab")
    var ab = alphabet.as_bytes()
    var tokens: List[String] = [
        String("google"), String(".google."), String("Google"), String("go"),
        String("oo"), String("gle"),
    ]
    var g = _Lcg(seed)
    var out = List[String]()
    for _ in range(rows):
        var n = g.next(max_len + 1)
        if g.next(7) == 0:
            n = 0  # a real share of empty rows, for the gallop's skip
        var bytes = List[UInt8]()
        if n > 0 and g.next(4) == 0:
            # A row that STARTS with a needle-like token: the match lands on
            # `offsets[r]` exactly, the equality edge of the row bisect.
            var tok = tokens[g.next(len(tokens))].as_bytes()
            for t in tok:
                bytes.append(t)
        for _ in range(n):
            bytes.append(ab[g.next(len(ab))])
        out.append(String(unsafe_from_utf8=Span(bytes)))
    return out^


# -----------------------------------------------------------------------------
# 1. the cases only a whole-buffer scan can get wrong
# -----------------------------------------------------------------------------


def test_straddle_is_not_a_match() raises:
    var arr = StringArray.from_strings([String("goo"), String("gle")])
    _expect(arr, "%google%", [False, False])
    _check(arr, "%google%", "straddle")


def test_straddle_then_real_match_next_row() raises:
    # "googl" + "egoogle": the first hit starts in row 0 and straddles; row 1
    # holds a real one AFTER that straddle's end.
    var arr = StringArray.from_strings(
        [String("googl"), String("egoogle"), String(""), String("google"), String("xx")]
    )
    _expect(arr, "%google%", [False, True, False, True, False])
    _check(arr, "%google%", "straddle-then-match")


def test_straddle_across_empty_rows() raises:
    var arr = StringArray.from_strings(
        [String("goo"), String(""), String(""), String("gle"), String("google")]
    )
    _expect(arr, "%google%", [False, False, False, False, True])
    _check(arr, "%google%", "straddle-across-empties")


def test_match_at_buffer_start_and_end() raises:
    var arr = StringArray.from_strings(
        [String("google.com"), String("nothing"), String("ends in google")]
    )
    _expect(arr, "%google%", [True, False, True])
    var whole = StringArray.from_strings([String("google")])
    _expect(whole, "%google%", [True])
    var short = StringArray.from_strings([String("googl")])
    _expect(short, "%google%", [False])


def test_row_start_match_the_gallop_steps_over() raises:
    # `k` non-matching rows, then a row whose match begins EXACTLY at its own
    # start. The gallop probes cursor+1, +3, +7, ... so for most `k` the
    # matching row is reached by the BISECT with `offsets[mid] == p` — the
    # equality edge a `<` for `<=` slip would push onto the previous row.
    for k in range(0, 40):
        var v = List[String]()
        var want = List[Bool]()
        for i in range(k):
            v.append(String("ab") * (1 + i % 3))
            want.append(False)
        v.append(String("google/x"))
        want.append(True)
        v.append(String("zz"))
        want.append(False)
        var arr = StringArray.from_strings(v)
        _expect(arr, "%google%", want)
        _check(arr, "%google%", "row-start after " + String(k) + " misses")


def test_every_row_matches() raises:
    # The dense regime: the gallop's one-probe path on every row.
    var v = List[String]()
    for i in range(300):
        v.append(String("ab") * (i % 5) + ".google." + String("x") * (i % 3))
    var arr = StringArray.from_strings(v)
    _check(arr, "%.google.%", "every-row")
    _check(arr, "%google%", "every-row")


def test_offsets_not_starting_at_zero() raises:
    # data = "XXXXgoogleYYgoo" ; rows = data[4:10], data[10:12], data[12:15]
    # The 4 leading bytes belong to NO row and must not be searched as if they
    # did; `from_buffers` does not enforce offsets[0] == 0.
    var data = List[UInt8]()
    for b in String("XXXXgoogleYYgoo").as_bytes():
        data.append(b)
    var arr = StringArray.from_buffers([Int32(4), Int32(10), Int32(12), Int32(15)], data^, None, 0)
    _expect(arr, "%google%", [True, False, False])
    _expect(arr, "%XX%", [False, False, False])
    _check(arr, "%google%", "offset-start")
    _check(arr, "%XXgo%", "offset-start")


def test_null_slot_holding_matching_bytes() raises:
    # Arrow permits a NULL slot with a non-empty byte range. Both kernels search
    # it; `_apply_validity` must still report the row as UNKNOWN (valid=0,
    # data=0), and NOT as a match.
    var data = List[UInt8]()
    for b in String("googlegooglezz").as_bytes():
        data.append(b)
    var validity = Bitmap.create_all_valid(3)
    validity.clear(1)
    var arr = StringArray.from_buffers(
        [Int32(0), Int32(6), Int32(12), Int32(14)], data^, validity^, 1
    )
    var m = eval_string_like(arr, "%google%")
    assert_false(m.is_null(0))
    assert_true(m.get(0))
    assert_true(m.is_null(1))
    assert_false(m.get(1))
    assert_false(m.is_null(2))
    assert_false(m.get(2))
    _check(arr, "%google%", "null-slot")


# -----------------------------------------------------------------------------
# 2. seeded corpora: every SIMD block / tail boundary, many needle lengths
# -----------------------------------------------------------------------------


def test_seeded_corpus_equals_reference() raises:
    var patterns: List[String] = [
        String("%go%"),
        String("%oo%"),
        String("%ee%"),
        String("%gle%"),
        String("%google%"),
        String("%.google.%"),
        String("%Google%"),
        String("%%google%%"),  # `%%` collapses to the same bare contains
        String("%googlegoogle%"),
        String("%abababababababababababababababababab%"),  # longer than a NEON block
        String("%oogleGOe.abgoogleGOe.abgoogleGOe.abgoogleGOe.abgoogleGOe.abgoogleG%"),  # > 64 B
    ]
    for seed in range(1, 5):
        var arr = StringArray.from_strings(_seeded_corpus(UInt64(seed), 700, 150))
        for i in range(len(patterns)):
            _check(arr, patterns[i], "seed " + String(seed))


def test_large_string_array_equals_reference() raises:
    var values = _seeded_corpus(UInt64(99), 500, 120)
    values.append(String("goo"))
    values.append(String("gle"))
    var arr = LargeStringArray.from_strings(values)
    var patterns: List[String] = [String("%google%"), String("%.google.%"), String("%oo%")]
    for i in range(len(patterns)):
        var reference = eval_large_string_like(arr, patterns[i], use_fastpath=False)
        var production = eval_large_string_like(arr, patterns[i])
        _assert_masks_equal(reference, production, "large pattern='" + patterns[i] + "'")
    var tail = eval_large_string_like(arr, "%google%")
    assert_false(tail.get(arr.length - 2))
    assert_false(tail.get(arr.length - 1))


def test_contains_fn_equals_like_reference() raises:
    # `contains(s, lit)` is `s LIKE '%lit%'` for a `%`/`_`-free literal.
    var arr = StringArray.from_strings(_seeded_corpus(UInt64(7), 600, 130))
    var needles: List[String] = [String("go"), String("google"), String(".google."), String("g")]
    for i in range(len(needles)):
        var reference = eval_string_like(arr, "%" + needles[i] + "%", use_fastpath=False)
        _assert_masks_equal(
            reference, eval_string_contains(arr, needles[i]), "contains '" + needles[i] + "'"
        )
    var straddle = StringArray.from_strings([String("goo"), String("gle")])
    var m = eval_string_contains(straddle, "google")
    assert_false(m.get(0))
    assert_false(m.get(1))
    var large = LargeStringArray.from_strings([String("goo"), String("gle"), String("a google")])
    var lm = eval_large_string_contains(large, "google")
    assert_false(lm.get(0))
    assert_false(lm.get(1))
    assert_true(lm.get(2))


# -----------------------------------------------------------------------------
# 3. THE ARM — both directions
# -----------------------------------------------------------------------------


def test_scan_arm_is_taken_for_bare_contains_only() raises:
    var arr = StringArray.from_strings(
        [String("http://www.google.com/"), String("yandex.ru"), String("")]
    )

    reset_contains_scan_call_count()
    _ = eval_string_like(arr, "%google%")
    assert_equal(contains_scan_call_count(), 1, "`%google%` must take the scan")

    reset_contains_scan_call_count()
    _ = eval_string_contains(arr, "google")
    assert_equal(contains_scan_call_count(), 1, "contains('google') must take the scan")

    # Every shape the scan must NOT answer: anchored, multi-segment, a 1-byte
    # needle, `_`, exact, and the reference arm itself.
    var not_scanned: List[String] = [
        String("http%"),
        String("%.ru"),
        String("%google%com%"),
        String("%g%"),
        String("%goo_le%"),
        String("yandex.ru"),
    ]
    reset_contains_scan_call_count()
    for i in range(len(not_scanned)):
        _ = eval_string_like(arr, not_scanned[i])
    _ = eval_string_like(arr, "%google%", use_fastpath=False)
    _ = eval_string_contains(arr, "g")
    assert_equal(contains_scan_call_count(), 0, "no non-bare shape may reach the scan")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
