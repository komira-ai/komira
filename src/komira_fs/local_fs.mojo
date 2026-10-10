# =============================================================================
# komira_fs.local_fs — LocalFile + LocalFs[S]
# =============================================================================
# `LocalFs[S]` is the local-POSIX-filesystem implementation of the
# `FileSystem` trait.
#
# `read_at` returns an `MmapAlignedBuffer[64]` borrowed from a lazily-opened
# mmap region (zero-copy on warm page cache):
#   * LocalFile carries `_mmap: Optional[ArcPointer[MmapRegion]]` — lazy
#     mmap state; None until first read_at; ArcPointer so the buffers
#     returned by read_at can outlive the LocalFile.
#   * LocalFs.read_at body: if `_mmap is None`, open the mmap and cache
#     the Arc on `file`; then call `MmapAlignedBuffer.borrow_from_mmap` to
#     produce a non-owning buffer aliasing the requested range.
#   * Open does no actual mmap (placeholder LocalFile) — so the
#     `read_footer` flow, which opens a separate fd, does not pay for an
#     8 MiB mmap just for the trailing 8-byte trailer.
#
# `read_whole` / `read_range` (below) use the same mmap-borrow pattern;
# `read_at` adds the `LocalFile`-keyed reuse of the mmap region across calls.
#
# The `[SinkType: WakerSink & Movable & Deinitable]` struct parameter is
# RETAINED even though the FileSystem trait no longer references `S`: many
# call sites construct `LocalFs[NoopSink]`. It is unused inside the struct
# but harmless.
#
# Pointer discipline:
#   * ZERO `UnsafePointer` in any public method signature.
#   * `LocalFile._fd: Int32` is a POSIX file descriptor scalar (no heap).
#   * `LocalFile._mmap: Optional[ArcPointer[MmapRegion]]` is the
#     compiler-tracked shared-ownership wrapper around the mmap region.
#     Not a byte-slab; the LocalFile is not stored in a wildcard-cast
#     container; the destroy-recreate hazard does not apply.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer

from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import (
    FooterRegion,
    speculative_tail_start,
)
# `ShallowDirEntry` is now defined in its own shared module so the cloud
# FS impls can reach it. Re-exported here so existing
# `from komira_fs.local_fs import ShallowDirEntry` callers are unbroken.
from komira_fs.local_fs_probe import (
    _fs_enoent,
    _fs_errno_label,
    _local_fs_is_directory,
)
from komira_fs.shallow_dir_entry import ShallowDirEntry
from komira_async.ops.waker_sink import WakerSink
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow_ipc.chunked_read import read_chunked, read_chunked_range
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_libc.posix_io import (
    RawWriteFd,
    IOV_MAX,
    fsync_path,
    fsync_dir,
)


# Prefetch depth for a local NVMe-backed file: shallow, because the device
# answers in microseconds and a deep queue only adds memory pressure. The other
# per-storage defaults (`PREFETCH_DEPTH_*`) live in
# `komira_async.sources.prefetch_source`.
comptime PREFETCH_DEPTH_LOCAL_NVME: Int = 4


# =============================================================================
# Local POSIX FFI helpers
# =============================================================================
# Used by `LocalFs.read_footer`, `LocalFs.is_dir`, `LocalFs.file_size`. Each
# helper is module-private and mirrors the shape used by
# `komira_parquet/file_reader.mojo`'s `_pread` / `_posix_open_fd` /
# `_posix_close_fd` (we cannot import those from there without a layering
# inversion — `komira_parquet` depends on `komira_fs`, not the other
# way around).
#
# FFI-BOUNDARY: POSIX fopen / fileno / pread / fseek / fclose / stat.
# SAFETY: each `external_call` is treated as opaque. Callers MUST close the
# returned fd via `_local_fs_close_fd` (matches `_posix_close_fd` in
# parquet's file_reader). The byte buffer used by `_local_fs_pread` is
# heap-owned by the caller (List[UInt8]); the unsafe pointer flows only
# from the caller's owned region.
# =============================================================================


def _local_fs_open_fp(var path: String) -> Int64:
    """Open `path` for read-only access; returns FILE* as Int64 address
    (0 on error). The C-stdio FILE* shape lets us call fseek + ftell
    + fileno on the same handle without bringing in lseek (which
    collides with a stdlib pre-declaration).
    """
    var c_path = path.as_c_string_slice().unsafe_ptr()
    var mode_str = String("rb")
    var c_mode = mode_str.as_c_string_slice().unsafe_ptr()
    return external_call["fopen", Int64](c_path, c_mode)


def _local_fs_close_fp(fp: Int64):
    """fclose(fp). Closes the underlying fd too."""
    _ = external_call["fclose", Int32](fp)


def _local_fs_file_size_via_fp(fp: Int64) -> Int:
    """File size via fseek(SEEK_END) + ftell. Returns -1 on error.
    Restores file position to 0 (SEEK_SET) via a second fseek so
    subsequent reads on the same FILE* see the start.
    """
    # SEEK_END = 2; SEEK_SET = 0.
    var rc = external_call["fseek", Int32](fp, Int64(0), Int32(2))
    if rc != 0:
        return -1
    var size = external_call["ftell", Int64](fp)
    if size < 0:
        return -1  # cov: unreachable fseek(SEEK_END) succeeded, so ftell cannot fail (64-bit off_t)
    var _restore = external_call["fseek", Int32](fp, Int64(0), Int32(0))
    return Int(size)


def _local_fs_fileno(fp: Int64) -> Int32:
    """Get the POSIX fd from a FILE*. Used for pread (lock-free
    random-access read). Note: closing the fd via close() ALSO
    invalidates the FILE*; callers MUST use fclose only — never close
    the fd separately."""
    return external_call["fileno", Int32](fp)


# `struct stat` is platform-dependent, so Mojo never parses it:
#   - is_dir / exists: `local_fs_probe.mojo` asks the C shim
#     (`komira_fs_path_kind`) for a kind or the errno; only ENOENT is absent.
#   - file_size: fopen+SEEK_END is robust on both OSes (matches the
#     ParquetFileReader.open shape).


def _local_fs_remove(path: String) -> Int32:
    """remove(3) `path` through the C shim. Returns 0 on success or the errno
    remove(3) failed with (read in C right after the call).

    FFI-BOUNDARY: `komira_fs_remove` in `_fs_shim.c`; it allocates nothing and
    keeps no pointer.
    """
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call;
    # the kernel copies it and the pointer does not escape.
    return external_call["komira_fs_remove", Int32](
        p.as_c_string_slice().unsafe_ptr()
    )


