# =============================================================================
# column_stats_accum: the per-column accumulator and the per-(column, batch)
# scanners behind `compute_column_stats` (see column_stats.mojo)
# =============================================================================
#
# One `_ColAccum` per column is threaded through every batch; the scanners
# read each batch's column buffers in place and feed it. `_finalize_accum`
# (column_stats.mojo) turns the accumulator into a ColumnStats.
#
# Values a scanner cannot read (a column type with no scanner, a column whose
# buffers do not match its schema field) are counted in `n_unscanned`, never
# in `n_values`; one such value makes every value statistic of the column
# Absent at finalize, since a min, max, sum, NDV or bloom over a subset of
# the values would claim something about values nobody looked at.
# =============================================================================

from std.math import inf, isnan
from std.sys import simd_width_of, size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.varlen_width_guard import (
    carries_offsets,
    offset_width_bytes_or_raise,
)
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_scan_source.column_stats_hll import HyperLogLog, _mix64, _mix64_simd


# =============================================================================
# Tuning constants
# =============================================================================

# Exact-NDV tracking threshold. While a column's observed distinct count is
# <= this, we track it exactly via a hash-set; above it, distinct_count
# becomes INEXACT (HLL estimate). 4096 mirrors the HLL register count.
comptime EXACT_NDV_THRESHOLD: Int = 4096

# Bloom filter is built only for columns whose estimated NDV is at or below
# this cap — i.e. plausible IN-list pushdown targets. 64 K distinct @ 1% FPP
# ≈ 96 KiB. Above the cap we leave bloom = None.
comptime BLOOM_NDV_CAP: Int = 64 * 1024
comptime BLOOM_FPP: Float64 = 0.01

# Bloom-disable polling: once we've seen enough rows for the HLL estimate
# to be reliable, poll it every `1 << BLOOM_DISABLE_CHECK_BITS` rows; if
# the estimate exceeds `BLOOM_NDV_CAP`, the bloom would be discarded at
# finalize anyway, so we stop inserting now and save the SBBF write cost
# on the remaining rows. The cadence is coarse (every 65 K rows) because
# HLL.count() builds a 4096-register histogram.
comptime BLOOM_DISABLE_FIRST_CHECK: Int = 65536
comptime BLOOM_DISABLE_CHECK_BITS: Int = 16  # 1 << 16 = 65536
comptime BLOOM_DISABLE_CHECK_MASK: Int = (1 << BLOOM_DISABLE_CHECK_BITS) - 1

# The hash key of every NaN. Float values are hashed by their IEEE-754 bit
# pattern, except that all NaNs share this key and -0.0 hashes as +0.0, so
# NaN counts as one distinct value and the two zeros as one (the engine's
# float order: NaNs are one value, +0.0 == -0.0).
comptime FLOAT_NAN_KEY: UInt64 = 0x7FF8000000000000


comptime _ACC_KIND_NONE: UInt8 = 0
comptime _ACC_KIND_INT: UInt8 = 1     # signed/unsigned int, date32/64, timestamp
comptime _ACC_KIND_FLOAT: UInt8 = 2
comptime _ACC_KIND_BOOL: UInt8 = 3
comptime _ACC_KIND_STRING: UInt8 = 4


@always_inline
def _float_key(v: Float64) -> UInt64:
    """The hash key of a float value: see `FLOAT_NAN_KEY`."""
    if isnan(v):
        return FLOAT_NAN_KEY
    if v == 0.0:
        return UInt64(0)
    return UInt64(v.to_bits())


@always_inline
def _add_overflows(a: Int64, b: Int64, s: Int64) -> Bool:
    """True when `s`, the wrapped `a + b`, overflowed: both operands share
    a sign and the result's sign differs."""
    return ((a ^ s) & (b ^ s)) < 0


# =============================================================================
# Per-column accumulator
# =============================================================================


