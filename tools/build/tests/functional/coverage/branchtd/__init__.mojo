"""branchtd: a library of the branch coverage tests (test 47) whose test
needs a test-only package (branchtdsup, in its `test_deps`)."""


def sign(x: Int32) -> Int32:
    """-1, 0 or 1 by the sign of `x`."""
    if x < 0:
        return -1
    elif x > 0:
        return 1
    return 0
