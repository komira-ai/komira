# =============================================================================
# distinct_key_column_string.mojo — the STRING key column of the stage
# DISTINCT state
# =============================================================================


from std.collections import Optional
from std.memory import bitcast
from std.os import abort
from std.sys import size_of

from komira_counters.keyeq_census import keyeq_record, KEYEQ_DISTINCT_DICTARM, KEYEQ_DISTINCT_DENSEARM, KEYEQ_DISTINCT_ROWBYTES, KEYEQ_DISTINCT_COMBINE
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    ArrowType,
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.batch_view import BatchView, scalar_arrow_type
from komira_arrow.band_view import BandView
from komira_udf.float_quotient_order import (
    canonical_bits_f32,
    canonical_bits_f64,
    float_quotient_eq_f32,
    float_quotient_eq_f64,
)

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.byte_view import ByteView

from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)
from komira_operator_api.emit_at_offset_target import (
    _EmitColDesc,
    _EmitColTarget,
    EMIT_KIND_INELIGIBLE,
    EMIT_KIND_FIXED,
    EMIT_KIND_STRING,
)
from komira_expr.stage_program import BREAKER_DISTINCT
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spillable_op import SpillableOp
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_arrow.column_native import ColumnNativeBatch


from komira_op_agg_distinct.distinct_key_column import (
    DISTINCT_DEFAULT_CAPACITY,
    DISTINCT_FNV_PRIME,
    DistinctKeyColumn,
    _distinct_fnv1a_step,
)

# =============================================================================
# §2c — DistinctKeyColumn_String[col] — the STRING DISTINCT-key conformer
# =============================================================================
#
# STRING keys. Mirrors `PartKeyCol_String` (the proven
# partition-top-n STRING key conformer) onto the `DistinctKeyColumn` trait
# surface: a flat byte SoA (`List[UInt8]` data + `List[Int]` offsets, Arrow
# varlen layout) of each stored DISTINCT row's key string. FNV-1a folds the
# string's bytes into the running combined-key hash `state` (same FNV-1a step
# the numeric `_distinct_fnv1a_step` uses, so a composite numeric+string key's
# combined hash is consistent across feed / combine / restore — the dedup
# directory bucket is byte-identical, the ptopn cross-worker lesson). Equality
# is a byte-length + memcmp over the candidate vs the stored slice — the
# directory delegates equality, so the directory stays value-type-agnostic and
# UNTOUCHED (no fixed-width-key assumption baked anywhere — the directory
# stores only salt|dense_idx + cached_hash).
#
# `DT` is `DType.uint8` (the per-byte channel) — a nominal sentinel for the
# `memory_usage_bytes` per-row size hint (string rows are variable-width; 1
# byte/row is a conservative estimate, and memory accounting is a spill hint,
# not load-bearing). The conformer NEVER reads `Scalar[DT]` off the batch — it
# reads bytes via the StringColumnView, so no numeric-accessor path is taken.
#
# Encapsulation invariants (the pointer rules):
#   - NO `UnsafePointer` in any signature; NO wildcard origins.
#   - `List[UInt8]` / `List[Int]` POD storage (mirror of
#     `PartKeyCol_String`; no heap-owning Movable element).


@always_inline
def _distinct_fnv1a_bytes_step(state: UInt64, b: UInt8) -> UInt64:
    """One FNV-1a fold of a single key BYTE into the running hash `state` — the
    string analogue of `_distinct_fnv1a_step` (which folds a typed scalar's bit
    pattern). Folding byte-by-byte keeps a STRING key's contribution to the
    combined composite-key hash consistent across feed / combine / restore, so
    a numeric+string composite key lands in the SAME directory bucket on every
    path (the byte-identical-hash cross-worker invariant)."""
    return (state ^ UInt64(b)) * DISTINCT_FNV_PRIME


