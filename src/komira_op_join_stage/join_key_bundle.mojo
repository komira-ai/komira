# =============================================================================
# join_key_bundle -- the key block of the stage join build table: the
# `KeyBundle` trait, its one conformer `KeyBundleVar[*Keys]` (one key column
# per pack element, any arity), the `KeyBundle1`..`KeyBundle4` aliases and
# their factories
# =============================================================================
#
# A composite key hashes to the XOR of its columns' `key_hash`es and is equal
# to another when every column is (each under the key model of
# join_key_slot). The table is open addressing with linear probing and does
# not deduplicate: every build row takes its own slot, so a probe that walks
# the whole run of occupied slots from the key's home slot sees every build
# row with that key (M:N). A run ends at the first empty slot.
#
# The batch-row entry points (`probe_batch_row`, `probe_batch_row_first`,
# `build_insert_row`) take up to four key columns as comptime parameters; a
# bundle of arity N reads the first N and ignores the rest. A NULL probe key
# matches nothing.
# =============================================================================

from komira_arrow.batch_view import BatchView

from komira_op_join_stage.join_key_slot import (
    KeyBlockWrap,
    KeyScalarTrait,
    KeySlot,
    key_slot,
)


@always_inline
def probe_key_any_null[
    bo: Origin[mut=False], n_arity: Int
](
    batch: BatchView[bo],
    probe_col0: Int,
    probe_col1: Int,
    probe_col2: Int,
    probe_col3: Int,
    row: Int,
) -> Bool:
    """True iff any of the first `n_arity` key columns is NULL at `row` (a
    NULL key matches nothing, not even another NULL)."""
    comptime if n_arity >= 1:
        if batch.col_is_null(probe_col0, row):
            return True
    comptime if n_arity >= 2:
        if batch.col_is_null(probe_col1, row):
            return True
    comptime if n_arity >= 3:
        if batch.col_is_null(probe_col2, row):
            return True
    comptime if n_arity >= 4:
        if batch.col_is_null(probe_col3, row):
            return True
    return False


trait KeyBundle(Defaultable, Movable, Deinitable):
    """The key block a `JoinBuildTable[KB, *Payload]` holds. A generic body
    over `KB: KeyBundle` reaches the key columns only through these methods.
    The batch-row methods take four key-column parameters; a bundle of arity
    N reads the first N."""

    @staticmethod
    def arity() -> Int:
        """The number of key columns."""
        ...

    def slot_is_empty(self, slot: Int) -> Bool:
        """True iff no key was written at `slot`."""
        ...

    def slot_hash(self, slot: Int) -> UInt64:
        """The composite hash of the key at `slot`."""
        ...

    def key_i64_at_slot[k: Int](self, slot: Int) -> Int64:
        """Key column `k` at `slot` as `Int64(value)` (a numeric cast)."""
        ...

    def key_bits_at_slot[k: Int](self, slot: Int) -> UInt64:
        """Key column `k` at `slot` as its own bits (`key_bits_of`)."""
        ...

    @staticmethod
    def key_dtype[k: Int]() -> DType:
        """The DType of key column `k`."""
        ...

    def rehash_keys_in_place(mut self, new_capacity: Int, remap: List[Int]):
        """Rehash every key column to `new_capacity` slots against `remap`."""
        ...

    def memory_size_bytes(self) -> Int:
        """The heap footprint of the key columns in bytes."""
        ...

    def probe_batch_row[
        bo: Origin[mut=False],
        probe_col0: Int,
        probe_col1: Int,
        probe_col2: Int,
        probe_col3: Int,
    ](
        self,
        batch: BatchView[bo],
        row: Int,
        capacity_mask: Int,
        has_dups: Bool,
        mut out_slots: List[Int],
    ) raises:
        """Append to `out_slots` the slots whose key equals the probe key of
        `row`: the first one when `has_dups` is False (N:1), every one when it
        is True (M:N). Appends nothing for a NULL probe key. Does not clear
        `out_slots`."""
        ...

    def probe_batch_row_first[
        bo: Origin[mut=False],
        probe_col0: Int,
        probe_col1: Int,
        probe_col2: Int,
        probe_col3: Int,
    ](
        self,
        batch: BatchView[bo],
        row: Int,
        capacity_mask: Int,
    ) raises -> Int:
        """The first slot whose key equals the probe key of `row`, or -1 (and
        -1 for a NULL probe key)."""
        ...

    def build_insert_row[
        bo: Origin[mut=False],
        key_col0: Int,
        key_col1: Int,
        key_col2: Int,
        key_col3: Int,
    ](
        mut self,
        batch: BatchView[bo],
        row: Int,
        mut n_used: Int,
        capacity_mask: Int,
        mut saw_duplicate: Bool,
    ) raises -> Int:
        """Insert the key of `row` into the first empty slot of its run and
        return that slot. Bumps `n_used`; sets `saw_duplicate` if an equal key
        is already in the run. The caller skips a NULL key and grows the table
        first, so an empty slot exists."""
        ...

    def insert_slot_from(
        mut self,
        src: Self,
        src_slot: Int,
        mut n_used: Int,
        capacity_mask: Int,
        mut saw_duplicate: Bool,
    ) -> Int:
        """`build_insert_row` for the key stored at `src[src_slot]` (the
        cross-table insert of `JoinBuildTable.combine`)."""
        ...


