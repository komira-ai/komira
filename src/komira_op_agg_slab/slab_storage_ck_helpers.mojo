# =============================================================================
# slab_storage_ck_helpers -- the composite-key helpers of SlabStorage
# =============================================================================
#
# Stateless free functions over the packed key bytes of a SlabStorage
# group: the byte width of a key column's DType, the composite hash of a
# packed key, and byte equality of two packed keys. `slab_storage.mojo`
# calls them from its probe, insert, rehash and combine paths.
#
# The `UnsafePointer[UInt8]` arguments never leave this package: the only
# caller is `slab_storage.mojo`, and the pointers are borrows over key bytes
# (a caller's stack buffer, or a row of `SlabStorage._key_bytes`) that live
# for the call.
# =============================================================================

from std.collections import Array
from std.memory import UnsafePointer

from komira_counters.keyeq_census import keyeq_record, KEYEQ_SLAB_CK_MEMCMP
from komira_op_agg_hash.flat_hash_agg_hash import _fib_hash_1, _fib_hash_2


@always_inline
def _ck_dtype_byte_width(dt: DType) -> Int:
    """Byte width of a fixed-width key DType, used by `init_multi_key_mode`
    to derive the per-column offsets and the total key stride."""
    if dt == DType.bool or dt == DType.int8 or dt == DType.uint8:
        return 1
    elif dt == DType.int16 or dt == DType.uint16 or dt == DType.float16:
        return 2
    elif dt == DType.int32 or dt == DType.uint32 or dt == DType.float32:
        return 4
    else:
        # int64 / uint64 / float64.
        return 8


def _ck_hash_key_bytes(
    key_ptr: UnsafePointer[UInt8, _],
    dtypes: Array[DType, 8],
    offsets: Array[Int, 8],
    widths: Array[Int, 8],
    num_cols: Int,
) -> UInt64:
    """Composite hash over `num_cols` packed key-byte columns.

    Two shapes hash exactly as the typed hash-aggregation tables do, so a
    hash computed by a caller with `_fib_hash_1` / `_fib_hash_2` finds the
    same group as one recomputed here from the stored bytes (the combine and
    rehash paths recompute it):
      * one 8-byte column: `_fib_hash_1(key)`;
      * two 8-byte columns at offsets 0 and 8: `_fib_hash_2(k0, k1)`.
    Any drift between the two would insert a second group for a key that is
    already present.

    Every other shape is hashed per column (each column zero-extended into
    an Int64 and passed through `_fib_hash_1`) and folded left to right with
    `h ^= col_h; h ^= h >> 33; h *= 0xff51afd7ed558ccd` (Murmur3's mix1).
    The fold is order-sensitive, so (a, b) and (b, a) hash differently. A
    zero result is mapped to 1.

    SAFETY: `key_ptr` must be valid for `offsets[i] + widths[i]` bytes for
    every column `i < num_cols`.
    """
    if num_cols == 1 and widths[0] == 8:
        # SAFETY: key_ptr is valid for 8 bytes per the stride invariant.
        return _fib_hash_1(key_ptr.bitcast[Int64]()[])
    if (
        num_cols == 2
        and widths[0] == 8
        and widths[1] == 8
        and offsets[0] == 0
        and offsets[1] == 8
    ):
        # SAFETY: key_ptr is valid for 16 bytes per the stride invariant.
        var k0 = key_ptr.bitcast[Int64]()[]
        var k1 = (key_ptr + 8).bitcast[Int64]()[]
        return _fib_hash_2(k0, k1)
    var h: UInt64 = 0
    for i in range(num_cols):
        var w = widths[i]
        var off = offsets[i]
        var col_h: UInt64
        if w == 8:
            # SAFETY: key_ptr + off is in bounds per the stride invariant.
            col_h = _fib_hash_1((key_ptr + off).bitcast[Int64]()[])
        elif w == 4:
            col_h = _fib_hash_1(
                Int64((key_ptr + off).bitcast[Int32]()[])
            )
        elif w == 2:
            col_h = _fib_hash_1(
                Int64((key_ptr + off).bitcast[Int16]()[])
            )
        else:  # w == 1
            # A one-byte column is ZERO-extended. The insert and the probe
            # both hash through this function, so any consistent extension
            # is correct; zero-extension is the one this hash has always
            # computed, and changing it would move every stored group.
            col_h = _fib_hash_1(Int64((key_ptr + off)[]))
        h ^= col_h
        h ^= h >> 33
        h = h * UInt64(0xff51afd7ed558ccd)
    if h == 0:
        h = 1
    return h


@always_inline
def _ck_memcmp_keys(
    a: UnsafePointer[UInt8, _], b: UnsafePointer[UInt8, _], n: Int
) -> Bool:
    """True iff the `n` bytes at `a` equal the `n` bytes at `b` (a scalar
    byte loop; the 8- and 16-byte strides compare as Int64 lanes in
    `SlabStorage._lookup_multi_key` and never reach here)."""
    var _i = 0
    var _eq = True
    while _i < n:
        if a[_i] != b[_i]:
            _eq = False
            break
        _i += 1
    keyeq_record(KEYEQ_SLAB_CK_MEMCMP, n, _i, _eq)
    return _eq
