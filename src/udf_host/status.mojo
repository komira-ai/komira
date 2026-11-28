# =============================================================================
# status -- a runtime's komira_udf_status as the engine's named error
# =============================================================================
#
# The error table of docs/design/udf_runtime_interface.md section 4.5: every
# status a runtime returns maps to one named code, the first word of the
# error the run refuses with, so a caller reads the code (`error_code` in
# src/so) and a person reads the runtime's own message after it. Nothing is
# retried. A status this build does not know (a later minor's) is the
# runtime's fault.
# =============================================================================

comptime UDF_OK: Int32 = 0
comptime UDF_ERR_ABI: Int32 = 1
comptime UDF_ERR_DESCRIPTOR: Int32 = 2
comptime UDF_ERR_UNSUPPORTED: Int32 = 3
comptime UDF_ERR_CODE_DIGEST: Int32 = 4
comptime UDF_ERR_LOAD: Int32 = 5
comptime UDF_ERR_RAISED: Int32 = 6
comptime UDF_ERR_RETURN_TYPE: Int32 = 7
comptime UDF_ERR_LENGTH: Int32 = 8
comptime UDF_ERR_STATE_TOO_LARGE: Int32 = 9
comptime UDF_ERR_GROUP_TOO_LARGE: Int32 = 10
comptime UDF_ERR_CANCELLED: Int32 = 11
comptime UDF_ERR_DEADLINE: Int32 = 12
comptime UDF_ERR_OUT_OF_MEMORY: Int32 = 13
comptime UDF_ERR_INSTANCE_LOST: Int32 = 14
comptime UDF_ERR_INTERNAL: Int32 = 15
comptime UDF_ERR_FIELD_NOT_DECLARED: Int32 = 16
comptime UDF_ERR_WORKER_CRASHED: Int32 = 17
comptime UDF_ERR_HOST_CONTRACT: Int32 = 18
comptime UDF_ERR_KILLED: Int32 = 19
comptime UDF_ERR_READ_SET_MISMATCH: Int32 = 20
comptime UDF_ERR_BAD_OPTION: Int32 = 21

# The codes the engine refuses with.
comptime UDF_RAISED = "UDF_RAISED"
comptime UDF_RETURN_TYPE_MISMATCH = "UDF_RETURN_TYPE_MISMATCH"
comptime UDF_BATCH_LENGTH_MISMATCH = "UDF_BATCH_LENGTH_MISMATCH"
comptime UDF_WORKER_CRASHED = "UDF_WORKER_CRASHED"
comptime UDF_DEADLINE_EXCEEDED = "UDF_DEADLINE_EXCEEDED"
comptime UDF_OUT_OF_MEMORY = "UDF_OUT_OF_MEMORY"
comptime UDF_CANCELLED = "UDF_CANCELLED"
comptime UDF_HOST_CONTRACT_VIOLATION = "UDF_HOST_CONTRACT_VIOLATION"
comptime UDF_FIELD_NOT_DECLARED = "UDF_FIELD_NOT_DECLARED"
comptime UDF_STATE_TOO_LARGE = "UDF_STATE_TOO_LARGE"
comptime UDF_GROUP_TOO_LARGE = "UDF_GROUP_TOO_LARGE"
comptime UDF_RUNTIME_FAULT = "UDF_RUNTIME_FAULT"
comptime UDF_RUNTIME_OPEN_FAILED = "UDF_RUNTIME_OPEN_FAILED"
comptime UDF_RUNTIME_MISSING_SYMBOL = "UDF_RUNTIME_MISSING_SYMBOL"
comptime UDF_RUNTIME_ABI_MISMATCH = "UDF_RUNTIME_ABI_MISMATCH"
comptime UDF_RUNTIME_OPTION_INVALID = "UDF_RUNTIME_OPTION_INVALID"
comptime UDF_RUNTIME_INIT_REFUSED = "UDF_RUNTIME_INIT_REFUSED"
comptime UDF_NULL_PROPAGATE_UNSUPPORTED = "UDF_NULL_PROPAGATE_UNSUPPORTED"
comptime OPTIMIZED_UDF_DESCRIPTOR_INVALID = "OPTIMIZED_UDF_DESCRIPTOR_INVALID"
comptime OPTIMIZED_UDF_UNSUPPORTED = "OPTIMIZED_UDF_UNSUPPORTED"
comptime OPTIMIZED_UDF_KIND_UNSUPPORTED = "OPTIMIZED_UDF_KIND_UNSUPPORTED"
comptime OPTIMIZED_UDF_CODE_DIGEST_MISMATCH = "OPTIMIZED_UDF_CODE_DIGEST_MISMATCH"
comptime OPTIMIZED_UDF_CODE_UNLOADABLE = "OPTIMIZED_UDF_CODE_UNLOADABLE"
comptime OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH = "OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH"
comptime OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH = "OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH"
comptime OPTIMIZED_UDF_RETURN_TYPE_MISSING = "OPTIMIZED_UDF_RETURN_TYPE_MISSING"
comptime OPTIMIZED_ENV_RUNTIME_MISSING = "OPTIMIZED_ENV_RUNTIME_MISSING"
comptime OPTIMIZED_ENV_CODE_MISSING = "OPTIMIZED_ENV_CODE_MISSING"


