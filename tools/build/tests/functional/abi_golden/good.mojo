@export
def neg_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


@export
def neg_fill(buf: UnsafePointer[UInt8, MutExternalOrigin], n: Int) abi("C"):
    for i in range(n):
        buf[i] = 0
