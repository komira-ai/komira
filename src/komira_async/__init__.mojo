"""`komira_async` — unified async substrate.

A standalone, library-first async substrate: per-core workers each owning a
reactor, a fork-join dispatcher, channels, timers, cancellation and async
synchronization primitives, behind one package.


Sub-modules (one source-tree directory per logical area; consumers import
directly via `from komira_async.<area>.<file> import <Type>`):
  - errors/        IoError, AsyncError, CancelledError, TimeoutError, ChannelClosed
  - primitives/    never_origin, yield_now, need_preempt, ConnectionRegistry
  - cancellation/  CancellationToken, ExecutionBudget, Cancellable
  - ops/           IoOp[T,S,ro], WakerSink trait
  - reactor/       Reactor[S], EpollSubsystem, KqueueSubsystem, MockSubsystem
  - spawner/       Spawner trait, ForkJoinSpawner, JoinHandle, TaskScope
  - channel/       MpscSender/Receiver, SpscSender/Receiver, OneshotSender/Receiver,
                   BroadcastSender/Receiver, Message[T]
  - sync/          AsyncMutex/MutexGuard, AsyncRwLock/Read/WriteGuard, Semaphore/SemPermit, Notify
  - stream/        Stream[T] trait + adapters (Map/Filter/Take/ChannelStream)
  - timer/         HierarchicalTimerWheel
  - morsel/        MorselPool[T] (single-owner OwnedPointer)
  - runtime/       PerCoreAsyncRuntime[S], Worker[S]

Pointer discipline:
  - ZERO UnsafePointer crossings of module boundaries (FFI internals only).
  - ZERO wildcard origins on the public surface.
  - ArcPointer ONLY appears as encapsulated `_shared:`-prefixed internal field
    on a Movable wrapper struct (CancellationToken, channel endpoints,
    ConnectionRegistry).
  - OwnedPointer is the canonical heap-stable single-owner shape (MorselPool,
    IoOp internals).
"""

