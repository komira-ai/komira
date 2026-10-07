# =============================================================================
# Aggregation Engine -- Hash-based GROUP BY aggregation
# =============================================================================
#
# Implements hash-based GROUP BY aggregation with per-group accumulators.
# Uses open-addressing with linear probing and power-of-2 capacity.
#
# Accumulator types are in accumulators.mojo (AggAccumulator, etc.)
# Statistical accumulators are in statistical_accumulators.mojo
#
# Reference: Rust aggregate/hash_map.rs, aggregate/accumulator.rs
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.dictionary_array import StringDictionaryArray

# Re-export accumulators so existing imports still work
from .accumulators import (
    CountDistinctAccumulator,
    AggAccumulator,
    MultiAggAccumulator,
)
from .statistical_accumulators import (
    StddevAccumulator,
    PercentileAccumulator,
    CovarianceAccumulator,
    CorrelationAccumulator,
)


# =============================================================================
# HashAggregator -- Hash-based GROUP BY engine
# =============================================================================

# Sentinel value for empty hash table slots.
comptime _EMPTY_SLOT: Int = -1

# Fibonacci hashing constant for 64-bit: 2^64 / phi
comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15


@always_inline
def _hash_key(key: Int64) -> UInt64:
    """Compute a hash for an Int64 group key."""
    var h = UInt64(key) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    return h


