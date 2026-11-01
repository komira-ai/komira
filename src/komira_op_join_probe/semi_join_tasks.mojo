# =============================================================================
# semi_join_tasks -- the semi/anti join hash set's slot arithmetic and the
# per-worker tasks of its parallel build and parallel probes.
# =============================================================================
#
# The set (`semi_join.SemiJoinHashSet`) is one table of INT64 keys carved into
# 8 equal power-of-two partitions; the top 3 bits of a key's Fibonacci hash
# pick the partition and linear probing stays inside it. `_EMPTY_KEY`
# (INT64_MIN) marks an empty slot, so the key INT64_MIN itself is never stored:
# the set records it in a flag (`has_min_key`) that every lookup consults.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.runtime.steal_work import StealWork
from komira_async_api.worker_pool_traits import KeepAlive, Segment


comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15

comptime _EMPTY_KEY: Int64 = Int64(-9223372036854775807 - 1)
"""INT64_MIN: the empty-slot marker. The key INT64_MIN is never stored."""

comptime _PREFETCH_DISTANCE: Int = 8


comptime SEMI_PROBE_PARALLEL_MIN_ROWS: Int = 131_072

comptime _MAX_LOAD_NUMER: Int = 7
comptime _MAX_LOAD_DENOM: Int = 10

comptime _NUM_PARTITIONS: Int = 8
comptime _PARTITION_SHIFT_BITS: UInt64 = 61  # 64 - log2(_NUM_PARTITIONS)
comptime _PARALLEL_BUILD_THRESHOLD: Int = 131_072


@always_inline
def _hash_key(key: Int64) -> UInt64:
    """Fibonacci hash for join keys."""
    var h = UInt64(key) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    return h


@always_inline
def _partition_of(h: UInt64) -> Int:
    """Top 3 bits of the hash select one of 8 partitions."""
    return Int(h >> _PARTITION_SHIFT_BITS)


@always_inline
def _arr_is_null(keys: PrimitiveArray[DType.int64], row: Int) -> Bool:
    """Non-raising NULL check for a fixed-width key column at `row`."""
    if not keys.validity:
        return False
    return not keys.validity.value().test(keys.offset + row)


@always_inline
def _probe_bit_is_null[
    o: Origin
](valid_ptr: UnsafePointer[UInt8, o], valid_offset: Int, row: Int) -> Bool:
    """Is probe `row` NULL per the Arrow validity bitmap?"""
    var bit_idx = valid_offset + row
    var byte = (valid_ptr + (bit_idx >> 3))[]
    return ((byte >> UInt8(bit_idx & 7)) & UInt8(1)) == UInt8(0)


@always_inline
def _table_contains[
    o: Origin
](keys_ptr: UnsafePointer[Int64, o], part_mask: UInt64, part_shift: Int, key: Int64) -> Bool:
    """Linear-probe lookup of `key` (never `_EMPTY_KEY`) in its partition."""
    var h = _hash_key(key)
    var base = _partition_of(h) << part_shift
    var slot = Int(h & part_mask)
    while True:
        var existing = (keys_ptr + base + slot)[]
        if existing == key:
            return True
        if existing == _EMPTY_KEY:
            return False
        slot = (slot + 1) & Int(part_mask)


struct SemiJoinBuildState(KeepAlive):
    """The parallel build's state. It OWNS the table (`keys`, moved in from
    the set and back out after the dispatch), the per-partition staging slab
    of keys (`part_slab`, `staging_stride` slots per partition), the staged
    count per partition and each partition's distinct-key count."""

    var keys: List[Int64]
    var part_mask: UInt64
    var part_shift: Int
    var staging_stride: Int
    var part_slab: List[Int64]
    var part_counts: List[Int]
    var part_dedup_counts: List[Int]

    def __init__(
        out self,
        var keys: List[Int64],
        part_mask: UInt64,
        part_shift: Int,
        staging_stride: Int,
        var part_slab: List[Int64],
        var part_counts: List[Int],
        var part_dedup_counts: List[Int],
    ):
        self.keys = keys^
        self.part_mask = part_mask
        self.part_shift = part_shift
        self.staging_stride = staging_stride
        self.part_slab = part_slab^
        self.part_counts = part_counts^
        self.part_dedup_counts = part_dedup_counts^

    def take_keys(mut self) -> List[Int64]:
        """Move the table out, leaving an empty List."""
        var v = self.keys^
        self.keys = List[Int64]()
        return v^


