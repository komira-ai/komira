# =============================================================================
# komira_async.runtime.pthread_worker — pthread launch
# =============================================================================
# (start/shutdown) with the heap-arg laundering pattern.
#
# Cross-platform pthread launch:
#   * `_PthreadArg[S]` — heap-boxed arg consumed + freed by the pthread.
#     Carries the laundered Worker address (Int) + worker_id.
#   * `_worker_pthread_entry[S]` — pthread start_routine. Recovers Worker
#     pointer via `unsafe_from_address=Int(arg.worker_addr)` (the ONE
#     allowed FFI-BOUNDARY site, the pthread-launch exception). Calls
#     `worker.run_until_shutdown()`.
#   * `launch_worker_pthread[S]` — public helper: heap-alloc the arg,
#     pthread_create with worker_addr, return the pthread_t handle.
#
# Each call launches ONE Worker on a pthread.
# The runtime owns the Worker via OwnedPointer; the pthread holds an
# FFI-laundered Int address that the entry recovers and dereferences for
# the lifetime of the pthread (which is bounded by the runtime's drop
# ordering — `shutdown` signals + pthread_joins BEFORE the OwnedPointer
# is freed). The runtime stores its workers as `Slab[OwnedPointer[Worker[S]]]`.
#
# Pointer discipline:
#   - `_PthreadArg[S].worker_addr: Int` is the FFI-POD carve-out (no
#     heap; just an address). Documented multi-line SAFETY block.
#   - `unsafe_from_address=Int(...)` is THE ONE allowed FFI-BOUNDARY site
#     per the pointer rules exception (pthread launch).
#   - public `launch_worker_pthread` takes the Worker by `ref [_]` (no
#     UnsafePointer crossing).
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc

# Affinity pinning at the
# worker-thread start site. The role byte on `_PthreadArg` selects which lane's
# CPU list (`engine_compute_cpus(p)` / `engine_io_cpus(p)`) the lane_index pins
# against. Gated by `EnginePlacement.pin_workers`; a False
# `pin_current_thread_to` return means "ran unpinned", always safe.
#
# NUMA-node locality — the SECOND, weaker placement at the
# same site: `confine_thread_to_engine_numa_node(p)` hands the thread the whole
# CHOSEN NUMA NODE as its mask instead of one CPU, so CFS still balances inside
# the socket. Gated by `EnginePlacement.numa_local` and additionally an
# identity no-op on any single-node host; a False return means "ran unconfined".
from komira_host.cpu_topology import (
    confine_thread_to_engine_numa_node,
    engine_compute_cpus,
    engine_io_cpus,
    pin_current_thread_to,
)
from komira_host.engine_placement import EnginePlacement

# komira_log — bind this worker thread's TLS worker_id so a `ctx.logger.*` on
# the thread routes to its per-core ring. the engine's pthread TLS key
# is CARRIED on the Worker (threaded from EngineContext at construction), so the
# bind is a direct `set_worker_id(key, worker_id)` — NO ambient
# `log_engine_ref()` (`unsafe_from_address=Int`) launder.
from komira_log.engine.worker_id_tls import set_worker_id

from komira_async.ops.waker_sink import WakerSink
from komira_async.runtime.worker import Worker


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed
    `_null_ptr[T, o]()` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL syscall arguments below.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# Worker lane role (compute/IO split).
# A POD UInt8 sentinel carried on `_PthreadArg` so `_worker_pthread_entry`
# knows which lane's CPU list to pin its `lane_index` against. The same UInt8-
# constant idiom as `PLACEMENT_FIXED` (runtime.mojo) / `SOURCE_PARQUET`.
comptime ROLE_COMPUTE: UInt8 = 0
comptime ROLE_IO: UInt8 = 1


@fieldwise_init
struct _PthreadArg[S: WakerSink & Movable & Deinitable](
    Copyable, Movable, Deinitable
):
    """Heap-boxed pthread arg. SAFETY: this struct is allocated on the
    heap by `launch_worker_pthread`, transferred to the pthread (single-
    consumer), and freed by the entry function before it returns. The
    `worker_addr` field is the FFI-POD address carve-out documented in
    the pointer rules exception (pthread launch).

    Why Copyable: pthread_create's `arg` parameter takes the heap pointer
    by value; the spawn-rig copies the arg pointer (NOT the contents) into
    the pthread stack. Copyable bound makes this trivial.

    Compute/IO split fields:
      * `role` — ROLE_COMPUTE / ROLE_IO. Selects which CpuTopology lane list
        (`engine_compute_cpus()` / `engine_io_cpus()`) the entry pins against.
      * `lane_index` — the index WITHIN that lane (NOT the global slab index;
        the IO lane's first worker has lane_index 0 even though its slab index
        is `n_compute`). `worker_id` stays the GLOBAL slab index (used for the
        per-core log TLS binding, which must be unique across both lanes).
    """

    var worker_addr: Int  # Int-laundered Worker[S]* — recovered by entry.
    var worker_id: UInt16
    var role: UInt8
    var lane_index: UInt16
    var placement: EnginePlacement


