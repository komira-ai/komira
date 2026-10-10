# =============================================================================
# FFI-BOUNDARY: the one export of the native_c shared library.
# =============================================================================
# The C native UDF library: echo_runtime.c built as a native library
# (//src/tests/helpers/komira_udf_spike_abi:komira_udf_echo_native).
# komira_udf_native_init_v1, the symbol the native runtime resolves, forwards
# to its C init, komira_udf_echo_native_init_v1.
# The three pointers belong to the caller (the host struct, the rt
# out-slot, the error struct) and are passed through untouched; the table
# returned is the library's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_native_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_echo_native_init_v1", Void](host, rt, err)
