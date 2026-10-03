@export
def plain_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


@export
def plain_sum_squares(n: Int32) abi("C") -> Int64:
    var s: Int64 = 0
    for i in range(Int(n)):
        s += Int64(i) * Int64(i)
    return s


# Named by no `exports` list: visible unless `exports_exact` hides it.
@export
def plain_hidden() abi("C") -> Int32:
    return 7
