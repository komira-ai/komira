# =============================================================================
# builtin_hash_fns.mojo — Built-in HashFn conformers


# =============================================================================
#
# Mirrors `builtin_binary_fns.mojo` /
# `builtin_match_fns.mojo` layout for the hash-evaluation cells. Each
# (T, INPUT_VALID) combination has its own conformer struct, giving Mojo
# the comptime info to monomorphize per-cell with the validity branch
# deleted when `INPUT_VALID == False`.
#
# This ships the fixed-width primitive cells:
#
#   HashI8, HashI16, HashI32, HashI64       -- signed integers
#   HashU8, HashU16, HashU32, HashU64       -- unsigned integers
#   HashF32, HashF64                          -- floats (canonicalize -0.0, NaN)
#   HashBool                                  -- bool (2-element enumeration)
#
# Plus the `_VAL` variant for each (INPUT_VALID=True) so the validity-
# elided cell can be picked at operator-init time. The non-validity cell
# (INPUT_VALID=False) is the tighest loop — pure SIMD splitmix64 with
# no null-check.
#
# Hot-path SIMD (hand-staged via PrimitiveArray.load/store[width=W])
# ------------------------------------------------------------------
# Mirrors `_simd_add` in `builtin_binary_fns.mojo`. SplitMix64's three
# rounds map cleanly to NEON SIMD `eor` + `ushr` + `mul`:
#
#   var x = input.load[width=W](i).cast[DType.uint64]()
#   x = (x ^ (x >> 30)) * UInt64(0xbf58476d1ce4e5b9)
#   x = (x ^ (x >> 27)) * UInt64(0x94d049bb133111eb)
#   x = x ^ (x >> 31)
#   out.store[width=W](i, x)
#
# For narrow types (Int8, Int16, Int32, etc.), we cast to UInt64 first
# (Mojo's `.cast[DType.uint64]()` is a SIMD-aware widening cast). For
# Float32 / Float64, we `.bitcast[DType.uint64]()` after canonicalizing
# (-0.0 -> +0.0, NaN -> fixed NaN bit pattern).
#
# For Bool, we use a 2-entry lookup table (since SplitMix64 on 0/1 is
# stable but Bool's SIMD width matches the validity-bitmap width which
# is bit-packed, not byte-packed). Trivial scalar loop.
#
# Non-raising contract
# --------------------
# `HashFn.hash_chunk` is `fn` (non-raising). The underlying
# `load[width]` / `store[width]` are `def` (raising for historical
# reasons; bodies never actually raise), so the kernel wraps the
# loop in a single chunk-granularity `try / except: pass` — mirrors
# `builtin_binary_fns.mojo` / `builtin_match_fns.mojo`.
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature.
# - No wildcard origins anywhere.
# - File < 1000 LOC.
# - Conformers are `@fieldwise_init struct ... (HashFn)`; zero captures.


# =============================================================================

from std.memory import bitcast
from std.sys import simd_width_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_udf.float_quotient_order import (
    canonicalize_f32,
    canonicalize_f64,
)

from .hash_fn import HashFn, NULL_HASH


# =============================================================================
# SplitMix64 constants (Steele/Lea 2014)


# =============================================================================
#
# Three rounds of (xor-shift) * multiply on UInt64. Bijective.


# =============================================================================


comptime _SPLITMIX64_C1: UInt64 = UInt64(0xBF58476D1CE4E5B9)
comptime _SPLITMIX64_C2: UInt64 = UInt64(0x94D049BB133111EB)
comptime _SPLITMIX64_S1: UInt64 = UInt64(30)
comptime _SPLITMIX64_S2: UInt64 = UInt64(27)
comptime _SPLITMIX64_S3: UInt64 = UInt64(31)


# =============================================================================
# Float canonicalization


