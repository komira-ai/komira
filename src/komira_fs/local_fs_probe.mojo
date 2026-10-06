# =============================================================================
# komira_fs/local_fs_probe.mojo
#   errno-aware path probes behind LocalFs.
# =============================================================================
#
# THE RULE. Only ENOENT means "the path is not there". Every other failure to
# classify a path (ENOTDIR, ELOOP, EACCES, EIO, ENAMETOOLONG, ...) raises an
# error naming the path and the errno with its symbolic name. A probe that
# cannot check a path must not answer "absent": LocalFs.list would then list
# [] and LocalFs.delete would report success while the entry remains.
#
# FFI-BOUNDARY: every call goes to `_fs_shim.c` (cxx_library `komira_fs_posix`),
# which reads errno immediately after the failing stat/lstat and owns the
# errno constants and names, so no errno number is spelled in Mojo. The shim
# allocates nothing here; every pointer passed is a local out-param or local
# buffer valid for the synchronous call only, and C retains none of them.
# =============================================================================

from std.ffi import external_call

# Mirrors KOMIRA_FS_KIND_* in _fs_shim.c (not platform values).
comptime _KIND_DIRECTORY: Int32 = 2


@always_inline
def _fs_enoent() -> Int32:
    """The platform's ENOENT, from the C shim."""
    return external_call["komira_fs_enoent", Int32]()


def _fs_errno_label(e: Int32) -> String:
    """`errno N (NAME)` for errno `e` (NAME is "E?" if the shim has none)."""
    var nb = Array[UInt8, 32](fill=UInt8(0))
    # SAFETY: `nb` is a stack-local 32-byte buffer that outlives the
    # synchronous call; the shim writes at most 32 bytes (NUL included) and
    # does not retain the pointer.
    var n = external_call["komira_fs_errno_name", Int64](
        e, UnsafePointer(to=nb).bitcast[UInt8](), Int64(32)
    )
    var name = List[UInt8]()
    for i in range(Int(n)):
        name.append(nb[i])
    return (
        String("errno ") + String(Int(e)) + " ("
        + String(StringSlice(unsafe_from_utf8=Span(name))) + ")"
    )


def _local_fs_path_kind(path: String, follow: Bool) raises -> Int32:
    """stat(2) (`follow`) or lstat(2) `path`: 0 if it does not exist
    (ENOENT), else the shim's KIND_* value (1 regular file, 2 directory,
    3 other). Any other failure raises naming the path and the errno."""
    var p = path
    var kind = Int32(0)
    # SAFETY: `p` pins the NUL-terminated path; `kind` is a local out-param
    # written during the synchronous call only.
    var rc = external_call["komira_fs_path_kind", Int32](
        p.as_c_string_slice().unsafe_ptr(),
        Int32(1) if follow else Int32(0),
        UnsafePointer(to=kind),
    )
    if rc != 0:
        if rc == _fs_enoent():
            return Int32(0)
        raise Error(
            "LocalFs: cannot " + (String("stat") if follow else String("lstat"))
            + " '" + path + "': " + _fs_errno_label(rc)
        )
    return kind


def _local_fs_is_directory(path: String) raises -> Int:
    """1 if `path` is a directory (symlinks followed), 0 if it exists and is
    not a directory, -1 if it does not exist (ENOENT). Raises on any other
    failure (ENOTDIR, ELOOP, EACCES on a parent, ...)."""
    var kind = _local_fs_path_kind(path, True)
    if kind == Int32(0):
        return -1
    if kind == _KIND_DIRECTORY:
        return 1
    return 0


def _local_fs_path_exists(path: String) raises -> Bool:
    """True iff an entry exists at `path` itself (lstat: a symlink is the
    entry, as remove(3) sees it); False iff it does not (ENOENT). Raises on
    any other failure: a path that cannot be checked is not "gone"."""
    return _local_fs_path_kind(path, False) != Int32(0)
