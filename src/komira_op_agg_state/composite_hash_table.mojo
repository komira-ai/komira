# =============================================================================
# composite_hash_table.mojo — Variadic multi-key CompositeHashTable
# =============================================================================
#
# WSC PHASE-B deliverable per RFC v1.1 §2.3 line 323 + WSC-SPIKE-H2O (1.038×
# hand-fused gold).
#
# Open-addressing linear-probe hash table indexed by composite-key hash.
#
# NARY-COMPOSITE-HT: collapsed the 2-struct
# fixed-arity `CompositeHashTable{2,3}F64` family into ONE generic core
# `_CompositeHashTableF64[KS: CompositeKeyStore, AggOp]` plus a fixed
# per-arity key-store family (`CompositeKeyStore{2,3}[HashFn, EqFn]`). The
# public names `CompositeHashTable2F64` / `CompositeHashTable3F64` are
# preserved as parametric ALIASES over the core (param order
# `[AggOp, HashFn, EqFn]` unchanged), so every consumer + test compiles
# without edits.
#
# Why standalone (not folded into NARY-HASHAGG `HashAggTable[KB, *Aggs]`):
# different trait surfaces with no overlap — HashAggTable keys are
# typed-DType `KeyTuple` SoA columns on the unwired `AggColumn`/`Aggregator`
# surface; CompositeHashTable keys are runtime-tagged `KeyValueN`/
# `ColumnValue` unions on the LIVE `HashAggOpF64` surface with PLUGGABLE
# `KeyHashFnN` / `KeyEqFnN`. See Step-0 memo
# an internal agent note
# . Fold deferred to
# NARY-COMPOSITE-HT-FOLD-FOLLOWUP.
#
# Design (mirror of NARY-HASHAGG finding A — only ONE `*` pack per
# declaration, so the arity axis folds into a fixed per-arity STORE family,
# exactly like HashAggTable's `KeyTuple{Scalar,1,2,3}`):
#   - `CompositeKeyStore` trait: owns the per-arity SoA component-arm Lists
#     + the `KeyValueN` round-trip codec + hash/eq dispatch. Carries
#     `comptime ARITY: Int` + associated `KeyType` (the `KeyValueN`).
#   - `CompositeKeyStore{2,3}[HashFn, EqFn]` — the two live arities.
#   - `_CompositeHashTableF64[KS, AggOp]` — arity-generic core: `hashes` /
#     `slabs` / `capacity` / `n_used` + the `KS` key store. Probe / insert /
#     update / finalize are written ONCE.
#
# Storage shape per H2O spike §6: parallel SoA Lists (keys + hashes + state).
# NOT AoS rows with List[String] inside (the gap6 trap). The "List with
# bulk-reserve at init" pattern is bounded-buffer compliant — no
# `.append()` on the hot path; per-row insertion writes into pre-allocated
# slots indexed by the hash.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - Parallel SoA Lists (gap6-safe per H2O spike §6 comment lines 400-403).
#   - StateTy parametric over AggOp.StateTy.
#
# Cross-references:
#   - WSC RFC v1.1 §2.3 line 323 (CompositeHashTable multi-key primitive).
#   - WSC-SPIKE-H2O h2o_expr_nodes.mojo §6 (CompositeHashTable canonical).
#   - komira_eval/composite_key.mojo — KeyValueN runtime values + hash helpers.
#   - komira_op_agg_state/agg_state_slab.mojo — AggOp + KeyHashFn /
#     KeyEqFn conformers.
#   - NARY-HASHAGG analog: stage_primitives/hash_agg.mojo (KeyTuple family).
# =============================================================================

from std.memory import bitcast

from komira_agg.agg_op_traits import HashAggOpF64, HashAggOpI64
from komira_expr.composite_key import ColumnValue, KeyValue2, KeyValue3
from komira_op_agg_state.agg_state_slab import (
    KeyHashFn2, KeyEqFn2, KeyHashFn3, KeyEqFn3,
)


