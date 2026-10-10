"""branchc: a library of the branch coverage tests (test 47) that calls
into C (komira_example_add, of komira//tools/build/examples/cshim:add)."""

from std.ffi import external_call


def add_clamped(a: Int32, b: Int32) -> Int32:
    """The sum of `a` and `b`, computed in C, clamped to [0, 100]."""
    var s = external_call["komira_example_add", Int32](a, b)
    if s < 0:
        return 0
    elif s > 100:
        return 100
    return s
