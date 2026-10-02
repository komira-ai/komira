# =============================================================================
# _pthread.mojo -- this package's one pthread_create / pthread_join binding
# =============================================================================
#
# Two bindings of one C symbol with different argument types in one binary can
# fail to lower, so the thread-spawning code in this package goes through the
# functions below. The argument tuple is the one the tree's detached-spawn
# helper uses: a `pthread_t*` out parameter, a NULL attribute pointer, a thin
# `void *(*)(void *)` entry and an opaque `void *` argument.
#
# Private to the package: nothing outside `komira_spawn_join` should import
# this module.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer

# Canonical FFI origin (FFI-BOUNDARY: pthread). A concrete (non-wildcard)
# origin; the `void *` args and returns are opaque and cross the ABI by value.
comptime FFI_ORIGIN = ImmStaticOrigin
comptime FfiHandle = UnsafePointer[NoneType, FFI_ORIGIN]
comptime FfiByte = UnsafePointer[UInt8, FFI_ORIGIN]
comptime ThreadEntry = def (FfiHandle) thin -> FfiHandle


@always_inline
def ffi_null() -> FfiHandle:
    """A NULL opaque handle (the stdlib has no null pointer constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer; `None` is the all-zero NULL bit pattern. No removed null
    # constructor and no `unsafe_from_address`.
    """
    var none: Optional[FfiHandle] = None
    return UnsafePointer(to=none).bitcast[FfiHandle]()[]


@always_inline
def pthread_create_thread(
    mut tid: UInt64, entry: ThreadEntry, arg: FfiHandle
) -> Int32:
    """Start a joinable thread running `entry(arg)`; the handle goes to `tid`.

    Returns the `pthread_create` return code (0 on success).
    """
    return external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        ffi_null().bitcast[UInt8](),
        entry,
        arg,
    )


@always_inline
def pthread_join_thread(tid: UInt64) -> Int32:
    """Block until thread `tid` exits; the thread's return value is dropped."""
    return external_call["pthread_join", Int32](
        tid, ffi_null().bitcast[UInt8]()
    )


@always_inline
def pthread_self_id() -> UInt64:
    """An opaque identifier of the calling thread: equal on one thread,
    different on two live threads. Meaningless across processes."""
    return external_call["pthread_self", UInt64]()
