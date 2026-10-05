# =============================================================================
# komira_localmodel/supervisor_registry.mojo
#   SupervisorRegistry: N supervised engine children addressed by id, and
#   find_free_port: a bind(0) helper that finds a free loopback port for each.
# =============================================================================
#
# WHY: komira_supervisor's `Supervisor` manages ONE child (one pid, one pipe
# pair). A server that runs several engines at once (an MLX server here, a
# llama.cpp server there, several models loaded together) needs to (a) address
# each child by a stable id and (b) start each on a DISTINCT port.
#
# WHAT IS HERE:
#   * SupervisorRegistry: id -> Supervisor. spawn(id, spec) -> pid,
#     terminate(id, grace) -> ExitInfo, poll(id) -> is the child still alive,
#     count(), contains(id), ids(). The registry OWNS the Supervisors (Movable,
#     single owner; no shared ownership).
#   * find_free_port(): bind a loopback socket to port 0 (the kernel picks an
#     ephemeral port), read the port back, then RELEASE the socket (the
#     listener drops and its fd closes) so an engine can bind it. Uses
#     komira_async's TcpListener.bind_loopback(0); no new FFI.
#
# THE bind(0) RELEASE-THEN-HAND-OFF RACE (known and accepted): the returned
# port is free at the instant of the call; between the listener drop and the
# engine's bind another process could take it. This is the usual "ephemeral
# port hint" pattern: the kernel does not hand out the same ephemeral port
# twice in quick succession, so the window is small. Bind the engine promptly
# after the call; a collision then surfaces as a launch readiness failure, never
# as a request routed to the wrong process. Passing a bound fd to the child
# (SO_REUSEADDR + fd inheritance) would close the window if it ever matters.
#
# POINTERS: the registry stores a `Slab[Supervisor]` (Supervisor is
# Movable-only, and `List[T]` requires `T: Copyable`; `Slab` is the
# Movable-only owned collection) plus parallel `List[String]` ids and
# `List[Bool]` spawned flags. No pointer in any signature; find_free_port does
# its socket handling through TcpListener.
# =============================================================================

from komira_async.runtime.tcp_stream import TcpListener

from komira_core.collections.slab import Slab

from komira_supervisor.supervisor import (
    Supervisor,
    ChildSpec,
    ExitInfo,
)


# -----------------------------------------------------------------------------
# Child lookup-state codes (returned by poll / terminate when an id is absent).
# -----------------------------------------------------------------------------
comptime CHILD_NOT_FOUND: Int = 0  # no child with that id in the registry
comptime CHILD_SPAWNED: Int = 1    # child spawned and (last we checked) alive
comptime CHILD_GONE: Int = 2       # child was spawned but has since exited


# -----------------------------------------------------------------------------
# ChildState — the result of a poll(id): a small POD describing one child.
# -----------------------------------------------------------------------------
struct ChildState(Copyable, ImplicitlyCopyable, Movable):
    """One child's state from a registry poll.

    Fields:
      * state  — CHILD_NOT_FOUND / CHILD_SPAWNED (alive) / CHILD_GONE (exited).
      * pid    — the child pid (-1 when NOT_FOUND).
      * alive  — convenience: state == CHILD_SPAWNED.
    """

    var state: Int
    var pid: Int32
    var alive: Bool

    def __init__(out self, state: Int, pid: Int32):
        self.state = state
        self.pid = pid
        self.alive = state == CHILD_SPAWNED


# -----------------------------------------------------------------------------
# ChildHandle — the spawn result: the id + pid (or a negative pid on failure).
# -----------------------------------------------------------------------------
struct ChildHandle(Copyable, Movable):
    """The result of a registry spawn.

    `pid > 0` on success; `pid <= 0` is the spawn failure (-errno from the
    posix_spawn FFI, or 0 for "id already present — not spawned").
    """

    var id: String
    var pid: Int32

    def __init__(out self, id: String, pid: Int32):
        self.id = id
        self.pid = pid

    def ok(self) -> Bool:
        return self.pid > Int32(0)


# -----------------------------------------------------------------------------
# find_free_port — bind(0) ephemeral-port allocator (rides TcpListener).
# -----------------------------------------------------------------------------
def find_free_port() raises -> UInt16:
    """Return a currently-free loopback TCP port (kernel-assigned ephemeral).

    Binds a loopback socket to port 0 (the kernel picks an unused ephemeral
    port), reads back the assigned port, then RELEASES the socket (the listener
    drops at end-of-scope -> the fd closes) so the caller can hand the port to
    a spawned engine. See the module header for the accepted TOCTOU note.

    Raises if the bind / getsockname FFI fails (a genuine socket error — the
    caller should surface it, not silently pick port 0).
    """
    # backlog is irrelevant (we never accept) — use a small value.
    var listener = TcpListener.bind_loopback(UInt16(0), Int32(16))
    var port = listener.local_port()
    # `listener` drops here -> the fd closes -> the port is free for the engine.
    return port


