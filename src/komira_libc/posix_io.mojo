# =============================================================================
# posix_io.mojo — raw fd write + writev gather for the Arrow IPC streaming sink.
# =============================================================================
#
# # Why this file exists
#
# A streaming Arrow IPC body sink issues one write per buffer: ~26 buffers
# per RecordBatch, over a thousand `FileHandle.write` calls for a large
# file; each call constructs a `String` from the source bytes via
# `String(unsafe_from_utf8=...)` then dispatches to `write(2)`. The String
# construction dominates that cost.
#
# POSIX `writev(2)` lets the kernel gather N disjoint buffers in ONE
# syscall — no userspace memcpy, no String wrap, one trip into the
# kernel per RB instead of ~26. This file exposes that primitive with
# raw pointers kept inside the module.
#
# # Public API
#
# `RawWriteFd` — owning handle for a write-only file descriptor:
#   * `open_truncate(path)` — opens `path` with `O_WRONLY|O_CREAT|O_TRUNC`,
#     mode 0644 (matches `FileHandle(path, "w")` semantics).
#   * `write_bytes(span)` — single `write(2)` call. Loops on short writes.
#   * `writev_spans(views)` — single `writev(2)` syscall to gather N
#     disjoint borrowed views. Caller MUST keep `views` alive across
#     the call.
#   * `close()` — explicit close (idempotent). Also called from `__deinit__`.
#
# # Encapsulation
#
# - Public API takes / returns: `String`, `Span[UInt8, _]`, `Int`.
# - `UnsafePointer` and the raw `_IoVec` POD layout stay INSIDE this
#   module. The `_IoVec` storage is a stack-local `InlineArray[UInt8, 16
#   * N]` constructed inside `writev_spans` and never escapes.
# - `_fd: Int32` field carries no origin; it's a small POD integer.
# - No wildcard origins; no `unsafe_from_address=Int`; no FFI carve-out
#   beyond the syscall sites which are guarded by `# SAFETY:` comments.
#
# # Cross-platform
#
# `writev(2)`, `write(2)`, `open(2)`, `close(2)` are POSIX.1-2008. Both
# macOS arm64 and Linux x86_64 ABI:
#   * fd is `int` (32-bit signed).
#   * iov_base is `void *` (8 bytes on 64-bit).
#   * iov_len is `size_t` (8 bytes on 64-bit).
#   * struct iovec is therefore 16 bytes on both platforms.
#   * IOV_MAX is 1024 on both platforms (well above 26 buffers/RB).
#
# `openat(AT_FDCWD, ...)` is used instead of `open(2)` because Mojo's
# stdlib reserves the symbol name `open` (collides at link time). This
# mirrors `mmap_region.mojo`'s choice.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget


# =============================================================================
# POSIX constants
# =============================================================================
# `O_WRONLY = 1`, `O_CREAT = 0x40 (Linux) / 0x200 (Darwin)`,
# `O_TRUNC = 0x200 (Linux) / 0x400 (Darwin)`. Platform-specific because
# Apple chose different bit values than Linux.
# `AT_FDCWD = -100 (Linux) / -2 (Darwin)` — PLATFORM-SPECIFIC. POSIX does
# NOT mandate a value; macOS uses -2, Linux uses -100. Passing the Darwin
# value on Linux breaks every RELATIVE-path openat with EBADF (openat
# ignores dirfd only for ABSOLUTE paths, which is why absolute-path callers
# would mask the bug). `mmap_region.mojo` resolves its POSIX constants in C
# for the same reason.
# `IOV_MAX = 1024` on both platforms.
# Mode `0644 = 0o644 = 420 decimal`.
comptime _O_WRONLY: Int32 = 1
comptime IOV_MAX: Int = 1024
comptime _DEFAULT_MODE: Int32 = 420  # 0o644


@always_inline
def _at_fdcwd() -> Int32:
    """`AT_FDCWD` for the current platform: -2 on macOS (Darwin),
    -100 on Linux. POSIX does not mandate a value; passing the wrong one
    makes every relative-path `openat(2)` fail with EBADF."""
    comptime if CompilationTarget.is_macos():
        return Int32(-2)
    else:
        return Int32(-100)


