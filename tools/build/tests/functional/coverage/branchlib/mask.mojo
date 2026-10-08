"""User masks (test 47): `xs.capacity()` is a field-2 load of a
`{ ptr, i64, i64 }`, masked with bit 62, the shape of a String's flags
test. A String's nodebug code puts the `and` and the test at one location;
Mojo puts the user's `and` at the `&`, so each `if` stays a decision."""


def roomy(xs: List[Int], ys: List[Int], n: Int) -> Int:
    var r = n
    if xs.capacity() & (1 << 62) != 0:
        r += 1
    if ys.capacity() & (1 << 62):
        r += 2
    return r
