# =============================================================================
# slab_hash_agg_sink_struct_state -- the Local and Global of the struct sinks
# =============================================================================
#
# `SlabHashAggSinkStruct` and `SlabHashAggSinkStructCorr` share this state:
#
#   * `SlabHashAggLocal`: a one-byte placeholder. A worker's tables hang off
#     the Global, so every SlabStorage is allocated (in `init_global`) and
#     freed (with the Global) on the driver thread, never on a worker.
#   * `SlabHashAggGlobal`: `num_workers * N_PARTITIONS_SHAPE_B` storages, one
#     per worker per partition; after `combine`, one survivor per partition
#     in `_merged_storages`; the output staging slot; and the `claim` atomic
#     that makes it a non-movable KeepAlive.
#
# `_per_worker_storages` and `_merged_storages` are
# `Slab[OwnedPointer[SlabStorage]]`: a Slab stores its elements as bytes, so
# each storage sits behind an 8-byte owning handle whose drop the Slab runs.
# =============================================================================

from std.collections.optional import Optional
from std.memory import OwnedPointer

from komira_arrow.schema import RecordBatch
from komira_async_api.worker_pool_traits import KeepAlive
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_morsel.hash_agg_decoded import (
    N_PARTITIONS as N_PARTITIONS_SHAPE_B,
)

from .slab_storage import SlabStorage


# =============================================================================
# Partitioning
# =============================================================================
#
# Each worker keeps N_PARTITIONS_SHAPE_B (64) independent SlabStorages and
# routes a row by `(h >> 32) & 0x3F`. Combine merges partition by partition
# (partitions merge in parallel), and finalize concatenates them.
#
# Bits 32..37 are disjoint from both the slot bits (the low bits) and the
# fingerprint (bits 56..63), so a partition keeps full fingerprint variety.
# `komira_morsel.hash_agg_decoded` uses the same layout, so a decoded batch's
# precomputed partition agrees with this one.
# =============================================================================

comptime _PART_SHIFT_SHAPE_B: Int = 32
"""Hash bit shift of the partition id."""

comptime _PART_MASK_SHAPE_B: UInt64 = 0x3F
"""Partition id mask for `N_PARTITIONS_SHAPE_B = 64`."""


@always_inline
def _partition_for_shape_b(h: UInt64) -> Int:
    """The partition id of hash `h`."""
    return Int((h >> UInt64(_PART_SHIFT_SHAPE_B)) & _PART_MASK_SHAPE_B)


# =============================================================================
# SlabHashAggLocal -- per-worker state (a placeholder)
# =============================================================================


struct SlabHashAggLocal(Movable, Deinitable):
    """Per-worker state of the struct sinks: empty.

    The per-worker storages live in `SlabHashAggGlobal._per_worker_storages`
    so they are allocated and freed on the driver thread; `consume` reaches
    worker `w`'s through `sink_global.partition_storage_ref(w, p)`.
    """

    var _placeholder: UInt8
    """Keeps the struct non-empty."""

    def __init__(out self):
        """No allocation."""
        self._placeholder = 0


# =============================================================================
# SlabHashAggGlobal -- shared sink state (KeepAlive)
# =============================================================================


