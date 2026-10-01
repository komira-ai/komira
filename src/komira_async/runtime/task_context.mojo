# =============================================================================
# komira_async.runtime.task_context — TaskContext
# =============================================================================
# + — per-task context. Carries:
#   - worker_addr: Int       — Int-laundered worker pointer
#   - reactor_addr: Int      — Int-laundered reactor pointer
#   - cancellation: CancellationToken (clone, owned by-value)
#
# v0.1 carve-out: TaskContext is constructed at task spawn time + threaded
# through awaitables via parametric `ctx_origin: Origin[mut=True]`. The
# worker_addr / reactor_addr fields are laundered Int-payloads per the
# canonical FFI-POD pattern documented at `runtime/awaitables.mojo` module
# top — the underlying Worker[S] + Reactor[S] live behind OwnedPointer
# slots on the runtime, with stable heap addresses for the runtime's
# lifetime.
#
# Cancellation track:
#   - State-machine track (IoOp.wait): polls ctx.cancellation[].is_cancelled()
#     between Reactor.poll_completions iterations; if cancelled, deregisters
#     the OpHandle and raises Error("CancelledError").
#   - Async/await track v0.1: each awaitable polls
#     ctx.cancellation[].is_cancelled() BEFORE __await__ does any work. If
#     cancelled at await entry, returns CancelledError without registering
#     with the reactor (avoids parking a doomed coro). Once parked: NO abort
#     path — the coro completes when IO completes (launch-and-let-complete).
# =============================================================================

from std.memory import OwnedPointer

from komira_async.cancellation.token import CancellationToken


@fieldwise_init
struct TaskContext(Movable, Deinitable):
    """Per-task context bundling worker/reactor address handles
    and the cancellation token.

    Movable but NOT Copyable: the cancellation token is clone-explicitly;
    constructing two TaskContexts that share a token would defeat the
    explicit-clone discipline. The `clone()` method below is the explicit
    boundary.

    Pointer discipline:
      - worker_addr / reactor_addr: laundered Ints per (the FFI-POD
        carve-out documented at `runtime/awaitables.mojo` module top). The
        underlying Worker[S] + Reactor[S] live behind OwnedPointer slots on
        the PerCoreAsyncRuntime for the runtime's lifetime; the addresses
        remain valid for the TaskContext's entire lifetime (bounded by the
        spawn/coro frame).
      - cancellation: by-value CancellationToken (Movable wrapper around
        List[ArcPointer[_AtomicSlot]]). Cloned at construction time from
        the parent token; descendants observe parent cancellation via the
        shared ancestor chain.

    Field set:
      var worker_addr: Int                — laundered Worker[S]*
      var reactor_addr: Int               — laundered Reactor[S]*
      var cancellation: CancellationToken — owned by-value
    """

    var worker_addr: Int
    var reactor_addr: Int
    var cancellation: CancellationToken

    @staticmethod
    def make(
        worker_addr: Int,
        reactor_addr: Int,
        var cancellation: CancellationToken,
    ) -> TaskContext:
        """Factory constructor. Consumes the cancellation token (caller can
        clone() before passing if they want to retain a copy)."""
        return TaskContext(
            worker_addr=worker_addr,
            reactor_addr=reactor_addr,
            cancellation=cancellation^,
        )

    def clone(self) -> TaskContext:
        """Explicit clone — addresses copy by value (POD); the cancellation
        token clones via its `clone()` method (refcount bump on each chain
        slot per CancellationToken contract)."""
        return TaskContext(
            worker_addr=self.worker_addr,
            reactor_addr=self.reactor_addr,
            cancellation=self.cancellation.clone(),
        )

    @always_inline
    def is_cancelled(self) -> Bool:
        """Pre-park / per-iter cancellation check. Returns True if the
        bound token (or any ancestor) has been cancelled."""
        return self.cancellation.is_cancelled()