@always_inline
def _o_creat() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x0200)  # Darwin O_CREAT
    else:
        return Int32(0x0040)  # Linux O_CREAT


@always_inline
def _o_trunc() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x0400)  # Darwin O_TRUNC
    else:
        return Int32(0x0200)  # Linux O_TRUNC


@always_inline
def _o_append() -> Int32:
    """O_APPEND — PLATFORM-DIVERGENT.

      * Darwin: 0x0008 (per `/usr/include/sys/fcntl.h`).
      * Linux : 0x0400 (02000 octal, per `<asm-generic/fcntl.h>`).

    0x0008 is NOT O_APPEND on Linux. With the wrong value
    `open_existing_append` opens the fd WITHOUT O_APPEND, so a dual-fd
    writev lands at offset 0 and CLOBBERS the header bytes another fd has
    already written. Same divergent shape as `_o_trunc` / `_o_excl`.
    """
    comptime if CompilationTarget.is_macos():
        return Int32(0x0008)  # Darwin O_APPEND
    else:
        return Int32(0x0400)  # Linux O_APPEND (02000 octal)


@always_inline
def _o_excl() -> Int32:
    """O_EXCL — fail if path already exists when combined with O_CREAT.

    Platform-divergent constant:
      * Darwin: 0x0800 (per `/usr/include/sys/fcntl.h`)
      * Linux : 0x0080 (per `<asm-generic/fcntl.h>`)
    """
    comptime if CompilationTarget.is_macos():
        return Int32(0x0800)  # Darwin O_EXCL
    else:
        return Int32(0x0080)  # Linux O_EXCL


# =============================================================================
# RawWriteFd — owning handle for a write-only fd
# =============================================================================