# =============================================================================
# §1 — Constants
# =============================================================================

comptime _EMPTY_HASH: UInt64 = 0
"""Empty-slot sentinel. We OR-mask with _HASH_SENTINEL so that real hashes
are never 0 (matches H2O spike §6 line 385)."""

comptime _HASH_SENTINEL: UInt64 = 1 << 63
"""Ensures hashes are never 0 (so 0 can be the empty-slot sentinel)."""

comptime DEFAULT_INITIAL_CAPACITY: Int = 16
"""Initial capacity for CompositeHashTable. Rounded up to power-of-2 in
the constructor (mask-based probing requires power-of-2 capacity)."""

comptime _GROW_LOAD_FACTOR_NUM: Int = 3
comptime _GROW_LOAD_FACTOR_DEN: Int = 4
"""Grow threshold: 75% load factor (3/4). Mirror of the dense-hash-agg
substrate's choice (`_DenseAggDirectory._maybe_grow`). When `n_used`
crosses `capacity * 3 / 4` after an insert, the table doubles its
capacity and rehashes all live keys + slabs into the new slots.

ERR-COMPOSITE-HASH-TABLE-F64-GROW — added to
close h6's `id4 × id5 → median(v3), stddev_samp(v3)` 10K-group infinite
linear-probe spin (cap=16 with no grow path). Mirror of the I64-keyed
HashAggTable + GrowableHashSetI64 grow patterns; pre-existing substrate
gap that affects the WHOLE composite multi-agg family (any composite
GROUP BY at realistic cardinality)."""

# ColumnValue tag constants (mirror komira_eval.composite_key CVT_*).
comptime _CVT_BOOL: UInt8 = 3
comptime _CVT_INT64: UInt8 = 8
comptime _CVT_FLOAT64: UInt8 = 12
comptime _CVT_STRING: UInt8 = 14


# =============================================================================
# §2 — Per-component arm storage helpers
# =============================================================================
#
# Each composite-key component is stored across three parallel SoA arms
# (f64 / str / tag); only the arm matching the tag is meaningful, but
# storing all keeps the Mojo storage shape well-defined and gap6-safe (no
# inner List/String nested in a row struct). One `_ComponentArm` owns the
# three Lists for a single key component; a `CompositeKeyStoreN` holds N
# of them.
# =============================================================================


@fieldwise_init
struct _ComponentArm(Copyable, Movable):
    """SoA arms for ONE composite-key component cell column.

    - f64: Int64 cells as their bit pattern (bitcast, exact for every
           Int64), raw F64 cells, or Bool cells as 0.0 / 1.0.
    - s:   String cells.
    - tag: ColumnValue.kind() per slot.
    """

    var f64: List[Float64]
    var s: List[String]
    var tag: List[UInt8]

    @staticmethod
    def new(cap: Int) -> _ComponentArm:
        """Bulk-reserve + sentinel-fill the three arms to `cap` slots."""
        var f = List[Float64](capacity=cap)
        var ss = List[String](capacity=cap)
        var t = List[UInt8](capacity=cap)
        for _ in range(cap):
            f.append(Float64(0.0))
            ss.append(String(""))
            t.append(UInt8(0))
        return _ComponentArm(f64=f^, s=ss^, tag=t^)

    @always_inline
    def store(mut self, slot: Int, cv: ColumnValue):
        """Store one ColumnValue cell at `slot`, dispatching on its tag."""
        var k = cv.kind()
        self.tag[slot] = k
        if k == _CVT_INT64:
            # The Int64's BITS, not its value: a value conversion rounds
            # every |v| > 2^53, and the probe compares the loaded key, so a
            # rounded key splits one group or merges two. The arm is only
            # moved, never computed on, so NaN-shaped patterns keep their bits.
            self.f64[slot] = bitcast[DType.float64, 1](
                SIMD[DType.int64, 1](cv.as_i64())
            )[0]
        elif k == _CVT_FLOAT64:
            self.f64[slot] = cv.as_f64()
        elif k == _CVT_STRING:
            self.s[slot] = cv.as_str()
        elif k == _CVT_BOOL:
            self.f64[slot] = SIMD[DType.int64, 1](
                Int64(1) if cv.as_bool() else Int64(0)
            ).cast[DType.float64]()[0]

    @always_inline
    def load(self, slot: Int) -> ColumnValue:
        """Reconstruct the ColumnValue stored at `slot`."""
        var t = self.tag[slot]
        if t == _CVT_INT64:
            return ColumnValue(
                bitcast[DType.int64, 1](SIMD[DType.float64, 1](self.f64[slot]))[
                    0
                ]
            )
        elif t == _CVT_FLOAT64:
            return ColumnValue(self.f64[slot])
        elif t == _CVT_STRING:
            return ColumnValue(self.s[slot])
        else:
            var bv = SIMD[DType.float64, 1](self.f64[slot]).cast[
                DType.int64
            ]()[0]
            return ColumnValue(bv != Int64(0))


