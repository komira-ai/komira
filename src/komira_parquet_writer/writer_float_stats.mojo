# =============================================================================
# FLOAT / DOUBLE column-chunk statistics
# =============================================================================
#
# WHY THIS MODULE EXISTS
# ----------------------
# Row-group pruning on a predicate over a float or double column needs that
# column's min/max, and on analytic workloads most MEASURE columns are floats.
# MEASURED 2026-09-02 on a corpus of Parquet files by walking every footer's
# compact thrift: every FLOAT/DOUBLE column chunk this writer's predecessor
# wrote (4,858 chunks, PLAIN, BYTE_STREAM_SPLIT and dictionary) had no
# min/max, and every one DuckDB wrote (1,583 chunks) had it.
#
# ⛔ THIS IS NOT A COPY OF THE INTEGER PATH. FLOATING POINT HAS SPEC-DEFINED
# HANDLING AND GETTING IT WRONG IS WORSE THAN OMITTING IT
# ---------------------------------------------------------------------------
# A wrong float min/max makes the pruner drop rows that satisfy the predicate,
# silently. `parquet.thrift`'s ColumnOrder comment states the rules a writer
# MUST follow when a FLOAT/DOUBLE column declares TYPE_ORDER (which ours do —
# `serialize_file_metadata` emits `FileMetaData.column_orders` with
# TypeDefinedOrder for every leaf). Verbatim:
#
#   - The nan_count field must be set for floating point types, even if it is
#     zero.
#   - If the nan_count field is set, min and max statistics fields, when
#     present, must not contain NaN values and must be computed from non-NaN
#     values only. [...]
#   - If all non-null values are NaN, min and max statistics must not be
#     written.
#   - If the computed max value is zero (whether negative or positive),
#     `+0.0` should be written into the max statistics field.
#   - If the computed min value is zero (whether negative or positive),
#     `-0.0` should be written into the min statistics field.
#
# WHAT THIS MODULE DOES, RULE BY RULE
# -----------------------------------
# * NaN NEVER ENTERS min/max. The accumulator is seeded from the first non-NaN
#   value and every subsequent comparison is written so a NaN lane KEEPS the
#   accumulator (`chunk.lt(acc).select(chunk, acc)`, never the reverse) —
#   IEEE-754 makes every comparison against NaN false, so the naive
#   `acc.lt(chunk).select(acc, chunk)` spelling would PROPAGATE a NaN into the
#   accumulator the moment one appeared. A NaN written as min prunes
#   everything.
#
# * NaNs ARE COUNTED, AND `nan_count` IS WRITTEN (Statistics field 9) whenever
#   the count is exact: the array scans count every NaN among the values the
#   page encodes, so a reader may conclude "no NaN here" from a 0. Statistics
#   field 9 is free for it: `komira_parquet_api.hll_footer` moved the
#   HyperLogLog registers into the chunk's key-value metadata. The dictionary
#   arm (`float_minmax_from_values`) sees each DISTINCT value once, so it
#   cannot count NaN rows; it leaves the count unknown and no `nan_count` is
#   written. The spec's fallback is safe: "If this field is not present,
#   readers MUST assume NaNs may be present".
#
# * ALL-NaN (with at least one non-null row) writes NO min/max. There is no
#   valid bound to report and a sentinel would be a fabricated range.
#
# * ALL-NULL and EMPTY write NO min/max, and all-null still reports
#   `null_count`. Arrow null slots may hold ANY bytes; a range derived from
#   them does not occur in the column.
#
# * -0.0 / +0.0 ARE NORMALISED AT EMIT TIME. They compare EQUAL under IEEE-754
#   (`Float64(-0.0) == Float64(0.0)` is True) but are DISTINCT bit patterns
#   (f64 0x8000000000000000 vs 0x0), and min/max are compared by a reader as
#   BITS after PLAIN-decoding. So a scan keeps whichever sign it saw first,
#   and `make_float_statistics` then rewrites a zero min to -0.0 and a zero
#   max to +0.0 — widening the published interval to cover both signs.
#   Without it a reader holding min=+0.0 could prune a row group that contains
#   -0.0 rows matching `x <= -0.0`.
#
# * A SINGLE-VALUE column reports min == max == that value (after the ±0.0
#   normalisation above, so a lone -0.0 column publishes min=-0.0, max=+0.0).
#
# ⚠ NO HYPERLOGLOG ON ANY FLOAT ARM, DELIBERATELY. MEASURED on files the
# predecessor writer produced: min/max + null_count costs 26 bytes per INT64
# chunk against 4,128 bytes per chunk for a chunk carrying the fixed 4 KiB of
# HLL registers, read on every file open, on the object-store critical path.
# Adding it to every float chunk buys an NDV estimate nothing prunes on.
#
# SAFETY: the only raw-pointer use is a read-only unit-stride scan inside
# `_dense_minmax` and `_masked_minmax`, bounded by the array length and
# confined to those functions. No UnsafePointer in any public signature.
# =============================================================================