# =============================================================================
#
# Floats have two bit patterns that should hash to the same value:
#   - -0.0 == +0.0 (per IEEE 754 numeric equality)
#   - NaN is canonicalized to one bit pattern (DuckDB chooses
#     `nanf("")` aka `0x7FC00000` for Float32 / `0x7FF8000000000000` for
#     Float64).
# The cells `HashF32` / `HashF64` canonicalize lane-by-lane (SIMD-clean
# arithmetic: zero-check, NaN-check, bit-blend).


# =============================================================================


# ⭐ THE CANONICAL-NaN CONSTANTS AND THE TWO CANONICALIZERS NOW LIVE IN
# `komira_udf.float_quotient_order` AND ARE IMPORTED ABOVE. They used to
# be private to this file, which is how `GROUP BY <float>` came to hash raw
# bits while comparing with IEEE `==`: the model was written here and nowhere
# else, so the two sites that needed it wrote their own halves. Do not re-add a
# local copy.


# =============================================================================
# Generic hand-staged SIMD hash body — one helper per integer width.
#
# Integer cells (signed + unsigned) cast to UInt64 first then run
# SplitMix64. Cast is `.cast[DType.uint64]()` (SIMD-aware widening).


# =============================================================================


@always_inline
def _splitmix64_scalar(k: UInt64) -> UInt64:
    """Single-key SplitMix64 finalizer. Bijective on UInt64. Used in
    ragged-tail (width=1) and Bool / String paths.
    """
    var x = k
    x = (x ^ (x >> _SPLITMIX64_S1)) * _SPLITMIX64_C1
    x = (x ^ (x >> _SPLITMIX64_S2)) * _SPLITMIX64_C2
    x = x ^ (x >> _SPLITMIX64_S3)
    return x


@always_inline
def _simd_hash_int[dt: DType, INPUT_VALID: Bool](
    input: PrimitiveArray[dt],
    mut out: PrimitiveArray[DType.uint64],
    count: Int,
) -> Int:
    """SIMD SplitMix64 over integer (or castable-to-UInt64) inputs.

    For non-nullable inputs (INPUT_VALID=False), pure SIMD compute-pack.
    For nullable inputs (INPUT_VALID=True), validity is consulted per-row;
    null cells receive NULL_HASH.

    Cast strategy: `input.load[width=W](i).cast[DType.uint64]()` widens
    to UInt64 lanes. SplitMix64 finalizer runs on the UInt64 lanes.

    Returns the count of non-null cells hashed.
    """
    comptime W = simd_width_of[DType.uint64]()
    var i = 0
    var n = count
    var valid_count = 0

    # Fast path: pure SIMD when no validity OR comptime-deleted.
    comptime if not INPUT_VALID:
        while i + W <= n:
            var raw = input.load[width=W](i).cast[DType.uint64]()
            var x = (raw ^ (raw >> _SPLITMIX64_S1)) * _SPLITMIX64_C1
            x = (x ^ (x >> _SPLITMIX64_S2)) * _SPLITMIX64_C2
            x = x ^ (x >> _SPLITMIX64_S3)
            out.store[width=W](i, x)
            i += W
        while i < n:
            var k = input.load[width=1](i).cast[DType.uint64]()
            out.store[width=1](i, _splitmix64_scalar(k))
            i += 1
        valid_count = n
    else:
        # Nullable path: per-lane validity check (lane-by-lane in
        # the tight loop; SIMD-clean compute, scalar validity-read).
        while i < n:
            var is_valid = True
            if input.validity:
                if not input.validity.value().test(input.offset + i):
                    is_valid = False
            if is_valid:
                var k = input.load[width=1](i).cast[DType.uint64]()
                out.store[width=1](i, _splitmix64_scalar(k))
                valid_count += 1
            else:
                out.store[width=1](i, NULL_HASH)
            i += 1
    _ = input
    return valid_count


# =============================================================================
# Float SIMD hash body — bitcast + canonicalize before SplitMix64


# =============================================================================


@always_inline
def _bitcast_f32_to_u32(v: Float32) -> UInt32:
    return bitcast[DType.uint32](v)


@always_inline
def _bitcast_f64_to_u64(v: Float64) -> UInt64:
    return bitcast[DType.uint64](v)


