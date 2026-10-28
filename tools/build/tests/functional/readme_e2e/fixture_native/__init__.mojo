from std.ffi import external_call


def native_add(a: Int32, b: Int32) -> Int32:
    """Adds two numbers in C (komira_fixture_native_add, the package's native library)."""
    return external_call["komira_fixture_native_add", Int32](a, b)
