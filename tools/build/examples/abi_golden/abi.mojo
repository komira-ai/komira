@export
def abi_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


@export
def abi_sum_bytes(
    data: UnsafePointer[UInt8, MutExternalOrigin], n: Int
) abi("C") -> Int64:
    var s: Int64 = 0
    for i in range(n):
        s += Int64(data[i])
    return s


@export
def abi_fill(
    buf: UnsafePointer[UInt8, MutExternalOrigin], n: Int, value: UInt8
) abi("C"):
    for i in range(n):
        buf[i] = value


@export
def abi_scale(x: Float64, k: Float64) abi("C") -> Float64:
    return x * k


# Added in 1.1: a handle argument.
@export
def abi_touch(handle: UnsafePointer[NoneType, MutExternalOrigin]) abi("C") -> Int32:
    _ = handle
    return 7
