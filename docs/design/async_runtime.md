# The async runtime: a reactor, and one event loop per worker

## What is it for, and what is out of scope?

`komira_async` gives Mojo code non-blocking I/O and multi-threaded execution without compiler coroutines. It has three parts:

- A **reactor** (`Reactor`) waits on many operations at once and reports each finished one as a **completion**, identified by an integer op id. Its **backend** is epoll on Linux, kqueue on macOS, or `BACKEND_MOCK`, which opens no kernel descriptor and reports no completions.
- A **worker runtime** (`PerCoreAsyncRuntime`) starts N threads called **workers**. Each worker is an event loop that owns one reactor and one inbound task queue. A task that starts on a worker finishes there, and work crosses threads only through explicit queues.
- The **`Runtime` trait**, the seam that protocol clients and servers are generic over. `PerCoreAsyncRuntime` conforms, and so do three runtimes that drive one reactor on the calling thread and start no worker: `BlockingRuntime`, `GcpCloudRunRuntime` and `AwsLambdaRuntime` ([conformers](#which-runtimes-implement-the-runtime-trait)).

The design idea is **share-nothing per worker, and suspension as data**. No scheduler moves a task between workers, and a computation that must wait is a value naming the operation it waits on. Load is balanced by moving data, never a task with state.

Terms: a **segment** is a `Segment` (a `komira_core` trait) whose `execute(state, worker_id, task_id)` does one unit of work, and a **task id** is an integer in `[0, n)`. A **shard** is one worker's share of one dispatch. A **morsel** is a chunk of input handed to one task. The **I/O lane** is an optional second set of workers that dispatch does not target.

Out of scope: object-store file systems, HTTP framing, and what a segment computes. Those live in the libraries that sit on top of this one. `Segment`, `KeepAlive`, `CancellationToken` and the CPU lists live in `komira_core` (`src/komira_core/runtime_traits/`, `src/komira_async_api/token.mojo`, `src/komira_host/cpu_topology.mojo`) so that lower libraries can name them without depending on the runtime.

## How does it work?

Every producer pushes a type-erased handle onto one worker's queue, then wakes that worker:

```
run_with_state / spawn / SpillPrefetcher ──push──► worker i's queue
             └──── WorkerWakeHandle.wake ────────► worker i's loop
```

### How is a runtime built and torn down?

`PerCoreAsyncRuntime[S]` (`src/komira_async/runtime/runtime.mojo`) is built in one call, or empty and then filled by `attach_workers`, optionally `attach_io_workers`, and `start()`. `start()` raises with no worker attached or on a second call; otherwise it launches one thread per worker (`launch_worker_pthread`). Each `Worker` sits behind an `OwnedPointer` in a `Slab`, so its address is fixed while its thread runs. `shutdown()`, and dropping a started runtime (`_runtime_teardown_join`, called from `__deinit__`), signal every worker and join every thread before any field is destroyed.

`attach_io_workers` appends the I/O lane, so `worker_count()`, the number of dispatch shards, does not change. Its producer is `SpillPrefetcher` (`src/komira_async/runtime/spill_prefetch.mojo`), which `LocalDispatcher.make_spill_prefetcher()` hands out holding clones of the I/O lane's senders; it primes the OS page cache with a file's bytes. With no I/O lane attached the prefetcher is empty and does nothing.

Worker placement is a value, `EnginePlacement` (`src/komira_host/engine_placement.mojo`), passed to the constructor or to `set_engine_placement` before `start()`. Every policy in it (`pin_workers`, `io_lane`, `numa_local`, `reserve_driver_cpu`) defaults to off, so by default the OS places and may migrate worker threads. `derive_io_placement` (`src/komira_host/cpu_topology.mojo`) picks the I/O lane's CPUs: hyperthread siblings if the machine has them, else the last of at least 17 compute CPUs, else a reserved driver CPU.

### How does a worker loop?

`Worker.run_until_shutdown` (`src/komira_async/runtime/worker.mojo`) repeats four steps until `signal_shutdown`.

1. **Spin.** Each turn drains up to 16 handles (`MAX_DRAIN_PER_ITER`) and runs them. A turn that found none polls the reactor with timeout 0 if the turn count is a multiple of 64, then runs `pause_intrinsic()`: the x86 `pause` instruction, a `sched_yield` system call elsewhere. Work found ends the window, and the next starts at turn 0.
2. **Idle.** After an empty window the worker fires the idle hook once, if `install_idle_hook` set one. The hook is how a higher layer drains per-core state, such as the log ring, while the worker has nothing else to do.
3. **Re-check.** It stores 1 in its sleeping flag, drains, polls with timeout 0, and drains again. Work found clears the flag and returns to step 1.
4. **Park.** It calls `poll_completions(-1)`. A kernel backend blocks until a wake, a ready descriptor or shutdown. The mock backend sleeps 10 µs and returns nothing. The worker clears the flag, routes completions and drains; a drain that hit the cap wakes the worker's own reactor so the next wait returns at once.

The spin limit starts at 8,192 turns. `_tier_for_spin` maps a moving average of time-to-work to 256 turns (under 1 µs), 2,048 (under 100 µs) or 8,192. Three consecutive empty windows drop it to 256 (`_on_empty_spin_window`). On shutdown the worker drains what is queued before its thread exits.

### How is a worker woken from another thread?

A producer calls the worker's `WorkerWakeHandle` (`src/komira_async/runtime/wake_primitives.mojo`). On a kernel backend each reactor owns a wake channel, an eventfd on Linux or an `EVFILT_USER` event on macOS. `wake()` always writes it. `wake_with_elision()` issues a full memory fence, reads the sleeping flag, and writes only if it is set; with the re-check in loop step 3, either the worker sees the new entry or the producer sees the flag. On the mock backend there is no channel, both calls do nothing, and the worker finds the entry after its park sleep.

Threads that wait outside a reactor (`JoinHandle.join()`, the dispatch barrier, the locks in `src/komira_async/sync/`) wait on a 32-bit word through `wait_on_address`: `futex` on Linux, `__ulock_wait` on macOS.

### How does fork-join dispatch work?

`LocalDispatcher.run_with_state(state, seg, n, cancel_token)` (`src/komira_async/runtime/local_dispatcher.mojo`) runs `seg.execute` for every task id in `[0, n)` and returns `seg` when all have finished.

1. It raises before posting anything on a nested dispatch, a negative `n`, no workers, or an already cancelled token. An `n` of zero returns `seg` at once.
2. It moves `seg` into a buffer it owns and builds a `_DispatchCtx` on the caller's stack that borrows the state, segment, counters, error slot and token.
3. It posts `min(n, worker_count())` shards, each an owning `ErasedHandle` (one heap allocation). The handle carries no origin, so the compiler does not tie a queued shard's borrow to the context; steps 5 and 6 do.
4. A shard claims task ids one at a time from a shared atomic cursor, which balances uneven tasks; with claiming switched off (`set_claim_enabled(False)`), it runs a fixed range. Before each id it stops if the error slot is set or the token is cancelled. The slot keeps the first error (`try_set`).
5. On every exit path the caller ends its context value (`_ = ctx^`) and waits in `_drain_in_flight_barrier` before its frame unwinds: 1 ms waits, a `[BARRIER-STALL]` report to stderr after about 10 s, no timeout.
6. It touches the state, segment, token and pool guard so none is destroyed early, moves the segment back, and raises the recorded error, if any.

Each shard carries its dispatch's generation and refuses to run once the dispatcher has moved on. Since the barrier and per-shard heap homes already prevent that, a refusal is a defect: after the barrier, `run_with_state` raises an error containing `Result is INCOMPLETE`. If a shard also recorded an error, that error is raised instead.

`_OnPoolDispatchGuard` raises a process-wide depth counter for the length of each dispatch. `fork_join_shared` (`src/komira_async_api/fork_join_shared.mojo`) reads it through `fork_join_pool_depth()`: while a dispatch is live, a wave runs its chunks inline on the calling thread instead of calling `run_with_state`. The counter is per process, not per dispatcher, so a wave on one runtime also runs inline while another runtime dispatches. `_on_pool_dispatch_active` (`src/komira_column_kernels/compiler_helpers.mojo`) reads the same counter.

Shapes built on it: `for_each_morsel` (one task per morsel, or a `MorselPool` when morsels outnumber workers), `parallel_fork_join`, `parallel_steal`, `parallel_multiphase` and `parallel_fork_join_shared`. The last forwards to `fork_join_shared` in `komira_core`.

### How do I spawn a task and get its result?

A task conforms to `SpawnableTask` (`src/komira_async/spawner/spawner.mojo`): `comptime T` and `run(mut self) raises -> Self.T`. `LocalSpawner.spawn(task)` pushes an owning `ErasedHandle` onto the next worker in round-robin order, wakes it, and returns a `JoinHandle[T]`. A full queue is retried with `cpu_pause()`, and `spawn` raises after 1,000,000 attempts. `spawn_with_token(task, tok^)` consumes the token and moves it into the task; the returned `JoinHandle` holds a clone that shares its flags, so `JoinHandle.cancel()` cancels the task's token. Pass `tok.clone()` to keep a token that shares those flags, or `tok.child()` for a token with its own flag that still sees `tok`'s cancellation.

A worker that finds the token already cancelled publishes a cancellation and never runs the body; otherwise it publishes the result or error. Then (`src/komira_async/spawner/join_handle.mojo`):

- `join()` spins 64 times, then waits in 1 ms slices. It returns the value, re-raises the task's error, or raises `CancelledError` once the token is cancelled while the result is pending. `join_with_token` discards its token.
- `cancel()` cancels the token and marks the slot cancelled even if the task had finished. A completion that lands later overwrites the mark.
- `detach()` returns the token without cancelling.
- Dropping the handle cancels the token. A task not yet started never runs; a running one finishes, because `run` receives no token.

### How does a handler wait for I/O without async/await?

A computation that waits is an explicit state machine. `SuspendableHandler.step` (`src/komira_async/runtime/suspendable_handler.mojo`) takes the reactor, resumes where the struct left off, and returns `HANDLER_PARKED` with the op id it now waits on, `HANDLER_DONE` with a response, or `HANDLER_ERR`. The reactor is passed in rather than stored, so a handler holds no borrow between steps and can be moved and type-erased. `SuspendableHandlerDriver` keeps parked handlers keyed by op id. The morsel-step form of the same pattern is `StepResult[T]` (`src/komira_async/runtime/step_result.mojo`): `MorselStepDriver` consumes it, and `prefetch_ring_park_step_result` returns the parked form for a `PrefetchRing`.

In `Reactor` (`src/komira_async/reactor/reactor.mojo`), `register_read(fd, op_id, consumer_id)` and `register_write(fd, op_id, consumer_id)` watch a descriptor under an op id the caller supplies, normally from `alloc_op_id()`, and return nothing. `register_timer(deadline_ns)` allocates and returns an op id. `poll_completions(timeout_us)` returns what finished. Each timer is its own kernel object: a `timerfd` on Linux, a one-shot `EVFILT_TIMER` on macOS.

### Which runtimes implement the `Runtime` trait?

`trait Runtime` (`src/komira_async/runtime/runtime_trait.mojo`) is the seam that protocol code is generic over: a method generic over `RT: Runtime` takes a `Reactor[RT.Sink]` and works with any conformer. A conformer names its waker-sink type `Sink`, reports `worker_count()`, and drives its reactors through `poll_completions`. It also declares two compile-time values for generic code to branch on: `RUNTIME_MODEL`, one of the `MODEL_*` constants in the same file, and `TASKS_ARE_THREAD_PINNED`. Four types conform:

| Runtime | `RUNTIME_MODEL` | For |
|---|---|---|
| `PerCoreAsyncRuntime` (`src/komira_async/runtime/runtime.mojo`) | `MODEL_SHARE_NOTHING_PER_CORE` | N worker threads, each with its own reactor and queue; the rest of this document |
| `BlockingRuntime` (`src/komira_async/runtime/blocking_runtime.mojo`) | `MODEL_CURRENT_THREAD_BLOCKING` | synchronous callers: `block_on(rt, work)` runs one reactor-driving function to completion |
| `GcpCloudRunRuntime` (`src/komira_async/runtime/gcp_cloud_run_runtime.mojo`) | `MODEL_CLOUD_RUN` | a server on Cloud Run that handles one request at a time per instance and scales by instances |
| `AwsLambdaRuntime` (`src/komira_async/runtime/aws_lambda_runtime.mojo`) | `MODEL_AWS_LAMBDA` | a server on AWS Lambda |

The last three each own one `Reactor` by value, drive it on the calling thread, start no thread, and return 1 from `worker_count()`. The two cloud runtimes are separate models because their platforms take the CPU away differently: Cloud Run throttles a running process between requests, and Lambda freezes the whole environment between invocations. `MODEL_WORK_STEALING` is reserved, and no type declares it.

### How does the runtime read files?

`FileSystem` (`src/komira_fs/file_system.mojo`) is a synchronous trait; `read_at(file, offset, length)` returns a `SharedAlignedBuffer[HeapRegion]`. `LocalFs` maps a file on its first read and returns buffers that borrow the mapping (`borrow_mmap_erased`), so a local read copies nothing. Overlap with compute comes from where the call runs: the I/O lane, or a `PrefetchRing` (`src/komira_async/sources/prefetch_source.mojo`).

### How do threads exchange data and cancel work?

- **Channels** (`src/komira_async/channel/`): `mpsc`, `spsc`, `oneshot`, `broadcast`. An `mpsc` ring's capacity must be a power of two; `unbounded()` is a 4,096-slot ring.
- **Locks** (`src/komira_async/sync/`) block the calling thread on a wake word.
- **Cancellation.** A `CancellationToken` is a chain of shared atomic flags. `child()` extends the chain, and `is_cancelled()` reads all of it, so a parent's cancellation reaches its descendants and not the reverse. It is cooperative: a shard checks before each task id, a spawned task once before it runs. `ExecutionBudget.check()` cancels its token and raises `CancelledError` when its work units run out.

## Why is it built this way?

### Why does every task stay on one worker?

**Decision.** Each worker owns its reactor, queue and parked operations, and no scheduler moves a task.

**Because.** A worker routes completions only from its own reactor (`Worker._dispatch_completion`), so parking needs no cross-worker protocol and a parked operation needs no lock. This matters for workers that park operations; a worker that runs each shard to completion never parks one, so for it the rule is free.

**Alternatives weighed.**

- Work stealing: a steal moves a task with state (frame, parked operations, registrations), so parking needs a cross-worker protocol. The runtime moves stateless work instead: claimed task ids, `parallel_steal`'s counter, `MorselPool`.

**Revisit if.** Long-lived tasks of very different cost skew load in a way data-level balancing cannot fix. `MODEL_WORK_STEALING` is reserved in the `Runtime` trait for such a runtime.

### Why do the dispatcher and the spawner share one queue per worker?

**Decision.** Each worker drains one bounded multi-producer queue of type-erased handles.

**Because.** A worker then waits on one queue and one wake channel, and producers on any thread push without a lock. `ErasedHandleBase` (`src/komira_async/runtime/shared_erasure.mojo`) is a hand-written vtable, a heap blob plus `run`, `step` and `drop` function pointers bound where the producer knows the concrete type, so the worker runs any entry blind.

**Alternatives weighed.**

- A queue per producer: the worker would poll and wake on several, and each new producer kind adds one.
- A queue per work kind: one queue per kind, or a worker generic over every kind.

The cost is an indirect call and a heap allocation per entry, which a shard pays once for all its task ids.

**Revisit if.** Producers contend on the ring's enqueue position at high core counts.

### Why spin before parking, and why adapt the spin?

**Decision.** An idle worker spins a bounded number of turns before it parks, and the bound follows how soon work has been arriving.

**Because.** Parking costs a wake write and a return from the kernel, which a worker parked between closely spaced dispatches pays on each. A worker that never sees work has no sample to adapt from, so three empty windows force the shortest limit.

**Alternatives weighed.**

- A fixed limit: too short for bursts, or wasteful when idle.
- A short-timeout poll instead of a full park: adds latency and wakes idle workers. The mock backend's park behaves this way.

**Revisit if.** Idle CPU matters more than dispatch latency. The knobs are the tier constants in `src/komira_async/runtime/worker.mojo`.

### Why are suspensions explicit state machines?

**Decision.** Anything that waits is a struct whose `step` returns parked, done or error; the runtime resumes no coroutines.

**Because.** A completion is seen by the worker that owns the reactor, so its waiter must resume on that worker. The library's own `parallel_fork_join_shared` notes that the stdlib's AsyncRT thread pool is a second pool this runtime cannot see, pin or govern, so the design keeps all resumption on the reactor's worker. A state machine also owns its working set and holds no borrow between steps.

**Alternatives weighed.**

- Coroutines left on AsyncRT's threads: a waiter would not resume on its reactor's worker, and the runtime could not pin or govern those threads.
- Raising to signal "parked": builds a heap string on every park.

**Revisit if.** Mojo lets an external executor choose the thread that resumes a coroutine.

### Why does dropping a `JoinHandle` cancel its task?

**Decision.** A handle dropped without `join()` or `detach()` cancels the task's token.

**Because.** A forgotten handle would otherwise leave running a task whose result was needed; `detach()` is the explicit opt-out.

**Alternatives weighed.**

- Detach on drop, as tokio does: a forgotten handle silently leaves the task running.

**Revisit if.** Most spawned tasks become fire-and-forget.

## What must always hold?

- **A worker outlives its thread.** Enforced by the join in `shutdown()`, and by `_runtime_teardown_join` in `PerCoreAsyncRuntime.__deinit__` when a started runtime is dropped without `shutdown()`. `test_worker_no_leak_after_runtime_drop` pins the `shutdown()` join: every case shuts down before the drop, so `__deinit__` skips its join there. The drop join is exercised by `test_raii_drop_stress_no_explicit_shutdown` (in `test_eventfd_wake`) and `test_raii_happy_path_dispatch_n4` (in `test_raii_ergonomics`).
- **`run_with_state` returns only after every shard has finished**, so the lent `state` is never touched afterwards. A queued shard carries no origin, so this is a runtime guarantee, not a type-system one. Enforced by the barrier and the touches after it ([steps 5 and 6](#how-does-fork-join-dispatch-work)); pinned by the `test_local_dispatcher_*` tests.
- **One dispatch at a time per dispatcher.** Enforced by a compare-and-swap at the start of `run_with_state`.
- **A worker thread must not block on its own runtime.** `run_with_state`, `JoinHandle.join()` and the locks block without draining the caller's queue, so a task or shard on worker k can wait forever on work queued behind it. Two guards cover dispatch only: the compare-and-swap at the start of `run_with_state` makes a nested dispatch on the same dispatcher raise, and `fork_join_shared` (and so `parallel_fork_join_shared`) runs a wave inline while the process-wide depth counter shows a live dispatch. Nothing guards `join()` or the locks.
- **An enqueue followed by a wake is never lost.** On a kernel backend, enforced by the re-check after the sleeping flag is set, paired with the fence in `wake_with_elision`; on the mock backend, by the bounded park. Pinned by `test_wake_elision_typed`, `test_eventfd_wake` and, on macOS, `test_kqueue_wake`.
- **A wake handle must not outlive its runtime.** It is copyable and holds the wake descriptor as a plain `Int32`, so a late `wake()` writes to a closed, possibly reused descriptor. Not enforced.
- **A task's error does not escape the worker.** The run functions catch it and publish it. If one escapes `run_until_shutdown`, the thread prints a warning and exits, its queue stays open, and a dispatch waiting on that worker hangs. Not tested.
- **A queue has one consumer.** `MpscReceiver` is movable, not copyable.
- **Public signatures carry no `UnsafePointer`, with a few exceptions** at the type-erasure and hook seams: the idle hook's `HookCtxPtr`, `ErasedHook` and `installable_hook_home` (`src/komira_async/runtime/installable_hook.mojo`); `single_consume_drop` and `make_borrowed_erased` (`src/komira_async/runtime/shared_erasure.mojo`); and `NestedBorrowBundle.new` and `__init__` (`src/komira_async/runtime/nested_borrow_bundle.mojo`).

## Where is the code?

The library is the `komira_async` target in `src/komira_async/BUCK`: every `.mojo` file under `src/komira_async/` except `src/komira_async/tests/`, plus the C shim `src/komira_async/reactor/_posix_shim.c`, built as the `:komira_async_posix` `cxx_library` that the library depends on. Its other four dependencies are `komira_core`, `komira_atomic_alias`, `komira_log` and `komira_runtime_paths` (tests take their scratch directory from it); the worker loop's idle hook is how a higher layer drains the per-core log ring. Start with these files:

| File | Holds |
|---|---|
| `src/komira_async/runtime/runtime.mojo` | `PerCoreAsyncRuntime`: lanes and lifecycle |
| `src/komira_async/runtime/worker.mojo` | `Worker.run_until_shutdown` and the spin policy |
| `src/komira_async/runtime/local_dispatcher.mojo` | `LocalDispatcher.run_with_state`, the barrier, the I/O lane |
| `src/komira_async/runtime/wake_primitives.mojo` | `WorkerWakeHandle`, `wait_on_address` |
| `src/komira_async/runtime/shared_erasure.mojo` | `ErasedHandleBase`, `make_erased` |
| `src/komira_async/runtime/runtime_trait.mojo` | `trait Runtime`, the `MODEL_*` constants |

Entry points:

- **Public API:** build a `PerCoreAsyncRuntime`, call `dispatcher().run_with_state(...)` or `spawner().spawn(task)`, and drop it to shut down. Code that needs only I/O drives a `Reactor` itself, directly or through a single-reactor runtime such as `BlockingRuntime`.
- **Execution starts at:** `Worker.run_until_shutdown`, which each thread runs once `PerCoreAsyncRuntime.start` launches it.

## How is it tested?

`komira_async` lists the files in `src/komira_async/tests/` in `test_srcs` in `src/komira_async/BUCK`, so building the library runs them all and it cannot build while any fails (see [the `test_srcs` gate](../../tools/build/mojo/README.md#libraries-and-the-test_srcs-gate)). Run: `./buck2 build //src/komira_async:komira_async`.

Beyond the tests named in the invariants: `test_fj_claim_dispatch` (claimed task ids), `test_reactor_park_no_lost_wakeup` (a reactor park does not miss descriptor readiness), `test_worker_adaptive_spin_tuning` (the spin tiers), `test_spill_prefetch_producer` (the I/O lane's producer) and `test_erased_handle_borrowed_probe` (borrowed erased handles).

Not tested:

- `test_kqueue_wake` compiles its bodies only for macOS.
- The reactor-poll cadence is tested only through `Worker._test_run_spin_iters`, a copy of the spin phase.
- Nothing measures a mock-backend runtime's idle CPU, or how long completions wait under a busy queue.
- In this library only `test_local_fs_write_at` and `test_select_first_notify` (on a two-worker `PerCoreAsyncRuntime`) call `parallel_fork_join_shared`.

## What are its limits and open questions?

- **Limit: a busy queue delays I/O.** A worker polls its reactor only on a spin turn that found its queue empty, or at re-check and park, so while tasks keep arriving its completions wait.
- **Limit: idle mock-backend workers never block.** Each alternates a spin window of at least 256 turns and the park sleep for its runtime's life; off x86 every spin turn is a system call.
- **Limit: no preemption.** The global `need_preempt()` returns `False` and `yield_if_needed()` does nothing; only `Worker.stall_detector()` flags a long iteration (over 20 ms). A long task holds its worker and its reactor.
- **Limit: locks block the thread**, stalling a worker's reactor for the whole wait.
- **Limit: fixed capacities.** A worker queue holds 1,024 entries (`TASK_QUEUE_CAPACITY`); no channel grows when full.
- **Limit: the waker sink has no behaviour.** `S` (a `WakerSink`) threads through `PerCoreAsyncRuntime`, `Reactor` and `Runtime`, but every `wake` raises, the reactor discards the error, and every caller passes `NoopSink`.
- **Limit: declared but inert.** `shutdown_token()` raises; the `placement` constructor argument is never read (worker CPU placement comes from `EnginePlacement`); `MAX_LOG_DRAIN_PER_IDLE` and `SPIN_LIMIT_FLOOR` have no effect; `ExecutionBudget` ignores its `deadline_ns`; the reactor raises `Unknown backend kind` for `BACKEND_IO_URING` and `BACKEND_DPDK`.
- **Limit: one kernel timer per deadline.** The loop does not drive `TimerWheel`, so on Linux every pending deadline holds a `timerfd`.
- **Open question: the backend for run-to-completion work.** A worker whose shards never park on its reactor uses the backend only to decide how an idle worker waits. `BACKEND_MOCK` costs idle CPU, and a shard posted to a parked worker waits out the rest of the park sleep ([loop step 4](#how-does-a-worker-loop)) plus the kernel's timer slack. A kernel backend costs a wake write per parked worker and makes the sleeping-flag handshake load-bearing for every dispatch. Deciding it takes measuring dispatch latency and idle CPU under both.
- **Open question: field destruction order.** The field comment in `src/komira_async/runtime/runtime.mojo` says Mojo drops fields in reverse declaration order, while the `__deinit__` docstring in the same file says declaration order. Threads are joined first, but no test pins the order.
- **Open question: stale headers.** The module list in the header of `src/komira_async/__init__.mojo` omits the `fs`, `net` and `observability` directories; this document follows the code.
