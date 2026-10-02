# =============================================================================
# komira_secret_env/process_env.mojo: `ProcessEnv`, the `EnvReader` over this
#   process's environment.
# =============================================================================
#
# `lookup` calls `getenv(3)` and builds the `SecretValue` straight from the
# environ bytes, through `SecretValue(Span)`. No `String` or `List` holds the
# value on the way, so nothing but the `SecretValue` (wiped on drop) and the
# environ block itself ever holds it. The environ block is not cleared: this
# reader does not `unsetenv`, so the value stays in the process environment
# for the life of the process (and in /proc/<pid>/environ). That is the price
# of the env channel; a caller who cannot accept it uses another store.
#
# THE getenv DECLARATION. komira_core_ffi is the usual home of `getenv`, and
# its header asks every package to import it from there: Mojo refuses, at
# LINK, a binary in which two packages declare one C symbol with DIFFERENT
# signatures. komira_core_ffi's `_read_env` cannot serve here: it returns a
# `String` (an unwiped copy of the secret), maps unset and empty to the same
# `""`, and takes a `StaticString`. So this file declares `getenv` itself,
# with komira_core_ffi's signature EXACTLY (a `var String` name, an
# `UnsafePointer[UInt8, MutUntrackedOrigin]` result). Same signature, no
# conflict: the `getenv_link_probe` test in this package's BUCK links this
# reader and komira_core_ffi's `_read_env` into one binary and compares their
# answers. Change one signature and change the other. (`std.os.getenv`
# declares `getenv` differently, so it cannot link beside this reader, nor
# beside komira_core_ffi.)
#
# SAFETY. The `UnsafePointer` is the FFI result and never leaves `lookup`;
# no pointer appears in any public signature.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer

from komira_secret_store import MAX_SECRET_LEN, SecretValue

from komira_secret_env.env_name import check_secret_env_name
from komira_secret_env.env_secret_store import EnvReader


def _getenv(var name: String) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Raw `getenv(3)` over a heap `String` (NUL-terminated).

    SAFETY: the untracked-origin pointer IS the FFI boundary: environ-managed
    memory, read by the caller in this file and never stored."""
    var name_ptr = name.as_c_string_slice().unsafe_ptr()
    return external_call["getenv", UnsafePointer[UInt8, MutUntrackedOrigin]](
        name_ptr
    )


struct ProcessEnv(EnvReader, Movable):
    """The `EnvReader` over this process's environment (`getenv(3)`)."""

    def __init__(out self):
        pass

    def lookup(mut self, name: String) raises -> Optional[SecretValue]:
        """The variable `name`: `None` when unset, else its bytes, exactly.

        Raises when `name` is not a variable name, or the value is longer
        than `MAX_SECRET_LEN` bytes."""
        check_secret_env_name(name)
        var p = _getenv(name)
        if Int(p) == 0:
            return None
        # Scan to the NUL, but no further than one byte past the limit: a
        # longer value is refused, so its length past that is never needed.
        var n: Int = 0
        while n <= MAX_SECRET_LEN:
            if p[n] == UInt8(0):
                break
            n += 1
        if n > MAX_SECRET_LEN:
            raise Error(
                String("value is longer than MAX_SECRET_LEN (")
                + String(MAX_SECRET_LEN)
                + " bytes)"
            )
        # SAFETY: `p` is environ memory scanned to its NUL above, so [0, n) is
        # in bounds. SecretValue copies the bytes before this frame returns;
        # neither the pointer nor the Span escapes.
        return SecretValue(Span(unsafe_ptr=p, length=n))
