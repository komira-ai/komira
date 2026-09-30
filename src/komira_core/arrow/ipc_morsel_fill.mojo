# =============================================================================
# ipc_morsel_fill.mojo -- the ARROW-IPC container FILL against the MorselView
#                         seam.
# =============================================================================
#
# WHAT THIS IS
#
# `IpcMorselFill` is the Arrow-IPC sibling of ENGINE-V2's `Chunk`: a PERSISTENT,
# reset-not-reconstruct container that is filled per RecordBatch frame and
# consumed through `IpcMorselView`, a `MorselView` conformer. Because the fused
# fold reads EXCLUSIVELY through the `MorselView` / `NumericColView` trait
# surface (`komira_core/collections/morsel_view.mojo`), `fold[IpcMorselView]`
# is the SAME kernel as `fold[BatchView]` / `fold[ChunkView]` -- one operator,
# N formats. This file adds a format, not a kernel.
#
# WHY ARROW-IPC IS THE ZERO-COPY ARM (and CSV/JSONL are not)
#
# An Arrow IPC RecordBatch message body IS the columnar layout: each fixed-width
# column's values live as a contiguous, little-endian, natively-typed run of
# bytes at `(body_pos + Buffer.offset)`. So the "fill" for Arrow IPC is
# **descriptor-only**: we parse the flatbuffer metadata (O(n_cols), NOT O(rows))
# and record, per column, the absolute byte offset of its values buffer inside
# the frame. Reads then go straight out of those bytes with
# `frame.load_simd[dt, W]`. There is NO per-value copy, NO `Column` allocation,
# NO `RecordBatch` construction, and NO arena staging on this path.
#
# Contrast the existing reader (`decode_record_batch_message`), which is
# COPY-ON-READ: it allocates a fresh buffer per column and memcpys the body
# bytes into it, then builds `Column[HeapRegion]` -> `RecordBatch` ->
# `BatchView`. This fill deletes that whole staircase for the fixed-width
# numeric projection.
#
# CSV / JSONL cannot have this property and we do not claim it for them: there
# is no zero-copy view of a parsed integer -- the text `"12345"` must become 8
# bytes of int64 somewhere. Their win from this seam is the persistent
# reset-not-reconstruct container + fold-while-hot, not zero-copy.
#
# WHAT DECLINES (honest scope -- the fill never guesses)
#
#   * A COMPRESSED body (`BodyCompression.codec != -1`): the body bytes are not
#     the layout. The whole fill DECLINES (returns False) -> caller falls back
#     to `decode_record_batch_message`, which decompresses.
#   * BOOL: bit-packed values buffer -- not a fixed-width numeric run.
#   * STRING / BINARY / LARGE_* / DICTIONARY / NULL / nested: not fixed-width.
#     These columns are marked DECLINED individually; the fill still succeeds
#     and serves the fixed-width columns beside them (the buffer cursor is
#     advanced correctly past them).
#   * More than `MAX_IPC_FILL_COLS` columns.
#
# A DECLINED column answers `col_is_declined(idx) == True`; reading it is a
# programming error (debug-trapped), exactly like reading an unbound `Chunk`
# column.
#
# SAFETY / ENCAPSULATION
#   * NO `UnsafePointer` in any signature here; the view holds
#     `Pointer[IpcMorselFill, origin]` (origin-tracked) and all byte access goes
#     through `SharedAlignedBuffer`'s typed `load_simd` / `read_u8_at`.
#   * NO wildcard origins. `IpcColDesc` is POD (an InlineArray element, so no
#     stale-pointer hazard across destroy and recreate).
#   * Untrusted `(offset, length)` from the wire are validated against the frame
#     with an EXPLICIT raise before any descriptor is recorded (release builds
#     elide `view_range_ro`'s debug_assert).
#   * Generation stamp: a view that survives a `reset()` / refill is CAUGHT
#     (`is_valid()`), never silently reading the next batch's bytes.
#
# Cross-references:
#   - komira_core/collections/morsel_view.mojo -- the traits.
#   - the parquet/arena fill in the engine    -- the sibling.
# =============================================================================

