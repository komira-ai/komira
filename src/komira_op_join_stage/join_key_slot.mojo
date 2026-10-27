# =============================================================================
# join_key_slot -- one key column of the stage join build table: the key
# value helpers (bits, hash, equality), `KeyScalarTrait` and its conformer
# `KeySlot[K]`, and the one-pack constructor wrapper `KeyBlockWrap`
# =============================================================================
#
# A key column is slot-indexed: the table's linear probe decides the slot a
# build row lands in, and every key column (and every payload column) of the
# table writes that row at the same slot. `KeySlot[K]` keeps the key values in
# a `List[Scalar[K]]` and a parallel occupancy list, so EVERY value of `K` is
# a key: there is no sentinel value standing for "empty" (a sentinel would
# make that one key value invisible to the probe).
#
# THE KEY MODEL. Hash and equality agree on one canonical bit pattern per
# key (`key_canonical_bits`): for an integer, date or bool key that is its
# zero-extended bits; for a float key it is the query semantics' float model
# (docs/design/query_semantics.md, 3.9 and 2.6), as in DuckDB: every NaN is
# one value and `-0.0` equals `+0.0` (`canonical_bits_*` of komira_udf). The
# stored value keeps its own bits, so a build key read back out of the table
# is the value that went in. NULL is not a key value: the callers skip a NULL
# build key and a NULL probe key (`KeyBundleVar.build_insert_row` and
# `KeyBundleVar.probe_batch_row`).
#
# The variadic bodies of `KeyBundleVar` cannot name a pack element's `K`, so
# every batch read, compare and store goes through this trait in the
# type-erased UInt64 bit space (`key_bits_of` / `key_from_bits`); the conformer,
# which knows `K`, does the DType-exact work.
# =============================================================================

from std.memory import bitcast
from std.sys import size_of
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.batch_view import BatchView
from komira_udf.float_quotient_order import (
    canonical_bits_f32,
    canonical_bits_f64,
)


comptime JOIN_BUILD_DEFAULT_CAP: Int = 64
"""The slot count of a table built by the nullary constructors (a power of
two)."""

comptime _KNUTH: UInt64 = UInt64(0x9E3779B97F4A7C15)


@always_inline
def key_bits_of[K: DType](value: Scalar[K]) -> UInt64:
    """`value`'s raw bit pattern, zero-extended to 64 bits (not a numeric
    cast). `key_from_bits[K]` is its exact inverse."""

    comptime if K == DType.int64 or K == DType.uint64 or K == DType.float64:
        return bitcast[DType.uint64, 1](SIMD[K, 1](value))[0]
    elif K == DType.int32 or K == DType.uint32 or K == DType.float32:
        return UInt64(bitcast[DType.uint32, 1](SIMD[K, 1](value))[0])
    elif K == DType.int16 or K == DType.uint16:
        return UInt64(bitcast[DType.uint16, 1](SIMD[K, 1](value))[0])
    elif K == DType.int8 or K == DType.uint8:
        return UInt64(bitcast[DType.uint8, 1](SIMD[K, 1](value))[0])
    elif K == DType.bool:
        # A BOOL scalar is one bit wide: no byte bitcast.
        return UInt64(1) if rebind[Scalar[DType.bool]](value) else UInt64(0)
    else:
        comptime assert False, (
            "key_bits_of: a fixed-width key DType of at most 8 bytes"
        )


@always_inline
def key_from_bits[K: DType](bits: UInt64) -> Scalar[K]:
    """The `K` value whose `key_bits_of` is `bits`."""

    comptime if K == DType.int64 or K == DType.uint64 or K == DType.float64:
        return rebind[Scalar[K]](bitcast[K, 1](SIMD[DType.uint64, 1](bits))[0])
    elif K == DType.int32 or K == DType.uint32 or K == DType.float32:
        return rebind[Scalar[K]](
            bitcast[K, 1](SIMD[DType.uint32, 1](UInt32(bits)))[0]
        )
    elif K == DType.int16 or K == DType.uint16:
        return rebind[Scalar[K]](
            bitcast[K, 1](SIMD[DType.uint16, 1](UInt16(bits)))[0]
        )
    elif K == DType.int8 or K == DType.uint8:
        return rebind[Scalar[K]](
            bitcast[K, 1](SIMD[DType.uint8, 1](UInt8(bits)))[0]
        )
    elif K == DType.bool:
        return rebind[Scalar[K]](Scalar[DType.bool](bits != 0))
    else:
        comptime assert False, (
            "key_from_bits: a fixed-width key DType of at most 8 bytes"
        )


