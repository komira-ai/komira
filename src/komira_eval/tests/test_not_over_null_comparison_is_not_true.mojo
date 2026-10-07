# =============================================================================
# `NOT (x = '')` OVER A NULL ROW MUST NOT MATCH — negation needs 3VL
# =============================================================================
#
# THE SHAPE. The string kernels receive the validity bitmap, so a NULL row
# (Arrow stores it as an `(offset, length=0)` slot) is not mistaken for a
# genuine empty string and `NULL = ''` does not evaluate TRUE.
#
# That also makes THIS shape a trap, and the arithmetic is worth stating:
#
#     NOT (x = '')  over a NULL row, kernels blind to validity:  False (right)
#     NOT (x = '')  over a NULL row, validity but no 3VL NOT:    True  (WRONG)
#
# Blind to validity, the wrong TRUE from `NULL = ''` is flipped by the
# negation into a right FALSE — THE BUG CANCELS ITSELF THROUGH THE NOT.
# Removing the wrong TRUE without supplying three-valued logic leaves the
# negation flipping a correct FALSE into a wrong TRUE.
#
# ⚠ `NOT (x = 'bob')` over a NULL row is wrong either way without 3VL — the
# empty-literal case merely has a second bug cancelling it. So the defect
# under test is **negation over a comparison must implement 3VL**. Both
# literals are exercised below for exactly that reason.
#
# WHAT SQL SAYS. `NULL = ''` is UNKNOWN, `NOT UNKNOWN` is UNKNOWN, and a WHERE
# over UNKNOWN does not match. So the NULL row is EXCLUDED under both the
# comparison and its negation — it is not a row that flips sides.
#
# ⚠ THE CONSUMER IS THE CONSTRAINT, AND IT READS THE DATA BITMAP ONLY.
# `filter_to_indices` (`komira_column_kernels.comparison`) walks
# `mask.data` 64 bits at a time and never looks at `mask.validity`. So a
# nullable mask alone fixes NOTHING.
# The invariant this file pins is therefore the stronger one that survives
# that consumer:
#
#     A row whose predicate value is UNKNOWN carries data bit 0.
#     The validity bitmap says WHY it is 0 (unknown, not false).
#
# `eval_and` / `eval_or` already preserve it (their Kleene validity is
# computed from data bits that are 0 for the unknown side). `eval_not` did
# not: it inverted every data bit and copied validity through, so an UNKNOWN
# row came out data=1 / valid=0 and `filter_to_indices` selected it.
#
# ⚠ A NOT over a comparison on a NON-NULLABLE column cannot see this: it
# needs a NOT over a comparison against a NULL, which this file supplies.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.string_comparison import eval_string_eq
from komira_column_kernels.arithmetic import eval_not
from komira_column_kernels.comparison import filter_to_indices


def _fixture() raises -> StringArray[HeapRegion]:
    """`["alice", NULL, "", "bob"]` — row 1 NULL, row 2 a GENUINE empty string.

    The two must be distinguishable: that is the whole content of the validity bitmap and of
    this file. Any assertion that treats rows 1 and 2 alike is not testing
    anything.
    """
    var values: List[String] = ["alice", "", "", "bob"]
    var valid: List[Bool] = [True, False, True, True]
    return StringArray.from_strings_with_validity(values, valid)


def test_not_eq_empty_over_null_does_not_match() raises:
    """★ THE SELF-CANCELLING CASE. `NOT (x = '')`, NULL row.

    Rows: 0 "alice", 1 NULL, 2 "", 3 "bob".
    `x = ''` is TRUE only at row 2, so `NOT (x = '')` is TRUE at 0 and 3,
    FALSE at 2, and UNKNOWN at 1 — which a WHERE does not select.

    Before the fix this asserts False on row 1 and gets True.
    """
    var col = _fixture()
    var mask = eval_not(eval_string_eq(col, String("")))
    assert_equal(len(mask), 4)

    assert_true(mask.get(0))  # NOT ("alice" = '')  -> TRUE
    # ★ NOT (NULL = '') is UNKNOWN, and UNKNOWN does not match a WHERE.
    assert_false(mask.get(1))
    assert_false(mask.get(2))  # NOT ('' = '')      -> FALSE
    assert_true(mask.get(3))  # NOT ("bob" = '')   -> TRUE


