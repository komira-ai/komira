# =============================================================================
# komira_shuffle_e2e/children.mojo -- the task processes of one test, owned so
# that none outlives it.
# =============================================================================
#
# `TaskGroup` starts each task through `komira_supervisor.Supervisor` (stdout
# and stderr captured on two pipes, read without blocking) and keeps it until
# it is reaped:
#
#   * every wait is bounded: past its deadline the task is stopped (SIGTERM,
#     500 ms, SIGKILL), reaped, and reported `timed_out`;
#   * a task the test has not reaped when the group is destroyed (the test
#     raised, or returned early) is SIGKILLed and reaped by `__del__`;
#   * where `/usr/bin/setpriv` exists (the farm's Linux workers), a task is
#     started through `setpriv --pdeathsig KILL`, which then execs it, so a
#     task also dies if the test process itself is killed.
#
# The loops sleep 2 ms when no pipe had data and the task had not exited: a
# poll tick inside a deadline, never a wait standing in for an event. The test
# synchronises on what a task prints (`wait_for_line`) and on its exit.
# =============================================================================

from std.os.path import exists
from std.time import perf_counter_ns, sleep

from komira_supervisor import ChildSpec, SIGKILL, Supervisor

comptime _SETPRIV = "/usr/bin/setpriv"
comptime _TERM_GRACE_MS = 500


struct TaskOutcome(Movable):
    """How a task ended. `exit_code` is -1 when a signal ended it, and
    `signal` is -1 when it exited."""

    var label: String
    var exit_code: Int
    var signal: Int
    var timed_out: Bool
    var out: String
    var err: String

    def __init__(
        out self, var label: String, exit_code: Int, signal: Int, timed_out: Bool, var out: String, var err: String
    ):
        self.label = label^
        self.exit_code = exit_code
        self.signal = signal
        self.timed_out = timed_out
        self.out = out^
        self.err = err^

    def ok(self) -> Bool:
        return self.exit_code == 0 and not self.timed_out

    def describe(self) -> String:
        var how = String("exit ") + String(self.exit_code)
        if self.signal >= 0:
            how = String("signal ") + String(self.signal)
        if self.timed_out:
            how += " (stopped at its deadline)"
        return (
            self.label + ": " + how + "\n--- stdout ---\n" + self.out + "--- stderr ---\n" + self.err + "--------------"
        )

    def lines_with(self, prefix: String) -> List[String]:
        """The stdout lines that start with `prefix`, in order."""
        var out = List[String]()
        for line in self.out.split("\n"):
            if line.startswith(prefix):
                out.append(String(line))
        return out^

    def field(self, prefix: String, name: String) raises -> String:
        """The `name=` value on the one stdout line starting with `prefix`."""
        var lines = self.lines_with(prefix)
        if len(lines) != 1:
            raise Error(
                self.label + ": expected one '" + prefix + "' line, found " + String(len(lines)) + "\n"
                + self.describe()
            )
        return line_field(lines[0], name)


def line_field(line: String, name: String) raises -> String:
    """The value of `name=value` among the space-separated words of `line`."""
    var want = name + "="
    for w in line.split(" "):
        if w.startswith(want):
            return String(w[byte = want.byte_length() :])
    raise Error("no " + name + "= in line: " + line)


struct _Child(Movable):
    var label: String
    var sup: Supervisor
    var out: String
    var err: String
    var out_eof: Bool
    var err_eof: Bool
    var reaped: Bool
    var timed_out: Bool

    def __init__(out self, var label: String, var sup: Supervisor):
        self.label = label^
        self.sup = sup^
        self.out = String("")
        self.err = String("")
        self.out_eof = False
        self.err_eof = False
        self.reaped = False
        self.timed_out = False


def _deadline(timeout_ms: Int) -> Int:
    return Int(perf_counter_ns()) + timeout_ms * 1_000_000


