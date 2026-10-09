# =============================================================================
# komira_objectstore/local_fs_file_read.mojo
#   The errno-aware file reads behind LocalFsConditionalStore.
# =============================================================================
#
# THE RULE. Only ENOENT means "the object is absent" (the not_found (404) the
# manifest's `_is_not_found` classifier matches). Every other failure to open,
# size or read an object file raises an error naming the path, the failing
# call and the errno with its symbolic name, and that message carries none of
# the not-found needles (`not_found`, `NotFound`, `NoSuchKey`, `status=404`,
# `StoreError[NOT_FOUND]`) and no `precondition`.
#
# WHY ENOTDIR IS NOT "ABSENT". Keys are flat-encoded into ONE filename directly
# under the store root (`/` becomes `%2F`), so no object has a parent directory
# of its own that could legitimately be missing. ENOTDIR on `<root>/<name>` can
# only mean the root (or one of its ancestors) is not a directory: the store is
# misconfigured or its directory was replaced, which is the analog of S3's
# NoSuchBucket or a GCS bucket error, not of NoSuchKey. Reading it as absent is
# the silent data loss this module exists to prevent. ENOENT on a missing ROOT
# stays "absent": `list_with_delimiter` already treats a missing root as an
# empty store, and a get must agree with it.
#
# FFI-BOUNDARY: every call goes to `_objectstore_shim.c` (cxx_library
# `komira_objectstore_posix`), which reads errno immediately after the failing
# call and owns the errno constants and names. The shim allocates nothing. The
# fd from `komira_objstore_open_for_read` is owned by this module until the one
# `komira_objstore_read_exact_close` call, which closes it on every path. Every
# pointer passed is a local out-param or the local `List`'s buffer, valid for
# the synchronous call only; none is retained by C.
# =============================================================================

from std.ffi import external_call

# Mirrors KOMIRA_OBJSTORE_STAGE_* in _objectstore_shim.c (not platform values).
comptime _STAGE_OPEN: Int32 = 1
comptime _STAGE_FSTAT: Int32 = 2
comptime _STAGE_READ: Int32 = 3
comptime _STAGE_STAT: Int32 = 4
comptime _STAGE_WRITE: Int32 = 5
comptime _STAGE_FSYNC: Int32 = 6
comptime _STAGE_CLOSE: Int32 = 7
comptime _STAGE_LINK: Int32 = 8

# Mirrors KOMIRA_OBJSTORE_KIND_* in _objectstore_shim.c.
comptime _KIND_DIRECTORY: Int32 = 2


@always_inline
def _enoent() -> Int32:
    """The platform's ENOENT, from the C shim (never spelled in Mojo)."""
    return external_call["komira_objstore_enoent", Int32]()


@always_inline
def _eexist() -> Int32:
    """The platform's EEXIST, from the C shim (never spelled in Mojo)."""
    return external_call["komira_objstore_eexist", Int32]()


def _errno_name(e: Int32) -> String:
    """The symbolic name of errno `e` ("EACCES", ...), or "E?"."""
    var nb = Array[UInt8, 32](fill=UInt8(0))
    # SAFETY: `nb` is a stack-local 32-byte buffer that outlives the
    # synchronous call; the shim writes at most 32 bytes (NUL included) and
    # does not retain the pointer.
    var n = external_call["komira_objstore_errno_name", Int64](
        e, UnsafePointer(to=nb).bitcast[UInt8](), Int64(32)
    )
    var out = List[UInt8]()
    for i in range(Int(n)):
        out.append(nb[i])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _stage_name(stage: Int32) -> String:
    if stage == _STAGE_OPEN:
        return String("open")
    if stage == _STAGE_FSTAT:
        return String("fstat")
    if stage == _STAGE_READ:
        return String("read")
    if stage == _STAGE_WRITE:
        return String("write")
    if stage == _STAGE_FSYNC:
        return String("fsync")
    if stage == _STAGE_CLOSE:
        return String("close")
    if stage == _STAGE_LINK:
        return String("link")
    return String("stat")


def _io_error(path: String, stage: Int32, e: Int32) -> Error:
    """The non-not-found error for a failed `stage` on `path`."""
    return Error(
        "LocalFsConditionalStore: I/O error reading '" + path + "': "
        + _stage_name(stage) + " failed with errno " + String(Int(e)) + " ("
        + _errno_name(e) + ")"
    )


