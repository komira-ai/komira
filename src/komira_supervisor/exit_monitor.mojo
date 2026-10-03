# =============================================================================
# komira_supervisor.exit_monitor — reactor-integrated child-exit watch.
# =============================================================================
#
# Child exit is a NORMAL reactor event — NO SIGCHLD handler, no
# async-signal-safety footgun. Both backends map onto existing reactor
# machinery:
#
#   darwin — EVFILT_PROC / NOTE_EXIT on the LONG-LIVED reactor kqueue, via
#            kqueue_subsystem.kevent_register_proc_exit (which reuses the
#            existing _encode_kevent thunk), rather than a fresh kqueue per
#            wait.
#   linux  — pidfd_open(pid, 0) returns an fd that becomes EPOLLIN-readable on
#            child exit; register it with the EXISTING
#            epoll_subsystem.epoll_ctl_add (no new epoll machinery). This is
#            the primary target (supervised children in container pods).
#
# Both converge on one upper-layer call — `watch_process_exit(reactor_fd, pid,
# cookie)` — exactly mirroring how the cross-thread wake (EVFILT_USER /
# eventfd) is abstracted behind one upper-layer call. The supervisor's
# wait_exit() awaits the resulting completion the same way it awaits an
# fd-readiness completion, then waitpid-reaps once (the notification is not a
# reaper).
#
# This module compiles on BOTH platforms: the code for the other OS's symbols
# sits behind a comptime platform check and is elided.
#
# Pointer discipline: typed-scalar in/out only. The reactor registration goes
# through the existing kqueue/epoll subsystem thunks (each already encapsulates
# its UnsafePointer with # SAFETY:). No UnsafePointer crosses this surface.
# =============================================================================

from std.sys.info import CompilationTarget

from komira_async.reactor.kqueue_subsystem import (
    kevent_register_proc_exit,
    kevent_deregister_proc_exit,
)
from komira_async.reactor.epoll_subsystem import epoll_ctl_add, epoll_ctl_del, EPOLLIN

from .proc_ffi import proc_pidfd_open, proc_close


# -----------------------------------------------------------------------------
# A registered process-exit watch. On darwin the kernel keys the EVFILT_PROC
# event by pid; nothing to hold. On Linux we own a pidfd that must be closed +
# epoll_ctl_del'd when the watch is torn down.
# -----------------------------------------------------------------------------
@fieldwise_init
struct ProcExitWatch(Movable):
    var pid: Int32
    var pidfd: Int32   # Linux: the pidfd to close on teardown; -1 on darwin
    var cookie: UInt64 # echoed back by the reactor on the exit completion

    def is_valid(self) -> Bool:
        return self.pid >= Int32(0)


# -----------------------------------------------------------------------------
# watch_process_exit — register the child's exit with the long-lived reactor.
#
# `reactor_fd` is the reactor's backend fd (kqueue fd on darwin, epoll fd on
# Linux). `cookie` is the op_id the reactor echoes back so it can route the
# "process N exited" completion. Returns a ProcExitWatch (or an invalid one
# with pid<0 on failure).
#
# darwin: register EVFILT_PROC/NOTE_EXIT under ident=pid, udata=cookie on the
#         reactor kqueue. No fd owned.
# linux:  pidfd_open(pid) -> register the pidfd EPOLLIN under data=cookie on the
#         reactor epoll. The pidfd is owned by the returned watch.
# -----------------------------------------------------------------------------
def watch_process_exit(
    reactor_fd: Int32, pid: Int32, cookie: UInt64
) raises -> ProcExitWatch:
    comptime if CompilationTarget.is_macos():
        kevent_register_proc_exit(reactor_fd, pid, cookie)
        return ProcExitWatch(pid=pid, pidfd=Int32(-1), cookie=cookie)
    elif CompilationTarget.is_linux():
        var pidfd = proc_pidfd_open(pid)
        if pidfd < Int32(0):
            raise Error(
                "watch_process_exit: pidfd_open failed (kernel >= 5.3 required)"
            )
        # The pidfd is just an fd the reactor's epoll already knows how to
        # watch — register it identically to a socket fd (no new epoll code).
        epoll_ctl_add(reactor_fd, pidfd, EPOLLIN, cookie)
        return ProcExitWatch(pid=pid, pidfd=pidfd, cookie=cookie)
    else:
        raise Error("watch_process_exit: unsupported platform")


# -----------------------------------------------------------------------------
# unwatch_process_exit — tear down a watch. darwin: best-effort EVFILT_PROC
# deregister (benign if the ONESHOT already fired). linux: epoll_ctl_del +
# close the pidfd.
# -----------------------------------------------------------------------------
def unwatch_process_exit(reactor_fd: Int32, mut watch: ProcExitWatch):
    comptime if CompilationTarget.is_macos():
        kevent_deregister_proc_exit(reactor_fd, watch.pid)
    elif CompilationTarget.is_linux():
        if watch.pidfd >= Int32(0):
            try:
                epoll_ctl_del(reactor_fd, watch.pidfd)
            except:
                pass  # best-effort; ENOENT benign
            proc_close(watch.pidfd)
            watch.pidfd = Int32(-1)