struct HashAggregator(Movable):
    """Hash-based GROUP BY aggregation.

    Groups rows by a key column (Int64), maintains per-group accumulators.
    Uses open-addressing with linear probing and power-of-2 capacity.

    Fields:
        keys: List of unique group key values, indexed by group_id.
        accumulators: Per-group accumulators, indexed by group_id.
        hash_table: Open-addressing hash table mapping hash slots to group indices.
        capacity: Current hash table capacity (always a power of 2).
        num_groups: Number of unique groups inserted so far.
    """

    var keys: List[Int64]
    var accumulators: List[AggAccumulator]
    var hash_table: List[Int]
    var capacity: Int
    var num_groups: Int

    def __init__(out self, var keys: List[Int64], var accumulators: List[AggAccumulator],
                 var hash_table: List[Int], capacity: Int, num_groups: Int):
        self.keys = keys^
        self.accumulators = accumulators^
        self.hash_table = hash_table^
        self.capacity = capacity
        self.num_groups = num_groups

    @staticmethod
    def create(initial_capacity: Int = 1024) -> HashAggregator:
        """Create a new empty HashAggregator."""
        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        var ht = List[Int]()
        for _ in range(cap):
            ht.append(_EMPTY_SLOT)

        return HashAggregator(
            keys=List[Int64](),
            accumulators=List[AggAccumulator](),
            hash_table=ht^,
            capacity=cap,
            num_groups=0,
        )

    @always_inline
    def _slot_for_hash(self, h: UInt64) -> Int:
        return Int(h & UInt64(self.capacity - 1))

    def _resize(mut self):
        """Double the hash table capacity and rehash all entries."""
        var new_cap = self.capacity * 2
        var new_ht = List[Int]()
        for _ in range(new_cap):
            new_ht.append(_EMPTY_SLOT)

        var new_mask = UInt64(new_cap - 1)

        for i in range(self.num_groups):
            var h = _hash_key(self.keys[i])
            var slot = Int(h & new_mask)
            while new_ht[slot] != _EMPTY_SLOT:
                slot = (slot + 1) & Int(new_mask)
            new_ht[slot] = i

        self.hash_table = new_ht^
        self.capacity = new_cap

    @always_inline
    def insert(mut self, key: Int64, value: Float64):
        """Insert or update a (key, value) pair into the aggregator."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var h = _hash_key(key)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.keys.append(key)
                self.accumulators.append(AggAccumulator.create())
                self.accumulators[group_id].update(value)
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return
            elif self.keys[idx] == key:
                self.accumulators[idx].update(value)
                return
            else:
                slot = (slot + 1) & mask

    def insert_batch(mut self, keys: PrimitiveArray[DType.int64], values: PrimitiveArray[DType.float64]) raises:
        """Insert all rows from key and value arrays.

        Uses software prefetch to hide L3 latency when the hash table
        exceeds L2 cache. Prefetch distance of 8 rows ahead targets
        ~40 cycle L3 latency on Apple M-series.
        """
        from std.sys.intrinsics import prefetch, PrefetchOptions

        var n = keys.length
        # Z.W3-D2: tight-origin typed reads (drop-in). PrimitiveArray's
        # `_typed_ptr_ro` is dtype-implicit (`Scalar[Self.dtype]`).
        var key_ptr = keys._typed_ptr_ro()
        var val_ptr = values._typed_ptr_ro()

        comptime PF_DIST = 8
        var ht_ptr = self.hash_table.unsafe_ptr()

        for i in range(n):
            # Software prefetch: hash a future key and prefetch the hash table slot.
            if i + PF_DIST < n:
                var fk = Int64((key_ptr + i + PF_DIST)[])
                var fh = _hash_key(fk)
                var fslot = Int(fh & UInt64(self.capacity - 1))
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (ht_ptr + fslot).bitcast[Scalar[DType.int64]]()
                )

            var k = Int64((key_ptr + i)[])
            var v = Float64((val_ptr + i)[])
            self.insert(k, v)

        # Keepalive: hash_table must outlive raw pointer access
        _ = self.hash_table

    def get_results(self) -> Tuple[List[Int64], List[Float64], List[Int], List[Float64], List[Float64]]:
        """Extract aggregation results for all groups."""
        var out_keys = List[Int64]()
        var out_sums = List[Float64]()
        var out_counts = List[Int]()
        var out_mins = List[Float64]()
        var out_maxs = List[Float64]()

        for i in range(self.num_groups):
            out_keys.append(self.keys[i])
            out_sums.append(self.accumulators[i].sum)
            out_counts.append(self.accumulators[i].count)
            out_mins.append(self.accumulators[i].min_val)
            out_maxs.append(self.accumulators[i].max_val)

        return (out_keys^, out_sums^, out_counts^, out_mins^, out_maxs^)


# =============================================================================
# HashMultiAggregator -- single int64 key, N independent agg slots
# =============================================================================
#
# Like HashAggregator but uses MultiAggAccumulator so that each agg expression
# can reference a DIFFERENT value column. This avoids falling to the expensive
# CompositeKeyAggregator (string-serialized keys) when the only reason is
# multiple value columns with a single integer group key.
# =============================================================================


struct HashMultiAggregator(Movable):
    """Hash-based GROUP BY with N independent agg slots per group.

    Same int64-keyed open-addressing hash table as HashAggregator, but each
    group stores a MultiAggAccumulator with num_aggs independent slots.
    """

    var keys: List[Int64]
    var accumulators: List[MultiAggAccumulator]
    var hash_table: List[Int]
    var capacity: Int
    var num_groups: Int
    var num_aggs: Int

    def __init__(out self, var keys: List[Int64],
                 var accumulators: List[MultiAggAccumulator],
                 var hash_table: List[Int], capacity: Int,
                 num_groups: Int, num_aggs: Int):
        self.keys = keys^
        self.accumulators = accumulators^
        self.hash_table = hash_table^
        self.capacity = capacity
        self.num_groups = num_groups
        self.num_aggs = num_aggs

    @staticmethod
    def create(num_aggs: Int, initial_capacity: Int = 1024) -> HashMultiAggregator:
        """Create a new empty HashMultiAggregator."""
        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        var ht = List[Int]()
        for _ in range(cap):
            ht.append(_EMPTY_SLOT)

        return HashMultiAggregator(
            keys=List[Int64](),
            accumulators=List[MultiAggAccumulator](),
            hash_table=ht^,
            capacity=cap,
            num_groups=0,
            num_aggs=num_aggs,
        )

    @always_inline
    def _slot_for_hash(self, h: UInt64) -> Int:
        return Int(h & UInt64(self.capacity - 1))

    def _resize(mut self):
        """Double the hash table capacity and rehash all entries."""
        var new_cap = self.capacity * 2
        var new_ht = List[Int]()
        for _ in range(new_cap):
            new_ht.append(_EMPTY_SLOT)

        var new_mask = UInt64(new_cap - 1)
        for i in range(self.num_groups):
            var h = _hash_key(self.keys[i])
            var slot = Int(h & new_mask)
            while new_ht[slot] != _EMPTY_SLOT:
                slot = (slot + 1) & Int(new_mask)
            new_ht[slot] = i

        self.hash_table = new_ht^
        self.capacity = new_cap

    @always_inline
    def _find_or_create(mut self, key: Int64) -> Int:
        """Find existing group or create a new one. Returns group index."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var h = _hash_key(key)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.keys.append(key)
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return group_id
            elif self.keys[idx] == key:
                return idx
            else:
                slot = (slot + 1) & mask

    @always_inline
    def insert(mut self, key: Int64, agg_index: Int, value: Float64):
        """Insert a value for a specific agg slot in the group identified by key."""
        var gid = self._find_or_create(key)
        self.accumulators[gid].update(agg_index, value)

    @always_inline
    def insert_count(mut self, key: Int64, agg_index: Int):
        """Insert a COUNT(*) tick for a specific agg slot."""
        var gid = self._find_or_create(key)
        self.accumulators[gid].update_count_only(agg_index)


