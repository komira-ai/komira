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

A spec with `set_stdin_pipe()` gives the child a stdin pipe: `write_stdin` writes every byte of a string (it returns the count or a negative errno), `close_stdin` ends the child's input (a write blocks while the pipe is full and the child is not reading), and `read_blocking(fd)` is one blocking read of a capture pipe (`eof` when every writer has closed it, `would_block` only if the descriptor was made non-blocking). All three pipes are created close-on-exec, so a child spawned later, on any thread, does not hold an end open. A write blocks while the pipe is full (about 64 KiB on Linux): a single thread that writes more than that to a child that answers on stdout deadlocks, the child blocked writing stdout and the parent blocked writing stdin, so drain stdout from another thread or write in small pieces. A write that fails with `-EPIPE` part-way does not report how many bytes went out. A write to a child that has closed its stdin or exited returns `-EPIPE` and never raises SIGPIPE in the calling process (the signal is blocked for the call and a SIGPIPE the call raised is consumed). `wait_readable(fd, timeout_ms)` waits until a read of a capture pipe would not block: 1 when data, end of file or an error is waiting, 0 when `timeout_ms` passes first (a negative value waits without limit), a negative errno on failure. If the parent has fd 0, 1 or 2 closed, the pipe ends `pipe()` hands out at those numbers are moved above 2 before the child's descriptors are wired, so the child still gets its stdin, stdout and stderr.

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

Write to the child's stdin and read its answers as they come:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_supervisor import ChildSpec, Supervisor

var spec = ChildSpec.shell("while IFS= read -r l; do echo \"echo $l\"; done")
spec.set_stdin_pipe()
var sup = Supervisor()
assert_true(sup.spawn(spec) > 0)
assert_true(sup.write_stdin("ping\n") > 0)
var chunk = sup.read_blocking(sup.stdout_fd())  # one blocking read
assert_equal(chunk.text, "echo ping\n")
sup.close_stdin()  # the child reads end of file and exits
assert_equal(sup.drain_pipe(sup.stdout_fd()), "")
_ = sup.drain_pipe(sup.stderr_fd())
assert_equal(sup.wait_exit().exit_code, 0)
sup.close()
```
