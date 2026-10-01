# =============================================================================
# komira_async.spawner.spawner — Spawner trait + ForkJoinSpawner
# =============================================================================
#
# Persistent task queue. LOCAL-ONLY semantics: spawn enqueues tasks on
# the calling Worker's local task queue (no cross-worker migration, no
# work-stealing). Returns JoinHandle[T] bound to the current Worker.
#
# Scope:
#   * `SpawnableTask[T]` trait: user defines a struct with `run(mut self) -> T`.
#     Sidesteps Mojo 0.26.3's Callable trait limitations.
#   * `Spawner[T, Task]` trait: `spawn(var task: Task) -> JoinHandle[T]`.
#   * `ForkJoinSpawner[T, Task]`: synchronous fork-join spawner.
#     It runs tasks INLINE on the calling thread (no real fork);
#     LocalSpawner is the cross-pthread spawner with the same API
#     surface.
#   * `drain()` — count tracker here; full quiescence semantics live in
#     LocalSpawner.
#
# ZERO ArcPointer crossings; ZERO wildcard origins;
# ZERO UnsafePointer in public sigs.
# =============================================================================

from komira_async.cancellation.token import CancellationToken
from komira_async.spawner.join_handle import (
    JoinHandle,
    complete_slot,
    complete_slot_err,
    make_spawn_slot,
)


# =============================================================================
# SpawnableTask trait
# =============================================================================
# User-defined task: a struct with a `run(mut self) raises -> T` method.
# Captures live as struct fields (Mojo's "closure" form pre-Callable).
#
# Trait bound: Movable + Deinitable. NOT Copyable — tasks are
# one-shot consumed by run().


trait SpawnableTask(Movable, Deinitable):
    """Closure form (the user struct). This
    this trait as the canonical pre-Callable workaround.

    Mojo 0.26.3 traits cannot carry generic parameters ("trait declarations
    do not support parameters yet"). We use trait-level associated-type
    associated comptime types (`comptime T: ...`) — same shape as the engine's
    `MorselSink` trait in `komira_engine_operators`.

    User defines a struct with captures + a `run` method:
        @fieldwise_init
        struct MyTask(SpawnableTask, Movable, Deinitable):
            comptime T = Int
            var x: Int
            def run(mut self) raises -> Int:
                return self.x * 2

    Then `spawner.spawn[Int, MyTask](MyTask(x=21))` returns
    `JoinHandle[Int]` whose join() yields 42.
    """

    # Associated type — the result type of run(). Concrete impls declare
    # `alias T = ConcreteType` matching the spawner's [T] binding.
    comptime T: Copyable & ImplicitlyCopyable & Movable & Deinitable

    def run(mut self) raises -> Self.T:
        ...


# =============================================================================
# Spawner trait
# =============================================================================
# Mojo 0.26.3: trait declarations cannot carry generic parameters. Spawner
# is a parameterless marker; concrete impls expose the `spawn[T, Task]`
# generic method directly. Same workaround as SpawnableTask above.


trait Spawner(Deinitable):
    """Persistent task-queue: result-bearing
    spawn. LOCAL-ONLY: spawn enqueues on the calling Worker's
    local task queue.

    Concrete impls declare:
        def spawn[T: ..., Task: SpawnableTask & ...](mut self, var task: Task) -> JoinHandle[T]
        def spawn_with_token[...](mut self, var task: Task, var token) -> JoinHandle[T]
        def drain(mut self) -> Int

    This form ships ForkJoinSpawner with a non-trait struct shape
    (parametric over [T, Task]); the trait above is a marker that
    encapsulates the ForkJoinSpawner kind for future polymorphism.
    """

    pass  # Marker trait.


# =============================================================================
# ForkJoinSpawner — concrete impl
# =============================================================================
# synchronous trampoline. spawn() runs the task inline on the
# calling thread; complete the slot before constructing the JoinHandle, so
# join() returns immediately. This validates the API shape + lets dependent
# tests build against the real type.
#
# 4 swaps `_run_inline` for `_enqueue_to_worker` — the public
# signature stays identical.


@fieldwise_init
struct ForkJoinSpawner(Spawner, Movable, Deinitable):
    """closed-surface struct list +

    Minimum-viable impl: synchronous task execution. Phase
    1.9.4 swaps in real worker-pool dispatch.

    `_spawned`: counter incremented on every successful spawn; consumed by
    `drain()`. A simplification — a multi-worker spawner needs an Atomic
    for this counter.

    Generic methods: `spawn[T, Task]` / `spawn_with_token[T, Task]` carry
    the parametric task type at the method level (Mojo 0.26.3 traits don't
    support struct-level parametrization).
    """

    var _spawned: Int
    # Sentinel — there is no actual queue.
    var _placeholder: UInt8

    @staticmethod
    def new() -> ForkJoinSpawner:
        return ForkJoinSpawner(_spawned=0, _placeholder=UInt8(0))

    def spawn[
        Task: SpawnableTask & Movable & Deinitable,
    ](mut self, var task: Task) raises -> JoinHandle[Task.T]:
        """Inline spawn. The task runs SYNCHRONOUSLY on the
        calling thread BEFORE the JoinHandle is returned — so join()
        returns immediately.

        Implicit token: a fresh root token (a pool-backed spawner would
        derive it from the calling worker's current task token).

        The caller binds [Task] explicitly:
            spawner.spawn[MyTask](MyTask(x=42))
        Result type is `JoinHandle[MyTask.T]` (associated type from trait).
        """
        var token = CancellationToken.new()
        return self._spawn_impl[Task](task^, token^)

    def spawn_with_token[
        Task: SpawnableTask & Movable & Deinitable,
    ](mut self, var task: Task, var token: CancellationToken) raises -> JoinHandle[Task.T]:
        """Tier 2: explicit token. Token consumed; child observability is
        the caller's responsibility."""
        return self._spawn_impl[Task](task^, token^)

    def _spawn_impl[
        Task: SpawnableTask & Movable & Deinitable,
    ](mut self, var task: Task, var token: CancellationToken) raises -> JoinHandle[Task.T]:
        """3 inline trampoline. Task runs synchronously on calling
        thread; result + error published to slot before JoinHandle returns.

        Trait-level associated-type alias `Task.T` makes Mojo's elaborator
        bind the result type via the trait declaration (vs duck-typing)."""
        self._spawned += 1
        var slot = make_spawn_slot[Task.T]()
        # task is already `var`; bind to a local mutable then invoke run().
        # `task^.run()` rejects because `run(mut self)` needs an lvalue,
        # not the rvalue produced by `^`.
        try:
            var t = task^
            var value = t.run()
            complete_slot[Task.T](slot, value=value)
        except Error:
            complete_slot_err[Task.T](
                slot, err=String("ForkJoinSpawner: task raised (inline)"),
            )
        return JoinHandle[Task.T](slot=slot^, op_id=Int64(self._spawned), token=token^)

    def drain(mut self) -> Int:
        """3 simplified drain: returns the cumulative spawn count
        (NOT the not-yet-completed count, since 1.9.3 completes inline). Phase
        1.9.4 promotes to true quiescence semantics:
          1. Mark draining (no new spawns; spawn() raises).
          2. Wait for every previously-spawned task to either complete OR
             observe its cancellation token.
          3. Return the count observed to completion.
        """
        return self._spawned
