# =============================================================================
# komira_supervisor.pid1: what a process needs to run as a container's PID 1
# (or as the supervising parent of a job tree): catch the platform's stop
# signal, and receive and collect the orphans of the tree it spawned.
# =============================================================================
#
#   install_stop_signal_handler()  catch SIGTERM and SIGINT into a latch; the
#                                  kernel drops these for a namespace's init
#                                  unless a handler is installed.
#   take_stop_signal() -> Int32    the first one caught since the last take
#                                  (cleared by the read), or 0.
#   adopt_orphans() -> Bool        PID 1 already receives orphans; otherwise,
#                                  on Linux, become a child subreaper.
#   Supervisor.reap_orphans()      (supervisor.mojo) collects them.
#
# The handler lives in _proc_shim.c (Mojo has no signal API): it does one
# async-signal-safe atomic store. A caught signal is reset to its default in
# a spawned child by exec, so the job never inherits it.
#
# No pointer type crosses this file's surface; the thunks are scalar-only
# (proc_ffi.mojo).
# =============================================================================

from .proc_ffi import (
    proc_adopt_orphans,
    proc_install_stop_handler,
    proc_take_stop_signal,
)


def install_stop_signal_handler() raises:
    """Catch SIGTERM and SIGINT into the stop latch (`take_stop_signal`).
    Idempotent. Raises, naming the errno, if sigaction fails."""
    var rc = proc_install_stop_handler()
    if rc != Int32(0):
        raise Error(
            String("installing the SIGTERM/SIGINT handler failed: errno ")
            + String(-rc)
        )


def take_stop_signal() -> Int32:
    """The first SIGTERM or SIGINT caught since the last take, cleared by this
    read; 0 when none arrived. Only meaningful after
    `install_stop_signal_handler`."""
    return proc_take_stop_signal()


def adopt_orphans() -> Bool:
    """Make the orphans of this process's descendants come to this process
    (they then become ITS zombies when they exit; `Supervisor.reap_orphans`
    collects them). True when that holds: this process is PID 1, or it is now
    a Linux child subreaper. False where the OS has no subreaper (orphans then
    go to init, which collects them) or the call failed."""
    return proc_adopt_orphans() >= Int32(0)
