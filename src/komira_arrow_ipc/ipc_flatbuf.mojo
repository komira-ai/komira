# =============================================================================
# ipc_flatbuf.mojo — Hand-rolled minimal Flatbuffers serializer + reader
#                    scoped to the Arrow IPC subset
# =============================================================================
#
# Hand-rolls a minimal Flatbuffers serializer + reader for the Arrow IPC
# fixed grammar subset — NOT a general-purpose Flatbuffers protocol
# implementation.
#
# **Subset coverage**:
#   - Message.fbs: Message table + MessageHeader union (5 arms:
#     Schema / DictionaryBatch / RecordBatch / Tensor / SparseTensor).
#   - Schema.fbs: Schema + Field + Type union (~25 variants).
#   - File.fbs: Footer + Block.
#   - Tensor.fbs / SparseTensor.fbs: Tensor + TensorDim + SparseTensor
#     + SparseTensorIndex 3-arm union (COO / CSX / CSF).
#   - DictionaryBatch + DictionaryEncoding.
#
# **Layers**: foundation primitives — FlatbufWriter struct + primitive
# scalar writers + string / vector primitives + table primitives
# (start/add_field/end_table) + offset arithmetic; the symmetric reader
# primitives; then the per-Type-union arms and per-table writers/readers
# (Schema / RecordBatch / Footer / Tensor / SparseTensor).
#
# **Wire format primer** (Apache Arrow IPC + Flatbuffers v1.12.0
# binary layout, little-endian):
#
#   - **Scalars**: fixed-width LE (u8 / u16 / u32 / u64 / i8 / i16 / i32 /
#     i64 / f32 / f64 / bool=u8). 8-byte-aligned roots.
#   - **Strings**: [u32 length, byte[length], 0x00 null terminator,
#     pad-to-4]. Reference via `u32 offset` (relative-from-offset-position).
#   - **Vectors**: [u32 element_count, element[count], pad-to-alignment].
#     Same offset-reference shape.
#   - **Tables**: variable-size, vtable-indexed:
#         [i32 soffset_to_vtable, ...table_inline_bytes...]
#     vtable: [u16 vtable_size, u16 inline_size, u16[N] field_offsets]
#     - Fields with default values omit their entry; vtable_offset = 0.
#     - soffset_to_vtable: signed; positive=vtable-before, negative=vtable-after
#       (typically negative — we write children first, then parent table
#       with its vtable beyond it; pointer arithmetic in the spec).
#   - **Structs**: fixed-size inline. No vtable. Natural alignment of
#     largest member.
#   - **Unions**: TWO adjacent vtable slots — u8 type discriminator
#     + Offset payload.
#   - **Root offset**: prepended `u32 root_offset` at buffer start
#     (relative-from-position).
#
# **Back-to-front writer discipline** (canonical Flatbuffers
# implementation pattern; flatcc / Google C++ flatbuffers / arrow-rs
# all use this): pre-allocate a buffer of fixed upper-bound capacity;
# track `cursor` = position of the lowest in-use byte; each write
# moves `cursor` toward 0. Final output is `buf[cursor..capacity)`.
# This lets us write children FIRST, then refer to them by relative
# offset from the parent — no patch-back required.
#
# **Mojo capability constraints**:
#   - MmapAlignedBuffer.reserve is destructive (frees + re-allocs without
#     copy). Pre-allocate large with comptime upper-bound estimate;
#     overflow raises with clear error.
#   - Vtable storage: `InlineArray[UInt16, MAX_VTABLE_FIELDS]` where
#     MAX_VTABLE_FIELDS = 16 (comfortable upper bound for the largest
#     Arrow table — Field has ~6 fields, with view-types it grows to
#     ~10). POD-only (fixed inline storage; no heap-owning inner).
#   - finalize() returns a moved-out MmapAlignedBuffer — caller owns;
#     no origin-tangle.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - MmapAlignedBuffer internal use respects same-file/typed-ptr disciplines.
#
# Cross-references:
#   - Apache Arrow IPC spec: https://arrow.apache.org/docs/format/IPC.html
#   - Flatbuffers wire-format: https://flatbuffers.dev/internals.html
#   - Precedent (Thrift parser cursor pattern): the `komira_parquet` file
#     reader's `_read_varint`.
# =============================================================================

from std.sys import size_of

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# §1 — Constants
# =============================================================================

comptime FB_DEFAULT_CAPACITY: Int = 65536  # 64 KB initial buffer
comptime FB_MIN_ALIGNMENT: Int = 4         # all scalar writes ≥ 4-byte aligned
comptime FB_ROOT_ALIGNMENT: Int = 8        # root must be 8-byte aligned

# Arrow IPC continuation marker — wraps every IPC message v0.15+
# `[u32 0xFFFFFFFF, u32 metadata_size, ...flatbuf metadata...]`
comptime IPC_CONTINUATION_MARKER: UInt32 = 0xFFFFFFFF

# Arrow IPC v1.0+ MetadataVersion (V5 since Arrow 1.0; this writer only writes V5)
comptime METADATA_VERSION_V5: Int8 = 4

# Maximum number of fields in any Arrow FB table — Field is the
# largest (~6 base fields + view-type additions through ~10). 16
# is a comfortable comptime upper bound for the vtable in-flight
# storage (POD-only inline; no heap-owning).
comptime MAX_VTABLE_FIELDS: Int = 16

# §2.4 (WIRE-OPTIMAL vtable dedup) — capacity of the per-writer vtable
# dedup cache. Each distinct vtable SHAPE (field_count + inline_size +
# field_offsets[]) is recorded once; later tables with an identical
# shape reuse the cached vtable's output position instead of emitting a
# fresh copy. A wide Schema reuses one Field/Int/Utf8 vtable shape across
# many columns, so the number of DISTINCT shapes is small even for very
# wide schemas — 64 is a comfortable upper bound. On overflow (cache
# full) or for field_count > MAX_VTABLE_FIELDS, `end_table` falls back
# to emitting a fresh vtable; correctness is preserved, only the dedup
# size win is skipped. Storage is POD-only InlineArray (no heap-owning
# element): 64 * (3 ints + 16 u16 offsets) is a small fixed-size struct.
comptime MAX_VTABLES: Int = 64


# =============================================================================
# §2 — FlatbufWriter — back-to-front binary writer
# =============================================================================
#
# Allocates an MmapAlignedBuffer of fixed capacity (default 64 KB) at
# construction. Writes proceed back-to-front: `cursor` tracks the
# lowest byte address currently in use. Each `write_*` method moves
# `cursor` toward 0 by the written width.
#
# "Position" in the public API means byte position from the START of
# the (filled) buffer — i.e. `position = capacity - bytes_written`.
# The root offset is computed as `position_of_root_table - 0` (relative
# from the root_offset slot at buffer start).
#
# Methods marked **TODO** are scaffolds for the Schema / RecordBatch /
# Tensor / SparseTensor / Footer table writers.
# =============================================================================