from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_simd.width_policy import komira_simd_width

from komira_parquet_api.metadata import Statistics


# =============================================================================
# FloatMinMax — the accumulator
# =============================================================================


struct FloatMinMax[dtype: DType](Movable, Copyable):
    """A NaN-excluding min/max accumulator over FLOAT32 / FLOAT64 values.

    `seeded` is False until the first NON-NaN value is observed. That is the
    discriminator between "there is a bound to publish" and the three cases
    that must publish none: empty, all-null, and all-NaN. It is deliberately
    not inferable from `min_value == max_value` or from any sentinel — a
    sentinel in a float statistic is indistinguishable from a real value.

    `nan_count` is the number of NaN values observed; `nan_count_exact` is
    False when the accumulator was built from distinct values (the
    dictionary arm), where a NaN row count cannot be known.
    """

    var seeded: Bool
    var min_value: Scalar[Self.dtype]
    var max_value: Scalar[Self.dtype]
    var nan_count: Int
    var nan_count_exact: Bool

    def __init__(out self):
        self.seeded = False
        self.min_value = Scalar[Self.dtype](0)
        self.max_value = Scalar[Self.dtype](0)
        self.nan_count = 0
        self.nan_count_exact = True

    @always_inline
    def observe(mut self, v: Scalar[Self.dtype]):
        """Fold one value in; a NaN is counted and kept out of min/max.

        `v != v` is true iff `v` is NaN (the canonical IEEE-754 test; it is
        the only predicate that distinguishes NaN without inspecting bits).
        """
        if v != v:
            self.nan_count += 1
            return
        if not self.seeded:
            self.min_value = v
            self.max_value = v
            self.seeded = True
            return
        if v < self.min_value:
            self.min_value = v
        if v > self.max_value:
            self.max_value = v

    @always_inline
    def merge(mut self, other: Self):
        """Fold another accumulator in (multi-batch / multi-page paths)."""
        self.nan_count += other.nan_count
        self.nan_count_exact = self.nan_count_exact and other.nan_count_exact
        if not other.seeded:
            return
        if not self.seeded:
            self.min_value = other.min_value
            self.max_value = other.max_value
            self.seeded = True
            return
        if other.min_value < self.min_value:
            self.min_value = other.min_value
        if other.max_value > self.max_value:
            self.max_value = other.max_value


# =============================================================================
# Scanners
# =============================================================================


