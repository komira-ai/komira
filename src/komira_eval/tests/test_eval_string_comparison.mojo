# =============================================================================
# Tests for string comparison eval — eval_string_eq/ne/gt/lt/ge/le
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import StringArray, LargeStringArray, BooleanArray
from komira_core.eval import eval_string_eq, eval_string_ne, eval_string_gt, eval_string_lt, eval_string_ge, eval_string_le

# ★ THE EIGHT PATTERN ENTRY POINTS. Imported from
# `komira_core.eval.string_comparison` rather than from the `komira_eval`
# facade because the facade re-exports the four Int32 spellings only, and the
# four Int64 (LARGE_STRING) siblings are HALF of what this file now gates.
#
# ⛔⛔ A CORRECTION: this note used to say the Int64 siblings "have
# no SQL spelling". THE SPELLING IS NOT WHAT IS MISSING. `sql_fn_table.mojo`
# binds `contains` / `starts_with` / `prefix` / `ends_with` / `suffix`, and
# `compiler_eval_predicate.mojo`'s EXPR_STRING_OP arm routes every one of them
# to the Int64 sibling when the COLUMN is LARGE_STRING. What is missing is an
# end-to-end INGRESS that produces such a column: `Session.read_parquet` is the
# only one the e2e gate has, and the parquet decode path names
# `ArrowType.STRING` for every BYTE_ARRAY leaf. So these four are unreachable
# from `//tests:pyffi_test_null_pattern_semantics` today — but by an ingress
# gap, which a new reader could close, and not by a naming gap, which would
# make this file the only possible gate forever. The other four ARE swept
# end-to-end there; that gate is not LIKE-only.
from komira_core.eval.string_comparison import (
    eval_string_contains, eval_string_starts_with, eval_string_ends_with,
    eval_string_like,
    eval_large_string_contains, eval_large_string_starts_with,
    eval_large_string_ends_with, eval_large_string_like,
)
from komira_core.eval.arithmetic import eval_not


# =============================================================================
# Helper
# =============================================================================


def _count_true(mask: BooleanArray) raises -> Int:
    """Count the number of True bits in a BooleanArray."""
    var count = 0
    for i in range(mask.length):
        if mask.get(i):
            count += 1
    return count


# =============================================================================
# eval_string_eq tests
# =============================================================================


def test_string_eq_match_some() raises:
    """eval_string_eq: matches specific strings in a mixed column."""
    var values: List[String] = ["alice", "bob", "alice", "charlie", "alice"]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("alice"))
    assert_equal(len(result), 5)
    assert_true(result.get(0))    # "alice" == "alice"
    assert_false(result.get(1))   # "bob" != "alice"
    assert_true(result.get(2))    # "alice" == "alice"
    assert_false(result.get(3))   # "charlie" != "alice"
    assert_true(result.get(4))    # "alice" == "alice"
    assert_equal(_count_true(result), 3)


def test_string_eq_match_none() raises:
    """eval_string_eq: no matches when value not in column."""
    var values: List[String] = ["alice", "bob", "charlie"]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("dave"))
    assert_equal(_count_true(result), 0)


def test_string_eq_match_all() raises:
    """eval_string_eq: all rows match when all values are the same."""
    var values: List[String] = ["F", "F", "F", "F"]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("F"))
    assert_equal(_count_true(result), 4)


def test_string_eq_single_char() raises:
    """eval_string_eq: single-character strings (common TPC-H flags)."""
    var values: List[String] = ["F", "O", "F", "N", "O", "F"]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("F"))
    assert_equal(len(result), 6)
    assert_true(result.get(0))    # "F"
    assert_false(result.get(1))   # "O"
    assert_true(result.get(2))    # "F"
    assert_false(result.get(3))   # "N"
    assert_false(result.get(4))   # "O"
    assert_true(result.get(5))    # "F"
    assert_equal(_count_true(result), 3)


