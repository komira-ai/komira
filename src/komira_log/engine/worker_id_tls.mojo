# =============================================================================
# komira_log.engine.worker_id_tls — pthread TLS for the ambient worker_id (P2b).
# =============================================================================
#
# A bare `log.info(...)` must know WHICH per-core ring to push into. The worker
# thread binds its `worker_id` into pthread thread-local storage ONCE when it
# starts; every subsequent log call on that thread reads it back in ~1ns.
#
#   create_worker_id_key() -> UInt64        # pthread_key_create, ONCE at init
#   delete_worker_id_key(key) -> Int32      # pthread_key_delete, ONCE at teardown
#   set_worker_id(key, id)                  # pthread_setspecific, once per worker
#   current_worker_id(key) -> UInt16        # pthread_getspecific, every log call
#
# Non-worker threads (the agent heartbeat loop, an HTTP handler, a CLI tool with
# no runtime) never call `set_worker_id`, so `current_worker_id` returns the
# WORKER_ID_UNSET sentinel (0xFFFF) → the facade routes them to the MPSC
# fallback ring.
#
# # SAFETY (FFI-BOUNDARY)
#
# The ONLY pointer crossing the FFI boundary is the void* TLS value, which is an
# INTEGER reinterpreted as a pointer — pthread stores the bit pattern verbatim
# and NEVER dereferences it (the TLS value is never a heap object). pthread_key_t
# is an opaque `unsigned int` on macOS + glibc; carried as UInt64 (the widest of
# the two ABIs) and narrowed at the FFI boundary. No `UnsafePointer` crosses the
# public surface — the API is integer-in / integer-out (the encapsulation rule).
# This is the same FFI-POD shape `komira_async`'s pthread worker uses.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed
    `UnsafePointer[T, o](_unsafe_null=())` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for the NULL pthread dtor arg below.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# Sentinel returned by current_worker_id when TLS is unset (NULL value). Matches
# the design's non-worker-thread MPSC fallback sentinel (0xFFFF).
comptime WORKER_ID_UNSET: UInt16 = 0xFFFF


def create_worker_id_key() raises -> UInt64:
    """`pthread_key_create` — make the TLS key ONCE at engine init.

    Signature: `int pthread_key_create(pthread_key_t *key, void (*dtor)(void*))`.
    pthread_key_t is `unsigned int` (4 bytes) on macOS + glibc; we read it into
    an 8-byte slot and zero-extend. NULL destructor (the TLS value is an integer,
    nothing to free).
    """
    var key_slot = Array[UInt64, 1](fill=UInt64(0))
    # SAFETY (FFI-BOUNDARY): key_slot is stack-local and outlives the FFI call;
    # the C function writes the key into it and returns. The cast is confined to
    # this one site; the address never escapes.
    var slot_ptr = UnsafePointer(to=key_slot).bitcast[UInt8]()
    var addr = UnsafePointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(slot_ptr)
    )
    var rc = external_call["pthread_key_create", Int32](
        addr,
        # NULL destructor — TLS holds an integer, not a heap object.
        _null_ptr[UInt8, MutUntrackedOrigin](),
    )
    if rc != 0:
        raise Error("pthread_key_create failed rc=" + String(rc))
    return key_slot[0]


def delete_worker_id_key(key: UInt64) -> Int32:
    """`pthread_key_delete` — give the TLS key back. Returns the rc; NEVER raises.

    ★ WHY THIS EXISTS, AND WHY ITS ABSENCE WAS NOT A TIDINESS PROBLEM.
    A pthread key is a PROCESS-WIDE resource with a HARD CAP
    (`PTHREAD_KEYS_MAX`: 512 on macOS, 1024 on glibc). `create_worker_id_key`
    needs a counterpart: without it a process that builds engines in a loop
    does not merely accumulate — once the keys run out, the next engine CANNOT
    BE CONSTRUCTED (`pthread_key_create` fails with EAGAIN after a few hundred
    `EngineContext()`s).

    RETURNS the rc rather than raising because the only caller is
    `SharedEngine.__del__` and a Mojo destructor is noexcept — the same shape
    `PerCoreAsyncRuntime.__del__` uses for `pthread_join`.

    # SAFETY (FFI-BOUNDARY): integer in, integer out; no pointer crosses.
    #
    # ⚠ DELETING A KEY DOES NOT RUN DESTRUCTORS FOR THREADS THAT STILL HOLD A
    # VALUE FOR IT (POSIX leaves that to the application). That is SOUND HERE on
    # both counts: the value is an INTEGER (`set_worker_id` stores `id + 1` as
    # the void*, never a heap object — there is nothing to free), and by the
    # time the owning `SharedEngine` is destroyed every thread that ever called
    # `set_worker_id` has been JOINED. See `SharedEngine.__del__` for why that
    # ordering holds by construction rather than by convention.
    """
    return external_call["pthread_key_delete", Int32](UInt32(key))


def set_worker_id(key: UInt64, worker_id: UInt16):
    """`pthread_setspecific` — bind THIS thread's worker_id. Call once when a
    worker thread starts.

    Signature: `int pthread_setspecific(pthread_key_t key, const void *value)`.
    We store `(worker_id + 1)` as the void* so worker_id 0 is distinguishable
    from the NULL "unset" state (TLS defaults to NULL). `current_worker_id()`
    subtracts the +1 bias back out.
    """
    var biased = UInt64(worker_id) + 1
    # SAFETY (FFI-BOUNDARY): `biased` is an integer reinterpreted as a void*.
    # pthread stores the bit pattern verbatim and NEVER dereferences it.
    var as_ptr = UnsafePointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(biased)
    )
    _ = external_call["pthread_setspecific", Int32](UInt32(key), as_ptr)


@always_inline
def current_worker_id(key: UInt64) -> UInt16:
    """`pthread_getspecific` — the ambient read at the bare log call site (~1ns).

    Signature: `void *pthread_getspecific(pthread_key_t key)`.
    Returns WORKER_ID_UNSET (0xFFFF) when the thread never called
    `set_worker_id` (TLS default NULL → 0 → unset sentinel). Otherwise returns
    the stored worker_id (undoing the +1 bias).
    """
    var raw = external_call[
        "pthread_getspecific", UnsafePointer[UInt8, MutUntrackedOrigin]
    ](UInt32(key))
    var bits = Int(raw)
    if bits == 0:
        return WORKER_ID_UNSET
    return UInt16(bits - 1)
