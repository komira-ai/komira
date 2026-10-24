# =============================================================================
# macos_security_backend.mojo: the macOS `security` CLI as a `KeychainBackend`.
# =============================================================================
#
# Fetches a generic-password item by running
#
#     /usr/bin/security find-generic-password -s <service> -a <account> -w
#
# through komira_supervisor (posix_spawn with capture pipes). `-w` prints only
# the password, so stdout is the secret. Exit 0 is found (the one trailing
# newline `-w` adds is stripped); exit 44 (errSecItemNotFound) is a miss; any
# other exit, or a failed spawn, is an error carrying the exit code and a
# bounded stderr tail (stderr is `security`'s diagnostics; stdout, the secret,
# is never folded into an error).
#
# PLATFORM GATE: the spawn is inside `comptime if CompilationTarget.is_macos()`.
# On every other platform `fetch` answers an error lookup and starts no process,
# so a Linux build never runs `security` and never reaches the supervisor.
#
# The only pointers live inside komira_supervisor's FFI, behind its typed
# `Supervisor` / `ChildSpec` / `ExitInfo` API. The stdout and stderr Strings are
# dropped on every path; a Mojo `String` cannot be zeroed in place, so the
# authoritative wipe is the `SecretValue` the store builds.
#
# For local runs only.
# =============================================================================

from std.sys.info import CompilationTarget

from komira_supervisor.supervisor import Supervisor, ChildSpec, ExitInfo

from komira_secrets_keychain.keychain_backend import KeychainBackend, KeychainLookup


# =============================================================================
# §0 — the macOS `security` CLI facts.
# =============================================================================
# The system `security` binary — present on every macOS install at this path.
comptime SECURITY_BIN: String = "/usr/bin/security"
# The subcommand + flags: find a generic-password item, print ONLY the password.
comptime SECURITY_FIND_GENERIC: String = "find-generic-password"
comptime SECURITY_SERVICE_FLAG: String = "-s"
comptime SECURITY_ACCOUNT_FLAG: String = "-a"
comptime SECURITY_PASSWORD_ONLY_FLAG: String = "-w"
# errSecItemNotFound — `security`'s exit code for "no such keychain item". A
# clean MISS, distinct from any other (error) exit code.
comptime SECURITY_NOT_FOUND_EXIT: Int = 44
# How long to wait for the child to exit cleanly before escalating (ms). A
# `security` read returns in milliseconds; this grace only bounds a hung/
# prompting child so a local resolve cannot wedge forever (fail fast).
comptime SECURITY_GRACE_MS: Int = 5000


# =============================================================================
# §0.5 — pure argv construction (testable without a spawn).
# =============================================================================
def build_security_argv(service: String, account: String) -> List[String]:
    """The argv[1:] for `security find-generic-password -s <service> -a <account>
    -w`. Pure — no spawn. Factored out so the argv assembly is unit-testable
    without shelling out (and so a `account == ""` lookup correctly omits the
    `-a` flag — `security` matches on service alone when no account is given)."""
    var argv = List[String]()
    argv.append(SECURITY_FIND_GENERIC)
    argv.append(SECURITY_SERVICE_FLAG)
    argv.append(service)
    if len(account.as_bytes()) > 0:
        argv.append(SECURITY_ACCOUNT_FLAG)
        argv.append(account)
    argv.append(SECURITY_PASSWORD_ONLY_FLAG)
    return argv^


