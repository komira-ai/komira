# =============================================================================
# WritableHandle / ReadableHandle — the byte-stream traits for v0.4 Arrow IPC.
# =============================================================================
#
# Two trait surfaces that
# abstract over "where bytes go" / "where bytes come from" so the
# `df.write_arrow_stream(handle)` / `ctx.read_arrow_stream(handle)` SDK
# methods can target a file, stdout/stdin, or an in-memory buffer behind
# one polymorphic signature.
#
# The traits are deliberately MINIMAL — `write_all(Span[UInt8])` + `close()`
# on the writer; `read_all() -> List[UInt8]` + `close()` on the reader.
# v0.4 consumes the whole stream into memory before parsing (the Arrow IPC
# decoder takes a `List[UInt8]`-backed buffer), so we do not need a
# streaming-read API yet. v0.5 may add `read_into(buf, n) -> Int` for
# constant-memory chunked decode; we leave a TODO marker rather than
# pre-emptively widening the trait.
#
# === Conformers shipped here ===
#
#   - `FileHandleWriter` — wraps `std.io.FileHandle` opened in "w" mode.
#     Factories: `from_path(String)` / `from_stdout()`. The stdout factory
#     opens `/dev/stdout` (POSIX universal — macOS + Linux both expose it).
#
#   - `FileHandleReader` — wraps `std.io.FileHandle` opened in "r" mode.
#     Factories: `from_path(String)` / `from_stdin()` (`/dev/stdin`).
#
#   - `BytesHandle` — owns a `List[UInt8]` buffer. Conforms to BOTH
#     `WritableHandle` AND `ReadableHandle`. Write-mode appends; read-mode
#     reads from a cursor that starts at 0 and advances. `as_reader()` is
#     a fluent helper that resets the cursor — the same struct value
#     supports a write-phase followed by a read-phase, useful for the
#     in-memory round-trip test pattern documented in
#     pseudocode.
#
# === SAFETY contract on each conformer ===
#
#   - No raw `UnsafePointer` crosses the trait boundary. `write_all` takes
#     `Span[UInt8, _]` (the canonical view-of-bytes in this codebase, see
#     `komira_csv/reader.mojo` for the established idiom); `read_all`
#     returns `List[UInt8]` by value.
#   - No wildcard origins. `Span[UInt8, _]` infers a concrete origin per
#     call site.
#   - No `unsafe_from_address=Int(...)`.
#   - No partial-move-via-UnsafePointer. `FileHandleWriter` /
#     `FileHandleReader` use `Optional[FileHandle].take()` to extract the
#     inner FileHandle on close (idempotent — `take()` on `None` returns
#     `None`, second `close()` is a no-op).
#   - `BytesHandle` uses `List[UInt8]` (safe across destroy-recreate: `List[UInt8]` is the
#     canonical byte buffer in this codebase; `UInt8` is a Movable POD
#     with no heap fields).
#
# === Why explicit `FileHandleWriter` / `FileHandleReader` instead of
# extending `FileHandle` directly ===
#
# `std.io.FileHandle` is not ours to extend, so we use the
# explicit adapter names.
# =============================================================================

from std.io import FileHandle

#
# Chunked_write import removed — FileHandleWriter now
# routes through LocalFs[NoopSink].write_at which absorbs the 64 MiB
# chunking workaround inside the trait body.
from komira_async.fs.local_fs import LocalFs, LocalWriteFile
from komira_async.fs.file_system import WriteMode
from komira_async.ops.waker_sink import NoopSink


# =============================================================================
# Trait surfaces
# =============================================================================


