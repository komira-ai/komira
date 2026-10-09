# =============================================================================
# FFI-BOUNDARY: the one export of the echo_as_library shared library.
# =============================================================================
# The reference runtime echo under the native library symbol: its describe
# reports another runtime_id and udf_class MANAGED, so the native runtime
# must refuse to load it.
# The three pointers belong to the caller (the host struct, the rt
# out-slot, the error struct) and are passed through untouched; the table
# returned is the library's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_native_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_echo_init_v1", Void](host, rt, err)