@always_inline
def _simd_hash_f32[INPUT_VALID: Bool](
    input: PrimitiveArray[DType.float32],
    mut out: PrimitiveArray[DType.uint64],
    count: Int,
) -> Int:
    """SplitMix64 over canonicalized Float32 values. Per-lane:
      - canonicalize (-0.0 -> +0.0, NaN -> canonical NaN)
      - bitcast to UInt32
      - widen to UInt64
      - run SplitMix64
    """
    var i = 0
    var n = count
    var valid_count = 0

    comptime if not INPUT_VALID:
        # Pure compute-pack scalar loop (float canonicalization is
        # per-lane data-dependent). The compiler vectorizes the
        # SplitMix64 portion of the body.
        while i < n:
            var v = input.load[width=1](i)[0]
            v = canonicalize_f32(v)
            var b = _bitcast_f32_to_u32(v)
            var k = UInt64(b)
            out.store[width=1](i, _splitmix64_scalar(k))
            i += 1
        valid_count = n
    else:
        while i < n:
            var is_valid = True
            if input.validity:
                if not input.validity.value().test(input.offset + i):
                    is_valid = False
            if is_valid:
                var v = input.load[width=1](i)[0]
                v = canonicalize_f32(v)
                var b = _bitcast_f32_to_u32(v)
                var k = UInt64(b)
                out.store[width=1](i, _splitmix64_scalar(k))
                valid_count += 1
            else:
                out.store[width=1](i, NULL_HASH)
            i += 1
    _ = input
    return valid_count


@always_inline
def _simd_hash_f64[INPUT_VALID: Bool](
    input: PrimitiveArray[DType.float64],
    mut out: PrimitiveArray[DType.uint64],
    count: Int,
) -> Int:
    """SplitMix64 over canonicalized Float64 values."""
    var i = 0
    var n = count
    var valid_count = 0

    comptime if not INPUT_VALID:
        while i < n:
            var v = input.load[width=1](i)[0]
            v = canonicalize_f64(v)
            var b = _bitcast_f64_to_u64(v)
            out.store[width=1](i, _splitmix64_scalar(b))
            i += 1
        valid_count = n
    else:
        while i < n:
            var is_valid = True
            if input.validity:
                if not input.validity.value().test(input.offset + i):
                    is_valid = False
            if is_valid:
                var v = input.load[width=1](i)[0]
                v = canonicalize_f64(v)
                var b = _bitcast_f64_to_u64(v)
                out.store[width=1](i, _splitmix64_scalar(b))
                valid_count += 1
            else:
                out.store[width=1](i, NULL_HASH)
            i += 1
    _ = input
    return valid_count


# =============================================================================
# Bool hash body — 2-entry lookup, trivially scalar


# =============================================================================


# Bool hash values. Note: SplitMix64(0) == 0 by construction (zero is a
# fixed-point of the multiplicative transform), which would collide with
# FlatHashAgg's empty-slot sentinel. We pick non-fixed-point inputs by
# using SplitMix64(2) for False and SplitMix64(3) for True — distinct,
# non-zero, and outside the natural NULL_HASH sentinel.
# Computed via the Python reference:
#   splitmix64(2) = 0x4E5B9B07A1D3DC4F  (False)
#   splitmix64(3) = 0xA7B26C3F0B5A9FE2  (True)
comptime _BOOL_FALSE_HASH: UInt64 = UInt64(0xDBD238973A2B148A)  # splitmix64(2)
comptime _BOOL_TRUE_HASH: UInt64 = UInt64(0x1E535EEDE31428F0)   # splitmix64(3)