def status_code(status: Int32) -> String:
    """The engine's code for a runtime's status (section 4.5). OK has none;
    a status outside 1-21 is the runtime's fault."""
    if status == UDF_ERR_RAISED:
        return UDF_RAISED
    if status == UDF_ERR_RETURN_TYPE:
        return UDF_RETURN_TYPE_MISMATCH
    if status == UDF_ERR_LENGTH:
        return UDF_BATCH_LENGTH_MISMATCH
    if status == UDF_ERR_WORKER_CRASHED or status == UDF_ERR_INSTANCE_LOST:
        return UDF_WORKER_CRASHED
    if status == UDF_ERR_DEADLINE or status == UDF_ERR_KILLED:
        return UDF_DEADLINE_EXCEEDED
    if status == UDF_ERR_OUT_OF_MEMORY:
        return UDF_OUT_OF_MEMORY
    if status == UDF_ERR_CANCELLED:
        return UDF_CANCELLED
    if status == UDF_ERR_HOST_CONTRACT:
        return UDF_HOST_CONTRACT_VIOLATION
    if status == UDF_ERR_FIELD_NOT_DECLARED:
        return UDF_FIELD_NOT_DECLARED
    if status == UDF_ERR_STATE_TOO_LARGE:
        return UDF_STATE_TOO_LARGE
    if status == UDF_ERR_GROUP_TOO_LARGE:
        return UDF_GROUP_TOO_LARGE
    if status == UDF_ERR_DESCRIPTOR:
        return OPTIMIZED_UDF_DESCRIPTOR_INVALID
    if status == UDF_ERR_UNSUPPORTED:
        return OPTIMIZED_UDF_UNSUPPORTED
    if status == UDF_ERR_CODE_DIGEST:
        return OPTIMIZED_UDF_CODE_DIGEST_MISMATCH
    if status == UDF_ERR_LOAD:
        return OPTIMIZED_UDF_CODE_UNLOADABLE
    if status == UDF_ERR_READ_SET_MISMATCH:
        return OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH
    if status == UDF_ERR_ABI:
        return UDF_RUNTIME_ABI_MISMATCH
    if status == UDF_ERR_BAD_OPTION:
        return UDF_RUNTIME_OPTION_INVALID
    return UDF_RUNTIME_FAULT


def loses_context(status: Int32) -> Bool:
    """Whether a call that returned `status` left its context unusable
    (section 4.5): the worker died, was stopped by force, ran out of memory,
    or the context was already lost. Only its closes may be called then."""
    return (
        status == UDF_ERR_WORKER_CRASHED
        or status == UDF_ERR_KILLED
        or status == UDF_ERR_INSTANCE_LOST
        or status == UDF_ERR_OUT_OF_MEMORY
    )


def status_name(status: Int32) -> String:
    """The ABI's own name of `status` (`ERR_RAISED`), or `status <n>`."""
    var names: List[String] = [
        "OK", "ERR_ABI", "ERR_DESCRIPTOR", "ERR_UNSUPPORTED", "ERR_CODE_DIGEST",
        "ERR_LOAD", "ERR_RAISED", "ERR_RETURN_TYPE", "ERR_LENGTH",
        "ERR_STATE_TOO_LARGE", "ERR_GROUP_TOO_LARGE", "ERR_CANCELLED",
        "ERR_DEADLINE", "ERR_OUT_OF_MEMORY", "ERR_INSTANCE_LOST", "ERR_INTERNAL",
        "ERR_FIELD_NOT_DECLARED", "ERR_WORKER_CRASHED", "ERR_HOST_CONTRACT",
        "ERR_KILLED", "ERR_READ_SET_MISMATCH", "ERR_BAD_OPTION",
    ]
    if status >= 0 and Int(status) < len(names):
        return names[Int(status)]
    return "status " + String(status)
