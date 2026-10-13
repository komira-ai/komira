# =============================================================================
# ipc_dict_cache.mojo — Per-EngineContext Arrow IPC dictionary cache
# ARROW-IPC-PHASE-4 step 3.
# =============================================================================
#
# Backing store for the read-side DictionaryBatch handling specified in
# RFC v0.3.2 §3.4. An Arrow IPC byte sequence (Stream or File mode) can
# carry zero or more DictionaryBatch messages, each of which is a triple
#
#     (dict_id: Int64, dict_values: RecordBatch, isDelta: Bool)
#
# Per Arrow spec:
#   - isDelta == False → REPLACE the cumulative dictionary at `dict_id`
#     with these values.  (First DictionaryBatch for a given dict_id is
#     always isDelta=False per spec; subsequent isDelta=False messages
#     reset the cumulative state.)
#   - isDelta == True  → APPEND these values to the existing cumulative
#     dictionary at `dict_id`.  A subsequent RecordBatch dict-encoded
#     column at `dict_id` reads cumulative dictionary state assembled
#     from the chain of (initial isDelta=False) + (zero or more
#     isDelta=True) messages seen so far in the stream.
#
# This cache is the canonical bookkeeping surface for that accumulated
# state, scoped to a single `ctx.read_arrow*` call.  The
# `EngineContext._ipc_dict_cache` field is the live instance; the
# `read_arrow*` SDK methods MUST call `self._ipc_dict_cache.clear()` at
# entry so each top-level read starts from a clean slate.  After the
# call returns, the decoded Columns carry their dictionary values inline
# (`_dict_data`, `_offsets`, `_dict_size`) — the cache itself is
# transient bookkeeping.
#
# === Storage layout ===
#
# `Slab[_DictEntry]` with linear scan keyed on `entry.id`.  Mirrors the
# `ParquetNumRowsCache._entries: Slab[_NumRowsEntry]` precedent at
# `komira_parquet/num_rows_cache.mojo:117`.  Linear scan is sub-L1:
# typical Arrow files carry < 10 distinct dict_ids; pyarrow + arrow-rs
# both use small-vector linear scans (parquet-cpp + arrow-cpp's
# `DictionaryFieldMapper`).
#
# `Dict[Int64, Column]` would be a more idiomatic key-value shape but
# is rejected on two grounds:
#   1. Column is Movable-not-Copyable on Mojo; Dict's `get(K)
#      -> V` API requires V: ImplicitlyCopyable.
#   2. The cache's by-construction small-N regime (typically 1-3, never
#      > ~10) makes the Dict's O(1) lookup not load-bearing.  Linear
#      scan over a ~10-element Slab is faster than the hash compute +
#      bucket walk a Dict would pay.
#
# === Append semantics (isDelta=True) ===
#
# PHASE-4 step 3 v1 covers STRING + BINARY + LARGE_STRING + LARGE_BINARY
# dict-value arrow_types.  These are the only arrow_types the v0.4
# DictionaryArray / Column.from_dictionary factory emits today, and they
# match Arrow spec's most common dictionary shape (pyarrow's
# `pa.dictionary(<index>, pa.string())`).  Fixed-width dict values
# (Int32 / Float64 / etc.) raise a clear "PHASE-4-FOLLOWUP-DICT-FIXED-
# WIDTH-APPEND" message; no production caller emits them today.
#
# Append is a buffer-concat operation:
#   - Concat `_data` byte buffers (raw value bytes).
#   - Shift offsets in the incoming column by `len(existing._data)`
#     and append after dropping the leading 0 (the new chain starts at
#     the existing tail).
#   - Concat validity bitmaps (rare for dictionary values; typically
#     all-non-null).
#
# `Column.concat` does not exist in the v0.4 Column surface; this
# module hosts a private `_concat_var_len_string_binary` helper that
# inlines the concat for the four supported var-len arrow_types.
# Filed as PHASE-4-FOLLOWUP-COLUMN-CONCAT-PUBLIC when a public
# `Column.concat` is wanted for downstream callers.
#
# === SAFETY contract ===
#
# - No `UnsafePointer` in any public signature.
# - `Slab[_DictEntry]` + Column own all buffers.  Cache is a value-typed
#   struct (Movable + Deinitable) with no FFI-POD slots and
#   no wildcard origins — Column is gap6-safe by construction
#   (decimal_p/decimal_s are Int, field_names is List[String], etc.).
# - `get()` returns `ref [self._entries] Column` — the borrow is bounded
#   by the cache's lifetime; caller MUST not retain the ref past a
#   subsequent `replace` / `append_to` / `clear` (any of those may
#   invalidate the slab's internal layout).
# - `clear()` is a Slab drop-in-place: every Column drops, every
#   buffer drops, the slab is reset to empty.
# =============================================================================

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.offset_overflow import check_int32_offsets
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_collections.slab import Slab