struct _ColAccum(Movable):
    """Mutable single-column accumulator threaded through the batch loop."""

    var arrow_type: ArrowType
    var acc_kind: UInt8
    var seen_value: Bool
    var null_count: Int
    var total_len_bytes: Int            # sum of element byte sizes (for avg)
    var n_values: Int                   # scanned non-null value count
    var n_unscanned: Int                # non-null values no scanner read
    # numeric (int representation):
    var min_i: Int64
    var max_i: Int64
    var sum_i: Int64
    var sum_overflowed: Bool            # sum_i wrapped at least once
    # numeric (float representation):
    var min_f: Float64                  # over non-NaN values
    var max_f: Float64                  # over non-NaN values
    var sum_f: Float64
    var n_nan: Int
    # string min/max:
    var min_s: String
    var max_s: String
    # NDV:
    var hll: HyperLogLog
    var exact_set: Dict[UInt64, Bool]
    var exact_overflowed: Bool
    # bloom (active while NDV plausibly small):
    var bloom: BloomFilter
    var bloom_active: Bool

    def __init__(out self, arrow_type: ArrowType, est_rows: Int):
        self.arrow_type = arrow_type
        if arrow_type == ArrowType.BOOL:
            self.acc_kind = _ACC_KIND_BOOL
        elif arrow_type == ArrowType.STRING or arrow_type == ArrowType.LARGE_STRING:
            self.acc_kind = _ACC_KIND_STRING
        elif arrow_type == ArrowType.FLOAT32 or arrow_type == ArrowType.FLOAT64:
            self.acc_kind = _ACC_KIND_FLOAT
        elif (
            arrow_type.is_integer()
            or arrow_type == ArrowType.DATE32
            or arrow_type == ArrowType.DATE64
            or arrow_type == ArrowType.TIMESTAMP
            or arrow_type == ArrowType.TIMESTAMP_S
            or arrow_type == ArrowType.TIMESTAMP_MS
            or arrow_type == ArrowType.TIMESTAMP_US
            or arrow_type == ArrowType.TIMESTAMP_NS
        ):
            self.acc_kind = _ACC_KIND_INT
        else:
            self.acc_kind = _ACC_KIND_NONE
        self.seen_value = False
        self.null_count = 0
        self.total_len_bytes = 0
        self.n_values = 0
        self.n_unscanned = 0
        self.min_i = Int64.MAX
        self.max_i = Int64.MIN
        self.sum_i = 0
        self.sum_overflowed = False
        self.min_f = inf[DType.float64]()
        self.max_f = -inf[DType.float64]()
        self.sum_f = 0.0
        self.n_nan = 0
        self.min_s = String("")
        self.max_s = String("")
        self.hll = HyperLogLog()
        self.exact_set = Dict[UInt64, Bool]()
        self.exact_overflowed = False
        var bloom_ndv = est_rows
        if bloom_ndv > BLOOM_NDV_CAP:
            bloom_ndv = BLOOM_NDV_CAP
        if bloom_ndv < 1:
            bloom_ndv = 1
        self.bloom = BloomFilter.with_ndv_fpp(bloom_ndv, BLOOM_FPP)
        self.bloom_active = True

    @always_inline
    def note_hash(mut self, h: UInt64):
        """Feed a value hash into the HLL, the exact set (until it holds more
        than `EXACT_NDV_THRESHOLD` hashes, when it is freed and the HLL
        estimate takes over), and the bloom (while active).

        Bloom independence: bloom_active is NOT flipped by the exact-set
        overflow — bloom is useful at NDVs up to `BLOOM_NDV_CAP` (64K), well
        above `EXACT_NDV_THRESHOLD` (4K). It is flipped off only when the HLL
        projects NDV > `BLOOM_NDV_CAP` at a `BLOOM_DISABLE_*` poll.
        """
        self.hll.add(h)
        if not self.exact_overflowed:
            self.exact_set[h] = True
            if len(self.exact_set) > EXACT_NDV_THRESHOLD:
                self.exact_overflowed = True
                self.exact_set = Dict[UInt64, Bool]()  # free it; HLL takes over
        # Bloom decision: we disable the bloom feed when (a) we've collected
        # enough rows for a reliable HLL estimate AND (b) that estimate
        # already exceeds BLOOM_NDV_CAP — in which case _finalize_accum will
        # drop the bloom anyway, so there's no point continuing to insert.
        if self.bloom_active:
            if (
                self.n_values >= BLOOM_DISABLE_FIRST_CHECK
                and (self.n_values & BLOOM_DISABLE_CHECK_MASK) == 0
            ):
                # HLL.count is O(m) = O(4096); cheap to poll at this cadence.
                var est = Int(self.hll.count())
                if est > BLOOM_NDV_CAP:
                    self.bloom_active = False
            if self.bloom_active:
                self.bloom.insert_hash(h)

    @always_inline
    def feed_hashes_simd_block[
        W: Int
    ](mut self, h_vec: SIMD[DType.uint64, W], n_values_before: Int):
        """Feed W pre-computed value hashes — the same net state as W
        successive `note_hash()` calls (vectorized feed).

        The HLL register update is done in one `add_bulk[W]` (SIMD-compute /
        scalar-scatter); the exact-set and bloom sides are per-lane scalar loops
        — `Dict[UInt64, Bool]` insert and the SBBF block OR-back have no SIMD
        batch form (random scatter destinations). When the column has already
        overflowed the exact set AND disabled the bloom (the common
        high-cardinality steady state), both scalar loops are skipped entirely
        and the only per-cell cost is the vectorized hash + register update.

        Preconditions: `self.n_values` has ALREADY been advanced past this block
        (i.e. equals `n_values_before + W`) and `seen_value` is set.

        The bloom-disable poll fires iff the block crosses a
        `1 << BLOOM_DISABLE_CHECK_BITS` boundary at or past
        `BLOOM_DISABLE_FIRST_CHECK` (the scalar path polls at exactly those
        row counts). The exact-set overflow is observed after the whole block
        rather than at the overflowing lane; an over-threshold set is
        discarded either way, so the finalized stats are the same.
        """
        self.hll.add_bulk[W](h_vec)

        if not self.exact_overflowed:

            comptime for j in range(W):
                self.exact_set[h_vec[j]] = True
            if len(self.exact_set) > EXACT_NDV_THRESHOLD:
                self.exact_overflowed = True
                self.exact_set = Dict[UInt64, Bool]()

        if self.bloom_active:
            var crossed_disable = (
                self.n_values >= BLOOM_DISABLE_FIRST_CHECK
                and (n_values_before >> BLOOM_DISABLE_CHECK_BITS)
                != (self.n_values >> BLOOM_DISABLE_CHECK_BITS)
            )
            if crossed_disable:
                var est = Int(self.hll.count())
                if est > BLOOM_NDV_CAP:
                    self.bloom_active = False
            if self.bloom_active:

                comptime for j in range(W):
                    self.bloom.insert_hash(h_vec[j])

    @always_inline
    def add_to_sum(mut self, v: Int64):
        """`sum_i += v`, wrapping, and remember whether it ever wrapped."""
        var s = self.sum_i + v
        if _add_overflows(self.sum_i, v, s):
            self.sum_overflowed = True
        self.sum_i = s

    @always_inline
    def note_int(mut self, v: Int64):
        self.seen_value = True
        self.n_values += 1
        if v < self.min_i:
            self.min_i = v
        if v > self.max_i:
            self.max_i = v
        self.add_to_sum(v)
        self.note_hash(_mix64(UInt64(v)))

    @always_inline
    def note_float(mut self, v: Float64):
        """Comparisons skip NaN (counted in `n_nan`); the sum takes every
        value, so one NaN makes it NaN."""
        self.seen_value = True
        self.n_values += 1
        self.sum_f += v
        if isnan(v):
            self.n_nan += 1
        else:
            if v < self.min_f:
                self.min_f = v
            if v > self.max_f:
                self.max_f = v
        self.note_hash(_mix64(_float_key(v)))

    @always_inline
    def note_bool(mut self, v: Bool):
        self.seen_value = True
        self.n_values += 1
        var iv: Int64 = 1 if v else 0
        if iv < self.min_i:
            self.min_i = iv
        if iv > self.max_i:
            self.max_i = iv
        self.note_hash(_mix64(UInt64(iv)))

    @always_inline
    def note_unscanned(mut self, col: Column, nrows: Int):
        """Count a batch's column without reading its values: exact nulls,
        and its non-null values as unscanned."""
        var ncol_nulls = col.null_count()
        self.null_count += ncol_nulls
        self.n_unscanned += nrows - ncol_nulls


