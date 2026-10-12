# =============================================================================
# PartitionedFlatHashAggregator -- pre-partitioned per-worker storage
# =============================================================================
#
# The radix-partitioned alternative to the abandon-cycle path
# (FlatHashAggregator + FlatHashPartitionFlush); the sink picks one through
# its strategy selector.
#
# Storage shape: each worker owns ONE PartitionedFlatHashAggregator holding
# NUM_PARTITIONS sub-aggregators (FlatHashAggregator), indexed by the top
# RADIX_BITS bits of the mixed hash. Every insert routes to exactly one
# sub-table; there is no per-batch flush and no abandon cycle, and the
# combine is a partition-parallel transpose and merge.
#
# Why: on high-cardinality inputs the abandon cycle's flush traffic
# dominates. Pre-partitioning keeps each sub-table L2-resident on its own
# and gives the combine natural parallelism (one task per partition).
#
# Movable-only: owns a Slab of FlatHashAggregator (itself Movable-only).
# Sub-tables are reached through `Slab.__getitem__`, whose reference carries
# the slab's origin and is mutable when the aggregator is borrowed mutably.
# =============================================================================

from std.memory import UnsafePointer

from komira_collections.slab import Slab

from .flat_hash_agg import FlatHashAggregator, EntryHandle, _fib_hash_1, _fib_hash_2, _fib_hash_n
from komira_agg_api.agg_layout import AggLayout


@always_inline
def _clone_tags(layout: AggLayout) -> List[UInt8]:
    """Snapshot layout.tags[0..num_aggs) into a fresh List[UInt8].

    Used by PartitionedFlatHashAggregator.with_layout to build one
    AggLayout per sub-HT from the source tag list.
    """
    var out = List[UInt8](capacity=layout.num_aggs)
    for i in range(layout.num_aggs):
        out.append(layout.tags[i])
    return out^


# Default radix shape: RADIX_BITS=8 (256 partitions). Against 64
# partitions it measured about 20% less wall time on high-cardinality
# group-bys, from finer partitions saturating the parallel finalize, with
# no regression above 1% elsewhere.
#
# IMPORTANT lockstep coupling: the sink that sizes its per-partition fan-out
# from its own partition count must use this value; if the two diverge, the
# per-partition combine reads out of bounds.
comptime RADIX_BITS: Int = 8
comptime NUM_PARTITIONS: Int = 1 << RADIX_BITS  # 256
# Partition selector: partition = (hash >> SHIFT) & (NUM_PARTITIONS - 1).
# 64 - log2(NUM_PARTITIONS) = 56.
comptime SHIFT: Int = 64 - RADIX_BITS  # 56


