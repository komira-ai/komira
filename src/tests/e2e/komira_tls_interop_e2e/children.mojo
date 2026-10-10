# =============================================================================
# komira_tls_interop_e2e/children.mojo -- the peer processes of one test,
# owned so that none outlives it.
# =============================================================================
#
# `PeerGroup` starts each peer (a `bssl` subcommand, or the CPython peer
# script, cpython.mojo) through
# `komira_supervisor.Supervisor`, which captures stdout and stderr on two
# pipes, read here without blocking, and keeps the peer until it is reaped:
#
#   * every wait is bounded: past its deadline the peer is stopped (SIGTERM,
#     500 ms, SIGKILL), reaped, and reported `timed_out`;
#   * a peer the test has not reaped when the group is destroyed (the test
#     raised, or returned early) is SIGKILLed and reaped by `__del__`;
#   * where `/usr/bin/setpriv` exists (Linux build workers), a peer is
#     started through `setpriv --pdeathsig KILL`, which then execs it, so a
#     peer also dies if the test process itself is killed.
#
# A peer's standard input is the test's (the test runner gives /dev/null),
# unless `start` is given a file: then the peer is started through the pinned
# busybox's `sh`, which opens the file as standard input and execs the peer
# (`bssl s_client` sends what it reads there).
#
# `pump` reads what is ready on every peer's pipes and reaps the peers that
# exited; the test calls it from its own loops (a TLS handshake, a read), so
# a peer's pipes never fill while the test waits on a socket. The loops here
# sleep 2 ms when nothing happened: a poll tick inside a deadline, never a
# wait standing in for an event. The test synchronises on what a peer prints
# (`wait_for_line`) and on its exit.
# =============================================================================

from std.os.path import exists
from std.time import perf_counter_ns, sleep

from komira_supervisor import ChildSpec, SIGKILL, Supervisor

comptime _SETPRIV = "/usr/bin/setpriv"
comptime _TERM_GRACE_MS = 500
comptime _TICK_S = 0.002


def deadline_after_ms(timeout_ms: Int) -> Int:
    """The `perf_counter_ns` value `timeout_ms` from now."""
    return Int(perf_counter_ns()) + timeout_ms * 1_000_000


def past(deadline: Int) -> Bool:
    """Whether `deadline` (from `deadline_after_ms`) has passed."""
    return Int(perf_counter_ns()) > deadline


def tick():
    """One poll tick: 2 ms."""
    sleep(_TICK_S)