struct KeyBundleVar[*Keys: KeyScalarTrait](KeyBundle):
    """A key block of one `KeyScalarTrait` column per pack element. Movable,
    not copyable. Built from a `KeyBlockWrap` or, at the default capacity, by
    the no-argument constructor."""

    var cols: Tuple[*Self.Keys]

    def __init__(out self, var keys_block: KeyBlockWrap[*Self.Keys]):
        self.cols = keys_block.take()

    def __init__(out self):
        """Every column at `JOIN_BUILD_DEFAULT_CAP` empty slots."""
        self.cols = Tuple[*Self.Keys]()

    @staticmethod
    @always_inline
    def arity() -> Int:
        return Self.Keys.__len__()

    @always_inline
    def slot_is_empty(self, slot: Int) -> Bool:
        return self.cols[0].slot_is_empty(slot)

    @always_inline
    def slot_eq_loaded(self, slot: Int, other: Self, other_slot: Int) -> Bool:
        """True iff every key column at `self[slot]` equals the same column at
        `other[other_slot]`."""
        var ok = True
        comptime for k in range(Self.Keys.__len__()):
            if not self.cols[k].slot_eq_loaded(slot, other.cols[k], other_slot):
                ok = False
        return ok

    @always_inline
    def slot_hash(self, slot: Int) -> UInt64:
        var h: UInt64 = 0
        comptime for k in range(Self.Keys.__len__()):
            h = h ^ self.cols[k].hash_slot(slot)
        return h

    @always_inline
    def key_i64_at_slot[k: Int](self, slot: Int) -> Int64:
        return self.cols[k].read_slot_i64(slot)

    @always_inline
    def key_bits_at_slot[k: Int](self, slot: Int) -> UInt64:
        return self.cols[k].read_slot_bits(slot)

    @staticmethod
    @always_inline
    def key_dtype[k: Int]() -> DType:
        return Self.Keys[k].DT

    def write_slot_from(mut self, slot: Int, src: Self, src_slot: Int):
        """Copy every key column of `src[src_slot]` into `self[slot]`."""
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].write_slot_from(slot, src.cols[k], src_slot)

    def rehash_keys_in_place(mut self, new_capacity: Int, remap: List[Int]):
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].rehash_in_place(new_capacity, remap)

    def memory_size_bytes(self) -> Int:
        var total = 0
        comptime for k in range(Self.Keys.__len__()):
            total += self.cols[k].memory_size_bytes()
        return total

    # -------------------------------------------------------------------------
    # The batch-row entry points. Each reads the key of one row as up to four
    # bit patterns (`_row_bits`), hashes them (`_bits_hash`) and compares them
    # against a slot (`_slot_eq_bits`), all through the column conformers.
    # -------------------------------------------------------------------------

    @always_inline
    def _row_bits[
        bo: Origin[mut=False], c0: Int, c1: Int, c2: Int, c3: Int
    ](self, batch: BatchView[bo], row: Int) raises -> SIMD[DType.uint64, 4]:
        comptime n_arity = Self.Keys.__len__()
        comptime assert n_arity <= 4, (
            "KeyBundleVar: the batch-row entry points read at most four key"
            " columns"
        )
        var bits = SIMD[DType.uint64, 4](0)
        comptime if n_arity >= 1:
            bits[0] = self.cols[0].read_key_bits_from_batch[bo](batch, c0, row)
        comptime if n_arity >= 2:
            bits[1] = self.cols[1].read_key_bits_from_batch[bo](batch, c1, row)
        comptime if n_arity >= 3:
            bits[2] = self.cols[2].read_key_bits_from_batch[bo](batch, c2, row)
        comptime if n_arity >= 4:
            bits[3] = self.cols[3].read_key_bits_from_batch[bo](batch, c3, row)
        return bits

    @always_inline
    def _bits_hash(self, bits: SIMD[DType.uint64, 4]) -> UInt64:
        var h: UInt64 = 0
        comptime for k in range(Self.Keys.__len__()):
            h = h ^ self.cols[k].hash_bits(bits[k])
        return h

    @always_inline
    def _slot_eq_bits(self, slot: Int, bits: SIMD[DType.uint64, 4]) -> Bool:
        var eq = True
        comptime for k in range(Self.Keys.__len__()):
            if eq and not self.cols[k].eq_slot_to_bits(slot, bits[k]):
                eq = False
        return eq

    def probe_batch_row[
        bo: Origin[mut=False],
        probe_col0: Int,
        probe_col1: Int,
        probe_col2: Int,
        probe_col3: Int,
    ](
        self,
        batch: BatchView[bo],
        row: Int,
        capacity_mask: Int,
        has_dups: Bool,
        mut out_slots: List[Int],
    ) raises:
        if not has_dups:
            var first = self.probe_batch_row_first[
                bo, probe_col0, probe_col1, probe_col2, probe_col3
            ](batch, row, capacity_mask)
            if first >= 0:
                out_slots.append(first)
            return
        comptime n_arity = Self.Keys.__len__()
        if probe_key_any_null[bo, n_arity](
            batch, probe_col0, probe_col1, probe_col2, probe_col3, row
        ):
            return
        var bits = self._row_bits[
            bo, probe_col0, probe_col1, probe_col2, probe_col3
        ](batch, row)
        var slot = Int(self._bits_hash(bits) & UInt64(capacity_mask))
        var first = slot
        while True:
            if self.cols[0].slot_is_empty(slot):
                return
            if self._slot_eq_bits(slot, bits):
                out_slots.append(slot)
            slot = (slot + 1) & capacity_mask
            if slot == first:
                return

    def probe_batch_row_first[
        bo: Origin[mut=False],
        probe_col0: Int,
        probe_col1: Int,
        probe_col2: Int,
        probe_col3: Int,
    ](
        self,
        batch: BatchView[bo],
        row: Int,
        capacity_mask: Int,
    ) raises -> Int:
        comptime n_arity = Self.Keys.__len__()
        if probe_key_any_null[bo, n_arity](
            batch, probe_col0, probe_col1, probe_col2, probe_col3, row
        ):
            return -1
        var bits = self._row_bits[
            bo, probe_col0, probe_col1, probe_col2, probe_col3
        ](batch, row)
        var slot = Int(self._bits_hash(bits) & UInt64(capacity_mask))
        var probe_count = 0
        while probe_count <= capacity_mask:
            if self.cols[0].slot_is_empty(slot):
                return -1
            if self._slot_eq_bits(slot, bits):
                return slot
            slot = (slot + 1) & capacity_mask
            probe_count = probe_count + 1
        return -1

    def build_insert_row[
        bo: Origin[mut=False],
        key_col0: Int,
        key_col1: Int,
        key_col2: Int,
        key_col3: Int,
    ](
        mut self,
        batch: BatchView[bo],
        row: Int,
        mut n_used: Int,
        capacity_mask: Int,
        mut saw_duplicate: Bool,
    ) raises -> Int:
        var bits = self._row_bits[bo, key_col0, key_col1, key_col2, key_col3](
            batch, row
        )
        var slot = Int(self._bits_hash(bits) & UInt64(capacity_mask))
        while not self.cols[0].slot_is_empty(slot):
            if self._slot_eq_bits(slot, bits):
                saw_duplicate = True
            slot = (slot + 1) & capacity_mask
        comptime for k in range(Self.Keys.__len__()):
            self.cols[k].write_bits_to_slot(slot, bits[k])
        n_used = n_used + 1
        return slot

    def insert_slot_from(
        mut self,
        src: Self,
        src_slot: Int,
        mut n_used: Int,
        capacity_mask: Int,
        mut saw_duplicate: Bool,
    ) -> Int:
        var slot = Int(src.slot_hash(src_slot) & UInt64(capacity_mask))
        while not self.cols[0].slot_is_empty(slot):
            if self.slot_eq_loaded(slot, src, src_slot):
                saw_duplicate = True
            slot = (slot + 1) & capacity_mask
        self.write_slot_from(slot, src, src_slot)
        n_used = n_used + 1
        return slot


