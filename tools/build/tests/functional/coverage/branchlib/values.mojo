"""`and`/`or` whose result is returned, stored or passed on, never tested
by a branch of its own (test 47): each is a decision of two arms, its right
operand evaluated or skipped; where a branch does test the result, its
right operand's outcomes are counted as well."""


def small(n: Int) -> Bool:
    return n < 10


def is_even(n: Int) -> Bool:
    return n % 2 == 0


def strict(n: Int) raises -> Bool:
    if n > 100:
        raise Error("too large")
    return n > 50


def count(flag: Bool) -> Int:
    return 1 if flag else 0


@always_inline
def digit(c: Int) -> Bool:
    return c >= 48 and small(c - 48)


def both_set(a: Bool, b: Bool) -> Bool:
    return a and b


def either_small(a: Int, b: Int) -> Bool:
    return small(a) or small(b)


def stored(a: Int, b: Int) -> Int:
    var r = a > 0 and is_even(b)
    return count(r) + 1


def passed(a: Int, b: Int) -> Int:
    return count(a < 0 or is_even(b))


def nested_values(a: Int, b: Int, c: Int) -> Bool:
    return a > 0 and (small(b) or is_even(c))


def raising(a: Int, b: Int) raises -> Bool:
    return a > 0 and strict(b)


def raising_or(a: Int, b: Int) raises -> Bool:
    return a > 0 or strict(b)


def guarded(a: Int, b: Int) -> Int:
    try:
        if a > 0 and strict(b):
            return 1
        return 0
    except:
        return -1


def digits(xs: List[Int]) -> Int:
    var n = 0
    for i in range(len(xs)):
        if digit(xs[i]):
            n += 1
    return n + count(digit(n + 48))


def lowers(xs: List[Int]) -> Int:
    var n = 0
    for i in range(len(xs)):
        var c = xs[i]
        var lower = c >= 97 and small(c - 97)
        var ok = lower if i == 0 else (lower or c == 95)
        if ok:
            n += 1
    return n


def folded(a: Int, b: Int) -> Int:
    var hit = False
    if a > 0 and is_even(b):
        hit = True
    if hit:
        return 1
    return 0
