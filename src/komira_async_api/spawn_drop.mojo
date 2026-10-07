# =============================================================================
# spawn_drop — detached background-drop primitive
# =============================================================================
#
# Fire-and-forget detached-pthread drop. Used by the parallel combine
# drivers to keep the per-worker partition + aggregate-map + accumulator
# destructor chain off the critical merge path.
#
# The FFI carve-out (pthread_create + pthread_detach to drop a heap-boxed
# value on a background thread) is orthogonal to any pool's dispatch engine.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc


# Canonical FFI origin (FFI-BOUNDARY: pthread). StaticConstantOrigin is a
# CONCRETE (non-wildcard) origin; the
# pthread void* args/returns are opaque and passed by value across the ABI.
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiHandle = UnsafePointer[NoneType, _FFI_ORIGIN]
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null() -> _FfiHandle:
    """Raw NULL opaque-handle (the stdlib has no null pointer ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer; `None` is
    # the all-zero NULL bit pattern. No removed null ctor, no banned
    # `unsafe_from_address=Int(0)`.
    """
    var none: Optional[_FfiHandle] = None
    return UnsafePointer(to=none).bitcast[_FfiHandle]()[]


def _spawn_drop_entry_for[T: Movable & Deinitable](
    arg: _FfiHandle,
) -> _FfiHandle:
    """pthread start_routine for spawn_drop. arg is the heap-allocated
    `T*` previously produced by `alloc[T](1) + init_pointee_move(value)`.

    Reconstructs `OwnedPointer[T](unsafe_from_raw_pointer=arg.bitcast[T]())`
    and drops it at scope exit. T's destructor cascades through any
    inner heap-owning fields.
    """
    # SAFETY: caller (`spawn_drop[T]`) allocated `arg` via `alloc[T](1)`
    # and initialised it via `init_pointee_move(value^)`. Reconstructing
    # the OwnedPointer here transfers ownership of the heap slot to this
    # function; the OwnedPointer's destructor at scope exit calls
    # `T.__del__` then frees the slot.
    # The void* arg is an owned heap box; recover a MutUntrackedOrigin typed
    # pointer (the origin `OwnedPointer.unsafe_from_raw_pointer` requires)
    # so OwnedPointer can take ownership + free it. The static FFI origin is
    # immutable on the ABI face; `unsafe_mut_cast[True]` + the origin cast
    # restore write/own capability for the heap slot we provably own
    # (alloc'd in spawn_drop).
    var typed = (
        arg.bitcast[T]()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var owned = OwnedPointer[T](unsafe_from_raw_pointer=typed)
    _ = owned^
    return _ffi_null()


def spawn_drop[T: Movable & Deinitable](var value: T) -> None:
    """Drop `value` on a detached background pthread. Fire-and-forget.

    Used by the parallel combine drivers to keep the per-worker
    partition + aggregate-map + accumulator destructor chain off
    the critical merge path.

    Failure mode: if pthread_create fails (rare; out-of-resources), the
    value is dropped synchronously inline — same destructor cost as a
    no-op spawn_drop. No raise, no surfacing of the failure beyond a
    silent fallback (matches `std::thread::spawn`'s behaviour, which
    panics; we soften to silent because the cost is purely a perf
    deopt).
    """
    # Heap-box the value via alloc + init_pointee_move (the same idiom
    # used for pre-allocated Slab slots).
    var raw = alloc[T](1)
    UnsafePointer(to=raw[]).unsafe_write(value^)

    # Stable per-T pthread entry function pointer. Mojo monomorphises
    # `_spawn_drop_entry_for[T]` per call site; the resulting fn ptr
    # has the void*(*)(void*) shape pthread_create expects.
    var entry = _spawn_drop_entry_for[T]

    # pthread_t storage is a stack local — pthread_detach reads its
    # value (an opaque thread handle) but the storage need not outlive
    # this function (pthread_detach copies the handle into kernel state).
    var tid: UInt64 = UInt64(0)
    var raw_arg = raw.bitcast[NoneType]().unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN]()
    var rc = external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        _ffi_null().bitcast[UInt8](),
        entry,
        raw_arg,
    )
    if rc != Int32(0):
        # pthread_create failed; the heap box is still alive at
        # `raw`. Reconstruct the OwnedPointer here and drop it
        # synchronously — value is destroyed, slot is freed, no leak.
        var fallback = OwnedPointer[T](unsafe_from_raw_pointer=raw)
        _ = fallback^
        return

    # SAFETY: pthread_detach releases the joinable kernel thread state
    # so resources are reclaimed at thread exit. After this call, no
    # one will pthread_join the thread. If detach fails (rc != 0), the
    # kernel thread becomes a zombie pending join — leaked, but not
    # incorrect. This mirrors a detached `std::thread::spawn` with no
    # JoinHandle stored.
    _ = external_call["pthread_detach", Int32](tid)