trait WritableHandle(Movable, Deinitable):
    """A byte-stream sink. `df.write_arrow_stream(handle)` writes the Arrow
    IPC framed-stream byte sequence through this trait.

    Conformers in v0.4:
      - `FileHandleWriter` — file / stdout.
      - `BytesHandle` — in-memory buffer (also conforms to `ReadableHandle`
        for round-trip use).

    Method contract:
      - `write_all(bytes)` MUST write every byte of `bytes` before returning.
        Conformers that buffer internally MAY defer the OS-level write; the
        contract is only that the bytes are committed by the time `close()`
        returns.
      - `close()` MUST be idempotent — a second `close()` is a no-op. The
        underlying resource (file descriptor / buffer) is released on the
        first call.
    """

    def write_all(mut self, bytes: Span[UInt8, _]) raises:
        """Write the entire span of bytes to the underlying stream. The call
        does NOT return until every byte has been accepted by the conformer
        (which may still be in an internal buffer; see `close`)."""
        ...

    def close(mut self) raises:
        """Flush + release the underlying resource. Idempotent — safe to
        call twice; the second call is a no-op."""
        ...


trait ReadableHandle(Movable, Deinitable):
    """A byte-stream source. `ctx.read_arrow_stream(handle)` consumes the
    Arrow IPC framed-stream byte sequence through this trait.

    Conformers in v0.4:
      - `FileHandleReader` — file / stdin.
      - `BytesHandle` — in-memory buffer.

    Method contract:
      - `read_all()` MUST read everything from the current position to EOF
        and return it as one owned `List[UInt8]`. v0.4 callers parse the
        whole-stream buffer; v0.5 may grow a chunked `read_into(buf, n)`
        method.
      - `close()` MUST be idempotent.
    """

    def read_all(mut self) raises -> List[UInt8]:
        """Read from the current position to EOF and return the bytes as
        a freshly-allocated `List[UInt8]`. The conformer's stream is
        positioned at EOF after this returns."""
        ...

    def close(mut self) raises:
        """Release the underlying resource. Idempotent — safe to call twice;
        the second call is a no-op."""
        ...


# =============================================================================
# FileHandleWriter — `std.io.FileHandle` in "w" mode.
# =============================================================================


struct FileHandleWriter(Movable, Deinitable, WritableHandle):
    """`WritableHandle` conformer over `FileSystem.WriteFile` (LocalFs).


    It wraps a
    `LocalWriteFile` (LocalFs's WriteFile conformer). The
    `LocalWriteFile` wraps a `RawWriteFd` internally; writes route
    through `LocalFs[NoopSink].write_at` which absorbs the 64 MiB
    chunking workaround for the Mojo 1.0.0b1 stdlib `FileHandle.write`
    >2 GB silent-flush bug.

    Use `from_path(path)` for file output; `from_stdout()` for stdout.

    SAFETY: the inner `Optional[LocalWriteFile]` is `Some` while open
    and `None` after `close()`. `take()`-based close idempotency
    matches the `_FileSinkState.finish_jsonl` idiom in
    `file_sink.mojo:867` (which also routes close through
    `LocalFs.close_write(f^)` as the explicit commit boundary).
    """

    var _handle: Optional[LocalWriteFile]

    def __init__(out self, var handle: LocalWriteFile):
        """Wrap an already-opened LocalWriteFile. The handle is moved
        in; ownership transfers to the writer."""
        self._handle = Optional[LocalWriteFile](handle^)

    @staticmethod
    def from_path(path: String) raises -> FileHandleWriter:
        """Open `path` for write (truncating any existing file)."""
        var fs = LocalFs[NoopSink].new()
        var f = fs.open_write(path, WriteMode.create_truncate())
        return FileHandleWriter(f^)

    @staticmethod
    def from_stdout() raises -> FileHandleWriter:
        """Open stdout via `/dev/stdout` (POSIX universal — macOS + Linux).

        Note: re-opening stdout via `/dev/stdout` gets a fresh file
        descriptor pointed at the same kernel stream; this matches the
        idiom used by JSON/CSV streaming tools (jq, csvtool) and works
        identically on both supported platforms.
        """
        var fs = LocalFs[NoopSink].new()
        var f = fs.open_write(
            String("/dev/stdout"), WriteMode.create_truncate()
        )
        return FileHandleWriter(f^)

    def write_all(mut self, bytes: Span[UInt8, _]) raises:
        """Write every byte to the underlying file via
        `LocalFs[NoopSink].write_at`. The 64 MiB chunking workaround
        for the Mojo 1.0.0b1 stdlib `FileHandle.write` >2 GB silent-
        flush bug is absorbed inside `LocalFs.write_at` body — sub-
        64 MiB writes take the single-write fast path; larger writes
        chunk at 64 MiB."""
        if not self._handle:
            raise Error(
                "FileHandleWriter.write_all: handle is closed"
            )
        if len(bytes) == 0:
            return
        var fs = LocalFs[NoopSink].new()
        _ = fs.write_at(self._handle.value(), bytes)

    def close(mut self) raises:
        """Idempotent close via `LocalFs.close_write(f^)` — surfaces
        close(2) errors to the caller (raises on close failure).
        Optional.take() extracts the LocalWriteFile by move; close_write
        consumes it.


        previously called `_ = self._handle.take()` to drop via
        FileHandle's destructor; now routes through close_write so
        the commit boundary is explicit.

        Second `close()` sees `_handle` already-None and is a no-op.
        """
        if self._handle:
            var fs = LocalFs[NoopSink].new()
            var f = self._handle.take()
            fs.close_write(f^)


