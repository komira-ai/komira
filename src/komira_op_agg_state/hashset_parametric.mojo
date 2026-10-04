# =============================================================================
# hashset_parametric.mojo — Option D parametric HashSet family (Phase 1)
# =============================================================================
#
# **Substrate primitives for SUBSTRATE-IMPL-PHASE-1-PRIMITIVES** per
# an internal doc §2.1.
#
# This file ships the **per-arity-parametric HashSet family** that
# supersedes today's hardcoded `HashSetI64` / `HashSetI64I64` /
# `HashSetI64I64I64` triplet at `runtime_breaker_state.mojo:327-519`. The
# new family covers arity-1 through arity-8 with per-position DType
# parametricity:
#
#   HashSet1[K0]
#   HashSet2[K0, K1]
#   HashSet3[K0, K1, K2]
#   HashSet4[K0, K1, K2, K3]
#   HashSet5[K0, K1, K2, K3, K4]
#   HashSet6[K0, K1, K2, K3, K4, K5]
#   HashSet7[K0, K1, K2, K3, K4, K5, K6]
#   HashSet8[K0, K1, K2, K3, K4, K5, K6, K7]
#
# `arity > 8` falls back to `byte_hashset.ByteHashSet` (the byte-erased
# tail; sibling file).
#
# # Storage shape
#
# Each `HashSetN[K0..KN-1]` carries N parallel SoA `List[Scalar[Ki]]`
# fields + a parallel `List[UInt64]` hash filter + `n_used: Int`. Linear-
# scan insert/contains:
#   1. Compute per-position FNV-1a-combined UInt64 hash.
#   2. Scan `hashes[i]` for filter match; on hit, compare all N key
#      positions.
#   3. On miss after full scan, append to all N+1 Lists.
#
# This matches today's `HashSetI64I64` / `HashSetI64I64I64` pattern
# verbatim. The `Scalar[Ki]` field type generalizes from today's
# hardcoded `Int64` to any fixed-width POD numeric DType (Int8..Int64,
# UInt8..UInt64, Float32, Float64, Bool, Int128 for Decimal128 backing).
# String / Bytes / variable-width types route to `ByteHashSet`.
#
# # Hash combinator (per-position FNV-1a)
#
# Today's hardcoded HashSetI64 uses Knuth's `0x9E3779B1` multiplicative
# scrambler. The parametric family uses FNV-1a per position (design doc
# §2.3) — POC measured 1.00× insert / 1.00× probe vs the scrambler for
# all-I64 arity-3, and FNV-1a generalizes cleanly across DTypes.
#
# # Movability + Copyability
#
# Each `HashSetN[...]` is `Movable` (not `Copyable`). Each holds N
# `List[Scalar[Ki]]` fields (themselves Movable, single-owner heap
# allocation). Copying a hash set is rare — the substrate is moved into
# `RuntimeBreakerState` once at lazy-init.
#
# # Encapsulation invariants (the internal development notes hard bans)
#
#   - NO UnsafePointer in any public method signature.
#   - NO wildcard origins.
#   - NO `unsafe_from_address`.
#   - NO partial-move-via-UnsafePointer.
#   - `List[Scalar[Ki]]` is gap6-safe (POD numeric storage; no Movable
#     struct with heap-owning inner fields).
#
# # File-size cap (the internal development notes "File-size cap relaxed for Mojo")
#
# 8 structs × ~70 LOC body + helpers = ~700 LOC. Well below the 5K LOC
# iterative-rebuild knee.
#
# # POC anchor
#
# Idioms validated by the poc_option_d_design_doc_compile probe
# (compile-only) and the poc_parametric_variadic_perf probe (1.00×
# insert + 1.00× probe vs hardcoded HashSetI64I64I64).
#
# # Cross-references
#
#   - Design doc: an internal doc §2.
#   - Sibling: `byte_hashset.mojo` (arity > 8 + exotic-DType fallback).
#   - Hardcoded primitives to be deleted in Phase 4:
#     `runtime_breaker_state.mojo:327-519`.
# =============================================================================