# =============================================================================
# DictAwareAggregator -- Dictionary-aware GROUP BY engine
# =============================================================================


struct DictAwareAggregator(Movable):
    """Aggregation using dictionary indices as group IDs."""

    var accumulators: List[AggAccumulator]
    var dict_size: Int

    def __init__(out self, var accumulators: List[AggAccumulator], dict_size: Int):
        self.accumulators = accumulators^
        self.dict_size = dict_size

    @staticmethod
    def create(dict_size: Int) -> DictAwareAggregator:
        """Create a new DictAwareAggregator for a dictionary of the given size."""
        var accs = List[AggAccumulator]()
        for _ in range(dict_size):
            accs.append(AggAccumulator.create())
        return DictAwareAggregator(accs^, dict_size)

    @always_inline
    def insert(mut self, dict_index: Int32, value: Float64):
        """Insert a value for the group identified by dict_index."""
        self.accumulators[Int(dict_index)].update(value)

    def insert_batch(
        mut self,
        indices: PrimitiveArray[DType.int32],
        values: PrimitiveArray[DType.float64],
    ) raises:
        """Insert all rows from index and value arrays."""
        # Z.4-continue: migrated `_unsafe_data_ptr()` callers onto
        # PrimitiveArray.get_typed[Scalar[T]].
        var n = indices.length
        for i in range(n):
            self.accumulators[Int(indices.get_typed[Scalar[DType.int32]](i))].update(
                Float64(values.get_typed[Scalar[DType.float64]](i))
            )

    @always_inline
    def active_groups(self) -> Int:
        """Count groups with at least one row."""
        var count = 0
        for i in range(self.dict_size):
            if self.accumulators[i].count > 0:
                count += 1
        return count

    def get_results(self) -> Tuple[List[Int], List[Float64], List[Int], List[Float64], List[Float64]]:
        """Extract aggregation results for all active groups."""
        var out_keys = List[Int]()
        var out_sums = List[Float64]()
        var out_counts = List[Int]()
        var out_mins = List[Float64]()
        var out_maxs = List[Float64]()

        for i in range(self.dict_size):
            if self.accumulators[i].count > 0:
                out_keys.append(i)
                out_sums.append(self.accumulators[i].sum)
                out_counts.append(self.accumulators[i].count)
                out_mins.append(self.accumulators[i].min_val)
                out_maxs.append(self.accumulators[i].max_val)

        return (out_keys^, out_sums^, out_counts^, out_mins^, out_maxs^)


# =============================================================================
# CompositeKeyAggregator -- Multi-column GROUP BY engine
# =============================================================================


@always_inline
def _hash_string(s: String) -> UInt64:
    """Compute a hash for a String key."""
    return hash(s)


@always_inline
def _composite_hash(keys: List[String]) -> UInt64:
    """Compute a composite hash for multiple string keys."""
    var h = UInt64(0)
    for i in range(len(keys)):
        var key_hash = _hash_string(keys[i])
        var shift = UInt64(i * 16) % UInt64(64)
        var rotated = (key_hash << shift) | (key_hash >> (UInt64(64) - shift))
        h = h ^ rotated
    return h


