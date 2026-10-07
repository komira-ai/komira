"""covbare: a library with no test and no README (tests 41 and 45): with the
coverage switch off its package is the compiler's output, with no join; with
it on, a join waits for its coverage gate, which has no report."""


def bare(x: Int) -> Int:
    return x + 1
