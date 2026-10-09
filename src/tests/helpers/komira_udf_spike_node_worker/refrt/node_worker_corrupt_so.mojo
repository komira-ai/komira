# =============================================================================
# FFI-BOUNDARY: the one export of the node_worker_corrupt.so runtime library.
# =============================================================================
# komira_udf_runtime_init_v1 forwards to kudfw_node_corrupt_init_v1, the
# second init of proxy/node_launcher.c: the same runtime, whose workers run
# with --corrupt-output and send outputs that break the IPC layout, for the
# test of the proxy's validation of worker outputs. The three pointers belong
# to the caller (the host struct, the rt out-slot, the error struct) and are
# passed through untouched; the table returned is the runtime's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["kudfw_node_corrupt_init_v1", Void](host, rt, err)
