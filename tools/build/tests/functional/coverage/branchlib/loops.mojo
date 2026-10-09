"""Loops over collections (test 47): a `for` over a List by name, whose
iteration branch sits at the name's first character, and over a list
literal of Strings, whose iterator's `__next__` returns the `i1` the loop
branches on, at the literal's `[`."""


def total(xs: List[Int]) -> Int:
    var n = 0
    for x in xs:
        n += x
    return n


def letters() -> Int:
    var n = 0
    for s in [String("a"), String("bcd")]:
        n += s.byte_length()
    return n
