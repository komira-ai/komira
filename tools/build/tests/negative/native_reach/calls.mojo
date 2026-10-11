from std.ffi import c_int, external_call


def fill(ptr: Int, n: Int) -> Int:
    return Int(external_call["komira_awslc_RAND_bytes", c_int](ptr, n))