struct RawWriteFd(Movable):
    """Owning handle for a POSIX write-only file descriptor.

    Drop closes the fd via `close(2)`. Movable so it can be stashed in
    `Optional[RawWriteFd]` inside a sink struct that itself moves through
    the `WriteSpec` Tuple multi-hop sequence.

    `_fd == -1` is the "closed / moved-out" sentinel; idempotent close
    and double-close are safe.
    """

    var _fd: Int32

    def __init__(out self):
        """Construct an empty (closed) handle."""
        self._fd = Int32(-1)

    def __deinit__(deinit self):
        """Close the fd if still open. Idempotent.

        Note: moveinit is compiler-derived (Int32 is Copyable+Movable).
        On move, the source struct is consumed without being dropped,
        so the fd is transferred to the destination and `close(2)` is
        called exactly once when the destination eventually drops.
        """
        if Int(self._fd) >= 0:
            _ = external_call["close", Int32](self._fd)

    @staticmethod
    def open_truncate(path: String) raises -> Self:
        """Open `path` for writing with O_WRONLY|O_CREAT|O_TRUNC, mode 0644.

        Semantically matches `FileHandle(path, "w")`.

        Raises on `openat(2)` failure.
        """
        var p = path
        var flags = _O_WRONLY | _o_creat() | _o_trunc()
        # SAFETY: `as_c_string_slice()` returns a NUL-terminated view
        # whose underlying buffer is owned by `p` (held alive across the
        # syscall by the local var). The kernel reads the path string
        # and copies what it needs; the pointer does not escape.
        # `komira_openat_creat` is a fixed-arity shim around openat(2):
        # libc's `openat(int dirfd, const char *path, int oflag, ...)` is
        # variadic from `mode` onward, and Apple's ARM64 ABI puts variadic
        # args on the stack while Mojo's external_call passes them in
        # registers — same variadic-fragile pattern that motivated
        # `komira_fcntl_set_nonblock`. Without the shim, the file is
        # created with arbitrary (typically zero) permission bits.
        var fd = external_call["komira_openat_creat", Int32](
            _at_fdcwd(),
            p.as_c_string_slice().unsafe_ptr(),
            flags,
            _DEFAULT_MODE,
        )
        if Int(fd) < 0:
            raise Error(
                "RawWriteFd.open_truncate: openat() failed for path '"
                + path + "' (errno not surfaced)"
            )
        var w = RawWriteFd()
        w._fd = fd
        return w^

    @staticmethod
    def open_existing_append(path: String) raises -> Self:
        """Open existing `path` with O_WRONLY|O_APPEND (no O_CREAT, no
        O_TRUNC). Every write(2) / writev(2) is positioned at end-of-file
        atomically by the kernel.

        The canonical dual-fd entry point. The Arrow IPC `accept_arrow_file` writes the
        dual-fd entry point. The Arrow IPC `accept_arrow_file` writes the
        per-RB FlatBuffer header via the existing stdlib `FileHandle`, then
        opens a parallel RawWriteFd via this factory and issues ONE writev
        per RB for body gather. Because POSIX O_APPEND guarantees each
        write atomically seeks to EOF, the two fds never race on file
        position — header bytes from `FileHandle.write(2)` land at the
        kernel-level EOF, then the next O_APPEND writev lands beyond them.

        File MUST already exist (we never `O_CREAT` here). Raises if
        `openat(2)` returns negative.
        """
        var p = path
        # NOTE: do NOT pass O_CREAT; we are re-opening an existing file
        # that the FileHandle path-open already created + truncated. The
        # `mode` arg is ignored by the kernel without O_CREAT but the
        # shim still requires it (fixed-arity ABI).
        var flags = _O_WRONLY | _o_append()
        # SAFETY: same contract as `open_truncate`. The path string is
        # held alive by the local `p` across the syscall; the kernel
        # copies what it needs and returns.
        var fd = external_call["komira_openat_creat", Int32](
            _at_fdcwd(),
            p.as_c_string_slice().unsafe_ptr(),
            flags,
            _DEFAULT_MODE,
        )
        if Int(fd) < 0:
            raise Error(
                "RawWriteFd.open_existing_append: openat() failed for path '"
                + path + "' (errno not surfaced)"
            )
        var w = RawWriteFd()
        w._fd = fd
        return w^

    @staticmethod
    def open_create_exclusive(path: String) raises -> Self:
        """Open `path` for writing with O_WRONLY|O_CREAT|O_EXCL, mode 0644.

        Atomically creates `path`. If `path` already exists, raises
        (errno EEXIST at the syscall layer, surfaced as a generic
        Error here per the existing fd-factory pattern).

        The primitive behind a local filesystem's
        `open_write(path, WriteMode.CREATE_EXCLUSIVE)`, for callers that
        need write-or-fail semantics (e.g. atomic rename-into-place flows).
        """
        var p = path
        var flags = _O_WRONLY | _o_creat() | _o_excl()
        # SAFETY: same contract as `open_truncate`. The path string is
        # held alive by the local `p` across the syscall; the kernel
        # copies what it needs and returns.
        var fd = external_call["komira_openat_creat", Int32](
            _at_fdcwd(),
            p.as_c_string_slice().unsafe_ptr(),
            flags,
            _DEFAULT_MODE,
        )
        if Int(fd) < 0:
            raise Error(
                "RawWriteFd.open_create_exclusive: openat() failed for path '"
                + path + "' (errno not surfaced; likely EEXIST if path exists)"
            )
        var w = RawWriteFd()
        w._fd = fd
        return w^

    def is_closed(self) -> Bool:
        """True if `close()` has been called or this is the moved-from
        sentinel."""
        return Int(self._fd) < 0

    def seek_to_end(mut self) raises -> Int:
        """`lseek(fd, 0, SEEK_END)` — re-sync this fd's offset to the
        current inode EOF.

        Two fds on
        the same file (stdlib `FileHandle` + this `RawWriteFd`) each
        track their own offset in the kernel's file table — they are
        NOT magically synchronized just because they point at the same
        inode. After `FileHandle.write` advances the inode size, this
        fd's stale offset would overwrite the FileHandle-written bytes
        on the next `write_bytes` / `writev_addr_len`. `seek_to_end`
        bumps this fd to the new EOF so the next write appends.

        Returns the new offset (= inode size) on success.

        Note: SEEK_END = 2, both Darwin and Linux. Binds the
        `komira_lseek_end` C shim (NOT a raw `external_call["lseek"]`):
        a raw lseek binding collides with the stdlib's own reserved
        `lseek` FFI declaration under archive lowering (the same reason as
        komira_pwrite / komira_fsync). The shim is
        `long long komira_lseek_end(int fd)` wrapping `lseek(fd, 0, SEEK_END)`.
        """
        if Int(self._fd) < 0:
            raise Error("RawWriteFd.seek_to_end: fd is closed")
        # `komira_lseek_end` returns off_t (= long on 64-bit POSIX =
        # 8 bytes). The external_call binding uses Int (8-byte signed).
        var off = external_call["komira_lseek_end", Int](
            self._fd
        )
        if off < 0:
            raise Error(
                "RawWriteFd.seek_to_end: lseek failed (rc=" + String(off) + ")"
            )
        return off

    def close(mut self) raises:
        """Explicit close. Idempotent; safe to call multiple times.

        Raises if `close(2)` returns non-zero AND the fd was non-sentinel.
        """
        if Int(self._fd) < 0:
            return
        var rc = external_call["close", Int32](self._fd)
        self._fd = Int32(-1)
        if Int(rc) != 0:
            raise Error(
                "RawWriteFd.close: close(2) failed (rc="
                + String(Int(rc)) + ")"
            )

    def fsync(mut self) raises:
        """Flush kernel page-cache writeback for this fd to underlying storage
        via `fsync(2)`. Returns only after the kernel has acknowledged all
        previously-written bytes are durably persisted.

        The fairness primitive for write-path benchmarks: ensures the
        timer reflects write-to-storage latency, not write-to-page-cache
        latency (the counterpart of `os.fsync(fd)` on the Python side).

        Raises if the fd is closed OR if `fsync(2)` returns non-zero (errno
        not surfaced).
        """
        if Int(self._fd) < 0:
            raise Error("RawWriteFd.fsync: fd is closed")
        # SAFETY: synchronous syscall; the kernel reads no userspace pointer
        # state, just flushes the in-kernel UBC pages for this fd.
        # `komira_fsync` is a fixed-arity shim around fsync(2) to sidestep
        # any stdlib "fsync" name collision.
        var rc = external_call["komira_fsync", Int32](self._fd)
        if Int(rc) != 0:
            raise Error(
                "RawWriteFd.fsync: fsync(2) failed (rc=" + String(Int(rc)) + ")"
            )

    def write_bytes(mut self, bytes: Span[UInt8, _]) raises:
        """Write `bytes` to the fd via `write(2)`. Loops on short writes
        until all bytes land.

        Empty input is a no-op (no syscall). Short writes (which can
        occur on signal-interrupted FDs, pipes, sockets) are retried;
        for a regular file this should always complete in one call.

        Raises if `write(2)` returns negative (errno not surfaced).
        """
        if Int(self._fd) < 0:
            raise Error("RawWriteFd.write_bytes: fd is closed")
        var n = len(bytes)
        if n == 0:
            return
        var off = 0
        # SAFETY: `bytes.unsafe_ptr()` is borrowed from the caller's
        # span; we only use it for the duration of this synchronous
        # syscall. The Span's origin pins it alive across the call.
        # `komira_write_bytes` is a fixed-arity shim around write(2)
        # to sidestep the stdlib's "write" name collision.
        var base = bytes.unsafe_ptr()
        while off < n:
            var remaining = n - off
            var rc = external_call["komira_write_bytes", Int](
                self._fd, base + off, UInt64(remaining)
            )
            if rc < 0:
                raise Error(
                    "RawWriteFd.write_bytes: write(2) failed at off="
                    + String(off) + " (rc=" + String(rc) + ")"
                )
            if rc == 0:
                raise Error(
                    "RawWriteFd.write_bytes: write(2) returned 0 with "
                    + String(remaining) + " bytes remaining"
                )
            off += Int(rc)

    def pwrite_at(
        self, offset: Int, bytes: Span[UInt8, _]
    ) raises:
        """Positional write — write `bytes` at file offset `offset` via
        `pwrite(2)`. Does NOT advance the kernel file-offset pointer
        (per POSIX), which is what makes pwrite safe to issue from
        multiple threads concurrently when each thread targets a
        disjoint `[offset, offset+len)` range on the same fd.

        Loops on short writes (regular files should never short-write,
        but pipes/sockets can; for safety we always loop).

        Empty input is a no-op (no syscall).

        Args:
            offset: Starting byte offset in the file. Must be >= 0.
            bytes:  Bytes to write.

        Raises:
          * Error if fd is closed.
          * Error if `pwrite(2)` returns negative.
          * Error if `pwrite(2)` returns 0 with bytes remaining
            (unexpected, indicates EOF / disk full / signal).

        Concurrency contract:
            Multiple threads MAY call `pwrite_at` concurrently on the
            same `RawWriteFd` provided each thread's
            `[offset, offset+len(bytes))` range is disjoint from every
            other thread's. POSIX `pwrite(2)` is documented atomic
            within one call for regular files; disjoint-range
            concurrent calls do not race. A parallel writer relies on
            this: N encoder workers compute per-worker byte buffers, the
            main thread prefix-sums byte sizes into offsets, then N writer
            workers `pwrite_at` their buffers in parallel to disjoint file
            ranges.

        Encapsulation: `self` is borrowed `read` (the fd is just an
        Int32 POD; no mutation of the struct). `bytes` is a
        borrowed Span; no UnsafePointer crosses the public sig.
        Internal `bytes.unsafe_ptr()` arithmetic is confined to this
        function body (see SAFETY note below).
        """
        if Int(self._fd) < 0:
            raise Error("RawWriteFd.pwrite_at: fd is closed")
        if offset < 0:
            raise Error(
                "RawWriteFd.pwrite_at: negative offset (" + String(offset) + ")"
            )
        var n = len(bytes)
        if n == 0:
            return
        # SAFETY: `bytes.unsafe_ptr()` is borrowed from the caller's
        # span; we only use it for the duration of this synchronous
        # syscall. The Span's origin pins it alive across the call.
        # No pointer escapes this function body.
        # `komira_pwrite` is a fixed-arity shim around pwrite(2) to
        # sidestep the stdlib's "pwrite" name collision.
        var base = bytes.unsafe_ptr()
        var written = 0
        while written < n:
            var remaining = n - written
            var rc = external_call["komira_pwrite", Int](
                self._fd,
                base + written,
                UInt64(remaining),
                Int64(offset + written),
            )
            if rc < 0:
                raise Error(
                    "RawWriteFd.pwrite_at: pwrite(2) failed at offset="
                    + String(offset + written)
                    + " (rc=" + String(rc) + ")"
                )
            if rc == 0:
                raise Error(
                    "RawWriteFd.pwrite_at: pwrite(2) returned 0 with "
                    + String(remaining) + " bytes remaining at offset="
                    + String(offset + written)
                )
            written += Int(rc)

    def ftruncate_size(mut self, length: Int) raises:
        """Truncate / extend the file behind this fd to exactly
        `length` bytes via `ftruncate(2)`.

        - If the file is currently LARGER than `length`, bytes beyond
          `length` are discarded.
        - If the file is currently SMALLER than `length`, the file is
          extended; new bytes read as zero (POSIX hole semantics on
          filesystems that support sparse files; otherwise the kernel
          allocates zero-filled blocks).

        Used (optionally) by a parallel-pwrite path to
        pre-size the file before issuing concurrent `pwrite_at`
        calls. Pre-sizing is not required for correctness (pwrite
        past EOF auto-extends), but pre-allocating in one syscall
        reduces fragmentation on some filesystems.

        Raises:
          * Error if fd is closed.
          * Error if length is negative.
          * Error if `ftruncate(2)` returns non-zero.

        Encapsulation: takes only `Int`; no pointer surface.
        """
        if Int(self._fd) < 0:
            raise Error("RawWriteFd.ftruncate_size: fd is closed")
        if length < 0:
            raise Error(
                "RawWriteFd.ftruncate_size: negative length ("
                + String(length) + ")"
            )
        # SAFETY: synchronous syscall; the kernel reads no userspace
        # pointer state, just adjusts the inode size.
        var rc = external_call["komira_ftruncate", Int32](
            self._fd, Int64(length)
        )
        if Int(rc) != 0:
            raise Error(
                "RawWriteFd.ftruncate_size: ftruncate(2) failed (rc="
                + String(Int(rc)) + ", length=" + String(length) + ")"
            )

    def writev_addr_len(
        mut self, addrs: Span[Int, _], lens: Span[Int, _]
    ) raises -> Int:
        """Gather-write up to IOV_MAX parallel (addr, len) pairs via
        ONE `writev(2)` syscall.

        Returns total bytes written.

        Performance contract:
          * Issues exactly ONE writev syscall per call (no internal
            looping over iovecs).
          * Zero userspace memcpy. The kernel reads from the source
            buffers via its internal scatter-gather DMA path.
          * Caller MUST hold the underlying buffers alive (the
            addresses in `addrs` must point at valid memory) for the
            duration of this call.

        Args:
            addrs: Per-iovec source byte addresses (as `Int`-cast
                pointers). `len(addrs)` must equal `len(lens)`.
            lens:  Per-iovec source lengths in bytes.

        Why `Int` addresses (not Span-of-Span): the caller has already
        extracted raw pointers from whatever heterogeneous sources
        (staging buffer slices, column data buffers, validity bitmaps);
        passing them as `Int` keeps the FFI surface zero-origin and
        keeps the encapsulation rule clean — no wildcard `Span` origin
        crosses this module boundary. The caller is responsible for
        keeping the underlying buffers alive across this synchronous
        call (its own stack frame guarantees that for the streaming
        sink use case).

        Raises:
          * Error if `_fd` is closed.
          * Error if `len(addrs) != len(lens)`.
          * Error if `len(addrs) > IOV_MAX` (caller MUST batch).
          * Error if `writev(2)` returns negative.
          * Error on short-write (writev may return short on partial
            iovec drain; for regular files this should never happen,
            but we surface it as an error rather than silently dropping
            bytes).
        """
        if Int(self._fd) < 0:
            raise Error("RawWriteFd.writev_addr_len: fd is closed")
        var n_iovs = len(addrs)
        if n_iovs != len(lens):
            raise Error(
                "RawWriteFd.writev_addr_len: addrs.len="
                + String(n_iovs) + " != lens.len="
                + String(len(lens))
            )
        if n_iovs == 0:
            return 0
        if n_iovs > IOV_MAX:
            raise Error(
                "RawWriteFd.writev_addr_len: " + String(n_iovs)
                + " iovecs exceeds IOV_MAX=" + String(IOV_MAX)
            )
        # Build the iovec array on the stack. Each iovec = 16 bytes
        # (8-byte pointer + 8-byte length on 64-bit POSIX).
        # We use an `InlineArray[UInt8, 16 * IOV_MAX]` = 16 KiB stack;
        # then bitcast to write the per-slot pointer + length.
        var iov_bytes = Array[UInt8, 16 * IOV_MAX](fill=UInt8(0))
        # SAFETY: `iov_bytes` is stack-local and outlives the syscall
        # (the kernel reads-only). Each iovec slot is 16 bytes; we
        # write the pointer at offset +0 and the length at offset +8
        # via Int64 bitcasts. The slot bytes are released when this
        # function returns; the kernel completes its read before
        # returning from the syscall (synchronous).
        var iov_base = UnsafePointer(to=iov_bytes).bitcast[UInt8]()
        var total_bytes: Int = 0
        for i in range(n_iovs):
            var n_bytes = lens[i]
            total_bytes += n_bytes
            # Write iov_base (8 bytes) at slot_off + 0.
            var slot_off = i * 16
            var slot_ptr_field = (iov_base + slot_off).bitcast[Int64]()
            slot_ptr_field[0] = Int64(addrs[i])
            # Write iov_len (8 bytes) at slot_off + 8.
            var slot_len_field = (iov_base + slot_off + 8).bitcast[Int64]()
            slot_len_field[0] = Int64(n_bytes)
        # SAFETY: synchronous syscall; iov_bytes outlives the call
        # frame, source buffers are pinned alive by the caller's
        # contract (it holds whatever owns the addresses in `addrs`
        # alive in its enclosing scope across the call).
        # `komira_writev_iov` is a fixed-arity shim around writev(2)
        # to sidestep any stdlib "writev" name collision and to give
        # uniform `long long` return on both platforms.
        var rc = external_call["komira_writev_iov", Int](
            self._fd, iov_base, Int32(n_iovs)
        )
        if rc < 0:
            raise Error(
                "RawWriteFd.writev_addr_len: writev(2) failed (rc="
                + String(rc) + ", n_iovs=" + String(n_iovs)
                + ", total_bytes=" + String(total_bytes) + ")"
            )
        if Int(rc) != total_bytes:
            # Short writev. For a regular file this should never
            # happen; the kernel's writev never short-writes on a
            # local file unless the disk is full. Surface as error
            # rather than silently dropping bytes.
            raise Error(
                "RawWriteFd.writev_addr_len: writev(2) short-wrote rc="
                + String(rc) + " of " + String(total_bytes)
                + " bytes (n_iovs=" + String(n_iovs) + ")"
            )
        return total_bytes


