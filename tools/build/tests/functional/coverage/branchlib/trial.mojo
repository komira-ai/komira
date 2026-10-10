"""try/except (test 47): a raising call in a `try:` body of its function is
a decision of two arms, the call returned or it raised into the handler.
Outside a `try:` body (an `except`, `else` or `finally` body, after the
`try`, or a function that `raises`) its error check is the compiler's."""


def checked(x: Int) raises -> Int:
    if x < 0:
        raise Error("negative")
    return x * 2


def both(x: Int) -> Int:
    try:
        return checked(x)
    except:
        return -1


def normal_only(x: Int) -> Int:
    var r = 0
    try:
        r = checked(x)
    except:
        r = -2
    return r


def outside(x: Int) raises -> Int:
    return checked(x) + 1


def nested(x: Int, y: Int) -> Int:
    try:
        var a = checked(x)
        try:
            a += checked(y)
        except:
            a += checked(x + 100)
        return a
    except:
        return -1


def raise_in_try(x: Int) -> Int:
    try:
        if x > 5:
            raise Error("big")
        return x
    except:
        return 0


def with_finally(x: Int) raises -> Int:
    var r = 0
    try:
        r = checked(x)
    finally:
        r += 1
    return r


def with_else(x: Int) raises -> Int:
    var r = 0
    try:
        r = checked(x)
    except:
        r = -1
    else:
        r += checked(x + 1)
    return r


def keyed(d: Dict[String, Int], key: String) -> Int:
    try:
        return d[key]
    except:
        return -3


def touch(x: Int) raises:
    if x == 13:
        raise Error("thirteen")


@always_inline
def inl(x: Int) raises -> Int:
    if x == 7:
        raise Error("seven")
    return x + 1


struct Box:
    var v: Int

    def __init__(out self, v: Int) raises:
        if v > 1000:
            raise Error("too big")
        self.v = v

    def get(self, d: Int) raises -> Int:
        if d == 0:
            raise Error("zero")
        return self.v // d


def calls(x: Int, s: String) -> Int:
    var r = 0
    try:
        touch(x)
        r = inl(x)
        r += checked(checked(x))
        var b = Box(x)
        r += b.get(x)
        r += Int(s)
    except e:
        r = -String(e).byte_length()
    return r


def looped(xs: List[Int]) -> Int:
    var n = 0
    for x in xs:
        try:
            n += checked(x)
        except:
            continue
    return n
