# Survey: print the compiler's __copy_ctor_is_trivial for a set of layouts.
# Every type below owns heap memory, so every line must print False.


def show[T: Copyable](name: StaticString):
    print(name, T.__copy_ctor_is_trivial, flush=True)


# --- the issue's layout: 3 x Optional[String] + Optional[Bool] ------------
@fieldwise_init
struct OS3B_deinit(Copyable, Movable):
    var a: Optional[String]
    var b: Optional[String]
    var c: Optional[String]
    var d: Optional[Bool]

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct OS3B_plain(Copyable, Movable):
    var a: Optional[String]
    var b: Optional[String]
    var c: Optional[String]
    var d: Optional[Bool]


@fieldwise_init
struct OS3B_ctor(Copyable, Movable):
    var a: Optional[String]
    var b: Optional[String]
    var c: Optional[String]
    var d: Optional[Bool]

    def __deinit__(deinit self):
        pass

    def __init__(out self, *, copy: Self):
        self.a = copy.a.copy()
        self.b = copy.b.copy()
        self.c = copy.c.copy()
        self.d = copy.d.copy()


# --- smaller Optional layouts ---------------------------------------------
@fieldwise_init
struct OS1_deinit(Copyable, Movable):
    var a: Optional[String]

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct OS1_plain(Copyable, Movable):
    var a: Optional[String]


@fieldwise_init
struct OS1B_deinit(Copyable, Movable):
    var a: Optional[String]
    var d: Optional[Bool]

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct OS1I_deinit(Copyable, Movable):
    var a: Optional[String]
    var d: Int

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct OS3_deinit(Copyable, Movable):
    var a: Optional[String]
    var b: Optional[String]
    var c: Optional[String]

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct OL1_deinit(Copyable, Movable):
    var a: Optional[List[Int]]

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct OL1_plain(Copyable, Movable):
    var a: Optional[List[Int]]


@fieldwise_init
struct OL3B_deinit(Copyable, Movable):
    var a: Optional[List[Int]]
    var b: Optional[List[Int]]
    var c: Optional[List[Int]]
    var d: Optional[Bool]

    def __deinit__(deinit self):
        pass


# --- no Optional ----------------------------------------------------------
@fieldwise_init
struct S3B_deinit(Copyable, Movable):
    var a: String
    var b: String
    var c: String
    var d: Bool

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct S1_deinit(Copyable, Movable):
    var a: String

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct L1I_deinit(Copyable, Movable):
    var a: List[Int]
    var n: Int

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct L1_plain(Copyable, Movable):
    var a: List[Int]


# --- nested ---------------------------------------------------------------
@fieldwise_init
struct Nest_deinit(Copyable, Movable):
    var inner: S1_deinit

    def __deinit__(deinit self):
        pass


@fieldwise_init
struct NestOpt_deinit(Copyable, Movable):
    var inner: Optional[S1_deinit]

    def __deinit__(deinit self):
        pass


def main():
    print("--- library types")
    show[String]("String")
    show[List[Int]]("List[Int]")
    show[Optional[String]]("Optional[String]")
    show[Optional[List[Int]]]("Optional[List[Int]]")
    show[Optional[Bool]]("Optional[Bool]")
    show[Optional[S1_deinit]]("Optional[S1_deinit]")
    print("--- user structs (__copy_ctor_is_trivial; every one must be False)")
    show[OS3B_deinit]("OS3B_deinit")
    show[OS3B_plain]("OS3B_plain")
    show[OS3B_ctor]("OS3B_ctor")
    show[OS1_deinit]("OS1_deinit")
    show[OS1_plain]("OS1_plain")
    show[OS1B_deinit]("OS1B_deinit")
    show[OS1I_deinit]("OS1I_deinit")
    show[OS3_deinit]("OS3_deinit")
    show[OL1_deinit]("OL1_deinit")
    show[OL1_plain]("OL1_plain")
    show[OL3B_deinit]("OL3B_deinit")
    show[S3B_deinit]("S3B_deinit")
    show[S1_deinit]("S1_deinit")
    show[L1I_deinit]("L1I_deinit")
    show[L1_plain]("L1_plain")
    show[Nest_deinit]("Nest_deinit")
    show[NestOpt_deinit]("NestOpt_deinit")
