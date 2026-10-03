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
  * SIGTERM / SIGKILL — the shared signal numbers.

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
    ReapStatus,
    SIGTERM,
    SIGKILL,
)
from .exit_monitor import (
    ProcExitWatch,
    watch_process_exit,
    unwatch_process_exit,
)