def _dense_minmax[
    dtype: DType
](array: PrimitiveArray[dtype]) -> FloatMinMax[dtype]:
    """SIMD NaN-excluding min/max over EVERY element of a dense array.

    The caller is asserting that every element in `[0, array.length)` is a
    value this page encodes — i.e. the array is REQUIRED, or the nulls have
    already been compacted out. `_masked_minmax` is the variant that consults
    a validity bitmap.

    SAFETY: read-only unit-stride scan of the array's own buffer through the
    origin-tied `_typed_ptr_ro()` (which is OFFSET-AWARE — it starts at
    `array.offset`), bounded by `array.length`. The pointer is confined to
    this function; the public surface takes and returns owned values only.
    """
    var out = FloatMinMax[dtype]()
    var n = array.length
    if n == 0:
        return out^

    var p = array._typed_ptr_ro()

    # Seed from the first NON-NaN element. On the overwhelmingly common
    # NaN-free column this exits at index 0.
    var seed = -1
    for s in range(n):
        var sv = p[s]
        if not (sv != sv):
            seed = s
            break
    if seed < 0:
        # All-NaN: no bound to publish. `seeded` stays False.
        out.nan_count = n
        return out^
    # Every element before the seed is a NaN.
    var nan_count = seed

    var current_min = p[seed]
    var current_max = current_min

    # CPU-aware width policy, NOT raw `simd_width_of`: on an AVX-512 target
    # the native width is 512-bit and issuing zmm ops downclocks Skylake-X /
    # Cascade Lake for the rest of the region. Same call the DBP min/max
    # prepass makes.
    comptime W = komira_simd_width[dtype]()
    var simd_end = (n // W) * W
    var i = 0
    if simd_end >= W:
        # ⚠ THE ACCUMULATOR IS SEEDED WITH A KNOWN-NON-NaN VALUE BROADCAST
        # ACROSS ALL LANES, NOT WITH `p.load(0)`. Loading lane 0 could seed a
        # NaN, and a NaN in the accumulator survives every subsequent compare
        # (all of them are false), so it would reach `reduce_min` and be
        # published as the column's minimum.
        var vec_min = SIMD[dtype, W](current_min)
        var vec_max = SIMD[dtype, W](current_max)
        var vec_nan = SIMD[DType.int64, W](0)
        comptime ONE = SIMD[DType.int64, W](1)
        comptime ZERO = SIMD[DType.int64, W](0)
        # The SIMD body starts at 0, not at `seed`: the elements before the
        # seed are NaN, so they move neither accumulator, and they are counted
        # here rather than by the `nan_count = seed` start.
        nan_count = 0
        while i < simd_end:
            var chunk = p.load[width=W](i)
            # A lane is NaN iff it is not equal to itself. `eq` is the
            # ORDERED compare (false for NaN); `ne` is ordered too, so
            # `chunk.ne(chunk)` is false on a NaN lane and counts nothing.
            vec_nan += chunk.eq(chunk).select(ZERO, ONE)
            # ⚠ ORDER IS LOAD-BEARING: the CHUNK is the left operand, so a NaN
            # lane makes the predicate false and the accumulator is KEPT.
            # `vec_min.lt(chunk).select(vec_min, chunk)` — the spelling the
            # integer path uses — would take the NaN lane instead.
            vec_min = chunk.lt(vec_min).select(chunk, vec_min)
            vec_max = chunk.gt(vec_max).select(chunk, vec_max)
            i += W
        # Neither vector can hold a NaN (they were seeded non-NaN and NaN
        # lanes never win a select), so reduce_min/max are NaN-free.
        current_min = vec_min.reduce_min()
        current_max = vec_max.reduce_max()
        nan_count = Int(vec_nan.reduce_add())
    else:
        # No SIMD body: the scalar tail starts after the seed, and the NaNs
        # before it are already in `nan_count`.
        i = seed + 1

    while i < n:
        var v = p[i]
        if v != v:
            nan_count += 1
        else:
            if v < current_min:
                current_min = v
            if v > current_max:
                current_max = v
        i += 1

    out.min_value = current_min
    out.max_value = current_max
    out.nan_count = nan_count
    out.seeded = True
    return out^


def _masked_minmax[
    dtype: DType
](array: PrimitiveArray[dtype]) -> FloatMinMax[dtype]:
    """Scalar NaN-excluding min/max over the NON-NULL elements only.

    ⚠ THE VALIDITY BITMAP IS INDEXED ABSOLUTELY (`array.offset + i`) WHILE THE
    DATA POINTER IS ALREADY OFFSET-RELATIVE (`_typed_ptr_ro()` starts at
    `array.offset`). Mixing the two conventions on a SLICED array reads the
    validity of a different row than the value — silently, and only for
    sliced inputs, which is why it survives most tests.

    SAFETY: read-only bounded scan through the origin-tied pointer; the
    pointer never leaves this function.
    """
    var n = array.length
    if n == 0:
        return FloatMinMax[dtype]()
    if not array.validity:
        return _dense_minmax[dtype](array)

    var out = FloatMinMax[dtype]()

    var p = array._typed_ptr_ro()
    ref bm = array.validity.value()
    for i in range(n):
        if bm.test(array.offset + i):
            out.observe(p[i])
    return out^


def float_minmax_from_array[
    dtype: DType
](array: PrimitiveArray[dtype], skip_nulls: Bool) -> FloatMinMax[dtype]:
    """Min/max over the values a page built from `array` will encode.

    `skip_nulls` MUST mirror what the encoder does with the null slots. For an
    OPTIONAL column the def-levels carry the mask and the page body holds only
    the non-nulls, so the statistic must describe the same set. For a REQUIRED
    column every slot IS encoded as a value, so every slot is in scope — the
    statistic stays consistent with the bytes on disk either way.
    """
    if skip_nulls and array.validity and array.null_count > 0:
        return _masked_minmax[dtype](array)
    return _dense_minmax[dtype](array)


def float_minmax_from_values[
    dtype: DType
](values: List[Scalar[dtype]]) -> FloatMinMax[dtype]:
    """Min/max over an already-dense value list (the dictionary arm).

    A dictionary's value list holds the DISTINCT non-null values of the chunk,
    so scanning it is both "non-null values only" for free and bounded by
    `NUMERIC_DICT_MAX_CARDINALITY` rather than by the row count. For the same
    reason it cannot count NaN rows: the result's `nan_count_exact` is False
    and `make_float_statistics` writes no `nan_count`.
    """
    var out = FloatMinMax[dtype]()
    for i in range(len(values)):
        out.observe(values[i])
    out.nan_count_exact = False
    return out^


# =============================================================================
# Emit
# =============================================================================


@always_inline
def _encode_le_bits[dtype: DType](value: Scalar[dtype]) -> List[UInt8]:
    """PLAIN-encode one float as little-endian IEEE-754 bytes.

    parquet.thrift: min_value/max_value are "encoded using PLAIN encoding",
    which for FLOAT is 4 little-endian bytes of the IEEE-754 single and for
    DOUBLE 8 of the double. `to_bits()` reinterprets without going through an
    integer CONVERSION, which is what keeps -0.0 (0x8000000000000000) and NaN
    payloads intact.
    """
    comptime width = size_of[Scalar[dtype]]()
    var bits = UInt64(value.to_bits())
    var out = List[UInt8](capacity=width)
    for i in range(width):
        out.append(UInt8(Int((bits >> UInt64(i * 8)) & UInt64(0xFF))))
    return out^


def make_float_statistics[
    dtype: DType
](mm: FloatMinMax[dtype], null_count: Int) -> Statistics:
    """Build the column-chunk `Statistics` for a FLOAT / DOUBLE chunk.

    Applies the spec rules that cannot be expressed in the scan itself:

    * an UNSEEDED accumulator (empty / all-null / all-NaN) publishes
      `null_count` and NO min/max;
    * `nan_count` is published whenever the accumulator's count is exact
      (every array scan), including 0 and the all-NaN case;
    * a computed zero min is written as **-0.0** and a computed zero max as
      **+0.0**, per parquet.thrift's ColumnOrder rules for TYPE_ORDER. They
      compare equal so this never changes which rows the interval covers; it
      only stops a reader that compares BITS from excluding the other sign.

    NO `distinct_count` and NO `hll_registers` — see the module header for
    the footer-size argument.
    """
    var nan_count = Optional[Int](None)
    if mm.nan_count_exact:
        nan_count = mm.nan_count
    if not mm.seeded:
        return Statistics(null_count=null_count, nan_count=nan_count)

    var lo = mm.min_value
    var hi = mm.max_value
    # ⚠ `== 0` matches BOTH signed zeros (IEEE-754 equality), which is exactly
    # the test the rule needs: "if the computed min value is zero (whether
    # negative or positive)". A bit-pattern test would miss +0.0.
    if lo == Scalar[dtype](0):
        lo = -Scalar[dtype](0)
    if hi == Scalar[dtype](0):
        hi = Scalar[dtype](0)

    return Statistics(
        null_count=null_count,
        min_value=_encode_le_bits[dtype](lo),
        max_value=_encode_le_bits[dtype](hi),
        nan_count=nan_count,
    )


def float_column_statistics[
    dtype: DType
](array: PrimitiveArray[dtype], skip_nulls: Bool, null_count: Int) -> Statistics:
    """One-shot: scan `array` and emit its chunk `Statistics`."""
    return make_float_statistics[dtype](
        float_minmax_from_array[dtype](array, skip_nulls), null_count
    )
