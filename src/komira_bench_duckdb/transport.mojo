# How the session talks to a DuckDB process: text to its stdin, text from its
# stdout (with a limit on the silence the caller is willing to wait through),
# the error text it has written so far, and the end of the process.
# `ProcessTransport` is the real one, over komira_supervisor: it starts the
# binary with a stdin pipe and no shell. A test supplies another conformer.

from komira_supervisor import ChildSpec, Supervisor

comptime _SLICE_MS: Int = 50
"""How long one wait on stdout lasts before stderr is drained and the wait
resumes. A wait ends the moment output arrives, so this adds no latency."""


struct StdoutChunk(Copyable, Movable):
    """What one read of the child's stdout gave: text, the end of file, or a
    report that nothing arrived within the wait the caller allowed."""

    var text: String
    var eof: Bool
    var timed_out: Bool

    def __init__(out self, var text: String, eof: Bool, timed_out: Bool = False):
        self.text = text^
        self.eof = eof
        self.timed_out = timed_out


trait DuckDbTransport(Movable, Deinitable):
    """The conversation with one DuckDB process."""

    def send(mut self, text: String) raises:
        """Write all of `text` to the process's stdin. Raises when the process
        can no longer be written to."""
        ...

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        """Wait for output and return what one read gives; `eof` once the
        process has closed its stdout. With `max_wait_ms` above zero, a wait
        of that many milliseconds without any output returns an empty chunk
        with `timed_out` set; zero waits without limit."""
        ...

    def take_stderr(mut self) raises -> String:
        """The error text written since the last call (no waiting)."""
        ...

    def kill(mut self) raises:
        """Stop the process now (SIGTERM, then SIGKILL) and release its
        pipes. A stopped process cannot be written to or read again."""
        ...

    def finish(mut self) raises -> Int:
        """Close its stdin, wait for it to exit and return its exit code."""
        ...


struct ProcessTransport(DuckDbTransport):
    """A DuckDB binary run under `komira_supervisor` with piped stdin, stdout
    and stderr. Its stderr is drained whenever stdout is waited on or read, so
    a long error message never blocks the process before it prints its end
    marker."""

    var _sup: Supervisor
    var _done: Bool
    var _exit: Int
    var _err: String

    def __init__(out self, binary_path: String, args: List[String]) raises:
        """Start `binary_path` with `args`. Raises when it cannot be started."""
        var spec = ChildSpec(binary_path)
        for a in args:
            spec.with_arg(a)
        spec.set_stdin_pipe()
        spec.set_default_signals()
        self._sup = Supervisor()
        self._done = False
        self._exit = 0
        self._err = String("")
        var pid = self._sup.spawn(spec)
        if pid <= Int32(0):
            raise Error(String("cannot start ") + binary_path + String(": error ") + String(Int(pid)))
        _ = self._sup.set_nonblocking(self._sup.stderr_fd())

    def _pull_stderr(mut self) raises:
        """Move whatever stderr holds right now into the buffer."""
        while True:
            var c = self._sup.read_available(self._sup.stderr_fd())
            if c.error:
                raise Error("cannot read the error output of duckdb")
            if c.would_block or c.eof:
                return
            self._err += c.text

    def send(mut self, text: String) raises:
        if self._done:
            raise Error("duckdb has been stopped")
        var n = self._sup.write_stdin(text)
        if n < 0:
            raise Error(String("cannot write to duckdb (it may have exited): error ") + String(n))

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        if self._done:
            raise Error("duckdb has been stopped")
        var waited = 0
        while True:
            var slice = _SLICE_MS
            if max_wait_ms > 0 and max_wait_ms - waited < slice:
                slice = max_wait_ms - waited
            var ready = self._sup.wait_readable(self._sup.stdout_fd(), slice)
            if ready < 0:
                raise Error(String("cannot wait for the output of duckdb: error ") + String(ready))
            self._pull_stderr()
            if ready == 1:
                break
            waited += slice
            if max_wait_ms > 0 and waited >= max_wait_ms:
                return StdoutChunk(String(""), False, True)
        var c = self._sup.read_blocking(self._sup.stdout_fd())
        if c.error:
            raise Error("cannot read the output of duckdb")
        self._pull_stderr()
        return StdoutChunk(c.text.copy(), c.eof)

    def take_stderr(mut self) raises -> String:
        if not self._done:
            self._pull_stderr()
        var out = self._err.copy()
        self._err = String("")
        return out^

    def kill(mut self) raises:
        if self._done:
            return
        self._done = True
        var info = self._sup.terminate(500)
        self._sup.close()
        self._exit = Int(info.exit_code)

    def finish(mut self) raises -> Int:
        if self._done:
            return self._exit
        self._done = True
        self._sup.close_stdin()
        _ = self._sup.drain_pipe(self._sup.stdout_fd())
        _ = self._sup.drain_pipe(self._sup.stderr_fd())
        var info = self._sup.wait_exit()
        self._sup.close()
        self._exit = Int(info.exit_code)
        return self._exit
