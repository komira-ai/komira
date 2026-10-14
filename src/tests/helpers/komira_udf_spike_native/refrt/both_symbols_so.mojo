# =============================================================================
# FFI-BOUNDARY: the two exports of the both_symbols shared library.
# =============================================================================
# The C native UDF library under both init symbols: the native library's,
# komira_udf_native_init_v1, and a runtime's, komira_udf_runtime_init_v1,
# each forwarding to komira_udf_echo_native_init_v1. A library that is also
# a runtime: the native runtime must refuse to load it, although its
# describe is a native library's. The three pointers belong to the caller
# and are passed through untouched; the table returned is the library's
# static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_native_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_echo_native_init_v1", Void](host, rt, err)


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_echo_native_init_v1", Void](host, rt, err)
