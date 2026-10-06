# =============================================================================
# HashAggDecodedRG — decode-fused key + hash + fingerprint + partition_id
# =============================================================================
#
# Phase I-A of Wave 9 v4.1.3 (decode-fused hash agg). The SLAB hash agg
# sink (`SlabHashAggSink`) currently decodes its group-by key column from
# the per-RG `RecordBatch` columns inside its `consume()` body, then
# computes
#
#     hash      = _fib_hash_1(key)
#     fp        = UInt8(h >> 56) | 0x80
#     partition = _partition_for_shape_b(h)
#
# per-row in the probe loop. Profiles (cluster_c b5, q3 FORCE_SLAB hc1)
# show that block accounts for ~95% of remaining FORCE_SLAB wall time
# at HEAD (770 ms on hc1).
#
# Phase I-A moves those four computations into the parquet decode loop —
# amortized over the L1-cached decoded key bytes. The parquet source
# attaches a `HashAggDecodedRG` to the morsel; the agg sink's
# `consume()` body then probes against pre-computed `hashes`,
# `fingerprints`, and `partition_ids` instead of recomputing per-row.
#
# Predicted -50-100 ms wall on hc1 FORCE_SLAB.
#
# Why this lives in `komira_morsel` (not `komira_engine_operators` or
# `komira_parquet`):
#   - `komira_parquet` cannot import from `komira_engine_operators`
#     (engine_operators depends on parquet via the dispatch layer; a
#     reverse edge would be a cycle).
#   - `komira_engine_operators` already depends on `komira_morsel`
#     (the Morsel + sink trait surface lives in morsel).
#   - `komira_parquet` already depends on `komira_morsel`.
#   - Therefore `komira_morsel` is the unique pkg both can reach
#     for shared types like `HashAggDecodedRG`, the Phase I-A hash
#     functions, and the `N_PARTITIONS` constant.
#
# Hash-function correctness
# -------------------------
# `fib_hash_key`, `partition_for_hash`, and `fingerprint_for_hash` are
# byte-exact copies of the canonical implementations in
# `komira_engine_operators/flat_hash_agg_hash.mojo:_fib_hash_1` and
# `komira_engine_operators/unified/agg/slab_hash_agg_sink.mojo:
# _partition_for_shape_b`. The agg sink's probe MUST agree bit-for-bit
# with what the parquet decode loop precomputes; if either drifts,
# the sink finds an incorrect partition slot and the merge silently
# produces duplicate groups.
#
# Per the PERF-CORRECTNESS-CRITICAL banner above `_fib_hash_2` in
# `flat_hash_agg_hash.mojo`: changes to either `fib_hash_key` here or
# `_fib_hash_1` there require a randomized cross-impl correctness test
# asserting `fib_hash_key(k) == _fib_hash_1(k)` for many random k.
#
# Pointer discipline
# ------------------
# - Public API: zero `UnsafePointer` in any signature.
# - `hashes` / `fingerprints` are `MmapAlignedBuffer[64]`-backed for SIMD
#   compatibility with the agg sink's bulk probe path.
# - `partition_ids` is a `List[UInt8]` (no SIMD requirement; the sink
#   indexes scalar-per-row).
# - `agg_input_columns` is a `Slab[Column]` (decode-time-owned copies;
#   the sink consumes them by reference into its accumulator).
# =============================================================================

from std.sys import size_of

from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow.column import Column
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.collections.slab import Slab


# =============================================================================
# Shape B partition layout (single source of truth)
# =============================================================================
#
# `N_PARTITIONS` and `_PART_SHIFT` mirror the constants in
# `komira_engine_operators/unified/agg/slab_hash_agg_sink.mojo`
# (`N_PARTITIONS_SHAPE_B`, `_PART_SHIFT_SHAPE_B`,
# `_PART_MASK_SHAPE_B`). The engine sink imports these from here so the
# parquet decode loop and the sink's combine path agree by construction.
# =============================================================================

comptime N_PARTITIONS: Int = 64
"""Phase H Shape B partition count (Wave 9 v4.1.3).

Matches `slab_hash_agg_sink._N_PARTITIONS_SHAPE_B` and Path 2's
`_NUM_PARTITIONS_FLATHASH`. 6-bit partition tag.
"""

