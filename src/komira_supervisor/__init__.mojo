"""`komira_supervisor` — native process supervisor.

Spawns a child, captures stdout and stderr SEPARATELY, detects exit via the
reactor (no SIGCHLD handler), and kills cleanly (SIGTERM -> grace -> SIGKILL).
The package test (`tests/test_supervisor_scenarios.mojo`) exercises each of
these on Linux and macOS.

Public surface:
  * Supervisor — the safe wrapper: spawn / stdout_fd / stderr_fd / wait_exit /
    drain_pipe / terminate / signal / close.
  * ChildSpec / RLimit — the typed spawn input (defaults inherit env+cwd).
  * ExitInfo — decoded exit status (exit_code / signal / shell_code).
  * watch_process_exit / unwatch_process_exit — the reactor-integrated exit
    monitor (darwin EVFILT_PROC/NOTE_EXIT, Linux pidfd_open+epoll).
  * proc_probe_children / ChildProbe — "is there any child of this
    process?", asked without reaping one (waitid WNOWAIT).
  * SIGTERM / SIGKILL / SIGINT — the shared signal numbers.
  * install_stop_signal_handler / take_stop_signal / adopt_orphans — what a
    PID 1 needs: catch the platform's SIGTERM/SIGINT into a latch, and
    receive the orphans of the tree it spawned (Supervisor.reap_orphans
    collects them). ChildSpec.set_own_process_group makes terminate signal
    the child's whole process group.

Scope: ONE child per Supervisor, no restart, no timeout, inherited env/cwd
by default. rlimits are accepted but not applied yet. The reactor exit monitor
makes child exit a normal reactor event: NO SIGCHLD handler, no fork, no
zombies.

Substrate: komira_async.reactor (kqueue/epoll subsystems for the exit monitor)
+ the _proc_shim.c FFI shim (posix_spawn two-pipe, waitpid decode,
pidfd_open).
"""

from .supervisor import (
    Supervisor,
    ChildSpec,
    RLimit,
    ExitInfo,
    spawn_detached,
    DetachedChild,
    DetachedExit,
)
from .proc_ffi import (
    ChildProbe,
    ReapStatus,
    SIGTERM,
    SIGKILL,
    SIGINT,
    proc_probe_children,
)
from .pid1 import (
    install_stop_signal_handler,
    take_stop_signal,
    adopt_orphans,
)
from .exit_monitor import (
    ProcExitWatch,
    watch_process_exit,
    unwatch_process_exit,
)