def test_string_eq_empty_strings() raises:
    """eval_string_eq: matching against empty string."""
    var values: List[String] = ["", "hello", "", "world", ""]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String(""))
    assert_true(result.get(0))    # "" == ""
    assert_false(result.get(1))   # "hello" != ""
    assert_true(result.get(2))    # "" == ""
    assert_false(result.get(3))   # "world" != ""
    assert_true(result.get(4))    # "" == ""
    assert_equal(_count_true(result), 3)


def test_string_eq_empty_column() raises:
    """eval_string_eq: empty array returns empty BooleanArray."""
    var values: List[String] = []
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("anything"))
    assert_equal(len(result), 0)


# =============================================================================
# eval_string_ne tests
# =============================================================================


def test_string_ne_inverse_of_eq() raises:
    """eval_string_ne: inverse of eq — all non-matching rows are True."""
    var values: List[String] = ["alice", "bob", "alice", "charlie"]
    var col = StringArray.from_strings(values)
    var result = eval_string_ne(col, String("alice"))
    assert_equal(len(result), 4)
    assert_false(result.get(0))   # "alice" == "alice" -> ne=false
    assert_true(result.get(1))    # "bob" != "alice" -> ne=true
    assert_false(result.get(2))   # "alice" == "alice" -> ne=false
    assert_true(result.get(3))    # "charlie" != "alice" -> ne=true
    assert_equal(_count_true(result), 2)


def test_string_ne_all_different() raises:
    """eval_string_ne: all rows pass when none match."""
    var values: List[String] = ["a", "b", "c"]
    var col = StringArray.from_strings(values)
    var result = eval_string_ne(col, String("z"))
    assert_equal(_count_true(result), 3)


# =============================================================================
# eval_string_gt tests (lexicographic comparison)
# =============================================================================


def test_string_gt_basic() raises:
    """eval_string_gt: lexicographic greater-than comparison."""
    var values: List[String] = ["apple", "banana", "cherry", "avocado"]
    var col = StringArray.from_strings(values)
    var result = eval_string_gt(col, String("banana"))
    assert_equal(len(result), 4)
    assert_false(result.get(0))   # "apple" > "banana" = false
    assert_false(result.get(1))   # "banana" > "banana" = false (not strictly greater)
    assert_true(result.get(2))    # "cherry" > "banana" = true
    assert_false(result.get(3))   # "avocado" > "banana" = false
    assert_equal(_count_true(result), 1)


def test_string_gt_prefix_comparison() raises:
    """eval_string_gt: shorter string is less than longer with same prefix."""
    var values: List[String] = ["ab", "abc", "abcd", "a"]
    var col = StringArray.from_strings(values)
    var result = eval_string_gt(col, String("ab"))
    assert_equal(len(result), 4)
    assert_false(result.get(0))   # "ab" > "ab" = false (equal)
    assert_true(result.get(1))    # "abc" > "ab" = true (longer prefix)
    assert_true(result.get(2))    # "abcd" > "ab" = true
    assert_false(result.get(3))   # "a" > "ab" = false (shorter)
    assert_equal(_count_true(result), 2)


# =============================================================================
# eval_string_lt tests (lexicographic comparison)
# =============================================================================


def test_string_lt_basic() raises:
    """eval_string_lt: lexicographic less-than comparison."""
    var values: List[String] = ["apple", "banana", "cherry", "avocado"]
    var col = StringArray.from_strings(values)
    var result = eval_string_lt(col, String("banana"))
    assert_equal(len(result), 4)
    assert_true(result.get(0))    # "apple" < "banana" = true
    assert_false(result.get(1))   # "banana" < "banana" = false
    assert_false(result.get(2))   # "cherry" < "banana" = false
    assert_true(result.get(3))    # "avocado" < "banana" = true
    assert_equal(_count_true(result), 2)