from std.collections import Array
from std.sys import size_of

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow.ipc_flatbuf import (
    RecordBatchDescriptor,
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_record_batch,
    MESSAGE_HEADER_RECORD_BATCH,
)
from komira_core.collections.morsel_view import MorselView, NumericColView
from komira_core.io.heap_region import HeapRegion


# Max columns one fill descriptor table carries. POD InlineArray.
comptime MAX_IPC_FILL_COLS: Int = 64

# Column descriptor kinds.
comptime IPC_COL_UNBOUND: UInt8 = 0
comptime IPC_COL_FLAT: UInt8 = 1  # zero-copy fixed-width numeric run
comptime IPC_COL_DECLINED: UInt8 = 2  # present in the batch, not fold-readable

# `BodyCompression.codec` sentinel meaning "uncompressed body".
comptime IPC_CODEC_UNCOMPRESSED: Int8 = -1


# =============================================================================
# Type helpers -- the fixed-width matrix + wire buffer counts.
#
# These MIRROR `ipc_decoder_dispatch._fixed_width_bytes_for` /
# `_buffer_count_for`. They are duplicated (not imported) because those are
# module-private helpers of the copy-on-read decoder; the byte-oracle
# test in komira_engine_operators is what keeps the two
# in agreement -- any drift misaligns the buffer cursor and the oracle fails.
# =============================================================================


@always_inline
def ipc_fixed_width_bytes(t: ArrowType) -> Int:
    """Bytes-per-element for a fixed-width numeric/temporal Arrow type whose
    IPC values buffer is a dense native-endian run. Returns 0 for anything that
    is not (BOOL is bit-packed and returns 0 by design)."""
    if t == ArrowType.INT8 or t == ArrowType.UINT8:
        return 1
    if t == ArrowType.INT16 or t == ArrowType.UINT16:
        return 2
    if t == ArrowType.INT32 or t == ArrowType.UINT32:
        return 4
    if t == ArrowType.INT64 or t == ArrowType.UINT64:
        return 8
    if t == ArrowType.FLOAT16:
        return 2
    if t == ArrowType.FLOAT32:
        return 4
    if t == ArrowType.FLOAT64:
        return 8
    if t == ArrowType.DATE32:
        return 4
    if t == ArrowType.DATE64:
        return 8
    if t == ArrowType.TIME32_S or t == ArrowType.TIME32_MS:
        return 4
    if t == ArrowType.TIME64_US or t == ArrowType.TIME64_NS:
        return 8
    if (
        t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
    ):
        return 8
    if (
        t == ArrowType.DURATION_S
        or t == ArrowType.DURATION_MS
        or t == ArrowType.DURATION_US
        or t == ArrowType.DURATION_NS
    ):
        return 8
    return 0


@always_inline
def ipc_buffer_count(t: ArrowType) raises -> Int:
    """Wire buffer count for a column of this ArrowType (Arrow columnar format buffer layout).
    Mirrors `ipc_decoder_dispatch._buffer_count_for`."""
    if t == ArrowType.NULL:
        return 0
    if t == ArrowType.BOOL:
        return 2  # validity + value bitmap
    if (
        t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
    ):
        return 3  # validity + offsets + data
    if t == ArrowType.DICTIONARY:
        return 2  # validity + int32 codes
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        return 2
    if ipc_fixed_width_bytes(t) > 0:
        return 2  # validity + values
    raise Error(
        "ipc_buffer_count: ArrowType "
        + String(Int(t.type_id))
        + " is not supported by the Arrow-IPC MorselView fill"
    )


@always_inline
def ipc_node_count(t: ArrowType) -> Int:
    """FieldNode count for a column of this ArrowType. One node per leaf; the
    fill declines nested types outright so every supported type is 1 node."""
    return 1


def _read_rb_descriptor[
    o: Origin[mut=False]
](ref [o] meta: SharedAlignedBuffer[HeapRegion]) raises -> RecordBatchDescriptor:
    """Decode the RecordBatch flatbuffer table out of a metadata slice anchored
    at byte 0. Kept as a free function so the `FlatbufReader`'s borrow of the
    caller's metadata buffer ENDS at the return (the descriptor lifts nodes /
    buffers into owned Lists), leaving the caller free to mutate itself."""
    var reader = flatbuf_reader_over(meta)
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(
            "IpcMorselFill: expected RECORD_BATCH header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))
            + "), got "
            + String(Int(msg.header_tag))
        )
    return read_record_batch(reader, msg.header_table_pos)


