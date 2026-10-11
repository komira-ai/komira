# =============================================================================
# Column-chunk statistics for Parquet column pages
# =============================================================================
#
# Computes min/max/null_count (and an HLL distinct_count) for typed
# PrimitiveArray and StringArray columns. The integer paths take min/max in
# one SIMD pass (element-wise compare + select, then reduce_min/reduce_max)
# when the column has no nulls, and in a scalar pass over the valid slots
# when it has some.
#
# What every statistic here holds to (parquet.thrift, Statistics):
#
#  * min/max describe the column's VALUES, so null slots never enter them.
#    An Arrow null slot may hold ANY bytes; a range picked up from one does
#    not occur in the column, and a pruner acting on it drops rows the
#    predicate cannot rule out. The validity bitmap is indexed absolutely
#    (`col.offset + i`), so a sliced array reads the validity of its own rows.
#  * An all-null or empty column publishes null_count and NO min/max.
#  * FLOAT64 goes through `writer_float_stats` (no NaN in min/max, -0.0 as a
#    zero min, +0.0 as a zero max, nan_count), the same rules every float
#    page encoder applies.
#  * The HLL registers backing distinct_count travel in `hll_registers`; the
#    footer writer stores them in the chunk's key-value metadata
#    (`komira_parquet_api.hll_footer`), never in Statistics field 9.
# =============================================================================

from std.sys import simd_width_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.hyperloglog import HyperLogLog, HLL_NUM_REGISTERS
from komira_parquet_api.metadata import Statistics

from .writer_float_stats import float_minmax_from_array, make_float_statistics


# =============================================================================
# Internal helpers: encode scalar values as little-endian byte lists
# =============================================================================


@always_inline
def _encode_le_i32(value: Int32) -> List[UInt8]:
    """Encode an Int32 value as 4 little-endian bytes via byte-wise shifts."""
    var u = UInt32(Int(value))
    var out = List[UInt8](capacity=4)
    out.append(UInt8(Int(u & UInt32(0xFF))))
    out.append(UInt8(Int((u >> UInt32(8)) & UInt32(0xFF))))
    out.append(UInt8(Int((u >> UInt32(16)) & UInt32(0xFF))))
    out.append(UInt8(Int((u >> UInt32(24)) & UInt32(0xFF))))
    return out^


@always_inline
def _encode_le_i64(value: Int64) -> List[UInt8]:
    """Encode an Int64 value as 8 little-endian bytes via byte-wise shifts."""
    var u = UInt64(Int(value))
    var out = List[UInt8](capacity=8)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(i * 8)) & UInt64(0xFF))))
    return out^


def _hll_register_bytes(hll: HyperLogLog) -> List[UInt8]:
    """The sketch's 4096 registers, in register order, for `hll_registers`."""
    var out = List[UInt8](capacity=HLL_NUM_REGISTERS)
    for i in range(HLL_NUM_REGISTERS):
        out.append(hll.register(i))
    return out^


# =============================================================================
# SIMD element-wise min/max helpers
# =============================================================================
#
# Element-wise min/max as comparison + select: a.lt(b).select(a, b) is the
# element-wise min, a.gt(b).select(a, b) the element-wise max.
# =============================================================================


@always_inline
def _simd_min[dtype: DType, width: Int](
    a: SIMD[dtype, width], b: SIMD[dtype, width]
) -> SIMD[dtype, width]:
    """Element-wise minimum of two SIMD vectors."""
    return a.lt(b).select(a, b)


@always_inline
def _simd_max[dtype: DType, width: Int](
    a: SIMD[dtype, width], b: SIMD[dtype, width]
) -> SIMD[dtype, width]:
    """Element-wise maximum of two SIMD vectors."""
    return a.gt(b).select(a, b)


# =============================================================================
# Integer statistics (INT32 / INT64)
# =============================================================================


