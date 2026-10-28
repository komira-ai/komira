# =============================================================================
# semi_join -- `SemiJoinHashSet`, the hash set of build-side keys a SEMI or
# ANTI join over one INT64 key probes, with serial and parallel builds and
# serial, parallel and count-only probes.
# =============================================================================
#
# PERF-CRITICAL: a SEMI or ANTI join only asks whether a key exists on the
# build side, never which rows hold it, so the build deduplicates into a flat
# open-addressing set (no chains, no row indices, no bloom) and the probe reads
# 8-byte slots with linear probing. DuckDB's MARK join uses a similar set.
#
# A large build (`_PARALLEL_BUILD_THRESHOLD` keys or more) stages its keys by
# partition and builds the 8 partitions in parallel, each worker owning one
# partition's slots (no atomics). A NULL key never matches: the build skips
# it, SEMI drops a NULL probe row and ANTI keeps it.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_steal import parallel_steal
from komira_async.runtime.sched_trace import (
    SITE_SEMI_JOIN,
    SITE_SEMI_PROBE_COUNT,
    SITE_SEMI_PROBE_INDEX,
)
from komira_async_api.token import CancellationToken
from komira_engine_runtime.fan_out_grain import (
    FORK_GRAIN_MAX_ROWS,
    parallel_fork_grain,
)
from komira_engine_runtime.grain_geometry import grain_geometry_record

from .semi_join_tasks import (
    SEMI_PROBE_PARALLEL_MIN_ROWS,
    SemiJoinBuildState,
    SemiJoinBuildTask,
    _EMPTY_KEY,
    _NUM_PARTITIONS,
    _PARALLEL_BUILD_THRESHOLD,
    _PREFETCH_DISTANCE,
    _ProbeCount,
    _ProbeCountWork,
    _ProbeInput,
    _ProbeMatches,
    _ProbeWork,
    _arr_is_null,
    _hash_key,
    _partition_of,
    _probe_bit_is_null,
    _table_contains,
)


def _initial_capacity(n: Int) -> Int:
    """Total slots for `n` build keys: a power of two holding them at a load
    of at most 1/1.5 (at least 16 slots a partition)."""
    var min_total_cap = max(Int(Float64(n) * 1.5) + 1, 16 * _NUM_PARTITIONS)
    var total_cap = 1
    while total_cap < min_total_cap:
        total_cap *= 2
    return total_cap


