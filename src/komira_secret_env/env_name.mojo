# =============================================================================
# komira_secret_env/env_name.mojo: the grammar of a secret handle that names an
#   environment variable.
# =============================================================================
#
# A handle is a NAME, never a value. The grammar is the shell variable name,
# `[A-Za-z_][A-Za-z0-9_]*`, at most `MAX_SECRET_NAME_LEN` bytes. It rejects
# most pasted tokens (they carry `-`, `.`, `/`, `+`, `=` or `:`), and it keeps
# a NUL byte from ever reaching `getenv`.
#
# A refused handle is NOT quoted back. A handle that fails the grammar may be
# a pasted secret, and an error message is logged. The refusal names the
# length and the position of the first bad byte instead.
# =============================================================================

comptime MAX_SECRET_NAME_LEN: Int = 128


def _is_name_byte(b: UInt8, first: Bool) -> Bool:
    if (b >= UInt8(ord("A")) and b <= UInt8(ord("Z"))) or (
        b >= UInt8(ord("a")) and b <= UInt8(ord("z"))
    ):
        return True
    if b == UInt8(ord("_")):
        return True
    if not first and b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return True
    return False


def is_secret_env_name(name: String) -> Bool:
    """Whether `name` is a valid environment-variable secret handle."""
    var bytes = name.as_bytes()
    var n = len(bytes)
    if n == 0 or n > MAX_SECRET_NAME_LEN:
        return False
    for i in range(n):
        if not _is_name_byte(bytes[i], i == 0):
            return False
    return True


def check_secret_env_name(name: String) raises:
    """Raise unless `name` is a valid handle. The message never quotes `name`."""
    var bytes = name.as_bytes()
    var n = len(bytes)
    if n == 0:
        raise Error("secret env name is empty")
    if n > MAX_SECRET_NAME_LEN:
        raise Error(
            String("secret env name is ")
            + String(n)
            + " bytes; the limit is "
            + String(MAX_SECRET_NAME_LEN)
            + " (a handle names a variable, it is not a value)"
        )
    for i in range(n):
        if not _is_name_byte(bytes[i], i == 0):
            raise Error(
                String("secret env name (")
                + String(n)
                + " bytes) is not an environment variable name: byte "
                + String(i)
                + " is outside [A-Za-z_][A-Za-z0-9_]*"
            )