# =============================================================================
# §3 — CompositeKeyStore trait + per-arity conformers
# =============================================================================
#
# The arity axis (NARY finding A) folds into this fixed per-arity STORE
# family — analogous to NARY-HASHAGG's `KeyTuple{Scalar,1,2,3}`. Each store
# owns its N `_ComponentArm`s + the `KeyValueN` codec + hash/eq dispatch
# (pluggable via the `HashFn` / `EqFn` type params). A new arity = one new
# `CompositeKeyStoreN` struct (mechanical), not a per-DType cartesian.
# =============================================================================


trait CompositeKeyStore(Movable, Copyable, Deinitable):
    """Per-arity composite-key SoA store + codec for the generic
    `_CompositeHashTableF64` core.

    Carries the runtime key arity (`ARITY`) and the associated runtime
    key-value type (`KeyType` = `KeyValueN`). The core delegates all
    key storage / reconstruction / hashing / equality to the store, so
    its probe / insert / finalize logic is written once and arity-blind.
    """

    comptime ARITY: Int

    comptime KeyType: Copyable & Movable & Deinitable

    @staticmethod
    def new(cap: Int) -> Self:
        """Bulk-reserve the per-component arms to `cap` slots."""
        ...

    def store_key(mut self, slot: Int, key: Self.KeyType):
        """Store the key components at `slot`."""
        ...

    def load_key(self, slot: Int) -> Self.KeyType:
        """Reconstruct the key stored at `slot`."""
        ...

    @staticmethod
    def hash_key(key: Self.KeyType) -> UInt64:
        """Hash via the bound HashFn conformer."""
        ...

    @staticmethod
    def eq_key(a: Self.KeyType, b: Self.KeyType) -> Bool:
        """Element-wise equality via the bound EqFn conformer."""
        ...


@fieldwise_init
struct CompositeKeyStore2[HashFn: KeyHashFn2, EqFn: KeyEqFn2](
    CompositeKeyStore
):
    """Arity-2 composite-key store (2 `_ComponentArm`s + KeyValue2 codec)."""

    comptime ARITY: Int = 2

    comptime KeyType = KeyValue2

    var a0: _ComponentArm
    var a1: _ComponentArm

    @staticmethod
    @always_inline
    def new(cap: Int) -> Self:
        return Self(a0=_ComponentArm.new(cap), a1=_ComponentArm.new(cap))

    @always_inline
    def store_key(mut self, slot: Int, key: KeyValue2):
        self.a0.store(slot, key.c0)
        self.a1.store(slot, key.c1)

    @always_inline
    def load_key(self, slot: Int) -> KeyValue2:
        return KeyValue2(self.a0.load(slot), self.a1.load(slot))

    @staticmethod
    @always_inline
    def hash_key(key: KeyValue2) -> UInt64:
        return Self.HashFn.hash(key)

    @staticmethod
    @always_inline
    def eq_key(a: KeyValue2, b: KeyValue2) -> Bool:
        return Self.EqFn.eq(a, b)


