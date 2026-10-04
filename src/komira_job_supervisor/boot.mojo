# =============================================================================
# komira_job_supervisor/boot.mojo: fetching the job binary before the spawn.
# =============================================================================
#
# With `--binary-key`, the supervisor GETs that key from the binary object
# store the embedding binary supplied (any komira_objectstore
# `ConditionalWriteStore`), verifies its SHA-256, writes it to
# `--binary-download-path` and makes it executable (0o755). A digest that
# does not match is refused BEFORE anything is written: a corrupted or
# substituted binary is never spawned.
#
# THE EXPECTED DIGEST is `--binary-sha256` when given; otherwise a 64-char
# lowercase-hex segment of the key, if the key has one (a content-addressed
# layout such as `<sha256>/binary`). A key with neither is fetched unverified.
#
# The bytes are an owned List[UInt8]; the file is written through
# komira_core's `RawWriteFd`. The one local FFI is `chmod(2)`, a fixed-arity
# libc call bounded inside `_chmod`. No pointer type crosses a boundary.
# =============================================================================

from std.ffi import external_call
from std.os import mkdir as _os_mkdir

from komira_core.io.posix_io import RawWriteFd
from komira_crypto.sha256 import sha256
from komira_crypto.hex import hex_lower_array_32
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_job_supervisor.job_supervisor_config import (
    JobSupervisorConfig,
    is_sha256_hex,
)

import komira_log as log
from komira_log import ArgStr, ArgI64


def expected_sha_from_key(key: String) -> Optional[String]:
    """The first 64-char lowercase-hex segment of `key` (split on '/'), or
    None."""
    var cur = String("")
    var bytes = key.as_bytes()
    for i in range(len(bytes) + 1):
        if i == len(bytes) or bytes[i] == UInt8(0x2F):
            if is_sha256_hex(cur):
                return Optional[String](cur)
            cur = String("")
        else:
            cur += chr(Int(bytes[i]))
    return None


def _chmod(path: String, mode: Int32) raises:
    """chmod(2) `path` to `mode`; raises on a non-zero return. `chmod` is
    fixed-arity (not variadic), so a direct external_call is ABI-safe."""
    var p = path
    # SAFETY: `as_c_string_slice()` is a NUL-terminated view of `p`'s buffer,
    # which this local keeps alive across the synchronous call; the kernel
    # copies the path and the pointer does not escape this function.
    var rc = external_call["chmod", Int32](
        p.as_c_string_slice().unsafe_ptr(), mode
    )
    if Int(rc) != 0:
        raise Error(
            String("job supervisor boot: chmod(")
            + path
            + String(") failed (rc=")
            + String(Int(rc))
            + String(")")
        )


def _mkdir_parents(path: String):
    """Create every parent directory of `path` that is missing (`mkdir -p` of
    the dirname). Failures are tolerated here: the write that follows reports
    a real one."""
    var b = path.as_bytes()
    var n = len(b)
    var SLASH = UInt8(ord("/"))
    var i = 1 if (n > 0 and b[0] == SLASH) else 0
    while i < n:
        if b[i] == SLASH:
            var prefix = String(StringSlice(unsafe_from_utf8=b[0:i]))
            if prefix.byte_length() > 0:
                # std.os's mkdir rather than a second external_call["mkdir"]:
                # two declarations of one symbol in a closure fail to legalize.
                try:
                    _os_mkdir(prefix, 0o755)
                except:
                    pass
        i += 1


def download_binary[
    S: ConditionalWriteStore,
](config: JobSupervisorConfig, store: S) raises -> String:
    """Fetch `config.binary_key` from `store`, verify, write to
    `config.binary_download_path`, chmod 0o755; return the path. Raises on any
    failure (no key, GET, digest mismatch, write, chmod)."""
    if not config.binary_key:
        raise Error("job supervisor boot: no --binary-key to download")
    var key = config.binary_key.value()
    var bytes = store.get(Path.parse(key))

    var expected: Optional[String]
    if config.binary_sha256:
        expected = Optional[String](config.binary_sha256.value())
    else:
        expected = expected_sha_from_key(key)
    if expected:
        var got = hex_lower_array_32(sha256(bytes))
        if got != expected.value():
            raise Error(
                String("job supervisor boot: SHA-256 mismatch for key ")
                + key
                + String(": expected ")
                + expected.value()
                + String(" got ")
                + got
                + String(" (refusing to spawn it)")
            )

    var path = config.binary_download_path
    _mkdir_parents(path)
    var fd = RawWriteFd.open_truncate(path)
    fd.write_bytes(bytes)
    fd.close()
    _chmod(path, Int32(0o755))

    log.info[
        "job supervisor boot: fetched {} bytes from key {} -> {}",
        "komira_job_supervisor",
    ](ArgI64(Int64(len(bytes))), ArgStr(key), ArgStr(path))
    return path
