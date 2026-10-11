# =============================================================================
# FFI-BOUNDARY: the one export of the python_shared_gil.so runtime library.
# =============================================================================
# komira_udf_runtime_init_v1 forwards to komira_udf_python_shared_gil_init_v1
# of pyrt/python_runtime.c: every context a thread state of the one main
# interpreter, behind its one GIL (the baseline). The three pointers belong
# to the caller (the host struct, the rt out-slot, the error struct) and are
# passed through untouched; the table returned is the runtime's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_runtime_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_python_shared_gil_init_v1", Void](host, rt, err)