struct SemiJoinHashSet(Movable):
    """Partitioned open-addressing hash set for semi/anti join key lookups:
    the distinct non-NULL INT64 keys of the build side (8 bytes a slot, no
    row indices), at most 1/1.5 loaded when the keys spread evenly and never
    more than 3/4 loaded in any partition (the table doubles when keys crowd
    into one). The key INT64_MIN, which marks an empty slot, is kept in
    `_has_min_key` instead of the table."""

    var _keys: List[Int64]
    var _part_cap: Int
    var _part_shift: Int
    var _part_mask: UInt64
    var _count: Int

    var _capacity: Int
    var _mask: UInt64
    var _has_min_key: Bool

    def __init__(out self, keys: PrimitiveArray[DType.int64]):
        """Build a deduplicating hash set from a key column (SERIAL).

        Args:
            keys: The build-side join key column (may contain duplicates).
        """
        self._part_cap = 0
        self._part_shift = 0
        self._part_mask = 0
        self._capacity = 0
        self._mask = 0
        self._count = 0
        self._has_min_key = False
        self._keys = List[Int64]()
        self._reset_table(_initial_capacity(keys.length), True)
        self._build_serial(keys)

        _ = keys  # keepalive

    def __init__(
        out self,
        keys: PrimitiveArray[DType.int64],
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
    ) raises:
        """Build a deduplicating hash set, PARALLEL for large build sides.

        A build whose keys crowd into one partition (more than three quarters
        of its slots) is built serially instead, into a table grown until no
        partition is more than three quarters full; the token is then not
        consulted.

        Args:
            keys: The build-side join key column (may contain duplicates).
            dispatcher: Caller-owned LocalDispatcher reference.
            cancel_token: Caller-supplied CancellationToken (consumed
                by the parallel-build dispatch; drops on serial path).
        """
        self._part_cap = 0
        self._part_shift = 0
        self._part_mask = 0
        self._capacity = 0
        self._mask = 0
        self._count = 0
        self._has_min_key = False
        self._keys = List[Int64]()
        var n = keys.length
        if n >= _PARALLEL_BUILD_THRESHOLD:
            # The parallel build's tasks initialise their own slots.
            self._reset_table(_initial_capacity(n), False)
            self._build_parallel_pooled(keys, dispatcher, cancel_token^)
        else:
            self._reset_table(_initial_capacity(n), True)
            self._build_serial(keys)

        _ = keys  # keepalive

    def _reset_table(mut self, total_cap: Int, fill: Bool):
        """Size the table to `total_cap` slots (a power of two) in
        `_NUM_PARTITIONS` equal partitions, forgetting every key; with `fill`
        every slot is marked empty (the parallel build's tasks do that
        themselves)."""
        var part_cap = total_cap // _NUM_PARTITIONS
        var part_shift = 0
        var tmp = part_cap
        while tmp > 1:
            tmp = tmp >> 1
            part_shift += 1
        self._part_cap = part_cap
        self._part_shift = part_shift
        self._part_mask = UInt64(part_cap - 1)
        self._capacity = total_cap
        self._mask = UInt64(part_cap - 1)
        self._count = 0
        self._has_min_key = False
        self._keys = List[Int64](capacity=total_cap)
        self._keys.resize(unsafe_uninit_length=total_cap)
        if fill:
            var keys_ptr = self._keys.unsafe_ptr()
            for i in range(total_cap):
                (keys_ptr + i)[] = _EMPTY_KEY

    @always_inline
    def _keys_mut_ptr(mut self) -> UnsafePointer[Int64, origin_of(self)]:
        """Mutable-origin pointer to the keys buffer."""
        return self._keys.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()

    @always_inline
    def _insert_serial(mut self, key: Int64, mut part_keys: List[Int]) -> Bool:
        """Insert a key into the partitioned table (single-threaded path).
        False when the key is new and its partition already holds three
        quarters of its slots: the caller grows the table and starts over, so
        every partition keeps empty slots and every probe loop ends."""
        if key == _EMPTY_KEY:
            if not self._has_min_key:
                self._has_min_key = True
                self._count += 1
            return True
        var h = _hash_key(key)
        var pid = _partition_of(h)
        var base = pid << self._part_shift
        var slot_in_part = Int(h & self._part_mask)
        var keys_ptr = self._keys_mut_ptr()

        while True:
            var existing = (keys_ptr + base + slot_in_part)[]
            if existing == _EMPTY_KEY:
                if part_keys[pid] >= self._part_cap - (self._part_cap >> 2):
                    return False
                (keys_ptr + base + slot_in_part)[] = key
                part_keys[pid] += 1
                self._count += 1
                return True
            if existing == key:
                return True
            slot_in_part = (slot_in_part + 1) & Int(self._part_mask)

    def _build_serial(mut self, keys: PrimitiveArray[DType.int64]):
        """Serial build: single-threaded scatter into the partitioned table,
        doubling the table and starting over while a partition fills up (keys
        that crowd into one partition)."""
        var n = keys.length
        var has_nulls = keys.null_count != 0
        var key_ptr = keys._typed_ptr_ro()
        while True:
            var part_keys = List[Int]()
            part_keys.resize(_NUM_PARTITIONS, 0)
            var fits = True
            for i in range(n):
                if has_nulls and _arr_is_null(keys, i):
                    continue
                if not self._insert_serial(Int64((key_ptr + i)[]), part_keys):
                    fits = False
                    break
            if fits:
                return
            self._reset_table(self._capacity * 2, True)

    def _build_parallel_pooled(
        mut self,
        keys: PrimitiveArray[DType.int64],
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
    ) raises:
        """Parallel radix-partitioned build: stage every non-NULL key into its
        partition's slice of a staging slab (doubling the slices and
        restarting if one overflows), then one task per partition fills and
        inserts its slice of the table (`SemiJoinBuildTask`)."""
        var n = keys.length
        var has_nulls = keys.null_count != 0
        var key_ptr = keys._typed_ptr_ro()

        var est_per_part = (n + _NUM_PARTITIONS - 1) // _NUM_PARTITIONS
        var cap_per_part = est_per_part + (est_per_part // 4) + 64
        var part_slab = List[Int64]()
        part_slab.resize(unsafe_uninit_length=cap_per_part * _NUM_PARTITIONS)
        var part_counts = List[Int]()
        part_counts.resize(_NUM_PARTITIONS, 0)
        var saw_min = False

        var i = 0
        while i < n:
            if has_nulls and keys.is_null(i):
                i += 1
                continue
            var k = Int64((key_ptr + i)[])
            if k == _EMPTY_KEY:
                saw_min = True
                i += 1
                continue
            var p = _partition_of(_hash_key(k))
            var wi = part_counts[p]
            if wi >= cap_per_part:
                cap_per_part = cap_per_part * 2
                part_slab = List[Int64]()
                part_slab.resize(
                    unsafe_uninit_length=cap_per_part * _NUM_PARTITIONS
                )
                for q in range(_NUM_PARTITIONS):
                    part_counts[q] = 0
                saw_min = False
                i = 0
                continue
            part_slab[p * cap_per_part + wi] = k
            part_counts[p] = wi + 1
            i += 1

        # Staged counts include duplicates, so a partition staging more than
        # three quarters of its slots may still hold fewer distinct keys; the
        # serial build sizes the table by the distinct keys it meets.
        var max_staged = 0
        for q in range(_NUM_PARTITIONS):
            max_staged = max(max_staged, part_counts[q])
        if max_staged * 4 > self._part_cap * 3:
            self._reset_table(self._capacity, True)
            self._build_serial(keys)
            return

        var part_dedup_counts = List[Int]()
        part_dedup_counts.resize(_NUM_PARTITIONS, 0)
        var table = self._keys^
        self._keys = List[Int64]()
        var build_state = SemiJoinBuildState(
            table^,
            self._part_mask,
            self._part_shift,
            cap_per_part,
            part_slab^,
            part_counts^,
            part_dedup_counts^,
        )
        var build_task = SemiJoinBuildTask(Int32(0))

        _ = dispatcher.run_with_state[SemiJoinBuildState, SemiJoinBuildTask](
            build_state, build_task^, _NUM_PARTITIONS, cancel_token^, site_id=SITE_SEMI_JOIN,
        )

        var total = 0
        for p in range(_NUM_PARTITIONS):
            total += build_state.part_dedup_counts[p]
        self._keys = build_state.take_keys()
        self._has_min_key = saw_min
        self._count = total + (1 if saw_min else 0)

    @always_inline
    def contains(mut self, key: Int64) -> Bool:
        """Check if a key exists in the set.

        Args:
            key: The key to look up.

        Returns:
            True if the key was inserted during build.
        """
        if key == _EMPTY_KEY:
            return self._has_min_key
        return _table_contains(
            self._keys_mut_ptr(), self._part_mask, self._part_shift, key
        )

    def probe_semi(mut self, probe_keys: PrimitiveArray[DType.int64]) -> List[Int]:
        """Semi-join probe: return probe indices where the key exists in the set.

        Args:
            probe_keys: The probe-side join key column.

        Returns:
            List of probe indices with at least one match in the build set.
        """
        var n = probe_keys.length
        var result = List[Int](capacity=min(n, self._count))
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        for i in range(n):
            if i + _PREFETCH_DISTANCE < n:
                var future_key = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                var future_h = _hash_key(future_key)
                var future_pid = _partition_of(future_h)
                var future_slot = (future_pid << self._part_shift) + Int(future_h & self._part_mask)
                prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                    self._keys_mut_ptr() + future_slot
                )

            if probe_has_nulls and _arr_is_null(probe_keys, i):
                continue
            var key = Int64((probe_key_ptr + i)[])
            if self.contains(key):
                result.append(i)

        _ = probe_keys  # keepalive
        return result^

    def probe_semi_count(mut self, probe_keys: PrimitiveArray[DType.int64]) -> Int:
        """Semi-join probe: return the COUNT of probe rows with a match.

        Args:
            probe_keys: The probe-side join key column.

        Returns:
            Number of probe rows with at least one match in the build set.
        """
        var n = probe_keys.length
        var count = 0
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        for i in range(n):
            if i + _PREFETCH_DISTANCE < n:
                var future_key = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                var future_h = _hash_key(future_key)
                var future_pid = _partition_of(future_h)
                var future_slot = (future_pid << self._part_shift) + Int(future_h & self._part_mask)
                prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                    self._keys_mut_ptr() + future_slot
                )

            if probe_has_nulls and _arr_is_null(probe_keys, i):
                continue
            var key = Int64((probe_key_ptr + i)[])
            if self.contains(key):
                count += 1

        _ = probe_keys  # keepalive
        return count

    def probe_semi_parallel(
        mut self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        probe_keys: PrimitiveArray[DType.int64],
        mut result: List[Int],
    ) raises:
        """Parallel semi-join probe: append, in probe order, the probe rows
        whose key is in the set (a NULL key never is). Serial below
        `SEMI_PROBE_PARALLEL_MIN_ROWS` probe rows.

        Args:
            dispatcher: Caller-owned LocalDispatcher, borrowed for the probe.
            cancel_token: Caller-supplied CancellationToken (consumed).
            probe_keys: The probe-side join key column.
            result: Output list for matching probe indices (appended).
        """
        var num_probe_rows = probe_keys.length
        var probe_view = probe_keys.view_ro()
        # SAFETY: both pointers are read-only views of `probe_keys`, borrowed
        # for this call; the views pin the buffers across the dispatch.
        var probe_key_ptr = (
            probe_view._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[False]()
        )
        var probe_has_nulls = probe_keys.null_count != 0
        if probe_has_nulls and probe_keys.validity:
            ref _vbm = probe_keys.validity.value()
            var valid_view = _vbm.buffer.view_ro()
            var valid_byte_ptr = valid_view._unsafe_ptr().unsafe_mut_cast[False]()
            self._probe_semi_parallel_ptrs(
                dispatcher, cancel_token^, probe_key_ptr, num_probe_rows,
                result, valid_byte_ptr, probe_keys.offset, True,
            )
            _ = valid_view
        else:
            var _no_valid = (
                probe_view._unsafe_ptr().bitcast[UInt8]().unsafe_mut_cast[False]()
            )
            self._probe_semi_parallel_ptrs(
                dispatcher, cancel_token^, probe_key_ptr, num_probe_rows,
                result, _no_valid, 0, False,
            )
        _ = probe_keys  # keepalive
        _ = probe_view

    def _probe_semi_parallel_ptrs[
        _mut: Bool, o_probe: Origin[mut=_mut],
        _vmut: Bool, o_valid: Origin[mut=_vmut], //
    ](
        mut self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        probe_key_ptr: UnsafePointer[Scalar[DType.int64], o_probe],
        num_probe_rows: Int,
        mut result: List[Int],
        probe_valid_ptr: UnsafePointer[UInt8, o_valid],
        probe_valid_offset: Int,
        probe_has_nulls: Bool,
    ) raises:
        """`probe_semi_parallel` over raw key and validity pointers: morsels
        of the probe rows are stolen by the workers (`_ProbeWork`), each
        collecting its matches, which are then concatenated in morsel order.
        """
        # SAFETY: the table and its partition geometry are not mutated after
        # construction; the workers only read them.

        var pool_n = dispatcher.worker_count()
        var morsel_size = FORK_GRAIN_MAX_ROWS
        var num_morsels = 1
        if num_probe_rows > SEMI_PROBE_PARALLEL_MIN_ROWS:
            morsel_size = parallel_fork_grain(num_probe_rows, pool_n)
            num_morsels = (num_probe_rows + morsel_size - 1) // morsel_size
        var num_workers = min(num_morsels, pool_n)
        grain_geometry_record(
            SITE_SEMI_PROBE_INDEX,
            num_probe_rows,
            morsel_size,
            num_morsels,
            num_workers,
        )

        if num_morsels <= 1:
            for i in range(num_probe_rows):
                if i + _PREFETCH_DISTANCE < num_probe_rows:
                    var fk = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                    var fh = _hash_key(fk)
                    var fpid = _partition_of(fh)
                    var fs = (fpid << self._part_shift) + Int(fh & self._part_mask)
                    prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                        self._keys_mut_ptr() + fs
                    )
                if probe_has_nulls and _probe_bit_is_null(
                    probe_valid_ptr, probe_valid_offset, i
                ):
                    continue
                var key = Int64((probe_key_ptr + i)[])
                if self.contains(key):
                    result.append(i)
            return

        # SAFETY: `ImmStaticOrigin` stands for "outlives the dispatch": the
        # table and the probe buffers are borrowed by this call, and
        # `parallel_steal` joins every worker before it returns.
        var ht_keys_immut = (
            self._keys_mut_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmStaticOrigin]()
        )
        var probe_immut = (
            probe_key_ptr
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmStaticOrigin]()
        )
        var valid_immut = (
            probe_valid_ptr
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmStaticOrigin]()
        )
        var sin = _ProbeInput(
            ht_keys_immut,
            self._part_mask,
            self._part_shift,
            probe_immut,
            num_probe_rows,
            morsel_size,
            valid_immut,
            probe_valid_offset,
            probe_has_nulls,
            self._has_min_key,
        )
        var work = _ProbeWork(Int32(0))
        var disp_ptr = Pointer(to=dispatcher)
        var per_worker = parallel_steal[
            _ProbeWork,
            _ProbeInput,
            _ProbeMatches,
            origin_of(sin),
            origin_of(dispatcher),
        ](
            work^,
            sin,
            num_morsels,
            disp_ptr,
            cancel_token^,
            min_parallel_items=2,
        )

        var ordered = List[List[Int]](capacity=num_morsels)
        for _ in range(num_morsels):
            ordered.append(List[Int]())
        var nw = per_worker.len()
        var w = 0
        while w < nw:
            ref slot = per_worker.get_mut_interior(w)
            if slot:
                ref pm = slot.value()
                var k = 0
                while k < len(pm.morsels):
                    var mi = pm.morsels[k]
                    swap(ordered[mi], pm.lists[k])
                    k = k + 1
            w = w + 1
        _ = per_worker^

        var total_matches = 0
        for m in range(num_morsels):
            total_matches += len(ordered[m])

        result.reserve(total_matches)
        for m in range(num_morsels):
            ref morsel_list = ordered[m]
            for j in range(len(morsel_list)):
                result.append(morsel_list[j])

    def probe_anti(mut self, probe_keys: PrimitiveArray[DType.int64]) -> List[Int]:
        """Anti-join probe: return probe indices where the key does NOT exist.

        Args:
            probe_keys: The probe-side join key column.

        Returns:
            List of probe indices with NO match in the build set.
        """
        var n = probe_keys.length
        var result = List[Int](capacity=max(n - self._count, 0))
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        for i in range(n):
            if i + _PREFETCH_DISTANCE < n:
                var future_key = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                var future_h = _hash_key(future_key)
                var future_pid = _partition_of(future_h)
                var future_slot = (future_pid << self._part_shift) + Int(future_h & self._part_mask)
                prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                    self._keys_mut_ptr() + future_slot
                )

            if probe_has_nulls and _arr_is_null(probe_keys, i):
                result.append(i)
                continue
            var key = Int64((probe_key_ptr + i)[])
            if not self.contains(key):
                result.append(i)

        _ = probe_keys  # keepalive
        return result^

    def _probe_count_parallel[
        _mut: Bool, o_probe: Origin[mut=_mut],
        _vmut: Bool, o_valid: Origin[mut=_vmut], //
    ](
        mut self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        probe_key_ptr: UnsafePointer[Scalar[DType.int64], o_probe],
        num_probe_rows: Int,
        probe_valid_ptr: UnsafePointer[UInt8, o_valid],
        probe_valid_offset: Int,
        probe_has_nulls: Bool,
        is_anti: Bool,
    ) raises -> Int:
        """Parallel COUNT-only semi (or, with `is_anti`, anti) probe: the
        work-stealing morsel probe adding counts instead of collecting rows."""
        var pool_n = dispatcher.worker_count()
        var morsel_size = FORK_GRAIN_MAX_ROWS
        var num_morsels = 1
        if num_probe_rows > SEMI_PROBE_PARALLEL_MIN_ROWS:
            morsel_size = parallel_fork_grain(num_probe_rows, pool_n)
            num_morsels = (num_probe_rows + morsel_size - 1) // morsel_size
        grain_geometry_record(
            SITE_SEMI_PROBE_COUNT,
            num_probe_rows,
            morsel_size,
            num_morsels,
            min(num_morsels, pool_n),
        )

        if num_morsels <= 1:
            var count = 0
            for i in range(num_probe_rows):
                if i + _PREFETCH_DISTANCE < num_probe_rows:
                    var fk = Int64((probe_key_ptr + i + _PREFETCH_DISTANCE)[])
                    var fh = _hash_key(fk)
                    var fpid = _partition_of(fh)
                    var fs = (fpid << self._part_shift) + Int(fh & self._part_mask)
                    prefetch[PrefetchOptions().for_read().to_data_cache().low_locality()](
                        self._keys_mut_ptr() + fs
                    )
                var is_null = probe_has_nulls and _probe_bit_is_null(
                    probe_valid_ptr, probe_valid_offset, i
                )
                if is_null:
                    if is_anti:
                        count += 1
                    continue
                var key = Int64((probe_key_ptr + i)[])
                var hit = self.contains(key)
                if is_anti:
                    if not hit:
                        count += 1
                else:
                    if hit:
                        count += 1
            return count

        # SAFETY: `ImmStaticOrigin` stands for "outlives the dispatch": the
        # table and the probe buffers are borrowed by this call, and
        # `parallel_steal` joins every worker before it returns.
        var ht_keys_immut = (
            self._keys_mut_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmStaticOrigin]()
        )
        var probe_immut = (
            probe_key_ptr
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmStaticOrigin]()
        )
        var valid_immut = (
            probe_valid_ptr
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmStaticOrigin]()
        )
        var sin = _ProbeInput(
            ht_keys_immut,
            self._part_mask,
            self._part_shift,
            probe_immut,
            num_probe_rows,
            morsel_size,
            valid_immut,
            probe_valid_offset,
            probe_has_nulls,
            self._has_min_key,
        )
        var work = _ProbeCountWork(is_anti)
        var disp_ptr = Pointer(to=dispatcher)
        var per_worker = parallel_steal[
            _ProbeCountWork,
            _ProbeInput,
            _ProbeCount,
            origin_of(sin),
            origin_of(dispatcher),
        ](
            work^,
            sin,
            num_morsels,
            disp_ptr,
            cancel_token^,
            min_parallel_items=2,
        )

        var total = 0
        var nw = per_worker.len()
        var w = 0
        while w < nw:
            ref slot = per_worker.get_mut_interior(w)
            if slot:
                total += slot.value().count
            w = w + 1
        _ = per_worker^
        return total

    def _count_parallel_over_arr(
        mut self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        probe_keys: PrimitiveArray[DType.int64],
        is_anti: Bool,
    ) raises -> Int:
        """Extract the probe key and validity pointers from `probe_keys` and
        run the parallel count fold (the public API takes the array)."""
        var num_probe_rows = probe_keys.length
        var probe_view = probe_keys.view_ro()
        var probe_key_ptr = (
            probe_view._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[False]()
        )
        var probe_has_nulls = probe_keys.null_count != 0
        var total: Int
        if probe_has_nulls and probe_keys.validity:
            ref _vbm = probe_keys.validity.value()
            var valid_view = _vbm.buffer.view_ro()
            var valid_byte_ptr = valid_view._unsafe_ptr().unsafe_mut_cast[False]()
            total = self._probe_count_parallel(
                dispatcher, cancel_token^, probe_key_ptr, num_probe_rows,
                valid_byte_ptr, probe_keys.offset, True, is_anti,
            )
            _ = valid_view
        else:
            var _no_valid = (
                probe_view._unsafe_ptr().bitcast[UInt8]().unsafe_mut_cast[False]()
            )
            total = self._probe_count_parallel(
                dispatcher, cancel_token^, probe_key_ptr, num_probe_rows,
                _no_valid, 0, False, is_anti,
            )
        _ = probe_keys  # keepalive
        _ = probe_view
        return total

    def probe_semi_count_parallel(
        mut self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        probe_keys: PrimitiveArray[DType.int64],
    ) raises -> Int:
        """Parallel SEMI COUNT: number of probe rows with >= 1 build match.
        A NULL probe key matches nothing, so it is not counted.
        """
        return self._count_parallel_over_arr(
            dispatcher, cancel_token^, probe_keys, is_anti=False,
        )

    def probe_anti_count_parallel(
        mut self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        probe_keys: PrimitiveArray[DType.int64],
    ) raises -> Int:
        """Parallel ANTI COUNT: number of probe rows with NO build match (a
        NULL probe key is unmatched, so it is counted).
        """
        return self._count_parallel_over_arr(
            dispatcher, cancel_token^, probe_keys, is_anti=True,
        )