struct FlatbufWriter(Movable):
    """Hand-rolled back-to-front Flatbuffers writer scoped to the
    Arrow IPC subset.

    State:
        _buf: pre-allocated MmapAlignedBuffer (8-byte aligned root).
        _capacity: total allocation in bytes.
        _bytes_written: count of bytes consumed from the back.
        _min_align: running max of natural-alignment requirements seen
            (1, 2, 4, 8). Tracks the buffer-level minimum alignment;
            `finalize()` pads the buffer tail (= writer's most-recently-
            written bytes) so the buffer total is a multiple of
            `_min_align`. Combined with the per-scalar Prep alignment
            in `prep()` this guarantees every field lands at its
            natural-alignment-aligned position in the FINAL forward-
            order buffer.

            Rationale: without this discipline, an i64 field inside a
            FB table can land at a 4-aligned-but-not-8-aligned position
            in the output buffer, which pyarrow's flatbuffers Verifier
            rejects with "Invalid flatbuffers message" (a cross-impl
            interop failure).
            See `_align_pre_write` / `prep` for the per-scalar discipline.
    """

    var _buf: SharedAlignedBuffer[HeapRegion]
    var _capacity: Int
    var _bytes_written: Int
    var _min_align: Int

    # §2.4 (WIRE-OPTIMAL) — vtable dedup cache. Parallel arrays keyed by
    # vtable SHAPE; `_vt_count` distinct shapes recorded so far.
    #   _vt_pos[k]:          OUTPUT (logical) position of cached vtable k
    #                        (= `cursor()` immediately after the vtable was
    #                        written; this is what a table's soffset slot
    #                        resolves against).
    #   _vt_field_count[k]:  field_count of shape k.
    #   _vt_inline_size[k]:  inline_size_with_soffset of shape k (the u16
    #                        in the vtable header, slot 1).
    #   _vt_offsets[k*MAX_VTABLE_FIELDS + i]: vtable field_offset for field
    #                        i of shape k (0 = absent field). Flattened so
    #                        the cache stays a single InlineArray.
    # POD-only: all elements are POD ints; no heap-owning member.
    var _vt_count: Int
    var _vt_pos: Array[Int, MAX_VTABLES]
    var _vt_field_count: Array[Int32, MAX_VTABLES]
    var _vt_inline_size: Array[Int32, MAX_VTABLES]
    var _vt_offsets: Array[UInt16, MAX_VTABLES * MAX_VTABLE_FIELDS]

    # --- Constructor ---

    def __init__(out self) raises:
        """Allocate a writer at FB_DEFAULT_CAPACITY (64 KB)."""
        self = FlatbufWriter(FB_DEFAULT_CAPACITY)

    def __init__(out self, capacity: Int) raises:
        """Allocate a writer at `capacity` bytes.

        Capacity is a HARD UPPER BOUND — the writer raises a clear
        overflow error if writes exceed `capacity`. Caller's
        responsibility to size based on schema metadata + per-field
        counts.
        """
        var cap = capacity if capacity >= 64 else 64
        # Round up to 8-byte alignment.
        cap = ((cap + 7) // 8) * 8
        # SAB[HeapRegion] replaces MmapAlignedBuffer[8] as
        # the IPC carrier substrate. OAB hardcodes _OWNED_ALIGN=64 which
        # over-aligns the 8-byte promise (8 | 64) — safe.
        self._buf = SharedAlignedBuffer[HeapRegion].heap_owned(cap)
        self._buf.zero()
        self._buf.set_length(0)

        self._capacity = cap
        self._bytes_written = 0
        self._min_align = 1

        # §2.4 vtable dedup cache — empty at construction.
        self._vt_count = 0
        self._vt_pos = Array[Int, MAX_VTABLES](fill=0)
        self._vt_field_count = Array[Int32, MAX_VTABLES](fill=Int32(0))
        self._vt_inline_size = Array[Int32, MAX_VTABLES](fill=Int32(0))
        self._vt_offsets = Array[UInt16, MAX_VTABLES * MAX_VTABLE_FIELDS](
            fill=UInt16(0)
        )

    # --- Position accessors ---

    @always_inline
    def bytes_written(self) -> Int:
        """Bytes consumed from the back of the buffer so far."""
        return self._bytes_written

    @always_inline
    def capacity(self) -> Int:
        """Total allocated capacity."""
        return self._capacity

    @always_inline
    def cursor(self) -> Int:
        """Position of the lowest in-use byte (the head of the back-
        to-front buffer). Equal to `capacity - bytes_written`.

        Use this as the canonical "logical position" reference: an
        offset to a target table at logical position P resolves as
        `P - offset_position` (caller side) since we write back-to-front.
        """
        return self._capacity - self._bytes_written

    # --- Primitive writers ---

    def _ensure_capacity(self, width: Int) raises:
        """Raise if writing `width` more bytes would overflow.

        The buffer's reserve is destructive (frees old +
        re-allocates without copy preserving). The writer pre-allocates
        an upper-bound estimate at construction; overflow is a clean
        raise with caller guidance.
        """
        if self._bytes_written + width > self._capacity:
            raise Error(
                "FlatbufWriter: capacity overflow ("
                + String(self._bytes_written)
                + " + "
                + String(width)
                + " > "
                + String(self._capacity)
                + "); pre-allocate a larger writer"
            )

    @always_inline
    def write_u8(mut self, value: UInt8) raises:
        """Write one byte at the new cursor position."""
        self._ensure_capacity(1)
        self._bytes_written += 1
        var pos = self._capacity - self._bytes_written
        self._buf.write_u8_at(pos, value)

    @always_inline
    def write_bool(mut self, value: Bool) raises:
        """Write a Bool as a single u8 (0 = False, 1 = True)."""
        if value:
            self.write_u8(UInt8(1))
        else:
            self.write_u8(UInt8(0))

    @always_inline
    def write_u16_le(mut self, value: UInt16) raises:
        """Write a little-endian u16 (2 bytes)."""
        self._ensure_capacity(2)
        self._bytes_written += 2
        var pos = self._capacity - self._bytes_written
        self._buf.write_u16_le_at(pos, value)

    @always_inline
    def write_u32_le(mut self, value: UInt32) raises:
        """Write a little-endian u32 (4 bytes)."""
        self._ensure_capacity(4)
        self._bytes_written += 4
        var pos = self._capacity - self._bytes_written
        self._buf.write_u32_le_at(pos, value)

    @always_inline
    def write_i32_le(mut self, value: Int32) raises:
        """Write a little-endian i32 (4 bytes)."""
        self._ensure_capacity(4)
        self._bytes_written += 4
        var pos = self._capacity - self._bytes_written
        self._buf.write_i32_le_at(pos, value)

    @always_inline
    def write_i64_le(mut self, value: Int64) raises:
        """Write a little-endian i64 (8 bytes)."""
        self._ensure_capacity(8)
        self._bytes_written += 8
        var pos = self._capacity - self._bytes_written
        self._buf.write_i64_le_at(pos, value)

    @always_inline
    def write_u64_le(mut self, value: UInt64) raises:
        """Write a little-endian u64 (8 bytes)."""
        self._ensure_capacity(8)
        self._bytes_written += 8
        var pos = self._capacity - self._bytes_written
        self._buf.write_u64_le_at(pos, value)

    def write_padding(mut self, num_bytes: Int) raises:
        """Write `num_bytes` of zero padding. Used between field-data
        records when alignment requires."""
        if num_bytes <= 0:
            return
        self._ensure_capacity(num_bytes)
        for _ in range(num_bytes):
            self._bytes_written += 1
            var pos = self._capacity - self._bytes_written
            self._buf.write_u8_at(pos, UInt8(0))

    def align_to(mut self, alignment: Int, additional_bytes: Int) raises:
        """Insert padding so that the NEXT scalar of size `additional_bytes`
        starts at a position aligned to `alignment` (counting the bytes
        we're ABOUT to write).

        Mirrors flatbuffers' `Prep(min_align, size)` discipline: align
        the running cursor PLUS the size of the upcoming write to the
        required boundary. This is the canonical "make sure the next
        write doesn't cross an alignment boundary" step.

        NOTE: This does NOT update `_min_align`. Use `prep()` for the
        full FB Prep semantic that tracks min_align.
        """
        var total = self._bytes_written + additional_bytes
        var rem = total % alignment
        if rem != 0:
            self.write_padding(alignment - rem)

    def prep(mut self, alignment: Int, additional_bytes: Int) raises:
        """Flatbuffers `Prep(min_align, size)` — full semantic.

        Padding contract: AFTER this call returns and the caller writes
        `additional_bytes` more bytes, the writer's `_bytes_written`
        will be a multiple of `alignment`. Equivalently: the bytes
        about to be written will START at a position in the output
        buffer that is `alignment`-aligned (assuming the buffer's total
        length at `finalize()` is also `alignment`-aligned, which the
        writer guarantees by padding via `_min_align` at finalize).

        This is the canonical FB writer discipline — without it, an
        i64 scalar inside a table can land at a 4-aligned-but-not-8-
        aligned position in the output buffer, triggering pyarrow's
        flatbuffers Verifier reject ("Invalid flatbuffers message" — a
        cross-impl interop failure).

        Side effect: `_min_align = max(_min_align, alignment)`.
        """
        if alignment > self._min_align:
            self._min_align = alignment
        self.align_to(alignment, additional_bytes)

    # --- §2.4 vtable dedup cache ---
    #
    # A FlatBuffers vtable is fully described by its SHAPE:
    #   (field_count, inline_size, field_offsets[0..field_count)).
    # Two tables with the same shape can share one physical vtable — the
    # reader resolves `table.soffset -> vtable` and reads field_offsets
    # identically regardless of WHICH table the vtable was first emitted
    # for. Dedup therefore preserves exact reading semantics while cutting
    # repeated vtable bytes (the dominant metadata cost on wide schemas
    # where every column-Field / Int / Utf8 table has an identical vtable).
    #
    # Ordering note (the slot's HALT trigger): the FlatBuffers soffset is
    # SIGNED precisely so a vtable may live either before OR after its
    # table. When a later table reuses a cached vtable, no bytes are
    # written for that table's vtable and no prior write is moved, so no
    # reordering is ever required — the HALT condition (a dedup forcing a
    # vtable to be relocated ahead of its consumers) cannot arise. The
    # cached vtable's output position is fixed at first emission; each
    # consuming table simply records `soffset = table_pos - vtable_pos`
    # (positive if the vtable precedes the table, negative if it follows).
    # Both are spec-valid and the reader resolves `vtable_pos = table_pos
    # - soffset` identically either way.

    def _vtable_lookup(
        self,
        field_count: Int,
        inline_size: Int,
        offsets: Array[Int32, MAX_VTABLE_FIELDS],
    ) -> Int:
        """Return the OUTPUT position of a cached vtable whose shape
        matches (field_count, inline_size, offsets[0..field_count)), or
        -1 if none is cached. `offsets[i]` is the table-relative
        field_offset (0 = absent field)."""
        if field_count > MAX_VTABLE_FIELDS:
            return -1
        for k in range(self._vt_count):
            if Int(self._vt_field_count[k]) != field_count:
                continue
            if Int(self._vt_inline_size[k]) != inline_size:
                continue
            var base = k * MAX_VTABLE_FIELDS
            var matched = True
            for i in range(field_count):
                if (
                    Int(self._vt_offsets[base + i])
                    != Int(offsets[i])
                ):
                    matched = False
                    break
            if matched:
                return self._vt_pos[k]
        return -1

    def _vtable_record(
        mut self,
        field_count: Int,
        inline_size: Int,
        offsets: Array[Int32, MAX_VTABLE_FIELDS],
        vtable_pos: Int,
    ):
        """Record a freshly-emitted vtable's shape + output position for
        future dedup. No-op if the cache is full or field_count exceeds
        MAX_VTABLE_FIELDS — in that case later identical tables simply
        emit their own vtable (correct, just not deduped)."""
        if field_count > MAX_VTABLE_FIELDS:
            return
        if self._vt_count >= MAX_VTABLES:
            return
        var k = self._vt_count
        self._vt_field_count[k] = Int32(field_count)
        self._vt_inline_size[k] = Int32(inline_size)
        self._vt_pos[k] = vtable_pos
        var base = k * MAX_VTABLE_FIELDS
        for i in range(field_count):
            self._vt_offsets[base + i] = UInt16(Int(offsets[i]))
        self._vt_count = k + 1

    # --- Offset arithmetic ---
    #
    # In Flatbuffers, an "Offset" is a u32 stored at one position that
    # encodes the relative byte distance to a target object.
    #
    #   target_address = offset_position + offset_value
    #
    # Since we write back-to-front (children before parents) the target
    # is always at a HIGHER buffer address than the offset slot. The
    # numeric offset value is (target_position - offset_position).

    @always_inline
    def write_offset_u32(mut self, target_logical_pos: Int) raises:
        """Write a u32 offset to a target at logical position
        `target_logical_pos`.

        Logical position = absolute byte position from buffer-start
        once the buffer is finalized (i.e. `_capacity - _bytes_written`
        at the moment the target was written, plus subsequent shifts).
        Since we maintain `cursor = _capacity - _bytes_written`, the
        offset value at write-time is
        `target_logical_pos - (cursor() - 4)` AFTER the 4-byte write
        consumes its slot.
        """
        # Compute offset at the position we're about to write.
        var offset_pos = self.cursor() - 4
        var rel = target_logical_pos - offset_pos
        if rel < 0:
            raise Error(
                "FlatbufWriter: offset target ("
                + String(target_logical_pos)
                + ") precedes offset slot ("
                + String(offset_pos)
                + "); back-to-front writer expects target-after-slot"
            )
        self.write_u32_le(UInt32(rel))

    # --- String writer ---
    #
    # Flatbuffer string layout: [u32 length, bytes[length], 0x00, pad-to-4].
    # The "offset to a string" is the position of the length prefix.

    def write_string(mut self, s: StringSlice) raises -> Int:
        """Write a Flatbuffers string; return its logical position.

        Layout (back-to-front, so we emit in reverse order):
            [u32 length] <- returned position
            [bytes (utf-8)]
            [0x00 null terminator]
            [pad to 4-byte alignment]

        The returned position is the position of the LENGTH PREFIX —
        consumers use this as the "string offset" target.

        The length u32 must
        land at a 4-aligned OUTPUT position. Pre-align via `prep(4, 4)`
        ahead of the trailing pad+null+bytes sequence so the writer's
        `_bytes_written` is 4-aligned at the moment the u32 length is
        written, guaranteeing 4-aligned position in the FINAL forward-
        order output buffer.
        """
        # s.as_bytes() gives UTF-8 byte access (same idiom as c_data_stream).
        var bytes = s.as_bytes()
        var byte_len = len(bytes)

        # Pad: total bytes between the u32 length prefix and the next
        # 4-byte aligned position. Layout in physical order is:
        # [u32 length, bytes, 0x00 null, pad-to-4]. Bytes + null may
        # have a tail of 1-4 padding zeros to land the NEXT write at
        # a 4-aligned boundary.
        var unpadded = byte_len + 1  # bytes + null terminator
        var aligned = ((unpadded + 3) // 4) * 4
        var pad = aligned - unpadded

        # Pre-align: after writing the trailing pad+null+bytes
        # (`aligned` bytes total) PLUS the u32 length (4 bytes), the
        # writer's `_bytes_written` must be a multiple of 4 so the
        # u32 length lands at a 4-aligned OUTPUT position. Since
        # `aligned` is a multiple of 4 by construction (we computed it
        # as such), this reduces to ensuring `_bytes_written` is 4-
        # aligned BEFORE we begin. `prep(4, aligned + 4)` achieves
        # this and also tracks `_min_align = max(_min_align, 4)`.
        self.prep(4, aligned + 4)
        # Write order (back-to-front means LAST physical byte first):
        # 1. Padding bytes (zero).
        self.write_padding(pad)
        # 2. Null terminator.
        self.write_u8(UInt8(0))
        # 3. String bytes in REVERSE physical order (back-to-front
        #    means bytes[byte_len-1] is written first).
        for i in range(byte_len - 1, -1, -1):
            self.write_u8(bytes[i])
        # 4. Length prefix u32.
        self.write_u32_le(UInt32(byte_len))
        # The "position" of this string for offset purposes is the
        # position of the length prefix — which is the current cursor.
        return self.cursor()

    # --- Finalize ---

    def finalize(var self, root_offset_logical_pos: Int) raises -> SharedAlignedBuffer[HeapRegion]:
        """Consume self; emit the SharedAlignedBuffer with the root offset
        prepended.

        The root offset is a u32 at position 0 of the final output
        pointing at the root table's position. Per the Arrow IPC
        spec the buffer also gets prefixed with a continuation marker
        + metadata size for v0.15+ IPC messages — but that's the
        outer MESSAGE framing, NOT the FlatBuffer payload itself.
        This finalize() emits the bare FlatBuffer payload; framing
        is the caller's responsibility (and is handled by the
        outer FileSink integration).

        Pads the buffer tail
        (= writer's most-recently-written bytes = the trailing zeros
        AFTER all content, which appear at the END of the output) such
        that `_bytes_written` is a multiple of `_min_align` BEFORE
        writing the root offset. Combined with the per-scalar Prep
        alignment in `end_table` / `_write_*_vector` / `write_string`,
        this ensures every scalar lands at its natural-alignment-
        aligned position in the OUTPUT buffer.

        WAIT — back-to-front discipline. The root offset is written
        LAST (at lowest internal cursor / first OUTPUT position). To
        ensure it lands at output position 0 (always 4-aligned for the
        u32), we need `_bytes_written_AFTER_root_write` to be a
        multiple of `_min_align`. Since the root write adds 4 bytes,
        we want `(_bytes_written + 4) % _min_align == 0` AFTER the
        root write completes. We call `prep(_min_align, 4)` BEFORE the
        root write (so the next 4 bytes land at a `_min_align`-aligned
        cursor).

        Returns:
            SharedAlignedBuffer[HeapRegion] containing exactly the FB
            payload bytes in forward order. Length may be padded UP to a
            multiple of `_min_align` (e.g., 8 if the FB contains an i64).
        """
        # Pre-align so that AFTER writing the 4-byte root offset, the
        # writer's `_bytes_written` is a multiple of `_min_align`.
        # This makes the output buffer length itself a multiple of
        # `_min_align`, which is the global invariant needed for every
        # internally-Prep-aligned scalar to land at its naturally-aligned
        # OUTPUT position.
        self.prep(self._min_align, 4)

        # Write the root offset u32 at the lowest position.
        self.write_offset_u32(root_offset_logical_pos)

        # The output starts at position `_capacity - _bytes_written`.
        # We compact the buffer to a forward-order representation by
        # memcpy'ing the tail into a fresh MmapAlignedBuffer (caller-friendly).
        #
        # This copy is a per-RB hot path (called from
        # `encode_record_batch_message` + `encode_schema_message` +
        # `write_ipc_message`), so it uses libc memcpy via
        # `copy_from_aligned_buffer_at` rather than a scalar byte loop.
        # No `out_buf.zero()` is needed: every byte in
        # [0, out_length) is overwritten by the memcpy below, and the
        # SIMD-tail pad bytes [out_length, padded_capacity) are already
        # zeroed by `MmapAlignedBuffer.__init__` per its create() contract
        # (the over-allocated tail is memset'd; bytes [0, size) are
        # uninitialized — but every one of them is about to be written).
        var out_length = self._bytes_written
        var out_buf = SharedAlignedBuffer[HeapRegion].heap_owned(max(out_length, 1))
        var src_cursor = self._capacity - self._bytes_written
        # libc memcpy: dest=out_buf[0..out_length), src=self._buf[src_cursor..)
        out_buf.copy_from_aligned_buffer_at(
            0, self._buf, src_cursor, out_length
        )
        out_buf.set_length(out_length)

        return out_buf^


# =============================================================================
# §3 — FlatbufReader — bounds-checked symmetric reader
# =============================================================================
#
# Reads a Flatbuffer payload in FORWARD byte order. Constructed from
# an MmapAlignedBuffer (typically the output of `FlatbufWriter.finalize`).
# All reads are bounds-checked; out-of-range raises a clear error.
#
# **Offset resolution**: a u32 stored at position P with value V
# encodes a relative pointer to target position `P + V`. The READER
# returns the resolved TARGET position; callers then read primitives
# at that target.
#
# **Origin discipline**: the reader carries a `Pointer[MmapAlignedBuffer,
# origin]` so the borrowed buffer's lifetime tracks through reads.
# Returned `String` instances are OWNED COPIES of the byte data — no
# UnsafePointer leaks across the public surface.
# =============================================================================


struct FlatbufReader[bo: Origin[mut=False]](Copyable, Movable):
    """Bounds-checked Flatbuffer reader over a borrowed MmapAlignedBuffer.

    Parameters:
        bo: Origin[mut=False] of the borrowed parent MmapAlignedBuffer.

    The reader cannot outlive its source buffer; the compiler tracks
    `bo` through every read.
    """

    var _buf: Pointer[SharedAlignedBuffer[HeapRegion], Self.bo]
    var _length: Int

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[SharedAlignedBuffer[HeapRegion], Self.bo],
        length: Int,
    ):
        """Construct from a typed pointer + logical byte length.

        `length` is the in-use byte count (the writer's
        `_bytes_written + 4` after finalize, NOT the MmapAlignedBuffer's
        physical capacity).
        """
        self._buf = ptr
        self._length = length

    @always_inline
    def length(self) -> Int:
        """Total byte length of the FB payload."""
        return self._length

    # --- Bounds-checking helper ---

    def _check_bounds(self, pos: Int, width: Int) raises:
        """Raise if reading `width` bytes at `pos` would exceed the
        FB payload."""
        if pos < 0 or pos + width > self._length:
            raise Error(
                "FlatbufReader: read at pos "
                + String(pos)
                + " + width "
                + String(width)
                + " exceeds payload length "
                + String(self._length)
            )

    # --- Primitive readers ---

    @always_inline
    def read_u8(self, pos: Int) raises -> UInt8:
        """Read one byte at `pos`."""
        self._check_bounds(pos, 1)
        return self._buf[].read_u8_at(pos)

    @always_inline
    def read_bool(self, pos: Int) raises -> Bool:
        """Read a Bool (0 = False, anything else = True)."""
        return self.read_u8(pos) != UInt8(0)

    @always_inline
    def read_u16_le(self, pos: Int) raises -> UInt16:
        """Read a little-endian u16 (2 bytes)."""
        self._check_bounds(pos, 2)
        return self._buf[].read_u16_le_at(pos)

    @always_inline
    def read_u32_le(self, pos: Int) raises -> UInt32:
        """Read a little-endian u32 (4 bytes)."""
        self._check_bounds(pos, 4)
        return self._buf[].read_u32_le_at(pos)

    @always_inline
    def read_i32_le(self, pos: Int) raises -> Int32:
        """Read a little-endian i32 (4 bytes)."""
        self._check_bounds(pos, 4)
        return self._buf[].read_i32_le_at(pos)

    @always_inline
    def read_u64_le(self, pos: Int) raises -> UInt64:
        """Read a little-endian u64 (8 bytes)."""
        self._check_bounds(pos, 8)
        return self._buf[].read_u64_le_at(pos)

    @always_inline
    def read_i64_le(self, pos: Int) raises -> Int64:
        """Read a little-endian i64 (8 bytes)."""
        self._check_bounds(pos, 8)
        return self._buf[].read_i64_le_at(pos)

    # --- Offset resolution ---

    @always_inline
    def read_offset_u32(self, slot_pos: Int) raises -> Int:
        """Resolve a u32 offset stored at `slot_pos`.

        Returns the target position: `slot_pos + offset_value`.
        Raises if the resolved target is outside the payload.
        """
        var rel = Int(self.read_u32_le(slot_pos))
        var target = slot_pos + rel
        if target < 0 or target >= self._length:
            raise Error(
                "FlatbufReader: offset target ("
                + String(target)
                + ") out of bounds [0, "
                + String(self._length)
                + ")"
            )
        return target

    # --- Root offset ---

    @always_inline
    def read_root_offset(self) raises -> Int:
        """Read the root table position from the first 4 bytes of the
        FB payload.

        This is the entry point: `reader.read_root_offset()` resolves
        to the position of the root Schema / Message / Footer table.
        """
        return self.read_offset_u32(0)

    # --- String reader ---

    def read_string(self, slot_pos: Int) raises -> String:
        """Resolve an offset slot at `slot_pos` and read the
        Flatbuffers string at the target.

        Layout at target: `[u32 length, bytes[length], 0x00 null, pad]`.
        Returns an owned String (copy of the byte data). No
        UnsafePointer leaks.
        """
        var target = self.read_offset_u32(slot_pos)
        return self.read_string_at(target)

    def read_string_at(self, length_pos: Int) raises -> String:
        """Read a Flatbuffers string at `length_pos` (the position of
        the u32 length prefix; NOT going through an offset slot)."""
        var length = Int(self.read_u32_le(length_pos))
        if length < 0:
            raise Error(  # cov: unreachable the length is a u32 widened to Int
                "FlatbufReader.read_string: negative length " + String(length)  # cov: unreachable the length is a u32 widened to Int
            )
        var data_pos = length_pos + 4
        self._check_bounds(data_pos, length)
        # Copy bytes into a String. Avoids UnsafePointer leak.
        var bytes = List[UInt8]()
        bytes.reserve(length + 1)
        for i in range(length):
            bytes.append(self._buf[].read_u8_at(data_pos + i))
        bytes.append(UInt8(0))  # null terminator for String
        # Canonical idiom: String(unsafe_from_utf8_ptr=...). There is no
        # `bytes=` kwarg on String.
        return String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())


# =============================================================================
# §3.1 — Factory helper: build a reader from a writer's finalized buffer
# =============================================================================


@always_inline
def flatbuf_reader_over[
    bo: Origin[mut=False]
](ref [bo] buf: SharedAlignedBuffer[HeapRegion]) -> FlatbufReader[bo]:
    """Construct a FlatbufReader over a borrowed SharedAlignedBuffer.

    Free-function factory matching the in-tree precedent at
    `batch_view_over` in collections/batch_view.mojo. Mojo 1.0.0b1 cannot infer
    parent struct param slots from `@staticmethod` ref-params.
    """
    return FlatbufReader[bo](Pointer(to=buf), buf.len())


# =============================================================================
# §4 — Type union tags (Apache Arrow Schema.fbs)
# =============================================================================
#
# 25 Type union variants. The tag value is the
# discriminator the parent table (Field) uses to know which Type
# variant follows. Values match Apache Arrow's Schema.fbs union order.
# =============================================================================

comptime TYPE_NULL: UInt8 = 1
comptime TYPE_INT: UInt8 = 2
comptime TYPE_FLOATING_POINT: UInt8 = 3
comptime TYPE_BINARY: UInt8 = 4
comptime TYPE_UTF8: UInt8 = 5
comptime TYPE_BOOL: UInt8 = 6
comptime TYPE_DECIMAL: UInt8 = 7
comptime TYPE_DATE: UInt8 = 8
comptime TYPE_TIME: UInt8 = 9
comptime TYPE_TIMESTAMP: UInt8 = 10
comptime TYPE_INTERVAL: UInt8 = 11
comptime TYPE_LIST: UInt8 = 12
comptime TYPE_STRUCT_: UInt8 = 13
comptime TYPE_UNION: UInt8 = 14
comptime TYPE_FIXED_SIZE_BINARY: UInt8 = 15
comptime TYPE_FIXED_SIZE_LIST: UInt8 = 16
comptime TYPE_MAP: UInt8 = 17
comptime TYPE_DURATION: UInt8 = 18
comptime TYPE_LARGE_BINARY: UInt8 = 19
comptime TYPE_LARGE_UTF8: UInt8 = 20
comptime TYPE_LARGE_LIST: UInt8 = 21
comptime TYPE_RUN_END_ENCODED: UInt8 = 22
comptime TYPE_BINARY_VIEW: UInt8 = 23
comptime TYPE_UTF8_VIEW: UInt8 = 24
comptime TYPE_LIST_VIEW: UInt8 = 25
comptime TYPE_LARGE_LIST_VIEW: UInt8 = 26


# =============================================================================
# §5 — Table builder primitives
# =============================================================================
#
# Flatbuffers tables are vtable-indexed. Layout in OUTPUT (forward) order:
#
#   [vtable: u16 vtable_size, u16 inline_size, u16[N] field_offsets]
#   [table_inline_data starting with i32 soffset_to_vtable]
#
# `soffset_to_vtable = table_pos - vtable_pos` (positive — vtable is
# BEFORE table in output). To resolve from table to vtable:
# `vtable_pos = table_pos - soffset`.
#
# Writer pattern (back-to-front):
#   1. Write children (offsets known after).
#   2. Push field elements via add_field — accumulate into in-flight
#      vtable_scratch (each field's offset within inline data).
#   3. Push i32 soffset_to_vtable PLACEHOLDER (0).
#   4. NOTE table_pos = cursor after soffset.
#   5. Write vtable.
#   6. NOTE vtable_pos = cursor after vtable.
#   7. Patch the soffset slot with `table_pos - vtable_pos`.
#
# The table builder is intentionally simple — no vtable deduplication
# (every table emits a fresh vtable). Dedup would save ~25% metadata
# bytes on wide schemas.
#
# The builder uses a SIMPLE-LAYOUT discipline: every present
# field is encoded as a 4-byte slot (either a direct u32 value for
# u8/u16/u32 inline scalars or a u32 offset for child references).
# Bool fields are still 4-byte slots (high 24 bits unused). This costs
# ~50% more bytes vs the optimal packed layout (where u8 takes 1 byte)
# but vastly simplifies the in-flight tracking — Apache Arrow's tables
# are small (Schema ~few hundred bytes for typical schemas), so the
# overhead is negligible. Optimal packing is a possible follow-up.
# =============================================================================


