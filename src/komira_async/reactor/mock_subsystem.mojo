# =============================================================================
# komira_async.reactor.mock_subsystem — MockSubsystem (testonly fixture)
# =============================================================================
# The mock backend: always available, no platform-specific FFI. Used by the
# mock-runtime testing surface.
#
# Implemented as an in-memory deterministic readiness queue.
# Tests pre-call `inject_ready(op_id)`; the next poll_ready_drain() drains
# the queue and reports the ready op_ids. No real fds, no syscalls.
#
# This sidesteps Reactor[S]'s actual `_epoll_fd = -1` no-op codepath when
# tests need a deterministic-readiness-injection point. Reactor with
# BACKEND_MOCK still works (run_once returns 0); MockSubsystem here is a
# parallel test-only construct that the test harness uses directly.
# =============================================================================


struct MockSubsystem(Movable, Deinitable):
    """Always-available mock IoSubsystem.

    Deterministic readiness: tests pre-call `inject_ready(op_id)`; the
    next `poll_ready_drain()` returns the queued op_ids in insertion
    order. No real fds, no syscalls, no platform-specific FFI.

    Test-only by convention: non-test source must not import it (a single
    package cannot carry a test-only marker per module).
    """

    var _ready_queue: List[Int64]
    var _registered: List[Int64]
    var _next_op_id: Int64

    def __init__(out self):
        self._ready_queue = List[Int64]()
        self._registered = List[Int64]()
        self._next_op_id = Int64(0)

    def alloc_op_id(mut self) -> Int64:
        """Monotone op-id allocator. Mirrors Reactor.alloc_op_id."""
        self._next_op_id += Int64(1)
        return self._next_op_id

    def register_read(mut self, fd: Int32, op_id: Int64, consumer_id: UInt16):
        """Register a read op. Mock ignores fd; just records op_id."""
        self._registered.append(op_id)

    def register_write(mut self, fd: Int32, op_id: Int64, consumer_id: UInt16):
        """Register a write op. Mock ignores fd; just records op_id."""
        self._registered.append(op_id)

    def deregister(mut self, op_id: Int64):
        """Remove the op from registered + ready queues. Best-effort."""
        var i = 0
        while i < len(self._registered):
            if self._registered[i] == op_id:
                _ = self._registered.pop(i)
            else:
                i += 1
        var j = 0
        while j < len(self._ready_queue):
            if self._ready_queue[j] == op_id:
                _ = self._ready_queue.pop(j)
            else:
                j += 1

    def inject_ready(mut self, op_id: Int64):
        """TEST-ONLY: schedule `op_id` to be reported ready on the next
        `poll_ready_drain()` call. The op_id is appended to the ready
        queue in insertion order; `poll_ready_drain()` pops in that
        order (deterministic).

        No-op if `op_id` is not currently registered — tests can verify
        deregister-after-injection works correctly.
        """
        # Only inject if registered (mirrors real reactor: epoll won't
        # report readiness for unregistered fds).
        for i in range(len(self._registered)):
            if self._registered[i] == op_id:
                self._ready_queue.append(op_id)
                return

    def poll_ready_drain(mut self) -> List[Int64]:
        """Return the queued ready op_ids in insertion order, clearing
        the queue. Tests use this in lieu of run_once() for deterministic
        behavior. `consumer_id` plumbing is omitted; a later version
        may add a `(op_id, consumer_id)` tuple variant if cross-worker
        SPSC dispatch tests need it.
        """
        var out = List[Int64]()
        for i in range(len(self._ready_queue)):
            out.append(self._ready_queue[i])
        self._ready_queue.clear()
        return out^

    def registered_count(self) -> Int:
        """Test introspection: how many ops are currently registered."""
        return len(self._registered)

    def ready_count(self) -> Int:
        """Test introspection: how many ops are queued ready."""
        return len(self._ready_queue)