@always_inline
def key_canonical_bits[K: DType](value: Scalar[K]) -> UInt64:
    """The bits two equal keys share: a float key's canonical bits (every NaN
    one pattern, `-0.0` as `+0.0`), any other key's own bits. Two keys are
    equal exactly when these are equal."""

    comptime if K == DType.float64:
        return canonical_bits_f64(rebind[Float64](value))
    elif K == DType.float32:
        return UInt64(canonical_bits_f32(rebind[Float32](value)))
    else:
        return key_bits_of[K](value)


@always_inline
def key_hash[K: DType](value: Scalar[K]) -> UInt64:
    """The hash of one key column: Knuth's multiplicative scrambler over the
    canonical bits. A composite key hashes to the XOR of its columns' hashes.
    For an INT64 key this is `UInt64(key) * 0x9E3779B97F4A7C15`."""
    return key_canonical_bits[K](value) * _KNUTH


@always_inline
def key_eq[K: DType](a: Scalar[K], b: Scalar[K]) -> Bool:
    """Key equality under the key model (a NaN key equals a NaN key, `-0.0`
    equals `+0.0`; IEEE `==` would not match the NaNs)."""
    return key_canonical_bits[K](a) == key_canonical_bits[K](b)


@always_inline
def round_up_pow2(n: Int) -> Int:
    """The least power of two at least `n` (1 for `n <= 1`)."""
    var cap = 1
    while cap < n:
        cap = cap * 2
    return cap


# -----------------------------------------------------------------------------
# KeyScalarTrait + KeySlot[K]
# -----------------------------------------------------------------------------


trait KeyScalarTrait(Defaultable, Movable, Deinitable):
    """One slot-indexed key column of a `KeyBundleVar`.

    Not `Copyable`: `Tuple[*Keys]` of List-backed columns cannot be. The
    no-argument constructor builds `JOIN_BUILD_DEFAULT_CAP` empty slots, so a
    `Tuple[*Keys]()` builds a whole key block. `DT` is the column's DType, an
    associated alias a generic body can read (a struct parameter it cannot)."""

    comptime DT: DType

    @staticmethod
    def make(capacity: Int) -> Self:
        """An all-empty key column of `capacity` slots."""
        ...

    def slot_is_empty(self, slot: Int) -> Bool:
        """True iff no key was written at `slot`."""
        ...

    def slot_eq_loaded(self, slot: Int, other: Self, other_slot: Int) -> Bool:
        """True iff `self[slot]` equals `other[other_slot]` under the key
        model."""
        ...

    def write_slot_from(mut self, slot: Int, src: Self, src_slot: Int):
        """Copy `src[src_slot]` into `self[slot]` (and mark it occupied)."""
        ...

    def hash_slot(self, slot: Int) -> UInt64:
        """`key_hash` of the key at `slot`."""
        ...

    def rehash_in_place(mut self, new_capacity: Int, remap: List[Int]):
        """Grow to `new_capacity` slots, moving the key at every old slot `s`
        to `remap[s]` (-1: the old slot was empty)."""
        ...

    def memory_size_bytes(self) -> Int:
        """The heap footprint of the column's storage in bytes."""
        ...

    def read_slot_i64(self, slot: Int) -> Int64:
        """The key at `slot` as `Int64(value)` (a numeric cast)."""
        ...

    def read_key_bits_from_batch[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], col: Int, row: Int) raises -> UInt64:
        """`key_bits_of` the value of type `DT` at `batch[col][row]`."""
        ...

    def hash_bits(self, bits: UInt64) -> UInt64:
        """`key_hash` of the key whose bits are `bits`; equal to `hash_slot`
        of a slot holding an equal key."""
        ...

    def eq_slot_to_bits(self, slot: Int, bits: UInt64) -> Bool:
        """True iff the key at `slot` equals the key whose bits are `bits`,
        under the key model."""
        ...

    def write_bits_to_slot(mut self, slot: Int, bits: UInt64):
        """Store the key whose bits are `bits` at `slot` (its own bits, not
        the canonical ones) and mark the slot occupied."""
        ...

    def read_slot_bits(self, slot: Int) -> UInt64:
        """`key_bits_of` the key stored at `slot`."""
        ...


