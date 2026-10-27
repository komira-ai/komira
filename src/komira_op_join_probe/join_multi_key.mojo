# =============================================================================
# join_multi_key -- the shared pieces of the composite-key hash join: key
# constants, the composite hash, the string-key hash and byte equality, the
# per-call equality-arm resolution, and `MultiKeyColumns`, the extracted-key
# bundle the builder and every probe consume.
# =============================================================================
#
# KEY SLOTS. Every key column, whatever its type, is rendered into one Int64
# "key slot" per row (`MultiKeyColumns.int_keys`): an INT64 key is its value,
# an INT32 key its sign-extended value, a FLOAT64 key its canonical bits under
# the float model (below), and a STRING or DICTIONARY key the 64-bit hash of
# its bytes, with the bytes kept on a side channel (`string_keys`) for the
# chain walk's byte-for-byte equality. The composite hash and the bloom filter
# read only the slots. A NULL key is the one slot value `_NAN_SENTINEL_BITS`:
# every build and probe loop skips a row holding it in any key, so a NULL key
# matches nothing (INNER and SEMI drop the row, ANTI and LEFT keep it
# unmatched). One known hazard follows from encoding NULL as a value: a
# non-NULL INT64 key equal to 9,221,120,237,041,090,561 (the sentinel read as
# Int64) is skipped as if it were NULL.
#
# FLOAT KEYS FOLLOW THE FLOAT MODEL (`docs/design/query_semantics.md` 3.9), as
# DuckDB does: every NaN equals every NaN and `-0.0` equals `+0.0`. A FLOAT64
# key slot holds `komira_udf.float_quotient_order.canonical_bits_f64` of the
# value, so equality of slots is equality under the model, and the canonical
# NaN (0x7FF8000000000000) is not the NULL sentinel (0x7FF8000000000001).
# =============================================================================

from std.memory import UnsafePointer
from std.sys import size_of

from komira_arrow.bitmap import Bitmap
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_counters.keyeq_census import keyeq_record, KEYEQ_JOINMK_MEMCMP
from komira_simd.byte_class.byte_equal import bytes_equal
from komira_udf.float_quotient_order import canonical_bits_f64


comptime _CHAIN_END: Int = -1
"""End of a chain and an empty bucket."""

comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15
"""2^64 / phi, the Fibonacci-hash multiplier."""

comptime MAX_JOIN_KEYS: Int = 8
"""The most key columns one composite join takes."""

comptime _NAN_SENTINEL_BITS: Int64 = 0x7FF8000000000001
"""The key-slot value of a NULL key (a quiet-NaN bit pattern no canonical
float produces). Every build and probe loop skips a row holding it."""


comptime _FNV1A_64_OFFSET_BASIS: UInt64 = 14695981039346656037
comptime _FNV1A_64_PRIME: UInt64 = 1099511628211


@always_inline
def _fnv1a_hash_bytes[
    o: Origin[mut=False]
](data_ptr: UnsafePointer[Scalar[DType.uint8], o], length: Int) -> UInt64:
    """FNV-1a-family 64-bit hash over `length` bytes, a word at a time.

    Two lanes each take 8 bytes per multiply, the tail byte-at-a-time, and a
    final avalanche folds the length in and mixes the high bits down so the
    bucket bits (`h & mask`) depend on every byte. The hash never decides
    equality: every candidate is then compared byte for byte. Reads only whole
    words strictly inside `[0, length)`.
    """
    var h0 = _FNV1A_64_OFFSET_BASIS
    var h1 = _FNV1A_64_OFFSET_BASIS ^ UInt64(0x9E3779B97F4A7C15)
    var i = 0
    while i + 16 <= length:
        var w0 = (data_ptr + i).bitcast[Scalar[DType.uint64]]().load[
            alignment=1
        ]()
        var w1 = (data_ptr + i + 8).bitcast[Scalar[DType.uint64]]().load[
            alignment=1
        ]()
        h0 = (h0 ^ UInt64(w0)) * _FNV1A_64_PRIME
        h1 = (h1 ^ UInt64(w1)) * _FNV1A_64_PRIME
        i += 16
    if i + 8 <= length:
        var w = (data_ptr + i).bitcast[Scalar[DType.uint64]]().load[
            alignment=1
        ]()
        h0 = (h0 ^ UInt64(w)) * _FNV1A_64_PRIME
        i += 8
    while i < length:
        h0 = (h0 ^ UInt64((data_ptr + i)[])) * _FNV1A_64_PRIME
        i += 1
    var h = h0 ^ ((h1 << 27) | (h1 >> 37)) ^ UInt64(length)
    h = h ^ (h >> 33)
    h = h * _FNV1A_64_PRIME
    h = h ^ (h >> 29)
    return h