struct SlabHashAggGlobal(KeepAlive):
    """Shared state of the struct sinks; non-movable (its `claim` atomic).

    `init_global` builds it with every per-worker storage on the driver
    thread, so `consume` allocates no table. `combine` moves the last
    worker's partition `p` into `_merged_storages[p]` (leaving an empty
    placeholder); `combine_partition(p)` merges the other workers'
    partition `p` into it. The donors stay in `_per_worker_storages` and
    drop with the Global, on the driver thread.
    """

    var _per_worker_storages: Slab[OwnedPointer[SlabStorage]]
    """`num_workers * N_PARTITIONS_SHAPE_B` storages; worker `w`'s partition
    `p` is at `w * N_PARTITIONS_SHAPE_B + p`."""

    var _merged_storages: Slab[OwnedPointer[SlabStorage]]
    """Empty before `combine`; after it, one survivor per partition, indexed
    by partition id, which `combine_partition` merges into and `finalize`
    reads."""

    var output_slot: Optional[RecordBatch]
    """Single-batch output staging."""

    var claim: AtomicI64
    """The inline atomic that makes this struct non-movable (KeepAlive)."""

    def __init__(
        out self,
        num_workers: Int,
        num_keys: Int,
        num_aggs: Int,
        per_worker_capacity: Int,
        var agg_state_strides_in: Optional[List[Int]] = None,
    ) raises:
        """Allocate `num_workers * N_PARTITIONS_SHAPE_B` storages.

        Each partition gets a capacity of `per_worker_capacity * 2 / 64 + 1`
        (at least 64) rounded up to a power of two: twice the expected
        per-partition load, for hash-distribution variance; a storage grows
        past it on its load factor.

        Args:
            num_workers: Worker pool size.
            num_keys: Key column count of every storage.
            num_aggs: Aggregate count of every storage.
            per_worker_capacity: Expected groups per worker.
            agg_state_strides_in: Per-aggregate state size in bytes, copied
                into every storage (`None` gives 8 bytes each).
        """
        var per_partition_raw = (
            (per_worker_capacity * 2) // N_PARTITIONS_SHAPE_B + 1
        )
        if per_partition_raw < 64:
            per_partition_raw = 64
        var per_partition = 16
        while per_partition < per_partition_raw:
            per_partition *= 2

        var total = num_workers * N_PARTITIONS_SHAPE_B
        self._per_worker_storages = (
            Slab[OwnedPointer[SlabStorage]].create(total)
        )
        var has_strides = Bool(agg_state_strides_in)
        var strides_n = 0
        if has_strides:
            strides_n = len(agg_state_strides_in.value())
        for _ in range(total):
            var per_storage_strides: Optional[List[Int]] = None
            if has_strides:
                var clone = List[Int](capacity=strides_n)
                for j in range(strides_n):
                    clone.append(agg_state_strides_in.value()[j])
                per_storage_strides = Optional[List[Int]](clone^)
            var s = SlabStorage(
                num_keys=num_keys,
                num_aggs=num_aggs,
                initial_capacity=per_partition,
                agg_state_strides_in=per_storage_strides^,
            )
            self._per_worker_storages.append(OwnedPointer[SlabStorage](s^))
        _ = agg_state_strides_in^

        self._merged_storages = (
            Slab[OwnedPointer[SlabStorage]].create(N_PARTITIONS_SHAPE_B)
        )
        self.output_slot = Optional[RecordBatch](None)
        self.claim = AtomicI64(0)

    @always_inline
    def partition_storage_ref(
        ref self, w: Int, p: Int
    ) -> ref [
        origin_of(self._per_worker_storages[w * N_PARTITIONS_SHAPE_B + p][])
    ] SlabStorage:
        """Worker `w`'s partition `p` storage, borrowed from `self`."""
        return self._per_worker_storages[w * N_PARTITIONS_SHAPE_B + p][]

    @always_inline
    def worker_partition_index(self, w: Int, p: Int) -> Int:
        """Index of worker `w`'s partition `p` in `_per_worker_storages`."""
        return w * N_PARTITIONS_SHAPE_B + p

    def worker_total_num_groups(self, w: Int) -> Int:
        """Groups in worker `w`'s storages, summed over its partitions."""
        var total = 0
        for p in range(N_PARTITIONS_SHAPE_B):
            total += self._per_worker_storages[
                w * N_PARTITIONS_SHAPE_B + p
            ][].num_groups()
        return total

    def total_merged_num_groups(self) -> Int:
        """Groups in the merged survivors (0 before `combine`)."""
        var total = 0
        for p in range(len(self._merged_storages)):
            total += self._merged_storages[p][].num_groups()
        return total

    def has_merged_state(self) -> Bool:
        """True iff `combine` has run and produced at least one group."""
        return (
            len(self._merged_storages) > 0
            and self.total_merged_num_groups() > 0
        )