# =============================================================================
# Per-(column, batch) scanners
# =============================================================================
#
# `col` is the type-erased Column (borrowed ref — `Column` is Movable-only so
# it cannot be passed by value).
#
# ZERO-COPY: the scanners read directly from `col._data` /
# `col._validity` / `col._offsets` (MmapAlignedBuffer.get_typed for primitives,
# Bitmap.test for validity, MmapAlignedBuffer.read_u8_at for raw bytes). They
# never invoke `as_primitive` / `as_string` / `as_boolean`, which would COPY
# the buffers into a freshly-allocated typed array (hundreds of MB of memcpy
# for a wide multi-million-row table). The single-underscore prefix on
# Column's internal fields is the module-internal convention — other
# perf-critical kernels (partition scan, perfect-hash aggregation, top-N
# rank helpers) also read these fields directly.


def _scan_primitive_int_zero_copy[dtype: DType](
    mut acc: _ColAccum, col: Column, nrows: Int
):
    """Scan an integer-valued column directly from `col._data` — no copy.

    The no-validity path (the common case for stats columns) goes through the
    SIMD kernel `_scan_int_simd_no_validity` — W values per iteration, lane-wise
    min/max/sum + lane-wise `_mix64` hash + bulk HLL register update.
    The validity path stays scalar (per-row Bitmap.test gating) and feeds via
    `acc.note_int`.
    """
    var has_validity = col._validity.__bool__()
    var off = col._offset
    if not has_validity:
        _scan_int_simd_no_validity[dtype](acc, col, nrows)
    else:
        ref vbm = col._validity.value()
        for i in range(nrows):
            if not vbm.test(off + i):
                acc.null_count += 1
            else:
                acc.note_int(
                    Int64(Int(col._data.get_typed[Scalar[dtype]](off + i)))
                )


