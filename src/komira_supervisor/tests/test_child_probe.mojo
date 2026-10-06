# =============================================================================
# test_child_probe.mojo -- proc_probe_children: "does this process have any
# child?", asked without reaping one.
# =============================================================================
#
# A file of its own so its process starts with no child: the "no child" case
# depends on that, and on every test here reaping what it spawns.
#
#   test_no_child_reports_no_child
#       nothing spawned -> any_child False (waitid failed with ECHILD).
#   test_a_running_child_exists_and_is_not_exited
#       a live `sleep 30` -> any_child True, exited_pid 0, and it is still
#       alive after the probe.
#   test_an_exited_child_is_reported_and_left_reapable
#       a child that exited with 7, observed through pidfd (Linux) or
#       EVFILT_PROC (macOS), neither of which reaps -> any_child True,
#       exited_pid == its pid; then waitpid(pid, WNOHANG) still collects
#       exit code 7, and a second probe says no child. Goes red when the shim
#       drops WNOWAIT (the probe would reap it and the waitpid would fail
#       with ECHILD).
#
# Not tested: a waitid failure other than ECHILD, which proc_probe_children
# raises. With its fixed arguments (valid idtype and options, a stack
# siginfo_t) waitid can fail only with ECHILD or EINTR (retried in the shim),
# so no honest test reaches the raise.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import TestSuite

from komira_supervisor.supervisor import ChildSpec, Supervisor
from komira_supervisor.proc_ffi import (
    proc_close,
    proc_kill,
    proc_kqueue_exit_wait,
    proc_pidfd_open,
    proc_pidfd_wait,
    proc_probe_children,
)


def _spawned(pid: Int32) raises:
    if pid <= Int32(0):
        raise Error(String("spawn returned ") + String(pid))


def _await_exit_without_reaping(pid: Int32) -> String:
    """Wait up to 5 s for `pid` to exit, through a kernel notification that
    does not reap it. Returns "" on success, else what went wrong."""
    comptime if CompilationTarget.is_macos():
        var fired = proc_kqueue_exit_wait(pid, Int32(5000))
        if fired != Int32(1):
            return String("kqueue exit wait returned ") + String(fired)
        return String("")
    else:
        var fd = proc_pidfd_open(pid)
        if fd < Int32(0):
            return String("pidfd_open returned ") + String(fd)
        var fired = proc_pidfd_wait(fd, Int32(5000))
        proc_close(fd)
        if fired != Int32(1):
            return String("pidfd wait returned ") + String(fired)
        return String("")


def test_no_child_reports_no_child() raises:
    var p = proc_probe_children()
    if p.any_child:
        raise Error(
            String("no child spawned, yet the probe saw one (exited_pid ")
            + String(p.exited_pid)
            + String(")")
        )


def test_a_running_child_exists_and_is_not_exited() raises:
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exec sleep 30")))
    _spawned(pid)
    var p = proc_probe_children()
    var alive_after = proc_kill(pid, Int32(0)) == Int32(0)
    _ = sup.terminate(1000)
    sup.close()
    if not (p.any_child and p.exited_pid == Int32(0) and alive_after):
        raise Error(
            String("running child ")
            + String(pid)
            + String(": any_child ")
            + String(p.any_child)
            + String(", exited_pid ")
            + String(p.exited_pid)
            + String(", alive after the probe ")
            + String(alive_after)
        )


def test_an_exited_child_is_reported_and_left_reapable() raises:
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exit 7")))
    _spawned(pid)
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var waited = _await_exit_without_reaping(pid)
    if waited.byte_length() > 0:
        _ = sup.wait_exit()
        sup.close()
        raise Error(waited)
    var p = proc_probe_children()
    # waitpid(pid, WNOHANG): collects only if the probe left the zombie.
    var r = sup.try_wait()
    var after = proc_probe_children()
    if not r.collected:
        # Do not leave a child behind for the next test if it is still there.
        _ = sup.terminate(1000)
    sup.close()
    if not (p.any_child and p.exited_pid == pid):
        raise Error(
            String("exited child ")
            + String(pid)
            + String(": any_child ")
            + String(p.any_child)
            + String(", exited_pid ")
            + String(p.exited_pid)
        )
    if not (r.collected and r.exited and r.exit_code == Int32(7)):
        raise Error(
            String("the probe reaped the exited child ")
            + String(pid)
            + String(": waitpid afterwards collected ")
            + String(r.collected)
            + String(", error ")
            + String(r.error)
            + String(", exit_code ")
            + String(r.exit_code)
        )
    if after.any_child:
        raise Error(
            String("after reaping the only child the probe still saw one")
            + String(" (exited_pid ")
            + String(after.exited_pid)
            + String(")")
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
