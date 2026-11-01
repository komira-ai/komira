# =============================================================================
# komira_libc.posix — the one `getenv(3)` and `unsetenv(3)` declarations,
# `access(2)` path probes, and the calling thread's identity.
# =============================================================================
#
# # Why the getenv declaration lives here
#
# Mojo's MLIR FFI legalization pass requires that each external C symbol be
# declared at most once per link unit. Independent
# `external_call["getenv", ...]` declarations in several packages each compile
# into their enclosing package; when more than one such package ends up in a
# single binary, MLIR aborts with `existing function with conflicting
# signature`. This file is therefore the single `getenv` declaration every
# package imports.
#
# # Environment variables are NOT a configuration channel
#
# Libraries take their configuration as explicit parameters (a function
# argument or a config struct field) supplied by the caller, and binaries take
# theirs as command-line flags parsed at startup, where a missing required
# flag is refused. Secrets are fetched from the secret store by a name passed
# as a flag. Platform facts (the port, which platform we run on) arrive as
# flags set by the deployer.
#
# `_read_env` exists ONLY for platform handshake values that no other channel
# carries, read inside the code that implements that platform handshake:
#
#   * AWS Lambda's Runtime API endpoint: `AWS_LAMBDA_RUNTIME_API`;
#   * AWS role credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
#     `AWS_SESSION_TOKEN`;
#   * ECS / Fargate task credentials: `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`;
#   * the STANDARD AWS SDK settings the AWS default credential and region
#     chains read (AWS_PROFILE, AWS_REGION, AWS_CONFIG_FILE, the web identity,
#     container and instance metadata variables, HOME for ~/.aws), read only
#     by komira_aws_core's `ProcessEnv` (komira_aws_core/sources.mojo), each
#     citing the AWS SDKs and Tools Reference Guide page that defines it;
#   * `PATH`, read only to look up an executable by bare name the way
#     execvp(3) and a shell do (exec-path lookup: komira_job_supervisor's
#     entrypoint resolves its `--job-binary` on it before the job starts);
#
# and for the test runner's own variables (`TEST_TMPDIR`, `HOME`), which a
# test reads through one small test-harness helper, never ad hoc. Any other
# read is configuration and belongs in a parameter or a flag.
#
# `_read_env_into` is the second reader over the same declaration, for SECRET
# material only: komira_secret_env's `ProcessEnv`, the secret store whose
# handle names an environment variable. A secret may not ride argv (it is
# world-readable in /proc/<pid>/cmdline), so the environment is one of its
# channels. That reader copies into a caller-owned byte buffer, never a
# `String`, so the caller can wipe it.
#
# `_unset_env` is the one `unsetenv(3)` declaration, for the same SECRET
# channel: a process that has read a secret out of a variable removes the
# variable, so a child it spawns afterwards (which inherits the environment)
# never sees it. It removes; it never sets. (The kernel's copy of the initial
# environment, /proc/<pid>/environ, is not rewritten by unsetenv.)
#
# Encapsulation: the `UnsafePointer[UInt8, MutUntrackedOrigin]` result of
# `getenv` IS the FFI boundary. It never leaves this file; `_read_env`
# returns a `String`, and `_read_env_into` copies into a caller's `Array`.
#
# Env reads use exactly the name asked for: no prefix rewriting, no fallback
# to another spelling.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# SAFETY: private FFI shim. The untracked-origin result is environ-managed
# memory and never leaves this file.
def _env_getenv_owned(var name: String) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Raw `getenv(3)` over a heap `String` (guarantees NUL termination).

    SAFETY: the untracked-origin pointer IS the FFI boundary. The returned
    pointer is environ-managed memory; it never escapes this file.
    """
    # SAFETY: `name` is owned by this frame and outlives the synchronous
    # `getenv` call, which keeps no pointer to the NUL-terminated buffer.
    var name_ptr = name.as_c_string_slice().unsafe_ptr()
    return external_call["getenv", UnsafePointer[UInt8, MutUntrackedOrigin]](
        name_ptr
    )


# -----------------------------------------------------------------------------
# Public — the one getenv primitive.
# -----------------------------------------------------------------------------


def _read_env(name: StaticString) -> String:
    """Read environment variable `name` into a Mojo `String`.

    ONLY for the platform handshake values and test-runner variables listed
    in this file's header. Configuration is never read from the environment.

    Returns `""` (empty string) when:
      * the variable is unset (libc `getenv` returns NULL), OR
      * the variable is set to an empty value.

    Internally caps the read at 65536 bytes (defensive — POSIX
    doesn't bound env-var lengths, but no realistic handshake
    value exceeds a few KB).

    SAFETY: The untracked-origin `getenv` result IS the FFI boundary.
    The returned pointer is environ-managed memory read transiently and
    never escapes this function, so the untracked origin is bounded to this
    call.
    """
    var env_ptr = _env_getenv_owned(String(name))
    if Int(env_ptr) == 0:
        return String("")
    # Length first, then ONE byte-exact copy.
    #
    # ⛔ DO NOT REWRITE THE COPY AS `out += chr(Int(b))` PER BYTE. That is a
    # SILENT WRONG ANSWER on any env value holding a byte >= 0x80: `chr` maps
    # a CODE POINT to its UTF-8 ENCODING, so such a byte is not reproduced but
    # re-encoded into TWO. `TMPDIR=/tmp/données` would come back
    # `/tmp/donnÃ©es`, a path that opens nothing. ASCII is the corruption's
    # fixed point, so an ASCII-only test cannot see it. Because this is the
    # consolidated env reader, such a defect reaches every consumer of a
    # non-ASCII env value, whatever package it lives in.
    var n: Int = 0
    while n <= 65536:  # defensive cap on env value length
        if env_ptr[n] == UInt8(0):
            break
        n += 1
    if n == 0:
        return String("")
    # The Span is length-explicit and the String constructor copies out of it
    # before this frame returns; neither the pointer nor the Span escapes.
    # `StringSlice(unsafe_from_utf8=)` is the byte-exact spelling — NOT
    # `String(unsafe_from_utf8_ptr=)`, which would stop at the first NUL.
    # SAFETY: `env_ptr` is environ-managed memory, scanned to its NUL above,
    # so `[0, n)` is in bounds. The bytes are copied as-is, not validated.
    return String(
        StringSlice(unsafe_from_utf8=Span(unsafe_ptr=env_ptr, length=n))
    )


def _read_env_into[N: Int](name: String, mut buf: Array[UInt8, N]) raises -> Int:
    """Copy environment variable `name`'s bytes into `buf`, exactly.

    The reader for a SECRET held in the environment (komira_secret_env's
    `ProcessEnv`): no `String` or `List` ever holds the value, so the caller
    can build its zeroizing holder from `buf` and then wipe `buf`. Unlike
    `_read_env`, unset and set-but-empty are different answers.

    Returns -1 when the variable is unset, else the value's length `n`, with
    the value in `buf[0:n]` (bytes past `n` are not written). Raises when the
    value is longer than `N` bytes; `buf` is then left untouched, and the
    error names neither the variable nor any byte of its value.

    SAFETY: the untracked-origin `getenv` result is read only inside this
    function: scanned to its NUL (no further than `N + 1` bytes), then copied
    into `buf`. No pointer leaves this function.
    """
    var env_ptr = _env_getenv_owned(name)
    if Int(env_ptr) == 0:
        return -1
    # Scan to the NUL, but no further than one byte past `N`: a longer value
    # is refused, so its length past that is never needed.
    var n: Int = 0
    while n <= N:
        if env_ptr[n] == UInt8(0):
            break
        n += 1
    if n > N:
        raise Error(
            String("environment value is longer than ")
            + String(N)
            + " bytes"
        )
    for i in range(n):
        buf[i] = env_ptr[i]
    return n


def _unset_env(name: String) raises:
    """Remove environment variable `name` from this process (unsetenv(3)).

    The secret channel only (module header): called after the secret has
    been read, so a child spawned later does not inherit it. Removing a
    variable that is not set succeeds. Raises, naming the variable, when libc
    refuses the name (empty, or holding `=`).

    FFI-BOUNDARY: libc `unsetenv` reads the NUL-terminated name, which the
    local `n` owns for the duration of the synchronous call; libc keeps no
    pointer to it. Nothing is allocated across the boundary and nothing needs
    freeing.
    """
    var n = name
    # SAFETY: `n` owns the NUL-terminated buffer and outlives the synchronous
    # call; unsetenv keeps no pointer to it and the pointer does not escape.
    var rc = external_call["unsetenv", Int32](n.as_c_string_slice().unsafe_ptr())
    if Int(rc) != 0:
        raise Error(
            String("unsetenv: cannot remove ")
            + name
            + String(" from the environment")
        )


# -----------------------------------------------------------------------------
# Public — filesystem executable probe (POSIX `access(path, X_OK)`).
#
# The canonical helper for a "which"-style PATH resolve: given an absolute
# candidate path, is it an EXISTING, EXECUTABLE file? Callers that fork-exec a
# host tool via `posix_spawn` (which does NOT PATH-search — it needs an absolute
# path) walk `PATH` and use this to pick the first executable match.
#
# `access(path, X_OK)` returns 0 iff the calling process could execute `path`
# (the file exists AND has an execute bit the caller can use). Any error
# (ENOENT / EACCES / a non-executable regular file) yields a non-zero rc.
# -----------------------------------------------------------------------------
def _path_is_directory(path: String) -> Bool:
    """Return True iff `path` names a directory.

    Portable `access(3)` trick: `access("<path>/.", F_OK)` succeeds ONLY when
    `<path>` is a directory — appending the `/.` component to a regular file (or a
    non-existent path) is not a valid path, so `access` returns non-zero; on a
    directory `<path>/.` resolves to the directory itself and returns 0. This
    avoids both the platform-dependent `struct stat` layout AND the `opendir` /
    `closedir` external_call (whose stdlib signature conflicts inside this
    compilation unit — a consumer that also pulls in std/ffi's `closedir` decl
    would see two declarations).

    `as_c_string_slice()` is a mutating method (appends a NUL) — needs an owned
    local that outlives the `external_call`."""
    var probe = path + String("/.")
    # `access` reads the path during the call and keeps no pointer to it.
    # SAFETY: `probe` owns the NUL-terminated buffer and lives to the end of
    # this function, past the synchronous call; the pointer does not escape.
    var rc = external_call["access", Int32](
        probe.as_c_string_slice().unsafe_ptr(), Int32(0)  # F_OK == 0
    )
    return rc == 0


def _path_is_executable(path: String) -> Bool:
    """Return True iff `path` exists, is a REGULAR FILE, and is executable by this
    process (POSIX `access(path, X_OK)` == 0, AND not a directory). `X_OK == 1`.

    The directory guard is LOAD-BEARING: `access(dir, X_OK)` returns 0 for a
    searchable directory, so a which-style PATH walk that trusted `access` alone
    would resolve a PATH entry containing a subdirectory NAMED like the tool
    (for example a `crane/` directory holding the crane binary, earlier on PATH
    than the real `crane`). That resolved 'path'
    then fails `posix_spawn` with EACCES (errno -13) trying to exec a directory.
    Rejecting directories here makes the resolver skip that entry and continue the
    PATH walk to the real binary.

    `as_c_string_slice()` is a mutating method (appends a NUL) — needs an owned
    local that outlives the `external_call`."""
    var p = path
    # SAFETY: as above: the NUL-terminated buffer is owned by `p`, which
    # outlives the synchronous `access` call, and the pointer does not escape.
    var rc = external_call["access", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int32(1)  # X_OK == 1
    )
    if rc != 0:
        return False
    # X_OK passed — reject a directory (searchable dirs also pass X_OK).
    return not _path_is_directory(path)


# -----------------------------------------------------------------------------
# Thread identity — driver-vs-worker attribution for traces.
# -----------------------------------------------------------------------------


def _thread_self() -> UInt64:
    """Return an opaque, per-thread-unique identifier for the CALLING thread.

    `pthread_self()` on both Linux (`unsigned long`) and macOS (an opaque
    `pthread_t*`). The VALUE is meaningless across processes and must never be
    persisted or compared to a kernel TID — its ONLY contract is: two calls on
    the same thread return the same value, two calls on different live threads
    return different values. That is exactly what a driver-vs-pool-worker
    attribution needs.

    Why this exists: a profile SHARE can mis-attribute work (an inlined worker
    body reads as overhead on the caller). A per-thread identity printed FROM A RUN settles
    "is this region on the serial driver or on the pool?" without a profiler.

    Declared HERE (not inline at a call site) per this module's rule: one FFI
    declaration per symbol, so no second site can introduce a conflicting
    signature. Do not declare `pthread_self` anywhere else.
    """
    return external_call["pthread_self", UInt64]()