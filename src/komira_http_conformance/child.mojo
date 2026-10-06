# =============================================================================
# child.mojo -- run one child process to completion, bounded by a deadline
# =============================================================================
#
# komira_supervisor spawns the child with two capture pipes. Both are read
# without blocking, in turns, so neither pipe can fill and wedge the child
# (Supervisor.drain_both does the same, but has no deadline). When the
# deadline passes first, the child gets SIGTERM, then SIGKILL after a grace
# period, and the result says it timed out. The deadline bounds the whole run:
# after both pipes reach EOF the exit is polled (a WNOHANG reap), so a child
# that closes its output and keeps running is stopped the same way.
#
# A turn with nothing to read waits 10 ms on an empty komira_async reactor
# (an epoll_wait with a timeout). Not std's time.sleep: komira_async declares
# its own `nanosleep`, and a second declaration with another signature fails
# to legalize in any program that links both.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_clock import now_ns
from komira_supervisor import ChildSpec, ExitInfo, Supervisor


@fieldwise_init
struct ChildOutcome(Movable):
    var exit: ExitInfo
    var stdout: String
    var stderr: String
    var timed_out: Bool

    def describe(self) -> String:
        var how: String
        if self.timed_out:
            how = String("timed out and was stopped")
        elif self.exit.signal >= Int32(0):
            how = "died of signal " + String(Int(self.exit.signal))
        else:
            how = "exited " + String(Int(self.exit.exit_code))
        return how^


comptime _TERM_GRACE_MS = 2_000
comptime _IDLE_WAIT_US: Int32 = 10_000


def run_child(spec: ChildSpec, deadline_s: Int) raises -> ChildOutcome:
    """Run the child `spec` names until it exits and both its pipes reach EOF,
    or until `deadline_s` seconds have passed. Raises only when it cannot be
    started."""
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        raise Error("cannot start " + spec.path + ": errno " + String(Int(-pid)))
    var out_fd = sup.stdout_fd()
    var err_fd = sup.stderr_fd()
    # A blocking pipe would park the drain in read() past the deadline.
    var nb_out = sup.set_nonblocking(out_fd)
    var nb_err = sup.set_nonblocking(err_fd)
    if nb_out < Int32(0) or nb_err < Int32(0):
        _ = sup.terminate(_TERM_GRACE_MS)
        sup.close()
        raise Error(
            "cannot make " + spec.path + "'s output pipes non-blocking: "
            + String(Int(nb_out)) + ", " + String(Int(nb_err))
        )
    var out = String("")
    var err = String("")
    var out_done = False
    var err_done = False
    var give_up = now_ns() + UInt64(deadline_s) * 1_000_000_000
    var timed_out = False
    var idle = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    while not out_done or not err_done:
        if now_ns() >= give_up:
            timed_out = True
            break
        var progressed = False
        if not out_done:
            var c = sup.read_available(out_fd)
            if c.text.byte_length() > 0:
                out += c.text
                progressed = True
            elif c.eof or c.error:
                out_done = True
        if not err_done:
            var c = sup.read_available(err_fd)
            if c.text.byte_length() > 0:
                err += c.text
                progressed = True
            elif c.eof or c.error:
                err_done = True
        if not progressed:
            _ = idle.poll_completions(0, _IDLE_WAIT_US)
    # Both pipes are closed; the child may still be running.
    while not timed_out:
        var r = sup.try_wait()
        if r.collected or r.error:
            break
        if now_ns() >= give_up:
            timed_out = True
            break
        _ = idle.poll_completions(0, _IDLE_WAIT_US)
    var info: ExitInfo
    if timed_out:
        info = sup.terminate(_TERM_GRACE_MS)
    else:
        info = sup.wait_exit()
    sup.close()
    return ChildOutcome(exit=info, stdout=out^, stderr=err^, timed_out=timed_out)