comptime _PART_SHIFT: Int = 32
"""Hash bit shift for Shape B partition selection.

Avoids overlap with the SlabStorage fingerprint (`h >> 56`) and slot
mask (low bits) per the radix-combine HALT memo's Shape C analysis.
Mirrors `slab_hash_agg_sink._PART_SHIFT_SHAPE_B`.
"""

comptime _PART_MASK: UInt64 = 0x3F
"""Mask for `N_PARTITIONS == 64`. Mirrors `_PART_MASK_SHAPE_B`."""

comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15
"""Fibonacci hashing constant for 64-bit: 2^64 / phi.

Mirrors `flat_hash_agg_hash._FIB_HASH_CONST`.
"""


# =============================================================================
# Hash + partition + fingerprint helpers
# =============================================================================
#
# PERF-CORRECTNESS-CRITICAL: `fib_hash_key` MUST match
# `komira_engine_operators.flat_hash_agg_hash._fib_hash_1` bit-for-bit.
# Phase I-A's correctness contract is that the sink's per-row probe
# computes the SAME hash + fingerprint + partition that the parquet
# decode loop precomputed. Any drift produces duplicate-group bugs of
# the kind documented in the `_fib_hash_2` banner.
# =============================================================================


@always_inline
def fib_hash_key(k: Int64) -> UInt64:
    """Hash a single Int64 key. Guarantees result != 0.

    Bit-identical to `_fib_hash_1(k)` in
    `komira_engine_operators.flat_hash_agg_hash`. Do NOT modify
    one without modifying the other; see the module header.
    """
    var h = UInt64(k) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    # Ensure non-zero (zero is the empty sentinel in SlabStorage).
    if h == 0:
        h = 1
    return h


@always_inline
def fingerprint_for_hash(h: UInt64) -> UInt8:
    """Compute the SlabStorage fingerprint for hash `h`.

    Mirrors the implicit fingerprint encoding from Phase F:
        fp = UInt8(h >> 56) | 0x80

    The high-bit OR (`| 0x80`) ensures the fingerprint byte is never
    zero, distinguishing a populated entry from the empty-slot sentinel
    (0x00) that the SlabStorage uses.
    """
    return UInt8(h >> 56) | UInt8(0x80)


@always_inline
def partition_for_hash(h: UInt64) -> Int:
    """Compute the Shape B partition_id for hash `h`.

    Single shift+mask. Bit-identical to
    `slab_hash_agg_sink._partition_for_shape_b(h)`.
    """
    return Int((h >> UInt64(_PART_SHIFT)) & _PART_MASK)


# =============================================================================
# HashAggDecodedRG — the morsel-attached payload
# =============================================================================


