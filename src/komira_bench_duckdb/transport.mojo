# How the session talks to a DuckDB process: text to its stdin, text from its
# stdout, the error text it has written so far, and the end of the process.
# `ProcessTransport` is the real one, over komira_supervisor: it starts the
# binary with a stdin pipe and no shell. A test supplies another conformer.

from komira_supervisor import ChildSpec, Supervisor


struct StdoutChunk(Copyable, Movable):
    """What one read of the child's stdout gave: text, or end of file."""

    var text: String
    var eof: Bool

    def __init__(out self, var text: String, eof: Bool):
        self.text = text^
        self.eof = eof


trait DuckDbTransport(Movable, Deinitable):
    """The conversation with one DuckDB process."""

    def send(mut self, text: String) raises:
        """Write all of `text` to the process's stdin."""
        ...

    def read_stdout(mut self) raises -> StdoutChunk:
        """Wait for output and return what one read gives; `eof` once the
        process has closed its stdout."""
        ...

    def take_stderr(mut self) raises -> String:
        """The error text written since the last call (no waiting)."""
        ...

    def finish(mut self) raises -> Int:
        """Close its stdin, wait for it to exit and return its exit code."""
        ...


struct ProcessTransport(DuckDbTransport):
    """A DuckDB binary run under `komira_supervisor` with piped stdin, stdout
    and stderr."""

    var _sup: Supervisor
    var _done: Bool

    def __init__(out self, binary_path: String, args: List[String]) raises:
        """Start `binary_path` with `args`. Raises when it cannot be started."""
        var spec = ChildSpec(binary_path)
        for a in args:
            spec.with_arg(a)
        spec.set_stdin_pipe()
        spec.set_default_signals()
        self._sup = Supervisor()
        self._done = False
        var pid = self._sup.spawn(spec)
        if pid <= Int32(0):
            raise Error(String("cannot start ") + binary_path + String(": error ") + String(Int(pid)))
        _ = self._sup.set_nonblocking(self._sup.stderr_fd())

    def send(mut self, text: String) raises:
        var n = self._sup.write_stdin(text)
        if n < 0:
            raise Error(String("cannot write to duckdb: error ") + String(n))

    def read_stdout(mut self) raises -> StdoutChunk:
        var c = self._sup.read_blocking(self._sup.stdout_fd())
        if c.error:
            raise Error("cannot read the output of duckdb")
        return StdoutChunk(c.text.copy(), c.eof)

    def take_stderr(mut self) raises -> String:
        var acc = String("")
        while True:
            var c = self._sup.read_available(self._sup.stderr_fd())
            if c.error:
                raise Error("cannot read the error output of duckdb")
            if c.would_block or c.eof:
                return acc^
            acc += c.text

    def finish(mut self) raises -> Int:
        if self._done:
            return 0
        self._done = True
        self._sup.close_stdin()
        _ = self._sup.drain_pipe(self._sup.stdout_fd())
        _ = self._sup.drain_pipe(self._sup.stderr_fd())
        var info = self._sup.wait_exit()
        self._sup.close()
        return Int(info.exit_code)