def test_string_lt_empty_vs_nonempty() raises:
    """eval_string_lt: empty string is less than any non-empty string."""
    var values: List[String] = ["", "a", "", "hello"]
    var col = StringArray.from_strings(values)
    var result = eval_string_lt(col, String("a"))
    assert_equal(len(result), 4)
    assert_true(result.get(0))    # "" < "a" = true
    assert_false(result.get(1))   # "a" < "a" = false (equal)
    assert_true(result.get(2))    # "" < "a" = true
    # "hello" > "a" lexicographically because 'h' > 'a'
    assert_false(result.get(3))   # "hello" < "a" = false


def test_string_lt_prefix() raises:
    """eval_string_lt: shorter string with same prefix is less than longer."""
    var values: List[String] = ["abc", "ab", "a", "abcd"]
    var col = StringArray.from_strings(values)
    var result = eval_string_lt(col, String("abc"))
    assert_equal(len(result), 4)
    assert_false(result.get(0))   # "abc" < "abc" = false (equal)
    assert_true(result.get(1))    # "ab" < "abc" = true (shorter prefix)
    assert_true(result.get(2))    # "a" < "abc" = true (shorter prefix)
    assert_false(result.get(3))   # "abcd" < "abc" = false (longer)
    assert_equal(_count_true(result), 2)


# =============================================================================
# eval_string_ge/le tests
# =============================================================================


def test_string_ge_basic() raises:
    """eval_string_ge: greater-than-or-equal (includes equality)."""
    var values: List[String] = ["apple", "banana", "cherry"]
    var col = StringArray.from_strings(values)
    var result = eval_string_ge(col, String("banana"))
    assert_false(result.get(0))   # "apple" >= "banana" = false
    assert_true(result.get(1))    # "banana" >= "banana" = true
    assert_true(result.get(2))    # "cherry" >= "banana" = true
    assert_equal(_count_true(result), 2)


def test_string_le_basic() raises:
    """eval_string_le: less-than-or-equal (includes equality)."""
    var values: List[String] = ["apple", "banana", "cherry"]
    var col = StringArray.from_strings(values)
    var result = eval_string_le(col, String("banana"))
    assert_true(result.get(0))    # "apple" <= "banana" = true
    assert_true(result.get(1))    # "banana" <= "banana" = true
    assert_false(result.get(2))   # "cherry" <= "banana" = false
    assert_equal(_count_true(result), 2)


# =============================================================================
# Boundary / edge case tests
# =============================================================================


def test_string_eq_boundary_9_elements() raises:
    """eval_string_eq: 9 elements tests remainder path (1 full byte + 1 bit)."""
    var values: List[String] = ["a", "b", "c", "d", "e", "f", "g", "h", "a"]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("a"))
    assert_equal(len(result), 9)
    assert_true(result.get(0))    # "a" match
    assert_false(result.get(1))   # "b"
    assert_false(result.get(7))   # "h"
    assert_true(result.get(8))    # "a" match (in remainder)
    assert_equal(_count_true(result), 2)


def test_string_eq_boundary_16_elements() raises:
    """eval_string_eq: 16 elements (2 full bytes, no remainder)."""
    var values: List[String] = [
        "x", "y", "x", "z", "x", "y", "z", "x",
        "y", "x", "z", "x", "y", "z", "x", "y",
    ]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("x"))
    assert_equal(len(result), 16)
    # "x" is at indices: 0, 2, 4, 7, 9, 11, 14 = 7 matches
    assert_true(result.get(0))
    assert_false(result.get(1))
    assert_true(result.get(2))
    assert_equal(_count_true(result), 7)


def test_string_gt_unicode_bytes() raises:
    """eval_string_gt: ASCII byte ordering (Unicode codepoints > 127 are higher bytes)."""
    # UTF-8 byte ordering: these are all ASCII, so byte order == char order
    var values: List[String] = ["A", "Z", "a", "z"]
    var col = StringArray.from_strings(values)
    var result = eval_string_gt(col, String("Z"))
    # In byte order: 'A'=0x41, 'Z'=0x5A, 'a'=0x61, 'z'=0x7A
    # Only 'a' and 'z' are > 'Z' in byte ordering
    assert_false(result.get(0))   # "A" > "Z" = false
    assert_false(result.get(1))   # "Z" > "Z" = false
    assert_true(result.get(2))    # "a" > "Z" = true
    assert_true(result.get(3))    # "z" > "Z" = true
    assert_equal(_count_true(result), 2)


