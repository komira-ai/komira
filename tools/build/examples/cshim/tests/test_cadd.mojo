from std.testing import assert_equal

from cadd import add


def main() raises:
    # assert_equal on Int32 and indexing a List in a loop both record the
    # source location of this file in the binary. The wrapper strips the
    # staging directory from it (-strip-file-prefix); without that the
    # build fails on the worker's absolute path (mojo_wrapper exit 4).
    var cases: List[Int32] = [2, 3, 5, -7, 7, 0]
    for i in range(0, len(cases), 3):
        assert_equal(add(cases[i], cases[i + 1]), cases[i + 2])
    print("test_cadd: PASS")
