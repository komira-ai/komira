# =============================================================================
# key_block.mojo — the GROUP BY key block of the stage hash aggregation
# =============================================================================
#
# `KeyTuple` is the key half of `HashAggTable[KB, *Aggs]`. A key block maps a
# row's composite GROUP BY key to a DENSE group index (0, 1, 2, ... in
# first-seen order) and stores each group's key values; the table indexes the
# per-group aggregate states with that index. Two conformers:
#
#   * `KeyTupleScalar` — no keys: the one group of an ungrouped aggregate.
#   * `AggKeyBlock[*Keys]` — one or more key columns (`DistinctKeyColumn`
#     conformers from `komira_op_agg_distinct`: numeric and STRING keys). The
#     composite key is hashed with FNV-1a (the same combinator `DistinctState`
#     uses) and looked up in a growable salt-packed open-addressing directory
#     (`_DistinctDirectory`); the directory grows, so the group count has no cap.
#
# NULL keys. A key column's NULL is one key value, as in DuckDB: every row whose
# key k is NULL lands in the same group as every other row with the same NULL
# pattern and equal non-NULL keys. Each group stores a NULL mask (bit k = key k
# is NULL); a NULL key folds a fixed word into the hash instead of the data
# under it, equality compares the masks before the non-NULL values, and the
# key column stores a placeholder for it. The drain emits those keys as NULL.
#
# The per-key work stays inside the key column conformers (the block fans over
# the key pack with `comptime for`, calling only `DistinctKeyColumn` methods),
# so `HashAggTable` drives any key arity without naming a key type.
# =============================================================================

from std.collections import List

from komira_arrow.batch_view import BatchView
from komira_arrow.band_view import BandView
from komira_arrow.schema import RecordBatchBuilder, SchemaBuilder

from komira_operator_api.emit_at_offset_target import (
    _EmitColDesc,
    _EmitColTarget,
    EMIT_KIND_INELIGIBLE,
)
from komira_op_agg_distinct.distinct_key_column import (
    DISTINCT_FNV_OFFSET,
    DISTINCT_FNV_PRIME,
    DistinctKeyColumn,
    DistinctKeyColumn_Typed,
    _DISTINCT_EMPTY_SLOT,
    _DISTINCT_IDX_MASK,
    _DISTINCT_SALT_SHIFT,
    _distinct_salt_of,
    _distinct_salt_stride,
)
from komira_op_agg_distinct.distinct_state import _DistinctDirectory


comptime _NULL_KEY_WORD: UInt64 = 0x9E3779B97F4A7C15
"""The word a NULL key folds into the composite hash in place of a value. It
may collide with a value's hash; equality compares the NULL masks first, so a
collision costs a probe step, never a wrong group."""


trait KeyTuple(Movable, Deinitable):
    """A growable block of GROUP BY key columns. `ARITY` is the key count.

    `feed_lookup` returns the row's dense group index and bumps `n_used` when
    the key is new; the owning table compares `n_used` before and after to grow
    its per-group aggregate states in lockstep."""

    comptime ARITY: Int

    @staticmethod
    def make() -> Self:
        """An empty block."""
        ...

    def reset(mut self):
        """Drop every group."""
        ...

    def feed_lookup[bo: Origin[mut=False]](
        mut self, mut n_used: Int, batch: BatchView[bo], row: Int
    ) -> Int:
        """Look up or insert `row`'s composite key; return its dense index."""
        ...

    def feed_lookup_band[o: Origin[mut=False]](
        mut self, mut n_used: Int, band: BandView[o], row: Int
    ) -> Int:
        """`feed_lookup` over a band's decoded spans: the same directory, the
        same hash of the same key bytes, so the same groups in the same order.
        A band carries no validity, so its keys are never NULL."""
        ...

    def emit_key_columns(
        self, slots: List[Int], mut rb: RecordBatchBuilder
    ) raises:
        """Append one column per key, in key order and native type, over the
        groups `slots` (always every group, in dense order)."""
        ...

    def add_key_schema_fields(self, mut sb: SchemaBuilder):
        """Append the key fields `k0`..`kN-1` (nullable) to the schema."""
        ...

    def is_occupied(self, slot: Int) -> Bool:
        """True iff `slot` is a live group. The 0-key block answers False (its
        one group's liveness is the table's `n_used`)."""
        ...

    def reinsert_from(
        mut self, mut n_used: Int, other: Self, other_slot: Int
    ) -> Int:
        """Look up or insert `other`'s group `other_slot` BY KEY VALUE; return
        its dense index here. The cross-worker merge: two blocks number their
        groups independently, so a fold by raw index would mix groups."""
        ...

    def cached_hash_at(self, slot: Int) -> UInt64:
        """The composite key hash of group `slot` (the same on every worker for
        the same key), which routes the group to a combine partition."""
        ...

    def has_null_keys(self) -> Bool:
        """True iff some group has a NULL key."""
        ...

    # --- the drain-at-offset surface (see `HashAggTable.emit_at_offset_plan`)

    def plan_key_cols(self, mut descs: List[_EmitColDesc]):
        """Append one `_EmitColDesc` per key column, in key order. A block
        holding a NULL key marks its columns INELIGIBLE (the targets carry no
        validity)."""
        ...

    def key_data_bytes(self, mut out: List[Int]):
        """Append each key column's variable data bytes (STRING: its byte
        length; fixed width: 0), in key order."""
        ...

    def emit_keys_at_offset[do: Origin[mut=False]](
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_base: Int,
        row_offset: Int,
        ref [do] data_offsets: List[Int],
        data_base: Int,
    ) raises:
        """Write key column k into `targets[col_base + k]` at `row_offset`;
        `data_offsets[data_base + col_base + k]` is its byte offset (STRING).
        Raises on a NULL key."""
        ...