def test_string_eq_length_mismatch_shortcircuit() raises:
    """eval_string_eq: length mismatch causes fast rejection (no byte compare)."""
    var values: List[String] = ["hi", "hello", "hey", "h", "hello"]
    var col = StringArray.from_strings(values)
    var result = eval_string_eq(col, String("hello"))
    assert_equal(len(result), 5)
    assert_false(result.get(0))   # "hi" (len=2 != 5)
    assert_true(result.get(1))    # "hello" (len=5 == 5, bytes match)
    assert_false(result.get(2))   # "hey" (len=3 != 5)
    assert_false(result.get(3))   # "h" (len=1 != 5)
    assert_true(result.get(4))    # "hello" (len=5 == 5, bytes match)
    assert_equal(_count_true(result), 2)


# =============================================================================
# ★ A NULL SATISFIES NO PATTERN PREDICATE — the eight pattern entry points
#
# =============================================================================
#
# THE DEFECT. Arrow stores a NULL string as an `(offset, length = 0)` slot, so
# a NULL row is BYTE-IDENTICAL to a genuine empty string in the offsets+data
# buffers these kernels read. `_apply_validity` was wired at all TWELVE
# relational entry points above and at NONE of these EIGHT, so:
#
#   * a pattern that MATCHES the empty string (`''`, `'%'`, and every
#     `contains` pattern, whose `pat_len == 0` arm returns True) selected the
#     NULL rows outright;
#   * every OTHER pattern returned a definite FALSE at a NULL row, which is the
#     right ROW SET at a bare filter and a WRONG VALUE one `NOT` away.
#
# ⚠ WHY BOTH HALVES ARE ASSERTED AT EVERY CELL. A DATA clear without the
# VALIDITY attach for the relational ops is still wrong under a negation — `eval_not` re-selects a row whose bit is 0 unless a
# validity bitmap says it is UNKNOWN rather than FALSE. So each cell checks
# `is_null(i)` (the validity half) AND `get(i) == False` (the data half), and
# then runs the mask through `eval_not` and checks the row is STILL not
# selected. Asserting only one half passes over a half fix.
#
# ⚠ THE ALL-VALID FAST PATH IS ASSERTED TOO, and it is not a nicety: it is what
# makes this repair free on a column with no nulls, and `_apply_validity`
# returning the kernel's mask untouched is the thing a future reader would
# "simplify" by attaching an all-ones bitmap.
# =============================================================================


def _valid_all_but(n: Int, nulls: List[Int]) raises -> List[Bool]:
    """A per-row validity list of length `n`, False at each index in `nulls`."""
    var out = List[Bool]()
    for i in range(n):
        var is_null = False
        for j in range(len(nulls)):
            if nulls[j] == i:
                is_null = True
        out.append(not is_null)
    return out^


def _assert_unknown_at(mask: BooleanArray, idx: Int, what: String) raises:
    """Both halves of this repo's UNKNOWN encoding, plus the negation.

    DATA BIT 0 is what `filter_to_indices` obeys; the cleared VALIDITY bit is
    what `eval_not` / `eval_and` / `eval_or` obey. A mask carrying only the
    first comes back SELECTED through a `NOT`.
    """
    assert_false(mask.get(idx), what + ": data bit set on a NULL row")
    assert_true(mask.is_null(idx), what + ": validity bit set on a NULL row")
    var negated = eval_not(mask)
    assert_false(
        negated.get(idx), what + ": NOT re-selected a NULL row (NOT UNKNOWN is UNKNOWN)"
    )


