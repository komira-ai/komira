# =============================================================================
# komira_async.reactor.graceful_shutdown — SIGTERM-driven graceful-drain seam
# =============================================================================
# The Mojo-side wrapper over the SIGTERM
# handler installed in the statically-linked posix shim
# (`_posix_shim.c:komira_install_sigterm_handler` /
# `komira_shutdown_requested`).
#
# WHY THIS IS A SEPARATE TINY MODULE: a server main built on this runtime is
# an infinite non-blocking serve loop, and without a SIGTERM handler a
# `docker stop` / an SO_REUSEPORT blue-green swap SIGKILLs it mid-session.
# This module exposes the two primitives a main needs to drain gracefully:
#   * `install_sigterm_handler()` — install the handler ONCE at boot.
#   * `shutdown_requested()` — poll the flag once per serve-loop iteration; when
#     it flips true the main stops accepting (closes the listener fd), drives the
#     existing per-connection CLOSING phase machine to completion, then exits.
#
# Mojo has no native signal API. The handler lives in C (a sigaction
# install + a `volatile sig_atomic_t` flag) — see `_posix_shim.c`, which this
# library links, so these `external_call` symbols resolve in every binary
# that depends on it with no extra link wiring.
#
# ENCAPSULATION + destroy-recreate: the FFI surface is two scalar-only
# `external_call`s (Int -> Int / () -> Int). NO UnsafePointer crosses the
# boundary; NO wildcard origins; NO unsafe_from_address; NO heap; NO Mojo struct
# field. The shutdown state is a process-resident C static scalar, never a Mojo
# struct field — so it is outside the destroy-recreate byte-slab/wildcard trap
# entirely. The handler does only an async-signal-safe sig_atomic_t store.
# =============================================================================

from std.ffi import external_call



def running_version(version: String) -> String:
    """The running release version as reported by /healthz: `version`, or
    "unknown" when the caller has none (an empty string).

    The serving binary receives its release version as a startup flag and
    passes it here; nothing is read from the environment."""
    return version if version.byte_length() > 0 else String("unknown")


def health_body(version: String) -> String:
    """The canonical /healthz response body: a tiny JSON object carrying the
    liveness status + the running version, e.g. `{"status":"ok","version":"1.4.2"}`.

    `version` is the release version the binary was started with (empty ->
    "unknown"). The body always contains the literal `ok`, so a probe that only
    looks for `ok` keeps working. The version is the only dynamic field; the
    status is always `ok` (a request that REACHES this handler means the server
    is serving). NO secret is ever in the health body — only the (non-secret)
    release version."""
    return (
        String('{"status":"ok","version":"')
        + running_version(version)
        + String('"}')
    )


def install_sigterm_handler() -> Bool:
    """Install the process-wide SIGTERM (+ SIGINT) graceful-shutdown handler.

    Call this ONCE at server boot (on the main thread, before the serve loop).
    After it returns, a SIGTERM (`docker stop`, the blue-green SIGTERM-blue step)
    or a SIGINT (Ctrl-C) sets a process-local flag that `shutdown_requested()`
    reports — it does NOT terminate the process, so the serve loop can drain.

    Idempotent (a second call re-points to the same handler). Returns True on
    success, False if the underlying `sigaction` install failed (the caller logs
    a warning + keeps serving; without the handler the old hard-exit-on-SIGTERM
    behavior applies — correctness-safe, just not graceful).
    """
    var rc = external_call["komira_install_sigterm_handler", Int32]()
    return rc == Int32(0)


def ignore_sigpipe() -> Bool:
    """Set SIGPIPE to SIG_IGN so a write to a departed peer returns EPIPE instead
    of terminating the process. Call ONCE at server boot, and from any test that
    hosts a serve loop in-process.

    ★ THIS MAKES AN ALREADY-WRITTEN ERROR PATH REACHABLE; IT IS NOT HARDENING.
    `try_send` (socket_io) passes `msg_dontwait()` and NOT
    `MSG_NOSIGNAL`, and nothing else in the process altered SIGPIPE's
    disposition, whose POSIX default is TERMINATE. `try_io_write`'s own docstring
    already names "EPIPE on closed peer" as a value it returns, and every serve
    loop built on it maps a hard write error onto "drop THIS connection
    and keep serving". Without this call the process never survives to run that
    code.

    Without it, a server that multiplexes many sessions in one process loses
    EVERY session the first time it writes to one departed peer.

    Returns True on success, False if the `sigaction` install failed (the caller
    logs and keeps serving — the pre-existing behaviour)."""
    var rc = external_call["komira_ignore_sigpipe", Int32]()
    return rc == Int32(0)


def shutdown_requested() -> Bool:
    """True once a SIGTERM / SIGINT has been received (the drain signal).

    The serve loop polls this once per outer iteration. It is a plain read of a
    `volatile sig_atomic_t` C static (atomic w.r.t. signal delivery), so the
    loop reliably observes the handler's store. Returns False until the first
    signal, True forever after (shutdown is one-way — there is no un-drain).
    """
    var v = external_call["komira_shutdown_requested", Int32]()
    return v != Int32(0)
