# =============================================================================
# radix_join -- the radix-partitioned single-INT64-key hash join, with INNER,
# SEMI, ANTI and LEFT probes.
# =============================================================================

from std.memory import alloc, memset, UnsafePointer
from komira_collections.slab import Slab
from std.sys.intrinsics import prefetch, PrefetchOptions
from std.sys import simd_width_of

from komira_arrow.primitive_array import PrimitiveArray


comptime _RADIX_BITS: Int = 8
comptime _NUM_PARTITIONS: Int = 256  # 1 << _RADIX_BITS
comptime _RADIX_MASK: UInt64 = 0xFF  # (1 << _RADIX_BITS) - 1

comptime _CHAIN_END: Int = -1

comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15


@always_inline
def _hash_key(key: Int64) -> UInt64:
    """Hash a join key using Fibonacci hashing."""
    var h = UInt64(key) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    if h == 0:
        h = 1
    return h


@always_inline
def _partition_of(h: UInt64) -> Int:
    """Extract partition index from hash (top 8 bits after mixing)."""
    return Int((h >> 56) & _RADIX_MASK)


struct PartitionTable(Movable):
    """Small hash table for one radix partition."""
    # SAFETY: the four arrays are Lists the table owns, sized in __init__ and
    # never grown, so a pointer into one is valid for the table's lifetime.
    # PERF-CRITICAL: the hot paths read them through pointers with the tight
    # origin `origin_of(self)` (on `mut self`), never a wildcard origin, which
    # would suppress ASAP destruction in every scope that touches the table.
    var _keys: List[Int64]
    var _indices: List[Int]
    var _next_chain: List[Int]
    var _buckets: List[Int]
    var capacity: Int
    var count: Int

    def __init__(out self, estimated_rows: Int):
        """Create a partition table sized for estimated_rows.

        Args:
            estimated_rows: Expected number of build rows in this partition.
        """
        var min_cap = max(Int(Float64(estimated_rows) * 1.4) + 1, 16)
        var cap = 1
        while cap < min_cap:
            cap *= 2

        self.capacity = cap
        self.count = 0

        var data_cap = max(estimated_rows + 64, 128)
        self._keys = List[Int64](capacity=data_cap)
        self._keys.resize(unsafe_uninit_length=data_cap)
        self._indices = List[Int](capacity=data_cap)
        self._indices.resize(unsafe_uninit_length=data_cap)
        self._next_chain = List[Int](capacity=data_cap)
        self._next_chain.resize(unsafe_uninit_length=data_cap)
        self._buckets = List[Int](capacity=cap)
        self._buckets.resize(unsafe_uninit_length=cap)

        memset(self._buckets.unsafe_ptr().bitcast[UInt8](), 0xFF, cap * 8)


    # --- Mutable-origin pointer helpers ---
    # SAFETY: a two-step cast (mutability, then origin) re-tags the pointer
    # `list.unsafe_ptr()` returns with the concrete mutable origin
    # `origin_of(self)`, so the compiler tracks the List buffer's liveness
    # through it. Valid for the lifetime of `self`; never held across a List
    # reallocation (the arrays are never grown).

    @always_inline
    def _keys_mut_ptr(mut self) -> UnsafePointer[Int64, origin_of(self)]:
        return self._keys.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()

    @always_inline
    def _indices_mut_ptr(mut self) -> UnsafePointer[Int, origin_of(self)]:
        return self._indices.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()

    @always_inline
    def _next_chain_mut_ptr(mut self) -> UnsafePointer[Int, origin_of(self)]:
        return self._next_chain.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()

    @always_inline
    def _buckets_mut_ptr(mut self) -> UnsafePointer[Int, origin_of(self)]:
        return self._buckets.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()

    # --- Raw pointer accessors ---
    # SAFETY: Returned pointer is borrowed from `self` and valid until the
    # struct is destroyed. Callers must not free the returned pointer.
    # Accessors exist so the hot path in RadixPartitionedHashJoin can issue
    # software prefetches on the bucket array without exposing the field.

    @always_inline
    def _unsafe_buckets_ptr(mut self) -> UnsafePointer[Int, origin_of(self)]:
        """Raw bucket-array pointer. Used for software prefetch only."""
        return self._buckets_mut_ptr()

    @always_inline
    def insert(mut self, key: Int64, original_idx: Int, h: UInt64):
        """Insert a build-side row. Hash already computed by caller.

        Args:
            key: The join key value.
            original_idx: The original row index in the build table.
            h: Pre-computed hash value.
        """
        var mask = self.capacity - 1
        var slot = Int(h) & mask
        var entry_idx = self.count
        var keys_ptr = self._keys_mut_ptr()
        var indices_ptr = self._indices_mut_ptr()
        var next_chain_ptr = self._next_chain_mut_ptr()
        var buckets_ptr = self._buckets_mut_ptr()

        (keys_ptr + entry_idx)[] = key
        (indices_ptr + entry_idx)[] = original_idx
        (next_chain_ptr + entry_idx)[] = (buckets_ptr + slot)[]
        (buckets_ptr + slot)[] = entry_idx
        self.count += 1

    @always_inline
    def probe_inner_into(
        mut self,
        probe_key: Int64,
        probe_idx: Int,
        h: UInt64,
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ):
        """Probe for inner join matches and append to output lists.

        Args:
            probe_key: The probe-side key value.
            probe_idx: The probe-side row index.
            h: Pre-computed hash value.
            build_matches: Output list for build-side row indices.
            probe_matches: Output list for probe-side row indices.
        """
        var mask = self.capacity - 1
        var slot = Int(h) & mask
        var buckets_ptr = self._buckets_mut_ptr()
        var keys_ptr = self._keys_mut_ptr()
        var indices_ptr = self._indices_mut_ptr()
        var next_chain_ptr = self._next_chain_mut_ptr()
        var chain_idx = (buckets_ptr + slot)[]
        while chain_idx != _CHAIN_END:
            if (keys_ptr + chain_idx)[] == probe_key:
                build_matches.append((indices_ptr + chain_idx)[])
                probe_matches.append(probe_idx)
            chain_idx = (next_chain_ptr + chain_idx)[]

    @always_inline
    def probe_semi_into(
        mut self,
        probe_key: Int64,
        h: UInt64,
    ) -> Bool:
        """Check if a key exists in this partition (for semi/anti joins)."""
        var mask = self.capacity - 1
        var slot = Int(h) & mask
        var buckets_ptr = self._buckets_mut_ptr()
        var keys_ptr = self._keys_mut_ptr()
        var next_chain_ptr = self._next_chain_mut_ptr()
        var chain_idx = (buckets_ptr + slot)[]
        while chain_idx != _CHAIN_END:
            if (keys_ptr + chain_idx)[] == probe_key:
                return True
            chain_idx = (next_chain_ptr + chain_idx)[]
        return False