def _local_fs_list_recursive(var root: String) raises -> List[String]:
    """Recursively walk `root`, returning the absolute path of every regular
    file under it (at any depth), with symlinks SKIPPED (cycle-safe).

    Delegates the platform-fragile `dirent` / `stat`
    parsing + the recursion to the `komira_walk_dir_recursive` C shim
    (`komira_async/reactor/_posix_shim.c`). The shim does an `lstat`-based
    classification that never dereferences symlinks (so a symlinked directory
    is neither emitted nor traversed — DuckDB's no-follow-symlink semantics),
    making the walk acyclic by construction.

    The shim hands back a single heap buffer of NUL-separated paths + a total
    length; we copy each path into an owned `List[String]` and `komira_free`
    the buffer. NO struct-offset arithmetic or pointer walking happens in
    Mojo (encapsulation rule) — the only pointers here are the FFI
    out-param slots, confined to this helper body.

    SAFETY: `out_buf` / `out_len` are stack-local out-param slots the kernel
    shim writes through; the malloc'd buffer's ownership transfers to this
    frame and is freed via `komira_free` before return. The buffer pointer
    never escapes this function; callers receive only owned `String`s.

    Args:
        root: the directory to walk (an existing directory path).

    Returns:
        Owned absolute file paths under `root` (UNSORTED; the caller — the
        discovery layer — sorts lexically).

    Returns an EMPTY list iff `root` itself does not exist (ENOENT).

    Raises:
        On any other failure, naming the path that failed and its errno: an
        opendir / readdir / lstat failure of the root OR of any entry below it
        (an unreadable subdirectory is NOT skipped; skipping it would drop its
        files from the listing silently), or an allocation failure (ENOMEM).
        An entry removed mid-walk (ENOENT below the root) is skipped.
    """
    # Out-param slots for the C shim: an 8-byte slot for the `char*` buffer
    # pointer and an 8-byte slot for the `unsigned long` length. We hold them
    # in stack-local InlineArrays (the mmap_region.mojo:260 FFI pattern) so
    # their addresses are stable across the synchronous call and no
    # wildcard-origin local pointer is needed.
    var buf_slot = Array[UInt8, 8](fill=UInt8(0))
    var len_slot = Array[UInt8, 8](fill=UInt8(0))
    var err_path = Array[UInt8, 4096](fill=UInt8(0))
    var c_root = root.as_c_string_slice().unsafe_ptr()
    # SAFETY: buf_slot / len_slot are stack-local and outlive the syscall (the
    # shim writes-only and returns before this frame destroys them). The
    # malloc'd buffer's ownership transfers to this frame and is freed via
    # `komira_free` below. `c_root` is NUL-terminated and held alive by the
    # `var root` parameter across the call. Single-syscall FFI carve-out.
    var buf_pp = UnsafePointer(to=buf_slot).bitcast[UInt8]()
    var len_pp = UnsafePointer(to=len_slot).bitcast[UInt8]()
    # SAFETY: `err_path` is a stack-local 4096-byte buffer the shim writes a
    # NUL-terminated (truncated) failing path into; it outlives the call.
    var err_pp = UnsafePointer(to=err_path).bitcast[UInt8]()
    var rc = external_call["komira_walk_dir_recursive", Int32](
        c_root, buf_pp, len_pp, err_pp, UInt64(4096),
    )
    if Int(rc) != 0:
        if rc == _fs_enoent():
            # ENOENT is only reported for the ROOT (the shim skips entries
            # removed mid-walk): the root does not exist -> nothing to list.
            return List[String]()
        var failed = List[UInt8]()
        var k = 0
        while k < 4095 and err_path[k] != UInt8(0):
            failed.append(err_path[k])
            k += 1
        raise Error(
            "LocalFs.list: recursive walk of '" + root + "' failed at '"
            + String(StringSlice(unsafe_from_utf8=Span(failed))) + "': "
            + _fs_errno_label(rc)
        )
    # Read the written buffer pointer + length back out of the slots. The
    # buffer is a malloc'd `char*` returned by the C shim — its address is an
    # FFI-returned value, held as a LOCAL with a concrete origin (never a
    # field); ownership transfers to this frame and is released via `komira_free`.
    # SAFETY: `out_buf` is the malloc'd buffer the shim wrote into `buf_slot`.
    # It is typed with the CONCRETE origin of `buf_slot` (never a wildcard
    # origin), so `buf_slot` is kept alive until the last use of `out_buf`,
    # which is the `komira_free` call below; the pointer is a local that never
    # leaves this function.
    var out_buf = buf_pp.bitcast[
        UnsafePointer[UInt8, origin_of(buf_slot)]
    ]()[0]
    var out_len = len_pp.bitcast[Int64]()[0]
    var paths = List[String]()
    var n = Int(out_len)
    var i = 0
    while i < n:
        # Each path is NUL-terminated; scan to the next NUL.
        var start = i
        while i < n and out_buf[i] != UInt8(0):
            i += 1
        # Build the String from the [start, i) byte run, BYTE-EXACTLY.
        #
        # ⛔ DO NOT REWRITE THIS AS `s += chr(Int(out_buf[j]))`. That was
        # this loop's body until 2026-09-07 and it is a SILENT WRONG ANSWER on
        # any non-ASCII path. `chr` maps a CODE POINT to its UTF-8 ENCODING, so
        # a stored byte >= 0x80 is not reproduced but RE-ENCODED into two:
        # readdir's `city=Zürich` (... 5A C3 BC ...) came back as
        # `city=ZÃ¼rich` (... 5A C3 83 C2 BC ...). This is the readdir
        # decode, so the corrupted string is a PATH -- and a re-encoded path
        # DOES NOT EXIST ON DISK, so every downstream open fails; feeding it to
        # `hive_partition_parser` also mojibakes the partition VALUE, which
        # `partition_prune_scans._value_satisfies` then compares byte-wise
        # against the user's (correct) predicate literal -> no path matches ->
        # the Filter is rewritten to literal FALSE -> EMPTY RESULT SET.
        # ASCII is the corruption's fixed point, which is why the all-ASCII
        # bench corpus never saw it.
        var name_bytes = List[UInt8]()
        for j in range(start, i):
            name_bytes.append(out_buf[j])
        # `StringSlice(unsafe_from_utf8=)` is the in-tree byte-exact spelling
        # (`komira_arrow/string_column_view.mojo:145`) -- and it is
        # LENGTH-EXPLICIT, unlike `String(unsafe_from_utf8_ptr=)`, which stops
        # at the first NUL.
        paths.append(String(StringSlice(unsafe_from_utf8=Span(name_bytes))))
        i += 1  # skip the NUL separator
    # Free the shim's heap buffer (ownership transferred to this frame).
    _ = external_call["komira_free", Int32](out_buf)
    return paths^


