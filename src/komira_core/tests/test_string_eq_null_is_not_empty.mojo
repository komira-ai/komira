# =============================================================================
# `NULL = ''` MUST NOT BE TRUE, at the kernel.
# =============================================================================
#
# THE ROUTE. Three null implementations exist and only one is on the
# string-equality path:
#
#   PipelineCompiler predicate evaluation  `eval_string_eq(arr, str_val)`
#     -> komira_core.eval.string_comparison (a one-line `import *` shim)
#     -> komira_core.eval.string_comparison  `eval_string_eq`
#     -> komira_core.eval.string_comparison  `_string_eq_kernel`
#
# `komira_kernels.kleene` and `komira_core.eval.comparison` are the
# other two implementations and NEITHER is reached by a string comparison.
#
# THE DEFECT IS IN THE SIGNATURE, NOT IN THE LOOP. `_string_eq_kernel` takes
# `(length, offsets, data, val)` — the validity bitmap is never passed, so the
# kernel CANNOT consult it. The string `validity` does not occur even once in
# the whole 47KB file (`grep -c validity` = 0). Arrow stores a NULL string as
# an `(offset, length=0)` slot, so `_string_bytes_equal(.., elem_len=0, "", 0)`
# returns TRUE and every NULL row matches the empty string.
#
# CONSEQUENCE: over a column holding exactly 6364 NULL and 6364 empty
# values, `WHERE name_n = ''` would return 12728 (NULL + empty) where SQL
# says 6364, while `name_n IS NULL` correctly returns 6364: the validity
# bitmap is present and correct in the very same column.
# It is read by the IS NULL arm and dropped by the `=` arm.
#
# The second assertion (`!= ''`) is the half that a data[] -only "fix" would
# silently get wrong: under three-valued logic NULL != '' is NOT TRUE either,
# so a kernel that merely inverts the eq mask turns one wrong answer into two.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import StringArray, BooleanArray
from komira_core.eval import eval_string_eq, eval_string_ne


def _count_true(mask: BooleanArray) raises -> Int:
    var count = 0
    for i in range(mask.length):
        if mask.get(i):
            count += 1
    return count


def test_null_string_does_not_equal_empty_string() raises:
    """`NULL = ''` must not be TRUE. SQ07, reduced to one kernel call.

    Row 1 is NULL; row 2 is a genuine empty string. Exactly ONE row may match
    `= ''`. Before the fix this counts 2 — the same 2x that turns 6364 into
    12728 on the parquet fixture.
    """
    var values: List[String] = ["alice", "", "", "bob"]
    var valid: List[Bool] = [True, False, True, True]
    var col = StringArray.from_strings_with_validity(values, valid)

    var result = eval_string_eq(col, String(""))
    assert_equal(len(result), 4)

    assert_false(result.get(0))  # "alice" != ""
    # ★ THE DEFECT: row 1 is NULL, and NULL = '' is not TRUE.
    assert_false(result.get(1))
    assert_true(result.get(2))  # a real empty string DOES match
    assert_false(result.get(3))  # "bob" != ""

    # The whole point, as a count: one row, not two.
    assert_equal(_count_true(result), 1)


def test_null_string_does_not_not_equal_a_literal() raises:
    """`NULL != 'bob'` must not be TRUE either — the three-valued other half.

    ⚠ THE LITERAL HERE IS DELIBERATELY NON-EMPTY, and the first draft of this
    file got it wrong. `_string_ne_kernel` is `_string_eq_kernel` modulo one
    `not`, so against `''` the NULL row's `elem_len == 0` compares EQUAL and
    the `ne` mask comes back FALSE — the right answer for the wrong reason,
    and the test PASSED while the defect was fully present. Against a
    non-empty literal the same NULL row compares UNEQUAL and the kernel
    reports TRUE, which is the actual defect.

    Only rows 0 and 2 ("alice", "") may match `!= 'bob'`.
    """
    var values: List[String] = ["alice", "", "", "bob"]
    var valid: List[Bool] = [True, False, True, True]
    var col = StringArray.from_strings_with_validity(values, valid)

    var result = eval_string_ne(col, String("bob"))
    assert_equal(len(result), 4)

    assert_true(result.get(0))  # "alice" != "bob"
    # ★ NULL != 'bob' is NOT TRUE under three-valued logic.
    assert_false(result.get(1))
    assert_true(result.get(2))  # "" != "bob"
    assert_false(result.get(3))  # "bob" != "bob"

    assert_equal(_count_true(result), 2)


def test_eq_over_a_column_with_no_nulls_is_unchanged() raises:
    """The all-valid fast path must not regress — the control for the two above.

    `from_strings_with_validity` with an all-True mask returns `validity=None`,
    which is the byte-identical shape `from_strings` produces. This test is
    GREEN today and must stay green: it is what proves a validity-consulting
    fix did not cost the non-null path its answer.
    """
    var values: List[String] = ["alice", "", "", "bob"]
    var valid: List[Bool] = [True, True, True, True]
    var col = StringArray.from_strings_with_validity(values, valid)

    var result = eval_string_eq(col, String(""))
    assert_equal(_count_true(result), 2)
    assert_true(result.get(1))
    assert_true(result.get(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