def _assert_true_and_valid_at(
    mask: BooleanArray, idx: Int, what: String, expect_nulls: Int
) raises:
    """A definite TRUE at `idx` — data bit set AND validity bit set.

    ⛔ `expect_nulls` is EXACT, not a floor. A kernel that nulled the genuine
    `''` row out would satisfy every NULL-row assertion in this file, because
    every one of those only looks at the rows that ARE null.
    """
    assert_true(mask.get(idx), what + ": the genuine '' row is not TRUE")
    assert_false(mask.is_null(idx), what + ": the genuine '' row was nulled")
    assert_equal(
        mask.null_count,
        expect_nulls,
        what + ": null_count moved off the declared NULL rows",
    )


def test_pattern_kernels_report_UNKNOWN_at_every_null_row() raises:
    """All four Int32 pattern entry points, over a nullable column.

    Row 1 and row 4 are NULL. The patterns are chosen so that the two failure
    modes are BOTH present: `''` and `'%'` MATCH the zero-length slot a NULL
    occupies (the kernel said TRUE), and `'z%'` / `'zz'` do not (the kernel
    said a definite FALSE, wrong only under a negation).
    """
    var values: List[String] = ["zzz", "", "zab", "bbb", "", "aaa"]
    var valid = _valid_all_but(6, [1, 4])
    var col = StringArray.from_strings_with_validity(values, valid)

    _assert_unknown_at(eval_string_like(col, String("")), 1, "like ''")
    _assert_unknown_at(eval_string_like(col, String("")), 4, "like ''")
    _assert_unknown_at(eval_string_like(col, String("%")), 1, "like '%'")
    _assert_unknown_at(eval_string_like(col, String("z%")), 1, "like 'z%'")
    _assert_unknown_at(eval_string_contains(col, String("")), 1, "contains ''")
    _assert_unknown_at(eval_string_contains(col, String("z")), 4, "contains 'z'")
    _assert_unknown_at(eval_string_starts_with(col, String("")), 1, "starts_with ''")
    _assert_unknown_at(eval_string_starts_with(col, String("z")), 4, "starts_with 'z'")
    _assert_unknown_at(eval_string_ends_with(col, String("")), 1, "ends_with ''")
    _assert_unknown_at(eval_string_ends_with(col, String("b")), 4, "ends_with 'b'")

    # ⚠ AND THE NON-NULL ROWS MUST STILL ANSWER. A repair that cleared the whole
    # mask would satisfy every assertion above.
    var lk = eval_string_like(col, String("z%"))
    assert_true(lk.get(0), "row 0 'zzz' LIKE 'z%'")
    assert_true(lk.get(2), "row 2 'zab' LIKE 'z%'")
    assert_false(lk.get(3), "row 3 'bbb' LIKE 'z%'")
    assert_false(lk.get(5), "row 5 'aaa' LIKE 'z%'")
    assert_equal(lk.null_count, 2)


