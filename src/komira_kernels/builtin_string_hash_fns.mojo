# =============================================================================
# builtin_string_hash_fns.mojo — Built-in StringHashFn conformers
# =============================================================================
#
# Mirrors `builtin_hash_fns.mojo` for
# variable-length UTF-8 strings. The hash algorithm is FNV-1a 64-bit
# (Fowler-Noll-Vo), the canonical short-string hash. Byte-at-a-time
# scalar loop; no SIMD (per-row buffer length varies — the loop overhead
# dominates for the typical 8-32 byte column-data strings).
#
# Why FNV-1a (vs xxhash3 / murmur3)
# ---------------------------------
# 1. Deterministic across platforms (no SIMD intrinsics that vary by
#    arch).
# 2. Byte-at-a-time, so loop unroll potential is low — at the typical
#    column-data string lengths (median 8-16 bytes), the actual hash
#    compute is ~5-15 ns. xxhash3's 32-byte alignment shuffle isn't a
#    win below 64-128 bytes.
# 3. Simple to verify byte-identical across implementations (16-line
#    finalize, 2-constant init).
#
# DuckDB uses MurmurHash64 for strings via the `Hash<string_t>`
# specialization. We pick FNV-1a because of (1)-(3) and the fact that
# DuckDB's MurmurHash64 has additional alignment-required code path
# that doesn't apply to Arrow string buffers (which are byte-aligned).
#
# This ships:
#
#   HashStr        -- non-nullable strings (most common column case)
#   HashStr_V      -- nullable strings (validity bitmap consulted)
#
# Non-raising contract
# --------------------
# `StringHashFn.hash_chunk` is `fn`. The `StringArray.get(i)` accessor
# is def-raising (bounds-check), so the body wraps the loop in a single
# `try / except: pass`.
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature.
# - No wildcard origins anywhere.
# - File < 1000 LOC.
# - Conformers are `@fieldwise_init struct ... (StringHashFn)`.
# - String byte access goes through `StringArray.data.view_ro()` +
#   `read_u8_at(offset)` — the typed accessor; no raw pointer crosses
#   the module boundary.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_hash import FNV1A_64_OFFSET_BASIS, FNV1A_64_PRIME

from .hash_fn import NULL_HASH, StringHashFn


# =============================================================================
# FNV-1a 64-bit
# =============================================================================
#
# The offset basis and the prime live in `komira_hash`, so every FNV-1a-64 fold
# shares one definition (`komira_hash.fnv1a_64` is the byte-span form).
# `_fnv1a_64_hash_range` below is the StringArray-range form of the
# same fold (xor, then multiply, byte by byte).
# =============================================================================


@always_inline
def _fnv1a_64_hash_range(
    input: StringArray, start: Int, length: Int
) raises -> UInt64:
    """Compute FNV-1a 64-bit hash over `length` bytes starting at byte
    offset `start` in `input.data`. The byte access goes through
    `data.view_ro().read_u8_at(offset)` — the typed accessor.

    NOTE: this function is `raises` because `view_ro` returns a view that
    bounds-checks `read_u8_at`. The caller wraps it in a chunk-level
    try/except per the non-raising contract.
    """
    var h = FNV1A_64_OFFSET_BASIS
    var view = input.data.view_ro()
    for off in range(length):
        var b = view.read_u8_at(start + off)
        h = h ^ UInt64(b)
        h = h * FNV1A_64_PRIME
    return h


# =============================================================================
# HashStr — non-nullable string column
# =============================================================================


@fieldwise_init
struct HashStr(StringHashFn):
    """FNV-1a 64-bit hash for non-nullable UTF-8 string column."""

    comptime INPUT_VALID = False
    comptime KERNEL_ID = UInt32(0x0003_0101)

    def name(self) -> String:
        return "HashStr"

    def hash_chunk(
        self,
        input: StringArray,
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        var valid_count = 0
        try:
            for i in range(count):
                # Per-row byte range: [offsets[i], offsets[i+1]).
                var start = Int(input.offsets.get_typed[Int32](i))
                var end = Int(input.offsets.get_typed[Int32](i + 1))
                var length = end - start
                var h = _fnv1a_64_hash_range(input, start, length)
                out.store[width=1](i, h)
                valid_count += 1
        except:
            pass
        _ = input
        return valid_count

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH


# =============================================================================
# HashStr_V — nullable string column
# =============================================================================


@fieldwise_init
struct HashStr_V(StringHashFn):
    """FNV-1a 64-bit hash for nullable UTF-8 string column. Null cells
    receive NULL_HASH."""

    comptime INPUT_VALID = True
    comptime KERNEL_ID = UInt32(0x0003_0102)

    def name(self) -> String:
        return "HashStr_V"

    def hash_chunk(
        self,
        input: StringArray,
        mut out: PrimitiveArray[DType.uint64],
        count: Int,
    ) -> Int:
        var valid_count = 0
        try:
            for i in range(count):
                var is_valid = True
                if input.validity:
                    if not input.validity.value().test(i):
                        is_valid = False
                if is_valid:
                    var start = Int(input.offsets.get_typed[Int32](i))
                    var end = Int(input.offsets.get_typed[Int32](i + 1))
                    var length = end - start
                    var h = _fnv1a_64_hash_range(input, start, length)
                    out.store[width=1](i, h)
                    valid_count += 1
                else:
                    out.store[width=1](i, NULL_HASH)
        except:
            pass
        _ = input
        return valid_count

    @always_inline
    def null_hash(self) -> UInt64:
        return NULL_HASH
