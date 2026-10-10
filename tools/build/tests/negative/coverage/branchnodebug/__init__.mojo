"""branchnodebug: a helper declared @always_inline("nodebug"), whose loop
test carries the location of its call (test 47): branch coverage refuses
the branch there rather than take it for the compiler's."""


@always_inline("nodebug")
def count_down(n: Int) -> Int:
    var i = n
    var steps = 0
    while i > 0:
        i -= 1
        steps += 1
    return steps


def use(n: Int) -> Int:
    return count_down(n)
