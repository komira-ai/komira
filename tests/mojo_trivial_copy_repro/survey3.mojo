from std.sys import size_of
from std.utils import Variant


def show[T: Copyable & Deinitable](name: StaticString):
    print(name, size_of[T](), T.__copy_ctor_is_trivial, T.__del__is_trivial, flush=True)


struct OS_OL_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[List[Int]]
    var f2: Optional[Bool]


struct OS_OS_I_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Int
    var f3: Optional[Bool]


struct OS_I_OS_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Int
    var f2: Optional[String]
    var f3: Optional[Bool]


struct OS_OS_OB_I(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Bool]
    var f3: Int


struct OS_OS_OB_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Bool]
    var f3: Optional[Bool]


struct S_OS_OB(Copyable, Movable):
    var f0: String
    var f1: Optional[String]
    var f2: Optional[Bool]


struct OS_S_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: String
    var f2: Optional[Bool]


struct L_L_OB(Copyable, Movable):
    var f0: List[Int]
    var f1: List[Int]
    var f2: Optional[Bool]


struct OS_OS_OB_OS(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Bool]
    var f3: Optional[String]


struct OL_OL_OI(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Optional[List[Int]]
    var f2: Optional[Int]


struct OL_OL_OB(Copyable, Movable):
    var f0: Optional[List[Int]]
    var f1: Optional[List[Int]]
    var f2: Optional[Bool]


struct OS_OS_OB(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Bool]


struct OS_OS_OF(Copyable, Movable):
    var f0: Optional[String]
    var f1: Optional[String]
    var f2: Optional[Float64]


struct VS_VS_VB(Copyable, Movable):
    var f0: Variant[Int, String]
    var f1: Variant[Int, String]
    var f2: Variant[Int, Bool]


struct OOS_OOS_OB(Copyable, Movable):
    var f0: Optional[Optional[String]]
    var f1: Optional[Optional[String]]
    var f2: Optional[Bool]


def main():
    print("name size copy_trivial del_trivial")
    show[Variant[Int, String]]("Variant[Int, String]")
    show[Variant[Int, Bool]]("Variant[Int, Bool]")
    show[Optional[Float64]]("Optional[Float64]")
    show[Optional[Optional[String]]]("Optional[Optional[String]]")
    show[OS_OL_OB]("OS_OL_OB")
    show[OS_OS_I_OB]("OS_OS_I_OB")
    show[OS_I_OS_OB]("OS_I_OS_OB")
    show[OS_OS_OB_I]("OS_OS_OB_I")
    show[OS_OS_OB_OB]("OS_OS_OB_OB")
    show[S_OS_OB]("S_OS_OB")
    show[OS_S_OB]("OS_S_OB")
    show[L_L_OB]("L_L_OB")
    show[OS_OS_OB_OS]("OS_OS_OB_OS")
    show[OL_OL_OI]("OL_OL_OI")
    show[OL_OL_OB]("OL_OL_OB")
    show[OS_OS_OB]("OS_OS_OB")
    show[OS_OS_OF]("OS_OS_OF")
    show[VS_VS_VB]("VS_VS_VB")
    show[OOS_OOS_OB]("OOS_OOS_OB")