struct CompositeKeyAggregator(Movable):
    """GROUP BY on multiple columns using composite key hashing."""

    var key_strings: List[String]
    var accumulators: List[MultiAggAccumulator]
    var hash_table: List[Int]
    var capacity: Int
    var num_groups: Int
    var num_aggs: Int

    def __init__(out self, var key_strings: List[String],
                 var accumulators: List[MultiAggAccumulator],
                 var hash_table: List[Int], capacity: Int,
                 num_groups: Int, num_aggs: Int):
        self.key_strings = key_strings^
        self.accumulators = accumulators^
        self.hash_table = hash_table^
        self.capacity = capacity
        self.num_groups = num_groups
        self.num_aggs = num_aggs

    @staticmethod
    def create(num_aggs: Int, initial_capacity: Int = 1024) -> CompositeKeyAggregator:
        """Create a new empty CompositeKeyAggregator."""
        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        var ht = List[Int]()
        for _ in range(cap):
            ht.append(_EMPTY_SLOT)

        return CompositeKeyAggregator(
            key_strings=List[String](),
            accumulators=List[MultiAggAccumulator](),
            hash_table=ht^,
            capacity=cap,
            num_groups=0,
            num_aggs=num_aggs,
        )

    @always_inline
    def _slot_for_hash(self, h: UInt64) -> Int:
        return Int(h & UInt64(self.capacity - 1))

    def _serialize_keys(self, keys: List[String]) -> String:
        var result = String("")
        for i in range(len(keys)):
            if i > 0:
                result += "\x1f"
            result += keys[i]
        return result^

    def _resize(mut self):
        """Double the hash table capacity and rehash all entries."""
        var new_cap = self.capacity * 2
        var new_ht = List[Int]()
        for _ in range(new_cap):
            new_ht.append(_EMPTY_SLOT)

        var new_mask = UInt64(new_cap - 1)

        for i in range(self.num_groups):
            var h = _hash_string(self.key_strings[i])
            var slot = Int(h & new_mask)
            while new_ht[slot] != _EMPTY_SLOT:
                slot = (slot + 1) & Int(new_mask)
            new_ht[slot] = i

        self.hash_table = new_ht^
        self.capacity = new_cap

    def insert(mut self, keys: List[String], agg_index: Int, value: Float64):
        """Insert or update a (composite_key, value) pair for a specific agg slot."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var serialized = self._serialize_keys(keys)
        var h = _hash_string(serialized)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.key_strings.append(serialized)
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.accumulators[group_id].update(agg_index, value)
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return
            elif self.key_strings[idx] == serialized:
                self.accumulators[idx].update(agg_index, value)
                return
            else:
                slot = (slot + 1) & mask

    def insert_count(mut self, keys: List[String], agg_index: Int):
        """Insert a COUNT(*) row for a specific agg slot."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var serialized = self._serialize_keys(keys)
        var h = _hash_string(serialized)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.key_strings.append(serialized)
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.accumulators[group_id].update_count_only(agg_index)
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return
            elif self.key_strings[idx] == serialized:
                self.accumulators[idx].update_count_only(agg_index)
                return
            else:
                slot = (slot + 1) & mask

    @always_inline
    def _find_or_create_serialized(mut self, serialized: String) -> Int:
        """Find existing group or create a new one from a pre-serialized key.

        Returns group index. The caller is responsible for serializing the
        composite key ONCE and passing it here. This avoids the 8x re-serialize
        + re-hash overhead when there are N agg expressions per row.
        """
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var h = _hash_string(serialized)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.key_strings.append(serialized)
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return group_id
            elif self.key_strings[idx] == serialized:
                return idx
            else:
                slot = (slot + 1) & mask

    def insert_multi_agg(mut self, keys: List[String], values: List[Float64]):
        """Insert values for ALL aggregation slots in one call."""
        var serialized = self._serialize_keys(keys)
        var gid = self._find_or_create_serialized(serialized)
        for a in range(len(values)):
            self.accumulators[gid].update(a, values[a])

    def get_group_keys(self, group_id: Int) -> List[String]:
        """Extract the individual key values for a given group."""
        var serialized = self.key_strings[group_id]
        var slices = serialized.split("\x1f")
        var result = List[String]()
        for s in slices:
            result.append(String(s))
        return result^