struct _TableBuilder(Movable):
    """In-flight state for a table-being-built.

    Each `add_field_*(field_id, value)` call records the value + its
    field WIDTH (1/2/4/8/N bytes). `end_table` walks fields in
    declaration order, computes per-field inline offsets honoring
    natural alignment, then writes inline data back-to-front, soffset
    placeholder, vtable, and patches the soffset.

    Per-field state (parallel arrays, POD-only InlineArray):
      - `_field_present[i]`: did the caller call any add_field_*(i, ...)?
      - `_field_widths[i]`: 1 / 2 / 4 / 8 / 16 / N — bytes per field
        (16 = Buffer-as-inline-struct; >16 = generic inline-struct
        bytes referenced via _field_struct_offset/_field_struct_size).
      - `_field_values[i]`: u32 storage for 1/2/4-byte fields + offsets
        (offsets use the high-bit-marker as before).
      - `_field_i64_values[i]`: i64 storage for 8-byte fields.
      - `_field_struct_offset[i]`: byte offset into `_struct_scratch`
        for inline-struct fields (>16 bytes); -1 = not a struct.
      - `_field_struct_size[i]`: byte count for inline-struct fields.

    The `_struct_scratch: List[UInt8]` buffer holds the bytes for
    every inline-struct field encountered. add_field_buffer_inline /
    add_field_field_node_inline append to this list + record their
    (offset, size). end_table copies them into the back-to-front writer
    at the correct positions.

    Fields are 0-indexed; vtable slots are at u16[field_id] offsets.
    """

    var _field_count: Int  # highest field_id + 1 referenced
    var _field_present: Array[Bool, MAX_VTABLE_FIELDS]
    var _field_widths: Array[UInt8, MAX_VTABLE_FIELDS]
    var _field_values: Array[UInt32, MAX_VTABLE_FIELDS]
    var _field_i64_values: Array[Int64, MAX_VTABLE_FIELDS]
    var _field_struct_offset: Array[Int32, MAX_VTABLE_FIELDS]
    var _field_struct_size: Array[Int32, MAX_VTABLE_FIELDS]
    var _struct_scratch: List[UInt8]

    def __init__(out self):
        """Empty table-in-flight; no fields set yet."""
        self._field_count = 0
        self._field_present = Array[Bool, MAX_VTABLE_FIELDS](fill=False)
        self._field_widths = Array[UInt8, MAX_VTABLE_FIELDS](fill=UInt8(0))
        self._field_values = Array[UInt32, MAX_VTABLE_FIELDS](fill=UInt32(0))
        self._field_i64_values = Array[Int64, MAX_VTABLE_FIELDS](fill=Int64(0))
        self._field_struct_offset = Array[Int32, MAX_VTABLE_FIELDS](
            fill=Int32(-1)
        )
        self._field_struct_size = Array[Int32, MAX_VTABLE_FIELDS](
            fill=Int32(0)
        )
        self._struct_scratch = List[UInt8]()


def start_table() -> _TableBuilder:
    """Start a new table build. Returns an empty `_TableBuilder` that
    callers populate via `add_field_*` then pass to `end_table`."""
    return _TableBuilder()


def add_field_u32(mut tb: _TableBuilder, field_id: Int, value: UInt32):
    """Record a 4-byte u32-storable field value at slot `field_id`.

    Used for both INLINE primitive values (Int.bit_width, enum tags
    >1 byte) and as the BACK-COMPAT name for 4-byte primitive scalars
    that callers wrote before wire-canonical migration. The wire-level
    encoding is u32 either way; the semantic distinction is the parent
    table's contract.

    For CANONICAL wire format on a u32-sized field, this is correct.
    For a u8 / bool / u16 field, prefer `add_field_u8` / `add_field_bool`
    / `add_field_u16` which produce a smaller inline slot.

    No bounds-check on `field_id` beyond MAX_VTABLE_FIELDS — caller
    contract.
    """
    if field_id < 0 or field_id >= MAX_VTABLE_FIELDS:
        return  # silently ignore out-of-range — caller bug
    tb._field_values[field_id] = value
    tb._field_widths[field_id] = UInt8(4)
    tb._field_present[field_id] = True
    if field_id + 1 > tb._field_count:
        tb._field_count = field_id + 1


def add_field_u16(mut tb: _TableBuilder, field_id: Int, value: UInt16):
    """Record a 2-byte u16 field. Used by enum fields like
    `MetadataVersion` (i16 spec) — encoded as u16 inline.
    """
    if field_id < 0 or field_id >= MAX_VTABLE_FIELDS:
        return
    tb._field_values[field_id] = UInt32(Int(value))
    tb._field_widths[field_id] = UInt8(2)
    tb._field_present[field_id] = True
    if field_id + 1 > tb._field_count:
        tb._field_count = field_id + 1


def add_field_u8(mut tb: _TableBuilder, field_id: Int, value: UInt8):
    """Record a 1-byte u8 field (used by union discriminator tags,
    enum bytes like Endianness / TimeUnit / Precision / etc.)."""
    if field_id < 0 or field_id >= MAX_VTABLE_FIELDS:
        return
    tb._field_values[field_id] = UInt32(Int(value))
    tb._field_widths[field_id] = UInt8(1)
    tb._field_present[field_id] = True
    if field_id + 1 > tb._field_count:
        tb._field_count = field_id + 1


def add_field_bool(mut tb: _TableBuilder, field_id: Int, value: Bool):
    """Record a Bool field as 1-byte u8 (0 or 1) — canonical FB Bool."""
    add_field_u8(tb, field_id, UInt8(1) if value else UInt8(0))


def add_field_i64(mut tb: _TableBuilder, field_id: Int, value: Int64):
    """Record an 8-byte i64 field — canonical FB long.

    Required for RecordBatch.length / Message.bodyLength / Block.* /
    TensorDim.size / Tensor.shape strides etc. — anywhere the .fbs
    declares `long` (i64).

    Pyarrow / arrow-rs readers strictly read 8 bytes at the vtable-
    indicated offset for `long` fields; writing only the low 32 bits
    would alias the next field's data into the high bytes.
    """
    if field_id < 0 or field_id >= MAX_VTABLE_FIELDS:
        return
    tb._field_i64_values[field_id] = value
    tb._field_widths[field_id] = UInt8(8)
    tb._field_present[field_id] = True
    if field_id + 1 > tb._field_count:
        tb._field_count = field_id + 1


def add_field_offset(mut tb: _TableBuilder, field_id: Int, target_pos: Int):
    """Record an OFFSET to a target position. Stored as raw target_pos
    initially; end_table converts it to a relative u32 at write-time.

    We store the absolute target_pos as a placeholder (high bits are
    the marker `0x80000000` ORed in) and the low 31 bits hold the
    target position. end_table detects the marker and converts to
    relative offset. Hack works because table positions never exceed
    ~64 MB (FB capacity ceiling).
    """
    if target_pos < 0 or target_pos > 0x7FFFFFFF:
        return  # caller bug
    if field_id < 0 or field_id >= MAX_VTABLE_FIELDS:
        return
    tb._field_values[field_id] = UInt32(target_pos) | UInt32(0x80000000)
    tb._field_widths[field_id] = UInt8(4)
    tb._field_present[field_id] = True
    if field_id + 1 > tb._field_count:
        tb._field_count = field_id + 1


def add_field_inline_struct(
    mut tb: _TableBuilder, field_id: Int, struct_bytes: List[UInt8]
):
    """Record an INLINE STRUCT field (e.g. Buffer = 16 bytes;
    FieldNode = 16 bytes; Block = 24 bytes; Tensor's data field per
    canonical Tensor.fbs).

    The `struct_bytes` list contains the struct's wire-format bytes
    IN FORWARD order. end_table writes them at the correct
    inline_offset in the table data area (back-to-front emission
    inside end_table handles the reverse-write per the FB writer's
    discipline).

    Width is set to the struct's byte count. For Buffer (16 bytes),
    pyarrow / arrow-rs Tensor reader will read 16 bytes at the
    vtable-indicated offset and parse as Buffer struct.
    """
    if field_id < 0 or field_id >= MAX_VTABLE_FIELDS:
        return
    var size = len(struct_bytes)
    var scratch_offset = len(tb._struct_scratch)
    tb._struct_scratch.reserve(scratch_offset + size)
    for i in range(size):
        tb._struct_scratch.append(struct_bytes[i])

    tb._field_struct_offset[field_id] = Int32(scratch_offset)
    tb._field_struct_size[field_id] = Int32(size)
    tb._field_widths[field_id] = UInt8(size if size <= 255 else 255)
    # `width=size` is fine for 16/24-byte structs; if a struct exceeds
    # 255 bytes (rare in Arrow.fbs), the width field is capped at 255
    # but the struct_size field carries the true size for emission.
    tb._field_present[field_id] = True
    if field_id + 1 > tb._field_count:
        tb._field_count = field_id + 1


# Convenience: write a Buffer struct directly as inline-struct bytes.
# Buffer wire layout per Arrow Schema.fbs: { offset: long, length: long }
# Total 16 bytes — both i64 LE.
def add_field_buffer_inline(
    mut tb: _TableBuilder, field_id: Int, buf: BufferDescriptor
):
    """Convenience: encode a `BufferDescriptor` as 16-byte inline-struct
    field. Used by Tensor.data + SparseTensor*.indicesBuffer / indptrBuffer.
    """
    var bytes = List[UInt8]()
    bytes.reserve(16)
    # offset: i64 LE
    var off_u64 = UInt64(buf.offset.cast[DType.uint64]())
    for i in range(8):
        bytes.append(UInt8(Int((off_u64 >> UInt64(i * 8)) & UInt64(0xFF))))
    # length: i64 LE
    var len_u64 = UInt64(buf.length.cast[DType.uint64]())
    for i in range(8):
        bytes.append(UInt8(Int((len_u64 >> UInt64(i * 8)) & UInt64(0xFF))))
    add_field_inline_struct(tb, field_id, bytes^)


def end_table(mut writer: FlatbufWriter, var tb: _TableBuilder) raises -> Int:
    """Finalize the in-flight table; emit inline data with per-field
    widths + alignments, soffset placeholder, vtable, then patch the
    soffset. Returns the table position.

    **WIRE-CANONICAL** layout: per-field width is honored on emission. Each field
    occupies exactly its natural width (1 / 2 / 4 / 8 / N bytes) with
    inline padding for alignment. inline_size in the vtable reflects
    the actual packed size; pyarrow / arrow-rs Tensor readers can
    correctly parse `data: Buffer` as INLINE 16-byte struct.

    Algorithm:
        1. Walk fields in declaration order; compute per-field
           inline_offset honoring natural alignment.
        2. Compute `inline_size` (cumulative bytes including padding).
        3. Write inline data back-to-front in DESCENDING inline_offset
           order. For each field: emit primitive (width-aware) /
           offset / inline-struct bytes.
        4. Write i32 soffset placeholder; note table_pos.
        5. Write vtable.
        6. Patch the soffset slot.
    """
    var field_count = tb._field_count

    # Step 1: compute per-field inline_offset. Walk in declaration
    # order; each field is placed at the next position aligned to its
    # natural width. inline_offset[i] = position of field i within the
    # inline data area (NOT counting the leading soffset 4 bytes).
    # The vtable field_offsets stored OUTPUT-side need to count from
    # the table_pos (i.e. include the soffset prefix of 4 bytes).
    var inline_offsets = Array[Int32, MAX_VTABLE_FIELDS](fill=Int32(0))
    var inline_size_data = 0  # bytes in the data area, NOT counting soffset
    # a FlatBuffer table BEGINS with
    # a soffset_t (i32) at byte 0 of the table — so the TABLE itself must be
    # 4-byte aligned regardless of field widths. Without this, a table whose
    # only fields are u8 / i16 / FixedSizeBinary[<4] (e.g. the FloatingPoint
    # Type union arm with a single i16 `precision` field) lands at a non-
    # 4-aligned position; pyarrow's FlatBuffer Verifier rejects the message
    # ("Invalid flatbuffers message.") because the soffset_t i32 read fails
    # VerifyAlignment. This bug surfaced as the 2D Float64 Tensor pyarrow-
    # parity failure: the Int Type table (bit_width i32) was 4-aligned via
    # max_field_align=4, but the FloatingPoint Type table (precision i16
    # only) was only 2-aligned. Starting max_field_align at 4 forces the
    # minimum-table-alignment invariant.
    var max_field_align = 4   # Max alignment seen
    for i in range(field_count):
        if not tb._field_present[i]:
            continue
        var w = Int(tb._field_widths[i])
        # Natural alignment: round inline_size_data up to multiple of w
        # for w ≤ 8; inline-struct fields (Buffer = 16) align to 8.
        var align: Int = w
        if w > 8:
            align = 8
        if align < 1:
            align = 1
        if align > max_field_align:
            max_field_align = align
        var rem = inline_size_data % align
        if rem != 0:
            inline_size_data += align - rem
        inline_offsets[i] = Int32(inline_size_data)
        inline_size_data += w

    # Total inline size including soffset prefix.
    var inline_size_with_soffset = 4 + inline_size_data

    # — pre-align the writer so
    # the table's INLINE DATA AREA (= bytes [table_pos+4, table_pos+4
    # + inline_size_data) in OUTPUT order) starts at a position that
    # is `max_field_align`-aligned. With this invariant + the existing
    # algorithm computing inline_offsets[i] as `max_field_align`-aware,
    # each field-data byte lands at its natural-alignment-aligned
    # OUTPUT position — which the flatbuffers Verifier (and pyarrow's
    # / arrow-rs's reader) MUST see for the message to be accepted.
    #
    # Math: in OUTPUT order the table layout is
    #   [4-byte soffset_t][inline_size_data bytes of field data].
    # Inline data starts at `table_pos + 4`. Field with vtable_offset
    # = `4 + inline_offsets[i]` lands at `table_pos + 4 + inline_offsets[i]`.
    # Since `inline_offsets[i]` is `w_i`-aligned (modulo
    # `max_field_align`), we need `table_pos + 4 ≡ 0 (mod max_field_align)`.
    # Equivalently, the OUTPUT position of the inline data area start
    # (= table_pos + 4) is `max_field_align`-aligned.
    #
    # In the back-to-front writer: a write that happens when
    # `_bytes_written = W_after` (post-write) lands at OUTPUT position
    # `total - W_after`. We want
    #   `(total - W_after_inline_data) % max_field_align == 0`,
    # where `W_after_inline_data` is the writer's `_bytes_written`
    # AFTER writing all `inline_size_data` bytes of field data (the
    # bytes BEFORE the soffset placeholder in OUTPUT order = AFTER
    # the soffset placeholder in writer BTF order).
    #
    # Strategy: `prep(max_field_align, inline_size_data)` BEFORE
    # writing field data so that AFTER writing `inline_size_data`
    # bytes, `_bytes_written` is `max_field_align`-aligned. Combined
    # with `finalize()` padding the buffer to a `_min_align`-aligned
    # total, the OUTPUT inline-data-start position is
    # `max_field_align`-aligned.
    writer.prep(max_field_align, inline_size_data)

    # Step 2: write inline data back-to-front. We walk fields in
    # DESCENDING inline_offset (so the highest-offset field is written
    # first, ending up at the highest writer position post-back-to-
    # front emission).
    #
    # First pass: build a sorted-by-inline-offset list of present field
    # IDs. With MAX_VTABLE_FIELDS = 16 the bubble sort is trivial; no
    # heap allocation needed.
    var sorted_ids = Array[Int, MAX_VTABLE_FIELDS](fill=-1)
    var n_present = 0
    for i in range(field_count):
        if tb._field_present[i]:
            sorted_ids[n_present] = i
            n_present += 1
    # Bubble sort descending by inline_offsets[id].
    for i in range(n_present):
        for j in range(0, n_present - i - 1):
            var a = sorted_ids[j]
            var b = sorted_ids[j + 1]
            if Int(inline_offsets[a]) < Int(inline_offsets[b]):
                sorted_ids[j] = b
                sorted_ids[j + 1] = a

    # Track expected cursor at end of inline data emission. The data
    # area should span [cursor_at_start_of_data, cursor_at_start_of_data
    # + inline_size_data). We emit highest-offset field first.
    var cursor_start = writer.cursor()  # before we start writing
    # We don't write here; we'll emit in the loop below. Track the
    # CURRENT inline_size_data position we need to occupy.
    var current_inline_pos = inline_size_data  # decreases as we write

    # Tail padding: bytes between (inline_size_data + 4 (soffset)) and
    # the topmost inline_offset of any field. Because we emit
    # highest-offset field first, and that field's END at
    # `inline_offset[id] + width[id]` may be < inline_size_data, we
    # need leading pad bytes to fill the gap.
    var topmost_end = 0
    for k in range(n_present):
        var id = sorted_ids[k]
        var off = Int(inline_offsets[id])
        var end = off + Int(tb._field_widths[id])
        # widths capped at 255 for >16-byte structs; use struct_size.
        var struct_sz = Int(tb._field_struct_size[id])
        if struct_sz > 0:
            end = off + struct_sz
        if end > topmost_end:
            topmost_end = end
    var tail_pad = inline_size_data - topmost_end
    if tail_pad > 0:
        writer.write_padding(tail_pad)  # cov: unreachable inline_size_data is the end of the last field, which no field passes
        current_inline_pos -= tail_pad  # cov: unreachable inline_size_data is the end of the last field, which no field passes

    for k in range(n_present):
        var id = sorted_ids[k]
        var off = Int(inline_offsets[id])
        var w = Int(tb._field_widths[id])
        var struct_sz = Int(tb._field_struct_size[id])
        var actual_w = struct_sz if struct_sz > 0 else w

        # Inline padding between (prev_field_start) and (this_field_end).
        # Since we walk in descending order, `current_inline_pos` is the
        # position the next byte will go to (we wrote down to it). We
        # need to land this field's END at `off + actual_w`.
        var pad_between = current_inline_pos - (off + actual_w)
        if pad_between > 0:
            writer.write_padding(pad_between)
            current_inline_pos -= pad_between

        # Emit field bytes (back-to-front means last byte first).
        if struct_sz > 0:
            # Inline-struct field — copy from scratch buffer in REVERSE.
            var scratch_off = Int(tb._field_struct_offset[id])
            for b in range(struct_sz - 1, -1, -1):
                writer.write_u8(tb._struct_scratch[scratch_off + b])
        elif w == 8:
            # i64 inline.
            writer.write_i64_le(tb._field_i64_values[id])
        elif w == 4:
            var v = tb._field_values[id]
            if (v & UInt32(0x80000000)) != UInt32(0):
                # Offset placeholder.
                var target = Int(v & UInt32(0x7FFFFFFF))
                writer.write_offset_u32(target)
            else:
                writer.write_u32_le(v)
        elif w == 2:
            writer.write_u16_le(UInt16(Int(tb._field_values[id]) & 0xFFFF))
        elif w == 1:
            writer.write_u8(UInt8(Int(tb._field_values[id]) & 0xFF))
        else:
            raise Error(
                "end_table: unsupported field width "
                + String(w)
                + " at field_id="
                + String(id)
            )
        current_inline_pos -= actual_w

    # current_inline_pos should be 0 here. If not, there's a layout bug.
    if current_inline_pos != 0:
        raise Error(
            "end_table: inline data layout mismatch — current_inline_pos="
            + String(current_inline_pos)
            + " (expected 0)"
        )

    # Step 3 + 4: write i32 soffset placeholder; note table_pos.
    writer.write_i32_le(Int32(0))  # placeholder
    var table_pos = writer.cursor()

    # Step 5: emit (or reuse) the vtable.
    #
    # Vtable wire layout (output forward order):
    #   [u16 vtable_size, u16 inline_size, u16 field_offsets[N]]
    # The vtable.field_offsets[i] is the position of field i RELATIVE
    # to the table start (= position of soffset). Field i lives at
    # `table_offset_byte = 4 + inline_offsets[i]` (4 = soffset width);
    # absent fields are 0.
    #
    # §2.4 (WIRE-OPTIMAL) — vtable dedup. First build the table-relative
    # field_offsets array (the vtable SHAPE). If an identical shape was
    # already emitted in this writer, point THIS table's soffset at the
    # cached vtable instead of writing a duplicate; this is the dominant
    # metadata size win on wide schemas. Otherwise emit a fresh vtable
    # (back-to-front) and record its shape + output position for reuse.
    var vtable_size = 2 + 2 + 2 * field_count
    var vt_field_offsets = Array[Int32, MAX_VTABLE_FIELDS](fill=Int32(0))
    for i in range(field_count):
        if tb._field_present[i]:
            vt_field_offsets[i] = Int32(4 + Int(inline_offsets[i]))
        else:
            vt_field_offsets[i] = Int32(0)

    var cached_pos = writer._vtable_lookup(
        field_count, inline_size_with_soffset, vt_field_offsets
    )
    var vtable_pos: Int
    if cached_pos >= 0:
        # Dedup hit — reuse the cached vtable. No bytes written here. The
        # soffset (patched below) may be positive or negative depending on
        # whether the reused vtable precedes or follows this table; both
        # are spec-valid (see _vtable_lookup ordering note).
        vtable_pos = cached_pos
    else:
        # Dedup miss — emit a fresh vtable back-to-front (last byte first).
        for i in range(field_count - 1, -1, -1):
            writer.write_u16_le(UInt16(Int(vt_field_offsets[i])))
        writer.write_u16_le(UInt16(inline_size_with_soffset))
        writer.write_u16_le(UInt16(vtable_size))
        vtable_pos = writer.cursor()
        writer._vtable_record(
            field_count, inline_size_with_soffset, vt_field_offsets, vtable_pos
        )

    # Step 6: patch the soffset slot.
    # soffset value = table_pos - vtable_pos. For a freshly-emitted vtable
    # (dedup miss) it is POSITIVE: the vtable was written right AFTER the
    # table in back-to-front order, so it lands BEFORE the table in output
    # order. For a REUSED vtable (dedup hit) it may be positive OR negative
    # depending on whether the cached vtable precedes or follows this
    # table; the FlatBuffers soffset is signed precisely to allow this, and
    # the reader resolves `vtable_pos = table_pos - soffset` either way.
    var soffset = Int32(table_pos - vtable_pos)
    writer._buf.write_i32_le_at(table_pos, soffset)

    _ = cursor_start  # diagnostic; unused
    return table_pos


