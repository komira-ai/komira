# =============================================================================
# join_build_table -- `JoinBuildTable[KB, *Payload]`, the typed hash-join
# build table of the engine's stage pipelines (its per-arity free functions
# over typed key values are in join_build_table_fns)
# =============================================================================
#
# One variadic struct covers every key arity and payload shape: the key axis
# is the `KB: KeyBundle` type parameter (`KeyBundle1`..`KeyBundle4`, or any
# `KeyBundleVar[*Keys]`), the payload axis the `*Payload` pack (a parameter
# list holds one variadic pack, so the keys fold into `KB`).
#
# Storage is open addressing with linear probing over slot-indexed columns
# (join_key_slot, join_payload_column). An insert does not deduplicate: every
# build row takes its own slot (M:N), and `has_duplicate_keys` records whether
# two equal keys were ever inserted, so a probe can take the first match only
# when it is the only one. The table doubles and rehashes before an insert
# would pass a load of 3/4 (`_maybe_grow`), moving the key and payload columns
# in lockstep; a slot's row is never split.
#
# Hash and equality follow the key model of join_key_slot (every value a key,
# float keys under the float model). The batch-row path (`KeyBundleVar`) and
# the free functions hash the same way, so a table built through either is
# probed correctly through either, before and after a rehash.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_arrow.schema import RecordBatch
from komira_expr.stage_program import BREAKER_JOIN_PROBE
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from komira_op_join_stage.join_key_slot import (
    JOIN_BUILD_DEFAULT_CAP,
    key_home,
    round_up_pow2,
)
from komira_op_join_stage.join_key_bundle import KeyBundle
from komira_op_join_stage.join_payload_column import (
    PayloadBlock,
    PayloadColumn,
)