@fieldwise_init
struct CompositeKeyStore3[HashFn: KeyHashFn3, EqFn: KeyEqFn3](
    CompositeKeyStore
):
    """Arity-3 composite-key store (3 `_ComponentArm`s + KeyValue3 codec)."""

    comptime ARITY: Int = 3

    comptime KeyType = KeyValue3

    var a0: _ComponentArm
    var a1: _ComponentArm
    var a2: _ComponentArm

    @staticmethod
    @always_inline
    def new(cap: Int) -> Self:
        return Self(
            a0=_ComponentArm.new(cap),
            a1=_ComponentArm.new(cap),
            a2=_ComponentArm.new(cap),
        )

    @always_inline
    def store_key(mut self, slot: Int, key: KeyValue3):
        self.a0.store(slot, key.c0)
        self.a1.store(slot, key.c1)
        self.a2.store(slot, key.c2)

    @always_inline
    def load_key(self, slot: Int) -> KeyValue3:
        return KeyValue3(
            self.a0.load(slot), self.a1.load(slot), self.a2.load(slot)
        )

    @staticmethod
    @always_inline
    def hash_key(key: KeyValue3) -> UInt64:
        return Self.HashFn.hash(key)

    @staticmethod
    @always_inline
    def eq_key(a: KeyValue3, b: KeyValue3) -> Bool:
        return Self.EqFn.eq(a, b)


# =============================================================================
# §4 — _CompositeHashTableF64 — arity-generic open-addressing core
# =============================================================================
#
# Open-addressing linear-probe hash table over composite keys with Float64
# per-bucket state. Generic over the `CompositeKeyStore` (which carries the
# arity + KeyValueN codec + pluggable hash/eq) and the `HashAggOpF64`
# aggregate. The probe / insert / update / finalize logic — formerly
# duplicated across CompositeHashTable2F64 + CompositeHashTable3F64 — is
# written ONCE here.
#
# Per H2O spike §6 (lines 380-472): mask-based probing on capacity-1;
# OR-mask hash with _HASH_SENTINEL so real hashes are never 0; insert on
# first empty slot in linear probe; key comparison goes through the store's
# EqFn conformer.
#
# Bounded-buffer compliance (RFC §6.3 R3): the store's SoA arms + `hashes`
# + `slabs` are bulk-reserve()'d at construction; hot-path operations write
# to pre-allocated slots (no per-row .append). Resize is a PHASE-D concern.
# =============================================================================


