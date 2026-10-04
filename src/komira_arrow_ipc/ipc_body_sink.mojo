# =============================================================================
# ipc_body_sink.mojo — BodySink trait + conformers for Arrow IPC encoders
# (zero-staging-copy uncompressed write).
# =============================================================================
#
# # The problem this file solves
#
# Today's encoder (`ipc_encoder_dispatch.encode_record_batch_message`)
# allocates a `body = MmapAlignedBuffer[64](_estimate_body_size(columns))` per
# RecordBatch (24+ MB for lineitem SF1), then `_copy_bytes_into_body`
# memcpys every source Column buffer INTO this staging body, then the
# FileSink's `_write_arrow_bytes` (via `write_ipc_message`) copies it
# back OUT to the file handle. That's THREE memcpy passes per RB body —
# pyarrow's `arrow::io::OutputStream::Write` does ZERO.
#

# # Design overview
#
# The encoder's "body" interface is small — three ops:
#   * write_u8_at(cursor, byte)    — 0-7 alignment pad bytes per buffer
#   * copy_from_view_at(cursor, v) — bulk per-buffer memcpy (the hot path)
#   * capacity()                   — bounds-check diagnostic
#
# The `BodySink` trait exposes those ops + `bytes_written()` for cursor
# accounting. Two conformers:
#
#   1. `AlignedBufferBodySink` — back-compat: wraps an existing
#      `MmapAlignedBuffer[64]` (compressed path still needs contiguous body
#      for the codec).
#
#   2. `StreamingFileBodySink[O]` — streams body bytes through a small
#      1 MiB staging buffer; large per-buffer writes BYPASS the staging
#      entirely (the source bytes flow directly to the FileHandle via
#      `write_chunked`). Origin-parameterized on the borrowed FileHandle
#      it writes through.
#
# Per-DType encoders are parameterized as `fn encode_X[B: BodySink](
# col, mut body: B, body_cursor, mut buffers, mut nodes) raises -> Int`.
# Mojo monomorphizes per concrete `B` — no virtual dispatch, no perf
# penalty vs the pre-refactor concrete signature.
#
# # Cursor accounting
#
# The encoder's per-DType arms read `cursor` and write `aligned_cursor =
# _align_to_8_zero_pad(body, cursor)`, then record `BufferDescriptor(
# offset=Int64(aligned_cursor), length=Int64(byte_count))`. Offsets are
# RELATIVE to the start of the RecordBatch body. For both sinks,
# `bytes_written()` returns the body-relative cursor, and the cursor
# invariant is maintained (writes always at `cursor == bytes_written()`).
#
# # Encapsulation rule compliance
#
# - Public trait surface uses `ByteView[_]` — NO raw `UnsafePointer` in
#   public sigs.
# - `StreamingFileBodySink[O]` borrows a `FileHandle` via concrete origin
#   `O` (NO wildcard widening). The borrow is short-lived (one encode
#   call) so liveness is statically tracked.
# - No `unsafe_from_address`, no wildcard origins, no `take_pointee` on
#   struct fields.
# =============================================================================

from std.io import FileHandle

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_buffer.byte_view import ByteView
from komira_libc.chunked_write import write_chunked


# =============================================================================
# Constants
# =============================================================================


# 1 MiB staging buffer. Sized to:
#   - Amortize per-buffer write overhead on small buffers (validity
#     bitmaps for a 122,880-row RB = 15,360 bytes; offsets for STRING
#     col = ~491 KB; both fit inside the buffer).
#   - Bound peak heap residency (1 MiB per concurrent sink).
#   - Allow large per-buffer payloads (e.g. lineitem Int64 value buffers
#     ~983 KB) to either coalesce or BYPASS the staging via the
#     FLUSH-AND-PASSTHROUGH path in `copy_from_view_at` (any single copy
#     exceeding STAGING_CAPACITY/2 flushes staging then writes the source
#     view directly through `write_chunked`).
comptime STAGING_CAPACITY: Int = 1024 * 1024