# =============================================================================
# FileHandleReader — `std.io.FileHandle` in "r" mode.
# =============================================================================


struct FileHandleReader(Movable, Deinitable, ReadableHandle):
    """`ReadableHandle` conformer over `std.io.FileHandle`. Use
    `from_path(path)` for file input; `from_stdin()` for stdin.

    SAFETY: same shape as `FileHandleWriter` — inner `Optional[FileHandle]`
    is `Some` while open, `None` after `close()`. Idempotent close.
    """

    var _handle: Optional[FileHandle]

    def __init__(out self, var handle: FileHandle):
        """Wrap an already-opened FileHandle (transfer ownership)."""
        self._handle = Optional[FileHandle](handle^)

    @staticmethod
    def from_path(path: String) raises -> FileHandleReader:
        """Open `path` for read."""
        var h = FileHandle(path, "r")
        return FileHandleReader(h^)

    @staticmethod
    def from_stdin() raises -> FileHandleReader:
        """Open stdin via `/dev/stdin` (POSIX universal — macOS + Linux)."""
        var h = FileHandle(String("/dev/stdin"), "r")
        return FileHandleReader(h^)

    def read_all(mut self) raises -> List[UInt8]:
        """Read from current position to EOF, returning the bytes. Uses the
        same `seek + read_bytes(file_size)` pattern as
        `plan_compiler_scan_filter.mojo:429` / `spill_writer.mojo:346`.
        """
        if not self._handle:
            raise Error(
                "FileHandleReader.read_all: handle is closed"
            )
        ref f = self._handle.value()
        # Seek to end to discover file size; rewind to start; slurp.
        _ = f.seek(0, 2)  # SEEK_END
        var file_size = Int(f.seek(0, 1))  # SEEK_CUR == tell
        _ = f.seek(0, 0)  # SEEK_SET (rewind)
        if file_size <= 0:
            return List[UInt8]()
        var raw = f.read_bytes(file_size)
        return raw^

    def close(mut self) raises:
        """Idempotent close. See FileHandleWriter.close."""
        if self._handle:
            var h = self._handle.take()
            h.close()


# =============================================================================
# BytesHandle — in-memory buffer, conforms to BOTH WritableHandle AND
# ReadableHandle.
# =============================================================================