def _local_fs_list_dir_shallow(var dir: String) raises -> List[ShallowDirEntry]:
    """Shallow (one-level) listing of `dir`'s immediate children via the
    `komira_list_dir_shallow` C shim —'s partition-schema probe.

    NOT recursive: the whole point of lazy Hive discovery is that we never
    enumerate the leaf data files at plan-BUILD. Each child is returned with
    a directory/file flag so the level-walk can find `key=value` partition
    subdirectories without descending into the data leaves.

    The shim hands back a single heap buffer of records, each `<tag><name>\\0`
    where `<tag>` is 'D' (subdirectory) or 'F' (regular file). We copy each
    record into an owned `ShallowDirEntry` and `komira_free` the buffer. NO
    struct-offset arithmetic happens in Mojo (encapsulation rule); the only
    pointers are the FFI out-param slots, confined to this helper body.

    A non-existent `dir` (ENOENT) yields an EMPTY list. Every other failure
    (opendir / readdir / lstat errno, ENOMEM) RAISES naming `dir` and the
    errno: a directory that exists but cannot be read is not empty.

    SAFETY: `buf_slot` / `len_slot` are stack-local out-param slots the shim
    writes through; the malloc'd buffer's ownership transfers to this frame and
    is freed via `komira_free` before return. The buffer pointer never escapes;
    callers receive only owned `ShallowDirEntry`s. Single-syscall FFI carve-out
    (same pattern as `_local_fs_list_recursive`).
    """
    var buf_slot = Array[UInt8, 8](fill=UInt8(0))
    var len_slot = Array[UInt8, 8](fill=UInt8(0))
    var c_dir = dir.as_c_string_slice().unsafe_ptr()
    # SAFETY: out-param slots outlive the synchronous syscall; the shim is
    # write-only and returns before this frame destroys them. `c_dir` is held
    # alive by the `var dir` parameter across the call.
    var buf_pp = UnsafePointer(to=buf_slot).bitcast[UInt8]()
    var len_pp = UnsafePointer(to=len_slot).bitcast[UInt8]()
    var rc = external_call["komira_list_dir_shallow", Int32](
        c_dir, buf_pp, len_pp,
    )
    if Int(rc) != 0:
        if rc == _fs_enoent():
            return List[ShallowDirEntry]()
        raise Error(
            "LocalFs.list_dir_shallow: listing '" + dir + "' failed: "
            + _fs_errno_label(rc)
        )
    # SAFETY: `out_buf` is the malloc'd buffer the shim wrote into `buf_slot`.
    # It is typed with the CONCRETE origin of `buf_slot` (never a wildcard
    # origin), so `buf_slot` is kept alive until the last use of `out_buf`,
    # which is the `komira_free` call below; the pointer is a local that never
    # leaves this function.
    var out_buf = buf_pp.bitcast[
        UnsafePointer[UInt8, origin_of(buf_slot)]
    ]()[0]
    var out_len = len_pp.bitcast[Int64]()[0]
    var entries = List[ShallowDirEntry]()
    var n = Int(out_len)
    var i = 0
    while i < n:
        # Each record is `<tag><name>\0`; the first byte is the type tag.
        var tag = out_buf[i]
        i += 1
        var start = i
        while i < n and out_buf[i] != UInt8(0):
            i += 1
        # BYTE-EXACT decode of the record's `<name>` run. ⛔ NOT
        # `chr(Int(out_buf[j]))` -- see the note in `_local_fs_list_recursive`:
        # `chr` RE-ENCODES every byte >= 0x80 into two, so a non-ASCII
        # partition directory (`city=Zürich`, `country=Österreich`,
        # `city=東京`) comes back as a path that does not exist on disk.
        # This is the shallow probe, reached in production from
        # the engine's scan setup.
        var name_bytes = List[UInt8]()
        for j in range(start, i):
            name_bytes.append(out_buf[j])
        entries.append(
            ShallowDirEntry(
                name=String(StringSlice(unsafe_from_utf8=Span(name_bytes))),
                is_dir=(tag == UInt8(ord("D"))),
            )
        )
        i += 1  # skip the NUL separator
    _ = external_call["komira_free", Int32](out_buf)
    return entries^


def _local_fs_pread(
    fd: Int32,
    buf: UnsafePointer[UInt8, _],
    count: Int,
    offset: Int,
) -> Int:
    """POSIX pread(2). Mirrors `komira_parquet.file_reader._pread`.

    SAFETY: caller owns the destination buffer (capacity >= count). `_pread`
    only writes; it does not retain the pointer. Wildcard origin on `buf`
    matches the parquet helper's signature. This helper is module-private
    and only consumed by `LocalFs.read_footer`, where the buffer is a
    freshly-allocated `List[UInt8]` whose ownership trivially encloses
    the call.
    """
    return Int(
        external_call["pread", Int64](
            fd, buf, Int64(count), Int64(offset)
        )
    )


# =============================================================================
# LocalFile — POSIX file handle + lazy mmap state
# =============================================================================
#
# Post shape:
#   * `_fd: Int32` — POSIX file descriptor (placeholder; -1 until the
#     `read_footer` / `file_size` path opens its own fd via fopen).
#   * `_path: String` — file path; consumed by `LocalFs.read_at` to
#     open the mmap region on first call.
#   * `_mmap: Optional[ArcPointer[MmapRegion]]` — lazy mmap state.
#     None until the first `read_at`; populated thereafter. ArcPointer
#     so the AlignedBuffers returned by `read_at` can outlive this
#     LocalFile (the buffer's `_keepalive` holds a refcount).
#
# Movable + Deinitable. Drop: the Optional drops, which
# drops the Arc; if the buffers returned by read_at have all dropped
# too, the refcount hits zero and `munmap(2)` fires.
#
# Destroy-recreate audit: LocalFile is NOT stored in
# a byte-slab or wildcard-cast container; it flows by-value through the
# trait method. The heap-owning inner type is `Optional[ArcPointer<T>]`,
# which is the canonical compiler-tracked shared-ownership wrapper.
# `MmapRegion` itself is Movable; its OWNING wildcard-origin field is
# documented at `mmap_region.mojo:173-203` as the FFI-boundary
# carve-out for kernel-managed mmap'd pages (NOT tcmalloc heap; destroy-recreate
# does not apply per the kernel-mmap rationale at :194-196).
# =============================================================================


@fieldwise_init
struct LocalFile(Movable, Deinitable):
    """POSIX file handle + lazy-mmap state.

    Field set:
      var _fd: Int32                              # POSIX fd (or -1 placeholder)
      var _path: String                           # file path; mmap open uses this
      var _mmap: Optional[ArcPointer[MmapRegion]] # lazy mmap state

    The `_fd` is not used by's `read_at` path (the mmap path
    opens its own fd inside `MmapRegion.open_readonly` and closes it
    before returning the region). Reserved for future direct-pread
    code paths (e.g. footer reads that don't want to mmap an 8 MiB
    region for an 8-byte trailer).

    Drop semantics: the `Optional[ArcPointer[MmapRegion]]` drops with
    the LocalFile; the Arc refcount decrements. If buffers returned by
    `read_at` have all dropped, the refcount hits zero and the kernel
    `munmap`s the region via `MmapRegion.__del__`. If buffers are still
    alive, the mmap survives until they drop too.
    """

    var _fd: Int32
    var _path: String
    var _mmap: Optional[ArcPointer[MmapRegion]]

    @staticmethod
    def placeholder(path: String) -> LocalFile:
        """Construct a placeholder LocalFile with fd=-1 and no mmap
        cached. `LocalFs.open` builds via this; the mmap fires lazily
        on the first `read_at`."""
        return LocalFile(
            _fd=Int32(-1),
            _path=path,
            _mmap=Optional[ArcPointer[MmapRegion]](None),
        )

    @always_inline
    def fd(self) -> Int32:
        """Returns the POSIX fd. -1 for a placeholder LocalFile (the
        mmap path opens its own fd internally and does not populate
        this field)."""
        return self._fd

    def path(self) -> String:
        """Returns the file path (used by `LocalFs.read_at` to open the
        mmap on first call)."""
        return self._path

    @always_inline
    def is_mmap_cached(self) -> Bool:
        """True iff the lazy mmap has been opened (set by the first
        `LocalFs.read_at` call). Useful for tests that want to observe
        the lazy-vs-eager semantics; production callers do not need
        to check this."""
        return self._mmap.__bool__()


# =============================================================================
# LocalWriteFile — POSIX write handle wrapping RawWriteFd
# =============================================================================
#
#
#
# Field set:
#   var _fd: RawWriteFd     # owning fd handle (idempotent close on drop)
#   var _path: String       # source path; surfaced in error messages
#   var _cursor: Int64      # logical write position; advanced by write_at
#
# `_fd: RawWriteFd` is the owning POSIX-fd primitive from
# `komira_libc/posix_io.mojo`. Its `__del__` calls `close(2)` if the
# fd is still open (idempotent; `close_write` consumes the LocalWriteFile
# and closes explicitly first, so the destructor on the consumed-into
# parameter sees a sentinel fd).
#
# `_cursor` mirrors the kernel's per-fd file-offset pointer. We advance
# it userspace-side so `write_at` can chunk the payload at 64 MiB
# (`chunked_write` workaround) by issuing the per-chunk `write(2)` and
# tracking how much landed. The kernel also advances its own offset for
# each successful `write(2)`; the two should remain in sync as long as
# no caller mixes `pwrite_at` (which does NOT advance the kernel
# pointer) with `write_at` on the same handle.
#
# Destroy-recreate audit: LocalWriteFile is NOT
# stored in a byte-slab or wildcard-cast container; it flows by value
# through the trait method. `RawWriteFd` itself has a single `_fd: Int32`
# field (POD); `_path: String` is heap-owning but tracked by the standard
# compiler ASAP-destruction path (no wildcard cast, no MutExternalOrigin).
# =============================================================================


