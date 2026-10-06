def f(x: Int) -> Int:
    if x > 0:
        return 1
    # nothing
    if x < -5:
        return 2
    abort()  # cov: unreachable x is never in [-5, 0]
