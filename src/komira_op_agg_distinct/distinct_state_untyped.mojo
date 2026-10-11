# =============================================================================
# distinct_state_untyped -- `DistinctState_Untyped`, the DISTINCT dedup state
# whose key and payload layout is a runtime list of `ColDescriptor`s
# =============================================================================
#
# The run-time-typed sibling of `DistinctState[*Keys]` (`distinct_state`): the
# same insert-only dedup, for a key layout known only when the plan runs.
#
# Storage: `ColumnFormatStorage` holds one slot per DISTINCT KEY (keys first,
# then payloads, by `col_idx_in_storage`); `HashDirectory` maps a composite key
# hash to the slot. Slots are allocated in first-seen order, so slots
# `0 .. n_unique` ARE the output order and every reader is a per-slot read.
#
#   feed_batch:  per row, hash the key columns; walk the directory (salt
#                match, then key equality); on a miss write the keys AND the
#                payloads into a fresh slot (first occurrence wins), on a hit
#                do nothing.
#
# Key semantics (DuckDB's DISTINCT):
#   * every NULL key cell is one value, distinct from every non-NULL value
#     (a NULL INT64 and a real 0, or a NULL STRING and '', are two rows);
#   * float keys follow the query semantics' float model: every NaN is one
#     value and `-0.0` equals `+0.0` (the first-seen spelling is kept);
#   * DECIMAL128 keys compare and hash both words.
#
# The per-column encode, hash and equality kernels are the untyped hash-join
# table's (`komira_op_join_build.join_build_untyped_cells`); this file adds the
# NULL layer a join does not have (a NULL join key matches nothing, a NULL
# DISTINCT key is a value).
#
# Supported key and payload types: the fixed-width integer, float, date,
# timestamp and BOOL types, DECIMAL128, STRING and BINARY.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_column_format.column_format_storage import (
    ColumnFormatStorage,
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    COL_DECIMAL128,
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_I16,
    DT_I8,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_DATE32,
    DT_DATE64,
    DT_BOOL,
    DT_TIMESTAMP_NS,
    DT_TIMESTAMP_US,
    DT_TIMESTAMP_MS,
    DT_TIMESTAMP_S,
)
from komira_op_join_build.hash_directory import HashDirectory, SLOT_EMPTY
from komira_op_join_build.join_build_untyped_cells import (
    _encode_cell,
    _hash_single_col,
    _key_eq_single_col,
)
from komira_op_join_build.join_untyped_key_hash import _hash_compose


comptime _NULL_KEY_HASH: UInt64 = 0x9E37_79B9_7F4A_7C15
"""The hash of a NULL key cell. Every NULL cell hashes alike, so all NULLs meet
in one bucket; the constant is not the hash of any value's bytes, so NULL does
not share the `''` / `0` bucket by construction. A collision with a real value
costs a probe, never a wrong answer: the equality compares the validity bit."""


def _utf8_to_string(kb: List[UInt8]) -> String:
    """The stored bytes of a STRING cell as a `String`, byte for byte.

    Not `chr(Int(byte))` per byte: `chr` maps a code point to its UTF-8
    encoding, so every byte >= 0x80 would come back as two bytes."""
    return String(StringSlice(unsafe_from_utf8=Span(kb)))