def test_not_eq_literal_over_null_does_not_match() raises:
    """The PRE-EXISTING half: `NOT (x = 'bob')` over NULL was never right.

    ⚠ THE LITERAL IS NON-EMPTY ON PURPOSE, and it is the leg that proves the
    defect is 3VL and not "the empty-string special case". This one was wrong
    BEFORE the string-kernel validity fix too — there the child `NULL = 'bob'` was correctly
    FALSE (a NULL slot's length 0 != 3) and the NOT still flipped it to TRUE.
    No second bug was cancelling it, so it never had a right answer to lose.
    """
    var col = _fixture()
    var mask = eval_not(eval_string_eq(col, String("bob")))
    assert_equal(len(mask), 4)

    assert_true(mask.get(0))  # NOT ("alice" = 'bob') -> TRUE
    # ★ NOT (NULL = 'bob') is UNKNOWN.
    assert_false(mask.get(1))
    assert_true(mask.get(2))  # NOT (''      = 'bob') -> TRUE
    assert_false(mask.get(3))  # NOT ("bob"   = 'bob') -> FALSE


def test_the_consumer_that_actually_selects_rows_agrees() raises:
    """The assertion that survives `filter_to_indices` reading DATA only.

    `mask.get(i)` reads the data bit, so the two tests above already speak the
    consumer's language — but stating it through the real selector is what
    makes the invariant non-negotiable. If someone later "fixes" 3VL by
    setting only the validity bitmap and leaving data=1 on the UNKNOWN row,
    the tests above still pass and THIS one fails.
    """
    var col = _fixture()
    var idx = filter_to_indices(eval_not(eval_string_eq(col, String(""))))
    assert_equal(len(idx), 2)
    assert_equal(idx[0], 0)
    assert_equal(idx[1], 3)


def test_unknown_is_recorded_as_unknown_not_as_false() raises:
    """UNKNOWN and FALSE must stay DISTINGUISHABLE on the mask.

    Data bit 0 alone cannot tell `NOT ('' = '')` (row 2, genuinely FALSE)
    from `NOT (NULL = '')` (row 1, UNKNOWN). A WHERE treats them the same;
    Kleene AND/OR above this mask do NOT — `UNKNOWN OR TRUE` is TRUE while
    `FALSE OR TRUE` is also TRUE, but `UNKNOWN OR FALSE` is UNKNOWN where
    `FALSE OR FALSE` is FALSE. So the validity bitmap has to carry the
    difference, and `eval_or`/`eval_and` already read it.
    """
    var col = _fixture()

    var cmp = eval_string_eq(col, String(""))
    assert_true(Bool(cmp.validity), "the comparison mask must carry validity")
    assert_true(cmp.is_null(1), "row 1 is NULL, so `x = ''` there is UNKNOWN")
    assert_false(cmp.is_null(2), "row 2 is a real empty string, not UNKNOWN")

    var neg = eval_not(cmp)
    assert_true(Bool(neg.validity), "NOT must not drop the UNKNOWN")
    assert_true(neg.is_null(1), "NOT UNKNOWN is UNKNOWN")
    assert_false(neg.is_null(2))
    assert_equal(neg.null_count, 1)


def test_no_nulls_means_no_validity_and_an_unchanged_answer() raises:
    """The control: an all-valid column must pay nothing and change nothing.

    `from_strings_with_validity` with an all-True mask returns
    `validity=None`, the same shape `from_strings` produces, so both the
    comparison and its negation must come back non-nullable and identical to
    the pre-3VL answer. This is what proves the fix did not tax the hot path.
    """
    var values: List[String] = ["alice", "", "", "bob"]
    var valid: List[Bool] = [True, True, True, True]
    var col = StringArray.from_strings_with_validity(values, valid)

    var mask = eval_not(eval_string_eq(col, String("")))
    assert_false(Bool(mask.validity), "an all-valid column needs no mask validity")
    assert_equal(mask.null_count, 0)
    assert_true(mask.get(0))
    assert_false(mask.get(1))
    assert_false(mask.get(2))
    assert_true(mask.get(3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
