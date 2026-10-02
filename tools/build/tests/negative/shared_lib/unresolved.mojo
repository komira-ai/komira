from std.ffi import external_call


@export
def neg_add(a: Int32, b: Int32) abi("C") -> Int32:
    # No library defines this symbol: the link allows it, dlopen(RTLD_NOW) does not.
    return external_call["komira_neg_undefined_symbol", Int32](a, b)