@always_inline
def _string_bytes_equal[
    oa_off: Origin[mut=False], oa_data: Origin[mut=False],
    ob_off: Origin[mut=False], ob_data: Origin[mut=False],
](
    a_offsets: UnsafePointer[Scalar[DType.int32], oa_off],
    a_data: UnsafePointer[Scalar[DType.uint8], oa_data],
    a_idx: Int,
    b_offsets: UnsafePointer[Scalar[DType.int32], ob_off],
    b_data: UnsafePointer[Scalar[DType.uint8], ob_data],
    b_idx: Int,
) -> Bool:
    """Compare two Arrow string slots for exact byte equality.

    The equality of every string-keyed composite probe: lengths first, then
    `komira_simd`'s `bytes_equal`. The pointers are the caller's borrows of
    each side's offsets and data buffers and must outlive the call.
    """
    var a_start = Int((a_offsets + a_idx)[])
    var a_end = Int((a_offsets + a_idx + 1)[])
    var b_start = Int((b_offsets + b_idx)[])
    var b_end = Int((b_offsets + b_idx + 1)[])
    if a_end - a_start != b_end - b_start:
        keyeq_record(KEYEQ_JOINMK_MEMCMP, a_end - a_start, 0, False)
        return False
    var _n = a_end - a_start
    var _eq = bytes_equal(
        Span[UInt8, oa_data](unsafe_ptr=a_data + a_start, length=_n),
        Span[UInt8, ob_data](unsafe_ptr=b_data + b_start, length=_n),
    )
    keyeq_record(KEYEQ_JOINMK_MEMCMP, _n, _n, _eq)
    return _eq


comptime MK_ARM_INT: Int = 0
"""Every key compares as `Int64 ==` on the build/probe key columns."""

comptime MK_ARM_DICT: Int = 1
"""Every key compares as `Int32 ==` on same-dictionary indices."""

comptime MK_ARM_STRING: Int = 2
"""Every key compares byte-wise through `_string_bytes_equal`."""

comptime MK_ARM_MIXED: Int = 3
"""Run the general per-key body (a mixed key vector, or a single key)."""


@always_inline
def mk_uniform_arm(
    imm is_same_dict: List[Bool], imm is_string: List[Bool], n_keys: Int
) -> Int:
    """Collapse a probe call's per-key arm vector to one uniform arm code.

    The arm of each key is fixed for a whole probe call, so a call site can
    branch once per candidate and run a body whose key loop is uniform. The
    precedence matches the call sites' general body: same-dictionary before
    string before integer (a DICT key is both). A single key returns
    `MK_ARM_MIXED`: with one key there is nothing to hoist.

    Args:
        is_same_dict: per-key same-dictionary flags, as built by the caller.
        is_string: per-key string-side-channel flags, as built by the caller.
        n_keys: number of keys; both lists are indexed `[0, n_keys)`.

    Returns:
        One of the four `MK_ARM_*` codes.
    """
    if n_keys < 2:
        return MK_ARM_MIXED
    var saw_dict = False
    var saw_string = False
    var saw_int = False
    for k in range(n_keys):
        if is_same_dict[k]:
            saw_dict = True
        elif is_string[k]:
            saw_string = True
        else:
            saw_int = True
    if saw_dict and not saw_string and not saw_int:
        return MK_ARM_DICT
    if saw_string and not saw_dict and not saw_int:
        return MK_ARM_STRING
    if saw_dict or saw_string:
        return MK_ARM_MIXED
    return MK_ARM_INT


@always_inline
def _canonicalize_float64_for_hash(v: Float64) -> Int64:
    """Map a Float64 key to its key slot under the float model: every NaN to
    the one canonical NaN's bits, `-0.0` to `+0.0`'s, any other value to its
    own bits. Never `_NAN_SENTINEL_BITS`, so a NaN key is a key, not a NULL.

    Args:
        v: a Float64 key value extracted from a probe/build column.

    Returns:
        An Int64 carrying the canonical bit pattern for `v`.
    """
    return Int64(canonical_bits_f64(v))


struct MultiKeyColumns(Movable):
    """N extracted join-key columns: the key slots plus the per-key STRING and
    DICTIONARY side channels.

    `int_keys[k]` holds key k's slots (see the module header). `string_keys[k]`
    is the key's bytes as a `StringArray` for a STRING key and for a DICTIONARY
    key (decoded, for the cross-dictionary compare), else None.
    `dict_keys[k]` is the `StringDictionaryArray` of a DICTIONARY key, else
    None, and `dict_fingerprints[k]` the hash of its dictionary's bytes (0
    otherwise): when the build and probe fingerprints of a key agree, the chain
    walk compares dictionary indices instead of bytes. Each field is an
    `Optional` so a consumer can `take()` them one at a time.
    """

    var int_keys: Optional[Slab[PrimitiveArray[DType.int64]]]
    var string_keys: Optional[Slab[Optional[StringArray[HeapRegion]]]]
    var dict_keys: Optional[Slab[Optional[StringDictionaryArray]]]
    var dict_fingerprints: Optional[List[UInt64]]
    var num_keys: Int

    def __init__(
        out self,
        var int_keys: Slab[PrimitiveArray[DType.int64]],
        var string_keys: Slab[Optional[StringArray[HeapRegion]]],
        var dict_keys: Slab[Optional[StringDictionaryArray]],
        var dict_fingerprints: List[UInt64],
        num_keys: Int,
    ):
        var ik_opt: Optional[Slab[PrimitiveArray[DType.int64]]] = int_keys^
        var sk_opt: Optional[Slab[Optional[StringArray[HeapRegion]]]] = string_keys^
        var dk_opt: Optional[Slab[Optional[StringDictionaryArray]]] = dict_keys^
        var df_opt: Optional[List[UInt64]] = dict_fingerprints^
        self.int_keys = ik_opt^
        self.string_keys = sk_opt^
        self.dict_keys = dk_opt^
        self.dict_fingerprints = df_opt^
        self.num_keys = num_keys


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin: the placeholder a per-key
    pointer list holds for a key whose arm never reads it.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer and `None` is the all-zero bit pattern. The result is never
    # dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


