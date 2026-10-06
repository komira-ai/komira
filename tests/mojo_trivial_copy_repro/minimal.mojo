# Every struct below holds two Optional[String], so none of them may have a
# trivial copy constructor or destructor. Expected: all False.


struct A(Copyable):
    var x: Optional[String]
    var y: Optional[String]
    var z: Optional[Bool]


struct B(Copyable):  # z moved to the front
    var z: Optional[Bool]
    var x: Optional[String]
    var y: Optional[String]


struct C(Copyable):  # y is a different non-trivial Optional
    var x: Optional[String]
    var y: Optional[List[Int]]
    var z: Optional[Bool]


def main():
    print("A", A.__copy_ctor_is_trivial, A.__del__is_trivial)
    print("B", B.__copy_ctor_is_trivial, B.__del__is_trivial)
    print("C", C.__copy_ctor_is_trivial, C.__del__is_trivial)