struct BytesHandle(Movable, Deinitable, WritableHandle, ReadableHandle):
    """In-memory `List[UInt8]`-backed handle. Conforms to BOTH writable and
    readable trait surfaces.

    Lifecycle:
      1. Construct empty via `BytesHandle()`.
      2. Pass to `df.write_arrow_stream(buf)` (writer mode — appends).
      3. Call `as_reader()` to reset the read cursor to 0.
      4. Pass to `ctx.read_arrow_stream(buf)` (reader mode — consumes from
         cursor to end on `read_all`).

    The "phase-switch" model (write-then-read) matches
    pseudocode. The struct does NOT enforce phase ordering at the type
    level — callers that interleave writes and reads will get
    write-then-read-resumes behavior, with reads picking up at the cursor's
    current position.

    SAFETY:
      - `_buf` is a plain `List[UInt8]`. `UInt8` is a POD Movable; no destroy-recreate
        hazard.
      - `_cursor` is `Int`. No pointer arithmetic at the trait boundary.
      - `close()` clears the buffer + zeroes the cursor; idempotent.
    """

    var _buf: List[UInt8]
    var _cursor: Int

    def __init__(out self):
        """Construct an empty BytesHandle. The buffer is empty; the cursor
        is 0."""
        self._buf = List[UInt8]()
        self._cursor = 0

    @staticmethod
    def from_bytes(var bytes: List[UInt8]) -> BytesHandle:
        """Construct a BytesHandle pre-populated with `bytes`, cursor at 0.
        Useful for the reader-only use case (e.g. round-trip a known byte
        sequence through `ctx.read_arrow_stream`)."""
        var h = BytesHandle()
        h._buf = bytes^
        return h^

    # ------------------------------------------------------------------
    # WritableHandle
    # ------------------------------------------------------------------

    def write_all(mut self, bytes: Span[UInt8, _]) raises:
        """Append every byte of `bytes` to the internal buffer. The cursor
        is NOT advanced (cursor is for reads only)."""
        # Per-byte append is the idiom in this codebase for List[UInt8]
        # extension (the engine's aggregate spill writer does the same).
        # The Mojo 1.0.0b1 List does not yet expose an extend(Span) method
        # we can rely on across the supported stdlib versions; the explicit
        # loop is portable and respects the encapsulation rule.
        var n = len(bytes)
        for i in range(n):
            self._buf.append(bytes[i])

    # ------------------------------------------------------------------
    # ReadableHandle
    # ------------------------------------------------------------------

    def read_all(mut self) raises -> List[UInt8]:
        """Read from the cursor to the end of the buffer and return those
        bytes. The cursor advances to end-of-buffer; subsequent
        `read_all()` calls return empty lists.
        """
        var remaining = len(self._buf) - self._cursor
        if remaining <= 0:
            self._cursor = len(self._buf)
            return List[UInt8]()
        var out = List[UInt8](capacity=remaining)
        for i in range(remaining):
            out.append(self._buf[self._cursor + i])
        self._cursor = len(self._buf)
        return out^

    # ------------------------------------------------------------------
    # BytesHandle-specific helpers (not on either trait)
    # ------------------------------------------------------------------

    def as_reader(mut self):
        """Reset the read cursor to 0 so the buffer can be consumed from
        the start. Idempotent. The buffer's contents are NOT cleared —
        this is the "phase-switch" call documented in the file header.
        """
        self._cursor = 0

    def bytes_view(self) -> Span[UInt8, origin_of(self._buf)]:
        """Read-only view of the underlying buffer (the entire buffer, not
        just the post-cursor region). Test-only — production callers should
        use `read_all()` instead."""
        return Span(self._buf)

    def num_bytes(self) -> Int:
        """Total bytes in the buffer (independent of cursor)."""
        return len(self._buf)

    def cursor(self) -> Int:
        """Current read cursor position."""
        return self._cursor

    # ------------------------------------------------------------------
    # Shared trait method
    # ------------------------------------------------------------------

    def close(mut self) raises:
        """Drop the buffer + zero the cursor. Idempotent."""
        # Replace with an empty List; the moved-out List drops cleanly.
        self._buf = List[UInt8]()
        self._cursor = 0
