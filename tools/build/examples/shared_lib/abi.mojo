from std.ffi import external_call


@export
def spike_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


@export
def spike_sum_squares(n: Int32) abi("C") -> Int64:
    var s: Int64 = 0
    for i in range(Int(n)):
        s += Int64(i) * Int64(i)
    return s


@export
def spike_c_add(a: Int32, b: Int32) abi("C") -> Int32:
    # C side: komira_example_add, a normal (not force-loaded) static dep.
    return external_call["komira_example_add", Int32](a, b)