struct HashAggDecodedRG(Movable, Deinitable):
    """Decode-fused hash-agg RG payload.

    Carries the per-RG decoded key column plus pre-computed hashes,
    fingerprints, and partition ids — all amortized over the parquet
    decode pass (which already touches the key bytes for column
    materialization).

    Single-Int64-key contract (v0.1):
        Only the single-key Int64 group-by shape is supported. Multi-
        key shapes are out of scope for Phase I-A; the planner gates
        the decode-fused path on the key column count + dtype before
        setting `caps.hash_agg_key_col_idx`.

    Field set:
        key_array         — decoded Int64 key column (PrimitiveArray for
                            zero-copy access to the typed buffer in the
                            sink's probe loop).
        hashes            — `MmapAlignedBuffer[64]` holding `num_rows`
                            consecutive UInt64 hash values, one per row.
                            Stride: `size_of[UInt64]() == 8` bytes.
        fingerprints      — `MmapAlignedBuffer[64]` holding `num_rows`
                            consecutive UInt8 fingerprint bytes.
                            Stride: 1 byte.
        partition_ids     — `List[UInt8]` of length `num_rows`. Each
                            entry is in [0, N_PARTITIONS). Plain List
                            (not MmapAlignedBuffer) because the sink reads
                            scalar-per-row, not SIMD-bulk.
        agg_input_columns — Decoded agg input columns, in the order the
                            caller requested them. Owned `Column` copies
                            extracted from the per-RG RecordBatch.
        num_rows          — Row count (matches every per-row buffer's
                            logical length).

    Lifetime:
        Owned via `Optional[OwnedPointer[HashAggDecodedRG]]` on
        `Morsel.hash_agg_decoded`. The Morsel transports the payload
        from the parquet source to the agg sink's `consume()` body;
        the sink reads-by-reference from the OwnedPointer and the
        Optional.take() the OwnedPointer out of the Morsel when the
        sink is done with it (or just lets the Morsel destructor
        release it).
    """

    var key_array: PrimitiveArray[DType.int64]
    var hashes: SharedAlignedBuffer[HeapRegion]
    var fingerprints: SharedAlignedBuffer[HeapRegion]
    var partition_ids: List[UInt8]
    var agg_input_columns: Slab[Column[HeapRegion]]
    var num_rows: Int

    def __init__(
        out self,
        var key_array: PrimitiveArray[DType.int64],
        var hashes: SharedAlignedBuffer[HeapRegion],
        var fingerprints: SharedAlignedBuffer[HeapRegion],
        var partition_ids: List[UInt8],
        var agg_input_columns: Slab[Column[HeapRegion]],
        num_rows: Int,
    ):
        """Construct a HashAggDecodedRG from already-computed buffers.

        Caller (parquet `decode_for_hash_agg`) is responsible for
        producing each buffer at the correct logical length:

            len(key_array)              == num_rows
            hashes capacity (in UInt64) == num_rows
            fingerprints capacity (UInt8) == num_rows
            len(partition_ids)          == num_rows

        R3.3.E.4 Batch 1: `hashes` / `fingerprints` field
        type flipped from `MmapAlignedBuffer[64]` to
        `SharedAlignedBuffer[HeapRegion]`. Producer-side ctor takes SAB
        directly; if the producer has an `OwnedAlignedBuffer`, bridge
        via `SharedAlignedBuffer.from_owned(buf^)` at the call site
        (see komira_parquet/parquet_reader.mojo:_decode_for_hash_agg).
        Accessor surface (`hash_at`, `fingerprint_at`) is unchanged
        because SAB exposes identical `get_typed[T]` / `set_typed[T]`
        public API to OLD AB. Path to objectstore-v04 retirement of the
        OLD `MmapAlignedBuffer` struct (R3.3.F).
        """
        self.key_array = key_array^
        self.hashes = hashes^
        self.fingerprints = fingerprints^
        self.partition_ids = partition_ids^
        self.agg_input_columns = agg_input_columns^
        self.num_rows = num_rows

    @staticmethod
    def from_key_col(
        var key_array: PrimitiveArray[DType.int64],
        var hashes: SharedAlignedBuffer[HeapRegion],
        var fingerprints: SharedAlignedBuffer[HeapRegion],
        var partition_ids: List[UInt8],
        var agg_input_columns: Slab[Column[HeapRegion]],
    ) -> HashAggDecodedRG:
        """Convenience constructor: pulls `num_rows` from `key_array.length`.

        Equivalent to the explicit `__init__` with `num_rows=key_array.length`.
        Keeps the parquet-side decode site terse.

        R3.3.E.4 Batch 1: SAB-typed `hashes` / `fingerprints` params (see
        `__init__` docstring).
        """
        var n = key_array.length
        return HashAggDecodedRG(
            key_array^,
            hashes^,
            fingerprints^,
            partition_ids^,
            agg_input_columns^,
            n,
        )

    @always_inline
    def hash_at(self, row: Int) -> UInt64:
        """Read the precomputed hash for `row`. Offset-aware via the
        MmapAlignedBuffer's `get_typed[UInt64]`."""
        return self.hashes.get_typed[UInt64](row)

    @always_inline
    def fingerprint_at(self, row: Int) -> UInt8:
        """Read the precomputed fingerprint byte for `row`."""
        return self.fingerprints.get_typed[UInt8](row)

    @always_inline
    def partition_at(self, row: Int) -> Int:
        """Read the precomputed partition_id for `row`. Returns `Int`
        (matches `partition_for_hash` return type)."""
        return Int(self.partition_ids[row])