@fieldwise_init
struct SemiJoinBuildTask(Segment):
    """One partition of the parallel build: fill the partition's slot range
    with `_EMPTY_KEY`, then insert its staged keys (deduplicating)."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: `SemiJoinHashSet._build_parallel_pooled` dispatches
        # run_with_state[SemiJoinBuildState, SemiJoinBuildTask], so the bitcast
        # recovers the concrete state. Task p writes only partition p's slot
        # range of `keys` and slot p of `part_dedup_counts`; the Lists are
        # sized before the dispatch and never resized during it, and the
        # dispatch barrier ends every task before the driver reads them.
        var sp = UnsafePointer(to=state).bitcast[SemiJoinBuildState]()
        var p = Int(task_id)
        var base = p << sp[].part_shift
        var mask = sp[].part_mask
        var part_cap = Int(mask) + 1

        # PERF-CRITICAL: each worker initialises its own partition's slots,
        # so the table's fill is split across the workers instead of one
        # serial memset, and overlaps the other partitions' inserts.
        var keys_mut_ptr = sp[].keys.unsafe_ptr()
        for s in range(part_cap):
            (keys_mut_ptr + base + s)[] = _EMPTY_KEY

        var pc = sp[].part_counts[p]
        var dedup_ptr = sp[].part_dedup_counts.unsafe_ptr()
        if pc == 0:
            (dedup_ptr + p)[] = 0
            return

        var pk = sp[].part_slab.unsafe_ptr() + p * sp[].staging_stride
        var cnt = 0
        # PERF-CRITICAL: tight insert loop; the hash is recomputed in a
        # register rather than loaded from a staging array.
        for i in range(pc):
            var key = (pk + i)[]
            var h = _hash_key(key)
            var slot = Int(h & mask)
            while True:
                var existing = (keys_mut_ptr + base + slot)[]
                if existing == _EMPTY_KEY:
                    (keys_mut_ptr + base + slot)[] = key
                    cnt += 1
                    break
                if existing == key:
                    break
                slot = (slot + 1) & Int(mask)
        (dedup_ptr + p)[] = cnt


struct _ProbeInput(Deinitable):
    """Borrowed read-only probe inputs for the work-stealing morsel probe.

    The pointers carry `ImmStaticOrigin`: they point into the set's table and
    the probe column, both borrowed by the driver for the whole
    `parallel_steal` call, which joins every worker before it returns."""

    var ht_keys_ptr: UnsafePointer[Int64, ImmStaticOrigin]
    var part_mask: UInt64
    var part_shift: Int
    var probe_key_ptr: UnsafePointer[Scalar[DType.int64], ImmStaticOrigin]
    var num_probe_rows: Int
    var morsel_size: Int
    var probe_valid_ptr: UnsafePointer[UInt8, ImmStaticOrigin]
    var probe_valid_offset: Int
    var probe_has_nulls: Bool
    var has_min_key: Bool

    def __init__(
        out self,
        ht_keys_ptr: UnsafePointer[Int64, ImmStaticOrigin],
        part_mask: UInt64,
        part_shift: Int,
        probe_key_ptr: UnsafePointer[Scalar[DType.int64], ImmStaticOrigin],
        num_probe_rows: Int,
        morsel_size: Int,
        probe_valid_ptr: UnsafePointer[UInt8, ImmStaticOrigin],
        probe_valid_offset: Int,
        probe_has_nulls: Bool,
        has_min_key: Bool,
    ):
        self.ht_keys_ptr = ht_keys_ptr
        self.part_mask = part_mask
        self.part_shift = part_shift
        self.probe_key_ptr = probe_key_ptr
        self.num_probe_rows = num_probe_rows
        self.morsel_size = morsel_size
        self.probe_valid_ptr = probe_valid_ptr
        self.probe_valid_offset = probe_valid_offset
        self.probe_has_nulls = probe_has_nulls
        self.has_min_key = has_min_key


struct _ProbeMatches(Movable, Deinitable):
    """Per-worker accumulator: each morsel this worker stole contributes a
    `(morsel_idx, matches)` pair. The parallel `morsels[k]` /  `lists[k]`
    arrays stay index-aligned. The caller orders the pairs by `morsel_idx`
    and concatenates them, so the result is in probe order.
    """

    var morsels: List[Int]
    var lists: List[List[Int]]

    def __init__(out self):
        self.morsels = List[Int]()
        self.lists = List[List[Int]]()


@fieldwise_init
struct _ProbeWork(StealWork):
    """Work-stealing morsel probe. Each grabbed morsel scans its ascending
    probe-row range against the read-only HT and collects matching probe
    indices into a fresh `List[Int]`, tagged by the morsel index. POD
    descriptor only — all heavy state lives on the helper-owned per-worker
    `_ProbeMatches`.
    """

    var _pad: Int32

    def init_worker_state[
        WS: Movable & Deinitable
    ](self, n_items: Int, mut out_slot: Optional[WS]) raises:
        var acc = _ProbeMatches()
        var op = UnsafePointer(to=out_slot).bitcast[Optional[_ProbeMatches]]()
        op[] = Optional[_ProbeMatches](acc^)

    def process_item[
        In: Deinitable, WS: Movable & Deinitable
    ](
        self,
        item_idx: Int,
        n_items: Int,
        ref input: In,
        mut ws: WS,
    ) raises:
        var ip = UnsafePointer(to=input).bitcast[_ProbeInput]()
        var ap = UnsafePointer(to=ws).bitcast[_ProbeMatches]()

        var morsel_size = ip[].morsel_size
        var num_probe_rows = ip[].num_probe_rows
        var keys_mut_ptr = ip[].ht_keys_ptr
        var probe_key_ptr = ip[].probe_key_ptr
        var part_mask = ip[].part_mask
        var part_shift = ip[].part_shift
        var probe_valid_ptr = ip[].probe_valid_ptr
        var probe_valid_offset = ip[].probe_valid_offset
        var probe_has_nulls = ip[].probe_has_nulls
        var has_min_key = ip[].has_min_key

        var start = item_idx * morsel_size
        var end = min(start + morsel_size, num_probe_rows)

        var est = max(morsel_size // 64, 256)
        var matches = List[Int](capacity=est)

        # PERF-CRITICAL: tight probe loop with software prefetch of the slot
        # the key `_PREFETCH_DISTANCE` rows ahead will read; the random table
        # reads dominate and the prefetch hides their latency.
        for i in range(start, end):
            if i + _PREFETCH_DISTANCE < end:
                var fk = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                var fh = _hash_key(fk)
                var fpid = _partition_of(fh)
                var fs = (fpid << part_shift) + Int(fh & part_mask)
                prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                    keys_mut_ptr + fs
                )

            if probe_has_nulls and _probe_bit_is_null(
                probe_valid_ptr, probe_valid_offset, i
            ):
                continue
            var key = Int64((probe_key_ptr + i)[])
            var found = has_min_key
            if key != _EMPTY_KEY:
                found = _table_contains(
                    keys_mut_ptr, part_mask, part_shift, key
                )
            if found:
                matches.append(i)

        ap[].morsels.append(item_idx)
        ap[].lists.append(matches^)


struct _ProbeCount(Movable, Deinitable):
    """Per-worker accumulator: total match (SEMI) / non-match (ANTI) count
    over every morsel this worker stole. POD Int — no heap inner.
    """

    var count: Int

    def __init__(out self):
        self.count = 0


@fieldwise_init
struct _ProbeCountWork(StealWork):
    """Work-stealing count-only morsel probe. Each grabbed morsel scans its
    ascending probe-row range against the read-only HT and adds its match
    (SEMI) / non-match (ANTI) count to the per-worker `_ProbeCount`. POD
    descriptor: only the `is_anti` mode discriminator.
    """

    var is_anti: Bool

    def init_worker_state[
        WS: Movable & Deinitable
    ](self, n_items: Int, mut out_slot: Optional[WS]) raises:
        var acc = _ProbeCount()
        var op = UnsafePointer(to=out_slot).bitcast[Optional[_ProbeCount]]()
        op[] = Optional[_ProbeCount](acc^)

    def process_item[
        In: Deinitable, WS: Movable & Deinitable
    ](
        self,
        item_idx: Int,
        n_items: Int,
        ref input: In,
        mut ws: WS,
    ) raises:
        var ip = UnsafePointer(to=input).bitcast[_ProbeInput]()
        var ap = UnsafePointer(to=ws).bitcast[_ProbeCount]()

        var morsel_size = ip[].morsel_size
        var num_probe_rows = ip[].num_probe_rows
        var keys_mut_ptr = ip[].ht_keys_ptr
        var probe_key_ptr = ip[].probe_key_ptr
        var part_mask = ip[].part_mask
        var part_shift = ip[].part_shift
        var probe_valid_ptr = ip[].probe_valid_ptr
        var probe_valid_offset = ip[].probe_valid_offset
        var probe_has_nulls = ip[].probe_has_nulls
        var has_min_key = ip[].has_min_key
        var is_anti = self.is_anti

        var start = item_idx * morsel_size
        var end = min(start + morsel_size, num_probe_rows)

        var count = 0
        # PERF-CRITICAL: tight count fold with software prefetch on the
        # probe-key + HT-slot stream (same shape as `_ProbeWork.process_item`,
        # minus the match-list append — just a scalar counter).
        for i in range(start, end):
            if i + _PREFETCH_DISTANCE < end:
                var fk = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                var fh = _hash_key(fk)
                var fpid = _partition_of(fh)
                var fs = (fpid << part_shift) + Int(fh & part_mask)
                prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                    keys_mut_ptr + fs
                )

            var is_null = probe_has_nulls and _probe_bit_is_null(
                probe_valid_ptr, probe_valid_offset, i
            )
            if is_null:
                if is_anti:
                    count += 1
                continue
            var key = Int64((probe_key_ptr + i)[])
            var found = has_min_key
            if key != _EMPTY_KEY:
                found = _table_contains(
                    keys_mut_ptr, part_mask, part_shift, key
                )
            if is_anti:
                if not found:
                    count += 1
            else:
                if found:
                    count += 1

        ap[].count += count