def test_a_GENUINE_EMPTY_STRING_is_NOT_A_NULL_at_every_pattern_kernel() raises:
    """⛔⛔ THE DISCRIMINATION THE 8-ENTRY-POINT CELL ABOVE CANNOT MAKE.

    ⚠ SCOPE FIRST, BECAUSE THIS FILE ALREADY HAS A CELL FOR THE DISTINCTION AND
    THIS IS NOT A DUPLICATE OF IT. `test_a_NULL_is_not_a_genuine_EMPTY_STRING_
    under_a_pattern` (below) makes it — for `eval_string_like(col, "")`, ONE
    pattern at ONE of the eight entry points, Int32 only. These two cells widen
    that to FIVE patterns (`''`, `'%'`, contains/starts_with/ends_with `''`)
    across BOTH width families, which is the surface `_apply_validity` is
    wired into.

    ⚠ LOOK AT THE FIXTURE ABOVE: `["zzz", "", "zab", "bbb", "", "aaa"]` with
    NULLs at 1 and 4 — and 1 and 4 ARE the two `""` entries. So the cell that
    sweeps all eight entry points holds NO zero-length row that is VALID, and
    every assertion in it is satisfied equally by the correct repair ("a NULL is
    UNKNOWN") and by a wrong one that reported UNKNOWN for EVERY ZERO-LENGTH
    ROW. Both would be green there. That is not a coincidence: an
    `(offset, length = 0)` slot
    is what a NULL and a `''` share, so a fixture written to exercise NULLs
    lands on it by default.

    Here row 2 is a GENUINE `''` — valid, zero length — sitting between the two
    NULLs. Every pattern that matches the empty string must return a definite
    TRUE there, with the validity bit SET, while rows 1 and 4 stay UNKNOWN.

    ⛔ `null_count == 2`, NOT `>= 2`, is the load-bearing line: a kernel that
    nulled the `''` row out would satisfy every per-row assertion below that
    only checks the NULL rows.
    """
    var values: List[String] = ["zzz", "", "", "bbb", "", "aaa"]
    var valid = _valid_all_but(6, [1, 4])
    var col = StringArray.from_strings_with_validity(values, valid)

    _assert_true_and_valid_at(eval_string_like(col, String("")), 2, "like ''", 2)
    _assert_true_and_valid_at(eval_string_like(col, String("%")), 2, "like '%'", 2)
    _assert_true_and_valid_at(
        eval_string_contains(col, String("")), 2, "contains ''", 2
    )
    _assert_true_and_valid_at(
        eval_string_starts_with(col, String("")), 2, "starts_with ''", 2
    )
    _assert_true_and_valid_at(
        eval_string_ends_with(col, String("")), 2, "ends_with ''", 2
    )

    # ...and the NULL rows are still UNKNOWN under the same patterns, so this
    # cell cannot be satisfied by a kernel that simply stopped applying
    # validity at all.
    _assert_unknown_at(eval_string_like(col, String("")), 1, "'' vs NULL: like ''")
    _assert_unknown_at(eval_string_like(col, String("%")), 4, "'' vs NULL: like '%'")
    _assert_unknown_at(eval_string_contains(col, String("")), 4, "'' vs NULL: contains ''")
    _assert_unknown_at(
        eval_string_starts_with(col, String("")), 1, "'' vs NULL: starts_with ''"
    )
    _assert_unknown_at(eval_string_ends_with(col, String("")), 1, "'' vs NULL: ends_with ''")

    # A pattern that does NOT match the empty string must be a definite FALSE
    # there — the opposite direction, so the cell sees both failure modes.
    var mz = eval_string_like(col, String("z%"))
    assert_false(mz.get(2), "the genuine '' row matched 'z%'")
    assert_false(mz.is_null(2), "the genuine '' row was nulled by 'z%'")
    assert_true(mz.get(0), "row 0 'zzz' LIKE 'z%'")


def test_a_GENUINE_EMPTY_STRING_is_NOT_A_NULL_at_the_LARGE_STRING_kernels() raises:
    """The Int64-offset half of the cell above. Same fixture, same claim.

    ⚠ THIS IS THE HALF NO END-TO-END GATE CAN COVER, and the reason is an
    INGRESS, not a spelling — see the note on the next cell. It is also the half
    `test_a_NULL_is_not_a_genuine_EMPTY_STRING_under_a_pattern` does not reach:
    that cell is Int32-only, so before this one NOTHING anywhere separated a
    NULL from a `''` at an Int64-offset kernel.
    """
    var values: List[String] = ["zzz", "", "", "bbb", "", "aaa"]
    var valid = _valid_all_but(6, [1, 4])
    var col = LargeStringArray.from_strings_with_validity(values, valid)

    _assert_true_and_valid_at(
        eval_large_string_like(col, String("")), 2, "L like ''", 2
    )
    _assert_true_and_valid_at(
        eval_large_string_like(col, String("%")), 2, "L like '%'", 2
    )
    _assert_true_and_valid_at(
        eval_large_string_contains(col, String("")), 2, "L contains ''", 2
    )
    _assert_true_and_valid_at(
        eval_large_string_starts_with(col, String("")), 2, "L starts_with ''", 2
    )
    _assert_true_and_valid_at(
        eval_large_string_ends_with(col, String("")), 2, "L ends_with ''", 2
    )

    _assert_unknown_at(eval_large_string_like(col, String("")), 1, "L '' vs NULL: like ''")
    _assert_unknown_at(
        eval_large_string_contains(col, String("")), 4, "L '' vs NULL: contains ''"
    )