# =============================================================================
# _DictEntry — internal slab element
# =============================================================================
#
# `(id, col)` pair holding the cumulative dictionary values for one
# dict_id.  Movable-only; Column is non-Copyable so the surrounding
# Slab uses `take_slot_unchecked` / `set_len_unchecked` on remove.


struct _DictEntry(Movable, Deinitable):
    """One cumulative-dictionary entry in the cache."""
    var id: Int64
    var col: Column[HeapRegion]

    def __init__(out self, id: Int64, var col: Column[HeapRegion]):
        self.id = id
        self.col = col^


# =============================================================================
# IpcDictCache — public surface
# =============================================================================


struct IpcDictCache(Movable, Deinitable):
    """Per-EngineContext cache of Arrow IPC dictionaries.

    Keyed by `Int64 dict_id` (from `DictionaryBatch.id`).  Each entry
    holds the CUMULATIVE dictionary values column accumulated across
    all DictionaryBatch messages seen so far in the current
    `ctx.read_arrow*` call (initial isDelta=False replace + zero or
    more isDelta=True appends).

    Lifecycle:
      - Constructed empty alongside `EngineContext.__init__`.
      - `clear()` called at entry of every `ctx.read_arrow*` /
        `ctx.read_arrow_stream*` method so each top-level read starts
        from a clean slate.  Per-call isolation prevents stale dict
        bleed-through (cache entries from a prior read of file A
        leaking into the decode of file B).
      - The cache is transient bookkeeping; after a top-level
        read returns, the decoded Columns OWN their dict values
        inline (via `_dict_data`, `_offsets`, `_dict_size`).  The
        cache contents are no longer load-bearing.

    Storage: `Slab[_DictEntry]` with linear scan on `id`.  Per the
    module header, this matches the small-N regime (typical Arrow
    files carry < 10 distinct dict_ids) and avoids the Dict trait
    bound (Column is non-Copyable in Mojo).
    """

    var _entries: Slab[_DictEntry]

    def __init__(out self):
        """Construct an empty cache."""
        self._entries = Slab[_DictEntry]()

    def _find(self, dict_id: Int64) -> Int:
        """Linear-scan lookup.  Returns -1 on miss, else the slab index."""
        var n = len(self._entries)
        for i in range(n):
            if self._entries[i].id == dict_id:
                return i
        return -1

    def contains(self, dict_id: Int64) -> Bool:
        """Return True if `dict_id` has at least one DictionaryBatch
        accumulated in the cache."""
        return self._find(dict_id) >= 0

    def size(self) -> Int:
        """Number of cached dict_ids.  Test hook."""
        return len(self._entries)

    def clear(mut self):
        """Drop every cached entry.  Called at the entry of each
        `ctx.read_arrow*` method to ensure per-call isolation.

        Implementation: replace the slab with a fresh empty Slab.
        The old slab's destructor walks every `_DictEntry`, drops the
        Column (which drops its buffers), and returns the underlying
        allocator memory.
        """
        self._entries = Slab[_DictEntry]()

    def replace(mut self, dict_id: Int64, var values: Column[HeapRegion]) raises:
        """Replace the cumulative dictionary at `dict_id` with `values`
        (isDelta=False semantics).

        If `dict_id` is already present, the existing entry's Column is
        dropped and `values` takes its place.  If `dict_id` is new, a
        fresh entry is appended.
        """
        var idx = self._find(dict_id)
        if idx >= 0:
            # Existing entry: swap the new column in, leaving the old
            # column to drop when the local `old` goes out of scope.
            var old = Column[HeapRegion]()
            swap(self._entries[idx].col, old)
            var new_col = values^
            swap(self._entries[idx].col, new_col)
            _ = old^
            _ = new_col^
            return
        # New entry.
        self._entries.append(_DictEntry(id=dict_id, col=values^))

    def append_to(mut self, dict_id: Int64, var delta: Column[HeapRegion]) raises:
        """Append `delta`'s values to the cumulative dictionary at
        `dict_id` (isDelta=True semantics).

        Per Arrow spec, the first DictionaryBatch for any dict_id is
        always isDelta=False; this method raises if `dict_id` is not
        already present in the cache.  PHASE-4 step 3 v1 supports
        STRING / BINARY / LARGE_STRING / LARGE_BINARY dict-value
        arrow_types (the four var-len Arrow types currently emitted by
        Column.from_dictionary).  Fixed-width dict values are filed as
        PHASE-4-FOLLOWUP-DICT-FIXED-WIDTH-APPEND.
        """
        var idx = self._find(dict_id)
        if idx < 0:
            raise Error(
                "IpcDictCache.append_to: dict_id "
                + String(Int(dict_id))
                + " has no existing entry (Arrow spec requires the FIRST "
                + "DictionaryBatch for a given dict_id to be isDelta=False; "
                + "received isDelta=True with no prior replace)"
            )
        ref existing = self._entries[idx].col
        if existing.arrow_type != delta.arrow_type:
            raise Error(
                "IpcDictCache.append_to: dict_id "
                + String(Int(dict_id))
                + " arrow_type mismatch (existing "
                + String(Int(existing.arrow_type.type_id))
                + ", delta "
                + String(Int(delta.arrow_type.type_id))
                + ") — isDelta=True must carry the same value type"
            )
        var t = existing.arrow_type
        if (
            t == ArrowType.STRING
            or t == ArrowType.BINARY
            or t == ArrowType.LARGE_STRING
            or t == ArrowType.LARGE_BINARY
        ):
            var merged = _concat_var_len_string_binary(
                existing, delta
            )
            # Swap merged into the cache; drop the prior existing column.
            var old = Column[HeapRegion]()
            swap(self._entries[idx].col, old)
            var merged_local = merged^
            swap(self._entries[idx].col, merged_local)
            _ = old^
            _ = merged_local^
            _ = delta^
            return
        raise Error(
            "IpcDictCache.append_to: PHASE-4 step 3 v1 supports STRING / "
            "BINARY / LARGE_STRING / LARGE_BINARY dict-value arrow_types "
            "only (got type_id "
            + String(Int(t.type_id))
            + ").  Filed as PHASE-4-FOLLOWUP-DICT-FIXED-WIDTH-APPEND for "
            "wider fixed-width and nested dict-value types."
        )

    def get(self, dict_id: Int64) raises -> Column[HeapRegion]:
        """Look up the cumulative dictionary values column for `dict_id`
        and return a `deep_copy()` of it.

        Returns a freshly-allocated Column owning its own buffers; the
        cache retains its own copy.  Returning by value (rather than a
        ref) avoids the Mojo ref-origin narrowing issue with
        Slab-indexed field access (`ref [self._entries._bytes] Column`
        does NOT widen the `.col` field access; the compiler reports
        `incompatible origin` mismatch).  The by-value shape also fits
        the canonical caller shape (the RecordBatch decode path
        attaching dict values to a DICTIONARY column inlines a copy).

        Raises if `dict_id` is not present.
        """
        var idx = self._find(dict_id)
        if idx < 0:
            raise Error(
                "IpcDictCache.get: dict_id "
                + String(Int(dict_id))
                + " not found in cache (no preceding DictionaryBatch "
                + "message with this id in the current ctx.read_arrow* "
                + "call)"
            )
        return self._entries[idx].col.deep_copy()


