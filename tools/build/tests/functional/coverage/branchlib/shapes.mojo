"""Source decisions of other shapes than classify_score's (test 47): a
`while`, a `for ... in range(`, a ternary `if`, a chain of `or`s, and the
`if` of a plain `@always_inline` helper, which keeps its own location where
it is inlined."""


@always_inline
def pick(n: Int) -> Int:
    if n > 1:
        return 3
    return 4


def any_positive(a: Int, b: Int, c: Int) -> Int:
    if a > 0 or b > 0 or c > 0:
        return a + b + c
    return 0


def shapes(n: Int, flag: Bool) -> Int:
    var total = 0
    var i = 0
    while i < n:
        i += 1
    for _ in range(n):
        total += 1
    var t = 1 if flag else 2
    return total + t + pick(n)