struct KeyTupleScalar(KeyTuple):
    """The zero-key block of an ungrouped aggregate: one group, index 0."""

    comptime ARITY: Int = 0

    def __init__(out self):
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        return Self()

    @always_inline
    def reset(mut self):
        pass

    @always_inline
    def feed_lookup[bo: Origin[mut=False]](
        mut self, mut n_used: Int, batch: BatchView[bo], row: Int
    ) -> Int:
        if n_used == 0:
            n_used = 1
        return 0

    @always_inline
    def feed_lookup_band[o: Origin[mut=False]](
        mut self, mut n_used: Int, band: BandView[o], row: Int
    ) -> Int:
        if n_used == 0:
            n_used = 1
        return 0

    def emit_key_columns(
        self, slots: List[Int], mut rb: RecordBatchBuilder
    ) raises:
        pass

    def add_key_schema_fields(self, mut sb: SchemaBuilder):
        pass

    @always_inline
    def is_occupied(self, slot: Int) -> Bool:
        return False

    @always_inline
    def reinsert_from(
        mut self, mut n_used: Int, other: Self, other_slot: Int
    ) -> Int:
        if n_used == 0:
            n_used = 1
        return 0

    @always_inline
    def cached_hash_at(self, slot: Int) -> UInt64:
        return UInt64(0)

    @always_inline
    def has_null_keys(self) -> Bool:
        return False

    def plan_key_cols(self, mut descs: List[_EmitColDesc]):
        pass

    def key_data_bytes(self, mut out: List[Int]):
        pass

    def emit_keys_at_offset[do: Origin[mut=False]](
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_base: Int,
        row_offset: Int,
        ref [do] data_offsets: List[Int],
        data_base: Int,
    ) raises:
        pass