def _int_statistics[
    dtype: DType
](col: PrimitiveArray[dtype]) -> Statistics:
    """Min/max over the non-null values, null_count, and an HLL distinct_count.

    `dtype` is int32 or int64. With no nulls, one SIMD min/max pass over the
    whole buffer; with nulls, one scalar pass over the valid slots only.

    SAFETY: the SIMD pass reads the array's own buffer through the
    origin-tied, offset-aware `_typed_ptr_ro()`, bounded by `col.length`; the
    pointer never leaves this function.
    """
    var n = col.length
    if n == 0:
        return Statistics(null_count=0, distinct_count=0)

    var has_nulls = False
    if col.validity and col.null_count > 0:
        has_nulls = True
    var hll = HyperLogLog()
    var seen = False
    var current_min = Scalar[dtype](0)
    var current_max = Scalar[dtype](0)

    if not has_nulls:
        var data_ptr = col._typed_ptr_ro()
        current_min = data_ptr[0]
        current_max = data_ptr[0]
        comptime simd_width = simd_width_of[dtype]()
        var simd_end = (n // simd_width) * simd_width
        var vec_min = SIMD[dtype, simd_width](current_min)
        var vec_max = SIMD[dtype, simd_width](current_max)
        var i = 0
        while i < simd_end:
            var chunk = data_ptr.load[width=simd_width](i)
            vec_min = _simd_min(vec_min, chunk)
            vec_max = _simd_max(vec_max, chunk)
            i += simd_width
        current_min = vec_min.reduce_min()
        current_max = vec_max.reduce_max()
        while i < n:
            var val = data_ptr[i]
            if val < current_min:
                current_min = val
            if val > current_max:
                current_max = val
            i += 1
        # Values are sign-extended to i64 for hashing, so an INT32 and an
        # INT64 column holding the same numbers hash alike.
        for j in range(n):
            hll.add_int64(Int64(data_ptr[j]))
        seen = True
    else:
        ref bm = col.validity.value()
        for j in range(n):
            if not bm.test(col.offset + j):
                continue
            var val = col.load[1](j)[0]
            if not seen:
                current_min = val
                current_max = val
                seen = True
            else:
                if val < current_min:
                    current_min = val
                if val > current_max:
                    current_max = val
            hll.add_int64(Int64(val))

    if not seen:
        # Every value is null: no range to publish.
        return Statistics(null_count=col.null_count, distinct_count=0)

    var min_bytes: List[UInt8]
    var max_bytes: List[UInt8]
    comptime if dtype == DType.int32:
        min_bytes = _encode_le_i32(Int32(current_min))
        max_bytes = _encode_le_i32(Int32(current_max))
    else:
        min_bytes = _encode_le_i64(Int64(current_min))
        max_bytes = _encode_le_i64(Int64(current_max))

    return Statistics(
        null_count=col.null_count if has_nulls else 0,
        distinct_count=hll.estimate(),
        min_value=min_bytes^,
        max_value=max_bytes^,
        hll_registers=Optional[List[UInt8]](_hll_register_bytes(hll)),
    )


def compute_statistics_int32(col: PrimitiveArray[DType.int32]) -> Statistics:
    """Statistics of an INT32 column: min/max over its non-null values,
    null_count, and an HLL distinct_count with its registers.

    Args:
        col: The Int32 PrimitiveArray to compute statistics for.

    Returns:
        A Statistics with min_value/max_value (4 little-endian bytes) when at
        least one value is non-null, null_count, and distinct_count (an HLL
        estimate, ~1.6% standard error; 0 for an empty or all-null column).
    """
    return _int_statistics[DType.int32](col)


def compute_statistics_int64(col: PrimitiveArray[DType.int64]) -> Statistics:
    """Statistics of an INT64 column: as `compute_statistics_int32`, with
    8-byte min/max.

    Args:
        col: The Int64 PrimitiveArray to compute statistics for.

    Returns:
        A Statistics with min_value/max_value, null_count and distinct_count.
    """
    return _int_statistics[DType.int64](col)


# =============================================================================
# DOUBLE statistics
# =============================================================================


def compute_statistics_float64(col: PrimitiveArray[DType.float64]) -> Statistics:
    """Statistics of a DOUBLE column: the spec's floating-point min/max and
    nan_count, null_count, and an HLL distinct_count with its registers.

    min/max/nan_count come from `writer_float_stats` over the non-null
    values: NaN never enters min/max, an all-NaN or all-null column has no
    min/max, a zero min is written as -0.0 and a zero max as +0.0. The HLL
    hashes each non-null value's bit pattern (every distinct NaN pattern
    counts as distinct).

    Args:
        col: The Float64 PrimitiveArray to compute statistics for.

    Returns:
        A Statistics with null_count, nan_count and distinct_count, and
        min_value/max_value (8 little-endian bytes) when a non-NaN non-null
        value exists.
    """
    var n = col.length
    if n == 0:
        return Statistics(null_count=0, distinct_count=0, nan_count=0)
    var has_nulls = False
    if col.validity and col.null_count > 0:
        has_nulls = True
    var null_count = col.null_count if has_nulls else 0
    var stats = make_float_statistics[DType.float64](
        float_minmax_from_array[DType.float64](col, True), null_count
    )
    var hll = HyperLogLog()
    if has_nulls:
        ref bm = col.validity.value()
        for j in range(n):
            if bm.test(col.offset + j):
                hll.add_float64(col.load[1](j)[0])
    else:
        for j in range(n):
            hll.add_float64(col.load[1](j)[0])
    stats.distinct_count = Optional[Int](hll.estimate())
    stats.hll_registers = Optional[List[UInt8]](_hll_register_bytes(hll))
    return stats^


# =============================================================================
# String statistics with truncation
# =============================================================================
#
# For BYTE_ARRAY (string) columns, Parquet statistics store min/max values
# as raw bytes. For very long strings, storing the full min/max would waste
# space in the footer. Truncation is the standard approach:
#
#   - min_value: truncate to first N bytes (always safe — the truncated
#     min is <= the full min for any string with this prefix).
#
#   - max_value: truncate to first N bytes, then increment the last byte.
#     This produces the shortest upper bound. If the last byte is 0xFF,
#     walk back to find a byte that can be incremented. If all bytes are
#     0xFF, store the full (untruncated) max.
#
# Default truncation length: 64 bytes (matches parquet-rs and Arrow).
# =============================================================================

# Default truncation length for string statistics.
comptime STRING_STATS_TRUNCATION_LEN: Int = 64


def _truncate_min(data: List[UInt8], max_len: Int) -> List[UInt8]:
    """Truncate a min value to at most max_len bytes.

    Simply takes the first max_len bytes. This is a valid lower bound
    because any string with this prefix is >= the prefix itself.

    Args:
        data: The raw min bytes.
        max_len: Maximum output length.

    Returns:
        Truncated min bytes. If data is shorter than max_len, returns a copy.
    """
    if len(data) <= max_len:
        return data.copy()
    var result = List[UInt8](capacity=max_len)
    for i in range(max_len):
        result.append(data[i])
    return result^


def _truncate_max(data: List[UInt8], max_len: Int) -> Tuple[List[UInt8], Bool]:
    """Truncate a max value to at most max_len bytes and increment.

    Takes the first max_len bytes, then increments the last non-0xFF byte.
    This produces the shortest valid upper bound:
      truncated_max >= any string with the same prefix.

    If all truncated bytes are 0xFF, the max cannot be incremented and
    is returned as-is (is_exact=True, no truncation benefit).

    Args:
        data: The raw max bytes.
        max_len: Maximum output length.

    Returns:
        A tuple of (truncated max bytes, is_exact: Bool).
        is_exact=True means the value was NOT truncated (exact max).
        is_exact=False means the value was truncated+incremented.
    """
    if len(data) <= max_len:
        return (data.copy(), True)

    # Take first max_len bytes.
    var result = List[UInt8](capacity=max_len)
    for i in range(max_len):
        result.append(data[i])

    # Increment the last non-0xFF byte.
    var i = len(result) - 1
    while i >= 0:
        if result[i] < UInt8(0xFF):
            result[i] = result[i] + UInt8(1)
            # Truncate everything after the incremented byte.
            var new_len = i + 1
            while len(result) > new_len:
                _ = result.pop()
            return (result^, False)
        i -= 1

    # All bytes are 0xFF — cannot increment. Return full untruncated max.
    return (data.copy(), True)


def compute_statistics_string(
    col: StringArray,
    truncation_len: Int = STRING_STATS_TRUNCATION_LEN,
) -> Statistics:
    """Compute min/max/null_count/distinct_count statistics for a string column.

    Compares strings lexicographically as unsigned bytes (the BYTE_ARRAY
    type-defined order). Truncates min/max values to truncation_len bytes to
    keep the footer compact.

    Also feeds each non-null string into a HyperLogLog sketch
    (precision 12) and populates `distinct_count`. The hash is taken
    over the FULL UTF-8 byte sequence (not the truncated min/max), so
    distinct strings differing only in their suffix beyond the
    truncation length still count as distinct.

    Args:
        col: The StringArray to compute statistics for.
        truncation_len: Maximum byte length for truncated min/max.

    Returns:
        A Statistics struct with truncated min/max as raw bytes,
        null_count, and an HLL distinct_count estimate.
    """
    var n = col.length
    if n == 0:
        return Statistics(null_count=0, distinct_count=0)

    var has_nulls = col.null_count > 0

    # Find first non-null value to initialize min/max.
    var first_idx = -1
    for i in range(n):
        if has_nulls and col.is_null(i):
            continue
        first_idx = i
        break

    if first_idx < 0:
        # All values are null — no min/max, distinct_count = 0.
        return Statistics(null_count=col.null_count, distinct_count=0)

    var min_idx = first_idx
    var max_idx = first_idx

    # HLL — feed every non-null row's full byte range.
    var hll = HyperLogLog()
    hll.add_hash(_hash_span(col.get_span(first_idx)))

    for i in range(first_idx + 1, n):
        if has_nulls and col.is_null(i):
            continue
        var s = col.get_span(i)
        # HLL ingest BEFORE the truncated min/max comparison so we hash
        # the full string regardless of truncation.
        hll.add_hash(_hash_span(s))
        if _span_less(s, col.get_span(min_idx)):
            min_idx = i
        if _span_less(col.get_span(max_idx), s):
            max_idx = i

    var min_bytes = _span_to_list(col.get_span(min_idx))
    var max_bytes = _span_to_list(col.get_span(max_idx))

    # Truncate for footer efficiency.
    var truncated_min = _truncate_min(min_bytes, truncation_len)
    var max_result = _truncate_max(max_bytes, truncation_len)
    var truncated_max = max_result[0].copy()
    var max_exact = max_result[1]

    var min_exact = len(min_bytes) <= truncation_len

    return Statistics(
        null_count=col.null_count,
        distinct_count=hll.estimate(),
        min_value=truncated_min^,
        max_value=truncated_max^,
        is_min_value_exact=min_exact,
        is_max_value_exact=max_exact,
        hll_registers=Optional[List[UInt8]](_hll_register_bytes(hll)),
    )


@always_inline
def _hash_span(bytes: Span[UInt8, _]) -> UInt64:
    """Hash a string's bytes for HLL ingestion: FNV-1a, then the splitmix64
    finalizer (the same pipeline as komira_collections' `hll_hash_bytes`)."""
    var h = UInt64(0xCBF29CE484222325)
    var prime = UInt64(0x00000100000001B3)
    for i in range(len(bytes)):
        h = h ^ UInt64(bytes[i])
        h = h * prime
    var x = h + UInt64(0x9E3779B97F4A7C15)
    x = (x ^ (x >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B5)
    x = (x ^ (x >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    x = x ^ (x >> UInt64(31))
    return x


@always_inline
def _span_less(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Whether `a` sorts before `b` as unsigned bytes (a proper prefix sorts
    first). It runs once per non-null row against the running min and max."""
    var a_len = len(a)
    var b_len = len(b)
    var min_len = a_len if a_len < b_len else b_len
    for i in range(min_len):
        if a[i] != b[i]:
            return a[i] < b[i]
    return a_len < b_len


def _span_to_list(bytes: Span[UInt8, _]) -> List[UInt8]:
    """An owned copy of `bytes`."""
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^