# =============================================================================
# §6 — Type union arm writers + readers (4 representative arms)
# =============================================================================
#
# Apache Arrow Schema.fbs Type union has 25 variants. This section holds
# 4 REPRESENTATIVE arms covering the primitive surface most queries
# need: Int / FloatingPoint / Utf8 / Bool.
#
# The remaining 21 arms (Null / Binary / LargeBinary / LargeUtf8 /
# Decimal / Date / Time / Timestamp / Duration / Interval / List /
# LargeList / FixedSizeList / Struct_ / Union / Map / FixedSizeBinary /
# BinaryView / Utf8View / ListView / LargeListView / RunEndEncoded)
# follow the same paired-writer/reader mechanical pattern (§6.b).
# =============================================================================


def write_type_int(mut writer: FlatbufWriter, bit_width: Int, is_signed: Bool) raises -> Int:
    """Write an Int type table.

    Schema.fbs Int table fields:
        - bit_width: int = 32 (default 32)
        - is_signed: bool = true (default true)

    Returns the table position (i32 soffset_to_vtable slot).
    """
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(bit_width))  # bit_width: int
    add_field_bool(tb, 1, is_signed)          # is_signed: bool
    return end_table(writer, tb^)


def write_dictionary_encoding(
    mut writer: FlatbufWriter,
    id: Int64,
    index_type_bit_width: Int,
    index_type_is_signed: Bool,
    is_ordered: Bool,
) raises -> Int:
    """Write a DictionaryEncoding table (Schema.fbs).

    Schema.fbs DictionaryEncoding fields:
        0: id: long (i64 — dict_id; per-Schema identifier joining
           Field.dictionary -> DictionaryBatch values)
        1: indexType: Int (offset to inner Int table — typically
           Int32; reused as the on-wire index type)
        2: isOrdered: bool (default false)
        3: dictionaryKind: DictionaryKind enum (DenseArray=0 default)

    The inner Int table is emitted FIRST so its position is known
    when this table's vtable is finalized; then the outer table is
    emitted referencing it via slot 1's offset.

    Returns the outer DictionaryEncoding table position.

    Used by `write_field` when a Field is dict-encoded (slot 4).
    """
    # Emit inner Int table for indexType first; its position becomes
    # the offset value of slot 1 in the outer DictionaryEncoding table.
    var index_type_pos = write_type_int(
        writer, index_type_bit_width, index_type_is_signed
    )

    var tb = start_table()
    add_field_i64(tb, 0, id)
    add_field_offset(tb, 1, index_type_pos)
    add_field_bool(tb, 2, is_ordered)
    # Slot 3 (dictionaryKind) omitted — DenseArray=0 default matches our
    # contract; non-default kinds aren't supported.
    return end_table(writer, tb^)


def write_type_floating_point(
    mut writer: FlatbufWriter, precision: Int
) raises -> Int:
    """Write a FloatingPoint type table.

    Schema.fbs FloatingPoint table fields:
        - precision: Precision enum (HALF=0, SINGLE=1, DOUBLE=2)
    """
    var tb = start_table()
    add_field_u8(tb, 0, UInt8(precision))
    return end_table(writer, tb^)


def write_type_utf8(mut writer: FlatbufWriter) raises -> Int:
    """Write a Utf8 type table.

    Schema.fbs Utf8 table has NO fields — it's a tag-only variant.
    Returns the table position; the table consists of just the
    soffset_to_vtable + an empty vtable (vtable_size=4, inline_size=4).
    """
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_bool(mut writer: FlatbufWriter) raises -> Int:
    """Write a Bool type table (tag-only)."""
    var tb = start_table()
    return end_table(writer, tb^)


# Precision enum constants (Schema.fbs FloatingPoint.precision).
comptime PRECISION_HALF: UInt8 = 0
comptime PRECISION_SINGLE: UInt8 = 1
comptime PRECISION_DOUBLE: UInt8 = 2

# Endianness enum constants (Schema.fbs Schema.endianness).
comptime ENDIANNESS_LITTLE: UInt8 = 0
comptime ENDIANNESS_BIG: UInt8 = 1

# DateUnit enum (Schema.fbs Date.unit).
comptime DATE_UNIT_DAY: UInt8 = 0
comptime DATE_UNIT_MILLISECOND: UInt8 = 1

# TimeUnit enum (Schema.fbs Time / Timestamp / Duration .unit).
comptime TIME_UNIT_SECOND: UInt8 = 0
comptime TIME_UNIT_MILLISECOND: UInt8 = 1
comptime TIME_UNIT_MICROSECOND: UInt8 = 2
comptime TIME_UNIT_NANOSECOND: UInt8 = 3

# IntervalUnit enum (Schema.fbs Interval.unit).
comptime INTERVAL_UNIT_YEAR_MONTH: UInt8 = 0
comptime INTERVAL_UNIT_DAY_TIME: UInt8 = 1
comptime INTERVAL_UNIT_MONTH_DAY_NANO: UInt8 = 2

# UnionMode enum (Schema.fbs Union.mode).
comptime UNION_MODE_SPARSE: UInt8 = 0
comptime UNION_MODE_DENSE: UInt8 = 1


# =============================================================================
# §6.b — the 21 remaining Type union arms
# =============================================================================
#
# Mechanical fanout of the Type union arms beyond the
# representative 4 (Int/FloatingPoint/Utf8/Bool). Each arm follows
# the same paired writer/reader shape:
#   - tag-only arms (no fields): write_type_<name> just calls
#     start_table + end_table — an empty vtable identifies the
#     variant via the parent Field's type_tag discriminant.
#   - typed arms: add_field_u32/u8/bool/offset per Schema.fbs spec.
#
# Apache Arrow Schema.fbs field declaration order is canonical;
# field IDs match this order. Refer to
# https://github.com/apache/arrow/blob/main/format/Schema.fbs for
# the source of truth.
# =============================================================================


# --- Tag-only arms (12 variants, no inline fields) ---


def write_type_null(mut writer: FlatbufWriter) raises -> Int:
    """Write a Null type table (tag-only)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_binary(mut writer: FlatbufWriter) raises -> Int:
    """Write a Binary type table (tag-only; variable-length byte array)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_large_binary(mut writer: FlatbufWriter) raises -> Int:
    """Write a LargeBinary type (i64 offsets)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_large_utf8(mut writer: FlatbufWriter) raises -> Int:
    """Write a LargeUtf8 type (i64 offsets)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_list(mut writer: FlatbufWriter) raises -> Int:
    """Write a List type (children carry the element type)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_large_list(mut writer: FlatbufWriter) raises -> Int:
    """Write a LargeList type (i64 offsets)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_struct(mut writer: FlatbufWriter) raises -> Int:
    """Write a Struct_ type (children carry per-field types)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_run_end_encoded(mut writer: FlatbufWriter) raises -> Int:
    """Write a RunEndEncoded type (children carry run-end + values types)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_binary_view(mut writer: FlatbufWriter) raises -> Int:
    """Write a BinaryView type (view-cell layout)."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_utf8_view(mut writer: FlatbufWriter) raises -> Int:
    """Write a Utf8View type."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_list_view(mut writer: FlatbufWriter) raises -> Int:
    """Write a ListView type."""
    var tb = start_table()
    return end_table(writer, tb^)


def write_type_large_list_view(mut writer: FlatbufWriter) raises -> Int:
    """Write a LargeListView type (i64 offsets)."""
    var tb = start_table()
    return end_table(writer, tb^)


# --- Typed arms (with inline fields) ---


def write_type_decimal(
    mut writer: FlatbufWriter,
    precision: Int,
    scale: Int,
    bit_width: Int,
) raises -> Int:
    """Write a Decimal type.

    Schema.fbs Decimal fields:
        0: precision: int
        1: scale: int
        2: bitWidth: int = 128 (default 128; 256 also valid)
    """
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(precision))
    add_field_u32(tb, 1, UInt32(scale))
    add_field_u32(tb, 2, UInt32(bit_width))
    return end_table(writer, tb^)


def write_type_date(mut writer: FlatbufWriter, unit: UInt8) raises -> Int:
    """Write a Date type. unit ∈ {DATE_UNIT_DAY, DATE_UNIT_MILLISECOND}.

    Schema.fbs Date fields:
        0: unit: DateUnit enum (u16 in spec, stored u8 in our layout).
    """
    var tb = start_table()
    add_field_u8(tb, 0, unit)
    return end_table(writer, tb^)


def write_type_time(
    mut writer: FlatbufWriter, unit: UInt8, bit_width: Int
) raises -> Int:
    """Write a Time type.

    Schema.fbs Time fields:
        0: unit: TimeUnit enum
        1: bitWidth: int = 32 (default 32; 64 valid)
    """
    var tb = start_table()
    add_field_u8(tb, 0, unit)
    add_field_u32(tb, 1, UInt32(bit_width))
    return end_table(writer, tb^)


def write_type_timestamp(
    mut writer: FlatbufWriter, unit: UInt8, timezone: StringSlice
) raises -> Int:
    """Write a Timestamp type.

    Schema.fbs Timestamp fields:
        0: unit: TimeUnit enum
        1: timezone: string (offset; empty string = "no tz" sentinel)
    """
    # Write timezone string FIRST so its position is known.
    var tz_pos = -1
    if timezone.byte_length() > 0:
        tz_pos = writer.write_string(timezone)

    var tb = start_table()
    add_field_u8(tb, 0, unit)
    if tz_pos >= 0:
        add_field_offset(tb, 1, tz_pos)
    return end_table(writer, tb^)


def write_type_interval(mut writer: FlatbufWriter, unit: UInt8) raises -> Int:
    """Write an Interval type.

    Schema.fbs Interval fields:
        0: unit: IntervalUnit enum (YEAR_MONTH / DAY_TIME / MONTH_DAY_NANO)
    """
    var tb = start_table()
    add_field_u8(tb, 0, unit)
    return end_table(writer, tb^)


def write_type_duration(mut writer: FlatbufWriter, unit: UInt8) raises -> Int:
    """Write a Duration type.

    Schema.fbs Duration fields:
        0: unit: TimeUnit enum
    """
    var tb = start_table()
    add_field_u8(tb, 0, unit)
    return end_table(writer, tb^)


def write_type_fixed_size_binary(
    mut writer: FlatbufWriter, byte_width: Int
) raises -> Int:
    """Write a FixedSizeBinary type.

    Schema.fbs FixedSizeBinary fields:
        0: byteWidth: int
    """
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(byte_width))
    return end_table(writer, tb^)


def write_type_fixed_size_list(
    mut writer: FlatbufWriter, list_size: Int
) raises -> Int:
    """Write a FixedSizeList type.

    Schema.fbs FixedSizeList fields:
        0: listSize: int
    """
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(list_size))
    return end_table(writer, tb^)


def write_type_map(mut writer: FlatbufWriter, keys_sorted: Bool) raises -> Int:
    """Write a Map type.

    Schema.fbs Map fields:
        0: keysSorted: bool
    """
    var tb = start_table()
    add_field_bool(tb, 0, keys_sorted)
    return end_table(writer, tb^)


def write_type_union(
    mut writer: FlatbufWriter,
    mode: UInt8,
    type_ids: List[Int32],
) raises -> Int:
    """Write a Union type.

    Schema.fbs Union fields:
        0: mode: UnionMode enum (SPARSE / DENSE)
        1: typeIds: [int]
    """
    # Write typeIds vector first.
    var n = len(type_ids)
    # I32 elements + u32 length both 4-aligned.
    writer.prep(4, n * 4 + 4)
    for i in range(n - 1, -1, -1):
        writer.write_i32_le(type_ids[i])
    writer.write_u32_le(UInt32(n))
    var type_ids_vec_pos = writer.cursor()

    var tb = start_table()
    add_field_u8(tb, 0, mode)
    add_field_offset(tb, 1, type_ids_vec_pos)
    return end_table(writer, tb^)


# =============================================================================
# §6.c — reader descriptors + read fns for typed arms
# =============================================================================


@fieldwise_init
struct DecimalTypeDescriptor(Copyable, Movable):
    """Decoded Decimal type: precision + scale + bit_width."""
    var precision: Int
    var scale: Int
    var bit_width: Int


@fieldwise_init
struct DateTypeDescriptor(Copyable, Movable):
    """Decoded Date type: unit (DAY / MILLISECOND)."""
    var unit: UInt8


@fieldwise_init
struct TimeTypeDescriptor(Copyable, Movable):
    """Decoded Time type: unit + bit_width."""
    var unit: UInt8
    var bit_width: Int


@fieldwise_init
struct TimestampTypeDescriptor(Copyable, Movable):
    """Decoded Timestamp type: unit + timezone (empty if absent)."""
    var unit: UInt8
    var timezone: String


@fieldwise_init
struct IntervalTypeDescriptor(Copyable, Movable):
    """Decoded Interval type: unit."""
    var unit: UInt8