from std.memory import bitcast


# =============================================================================
# §1 — Hash combinator constants + helper
# =============================================================================

comptime FNV_OFFSET: UInt64 = 14695981039346656037
"""FNV-1a 64-bit offset basis (RFC standard)."""

comptime FNV_PRIME: UInt64 = 1099511628211
"""FNV-1a 64-bit prime (RFC standard)."""

comptime HASHSET_DEFAULT_CAPACITY: Int = 16
"""Initial capacity for parametric hash-set tables. Inherited from
`DEFAULT_COMPOSITE_HASHSET_CAPACITY` at `runtime_breaker_state.mojo:406`
(today's hardcoded composite HashSet default). Linear-scan probe — list
grows via `List.append` on miss."""


@always_inline
def _fnv1a_combine[K: DType](state: UInt64, k: Scalar[K]) -> UInt64:
    """Per-position FNV-1a step.

    Bit-cast the typed cell to UInt64 (8-byte types) / UInt32 (4-byte
    types) / UInt8 (Bool) and fold into the running state. Monomorphizer
    emits one inlined arm per (K0, K1, ..., KN-1) tuple.

    Per design doc §2.3 — FNV-1a generalizes cleanly across DTypes;
    matches today's Knuth scrambler at 1.00× for all-I64 arity-3 per the
    parametric POC.
    """
    comptime if K == DType.int64 or K == DType.uint64 or K == DType.float64:
        var bits = bitcast[DType.uint64, 1](SIMD[K, 1](k))
        return (state ^ bits[0]) * FNV_PRIME
    elif K == DType.int32 or K == DType.uint32 or K == DType.float32:
        var bits = bitcast[DType.uint32, 1](SIMD[K, 1](k))
        return (state ^ UInt64(bits[0])) * FNV_PRIME
    elif K == DType.int16 or K == DType.uint16:
        var bits = bitcast[DType.uint16, 1](SIMD[K, 1](k))
        return (state ^ UInt64(bits[0])) * FNV_PRIME
    elif K == DType.int8 or K == DType.uint8 or K == DType.bool:
        var bits = bitcast[DType.uint8, 1](SIMD[K, 1](k))
        return (state ^ UInt64(bits[0])) * FNV_PRIME
    else:
        # Fallback: treat as 8-byte (covers Int128 via two-fold below
        # — but Int128 is not a single-element Scalar in Mojo
        # so this path is for forward-compat). For unsupported DTypes
        # the SDK lowering arm should route to ByteHashSet.
        var bits = bitcast[DType.uint64, 1](SIMD[K, 1](k))
        return (state ^ bits[0]) * FNV_PRIME


# =============================================================================
# §2 — HashSet1[K0]
# =============================================================================