def _not_found(path: String) -> Error:
    return Error(
        "LocalFsConditionalStore: not_found (404) — no object file at '"
        + path + "'"
    )


def _read_whole_file(path: String) raises -> List[UInt8]:
    """Read the whole object file at `path`, byte-safe (interior NULs survive).

    Raises the not_found (404) error iff opening fails with ENOENT; raises a
    non-not-found error naming the path, the failing call and the errno for
    every other open, fstat or read failure, for a directory at `path`
    (EISDIR), and for a short read."""
    var p = path
    var fd = Int32(-1)
    var size = Int64(0)
    var stage = Int32(0)
    # SAFETY: `p` pins the NUL-terminated path; `fd`/`size`/`stage` are locals
    # the shim writes through during the synchronous call only.
    var rc = external_call["komira_objstore_open_for_read", Int32](
        p.as_c_string_slice().unsafe_ptr(),
        UnsafePointer(to=fd),
        UnsafePointer(to=size),
        UnsafePointer(to=stage),
    )
    if rc != 0:
        if stage == _STAGE_OPEN and rc == _enoent():
            raise _not_found(path)
        raise _io_error(path, stage, rc)
    var n = Int(size)
    var buf = List[UInt8]()
    if n > 0:
        buf.resize(n, UInt8(0))
    var got = Int64(0)
    # SAFETY: `buf` is a local List sized to `n`; the shim writes at most `n`
    # bytes into its buffer and closes `fd` (owned here since the open) on
    # every path. `got` is a local out-param. Nothing is retained by C.
    var rrc = external_call["komira_objstore_read_exact_close", Int32](
        fd, buf.unsafe_ptr(), Int64(n), UnsafePointer(to=got)
    )
    if rrc != 0:
        raise _io_error(path, _STAGE_READ, rrc)  # cov: unreachable read(2) on an open regular file fails only on a device fault
    if Int(got) != n:
        raise Error(
            "LocalFsConditionalStore: short read (" + String(Int(got)) + " < "
            + String(n) + ") for '" + path + "'"
        )
    return buf^


def _path_kind(path: String) raises -> Int32:
    """stat(2) `path`: 0 if it does not exist (ENOENT), else the shim's KIND_*
    value. Any other stat failure raises the non-not-found error."""
    var p = path
    var kind = Int32(0)
    # SAFETY: `p` pins the path; `kind` is a local out-param written during the
    # synchronous call only.
    var rc = external_call["komira_objstore_path_kind", Int32](
        p.as_c_string_slice().unsafe_ptr(), UnsafePointer(to=kind)
    )
    if rc != 0:
        if rc == _enoent():
            return Int32(0)
        raise _io_error(path, _STAGE_STAT, rc)
    return kind


def _object_file_present(path: String) raises -> Bool:
    """True iff something exists at `path` (a create there would collide);
    False iff it does not exist (ENOENT). Raises on any other failure: a path
    that cannot be checked is neither present nor absent."""
    return _path_kind(path) != Int32(0)


def _root_is_listable(root: String) raises -> Bool:
    """True iff `root` is an existing directory; False iff it does not exist
    (an empty store). Raises if it exists but is not a directory (ENOTDIR,
    named as such) or cannot be checked."""
    var kind = _path_kind(root)
    if kind == Int32(0):
        return False
    if kind != _KIND_DIRECTORY:
        raise Error(
            "LocalFsConditionalStore: I/O error listing '" + root
            + "': the store root is not a directory (ENOTDIR)"
        )
    return True


def _remove_object_file(path: String) raises:
    """remove(3) the object file at `path`. Success or ENOENT (already gone:
    an idempotent delete, S3 semantics) returns; any other errno raises
    `cannot remove '<path>': errno N (NAME)`, with no not-found needle."""
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call;
    # the shim keeps no pointer.
    var rc = external_call["komira_objstore_remove", Int32](
        p.as_c_string_slice().unsafe_ptr()
    )
    if rc == 0 or rc == _enoent():
        return
    raise Error(
        "LocalFsConditionalStore: cannot remove '" + path + "': errno "
        + String(Int(rc)) + " (" + _errno_name(rc) + ")"
    )
