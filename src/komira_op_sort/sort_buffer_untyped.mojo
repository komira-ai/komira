# =============================================================================
# SortBuffer_Untyped: a multi-key sort buffer whose column types are known
# only at run time
# =============================================================================
#
# The layout is a `List[ColDescriptor]` (see `komira_column_format`): sort
# keys first, payload columns after, in one `ColumnFormatStorage`.
#
#   * `feed_batch(BatchView)` appends every row of a batch as a slot, each
#     cell copied by `sort_buffer_cells._encode_cell`.
#   * `finalize_sort()` orders the slots by a stable bottom-up merge sort,
#     comparing the keys in order (`sort_buffer_cells._compare_cells`), each
#     in its own direction (`SORT_ASC` / `SORT_DESC`).
#   * `read_sorted_*` read a column back in sorted order, one typed reader
#     per DType.
#
# Key and payload types: I64, F64, I32, F32, I16, I8, U8, U16, U32, U64,
# DATE32, DATE64, BOOL, the TIMESTAMP units, DECIMAL128 (both 64-bit words,
# signed), STRING and BINARY (byte-wise). Floats order by `sort_key_lt`:
# NaN above +inf. Typed readers exist for every type above except TIMESTAMP,
# DECIMAL128 and BINARY; for those the order is in `sorted_indices`.
#
# Validity is not tracked: a NULL cell is stored and compared as its value
# bytes. The caller keeps nullable keys out (or places nulls itself).
#
# No pointer in any signature; no wildcard origin.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_column_format.column_format_storage import (
    COL_FIXED,
    COL_VAR_STRING,
    ColDescriptor,
    ColumnFormatStorage,
    DT_BOOL,
    DT_DATE32,
    DT_DATE64,
    DT_F32,
    DT_F64,
    DT_I16,
    DT_I32,
    DT_I64,
    DT_I8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_U8,
)

from .sort_buffer_cells import _compare_cells, _encode_cell


# Sort direction constants. ASC = natural order (smaller first); DESC
# = reversed.
comptime SORT_ASC: UInt8 = 0
comptime SORT_DESC: UInt8 = 1


def _untyped_sort_bytes_to_string(imm kb: List[UInt8]) -> String:
    """Decode a UTF-8 byte slab into a String (`read_sorted_string`).

    Do not rewrite this as `out += chr(Int(kb[k]))` per byte: `chr` takes a
    code point, so every byte of a multi-byte UTF-8 character would be
    re-encoded as a character of its own."""
    return String(StringSlice(unsafe_from_utf8=Span(kb)))


