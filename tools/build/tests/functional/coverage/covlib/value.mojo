def clamp(x: Int, lo: Int, hi: Int) -> Int:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def describe(x: Int) -> String:
    if x == 0:
        return "zero"
    return "nonzero"