def test_LARGE_STRING_pattern_kernels_report_UNKNOWN_at_every_null_row() raises:
    """The four Int64-offset siblings — HALF the repaired surface.

    ⛔ A CORRECTION: this docstring said they are "the half no SQL
    text can reach, because `LIKE` binds to a STRING column". THAT IS NOT WHY.
    `sql_fn_table.mojo` binds `contains` / `starts_with` / `prefix` /
    `ends_with` / `suffix` by NAME, and `compiler_eval_predicate`'s
    `EXPR_STRING_OP` arm routes every one of them — `LIKE` included — to the
    Int64 sibling when the COLUMN is LARGE_STRING. What no end-to-end gate can
    reach is a LARGE_STRING COLUMN: `Session.read_parquet` is the only ingress
    those gates have, and `decode_helpers._parquet_type_to_arrow_type_opt` maps
    BYTE_ARRAY -> `ArrowType.STRING` UNCONDITIONALLY (there is no
    annotation-aware arm; the invariant is spelled out at
    `komira_parquet.band_producer`'s `_emit_band` note, which depends on
    it). So this cell is load-bearing because of an ingress
    gap that a new reader could close — not a naming gap that would make this
    file the only possible gate forever."""
    var values: List[String] = ["zzz", "", "zab", "bbb", "", "aaa"]
    var valid = _valid_all_but(6, [1, 4])
    var col = LargeStringArray.from_strings_with_validity(values, valid)

    _assert_unknown_at(eval_large_string_like(col, String("")), 1, "L like ''")
    _assert_unknown_at(eval_large_string_like(col, String("%")), 4, "L like '%'")
    _assert_unknown_at(eval_large_string_like(col, String("z%")), 1, "L like 'z%'")
    _assert_unknown_at(eval_large_string_contains(col, String("")), 4, "L contains ''")
    _assert_unknown_at(eval_large_string_contains(col, String("z")), 1, "L contains 'z'")
    _assert_unknown_at(
        eval_large_string_starts_with(col, String("")), 1, "L starts_with ''"
    )
    _assert_unknown_at(
        eval_large_string_starts_with(col, String("z")), 4, "L starts_with 'z'"
    )
    _assert_unknown_at(eval_large_string_ends_with(col, String("")), 4, "L ends_with ''")
    _assert_unknown_at(eval_large_string_ends_with(col, String("b")), 1, "L ends_with 'b'")

    var lk = eval_large_string_like(col, String("z%"))
    assert_true(lk.get(0), "L row 0 'zzz' LIKE 'z%'")
    assert_true(lk.get(2), "L row 2 'zab' LIKE 'z%'")
    assert_equal(lk.null_count, 2)


def test_a_NULL_is_not_a_genuine_EMPTY_STRING_under_a_pattern() raises:
    """The distinction the whole defect erased, asserted directly.

    Rows 0 and 2 hold a REAL empty string; rows 1 and 3 are NULL. In the
    offsets+data buffers all four are `(offset, length = 0)`. `LIKE ''` must
    select the first two and answer UNKNOWN for the other two.
    """
    var values: List[String] = ["", "", "", "", "q"]
    var valid = _valid_all_but(5, [1, 3])
    var col = StringArray.from_strings_with_validity(values, valid)

    var m = eval_string_like(col, String(""))
    assert_true(m.get(0), "a real empty string DOES match LIKE ''")
    assert_true(m.get(2), "a real empty string DOES match LIKE ''")
    assert_false(m.get(4), "'q' does not match LIKE ''")
    _assert_unknown_at(m, 1, "null vs empty, row 1")
    _assert_unknown_at(m, 3, "null vs empty, row 3")
    assert_equal(m.null_count, 2)