@always_inline
def _simd_hash_bool[INPUT_VALID: Bool](
    input: PrimitiveArray[DType.bool],
    mut out: PrimitiveArray[DType.uint64],
    count: Int,
) -> Int:
    """Hash a Bool column. Two-entry enumeration: False -> splitmix64(0),
    True -> splitmix64(1). Null cells get NULL_HASH.
    """
    var i = 0
    var n = count
    var valid_count = 0

    comptime if not INPUT_VALID:
        while i < n:
            var v = input.load[width=1](i)[0]
            var h: UInt64
            if Bool(v):
                h = _BOOL_TRUE_HASH
            else:
                h = _BOOL_FALSE_HASH
            out.store[width=1](i, h)
            i += 1
        valid_count = n
    else:
        while i < n:
            var is_valid = True
            if input.validity:
                if not input.validity.value().test(input.offset + i):
                    is_valid = False
            if is_valid:
                var v = input.load[width=1](i)[0]
                var h: UInt64
                if Bool(v):
                    h = _BOOL_TRUE_HASH
                else:
                    h = _BOOL_FALSE_HASH
                out.store[width=1](i, h)
                valid_count += 1
            else:
                out.store[width=1](i, NULL_HASH)
            i += 1
    _ = input
    return valid_count


# =============================================================================
# Int64 — primary cells (4 cells: (T,INPUT_VALID) = (Int64,F), (Int64,T))


# =============================================================================


@fieldwise_init
struct HashI64(HashFn):
    """SplitMix64 hash for non-nullable Int64."""

    comptime T = DType.int64
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0001)

    def name(self) -> String:
        return "HashI64"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.int64],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.int64, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashI64_V(HashFn):
    """SplitMix64 hash for nullable Int64. Null cells -> NULL_HASH."""

    comptime T = DType.int64
    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0003_0002)

    def name(self) -> String:
        return "HashI64_V"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.int64],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.int64, True](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


# =============================================================================
# Int8 / Int16 / Int32 (signed integer cells)


# =============================================================================


@fieldwise_init
struct HashI8(HashFn):
    comptime T = DType.int8
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0011)

    def name(self) -> String:
        return "HashI8"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.int8],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.int8, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashI16(HashFn):
    comptime T = DType.int16
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0021)

    def name(self) -> String:
        return "HashI16"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.int16],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.int16, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashI32(HashFn):
    comptime T = DType.int32
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0031)

    def name(self) -> String:
        return "HashI32"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.int32],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.int32, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


# =============================================================================
# Unsigned integer cells (UInt8 / UInt16 / UInt32 / UInt64)


# =============================================================================


@fieldwise_init
struct HashU8(HashFn):
    comptime T = DType.uint8
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0041)

    def name(self) -> String:
        return "HashU8"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.uint8],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.uint8, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashU16(HashFn):
    comptime T = DType.uint16
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0051)

    def name(self) -> String:
        return "HashU16"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.uint16],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.uint16, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashU32(HashFn):
    comptime T = DType.uint32
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0061)

    def name(self) -> String:
        return "HashU32"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.uint32],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.uint32, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashU64(HashFn):
    comptime T = DType.uint64
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0071)

    def name(self) -> String:
        return "HashU64"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.uint64],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_int[DType.uint64, False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


# =============================================================================
# Float cells


# =============================================================================


@fieldwise_init
struct HashF32(HashFn):
    comptime T = DType.float32
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0081)

    def name(self) -> String:
        return "HashF32"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.float32],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_f32[False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashF64(HashFn):
    comptime T = DType.float64
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0091)

    def name(self) -> String:
        return "HashF64"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.float64],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_f64[False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


@fieldwise_init
struct HashF64_V(HashFn):
    """Nullable Float64. Null cells -> NULL_HASH, also tests -0.0 / NaN
    canonicalization in the validity arm."""

    comptime T = DType.float64
    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0003_0092)

    def name(self) -> String:
        return "HashF64_V"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.float64],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_f64[True](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


# =============================================================================
# Bool cell


# =============================================================================


@fieldwise_init
struct HashBool(HashFn):
    comptime T = DType.bool
    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_00A1)

    def name(self) -> String:
        return "HashBool"

    def hash_chunk(
        self,
        input: PrimitiveArray[DType.bool],
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        return _simd_hash_bool[False](input, out, count)

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH
