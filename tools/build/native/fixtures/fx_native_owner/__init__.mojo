"""fx_native_owner: ships the C it links (`native_static`), a fixture of tools/build/native/fixtures."""

from std.ffi import external_call


def fx_native_add(a: Int32, b: Int32) -> Int32:
    return external_call["komira_example_add", Int32](a, b)