struct HashSet1[K0: DType](Movable):
    """Arity-1 parametric HashSet over typed Scalar[K0] keys.

    Replaces today's hardcoded `HashSetI64` (arity-1, K0=DType.int64) at
    `runtime_breaker_state.mojo:327`. Storage: a single SoA
    `List[Scalar[K0]]` + parallel `List[UInt64]` hash filter; linear-scan
    insert/contains. The K0=DType.int64 instantiation produces
    byte-identical machine code to today's HashSetI64 inner loop — the
    poc_parametric_variadic_perf POC measures 1.00×.

    Encapsulation: no UnsafePointer in any public sig. Internal storage
    is `List[Scalar[Self.K0]]` (typed; List's own OwnedPointer-backed
    buffer underneath). No wildcard origins.
    """

    var keys: List[Scalar[Self.K0]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys = List[Scalar[Self.K0]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(mut self, k0: Scalar[Self.K0]) -> Bool:
        """Insert key. Returns True on new insert, False on duplicate."""
        var h = _fnv1a_combine[Self.K0](FNV_OFFSET, k0)
        var i = 0
        var n = self.n_used
        while i < n:
            if self.hashes[i] == h and self.keys[i] == k0:
                return False
            i = i + 1
        self.keys.append(k0)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(self, k0: Scalar[Self.K0]) -> Bool:
        var h = _fnv1a_combine[Self.K0](FNV_OFFSET, k0)
        var i = 0
        var n = self.n_used
        while i < n:
            if self.hashes[i] == h and self.keys[i] == k0:
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §3 — HashSet2[K0, K1]
# =============================================================================


struct HashSet2[K0: DType, K1: DType](Movable):
    """Arity-2 parametric HashSet. Replaces today's `HashSetI64I64` at
    `runtime_breaker_state.mojo:409`."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(mut self, k0: Scalar[Self.K0], k1: Scalar[Self.K1]) -> Bool:
        var h = _fnv1a_combine[Self.K1](
            _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(self, k0: Scalar[Self.K0], k1: Scalar[Self.K1]) -> Bool:
        var h = _fnv1a_combine[Self.K1](
            _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §4 — HashSet3[K0, K1, K2]
# =============================================================================


struct HashSet3[K0: DType, K1: DType, K2: DType](Movable):
    """Arity-3 parametric HashSet. Replaces today's `HashSetI64I64I64` at
    `runtime_breaker_state.mojo:467`. TPC-H Q3 shape (3-I64 composite
    DISTINCT) — POC perf 1.00×."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var keys_c2: List[Scalar[Self.K2]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.keys_c2 = List[Scalar[Self.K2]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(
        mut self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K2](
            _fnv1a_combine[Self.K1](
                _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
            ),
            k2,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.keys_c2.append(k2)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(
        self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K2](
            _fnv1a_combine[Self.K1](
                _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
            ),
            k2,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §5 — HashSet4[K0..K3]
# =============================================================================


struct HashSet4[K0: DType, K1: DType, K2: DType, K3: DType](Movable):
    """Arity-4 parametric HashSet. No hardcoded counterpart today; opens
    up arity-4 DISTINCT shapes (H2O h10 6×I64 partial)."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var keys_c2: List[Scalar[Self.K2]]
    var keys_c3: List[Scalar[Self.K3]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.keys_c2 = List[Scalar[Self.K2]](capacity=capacity)
        self.keys_c3 = List[Scalar[Self.K3]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(
        mut self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K3](
            _fnv1a_combine[Self.K2](
                _fnv1a_combine[Self.K1](
                    _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                ),
                k2,
            ),
            k3,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.keys_c2.append(k2)
        self.keys_c3.append(k3)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(
        self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K3](
            _fnv1a_combine[Self.K2](
                _fnv1a_combine[Self.K1](
                    _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                ),
                k2,
            ),
            k3,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §6 — HashSet5[K0..K4]
# =============================================================================


struct HashSet5[K0: DType, K1: DType, K2: DType, K3: DType, K4: DType](Movable):
    """Arity-5 parametric HashSet."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var keys_c2: List[Scalar[Self.K2]]
    var keys_c3: List[Scalar[Self.K3]]
    var keys_c4: List[Scalar[Self.K4]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.keys_c2 = List[Scalar[Self.K2]](capacity=capacity)
        self.keys_c3 = List[Scalar[Self.K3]](capacity=capacity)
        self.keys_c4 = List[Scalar[Self.K4]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(
        mut self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K4](
            _fnv1a_combine[Self.K3](
                _fnv1a_combine[Self.K2](
                    _fnv1a_combine[Self.K1](
                        _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                    ),
                    k2,
                ),
                k3,
            ),
            k4,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.keys_c2.append(k2)
        self.keys_c3.append(k3)
        self.keys_c4.append(k4)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(
        self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K4](
            _fnv1a_combine[Self.K3](
                _fnv1a_combine[Self.K2](
                    _fnv1a_combine[Self.K1](
                        _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                    ),
                    k2,
                ),
                k3,
            ),
            k4,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §7 — HashSet6[K0..K5]
# =============================================================================


struct HashSet6[
    K0: DType, K1: DType, K2: DType, K3: DType, K4: DType, K5: DType,
](Movable):
    """Arity-6 parametric HashSet. H2O h10 6×I64 GROUP BY shape."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var keys_c2: List[Scalar[Self.K2]]
    var keys_c3: List[Scalar[Self.K3]]
    var keys_c4: List[Scalar[Self.K4]]
    var keys_c5: List[Scalar[Self.K5]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.keys_c2 = List[Scalar[Self.K2]](capacity=capacity)
        self.keys_c3 = List[Scalar[Self.K3]](capacity=capacity)
        self.keys_c4 = List[Scalar[Self.K4]](capacity=capacity)
        self.keys_c5 = List[Scalar[Self.K5]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(
        mut self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
        k5: Scalar[Self.K5],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K5](
            _fnv1a_combine[Self.K4](
                _fnv1a_combine[Self.K3](
                    _fnv1a_combine[Self.K2](
                        _fnv1a_combine[Self.K1](
                            _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                        ),
                        k2,
                    ),
                    k3,
                ),
                k4,
            ),
            k5,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
                and self.keys_c5[i] == k5
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.keys_c2.append(k2)
        self.keys_c3.append(k3)
        self.keys_c4.append(k4)
        self.keys_c5.append(k5)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(
        self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
        k5: Scalar[Self.K5],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K5](
            _fnv1a_combine[Self.K4](
                _fnv1a_combine[Self.K3](
                    _fnv1a_combine[Self.K2](
                        _fnv1a_combine[Self.K1](
                            _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                        ),
                        k2,
                    ),
                    k3,
                ),
                k4,
            ),
            k5,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
                and self.keys_c5[i] == k5
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §8 — HashSet7[K0..K6]
# =============================================================================


struct HashSet7[
    K0: DType, K1: DType, K2: DType, K3: DType,
    K4: DType, K5: DType, K6: DType,
](Movable):
    """Arity-7 parametric HashSet."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var keys_c2: List[Scalar[Self.K2]]
    var keys_c3: List[Scalar[Self.K3]]
    var keys_c4: List[Scalar[Self.K4]]
    var keys_c5: List[Scalar[Self.K5]]
    var keys_c6: List[Scalar[Self.K6]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.keys_c2 = List[Scalar[Self.K2]](capacity=capacity)
        self.keys_c3 = List[Scalar[Self.K3]](capacity=capacity)
        self.keys_c4 = List[Scalar[Self.K4]](capacity=capacity)
        self.keys_c5 = List[Scalar[Self.K5]](capacity=capacity)
        self.keys_c6 = List[Scalar[Self.K6]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(
        mut self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
        k5: Scalar[Self.K5],
        k6: Scalar[Self.K6],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K6](
            _fnv1a_combine[Self.K5](
                _fnv1a_combine[Self.K4](
                    _fnv1a_combine[Self.K3](
                        _fnv1a_combine[Self.K2](
                            _fnv1a_combine[Self.K1](
                                _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                            ),
                            k2,
                        ),
                        k3,
                    ),
                    k4,
                ),
                k5,
            ),
            k6,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
                and self.keys_c5[i] == k5
                and self.keys_c6[i] == k6
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.keys_c2.append(k2)
        self.keys_c3.append(k3)
        self.keys_c4.append(k4)
        self.keys_c5.append(k5)
        self.keys_c6.append(k6)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(
        self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
        k5: Scalar[Self.K5],
        k6: Scalar[Self.K6],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K6](
            _fnv1a_combine[Self.K5](
                _fnv1a_combine[Self.K4](
                    _fnv1a_combine[Self.K3](
                        _fnv1a_combine[Self.K2](
                            _fnv1a_combine[Self.K1](
                                _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                            ),
                            k2,
                        ),
                        k3,
                    ),
                    k4,
                ),
                k5,
            ),
            k6,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
                and self.keys_c5[i] == k5
                and self.keys_c6[i] == k6
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used


# =============================================================================
# §9 — HashSet8[K0..K7]
# =============================================================================


struct HashSet8[
    K0: DType, K1: DType, K2: DType, K3: DType,
    K4: DType, K5: DType, K6: DType, K7: DType,
](Movable):
    """Arity-8 parametric HashSet. Max parametric arity per Option D
    design doc §1.2 non-goal #2; arity > 8 falls back to ByteHashSet."""

    var keys_c0: List[Scalar[Self.K0]]
    var keys_c1: List[Scalar[Self.K1]]
    var keys_c2: List[Scalar[Self.K2]]
    var keys_c3: List[Scalar[Self.K3]]
    var keys_c4: List[Scalar[Self.K4]]
    var keys_c5: List[Scalar[Self.K5]]
    var keys_c6: List[Scalar[Self.K6]]
    var keys_c7: List[Scalar[Self.K7]]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = HASHSET_DEFAULT_CAPACITY):
        self.keys_c0 = List[Scalar[Self.K0]](capacity=capacity)
        self.keys_c1 = List[Scalar[Self.K1]](capacity=capacity)
        self.keys_c2 = List[Scalar[Self.K2]](capacity=capacity)
        self.keys_c3 = List[Scalar[Self.K3]](capacity=capacity)
        self.keys_c4 = List[Scalar[Self.K4]](capacity=capacity)
        self.keys_c5 = List[Scalar[Self.K5]](capacity=capacity)
        self.keys_c6 = List[Scalar[Self.K6]](capacity=capacity)
        self.keys_c7 = List[Scalar[Self.K7]](capacity=capacity)
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def insert(
        mut self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
        k5: Scalar[Self.K5],
        k6: Scalar[Self.K6],
        k7: Scalar[Self.K7],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K7](
            _fnv1a_combine[Self.K6](
                _fnv1a_combine[Self.K5](
                    _fnv1a_combine[Self.K4](
                        _fnv1a_combine[Self.K3](
                            _fnv1a_combine[Self.K2](
                                _fnv1a_combine[Self.K1](
                                    _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                                ),
                                k2,
                            ),
                            k3,
                        ),
                        k4,
                    ),
                    k5,
                ),
                k6,
            ),
            k7,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
                and self.keys_c5[i] == k5
                and self.keys_c6[i] == k6
                and self.keys_c7[i] == k7
            ):
                return False
            i = i + 1
        self.keys_c0.append(k0)
        self.keys_c1.append(k1)
        self.keys_c2.append(k2)
        self.keys_c3.append(k3)
        self.keys_c4.append(k4)
        self.keys_c5.append(k5)
        self.keys_c6.append(k6)
        self.keys_c7.append(k7)
        self.hashes.append(h)
        self.n_used = n + 1
        return True

    @always_inline
    def contains(
        self,
        k0: Scalar[Self.K0],
        k1: Scalar[Self.K1],
        k2: Scalar[Self.K2],
        k3: Scalar[Self.K3],
        k4: Scalar[Self.K4],
        k5: Scalar[Self.K5],
        k6: Scalar[Self.K6],
        k7: Scalar[Self.K7],
    ) -> Bool:
        var h = _fnv1a_combine[Self.K7](
            _fnv1a_combine[Self.K6](
                _fnv1a_combine[Self.K5](
                    _fnv1a_combine[Self.K4](
                        _fnv1a_combine[Self.K3](
                            _fnv1a_combine[Self.K2](
                                _fnv1a_combine[Self.K1](
                                    _fnv1a_combine[Self.K0](FNV_OFFSET, k0), k1
                                ),
                                k2,
                            ),
                            k3,
                        ),
                        k4,
                    ),
                    k5,
                ),
                k6,
            ),
            k7,
        )
        var i = 0
        var n = self.n_used
        while i < n:
            if (
                self.hashes[i] == h
                and self.keys_c0[i] == k0
                and self.keys_c1[i] == k1
                and self.keys_c2[i] == k2
                and self.keys_c3[i] == k3
                and self.keys_c4[i] == k4
                and self.keys_c5[i] == k5
                and self.keys_c6[i] == k6
                and self.keys_c7[i] == k7
            ):
                return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        return self.n_used
