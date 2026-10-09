# =============================================================================
# komira_job_supervisor/bearer_auth.mojo: a bearer credential for the
# heartbeat, from a file or from one environment variable.
# =============================================================================
#
# `BearerHeartbeatAuth` is the `HeartbeatAuth` conformer the entrypoint
# binary (entrypoint.mojo) uses: every heartbeat carries
# `Authorization: Bearer <token>`. The token comes from one of two places, and
# never from argv (world-readable in /proc/<pid>/cmdline):
#
#   from_file(path)  the token is the file's contents. The file is read when
#                    the conformer is built (an unreadable or empty file
#                    refuses the start) and AGAIN FOR EVERY HEARTBEAT, so a
#                    token the platform rotates in place (a mounted secret
#                    volume) is picked up at the next beat without a restart.
#                    A file that cannot be read at a beat fails that beat
#                    closed (HEARTBEAT_STATUS_AUTH_UNAVAILABLE); nothing is
#                    sent without the credential.
#   from_env(name)   the token is environment variable `name`, read ONCE when
#                    the conformer is built, held in a zeroizing
#                    komira_secret_store `SecretValue`, and then the variable
#                    is removed from this process's environment (unsetenv), so
#                    the job, which inherits the environment, never sees it.
#                    The kernel's copy of the initial environment
#                    (/proc/<pid>/environ, readable by the same user) is not
#                    rewritten; the supervisor's own children do not get it.
#
# THE TOKEN: trailing whitespace (a file written with a final newline) is
# dropped; what remains must be non-empty, at most MAX_SECRET_LEN bytes, and
# every byte visible ASCII (0x21..0x7E), so a token can never split or forge
# a header line. Every refusal names the file or the variable, never a byte of
# the token.
#
# No FFI here: the variable's VALUE is read through komira_secret_env
# (komira_libc's one getenv), and it is removed with komira_libc's
# `_unset_env` (the one unsetenv declaration), which owns that boundary.
#
# No pointer type crosses this file's public surface.
# =============================================================================

from std.pathlib import Path as FsPath

from komira_http_client.header_map import HeaderEntry
from komira_libc.posix import _unset_env
from komira_secret_env import ProcessEnv, check_secret_env_name
from komira_secret_store import MAX_SECRET_LEN, SecretValue

from komira_job_supervisor.heartbeat_auth import HeartbeatAuth


def _is_trailing_space(b: UInt8) -> Bool:
    return b == UInt8(0x20) or b == UInt8(0x09) or b == UInt8(0x0A) or b == UInt8(
        0x0D
    )


def bearer_token_length(bytes: Span[UInt8, _], what: String) raises -> Int:
    """The length of the usable token at the front of `bytes`: `bytes` with
    trailing whitespace dropped. Raises (naming `what`, never a byte of the
    token) when that is empty, longer than MAX_SECRET_LEN, or holds a byte
    outside visible ASCII 0x21..0x7E."""
    var n = len(bytes)
    while n > 0 and _is_trailing_space(bytes[n - 1]):
        n -= 1
    if n == 0:
        raise Error(
            String("job supervisor: the heartbeat credential in ")
            + what
            + String(" is empty")
        )
    if n > MAX_SECRET_LEN:
        raise Error(
            String("job supervisor: the heartbeat credential in ")
            + what
            + String(" is longer than ")
            + String(MAX_SECRET_LEN)
            + String(" bytes")
        )
    for i in range(n):
        var b = bytes[i]
        if b < UInt8(0x21) or b > UInt8(0x7E):
            raise Error(
                String("job supervisor: the heartbeat credential in ")
                + what
                + String(" holds a byte that is not visible ASCII at offset ")
                + String(i)
            )
    return n


def _bearer_header(token: Span[UInt8, _]) -> HeaderEntry:
    """`Authorization: Bearer <token>`; `token` was checked by
    `bearer_token_length`, so it is visible ASCII."""
    var value = String("Bearer ")
    value += String(StringSlice(unsafe_from_utf8=token))
    return HeaderEntry(name=String("Authorization"), value=value^)


def _read_token_file(path: String) raises -> List[UInt8]:
    """The file's bytes; a read failure names the file only."""
    try:
        return FsPath(path).read_bytes()
    except:
        raise Error(
            String("job supervisor: cannot read the heartbeat credential file ")
            + path
        )


struct BearerHeartbeatAuth(HeartbeatAuth):
    """`Authorization: Bearer <token>` on every heartbeat, the token from a
    file re-read per beat or from an environment variable read once (module
    header). Build it with `from_file` or `from_env`."""

    var _file: String
    var _held: Optional[SecretValue]

    def __init__(out self, var file: String, var held: Optional[SecretValue]):
        """Fieldwise; use `from_file` or `from_env`."""
        self._file = file^
        self._held = held^

    @staticmethod
    def from_file(path: String) raises -> BearerHeartbeatAuth:
        """The token is file `path`, read now (refusing an unusable one) and
        again for every heartbeat."""
        if path.byte_length() == 0:
            raise Error("job supervisor: the heartbeat credential file path is empty")
        var bytes = _read_token_file(path)
        _ = bearer_token_length(Span(bytes), String("the file ") + path)
        return BearerHeartbeatAuth(String(path), None)

    @staticmethod
    def from_env(name: String) raises -> BearerHeartbeatAuth:
        """The token is environment variable `name`, read once now; the
        variable is then removed from this process's environment, so the
        job never inherits it. Refuses a name outside
        `[A-Za-z_][A-Za-z0-9_]*`, an unset variable and an unusable value."""
        check_secret_env_name(name)
        var env = ProcessEnv()
        var found = env.lookup(name)
        if not found:
            raise Error(
                String("job supervisor: the heartbeat credential variable ")
                + name
                + String(" is not set")
            )
        var value = found.take()
        var n = bearer_token_length(
            value.revealed_bytes(), String("the variable ") + name
        )
        var token = SecretValue(value.revealed_bytes()[:n])
        try:
            _unset_env(name)
        except:
            raise Error(
                String("job supervisor: cannot remove ")
                + name
                + String(" from the environment")
            )
        if env.lookup(name):
            raise Error(
                String("job supervisor: ")
                + name
                + String(" is still in the environment after unsetenv")
            )
        return BearerHeartbeatAuth(String(""), Optional[SecretValue](token^))

    def reads_file_per_beat(self) -> Bool:
        """True iff the token is re-read from a file for every beat."""
        return self._file.byte_length() > 0

    def name(self) -> String:
        if self.reads_file_per_beat():
            return String("bearer-file")
        return String("bearer-env")

    def attaches_credential(self) -> Bool:
        return True

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        _ = method
        _ = url
        _ = len(body)
        var out = List[HeaderEntry]()
        if self.reads_file_per_beat():
            var bytes = _read_token_file(self._file)
            var n = bearer_token_length(Span(bytes), String("the file ") + self._file)
            out.append(_bearer_header(Span(bytes)[:n]))
            return out^
        if not self._held:
            raise Error("job supervisor: no heartbeat credential is held")
        ref held = self._held.value()
        out.append(_bearer_header(held.revealed_bytes()))
        return out^
