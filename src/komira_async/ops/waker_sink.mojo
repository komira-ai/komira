# =============================================================================
# komira_async.ops.waker_sink — WakerSink trait + concrete impls
# =============================================================================
# + the production WakerSink impls (ThreadWaker,
# FdWaker, MorselWaker — engine-side; declared closed-surface struct
# list).
#
# Sink for op-readiness notifications. The reactor OWNS its WakerSink. Each
# ready op_id from `Reactor.run_once` causes `wake(op_id)` to fire.
#
# The reactor owns the mapping from op_id to (fd, mode, consumer_id) in its
# Slab[WaitingOp]; the WakerSink only sees the op_id.
#
# NOT Movable — Atomic-bearing impls (ThreadWaker, FdWaker) cannot synthesize
# move on 0.26.3. Construct in place; reach via Pointer.
# NOT Copyable — one reactor owns one sink.
# =============================================================================


trait WakerSink(Deinitable):
    """Sink for op-readiness notifications.
    The single method is `wake(op_id)`; there is no separate Readiness
    enum.

    NOT Movable, NOT Copyable. One reactor owns one sink.
    """

    def wake(mut self, op_id: Int64) raises:
        ...


# Concrete production impls. declaration-only stubs;
# wires Condvar (ThreadWaker), eventfd / EVFILT_USER (FdWaker), and the
# engine's MorselScheduler park_word (MorselWaker, in komira_engine_runtime).


@fieldwise_init
struct ThreadWaker(WakerSink, Movable, Deinitable):
    """Standalone-consumer waker; uses Condvar for
    cross-thread wake. Constructed once per worker; lives at a stable
    address inside Reactor[ThreadWaker].

    A stub: the actual Condvar pair is not wired.
    """

    var _placeholder: UInt8

    def wake(mut self, op_id: Int64) raises:
        raise Error("not implemented")


@fieldwise_init
struct FdWaker(WakerSink, Movable, Deinitable):
    """eventfd (Linux) / EVFILT_USER (Darwin) backed
    waker. Used by Reactor when the worker thread parks in the kernel via
    epoll_wait / kevent and a peer worker needs to push a wake.

    A stub: the eventfd / kevent FFI lives in the Reactor itself.
    """

    var _placeholder: UInt8

    def wake(mut self, op_id: Int64) raises:
        raise Error("not implemented")


# NoopSink lives in the same module — used by synthetic IoOps (yield_now,
# channel ops, sync ops) whose readiness is NOT driven by a fd-readiness
# event but by an in-process wait queue. The IoOp surface keeps the
# call-site uniform (`channel.recv().wait()`); compose channel ops with
# reactor ops via select / gather.
@fieldwise_init
struct NoopSink(WakerSink, Movable, Deinitable):
    """+. Internal-to-komira_async
    sink for synthetic IoOps that are not registered with a real reactor.
    Their `_state` transitions to READY without going through wake().
    """

    var _placeholder: UInt8

    def wake(mut self, op_id: Int64) raises:
        # Synthetic ops never invoke their sink; readiness is driven by
        # the in-process wait queue not a fd-readiness event.
        raise Error("NoopSink.wake should never be called")
