# komira_supervisor

Run one child process and watch it. `Supervisor.spawn` starts a `ChildSpec`
(an absolute path and arguments, optionally a closed environment, an
environment overlaid on this process's own, and a working directory) with
`posix_spawn`, capturing stdout and stderr on two separate pipes;
`drain_pipe` reads one to end of file, `wait_exit` reaps the child into an
`ExitInfo` (exit code, signal, and the shell's `128 + signal` code), and
`terminate(grace_ms)` sends SIGTERM, waits up to the grace period, then
sends SIGKILL. By default signals go to the child's pid, so a grandchild the
child spawned itself is not signalled (with a shell command, `exec` the last
command to make it the signalled process). A spec with
`set_own_process_group()` makes the child lead its own process group, and
`terminate` / `terminate_with(sig, grace_ms, reap_orphans)` then signal the
whole group and wait for it to empty; `set_default_signals()` starts the
child with every signal at its default action instead of inheriting this
process's ignored ones. A reaped child leaves no zombie, and a second
`terminate` returns the cached result. `watch_process_exit` makes a child's exit a
reactor event (`pidfd` on Linux, `EVFILT_PROC` on macOS) instead of a SIGCHLD
handler; `spawn_detached` starts a long-lived child that
inherits this process's stdin, stdout and stderr (no pipes); `proc_probe_children`
asks whether this process has any child, without reaping one.

For a process that runs as a container's PID 1 (or supervises a job tree):
`install_stop_signal_handler` catches SIGTERM and SIGINT into a latch that
`take_stop_signal` reads and clears (without a handler the kernel drops both
for a namespace's init); `adopt_orphans` makes the orphans of the tree come
to this process (PID 1 already receives them; on Linux it becomes a child
subreaper); `Supervisor.reap_orphans` collects the exited ones, leaving the
Supervisor's own child to `wait_exit`. Use it only in a process that owns
every child it has.

One child per `Supervisor`. It does not restart a child, does not time one out
by itself, and accepts resource limits (`RLimit`) without applying them yet.
`spawn` returns the pid, or a negative errno when nothing was started.

## Examples

Capture both streams separately and read the exit code:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_supervisor import ChildSpec, Supervisor

var sup = Supervisor()
var pid = sup.spawn(ChildSpec.shell("echo out-1; echo err-1 >&2; echo out-2; exit 3"))
assert_true(pid > 0)
var out = sup.drain_pipe(sup.stdout_fd())
var err = sup.drain_pipe(sup.stderr_fd())
var info = sup.wait_exit()
sup.close()
assert_equal(out, "out-1\nout-2\n")
assert_equal(err, "err-1\n")
assert_equal(info.exit_code, 3)
assert_equal(info.signal, -1)
```

Arguments and a closed environment (the child sees only what is passed):

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_supervisor import ChildSpec, Supervisor

var spec = ChildSpec("/bin/sh")
spec.with_arg("-c")
spec.with_arg('echo "$GREETING ${HOME:-no-home}"')
var env: List[String] = ["GREETING=hello"]
spec.set_env(env^)

var sup = Supervisor()
assert_true(sup.spawn(spec) > 0)
assert_equal(sup.drain_pipe(sup.stdout_fd()), "hello no-home\n")
_ = sup.drain_pipe(sup.stderr_fd())
assert_equal(sup.wait_exit().exit_code, 0)
sup.close()
```

Stop a long-running child:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_supervisor import ChildSpec, SIGTERM, Supervisor

var sup = Supervisor()
assert_true(sup.spawn(ChildSpec.shell("exec sleep 30")) > 0)
var info = sup.terminate(2000)  # SIGTERM; SIGKILL only if still alive after 2 s
assert_equal(info.signal, SIGTERM)
assert_equal(info.shell_code, 143)  # 128 + SIGTERM
assert_equal(sup.terminate(2000).shell_code, 143)  # cached, not signalled again
sup.close()
```

A path that does not exist starts nothing and says why:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_supervisor import ChildSpec, Supervisor

var sup = Supervisor()
var rc = sup.spawn(ChildSpec("/nonexistent/komira-readme-binary"))
assert_true(rc < 0)  # -errno
sup.close()
```
