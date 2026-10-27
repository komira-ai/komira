# The numbers of komira_udf_runtime.h, as Mojo values, and the host's error
# table (docs/design/udf_runtime_interface.md section 4.5). tests/test_layout
# compares every constant here with the C header through the layout probe.

comptime ABI_MAJOR: UInt32 = 1
comptime ABI_MINOR: UInt32 = 0

comptime ARROW_FLAG_NULLABLE: Int64 = 2
comptime ARROW_DEVICE_CPU: Int32 = 1

# komira_udf_status
comptime OK: Int32 = 0
comptime ERR_ABI: Int32 = 1
comptime ERR_DESCRIPTOR: Int32 = 2
comptime ERR_UNSUPPORTED: Int32 = 3
comptime ERR_CODE_DIGEST: Int32 = 4
comptime ERR_LOAD: Int32 = 5
comptime ERR_RAISED: Int32 = 6
comptime ERR_RETURN_TYPE: Int32 = 7
comptime ERR_LENGTH: Int32 = 8
comptime ERR_STATE_TOO_LARGE: Int32 = 9
comptime ERR_GROUP_TOO_LARGE: Int32 = 10
comptime ERR_CANCELLED: Int32 = 11
comptime ERR_DEADLINE: Int32 = 12
comptime ERR_OUT_OF_MEMORY: Int32 = 13
comptime ERR_INSTANCE_LOST: Int32 = 14
comptime ERR_INTERNAL: Int32 = 15
comptime ERR_FIELD_NOT_DECLARED: Int32 = 16
comptime ERR_WORKER_CRASHED: Int32 = 17
comptime ERR_HOST_CONTRACT: Int32 = 18
comptime ERR_KILLED: Int32 = 19
comptime ERR_READ_SET_MISMATCH: Int32 = 20
comptime STATUS_COUNT = 21
"""The statuses ABI 1.0 defines: 0 to STATUS_COUNT - 1."""

# capabilities.shapes / spec.shape
comptime SHAPE_SCALAR: UInt32 = 1 << 0
comptime SHAPE_ROW: UInt32 = 1 << 1
comptime SHAPE_MAP_BATCHES_COLUMN: UInt32 = 1 << 2
comptime SHAPE_MAP_BATCHES_FRAME: UInt32 = 1 << 3
comptime SHAPE_MAP_BATCHES_FRAME_GROUPED: UInt32 = 1 << 4
comptime SHAPE_AGG_PLAIN: UInt32 = 1 << 5
comptime SHAPE_AGG_MERGEABLE: UInt32 = 1 << 6
comptime SHAPE_STEP: UInt32 = 1 << 7

# capabilities.udf_class, devices, features
comptime CLASS_NATIVE: UInt32 = 1
comptime CLASS_MANAGED: UInt32 = 2
comptime DEVICE_CPU: UInt32 = 1 << 0
comptime FEATURE_MEMORY_REPORT: UInt32 = 1 << 0
comptime FEATURE_CONTAINS_CRASHES: UInt32 = 1 << 1
comptime FEATURE_FORCED_STOP: UInt32 = 1 << 2
comptime FEATURES_DEFINED: UInt32 = FEATURE_MEMORY_REPORT | FEATURE_CONTAINS_CRASHES | FEATURE_FORCED_STOP
"""Every feature bit ABI 1.0 defines; a runtime reporting another fails its
capabilities check."""

# spec.form, spec.null_mode, spec.stability
comptime FORM_PACKAGE: Int32 = 1
comptime FORM_BUNDLE: Int32 = 2
comptime FORM_VALUE: Int32 = 3
comptime NULL_MANUAL: Int32 = 1
comptime NULL_PROPAGATE: Int32 = 2
comptime IMMUTABLE: Int32 = 1
comptime STABLE: Int32 = 2
comptime VOLATILE: Int32 = 3


def status_name(code: Int32) -> String:
    """The header's name of a komira_udf_status, or `UNKNOWN(<n>)`."""
    if code == OK:
        return "OK"
    if code == ERR_ABI:
        return "ERR_ABI"
    if code == ERR_DESCRIPTOR:
        return "ERR_DESCRIPTOR"
    if code == ERR_UNSUPPORTED:
        return "ERR_UNSUPPORTED"
    if code == ERR_CODE_DIGEST:
        return "ERR_CODE_DIGEST"
    if code == ERR_LOAD:
        return "ERR_LOAD"
    if code == ERR_RAISED:
        return "ERR_RAISED"
    if code == ERR_RETURN_TYPE:
        return "ERR_RETURN_TYPE"
    if code == ERR_LENGTH:
        return "ERR_LENGTH"
    if code == ERR_STATE_TOO_LARGE:
        return "ERR_STATE_TOO_LARGE"
    if code == ERR_GROUP_TOO_LARGE:
        return "ERR_GROUP_TOO_LARGE"
    if code == ERR_CANCELLED:
        return "ERR_CANCELLED"
    if code == ERR_DEADLINE:
        return "ERR_DEADLINE"
    if code == ERR_OUT_OF_MEMORY:
        return "ERR_OUT_OF_MEMORY"
    if code == ERR_INSTANCE_LOST:
        return "ERR_INSTANCE_LOST"
    if code == ERR_INTERNAL:
        return "ERR_INTERNAL"
    if code == ERR_FIELD_NOT_DECLARED:
        return "ERR_FIELD_NOT_DECLARED"
    if code == ERR_WORKER_CRASHED:
        return "ERR_WORKER_CRASHED"
    if code == ERR_HOST_CONTRACT:
        return "ERR_HOST_CONTRACT"
    if code == ERR_KILLED:
        return "ERR_KILLED"
    if code == ERR_READ_SET_MISMATCH:
        return "ERR_READ_SET_MISMATCH"
    return "UNKNOWN(" + String(code) + ")"


