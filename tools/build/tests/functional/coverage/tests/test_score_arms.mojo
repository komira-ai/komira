# Test 47: some arms of classify_score, never "invalid" (its counter stays
# 0 in the profile of the branch coverage run), and of the decisions of
# shapes.mojo, both arms of strings.mojo's `first`, the loops of loops.mojo
# (each a known number of iterations and ends), a Dict subscript that finds
# its key and one that raises, mask.mojo's `if`s, never true, and the
# raising calls of trial.mojo, some raising into their `try`'s handler and
# some never (normal_only's, and the outer `checked(` of `calls`), and the
# `and`/`or`s of values.mojo, each left operand both ways but for
# `passed`'s, `nested_values`'s inner `or` and `raising`'s.
from branchlib import (
    any_positive,
    both,
    both_set,
    calls,
    classify_score,
    digits,
    either_small,
    first,
    folded,
    guarded,
    keyed,
    letters,
    lookup,
    looped,
    lowers,
    nested,
    nested_values,
    normal_only,
    outside,
    passed,
    raise_in_try,
    raising,
    raising_or,
    roomy,
    shapes,
    stored,
    total,
    with_else,
    with_finally,
)
from std.testing import assert_equal


def main() raises:
    assert_equal(classify_score(95, True), "top", "top")
    assert_equal(classify_score(95, False), "high", "high")
    assert_equal(classify_score(50, False), "pass", "pass")
    assert_equal(classify_score(70, True), "pass", "pass with bonus")
    assert_equal(shapes(3, True), 3 + 1 + 3, "three turns, flag, pick 3")
    assert_equal(shapes(0, False), 0 + 2 + 4, "no turn, no flag, pick 4")
    assert_equal(any_positive(0, 0, 1), 1, "the last decides")
    assert_equal(any_positive(1, 0, 0), 1, "the first decides")
    assert_equal(first(String("abc"), True), 1, "the flag returns 1")
    assert_equal(first(String("abcd"), False), 4, "no flag: the length")
    assert_equal(total([1, 2, 3]), 6, "three iterations, one end")
    assert_equal(total(List[Int]()), 0, "no iteration, one end")
    assert_equal(letters(), 4, "two iterations, one end")
    var d = Dict[String, Int]()
    d["a"] = 7
    assert_equal(lookup(d, "a"), 7, "the key is there")
    var raised = False
    try:
        _ = lookup(d, "b")
    except:
        raised = True
    assert_equal(raised, True, "a missing key raises")
    assert_equal(roomy(List[Int](), List[Int](), 5), 5, "no capacity has bit 62")
    assert_equal(both(1), 2, "both: normal")
    assert_equal(both(-1), -1, "both: raised")
    assert_equal(normal_only(3), 6, "normal only")
    assert_equal(outside(2), 5, "outside")
    assert_equal(nested(1, 2), 6, "nested: normal")
    assert_equal(nested(1, -2), 2 + 202, "nested: inner raised")
    assert_equal(nested(-1, 2), -1, "nested: outer raised")
    assert_equal(raise_in_try(9), 0, "raise in try")
    assert_equal(raise_in_try(2), 2, "no raise in try")
    assert_equal(with_finally(2), 5, "finally")
    assert_equal(with_else(2), 10, "else")
    assert_equal(with_else(-2), -1, "else: raised")
    assert_equal(keyed(d, "a"), 7, "keyed: found")
    assert_equal(keyed(d, "z"), -3, "keyed: raised")
    assert_equal(calls(2, "5"), 3 + 8 + 1 + 5, "calls: normal")
    assert_equal(calls(13, "5") < 0, True, "calls: touch raised")
    assert_equal(calls(7, "5") < 0, True, "calls: inl raised")
    assert_equal(calls(-1, "5") < 0, True, "calls: checked raised")
    assert_equal(calls(2000, "5") < 0, True, "calls: Box raised")
    assert_equal(calls(0, "5") < 0, True, "calls: get raised")
    assert_equal(calls(2, "x") < 0, True, "calls: Int raised")
    assert_equal(looped([1, -1, 2]), 6, "looped")
    assert_equal(both_set(True, False), False, "both_set: the right operand decides")
    assert_equal(both_set(False, True), False, "both_set: the left operand decides")
    assert_equal(either_small(20, 3), True, "either_small: the right operand decides")
    assert_equal(either_small(3, 20), True, "either_small: the left operand decides")
    assert_equal(stored(1, 2), 2, "stored: both true")
    assert_equal(stored(-1, 2), 1, "stored: the left operand decides")
    assert_equal(passed(1, 3), 0, "passed: the right operand decides")
    assert_equal(nested_values(1, 20, 4), True, "nested: the innermost decides")
    assert_equal(nested_values(0, 3, 3), False, "nested: the left operand decides")
    assert_equal(raising(1, 60), True, "raising: the right operand decides")
    var raised_rhs = False
    try:
        _ = raising(1, 200)
    except:
        raised_rhs = True
    assert_equal(raised_rhs, True, "raising: the right operand raised")
    assert_equal(raising_or(1, 200), True, "raising_or: the left operand decides")
    assert_equal(raising_or(-1, 60), True, "raising_or: the right operand decides")
    assert_equal(guarded(0, 0), 0, "guarded: the call skipped")
    assert_equal(guarded(1, 60), 1, "guarded: the call returned")
    assert_equal(guarded(1, 200), -1, "guarded: the call raised")
    assert_equal(digits([48, 49, 120]), 3, "digits: two digits, one not, then one")
    assert_equal(digits([5]), 1, "digits: below '0'")
    assert_equal(lowers([97, 98, 95]), 3, "lowers: two lower, one underscore")
    assert_equal(folded(1, 2), 1, "folded: both")
    assert_equal(folded(1, 3), 0, "folded: the right operand decides")
    assert_equal(folded(0, 2), 0, "folded: the left operand decides")
