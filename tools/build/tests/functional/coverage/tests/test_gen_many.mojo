# Calls a function of a written source (plain.mojo) and one of each of
# covgenmany's twelve generated sources: the coverage run's report has the
# first and none of the others (test 43).
from covgenmany import half, add_00, add_01, add_02, add_03, add_04, add_05, add_06, add_07, add_08, add_09, add_10, add_11
from std.testing import assert_equal


def main() raises:
    assert_equal(half(8), 4, "half of 8")
    assert_equal(add_00(1), 1 + 0, "add_00")
    assert_equal(add_01(1), 1 + 1, "add_01")
    assert_equal(add_02(1), 1 + 2, "add_02")
    assert_equal(add_03(1), 1 + 3, "add_03")
    assert_equal(add_04(1), 1 + 4, "add_04")
    assert_equal(add_05(1), 1 + 5, "add_05")
    assert_equal(add_06(1), 1 + 6, "add_06")
    assert_equal(add_07(1), 1 + 7, "add_07")
    assert_equal(add_08(1), 1 + 8, "add_08")
    assert_equal(add_09(1), 1 + 9, "add_09")
    assert_equal(add_10(1), 1 + 10, "add_10")
    assert_equal(add_11(1), 1 + 11, "add_11")