@fieldwise_init
struct DistinctKeyColumn_String[col: Int](DistinctKeyColumn):
    """STRING DISTINCT-key column bound to input batch column `col`. Stores each
    stored DISTINCT row's key string as bytes in a flat `List[UInt8]` data
    buffer + a `List[Int]` offsets array (Arrow varlen SoA). FNV-1a folds the
    bytes into the combined-key hash; byte-exact equality.
    (`List[UInt8]` / `List[Int]` POD.) The `DistinctKeyColumn` analogue of
    `PartKeyCol_String[col]`."""

    comptime DT: DType = DType.uint8
    var data: List[UInt8]
    var offsets: List[Int]  # offsets[row]..offsets[row+1] is row's byte slice

    def __init__(out self):
        """`Defaultable` no-arg ctor — builds an empty column with the varlen-SoA
        sentinel offset (offsets[0] == 0). Lets the pack-aware `Tuple[*Keys]()`
        default ctor resolve in `DistinctState[*Keys]`'s nullary ctor."""
        self.data = List[UInt8](capacity=DISTINCT_DEFAULT_CAPACITY * 8)
        self.offsets = List[Int](capacity=DISTINCT_DEFAULT_CAPACITY + 1)
        self.offsets.append(0)

    @always_inline
    def _len_of(self, stored_idx: Int) -> Int:
        return self.offsets[stored_idx + 1] - self.offsets[stored_idx]

    # The `DistinctKeyColumn` trait surface (`hash_step` / `equals_row` /
    # `append_row` / `restore_*`) is NON-raising, but the StringColumnView
    # accessors (`col_str` / `get` / `byte_at` / `length`) raise (Arrow
    # bounds-checks). The row index is ALWAYS in-bounds on these paths (the
    # directory probe + drain iterate over valid rows of a valid Arrow string
    # column), so a raise here is unreachable; the three private helpers catch
    # + `abort` to satisfy the non-raising trait contract (the numeric conformer
    # avoids this because its `col_iNN().load` accessor is non-raising).

    # DICTIONARY keys: when the bound key column arrives as a string
    # DICTIONARY (codes + a per-row-group dictionary page), the three read helpers RESOLVE code->bytes INLINE via the
    # INC-1 `col_string_dict_value_at` primitive and hash/compare/store the
    # RESOLVED BYTES — byte-identical to the dense-STRING path over the same
    # bytes (so a dict-encoded key hashes + groups exactly like its dense
    # sibling), and the STORED representation stays resolved bytes (codes are
    # per-RG; storing bytes makes the group cross-RG-canonical for free). NO
    # dense StringArray is materialized on the source or on a worker thread.

    @always_inline
    def _append_bytes_from[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], read_col: Int, row: Int):
        """Append `batch[row]`'s string (off column `read_col`) as one stored
        distinct value: copy its bytes into `data`, push the new end-offset."""
        try:
            if batch.col_is_string_dict(read_col):
                var code = batch.col_string_dict_code_at(read_col, row)
                var bv = batch.col_string_dict_value_at(read_col, code)
                for i in range(bv.len()):
                    self.data.append(bv.read_u8_at(i))
            else:
                var sv = batch.col_str(read_col).get(row)
                var n = sv.length()
                for i in range(n):
                    self.data.append(sv.byte_at(i))
            self.offsets.append(len(self.data))
        except e:
            abort(String("DistinctKeyColumn_String._append: ") + String(e))

    @always_inline
    def _hash_bytes_of[
        bo: Origin[mut=False]
    ](self, state: UInt64, batch: BatchView[bo], read_col: Int, row: Int) -> UInt64:
        """Fold `batch[row]`'s string bytes (off column `read_col`) into the
        running FNV-1a hash `state`."""
        try:
            var h = state
            if batch.col_is_string_dict(read_col):
                var code = batch.col_string_dict_code_at(read_col, row)
                var bv = batch.col_string_dict_value_at(read_col, code)
                for i in range(bv.len()):
                    h = _distinct_fnv1a_bytes_step(h, bv.read_u8_at(i))
            else:
                var sv = batch.col_str(read_col).get(row)
                var n = sv.length()
                for i in range(n):
                    h = _distinct_fnv1a_bytes_step(h, sv.byte_at(i))
            return h
        except e:
            abort(String("DistinctKeyColumn_String._hash: ") + String(e))

    @always_inline
    def _equals_bytes[
        bo: Origin[mut=False]
    ](
        self, stored_idx: Int, batch: BatchView[bo], read_col: Int, row: Int
    ) -> Bool:
        """True iff the stored string at `stored_idx` equals `batch[row]`'s
        string (off column `read_col`): byte-length + memcmp over the slice."""
        try:
            var base = self.offsets[stored_idx]
            var stored_n = self._len_of(stored_idx)
            if batch.col_is_string_dict(read_col):
                var code = batch.col_string_dict_code_at(read_col, row)
                var bv = batch.col_string_dict_value_at(read_col, code)
                if bv.len() != stored_n:
                    keyeq_record(
                        KEYEQ_DISTINCT_DICTARM, bv.len(), 0, False
                    )
                    return False
                var _i = 0
                var _eq = True
                while _i < stored_n:
                    if bv.read_u8_at(_i) != self.data[base + _i]:
                        _eq = False
                        break
                    _i += 1
                keyeq_record(KEYEQ_DISTINCT_DICTARM, stored_n, _i, _eq)
                return _eq
            var sv = batch.col_str(read_col).get(row)
            var n = sv.length()
            if n != stored_n:
                keyeq_record(KEYEQ_DISTINCT_DENSEARM, n, 0, False)
                return False
            var _j = 0
            var _eqd = True
            while _j < n:
                if sv.byte_at(_j) != self.data[base + _j]:
                    _eqd = False
                    break
                _j += 1
            keyeq_record(KEYEQ_DISTINCT_DENSEARM, n, _j, _eqd)
            return _eqd
        except e:
            abort(String("DistinctKeyColumn_String._equals: ") + String(e))

    @always_inline
    def hash_step[bo: Origin[mut=False]](
        self, state: UInt64, batch: BatchView[bo], row: Int
    ) -> UInt64:
        return self._hash_bytes_of[bo](state, batch, Self.col, row)

    @always_inline
    def row_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        return batch.col_is_null(Self.col, row)

    @always_inline
    def equals_row[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], row: Int
    ) -> Bool:
        return self._equals_bytes[bo](stored_idx, batch, Self.col, row)

    @always_inline
    def append_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        self._append_bytes_from[bo](batch, Self.col, row)

    # --- BAND reads:
    #     BAND-read siblings. The byte-identity ANCHOR (§3.3a / §4.3): fold /
    #     compare / store a RESOLVED dict-entry ByteView with the SAME FNV-1a
    #     combinator (`_distinct_fnv1a_bytes_step`) + the SAME byte SoA the batch
    #     DICT arm of `_hash_bytes_of` / `_equals_bytes` / `_append_bytes_from`
    #     uses. Same resolved bytes -> same FNV-1a -> same salt/probe -> same
    #     directory bucket + same stored key => byte-identical to the batch path.

    @always_inline
    def hash_step_bytes(self, state: UInt64, bytes: ByteView[_]) -> UInt64:
        """Fold a resolved dict-entry ByteView into the running FNV-1a `state`
        (the dict arm of `_hash_bytes_of`, over PRE-resolved bytes)."""
        var h = state
        for i in range(bytes.len()):
            h = _distinct_fnv1a_bytes_step(h, bytes.read_u8_at(i))
        return h

    @always_inline
    def equals_row_bytes(self, stored_idx: Int, bytes: ByteView[_]) -> Bool:
        """True iff the stored string at `stored_idx` equals a resolved dict-entry
        ByteView (byte-length + memcmp — the dict arm of `_equals_bytes`)."""
        var stored_n = self._len_of(stored_idx)
        if bytes.len() != stored_n:
            keyeq_record(KEYEQ_DISTINCT_ROWBYTES, bytes.len(), 0, False)
            return False
        var base = self.offsets[stored_idx]
        var _i = 0
        var _eq = True
        while _i < stored_n:
            if bytes.read_u8_at(_i) != self.data[base + _i]:
                _eq = False
                break
            _i += 1
        keyeq_record(KEYEQ_DISTINCT_ROWBYTES, stored_n, _i, _eq)
        return _eq

    @always_inline
    def append_row_bytes(mut self, bytes: ByteView[_]):
        """Append a resolved dict-entry ByteView as one stored distinct value
        (the dict arm of `_append_bytes_from`). Stored as RESOLVED bytes —
        cross-RG-canonical for free, and byte-identical to the dense/dict batch
        path's stored key."""
        for i in range(bytes.len()):
            self.data.append(bytes.read_u8_at(i))
        self.offsets.append(len(self.data))

    @always_inline
    def hash_step_band[o: Origin[mut=False]](
        self, state: UInt64, band: BandView[o], row: Int
    ) -> UInt64:
        """Resolve dict column `Self.col`'s code at `row` -> bytes, fold via
        `hash_step_bytes` (byte-identical to `hash_step` over the same bytes)."""
        try:
            return self.hash_step_bytes(
                state, band.resolve_string(Self.col, row)
            )
        except e:
            abort(String("DistinctKeyColumn_String.hash_step_band: ") + String(e))
            return state

    @always_inline
    def equals_row_band[o: Origin[mut=False]](
        self, stored_idx: Int, band: BandView[o], row: Int
    ) -> Bool:
        """Resolve dict column `Self.col`'s code at `row` -> bytes, compare via
        `equals_row_bytes`."""
        try:
            return self.equals_row_bytes(
                stored_idx, band.resolve_string(Self.col, row)
            )
        except e:
            abort(String("DistinctKeyColumn_String.equals_row_band: ") + String(e))
            return False

    @always_inline
    def append_row_band[o: Origin[mut=False]](
        mut self, band: BandView[o], row: Int
    ):
        """Resolve dict column `Self.col`'s code at `row` -> bytes, store via
        `append_row_bytes`."""
        try:
            self.append_row_bytes(band.resolve_string(Self.col, row))
        except e:
            abort(String("DistinctKeyColumn_String.append_row_band: ") + String(e))

    @always_inline
    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        self._append_bytes_from[bo](batch, spill_col, row)

    @always_inline
    def restore_hash_step[bo: Origin[mut=False]](
        self, state: UInt64, batch: BatchView[bo], spill_col: Int, row: Int
    ) -> UInt64:
        return self._hash_bytes_of[bo](state, batch, spill_col, row)

    @always_inline
    def restore_equals_row[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], spill_col: Int, row: Int
    ) -> Bool:
        return self._equals_bytes[bo](stored_idx, batch, spill_col, row)

    @always_inline
    def clear_values(mut self):
        self.data.clear()
        self.offsets.clear()
        self.offsets.append(0)

    @always_inline
    def append_stored_from(mut self, other: Self, other_idx: Int):
        """Copy `other`'s stored byte slice at dense index `other_idx` into this
        column's flat data buffer + push the new end-offset (the byte-SoA mirror
        of the numeric `append_stored_from`)."""
        var base = other.offsets[other_idx]
        var n = other.offsets[other_idx + 1] - base
        for i in range(n):
            self.data.append(other.data[base + i])
        self.offsets.append(len(self.data))

    @always_inline
    def equals_stored(
        self, stored_idx: Int, other: Self, other_idx: Int
    ) -> Bool:
        """Byte-length + memcmp over this column's stored slice at `stored_idx`
        vs `other`'s stored slice at `other_idx`."""
        var n = self._len_of(stored_idx)
        var on = other.offsets[other_idx + 1] - other.offsets[other_idx]
        if n != on:
            return False
        var sbase = self.offsets[stored_idx]
        var obase = other.offsets[other_idx]
        var _i = 0
        var _eq = True
        while _i < n:
            if self.data[sbase + _i] != other.data[obase + _i]:
                _eq = False
                break
            _i += 1
        keyeq_record(KEYEQ_DISTINCT_COMBINE, n, _i, _eq)
        return _eq

    @always_inline
    def length(self) -> Int:
        return len(self.offsets) - 1

    def _to_string(self, stored_idx: Int) raises -> String:
        # Materialize the stored byte slice as a String — span EXACTLY the n
        # bytes (NO trailing NUL; a NUL would round-trip as "key\0" and break
        # byte-exact equality + the byte-identical-vs-untyped oracle). Mirrors
        # `StringView.to_string`.
        var n = self._len_of(stored_idx)
        var base = self.offsets[stored_idx]
        var bytes = List[UInt8]()
        for i in range(n):
            bytes.append(self.data[base + i])
        return String(StringSlice(unsafe_from_utf8=Span(bytes)))

    def emit_distinct_column(self, mut rb: RecordBatchBuilder):
        try:
            var n = self.length()
            var strs = List[String](capacity=n)
            for i in range(n):
                strs.append(self._to_string(i))
            var arr = StringArray.from_strings(strs)
            rb.add_column(Column.from_string(arr^))
        except e:
            # emit_distinct_column is non-raising on the trait; a UTF-8 decode
            # failure on a stored key is unreachable for well-formed string
            # input (bytes were copied verbatim off a valid Arrow column).
            abort(String("DistinctKeyColumn_String.emit: ") + String(e))

    def add_distinct_schema_field(self, mut sb: SchemaBuilder, k: Int):
        sb.add_field(Field(String("k") + String(k), ArrowType.STRING, True))

    def emit_at_offset_desc(self, k: Int) -> _EmitColDesc:
        """STRING key: kind=STRING, byte_width=4 (the Int32 offset-entry width)."""
        return _EmitColDesc(
            Field(String("k") + String(k), ArrowType.STRING, True),
            EMIT_KIND_STRING,
            4,
        )

    def emit_at_offset_data_bytes(self) -> Int:
        """This partition's total key-byte contribution — the flat SoA byte buffer
        length (all groups' key bytes are already contiguous in insertion order,
        so this is O(1), no scan). Equals `self.offsets[n]` (the last offset)."""
        return len(self.data)

    def emit_distinct_at_offset(
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_idx: Int,
        row_offset: Int,
        data_offset: Int,
    ) raises:
        """Two-phase string scatter into the shared final column:
          (1) memcpy this partition's contiguous key bytes into the shared DATA
              buffer at `data_offset` (the prefix-sum byte offset);
          (2) write this partition's `n` START offsets (rebased by `data_offset`)
              at `offsets[row_offset .. row_offset+n)`.
        The shared `offsets[total]` sentinel (= total data bytes) is written ONCE
        by the orchestrator, so no two partitions write the same offset entry —
        the writes are strictly disjoint (the task's NO-cross-partition-race
        invariant). Byte-identical to the string emit -> concat: the stored SoA
        bytes ARE the emitted bytes (verbatim off the input column), same order."""
        var n = len(slots)
        # Phase 1: contiguous byte memcpy at the partition's data offset.
        var nb = len(self.data)
        if nb > 0:
            # SAFETY: `ByteView` over THIS column's OWN `List[UInt8]` data (origin
            # tied to `self.data`); consumed synchronously by the bounded
            # `copy_from_view_at` memcpy. No pointer crosses the module boundary —
            # `targets[col_idx].data` is written via its typed public buffer API.
            var src = ByteView(self.data.unsafe_ptr(), nb)
            targets[col_idx].data.copy_from_view_at(data_offset, src)
        # Phase 2: rebased start offsets for THIS partition's rows only.
        ref offs = targets[col_idx].offsets
        for si in range(n):
            offs.set_typed[Int32](
                row_offset + si, Int32(data_offset + self.offsets[slots[si]])
            )