struct SortBuffer_Untyped(Movable, Deinitable):
    """Runtime-ColDescriptor-dispatched multi-key sort buffer.

    Fields:
        var sort_key_descriptors: List[ColDescriptor]  # sort keys
        var sort_directions: List[UInt8]               # ASC/DESC per key
        var payload_descriptors: List[ColDescriptor]   # payload cols
        var storage: ColumnFormatStorage               # slot store
        var sorted_indices: List[Int]                  # post-sort slot order

    Layout convention: the `storage`'s ColDescriptor list interleaves
    sort keys + payloads (keys first, payloads after) by
    `col_idx_in_storage`. `sort_key_descriptors[k].col_idx_in_storage == k`;
    `payload_descriptors[p].col_idx_in_storage == n_keys + p`.

    Feed hot loop (feed_batch):
        for r in 0..batch.n_rows():
            1. alloc a fresh slot at storage.n_slots
            2. write all sort keys + all payloads via per-DType
               `_encode_cell` into the new slot
            3. set_n_slots + sorted_indices.append(new_slot)

    Sort hot loop (finalize_sort):
        stable bottom-up MERGE sort over `sorted_indices` using
        `_compare_storage_rows` to compare two slot indices via every
        sort key (per-DType cmp) and per-key direction (ASC/DESC).
        O(n log n); see `_msort_indices`.
    """

    var sort_key_descriptors: List[ColDescriptor]
    """Per-sort-key-col metadata; layout governs the comparator dispatch."""

    var sort_directions: List[UInt8]
    """Per-sort-key direction. SORT_ASC = 0 (natural order); SORT_DESC = 1
    (reversed). Same length as `sort_key_descriptors`."""

    var payload_descriptors: List[ColDescriptor]
    """Per-payload-col metadata; governs the post-sort gather."""

    var storage: ColumnFormatStorage
    """Per-col slot store. Holds both sort keys + payloads under one
    descriptor list (keys first, payloads after, by `col_idx_in_storage`)."""

    var sorted_indices: List[Int]
    """Post-sort slot ordering. Set by `finalize_sort`; before that, the
    list is in insertion order (same as iteration order of the fed
    batches). Length always equals `storage.n_slots`."""

    # ─────────────────────────────────────────────────────────────────────
    # Construction
    # ─────────────────────────────────────────────────────────────────────

    def __init__(
        out self,
        var sort_key_descriptors: List[ColDescriptor],
        var sort_directions: List[UInt8],
        var payload_descriptors: List[ColDescriptor],
        initial_capacity: Int,
    ) raises:
        """Build a SortBuffer_Untyped with the given key + direction +
        payload layout.

        Args:
            sort_key_descriptors: Per-sort-key-col metadata. MUST have
                `col_idx_in_storage` equal to the col's 0-based index
                within sort_key_descriptors.
            sort_directions: Per-sort-key direction (SORT_ASC / SORT_DESC).
                MUST have the same length as sort_key_descriptors.
            payload_descriptors: Per-payload-col metadata. MUST have
                `col_idx_in_storage` equal to `n_keys + p`.
            initial_capacity: Pre-allocated slot capacity.

        Raises:
            On sort_directions length mismatch.
        """
        # Snapshot lengths BEFORE moving the lists into self.
        var n_keys = sort_key_descriptors.__len__()
        var n_payload = payload_descriptors.__len__()
        var n_dirs = sort_directions.__len__()

        if n_dirs != n_keys:
            raise Error(
                "SortBuffer_Untyped: sort_directions length="
                + String(n_dirs)
                + " must equal n_sort_keys="
                + String(n_keys)
            )

        # Build the combined storage layout (keys first, payloads after).
        var combined = List[ColDescriptor]()
        for k in range(n_keys):
            combined.append(sort_key_descriptors[k])
        for p in range(n_payload):
            combined.append(payload_descriptors[p])

        # Allocate per-col storage. ColumnFormatStorage.alloc takes
        # ownership of the layout list.
        self.storage = ColumnFormatStorage.alloc(combined^, initial_capacity)

        # Move the descriptor + direction lists into self LAST.
        self.sort_key_descriptors = sort_key_descriptors^
        self.sort_directions = sort_directions^
        self.payload_descriptors = payload_descriptors^
        self.sorted_indices = List[Int]()

    # ─────────────────────────────────────────────────────────────────────
    # Diagnostics / accessors
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def n_sort_keys(self) -> Int:
        """Number of sort-key cols."""
        return self.sort_key_descriptors.__len__()

    @always_inline
    def n_payload(self) -> Int:
        """Number of payload cols."""
        return self.payload_descriptors.__len__()

    @always_inline
    def n_slots(self) -> Int:
        """Live slot count (= row count fed)."""
        return self.storage.n_slots

    @always_inline
    def capacity(self) -> Int:
        """Current per-col slot capacity."""
        return self.storage.capacity

    def _compare_storage_rows(
        self, slot_a: Int, slot_b: Int
    ) raises -> Int:
        """Multi-key compare. Walks sort keys in order, applying per-key
        direction. Returns negative/zero/positive per the first
        non-equal key. Returns 0 only if all keys compare equal.
        """
        var n_keys = self.sort_key_descriptors.__len__()
        for k in range(n_keys):
            var desc = self.sort_key_descriptors[k]
            var raw = _compare_cells(self.storage, desc, slot_a, slot_b)
            if raw != 0:
                if self.sort_directions[k] == SORT_DESC:
                    return -raw
                return raw
        return 0

    # ─────────────────────────────────────────────────────────────────────
    # feed_batch — primary feed entry.
    # ─────────────────────────────────────────────────────────────────────

    def feed_batch[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo]) raises:
        """Append each row of `batch` into the sort buffer.

        For each row r:
          1. Compute the new slot index (= storage.n_slots).
          2. Grow the storage if at capacity (constant-amortized doubling).
          3. Write each sort key col + each payload col via per-DType
             `_encode_cell` into the new slot.
          4. set_n_slots(new_slot + 1).
          5. sorted_indices.append(new_slot).
        """
        var n_rows = batch.n_rows()
        for r in range(n_rows):
            self._feed_one_row(batch, r)

    def _feed_one_row[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], row: Int) raises:
        """Feed hot path for ONE row. Called by `feed_batch` once per row."""
        # Grow before write — ensures the new slot fits.
        self._grow_if_needed()

        var new_slot = self.storage.n_slots

        # Write all sort key cols. Copy the descriptor into a local
        # before passing: a mut argument and a ref through `self` in the
        # same call would alias.
        for k in range(self.sort_key_descriptors.__len__()):
            var key_desc = self.sort_key_descriptors[k]
            _encode_cell(self.storage, batch, key_desc, row, new_slot)
        # Write all payload cols.
        for p in range(self.payload_descriptors.__len__()):
            var pay_desc = self.payload_descriptors[p]
            _encode_cell(self.storage, batch, pay_desc, row, new_slot)

        self.storage.set_n_slots(new_slot + 1)
        self.sorted_indices.append(new_slot)

    def _grow_if_needed(mut self) raises:
        """Grow storage if at capacity."""
        if self.storage.n_slots >= self.storage.capacity:
            var new_cap = self.storage.capacity * 2
            if new_cap < 16:
                new_cap = 16
            self.storage.grow_to(new_cap)

    # ─────────────────────────────────────────────────────────────────────
    # finalize_sort — stable bottom-up MERGE sort over `sorted_indices`.
    #
    # PERF-CRITICAL: O(n log n) compares, O(n) scratch (an insertion sort
    # is quadratic here). Stable: equal keys keep buffer order.
    # ─────────────────────────────────────────────────────────────────────

    def finalize_sort(mut self) raises:
        """Stable bottom-up merge-sort of `sorted_indices` per multi-key
        comparator. After this, walking sorted_indices yields slot indices
        in sort-order.

        Stability: the merge takes from the LEFT run unless the RIGHT is
        strictly less (`_compare_storage_rows(right, left) < 0`), so
        equal-keyed slots preserve their input (buffer) order.
        """
        self._msort_indices()

    def _msort_indices(mut self) raises:
        """Stable bottom-up (iterative) merge sort of `sorted_indices` by
        the multi-key `_compare_storage_rows` comparator. O(n log n)
        compares, O(n) scratch.

        Bottom-up (iterative) avoids recursion. STABLE: the merge takes the
        LEFT element unless the RIGHT is strictly less
        (`_compare_storage_rows(order[j], order[i]) < 0`), so equal keys
        retain buffer order.

        Sorts a LOCAL copy then writes back: `_compare_storage_rows` borrows
        `self` (read-only over storage) so it cannot run while also mutating
        `self.sorted_indices` in place under the same `self` receiver.
        """
        var order = self.sorted_indices.copy()
        var n = len(order)
        if n < 2:
            return
        var buf = List[Int](capacity=n)
        for _ in range(n):
            buf.append(0)
        var width = 1
        while width < n:
            var lo = 0
            while lo < n:
                var mid = lo + width
                if mid > n:
                    mid = n
                var hi = lo + 2 * width
                if hi > n:
                    hi = n
                # Merge order[lo:mid) and order[mid:hi) into buf[lo:hi).
                var i = lo
                var j = mid
                var k = lo
                while i < mid and j < hi:
                    # STABLE: take LEFT unless RIGHT is strictly less.
                    if self._compare_storage_rows(order[j], order[i]) < 0:
                        buf[k] = order[j]
                        j += 1
                    else:
                        buf[k] = order[i]
                        i += 1
                    k += 1
                while i < mid:
                    buf[k] = order[i]
                    i += 1
                    k += 1
                while j < hi:
                    buf[k] = order[j]
                    j += 1
                    k += 1
                lo += 2 * width
            # Copy the merged run back into order for the next pass.
            for t in range(n):
                order[t] = buf[t]
            width *= 2
        self.sorted_indices = order^

    # ─────────────────────────────────────────────────────────────────────
    # emit_to_record_batch_columnar — drain sorted slots into a per-DType
    # `List[T]` per output payload col.
    #
    # The readers return parallel lists, not a `RecordBatch`; the caller
    # builds the Arrow columns.
    # ─────────────────────────────────────────────────────────────────────

    def read_sorted_i64(self, col_idx_in_storage: Int) raises -> List[Int64]:
        """Gather Int64 col `col_idx_in_storage` in post-sort order.
        Output length == n_slots."""
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.storage.n_cols():
            raise Error(
                "SortBuffer_Untyped.read_sorted_i64: col_idx out of range"
            )
        var desc = self.storage.col_descriptor(col_idx_in_storage)
        if desc.kind != COL_FIXED or desc.dtype_tag != DT_I64:
            raise Error(
                "SortBuffer_Untyped.read_sorted_i64: col is not Int64 fixed"
                " (kind=" + String(Int(desc.kind))
                + " dtype_tag=" + String(Int(desc.dtype_tag))
                + ")"
            )
        var out = List[Int64]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_i64(col_idx_in_storage, slot))
        return out^

    def read_sorted_f64(self, col_idx_in_storage: Int) raises -> List[Float64]:
        """Gather Float64 col in post-sort order."""
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.storage.n_cols():
            raise Error(
                "SortBuffer_Untyped.read_sorted_f64: col_idx out of range"
            )
        var desc = self.storage.col_descriptor(col_idx_in_storage)
        if desc.kind != COL_FIXED or desc.dtype_tag != DT_F64:
            raise Error(
                "SortBuffer_Untyped.read_sorted_f64: col is not Float64 fixed"
            )
        var out = List[Float64]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_f64(col_idx_in_storage, slot))
        return out^

    def read_sorted_i32(self, col_idx_in_storage: Int) raises -> List[Int32]:
        """Gather Int32 / Date32 col in post-sort order."""
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.storage.n_cols():
            raise Error(
                "SortBuffer_Untyped.read_sorted_i32: col_idx out of range"
            )
        var desc = self.storage.col_descriptor(col_idx_in_storage)
        if (desc.kind != COL_FIXED
                or (desc.dtype_tag != DT_I32 and desc.dtype_tag != DT_DATE32)):
            raise Error(
                "SortBuffer_Untyped.read_sorted_i32: col is not Int32 / Date32 fixed"
            )
        var out = List[Int32]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_i32(col_idx_in_storage, slot))
        return out^

    # ─────────────────────────────────────────────────────────────────────
    # One reader per fixed DType, so a caller can emit the native Arrow
    # column type. DT_DATE64 reads as u64, DT_BOOL as u8; the signed
    # narrow types (I16 / I8) read the unsigned cell and re-narrow.
    # ─────────────────────────────────────────────────────────────────────

    def read_sorted_f32(self, col_idx_in_storage: Int) raises -> List[Float32]:
        """Gather Float32 col in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_F32:
            raise Error(
                "SortBuffer_Untyped.read_sorted_f32: col is not Float32 fixed"
            )
        var out = List[Float32]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_f32(col_idx_in_storage, slot))
        return out^

    def read_sorted_i16(self, col_idx_in_storage: Int) raises -> List[Int16]:
        """Gather Int16 col (stored in a u16 cell) in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_I16:
            raise Error(
                "SortBuffer_Untyped.read_sorted_i16: col is not Int16 fixed"
            )
        var out = List[Int16]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            var u = self.storage.read_slot_u16(col_idx_in_storage, slot)
            out.append(Int16(Int(u)))
        return out^

    def read_sorted_u16(self, col_idx_in_storage: Int) raises -> List[UInt16]:
        """Gather UInt16 col in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_U16:
            raise Error(
                "SortBuffer_Untyped.read_sorted_u16: col is not UInt16 fixed"
            )
        var out = List[UInt16]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_u16(col_idx_in_storage, slot))
        return out^

    def read_sorted_i8(self, col_idx_in_storage: Int) raises -> List[Int8]:
        """Gather Int8 col (stored in a u8 cell) in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_I8:
            raise Error(
                "SortBuffer_Untyped.read_sorted_i8: col is not Int8 fixed"
            )
        var out = List[Int8]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            var u = self.storage.read_slot_u8(col_idx_in_storage, slot)
            out.append(Int8(Int(u)))
        return out^

    def read_sorted_u8(self, col_idx_in_storage: Int) raises -> List[UInt8]:
        """Gather UInt8 / Bool col in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_U8 and desc.dtype_tag != DT_BOOL:
            raise Error(
                "SortBuffer_Untyped.read_sorted_u8: col is not UInt8/Bool fixed"
            )
        var out = List[UInt8]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_u8(col_idx_in_storage, slot))
        return out^

    def read_sorted_u32(self, col_idx_in_storage: Int) raises -> List[UInt32]:
        """Gather UInt32 col in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_U32:
            raise Error(
                "SortBuffer_Untyped.read_sorted_u32: col is not UInt32 fixed"
            )
        var out = List[UInt32]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_u32(col_idx_in_storage, slot))
        return out^

    def read_sorted_u64(self, col_idx_in_storage: Int) raises -> List[UInt64]:
        """Gather UInt64 / Date64 col in post-sort order."""
        var desc = self._checked_sorted_desc(col_idx_in_storage)
        if desc.dtype_tag != DT_U64 and desc.dtype_tag != DT_DATE64:
            raise Error(
                "SortBuffer_Untyped.read_sorted_u64: col is not"
                " UInt64/Date64 fixed"
            )
        var out = List[UInt64]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            out.append(self.storage.read_slot_u64(col_idx_in_storage, slot))
        return out^

    def read_sorted_string(
        self, col_idx_in_storage: Int
    ) raises -> List[String]:
        """Gather STRING (VAR_STRING) col `col_idx_in_storage` in
        post-sort order. Output length == n_slots.

        The storage holds the bytes in the column's payload heap; this
        decodes each sorted slot to a String.
        """
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.storage.n_cols():
            raise Error(
                "SortBuffer_Untyped.read_sorted_string: col_idx out of range"
            )
        var desc = self.storage.col_descriptor(col_idx_in_storage)
        if desc.kind != COL_VAR_STRING:
            raise Error(
                "SortBuffer_Untyped.read_sorted_string: col is not"
                " VAR_STRING (kind=" + String(Int(desc.kind)) + ")"
            )
        var out = List[String]()
        for i in range(self.sorted_indices.__len__()):
            var slot = self.sorted_indices[i]
            var bytes = self.storage.read_slot_str_bytes(
                col_idx_in_storage, slot
            )
            out.append(_untyped_sort_bytes_to_string(bytes^))
        return out^

    def _checked_sorted_desc(
        self, col_idx_in_storage: Int
    ) raises -> ColDescriptor:
        """Bounds-check + fixed-width-check shared by the wider sorted
        readers."""
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.storage.n_cols():
            raise Error(
                "SortBuffer_Untyped.read_sorted_*: col_idx out of range"
            )
        var desc = self.storage.col_descriptor(col_idx_in_storage)
        if desc.kind != COL_FIXED:
            raise Error(
                "SortBuffer_Untyped.read_sorted_*: col is not fixed-width"
                " (kind=" + String(Int(desc.kind)) + ")"
            )
        return desc
