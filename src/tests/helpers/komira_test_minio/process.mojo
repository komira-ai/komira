# =============================================================================
# komira_test_minio/process.mojo -- the process seam `start_embedded_minio`
# starts its server through, a scripted fake, and `NoProcess`, the runner
# type of a test bucket on an external store (it starts no process).
# =============================================================================
#
# A real runner (over a process supervisor) implements `ProcessRunner`
# elsewhere. What it must do, so a killed test leaves no server behind:
#   * `die_with_parent`: the child dies when the test process dies. On Linux
#     that is `PR_SET_PDEATHSIG`; macOS has none, so a small watcher waits on
#     the parent with kqueue `EVFILT_PROC`/`NOTE_EXIT` and kills the child.
#   * `child_env` is the child's WHOLE environment, not an addition to ours.
#   * `stop` sends SIGTERM, waits up to `grace_s`, then SIGKILL, and returns
#     the exit status. It raises when it cannot confirm the child is gone.
# =============================================================================


struct EnvEntry(Copyable, Movable):
    """One `NAME=value` of a child's environment."""

    var name: String
    var value: String

    def __init__(out self, var name: String, var value: String):
        self.name = name^
        self.value = value^


struct ProcessSpec(Copyable, Movable):
    """What to start: `argv[0]` is the executable's path."""

    var argv: List[String]
    var child_env: List[EnvEntry]
    var cwd: String
    var die_with_parent: Bool

    def __init__(
        out self,
        var argv: List[String],
        var child_env: List[EnvEntry],
        var cwd: String,
        die_with_parent: Bool,
    ):
        self.argv = argv^
        self.child_env = child_env^
        self.cwd = cwd^
        self.die_with_parent = die_with_parent


comptime READINESS_READY: Int = 0
comptime READINESS_EXITED: Int = 1
comptime READINESS_TIMEOUT: Int = 2


struct Readiness(Copyable, Movable):
    """The outcome of waiting for a child's port: READY, EXITED (with the
    child's exit code) or TIMEOUT."""

    var kind: Int
    var exit_code: Int

    def __init__(out self, kind: Int, exit_code: Int = 0):
        self.kind = kind
        self.exit_code = exit_code

    @staticmethod
    def ready() -> Readiness:
        return Readiness(READINESS_READY)

    @staticmethod
    def exited(code: Int) -> Readiness:
        return Readiness(READINESS_EXITED, code)

    @staticmethod
    def timeout() -> Readiness:
        return Readiness(READINESS_TIMEOUT)


trait ProcessRunner(Movable, Deinitable):
    """Starts, watches and stops child processes. See the module header."""

    def start(mut self, spec: ProcessSpec) raises -> Int:
        """Start `spec`; return an opaque handle."""
        ...

    def wait_port(mut self, h: Int, host: String, port: Int, timeout_s: Int) -> Readiness:
        """Wait until `host:port` accepts a connection, the child exits, or
        `timeout_s` passes."""
        ...

    def stop(mut self, h: Int, grace_s: Int) raises -> Int:
        """Stop the child and return its exit status. Raise when it cannot be
        confirmed gone."""
        ...


struct NoProcess(ProcessRunner):
    """The runner type of a test bucket on an external S3-compatible store:
    it starts nothing, and any call is a bug in the caller."""

    def __init__(out self):
        pass

    def start(mut self, spec: ProcessSpec) raises -> Int:
        raise Error("NoProcess: an external store starts no process")

    def wait_port(mut self, h: Int, host: String, port: Int, timeout_s: Int) -> Readiness:
        return Readiness.timeout()

    def stop(mut self, h: Int, grace_s: Int) raises -> Int:
        raise Error("NoProcess: an external store has no process to stop")


struct ScriptedProcessRunner(ProcessRunner):
    """A test runner: records every spec it is asked to start and replays a
    script of outcomes.

    `readiness[i]` is what `wait_port` reports for the i-th start (TIMEOUT
    once the script runs out). `stop` returns `stop_status`, or raises when
    `stop_raises` is set. Handles are 1, 2, 3, ... in start order.
    """

    var specs: List[ProcessSpec]
    var readiness: List[Readiness]
    var waits: List[Int]
    var stops: List[Int]
    var stop_graces: List[Int]
    var stop_status: Int
    var stop_raises: Bool

    def __init__(out self, var readiness: List[Readiness]):
        self.specs = List[ProcessSpec]()
        self.readiness = readiness^
        self.waits = List[Int]()
        self.stops = List[Int]()
        self.stop_graces = List[Int]()
        self.stop_status = 0
        self.stop_raises = False

    def start(mut self, spec: ProcessSpec) raises -> Int:
        self.specs.append(spec.copy())
        return len(self.specs)

    def wait_port(mut self, h: Int, host: String, port: Int, timeout_s: Int) -> Readiness:
        self.waits.append(port)
        var i = h - 1
        if i >= 0 and i < len(self.readiness):
            return self.readiness[i].copy()
        return Readiness.timeout()

    def stop(mut self, h: Int, grace_s: Int) raises -> Int:
        self.stops.append(h)
        self.stop_graces.append(grace_s)
        if self.stop_raises:
            raise Error("stop: liveness unknown (injected)")
        return self.stop_status