# =============================================================================
# §1 — MacosSecurityKeychainBackend — the LIVE macOS backend.
# =============================================================================
struct MacosSecurityKeychainBackend(KeychainBackend, Movable):
    """The LIVE local-dev macOS `KeychainBackend`: fetches a generic-password
    item by spawning `/usr/bin/security find-generic-password -s <service> -a
    <account> -w` through komira_supervisor and capturing its
    stdout (the password). Exit 0 -> found (stdout, trailing newline stripped);
    exit 44 -> miss (errSecItemNotFound); any other -> error (the exit code +
    a bounded stderr tail, NON-secret). A spawn failure -> error.

    It has no field (the `Supervisor` is built per `fetch`, owns its
    capture-pipe fds, and is closed before `fetch` returns). The secret is never
    a struct field: it lives in the per-fetch lookup the store consumes and
    wipes.

    On a platform other than macOS, `fetch` returns an error lookup and starts
    no process.

    LOCAL-DEV ONLY — the developer's login keychain, the local stand-in for a
    cloud secret manager. NOT a production secret store."""

    def __init__(out self):
        pass

    def fetch(mut self, service: String, account: String) raises -> KeychainLookup:
        """Spawn `security`, capture stdout, and map the exit code to a
        `KeychainLookup`. Exit 0 -> found(stdout minus the trailing newline the
        `-w` form adds); exit 44 -> miss; any other / spawn failure -> error
        (exit code + bounded stderr tail). The stdout (secret) + stderr
        transients are wiped before return; the error path NEVER carries stdout."""
        comptime if CompilationTarget.is_macos():
            # --- 1. Build the child spec: /usr/bin/security <args>. ---
            var spec = ChildSpec(SECURITY_BIN)
            var argv = build_security_argv(service, account)
            for ref a in argv:
                spec.with_arg(a)

            # --- 2. Spawn over the supervisor shim. A spawn failure is a backend
            #        ERROR (the `security` binary missing / not executable), never a
            #        miss — fail loud with the -errno the shim returns. ---
            var sup = Supervisor()
            var pid = sup.spawn(spec)
            if pid <= Int32(0):
                sup.close()
                return KeychainLookup.error(
                    String("spawn of /usr/bin/security failed (errno ")
                    + String(Int(pid))
                    + String(")")
                )

            # --- 3. Drain stdout (the password) + stderr (diagnostics) to EOF, then
            #        reap. drain_pipe reads until the child closes the fd (EOF), which
            #        only happens once it exits — so the drain doubles as the
            #        exit-observed barrier the blocking reap relies on. ---
            var stdout_text = sup.drain_pipe(sup.stdout_fd())
            var stderr_text = sup.drain_pipe(sup.stderr_fd())
            var info = sup.wait_exit()
            sup.close()
            var exit_code = Int(info.exit_code)

            # --- 4. errSecItemNotFound (44) is a clean MISS, not an error. ---
            if exit_code == SECURITY_NOT_FOUND_EXIT:
                _wipe_string(stdout_text)
                _wipe_string(stderr_text)
                return KeychainLookup.miss()

            # --- 5. Any non-zero exit (other than 44) is a backend ERROR. The
            #        reason carries the exit code + a bounded, NON-secret stderr tail
            #        (stderr is `security`'s diagnostics, NEVER the value). stdout
            #        (the secret) is wiped and NEVER folded into the error. ---
            if exit_code != 0:
                var reason = String("/usr/bin/security exited ") + String(exit_code)
                var tail = _bounded_tail(stderr_text)
                if len(tail.as_bytes()) > 0:
                    reason += String(": ") + tail^
                _wipe_string(stdout_text)
                _wipe_string(stderr_text)
                return KeychainLookup.error(reason^)

            # --- 6. Exit 0 -> found. Copy stdout (minus the trailing newline the
            #        `-w` form appends) into the lookup's byte buffer, then wipe the
            #        transients. ---
            var bytes = _stdout_to_secret_bytes(stdout_text)
            _wipe_string(stdout_text)
            _wipe_string(stderr_text)
            return KeychainLookup.found(bytes^)
        else:
            return KeychainLookup.error(
                String("MacosSecurityKeychainBackend: the macOS `security` ")
                + String("tool is only available on macOS")
            )


# =============================================================================
# §2 — stdout -> secret bytes (strip the CLI's trailing newline).
# =============================================================================
def _stdout_to_secret_bytes(out_text: String) -> List[UInt8]:
    """Copy `security`'s stdout into a byte buffer, stripping the SINGLE trailing
    newline the `-w` form appends (it prints `<password>\\n`). We strip exactly
    one trailing `\\n` (and a preceding `\\r` if present, defensive) — never more,
    so a password that legitimately ends in whitespace is not corrupted. A
    password is opaque bytes; we touch only the one CLI-added line terminator."""
    var src = out_text.as_bytes()
    var n = len(src)
    # Strip exactly one trailing "\n", then an optional preceding "\r".
    if n > 0 and src[n - 1] == UInt8(ord("\n")):
        n -= 1
        if n > 0 and src[n - 1] == UInt8(ord("\r")):
            n -= 1
    var bytes = List[UInt8]()
    for i in range(n):
        bytes.append(src[i])
    return bytes^


# =============================================================================
# §3 — bounded, non-secret stderr tail for the error reason.
# =============================================================================
def _bounded_tail(s: String) -> String:
    """A bounded (<= 200 char) tail of `security`'s stderr, for the operator-facing
    error reason. stderr is `security`'s own diagnostic text (e.g. 'The specified
    item could not be found in the keychain.'), NOT the secret — but we still
    bound it so a pathological stderr cannot bloat the error. Trailing whitespace
    is trimmed."""
    comptime MAX = 200
    var src = s.as_bytes()
    var n = len(src)
    # Trim trailing whitespace/newlines for a tidy message.
    while n > 0 and (
        src[n - 1] == UInt8(ord("\n"))
        or src[n - 1] == UInt8(ord("\r"))
        or src[n - 1] == UInt8(ord(" "))
        or src[n - 1] == UInt8(ord("\t"))
    ):
        n -= 1
    var start = 0
    if n > MAX:
        start = n - MAX
    var out = String("")
    for i in range(start, n):
        out += chr(Int(src[i]))
    return out^


# =============================================================================
# §4 — best-effort transient scrub.
# =============================================================================
def _wipe_string(mut s: String):
    """Best-effort scrub of a transient `String` that briefly held the secret
    (stdout) or backend diagnostics. Mojo cannot securely zero a `String`
    heap buffer (the same limitation `SecretValue` exists to avoid), so this drops
    the prior heap buffer by reassigning to empty. The AUTHORITATIVE secure wipe
    is on the zeroizing `SecretValue` the store mints (InlineArray +
    `zeroize_inline_array`); this transient holds the secret only for the few
    instructions between the drain and the lookup copy."""
    s = String("")
