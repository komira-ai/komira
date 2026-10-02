from std.ffi import external_call


@export
def neg_c_add(a: Int32, b: Int32) abi("C") -> Int32:
    return external_call["komira_example_add", Int32](a, b)