def status_from_name(name: String) raises -> Int32:
    """The inverse of status_name over the header's statuses."""
    for c in range(STATUS_COUNT):
        if status_name(Int32(c)) == name:
            return Int32(c)
    raise Error("UDF_STATUS_UNKNOWN: " + name)


comptime RUN_CANCEL = "UDF_CANCELLED"
"""The harness's label for "the run's cancel" (design section 4.5). The design
names no identifier for it: a cancelled run fails with whatever its cancel
carries. Every ERR_CANCELLED, and every ERR_KILLED of a call whose cancel the
host had set, maps to this label."""

comptime KIND_UNSUPPORTED = "OPTIMIZED_UDF_KIND_UNSUPPORTED"
"""The host's refusal of a shape the runtime as a whole lacks, taken from
describe before validate is called (design sections 4.2 and 4.5). No status
maps to it: the harness produces it itself."""


def loses_context(code: Int32) -> Bool:
    """Whether a status loses the context it was returned on (design section
    4.5): ERR_INSTANCE_LOST, ERR_WORKER_CRASHED, ERR_KILLED and
    ERR_OUT_OF_MEMORY. After any of them the host makes no further call into
    the context, only closes its objects and then the context; after any other
    failure the context and its instances stay usable."""
    return (
        code == ERR_INSTANCE_LOST
        or code == ERR_WORKER_CRASHED
        or code == ERR_KILLED
        or code == ERR_OUT_OF_MEMORY
    )


def run_error(code: Int32, at_call: Bool, shape: UInt32 = 0, cancel_was_set: Bool = False) -> String:
    """The run's named error for a status, through one table for every runtime
    (design section 4.5). `at_call` tells ERR_UNSUPPORTED returned by a call
    (a runtime fault) from one returned by validate or load. `shape` is the
    called UDF's shape (a STEP's deadline is UDF_STEP_TIMED_OUT), and
    `cancel_was_set` whether the host had set the call's cancel flag (it
    decides ERR_KILLED). OK maps to ""."""
    if code == OK:
        return ""
    if code == ERR_RAISED:
        return "UDF_RAISED"
    if code == ERR_RETURN_TYPE:
        return "UDF_RETURN_TYPE_MISMATCH"
    if code == ERR_LENGTH:
        return "UDF_BATCH_LENGTH_MISMATCH"
    if code == ERR_FIELD_NOT_DECLARED:
        return "UDF_FIELD_NOT_DECLARED"
    if code == ERR_STATE_TOO_LARGE:
        return "UDF_STATE_TOO_LARGE"
    if code == ERR_GROUP_TOO_LARGE:
        return "UDF_GROUP_TOO_LARGE"
    if code == ERR_LOAD:
        return "OPTIMIZED_UDF_CODE_UNLOADABLE"
    if code == ERR_CODE_DIGEST:
        return "OPTIMIZED_UDF_CODE_DIGEST_MISMATCH"
    if code == ERR_DESCRIPTOR:
        return "OPTIMIZED_UDF_DESCRIPTOR_INVALID"
    if code == ERR_READ_SET_MISMATCH:
        return "OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH"
    if code == ERR_UNSUPPORTED and not at_call:
        return "OPTIMIZED_UDF_UNSUPPORTED"
    if code == ERR_ABI:
        return "UDF_RUNTIME_ABI_MISMATCH"
    if code == ERR_CANCELLED:
        return RUN_CANCEL
    if code == ERR_KILLED and cancel_was_set:
        return RUN_CANCEL
    if code == ERR_DEADLINE or code == ERR_KILLED:
        if shape == SHAPE_STEP:
            return "UDF_STEP_TIMED_OUT"
        return "UDF_DEADLINE_EXCEEDED"
    if code == ERR_INSTANCE_LOST or code == ERR_WORKER_CRASHED:
        return "UDF_WORKER_CRASHED"
    if code == ERR_OUT_OF_MEMORY:
        return "UDF_OUT_OF_MEMORY"
    if code == ERR_HOST_CONTRACT:
        return "UDF_HOST_CONTRACT_VIOLATION"
    return "UDF_RUNTIME_FAULT"


def shape_from_name(name: String) raises -> UInt32:
    """The shape bit named as in the design (`SCALAR`, `AGG_MERGEABLE`, ...)."""
    if name == "SCALAR":
        return SHAPE_SCALAR
    if name == "ROW":
        return SHAPE_ROW
    if name == "MAP_BATCHES_COLUMN":
        return SHAPE_MAP_BATCHES_COLUMN
    if name == "MAP_BATCHES_FRAME":
        return SHAPE_MAP_BATCHES_FRAME
    if name == "MAP_BATCHES_FRAME_GROUPED":
        return SHAPE_MAP_BATCHES_FRAME_GROUPED
    if name == "AGG_PLAIN":
        return SHAPE_AGG_PLAIN
    if name == "AGG_MERGEABLE":
        return SHAPE_AGG_MERGEABLE
    if name == "STEP":
        return SHAPE_STEP
    raise Error("UDF_SHAPE_UNKNOWN: " + name)