comptime KeyBundle1[K0: DType] = KeyBundleVar[KeySlot[K0]]
"""A one-column key block."""

comptime KeyBundle2[K0: DType, K1: DType] = KeyBundleVar[
    KeySlot[K0], KeySlot[K1]
]
"""A two-column key block."""

comptime KeyBundle3[K0: DType, K1: DType, K2: DType] = KeyBundleVar[
    KeySlot[K0], KeySlot[K1], KeySlot[K2]
]
"""A three-column key block."""

comptime KeyBundle4[K0: DType, K1: DType, K2: DType, K3: DType] = KeyBundleVar[
    KeySlot[K0], KeySlot[K1], KeySlot[K2], KeySlot[K3]
]
"""A four-column key block."""


@always_inline
def make_key_bundle_1[K0: DType](capacity: Int) -> KeyBundle1[K0]:
    """A one-column key block of `capacity` empty slots."""
    return KeyBundleVar[KeySlot[K0]](
        KeyBlockWrap[KeySlot[K0]](key_slot[K0](capacity))
    )


@always_inline
def make_key_bundle_2[
    K0: DType, K1: DType
](capacity: Int) -> KeyBundle2[K0, K1]:
    """A two-column key block of `capacity` empty slots."""
    return KeyBundleVar[KeySlot[K0], KeySlot[K1]](
        KeyBlockWrap[KeySlot[K0], KeySlot[K1]](
            key_slot[K0](capacity), key_slot[K1](capacity)
        )
    )


@always_inline
def make_key_bundle_3[
    K0: DType, K1: DType, K2: DType
](capacity: Int) -> KeyBundle3[K0, K1, K2]:
    """A three-column key block of `capacity` empty slots."""
    return KeyBundleVar[KeySlot[K0], KeySlot[K1], KeySlot[K2]](
        KeyBlockWrap[KeySlot[K0], KeySlot[K1], KeySlot[K2]](
            key_slot[K0](capacity),
            key_slot[K1](capacity),
            key_slot[K2](capacity),
        )
    )


@always_inline
def make_key_bundle_4[
    K0: DType, K1: DType, K2: DType, K3: DType
](capacity: Int) -> KeyBundle4[K0, K1, K2, K3]:
    """A four-column key block of `capacity` empty slots."""
    return KeyBundleVar[KeySlot[K0], KeySlot[K1], KeySlot[K2], KeySlot[K3]](
        KeyBlockWrap[KeySlot[K0], KeySlot[K1], KeySlot[K2], KeySlot[K3]](
            key_slot[K0](capacity),
            key_slot[K1](capacity),
            key_slot[K2](capacity),
            key_slot[K3](capacity),
        )
    )
