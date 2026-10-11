# =============================================================================
# src/kci_build/supervisor_runner.mojo -- `ProcessRunner` over
#   komira_supervisor: the one place the BUILD step starts a real process.
# =============================================================================
#
# The child inherits this process's environment unchanged unless the spec
# gives an explicit one (`RunSpec.set_env`); then it gets exactly that list
# and nothing else. kci adds no variable of its own either way. An explicit
# environment that is empty is refused before anything starts: komira_
# supervisor reads an empty envp as "inherit". Its stdout and stderr are drained concurrently
# into the two files named by the spec, so neither pipe can fill and stall
# it. Past `timeout_s` it is stopped (SIGTERM, then SIGKILL after
# `grace_ms`) and the result says `timed_out`. Its clock (`now_ns`) is the
# ProcessRunner default, CLOCK_MONOTONIC.
#
# After the child exits, the pipes are read until both reach EOF, or until
# nothing has arrived for `_LINGER_TICKS` ticks: a grandchild that inherited a
# pipe (a build daemon, say) must not keep the BUILD step waiting forever.
#
# Pauses use `usleep`, not `std.time.sleep`: the latter declares `nanosleep`
# with a signature that clashes with komira_async's at link time.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns

from komira_supervisor import ChildSpec, Supervisor

from kci_build.runner import (
    STDERR_TAIL_BYTES,
    ProcessRunner,
    RunResult,
    RunSpec,
    check_child_env,
    tail_text,
)

comptime _TICK_MS: Int = 2
comptime _LINGER_TICKS: Int = 250
"""After the child exits: give up on its pipes after this many idle ticks."""


def _pause_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


struct _Sink(Movable):
    """One drained stream: its file and whether its pipe reached EOF."""

    var file: FileHandle
    var done: Bool

    def __init__(out self, path: String, fd: Int32) raises:
        try:
            self.file = open(path, "w")
        except e:
            raise Error(String("cannot open '") + path + String("' for writing: ") + String(e))
        self.done = fd < Int32(0)


struct SupervisorRunner(ProcessRunner):
    """Runs real processes through komira_supervisor."""

    var grace_ms: Int

    def __init__(out self, grace_ms: Int = 10000):
        self.grace_ms = grace_ms

    def run(mut self, spec: RunSpec) raises -> RunResult:
        var child = ChildSpec(spec.path)
        for i in range(len(spec.argv)):
            child.with_arg(spec.argv[i])
        if spec.cwd.byte_length() > 0:
            child.set_cwd(spec.cwd)
        if spec.env:
            # `env` is a public field: re-check, an empty list would inherit
            check_child_env(spec.env.value())
            child.set_env(spec.env.value().copy())
        var out = _Sink(spec.stdout_path, Int32(0))
        var err = _Sink(spec.stderr_path, Int32(0))
        var sup = Supervisor()
        var pid = sup.spawn(child)
        if pid < Int32(0):
            out.file.close()
            err.file.close()
            raise Error(
                String("cannot start '")
                + spec.path
                + String("': errno ")
                + String(Int(-pid))
            )
        var out_fd = sup.stdout_fd()
        var err_fd = sup.stderr_fd()
        out.done = out_fd < Int32(0)
        err.done = err_fd < Int32(0)
        _ = sup.set_nonblocking(out_fd)
        _ = sup.set_nonblocking(err_fd)
        var tail = String("")
        var deadline = Int(perf_counter_ns()) + spec.timeout_s * 1_000_000_000
        var exited = False
        var timed_out = False
        var idle_after_exit = 0
        while True:
            var progressed = False
            if not out.done:
                var c = sup.read_available(out_fd)
                if c.text.byte_length() > 0:
                    out.file.write_bytes(c.text.as_bytes())
                    progressed = True
                elif c.eof or c.error:
                    out.done = True
            if not err.done:
                var c = sup.read_available(err_fd)
                if c.text.byte_length() > 0:
                    err.file.write_bytes(c.text.as_bytes())
                    tail += c.text
                    if tail.byte_length() > 2 * STDERR_TAIL_BYTES:
                        tail = tail_text(tail, STDERR_TAIL_BYTES)
                    progressed = True
                elif c.eof or c.error:
                    err.done = True
            if not exited:
                var r = sup.try_wait()
                if r.collected:
                    exited = True
                elif Int(perf_counter_ns()) > deadline:
                    _ = sup.terminate(self.grace_ms)
                    exited = True
                    timed_out = True
            if exited:
                if out.done and err.done:
                    break
                if progressed:
                    idle_after_exit = 0
                else:
                    idle_after_exit += 1
                    if idle_after_exit >= _LINGER_TICKS:
                        break
            if not progressed:
                _pause_ms(_TICK_MS)
        var info = sup.wait_exit()
        sup.close()
        out.file.close()
        err.file.close()
        return RunResult(
            info.exit_code,
            signaled=info.signal != Int32(-1),
            timed_out=timed_out,
            stderr_tail=tail_text(tail, STDERR_TAIL_BYTES),
        )