struct JoinBuildTable[
    KB: KeyBundle, *Payload: PayloadColumn
](Movable, BreakerStateCombinable):
    """A hash-join build table: an N-column key block and M payload columns,
    open addressing with linear probing, one slot per build row.

    Movable, not copyable. Built from a key block and a `PayloadBlock` sized
    to the same capacity, or (nullary payload) at `JOIN_BUILD_DEFAULT_CAP`:

        JoinBuildTable[KeyBundle1[DType.int64], PayloadSlot[DType.int64]](
            make_key_bundle_1[DType.int64](64),
            PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](64)),
            initial_capacity=64,
        )

    As a `BreakerState` it is the build primitive, not a pipeline state:
    `feed_row`, `drain_to_record_batch`, `probe_batch` and `probe_asof_batch`
    raise: a pipeline drives the table through the join's build and probe
    states, not through these methods. Its `combine` is the cross-worker
    merge those states use."""

    var keys: Self.KB
    var payload: Tuple[*Self.Payload]
    var capacity_mask: Int
    var n_used: Int
    var has_duplicate_keys: Bool
    """True once two equal keys were inserted: a probe must then walk every
    match, not stop at the first."""

    def __init__(
        out self,
        var keys: Self.KB,
        var payload_block: PayloadBlock[*Self.Payload],
        initial_capacity: Int = JOIN_BUILD_DEFAULT_CAP,
    ):
        """An empty table of `round_up_pow2(initial_capacity)` slots. `keys`
        and every payload column must have exactly that many slots."""
        self.keys = keys^
        self.payload = payload_block.take()
        self.capacity_mask = round_up_pow2(initial_capacity) - 1
        self.n_used = 0
        self.has_duplicate_keys = False

    def __init__(out self, var keys: Self.KB):
        """An empty table of `JOIN_BUILD_DEFAULT_CAP` slots; the payload
        columns are built by their no-argument constructors. `keys` must have
        `JOIN_BUILD_DEFAULT_CAP` slots (`KeyBundleVar()` has)."""
        self.keys = keys^
        self.payload = Tuple[*Self.Payload]()
        self.capacity_mask = JOIN_BUILD_DEFAULT_CAP - 1
        self.n_used = 0
        self.has_duplicate_keys = False

    @staticmethod
    @always_inline
    def payload_arity() -> Int:
        """The number of payload columns."""
        return Self.Payload.__len__()

    @staticmethod
    @always_inline
    def key_arity() -> Int:
        """The number of key columns."""
        return Self.KB.arity()

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_JOIN_PROBE

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        raise Error(
            "JoinBuildTable.feed_row: the table is a build primitive; feed"
            " rows through the join's build state"
        )

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        raise Error(
            "JoinBuildTable.drain_to_record_batch: the table is a build"
            " primitive; probe it through the join's probe state"
        )

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error(
            "JoinBuildTable.probe_batch: the table is a build primitive; probe"
            " it through the join's probe state"
        )

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("JoinBuildTable.probe_asof_batch: not an ASOF_JOIN state")

    @always_inline
    def capacity(self) -> Int:
        """The slot count (a power of two)."""
        return self.capacity_mask + 1

    @always_inline
    def n_rows(self) -> Int:
        """The number of build rows inserted."""
        return self.n_used

    @always_inline
    def _at_load_factor(self) -> Bool:
        """True when one more insert would reach a load of 3/4."""
        return (self.n_used + 1) * 4 >= (self.capacity_mask + 1) * 3

    @always_inline
    def payload_read_f64[p: Int](self, slot: Int) -> Float64:
        """Payload column `p` at `slot` cast to Float64."""
        return self.payload[p].read_slot_f64(slot)

    @always_inline
    def payload_at[col: Int](self, slot: Int) -> Int64:
        """Payload column `col` at `slot` cast to Int64."""
        return self.payload[col].read_slot_i64(slot)

    @always_inline
    def payload_bits_at[p: Int](self, slot: Int) -> UInt64:
        """Fixed-width payload column `p` at `slot` as its own bits."""
        return self.payload[p].read_slot_bits(slot)

    @always_inline
    def payload_is_null[p: Int](self, slot: Int) -> Bool:
        """True iff payload column `p` is NULL at `slot`."""
        return self.payload[p].slot_is_null(slot)

    @always_inline
    def payload_write_f64[p: Int](mut self, slot: Int, value: Float64):
        """Store `value` cast to payload column `p`'s type at `slot`."""
        self.payload[p].write_slot_f64(slot, value)

    @always_inline
    def payload_write_from_batch[p: Int, bo: Origin[mut=False]](
        mut self, slot: Int, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        """Store `batch[col][row]` (or its NULL) in payload column `p` at
        `slot`, read at the column's own type."""
        self.payload[p].write_slot_from_batch[bo](slot, batch, col, row)

    @always_inline
    def payload_str_at[col: Int](self, slot: Int) raises -> String:
        """STRING payload column `col` at `slot`."""
        return self.payload[col].read_slot_string(slot)

    def _grow(mut self):
        """Double the slot count and move every occupied slot to its place in
        the larger table, keys and payloads in lockstep (one remap)."""
        var old_cap = self.capacity_mask + 1
        var new_cap = old_cap * 2
        var new_mask = new_cap - 1
        var occupied = List[Bool](capacity=new_cap)
        for _ in range(new_cap):
            occupied.append(False)
        var remap = List[Int](capacity=old_cap)
        for old_slot in range(old_cap):
            if self.keys.slot_is_empty(old_slot):
                remap.append(-1)
            else:
                var h = self.keys.slot_hash(old_slot)
                var new_slot = key_home(h, new_mask)
                while occupied[new_slot]:
                    new_slot = (new_slot + 1) & new_mask
                occupied[new_slot] = True
                remap.append(new_slot)
        self.keys.rehash_keys_in_place(new_cap, remap)
        comptime for p in range(Self.Payload.__len__()):
            self.payload[p].rehash_in_place(new_cap, remap)
        self.capacity_mask = new_mask

    @always_inline
    def _maybe_grow(mut self):
        """Grow when one more insert would reach a load of 3/4."""
        if self._at_load_factor():
            self._grow()

    def memory_size_bytes(self) -> Int:
        """The heap footprint of the key and payload columns in bytes."""
        var total = self.keys.memory_size_bytes()
        comptime for p in range(Self.Payload.__len__()):
            total += self.payload[p].memory_size_bytes()
        return total

    def combine(mut self, var other: Self) raises:
        """Insert every row of `other` (key, payloads and their NULLs) into
        this table. The table is a multiset of rows, so the result probes the
        same as one table built from both inputs; slot positions may differ.
        `has_duplicate_keys` holds if it held on either side or the merge put
        two equal keys together."""
        self.has_duplicate_keys = (
            self.has_duplicate_keys or other.has_duplicate_keys
        )
        var other_cap = other.capacity_mask + 1
        for other_slot in range(other_cap):
            if not other.keys.slot_is_empty(other_slot):
                self._maybe_grow()
                var saw_dup = False
                var dst = self.keys.insert_slot_from(
                    other.keys,
                    other_slot,
                    self.n_used,
                    self.capacity_mask,
                    saw_dup,
                )
                if saw_dup:
                    self.has_duplicate_keys = True
                comptime for p in range(Self.Payload.__len__()):
                    self.payload[p].copy_slot(dst, other.payload[p], other_slot)