struct DistinctState_Untyped(Movable, Deinitable):
    """Insert-only dedup state over a run-time key layout.

    `key_descriptors[k].col_idx_in_storage == k` and
    `payload_descriptors[p].col_idx_in_storage == n_keys + p`. Payload columns
    carry the value of the FIRST row of each distinct key (DISTINCT keeps the
    child's schema; a later duplicate does not overwrite them).
    """

    var key_descriptors: List[ColDescriptor]
    var payload_descriptors: List[ColDescriptor]
    var storage: ColumnFormatStorage
    """One slot per distinct key: keys first, payloads after."""
    var directory: HashDirectory
    var n_unique: Int
    """Distinct keys seen; always `storage.n_slots`."""
    var _slot_hashes: List[UInt64]
    """`_slot_hashes[s]` is the composite hash that placed slot `s`, appended
    by the one allocator (`_feed_one_row`'s miss arm), so it always covers
    every slot. A directory doubling re-inserts every slot at this hash and
    reads no key byte. Re-deriving the hash from storage is NOT equivalent: a
    negative INT16 / INT8 key is hashed sign-extended from the batch but its
    storage cell reads back unsigned, so a re-derived slot would land where no
    later probe of that key looks, and the key's next occurrence would insert
    a second row."""
    var _directory_rehashes: Int
    """Directory doublings performed, so a test can show it grew."""

    def __init__(
        out self,
        var key_descriptors: List[ColDescriptor],
        initial_capacity: Int,
    ) raises:
        """A key-only DISTINCT (no payload columns).

        Args:
            key_descriptors: The key columns; `col_idx_in_storage` must be the
                column's index in this list.
            initial_capacity: Slots allocated up front; the directory starts
                at four times this.
        """
        self = Self(key_descriptors^, List[ColDescriptor](), initial_capacity)

    def __init__(
        out self,
        var key_descriptors: List[ColDescriptor],
        var payload_descriptors: List[ColDescriptor],
        initial_capacity: Int,
    ) raises:
        """A DISTINCT that also carries non-key columns through.

        Args:
            key_descriptors: The key columns; `col_idx_in_storage == k`.
            payload_descriptors: The pass-through columns;
                `col_idx_in_storage == n_keys + p`.
            initial_capacity: Slots allocated up front; the directory starts
                at four times this.
        """
        var combined = List[ColDescriptor]()
        for k in range(len(key_descriptors)):
            combined.append(key_descriptors[k])
        for p in range(len(payload_descriptors)):
            combined.append(payload_descriptors[p])
        self.storage = ColumnFormatStorage.alloc(combined^, initial_capacity)
        self.directory = HashDirectory(initial_capacity * 4)
        self.key_descriptors = key_descriptors^
        self.payload_descriptors = payload_descriptors^
        self.n_unique = 0
        self._slot_hashes = List[UInt64]()
        if initial_capacity > 0:
            self._slot_hashes.reserve(initial_capacity)
        self._directory_rehashes = 0

    # ─────────────────────────────────────────────────────────────────────
    # Accessors
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def n_keys(self) -> Int:
        """Number of key columns."""
        return len(self.key_descriptors)

    @always_inline
    def n_payload(self) -> Int:
        """Number of pass-through payload columns."""
        return len(self.payload_descriptors)

    @always_inline
    def capacity(self) -> Int:
        """Current per-column slot capacity."""
        return self.storage.capacity

    def slot_hash(self, slot: Int) raises -> UInt64:
        """The composite hash that placed distinct-key slot `slot`."""
        if slot < 0 or slot >= len(self._slot_hashes):
            raise Error(
                "DistinctState_Untyped.slot_hash: slot " + String(slot)
                + " out of range"
            )
        return self._slot_hashes[slot]

    @always_inline
    def directory_rehashes(self) -> Int:
        """Directory doublings performed so far."""
        return self._directory_rehashes

    # ─────────────────────────────────────────────────────────────────────
    # The NULL layer over the join table's cell kernels
    # ─────────────────────────────────────────────────────────────────────

    def _encode_with_validity[
        bo: Origin[mut=False]
    ](
        mut self,
        batch: BatchView[bo],
        desc: ColDescriptor,
        row: Int,
        slot: Int,
    ) raises:
        """Write cell (`row`, `desc`) into `slot`, validity bit first.

        A NULL cell's value bytes (a zero word, an empty string) are the bytes
        of a real `0` / `''`; the bit is what tells them apart, for the
        equality below and for the readers. The value is still written: an
        Arrow NULL slot is always a well-formed read."""
        if desc.validity_tracked:
            self.storage.set_slot_valid(
                desc.col_idx_in_storage,
                slot,
                not batch.col_is_null(desc.col_idx_in_batch, row),
            )
        _encode_cell(self.storage, batch, desc, row, slot)

    def _hash_row[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        """Composite hash of the key columns at `row`."""
        var h: UInt64 = 0
        for k in range(len(self.key_descriptors)):
            var desc = self.key_descriptors[k]
            var col_h: UInt64
            if desc.validity_tracked and batch.col_is_null(
                desc.col_idx_in_batch, row
            ):
                col_h = _NULL_KEY_HASH
            else:
                col_h = _hash_single_col(batch, desc, row)
            h = col_h if k == 0 else _hash_compose(h, col_h)
        return h

    def _keys_match[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], row: Int, slot: Int) raises -> Bool:
        """True iff every key at (`batch`, `row`) equals the key at `slot`.

        NULL vs value is unequal; NULL vs NULL is EQUAL (GROUP BY and DISTINCT
        put every NULL in one group), so the bit is compared before any value
        byte and two NULLs never reach the value compare."""
        for k in range(len(self.key_descriptors)):
            var desc = self.key_descriptors[k]
            if desc.validity_tracked:
                var row_null = batch.col_is_null(desc.col_idx_in_batch, row)
                var slot_null = not self.storage.is_slot_valid(
                    desc.col_idx_in_storage, slot
                )
                if row_null != slot_null:
                    return False
                if row_null:
                    continue
            if not _key_eq_single_col(self.storage, batch, row, slot, desc):
                return False
        return True

    # ─────────────────────────────────────────────────────────────────────
    # Feed
    # ─────────────────────────────────────────────────────────────────────

    def feed_batch[bo: Origin[mut=False]](mut self, batch: BatchView[bo]) raises:
        """Insert every row of `batch` whose key has not been seen; a seen key
        is a no-op, so first-seen order and first-occurrence payloads hold."""
        for r in range(batch.n_rows()):
            self._feed_one_row(batch, r)

    def _grow_if_needed(mut self) raises:
        """Grow the storage and the directory before an insert needs them."""
        if self.storage.n_slots >= self.storage.capacity:
            var new_cap = self.storage.capacity * 2
            if new_cap < 16:
                new_cap = 16
            self.storage.grow_to(new_cap)
        if self.directory.would_grow_on_insert():
            self.directory.reset_doubled()
            self._directory_rehashes += 1
            for s in range(self.storage.n_slots):
                _ = self.directory.insert_raw(self._slot_hashes[s], Int32(s))

    def _feed_one_row[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], row: Int) raises:
        # Grow before the probe: a doubling moves every bucket.
        self._grow_if_needed()
        var h = self._hash_row(batch, row)
        var salt = HashDirectory._salt_of(h)
        var bucket = self.directory.bucket_of(h)
        while True:
            var s = self.directory.read_slot_at(bucket)
            if Int(s) == Int(SLOT_EMPTY):
                var new_slot = self.storage.n_slots
                for k in range(len(self.key_descriptors)):
                    var kd = self.key_descriptors[k]
                    self._encode_with_validity(batch, kd, row, new_slot)
                for p in range(len(self.payload_descriptors)):
                    var pd = self.payload_descriptors[p]
                    self._encode_with_validity(batch, pd, row, new_slot)
                self.storage.set_n_slots(new_slot + 1)
                _ = self.directory.insert_raw(h, Int32(new_slot))
                self._slot_hashes.append(h)
                self.n_unique += 1
                return
            if self.directory.read_salt_at(bucket) == salt:
                if self._keys_match(batch, row, Int(s)):
                    return
            bucket = self.directory.next_bucket(bucket)

    # ─────────────────────────────────────────────────────────────────────
    # Readers: one value per distinct key, in first-seen order. Key readers
    # take a key index, payload readers a payload index; both read the same
    # slots. A NULL cell reads back as its stored bytes (0 or empty); the
    # `*_validity` readers say which cells are NULL.
    # ─────────────────────────────────────────────────────────────────────

    def _key_desc(self, key_idx: Int, who: StaticString) raises -> ColDescriptor:
        if key_idx < 0 or key_idx >= len(self.key_descriptors):
            raise Error(
                "DistinctState_Untyped." + String(who) + ": key_idx "
                + String(key_idx) + " out of range"
            )
        return self.key_descriptors[key_idx]

    def _payload_desc(
        self, payload_idx: Int, who: StaticString
    ) raises -> ColDescriptor:
        if payload_idx < 0 or payload_idx >= len(self.payload_descriptors):
            raise Error(
                "DistinctState_Untyped." + String(who) + ": payload_idx "
                + String(payload_idx) + " out of range"
            )
        return self.payload_descriptors[payload_idx]

    @staticmethod
    def _require_fixed(
        desc: ColDescriptor, ok: Bool, who: StaticString, want: String
    ) raises:
        if desc.kind != COL_FIXED or not ok:
            raise Error(
                "DistinctState_Untyped." + String(who) + ": column is not "
                + want + " (kind=" + String(Int(desc.kind))
                + " dtype_tag=" + String(Int(desc.dtype_tag)) + ")"
            )

    def _gather_i64(self, desc: ColDescriptor, who: StaticString) raises -> List[Int64]:
        Self._require_fixed(desc, desc.dtype_tag == DT_I64, who, "Int64")
        var out = List[Int64](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_i64(desc.col_idx_in_storage, s))
        return out^

    def _gather_f64(self, desc: ColDescriptor, who: StaticString) raises -> List[Float64]:
        Self._require_fixed(desc, desc.dtype_tag == DT_F64, who, "Float64")
        var out = List[Float64](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_f64(desc.col_idx_in_storage, s))
        return out^

    def _gather_i32(self, desc: ColDescriptor, who: StaticString) raises -> List[Int32]:
        Self._require_fixed(
            desc,
            desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32,
            who,
            "Int32 / Date32",
        )
        var out = List[Int32](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_i32(desc.col_idx_in_storage, s))
        return out^

    def _gather_f32(self, desc: ColDescriptor, who: StaticString) raises -> List[Float32]:
        Self._require_fixed(desc, desc.dtype_tag == DT_F32, who, "Float32")
        var out = List[Float32](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_f32(desc.col_idx_in_storage, s))
        return out^

    def _gather_u16(
        self, desc: ColDescriptor, signed: Bool, who: StaticString
    ) raises -> List[UInt16]:
        """The 16-bit cells; an INT16 key is stored as its two's-complement
        pattern, so the signed reader re-narrows these."""
        Self._require_fixed(
            desc,
            desc.dtype_tag == (DT_I16 if signed else DT_U16),
            who,
            "Int16" if signed else "UInt16",
        )
        var out = List[UInt16](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_u16(desc.col_idx_in_storage, s))
        return out^

    def _gather_u8(
        self, desc: ColDescriptor, signed: Bool, who: StaticString
    ) raises -> List[UInt8]:
        """The 8-bit cells (INT8 as its two's-complement pattern; BOOL as
        0 / 1 under the unsigned reader)."""
        var ok: Bool
        if signed:
            ok = desc.dtype_tag == DT_I8
        else:
            ok = desc.dtype_tag == DT_U8 or desc.dtype_tag == DT_BOOL
        Self._require_fixed(
            desc, ok, who, "Int8" if signed else "UInt8 / Bool"
        )
        var out = List[UInt8](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_u8(desc.col_idx_in_storage, s))
        return out^

    def _gather_u32(self, desc: ColDescriptor, who: StaticString) raises -> List[UInt32]:
        Self._require_fixed(desc, desc.dtype_tag == DT_U32, who, "UInt32")
        var out = List[UInt32](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_u32(desc.col_idx_in_storage, s))
        return out^

    def _gather_u64(self, desc: ColDescriptor, who: StaticString) raises -> List[UInt64]:
        """A 64-bit word column: UInt64, Date64 or any TIMESTAMP unit. The cell
        is the value's bit pattern, so a negative (pre-epoch) tick comes back
        as a word above 2**63 and `Int()` of it recovers the tick."""
        var t = desc.dtype_tag
        Self._require_fixed(
            desc,
            t == DT_U64 or t == DT_DATE64 or t == DT_TIMESTAMP_S
            or t == DT_TIMESTAMP_MS or t == DT_TIMESTAMP_US
            or t == DT_TIMESTAMP_NS,
            who,
            "a 64-bit word (UInt64 / Date64 / TIMESTAMP)",
        )
        var out = List[UInt64](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.read_slot_u64(desc.col_idx_in_storage, s))
        return out^

    def _gather_string(
        self, desc: ColDescriptor, who: StaticString
    ) raises -> List[String]:
        if desc.kind != COL_VAR_STRING:
            raise Error(
                "DistinctState_Untyped." + String(who)
                + ": column is not VAR_STRING (kind="
                + String(Int(desc.kind)) + ")"
            )
        var out = List[String](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(
                _utf8_to_string(
                    self.storage.read_slot_str_bytes(desc.col_idx_in_storage, s)
                )
            )
        return out^

    def _gather_validity(self, desc: ColDescriptor) raises -> List[Bool]:
        var out = List[Bool](capacity=self.n_unique)
        for s in range(self.n_unique):
            out.append(self.storage.is_slot_valid(desc.col_idx_in_storage, s))
        return out^

    def read_unique_i64(self, key_idx: Int) raises -> List[Int64]:
        """INT64 key column `key_idx`, in first-seen order."""
        return self._gather_i64(self._key_desc(key_idx, "read_unique_i64"), "read_unique_i64")

    def read_unique_f64(self, key_idx: Int) raises -> List[Float64]:
        """FLOAT64 key column, in first-seen order."""
        return self._gather_f64(self._key_desc(key_idx, "read_unique_f64"), "read_unique_f64")

    def read_unique_i32(self, key_idx: Int) raises -> List[Int32]:
        """INT32 or DATE32 key column, in first-seen order."""
        return self._gather_i32(self._key_desc(key_idx, "read_unique_i32"), "read_unique_i32")

    def read_unique_f32(self, key_idx: Int) raises -> List[Float32]:
        """FLOAT32 key column, in first-seen order."""
        return self._gather_f32(self._key_desc(key_idx, "read_unique_f32"), "read_unique_f32")

    def read_unique_i16(self, key_idx: Int) raises -> List[Int16]:
        """INT16 key column, in first-seen order."""
        var u = self._gather_u16(
            self._key_desc(key_idx, "read_unique_i16"), True, "read_unique_i16"
        )
        var out = List[Int16](capacity=len(u))
        for i in range(len(u)):
            out.append(Int16(Int(u[i])))
        return out^

    def read_unique_u16(self, key_idx: Int) raises -> List[UInt16]:
        """UINT16 key column, in first-seen order."""
        return self._gather_u16(
            self._key_desc(key_idx, "read_unique_u16"), False, "read_unique_u16"
        )

    def read_unique_i8(self, key_idx: Int) raises -> List[Int8]:
        """INT8 key column, in first-seen order."""
        var u = self._gather_u8(
            self._key_desc(key_idx, "read_unique_i8"), True, "read_unique_i8"
        )
        var out = List[Int8](capacity=len(u))
        for i in range(len(u)):
            out.append(Int8(Int(u[i])))
        return out^

    def read_unique_u8(self, key_idx: Int) raises -> List[UInt8]:
        """UINT8 or BOOL (0 / 1) key column, in first-seen order."""
        return self._gather_u8(
            self._key_desc(key_idx, "read_unique_u8"), False, "read_unique_u8"
        )

    def read_unique_u32(self, key_idx: Int) raises -> List[UInt32]:
        """UINT32 key column, in first-seen order."""
        return self._gather_u32(self._key_desc(key_idx, "read_unique_u32"), "read_unique_u32")

    def read_unique_u64(self, key_idx: Int) raises -> List[UInt64]:
        """UINT64, DATE64 or TIMESTAMP key column as 64-bit words, in
        first-seen order."""
        return self._gather_u64(self._key_desc(key_idx, "read_unique_u64"), "read_unique_u64")

    def read_unique_string(self, key_idx: Int) raises -> List[String]:
        """STRING key column, byte for byte, in first-seen order."""
        return self._gather_string(
            self._key_desc(key_idx, "read_unique_string"), "read_unique_string"
        )

    def read_unique_i128(self, key_idx: Int) raises -> List[SIMD[DType.int128, 1]]:
        """DECIMAL128 key column as the unscaled signed 128-bit values, in
        first-seen order: `(hi << 64) | lo`, reinterpreted as signed."""
        var desc = self._key_desc(key_idx, "read_unique_i128")
        if desc.kind != COL_DECIMAL128:
            raise Error(
                "DistinctState_Untyped.read_unique_i128: column is not"
                " DECIMAL128 (kind=" + String(Int(desc.kind)) + ")"
            )
        var out = List[SIMD[DType.int128, 1]](capacity=self.n_unique)
        for s in range(self.n_unique):
            var lo = self.storage.read_slot_u64(desc.col_idx_in_storage, s)
            var hi = self.storage.read_slot_decimal128_hi(
                desc.col_idx_in_storage, s
            )
            var u = (hi.cast[DType.uint128]() << UInt128(64)) | lo.cast[
                DType.uint128
            ]()
            out.append(u.cast[DType.int128]())
        return out^

    def read_unique_validity(self, key_idx: Int) raises -> List[Bool]:
        """Per distinct key, False where key column `key_idx` is NULL. All
        True for a column whose descriptor tracks no validity."""
        return self._gather_validity(self._key_desc(key_idx, "read_unique_validity"))

    def read_payload_i64(self, payload_idx: Int) raises -> List[Int64]:
        """INT64 payload column (each key's first occurrence)."""
        return self._gather_i64(
            self._payload_desc(payload_idx, "read_payload_i64"), "read_payload_i64"
        )

    def read_payload_f64(self, payload_idx: Int) raises -> List[Float64]:
        """FLOAT64 payload column."""
        return self._gather_f64(
            self._payload_desc(payload_idx, "read_payload_f64"), "read_payload_f64"
        )

    def read_payload_i32(self, payload_idx: Int) raises -> List[Int32]:
        """INT32 or DATE32 payload column."""
        return self._gather_i32(
            self._payload_desc(payload_idx, "read_payload_i32"), "read_payload_i32"
        )

    def read_payload_f32(self, payload_idx: Int) raises -> List[Float32]:
        """FLOAT32 payload column."""
        return self._gather_f32(
            self._payload_desc(payload_idx, "read_payload_f32"), "read_payload_f32"
        )

    def read_payload_i16(self, payload_idx: Int) raises -> List[Int16]:
        """INT16 payload column."""
        var u = self._gather_u16(
            self._payload_desc(payload_idx, "read_payload_i16"),
            True,
            "read_payload_i16",
        )
        var out = List[Int16](capacity=len(u))
        for i in range(len(u)):
            out.append(Int16(Int(u[i])))
        return out^

    def read_payload_u16(self, payload_idx: Int) raises -> List[UInt16]:
        """UINT16 payload column."""
        return self._gather_u16(
            self._payload_desc(payload_idx, "read_payload_u16"),
            False,
            "read_payload_u16",
        )

    def read_payload_i8(self, payload_idx: Int) raises -> List[Int8]:
        """INT8 payload column."""
        var u = self._gather_u8(
            self._payload_desc(payload_idx, "read_payload_i8"),
            True,
            "read_payload_i8",
        )
        var out = List[Int8](capacity=len(u))
        for i in range(len(u)):
            out.append(Int8(Int(u[i])))
        return out^

    def read_payload_u8(self, payload_idx: Int) raises -> List[UInt8]:
        """UINT8 or BOOL payload column."""
        return self._gather_u8(
            self._payload_desc(payload_idx, "read_payload_u8"),
            False,
            "read_payload_u8",
        )

    def read_payload_u32(self, payload_idx: Int) raises -> List[UInt32]:
        """UINT32 payload column."""
        return self._gather_u32(
            self._payload_desc(payload_idx, "read_payload_u32"), "read_payload_u32"
        )

    def read_payload_u64(self, payload_idx: Int) raises -> List[UInt64]:
        """UINT64, DATE64 or TIMESTAMP payload column as 64-bit words."""
        return self._gather_u64(
            self._payload_desc(payload_idx, "read_payload_u64"), "read_payload_u64"
        )

    def read_payload_string(self, payload_idx: Int) raises -> List[String]:
        """STRING payload column, byte for byte."""
        return self._gather_string(
            self._payload_desc(payload_idx, "read_payload_string"),
            "read_payload_string",
        )

    def read_payload_validity(self, payload_idx: Int) raises -> List[Bool]:
        """Per distinct key, False where payload column `payload_idx` was NULL
        on the key's first occurrence."""
        return self._gather_validity(
            self._payload_desc(payload_idx, "read_payload_validity")
        )