# =============================================================================
# Module-level helper: fsync a just-written file by path
# =============================================================================
# The write-path fairness helper: the Mojo-side counterpart of `os.fsync(fd)`.
#
# It re-opens the just-written file (write-mode O_APPEND, no O_TRUNC),
# fsyncs, and closes. The cost is the kernel-side flush latency; the
# open/close pair is ~10 µs (negligible). The writer's own fd never escapes;
# this borrows a new fd that targets the same inode for the fsync syscall.
#
# Why O_APPEND and not O_RDONLY: macOS APFS `fsync(2)` on an O_RDONLY fd
# is a no-op on some kernels and a documented inconsistency on others.
# O_APPEND with O_WRONLY guarantees the kernel treats this fd as a write-
# capable handle and flushes any dirty pages associated with the inode
# regardless of which fd initially queued them. We never actually call
# write(2) on this fd; it serves as a flush-channel only.
# =============================================================================


def fsync_path(path: String) raises:
    """Flush the kernel page-cache writeback for the file at `path` to
    underlying storage. Returns only after the kernel acknowledges all
    previously-written bytes (via any fd, by any process) for the inode
    behind `path` are durably persisted.

    Encapsulation contract: NO raw fd / UnsafePointer escapes this fn.
    Public surface is `path: String` -> `raises`. Internal RawWriteFd is
    opened, fsync'd, and dropped (closed) inside the fn body.

    The write-path fairness primitive for benchmarks: call AFTER
    `ctx.run(df^.write_*(path))` returns, INSIDE the timed region, so the
    reported wall reflects write-to-storage latency.

    Raises if the file cannot be opened (must already exist) or if
    `fsync(2)` returns non-zero.
    """
    var fd = RawWriteFd.open_existing_append(path)
    fd.fsync()
    fd.close()


