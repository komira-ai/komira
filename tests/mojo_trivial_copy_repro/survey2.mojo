from std.sys import size_of

# Survey 2: no __deinit__ anywhere; every type must print False.

def show[T: Copyable](name: StaticString):
    print(name, size_of[T](), T.__copy_ctor_is_trivial, flush=True)


struct OS2_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Bool]


struct OS3_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Optional[Bool]


struct OS4_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Optional[String]
    var f4: Optional[Bool]


struct OB_OS3(Copyable, Movable):
    var f0: Optional[Bool]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Optional[String]


struct OS1_OB_OS2(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[Bool]
    var f2: Optional[String]
    var f3: Optional[String]


struct OS3_B(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Bool


struct OS3_I(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Int


struct OS3_OI(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Optional[Int]


struct OS3_OI64(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Optional[Int64]


struct OS3_OS(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[String]
    var f3: Optional[String]


struct S3_OB(Copyable, Movable):
    var f0: String
    var f1: String
    var f2: String
    var f3: Optional[Bool]


struct S1_OB(Copyable, Movable):
    var f0: String
    var f1: Optional[Bool]


struct OS1_OI(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[Int]


struct OS2_OI(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Int]


struct OS2_I(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Int


struct OS2_B(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Bool


struct OS2(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]


struct OL2_I(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Optional[List[Int]]
    var f2: Int


struct L_OI(Copyable, Movable):
    var f0: List[Int]
    var f1: Optional[Int]


struct L3_OI(Copyable, Movable):
    var f0: List[Int]
    var f1: List[Int]
    var f2: List[Int]
    var f3: Optional[Int]


struct OL1_OI(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Optional[Int]


struct OL1_I(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Int


struct OL1_I_I(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Int
    var f2: Int


struct OL1_B(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Bool


struct I_OL1(Copyable, Movable):
    var f0: Int
    var f1: Optional[List[Int]]


def main():
    show[String]("String")
    show[List[Int]]("List[Int]")
    show[Optional[String]]("Optional[String]")
    show[Optional[List[Int]]]("Optional[List[Int]]")
    show[Optional[Bool]]("Optional[Bool]")
    show[Optional[Int]]("Optional[Int]")
    show[Optional[Int64]]("Optional[Int64]")
    show[OS2_OB]("OS2_OB")
    show[OS3_OB]("OS3_OB")
    show[OS4_OB]("OS4_OB")
    show[OB_OS3]("OB_OS3")
    show[OS1_OB_OS2]("OS1_OB_OS2")
    show[OS3_B]("OS3_B")
    show[OS3_I]("OS3_I")
    show[OS3_OI]("OS3_OI")
    show[OS3_OI64]("OS3_OI64")
    show[OS3_OS]("OS3_OS")
    show[S3_OB]("S3_OB")
    show[S1_OB]("S1_OB")
    show[OS1_OI]("OS1_OI")
    show[OS2_OI]("OS2_OI")
    show[OS2_I]("OS2_I")
    show[OS2_B]("OS2_B")
    show[OS2]("OS2")
    show[OL2_I]("OL2_I")
    show[L_OI]("L_OI")
    show[L3_OI]("L3_OI")
    show[OL1_OI]("OL1_OI")
    show[OL1_I]("OL1_I")
    show[OL1_I_I]("OL1_I_I")
    show[OL1_B]("OL1_B")
    show[I_OL1]("I_OL1")