@fieldwise_init
struct DurationTypeDescriptor(Copyable, Movable):
    """Decoded Duration type: unit."""
    var unit: UInt8


@fieldwise_init
struct FixedSizeBinaryTypeDescriptor(Copyable, Movable):
    """Decoded FixedSizeBinary type: byte_width."""
    var byte_width: Int


@fieldwise_init
struct FixedSizeListTypeDescriptor(Copyable, Movable):
    """Decoded FixedSizeList type: list_size."""
    var list_size: Int


@fieldwise_init
struct MapTypeDescriptor(Copyable, Movable):
    """Decoded Map type: keys_sorted."""
    var keys_sorted: Bool


@fieldwise_init
struct UnionTypeDescriptor(Copyable, Movable):
    """Decoded Union type: mode + type_ids."""
    var mode: UInt8
    var type_ids: List[Int32]


def read_type_decimal[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> DecimalTypeDescriptor:
    """Read a Decimal Type table."""
    var precision = Int(_read_table_field_u32(reader, table_pos, 0))
    var scale = Int(_read_table_field_u32(reader, table_pos, 1))
    # Schema.fbs: `bitWidth: int = 128`.
    var bit_width = Int(_read_table_field_u32_or(reader, table_pos, 2, 128))
    return DecimalTypeDescriptor(
        precision=precision, scale=scale, bit_width=bit_width
    )


def read_type_date[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> DateTypeDescriptor:
    """Read a Date Type table. Schema.fbs: `unit: DateUnit = MILLISECOND`,
    so an absent unit is date64, not date32."""
    return DateTypeDescriptor(
        unit=_read_table_field_u8_or(
            reader, table_pos, 0, DATE_UNIT_MILLISECOND
        )
    )


def read_type_time[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> TimeTypeDescriptor:
    """Read a Time Type table. Schema.fbs:
    `unit: TimeUnit = MILLISECOND; bitWidth: int = 32`."""
    var unit = _read_table_field_u8_or(
        reader, table_pos, 0, TIME_UNIT_MILLISECOND
    )
    var bit_width = Int(_read_table_field_u32_or(reader, table_pos, 1, 32))
    return TimeTypeDescriptor(unit=unit, bit_width=bit_width)


def read_type_timestamp[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> TimestampTypeDescriptor:
    """Read a Timestamp Type table. Schema.fbs: `unit: TimeUnit` (default
    SECOND)."""
    var unit = _read_table_field_u8_or(reader, table_pos, 0, TIME_UNIT_SECOND)
    var tz_pos = _read_table_field_offset(reader, table_pos, 1)
    var tz_str = String("")
    if tz_pos >= 0:
        tz_str = reader.read_string_at(tz_pos)
    return TimestampTypeDescriptor(unit=unit, timezone=tz_str^)


def read_type_interval[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> IntervalTypeDescriptor:
    """Read an Interval Type table. Schema.fbs: `unit: IntervalUnit`
    (default YEAR_MONTH)."""
    return IntervalTypeDescriptor(
        unit=_read_table_field_u8_or(
            reader, table_pos, 0, INTERVAL_UNIT_YEAR_MONTH
        )
    )


def read_type_duration[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> DurationTypeDescriptor:
    """Read a Duration Type table. Schema.fbs:
    `unit: TimeUnit = MILLISECOND`."""
    return DurationTypeDescriptor(
        unit=_read_table_field_u8_or(
            reader, table_pos, 0, TIME_UNIT_MILLISECOND
        )
    )


def read_type_fixed_size_binary[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo], table_pos: Int
) raises -> FixedSizeBinaryTypeDescriptor:
    """Read a FixedSizeBinary Type table."""
    return FixedSizeBinaryTypeDescriptor(
        byte_width=Int(_read_table_field_u32(reader, table_pos, 0))
    )


def read_type_fixed_size_list[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo], table_pos: Int
) raises -> FixedSizeListTypeDescriptor:
    """Read a FixedSizeList Type table."""
    return FixedSizeListTypeDescriptor(
        list_size=Int(_read_table_field_u32(reader, table_pos, 0))
    )


def read_type_map[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> MapTypeDescriptor:
    """Read a Map Type table."""
    return MapTypeDescriptor(
        keys_sorted=_read_table_field_bool(reader, table_pos, 0)
    )


def read_type_union[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> UnionTypeDescriptor:
    """Read a Union Type table. Schema.fbs: `mode: UnionMode` (default
    Sparse)."""
    var mode = _read_table_field_u8_or(reader, table_pos, 0, UNION_MODE_SPARSE)
    var ids_vec_pos = _read_table_field_offset(reader, table_pos, 1)
    var ids = List[Int32]()
    if ids_vec_pos >= 0:
        var n = Int(reader.read_u32_le(ids_vec_pos))
        # ASSERT=none HARDENING: validate-then-reserve. See
        # read_record_batch for the full rationale; i32 elements here.
        reader._check_bounds(ids_vec_pos + 4, n * 4)
        ids.reserve(n)
        for i in range(n):
            ids.append(reader.read_i32_le(ids_vec_pos + 4 + i * 4))
    return UnionTypeDescriptor(mode=mode, type_ids=ids^)


# =============================================================================
# §7 — Field + Schema writers
# =============================================================================
#
# Schema.fbs Field table fields (in declaration order):
#   0: name: string (offset)
#   1: nullable: bool
#   2: type_type: Type union discriminator (u8 tag)
#   3: type: Type union payload (offset to Type variant table)
#   4: dictionary: DictionaryEncoding (offset; nullable — None = absent)
#   5: children: [Field] (vector offset)
#   6: custom_metadata: [KeyValue] (vector offset)
#
# Schema.fbs Schema table fields:
#   0: endianness: Endianness enum (u16 in spec, but stored as u8 here
#      for our simple-layout discipline; matches arrow-rs's behavior
#      of zero-extending small enums).
#   1: fields: [Field] (vector offset)
#   2: custom_metadata: [KeyValue]
#   3: features: [Feature] (skip — emitted empty)
# =============================================================================


def write_field(
    mut writer: FlatbufWriter,
    name: StringSlice,
    nullable: Bool,
    type_tag: UInt8,
    type_table_pos: Int,
    dictionary_pos: Int = -1,
) raises -> Int:
    """Write a Field table.

    Schema.fbs Field fields:
        0: name: string (offset to FB string)
        1: nullable: bool
        2: type_type: u8 tag
        3: type: offset to the Type variant table
        4: dictionary: DictionaryEncoding (offset; absent = -1)

    `dictionary_pos`: when >= 0, the position of a pre-written
    `DictionaryEncoding` table (via `write_dictionary_encoding`). When
    -1 (default), Field.dictionary is omitted — fully back-compat with
    callers that don't dict-encode.

    Returns the table position.
    """
    # Write the name string FIRST so its position is known when the
    # field table goes through `end_table`.
    var name_pos = writer.write_string(name)

    var tb = start_table()
    add_field_offset(tb, 0, name_pos)
    add_field_bool(tb, 1, nullable)
    add_field_u8(tb, 2, type_tag)
    add_field_offset(tb, 3, type_table_pos)
    if dictionary_pos >= 0:
        add_field_offset(tb, 4, dictionary_pos)
    return end_table(writer, tb^)


def write_schema(
    mut writer: FlatbufWriter,
    endianness: UInt8,
    field_positions: List[Int],
) raises -> Int:
    """Write a Schema table (minimal: no custom_metadata,
    no features).

    Schema.fbs Schema fields:
        0: endianness: enum (u8 inline)
        1: fields: vector of [Field] offsets (offset to FB vector)

    Returns the table position.
    """
    # Write the [Field] vector FIRST. FB vector layout:
    # [u32 length, element[length]] where elements are u32 offsets.
    # U32 offset elements + u32 length, 4-aligned.
    var n_fields = len(field_positions)
    writer.prep(4, n_fields * 4 + 4)
    # Vector elements written back-to-front: last element first.
    # Each element is a u32 offset (relative from the offset's
    # position to the target field table).
    for i in range(n_fields - 1, -1, -1):
        writer.write_offset_u32(field_positions[i])
    writer.write_u32_le(UInt32(n_fields))
    var fields_vec_pos = writer.cursor()

    var tb = start_table()
    add_field_u8(tb, 0, endianness)
    add_field_offset(tb, 1, fields_vec_pos)
    return end_table(writer, tb^)


# =============================================================================
# §8 — Reader-side Type / Field / Schema helpers
# =============================================================================
#
# Symmetric reader entry points. Each returns a small descriptor
# struct that owns its data (no UnsafePointer leaks).
# =============================================================================


@fieldwise_init
struct IntTypeDescriptor(Copyable, Movable):
    """Decoded Arrow Int type: bit_width + is_signed."""
    var bit_width: Int
    var is_signed: Bool


@fieldwise_init
struct FloatingPointTypeDescriptor(Copyable, Movable):
    """Decoded Arrow FloatingPoint type: precision (HALF/SINGLE/DOUBLE)."""
    var precision: UInt8


@fieldwise_init
struct DictionaryEncodingDescriptor(Copyable, Movable):
    """Decoded Arrow Field.dictionary (DictionaryEncoding).

    Flatbuf-layer POD that carries the dict-encoding metadata extracted
    from a Field table's slot 4. The contract pins indexType to a single
    Int variant (default INT32, signed).
    """
    var id: Int64
    var index_type_bit_width: Int
    var index_type_is_signed: Bool
    var is_ordered: Bool


@fieldwise_init
struct FieldDescriptor(Copyable, Movable):
    """Decoded Arrow Field: name + nullable + type_tag + type_table_pos
    + optional dictionary_encoding.

    type_table_pos is the buffer position of the Type variant's table;
    callers dispatch on type_tag to call the matching read_type_*.

    `dictionary_encoding` is populated when Field slot 4 is present on
    the wire (dict-encoded column); None otherwise.
    """
    var name: String
    var nullable: Bool
    var type_tag: UInt8
    var type_table_pos: Int
    var dictionary_encoding: Optional[DictionaryEncodingDescriptor]


@fieldwise_init
struct SchemaDescriptor(Copyable, Movable):
    """Decoded Arrow Schema: endianness + list of FieldDescriptor."""
    var endianness: UInt8
    var fields: List[FieldDescriptor]


# Absent fields and schema defaults.
#
# A FlatBuffers writer omits a scalar field whose value equals the default
# the schema declares for it (pyarrow and every flatc-generated builder do).
# A reader must then return that declared default, not 0. A field is absent
# when the vtable is too short to hold its slot or when its slot holds 0.
# The `_or` readers take the declared default; the plain readers are the
# `_or` readers with default 0, correct only for fields whose declared
# default is 0. Fields with a non-zero default in Schema.fbs:
# `Decimal.bitWidth = 128`, `Date.unit = MILLISECOND`,
# `Time.unit = MILLISECOND`, `Time.bitWidth = 32`,
# `Duration.unit = MILLISECOND`.


def _read_table_field_u32_or[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo],
    table_pos: Int,
    field_id: Int,
    default_value: UInt32,
) raises -> UInt32:
    """Read the u32 stored at field `field_id` of the table at
    `table_pos`. Returns `default_value`, the field's declared schema
    default, if the field is absent.

    Resolves vtable, reads field_offset[field_id], then the inline slot.
    """
    var soffset = reader.read_i32_le(table_pos)
    var vtable_pos = table_pos - Int(soffset)
    if vtable_pos < 0:
        raise Error(
            "FlatbufReader: invalid vtable position " + String(vtable_pos)
        )
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    # Each field is a u16 at vtable_pos + 4 + field_id * 2.
    var slot_offset = 4 + field_id * 2
    if slot_offset + 2 > vtable_size:
        return default_value  # field beyond declared slots: absent
    var inline_offset = Int(reader.read_u16_le(vtable_pos + slot_offset))
    if inline_offset == 0:
        return default_value  # slot present but empty: absent
    return reader.read_u32_le(table_pos + inline_offset)


def _read_table_field_u32[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> UInt32:
    """Read a u32 field whose declared schema default is 0. Returns 0 if
    the field is absent."""
    return _read_table_field_u32_or(reader, table_pos, field_id, UInt32(0))


def _read_table_field_u8_or[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo],
    table_pos: Int,
    field_id: Int,
    default_value: UInt8,
) raises -> UInt8:
    """Read a u8 field. Returns `default_value`, the field's declared schema
    default, if the field is absent.

    Reads EXACTLY 1 byte (NOT 4 via u32 mask) so the
    read fits inside the FB payload even when the field is at the
    very end of the buffer. The previous u32-read-then-mask shape
    over-read by 3 bytes at end-of-buffer positions (a SparseTensor CSX
    decode failure). Arrow's `short` enums (DateUnit, TimeUnit, ...) are
    read through this too: the low byte of the little-endian i16 holds
    every value those enums define.
    """
    var soffset = reader.read_i32_le(table_pos)
    var vtable_pos = table_pos - Int(soffset)
    if vtable_pos < 0:
        raise Error(
            "FlatbufReader: invalid vtable position " + String(vtable_pos)
        )
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    var slot_offset = 4 + field_id * 2
    if slot_offset + 2 > vtable_size:
        return default_value  # field beyond declared slots: absent
    var inline_offset = Int(reader.read_u16_le(vtable_pos + slot_offset))
    if inline_offset == 0:
        return default_value  # slot present but empty: absent
    return reader.read_u8(table_pos + inline_offset)


def _read_table_field_u8[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> UInt8:
    """Read a u8 field whose declared schema default is 0. Returns 0 if
    the field is absent."""
    return _read_table_field_u8_or(reader, table_pos, field_id, UInt8(0))


def _read_table_field_bool[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> Bool:
    """Read a Bool field. Routes through `_read_table_field_u8` for the
    1-byte read (fixes end-of-buffer over-read; see u8 docstring)."""
    return _read_table_field_u8(reader, table_pos, field_id) != UInt8(0)


def _read_table_field_offset[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> Int:
    """Read an OFFSET field; returns the resolved target position.

    Returns -1 if the field is absent (so caller can distinguish
    absent-offset from a valid offset).
    """
    var soffset = reader.read_i32_le(table_pos)
    var vtable_pos = table_pos - Int(soffset)
    if vtable_pos < 0:
        raise Error("FlatbufReader: invalid vtable position")
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    var slot_offset = 4 + field_id * 2
    if slot_offset + 2 > vtable_size:
        return -1
    var inline_offset = Int(reader.read_u16_le(vtable_pos + slot_offset))
    if inline_offset == 0:
        return -1
    var slot_pos = table_pos + inline_offset
    return reader.read_offset_u32(slot_pos)


def _read_table_field_i64[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> Int64:
    """Read an 8-byte i64 inline field. Returns 0 if absent.

    Used for canonical i64 fields (RecordBatch.length / Message.bodyLength /
    Footer Block.* / TensorDim.size). Strictly reads 8 bytes — vs the
    older `_read_table_field_u32`-masked path which read 4 bytes and
    truncated.
    """
    var soffset = reader.read_i32_le(table_pos)
    var vtable_pos = table_pos - Int(soffset)
    if vtable_pos < 0:
        raise Error("FlatbufReader: invalid vtable position")
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    var slot_offset = 4 + field_id * 2
    if slot_offset + 2 > vtable_size:
        return Int64(0)
    var inline_offset = Int(reader.read_u16_le(vtable_pos + slot_offset))
    if inline_offset == 0:
        return Int64(0)
    return reader.read_i64_le(table_pos + inline_offset)


def _read_table_field_buffer_inline[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo], table_pos: Int, field_id: Int
) raises -> BufferDescriptor:
    """Read an INLINE Buffer struct (16 bytes: offset i64 + length i64)
    at field `field_id`.

    Returns BufferDescriptor{0, 0} if absent (caller can distinguish via
    a vtable presence check if needed; v1 callers always set the field).
    """
    var soffset = reader.read_i32_le(table_pos)
    var vtable_pos = table_pos - Int(soffset)
    if vtable_pos < 0:
        raise Error("FlatbufReader: invalid vtable position")
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    var slot_offset = 4 + field_id * 2
    if slot_offset + 2 > vtable_size:
        return BufferDescriptor(offset=Int64(0), length=Int64(0))
    var inline_offset = Int(reader.read_u16_le(vtable_pos + slot_offset))
    if inline_offset == 0:
        return BufferDescriptor(offset=Int64(0), length=Int64(0))
    var pos = table_pos + inline_offset
    var off = reader.read_i64_le(pos)
    var length = reader.read_i64_le(pos + 8)
    return BufferDescriptor(offset=off, length=length)


def read_type_int[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> IntTypeDescriptor:
    """Read an Int Type table."""
    var bit_width = Int(_read_table_field_u32(reader, table_pos, 0))
    var is_signed = _read_table_field_bool(reader, table_pos, 1)
    return IntTypeDescriptor(bit_width=bit_width, is_signed=is_signed)


def read_type_floating_point[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo], table_pos: Int
) raises -> FloatingPointTypeDescriptor:
    """Read a FloatingPoint Type table. Schema.fbs: `precision: Precision`
    (default HALF)."""
    var precision = _read_table_field_u8_or(
        reader, table_pos, 0, PRECISION_HALF
    )
    return FloatingPointTypeDescriptor(precision=precision)


def read_field[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> FieldDescriptor:
    """Read a Field table.

    Reads slots 0..4 from Schema.fbs Field:
        0: name (string offset; optional: Schema.fbs says "Name is not
           required (e.g., in a List)", and an absent name reads as "",
           as Arrow C++ reads it)
        1: nullable (bool)
        2: type_type (u8 union tag)
        3: type (offset to Type variant table; required)
        4: dictionary (offset to DictionaryEncoding table; optional —
           populated only if the field is dict-encoded on the wire).

    Slots 5 (children) and 6 (custom_metadata) are read elsewhere by
    schema-walker entry points; this primitive just exposes the
    primary Field slots + dict_encoding for
    DECODE-COLUMN.
    """
    var name_pos = _read_table_field_offset(reader, table_pos, 0)
    var name = String("")
    if name_pos >= 0:
        name = reader.read_string_at(name_pos)
    var nullable = _read_table_field_bool(reader, table_pos, 1)
    var type_tag = _read_table_field_u8(reader, table_pos, 2)
    var type_pos = _read_table_field_offset(reader, table_pos, 3)
    if type_pos < 0:
        raise Error("Field: type field missing")

    # Slot 4 (dictionary: DictionaryEncoding) — optional. Resolve the
    # outer DictionaryEncoding table position, then drill into its
    # inner Int table (slot 1) for indexType bit_width + is_signed.
    var dictionary_encoding = Optional[DictionaryEncodingDescriptor](None)
    var dict_pos = _read_table_field_offset(reader, table_pos, 4)
    if dict_pos >= 0:
        var dict_id = _read_table_field_i64(reader, dict_pos, 0)
        var index_type_pos = _read_table_field_offset(reader, dict_pos, 1)
        var idx_bit_width: Int = 32
        var idx_is_signed: Bool = True
        if index_type_pos >= 0:
            var idx_desc = read_type_int(reader, index_type_pos)
            idx_bit_width = idx_desc.bit_width
            idx_is_signed = idx_desc.is_signed
        var is_ordered = _read_table_field_bool(reader, dict_pos, 2)
        dictionary_encoding = Optional[DictionaryEncodingDescriptor](
            DictionaryEncodingDescriptor(
                id=dict_id,
                index_type_bit_width=idx_bit_width,
                index_type_is_signed=idx_is_signed,
                is_ordered=is_ordered,
            )
        )

    return FieldDescriptor(
        name=name^,
        nullable=nullable,
        type_tag=type_tag,
        type_table_pos=type_pos,
        dictionary_encoding=dictionary_encoding^,
    )


def read_schema[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> SchemaDescriptor:
    """Read a Schema table.

    Walks the [Field] vector + decodes each FieldDescriptor."""
    # Schema.fbs: `endianness: Endianness = Little`.
    var endianness = _read_table_field_u8_or(
        reader, table_pos, 0, ENDIANNESS_LITTLE
    )
    var fields_vec_pos = _read_table_field_offset(reader, table_pos, 1)
    var fields = List[FieldDescriptor]()
    if fields_vec_pos >= 0:
        var n_fields = Int(reader.read_u32_le(fields_vec_pos))
        # ASSERT=none HARDENING: validate-then-reserve. u32
        # offset elements. read_field then bounds-checks each target.
        reader._check_bounds(fields_vec_pos + 4, n_fields * 4)
        fields.reserve(n_fields)
        for i in range(n_fields):
            # Each element is a u32 offset at position
            # fields_vec_pos + 4 + i * 4. Resolve to target position.
            var elem_slot = fields_vec_pos + 4 + i * 4
            var field_pos = reader.read_offset_u32(elem_slot)
            fields.append(read_field(reader, field_pos))
    return SchemaDescriptor(endianness=endianness, fields=fields^)


# =============================================================================
# §9 — Message / RecordBatch / Footer / Dict tables
# =============================================================================
#
# Arrow IPC Message framing:
#
#   Message.fbs:
#     Message table {
#         0: version: MetadataVersion enum (i16; V5=4 for v1.0+ Arrow)
#         1: header_type: MessageHeader union discriminator (u8 tag)
#         2: header: MessageHeader union payload (offset)
#         3: bodyLength: i64 (length of the column data body, in bytes)
#         4: custom_metadata: [KeyValue] (rare; skipped)
#     }
#     MessageHeader union arms (tag values 1..5):
#         1 = Schema
#         2 = DictionaryBatch
#         3 = RecordBatch
#         4 = Tensor
#         5 = SparseTensor
#
#   RecordBatch table {
#         0: length: i64 (row count)
#         1: nodes: [FieldNode] (struct vector; one per column)
#         2: buffers: [Buffer] (struct vector; multiple per column)
#         3: compression: BodyCompression (offset; absent = uncompressed)
#         4: variadicBufferCounts: [i64] (offset; for view types)
#     }
#     FieldNode struct (inline, no vtable) { length: i64, null_count: i64 }
#     Buffer struct (inline, no vtable)   { offset: i64, length: i64 }
#
#   File.fbs:
#     Footer table {
#         0: version: MetadataVersion enum (i16)
#         1: schema: Schema (offset)
#         2: dictionaries: [Block] (struct vector)
#         3: recordBatches: [Block] (struct vector)
#         4: custom_metadata: [KeyValue] (skipped)
#     }
#     Block struct (inline) { offset: i64, metaDataLength: i32, bodyLength: i64 }
#
# Structs are fixed-size INLINE — no vtable. Written as concatenated
# bytes. In FB wire format, struct vectors are: [u32 count, struct[count]]
# with the struct bytes packed in order.
# =============================================================================


# MessageHeader union discriminator tags (Arrow Message.fbs).
comptime MESSAGE_HEADER_SCHEMA: UInt8 = 1
comptime MESSAGE_HEADER_DICTIONARY_BATCH: UInt8 = 2
comptime MESSAGE_HEADER_RECORD_BATCH: UInt8 = 3
comptime MESSAGE_HEADER_TENSOR: UInt8 = 4
comptime MESSAGE_HEADER_SPARSE_TENSOR: UInt8 = 5

# BodyCompression codec enum (Arrow Message.fbs).
comptime COMPRESSION_LZ4_FRAME: Int8 = 0
comptime COMPRESSION_ZSTD: Int8 = 1


@fieldwise_init
struct FieldNode(Copyable, Movable):
    """Arrow FieldNode struct: per-column length + null_count."""
    var length: Int64
    var null_count: Int64


@fieldwise_init
struct BufferDescriptor(Copyable, Movable):
    """Arrow Buffer struct: offset + length in body bytes."""
    var offset: Int64
    var length: Int64


@fieldwise_init
struct Block(Copyable, Movable):
    """Arrow Footer Block struct: offset + metaDataLength + bodyLength."""
    var offset: Int64
    var meta_data_length: Int32
    var body_length: Int64


@fieldwise_init
struct MessageDescriptor(Copyable, Movable):
    """Decoded Arrow Message header.

    `header_tag` identifies which MessageHeader variant follows.
    `header_table_pos` is the buffer position of the variant's table;
    callers dispatch on header_tag to call the matching reader.
    """
    var version: Int16
    var header_tag: UInt8
    var header_table_pos: Int
    var body_length: Int64


@fieldwise_init
struct RecordBatchDescriptor(Copyable, Movable):
    """Decoded RecordBatch metadata. Buffers + nodes are lifted into
    owned Lists so the caller doesn't need the original buffer
    alive past the read.

    `variadic_buffer_counts` is populated only when the RecordBatch
    contains view-type columns (Arrow v0.15+ BinaryView / Utf8View
    / ListView / LargeListView). Each entry is the number of variadic
    data buffers contributed by ONE view-type column, in column order.
    Empty (length 0) when no view-type columns are present.

    `body_compression_codec`:
    the observed `BodyCompression.codec` field id at field 3 of the
    RecordBatch flatbuf table (per Arrow Message.fbs). Defaults to
    `-1` (sentinel for "no BodyCompression flatbuf field emitted" =
    uncompressed body, per Arrow IPC `Message.fbs` spec). Values:
      -1 = Uncompressed (BodyCompression absent)
       0 = LZ4_FRAME
       1 = ZSTD
    Consumed by `ctx.read_arrow_strict[C]` for typed codec-mismatch
    diagnostics; the absence of the flatbuf field on Komira-emitted
    Uncompressed batches keeps the writer wire-conformant.
    """
    var length: Int64
    var nodes: List[FieldNode]
    var buffers: List[BufferDescriptor]
    var variadic_buffer_counts: List[Int64]
    var body_compression_codec: Int8


# --- Struct writers (fixed-size, no vtable) ---


def _write_field_node(mut writer: FlatbufWriter, node: FieldNode) raises:
    """Write a FieldNode struct inline (16 bytes: length i64 + null_count i64).

    Back-to-front means we write the LAST physical byte first; struct
    layout in OUTPUT order is [length, null_count], so we write
    null_count FIRST (it ends up at the higher physical position) and
    length SECOND.
    """
    writer.write_i64_le(node.null_count)
    writer.write_i64_le(node.length)


def _write_buffer(mut writer: FlatbufWriter, buf: BufferDescriptor) raises:
    """Write a Buffer struct inline (16 bytes: offset i64 + length i64)."""
    writer.write_i64_le(buf.length)
    writer.write_i64_le(buf.offset)


def _write_block(mut writer: FlatbufWriter, blk: Block) raises:
    """Write a Block struct inline (24 bytes per spec: offset i64 +
    metaDataLength i32 + 4 pad + bodyLength i64).

    The metaDataLength is 4 bytes but a Block is 24 bytes total — the
    4-byte pad after metaDataLength keeps bodyLength 8-byte aligned.
    """
    writer.write_i64_le(blk.body_length)
    writer.write_u32_le(UInt32(0))  # pad
    writer.write_i32_le(blk.meta_data_length)
    writer.write_i64_le(blk.offset)


# --- Struct vector writers ---


def _write_field_node_vector(
    mut writer: FlatbufWriter, nodes: List[FieldNode]
) raises -> Int:
    """Write [FieldNode] vector; return the position of the u32 length
    prefix.

    FieldNode is 16 bytes
    containing two i64 fields; each element must be 8-aligned in
    OUTPUT. Pre-align the writer so after writing `n * 16` bytes the
    cursor is 8-aligned, guaranteeing every FieldNode struct lands at
    an 8-aligned position. `prep(8, n*16 + 4)` also keeps the u32
    length prefix 4-aligned (since `n*16` is 16-aligned).
    """
    var n = len(nodes)
    writer.prep(8, n * 16 + 4)
    # Write structs back-to-front: last element first.
    for i in range(n - 1, -1, -1):
        _write_field_node(writer, nodes[i])
    writer.write_u32_le(UInt32(n))
    return writer.cursor()


def _write_buffer_vector(
    mut writer: FlatbufWriter, buffers: List[BufferDescriptor]
) raises -> Int:
    """Write [Buffer] vector; return the position of the u32 length
    prefix.

    Buffer is 16 bytes
    containing two i64 fields; pre-align to 8 so each Buffer lands
    at an 8-aligned OUTPUT position.
    """
    var n = len(buffers)
    writer.prep(8, n * 16 + 4)
    for i in range(n - 1, -1, -1):
        _write_buffer(writer, buffers[i])
    writer.write_u32_le(UInt32(n))
    return writer.cursor()


def _write_block_vector(
    mut writer: FlatbufWriter, blocks: List[Block]
) raises -> Int:
    """Write [Block] vector; return position of u32 length prefix.

    Block is 24 bytes
    (i64 offset + i32 metaDataLength + i32 pad + i64 bodyLength);
    the i64 fields must be 8-aligned. Pre-align to 8 so each Block
    lands at an 8-aligned OUTPUT position.
    """
    var n = len(blocks)
    writer.prep(8, n * 24 + 4)
    for i in range(n - 1, -1, -1):
        _write_block(writer, blocks[i])
    writer.write_u32_le(UInt32(n))
    return writer.cursor()


# --- RecordBatch + Message + Footer table writers ---


def write_record_batch(
    mut writer: FlatbufWriter,
    length: Int64,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    variadic_buffer_counts: List[Int64] = List[Int64](),
) raises -> Int:
    """Write a RecordBatch table without a BodyCompression field.

    Fields:
        0: length: i64
        1: nodes: [FieldNode] vector offset
        2: buffers: [Buffer] vector offset
        4: variadicBufferCounts: [i64] vector offset, written only when
           `variadic_buffer_counts` is non-empty (one entry per
           BinaryView / Utf8View field, in schema order, nested
           included). Absent when empty, so a batch with no view fields
           is byte-identical to the three-field table.
    """
    var nodes_pos = _write_field_node_vector(writer, nodes)
    var buffers_pos = _write_buffer_vector(writer, buffers)
    var variadic_pos = -1
    if len(variadic_buffer_counts) > 0:
        variadic_pos = _write_i64_vector(writer, variadic_buffer_counts)

    # WIRE-CANONICAL: length is i64 inline (was
    # u32-truncated in v1; pyarrow read 8 bytes there and got
    # wrong values).
    var tb = start_table()
    add_field_i64(tb, 0, length)
    add_field_offset(tb, 1, nodes_pos)
    add_field_offset(tb, 2, buffers_pos)
    if variadic_pos >= 0:
        add_field_offset(tb, 4, variadic_pos)
    return end_table(writer, tb^)


def write_body_compression(
    mut writer: FlatbufWriter,
    codec_id: Int8,
) raises -> Int:
    """Write a BodyCompression child table (Arrow IPC Message.fbs).

    Layout:
        table BodyCompression {
            0: codec: i8 (CompressionType enum; default LZ4_FRAME=0)
            1: method: i8 (BodyCompressionMethod enum; default BUFFER=0)
        }

    Only codec id 0 (LZ4_FRAME) or 1 (ZSTD) is emitted; the `method`
    field is left at its default (BUFFER per-buffer compression — the
    only mode Arrow defines).

    anchor. Caller passes the resulting `pos`
    to `write_record_batch_compressed` as field 3.
    """
    var tb = start_table()
    # codec: i8 — but FB stores enums as 1-byte u8. The Arrow Message.fbs
    # uses `byte` (= i8) for the enum but pyarrow / arrow-rs all read it
    # as 1 unsigned byte. Re-interpret via UInt8(codec_id & 0xFF).
    add_field_u8(tb, 0, UInt8(Int(codec_id) & 0xFF))
    # field 1 (method) — leave at default BUFFER=0.
    return end_table(writer, tb^)


def write_record_batch_compressed(
    mut writer: FlatbufWriter,
    length: Int64,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    body_compression_pos: Int,
    variadic_buffer_counts: List[Int64] = List[Int64](),
) raises -> Int:
    """Write a RecordBatch table WITH a BodyCompression child reference.

    Fields:
        0: length: i64
        1: nodes: [FieldNode] vector offset
        2: buffers: [Buffer] vector offset
        3: compression: BodyCompression offset
        4: variadicBufferCounts: [i64] vector offset, written only when
           `variadic_buffer_counts` is non-empty (as in
           `write_record_batch`)

    Used by the per-buffer compression encoder path. Caller
    must call `write_body_compression` BEFORE invoking this helper
    (the BodyCompression child table must be already-emitted so we
    can record the offset).

    When `C.ARROW_IPC_CODEC_ID == -1`
    (Uncompressed sentinel), the encoder MUST use `write_record_batch`
    (no BodyCompression field). Emitting BodyCompression{codec:-1} is
    NOT valid Arrow IPC; the spec's "no field" path means "uncompressed
    body".
    """
    var nodes_pos = _write_field_node_vector(writer, nodes)
    var buffers_pos = _write_buffer_vector(writer, buffers)
    var variadic_pos = -1
    if len(variadic_buffer_counts) > 0:
        variadic_pos = _write_i64_vector(writer, variadic_buffer_counts)

    var tb = start_table()
    add_field_i64(tb, 0, length)
    add_field_offset(tb, 1, nodes_pos)
    add_field_offset(tb, 2, buffers_pos)
    add_field_offset(tb, 3, body_compression_pos)
    if variadic_pos >= 0:
        add_field_offset(tb, 4, variadic_pos)
    return end_table(writer, tb^)


def write_dictionary_batch(
    mut writer: FlatbufWriter,
    dict_id: Int64,
    data_record_batch_pos: Int,
    is_delta: Bool,
) raises -> Int:
    """Write a DictionaryBatch table.

    Per Arrow IPC Message.fbs:
        table DictionaryBatch {
            0: id: long  (i64 dict_id; consumer matches against
               Schema.Field.dictionary.id)
            1: data: RecordBatch  (offset to the data RecordBatch table;
               the dict values are encoded as a RecordBatch with 1
               column matching the Field's underlying value type)
            2: isDelta: bool  (false for replace-dict, true for append-
               to-dict; v1 ships replace-only)
        }

    `data_record_batch_pos` is the position of an already-written
    RecordBatch table holding the dictionary's value column.


    """
    var tb = start_table()
    add_field_i64(tb, 0, dict_id)
    add_field_offset(tb, 1, data_record_batch_pos)
    add_field_bool(tb, 2, is_delta)
    return end_table(writer, tb^)


@fieldwise_init
struct DictionaryBatchDescriptor(Copyable, Movable):
    """Decoded DictionaryBatch metadata. `data_table_pos` is the
    position of the inner RecordBatch table; caller invokes
    `read_record_batch(reader, data_table_pos)` to walk it."""
    var id: Int64
    var data_table_pos: Int
    var is_delta: Bool


def read_dictionary_batch[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> DictionaryBatchDescriptor:
    """Read a DictionaryBatch table. Returns dict_id + position of the
    inner data RecordBatch + isDelta flag."""
    var dict_id = _read_table_field_i64(reader, table_pos, 0)
    var data_pos = _read_table_field_offset(reader, table_pos, 1)
    if data_pos < 0:
        raise Error("DictionaryBatch: data field missing")
    var is_delta = _read_table_field_bool(reader, table_pos, 2)
    return DictionaryBatchDescriptor(
        id=dict_id, data_table_pos=data_pos, is_delta=is_delta
    )


def write_message(
    mut writer: FlatbufWriter,
    version: Int16,
    header_tag: UInt8,
    header_table_pos: Int,
    body_length: Int64,
) raises -> Int:
    """Write a Message table.

    Fields:
        0: version: i16 (MetadataVersion enum)
        1: header_type: u8 union discriminator
        2: header: union payload offset
        3: bodyLength: i64

    WIRE-CANONICAL: version is 2-byte u16 (i16 in spec; same wire
    bytes); bodyLength is true 8-byte i64 inline (was u32-truncated
    in v1).
    """
    var tb = start_table()
    add_field_u16(tb, 0, UInt16(Int(version) & 0xFFFF))
    add_field_u8(tb, 1, header_tag)
    add_field_offset(tb, 2, header_table_pos)
    add_field_i64(tb, 3, body_length)
    return end_table(writer, tb^)


def write_footer(
    mut writer: FlatbufWriter,
    version: Int16,
    schema_pos: Int,
    dictionaries: List[Block],
    record_batches: List[Block],
) raises -> Int:
    """Write a Footer table.

    Fields:
        0: version: i16
        1: schema: offset
        2: dictionaries: [Block] vector offset
        3: recordBatches: [Block] vector offset
    """
    var dict_vec_pos = _write_block_vector(writer, dictionaries)
    var rb_vec_pos = _write_block_vector(writer, record_batches)

    # WIRE-CANONICAL: version is u16 (i16 in spec; same bytes).
    var tb = start_table()
    add_field_u16(tb, 0, UInt16(Int(version) & 0xFFFF))
    add_field_offset(tb, 1, schema_pos)
    add_field_offset(tb, 2, dict_vec_pos)
    add_field_offset(tb, 3, rb_vec_pos)
    return end_table(writer, tb^)


# --- Readers ---


def _read_field_node[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], pos: Int) raises -> FieldNode:
    """Read a FieldNode struct at `pos` (16 bytes: length i64 + null_count i64)."""
    var length = reader.read_i64_le(pos)
    var null_count = reader.read_i64_le(pos + 8)
    return FieldNode(length=length, null_count=null_count)


def _read_buffer[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], pos: Int) raises -> BufferDescriptor:
    """Read a Buffer struct at `pos`."""
    var offset = reader.read_i64_le(pos)
    var length = reader.read_i64_le(pos + 8)
    return BufferDescriptor(offset=offset, length=length)


def _read_block[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], pos: Int) raises -> Block:
    """Read a Block struct at `pos` (24 bytes including pad)."""
    var offset = reader.read_i64_le(pos)
    var meta_data_length = reader.read_i32_le(pos + 8)
    var body_length = reader.read_i64_le(pos + 16)
    return Block(
        offset=offset,
        meta_data_length=meta_data_length,
        body_length=body_length,
    )


def read_record_batch[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> RecordBatchDescriptor:
    """Read a RecordBatch table.

    WIRE-CANONICAL: length is i64 inline (matches pyarrow / arrow-rs
    expectations).
    """
    var length = _read_table_field_i64(reader, table_pos, 0)

    # ASSERT=none HARDENING: a FlatBuffer vector's element COUNT
    # is a u32 read straight out of untrusted bytes, and a `reserve(n)` that
    # ran BEFORE anything checked that n elements exist would, for n = 0xFFFFFFF0, ask
    # for ~68 GB from a ~20-byte hostile payload, so the 10 MiB HTTP body cap
    # does not mitigate it. The per-element `_read_field_node` bounds-check
    # would fire only AFTER the reservation. `read_string_at` has the same
    # ordering as here — `_check_bounds` before `bytes.reserve`. One check per
    # vector, at the parse boundary.
    var nodes_vec_pos = _read_table_field_offset(reader, table_pos, 1)
    var nodes = List[FieldNode]()
    if nodes_vec_pos >= 0:
        var n = Int(reader.read_u32_le(nodes_vec_pos))
        # struct elements packed at [vec_pos + 4, vec_pos + 4 + n*16).
        reader._check_bounds(nodes_vec_pos + 4, n * 16)
        nodes.reserve(n)
        for i in range(n):
            nodes.append(_read_field_node(reader, nodes_vec_pos + 4 + i * 16))

    var buffers_vec_pos = _read_table_field_offset(reader, table_pos, 2)
    var buffers = List[BufferDescriptor]()
    if buffers_vec_pos >= 0:
        var n = Int(reader.read_u32_le(buffers_vec_pos))
        reader._check_bounds(buffers_vec_pos + 4, n * 16)
        buffers.reserve(n)
        for i in range(n):
            buffers.append(_read_buffer(reader, buffers_vec_pos + 4 + i * 16))

    # variadicBufferCounts (field 4) — Arrow v0.15+ view-type metadata.
    # Vector of i64 values; one entry per view-type column counting
    # the variadic data buffers it contributes. Empty list when no
    # view-type columns present (most RecordBatches).
    var variadic_buffer_counts = List[Int64]()
    var variadic_vec_pos = _read_table_field_offset(reader, table_pos, 4)
    if variadic_vec_pos >= 0:
        var n_variadic = Int(reader.read_u32_le(variadic_vec_pos))
        # Same validate-then-reserve ordering as the two vectors above (i64
        # elements here, so 8 bytes apiece).
        reader._check_bounds(variadic_vec_pos + 4, n_variadic * 8)
        variadic_buffer_counts.reserve(n_variadic)
        for i in range(n_variadic):
            variadic_buffer_counts.append(
                reader.read_i64_le(variadic_vec_pos + 4 + i * 8)
            )

    # BodyCompression (field 3).
    # Per Arrow Message.fbs: `compression: BodyCompression` is an OFFSET
    # to a child BodyCompression table. If the offset is absent the body
    # is UNCOMPRESSED — sentinel -1 in our descriptor (matches
    # `Uncompressed.ARROW_IPC_CODEC_ID = -1`).
    # The BodyCompression table itself has field 0 = `codec` (i8 enum;
    # default LZ4_FRAME=0 per the .fbs default). Field 1 = `method` (i8;
    # default BUFFER=0; we don't surface this — Arrow only defines
    # BUFFER mode).
    var body_comp_codec: Int8 = Int8(-1)
    var body_comp_pos = _read_table_field_offset(reader, table_pos, 3)
    if body_comp_pos >= 0:
        # Read codec field (0) on the BodyCompression child table.
        # Default is LZ4_FRAME=0 if the field is omitted entirely.
        var codec_u8 = _read_table_field_u8(reader, body_comp_pos, 0)
        # u8 -> i8 reinterpret: pyarrow's enum values fit in [0, 127],
        # but the Arrow spec is i8; this preserves sign for any future
        # negative-valued additions to the enum.
        body_comp_codec = Int8(Int(codec_u8))

    return RecordBatchDescriptor(
        length=length,
        nodes=nodes^,
        buffers=buffers^,
        variadic_buffer_counts=variadic_buffer_counts^,
        body_compression_codec=body_comp_codec,
    )


def _read_version_field[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> Int16:
    """Read the i16 `version` (field 0) of a Message or Footer table; 0 when
    absent. Reads EXACTLY the field's 2 bytes through the bounds-checked
    reader: a 4-byte read masked to 16 bits reaches 2 bytes past the field,
    which is past the payload when the field ends the buffer."""
    var soffset = reader.read_i32_le(table_pos)
    var vtable_pos = table_pos - Int(soffset)
    if vtable_pos < 0:
        raise Error(
            "FlatbufReader: invalid vtable position " + String(vtable_pos)
        )
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    if vtable_size < 6:
        return Int16(0)  # field 0 beyond the declared slots → default
    var inline_offset = Int(reader.read_u16_le(vtable_pos + 4))
    if inline_offset == 0:
        return Int16(0)  # absent → default
    return reader.read_u16_le(table_pos + inline_offset).cast[DType.int16]()


def read_message[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> MessageDescriptor:
    """Read a Message table.

    WIRE-CANONICAL: version is 2-byte i16; bodyLength is 8-byte i64
    inline.
    """
    var version = _read_version_field(reader, table_pos)
    var header_tag = _read_table_field_u8(reader, table_pos, 1)
    var header_pos = _read_table_field_offset(reader, table_pos, 2)
    if header_pos < 0:
        raise Error("Message: header field missing")
    var body_length = _read_table_field_i64(reader, table_pos, 3)
    return MessageDescriptor(
        version=version,
        header_tag=header_tag,
        header_table_pos=header_pos,
        body_length=body_length,
    )


# =============================================================================
# Footer reader
# =============================================================================
#
# Symmetric to `read_record_batch` / `read_message`. Decodes the
# Footer flatbuf table emitted by `write_footer` (above), returning a
# typed `FooterDescriptor`:
#
#   Footer table {
#       0: version: MetadataVersion (i16; V5 = 4)
#       1: schema: Schema offset (re-emitted from the stream's first message)
#       2: dictionaries: [Block]   (vector of inline 24-byte Block structs)
#       3: recordBatches: [Block]  (vector of inline 24-byte Block structs)
#       4: custom_metadata: [KeyValue]  (the reader does NOT decode)
#   }
#
# Block layout (24 bytes including 4 pad after metaDataLength):
#       offset i64       @ +0
#       metaDataLength i32 @ +8
#       <pad i32>        @ +12
#       bodyLength i64   @ +16
#
# Caller decodes the Schema via `read_schema(reader, desc.schema_table_pos)`
# (the Footer carries a re-emitted Schema; in practice it's identical to
# the Schema message at the head of the file, but the spec allows them
# to differ — pyarrow + arrow-rs trust the Footer's copy on read).


@fieldwise_init
struct FooterDescriptor(Copyable, Movable):
    """Decoded Arrow File-format Footer.

    `version` is the MetadataVersion enum (i16 in spec; we widen to Int16).
    `schema_table_pos` is the buffer position of the re-emitted Schema
    table; caller invokes `read_schema(reader, footer.schema_table_pos)`
    to walk it.

    `dictionaries` is empty when the file contains no DictionaryBatch
    messages. `record_batches` is always populated for a non-empty file.
    custom_metadata is not decoded.
    """
    var version: Int16
    var schema_table_pos: Int
    var dictionaries: List[Block]
    var record_batches: List[Block]


def read_footer[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> FooterDescriptor:
    """Read a Footer flatbuf table.

    Layout:
        0: version: i16 (MetadataVersion; V5 = 4)
        1: schema: Schema offset
        2: dictionaries: [Block] vector offset
        3: recordBatches: [Block] vector offset

    Returns a `FooterDescriptor` carrying:
      - `version` (Int16 widening of the wire i16)
      - `schema_table_pos` — caller decodes via `read_schema`
      - `dictionaries` — list of Block structs (may be empty)
      - `record_batches` — list of Block structs (always populated for
        a non-empty file)

    Symmetric to `read_record_batch` / `read_message`. Each Block struct
    is 24 bytes inline (8 i64 offset + 4 i32 metaDataLength + 4 pad +
    8 i64 bodyLength) — same shape as `_read_block` reads.
    """
    var version = _read_version_field(reader, table_pos)

    var schema_pos = _read_table_field_offset(reader, table_pos, 1)
    if schema_pos < 0:
        raise Error("Footer: schema field missing")

    # dictionaries vector — vec of inline Block structs (24 bytes each).
    var dictionaries = List[Block]()
    var dict_vec_pos = _read_table_field_offset(reader, table_pos, 2)
    if dict_vec_pos >= 0:
        var n_dict = Int(reader.read_u32_le(dict_vec_pos))
        # ASSERT=none HARDENING: validate-then-reserve. The Arrow
        # FILE footer is as attacker-supplied as the stream; 24-byte Blocks.
        reader._check_bounds(dict_vec_pos + 4, n_dict * 24)
        dictionaries.reserve(n_dict)
        for i in range(n_dict):
            dictionaries.append(
                _read_block(reader, dict_vec_pos + 4 + i * 24)
            )

    # recordBatches vector — vec of inline Block structs (24 bytes each).
    var record_batches = List[Block]()
    var rb_vec_pos = _read_table_field_offset(reader, table_pos, 3)
    if rb_vec_pos >= 0:
        var n_rb = Int(reader.read_u32_le(rb_vec_pos))
        # ASSERT=none HARDENING: validate-then-reserve.
        reader._check_bounds(rb_vec_pos + 4, n_rb * 24)
        record_batches.reserve(n_rb)
        for i in range(n_rb):
            record_batches.append(
                _read_block(reader, rb_vec_pos + 4 + i * 24)
            )

    return FooterDescriptor(
        version=version,
        schema_table_pos=schema_pos,
        dictionaries=dictionaries^,
        record_batches=record_batches^,
    )


# =============================================================================
# §10 — Tensor + SparseTensor + SparseTensorIndex
# =============================================================================
#
# Apache Arrow Tensor.fbs + SparseTensor.fbs subset:
#
#   table TensorDim {
#       0: size: i64
#       1: name: string (optional dim label)
#   }
#
#   table Tensor {
#       0: type: Type union (2 slots: type_tag at field 0, type_offset at field 1)
#       2: shape: [TensorDim] (vector of TensorDim offsets)
#       3: strides: [i64] (optional; default contiguous)
#       4: data: Buffer
#   }
#
#   table SparseTensorIndexCOO {
#       0: indicesType: Int (offset to Int Type table)
#       1: indicesStrides: [i64]
#       2: indicesBuffer: Buffer
#       3: isCanonical: bool
#   }
#
#   table SparseMatrixIndexCSX {
#       0: compressedAxis: SparseMatrixCompressedAxis (Row=0, Column=1)
#       1: indptrType: Int (offset)
#       2: indptrBuffer: Buffer
#       3: indicesType: Int (offset)
#       4: indicesBuffer: Buffer
#   }
#
#   table SparseTensor {
#       0: type: Type union (2 slots)
#       2: shape: [TensorDim]
#       3: non_zero_length: i64
#       4: sparseIndex_type: u8 union discriminator (1=COO, 2=CSX, 3=CSF)
#       5: sparseIndex: union payload offset
#       6: data: Buffer
#   }
#
# The Buffer struct fields in Tensor/SparseTensorIndex* are written
# INLINE (16 bytes embedded in the parent table's inline_data), the
# canonical Flatbuffers layout for Tensor.fbs that pyarrow/arrow-rs
# expect (see `add_field_buffer_inline` / `_read_table_field_buffer_inline`
# below).
# =============================================================================


# SparseTensorIndex union discriminator tags.
comptime SPARSE_TENSOR_INDEX_COO: UInt8 = 1
comptime SPARSE_TENSOR_INDEX_CSX: UInt8 = 2
comptime SPARSE_TENSOR_INDEX_CSF: UInt8 = 3

# SparseMatrixCompressedAxis enum (CSR vs CSC).
comptime SPARSE_AXIS_ROW: UInt8 = 0
comptime SPARSE_AXIS_COLUMN: UInt8 = 1


# --- TensorDim ---


@fieldwise_init
struct TensorDimDescriptor(Copyable, Movable):
    """Decoded TensorDim: size + optional name."""
    var size: Int64
    var name: String


def write_tensor_dim(
    mut writer: FlatbufWriter, size: Int64, name: StringSlice
) raises -> Int:
    """Write a TensorDim table.

    Fields:
        0: size: i64 (canonical 8-byte inline)
        1: name: string (offset; absent if empty)
    """
    var name_pos = -1
    if name.byte_length() > 0:
        name_pos = writer.write_string(name)
    var tb = start_table()
    add_field_i64(tb, 0, size)
    if name_pos >= 0:
        add_field_offset(tb, 1, name_pos)
    return end_table(writer, tb^)


def read_tensor_dim[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> TensorDimDescriptor:
    """Read a TensorDim table."""
    var size = _read_table_field_i64(reader, table_pos, 0)
    var name_pos = _read_table_field_offset(reader, table_pos, 1)
    var name = String("")
    if name_pos >= 0:
        name = reader.read_string_at(name_pos)
    return TensorDimDescriptor(size=size, name=name^)


def _write_tensor_dim_vector(
    mut writer: FlatbufWriter, dims: List[TensorDimDescriptor]
) raises -> Int:
    """Write a [TensorDim] vector (offsets to TensorDim tables)."""
    # Write each TensorDim table first; collect their positions.
    var dim_positions = List[Int]()
    dim_positions.reserve(len(dims))
    for i in range(len(dims)):
        # SAFETY: TensorDimDescriptor is Copyable+Movable but not
        # ImplicitlyCopyable in Mojo 1.0.0b1; access fields directly
        # rather than copy the dim by value.
        var pos = write_tensor_dim(writer, dims[i].size, dims[i].name)
        dim_positions.append(pos)
    # Now write the vector: u32 count + element offsets (back-to-front).
    # U32 offset elements + u32 length, 4-aligned.
    var n = len(dim_positions)
    writer.prep(4, n * 4 + 4)
    for i in range(n - 1, -1, -1):
        writer.write_offset_u32(dim_positions[i])
    writer.write_u32_le(UInt32(n))
    return writer.cursor()


def _write_i64_vector(
    mut writer: FlatbufWriter, values: List[Int64]
) raises -> Int:
    """Write a [long] vector (i64 elements).

    i64 elements MUST be
    8-aligned in OUTPUT. Pre-align so each element lands at an 8-
    aligned position.
    """
    var n = len(values)
    writer.prep(8, n * 8 + 4)
    for i in range(n - 1, -1, -1):
        writer.write_i64_le(values[i])
    writer.write_u32_le(UInt32(n))
    return writer.cursor()


# --- Tensor ---
# Tensor.data + SparseTensor*.{indicesBuffer, indptrBuffer} use
# canonical INLINE 16-byte Buffer struct via add_field_buffer_inline /
# _read_table_field_buffer_inline.


@fieldwise_init
struct TensorDescriptor(Copyable, Movable):
    """Decoded Tensor: type_tag + type_table_pos + shape + strides + data.

    `type_table_pos` is the buffer position of the Type variant; caller
    dispatches on type_tag to read the matching Type descriptor.
    """
    var type_tag: UInt8
    var type_table_pos: Int
    var shape: List[TensorDimDescriptor]
    var strides: List[Int64]
    var data: BufferDescriptor


def write_tensor(
    mut writer: FlatbufWriter,
    type_tag: UInt8,
    type_table_pos: Int,
    shape: List[TensorDimDescriptor],
    strides: List[Int64],
    data: BufferDescriptor,
) raises -> Int:
    """Write a Tensor table.

    Fields (WIRE-CANONICAL per Apache Arrow Tensor.fbs):
        0: type_type: u8 union discriminator
        1: type: Type variant offset (u32)
        2: shape: [TensorDim] vector offset (u32)
        3: strides: [i64] vector offset (u32; absent if empty)
        4: data: Buffer INLINE struct (16 bytes; offset + length i64s)

    Wire-canonical post-Data is now INLINE 16-byte
    Buffer struct in the parent table's inline_data, matching pyarrow /
    arrow-rs Tensor reader expectations.
    """
    var shape_vec_pos = _write_tensor_dim_vector(writer, shape)
    var strides_pos = -1
    if len(strides) > 0:
        strides_pos = _write_i64_vector(writer, strides)

    var tb = start_table()
    add_field_u8(tb, 0, type_tag)
    add_field_offset(tb, 1, type_table_pos)
    add_field_offset(tb, 2, shape_vec_pos)
    if strides_pos >= 0:
        add_field_offset(tb, 3, strides_pos)
    add_field_buffer_inline(tb, 4, data)
    return end_table(writer, tb^)


def read_tensor[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> TensorDescriptor:
    """Read a Tensor table.

    WIRE-CANONICAL: data is INLINE Buffer struct (vs the v1 offset-to-
    Buffer-table workaround). Reader uses _read_table_field_buffer_inline
    to fetch 16 bytes at the field's inline offset and parse as
    BufferDescriptor.
    """
    var type_tag = _read_table_field_u8(reader, table_pos, 0)
    var type_pos = _read_table_field_offset(reader, table_pos, 1)
    if type_pos < 0:
        raise Error("Tensor: type field missing")

    var shape = List[TensorDimDescriptor]()
    var shape_vec_pos = _read_table_field_offset(reader, table_pos, 2)
    if shape_vec_pos >= 0:
        var n = Int(reader.read_u32_le(shape_vec_pos))
        # ASSERT=none HARDENING: validate-then-reserve (u32
        # offset elements). See read_record_batch for the rationale.
        reader._check_bounds(shape_vec_pos + 4, n * 4)
        shape.reserve(n)
        for i in range(n):
            var elem_slot = shape_vec_pos + 4 + i * 4
            var dim_pos = reader.read_offset_u32(elem_slot)
            shape.append(read_tensor_dim(reader, dim_pos))

    var strides = List[Int64]()
    var strides_pos = _read_table_field_offset(reader, table_pos, 3)
    if strides_pos >= 0:
        var n = Int(reader.read_u32_le(strides_pos))
        # ASSERT=none HARDENING: validate-then-reserve (i64
        # elements). See read_record_batch for the rationale.
        reader._check_bounds(strides_pos + 4, n * 8)
        strides.reserve(n)
        for i in range(n):
            strides.append(reader.read_i64_le(strides_pos + 4 + i * 8))

    var data = _read_table_field_buffer_inline(reader, table_pos, 4)

    return TensorDescriptor(
        type_tag=type_tag,
        type_table_pos=type_pos,
        shape=shape^,
        strides=strides^,
        data=data^,
    )


# --- SparseTensorIndexCOO ---


@fieldwise_init
struct SparseTensorIndexCOODescriptor(Copyable, Movable):
    """Decoded SparseTensorIndexCOO: indicesType_pos + indicesStrides
    + indicesBuffer + isCanonical."""
    var indices_type_table_pos: Int
    var indices_strides: List[Int64]
    var indices_buffer: BufferDescriptor
    var is_canonical: Bool


def write_sparse_tensor_index_coo(
    mut writer: FlatbufWriter,
    indices_type_pos: Int,
    indices_strides: List[Int64],
    indices_buffer: BufferDescriptor,
    is_canonical: Bool,
) raises -> Int:
    """Write a SparseTensorIndexCOO table.

    WIRE-CANONICAL: indicesBuffer is INLINE 16-byte Buffer struct
    (vs the v1 offset-to-Buffer-table workaround).
    """
    var strides_pos = -1
    if len(indices_strides) > 0:
        strides_pos = _write_i64_vector(writer, indices_strides)

    var tb = start_table()
    add_field_offset(tb, 0, indices_type_pos)
    if strides_pos >= 0:
        add_field_offset(tb, 1, strides_pos)
    add_field_buffer_inline(tb, 2, indices_buffer)
    add_field_bool(tb, 3, is_canonical)
    return end_table(writer, tb^)


def read_sparse_tensor_index_coo[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo], table_pos: Int
) raises -> SparseTensorIndexCOODescriptor:
    """Read a SparseTensorIndexCOO table.

    WIRE-CANONICAL: indicesBuffer is INLINE 16-byte Buffer struct.
    """
    var type_pos = _read_table_field_offset(reader, table_pos, 0)
    if type_pos < 0:
        raise Error("SparseTensorIndexCOO: indicesType field missing")

    var strides = List[Int64]()
    var strides_pos = _read_table_field_offset(reader, table_pos, 1)
    if strides_pos >= 0:
        var n = Int(reader.read_u32_le(strides_pos))
        # ASSERT=none HARDENING: validate-then-reserve (i64
        # elements). See read_record_batch for the rationale.
        reader._check_bounds(strides_pos + 4, n * 8)
        strides.reserve(n)
        for i in range(n):
            strides.append(reader.read_i64_le(strides_pos + 4 + i * 8))

    var indices_buffer = _read_table_field_buffer_inline(reader, table_pos, 2)
    var is_canonical = _read_table_field_bool(reader, table_pos, 3)

    return SparseTensorIndexCOODescriptor(
        indices_type_table_pos=type_pos,
        indices_strides=strides^,
        indices_buffer=indices_buffer^,
        is_canonical=is_canonical,
    )


# --- SparseMatrixIndexCSX (CSR / CSC) ---


@fieldwise_init
struct SparseMatrixIndexCSXDescriptor(Copyable, Movable):
    """Decoded SparseMatrixIndexCSX: compressed_axis + indptr/indices types + buffers."""
    var compressed_axis: UInt8
    var indptr_type_table_pos: Int
    var indptr_buffer: BufferDescriptor
    var indices_type_table_pos: Int
    var indices_buffer: BufferDescriptor


def write_sparse_matrix_index_csx(
    mut writer: FlatbufWriter,
    compressed_axis: UInt8,
    indptr_type_pos: Int,
    indptr_buffer: BufferDescriptor,
    indices_type_pos: Int,
    indices_buffer: BufferDescriptor,
) raises -> Int:
    """Write a SparseMatrixIndexCSX table (CSR / CSC matrix index).

    WIRE-CANONICAL: indptrBuffer + indicesBuffer are INLINE 16-byte
    Buffer structs.
    """
    var tb = start_table()
    add_field_u8(tb, 0, compressed_axis)
    add_field_offset(tb, 1, indptr_type_pos)
    add_field_buffer_inline(tb, 2, indptr_buffer)
    add_field_offset(tb, 3, indices_type_pos)
    add_field_buffer_inline(tb, 4, indices_buffer)
    return end_table(writer, tb^)


def read_sparse_matrix_index_csx[
    bo: Origin[mut=False]
](
    reader: FlatbufReader[bo], table_pos: Int
) raises -> SparseMatrixIndexCSXDescriptor:
    """Read a SparseMatrixIndexCSX table.

    WIRE-CANONICAL: indptrBuffer + indicesBuffer are INLINE.
    """
    var compressed_axis = _read_table_field_u8(reader, table_pos, 0)
    var indptr_type_pos = _read_table_field_offset(reader, table_pos, 1)
    var indices_type_pos = _read_table_field_offset(reader, table_pos, 3)

    if indptr_type_pos < 0 or indices_type_pos < 0:
        raise Error("SparseMatrixIndexCSX: required type field missing")

    var indptr_buf = _read_table_field_buffer_inline(reader, table_pos, 2)
    var indices_buf = _read_table_field_buffer_inline(reader, table_pos, 4)

    return SparseMatrixIndexCSXDescriptor(
        compressed_axis=compressed_axis,
        indptr_type_table_pos=indptr_type_pos,
        indptr_buffer=indptr_buf^,
        indices_type_table_pos=indices_type_pos,
        indices_buffer=indices_buf^,
    )


# --- SparseTensor (with COO index) ---


@fieldwise_init
struct SparseTensorDescriptor(Copyable, Movable):
    """Decoded SparseTensor with one of three SparseTensorIndex variants.

    sparse_index_tag identifies which SparseTensorIndex variant follows:
        SPARSE_TENSOR_INDEX_COO / _CSX / _CSF.
    sparse_index_table_pos is the position of the variant table; caller
    dispatches via the corresponding read fn.
    """
    var type_tag: UInt8
    var type_table_pos: Int
    var shape: List[TensorDimDescriptor]
    var non_zero_length: Int64
    var sparse_index_tag: UInt8
    var sparse_index_table_pos: Int
    var data: BufferDescriptor


def write_sparse_tensor(
    mut writer: FlatbufWriter,
    type_tag: UInt8,
    type_table_pos: Int,
    shape: List[TensorDimDescriptor],
    non_zero_length: Int64,
    sparse_index_tag: UInt8,
    sparse_index_table_pos: Int,
    data: BufferDescriptor,
) raises -> Int:
    """Write a SparseTensor table.

    Fields (WIRE-CANONICAL):
        0: type_type: u8 union discriminator
        1: type: Type variant offset
        2: shape: [TensorDim] vector offset
        3: non_zero_length: i64 inline
        4: sparseIndex_type: u8 union discriminator
        5: sparseIndex: union payload offset
        6: data: Buffer INLINE struct (16 bytes)
    """
    var shape_vec_pos = _write_tensor_dim_vector(writer, shape)

    var tb = start_table()
    add_field_u8(tb, 0, type_tag)
    add_field_offset(tb, 1, type_table_pos)
    add_field_offset(tb, 2, shape_vec_pos)
    add_field_i64(tb, 3, non_zero_length)
    add_field_u8(tb, 4, sparse_index_tag)
    add_field_offset(tb, 5, sparse_index_table_pos)
    add_field_buffer_inline(tb, 6, data)
    return end_table(writer, tb^)


def read_sparse_tensor[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int) raises -> SparseTensorDescriptor:
    """Read a SparseTensor table.

    WIRE-CANONICAL: non_zero_length is i64 inline; data is INLINE
    16-byte Buffer struct.
    """
    var type_tag = _read_table_field_u8(reader, table_pos, 0)
    var type_pos = _read_table_field_offset(reader, table_pos, 1)
    if type_pos < 0:
        raise Error("SparseTensor: type field missing")

    var shape = List[TensorDimDescriptor]()
    var shape_vec_pos = _read_table_field_offset(reader, table_pos, 2)
    if shape_vec_pos >= 0:
        var n = Int(reader.read_u32_le(shape_vec_pos))
        # ASSERT=none HARDENING: validate-then-reserve (u32
        # offset elements). See read_record_batch for the rationale.
        reader._check_bounds(shape_vec_pos + 4, n * 4)
        shape.reserve(n)
        for i in range(n):
            var elem_slot = shape_vec_pos + 4 + i * 4
            var dim_pos = reader.read_offset_u32(elem_slot)
            shape.append(read_tensor_dim(reader, dim_pos))

    var nnz = _read_table_field_i64(reader, table_pos, 3)
    var sparse_idx_tag = _read_table_field_u8(reader, table_pos, 4)
    var sparse_idx_pos = _read_table_field_offset(reader, table_pos, 5)
    if sparse_idx_pos < 0:
        raise Error("SparseTensor: sparseIndex field missing")

    var data = _read_table_field_buffer_inline(reader, table_pos, 6)

    return SparseTensorDescriptor(
        type_tag=type_tag,
        type_table_pos=type_pos,
        shape=shape^,
        non_zero_length=nnz,
        sparse_index_tag=sparse_idx_tag,
        sparse_index_table_pos=sparse_idx_pos,
        data=data^,
    )


# =============================================================================
# §11 — IPC outer message framing
# =============================================================================
#
# Apache Arrow IPC v0.15+ frames every message with a continuation
# marker. The on-wire format for a single message is:
#
#   [u32 0xFFFFFFFF]            # IPC_CONTINUATION_MARKER
#   [u32 metadata_size]         # length of the FB payload (4-byte aligned)
#   [FB_payload]                # the FlatBuffer-encoded Schema / Message /
#                               # RecordBatch / Tensor / SparseTensor /
#                               # Footer
#   [body_bytes]                # the raw column data (RecordBatch only;
#                               # Schema / Footer messages have body_length=0)
#
# v0.15 legacy mode (`write_legacy_ipc_format=True`) omits the
# continuation marker — emits `[u32 metadata_size, FB_payload, body]`
# only. This writer emits canonical (with continuation marker) by default.
#
# File format (per File.fbs) adds: ARROW1\0\0 magic prefix + suffix +
# u32 footer_size before the trailing magic. Footer is itself a FB
# message that points at the stream of RecordBatch messages embedded
# in the file. This section provides the message-framing primitives;
# the file-level wrapping happens in the FileSink integration.
# =============================================================================


@fieldwise_init
struct IpcMessageFrame(Copyable, Movable):
    """Decoded IPC message frame: metadata span position + body span position.

    `metadata_pos` + `metadata_size` describe the FlatBuffer payload
    position within the source bytes; `body_pos` + `body_size` describe
    the raw column data following the FB payload.
    """
    var metadata_pos: Int
    var metadata_size: Int
    var body_pos: Int
    var body_size: Int


def write_ipc_message(
    mut writer: FlatbufWriter,
    fb_payload: SharedAlignedBuffer[HeapRegion],
    body_bytes: Span[UInt8, _],
    use_continuation_marker: Bool,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Write a complete IPC message frame.

    Layout (with continuation marker, default v0.15+):
        [u32 0xFFFFFFFF, u32 metadata_size, FB_payload, body]
    Layout (legacy, pre-v0.15):
        [u32 metadata_size, FB_payload, body]

    The FB_payload is the output of a separate FlatbufWriter.finalize()
    call (Schema / Message / RecordBatch / Tensor / SparseTensor /
    Footer payload). `body_bytes` is the raw column data following
    a RecordBatch metadata message (empty for Schema / Footer).

    This function MUTATES `writer` for forward-byte output (NOT
    back-to-front) — the IPC frame is naturally forward-ordered.
    Caller passes a fresh FlatbufWriter (the finalize at the end
    yields the output buffer).

    Body bytes are written as a Span<UInt8> with read-only access;
    no UnsafePointer leak.
    """
    # NOTE: this writer goes FORWARD (unlike FlatbufWriter's back-to-front
    # core discipline). We use MmapAlignedBuffer.write_u8_at at increasing
    # positions, then construct the output via length cap.
    var fb_size = fb_payload.len()
    var body_size = body_bytes.__len__()
    # FB payload size must be 8-byte aligned per spec (post-v0.15);
    # pad with zero bytes after the payload if needed.
    var fb_aligned = ((fb_size + 7) // 8) * 8
    var pad_after_fb = fb_aligned - fb_size
    # Outer frame: optional continuation marker (4 bytes) + metadata_size
    # (4 bytes) + FB_payload (fb_aligned bytes) + body.
    var continuation_size = 4 if use_continuation_marker else 0
    var total_size = (
        continuation_size + 4 + fb_aligned + body_size
    )

    # Three
    # choices keep this fast. (1) No blanket `out.zero()`
    # — every byte in [0, total_size) is covered below by an explicit
    # write or memcpy, except the (0-7 byte) `pad_after_fb` gap. (2)
    # The fb_payload copy uses libc memcpy via
    # `copy_from_aligned_buffer_at`. (3) The body_bytes copy uses libc
    # memcpy via `copy_from_span_at`. A blanket zero and scalar byte loops
    # would each be a sizeable share of `encode_record_batch_message`.
    # The bytes are exactly those a zeroed buffer plus byte copies would
    # produce (the explicit pad zero-write below covers the gap).
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(total_size, 1))
    var pos = 0
    # Continuation marker.
    if use_continuation_marker:
        out.write_u32_le_at(pos, IPC_CONTINUATION_MARKER)
        pos += 4
    # Metadata size — the size of the FB_payload INCLUDING any padding
    # (8-byte aligned).
    out.write_u32_le_at(pos, UInt32(fb_aligned))
    pos += 4
    # FB payload bytes — libc memcpy.
    out.copy_from_aligned_buffer_at(pos, fb_payload, 0, fb_size)
    pos += fb_size
    # Explicit zero the 0-7 byte FB-to-body alignment gap (was implicitly
    # zero via the dropped `out.zero()`).
    if pad_after_fb > 0:
        for i in range(pad_after_fb):
            out.write_u8_at(pos + i, UInt8(0))
        pos += pad_after_fb
    # Body bytes — libc memcpy via Span.
    out.copy_from_span_at(pos, body_bytes)
    pos += body_size

    out.set_length(total_size)

    return out^


def parse_ipc_message[
    bo: Origin[mut=False]
](ref [bo] frame: SharedAlignedBuffer[HeapRegion]) raises -> IpcMessageFrame:
    """Parse an IPC message frame.

    Detects + skips the continuation marker if present (v0.15+).
    Returns positions/sizes for the FB metadata + body. Caller
    constructs FlatbufReader over the metadata slice for further
    decoding.

    Raises on:
        - Frame too short for header.
        - Metadata size exceeds frame.
    """
    var total = frame.len()
    if total < 8:
        raise Error("IPC frame: too short (< 8 bytes)")

    var pos = 0
    var first_u32 = frame.read_u32_le_at(0)
    if first_u32 == IPC_CONTINUATION_MARKER:
        # v0.15+ canonical framing.
        pos = 4
    # Otherwise legacy: the first u32 IS the metadata_size.

    if total < pos + 4:
        raise Error("IPC frame: too short for metadata_size header")  # cov: unreachable total >= 8 and pos <= 4 here

    var metadata_size = Int(frame.read_u32_le_at(pos))
    pos += 4

    if metadata_size < 0 or pos + metadata_size > total:
        raise Error(
            "IPC frame: invalid metadata_size "
            + String(metadata_size)
            + " (frame size " + String(total) + ", offset " + String(pos) + ")"
        )

    var metadata_pos = pos
    var body_pos = pos + metadata_size
    var body_size = total - body_pos

    return IpcMessageFrame(
        metadata_pos=metadata_pos,
        metadata_size=metadata_size,
        body_pos=body_pos,
        body_size=body_size,
    )