# =============================================================================
# Module-level helper: fsync a directory inode by path
# =============================================================================
# For a file that is CREATED (a fresh directory entry, not an overwrite of an
# existing one) — as the spill layer's `write_chunk` does — power-loss
# durability requires fsync'ing not only the file's data (`fsync_path` above)
# but ALSO the parent directory's inode. The directory entry (the new
# filename's link) is metadata in the directory inode; without an explicit
# directory fsync, after a power loss the file's data can be durable while the
# directory entry that NAMES it is lost — the file becomes unreachable (the
# classic "fsync the file AND the dir" rule for atomic create /
# rename-into-place).
#
# We open the directory READ-ONLY (O_RDONLY == 0 on both Darwin and Linux; no
# O_CREAT, so the mode arg is ignored by the kernel) and fsync that fd. POSIX
# permits fsync(2) on a directory fd to flush its dirent metadata. macOS APFS
# honors this; Linux ext4/xfs/btrfs honor this.
#
# Encapsulation contract: NO raw fd / UnsafePointer escapes this fn. Public
# surface is `dir: String` -> `raises`.
# =============================================================================


comptime _O_RDONLY: Int32 = 0


# =============================================================================
# Module-level helper: page-cache prefetch of a file by path
# =============================================================================
# Prefetch offload for a compute/IO hyperthread split.
#
# The IO-lane worker (on a sibling hyperthread) runs this on a spill-chunk path
# so the file's pages are warm in the OS page cache by the time the compute
# thread does its own `read_chunk` (an mmap-fault on LocalFs). This is the SAFE
# form-(a) handoff: the prefetch touches ONLY the source file (no shared mutable
# buffer, no per-dispatch `state`, no fork-join barrier), and the "handoff" is
# the kernel page cache — fire-and-forget. If the prefetch has not finished when
# the compute thread reads, the read faults the remaining pages itself:
# correctness is never affected, only the IO/compute overlap.
#
# Encapsulation contract: NO raw fd / UnsafePointer escapes this fn. Public
# surface is `path: String` + `max_bytes: Int` -> `None`. The open / advise /
# read / close all happen inside the `komira_prefetch_file` C shim (which also
# resolves POSIX_FADV_WILLNEED at the C level); the discarded read buffer is a
# C-internal stack array that never reaches Mojo.
# =============================================================================