def _worker_pthread_entry[
    S: WakerSink & Movable & Deinitable,
](arg: UnsafePointer[NoneType, MutUntrackedOrigin]) -> UnsafePointer[
    NoneType, MutUntrackedOrigin
]:
    """pthread start_routine. Recovers the Worker pointer + runs
    run_until_shutdown.

    SAFETY (FFI-BOUNDARY):
      - `arg` is a heap-alloc'd `_PthreadArg[S]` whose ownership transfers
        to this thread on pthread_create. We free it before returning.
      - `worker_addr` is `Int(UnsafePointer(to=worker))` produced by
        launch_worker_pthread on the parent thread. The Worker outlives
        the pthread by construction:
        * runtime owns the Worker via OwnedPointer.
        * runtime.shutdown() signals via Atomic flag + pthread_joins
          BEFORE returning — so the pthread is fully exited before the
          runtime drops its OwnedPointer.
      - The Worker pointer recovered here is mutated through the FFI-
        boundary cast (`UnsafePointer[Worker[S], MutExternalOrigin]`
        from `unsafe_from_address=Int(...)`). This is the ONE allowed
        `unsafe_from_address=Int` site (the pthread-launch exception).
        Documented exception.
    """
    var typed_arg = arg.bitcast[_PthreadArg[S]]()
    var worker_id = typed_arg[].worker_id
    var worker_addr = typed_arg[].worker_addr
    var role = typed_arg[].role
    var lane_index = Int(typed_arg[].lane_index)
    var placement = typed_arg[].placement
    # Free the heap arg now — we've extracted the data.
    typed_arg.bitcast[UInt8]().free()

    # Compute/IO affinity pinning. Gated by
    # `placement.pin_workers` (default OFF -> the OS scheduler migrates
    # workers freely). When ON, pin this worker thread to its lane CPU:
    #   * ROLE_COMPUTE worker k -> engine_compute_cpus()[k]
    #   * ROLE_IO      worker k -> engine_io_cpus()[k]
    # `pin_current_thread_to` returns False (ran unpinned) on any failure / a
    # short lane list (partial-HT: a compute worker whose index is past the IO
    # lane simply never reaches the IO branch). Both are safe: an unpinned
    # worker is exactly today's behavior. This is the ONLY new FFI on the
    # worker path and it is the existing encapsulated primitive (cpu_set_t
    # never escapes cpu_topology.mojo).
    var pinned = False
    if placement.pin_workers:
        var cpus = (
            engine_compute_cpus(placement) if role
            == ROLE_COMPUTE else engine_io_cpus(placement)
        )
        if lane_index >= 0 and lane_index < len(cpus):
            pinned = pin_current_thread_to(cpus[lane_index])

    # NUMA-node locality — the WEAKER placement, and the one that is
    # independent of `placement.pin_workers`. Confine this worker to the chosen
    # NUMA node's CPUs (a multi-CPU mask: CFS keeps its freedom to balance
    # inside the socket, which is what makes this a `numactl --cpunodebind`
    # equivalent rather than a second pin).
    #
    # ORDER + THE `pinned` GUARD: a successful 1:1 pin is STRICTLY NARROWER than
    # this mask and already lands inside the node — `engine_compute_cpus()` has
    # been filtered by NUMA locality before the pin site reads it, because both go
    # through `engine_topology()`. Widening it back to the whole node afterwards
    # would silently undo the pin for anyone running both settings. So
    # the confinement is the FALLBACK, not an addition; on the default path
    # (pin OFF) it is the only placement that runs.
    if not pinned and placement.numa_local:
        _ = confine_thread_to_engine_numa_node(placement)

    # Recover Worker pointer. ONE allowed FFI-BOUNDARY site.
    var worker_ptr = UnsafePointer[Worker[S], MutUntrackedOrigin](
        unsafe_from_address=worker_addr,
    )

    # komira_log — bind this thread's worker_id into pthread TLS so a bare
    # `log.*` on this worker thread resolves the right per-core ring. Done ONCE
    # here at thread start. Only if an
    # engine is installed (the forever-root built one); otherwise the facade
    # uses the synchronous fallback and TLS is irrelevant.
    var log_tls_key = worker_ptr[].log_tls_key()
    if log_tls_key != UInt64(0):
        set_worker_id(log_tls_key, worker_id)
    # Drive the worker's main loop. Blocks until signal_shutdown is set.
    try:
        worker_ptr[].run_until_shutdown()
    except e:
        # Mojo 0.26.3 pthread entry can't propagate exceptions. Print +
        # continue (cancellation propagates through the token cascade in the
        # worker.run_until_shutdown body).
        print(
            "WARN _worker_pthread_entry: run_until_shutdown raised: ",
            String(e),
        )
    # pthread_create's `void* (*start_routine)(void*)`
    # ABI requires a raw `UnsafePointer` return — Optional cannot stand in
    # without changing the entry-fn type signature. Use `_unsafe_null=()`
    # to construct a true NULL bit pattern without the deprecated default
    # ctor.
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def launch_worker_pthread[
    S: WakerSink & Movable & Deinitable,
](
    ref [_] worker: Worker[S],
    worker_id: UInt16,
    ref [_] thread_id_slot: Int64,
    role: UInt8 = ROLE_COMPUTE,
    lane_index: UInt16 = UInt16.MAX,
    placement: EnginePlacement = EnginePlacement(),
) raises -> Int32:
    """Heap-alloc + pthread_create wrapper. Returns the pthread_create rc.

    `thread_id_slot` is an `Int64` storage slot the caller owns; we write
    the pthread_t handle into it via UnsafePointer aliasing (pthread_t is
    typically 64-bit on Linux + macOS).

    Compute/IO split:
      * `role` — ROLE_COMPUTE (default) / ROLE_IO. Carried on the pthread arg;
        the entry uses it to select the lane CPU list when
        `placement.pin_workers` is set.
      * `lane_index` — the index within `role`'s lane. Defaults to
        `worker_id` (the single-lane case where the slab index IS the lane
        index — the single-lane behavior for all existing callers).
        The two-lane `start()` passes the IO worker's lane-local index
        explicitly so IO worker k pins to `engine_io_cpus(placement)[k]`.
      * `placement` — the worker CPU placement (`EnginePlacement`) the
        entry applies; the default `EnginePlacement()` pins nothing.

    SAFETY:
      - `worker` is borrowed for the duration of this fn. We extract the
        address (`Int(UnsafePointer(to=worker))`) and pass it into the
        heap arg; the pthread then holds the address for its lifetime.
        Caller MUST guarantee `worker` outlives the pthread (runtime's
        drop ordering — shutdown joins all pthreads before freeing).
    """
    var worker_addr = Int(UnsafePointer(to=worker))
    # Default lane_index to worker_id (single-lane: slab index == lane index).
    # UInt16.MAX is the "use worker_id" sentinel so existing callers need no
    # change and still pin worker k to compute_cpus()[k].
    var resolved_lane = lane_index if lane_index != UInt16.MAX else worker_id

    # Heap-alloc the _PthreadArg[S]. Use Repro 7 / the canonical shape: alloc +
    # init_pointee_move. The arg is Copyable + Movable so init_pointee_move
    # is the canonical fill.
    var raw = alloc[_PthreadArg[S]](1)
    UnsafePointer(to=raw[]).unsafe_write(
        _PthreadArg[S](
            worker_addr=worker_addr,
            worker_id=worker_id,
            role=role,
            lane_index=resolved_lane,
            placement=placement,
        ),
    )
    # Cast raw → void* (UnsafePointer[NoneType, MutExternalOrigin]) for
    # pthread_create's third arg.
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()

    # pthread_create. Slot for pthread_t handle is the first arg.
    var slot_addr = UnsafePointer(to=thread_id_slot)
    var rc = external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),  # pthread_t* (typically 64-bit)
        _null_ptr[UInt8, MutUntrackedOrigin](),  # attr (NULL)
        _worker_pthread_entry[S],   # start_routine
        raw_void,                    # arg
    )
    return rc


def join_worker_pthread(thread_id: Int64) -> Int32:
    """Wrapper around pthread_join. Returns rc."""
    return external_call["pthread_join", Int32](
        thread_id, _null_ptr[UInt8, MutUntrackedOrigin](),
    )