struct TaskGroup(Movable):
    """The processes one test started; see the module header."""

    var _children: List[_Child]
    var _setpriv: Bool

    def __init__(out self):
        self._children = List[_Child]()
        self._setpriv = exists(_SETPRIV)

    def __del__(deinit self):
        for i in range(len(self._children)):
            if not self._children[i].reaped:
                _ = self._children[i].sup.signal(SIGKILL)
                _ = self._children[i].sup.wait_exit()
            self._children[i].sup.close()

    def start(mut self, var label: String, program: String, args: List[String]) raises -> Int:
        """Start `program args...`; returns the task's handle."""
        var spec: ChildSpec
        if self._setpriv:
            spec = ChildSpec(String(_SETPRIV))
            spec.with_arg("--pdeathsig")
            spec.with_arg("KILL")
            spec.with_arg(program)
        else:
            spec = ChildSpec(program)
        for a in args:
            spec.with_arg(a)
        var sup = Supervisor()
        var pid = sup.spawn(spec)
        if pid <= Int32(0):
            raise Error(label + ": spawn of " + program + " failed (" + String(pid) + ")")
        _ = sup.set_nonblocking(sup.stdout_fd())
        _ = sup.set_nonblocking(sup.stderr_fd())
        self._children.append(_Child(label^, sup^))
        return len(self._children) - 1

    def _pump(mut self, h: Int) -> Bool:
        """Read what is ready on both pipes and reap the task if it has
        exited. True when anything happened."""
        ref c = self._children[h]
        var progressed = False
        if not c.out_eof:
            var r = c.sup.read_available(c.sup.stdout_fd())
            if r.text.byte_length() > 0:
                c.out += r.text
                progressed = True
            elif r.eof or r.error:
                c.out_eof = True
                progressed = True
        if not c.err_eof:
            var r = c.sup.read_available(c.sup.stderr_fd())
            if r.text.byte_length() > 0:
                c.err += r.text
                progressed = True
            elif r.eof or r.error:
                c.err_eof = True
                progressed = True
        if not c.reaped:
            var s = c.sup.try_wait()
            if s.collected or s.error:
                c.reaped = True
                progressed = True
        return progressed

    def _done(self, h: Int) -> Bool:
        ref c = self._children[h]
        return c.reaped and c.out_eof and c.err_eof

    def _stop(mut self, h: Int):
        ref c = self._children[h]
        if not c.reaped:
            _ = c.sup.terminate(_TERM_GRACE_MS)
            c.reaped = True
            c.timed_out = True

    def wait(mut self, h: Int, timeout_ms: Int) -> TaskOutcome:
        """Wait for task `h` to exit and its pipes to close; past the deadline
        stop it. Never raises for a failed task: the caller reads the outcome."""
        var deadline = _deadline(timeout_ms)
        while not self._done(h):
            if Int(perf_counter_ns()) > deadline:
                if not self._children[h].reaped:
                    self._stop(h)
                    deadline = _deadline(timeout_ms)
                    continue
                # Reaped but a pipe is still open: something the task left
                # behind holds it. Stop reading rather than wait forever.
                self._children[h].out_eof = True
                self._children[h].err_eof = True
                self._children[h].timed_out = True
                break
            if not self._pump(h):
                sleep(0.002)
        ref c = self._children[h]
        var info = c.sup.wait_exit()
        c.sup.close()
        return TaskOutcome(
            c.label.copy(), Int(info.exit_code), Int(info.signal), c.timed_out, c.out.copy(), c.err.copy()
        )

    def wait_for_line(mut self, h: Int, prefix: String, timeout_ms: Int) raises:
        """Return once task `h` has printed a stdout line starting with
        `prefix`. Raises, with what the task printed, if it exits first or
        the deadline passes."""
        var deadline = _deadline(timeout_ms)
        while True:
            for line in self._children[h].out.split("\n"):
                if line.startswith(prefix):
                    return
            if self._children[h].reaped and self._children[h].out_eof:
                var o = self.wait(h, timeout_ms)
                raise Error("exited before printing '" + prefix + "': " + o.describe())
            if Int(perf_counter_ns()) > deadline:
                self._stop(h)
                var o = self.wait(h, timeout_ms)
                raise Error("did not print '" + prefix + "' in " + String(timeout_ms) + " ms: " + o.describe())
            if not self._pump(h):
                sleep(0.002)

    def kill(mut self, h: Int, timeout_ms: Int) -> TaskOutcome:
        """SIGKILL task `h` and wait for it."""
        if not self._children[h].reaped:
            _ = self._children[h].sup.signal(SIGKILL)
        return self.wait(h, timeout_ms)
