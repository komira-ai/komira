"""A module no test imports: every executable line counts as not covered."""
from std.os import abort

def h(x: Int) -> Int:
    if x < 0:
        abort()  # cov: unreachable callers pass x >= 0
    # the common case
    return x + 1