# =============================================================================
# Internal helper: _concat_var_len_string_binary
# =============================================================================
#
# Concatenate two var-len String/Binary Columns into a single Column of
# the same arrow_type.  Used by `IpcDictCache.append_to` for the
# isDelta=True path.  The four supported arrow_types share a single
# layout shape (validity bitmap + offsets buffer + data buffer):
#
#   STRING / BINARY:       Int32 offsets (4-byte)
#   LARGE_STRING / LARGE_BINARY: Int64 offsets (8-byte)
#
# Concat algorithm:
#   - new_len = a._length + b._length
#   - new_data = a._data ++ b._data
#   - new_offsets:
#       slot 0     = 0
#       slot 1..a._length = a's offsets[1..a._length]
#       slot a._length + i (for i in 1..=b._length) = a._data.length +
#           b._offsets[i]
#   - new_validity:
#       all-non-null on both sides → None
#       otherwise → bit-wise concat of the two bitmaps (LSB-first;
#       Arrow standard layout)
#
# Returns a fresh Column owning copies of all buffers.  Both inputs
# are borrowed (not consumed); the caller controls the lifecycle of
# the existing cache entry vs the incoming delta.


def _concat_var_len_string_binary(
    a: Column[HeapRegion], b: Column[HeapRegion]
) raises -> Column[HeapRegion]:
    """Concatenate two var-len Columns of identical arrow_type
    (STRING / BINARY / LARGE_STRING / LARGE_BINARY).

    Returns a freshly-allocated Column.  Both inputs are borrowed; the
    caller manages their lifetimes.
    """
    if a.arrow_type != b.arrow_type:
        raise Error(
            "_concat_var_len_string_binary: arrow_type mismatch ("
            + String(Int(a.arrow_type.type_id))
            + " vs "
            + String(Int(b.arrow_type.type_id))
            + ")"
        )
    if not a._offsets or not b._offsets:
        raise Error(
            "_concat_var_len_string_binary: missing offsets buffer on "
            "input column (expected var-len column with offsets)"
        )

    var is_large = (
        a.arrow_type == ArrowType.LARGE_STRING
        or a.arrow_type == ArrowType.LARGE_BINARY
    )
    var off_bytes = 8 if is_large else 4

    var a_len = a._length
    var b_len = b._length
    var new_len = a_len + b_len

    var a_data_len = a._data.len()
    var b_data_len = b._data.len()
    var new_data_bytes = a_data_len + b_data_len

    # THE INT32 OFFSET CEILING — the IPC-path sibling of the same shape
    #. This is the DictionaryBatch isDelta=True accumulator:
    # every delta batch off the wire is concatenated onto the cached
    # dictionary, so `new_data_bytes` grows without bound across a
    # stream. For the non-LARGE arrow_types the offsets buffer is
    # **Int32**, and the rebase below is done in Int32 ARITHMETIC —
    # `b_off.read_i32_le_at(...) + Int32(a_data_len)` — so it wraps in
    # two places at once: `Int32(a_data_len)` narrows the base, and the
    # add itself overflows. Neither raises; the merged dictionary just
    # starts returning negative offsets, and every dict-coded column in
    # the stream then resolves against it.
    #
    # Guard the TOTAL, before the allocations, exactly as the 12 other
    # producers do (`offset_overflow.mojo`). LARGE_STRING /
    # LARGE_BINARY take the Int64 arm below and are not affected.
    if not is_large:
        check_int32_offsets(
            "IpcDictCache._concat_var_len_string_binary",
            new_data_bytes,
            new_len,
        )

    # 1. Concat data buffer.
    var new_data = OwnedAlignedBuffer(max(new_data_bytes, 1))
    if a_data_len > 0:
        new_data.copy_from_view(a._data.view_range_ro(0, a_data_len))
    if b_data_len > 0:
        # copy_from_view writes starting at byte 0; use direct byte
        # copy at offset a_data_len for the second buffer.
        for i in range(b_data_len):
            new_data.write_u8_at(a_data_len + i, b._data.read_u8_at(i))
    new_data.set_length(Int64(new_data_bytes))


    # 2. Concat offsets buffer.  new_offsets has new_len + 1 slots.
    var new_off_bytes = (new_len + 1) * off_bytes
    var new_off = OwnedAlignedBuffer(max(new_off_bytes, off_bytes))
    new_off.zero()
    new_off.set_length(Int64(new_off_bytes))


    ref a_off = a._offsets.value()
    ref b_off = b._offsets.value()

    if is_large:
        # Slot 0 = 0 (already zeroed).
        # Copy a's offsets[0..=a_len] verbatim (a_len+1 slots).
        for i in range(a_len + 1):
            new_off.write_i64_le_at(i * 8, a_off.read_i64_le_at(i * 8))
        # Copy b's offsets[1..=b_len], shifted by a_data_len.
        for j in range(1, b_len + 1):
            var v = b_off.read_i64_le_at(j * 8) + Int64(a_data_len)
            new_off.write_i64_le_at((a_len + j) * 8, v)
    else:
        for i in range(a_len + 1):
            new_off.write_i32_le_at(
                i * 4, a_off.read_i32_le_at(i * 4)
            )
        for j in range(1, b_len + 1):
            var v32 = (
                b_off.read_i32_le_at(j * 4) + Int32(a_data_len)
            )
            new_off.write_i32_le_at((a_len + j) * 4, v32)

    # 3. Concat validity.  Arrow spec: dictionary values are typically
    # all-non-null.  If either side has nulls, materialize a merged
    # bitmap.  PHASE-4 step 3 v1 keeps this branch simple: if BOTH
    # sides are no-nulls we emit no bitmap; otherwise we build a fresh
    # one with LSB-first bit packing per Arrow standard.
    var a_has_validity = True if a._validity else False
    var b_has_validity = True if b._validity else False
    var a_has_nulls = a._null_count > 0 or a_has_validity
    var b_has_nulls = b._null_count > 0 or b_has_validity
    var new_validity: Optional[Bitmap[HeapRegion]] = None
    var new_null_count = 0

    if a_has_nulls or b_has_nulls:
        var bm = Bitmap.create(new_len)
        # Set all bits to 1 initially (valid).
        for i in range((new_len + 7) // 8):
            bm.buffer.write_u8_at(i, UInt8(0xFF))
        bm.buffer.set_length((new_len + 7) // 8)


        # Copy a's validity bits (or all-set if a has no bitmap).
        if a._validity:
            ref ab = a._validity.value().buffer
            for i in range(a_len):
                var byte = Int(ab.read_u8_at(i >> 3))
                var bit = (byte >> (i & 7)) & 1
                _set_bit(bm.buffer, i, bit == 1)
                if bit == 0:
                    new_null_count += 1

        # Copy b's validity bits (or all-set if b has no bitmap), at
        # offset a_len.
        if b._validity:
            ref bb = b._validity.value().buffer
            for i in range(b_len):
                var byte = Int(bb.read_u8_at(i >> 3))
                var bit = (byte >> (i & 7)) & 1
                _set_bit(bm.buffer, a_len + i, bit == 1)
                if bit == 0:
                    new_null_count += 1

        new_validity = bm^

    return Column[HeapRegion](
        arrow_type=a.arrow_type,
        data=new_data^,
        offsets=new_off^,
        validity=new_validity^,
        length=new_len,
        null_count=new_null_count,
        offset=0,
    )


def _set_bit[B: AlignedBufferTrait](mut buf: B, pos: Int, set: Bool):
    """LSB-first bit set within an MmapAlignedBuffer-trait-conformer.

    R3.3.D Batch 1: was `mut buf: MmapAlignedBuffer[64]`; trait-parametrized so
    callers can pass either OLD `MmapAlignedBuffer[64]` or the new
    `SharedAlignedBuffer[K]` (Bitmap.buffer's new type).
    """
    var byte_idx = pos >> 3
    var bit_idx = pos & 7
    var byte = Int(buf.read_u8_at(byte_idx))
    if set:
        byte = byte | (1 << bit_idx)
    else:
        byte = byte & (~(1 << bit_idx) & 0xFF)
    buf.write_u8_at(byte_idx, UInt8(byte))