# =============================================================================
# IntPairKeyAggregator -- 2-column integer GROUP BY (zero string allocation)
# =============================================================================
#
# Replaces CompositeKeyAggregator for the common case of 2 integer group-by
# keys. Stores (Int64, Int64) key pairs directly instead of serializing to
# String. This eliminates 2 * N string allocations per query.
#
# Covers: H2O Q2 (id1, id2), CB-12 (age, sex), CB-17 (counter_id, region_id)
# =============================================================================


@always_inline
def _hash_int_pair(k1: Int64, k2: Int64) -> UInt64:
    """Hash two Int64 keys without string allocation.

    Uses Fibonacci hashing with distinct multipliers per key position to
    produce good distribution with minimal collisions.
    """
    var h1 = UInt64(k1) * _FIB_HASH_CONST
    var h2 = UInt64(k2) * UInt64(0x517CC1B727220A95)  # second Fibonacci prime
    return (h1 ^ (h2 >> 16)) ^ (h2 << 16)


struct IntPairKeyAggregator(Movable):
    """GROUP BY on two integer columns with typed key storage.

    Avoids all string allocation by storing (Int64, Int64) pairs directly.
    Uses the same open-addressing + linear probing pattern as HashAggregator.

    Fields:
        keys_a: First key component per group.
        keys_b: Second key component per group.
        accumulators: Per-group multi-agg accumulators.
        hash_table: Open-addressing hash table mapping slots to group indices.
        capacity: Current hash table capacity (power of 2).
        num_groups: Number of unique groups.
        num_aggs: Number of aggregation slots per group.
    """

    var keys_a: List[Int64]
    var keys_b: List[Int64]
    var accumulators: List[MultiAggAccumulator]
    var hash_table: List[Int]
    var capacity: Int
    var num_groups: Int
    var num_aggs: Int

    def __init__(out self, var keys_a: List[Int64], var keys_b: List[Int64],
                 var accumulators: List[MultiAggAccumulator],
                 var hash_table: List[Int], capacity: Int,
                 num_groups: Int, num_aggs: Int):
        self.keys_a = keys_a^
        self.keys_b = keys_b^
        self.accumulators = accumulators^
        self.hash_table = hash_table^
        self.capacity = capacity
        self.num_groups = num_groups
        self.num_aggs = num_aggs

    @staticmethod
    def create(num_aggs: Int, initial_capacity: Int = 1024) -> IntPairKeyAggregator:
        """Create a new empty IntPairKeyAggregator."""
        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        var ht = List[Int]()
        for _ in range(cap):
            ht.append(_EMPTY_SLOT)

        return IntPairKeyAggregator(
            keys_a=List[Int64](),
            keys_b=List[Int64](),
            accumulators=List[MultiAggAccumulator](),
            hash_table=ht^,
            capacity=cap,
            num_groups=0,
            num_aggs=num_aggs,
        )

    @always_inline
    def _slot_for_hash(self, h: UInt64) -> Int:
        return Int(h & UInt64(self.capacity - 1))

    def _resize(mut self):
        """Double the hash table capacity and rehash all entries."""
        var new_cap = self.capacity * 2
        var new_ht = List[Int]()
        for _ in range(new_cap):
            new_ht.append(_EMPTY_SLOT)

        var new_mask = UInt64(new_cap - 1)

        for i in range(self.num_groups):
            var h = _hash_int_pair(self.keys_a[i], self.keys_b[i])
            var slot = Int(h & new_mask)
            while new_ht[slot] != _EMPTY_SLOT:
                slot = (slot + 1) & Int(new_mask)
            new_ht[slot] = i

        self.hash_table = new_ht^
        self.capacity = new_cap

    @always_inline
    def _find_or_create(mut self, ka: Int64, kb: Int64) -> Int:
        """Find existing group or create new one. Returns group_id."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var h = _hash_int_pair(ka, kb)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.keys_a.append(ka)
                self.keys_b.append(kb)
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return group_id
            elif self.keys_a[idx] == ka and self.keys_b[idx] == kb:
                return idx
            else:
                slot = (slot + 1) & mask

    def insert(mut self, ka: Int64, kb: Int64, agg_index: Int, value: Float64):
        """Insert or update a (key_pair, value) for a specific agg slot."""
        var gid = self._find_or_create(ka, kb)
        self.accumulators[gid].update(agg_index, value)

    def insert_count(mut self, ka: Int64, kb: Int64, agg_index: Int):
        """Insert a COUNT(*) row for a specific agg slot."""
        var gid = self._find_or_create(ka, kb)
        self.accumulators[gid].update_count_only(agg_index)


# =============================================================================
# IntTripleKeyAggregator -- 3-column integer GROUP BY (zero string allocation)
# =============================================================================
#
# Same approach as IntPairKeyAggregator but for 3 integer keys.
# Covers: TPC-H Q16 (brand, type, size)
# =============================================================================


@always_inline
def _hash_int_triple(k1: Int64, k2: Int64, k3: Int64) -> UInt64:
    """Hash three Int64 keys without string allocation."""
    var h1 = UInt64(k1) * _FIB_HASH_CONST
    var h2 = UInt64(k2) * UInt64(0x517CC1B727220A95)
    var h3 = UInt64(k3) * UInt64(0x6C62272E07BB0142)  # third prime
    return (h1 ^ (h2 >> 16) ^ (h3 >> 32)) ^ ((h2 << 16) ^ (h3 << 32))


struct IntTripleKeyAggregator(Movable):
    """GROUP BY on three integer columns with typed key storage."""

    var keys_a: List[Int64]
    var keys_b: List[Int64]
    var keys_c: List[Int64]
    var accumulators: List[MultiAggAccumulator]
    var hash_table: List[Int]
    var capacity: Int
    var num_groups: Int
    var num_aggs: Int

    def __init__(out self, var keys_a: List[Int64], var keys_b: List[Int64],
                 var keys_c: List[Int64],
                 var accumulators: List[MultiAggAccumulator],
                 var hash_table: List[Int], capacity: Int,
                 num_groups: Int, num_aggs: Int):
        self.keys_a = keys_a^
        self.keys_b = keys_b^
        self.keys_c = keys_c^
        self.accumulators = accumulators^
        self.hash_table = hash_table^
        self.capacity = capacity
        self.num_groups = num_groups
        self.num_aggs = num_aggs

    @staticmethod
    def create(num_aggs: Int, initial_capacity: Int = 1024) -> IntTripleKeyAggregator:
        """Create a new empty IntTripleKeyAggregator."""
        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        var ht = List[Int]()
        for _ in range(cap):
            ht.append(_EMPTY_SLOT)

        return IntTripleKeyAggregator(
            keys_a=List[Int64](),
            keys_b=List[Int64](),
            keys_c=List[Int64](),
            accumulators=List[MultiAggAccumulator](),
            hash_table=ht^,
            capacity=cap,
            num_groups=0,
            num_aggs=num_aggs,
        )

    @always_inline
    def _slot_for_hash(self, h: UInt64) -> Int:
        return Int(h & UInt64(self.capacity - 1))

    def _resize(mut self):
        """Double the hash table capacity and rehash all entries."""
        var new_cap = self.capacity * 2
        var new_ht = List[Int]()
        for _ in range(new_cap):
            new_ht.append(_EMPTY_SLOT)

        var new_mask = UInt64(new_cap - 1)

        for i in range(self.num_groups):
            var h = _hash_int_triple(self.keys_a[i], self.keys_b[i], self.keys_c[i])
            var slot = Int(h & new_mask)
            while new_ht[slot] != _EMPTY_SLOT:
                slot = (slot + 1) & Int(new_mask)
            new_ht[slot] = i

        self.hash_table = new_ht^
        self.capacity = new_cap

    @always_inline
    def _find_or_create(mut self, ka: Int64, kb: Int64, kc: Int64) -> Int:
        """Find existing group or create new one. Returns group_id."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var h = _hash_int_triple(ka, kb, kc)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                self.keys_a.append(ka)
                self.keys_b.append(kb)
                self.keys_c.append(kc)
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return group_id
            elif self.keys_a[idx] == ka and self.keys_b[idx] == kb and self.keys_c[idx] == kc:
                return idx
            else:
                slot = (slot + 1) & mask

    def insert(mut self, ka: Int64, kb: Int64, kc: Int64, agg_index: Int, value: Float64):
        """Insert or update a (key_triple, value) for a specific agg slot."""
        var gid = self._find_or_create(ka, kb, kc)
        self.accumulators[gid].update(agg_index, value)

    def insert_count(mut self, ka: Int64, kb: Int64, kc: Int64, agg_index: Int):
        """Insert a COUNT(*) row for a specific agg slot."""
        var gid = self._find_or_create(ka, kb, kc)
        self.accumulators[gid].update_count_only(agg_index)


