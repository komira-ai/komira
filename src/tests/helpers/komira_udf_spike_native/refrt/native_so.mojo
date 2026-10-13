# =============================================================================
# FFI-BOUNDARY: the one export of the native shared library.
# =============================================================================
# The native runtime (native/native_runtime.c, built as :komira_udf_native_rt):
# komira_udf_runtime_init_v1 forwards to its C init, komira_udf_native_rt_init_v1
# (every C library under src/ is linked whole by the one-definition gate, so
# the C init has a name of its own and this file gives the shared library
# the name the ABI requires).
# The three pointers belong to the caller (the host struct, the rt
# out-slot, the error struct) and are passed through untouched; the table
# returned is the library's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_native_rt_init_v1", Void](host, rt, err)
