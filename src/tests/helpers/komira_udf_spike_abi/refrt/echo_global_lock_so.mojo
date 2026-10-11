# =============================================================================
# FFI-BOUNDARY: the one export of the echo_global_lock.so runtime library.
# =============================================================================
# komira_udf_runtime_init_v1 forwards to komira_udf_echo_global_lock_init_v1,
# the second init of echo_runtime.c built as :komira_udf_echo (defined by
# ECHO_INIT_GLOBAL_LOCK): the same runtime, reporting global_lock 1 beside
# THREAD_SAFE. The three pointers belong to the caller (the host struct, the
# rt out-slot, the error struct) and are passed through untouched; the table
# returned is the runtime's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_echo_global_lock_init_v1", Void](host, rt, err)