struct PeerOutcome(Movable):
    """How a peer ended. `exit_code` is -1 when a signal ended it, and
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


struct _Peer(Movable):
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


struct PeerGroup(Movable):
    """The processes one test started; see the module header."""

    var _peers: List[_Peer]
    var _setpriv: Bool

    def __init__(out self):
        self._peers = List[_Peer]()
        self._setpriv = exists(_SETPRIV)

    def __del__(deinit self):
        for i in range(len(self._peers)):
            if not self._peers[i].reaped:
                _ = self._peers[i].sup.signal(SIGKILL)
                _ = self._peers[i].sup.wait_exit()
            self._peers[i].sup.close()

    def start(
        mut self,
        var label: String,
        program: String,
        args: List[String],
        stdin_file: String = "",
        busybox: String = "",
        env: List[String] = List[String](),
    ) raises -> Int:
        """Start `program args...`, its standard input `stdin_file` when that
        is not empty (read through `busybox sh`); returns the peer's handle.
        A non-empty `env` ("NAME=VALUE" entries) is the peer's whole
        environment; otherwise it inherits the test's."""
        var argv = List[String]()
        if stdin_file.byte_length() > 0:
            if busybox.byte_length() == 0:
                raise Error(label + ": a standard-input file needs the busybox path")
            argv.append(busybox)
            argv.append(String("sh"))
            argv.append(String("-c"))
            argv.append(String('f="$1"; shift; exec "$@" < "$f"'))
            argv.append(String("sh"))
            argv.append(stdin_file)
        argv.append(program)
        for a in args:
            argv.append(a)
        var spec: ChildSpec
        if self._setpriv:
            spec = ChildSpec(String(_SETPRIV))
            spec.with_arg("--pdeathsig")
            spec.with_arg("KILL")
            for a in argv:
                spec.with_arg(a)
        else:
            spec = ChildSpec(argv[0])
            for i in range(1, len(argv)):
                spec.with_arg(argv[i])
        if len(env) > 0:
            spec.set_env(env.copy())
        var sup = Supervisor()
        var pid = sup.spawn(spec)
        if pid <= Int32(0):
            raise Error(label + ": spawn of " + program + " failed (" + String(pid) + ")")
        _ = sup.set_nonblocking(sup.stdout_fd())
        _ = sup.set_nonblocking(sup.stderr_fd())
        self._peers.append(_Peer(label^, sup^))
        return len(self._peers) - 1

    def _pump_one(mut self, h: Int) -> Bool:
        """Read what is ready on peer `h`'s pipes and reap it if it has
        exited. True when anything happened."""
        ref c = self._peers[h]
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

    def pump(mut self) -> Bool:
        """`_pump_one` for every peer. True when anything happened."""
        var progressed = False
        for h in range(len(self._peers)):
            if self._pump_one(h):
                progressed = True
        return progressed

    def exited(self, h: Int) -> Bool:
        """Whether peer `h` has been reaped."""
        return self._peers[h].reaped

    def stdout(self, h: Int) -> String:
        """What peer `h` has printed on stdout so far."""
        return self._peers[h].out.copy()

    def stderr(self, h: Int) -> String:
        """What peer `h` has printed on stderr so far."""
        return self._peers[h].err.copy()

    def _done(self, h: Int) -> Bool:
        ref c = self._peers[h]
        return c.reaped and c.out_eof and c.err_eof

    def _stop(mut self, h: Int):
        ref c = self._peers[h]
        if not c.reaped:
            _ = c.sup.terminate(_TERM_GRACE_MS)
            c.reaped = True
            c.timed_out = True

    def wait(mut self, h: Int, timeout_ms: Int) -> PeerOutcome:
        """Wait for peer `h` to exit and its pipes to close; past the
        deadline stop it. Never raises for a failed peer: the caller reads
        the outcome."""
        var deadline = deadline_after_ms(timeout_ms)
        while not self._done(h):
            if past(deadline):
                if not self._peers[h].reaped:
                    self._stop(h)
                    deadline = deadline_after_ms(timeout_ms)
                    continue
                # Reaped but a pipe is still open: something the peer left
                # behind holds it. Stop reading rather than wait forever.
                self._peers[h].out_eof = True
                self._peers[h].err_eof = True
                self._peers[h].timed_out = True
                break
            if not self._pump_one(h):
                tick()
        ref c = self._peers[h]
        var info = c.sup.wait_exit()
        c.sup.close()
        return PeerOutcome(
            c.label.copy(), Int(info.exit_code), Int(info.signal), c.timed_out, c.out.copy(), c.err.copy()
        )

    def kill(mut self, h: Int, timeout_ms: Int) -> PeerOutcome:
        """SIGKILL peer `h` and wait for it."""
        if not self._peers[h].reaped:
            _ = self._peers[h].sup.signal(SIGKILL)
        return self.wait(h, timeout_ms)

    def wait_for_line(mut self, h: Int, prefix: String, timeout_ms: Int) raises:
        """Return once peer `h` has printed a line starting with `prefix`, on
        stdout or stderr. Raises, with what the peer printed, if it exits
        first or the deadline passes."""
        var deadline = deadline_after_ms(timeout_ms)
        while True:
            if _has_line(self._peers[h].out, prefix) or _has_line(self._peers[h].err, prefix):
                return
            if self._peers[h].reaped and self._peers[h].out_eof and self._peers[h].err_eof:
                var o = self.wait(h, timeout_ms)
                raise Error("exited before printing '" + prefix + "': " + o.describe())
            if past(deadline):
                self._stop(h)
                var o = self.wait(h, timeout_ms)
                raise Error("did not print '" + prefix + "' in " + String(timeout_ms) + " ms: " + o.describe())
            if not self._pump_one(h):
                tick()


def _has_line(text: String, prefix: String) -> Bool:
    for line in text.split("\n"):
        if line.startswith(prefix):
            return True
    return False