def prefetch_file_into_page_cache(path: String, max_bytes: Int):
    """Best-effort page-cache prime for the file at `path`.

    Faults up to `max_bytes` of the file into the OS page cache so a subsequent
    read (by the compute thread) hits warm pages. `max_bytes <= 0` means "warm
    to EOF" (the C shim reads until EOF). NEVER raises — a missing / unreadable
    file is benign (the compute thread's own read covers correctness); the C
    shim returns -1 which we ignore. Runs on the IO-lane worker thread when
    `EnginePlacement.io_lane` is set.
    """
    var p = path
    # SAFETY: `as_c_string_slice()` returns a NUL-terminated view owned by the
    # local `p`, held alive across the synchronous shim call. The kernel (inside
    # the shim) copies the path; no pointer escapes. `komira_prefetch_file`
    # opens RO, posix_fadvise(WILLNEED) + sequentially reads to fault the pages,
    # then closes — all in C. The return is ignored (best-effort).
    var rc = external_call["komira_prefetch_file", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int64(max_bytes)
    )
    _ = rc


def fsync_dir(dir: String) raises:
    """Flush the directory inode at `dir` to underlying storage via
    `fsync(2)` on a read-only directory fd. Makes any newly-created /
    renamed directory entries under `dir` durable across a power loss.

    Returns only after the kernel acknowledges the directory metadata is
    persisted. Encapsulation: NO raw fd escapes; the directory fd is
    opened, fsync'd, and closed inside the fn body.

    Called by the spill storage's `sync()` after fsync'ing each live
    chunk's data, so the chunk filenames themselves survive a power loss.

    Raises if the directory cannot be opened or if `fsync(2)` returns
    non-zero.
    """
    var p = dir
    # SAFETY: `as_c_string_slice()` returns a NUL-terminated view owned by
    # the local `p`, held alive across the synchronous openat(2). The kernel
    # copies the path; no pointer escapes. O_RDONLY (flags=0), no O_CREAT —
    # the directory must already exist; the mode arg is ignored.
    var fd = external_call["komira_openat_creat", Int32](
        _at_fdcwd(),
        p.as_c_string_slice().unsafe_ptr(),
        _O_RDONLY,
        _DEFAULT_MODE,
    )
    if Int(fd) < 0:
        raise Error(
            "fsync_dir: openat() failed for directory '" + dir
            + "' (errno not surfaced)"
        )
    # SAFETY: synchronous syscall; the kernel reads no userspace pointer
    # state, just flushes the directory inode's dirent metadata for `fd`.
    var rc = external_call["komira_fsync", Int32](fd)
    var crc = external_call["close", Int32](fd)
    if Int(rc) != 0:
        raise Error(
            "fsync_dir: fsync(2) failed for directory '" + dir
            + "' (rc=" + String(Int(rc)) + ")"
        )
    _ = crc