# =============================================================================
# IpcColDesc -- the POD per-column descriptor (InlineArray element; no heap
# field, no tracked origin).
# =============================================================================


struct IpcColDesc(Copyable, Movable, ImplicitlyCopyable):
    """Where one column's bytes live INSIDE the IPC frame.

    Fields:
        kind:         IPC_COL_* tag.
        type_id:      the ArrowType id (runtime shadow; the typed read takes
                      DType at comptime -- the only comptime axis).
        elem_bytes:   bytes per element of the values run.
        values_pos:   ABSOLUTE byte offset of the values buffer in the frame
                      (`body_pos + Buffer.offset`), or -1 when declined.
        validity_pos: ABSOLUTE byte offset of the validity bitmap, or -1 when
                      the column has no bitmap (all rows valid).
        length:       rows in this column.
        all_valid:    True == FieldNode.null_count == 0 (no-null fast path).
    """

    var kind: UInt8
    var type_id: UInt8
    var elem_bytes: Int
    var values_pos: Int
    var validity_pos: Int
    var length: Int
    var all_valid: Bool

    @always_inline
    def __init__(out self):
        """An UNBOUND slot (the pre-fill state)."""
        self.kind = IPC_COL_UNBOUND
        self.type_id = 0
        self.elem_bytes = 0
        self.values_pos = -1
        self.validity_pos = -1
        self.length = 0
        self.all_valid = True

    @always_inline
    def is_flat(self) -> Bool:
        return self.kind == IPC_COL_FLAT


# =============================================================================
# IpcMorselFill -- the persistent reset-not-reconstruct Arrow-IPC container.
# =============================================================================