struct LocalWriteFile(Movable, Deinitable):
    """POSIX write handle wrapping a `RawWriteFd`.

    Field set:
      var _fd: RawWriteFd     # owning fd handle (close-on-drop)
      var _path: String       # source path; surfaced in error messages
      var _cursor: Int64      # logical write position (write_at-advanced)

    Constructed via `LocalFs.open_write(path, mode)`. Drop closes the
    fd via `RawWriteFd.__del__` (idempotent). For explicit
    flush-and-close semantics, use `LocalFs.close_write(file^)` which
    consumes the handle and closes the fd before drop sees it (the
    destructor on the consumed-into-local sees a sentinel fd).
    """

    var _fd: RawWriteFd
    var _path: String
    var _cursor: Int64

    def __init__(out self, var fd: RawWriteFd, path: String):
        """Construct with an opened RawWriteFd. The cursor starts at 0
        for CREATE_TRUNCATE / CREATE_EXCLUSIVE modes; for APPEND mode,
        the cursor is advisory only (the kernel positions each write at
        EOF atomically) but we still initialize to 0 for diagnostic
        consistency."""
        self._fd = fd^
        self._path = path
        self._cursor = Int64(0)

    @always_inline
    def cursor(self) -> Int64:
        """Returns the current logical write position. Test-only
        observer; production callers don't need to consult this."""
        return self._cursor

    @always_inline
    def path(self) -> String:
        """Returns the source path (for error messages / diagnostics)."""
        return self._path

    @always_inline
    def is_closed(self) -> Bool:
        """True iff the underlying fd has been closed."""
        return self._fd.is_closed()

    def seek_to_end(mut self) raises -> Int64:
        """`lseek(fd, 0, SEEK_END)` — re-sync this fd's kernel file-offset
        pointer to the current inode EOF, returning the new offset.

        Load-bearing for the StreamingParquetWriter's parallel-pwrite
        commit (`_commit_row_groups_parallel_pwrite`): after the per-page
        parallel
        `pwrite_at` fan-out (which does NOT advance the kernel offset),
        the writer re-syncs the handle to EOF so the subsequent
        cursor-advancing `write_at` (the footer / trailer) appends at the
        correct position instead of clobbering the pwritten page bytes.

        Delegates to `RawWriteFd.seek_to_end`. Raises on closed fd /
        lseek(2) failure.
        """
        return Int64(self._fd.seek_to_end())

    def ftruncate_size(mut self, length: Int) raises:
        """Extend (or truncate) the underlying file to `length` bytes via
        POSIX ftruncate(2).

        Load-bearing for the JSONL parallel-pwrite writer in
        the file sink: pre-allocates the inode to the new
        EOF before launching the parallel pwrite_at workers so APFS can
        resolve all inode-extension work in one syscall instead of N
        concurrent extensions racing on the inode's size field. Reduces
        fs-level lock contention + smooths per-pwrite latency variance
        on M-series macOS.

        Method on LocalWriteFile (not LocalFs) because ftruncate is a
        per-fd operation mutating the file size — matches the
        `pwrite_at` shape where `LocalFs.pwrite_at(file, offset,
        data)` takes the file by value.

        Encapsulation: keeps the encapsulation rule satisfied
        (file_sink no longer reaches into LocalWriteFile._fd; it calls
        this typed method instead).

        Raises on: closed fd; negative length; ftruncate(2) failure.
        """
        self._fd.ftruncate_size(length)


# =============================================================================
# Internal helper — chunked write absorbing the >2 GB stdlib workaround
# =============================================================================
# The Mojo 1.0.0b1 stdlib `FileHandle.write(s)` silently flushes 0 bytes
# for `len(s) > ~2 GB` (Int32 overflow in the underlying write(2) count
# argument). The canonical workaround is to chunk every write at 64 MiB
# (`komira_libc.chunked_write.write_chunked`). For the FileSystem
# trait surface, we absorb that workaround INSIDE `LocalFs.write_at`
# so codec writers stop importing `chunked_write` directly.
#
# This helper uses `RawWriteFd.write_bytes` (POSIX write(2) via the
# `komira_write_bytes` shim) — NOT `FileHandle.write`. RawWriteFd's
# `write_bytes` already uses UInt64 byte counts internally (not Int32),
# so on most systems a single write would be fine. The chunking is
# defense-in-depth + page-cache-friendly batch size + bounded-failure
# localization (matches `chunked_write` rationale at lines 24-33).
# =============================================================================


# 64 MiB chunk size. Mirrors `komira_libc.chunked_write.CHUNK_BYTES`;
# we redeclare locally to avoid pulling chunked_write's `FileHandle`-based
# helpers into the LocalFs trait conformance path.
comptime _LOCAL_FS_WRITE_CHUNK_BYTES: Int = 64 * 1024 * 1024


def _local_fs_write_chunked(
    mut fd: RawWriteFd, data: Span[UInt8, _]
) raises -> Int64:
    """Write `data` to `fd` in chunks of at most `_LOCAL_FS_WRITE_CHUNK_BYTES`
    via `RawWriteFd.write_bytes` (POSIX write(2)). Returns total bytes
    written.

    Empty input is a no-op (returns 0). Single-chunk input (≤ 64 MiB)
    takes the single-write fast path.

    SAFETY: takes a borrowed Span (origin inferred per call site). The
    internal `Span(ptr=..., length=...)` reconstruction for sub-chunks
    is confined to this fn body and does not cross a module boundary.
    """
    var n = len(data)
    if n == 0:
        return Int64(0)
    if n <= _LOCAL_FS_WRITE_CHUNK_BYTES:
        # Fast path: single write for sub-chunk payloads (the common case).
        fd.write_bytes(data)
        return Int64(n)
    # Slow path: chunk every 64 MiB.
    var off = 0
    while off < n:
        var end = off + _LOCAL_FS_WRITE_CHUNK_BYTES
        if end > n:
            end = n
        var chunk_len = end - off
        var chunk = Span(
            unsafe_ptr=data.unsafe_ptr() + off, length=chunk_len
        )
        fd.write_bytes(chunk)
        off = end
    return Int64(n)


# =============================================================================
# LocalFs[S] — FileSystem implementation for local POSIX filesystem
# =============================================================================
#
# Parametric over `S: WakerSink & Movable & Deinitable` so
# that LocalFs can be instantiated against any sink shape (`NoopSink`,
# `ThreadWaker`, `FdWaker`). The `alias S = Self.SinkType` binds the
# trait's `S` associated type to the struct's `SinkType` parameter at
# conformance time.
#
# `alias File = LocalFile` binds the trait's `File` associated type.
#
# Fields:
#   var _root: String   — diagnostic / future virtual-root scope
#
# Possible later fields:
#   var _open_files: Slab[LocalFile]  — pooled fd reuse
#   var _io_queue_depth: Int          — per-fs depth override
# =============================================================================


