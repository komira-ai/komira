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
# No pointer exists on the Mojo side. The void* TLS value is an INTEGER that
# pthread stores verbatim and NEVER dereferences (the TLS value is never a heap
# object); the integer <-> void* conversion, and the `pthread_key_t` out-
# parameter of `pthread_key_create`, live in three fixed-arity C entries in
# `_log_holder_shim.c` (`komira_log_tls_key_create` / `_set` / `_get`) that take
# and return integers. pthread_key_t is an opaque `unsigned int` on macOS +
# glibc; carried as UInt64 (the widest of the two ABIs) and narrowed at the FFI
# boundary. The API is integer-in / integer-out (the encapsulation rule).
# =============================================================================

from std.ffi import external_call


# Sentinel returned by current_worker_id when TLS is unset (NULL value). Matches
# the design's non-worker-thread MPSC fallback sentinel (0xFFFF).
comptime WORKER_ID_UNSET: UInt16 = 0xFFFF


def create_worker_id_key() raises -> UInt64:
    """Make the TLS key ONCE at engine init (`pthread_key_create`, with a NULL
    destructor: the TLS value is an integer, nothing to free).

    The C entry returns the key, or -1 when `pthread_key_create` failed (the key
    table is full: EAGAIN)."""
    var key = external_call["komira_log_tls_key_create", Int64]()
    if key < 0:
        raise Error("pthread_key_create failed")
    return UInt64(key)


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

    We store `(worker_id + 1)` as the TLS value so worker_id 0 is
    distinguishable from the NULL "unset" state (TLS defaults to NULL).
    `current_worker_id()` subtracts the +1 bias back out.
    """
    var biased = Int64(worker_id) + 1
    external_call["komira_log_tls_set", NoneType](Int64(key), biased)


@always_inline
def current_worker_id(key: UInt64) -> UInt16:
    """`pthread_getspecific` — the ambient read at the bare log call site.

    Returns WORKER_ID_UNSET (0xFFFF) when the thread never called
    `set_worker_id` (TLS default NULL → 0 → unset sentinel). Otherwise returns
    the stored worker_id (undoing the +1 bias).
    """
    var bits = Int(external_call["komira_log_tls_get", Int64](Int64(key)))
    if bits == 0:
        return WORKER_ID_UNSET
    return UInt16(bits - 1)