struct IpcMorselFill(Movable):
    """Persistent Arrow-IPC morsel container: constructed ONCE, refilled per
    RecordBatch frame, consumed through `IpcMorselView`.

    The descriptor table (`cols`) is inline-stored and the flatbuffer-metadata
    scratch (`meta`) is grow-only, so a steady-state refill does ZERO
    allocation beyond taking ownership of the incoming frame -- and the frame
    itself may be an mmap borrow (`SharedAlignedBuffer.borrow_from_mmap`), in
    which case the entire read path touches only mapped file pages.

    Safety: no wildcard-origin field, no owning raw pointer. `frame` / `meta`
    are `SharedAlignedBuffer` (Arc-backed); `cols` is a POD `InlineArray`.
    """

    var frame: SharedAlignedBuffer[HeapRegion]
    var meta: SharedAlignedBuffer[HeapRegion]
    var cols: Array[IpcColDesc, MAX_IPC_FILL_COLS]
    var n_cols: Int
    var n_rows: Int
    var generation: UInt64
    var filled: Bool

    def __init__(out self):
        """An empty container. Bytes arrive via `fill_from_frame`."""
        self.frame = SharedAlignedBuffer[HeapRegion].heap_owned(1)
        self.meta = SharedAlignedBuffer[HeapRegion].heap_owned(1)
        self.cols = Array[IpcColDesc, MAX_IPC_FILL_COLS](
            fill=IpcColDesc()
        )
        self.n_cols = 0
        self.n_rows = 0
        self.generation = 0
        self.filled = False

    # -------------------------------------------------------------------------
    # Per-batch mutation.
    # -------------------------------------------------------------------------

    def reset(mut self):
        """O(1) reset: clear the fill state + bump the generation. The
        descriptor table's storage and the metadata scratch SURVIVE (that is
        the reset-not-reconstruct property). Any `IpcMorselView` leaked past
        this point is invalidated by the generation bump."""
        self.n_cols = 0
        self.n_rows = 0
        self.filled = False
        self.generation += 1

    def fill_from_frame(
        mut self,
        var frame: SharedAlignedBuffer[HeapRegion],
        schema_types: List[ArrowType],
    ) raises -> Bool:
        """Take ownership of one Arrow IPC RecordBatch message `frame` and
        record, per column, where its bytes live. ZERO per-row work.

        Returns True when the fill succeeded (some or all columns FLAT), and
        False when the batch as a whole DECLINES -- a compressed body, or more
        columns than `MAX_IPC_FILL_COLS`. On False the caller must fall back to
        `decode_record_batch_message`; the container is left reset and empty.

        Raises on a structurally invalid frame (bad framing, wrong message
        header, node/buffer count mismatch, or an out-of-frame Buffer
        descriptor) -- never a silent out-of-bounds read.
        """
        self.reset()

        var n_cols = len(schema_types)
        if n_cols > MAX_IPC_FILL_COLS:
            return False

        var f = parse_ipc_message(frame)

        # Lift the FB metadata slice into the persistent scratch at byte 0 so
        # FlatbufReader's root_offset anchors correctly (the reader is
        # base-relative). This is the ONE copy on this path and it is
        # O(metadata) -- hundreds of bytes -- never O(rows).
        var meta_size = f.metadata_size
        self.meta.reserve(meta_size if meta_size > 0 else 1)
        self.meta.set_length(meta_size if meta_size > 0 else 1)
        if meta_size > 0:
            self.meta.copy_from_view_at(
                0, frame.view_range_ro(f.metadata_pos, meta_size)
            )
            self.meta.set_length(meta_size)

        # The FlatbufReader's borrow of `self.meta` is scoped inside the helper.
        var rb = _read_rb_descriptor(self.meta)
        var rb_length = Int(rb.length)

        # A compressed body is NOT the layout -> whole-batch DECLINE.
        if rb.body_compression_codec != IPC_CODEC_UNCOMPRESSED:
            return False

        # Node / buffer count agreement with the caller's schema.
        var expected_nodes = 0
        var expected_buffers = 0
        for i in range(n_cols):
            expected_nodes += ipc_node_count(schema_types[i])
            expected_buffers += ipc_buffer_count(schema_types[i])
        if len(rb.nodes) != expected_nodes:
            raise Error(
                "IpcMorselFill.fill_from_frame: FieldNode count mismatch (got "
                + String(len(rb.nodes))
                + ", expected "
                + String(expected_nodes)
                + ")"
            )
        if len(rb.buffers) != expected_buffers:
            raise Error(
                "IpcMorselFill.fill_from_frame: Buffer count mismatch (got "
                + String(len(rb.buffers))
                + ", expected "
                + String(expected_buffers)
                + ")"
            )

        # Explicit bounds gate on every untrusted (offset, length) BEFORE any
        # descriptor is recorded. Release builds elide `view_range_ro`'s
        # internal debug_assert, so this raise is the only real guard.
        var frame_len = frame.len()
        var body_pos = f.body_pos
        var body_size = frame_len - body_pos
        for i in range(len(rb.buffers)):
            var off = Int(rb.buffers[i].offset)
            var blen = Int(rb.buffers[i].length)
            if blen < 0:
                raise Error(
                    "IpcMorselFill.fill_from_frame: Buffer["
                    + String(i)
                    + "] has negative length"
                )
            if blen == 0:
                continue
            var escapes = off < 0 or off > body_size or blen > body_size
            if not escapes:
                escapes = off + blen > body_size
            if escapes:
                raise Error(
                    "IpcMorselFill.fill_from_frame: Buffer["
                    + String(i)
                    + "] range ["
                    + String(off)
                    + ", "
                    + String(off + blen)
                    + ") escapes the "
                    + String(body_size)
                    + "-byte message body"
                )

        # Descriptor pass -- O(n_cols).
        var node_idx = 0
        var buf_idx = 0
        for i in range(n_cols):
            var t = schema_types[i]
            var nbufs = ipc_buffer_count(t)
            var width = ipc_fixed_width_bytes(t)
            var d = IpcColDesc()
            d.type_id = t.type_id
            d.length = rb_length
            if width > 0:
                # validity @ buf_idx, values @ buf_idx + 1.
                ref vbuf = rb.buffers[buf_idx + 1]
                var nulls = Int(rb.nodes[node_idx].null_count)
                ref vld = rb.buffers[buf_idx]
                d.kind = IPC_COL_FLAT
                d.elem_bytes = width
                d.values_pos = body_pos + Int(vbuf.offset)
                d.all_valid = nulls == 0
                if nulls == 0 or Int(vld.length) == 0:
                    d.validity_pos = -1
                    d.all_valid = True
                else:
                    d.validity_pos = body_pos + Int(vld.offset)
                # The values run must actually hold `rb_length` elements.
                if Int(vbuf.length) < rb_length * width:
                    raise Error(
                        "IpcMorselFill.fill_from_frame: column "
                        + String(i)
                        + " values buffer is "
                        + String(Int(vbuf.length))
                        + " bytes, short of "
                        + String(rb_length * width)
                        + " for "
                        + String(rb_length)
                        + " rows"
                    )
            else:
                d.kind = IPC_COL_DECLINED
            self.cols[i] = d
            node_idx += ipc_node_count(t)
            buf_idx += nbufs

        self.n_cols = n_cols
        self.n_rows = rb_length
        self.frame = frame^
        self.filled = True
        return True

    # -------------------------------------------------------------------------
    # Read primitives (consumed by IpcMorselView / IpcColView).
    # -------------------------------------------------------------------------

    @always_inline
    def gen(self) -> UInt64:
        return self.generation

    @always_inline
    def num_rows(self) -> Int:
        return self.n_rows

    @always_inline
    def num_cols(self) -> Int:
        return self.n_cols

    @always_inline
    def col_is_declined(self, idx: Int) -> Bool:
        return not self.cols[idx].is_flat()

    @always_inline
    def col_length(self, idx: Int) -> Int:
        return self.cols[idx].length

    @always_inline
    def col_has_validity(self, idx: Int) -> Bool:
        return self.cols[idx].validity_pos >= 0

    @always_inline
    def load[dt: DType, W: Int](self, idx: Int, row_i: Int) -> SIMD[dt, W]:
        """ZERO-COPY SIMD read: `W` lanes of `dt` straight out of the IPC frame
        bytes at `values_pos + row_i * size_of[dt]()`. No staging buffer."""
        debug_assert(
            idx >= 0 and idx < self.n_cols,
            "IpcMorselFill.load: column index out of range",
        )
        debug_assert(
            self.cols[idx].is_flat(),
            "IpcMorselFill.load: column DECLINED (not a fixed-width numeric"
            " run) -- read it through the copy-on-read decoder instead",
        )
        debug_assert(
            self.cols[idx].elem_bytes == size_of[dt](),
            "IpcMorselFill.load: comptime DType width does not match the"
            " column's wire element width",
        )
        return self.frame.load_simd[dt, W](
            self.cols[idx].values_pos + row_i * size_of[dt]()
        )

    @always_inline
    def is_null(self, idx: Int, row: Int) -> Bool:
        """Arrow validity bitmap probe (LSB-first). False for a column with no
        bitmap (all-valid fast path)."""
        var vp = self.cols[idx].validity_pos
        if vp < 0:
            return False
        var byte = self.frame.read_u8_at(vp + (row >> 3))
        return ((byte >> UInt8(row & 7)) & UInt8(1)) == UInt8(0)


