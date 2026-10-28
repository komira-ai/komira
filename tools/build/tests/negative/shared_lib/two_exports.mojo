@export
def neg_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


# Not named by `exports` in the target that uses this file.
@export
def neg_sub(a: Int32, b: Int32) abi("C") -> Int32:
    return a - b
