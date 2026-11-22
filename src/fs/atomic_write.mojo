# =============================================================================
# fs/atomic_write.mojo
#   Write a whole local file, all or nothing.
# =============================================================================
#
# `write_file_atomic(path, data)` writes `data` to a temporary file in the
# destination's directory, named with a leading dot and a random suffix
# (`.<name>.<16 hex digits>.tmp`), syncs it, closes it, renames it over `path`
# and syncs the directory. A failure before the rename removes the temporary
# file and leaves `path` as it was (absent, or the old file whole). After the
# rename `path` is the whole new file, so a failed sync of the directory is not
# reported as a failed write: it only leaves the rename's durability to the
# file system. A crash
# can leave a temporary file behind, never a partial `path`. Because the new
# file replaces the old one only by the rename, a write may read the file it
# replaces until the rename.
#
# Errors name the step and the errno:
#   STORAGE_NOT_FOUND: write '<path>': the directory '<dir>' does not exist
#   STORAGE_IO: write '<path>': <step> failed: errno N (NAME)
# The parent directory is never created.
#
# FFI-BOUNDARY: every call goes to `_fs_shim.c` (cxx_library
# `komira_fs_posix`), which reads errno right after each failing call. The shim
# allocates nothing; every pointer passed is a local path, a local out-param
# or the caller's `data`, valid for the synchronous call only, and C retains
# none of them. The descriptor the shim opens is owned here and closed on every
# path before this function returns.
# =============================================================================

from std.ffi import external_call

from .local_fs_probe import _fs_enoent, _fs_errno_label

comptime STORAGE_NOT_FOUND = "STORAGE_NOT_FOUND"
"""The destination's directory does not exist."""

comptime STORAGE_IO = "STORAGE_IO"
"""A local write step failed (no space, a read-only file system, a directory
at the path, ...); the message names the step and the errno."""


def _random_hex() raises -> String:
    """Sixteen lowercase hex digits from the system's random source."""
    var v = UInt64(0)
    # SAFETY: `v` is a local out-param the shim writes during the synchronous
    # call only.
    var rc = external_call["komira_fs_random_u64", Int32](UnsafePointer(to=v))
    if rc != 0:
        raise Error(
            String(STORAGE_IO) + ": no random name for a temporary file: "
            + _fs_errno_label(rc)
        )
    var digits = String("0123456789abcdef").as_bytes()
    var out = String("")
    for i in range(16):
        var nibble = Int((v >> UInt64(60 - 4 * i)) & UInt64(15))
        out += chr(Int(digits[nibble]))
    return out^


def _split_path(path: String) -> Tuple[String, String, String]:
    """`path` as (the directory prefix up to and including the last `/`, the
    file name after it, the directory to sync): `a/b/c` is (`a/b/`, `c`,
    `a/b`), `/c` is (`/`, `c`, `/`) and `c` is (``, `c`, `.`)."""
    var slash = path.rfind(String("/"))
    if slash < 0:
        return (String(""), path, String("."))
    var dir = String(path[byte=0:slash]) if slash > 0 else String("/")
    return (
        String(path[byte = 0 : slash + 1]),
        String(path[byte = slash + 1 :]),
        dir^,
    )


def _remove(path: String):
    """Remove `path`, ignoring a failure: the caller is already reporting the
    failure that made the file unwanted."""
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call.
    _ = external_call["komira_fs_remove", Int32](p.as_c_string_slice().unsafe_ptr())


def _io_error(path: String, step: String, rc: Int32) -> Error:
    return Error(
        String(STORAGE_IO) + ": write '" + path + "': " + step + " failed: "
        + _fs_errno_label(rc)
    )


def _close(fd: Int32) -> Int32:
    return external_call["komira_fs_close_fd", Int32](fd)


def write_file_atomic(path: String, data: Span[UInt8, _]) raises:
    """Replace the file at `path` with `data`, all or nothing.

    `path` is used as written: a relative path resolves against the working
    directory. An existing file at `path` is replaced; its directory must
    exist.

    Raises:
        `STORAGE_NOT_FOUND` when the directory of `path` does not exist, and
        `STORAGE_IO` naming the step and the errno for any other failure. Before
        raising, the temporary file is removed and `path` is unchanged.
    """
    var parts = _split_path(path)
    var dir = parts[2]
    var tmp = parts[0] + "." + parts[1] + "." + _random_hex() + ".tmp"

    var fd = Int32(-1)
    # SAFETY: `tmp` pins the NUL-terminated path and `fd` is a local
    # out-param, both for the synchronous call only.
    var rc = external_call["komira_fs_create_exclusive", Int32](
        tmp.as_c_string_slice().unsafe_ptr(), UnsafePointer(to=fd)
    )
    if rc != 0:
        if rc == _fs_enoent():
            raise Error(
                String(STORAGE_NOT_FOUND) + ": write '" + path
                + "': the directory '" + dir + "' does not exist"
            )
        raise _io_error(path, "create of the temporary file", rc)

    # SAFETY: `data` is the caller's borrowed span, alive for this call; the
    # shim reads `len(data)` bytes from it and keeps no pointer.
    rc = external_call["komira_fs_write_all", Int32](
        fd, data.unsafe_ptr(), Int64(len(data))
    )
    var step = String("write")
    if rc == 0:
        rc = external_call["komira_fs_fsync_fd", Int32](fd)
        step = String("fsync")
    if rc != 0:
        _ = _close(fd)
        _remove(tmp)
        raise _io_error(path, step, rc)
    rc = _close(fd)
    if rc != 0:
        _remove(tmp)
        raise _io_error(path, "close", rc)

    var dst = path
    # SAFETY: `tmp` and `dst` pin the two NUL-terminated paths across the
    # synchronous call; the kernel copies them.
    rc = external_call["komira_fs_rename", Int32](
        tmp.as_c_string_slice().unsafe_ptr(), dst.as_c_string_slice().unsafe_ptr()
    )
    if rc != 0:
        _remove(tmp)
        raise _io_error(path, "rename", rc)

    # The new file is in place; the directory sync only makes the rename
    # durable, and its failure changes nothing a reader sees.
    # SAFETY: `dir` pins the NUL-terminated path across the synchronous call.
    _ = external_call["komira_fs_fsync_dir", Int32](
        dir.as_c_string_slice().unsafe_ptr()
    )
