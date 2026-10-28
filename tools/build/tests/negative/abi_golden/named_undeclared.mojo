comptime ConstBytes = UnsafePointer[UInt8, MutUntrackedOrigin]


@export
def neg_open(path: CStr, plan: ConstBytes, n: UInt64) abi("C") -> Int32:
    return Int32(n)
