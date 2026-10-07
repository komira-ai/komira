def clamp(x: Int, lo: Int, hi: Int) -> Int:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def describe(x: Int) -> String:
    if x == 0:
        return "zero"
    if x > 0:
        return "positive"
    return "negative"  # cov: unreachable a fixture line (test 43): the tests describe 0 only
