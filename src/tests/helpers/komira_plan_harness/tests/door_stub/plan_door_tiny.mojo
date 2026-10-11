# =============================================================================
# FFI-BOUNDARY: plan_door_tiny -- the door ABI with nothing behind it.
# =============================================================================
#
# Two test-only shared libraries of komira_plan_harness/BUCK are built from
# this one file, for two refusals PlanDoor.open must name before any plan is
# sent:
#
#   :plan_door_null_ctx   exports all six door symbols; komira_ctx_new
#                         returns NULL: PLAN_DOOR_CTX_NEW_FAILED.
#   :plan_door_no_bytes   `exports_exact` without komira_plan_bytes, so that
#                         symbol is local to the library and dlsym cannot
#                         find it: PLAN_DOOR_MISSING_SYMBOL, which open must
#                         raise before it calls komira_ctx_new.
#
# It reports door ABI version 1 (door.mojo's PLAN_DOOR_ABI_VERSION). Every
# plan call returns DOOR_ERR_ENGINE and touches no out slot; last_error is
# NULL (no session can exist to hold a message).
#
# Who owns and frees each pointer: nothing is allocated (ctx is always
# NULL); plan and out pointers are never read or written.
# =============================================================================

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _BytesPtr = UnsafePointer[UInt8, MutUntrackedOrigin]


def _null_void() -> _VoidPtr:
    # SAFETY: Optional of a pointer has the bare pointer's layout and None is
    # NULL; returned as a C NULL, never dereferenced.
    var none: Optional[_VoidPtr] = None
    return UnsafePointer(to=none).bitcast[_VoidPtr]()[]


@export
def komira_abi_version() abi("C") -> Int32:
    return 1


@export
def komira_ctx_new() abi("C") -> _VoidPtr:
    return _null_void()


@export
def komira_ctx_free(ctx: _VoidPtr) abi("C"):
    _ = ctx


@export
def komira_last_error(ctx: _VoidPtr) abi("C") -> _BytesPtr:
    _ = ctx
    return _null_void().bitcast[UInt8]()


@export
def komira_plan_stream(ctx: _VoidPtr, plan: _BytesPtr, plan_len: UInt64, out_stream: _VoidPtr) abi("C") -> Int32:
    _ = ctx
    _ = plan
    _ = plan_len
    _ = out_stream
    return -3


@export
def komira_plan_bytes(
    ctx: _VoidPtr, plan: _BytesPtr, plan_len: UInt64, out_buf: _BytesPtr, out_cap: UInt64, out_len: _VoidPtr
) abi("C") -> Int32:
    _ = ctx
    _ = plan
    _ = plan_len
    _ = out_buf
    _ = out_cap
    _ = out_len
    return -3