# =============================================================================
# IntNKeyAggregator -- N-column integer GROUP BY (zero string allocation)
# =============================================================================
#
# Generalized N-key integer aggregator for 4+ keys. Stores N Int64 values
# per group in a flat List (stride = num_keys). Uses combined Fibonacci
# hashing across all N keys.
#
# Covers: H2O Q10 (6 keys: id1-id6). Avoids string serialization overhead
# that makes CompositeKeyAggregator 18x slower than DuckDB on Q10.
#
# Key storage: flat List[Int64] with stride = num_keys.
#   Group g's keys: flat_keys[g * num_keys + 0], ..., flat_keys[g * num_keys + num_keys - 1]
#
# Hash: XOR of (key_i * prime_i) for i in 0..num_keys-1.
# =============================================================================


# Fibonacci-derived primes for multi-key hashing (up to 8 keys)
comptime _MULTI_KEY_PRIMES_0: UInt64 = 0x9E3779B97F4A7C15
comptime _MULTI_KEY_PRIMES_1: UInt64 = 0x517CC1B727220A95
comptime _MULTI_KEY_PRIMES_2: UInt64 = 0x6C62272E07BB0142
comptime _MULTI_KEY_PRIMES_3: UInt64 = 0xE9170A1B3F6C8D2D
comptime _MULTI_KEY_PRIMES_4: UInt64 = 0xB4F0A22C3E5D1987
comptime _MULTI_KEY_PRIMES_5: UInt64 = 0xD83C6F45A1B2E3A7
comptime _MULTI_KEY_PRIMES_6: UInt64 = 0xA59F1E72B4C6D803
comptime _MULTI_KEY_PRIMES_7: UInt64 = 0x7B2E5C8F19A3D641


