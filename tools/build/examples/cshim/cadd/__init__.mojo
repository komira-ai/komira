from std.ffi import external_call


def add(a: Int32, b: Int32) -> Int32:
    """Adds two numbers in C (komira_example_add, from //tools/build/examples/cshim:add)."""
    return external_call["komira_example_add", Int32](a, b)
