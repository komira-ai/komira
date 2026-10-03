"""The s2n-tls init idempotency guard must be PROCESS-LOCAL, not stored in the
ENVIRONMENT.

The hazard: an "already initialized" flag kept in an ENVIRONMENT VARIABLE is
INHERITED across `fork()` / `fork+exec`. A child process (a nested CLI run by a
script the parent spawned) then sees the inherited flag, skips `s2n_init()` —
but s2n's per-PROCESS C library state does NOT survive fork, so it was never
initialized in the child — and every `s2n_config_new()` there returns NULL.

The guard is therefore a TRUE process-local flag (the stdlib `_Global` KGEN
runtime slot). `_Global` storage lives in the process's OWN memory, so it NEVER
crosses a process boundary: a fresh process gets a fresh slot and runs
`s2n_init()` exactly once for ITSELF. The guard remains init-once WITHIN a
process (idempotent) and the KGEN runtime serializes the init, so it is safe
under concurrent `tls_init()`.

FALSIFIER STRATEGY (behavioral / subprocess): this test `fork()`s a child
AFTER poisoning the environment with `KOMIRA_S2N_INIT_DONE=1`, WITHOUT the
parent ever calling `tls_init()` first (so the child is genuinely the first to
init TLS). The child inherits the poisoned env, then calls `tls_init()` +
constructs a `TlsConfig` (which allocates a real s2n_config_t via
s2n_config_new). On success the child `_exit(0)`; on the config-NULL failure
it `_exit(2)`. The parent `waitpid`s and asserts exit 0.

  An environment-stored guard would short-circuit on the inherited flag and
  never call `s2n_init()`, so `TlsConfig()` -> s2n_config_new() returns NULL
  and raises -> the child `_exit(2)` -> this test raises. With the
  process-local guard the child's fresh `_Global` slot runs `s2n_init()`,
  s2n_config_new succeeds, the child `_exit(0)`, and the test passes.

Same static s2n link as the sibling L1 TLS tests; no cert fixtures needed
(only s2n_init + s2n_config_new are exercised).
"""

from std.ffi import external_call

from komira_http_core.tls import (
    TlsConfig,
    last_s2n_errno,
    tls_init,
)


# -----------------------------------------------------------------------------
# libc helpers — setenv / fork / waitpid / _exit
# -----------------------------------------------------------------------------


def _poison_init_env() raises:
    """Set KOMIRA_S2N_INIT_DONE=1 in this process's environment.

    This reproduces the state a nested child process inherits from an
    outer process that already initialized TLS under an environment-stored
    guard. We set it directly here
    so the test does not depend on running an actual outer process.

    SAFETY: setenv copies both NUL-terminated strings into environ storage;
    the local Strings are held alive across the external_call.
    """
    var key_str = String("KOMIRA_S2N_INIT_DONE")
    var val_str = String("1")
    var rc = external_call["setenv", Int32](
        key_str.as_c_string_slice().unsafe_ptr(),
        val_str.as_c_string_slice().unsafe_ptr(),
        Int32(1),  # overwrite=1
    )
    if rc != Int32(0):
        raise Error("setenv(KOMIRA_S2N_INIT_DONE) returned " + String(Int(rc)))


def _fork() -> Int32:
    """libc fork(). Returns 0 in the child, the child pid in the parent, -1 on
    error. SAFETY: fork is a stable POSIX symbol on macOS + Linux."""
    return external_call["fork", Int32]()


def _exit_process(code: Int32):
    """libc _exit() — terminate the calling process immediately WITHOUT running
    atexit handlers / flushing stdio (the child must NOT run the parent's
    at-exit teardown). SAFETY: _exit never returns."""
    external_call["_exit", NoneType](code)


def _waitpid_status(pid: Int32) raises -> Int32:
    """Block on the child `pid` and return the RAW wait status word.

    SAFETY: `status` is a stack Int32; waitpid writes the status word in place.
    We pass options=0 (block until the child terminates).
    """
    var status = Int32(0)
    var status_ptr = UnsafePointer(to=status).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var rc = external_call["waitpid", Int32](pid, status_ptr, Int32(0))
    if rc < Int32(0):
        raise Error("waitpid(" + String(Int(pid)) + ") returned " + String(Int(rc)))
    return status


