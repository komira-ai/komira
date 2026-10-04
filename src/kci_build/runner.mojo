# =============================================================================
# src/kci_build/runner.mojo -- the process-runner seam: how the BUILD step runs
#   buck2 without knowing how a process is started.
# =============================================================================
#
# `ProcessRunner.run` starts `spec.path` with `spec.argv` in `spec.cwd`, writes
# its stdout and stderr to the two named files, and returns how it ended. A
# run past `spec.timeout_s` is stopped and reported `timed_out`. A process that
# cannot be started at all RAISES: that is not an exit status.
#
# Two implementations: `SupervisorRunner` (supervisor_runner.mojo) starts real
# processes; `ScriptedRunner` (scripted_runner.mojo) answers from a script and
# is what the welded tests use.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

comptime STDERR_TAIL_BYTES: Int = 4096
"""How much of the end of stderr a `RunResult` keeps for a refusal message."""


struct RunSpec(Copyable, Movable):
    """One process to run. `argv` excludes argv[0], which is `path`.

    Layout: owned values only. No pointer field."""

    var path: String
    var argv: List[String]
    var cwd: String
    var timeout_s: Int
    var stdout_path: String
    var stderr_path: String

    def __init__(
        out self,
        var path: String,
        var argv: List[String],
        var cwd: String,
        timeout_s: Int,
        var stdout_path: String,
        var stderr_path: String,
    ):
        self.path = path^
        self.argv = argv^
        self.cwd = cwd^
        self.timeout_s = timeout_s
        self.stdout_path = stdout_path^
        self.stderr_path = stderr_path^

    def command_line(self) -> String:
        """`path argv...`, space-joined: for messages, never for a shell."""
        var s = self.path.copy()
        for i in range(len(self.argv)):
            s += String(" ") + self.argv[i]
        return s^


struct RunResult(Copyable, Movable):
    """How a run ended. `exit_code` is meaningful only when neither
    `signaled` nor `timed_out`; `stderr_tail` is at most
    `STDERR_TAIL_BYTES` from the end of stderr.

    Layout: owned values only. No pointer field."""

    var exit_code: Int32
    var signaled: Bool
    var timed_out: Bool
    var stderr_tail: String

    def __init__(
        out self,
        exit_code: Int32,
        signaled: Bool = False,
        timed_out: Bool = False,
        var stderr_tail: String = String(""),
    ):
        self.exit_code = exit_code
        self.signaled = signaled
        self.timed_out = timed_out
        self.stderr_tail = stderr_tail^

    def ok(self) -> Bool:
        return self.exit_code == Int32(0) and not self.signaled and not self.timed_out

    def describe(self) -> String:
        """`exit 1`, `killed by a signal` or `timed out`."""
        if self.timed_out:
            return String("timed out")
        if self.signaled:
            return String("killed by a signal")
        return String("exit ") + String(Int(self.exit_code))


def tail_text(text: String, max_bytes: Int) -> String:
    """The last `max_bytes` bytes of `text`, moved forward past any UTF-8
    continuation bytes so the result starts on a character boundary."""
    var b = text.as_bytes()
    var n = len(b)
    if n <= max_bytes:
        return text.copy()
    var start = n - max_bytes
    while start < n and (b[start] & UInt8(0xC0)) == UInt8(0x80):
        start += 1
    return String(text[byte = start:])


trait ProcessRunner(Movable):
    """Runs one process to completion (see the file header)."""

    def run(mut self, spec: RunSpec) raises -> RunResult:
        ...
