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
# THE CHILD'S ENVIRONMENT. `spec.env` is None by default: the child inherits
# this process's environment unchanged (the BUILD step's case). `set_env`
# gives the child EXACTLY the listed `NAME=value` entries and nothing else, so
# a child that must not see a credential held by this process (a CI job's
# identity-token request variables, say) is started with an allow-list. An
# explicit environment is never empty and always holds PATH: an empty envp is
# komira_supervisor's "inherit" arm, so an empty list would silently mean
# the opposite of what it says.
#
# Two implementations: `SupervisorRunner` (supervisor_runner.mojo) starts real
# processes; `ScriptedRunner` (scripted_runner.mojo) answers from a script and
# is what the welded tests use.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.time import perf_counter_ns

comptime STDERR_TAIL_BYTES: Int = 4096
"""How much of the end of stderr a `RunResult` keeps for a refusal message."""


def _is_env_name(name: String) -> Bool:
    """`[A-Za-z_][A-Za-z0-9_]*`."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var alpha = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
        if i == 0 and not alpha:
            return False
        if not (alpha or (c >= 48 and c <= 57)):
            return False
    return True


def env_entry_name(entry: String) -> String:
    """The name of a `NAME=value` entry ("" when it has no `=`)."""
    var at = entry.find(String("="))
    if at < 0:
        return String("")
    return String(entry[byte=0:at])


def check_child_env(entries: List[String]) raises:
    """Refuses an explicit child environment that is empty, holds an entry
    that is not `NAME=value`, names one variable twice, or has no PATH
    (file header)."""
    if len(entries) == 0:
        raise Error(String("an explicit child environment is empty: it would inherit this process's environment"))
    var names = List[String]()
    for i in range(len(entries)):
        var name = env_entry_name(entries[i])
        if not _is_env_name(name):
            raise Error(
                String("child environment entry '") + entries[i] + String("' is not NAME=value")
            )
        for j in range(len(names)):
            if names[j] == name:
                raise Error(String("the child environment sets '") + name + String("' twice"))
        names.append(name^)
    for j in range(len(names)):
        if names[j] == String("PATH"):
            return
    raise Error(String("an explicit child environment holds no PATH"))


struct RunSpec(Copyable, Movable):
    """One process to run. `argv` excludes argv[0], which is `path`. `env`
    is None (inherit) unless `set_env` gave an explicit environment.

    Layout: owned values only. No pointer field."""

    var path: String
    var argv: List[String]
    var cwd: String
    var timeout_s: Int
    var stdout_path: String
    var stderr_path: String
    var env: Optional[List[String]]

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
        self.env = None

    def set_env(mut self, var entries: List[String]) raises:
        """Start the child with exactly `entries` (`NAME=value`) and nothing
        inherited. Refused by `check_child_env`."""
        check_child_env(entries)
        self.env = entries^

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

    def now_ns(self) -> Int:
        """A MONOTONIC clock, in nanoseconds: what the per-change check's
        build budget is read against (affected_batch.mojo, THE BUDGET). Only
        differences between two readings mean anything. The default is
        `std.time.perf_counter_ns`, which on Linux reads
        `clock_gettime(CLOCK_MONOTONIC)` (the standard library's
        std/time/time.mojo: `perf_counter_ns` returns
        `_monotonic_nanoseconds()`, which reads `_CLOCK_MONOTONIC`, clock id
        1 on Linux), so a wall-clock step never moves it. ScriptedRunner
        overrides it with a clock its steps advance."""
        return Int(perf_counter_ns())