# =============================================================================
# IpcColView[dtype, origin] -- the frame-resident NumericColView.
# =============================================================================


struct IpcColView[dtype: DType, origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, NumericColView
):
    """Zero-copy typed borrow over ONE fixed-width numeric column of an Arrow
    IPC frame. Structural isomorph of `ColView` (RecordBatch-backed) and
    `ChunkColView` (arena-backed) -- same `load[W]` arithmetic after the read,
    only the backing store differs (here: the IPC message body itself)."""

    comptime DT: DType = Self.dtype

    var _fill: Pointer[IpcMorselFill, Self.origin]
    var _idx: Int

    @always_inline
    def __init__(out self, ptr: Pointer[IpcMorselFill, Self.origin], idx: Int):
        self._fill = ptr
        self._idx = idx

    @always_inline
    def load[W: Int](self, i: Int) -> SIMD[Self.dtype, W]:
        return self._fill[].load[Self.dtype, W](self._idx, i)

    @always_inline
    def has_validity(self) -> Bool:
        return self._fill[].col_has_validity(self._idx)

    def validity_load[W: Int](self, i: Int) raises -> SIMD[DType.bool, W]:
        """SIMD validity load: lane `j` True iff row `i + j` is VALID."""
        var out = SIMD[DType.bool, W](fill=True)
        if not self._fill[].col_has_validity(self._idx):
            return out

        comptime for j in range(W):
            out[j] = not self._fill[].is_null(self._idx, i + j)
        return out

    @always_inline
    def length(self) -> Int:
        return self._fill[].col_length(self._idx)


