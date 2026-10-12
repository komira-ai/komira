from std.testing import assert_equal, assert_false, assert_true

from change_map.floors import FloorChange, floor_refusals, is_floor_file, refusal_reason

# Floors only rise (change_map/floors.mojo): each case is a changed floor
# file at the base and at the head, and the refusals it must give.

comptime A = "src/a/coverage_floor.tsv"


def _one(base: String, in_base: Bool, head: String, in_head: Bool, stays: Bool) -> String:
    var l = List[FloorChange]()
    l.append(FloorChange(String(A), base, in_base, head, in_head, stays))
    var r = floor_refusals(l)
    var s = String("")
    for i in range(len(r)):
        if i > 0:
            s += String(" | ")
        s += r[i]
    return s^


def test_floor_file_names() raises:
    assert_true(is_floor_file(String("src/a/coverage_floor.tsv")))
    assert_true(is_floor_file(String("coverage_floor.tsv")))
    assert_false(is_floor_file(String("src/a/old_coverage_floor.tsv")))
    assert_false(is_floor_file(String("src/a/coverage_floor.tsv.orig")))
    assert_false(is_floor_file(String("src/a/coverage_census.tsv")))


def test_raised_and_equal_floors_pass() raises:
    assert_equal(_one(String("src/a\t5000\t-\n"), True, String("src/a\t5100\t-\n"), True, True), "")
    assert_equal(_one(String("src/a\t5000\t2500\n"), True, String("# c\nsrc/a\t5000\t2500\n"), True, True), "")


def test_a_lowered_floor_is_refused() raises:
    assert_equal(
        _one(String("src/a\t5000\t2500\n"), True, String("src/a\t4999\t2500\n"), True, True),
        "src/a/coverage_floor.tsv: src/a: line floor 50.00% -> 49.99%",
    )
    assert_equal(
        _one(String("src/a\t5000\t2500\n"), True, String("src/a\t5000\t-\n"), True, True),
        "src/a/coverage_floor.tsv: src/a: branch floor 25.00% -> none",
    )


def test_new_file_and_deleted_package_pass() raises:
    assert_equal(_one(String(""), False, String("src/a\t0\t-\n"), True, True), "")
    assert_equal(_one(String("src/a\t5000\t-\n"), True, String(""), False, False), "")


def test_deleted_file_of_a_package_that_stays_is_refused() raises:
    assert_equal(
        _one(String("src/a\t5000\t-\n"), True, String(""), False, True),
        "src/a/coverage_floor.tsv: src/a: the row is gone (line floor 50.00%, branch floor none)",
    )
    # A file whose floors were 0 lowers nothing when it goes.
    assert_equal(_one(String("src/a\t0\t-\n"), True, String(""), False, True), "")


def test_an_unreadable_floor_is_refused() raises:
    var r = _one(String("src/a\t5000\t-\n"), True, String("src/a\tlots\t-\n"), True, True)
    assert_true(r.startswith("src/a/coverage_floor.tsv: cannot be read as a floor: src/a/coverage_floor.tsv:1: line floor 'lots'"), r)
    var b = _one(String("src/a\t5000\n"), True, String("src/a\t5000\t-\n"), True, True)
    assert_true(b.startswith("src/a/coverage_floor.tsv: cannot be read as a floor: src/a/coverage_floor.tsv at the base:1:"), b)


def test_every_change_is_read_and_the_reason_names_them_all() raises:
    var l = List[FloorChange]()
    l.append(FloorChange(String(A), String("src/a\t5000\t-\n"), True, String("src/a\t4000\t-\n"), True, True))
    l.append(FloorChange(String("src/b/coverage_floor.tsv"), String("src/b\t1\t-\n"), True, String("src/b\t2\t-\n"), True, True))
    l.append(FloorChange(String("src/c/coverage_floor.tsv"), String("src/c\t9000\t9000\n"), True, String("src/c\t9000\t8000\n"), True, True))
    var r = floor_refusals(l)
    assert_equal(len(r), 2)
    var why = refusal_reason(r)
    assert_true(why.startswith("a coverage floor was lowered (a floor only rises"), why)
    assert_true(why.endswith(
        "src/a/coverage_floor.tsv: src/a: line floor 50.00% -> 40.00%; src/c/coverage_floor.tsv: src/c: branch floor 90.00% -> 80.00%"
    ), why)


def main() raises:
    test_floor_file_names()
    test_raised_and_equal_floors_pass()
    test_a_lowered_floor_is_refused()
    test_new_file_and_deleted_package_pass()
    test_deleted_file_of_a_package_that_stays_is_refused()
    test_an_unreadable_floor_is_refused()
    test_every_change_is_read_and_the_reason_names_them_all()
    print("test_floors: PASS")
