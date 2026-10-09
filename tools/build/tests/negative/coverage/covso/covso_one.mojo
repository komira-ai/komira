# A shared library of one C-ABI export (tests 43 and 46): its drivers load it
# and call covso_one.
@export
def covso_one() abi("C") -> Int32:
    var one: Int32 = 1
    return one