struct IntNKeyAggregator(Movable):
    """GROUP BY on N integer columns with typed key storage (N >= 4).

    Stores keys in a flat Int64 array with stride = num_keys. Avoids all
    string allocation by hashing and comparing Int64 values directly.
    """

    var flat_keys: List[Int64]
    var accumulators: List[MultiAggAccumulator]
    var hash_table: List[Int]
    var capacity: Int
    var num_groups: Int
    var num_aggs: Int
    var num_keys: Int

    def __init__(out self, var flat_keys: List[Int64],
                 var accumulators: List[MultiAggAccumulator],
                 var hash_table: List[Int], capacity: Int,
                 num_groups: Int, num_aggs: Int, num_keys: Int):
        self.flat_keys = flat_keys^
        self.accumulators = accumulators^
        self.hash_table = hash_table^
        self.capacity = capacity
        self.num_groups = num_groups
        self.num_aggs = num_aggs
        self.num_keys = num_keys

    @staticmethod
    def create(num_keys: Int, num_aggs: Int, initial_capacity: Int = 1024) -> IntNKeyAggregator:
        """Create a new empty IntNKeyAggregator for N-key groups."""
        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        var ht = List[Int]()
        for _ in range(cap):
            ht.append(_EMPTY_SLOT)

        return IntNKeyAggregator(
            flat_keys=List[Int64](),
            accumulators=List[MultiAggAccumulator](),
            hash_table=ht^,
            capacity=cap,
            num_groups=0,
            num_aggs=num_aggs,
            num_keys=num_keys,
        )

    @always_inline
    def _hash_keys(self, row_keys: List[Int64]) -> UInt64:
        """Hash N Int64 keys using position-dependent Fibonacci primes."""
        var h = UInt64(0)
        var nk = len(row_keys)
        # Use compile-time primes for first 8 keys, fallback for more
        if nk > 0:
            h = h ^ (UInt64(row_keys[0]) * _MULTI_KEY_PRIMES_0)
        if nk > 1:
            h = h ^ (UInt64(row_keys[1]) * _MULTI_KEY_PRIMES_1)
        if nk > 2:
            h = h ^ (UInt64(row_keys[2]) * _MULTI_KEY_PRIMES_2)
        if nk > 3:
            h = h ^ (UInt64(row_keys[3]) * _MULTI_KEY_PRIMES_3)
        if nk > 4:
            h = h ^ (UInt64(row_keys[4]) * _MULTI_KEY_PRIMES_4)
        if nk > 5:
            h = h ^ (UInt64(row_keys[5]) * _MULTI_KEY_PRIMES_5)
        if nk > 6:
            h = h ^ (UInt64(row_keys[6]) * _MULTI_KEY_PRIMES_6)
        if nk > 7:
            h = h ^ (UInt64(row_keys[7]) * _MULTI_KEY_PRIMES_7)
        # Final mix
        h = h ^ (h >> 33)
        h = h * UInt64(0xFF51AFD7ED558CCD)
        h = h ^ (h >> 33)
        return h

    @always_inline
    def _keys_equal(self, group_id: Int, row_keys: List[Int64]) -> Bool:
        """Compare stored keys for group_id against row_keys."""
        var base = group_id * self.num_keys
        for k in range(self.num_keys):
            if self.flat_keys[base + k] != row_keys[k]:
                return False
        return True

    @always_inline
    def _slot_for_hash(self, h: UInt64) -> Int:
        return Int(h & UInt64(self.capacity - 1))

    def _resize(mut self):
        """Double the hash table capacity and rehash all entries."""
        var new_cap = self.capacity * 2
        var new_ht = List[Int]()
        for _ in range(new_cap):
            new_ht.append(_EMPTY_SLOT)

        var new_mask = UInt64(new_cap - 1)
        var row_keys = List[Int64]()
        for _ in range(self.num_keys):
            row_keys.append(Int64(0))

        for i in range(self.num_groups):
            var base = i * self.num_keys
            for k in range(self.num_keys):
                row_keys[k] = self.flat_keys[base + k]
            var h = self._hash_keys(row_keys)
            var slot = Int(h & new_mask)
            while new_ht[slot] != _EMPTY_SLOT:
                slot = (slot + 1) & Int(new_mask)
            new_ht[slot] = i

        self.hash_table = new_ht^
        self.capacity = new_cap

    def _find_or_create(mut self, row_keys: List[Int64]) -> Int:
        """Find existing group or create new one. Returns group_id."""
        if self.num_groups * 10 > self.capacity * 7:
            self._resize()

        var h = self._hash_keys(row_keys)
        var slot = self._slot_for_hash(h)
        var mask = self.capacity - 1

        while True:
            var idx = self.hash_table[slot]
            if idx == _EMPTY_SLOT:
                var group_id = self.num_groups
                # Append all N keys to flat storage
                for k in range(self.num_keys):
                    self.flat_keys.append(row_keys[k])
                self.accumulators.append(MultiAggAccumulator.create(self.num_aggs))
                self.hash_table[slot] = group_id
                self.num_groups += 1
                return group_id
            elif self._keys_equal(idx, row_keys):
                return idx
            else:
                slot = (slot + 1) & mask

    def insert(mut self, row_keys: List[Int64], agg_index: Int, value: Float64):
        """Insert or update a (N-key group, value) for a specific agg slot."""
        var gid = self._find_or_create(row_keys)
        self.accumulators[gid].update(agg_index, value)

    def insert_count(mut self, row_keys: List[Int64], agg_index: Int):
        """Insert a COUNT(*) row for a specific agg slot."""
        var gid = self._find_or_create(row_keys)
        self.accumulators[gid].update_count_only(agg_index)

    def get_group_keys(self, group_id: Int) -> List[Int64]:
        """Extract the individual key values for a given group."""
        var result = List[Int64]()
        var base = group_id * self.num_keys
        for k in range(self.num_keys):
            result.append(self.flat_keys[base + k])
        return result^
