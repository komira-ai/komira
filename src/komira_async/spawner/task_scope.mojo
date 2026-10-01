# =============================================================================
# komira_async.spawner.task_scope — TaskScope + ComputeTaskScope
# =============================================================================
# Structured concurrency with a cancellation cascade.
#
# TaskScope is the structured-concurrency primitive (trio-nursery shape).
# Two variants:
#   * `ComputeTaskScope[T]` — scope over JoinHandle[T] children.
#   * `TaskScope[T, S, ro]` — scope over IoOp[T,S,ro] children;
#     parametric over caller origin.
#
# 10 scope:
#   * `ComputeTaskScope[T]` real impl: spawn captures the spawned slot's
#     ArcPointer + token; wait_all parks on each slot via Mechanism D;
#     collects results; cancellation cascades via the scope token.
#   * `TaskScope[T, S, ro]` real impl: stores IoOp values; wait_all calls
#     each child.wait().
#   * Drop without wait_all prints diagnostic + cancels children's tokens
#     (the ideal is a "panic"; Mojo 0.26.3's `def __del__(deinit self)` cannot
#     raise — print is the closest approximation; the cancel propagation
#     is the load-bearing safety guarantee).
#
# Storage shape:
#   ComputeTaskScope can't directly store `List[JoinHandle[T]]` because
#   List requires T: Copyable and JoinHandle is not Copyable. Instead we
#   store parallel lists:
#     _slots:  List[ArcPointer[_SpawnSlot[T]]]
#     _tokens: List[CancellationToken]      # NOT Copyable but Movable
#   Wait — List[CancellationToken] ALSO requires Copyable. We sidestep by
#   only storing slots (which are ArcPointer-backed; Arc clones are cheap)
#   and the SCOPE's own token (which propagates to children via spawn
#   wiring at the spawner level — caller passes scope.token().clone() into
#   spawn_with_token).
#
# Pointer discipline:
#   * No ArcPointer crossings in public method signatures.
#   * No UnsafePointer in public sigs.
#   * No wildcard origins.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer
from komira_atomic_alias import AtomicI32

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.io_op import IoOp
from komira_async.ops.waker_sink import WakerSink
from komira_async.spawner.join_handle import (
    JoinHandle,
    _SpawnSlot,
    _SLOT_PENDING,
    _SLOT_READY,
    _SLOT_ERR,
    _SLOT_CANCELLED,
)
from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_one_by_address,
)


comptime MAX_SCOPE_CHILDREN: Int = 64


# =============================================================================
# ComputeTaskScope[T] — JoinHandle children
# =============================================================================