# Any per-buffer write >= this size bypasses staging and flushes the
# source view DIRECTLY through write_chunked. 4 KiB is small enough to
# capture every real Arrow buffer (smallest is a single-row validity
# bitmap at 1 byte; smallest real-world buffer is a per-RB validity
# bitmap at length/8 bytes, typically 15 KB for a 122,880-row morsel)
# while large enough to leave the 0-7-byte alignment-pad write path
# (which fires N_buffers times per RB) in the coalesce regime.
comptime DIRECT_THRESHOLD: Int = 4 * 1024


# =============================================================================
# BodySink trait
# =============================================================================


trait BodySink:
    """The 3-op interface that Arrow IPC encoders use to emit body bytes.

    Cursor invariant: encoders always call write_u8_at(cursor, ...) or
    copy_from_view_at(cursor, ...) with cursor == bytes_written().
    Conformers MAY assume this and raise on out-of-order writes.

    Trait is intentionally minimal — the encoder's "complex" body logic
    (FB metadata, BufferDescriptor + FieldNode lists, body_cursor
    threading) lives in the encoder, NOT the sink.
    """

    def write_u8_at(mut self, cursor: Int, value: UInt8) raises:
        ...

    def copy_from_view_at(
        mut self, cursor: Int, src: ByteView[_]
    ) raises:
        ...

    def capacity(self) -> Int:
        ...

    def bytes_written(self) -> Int:
        ...


# =============================================================================
# AlignedBufferBodySink — back-compat conformer; wraps an MmapAlignedBuffer
# =============================================================================


struct AlignedBufferBodySink(BodySink, Movable):
    """BodySink conformer that buffers bytes into an internal
    `MmapAlignedBuffer[64]`. Used by the compressed encoder path
    (`encode_record_batch_message_compressed[C]`) that needs contiguous
    body bytes for the codec.

    Semantically identical to the pre-refactor `body: MmapAlignedBuffer[64]`
    pattern. After encode, the caller takes ownership of the inner
    buffer via `finalize()` and passes it to `write_ipc_message` or
    `codec.compress`.

    Buffer storage uses `Optional[MmapAlignedBuffer[64]]` so `finalize()`
    can `take()` the inner buffer without triggering the partial-move
    ban (`Optional.take()` is the canonical replacement primitive).
    """

    var _buf: Optional[OwnedAlignedBuffer]
    var _written: Int

    def __init__(out self, capacity_hint: Int):
        """Allocate the internal buffer.

        Args:
            capacity_hint: Upper bound on body bytes (computed by
                `_estimate_body_size(columns)` at the call site).
        """
        self._buf = Optional[OwnedAlignedBuffer](
            OwnedAlignedBuffer(capacity_hint)
        )
        self._written = 0

    def write_u8_at(mut self, cursor: Int, value: UInt8) raises:
        if not self._buf:
            raise Error(
                "AlignedBufferBodySink: buffer was finalize()d; cannot write"
            )
        ref b = self._buf.value()
        b.write_u8_at(cursor, value)
        var new_w = cursor + 1
        if new_w > self._written:
            self._written = new_w

    def copy_from_view_at(
        mut self, cursor: Int, src: ByteView[_]
    ) raises:
        if not self._buf:
            raise Error(
                "AlignedBufferBodySink: buffer was finalize()d; cannot write"
            )
        var n = src.len()
        ref b = self._buf.value()
        b.copy_from_view_at(cursor, src)
        var new_w = cursor + n
        if new_w > self._written:
            self._written = new_w

    def capacity(self) -> Int:
        if not self._buf:
            return 0
        return self._buf.value().capacity()

    def bytes_written(self) -> Int:
        return self._written

    def finalize(mut self) raises -> SharedAlignedBuffer[HeapRegion]:
        """Take ownership of the inner buffer (promoted to SAB[HeapRegion])
        with `length` set to the body byte count. Caller uses this for
        `write_ipc_message` or codec compression."""
        if not self._buf:
            raise Error(
                "AlignedBufferBodySink.finalize: already finalized"
            )
        var b = self._buf.take()
        b.set_length(Int64(self._written))

        return SharedAlignedBuffer.from_owned(b^)