struct RadixPartitionedHashJoin(Movable):
    """Radix-partitioned hash join over one INT64 key: the build side is split
    into 256 partitions by the top 8 bits of the key hash, each with its own
    small chained table, so a probe works in one cache-resident table at a
    time. A NULL key (build or probe) matches nothing."""
    var _partitions: Slab[PartitionTable]
    var _num_build_rows: Int

    def __init__(out self, var partitions: Slab[PartitionTable], num_build_rows: Int):
        self._partitions = partitions^
        self._num_build_rows = num_build_rows


    @staticmethod
    def build(keys: PrimitiveArray[DType.int64]) raises -> RadixPartitionedHashJoin:
        """Build a radix-partitioned hash join from the build-side keys.

        Args:
            keys: The build-side join key column.

        Returns:
            A RadixPartitionedHashJoin ready for probe() calls.
        """
        var n = keys.length
        var has_nulls = keys.null_count != 0
        var key_ptr = keys._typed_ptr_ro()

        # Phase 1: Build histogram of partition sizes.
        # SAFETY: Stack-allocated histogram, zeroed.
        var histogram = alloc[Int](_NUM_PARTITIONS)
        memset(histogram.bitcast[UInt8](), 0, _NUM_PARTITIONS * 8)

        # Pre-compute hashes and partition IDs for all build rows.
        # Store them to avoid recomputing during scatter.
        # SAFETY: Temporary arrays freed at end of this method.
        var hashes = alloc[UInt64](n)
        var part_ids = alloc[Int](n)

        # PERF-CRITICAL: SIMD hash pre-pass — vectorize hash computation,
        # then scalar histogram update (histogram is scatter-add, serial).
        comptime W = simd_width_of[DType.uint64]()
        var fib_vec = SIMD[DType.uint64, W](_FIB_HASH_CONST)
        var zero_vec = SIMD[DType.uint64, W](0)
        var one_vec = SIMD[DType.uint64, W](1)
        var simd_end = (n // W) * W
        var ri = 0
        while ri < simd_end:
            var keys_u64 = key_ptr.bitcast[Scalar[DType.uint64]]().load[width=W](ri)
            var h = keys_u64 * fib_vec
            h = h ^ (h >> 32)
            h = (h.eq(zero_vec)).select(one_vec, h)
            hashes.bitcast[Scalar[DType.uint64]]().store[width=W](ri, h)
            ri += W
        while ri < n:
            (hashes + ri)[] = _hash_key(Int64((key_ptr + ri)[]))
            ri += 1
        for i in range(n):
            var pid = _partition_of((hashes + i)[])
            (part_ids + i)[] = pid
            if has_nulls and keys.is_null(i):
                continue
            (histogram + pid)[] = (histogram + pid)[] + 1

        var partitions = Slab[PartitionTable].create(_NUM_PARTITIONS)
        for p in range(_NUM_PARTITIONS):
            var est = (histogram + p)[]
            partitions.append(PartitionTable(est))

        # Phase 3: Scatter build rows into partitions.
        # PERF-CRITICAL: one base pointer to the partition Slab for the inner
        # loop (through the Slab's interior-mutability primitive). SAFETY: the
        # Slab is local, filled above and not resized while the pointer lives.
        var parts_ptr = UnsafePointer(to=partitions.get_mut_interior(0))
        for i in range(n):
            if has_nulls and keys.is_null(i):
                continue
            var key = Int64((key_ptr + i)[])
            var h = (hashes + i)[]
            var pid = (part_ids + i)[]
            (parts_ptr + pid)[].insert(key, i, h)

        histogram.free()
        hashes.free()
        part_ids.free()

        _ = keys  # keepalive

        return RadixPartitionedHashJoin(partitions^, n)

    # =================================================================
    # PERF-CRITICAL: Partition-wise probe (scatter-then-probe pattern)
    # =================================================================
    # Probe rows are scattered into per-partition lists first, so each
    # partition's table (about 4 KB) stays in L1 for all of its probe rows;
    # probing row by row would touch a random partition per row and evict
    # between them. DuckDB's counterpart is its partition-local probe of a
    # radix-partitioned hash table. Do not remove without rerunning the
    # inner-join and join-heavy benchmarks.
    # =================================================================

    def probe_inner_into(
        mut self,
        probe_keys: PrimitiveArray[DType.int64],
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """Inner radix-partitioned probe using partition-wise scatter.

        Args:
            probe_keys: The probe-side join key column.
            build_matches: Output list for build-side row indices (appended).
            probe_matches: Output list for probe-side row indices (appended).
        """
        var n = probe_keys.length
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        # Phase 1: Pre-compute hashes and partition IDs.
        # SAFETY: Temporary arrays, freed at end of this method.
        var hashes = alloc[UInt64](n)
        var part_ids = alloc[Int](n)

        for i in range(n):
            var key = Int64((probe_key_ptr + i)[])
            var h = _hash_key(key)
            (hashes + i)[] = h
            (part_ids + i)[] = _partition_of(h)

        var histogram = alloc[Int](_NUM_PARTITIONS)
        memset(histogram.bitcast[UInt8](), 0, _NUM_PARTITIONS * 8)
        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                continue
            (histogram + (part_ids + i)[])[] += 1

        var part_offsets = alloc[Int](_NUM_PARTITIONS + 1)
        var running = 0
        for p in range(_NUM_PARTITIONS):
            (part_offsets + p)[] = running
            running += (histogram + p)[]
        (part_offsets + _NUM_PARTITIONS)[] = running

        var flat_probe_idx = alloc[Int](n)
        var flat_probe_hash = alloc[UInt64](n)
        var write_cursors = alloc[Int](_NUM_PARTITIONS)
        for p in range(_NUM_PARTITIONS):
            (write_cursors + p)[] = (part_offsets + p)[]

        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                continue
            var pid = (part_ids + i)[]
            var w = (write_cursors + pid)[]
            (flat_probe_idx + w)[] = i
            (flat_probe_hash + w)[] = (hashes + i)[]
            (write_cursors + pid)[] = w + 1

        for p in range(_NUM_PARTITIONS):
            var start = (part_offsets + p)[]
            var end = (part_offsets + p + 1)[]
            if start == end:
                continue
            var pt_ptr = UnsafePointer(to=self._partitions.get_mut_interior(p))
            for j in range(start, end):
                var probe_idx = (flat_probe_idx + j)[]
                var h = (flat_probe_hash + j)[]
                var probe_key = Int64((probe_key_ptr + probe_idx)[])
                pt_ptr[].probe_inner_into(
                    probe_key, probe_idx, h, build_matches, probe_matches,
                )

        flat_probe_idx.free()
        flat_probe_hash.free()
        write_cursors.free()
        part_offsets.free()
        histogram.free()
        hashes.free()
        part_ids.free()

        _ = probe_keys  # keepalive

    def probe_inner(mut self, probe_keys: PrimitiveArray[DType.int64]) raises -> Tuple[List[Int], List[Int]]:
        """Inner join probe using radix partitioning. Tuple-returning wrapper.

        Args:
            probe_keys: The probe-side join key column.

        Returns:
            A tuple of (build_indices, probe_indices).
        """
        var est_matches = min(probe_keys.length, self._num_build_rows)
        var build_matches = List[Int](capacity=est_matches)
        var probe_matches = List[Int](capacity=est_matches)
        self.probe_inner_into(probe_keys, build_matches, probe_matches)
        return (build_matches^, probe_matches^)

    def probe_semi(mut self, probe_keys: PrimitiveArray[DType.int64]) raises -> List[Int]:
        """Semi-join probe using partition-wise scatter (CSR layout)."""
        comptime W = simd_width_of[DType.uint64]()
        var n = probe_keys.length
        var result = List[Int](capacity=min(n, self._num_build_rows))
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        # PERF-CRITICAL: SIMD hash pre-pass for probe side.
        var hashes_buf = alloc[UInt64](n)
        var part_ids_buf = alloc[Int](n)
        var _fib_v = SIMD[DType.uint64, W](_FIB_HASH_CONST)
        var _z_v = SIMD[DType.uint64, W](0)
        var _o_v = SIMD[DType.uint64, W](1)
        var _se = (n // W) * W
        var _ri = 0
        while _ri < _se:
            var _ku = probe_key_ptr.bitcast[Scalar[DType.uint64]]().load[width=W](_ri)
            var _hv = _ku * _fib_v
            _hv = _hv ^ (_hv >> 32)
            _hv = (_hv.eq(_z_v)).select(_o_v, _hv)
            hashes_buf.bitcast[Scalar[DType.uint64]]().store[width=W](_ri, _hv)
            _ri += W
        while _ri < n:
            (hashes_buf + _ri)[] = _hash_key(Int64((probe_key_ptr + _ri)[]))
            _ri += 1
        for i in range(n):
            (part_ids_buf + i)[] = _partition_of((hashes_buf + i)[])

        var histogram = alloc[Int](_NUM_PARTITIONS)
        memset(histogram.bitcast[UInt8](), 0, _NUM_PARTITIONS * 8)
        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                continue
            (histogram + (part_ids_buf + i)[])[] += 1

        var part_offsets = alloc[Int](_NUM_PARTITIONS + 1)
        var running = 0
        for p in range(_NUM_PARTITIONS):
            (part_offsets + p)[] = running
            running += (histogram + p)[]
        (part_offsets + _NUM_PARTITIONS)[] = running

        var flat_probe_idx = alloc[Int](n)
        var flat_probe_hash = alloc[UInt64](n)
        var write_cursors = alloc[Int](_NUM_PARTITIONS)
        for p in range(_NUM_PARTITIONS):
            (write_cursors + p)[] = (part_offsets + p)[]

        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                continue
            var pid = (part_ids_buf + i)[]
            var w = (write_cursors + pid)[]
            (flat_probe_idx + w)[] = i
            (flat_probe_hash + w)[] = (hashes_buf + i)[]
            (write_cursors + pid)[] = w + 1

        for p in range(_NUM_PARTITIONS):
            var start = (part_offsets + p)[]
            var end = (part_offsets + p + 1)[]
            if start == end:
                continue
            var pt_ptr = UnsafePointer(to=self._partitions.get_mut_interior(p))
            for j in range(start, end):
                var probe_idx = (flat_probe_idx + j)[]
                var h = (flat_probe_hash + j)[]
                var probe_key = Int64((probe_key_ptr + probe_idx)[])
                if pt_ptr[].probe_semi_into(probe_key, h):
                    result.append(probe_idx)

        flat_probe_idx.free()
        flat_probe_hash.free()
        write_cursors.free()
        part_offsets.free()
        histogram.free()
        hashes_buf.free()
        part_ids_buf.free()

        _ = probe_keys  # keepalive
        return result^

    def probe_anti(mut self, probe_keys: PrimitiveArray[DType.int64]) raises -> List[Int]:
        """Anti-join probe using partition-wise scatter (CSR layout)."""
        comptime W = simd_width_of[DType.uint64]()
        var n = probe_keys.length
        var result = List[Int](capacity=n - min(n, self._num_build_rows))
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        # PERF-CRITICAL: SIMD hash pre-pass for probe side.
        var hashes_buf = alloc[UInt64](n)
        var part_ids_buf = alloc[Int](n)
        var _fib_v = SIMD[DType.uint64, W](_FIB_HASH_CONST)
        var _z_v = SIMD[DType.uint64, W](0)
        var _o_v = SIMD[DType.uint64, W](1)
        var _se = (n // W) * W
        var _ri = 0
        while _ri < _se:
            var _ku = probe_key_ptr.bitcast[Scalar[DType.uint64]]().load[width=W](_ri)
            var _hv = _ku * _fib_v
            _hv = _hv ^ (_hv >> 32)
            _hv = (_hv.eq(_z_v)).select(_o_v, _hv)
            hashes_buf.bitcast[Scalar[DType.uint64]]().store[width=W](_ri, _hv)
            _ri += W
        while _ri < n:
            (hashes_buf + _ri)[] = _hash_key(Int64((probe_key_ptr + _ri)[]))
            _ri += 1
        for i in range(n):
            (part_ids_buf + i)[] = _partition_of((hashes_buf + i)[])

        var histogram = alloc[Int](_NUM_PARTITIONS)
        memset(histogram.bitcast[UInt8](), 0, _NUM_PARTITIONS * 8)
        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                continue
            (histogram + (part_ids_buf + i)[])[] += 1

        var part_offsets = alloc[Int](_NUM_PARTITIONS + 1)
        var running = 0
        for p in range(_NUM_PARTITIONS):
            (part_offsets + p)[] = running
            running += (histogram + p)[]
        (part_offsets + _NUM_PARTITIONS)[] = running

        var flat_probe_idx = alloc[Int](n)
        var flat_probe_hash = alloc[UInt64](n)
        var write_cursors = alloc[Int](_NUM_PARTITIONS)
        for p in range(_NUM_PARTITIONS):
            (write_cursors + p)[] = (part_offsets + p)[]

        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                result.append(i)
                continue
            var pid = (part_ids_buf + i)[]
            var w = (write_cursors + pid)[]
            (flat_probe_idx + w)[] = i
            (flat_probe_hash + w)[] = (hashes_buf + i)[]
            (write_cursors + pid)[] = w + 1

        for p in range(_NUM_PARTITIONS):
            var start = (part_offsets + p)[]
            var end = (part_offsets + p + 1)[]
            if start == end:
                continue
            var pt_ptr = UnsafePointer(to=self._partitions.get_mut_interior(p))
            for j in range(start, end):
                var probe_idx = (flat_probe_idx + j)[]
                var h = (flat_probe_hash + j)[]
                var probe_key = Int64((probe_key_ptr + probe_idx)[])
                if not pt_ptr[].probe_semi_into(probe_key, h):
                    result.append(probe_idx)

        flat_probe_idx.free()
        flat_probe_hash.free()
        write_cursors.free()
        part_offsets.free()
        histogram.free()
        hashes_buf.free()
        part_ids_buf.free()

        _ = probe_keys  # keepalive
        return result^

    def probe_left_into(
        mut self,
        probe_keys: PrimitiveArray[DType.int64],
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """Left outer radix-partitioned probe using partition-wise scatter (CSR).

        Args:
            probe_keys: The probe-side join key column.
            build_matches: Output list for build-side row indices (-1 when
                no match); appended.
            probe_matches: Output list for probe-side row indices; appended.
        """
        var n = probe_keys.length
        var probe_has_nulls = probe_keys.null_count != 0
        var probe_key_ptr = probe_keys._typed_ptr_ro()

        var hashes_buf = alloc[UInt64](n)
        var part_ids_buf = alloc[Int](n)

        for i in range(n):
            var key = Int64((probe_key_ptr + i)[])
            var h = _hash_key(key)
            (hashes_buf + i)[] = h
            (part_ids_buf + i)[] = _partition_of(h)

        var histogram = alloc[Int](_NUM_PARTITIONS)
        memset(histogram.bitcast[UInt8](), 0, _NUM_PARTITIONS * 8)
        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                continue
            (histogram + (part_ids_buf + i)[])[] += 1

        var part_offsets = alloc[Int](_NUM_PARTITIONS + 1)
        var running = 0
        for p in range(_NUM_PARTITIONS):
            (part_offsets + p)[] = running
            running += (histogram + p)[]
        (part_offsets + _NUM_PARTITIONS)[] = running

        var flat_probe_idx = alloc[Int](n)
        var flat_probe_hash = alloc[UInt64](n)
        var write_cursors = alloc[Int](_NUM_PARTITIONS)
        for p in range(_NUM_PARTITIONS):
            (write_cursors + p)[] = (part_offsets + p)[]

        for i in range(n):
            if probe_has_nulls and probe_keys.is_null(i):
                build_matches.append(-1)
                probe_matches.append(i)
                continue
            var pid = (part_ids_buf + i)[]
            var w = (write_cursors + pid)[]
            (flat_probe_idx + w)[] = i
            (flat_probe_hash + w)[] = (hashes_buf + i)[]
            (write_cursors + pid)[] = w + 1

        for p in range(_NUM_PARTITIONS):
            var start = (part_offsets + p)[]
            var end = (part_offsets + p + 1)[]
            if start == end:
                continue
            var pt_ptr = UnsafePointer(to=self._partitions.get_mut_interior(p))
            for j in range(start, end):
                var probe_idx = (flat_probe_idx + j)[]
                var h = (flat_probe_hash + j)[]
                var probe_key = Int64((probe_key_ptr + probe_idx)[])
                var pre_len = len(build_matches)
                pt_ptr[].probe_inner_into(
                    probe_key, probe_idx, h, build_matches, probe_matches,
                )
                if len(build_matches) == pre_len:
                    build_matches.append(-1)
                    probe_matches.append(probe_idx)

        flat_probe_idx.free()
        flat_probe_hash.free()
        write_cursors.free()
        part_offsets.free()
        histogram.free()
        hashes_buf.free()
        part_ids_buf.free()

        _ = probe_keys  # keepalive

    def probe_left(mut self, probe_keys: PrimitiveArray[DType.int64]) raises -> Tuple[List[Int], List[Int]]:
        """Left outer join probe: the Tuple-returning form.

        Args:
            probe_keys: The probe-side join key column.

        Returns:
            A tuple of (build_indices, probe_indices). build_indices[i] is -1
            when there is no match.
        """
        var build_matches = List[Int](capacity=probe_keys.length)
        var probe_matches = List[Int](capacity=probe_keys.length)
        self.probe_left_into(probe_keys, build_matches, probe_matches)
        return (build_matches^, probe_matches^)


comptime RADIX_JOIN_THRESHOLD: Int = 50_000


@always_inline
def should_use_radix_join(build_rows: Int) -> Bool:
    """True above `RADIX_JOIN_THRESHOLD` build rows."""
    return build_rows > RADIX_JOIN_THRESHOLD
