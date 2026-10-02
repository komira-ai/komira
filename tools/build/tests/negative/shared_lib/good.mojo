@export
def neg_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b