def test_an_all_valid_column_pays_nothing_and_attaches_no_bitmap() raises:
    """⚠ THE FAST PATH IS PART OF THE CONTRACT. `_apply_validity` returns the
    kernel's mask untouched when the column has no validity bitmap, so a column
    with no nulls is byte-identical to the pre-fix answer and costs nothing.
    Attaching an all-ones bitmap "for uniformity" would make every downstream
    `if not mask.validity` short-circuit — including the four in
    `_eval_short_circuit_{and,or}` — go dark on data that has no nulls at all.
    """
    var values: List[String] = ["zzz", "abc", "zab", "bbb"]
    var col = StringArray.from_strings(values)
    var m = eval_string_like(col, String("z%"))
    assert_false(Bool(m.validity), "an all-valid column must get NO validity bitmap")
    assert_equal(m.null_count, 0)
    assert_equal(_count_true(m), 2)

    var lcol = LargeStringArray.from_strings(values)
    var lm = eval_large_string_like(lcol, String("z%"))
    assert_false(Bool(lm.validity), "all-valid LARGE_STRING must get NO bitmap")
    assert_equal(_count_true(lm), 2)


def test_pattern_null_semantics_hold_across_a_word_boundary() raises:
    """⚠ EVERY FIXTURE IN THIS AREA WAS EXACTLY 8 ROWS — one bitmap byte — so a
    defect confined to the trailing partial word could not be observed at all.

    This sweeps lengths straddling the byte and 64-bit-word boundaries from
    both sides and puts a NULL in the LAST row of every one of them, which is
    the position `_apply_validity`'s trailing-bit mask (`length & 7`) governs
    and where an off-by-one shows up as a selected NULL.
    """
    var lengths: List[Int] = [5, 6, 7, 8, 9, 12, 13, 15, 16, 17, 24, 25,
                              63, 64, 65, 127, 128, 129]
    var checked = 0
    var covered = 0
    for li in range(len(lengths)):
        var n = lengths[li]
        var values = List[String]()
        var nulls = List[Int]()
        for i in range(n):
            values.append(String("z") if (i % 3) else String("a"))
            # Every third row NULL, AND always the last row, so the trailing
            # partial byte is never all-valid.
            if (i % 3) == 2 or i == n - 1:
                nulls.append(i)
        var col = StringArray.from_strings_with_validity(
            values, _valid_all_but(n, nulls)
        )
        # A pattern that MATCHES the empty slot, and one that does not.
        var m_empty = eval_string_like(col, String(""))
        var m_z = eval_string_like(col, String("z%"))
        var negated = eval_not(m_z)
        for j in range(len(nulls)):
            var idx = nulls[j]
            assert_false(m_empty.get(idx), "n=" + String(n) + " LIKE '' selected a NULL")
            assert_true(m_empty.is_null(idx), "n=" + String(n) + " LIKE '' lost validity")
            assert_false(m_z.get(idx), "n=" + String(n) + " LIKE 'z%' selected a NULL")
            assert_false(negated.get(idx), "n=" + String(n) + " NOT LIKE resurrected a NULL")
            checked += 1
        # ⛔ AND THE SWEEP MUST NOT BE VACUOUS: the LAST row is a NULL at every
        # length, so the trailing partial byte is exercised at every one.
        assert_true(m_empty.is_null(n - 1), "n=" + String(n) + " last row not covered")
        covered += 1
    # ⛔ THE SWEEP MUST BE THE SWEEP IT CLAIMS. Both totals are EXACT for this
    # deterministic fixture — 733 rows over 18 lengths, of which 250 are NULL
    # (every third row, plus the last row of each length). An inequality here
    # would let the loop silently shrink; this is the arithmetic, so it cannot.
    assert_equal(covered, len(lengths), "not every sweep length ran")
    assert_equal(checked, 250, "word-boundary sweep did not check every NULL row")


# =============================================================================
# Main
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