# =============================================================================
# IpcMorselView[origin] -- the MorselView conformer the fold consumes.
# =============================================================================


struct IpcMorselView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, MorselView
):
    """Typed borrow over an `IpcMorselFill` -- the Arrow-IPC arm of the
    format-blind operator feed.

    `fold[IpcMorselView]` is the SAME comptime-monomorphized kernel as
    `fold[BatchView]` and `fold[ChunkView]`; only the view TYPE differs. Carries
    the fill's generation stamp so a view leaked past a refill is CAUGHT
    (`is_valid()`), never silently reading the next batch's bytes.
    """

    var _fill: Pointer[IpcMorselFill, Self.origin]
    var _gen: UInt64

    @always_inline
    def __init__(out self, ref [Self.origin] fill: IpcMorselFill):
        self._fill = Pointer(to=fill)
        self._gen = fill.generation

    @always_inline
    def generation(self) -> UInt64:
        return self._gen

    @always_inline
    def is_valid(self) -> Bool:
        """True iff the borrowed fill has NOT been reset/refilled since this
        view was created (the stale-view guard)."""
        return self._gen == self._fill[].generation

    @always_inline
    def col_is_declined(self, idx: Int) -> Bool:
        """True iff column `idx` is not a zero-copy fixed-width numeric run
        (bool / var-len / dictionary / nested). Reading it is an error."""
        return self._fill[].col_is_declined(idx)

    @always_inline
    def col_numeric[
        dt: DType
    ](self, idx: Int) -> IpcColView[dt, Self.origin]:
        """Borrow column `idx` as a typed `NumericColView` at comptime `dt`."""
        return IpcColView[dt, Self.origin](self._fill, idx)

    # -------------------------------------------------------------------------
    # MorselView conformance.
    # -------------------------------------------------------------------------

    @always_inline
    def n_rows(self) -> Int:
        return self._fill[].num_rows()

    @always_inline
    def num_columns(self) -> Int:
        return self._fill[].num_cols()

    @always_inline
    def has_selection_mask(self) -> Bool:
        """An IPC frame carries no reader-deferred selection mask."""
        return False

    @always_inline
    def selection_mask_get(self, row: Int) raises -> Bool:
        """No mask -> every row live (identity)."""
        return True

    @always_inline
    def col_is_null(self, idx: Int, row: Int) -> Bool:
        return self._fill[].is_null(idx, row)

    @always_inline
    def col_scalar[dt: DType](self, idx: Int, row: Int) raises -> Scalar[dt]:
        return self._fill[].load[dt, 1](idx, row)[0]

    @always_inline
    def col_scalar_nonraising[dt: DType](self, idx: Int, row: Int) -> Scalar[
        dt
    ]:
        return self._fill[].load[dt, 1](idx, row)[0]

    @always_inline
    def col_scalar_simd[dt: DType, W: Int](self, idx: Int, i: Int) -> SIMD[
        dt, W
    ]:
        debug_assert(
            self.is_valid(),
            "IpcMorselView.col_scalar_simd: stale view -- the fill was reset"
            " or refilled since this view was created",
        )
        return self._fill[].load[dt, W](idx, i)


@always_inline
def ipc_morsel_view_over[
    o: Origin[mut=False]
](ref [o] fill: IpcMorselFill) -> IpcMorselView[o]:
    """Module-level factory (mirrors `batch_view_over` / `chunk_view_over`).
    Mojo 1.0.0b2 cannot infer the parent struct's `origin` from a
    `@staticmethod`'s ref-parameter, so the free function is the documented
    workaround."""
    return IpcMorselView[o](fill)