# -----------------------------------------------------------------------------
# SupervisorRegistry — manage N engine children keyed by id.
# -----------------------------------------------------------------------------
struct SupervisorRegistry(Movable):
    """A registry of N supervised children, each addressed by a stable id.

    Single-owner storage (no shared ownership): a `Slab[Supervisor]` (the
    canonical Movable-only owned collection — Supervisor is not Copyable, so a
    plain List is rejected) with parallel `List[String]` ids and `List[Bool]`
    spawned-flags. An id is unique within the registry; spawn() on a duplicate
    id is a no-op that returns pid 0 (the caller must terminate + remove the old
    child first, or use a distinct id).

    Lifecycle per child: spawn(id, spec) -> poll(id) (alive?) -> terminate(id,
    grace) (SIGTERM -> grace -> SIGKILL, reap). terminate_all() on
    shutdown stops every child (no orphans).
    """

    var _ids: List[String]
    var _children: Slab[Supervisor]
    # Whether the slot's Supervisor has been spawned (vs a default-constructed
    # placeholder). A child that has been terminate()'d stays in the slab with
    # spawned=False until removed (so ids() reflects the registry shape; the
    # owner can re-key or compact).
    var _spawned: List[Bool]

    def __init__(out self):
        self._ids = List[String]()
        self._children = Slab[Supervisor]()
        self._spawned = List[Bool]()

    # --- lookup --------------------------------------------------------------

    def _index_of(self, id: String) -> Int:
        """Return the slot index for `id`, or -1 if absent. PRIVATE."""
        for i in range(len(self._ids)):
            if self._ids[i] == id:
                return i
        return -1

    def contains(self, id: String) -> Bool:
        return self._index_of(id) >= 0

    def count(self) -> Int:
        """Number of registered slots (spawned or terminated-but-not-removed)."""
        return len(self._ids)

    def live_count(self) -> Int:
        """Number of children currently flagged spawned (alive at last poll)."""
        var n = 0
        for i in range(len(self._spawned)):
            if self._spawned[i]:
                n += 1
        return n

    def ids(self) -> List[String]:
        """A copy of the registered ids (registry shape introspection)."""
        var out = List[String]()
        for i in range(len(self._ids)):
            out.append(self._ids[i])
        return out^

    def pid_of(self, id: String) -> Int32:
        """The pid for `id` (-1 if absent)."""
        var idx = self._index_of(id)
        if idx < 0:
            return Int32(-1)
        return self._children[idx].pid()

    # --- lifecycle -----------------------------------------------------------

    def spawn(mut self, id: String, var spec: ChildSpec) -> ChildHandle:
        """Spawn a supervised child under `id`. Returns a ChildHandle whose pid
        is > 0 on success, -errno on a spawn failure, or 0 if `id` is already
        present (no-op — the caller must use a distinct id or terminate the old
        child first).

        The registry takes ownership of the child's Supervisor.
        """
        if self._index_of(id) >= 0:
            return ChildHandle(id, Int32(0))  # duplicate id -> no spawn.
        var sup = Supervisor()
        var pid = sup.spawn(spec^)
        if pid <= Int32(0):
            # Spawn failed — do NOT register the dead slot (nothing to manage).
            return ChildHandle(id, pid)
        self._ids.append(id)
        self._children.append(sup^)
        self._spawned.append(True)
        return ChildHandle(id, pid)

    def poll(mut self, id: String) -> ChildState:
        """Poll `id`: is the child still alive? Does a non-blocking WNOHANG reap
        (so an exited child is reaped + the slot flips to CHILD_GONE, no zombie).

        Returns CHILD_NOT_FOUND if `id` is absent; CHILD_GONE if the child has
        exited (now or previously); CHILD_SPAWNED if it is still running.
        """
        var idx = self._index_of(id)
        if idx < 0:
            return ChildState(CHILD_NOT_FOUND, Int32(-1))
        if not self._spawned[idx]:
            return ChildState(CHILD_GONE, self._children[idx].pid())
        var pid = self._children[idx].pid()
        var r = self._children[idx].try_wait()
        if r.collected:
            # Child exited — flip the slot to GONE (reaped by try_wait).
            self._spawned[idx] = False
            return ChildState(CHILD_GONE, pid)
        return ChildState(CHILD_SPAWNED, pid)

    def terminate(mut self, id: String, grace_ms: Int) -> ExitInfo:
        """Stop `id`'s child (SIGTERM -> grace -> SIGKILL, reap exactly-once) +
        close its pipes. Flips the slot to spawned=False (kept in the registry
        until remove()). Returns the decoded ExitInfo; a sentinel ExitInfo
        (all -1) when `id` is absent or already terminated.
        """
        var idx = self._index_of(id)
        if idx < 0 or not self._spawned[idx]:
            return ExitInfo(Int32(-1), Int32(-1), Int32(-1))
        var info = self._children[idx].terminate(grace_ms)
        self._children[idx].close()
        self._spawned[idx] = False
        return info

    def terminate_all(mut self, grace_ms: Int):
        """Stop every still-spawned child (shutdown — no orphans). Each
        child is SIGTERM -> grace -> SIGKILL + reaped + closed."""
        for i in range(len(self._spawned)):
            if self._spawned[i]:
                _ = self._children[i].terminate(grace_ms)
                self._children[i].close()
                self._spawned[i] = False
