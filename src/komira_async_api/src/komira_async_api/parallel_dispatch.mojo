# =============================================================================
# komira_async_api.parallel_dispatch — ParallelDispatch trait
# =============================================================================
# The arrow IPC body compress/decompress + decoder-dispatch entries in
# the core packages dispatch parallel per-buffer work, but the concrete
# dispatcher (`LocalDispatcher[NoopSink]`) lives UP in `komira_async`. Naming
# `LocalDispatcher[NoopSink]` in their signatures would create a
# `the core packages -> komira_async` up-edge (an import cycle).
#
# TRAIT INVERSION: this trait abstracts the ONE dispatch operation the arrow
# IPC path uses (`run_with_state`). The core packages depends only on the trait;
# `komira_async`'s `LocalDispatcher` CONFORMS to it (a down-edge async ->
# core, which is allowed). The arrow IPC entries become generic over
# `D: ParallelDispatch` — `D` is a monomorphized type parameter, so the call
# DEVIRTUALIZES at each instantiation (no vtable; `LocalDispatcher.run_with_state`
# is called directly after monomorphization). No perf cost vs. a hard-coded
# dispatcher.
#
# `NoDispatch` is the zero-sized serial-fallback conformer used by the bare
# (no-EngineContext) wrappers. Its `run_with_state` body is UNREACHABLE — the
# bare wrappers pass `has_pool=False` so the comptime branch that would call
# `D.run_with_state` is pruned away. Substituting `D=NoDispatch` lets the bare
# wrappers name a concrete origin for their always-`None` dispatcher pointer
# instead of a wildcard origin.
#
# Method-level parameters (`run_with_state[State, T]`) are legal on a trait
# method — same precedent as `Segment.execute[State]` in
# `runtime_traits/worker_pool_traits.mojo`. Mojo does NOT support
# parameters on the trait DECLARATION itself, but DOES support them on a trait
# METHOD.
# =============================================================================

from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment


trait ParallelDispatch(Movable, Deinitable):
    """Abstract fork-join dispatch surface for the arrow IPC compress /
    decompress / decode path.

    The ONE method `run_with_state[State, T]` matches
    `LocalDispatcher.run_with_state` byte-for-byte. The core packages
    entries thread a `D: ParallelDispatch` through their dispatcher pointers
    instead of hard-coding `LocalDispatcher[NoopSink]`, which removes the
    `the core packages -> komira_async` up-edge.

    Conformers:
      * `LocalDispatcher[S]` (in `komira_async`) — the real
        EngineContext-owned dispatcher.
      * `NoDispatch` (below) — zero-sized serial-fallback stand-in for the
        bare (no-dispatcher) wrappers; its body is unreachable.

    `run_with_state`:
      - dispatches `n` copies of `seg.execute[State](state, wid, tid)`
        across the conformer's worker set, borrowing `state` for the
        dispatch window and MOVING `seg` + `cancel_token` in.
      - returns the moved `seg` back to the caller on completion.

    `worker_count`:
      - the HARDWARE-DERIVED shard ceiling (the conformer's attached-worker
        count). The shared-payload fork-join driver
        (`runtime_traits/fork_join_shared.mojo`) sizes every wave from it
        instead of from a constant.
    """

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        ...

    def worker_count(self) -> Int:
        ...


struct NoDispatch(ParallelDispatch, Movable, Deinitable):
    """Zero-sized serial-fallback conformer for the bare arrow IPC wrappers.

    The bare (no-EngineContext) entries pass `has_pool=False`, so the comptime
    branch that would invoke `D.run_with_state` is pruned and this body is
    NEVER reached at runtime. It exists only so the bare wrappers can name a
    CONCRETE `D=NoDispatch` (with an empty/static-origin `None` pointer)
    instead of an `Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]]`
    carrying a wildcard origin.
    """

    def __init__(out self):
        # Zero-sized; nothing to initialize. Exists so the bare arrow IPC
        # wrappers can stack-construct a `NoDispatch` and take a concrete
        # `origin_of(...)` for the (always-None) dispatcher Optional.
        pass

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        # UNREACHABLE: bare wrappers gate this behind comptime `has_pool=False`.
        # Consume the moved-in token + return the moved-in segment so the
        # ownership/destructor contract is satisfied for the (never-taken) path.
        _ = cancel_token^
        return seg^

    def worker_count(self) -> Int:
        # UNREACHABLE for the same reason as `run_with_state` (the
        # `has_pool=False` arm never sizes a wave). 1 is the honest answer for a
        # dispatcher that owns no workers.
        return 1