def _exit_code_of(status: Int32) -> Int32:
    """Extract the child's exit code from a waitpid status word.

    POSIX `WIFEXITED(status)` iff `(status & 0x7f) == 0`, and
    `WEXITSTATUS(status)` is `(status >> 8) & 0xff`. If the child did NOT exit
    normally (e.g. it crashed with a signal), return -1 so the caller treats it
    as a failure.
    """
    var s = Int(status)
    if (s & 0x7F) != 0:
        # Terminated by a signal (or stopped) — not a normal exit.
        return Int32(-1)
    return Int32((s >> 8) & 0xFF)


# -----------------------------------------------------------------------------
# Child body — the actual TLS init under a poisoned-inherited environment
# -----------------------------------------------------------------------------

# Child exit codes (distinct so the parent can diagnose):
comptime _CHILD_OK: Int32 = 0
comptime _CHILD_CONFIG_NULL: Int32 = 2  # s2n_config_new returned NULL (the bug)
comptime _CHILD_UNEXPECTED: Int32 = 3  # any other raise in the child


def _run_child_tls_init() -> Int32:
    """Executed in the forked child. The child has inherited
    KOMIRA_S2N_INIT_DONE=1. Under the pre-fix env-guard, `tls_init()` will
    SKIP s2n_init(), so the subsequent `TlsConfig()` -> s2n_config_new() returns
    NULL and raises. Under the fixed process-local guard, `tls_init()` runs
    s2n_init() for THIS process and the config is constructed successfully.

    Returns the exit code the child should terminate with.
    """
    try:
        # First TLS use IN THIS PROCESS. With the env flag inherited, the
        # pre-fix guard short-circuits and never calls s2n_init().
        tls_init()
        # Allocate a real s2n_config_t. This is the operation that returns NULL
        # (-> raises "s2n_config_new returned NULL") when s2n was never
        # initialized in this process.
        var config = TlsConfig()
        _ = config^  # drop cleanly (s2n_config_free)
        return _CHILD_OK
    except e:
        # Distinguish the specific config-NULL failure (the bug's signature)
        # from any other unexpected raise for clearer diagnostics.
        var msg = String(e)
        if "s2n_config_new returned NULL" in msg:
            return _CHILD_CONFIG_NULL
        return _CHILD_UNEXPECTED


# -----------------------------------------------------------------------------
# Test case
# -----------------------------------------------------------------------------


def test_tls_init_guard_is_process_local_not_env_inherited() raises:
    """A child process that INHERITS KOMIRA_S2N_INIT_DONE=1 must STILL init
    TLS + construct a config handle for itself.

    This is the falsifier: it FAILS under an env-var guard (child skips
    s2n_init -> s2n_config_new NULL -> exit 2) and PASSES once the guard is a
    process-local `_Global` slot (child runs its own s2n_init -> config OK ->
    exit 0).

    CRITICAL: the parent must NOT call `tls_init()` before forking, so the
    child is genuinely the first to init TLS (the nested-process shape) and
    inherits an uninitialized `_Global` slot via fork's copy-on-write.
    """
    print("  test_tls_init_guard_is_process_local_not_env_inherited...")

    # Reproduce the inherited-env poisoning that a process spawned by another
    # s2n-using process sees.
    _poison_init_env()

    var pid = _fork()
    if pid == Int32(0):
        # ---- CHILD ----
        var code = _run_child_tls_init()
        # Terminate immediately; do NOT unwind back into the parent's test
        # driver (that would double-run the parent's teardown in the child).
        _exit_process(code)
        # unreachable
        return

    if pid < Int32(0):
        raise Error("fork() failed (returned " + String(Int(pid)) + ")")

    # ---- PARENT ----
    var status = _waitpid_status(pid)
    var code = _exit_code_of(status)
    print("    child exit code: " + String(Int(code)))

    if code == _CHILD_CONFIG_NULL:
        raise Error(
            "FALSIFIED: the forked child INHERITED KOMIRA_S2N_INIT_DONE=1, its"
            " tls_init() skipped s2n_init(), and s2n_config_new() returned NULL"
            " (child exit 2). The init guard is stored in the ENVIRONMENT and"
            " crosses fork -> every nested TLS process fails. It MUST be a"
            " process-local flag."
        )
    if code != _CHILD_OK:
        raise Error(
            "child TLS init failed unexpectedly (exit code "
            + String(Int(code)) + ", last_s2n_errno in parent="
            + String(Int(last_s2n_errno())) + ")"
        )
    print("    OK (child re-inited TLS despite inherited env flag)")


def main() raises:
    """Drive the process-local TLS-init-guard falsifier."""
    print("== L1 TLS init process-local guard (not env-inherited) ==")
    test_tls_init_guard_is_process_local_not_env_inherited()
    print("== PASSED (1 test) ==")