# =============================================================================
# StreamingFileBodySink[O] — streaming conformer; writes through FileHandle
# =============================================================================


struct StreamingFileBodySink[O: Origin[mut=True]](BodySink):
    """BodySink conformer that streams body bytes directly to a borrowed
    FileHandle through a 1 MiB staging buffer.

    Write routing:
      - Small writes (<= STAGING_CAPACITY/2) coalesce in `_staging` until
        full, then flush via `write_chunked(handle, staged_bytes)`.
      - Large writes (> STAGING_CAPACITY/2; typical for primitive value
        buffers) flush staging first, then write the source bytes
        DIRECTLY through `write_chunked` — bypassing the staging copy
        entirely. This is the Tier B savings: the 1.16 GB of lineitem
        value bytes never get staged, they flow source → file.

    Non-Movable: holds a borrowed `Pointer[FileHandle, O]`. Constructed
    at the start of one `encode_record_batch_message_streaming` call,
    consumed at the end; lifetime tracked by `O`.

    NOT Copyable, NOT Movable (carries borrowed lifetime O); construct
    locally at the call site.
    """

    var _staging: OwnedAlignedBuffer
    var _staging_len: Int
    var _written: Int
    var _handle: Pointer[FileHandle, Self.O]

    def __init__(out self, handle: Pointer[FileHandle, Self.O]):
        """Construct a streaming sink that flushes through `handle`.

        Args:
            handle: Pointer to the destination FileHandle. The pointer's
                origin is captured by the type parameter `O` so the
                compiler enforces the handle stays alive for the sink's
                lifetime.
        """
        self._staging = OwnedAlignedBuffer(STAGING_CAPACITY)
        self._staging_len = 0
        self._written = 0
        self._handle = handle

    def write_u8_at(mut self, cursor: Int, value: UInt8) raises:
        if cursor != self._written:
            raise Error(
                "StreamingFileBodySink.write_u8_at: out-of-order cursor "
                + String(cursor)
                + " (expected "
                + String(self._written)
                + ")"
            )
        if self._staging_len == STAGING_CAPACITY:
            self._flush_staging()
        self._staging.write_u8_at(self._staging_len, value)
        self._staging_len += 1
        self._written += 1

    def copy_from_view_at(
        mut self, cursor: Int, src: ByteView[_]
    ) raises:
        if cursor != self._written:
            raise Error(
                "StreamingFileBodySink.copy_from_view_at: out-of-order "
                "cursor "
                + String(cursor)
                + " (expected "
                + String(self._written)
                + ")"
            )
        var n = src.len()
        if n == 0:
            return
        # PERF: bypass staging for any write >= DIRECT_THRESHOLD.
        # Threshold chosen low (4 KiB) so per-buffer bulk memcpys
        # ALWAYS flow source → file directly. The staging buffer is
        # reserved for the 0-7-byte alignment pad writes that
        # `_align_to_8_zero_pad` emits between adjacent
        # BufferDescriptor entries — those coalesce until a real
        # buffer copy flushes them.
        if n >= DIRECT_THRESHOLD:
            if self._staging_len > 0:
                self._flush_staging()
            write_chunked(self._handle[], src.into_span())
            self._written += n
            return
        # Small write path: coalesce into staging.
        if self._staging_len + n > STAGING_CAPACITY:
            self._flush_staging()
        self._staging.copy_from_view_at(self._staging_len, src)
        self._staging_len += n
        self._written += n

    def capacity(self) -> Int:
        # No hard cap; encoders use this for bounds-check diagnostic.
        return 1 << 62

    def bytes_written(self) -> Int:
        return self._written

    def _flush_staging(mut self) raises:
        """Drain the staging buffer to the FileHandle."""
        if self._staging_len == 0:
            return
        var view = self._staging.view_range_ro(0, self._staging_len)
        write_chunked(self._handle[], view.into_span())
        self._staging_len = 0

    def flush(mut self) raises:
        """Public flush — drain staging to the FileHandle. Caller MUST
        invoke this at end-of-body so all bytes reach the file."""
        self._flush_staging()
