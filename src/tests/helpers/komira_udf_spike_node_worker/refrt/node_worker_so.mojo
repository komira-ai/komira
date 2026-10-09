# =============================================================================
# FFI-BOUNDARY: the one export of the node_worker.so runtime library.
# =============================================================================
# komira_udf_runtime_init_v1 forwards to kudfw_node_init_v1, the C init of
# the worker proxy with the `node` launcher (proxy/node_launcher.c, built as
# :komira_udf_node_worker_proxy). The C library cannot define the export
# itself: every C library under src/ is linked into one binary by the
# one-definition gate, where echo's forwarders define it too. The three
# pointers belong to the caller (the host struct, the rt out-slot, the error
# struct) and are passed through untouched; the table returned is the
# runtime's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["kudfw_node_init_v1", Void](host, rt, err)