@fieldwise_init
struct _CompositeHashTableF64[
    KS: CompositeKeyStore,
    AggOp: HashAggOpF64,
](Copyable, Movable):
    """Arity-generic composite-key hash table with Float64 per-bucket state.

    Storage:
      - keys:    KS (per-arity SoA component arms + KeyValueN codec).
      - hashes:  List[UInt64]             — full 64-bit hash (0 = empty).
      - slabs:   List[Self.AggOp.StateTy] — per-bucket state.
      - capacity: Int                      — power-of-2 capacity.
      - n_used:   Int                      — number of non-empty buckets.
    """

    var keys: Self.KS
    var hashes: List[UInt64]
    var slabs: List[Self.AggOp.StateTy]
    var capacity: Int
    var n_used: Int

    @staticmethod
    def new(
        initial_capacity: Int,
    ) -> _CompositeHashTableF64[Self.KS, Self.AggOp]:
        """Construct empty table with at-least `initial_capacity` slots
        (rounded up to power of 2). Bulk-allocate parallel SoA Lists, fill
        with sentinel values, return populated struct (H2O spike §6
        line 412-437)."""
        var cap = 1
        while cap < initial_capacity:
            cap = cap * 2

        var hh = List[UInt64](capacity=cap)
        var sl = List[Self.AggOp.StateTy](capacity=cap)
        for _ in range(cap):
            hh.append(_EMPTY_HASH)
            # StateTy is Copyable but not ImplicitlyCopyable — re-init each
            # slot per H2O spike §6 line 425 pattern.
            sl.append(Self.AggOp.init())

        return _CompositeHashTableF64[Self.KS, Self.AggOp](
            keys=Self.KS.new(cap),
            hashes=hh^,
            slabs=sl^,
            capacity=cap,
            n_used=0,
        )

    @always_inline
    def probe_or_insert(mut self, key: Self.KS.KeyType, hash: UInt64) -> Int:
        """Find bucket for `key` (insert if not present). Returns bucket idx.

        Per H2O spike §6 line 440-464: OR-mask hash with _HASH_SENTINEL,
        compute mask-based initial slot, linear-probe; on empty slot
        insert; on hash match verify via the store's EqFn; on collision
        advance linear-probe.

        ERR-COMPOSITE-HASH-TABLE-F64-GROW —
        on insert into an empty slot, if the resulting `n_used` crosses
        the 75% load-factor threshold (`n_used * 4 >= capacity * 3`),
        trigger `_grow` which doubles capacity and rehashes. Without
        this, h6's 10K-group composite GROUP BY hangs in infinite
        linear-probe (cap=16, no empty slots).
        """
        var h = hash | _HASH_SENTINEL
        var mask = self.capacity - 1
        var slot = Int(h & UInt64(mask))
        while True:
            var existing = self.hashes[slot]
            if existing == _EMPTY_HASH:
                self.hashes[slot] = h
                self.keys.store_key(slot, key)
                self.n_used = self.n_used + 1
                # Grow check: when load factor crosses the 75%
                # threshold, double capacity + rehash. The grow runs
                # AFTER the insert (the returned slot is valid in the
                # NEW table; the grow rehashes the just-inserted slot
                # too, but `probe_or_insert_after_grow` re-locates it
                # by hash). We return the post-grow slot via
                # `_lookup_after_grow`.
                if (
                    self.n_used * _GROW_LOAD_FACTOR_DEN
                    >= self.capacity * _GROW_LOAD_FACTOR_NUM
                ):
                    self._grow()
                    return self._lookup_existing(key, h)
                return slot
            elif existing == h:
                var stored = self.keys.load_key(slot)
                if Self.KS.eq_key(stored, key):
                    return slot
            slot = (slot + 1) & mask

    def _grow(mut self):
        """Double capacity and rehash all live keys + slabs into new slots.

        Mirror of `_DenseAggDirectory._maybe_grow` / the dense-hash-agg
        substrate's grow path. The old keys are read out via
        `keys.load_key` and re-inserted into a freshly-allocated store
        + parallel hashes/slabs Lists at 2x capacity.
        """
        var old_cap = self.capacity
        var new_cap = old_cap * 2
        var new_mask = new_cap - 1

        # Allocate fresh storage at 2x capacity.
        var new_keys = Self.KS.new(new_cap)
        var new_hashes = List[UInt64](capacity=new_cap)
        var new_slabs = List[Self.AggOp.StateTy](capacity=new_cap)
        for _ in range(new_cap):
            new_hashes.append(_EMPTY_HASH)
            new_slabs.append(Self.AggOp.init())

        # Rehash every live slot from the old table into the new table.
        for old_slot in range(old_cap):
            var h = self.hashes[old_slot]
            if h == _EMPTY_HASH:
                continue
            var key = self.keys.load_key(old_slot)
            # Linear-probe into the new table; first empty slot wins.
            var slot = Int(h & UInt64(new_mask))
            while True:
                if new_hashes[slot] == _EMPTY_HASH:
                    new_hashes[slot] = h
                    new_keys.store_key(slot, key)
                    # Copy the agg slab payload to the new slot. The
                    # StateTy is Copyable (HashAggOpF64 binding); a
                    # straight assignment preserves the accumulated
                    # aggregate state.
                    new_slabs[slot] = self.slabs[old_slot].copy()
                    break
                slot = (slot + 1) & new_mask

        self.keys = new_keys^
        self.hashes = new_hashes^
        self.slabs = new_slabs^
        self.capacity = new_cap

    @always_inline
    def _lookup_existing(self, key: Self.KS.KeyType, h: UInt64) -> Int:
        """Locate the slot of an already-inserted key in the CURRENT
        table (post-grow). Used by `probe_or_insert` to return the new
        slot index after a grow rehashed the freshly-inserted key.

        Caller-enforced precondition: key is present (hash `h` was
        either an inserted-then-grown key or one whose grow-time
        rehash landed it in the new table).
        """
        var mask = self.capacity - 1
        var slot = Int(h & UInt64(mask))
        while True:
            var existing = self.hashes[slot]
            if existing == h:
                var stored = self.keys.load_key(slot)
                if Self.KS.eq_key(stored, key):
                    return slot
            slot = (slot + 1) & mask

    @always_inline
    def update_scalar(mut self, key: Self.KS.KeyType, value: Float64):
        """Per-row hot path: hash key, probe-or-insert, then update slab."""
        var hash = Self.KS.hash_key(key)
        var slot = self.probe_or_insert(key, hash)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def finalize_at(self, slot: Int) -> Float64:
        """Read finalized value at slot."""
        return Self.AggOp.finalize(self.slabs[slot])

    @always_inline
    def key_at(self, slot: Int) -> Self.KS.KeyType:
        """Reconstruct the key at slot. Caller must verify hash != 0."""
        return self.keys.load_key(slot)

    @always_inline
    def is_occupied(self, slot: Int) -> Bool:
        """True if slot has an inserted key."""
        return self.hashes[slot] != _EMPTY_HASH

    @always_inline
    def capacity_of(self) -> Int:
        """Table capacity (power-of-2)."""
        return self.capacity