struct KeySlot[K: DType](KeyScalarTrait):
    """A `KeyScalarTrait` column over `List[Scalar[K]]` with a parallel
    occupancy list (`used`): every value of `K` can be a key."""

    comptime DT: DType = Self.K

    var c: List[Scalar[Self.K]]
    var used: List[Bool]

    def __init__(out self, capacity: Int):
        self.c = List[Scalar[Self.K]](capacity=capacity)
        self.used = List[Bool](capacity=capacity)
        for _ in range(capacity):
            self.c.append(Scalar[Self.K](0))
            self.used.append(False)

    def __init__(out self):
        """`JOIN_BUILD_DEFAULT_CAP` empty slots."""
        self = Self(JOIN_BUILD_DEFAULT_CAP)

    @staticmethod
    @always_inline
    def make(capacity: Int) -> Self:
        return Self(capacity)

    @always_inline
    def slot_is_empty(self, slot: Int) -> Bool:
        return not self.used[slot]

    @always_inline
    def slot_eq_loaded(self, slot: Int, other: Self, other_slot: Int) -> Bool:
        return key_eq[Self.K](self.c[slot], other.c[other_slot])

    @always_inline
    def write_slot_from(mut self, slot: Int, src: Self, src_slot: Int):
        self.c[slot] = src.c[src_slot]
        self.used[slot] = True

    @always_inline
    def hash_slot(self, slot: Int) -> UInt64:
        return key_hash[Self.K](self.c[slot])

    @always_inline
    def slot_at(self, slot: Int) -> Scalar[Self.K]:
        """The key stored at `slot` (meaningless for an empty slot)."""
        return self.c[slot]

    @always_inline
    def write_value(mut self, slot: Int, value: Scalar[Self.K]):
        """Store `value` at `slot` and mark the slot occupied."""
        self.c[slot] = value
        self.used[slot] = True

    @always_inline
    def slot_eq_value(self, slot: Int, value: Scalar[Self.K]) -> Bool:
        """True iff `slot` is occupied by a key equal to `value` under the key
        model."""
        return self.used[slot] and key_eq[Self.K](self.c[slot], value)

    @always_inline
    def read_slot_i64(self, slot: Int) -> Int64:
        return Int64(self.c[slot])

    @always_inline
    def read_key_bits_from_batch[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], col: Int, row: Int) raises -> UInt64:
        return key_bits_of[Self.K](batch.col_scalar[Self.K](col, row))

    @always_inline
    def hash_bits(self, bits: UInt64) -> UInt64:
        return key_hash[Self.K](key_from_bits[Self.K](bits))

    @always_inline
    def eq_slot_to_bits(self, slot: Int, bits: UInt64) -> Bool:
        return key_eq[Self.K](self.c[slot], key_from_bits[Self.K](bits))

    @always_inline
    def write_bits_to_slot(mut self, slot: Int, bits: UInt64):
        self.c[slot] = key_from_bits[Self.K](bits)
        self.used[slot] = True

    @always_inline
    def read_slot_bits(self, slot: Int) -> UInt64:
        return key_bits_of[Self.K](self.c[slot])

    @always_inline
    def prefetch_at(self, slot: Int):
        """A software prefetch of the cache line holding the key at `slot`."""
        # SAFETY: the pointer is `self.c`'s own buffer, borrowed for this O(1)
        # call; a prefetch is a non-faulting hint (no load, no fault on an
        # out-of-range address) and the pointer does not leave this body.
        prefetch[params = PrefetchOptions().for_read().high_locality()](
            self.c.unsafe_ptr() + slot
        )

    def rehash_in_place(mut self, new_capacity: Int, remap: List[Int]):
        var fresh = List[Scalar[Self.K]](capacity=new_capacity)
        var fresh_used = List[Bool](capacity=new_capacity)
        for _ in range(new_capacity):
            fresh.append(Scalar[Self.K](0))
            fresh_used.append(False)
        for old_slot in range(len(remap)):
            var dst = remap[old_slot]
            if dst >= 0:
                fresh[dst] = self.c[old_slot]
                fresh_used[dst] = True
        self.c = fresh^
        self.used = fresh_used^

    def memory_size_bytes(self) -> Int:
        return len(self.c) * size_of[Scalar[Self.K]]() + len(self.used)


@always_inline
def key_slot[K: DType](capacity: Int) -> KeySlot[K]:
    """A `KeySlot[K]` of `capacity` empty slots."""
    return KeySlot[K](capacity)


struct KeyBlockWrap[*Keys: KeyScalarTrait](Movable):
    """Carries a pack of key columns into the `KeyBundleVar` constructor (a
    parameter list holds one variadic pack). The pack is lifted out once with
    `Optional.take()`."""

    var _keys: Optional[Tuple[*Self.Keys]]

    def __init__(out self, var *slots: *Self.Keys):
        self._keys = Tuple(*slots^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Keys]:
        """The key columns (once)."""
        return self._keys.take()
