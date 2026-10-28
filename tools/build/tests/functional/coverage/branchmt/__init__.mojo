"""branchmt: a library of the branch coverage tests (test 47) whose test
calls it from several threads at once, so that its profile counters are
incremented concurrently."""


def quarter(i: Int) -> Int:
    """2 when `i` is 0 modulo 4, 1 when it is 1, and 0 otherwise: three arms
    taken 1, 1 and 2 times in every 4 consecutive values of `i`."""
    var r = i % 4
    if r == 0:
        return 2
    elif r == 1:
        return 1
    return 0