# =============================================================================
# §5 — Public aliases — preserve the legacy fixed-arity names
# =============================================================================
#
# The 2-struct `CompositeHashTable{2,3}F64` family is now thin parametric
# aliases over the generic core. The param ORDER `[AggOp, HashFn, EqFn]` is
# preserved exactly so every consumer (`stage_group_agg.mojo`,
# `runtime_breaker_state.mojo`) + test (`test_stage_group_agg.mojo`)
# compiles WITHOUT edits.
# =============================================================================


comptime CompositeHashTable2F64[
    AggOp: HashAggOpF64,
    HashFn: KeyHashFn2,
    EqFn: KeyEqFn2,
] = _CompositeHashTableF64[CompositeKeyStore2[HashFn, EqFn], AggOp]
"""Open-addressing linear-probe hash table over 2-component composite keys
with Float64 per-bucket state. Alias over `_CompositeHashTableF64` with the
arity-2 `CompositeKeyStore2`. See §4."""


comptime CompositeHashTable3F64[
    AggOp: HashAggOpF64,
    HashFn: KeyHashFn3,
    EqFn: KeyEqFn3,
] = _CompositeHashTableF64[CompositeKeyStore3[HashFn, EqFn], AggOp]
"""Open-addressing linear-probe hash table over 3-component composite keys
with Float64 per-bucket state. Alias over `_CompositeHashTableF64` with the
arity-3 `CompositeKeyStore3`. See §4."""


# =============================================================================
# §6 — Arity 1 / 4 variants — DEFERRED to PHASE-D
# =============================================================================
#
# CompositeHashTable1 / CompositeHashTable4 follow trivially from the
# generic core: add a `CompositeKeyStore{1,4}[HashFn, EqFn]` conformer
# (one `_ComponentArm` per component + the KeyValue{1,4} codec) and a
# `CompositeHashTable{1,4}F64` alias. PHASE-B/D ship arities 2 + 3 (the
# live group-agg shapes); arities 1 / 4 ship as kernel migrations consume
# them.
# =============================================================================
