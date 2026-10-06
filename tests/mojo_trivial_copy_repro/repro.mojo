# Mojo 1.0.0: a struct holding two Optional[List[Int]] and a trailing
# Optional[Bool] gets a synthesized `__copy_ctor_is_trivial` of True, so
# `List.copy()` copies its elements with a memcpy and the copy shares the
# original's heap buffers. Run with `plain`, `deinit` or `control`.
from std.sys import argv


trait Probe(Copyable, Deinitable, Movable):
    @staticmethod
    def make() -> Self:
        ...

    def buf(self) -> Int:
        ...

    def first(self) -> Int:
        ...


def ints() -> List[Int]:
    var l = List[Int]()
    for i in range(64):
        l.append(i + 1)
    return l^


# The trigger: two Optional fields of a non-trivial type, then an Optional of
# a trivial type as the LAST field.
@fieldwise_init
struct Plain(Probe):
    var a: Optional[List[Int]]
    var b: Optional[List[Int]]
    var c: Optional[Bool]

    @staticmethod
    def make() -> Self:
        return Self(a=Optional(ints()), b=Optional(ints()), c=Optional(True))

    def buf(self) -> Int:
        return Int(self.a.value().unsafe_ptr())

    def first(self) -> Int:
        return self.a.value()[0]


# Same fields plus an explicit (empty) destructor.
@fieldwise_init
struct WithDeinit(Probe):
    var a: Optional[List[Int]]
    var b: Optional[List[Int]]
    var c: Optional[Bool]

    def __deinit__(deinit self):
        pass

    @staticmethod
    def make() -> Self:
        return Self(a=Optional(ints()), b=Optional(ints()), c=Optional(True))

    def buf(self) -> Int:
        return Int(self.a.value().unsafe_ptr())

    def first(self) -> Int:
        return self.a.value()[0]


# Control: WithDeinit plus an explicit field-wise copy constructor.
@fieldwise_init
struct Control(Probe):
    var a: Optional[List[Int]]
    var b: Optional[List[Int]]
    var c: Optional[Bool]

    def __deinit__(deinit self):
        pass

    def __init__(out self, *, copy: Self):
        self.a = copy.a.copy()
        self.b = copy.b.copy()
        self.c = copy.c.copy()

    @staticmethod
    def make() -> Self:
        return Self(a=Optional(ints()), b=Optional(ints()), c=Optional(True))

    def buf(self) -> Int:
        return Int(self.a.value().unsafe_ptr())

    def first(self) -> Int:
        return self.a.value()[0]


def churn() -> List[List[Int]]:
    # Same-size allocations, to reuse any buffer that was freed.
    var out = List[List[Int]]()
    for _ in range(64):
        var l = List[Int]()
        for _ in range(64):
            l.append(999)
        out.append(l^)
    return out^


def run[T: Probe]():
    print("__copy_ctor_is_trivial:", T.__copy_ctor_is_trivial, flush=True)
    print("__del__is_trivial:", T.__del__is_trivial, flush=True)
    print("Optional[List[Int]].__copy_ctor_is_trivial:", Optional[List[Int]].__copy_ctor_is_trivial, flush=True)
    var xs = List[T]()
    xs.append(T.make())
    var one = xs[0].copy()
    print("x.copy() shares the buffer:", one.buf() == xs[0].buf(), flush=True)
    var ys = xs.copy()
    print("List.copy() shares the buffer:", ys[0].buf() == xs[0].buf(), flush=True)
    _ = ys^  # destroys the copy; after a memcpy copy its buffers are xs's
    var junk = churn()
    print("xs[0].a[0] after dropping the copy (expect 1):", xs[0].first(), flush=True)
    _ = junk^
    print("end of run", flush=True)  # xs is destroyed next


def main():
    var which = argv()[1]
    if which == "plain":
        run[Plain]()
    elif which == "deinit":
        run[WithDeinit]()
    else:
        run[Control]()