comptime _COMPOSITE_HASH_SEED: UInt64 = _FIB_HASH_CONST


@always_inline
def _composite_hash_step(h: UInt64, v: Int64) -> UInt64:
    """One key's contribution to the composite hash: Fibonacci-multiply the key,
    xor-fold its high half down, XOR into the accumulator, rotate left 5.

    The serial build, the parallel build (which folds key-outer) and every probe
    call this one step, so their hashes cannot drift apart.
    """
    var k = UInt64(v)
    var ki = k * _FIB_HASH_CONST
    ki = ki ^ (ki >> 32)
    var acc = h ^ ki
    return (acc << 5) | (acc >> 59)


@always_inline
def _composite_hash_int64[
    o: Origin
](values: UnsafePointer[Int64, o], n: Int) -> UInt64:
    """Compute a composite hash over N Int64 values (FxHash-style chain).

    Args:
        values: pointer to N consecutive Int64 values to hash together.
        n: number of values to hash (1..MAX_JOIN_KEYS).

    Returns:
        UInt64 composite hash.
    """
    var h = _COMPOSITE_HASH_SEED
    for i in range(n):
        h = _composite_hash_step(h, values[i])
    return h


def _decode_dict_to_string_array(
    ref da: StringDictionaryArray,
) raises -> StringArray[HeapRegion]:
    """Decode every row of a StringDictionaryArray into a fresh StringArray
    (the cross-dictionary compare's side channel). A NULL index is a NULL row;
    an out-of-range index decodes as the empty string."""
    var n = da.length
    comptime int32_size = size_of[Int32]()

    var dict_off_view = da.dictionary.offsets.view_ro()
    var dict_off_ptr = dict_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var idx_view = da.indices.view_ro()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var has_idx_validity = da.indices.validity.__bool__()
    var total_bytes = 0
    var null_count = 0
    for r in range(n):
        if has_idx_validity and not da.indices.validity.value().test(r):
            null_count += 1
            continue
        var d = Int((idx_ptr + r)[])
        if d < 0 or d >= da.dictionary.length:
            continue
        var s_start = Int((dict_off_ptr + d)[])
        var s_end = Int((dict_off_ptr + d + 1)[])
        total_bytes += (s_end - s_start)

    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

    var dict_data_view = da.dictionary.data.view_ro()
    var dict_data_ptr = dict_data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var validity_opt = Optional[Bitmap[HeapRegion]](None)
    var bm = Bitmap.create(n) if has_idx_validity else Bitmap.create(0)
    var offset = 0
    for r in range(n):
        if has_idx_validity and not da.indices.validity.value().test(r):
            bm.clear(r)
            offsets_buf.set_typed[Int32](r + 1, Int32(offset))
            continue
        if has_idx_validity:
            bm.set(r)
        var d = Int((idx_ptr + r)[])
        if d >= 0 and d < da.dictionary.length:
            var s_start = Int((dict_off_ptr + d)[])
            var s_end = Int((dict_off_ptr + d + 1)[])
            var s_len = s_end - s_start
            if s_len > 0:
                # SAFETY: dict_data_ptr is alive because `da.dictionary.data`
                # is borrowed via `ref da` for this function frame; data_buf
                # is mutably borrowed only here.
                var src_view = ByteView(
                    dict_data_ptr + s_start, s_len
                )
                data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                    0, src_view
                )
                offset += s_len
        offsets_buf.set_typed[Int32](r + 1, Int32(offset))

    offsets_buf.set_length(Int64((n + 1) * int32_size))

    data_buf.set_length(Int64(total_bytes))


    if has_idx_validity:
        validity_opt = bm^

    _ = da.dictionary.offsets  # keepalive for dict_off_ptr
    _ = da.dictionary.data  # keepalive for dict_data_ptr
    _ = da.indices  # keepalive for idx_ptr

    return StringArray(
        offsets=offsets_buf^,
        data=data_buf^,
        validity=validity_opt^,
        length=n,
        data_length=total_bytes,
        null_count=null_count,
    )
