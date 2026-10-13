from std.testing import assert_equal, assert_false, assert_true

from change_map.held import HeldChange, held_refusals, is_held_file, refusal_reason

# A hold is never dropped (change_map/held.mojo): each case is a changed
# marker at the base and at the head, and the refusals it must give.

comptime A = "src/a/coverage_held"


def _one(base: String, in_base: Bool, head: String, in_head: Bool, stays: Bool) -> String:
    var l = List[HeldChange]()
    l.append(HeldChange(String(A), base, in_base, head, in_head, stays))
    var r = held_refusals(l)
    var s = String("")
    for i in range(len(r)):
        if i > 0:
            s += String(" | ")
        s += r[i]
    return s^


def test_held_file_names() raises:
    assert_true(is_held_file(String("src/a/coverage_held")))
    assert_true(is_held_file(String("coverage_held")))
    assert_false(is_held_file(String("src/a/old_coverage_held")))
    assert_false(is_held_file(String("src/a/coverage_held.orig")))
    assert_false(is_held_file(String("src/a/coverage_census.tsv")))
    assert_false(is_held_file(String("src/a/coverage_floor.tsv")))


def test_kept_and_gained_holds_pass() raises:
    assert_equal(_one(String("line\n"), True, String("# c\nline\n"), True, True), "")
    assert_equal(_one(String("line\n"), True, String("branch\nline\n"), True, True), "")
    assert_equal(_one(String("# c\nline\nbranch\n"), True, String("# d\nbranch\nline\n"), True, True), "")


def test_a_metric_taken_out_is_refused() raises:
    assert_equal(_one(String("# c\nline\nbranch\n"), True, String("# c\nline\n"), True, True), "src/a/coverage_held: branch is no longer held")
    assert_equal(_one(String("line\nbranch\n"), True, String("# none\n"), True, True), "src/a/coverage_held: line is no longer held | src/a/coverage_held: branch is no longer held")


def test_new_marker_and_deleted_package_pass() raises:
    assert_equal(_one(String(""), False, String("line\n"), True, True), "")
    assert_equal(_one(String("line\nbranch\n"), True, String(""), False, False), "")


def test_deleted_marker_of_a_package_that_stays_is_refused() raises:
    assert_equal(_one(String("line\n"), True, String(""), False, True), "src/a/coverage_held: line is no longer held")
    # A marker that held nothing drops nothing when it goes.
    assert_equal(_one(String("# nothing\n"), True, String(""), False, True), "")


def test_every_change_is_read_and_the_reason_names_them_all() raises:
    var l = List[HeldChange]()
    l.append(HeldChange(String(A), String("line\n"), True, String("# c\n"), True, True))
    l.append(HeldChange(String("src/b/coverage_held"), String("line\n"), True, String("line\nbranch\n"), True, True))
    l.append(HeldChange(String("src/c/coverage_held"), String("branch\n"), True, String(""), False, True))
    var r = held_refusals(l)
    assert_equal(len(r), 2)
    var why = refusal_reason(r)
    assert_true(why.startswith("a coverage hold was dropped (a package that reached the target stays held"), why)
    assert_true(why.endswith("src/a/coverage_held: line is no longer held; src/c/coverage_held: branch is no longer held"), why)


def main() raises:
    test_held_file_names()
    test_kept_and_gained_holds_pass()
    test_a_metric_taken_out_is_refused()
    test_new_marker_and_deleted_package_pass()
    test_deleted_marker_of_a_package_that_stays_is_refused()
    test_every_change_is_read_and_the_reason_names_them_all()
    print("test_held: PASS")
