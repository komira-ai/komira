# =============================================================================
# src/kci_api/tests/test_exit_table.mojo
#   The ONE exit table, pinned by value: a renumbering is an edit of this
#   golden, never a side effect.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    ERROR_INTERNAL,
    ERROR_PUBLISH_READ_BACK,
    ERROR_USAGE,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_PARTIAL,
    EXIT_REFUSED,
    OUTCOME_CANCELLED,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_INTERRUPTED,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
    OUTCOME_VALIDATION_FAILED,
    RETRY_NEEDS_HUMAN,
    RETRY_SAFE,
    RETRY_UNSAFE,
    all_outcomes,
    default_retry,
    exit_code_of,
    exit_table,
    outcome_rank,
    promises_no_effect,
    require_outcome,
    require_retry_for,
    worst_outcome,
)


def _raises_with(outcome: String, needle: String) -> Bool:
    try:
        require_outcome(outcome)
    except e:
        return String(e).find(needle) >= 0
    return False


def test_golden_numbers() raises:
    var t = exit_table()
    assert_equal(len(t), 9)
    var names = List[String]()
    names.append(String("EXIT_OK"))
    names.append(String("EXIT_INTERNAL"))
    names.append(String("EXIT_USAGE"))
    names.append(String("EXIT_REFUSED"))
    names.append(String("EXIT_FAILED"))
    names.append(String("EXIT_CANNOT_TELL"))
    names.append(String("EXIT_PARTIAL"))
    names.append(String("EXIT_VALIDATION_FAILED"))
    names.append(String("EXIT_LEFT_BEHIND"))
    for i in range(len(t)):
        assert_equal(t[i].code, i)
        assert_equal(t[i].name, names[i])
        assert_true(t[i].meaning.byte_length() > 0)


def test_exactly_2_3_and_4_promise_no_effect() raises:
    # the numbers whose meaning says nothing external landed; a result row
    # listing a landed node can never carry one (result_deploy.mojo)
    var t = exit_table()
    for i in range(len(t)):
        var want = t[i].code == 2 or t[i].code == 3 or t[i].code == 4
        assert_equal(promises_no_effect(t[i].code), want, t[i].name)
    assert_true(promises_no_effect(exit_code_of(String(OUTCOME_FAILED))))
    assert_true(promises_no_effect(exit_code_of(String(OUTCOME_REFUSED))))
    assert_false(promises_no_effect(exit_code_of(String(OUTCOME_PARTIAL))))


def test_no_two_rows_share_a_number_or_a_name() raises:
    var t = exit_table()
    for i in range(len(t)):
        for j in range(i):
            assert_true(t[i].code != t[j].code)
            assert_true(t[i].name != t[j].name)


def test_every_outcome_has_exactly_one_number() raises:
    var o = all_outcomes()
    assert_equal(len(o), 10)
    for i in range(len(o)):
        var n = exit_code_of(o[i])
        assert_true(n >= 0 and n <= 8)
        assert_equal(exit_code_of(o[i]), n)


def test_outcome_numbers() raises:
    assert_equal(exit_code_of(String(OUTCOME_SUCCEEDED)), 0)
    # a run stopped because something newer is ahead is not a red job
    assert_equal(exit_code_of(String(OUTCOME_SUPERSEDED)), 0)
    assert_equal(exit_code_of(String(OUTCOME_REFUSED)), 3)
    assert_equal(exit_code_of(String(OUTCOME_FAILED)), 4)
    assert_equal(exit_code_of(String(OUTCOME_INDETERMINATE)), 5)
    assert_equal(exit_code_of(String(OUTCOME_PARTIAL)), 6)
    assert_equal(exit_code_of(String(OUTCOME_INTERRUPTED)), 6)
    assert_equal(exit_code_of(String(OUTCOME_CANCELLED)), 6)
    assert_equal(exit_code_of(String(OUTCOME_VALIDATION_FAILED)), 7)


def test_already_published_identical_is_exit_zero() raises:
    # The old publish table had ALREADY_PUBLISHED = 6 and a {0, 6} green
    # rule for drivers. A NOOP is the end state holding: exit 0, retry SAFE.
    assert_equal(exit_code_of(String(OUTCOME_NOOP)), EXIT_OK)
    assert_equal(default_retry(EXIT_OK), String(RETRY_SAFE))