struct PartitionedFlatHashAggregator(Movable):
    """NUM_PARTITIONS-way pre-partitioned aggregator, one sub-HT per
    partition.

    Each insert routes by the top `RADIX_BITS` bits of `mixed_hash` into
    one of NUM_PARTITIONS `FlatHashAggregator` sub-tables. Sub-tables grow
    on demand via the standard `find_or_create_*` paths (no shared global
    resize).

    Fields:
        _partitions: Slab of `NUM_PARTITIONS` FlatHashAggregator
            values. Slab (not List) because FlatHashAggregator is
            Movable-only and List requires Copyable elements.
        _num_partitions: Cached partition count (always NUM_PARTITIONS;
            stored so callers can ask without importing the constant).
        _shift: Cached partition selector shift (always SHIFT).
        _num_keys: Number of Int64 key columns. All sub-HTs share this.
        _num_aggs: Number of agg slots per group. All sub-HTs share this.
    """

    # The Slab's destructor destroys every element, then frees the buffer.
    var _partitions: Slab[FlatHashAggregator]
    var _num_partitions: Int
    var _shift: Int
    var _num_keys: Int
    var _num_aggs: Int

    def __init__(
        out self,
        num_keys: Int,
        num_aggs: Int,
        initial_sub_capacity: Int = 256,
    ):
        """Allocate NUM_PARTITIONS sub-HTs, each starting at
        `initial_sub_capacity`.

        Args:
            num_keys: Group-by key column count (Int64 keys).
            num_aggs: Aggregation slots per group.
            initial_sub_capacity: Initial capacity per sub-HT. Default 256,
                because each sub-HT only sees 1/NUM_PARTITIONS of the input
                rows: each grows on demand instead of pre-sizing them all.
        """
        self._num_partitions = NUM_PARTITIONS
        self._shift = SHIFT
        self._num_keys = num_keys
        self._num_aggs = num_aggs

        # Pre-size the array so `append` never reallocates during the init
        # loop; we know the final size statically.
        self._partitions = Slab[FlatHashAggregator].with_capacity(
            NUM_PARTITIONS
        )
        for _ in range(NUM_PARTITIONS):
            self._partitions.append(
                FlatHashAggregator(
                    num_keys=num_keys,
                    num_aggs=num_aggs,
                    initial_capacity=initial_sub_capacity,
                )
            )

    @staticmethod
    def with_layout(
        num_keys: Int,
        var layout: AggLayout,
        initial_sub_capacity: Int = 256,
    ) -> PartitionedFlatHashAggregator:
        """Build a PartitionedFlatHashAggregator whose sub-HTs follow `layout`.

        Lets callers select a narrow slot layout (ACC_SUM_COUNT_F64) for
        SUM+COUNT-only queries. Every sub-HT gets the same layout, so the
        partition-parallel merge's byte contract holds.

        Args:
            num_keys: Group-by key column count.
            layout: Per-slot width/tag schema; consumed (moved) into
                each sub-HT.
            initial_sub_capacity: Initial capacity per sub-HT.
        """
        var agg = PartitionedFlatHashAggregator(
            num_keys=num_keys,
            num_aggs=layout.num_aggs,
            initial_sub_capacity=initial_sub_capacity,
        )
        # Replace each sub-HT with one built via with_layout so the
        # narrow slot stride takes effect; each gets its own AggLayout
        # (`FlatHashAggregator.with_layout` consumes it). The Slab's
        # `__setitem__` destroys the replaced sub-HT.
        for p in range(NUM_PARTITIONS):
            var sub_layout = AggLayout(_clone_tags(layout))
            agg._partitions[p] = FlatHashAggregator.with_layout(
                num_keys=num_keys,
                layout=sub_layout^,
                initial_capacity=initial_sub_capacity,
            )
        _ = layout^
        return agg^

    # ------------------------------------------------------------------
    # Accessors
    # ------------------------------------------------------------------

    @always_inline
    def num_partitions(self) -> Int:
        return self._num_partitions

    @always_inline
    def shift(self) -> Int:
        return self._shift

    @always_inline
    def num_keys(self) -> Int:
        return self._num_keys

    @always_inline
    def num_aggs(self) -> Int:
        return self._num_aggs

    def num_groups(self) -> Int:
        """Sum of `num_groups()` across all sub-HTs."""
        var total = 0
        for p in range(self._num_partitions):
            total += self._partitions[p].num_groups()
        return total

    # ------------------------------------------------------------------
    # Bulk pre-size sub-tables from a per-sub-table target.
    # ------------------------------------------------------------------
    #
    # PERF-CRITICAL: the high-cardinality path. With 64 sub-tables, 11
    # workers and ~1M groups, each sub-table reaches ~1.4K entries during
    # consume; starting at the default 256 costs ~3 doublings per sub-table
    # per worker (about 2,100 resizes per query, ~14% of its wall time).
    #
    # `pre_size(target_per_partition)` calls FlatHashAggregator.pre_grow
    # once per sub-table to pre-allocate capacity sufficient for
    # `target_per_partition` groups under the load-factor threshold,
    # eliminating consume-phase resize cycles when the estimate is
    # within a 1.5x margin of reality. An estimate too low falls back to
    # grow-on-demand for that sub-table; one too high wastes heap, bounded
    # by the per-sub-table cap the caller imposes.
    #
    # Idempotent: a target at or below current capacity is a no-op
    # (FlatHashAggregator.pre_grow guards that internally).
    def pre_size(mut self, target_per_partition: Int):
        """Pre-grow every sub-HT to hold `target_per_partition` groups.

        Args:
            target_per_partition: Estimated final group count per sub-HT.
                The actual capacity allocated is the smallest power-of-two
                whose load-factor threshold (currently 7/10) is >=
                `target_per_partition`. <=0 is a no-op.
        """
        if target_per_partition <= 0:
            return
        for p in range(self._num_partitions):
            self._partitions[p].pre_grow(target_per_partition)

    @always_inline
    def partition(
        ref self, p: Int
    ) -> ref [self._partitions._bytes] FlatHashAggregator:
        """Sub-HT `p` (mutable when `self` is borrowed mutably). Used by
        the commit and combine paths to reach one sub-table."""
        return self._partitions[p]

    @always_inline
    def _partition_for(self, mixed_hash: UInt64) -> Int:
        """Route a non-zero mixed hash to its partition [0, NUM_PARTITIONS)."""
        return Int((mixed_hash >> UInt64(self._shift)) & UInt64(self._num_partitions - 1))

    # ------------------------------------------------------------------
    # Insert paths — route to the appropriate sub-HT and update the agg
    # ------------------------------------------------------------------
    #
    # We expose the same "find-or-create + caller updates the agg" shape
    # as FlatHashAggregator. The caller hashes the keys exactly once and
    # passes both the hash (for routing AND probing) and the key(s).

    def insert_1(
        mut self,
        key: Int64,
        value: Float64,
    ):
        """Single-key insert with a SUM/COUNT/MIN/MAX agg update.

        Hashes the key, routes to the partition, find_or_create in the
        sub-HT, updates agg slot 0. For multi-agg call sites use
        `insert_1_handle` and update each slot manually.
        """
        var h = _fib_hash_1(key)
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub.probe_or_insert_row(h, key)
        sub._update_agg(handle, 0, value)

    def insert_1_count_only(
        mut self,
        key: Int64,
    ):
        """Single-key COUNT(*) insert."""
        var h = _fib_hash_1(key)
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub.probe_or_insert_row(h, key)
        sub._update_count_only(handle, 0)

    def insert_2(
        mut self,
        k0: Int64,
        k1: Int64,
        value: Float64,
    ):
        """Two-key insert with a single-agg update."""
        var h = _fib_hash_2(k0, k1)
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub.find_or_create_2_prehashed(k0, k1, h)
        sub._update_agg(handle, 0, value)

    def insert_n[
        o_keys: Origin
    ](
        mut self,
        keys: Span[Int64, o_keys],
        value: Float64,
    ):
        """N-key insert of the `len(keys)` keys (the aggregator's key
        count) with a single-agg update."""
        var num_keys = len(keys)
        var keys_ptr = keys.unsafe_ptr()
        var h = _fib_hash_n(keys_ptr.bitcast[UInt8](), num_keys)
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub._find_or_create_n_prehashed(keys_ptr, num_keys, h)
        sub._update_agg(handle, 0, value)

    # ------------------------------------------------------------------
    # PERF-CRITICAL: prehashed find_or_create variants for the consume
    # hot loop.
    #
    # The consume loop pre-computes hashes in a SIMD batch and then probes
    # per row. These methods take the pre-computed hash so the caller does
    # not re-hash, and return (partition_index, EntryHandle) so the caller
    # can commit_row on the right sub-table.
    # ------------------------------------------------------------------

    @always_inline
    def find_or_create_1_prehashed(
        mut self,
        key: Int64,
        h: UInt64,
    ) -> Tuple[Int, EntryHandle]:
        """Single-key prehashed find/create.

        Routes by hash to the correct sub-table, probes, and returns
        (partition_index, entry_handle). Caller uses partition_index to
        get the sub-table for commit_row.
        """
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub.probe_or_insert_row(h, key)
        return (p, handle)

    @always_inline
    def find_or_create_2_prehashed(
        mut self,
        k0: Int64,
        k1: Int64,
        h: UInt64,
    ) -> Tuple[Int, EntryHandle]:
        """Two-key prehashed find/create."""
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub.find_or_create_2_prehashed(k0, k1, h)
        return (p, handle)

    @always_inline
    def _find_or_create_n_prehashed[
        o_keys: Origin
    ](
        mut self,
        keys: UnsafePointer[Int64, o_keys],
        num_keys: Int,
        h: UInt64,
    ) -> Tuple[Int, EntryHandle]:
        """N-key prehashed find/create."""
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        var handle = sub._find_or_create_n_prehashed(keys, num_keys, h)
        return (p, handle)

    # PERF: the "_handle" variants return a (partition_index, EntryHandle)
    # so a multi-agg caller can issue one find_or_create then loop over agg
    # slots. We expose the partition index too in case the caller wants to
    # confirm routing.

    def find_or_create_1_handle(
        mut self,
        key: Int64,
    ) -> Int:
        """Single-key find/create that returns the partition index.

        After calling this, the caller can reach the sub-table with
        `partition(p)` and invoke its agg update API directly. The hash is
        computed internally.
        """
        var h = _fib_hash_1(key)
        var p = self._partition_for(h)
        ref sub = self._partitions[p]
        _ = sub.probe_or_insert_row(h, key)
        return p
