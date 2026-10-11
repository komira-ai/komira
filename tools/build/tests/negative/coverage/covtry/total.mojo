def check(x: Int) raises -> Int:
    if x < 0:
        raise Error("negative")
    return x


def total(a: Int, b: Int) -> Int:
    var r = 0
    try:
        r = check(a)
        r += check(b)
    except:
        r = -1
    return r