def test_internal_and_usage_ids_pick_their_number() raises:
    assert_equal(exit_code_of(String(OUTCOME_INDETERMINATE), String(ERROR_INTERNAL)), 1)
    assert_equal(exit_code_of(String(OUTCOME_REFUSED), String(ERROR_USAGE)), 2)
    # any other id leaves the number to the outcome
    assert_equal(exit_code_of(String(OUTCOME_PARTIAL), String(ERROR_PUBLISH_READ_BACK)), 6)


def test_retry_advice() raises:
    assert_equal(default_retry(EXIT_OK), String(RETRY_SAFE))
    assert_equal(default_retry(1), String(RETRY_NEEDS_HUMAN))
    assert_equal(default_retry(2), String(RETRY_NEEDS_HUMAN))
    assert_equal(default_retry(EXIT_REFUSED), String(RETRY_NEEDS_HUMAN))
    assert_equal(default_retry(EXIT_FAILED), String(RETRY_SAFE))
    assert_equal(default_retry(EXIT_CANNOT_TELL), String(RETRY_NEEDS_HUMAN))
    assert_equal(default_retry(EXIT_PARTIAL), String(RETRY_UNSAFE))
    # stronger advice is allowed, weaker is refused
    require_retry_for(EXIT_PARTIAL, String(RETRY_NEEDS_HUMAN))
    var refused = False
    try:
        require_retry_for(EXIT_PARTIAL, String(RETRY_SAFE))
    except e:
        refused = String(e).find(String("weaker")) >= 0
    assert_true(refused)
    refused = False
    try:
        _ = default_retry(9)
    except e:
        refused = String(e).find(String("not in kci's exit table")) >= 0
    assert_true(refused)


def test_unknown_outcome_refused() raises:
    assert_true(_raises_with(String("ALREADY_PUBLISHED"), String("is not one of")))
    assert_true(_raises_with(String("succeeded"), String("is not one of")))
    var refused = False
    try:
        _ = exit_code_of(String("PUBLISHED"))
    except e:
        refused = True
    assert_true(refused)


def test_worst_outcome() raises:
    assert_equal(worst_outcome(String(OUTCOME_NOOP), String(OUTCOME_SUCCEEDED)), String(OUTCOME_SUCCEEDED))
    assert_equal(worst_outcome(String(OUTCOME_SUCCEEDED), String(OUTCOME_REFUSED)), String(OUTCOME_REFUSED))
    assert_equal(worst_outcome(String(OUTCOME_PARTIAL), String(OUTCOME_FAILED)), String(OUTCOME_PARTIAL))
    assert_equal(worst_outcome(String(OUTCOME_PARTIAL), String(OUTCOME_INDETERMINATE)), String(OUTCOME_INDETERMINATE))
    assert_false(worst_outcome(String(OUTCOME_NOOP), String(OUTCOME_NOOP)) != String(OUTCOME_NOOP))


def test_outcome_rank_orders_every_outcome() raises:
    # best to worst; each rank pinned, so two outcomes swapping places (or
    # one falling through to INDETERMINATE's 8) is caught
    var order = List[String]()
    order.append(String(OUTCOME_NOOP))
    order.append(String(OUTCOME_SUCCEEDED))
    order.append(String(OUTCOME_SUPERSEDED))
    order.append(String(OUTCOME_REFUSED))
    order.append(String(OUTCOME_FAILED))
    order.append(String(OUTCOME_VALIDATION_FAILED))
    order.append(String(OUTCOME_CANCELLED))
    order.append(String(OUTCOME_INTERRUPTED))
    order.append(String(OUTCOME_PARTIAL))
    order.append(String(OUTCOME_INDETERMINATE))
    assert_equal(len(order), len(all_outcomes()))
    for i in range(len(order)):
        assert_equal(outcome_rank(order[i]), i, order[i])
        for j in range(i):
            assert_equal(worst_outcome(order[i], order[j]), order[i])
            assert_equal(worst_outcome(order[j], order[i]), order[i])
    assert_true(_rank_refused(String("DONE")))


def _rank_refused(word: String) -> Bool:
    try:
        _ = outcome_rank(word)
    except e:
        return String(e).find(String("is not one of")) >= 0
    return False


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
