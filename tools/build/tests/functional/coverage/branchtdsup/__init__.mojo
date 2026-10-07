"""branchtdsup: the test-support package of branchtd's test (test 47),
reaching it only through branchtd's `test_deps`. It calls into C
(komira_example_add, of komira//tools/build/examples/cshim:add), so the
test's link needs that C library too."""

from std.ffi import external_call


def c_add(a: Int32, b: Int32) -> Int32:
    """The sum of `a` and `b`, computed in C."""
    return external_call["komira_example_add", Int32](a, b)