struct AggKeyBlock[*Keys: DistinctKeyColumn](KeyTuple):
    """One or more GROUP BY key columns over a growable directory.

    Storage: `key_cols` (one `DistinctKeyColumn` per key, each holding its
    key's value per group, in dense order), `_dir` (composite hash -> dense
    index, plus each group's cached hash) and `null_masks` (per group, bit k
    set when key k is NULL)."""

    comptime ARITY: Int = Self.Keys.__len__()

    var key_cols: Tuple[*Self.Keys]
    var _dir: _DistinctDirectory
    var null_masks: List[UInt64]
    var n_null_groups: Int
    """The number of groups with at least one NULL key."""

    def __init__(out self):
        comptime assert Self.ARITY <= 64, "AggKeyBlock: at most 64 keys"
        self.key_cols = Tuple[*Self.Keys]()
        self._dir = _DistinctDirectory.new()
        self.null_masks = List[UInt64]()
        self.n_null_groups = 0

    @staticmethod
    @always_inline
    def make() -> Self:
        return Self()

    @always_inline
    def reset(mut self):
        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].clear_values()
        self._dir.clear()
        self.null_masks.clear()
        self.n_null_groups = 0

    @always_inline
    def _null_mask[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> UInt64:
        var m = UInt64(0)
        comptime for k in range(Self.Keys.__len__()):
            if self.key_cols[k].is_null_row[bo](batch, row):
                m = m | (UInt64(1) << UInt64(k))
        return m

    @always_inline
    def _hash_row[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, mask: UInt64
    ) -> UInt64:
        """FNV-1a over the key pack. With no NULL key it is `DistinctState`'s
        row hash, so a group lands in the same bucket on every path."""
        var h = DISTINCT_FNV_OFFSET
        comptime for k in range(Self.Keys.__len__()):
            if (mask >> UInt64(k)) & 1 == 1:
                h = (h ^ _NULL_KEY_WORD) * DISTINCT_FNV_PRIME
            else:
                h = self.key_cols[k].hash_step[bo](h, batch, row)
        return h

    @always_inline
    def _row_equals_stored[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], row: Int, mask: UInt64
    ) -> Bool:
        if self.null_masks[stored_idx] != mask:
            return False
        comptime for k in range(Self.Keys.__len__()):
            if (mask >> UInt64(k)) & 1 == 0:
                if not self.key_cols[k].equals_row[bo](stored_idx, batch, row):
                    return False
        return True

    @always_inline
    def _commit_mask(mut self, mask: UInt64):
        self.null_masks.append(mask)
        if mask != 0:
            self.n_null_groups += 1

    @always_inline
    def feed_lookup[bo: Origin[mut=False]](
        mut self, mut n_used: Int, batch: BatchView[bo], row: Int
    ) -> Int:
        var mask = self._null_mask[bo](batch, row)
        var h = self._hash_row[bo](batch, row, mask)
        self._dir.maybe_grow()
        var salt = _distinct_salt_of(h)
        var dmask = UInt64(self._dir.capacity - 1)
        var stride = _distinct_salt_stride(salt, dmask)
        var slot = h & dmask
        while True:
            var word = self._dir.directory[Int(slot)]
            if word == _DISTINCT_EMPTY_SLOT:
                var dense_idx = self._dir.n_used
                comptime for k in range(Self.Keys.__len__()):
                    if (mask >> UInt64(k)) & 1 == 1:
                        self.key_cols[k].append_null_placeholder()
                    else:
                        self.key_cols[k].append_row[bo](batch, row)
                self._commit_mask(mask)
                self._dir.commit_insert(slot, salt, h)
                n_used = n_used + 1
                return dense_idx
            if (word >> UInt64(_DISTINCT_SALT_SHIFT)) == salt:
                var stored_idx = Int(word & _DISTINCT_IDX_MASK)
                if self._row_equals_stored[bo](stored_idx, batch, row, mask):
                    return stored_idx
            slot = (slot + stride) & dmask

    @always_inline
    def _hash_row_band[o: Origin[mut=False]](
        self, band: BandView[o], row: Int
    ) -> UInt64:
        var h = DISTINCT_FNV_OFFSET
        comptime for k in range(Self.Keys.__len__()):
            h = self.key_cols[k].hash_step_band[o](h, band, row)
        return h

    @always_inline
    def _row_equals_stored_band[o: Origin[mut=False]](
        self, stored_idx: Int, band: BandView[o], row: Int
    ) -> Bool:
        if self.null_masks[stored_idx] != 0:
            return False
        comptime for k in range(Self.Keys.__len__()):
            if not self.key_cols[k].equals_row_band[o](stored_idx, band, row):
                return False
        return True

    @always_inline
    def feed_lookup_band[o: Origin[mut=False]](
        mut self, mut n_used: Int, band: BandView[o], row: Int
    ) -> Int:
        var h = self._hash_row_band[o](band, row)
        self._dir.maybe_grow()
        var salt = _distinct_salt_of(h)
        var dmask = UInt64(self._dir.capacity - 1)
        var stride = _distinct_salt_stride(salt, dmask)
        var slot = h & dmask
        while True:
            var word = self._dir.directory[Int(slot)]
            if word == _DISTINCT_EMPTY_SLOT:
                var dense_idx = self._dir.n_used
                comptime for k in range(Self.Keys.__len__()):
                    self.key_cols[k].append_row_band[o](band, row)
                self._commit_mask(0)
                self._dir.commit_insert(slot, salt, h)
                n_used = n_used + 1
                return dense_idx
            if (word >> UInt64(_DISTINCT_SALT_SHIFT)) == salt:
                var stored_idx = Int(word & _DISTINCT_IDX_MASK)
                if self._row_equals_stored_band[o](stored_idx, band, row):
                    return stored_idx
            slot = (slot + stride) & dmask

    def emit_key_columns(
        self, slots: List[Int], mut rb: RecordBatchBuilder
    ) raises:
        """Every group's keys, in dense order (`slots` is that range)."""
        comptime for k in range(Self.Keys.__len__()):
            var has_null = False
            if self.n_null_groups > 0:
                for g in range(len(self.null_masks)):
                    if (self.null_masks[g] >> UInt64(k)) & 1 == 1:
                        has_null = True
                        break
            if not has_null:
                self.key_cols[k].emit_distinct_column(rb)
            else:
                var valid = List[Bool](capacity=len(self.null_masks))
                for g in range(len(self.null_masks)):
                    valid.append((self.null_masks[g] >> UInt64(k)) & 1 == 0)
                self.key_cols[k].emit_distinct_column_with_nulls(valid, rb)

    def add_key_schema_fields(self, mut sb: SchemaBuilder):
        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].add_distinct_schema_field(sb, k)

    @always_inline
    def is_occupied(self, slot: Int) -> Bool:
        return slot < self._dir.n_used

    @always_inline
    def n_groups(self) -> Int:
        return self._dir.n_used

    @always_inline
    def cached_hash_at(self, slot: Int) -> UInt64:
        return self._dir.cached_hash[slot]

    @always_inline
    def has_null_keys(self) -> Bool:
        return self.n_null_groups > 0

    def plan_key_cols(self, mut descs: List[_EmitColDesc]):
        comptime for k in range(Self.Keys.__len__()):
            var d = self.key_cols[k].emit_at_offset_desc(k)
            if self.n_null_groups > 0:
                d.kind = EMIT_KIND_INELIGIBLE
            descs.append(d^)

    def key_data_bytes(self, mut out: List[Int]):
        comptime for k in range(Self.Keys.__len__()):
            out.append(self.key_cols[k].emit_at_offset_data_bytes())

    def emit_keys_at_offset[do: Origin[mut=False]](
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_base: Int,
        row_offset: Int,
        ref [do] data_offsets: List[Int],
        data_base: Int,
    ) raises:
        if self.n_null_groups > 0:
            raise Error(
                "AggKeyBlock.emit_keys_at_offset: a group has a NULL key and"
                " the drain-at-offset targets carry no validity; drain this"
                " table with drain_to_record_batch"
            )
        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].emit_distinct_at_offset(
                slots,
                targets,
                col_base + k,
                row_offset,
                data_offsets[data_base + col_base + k],
            )

    @always_inline
    def reinsert_from(
        mut self, mut n_used: Int, other: Self, other_slot: Int
    ) -> Int:
        var h = other._dir.cached_hash[other_slot]
        var mask = other.null_masks[other_slot]
        self._dir.maybe_grow()
        var salt = _distinct_salt_of(h)
        var dmask = UInt64(self._dir.capacity - 1)
        var stride = _distinct_salt_stride(salt, dmask)
        var slot = h & dmask
        while True:
            var word = self._dir.directory[Int(slot)]
            if word == _DISTINCT_EMPTY_SLOT:
                var dense_idx = self._dir.n_used
                comptime for k in range(Self.Keys.__len__()):
                    self.key_cols[k].append_stored_from(
                        other.key_cols[k], other_slot
                    )
                self._commit_mask(mask)
                self._dir.commit_insert(slot, salt, h)
                n_used = n_used + 1
                return dense_idx
            if (word >> UInt64(_DISTINCT_SALT_SHIFT)) == salt:
                var stored_idx = Int(word & _DISTINCT_IDX_MASK)
                if self._other_equals_stored(
                    stored_idx, other, other_slot, mask
                ):
                    return stored_idx
            slot = (slot + stride) & dmask

    @always_inline
    def _other_equals_stored(
        self, stored_idx: Int, other: Self, other_slot: Int, mask: UInt64
    ) -> Bool:
        if self.null_masks[stored_idx] != mask:
            return False
        comptime for k in range(Self.Keys.__len__()):
            if (mask >> UInt64(k)) & 1 == 0:
                if not self.key_cols[k].equals_stored(
                    stored_idx, other.key_cols[k], other_slot
                ):
                    return False
        return True


# The fixed-arity spellings over the one variadic block (numeric keys).
comptime KeyTuple1[d0: DType, col0: Int] = AggKeyBlock[
    DistinctKeyColumn_Typed[d0, col0]
]
comptime KeyTuple2[d0: DType, col0: Int, d1: DType, col1: Int] = AggKeyBlock[
    DistinctKeyColumn_Typed[d0, col0], DistinctKeyColumn_Typed[d1, col1]
]
comptime KeyTuple3[
    d0: DType, col0: Int, d1: DType, col1: Int, d2: DType, col2: Int
] = AggKeyBlock[
    DistinctKeyColumn_Typed[d0, col0],
    DistinctKeyColumn_Typed[d1, col1],
    DistinctKeyColumn_Typed[d2, col2],
]
