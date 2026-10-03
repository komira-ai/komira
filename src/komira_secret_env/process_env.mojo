# =============================================================================
# komira_secret_env/process_env.mojo: `ProcessEnv`, the `EnvReader` over this
#   process's environment.
# =============================================================================
#
# `lookup` reads the variable with komira_libc's `_read_env_into`, the
# package that holds this binary's one `getenv` declaration, into a stack
# buffer of `MAX_SECRET_LEN` bytes, builds the `SecretValue` from it, and
# wipes the buffer with `zeroize_inline_array` on every path out. No `String`
# or `List` holds the value on the way, so after `lookup` returns only the
# `SecretValue` (wiped on drop) and the environ block hold it. The environ
# block is not cleared: this reader does not `unsetenv`, so the value stays in
# the process environment for the life of the process (and in
# /proc/<pid>/environ). That is the price of the env channel; a caller who
# cannot accept it uses another store.
#
# No pointer appears here: the FFI result never leaves komira_libc.
# =============================================================================

from komira_libc.posix import _read_env_into
from komira_crypto import zeroize_inline_array
from komira_secret_store import MAX_SECRET_LEN, SecretValue

from komira_secret_env.env_name import check_secret_env_name
from komira_secret_env.env_secret_store import EnvReader


struct ProcessEnv(EnvReader, Movable):
    """The `EnvReader` over this process's environment (`getenv(3)`)."""

    def __init__(out self):
        pass

    def lookup(mut self, name: String) raises -> Optional[SecretValue]:
        """The variable `name`: `None` when unset, else its bytes, exactly.

        Raises when `name` is not a variable name, or the value is longer
        than `MAX_SECRET_LEN` bytes."""
        check_secret_env_name(name)
        var buf = Array[UInt8, MAX_SECRET_LEN](fill=UInt8(0))
        var n: Int
        try:
            n = _read_env_into(name, buf)
        except:
            # Nothing was copied (the reader refuses before copying), but the
            # wipe is unconditional so no path leaves bytes behind.
            zeroize_inline_array(buf)
            raise Error(
                String("value is longer than MAX_SECRET_LEN (")
                + String(MAX_SECRET_LEN)
                + " bytes)"
            )
        if n < 0:
            zeroize_inline_array(buf)
            return None
        var value: SecretValue
        try:
            value = SecretValue(Span(buf)[:n])
        except e:
            zeroize_inline_array(buf)
            raise e^
        zeroize_inline_array(buf)
        return value^
