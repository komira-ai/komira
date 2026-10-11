# =============================================================================
# FFI-BOUNDARY: the one export of the echo.so runtime library.
# =============================================================================
# komira_udf_runtime_init_v1 forwards to komira_udf_echo_init_v1, the C init
# of echo_runtime.c built as :komira_udf_echo. The C library cannot define
# the export itself: both builds of echo_runtime.c are C libraries under
# src/, which the one-definition gate links into one library, so each gets
# an init of its own name and this file gives its shared library the name
# the ABI requires. The three pointers belong to the caller (the host struct,
# the rt out-slot, the error struct) and are passed through untouched; the
# table returned is the runtime's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_echo_init_v1", Void](host, rt, err)