def _scan_int_simd_no_validity[dtype: DType](
    mut acc: _ColAccum, col: Column, nrows: Int
):
    """SIMD column scan for a null-free integer column (vectorized feed).

    Per W-lane iteration (W = native int64 lane count, 4 on AVX2 / 8 on
    AVX-512):
      - load W `dtype` values from `col._data` and widen to `SIMD[int64, W]`;
      - lane-wise min / max / sum reduction (branchless `select`) —
        the SIMD accumulators are seeded from the running `acc.min_i/max_i` and
        reduced back after the loop; a lane sum that wraps is recorded in
        `ovf_vec` (the sign bit of `(a ^ s) & (b ^ s)`), and the lanes are
        folded into `acc.sum_i` through the checked `add_to_sum`;
      - lane-wise `_mix64` hash on the int64 bit-pattern, then a single
        `HyperLogLog.add_bulk[W]` (SIMD index/rank compute, scalar scatter-max)
        and `_ColAccum.feed_hashes_simd_block[W]` for the exact-set / bloom side
        (per-lane scalar — those have no SIMD batch form — but skipped wholesale
        once the column has overflowed the exact set and disabled the bloom).
    The `nrows % W` tail is handled by the scalar `acc.note_int` path.

    The net state equals W successive `note_int` calls: the lane-wise hash
    is the same algebraic form as `_mix64` (lane-by-lane agreement is
    checked by test_mix64_is_splitmix64_and_simd_twin_agrees),
    register-max is order-independent, min/max are commutative, and a
    wrapping sum is the same modulo 2^64 in any order. Only the
    overflow flag can differ: a sum that wraps and wraps back is flagged
    by one order and not another, and a flagged sum is never reported.
    """
    if nrows == 0:
        return
    var off = col._offset
    acc.seen_value = True

    comptime W: Int = simd_width_of[DType.int64]()
    comptime ELEM_BYTES: Int = size_of[Scalar[dtype]]()
    var simd_end = (nrows // W) * W

    # SIMD min/max/sum accumulators, seeded from the running accumulator state.
    var min_vec = SIMD[DType.int64, W](acc.min_i)
    var max_vec = SIMD[DType.int64, W](acc.max_i)
    var sum_vec = SIMD[DType.int64, W](0)
    var ovf_vec = SIMD[DType.int64, W](0)

    var i = 0
    while i < simd_end:
        # Load W lanes of `dtype` (byte offset = element-index * elem size),
        # widen to int64 (sign-extends signed lanes, zero-extends unsigned).
        var raw = col._data.load_simd[dtype, W]((off + i) * ELEM_BYTES)
        var v64 = raw.cast[DType.int64]()

        min_vec = (v64.lt(min_vec)).select(v64, min_vec)
        max_vec = (v64.gt(max_vec)).select(v64, max_vec)
        var new_sum = sum_vec + v64
        ovf_vec |= (sum_vec ^ new_sum) & (v64 ^ new_sum)
        sum_vec = new_sum

        # Hash the int64 bit-pattern (matches scalar `_mix64(UInt64(v))`).
        var h_vec = _mix64_simd[W](v64.cast[DType.uint64]())

        var n_before = acc.n_values
        acc.n_values += W
        acc.feed_hashes_simd_block[W](h_vec, n_before)
        i += W

    # Fold the SIMD accumulators back into the scalar accumulator.
    acc.min_i = min_vec.reduce_min()
    acc.max_i = max_vec.reduce_max()
    if ovf_vec.reduce_or() < 0:
        acc.sum_overflowed = True
    comptime for j in range(W):
        acc.add_to_sum(sum_vec[j])

    # Scalar tail (< W rows) — use the row-at-a-time path for exact parity.
    while i < nrows:
        acc.note_int(Int64(Int(col._data.get_typed[Scalar[dtype]](off + i))))
        i += 1


def _scan_primitive_float_zero_copy[dtype: DType](
    mut acc: _ColAccum, col: Column, nrows: Int
):
    """Scan a float-valued column directly from `col._data` — no copy.
    Promotes each non-null value to Float64 and feeds the accumulator.
    """
    var has_validity = col._validity.__bool__()
    var off = col._offset
    if not has_validity:
        for i in range(nrows):
            acc.note_float(
                Float64(col._data.get_typed[Scalar[dtype]](off + i))
            )
    else:
        ref vbm = col._validity.value()
        for i in range(nrows):
            if not vbm.test(off + i):
                acc.null_count += 1
            else:
                acc.note_float(
                    Float64(col._data.get_typed[Scalar[dtype]](off + i))
                )


def _scan_int_column(mut acc: _ColAccum, col: Column, at: ArrowType, nrows: Int) raises:
    if at == ArrowType.INT8:
        _scan_primitive_int_zero_copy[DType.int8](acc, col, nrows)
    elif at == ArrowType.INT16:
        _scan_primitive_int_zero_copy[DType.int16](acc, col, nrows)
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        _scan_primitive_int_zero_copy[DType.int32](acc, col, nrows)
    elif (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        _scan_primitive_int_zero_copy[DType.int64](acc, col, nrows)
    elif at == ArrowType.UINT8:
        _scan_primitive_int_zero_copy[DType.uint8](acc, col, nrows)
    elif at == ArrowType.UINT16:
        _scan_primitive_int_zero_copy[DType.uint16](acc, col, nrows)
    elif at == ArrowType.UINT32:
        _scan_primitive_int_zero_copy[DType.uint32](acc, col, nrows)
    elif at == ArrowType.UINT64:
        # A value above Int64.MAX reads as a negative Int64; `_finalize_accum`
        # then reports no min/max/sum (see there).
        _scan_primitive_int_zero_copy[DType.uint64](acc, col, nrows)
    else:  # no INT-kind type reaches here; count without reading.
        acc.note_unscanned(col, nrows)


def _scan_float_column(mut acc: _ColAccum, col: Column, at: ArrowType, nrows: Int) raises:
    if at == ArrowType.FLOAT32:
        _scan_primitive_float_zero_copy[DType.float32](acc, col, nrows)
    elif at == ArrowType.FLOAT64:
        _scan_primitive_float_zero_copy[DType.float64](acc, col, nrows)
    else:  # no FLOAT-kind type reaches here; count without reading.
        acc.note_unscanned(col, nrows)


def _scan_bool_column(mut acc: _ColAccum, col: Column, nrows: Int) raises:
    """Scan a boolean column zero-copy: read packed bits from `col._data`
    (a Bitmap stored as bytes) and validity from `col._validity`. No
    BooleanArray copy."""
    # The Column's `_data` for BOOL stores the packed value bits (one bit
    # per element); validity is the standard separate bitmap. Both share
    # the same byte-offset access pattern.
    var has_validity = col._validity.__bool__()
    var off = col._offset
    for i in range(nrows):
        if has_validity:
            ref vbm = col._validity.value()
            if not vbm.test(off + i):
                acc.null_count += 1
                continue
        # Read the value bit directly from col._data. Same encoding as
        # Bitmap.test: byte = (off + i) >> 3, bit = (off + i) & 7.
        var pos = off + i
        var byte_idx = pos >> 3
        var bit_idx = pos & 7
        var b = col._data.read_u8_at(byte_idx)
        var v = ((b >> UInt8(bit_idx)) & UInt8(1)) == UInt8(1)
        acc.note_bool(v)


def _scan_string_column(mut acc: _ColAccum, col: Column, nrows: Int) raises:
    """Scan a string column zero-copy, dispatching on the offsets width.

    `_ColAccum.__init__` tags BOTH STRING and LARGE_STRING as
    `_ACC_KIND_STRING`, and the two layouts differ in offsets width (Int32 vs
    Int64). `get_typed` is ELEMENT-indexed, so reading an Int64 buffer with
    `get_typed[Int32]` would return low32(O[k/2]) for even k and
    high32(O[k/2]) for odd k — wrong min/max/NDV/avg_size feeding the
    OPTIMIZER, and from row index 2 onward a NEGATIVE `nbytes` that reaches
    `List[UInt8](capacity=nbytes + 1)` in `_string_from_col`. The width is
    therefore dispatched on.

    ⚠ THE SCHEMA FIELD AND THE COLUMN CAN DISAGREE, AND THIS FUNCTION IS
    REACHED BY THE DISAGREEMENT. `acc_kind` was decided from
    `schema.field_arrow_type(c)` (`compute_column_stats`), while the width
    below must come from `col.arrow_type` — it is the COLUMN's buffer that is
    about to be strided, and only the column knows how wide its entries are.
    A DICTIONARY column under a declared STRING / LARGE_STRING field lands
    here with a NON-NULL `_offsets` (its dict-VALUE offsets), and
    `carries_offsets(DICTIONARY)` is False; a non-string column under such a
    field has no `_offsets` at all.

    Both take the counting arm below and MUST NOT RAISE. This path runs
    inside `InMemorySource.get_column_stats` during OPTIMIZATION: raising
    fails the whole query. The counting arm is what `compute_column_stats`
    does for a column type it has no scanner for: exact null count, values
    counted as unscanned, so finalize reports min/max/sum/NDV Absent —
    which is also the stats this same DICTIONARY column receives when its
    schema field is honest about being a DICTIONARY.
    """
    if not col._offsets or not carries_offsets(col.arrow_type):
        acc.note_unscanned(col, nrows)
        return
    var ow = offset_width_bytes_or_raise(
        "column_stats(_scan_string_column)", col.arrow_type
    )
    if ow == 8:
        _scan_string_column_w[DType.int64](acc, col, nrows)
    else:
        _scan_string_column_w[DType.int32](acc, col, nrows)


def _scan_string_column_w[
    OffsetType: DType
](mut acc: _ColAccum, col: Column, nrows: Int) raises:
    """Width-parameterized body of `_scan_string_column`. ONE body serves the
    Int32 (STRING) and Int64 (LARGE_STRING) offset layouts.

    The min/max strings still need owned `String` values (PrecisionScalar
    holds a ScalarValue with owned bytes), so a String IS constructed when
    a new min or max is discovered — but only for those branches, not for
    every row (a string column with N distinct values produces O(N)
    String allocations for min/max tracking, vs O(nrows) for the
    `as_string` path).
    """
    var has_validity = col._validity.__bool__()
    var off = col._offset
    ref offsets_buf = col._offsets.value()
    for i in range(nrows):
        if has_validity:
            ref vbm = col._validity.value()
            if not vbm.test(off + i):
                acc.null_count += 1
                continue
        # Offset range for string at logical index `off + i`.
        var start = Int(offsets_buf.get_typed[Scalar[OffsetType]](off + i))
        var end = Int(offsets_buf.get_typed[Scalar[OffsetType]](off + i + 1))
        var nbytes = end - start
        acc.n_values += 1
        acc.total_len_bytes += nbytes
        # FNV-1a directly over col._data bytes — no per-row materialization.
        var h = UInt64(0xCBF29CE484222325)
        comptime prime = UInt64(0x00000100000001B3)
        for b in range(nbytes):
            var byte = col._data.read_u8_at(start + b)
            h = (h ^ UInt64(byte)) * prime
        acc.note_hash(h)
        # Min/max tracking still needs an owned String, but only on
        # discovery of a new extreme (O(distinct) allocations, not
        # O(nrows)).
        if not acc.seen_value:
            acc.seen_value = True
            var s_init = _string_from_col(col, start, nbytes)
            acc.min_s = s_init.copy()
            acc.max_s = s_init^
        else:
            # Materialize only when we need to actually compare: defer
            # the String construction until the byte-compare proves a new
            # extreme. Lexicographic byte-compare of (start, nbytes) vs
            # (existing min/max) is sufficient.
            var cmp_min = _str_byte_cmp(col, start, nbytes, acc.min_s)
            if cmp_min < 0:
                acc.min_s = _string_from_col(col, start, nbytes)
            var cmp_max = _str_byte_cmp(col, start, nbytes, acc.max_s)
            if cmp_max > 0:
                acc.max_s = _string_from_col(col, start, nbytes)


@always_inline
def _string_from_col(col: Column, start: Int, nbytes: Int) -> String:
    """Materialize an owned String from `col._data[start..start+nbytes]`.

    Reuses the same null-terminated-scratch idiom as `StringArray.get`,
    but reads from `col._data` directly (one byte-copy, then String ctor).
    """
    if nbytes == 0:
        return String("")
    var scratch = List[UInt8](capacity=nbytes + 1)
    for b in range(nbytes):
        scratch.append(col._data.read_u8_at(start + b))
    scratch.append(UInt8(0))
    # SAFETY: scratch is alive through the ctor; null-terminated UTF-8.
    return String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())


@always_inline
def _str_byte_cmp(col: Column, start: Int, nbytes: Int, ref s: String) -> Int:
    """Lexicographic byte-compare of `col._data[start..start+nbytes]` vs
    the bytes of `s`. Returns negative / zero / positive (memcmp shape)."""
    var sb = s.as_bytes()
    var slen = len(sb)
    var n = nbytes if nbytes < slen else slen
    for k in range(n):
        var a = col._data.read_u8_at(start + k)
        var b = sb[k]
        if a != b:
            return Int(a) - Int(b)
    return nbytes - slen