@fieldwise_init
struct LocalFs[
    SinkType: WakerSink & Movable & Deinitable,
](FileSystem, Movable, Deinitable):
    """Local POSIX filesystem `FileSystem` impl.

    Parametric over `SinkType: WakerSink` so callers can compose with
    NoopSink (synthetic IoOps; tests + in-process operators) or
    ThreadWaker / FdWaker (production worker integration).

    Trait conformance:
      comptime File = LocalFile
      comptime S = Self.SinkType

    Bodies:
      * `list` — returns empty List[String]
      * `open` — returns LocalFile.placeholder(path)
      * `read_at` — returns IoOp.synthetic_ready(value=length, op_id=0)
      * `prefetch_depth` — PREFETCH_DEPTH_LOCAL_NVME (= 4)
      * `supports_random_read` — True
    """

    comptime File = LocalFile
    comptime S = Self.SinkType
    # Override the FileSystem trait's `IS_MMAP_BACKED = False` default to
    # advertise that LocalFs exposes a kernel-mmap'd zero-copy substrate.
    # Consumers (e.g. `ParquetFileReader._Impl[FS]` pImpl in''-β)
    # branch on this at comptime to pick `borrow_from_mmap` over
    # `fs.read_at(file, ...)`.
    comptime IS_MMAP_BACKED: Bool = True

    # LocalFs has the working `list_dir_shallow` +
    # recursive `list` that PrunedHiveDiscovery.open_pruned prunes over (the
    # v1 lazy Hive path was validated on local) — admit it for the
    # lazy Hive dir-scan re-route.
    comptime SUPPORTS_LAZY_HIVE: Bool = True

    # ----
    # Bind the trait's WriteFile alias to LocalWriteFile (declared above;
    # wraps RawWriteFd from `komira_libc.posix_io`).
    comptime WriteFile = LocalWriteFile
    # POSIX pwrite(2) is atomic for disjoint ranges on a regular file —
    # advertise that disjoint-range concurrent writes are safe.
    # Load-bearing for the JSONL parallel-pwrite writer's
    # `@parameter if FS.SUPPORTS_PARALLEL_WRITES` branch.
    comptime SUPPORTS_PARALLEL_WRITES: Bool = True

    var _root: String

    @staticmethod
    def new() -> LocalFs[Self.SinkType]:
        """Default-construct with empty root."""
        return LocalFs[Self.SinkType](_root=String(""))

    @staticmethod
    def from_root(root: String) -> LocalFs[Self.SinkType]:
        """Construct with an explicit virtual root (diagnostic / future
        sandboxing — the root is not enforced)."""
        return LocalFs[Self.SinkType](_root=root)

    # -----α — clone() for multi-file factory loops ----
    def clone(self) -> Self:
        """Return a fresh LocalFs[SinkType] with the same `_root` field.
        Cheap: a single `String.copy()`; no heap-shared state, no atomic
        ops. The SinkType parameter propagates unchanged.

        Per trait contract — `ParquetReaderFactory.open[FS]` consumes
        the FS via move; the factory needs `clone()` to open multiple
        files from one configured LocalFs.
        """
        return LocalFs[Self.SinkType](_root=self._root.copy())

    # ---- Sync metadata ops ----
    def list(self, prefix: String) raises -> List[String]:
        """List files under `prefix` (RECURSIVE — every regular file at any
        depth), returning absolute paths. Symlinks are SKIPPED (cycle-safe).

        This is a real recursive directory walk via the
        `komira_walk_dir_recursive` C shim (encapsulated in
        `_local_fs_list_recursive`).

        RECURSIVE is the right contract for two reasons: (1) a bare
        directory spec auto-globs to recursive (every file under the tree);
        (2) a glob's static prefix (`dir/**/*.parquet` -> static prefix
        `dir/`) is handed here and the discovery layer's client-side
        `glob_match_path` does the precise per-segment filtering — so a
        recursive (superset) listing is always correct, and the
        `FileSystem.list` trait surface carries no recursive flag to express
        the shallow optimization.

        Paths to `prefix`-as-a-directory are walked. If `prefix` is NOT an
        existing directory (e.g. a non-existent path, or a partial key
        prefix), an EMPTY list is returned — consistent with the object-store
        `S3Fs.list` "prefix matched nothing" behavior. (A glob whose static
        prefix is a strict sub-path of a real directory is not the v1 shape:
        `split_static_prefix` yields the directory portion up to the first
        metachar, which is a directory in the layouts v1 supports.)

        Raises:
            If `prefix` cannot be checked (any stat errno but ENOENT, e.g.
            ENOTDIR, ELOOP, EACCES on a parent) or the walk fails (see
            `_local_fs_list_recursive`), naming the path and the errno.
        """
        # Only walk if `prefix` names an existing directory (stat probe). A
        # missing (ENOENT) or non-directory prefix yields []; any other probe
        # failure raises.
        if _local_fs_is_directory(prefix.copy()) != 1:
            return List[String]()
        return _local_fs_list_recursive(prefix.copy())

    def list_dir_shallow(self, dir: String) raises -> List[ShallowDirEntry]:
        """SHALLOW (one-level) listing of `dir`'s immediate children —
        partition-schema probe. NOT recursive: returns only the direct children
        (each tagged dir vs file), never descending into the data leaves. A
        non-directory / non-existent (ENOENT) `dir` yields an empty list; any
        other failure raises naming the path and the errno. See
        `_local_fs_list_dir_shallow`."""
        if _local_fs_is_directory(dir) != 1:
            return List[ShallowDirEntry]()
        return _local_fs_list_dir_shallow(dir)

    def open(self, path: String) raises -> Self.File:
        """Returns LocalFile.placeholder(path) (no fd is opened yet).
        A later step may open(2) with O_RDONLY | O_NOATIME here.

       ''-β change: `self` is now non-mut (was `mut self`).
        Body is purely value-constructive — does not mutate LocalFs
        state. The mut requirement was vestigial and blocked the
        non-mut `read_bytes(self)` path in `ParquetFileReader._Impl`.
        """
        return LocalFile.placeholder(path)

    # ---- Sync byte ops (buffer-returning) ----
    def read_at(
        self,
        mut file: Self.File,
        offset: Int64,
        length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read `length` bytes from `offset` in `file` via mmap-borrow.

        Body:
          1. If `file._mmap is None`, open the mmap via
             `MmapRegion.open_readonly(file._path)` and cache the Arc
             on `file`. This is the lazy-mmap step: open() does NOT
             mmap, so the first read_at pays for it (and only it; later
             reads on the same file reuse the cached mmap).
          2. Bounds check: `offset + length <= region.len()`. Out of
             bounds raises (the `borrow_from_mmap` debug_assert is
             release-elided, so we surface explicitly here).
          3. Borrow a non-owning MmapAlignedBuffer aliasing
             `[offset, offset+length)` of the mmap region. The Arc is
             copied (refcount bump); the buffer's `_keepalive` holds
             one count, the LocalFile's Optional holds the other.

        Returned buffer is non-owning (`is_owned() == False`;
        `is_mmap_backed() == True`). The bytes alias kernel-managed
        read-only pages; mutations through the buffer are UB at the
        kernel level (SIGBUS on PROT_READ). The mutating MmapAlignedBuffer
        APIs (reserve / set_typed etc.) debug-raise on borrowed buffers.

        SAFETY (per `mmap_aligned_buffer.mojo:435-447` + `mmap_region.mojo:173-203`):
          * The mmap'd bytes have a lifetime tracked by the Arc on
            `MmapRegion`. The buffer holds one Arc refcount; the
            LocalFile holds another. Last-Arc-drop fires `munmap(2)`
            via `MmapRegion.__del__`. The buffer cannot outlive the
            mmap because it holds a refcount.
          * No tcmalloc heap is touched: mmap pages are kernel-managed,
            so the destroy-recreate hazard (struct-destroy + tcmalloc reuse) does
            not apply (`mmap_region.mojo:194-196`).
          * The MutExternalOrigin on the buffer's `_ptr` is the
            documented FFI-boundary carve-out for kernel-returned mmap
            addresses; the field is owned by `MmapRegion`, not exposed
            as a wildcard at the trait surface (the pointer rules).

        Raises:
          * MmapRegion open failures: file not found, permissions,
            address-space exhaustion.
          * Out of bounds: `offset + length > file_size`.
        """
        # Lazy mmap on first read. `__bool__` on Optional returns True
        # iff populated; the first call populates, subsequent calls
        # short-circuit and reuse the cached Arc.
        if not file._mmap.__bool__():
            var region = MmapRegion.open_readonly(file._path)
            file._mmap = Optional[ArcPointer[MmapRegion]](
                ArcPointer[MmapRegion](region^)
            )
        # Explicit bounds check (release-build robust; the
        # borrow_from_mmap debug_assert is elided in release).
        var region_len = file._mmap.value()[].len()
        if offset < Int64(0) or length < Int64(0):
            raise Error(
                "LocalFs.read_at: negative offset/length: offset=",
                offset, " length=", length, " path=", file._path,
            )
        if Int(offset) + Int(length) > region_len:
            raise Error(
                "LocalFs.read_at: range out of bounds: offset=", offset,
                " length=", length, " file_size=", region_len,
                " path=", file._path,
            )
        # Borrow a slice from the now-alive mmap region. ArcPointer's
        # `copy=` ctor matches `read_whole` / `read_range` and the Arrow
        # file reader.
        #
        # Zero-copy borrow, NOT `borrow_from_mmap(...).realign_to[64]()`:
        # `realign_to[64]` ALWAYS allocates a fresh HeapRegion and memcpys
        # every byte (the copy is unconditional, not alignment-predicated),
        # which would make `read_at` return an OWNING heap buffer while this
        # docstring (and `read_ranges_prefetched`'s) promises
        # `is_owned() == False` / `is_mmap_backed() == True`.
        # `borrow_mmap_erased` returns `SAB[HeapRegion]` aliasing the mmap'd
        # page-cache bytes DIRECTLY, with an `ArcPointer[MmapRegion]` keepalive
        # cookie pinning the mapping for the buffer's lifetime — the K-bridge
        # `realign_to` would give, WITHOUT the per-read memcpy.
        # Alignment: the returned `_ptr` is `mmap_base + offset`, so it is
        # 64-aligned iff `offset % 64 == 0`. That is correctness-safe — the
        # Arrow read path uses unaligned SIMD loads, and the realign was a
        # K-bridge, never an alignment requirement (see `borrow_mmap_erased`'s
        # SAFETY note). Every production consumer of this method is a read-only
        # slurp (`read_ranges_prefetched` below, `FileSystemSpillStorage
        # .read_chunk`, the engine's whole-file slurp); none mutates the
        # returned buffer, so the borrowed-buffer mutation guard is not reached.
        return SharedAlignedBuffer.borrow_mmap_erased(
            ArcPointer[MmapRegion](copy=file._mmap.value()),
            offset,
            length,
        )

    def read_ranges_prefetched(
        self,
        mut file: Self.File,
        ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        """LocalFs reads are already
        mmap-backed zero-copy, so there is no body-transfer to overlap —
        the prefetch fan-out is a no-op here. This is a SEQUENTIAL fallback
        (one `read_at` per range, input order) that exists only so the
        generic `[FS: FileSystem]` parquet decode path type-checks. The
        consumer branches `@parameter if FS.IS_MMAP_BACKED` and uses the
        per-column mmap path instead — this method is never on the LocalFs
        hot path.
        """
        var out = Slab[SharedAlignedBuffer[HeapRegion]]()
        var i = 0
        var n = ranges.__len__()
        while i < n:
            var offset_len = ranges[i]
            var buf = self.read_at(file, offset_len[0], offset_len[1])
            out.append(buf^)
            i = i + 1
        return out^

    # ---- Capability queries ----
    @always_inline
    def prefetch_depth(self) -> Int:
        """Local NVMe default (4) per calibration. Power users
        can override at SDK level via `read_parquet(..., prefetch_depth=N)`."""
        return PREFETCH_DEPTH_LOCAL_NVME

    @always_inline
    def supports_random_read(self) -> Bool:
        """POSIX pread supports random access universally."""
        return True

    # ---- sync metadata + footer-region read ----
    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        """Sync (blocking) speculative tail read of `path`.

        Body:
          1. fopen(path) → fileno() → fd.
          2. SEEK_END to learn file size.
          3. `read_count = min(file_size, window)`.
          4. pread(fd, buf, read_count, file_size - read_count).
          5. Return `FooterRegion(bytes, offset, file_size)`.

        For Parquet, this returns at least the trailing 8-byte
        `(metadata_length, PAR1)` trailer plus (for every footer within the
        window) the metadata blob. A caller whose format metadata exceeds
        the window issues ONE exact follow-up read.

        `window` is a caller
        parameter (`FooterWindowHints.suggest(path)`). The exact-follow-up
        path in `read_parquet_preamble` reuses THIS method with the known
        footer size rather than `open` + `read_at`, which on LocalFs would
        mmap the WHOLE file (14.78 GB on `hits_canonical`) to extract a
        2.33 MB footer.

        the cold window moved 8 MiB → 256 KiB
        (see `footer_region.mojo`) and the total size now rides back on the
        return value, so no caller needs a second `file_size(path)` call.
        On local POSIX that second call was only a stat; on the object-store
        conformers it was a whole HTTP HEAD round trip, and the seam is
        shared.

        Raises on:
          * file-not-found / open failure
          * pread short-read below the parquet 8-byte trailer minimum
        """
        var fp = _local_fs_open_fp(path)
        if fp == 0:
            raise Error("LocalFs.read_footer: open failed for ", path)
        var size = _local_fs_file_size_via_fp(fp)
        if size < 0:
            _local_fs_close_fp(fp)
            raise Error(
                "LocalFs.read_footer: fseek/ftell failed for ", path,
            )
        var offset = speculative_tail_start(size, window)
        var read_count = size - offset
        # Allocate destination buffer.
        var buf = List[UInt8]()
        buf.resize(read_count, UInt8(0))
        # SAFETY: `buf` is owned + sized to `read_count`; pread writes at
        # most `read_count` bytes; pointer is module-private inside the
        # FFI helper. Origin is the local List[UInt8] backing memory.
        var fd = _local_fs_fileno(fp)
        var n_read = _local_fs_pread(
            fd, buf.unsafe_ptr(), read_count, offset
        )
        _local_fs_close_fp(fp)
        if n_read < read_count:
            raise Error(
                "LocalFs.read_footer: short read (", n_read, " < ",
                read_count, ") for ", path,
            )
        return FooterRegion(buf^, offset, size)

    def is_dir(self, path: String) raises -> Bool:
        """Sync probe — True iff `path` is a directory.

        A stat(2) probe (symlinks followed). Returns False for an existing
        non-directory; raises "path not found" on ENOENT, and raises naming
        the errno on any other failure (ENOTDIR, ELOOP, EACCES, ...).
        """
        var rc = _local_fs_is_directory(path)
        if rc < 0:
            raise Error("LocalFs.is_dir: path not found: ", path)
        return rc == 1

    def file_size(self, path: String) raises -> Int:
        """Sync probe — size of `path` in bytes.

        Body uses fopen+SEEK_END (matches `ParquetFileReader.open`'s
        size probe; cheap, ~µs on local NVMe). Used by the footer
        cache's `(path, file_size)` validity-key check (see
        `ParquetMetadataCache._RuntimeFooterEntry`).
        """
        var fp = _local_fs_open_fp(path)
        if fp == 0:
            raise Error("LocalFs.file_size: open failed for ", path)
        var size = _local_fs_file_size_via_fp(fp)
        _local_fs_close_fp(fp)
        if size < 0:
            raise Error(
                "LocalFs.file_size: fseek/ftell failed for ", path,
            )
        return size

    # =========================================================================
    # Write side of the FileSystem trait.
    # =========================================================================
    # =========================================================================

    def open_write(
        self, path: String, mode: WriteMode
    ) raises -> Self.WriteFile:
        """Open a write handle for `path` with the given `mode`.

        Body dispatches on `mode`:
          * CREATE_TRUNCATE  → `RawWriteFd.open_truncate(path)`
                               (O_WRONLY|O_CREAT|O_TRUNC, 0644)
          * CREATE_EXCLUSIVE → `RawWriteFd.open_create_exclusive(path)`
                               (O_WRONLY|O_CREAT|O_EXCL, 0644)
          * APPEND           → `RawWriteFd.open_existing_append(path)`
                               (O_WRONLY|O_APPEND, no O_CREAT/O_TRUNC)

        Returned `LocalWriteFile` wraps the opened fd + path + a cursor
        starting at 0. Drop closes the fd (idempotent); explicit
        `close_write(file^)` is the preferred commit boundary.

        Raises on: open(2) failure (file-not-found for APPEND;
        already-exists for CREATE_EXCLUSIVE; permissions; etc.).
        """
        if mode.is_create_truncate():
            var fd = RawWriteFd.open_truncate(path)
            return LocalWriteFile(fd^, path)
        elif mode.is_create_exclusive():
            var fd = RawWriteFd.open_create_exclusive(path)
            return LocalWriteFile(fd^, path)
        elif mode.is_append():
            var fd = RawWriteFd.open_existing_append(path)
            return LocalWriteFile(fd^, path)
        else:
            raise Error(
                "LocalFs.open_write: unknown WriteMode discriminant value="
                + String(Int(mode.value)) + " path=" + path
            )

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        """Cursor-advancing write of `data` to `file` via POSIX write(2).

        Body: delegates to the module-private `_local_fs_write_chunked`
        helper which absorbs the 64 MiB chunking workaround for the
        Mojo 1.0.0b1 stdlib `FileHandle.write` >2 GB silent-flush bug.
        The chunking matters for raw POSIX write(2) on macOS too — a
        single 2.7 GB write(2) hits XNU's ~2 GiB single-syscall ceiling
        and short-writes (which `RawWriteFd.write_bytes` would loop
        around, but at the cost of one extra syscall round-trip + page
        cache pressure). Chunking at 64 MiB amortizes syscall overhead
        + matches what production C++ writers (DuckDB Parquet sink,
        Arrow IPC) use for their write-loop batch size.

        Advances `file._cursor` by the written byte count after each
        chunk. The kernel's per-fd offset advances in lockstep with
        write(2).

        Concurrency contract: NOT safe to call concurrently on the
        same `file` (the cursor races; the kernel offset races; the
        underlying write(2) interleaving is undefined). For parallel
        disjoint-range writes, use `pwrite_at` and gate the caller on
        `Self.SUPPORTS_PARALLEL_WRITES`.

        Empty input is a no-op (returns 0).

        Raises on: closed handle, write(2) failure (disk full, signal,
        etc. — surfaced via `RawWriteFd.write_bytes`).
        """
        var n = _local_fs_write_chunked(file._fd, data)
        file._cursor += n
        return n

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        """Positional write of `data` at `offset` in `file` via POSIX
        pwrite(2). Does NOT advance the kernel file-offset pointer.

        Both `self` and `file` are NON-MUT — this is the disjoint-range
        concurrent-safe path. POSIX `pwrite(2)` is documented atomic
        for regular files; multiple threads MAY call `pwrite_at`
        concurrently on the same `file` provided each thread's
        `[offset, offset+len(data))` range is disjoint from every
        other thread's. Load-bearing for the JSONL parallel-pwrite
        writer's call site at `RawWriteFd.pwrite_at`.

        Empty input is a no-op (returns 0).

        Note: we do NOT advance `file._cursor` here — `pwrite_at` is
        positional by design. Mixing `pwrite_at` + `write_at` on the
        same handle leaves `_cursor` desynchronized from the kernel
        offset; callers that need both must pick one or the other.

        Raises on:
          * Closed handle
          * Negative offset
          * pwrite(2) failure (disk full, signal, etc. — surfaced via
            `RawWriteFd.pwrite_at`)
        """
        # Empty payload no-op pre-check (RawWriteFd.pwrite_at also no-ops,
        # but eliding the syscall altogether is cheaper).
        var n = len(data)
        if n == 0:
            return Int64(0)
        file._fd.pwrite_at(Int(offset), data)
        return Int64(n)

    def seek_write_to_end(self, mut file: Self.WriteFile) raises -> Int64:
        """Re-sync `file`'s kernel write offset to the current inode EOF
        (`lseek(fd, 0, SEEK_END)`). Returns the new offset.

        Called by the streaming
        parquet writer after a parallel `pwrite_at` page commit to restore
        the kernel file-position pointer (pwrite is positional and does
        NOT advance it) so the next cursor-advancing `write_at` (footer)
        appends correctly. Also bumps the LocalWriteFile logical cursor
        to match.
        """
        var off = file.seek_to_end()
        file._cursor = off
        return off

    def writev_at_cursor(
        self,
        mut file: Self.WriteFile,
        addrs: Span[Int, _],
        lens: Span[Int, _],
    ) raises -> Int64:
        """Single-threaded in-order GATHER write of N scattered buffers
        from `file`'s current cursor via `writev(2)` (kernel scatter-
        gather, zero userspace memcpy). Advances the cursor; returns the
        total bytes written.

        Replaces the
        parallel `pwrite_at` page fan-out: the A/B microbench
        proved N-thread parallel pwrite to ONE shared fd is strictly
        slower than a single-threaded in-order gather (inode `i_rwsem` /
        page-cache contention; penalty monotonic in thread count). The
        `writev` reclaims the contention penalty AND avoids a gather
        memcpy (the iovecs reference the scattered page buffers in place).

        Delegates to `RawWriteFd.writev_addr_len`, which issues exactly
        ONE `writev(2)` per call (no internal iovec loop) but caps at
        `IOV_MAX` iovecs. We batch the caller's N (addr,len) pairs into
        IOV_MAX-sized chunks (the per-flush page count can be ~1000+,
        which is right at the IOV_MAX=1024 edge). The kernel offset is
        advanced by each `writev(2)` in lockstep with the cursor.

        Caller MUST keep every source buffer addressed by `addrs` alive
        across this synchronous call (its enclosing frame owns the pages).
        """
        var n = len(addrs)
        if n != len(lens):
            raise Error(
                "LocalFs.writev_at_cursor: addrs.len="
                + String(n) + " != lens.len=" + String(len(lens))
            )
        if n == 0:
            return Int64(0)
        var total: Int = 0
        var i = 0
        while i < n:
            var hi = i + IOV_MAX
            if hi > n:
                hi = n
            # Slice this IOV_MAX-bounded batch. writev(2) is positional at
            # the kernel's current fd offset and advances it; consecutive
            # batches therefore append contiguously, producing byte-
            # identical output to the in-order serial commit.
            var written = file._fd.writev_addr_len(addrs[i:hi], lens[i:hi])
            total += written
            i = hi
        file._cursor += Int64(total)
        return Int64(total)

    def close_write(
        self, var file: Self.WriteFile
    ) raises -> None:
        """Explicit close commit boundary. Consumes `file`.

        Body: explicitly calls `RawWriteFd.close()` to surface any
        close(2) error to the caller (raises on close failure). The
        `var file` parameter consumes the LocalWriteFile; the
        underlying RawWriteFd's `__del__` runs when this function
        returns and sees a sentinel fd (idempotent close — no
        double-close).

        Durability: close(2) does NOT fsync. For write-to-storage
        durability, the caller must invoke
        `komira_libc.posix_io.fsync_path(path)` separately
        (matches the existing `-
        MOJO-SIDE` pattern at posix_io.mojo:586-607).

        Raises on close(2) failure (rare on regular files; can occur
        on remote filesystems if writeback is asynchronously flushed
        and reports an error at close time).
        """
        file._fd.close()

    # ---- U-0 delete ----
    def delete(self, path: String) raises -> None:
        """Delete the file at `path` via POSIX `remove(3)`. ENOENT-tolerant.

        Overrides the FileSystem trait's default raising body so the spill
        layer (`FileSystemSpillStorage[LocalFs].release_chunk`) can reclaim
        disk space.

        remove(3)'s own errno decides (read in C right after the call):
          * 0 → removed (a file, or an EMPTY directory).
          * ENOENT → already gone (never existed, or a concurrent release
            removed it): the post-condition holds, return (idempotent).
          * anything else (EACCES, EPERM, EBUSY, EROFS, ENOTEMPTY for a
            non-empty directory, ENOTDIR, ELOOP, EIO, …) → raise
            `cannot remove '<path>': errno N (NAME)`.
        """
        var rc = _local_fs_remove(path)
        if rc == 0 or rc == _fs_enoent():
            return
        raise Error(
            "LocalFs.delete: cannot remove '" + path + "': "
            + _fs_errno_label(rc)
        )

    # ---- durable-flush barrier ----
    def fsync_file(self, path: String) raises -> None:
        """`fsync(2)` the file at `path` so its bytes survive a power loss.

        Overrides the FileSystem trait's default raising body. Delegates to
        `posix_io.fsync_path` (re-open the inode write-append, fsync, close —
        the same primitive the conditional store's WRITE-TEMP-THEN-RENAME
        durable path uses). Returns only after `fsync(2)` acknowledges.

        Called by `FileSystemSpillStorage[LocalFs].sync()` for every live
        chunk file (the gap B local-FS durable barrier).

        Raises if the file cannot be opened (must already exist) or if
        `fsync(2)` returns non-zero.
        """
        fsync_path(path)

    def fsync_dir(self, dir: String) raises -> None:
        """`fsync(2)` the directory inode at `dir` so newly-created chunk
        FILENAMES survive a power loss.

        Overrides the FileSystem trait's default raising body. Delegates to
        `posix_io.fsync_dir` (open the directory read-only, fsync, close).
        Power-loss durability for a CREATED file requires fsync'ing both the
        file's data (`fsync_file`) AND the parent directory's inode (the new
        directory entry naming the file).

        Called once by `FileSystemSpillStorage[LocalFs].sync()` after
        fsync'ing each live chunk.

        Raises if the directory cannot be opened or if `fsync(2)` returns
        non-zero.
        """
        fsync_dir(dir)

    # ---- abort_write — error-path cleanup ----
    def abort_write(self, var file: Self.WriteFile) raises -> None:
        """Abort an in-flight LocalFs write: best-effort unlink the partial
        file at the handle's path (the footerless corpse), then drop the fd.

        Overrides the FileSystem trait's default raising body. Mirrors the
        codec writers' existing `_best_effort_unlink` on the error path — the
        on-disk file is incomplete (no footer) and unreadable, so it must not
        be left behind. The `var file` consumes the LocalWriteFile; its fd is
        closed by `RawWriteFd.__del__` when this function returns. ENOENT-
        tolerant (best-effort: a never-flushed file may not exist yet).
        """
        var path = file._path.copy()
        _ = file^
        # Best-effort by contract (this runs on an error path, and raising
        # here would mask the caller's original error): the errno is ignored.
        var rc = _local_fs_remove(path)
        _ = rc

    # ---- facade methods --------------------------------
    # Thin delegates over
    # `komira_arrow_ipc.chunked_read.read_chunked` /
    # `read_chunked_range` — that file is the single canonical
    # mmap-wrap site in the tree.
    #
    # Why both this facade AND read_chunked exist:
    #   * `read_chunked(path)` lives in the core packages so downstream
    #     reader packages (`komira_orc`, `komira_csv`, `komira_json`,
    #     `komira_sdk`) can import it without an upward layering hop
    #     into `komira_async`.
    #   * `LocalFs.read_whole` / `LocalFs.read_range` remain as the
    #     entry points for callers that already hold a `LocalFs[Sink]`
    #     handle (Avro reader; future async-FS contexts). They are
    #     0-cost delegations to the same canonical helper.
    #
    # Both paths produce byte-identical `MmapAlignedBuffer[64]` with
    # identical Arc-keepalive semantics (see chunked_read.mojo header).
    # Substrate-consistency win: the tree has exactly ONE place that
    # opens an mmap and binds an MmapAlignedBuffer over it.

    def read_whole(self, path: String) raises -> SharedAlignedBuffer[HeapRegion]:
        """Sync slurp facade — mmap `path` and return a borrowed MmapAlignedBuffer.

        Thin delegate to `komira_arrow_ipc.chunked_read.read_chunked`
        (the canonical mmap-wrap site). The returned buffer's
        `_keepalive` is an `ArcPointer[MmapRegion]`; bytes alias the
        kernel mmap mapping (zero-copy on warm page cache); the last
        drop fires `munmap(2)` via `MmapRegion.__del__`.

        Args:
            path: Filesystem path to read.

        Returns:
            A non-owning MmapAlignedBuffer[64] aliasing the entire file
            contents, with the mmap region kept alive by the buffer's
            Arc keepalive.

        Raises:
            * `MmapRegion.open_readonly` failures (open/fstat/mmap;
              zero-length file).

        `read_chunked` returns
        `MmapAlignedBuffer[64, MmapRegion]`;
        FileSystem trait's `read_at` and the historic `read_whole` /
        `read_range` API contract returns `MmapAlignedBuffer[64]` (= HeapRegion
        default). Bridge via `realign_to[64]()` — ONE memcpy per call.
        The same realign-at-boundary discipline as
        the IPC mmap column-builder fns. Making the Region parametric on the
        FileSystem trait would cascade through every caller and
        per-format-reader state holder, so it is not done here.
        """
        # `read_chunked` returns `SAB[MmapRegion]` directly;
        # `.realign_to[64]()` collapses to `SAB[HeapRegion]`. No bridge needed.
        return read_chunked(path).realign_to[64]()

    def read_range(
        self, path: String, offset: Int, length: Int,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Sync ranged-read facade — mmap `path` and return a borrowed
        MmapAlignedBuffer over `[offset, offset+length)`.

        Thin delegate to `komira_arrow_ipc.chunked_read.read_chunked_range`
        (the canonical mmap-wrap site).

        Args:
            path: Filesystem path to read.
            offset: Byte offset into the file. Must be >= 0.
            length: Bytes to expose through the returned buffer.
                `offset + length` must be <= file_size.

        Returns:
            A non-owning MmapAlignedBuffer[64] aliasing the requested range.

        Raises:
            * `MmapRegion.open_readonly` failures.
            * Negative offset/length.
            * Range out of bounds.

        See `read_whole` above
        for the realign-at-boundary rationale.
        """
        # Trait signature is SAB[HeapRegion]: realign-at-boundary (one memcpy)
        # per the pointer rules. `read_chunked_range` returns `SAB[MmapRegion]`
        # directly; `.realign_to[64]()` collapses to `SAB[HeapRegion]`.
        return read_chunked_range(path, offset, length).realign_to[64]()
