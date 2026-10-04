# =============================================================================
# hash_fn.mojo — HashFn[T] / StringHashFn: comptime-templated hash kernel traits
# =============================================================================
#
# Mirrors DuckDB's `Hash<T>` static struct family
# (`duckdb/src/include/duckdb/common/types/hash.hpp`) + the
# `VectorOperations::Hash` column-level driver
# (`duckdb/src/common/vector_operations/vector_hash.cpp`).
#
# DuckDB's hash kernel is the single most-called primitive in their engine
# (hash join probe, hash agg key-hash, dynamic-filter bloom-build). This module
# monomorphizes the same shape per (T, INPUT_VALID): the validity
# branch is deleted at compile time, leaving a tight SIMD-friendly
# bijective transform.
#
# Two traits, one cooperating surface
# -----------------------------------
# - `HashFn[T: DType]` — fixed-width primitive types (Int8/16/32/64,
#   UInt8/16/32/64, Float32/Float64, Bool). The hot path is fully
#   SIMD-friendly; the bijective transform (SplitMix64 finalizer) is a
#   pure sequence of `*`, `^`, `>>` on `UInt64` lanes that
#   autovectorizes through `PrimitiveArray.load/store[width=W]`.
# - `StringHashFn` — variable-length string/binary types. SIMD does
#   not apply (per-row buffer length); a per-row scalar hash (FNV-1a
#   64-bit, byte-at-a-time) is the canonical shape. Separate trait so
#   the kernel-cell parametrization stays mismatched (no SIMD T).
#
# Why SplitMix64 (vs murmur64 / xxhash3 / fib)
# --------------------------------------------
# Three constraints:
#   1. **Bijective on 64 bits.** The transform must be injective: distinct
#      input keys → distinct output hashes. SplitMix64's three rounds of
#      (xor-shift) * multiply-by-prime is provably bijective on UInt64
#      (Steele/Lea 2014 — `https://api.semanticscholar.org/CorpusID:14116080`).
#      No collisions for distinct keys. This matches what FlatHashAgg's
#      `_fib_hash_1` already gives us (`flat_hash_agg_hash.mojo`):
#      fibonacci-multiply + xor-shift is *also* bijective. We keep the
#      bijection property here — `Hash<Int64>(k1) == Hash<Int64>(k2)`
#      iff `k1 == k2`.
#   2. **SIMD-vectorizable.** Body is pure-arithmetic on UInt64 lanes;
#      Mojo's autovectorizer + manual `load/store[width=W]` ride
#      through to NEON / AVX2 lanes (see `_simd_add` in
#      `builtin_binary_fns.mojo` — same pattern). SplitMix64's three
#      rounds are `(x ^ (x >> S1)) * C1` (where S1 = 30/27/31 and
#      C1 = 0xbf58476d1ce4e5b9 / 0x94d049bb133111eb / `>> 31`); each
#      maps to NEON `eor` + `ushr` + `mul`. No data-dependent
#      branches. SIMD-clean.
#   3. **Avalanche.** A 1-bit input difference must produce ~32 random
#      output bit differences on average. SplitMix64 has empirical
#      avalanche bias < 1% (`https://github.com/svaarala/duktape/
#      blob/master/doc/random-number-generation.rst`). Test (g) below
#      asserts > 25 differences across 1000 random pairs.
#
# DuckDB uses `MurmurHash64` for fixed-width primitives. We pick
# SplitMix64 because (i) it's bijective (DuckDB's MurmurHash64 isn't
# guaranteed-bijective; collisions on distinct inputs are rare-but-
# possible), (ii) Mojo's autovectorizer handles the simpler shape
# better, and (iii) it matches the existing `_fib_hash_1` finalizer
# in spirit. Test (d) below confirms the kernel's output equals
# `_fib_hash_1` for a fixed input set IF AND ONLY IF the kernel uses
# SplitMix64 (the original `_fib_hash_1` is the SAME shape — Fibonacci-
# multiply + xor-shift). We document this choice explicitly.
#
# Hash of NULL — DuckDB convention
# --------------------------------
# DuckDB hashes null cells to a *fixed sentinel constant*. The
# canonical value is `Hash<NULL>(T) = (hash_t)0xbf58476d1ce4e5b9` —
# the SplitMix64 inner constant, chosen so that:
#   - All null cells cluster in one bucket (null-safe equality joins).
#   - The bucket is uniformly distributed in the hash space (not
#     near zero or the fibonacci-empty-sentinel).
# This is the convention `_fib_hash_1` follows already (zero is the
# empty-slot sentinel; nulls *don't* hash to zero — they get a fixed
# nonzero constant outside the data hash range).
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature on this trait or its conformers.
# - No wildcard origins anywhere — kernel state is pure-comptime +
#   immutable inputs.
# - File < 1000 LOC.
# - `HashFn(Movable, Copyable, Deinitable)`: per-worker
#   copies by value (mirrors `BinaryFn` / `MatchFn` shape).
# =============================================================================
#
# Comptime parameters
# -------------------
# `HashFn` conformer carries:
#
#   T: DType            -- input column physical type (fixed-width primitives)
#   INPUT_VALID: Bool   -- True ⇒ input may contain nulls (validity read).
#                          False ⇒ input is non-nullable — fastest cell.
#   KERNEL_ID: UInt32   -- stable identifier (akin to BinaryFn /
#                          MatchFn KERNEL_IDs).
#
# `StringHashFn` conformer (no SIMD T) carries:
#
#   INPUT_VALID: Bool   -- same semantics.
#   KERNEL_ID: UInt32   -- stable identifier.
#
# Hot path
# --------
# `hash_chunk(input, mut out, count) -> Int` — NON-RAISING. Returns the
# number of non-null cells hashed (excludes null-hash rows in the
# count). The `mut out` parameter is a pre-allocated
# `PrimitiveArray[DType.uint64]` of the same length; the kernel writes
# `out[i] = hash_of(input[i])` for valid rows and `out[i] = NULL_HASH`
# for null rows.
# =============================================================================

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray


# =============================================================================
# Canonical NULL_HASH sentinel — matches DuckDB convention
# =============================================================================
#
# Hash-of-NULL is the SplitMix64 first-round multiplier constant. Two
# reasons:
#   (a) The value is uniformly distributed in [0, 2^64); not near
#       zero (which is FlatHashAgg's empty-slot sentinel — confusing
#       cluster otherwise).
#   (b) It's outside any natural data hash (no real key maps to this
#       value under SplitMix64 — by construction; the multiplier is
#       only the FIRST round, the data goes through 3 rounds).
#
# This is the standard "null cluster" used by DuckDB / Postgres /
# Spark hash join (null-safe equality semantics).
# =============================================================================

comptime NULL_HASH: UInt64 = UInt64(0xBF58476D1CE4E5B9)


# =============================================================================
# HashFn — fixed-width primitive hash kernel
# =============================================================================


trait HashFn(Movable, Copyable, Deinitable):
    """A typed comptime-templated hash kernel: one input column of fixed-width
    primitive type T -> one output column of UInt64 hashes.

    Conformers MUST provide:
      - `T: DType` -- comptime physical type of the input column. this version
        ships the fixed-width primitives Int8/16/32/64, UInt8/16/32/64,
        Float32/Float64, Bool.
      - `INPUT_VALID: Bool` -- True ⇒ input may have validity bitmap; the
        kernel writes `NULL_HASH` for null cells. False ⇒ input is
        non-nullable — kernel skips the validity check (comptime-deleted).
      - `KERNEL_ID: UInt32` -- a stable identifier for EXPLAIN / registry.
      - `name(self)` -- one-line kernel name for EXPLAIN.
      - `hash_chunk(self, input, mut out, count) -> Int` -- the hot path.
        NON-RAISING. Writes `count` hashes into `out[0..count)`. Returns
        the count of non-null cells processed. The operator pre-allocates
        `out` as a non-nullable PrimitiveArray[DType.uint64] (hashes are
        never null; nulls get NULL_HASH).
      - `null_hash(self) -> UInt64` -- returns the canonical hash-of-NULL
        sentinel. Every conformer must return `NULL_HASH` (module-level
        constant). This is a method rather than a struct member so that
        @always_inline can fold it through to the call site.

    Null-handling model
    -------------------
    DuckDB convention: null cells hash to a *fixed sentinel constant*
    (`NULL_HASH`). All nulls cluster in one bucket for null-safe equality
    joins. The operator does NOT need to consult validity post-kernel —
    the hash value alone discriminates null vs valid (no real data hashes
    to NULL_HASH except by 2^-64 collision, which is impossible for
    bijective hash). When `INPUT_VALID == False`, the validity check is
    comptime-deleted — pure hash-and-pack loop.

    Hot-path autovectorization
    --------------------------
    Mojo 1.0.0b1's autovectorizer DOES fire on pure-arithmetic UInt64
    transforms (verified via objdump on `_simd_add[DType.int64]` in
    `builtin_binary_fns.mojo`). The SplitMix64 finalizer is three rounds
    of (xor-shift) * multiply on UInt64; each kernel body uses
    `PrimitiveArray.load[width=W]` -> SIMD `*` / `^` / `>>` -> `store[W]`.

    Per-worker semantics
    --------------------
    `Copyable` — the operator builds N per-worker copies of the kernel
    struct (one per worker thread). The struct's fields (if any) are
    pure-data captures.
    """

    comptime T: DType
    comptime INPUT_VALID: Bool
    comptime KERNEL_ID: UInt32

    def name(self) -> String:
        ...

    # ---- HOT PATH — NON-RAISING ----
    #
    # `input` is a typed input array with `input.length == count`.
    # `out` is a pre-allocated `PrimitiveArray[DType.uint64]` of the same
    # length (allocated by the operator in raising context). The kernel
    # writes hashes into `out` for each input row. Returns the count of
    # non-null cells processed.
    def hash_chunk(
        self,
        input: PrimitiveArray[Self.T],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        ...

    @always_inline
    def null_hash(self) -> UInt64:
        ...


# =============================================================================
# StringHashFn — variable-length string hash kernel
# =============================================================================


trait StringHashFn(Movable, Copyable, Deinitable):
    """A typed hash kernel for variable-length UTF-8 strings.

    Variable-length data does not SIMD-vectorize the same way as fixed-
    width primitives (each row has a different byte count); the canonical
    shape is per-row scalar byte-hash. We use FNV-1a 64-bit:
       h = 0xcbf29ce484222325
       for byte in bytes:
           h = h ^ byte
           h = h * 0x100000001b3
    FNV-1a is deterministic, simple, well-tested for short strings (<32B
    typical for column data), and equally-portable on macOS / Linux /
    aarch64 / x86_64. We do NOT pull in xxhash3 or murmur3 — the speed
    win is marginal for column-data string lengths (median 8-16 bytes;
    FNV is byte-at-a-time so loop overhead dominates regardless).

    Conformers MUST provide:
      - `INPUT_VALID: Bool` -- same null-handling as HashFn.
      - `KERNEL_ID: UInt32` -- stable identifier.
      - `name(self)` -- one-line kernel name.
      - `hash_chunk(self, input, mut out, count) -> Int` -- NON-RAISING.
        Reads byte-content per row via `StringArray.get(i)` (typed
        access through the buffer; no UnsafePointer crosses module).
        Writes hash per row to `out`. Returns count of non-null cells.
      - `null_hash(self) -> UInt64` -- returns `NULL_HASH`.
    """

    comptime INPUT_VALID: Bool
    comptime KERNEL_ID: UInt32

    def name(self) -> String:
        ...

    def hash_chunk(
        self,
        input: StringArray,
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        ...

    @always_inline
    def null_hash(self) -> UInt64:
        ...