@fieldwise_init
struct ComputeTaskScope[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Trio-nursery scope over JoinHandle
    children. Owns a CancellationToken that cancels-on-error
    (cascading to all in-flight children).

    10 storage shape:
      var _slots: List[ArcPointer[_SpawnSlot[T]]]
      var _token: CancellationToken
      var _waited: Bool

    Spawn flow:
      var scope = ComputeTaskScope[Int].new()
      var h = scope.spawn_into(spawner, MyTask(...))   # one of the helpers
      ...
      var results = scope.wait_all()                    # collects all

    10 simpler API: caller spawns externally + adds the resulting
    JoinHandle's slot+token to the scope via `add(handle^)`. wait_all()
    parks on each slot.
    """

    var _slots: List[ArcPointer[_SpawnSlot[Self.T]]]
    var _token: CancellationToken
    var _waited: Bool

    @staticmethod
    def new() -> ComputeTaskScope[Self.T]:
        """Tier 1: derive scope token as a fresh root.
        simplification — wires tier 1 to the worker-local current-
        task token."""
        return ComputeTaskScope[Self.T](
            _slots=List[ArcPointer[_SpawnSlot[Self.T]]](),
            _token=CancellationToken.new(),
            _waited=False,
        )

    @staticmethod
    def with_parent(var parent_token: CancellationToken) -> ComputeTaskScope[Self.T]:
        """Tier 2 escape: explicit parent token. Scope's token is a child
        of parent; cancellation cascades parent → scope → children."""
        return ComputeTaskScope[Self.T](
            _slots=List[ArcPointer[_SpawnSlot[Self.T]]](),
            _token=parent_token^.child(),
            _waited=False,
        )

    def token(self) -> CancellationToken:
        """Return a clone of the scope's token. Pass into Spawner's
        spawn_with_token to derive children that observe scope cancel."""
        return self._token.clone()

    def add(mut self, var handle: JoinHandle[Self.T]) raises:
        """Add a JoinHandle to the scope. The scope takes over the handle's
        join responsibility (wait_all consumes them all).

        Trick: we extract the slot's ArcPointer via a private accessor
        `_slot_arc` (same module — see helper below). The handle's __del__
        marks the task cancelled if the scope is dropped without wait_all
        (the scope's token cascades; the slot's wake-word transitions to
        _SLOT_CANCELLED).

        Detach the handle (so its __del__ doesn't fire cancel-on-drop) +
        add slot+token to the scope.
        """
        if len(self._slots) >= MAX_SCOPE_CHILDREN:
            raise Error("ComputeTaskScope.add: too many children (MAX_SCOPE_CHILDREN exceeded)")
        # Extract the slot's Arc handle BEFORE detach (which consumes the handle).
        var slot_arc = ArcPointer[_SpawnSlot[Self.T]](copy=handle._shared_slot)
        # Detach the handle (returns the token; we don't need it; the
        # scope already has its own token + the spawner-derived child
        # token is already on the slot's task). detach also marks
        # _joined=True so __del__ skips cancel-on-drop.
        var _detached_token = handle^.detach()
        _ = _detached_token^
        self._slots.append(slot_arc^)

    def wait_all(mut self) raises -> List[Self.T]:
        """Park on each child's wake-word until
        ready; collect results. If any child raises (errored OR cancelled),
        cancel the scope (cascading to remaining children) + propagate the
        first raised error.
        """
        if self._waited:
            raise Error("ComputeTaskScope.wait_all: scope already awaited")
        self._waited = True
        var results = List[Self.T]()
        var first_err = String("")
        for i in range(len(self._slots)):
            # Park on slot[i].wake_word until terminal state.
            while True:
                var state = self._slots[i][]._wake_word[].load()
                if state == _SLOT_READY:
                    if self._slots[i][]._result.__bool__():
                        results.append(self._slots[i][]._result.value())
                    break
                if state == _SLOT_ERR:
                    if first_err.byte_length() == 0:
                        first_err = self._slots[i][]._err
                        # Cancel scope to cascade to remaining children.
                        self._token.cancel(String("ComputeTaskScope: child errored"))
                    break
                if state == _SLOT_CANCELLED:
                    if first_err.byte_length() == 0:
                        first_err = String("CancelledError: child cancelled")
                        self._token.cancel(String("ComputeTaskScope: child cancelled"))
                    break
                if self._token.is_cancelled():
                    # Scope cancelled externally; propagate to this child
                    # via the slot's wake-word.
                    AtomicI32.store(
                        UnsafePointer(to=self._slots[i][]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](),
                        _SLOT_CANCELLED,
                    )
                    _ = wake_one_by_address(self._slots[i][]._wake_word[])
                    if first_err.byte_length() == 0:
                        first_err = String("CancelledError: scope cancelled")
                    break
                # Park.
                _ = wait_on_address(
                    self._slots[i][]._wake_word[],
                    expected=_SLOT_PENDING,
                    timeout_ns=Int64(1_000_000),  # 1ms cancel-poll period
                )
        if first_err.byte_length() > 0:
            raise Error(first_err)
        return results^

    def cancel(mut self):
        """Cancel the scope-local token; children
        observe via their cancellation-poll cycles + the wake-word cascade
        in wait_all."""
        self._token.cancel(String("ComputeTaskScope.cancel"))
        # Bump every child's wake-word so any active joiner returns.
        for i in range(len(self._slots)):
            AtomicI32.store(
                UnsafePointer(to=self._slots[i][]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](),
                _SLOT_CANCELLED,
            )
            _ = wake_one_by_address(self._slots[i][]._wake_word[])

    def __deinit__(deinit self):
        """Drop without wait_all is a
        structured-concurrency violation. The ideal is a "panic"; Mojo 0.26.3's
        `def __del__(deinit self)` cannot raise. Best approximation:
        print loud diagnostic + cancel children (so the violation surfaces
        when a child task observes its cancellation token).
        """
        if not self._waited and len(self._slots) > 0:
            print(
                "ERROR ComputeTaskScope dropped without wait_all() — "
                "structured-concurrency violation. Cancelling "
                + String(len(self._slots))
                + " in-flight children."
            )
            self._token.cancel(String("ComputeTaskScope dropped without wait_all"))
            for i in range(len(self._slots)):
                AtomicI32.store(
                    UnsafePointer(to=self._slots[i][]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](),
                    _SLOT_CANCELLED,
                )
                _ = wake_one_by_address(self._slots[i][]._wake_word[])


# =============================================================================
# TaskScope[T, S, ro] — IoOp children
# =============================================================================
# Parametric over caller origin `ro: Origin[mut=False]` so
# child IoOps that borrow scope-local data can be parked safely.


@fieldwise_init
struct TaskScope[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
    S: WakerSink & Movable & Deinitable,
    ro: Origin[mut=False],
](Movable, Deinitable):
    """Trio-nursery scope over IoOp
    children. On scope drop, prints loud diagnostic if children unjoined.

    10 simple impl: stores IoOp values directly (IoOp is Movable
    + Copyable). wait_all() calls .wait() on each.

    Parametric origin: child tasks can hold `ref [ro]` access
    to scope-local data; the lifetime tracker rejects escape attempts at
    the type level.
    """

    var _children: List[IoOp[Self.T, Self.S, Self.ro]]
    var _token: CancellationToken
    var _waited: Bool

    @staticmethod
    def new() -> TaskScope[Self.T, Self.S, Self.ro]:
        return TaskScope[Self.T, Self.S, Self.ro](
            _children=List[IoOp[Self.T, Self.S, Self.ro]](),
            _token=CancellationToken.new(),
            _waited=False,
        )

    @staticmethod
    def with_parent(var parent_token: CancellationToken) -> TaskScope[Self.T, Self.S, Self.ro]:
        return TaskScope[Self.T, Self.S, Self.ro](
            _children=List[IoOp[Self.T, Self.S, Self.ro]](),
            _token=parent_token^.child(),
            _waited=False,
        )

    def token(self) -> CancellationToken:
        return self._token.clone()

    def spawn(mut self, var op: IoOp[Self.T, Self.S, Self.ro]) raises:
        """Append op to children list."""
        if len(self._children) >= MAX_SCOPE_CHILDREN:
            raise Error("TaskScope.spawn: too many children (MAX_SCOPE_CHILDREN exceeded)")
        self._children.append(op^)

    def wait_all(mut self) raises -> List[Self.T]:
        """Wait on each child IoOp; collect
        results."""
        if self._waited:
            raise Error("TaskScope.wait_all: scope already awaited")
        self._waited = True
        var results = List[Self.T]()
        for i in range(len(self._children)):
            # IoOp.wait() consumes the op; we hold them in the list as
            # Movable values + extract via index/move.
            var op_copy = self._children[i].copy()
            results.append(op_copy^.wait())
        return results^

    def cancel(mut self):
        """Cancels the scope-local token."""
        self._token.cancel(String("TaskScope.cancel"))

    def __deinit__(deinit self):
        if not self._waited and len(self._children) > 0:
            print(
                "ERROR TaskScope dropped without wait_all() — "
                "structured-concurrency violation. "
                + String(len(self._children))
                + " in-flight children."
            )
            self._token.cancel(String("TaskScope dropped without wait_all"))
