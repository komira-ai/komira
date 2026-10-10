# =============================================================================
# ColumnStats — per-column statistics for InMemorySource
# =============================================================================
#
# One ColumnStats per column of an in-memory relation, holding:
#
#   - min / max          : PrecisionScalar lattice. Exact when every value
#                          was scanned; Absent for a type with no scanner, a
#                          column with values no scanner read, no orderable
#                          value, and the cases `_finalize_accum` lists.
#   - null_count         : Int — exact (we scan the validity buffers).
#   - distinct_count     : PrecisionScalar (Int payload). EXACT when the true
#                          NDV is small enough to track via an exact hash-set;
#                          INEXACT when it exceeds the threshold and we fall
#                          back to the HyperLogLog estimate (at most the
#                          non-null value count); Absent when values went
#                          unscanned.
#   - sum                : PrecisionScalar — numeric columns only; Absent
#                          otherwise, and when it is not representable.
#   - avg_size_bytes     : Float64 — for variable-length columns (String) it's
#                          the mean byte length; for fixed-width it's the
#                          dtype's element size; 0.0 where neither is known.
#   - hll                : Optional[ArcPointer[HyperLogLog]] — register state
#                          for the high-cardinality NDV estimate. Arc-shared so
#                          cache entries that share the same InMemorySource
#                          share the sketch (no byte-copy on ColumnStats.copy()).
#   - bloom              : Optional[ArcPointer[BloomFilter]] — a *static* SBBF
#                          over the column's distinct values, for IN-list
#                          pushdown. Built only when the column is a plausible
#                          IN-list target (NDV <= BLOOM_NDV_CAP); None
#                          otherwise. Reuses komira_dynamic_filter.bloom_filter.
#
# The sketch and the value hashes are in column_stats_hll.mojo; the
# accumulator and the scanners in column_stats_accum.mojo.
#
# ColumnStats is `Movable, Copyable, Deinitable` (the IR-variant
# value-type discipline). The Arc-shared sharing happens at the InMemorySource
# field level (`Optional[ArcPointer[List[ColumnStats]]]`), NOT inside
# ColumnStats — but `copy()` does refcount-bump the HLL/Bloom Arcs, so cloning
# a ColumnStats is cheap.
#
# NESTED-TYPE ColumnStats: a `kind` tag is reserved (PRIMITIVE only
# implemented; LIST / STRUCT child-stats propagation is not implemented).
# =============================================================================

from std.memory import ArcPointer
from std.math import isfinite

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_collections.slab import Slab
from komira_plan_stats.precision_scalar import PrecisionScalar
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.column_stats_accum import (
    BLOOM_NDV_CAP,
    _ACC_KIND_BOOL,
    _ACC_KIND_FLOAT,
    _ACC_KIND_INT,
    _ACC_KIND_STRING,
    _ColAccum,
    _scan_bool_column,
    _scan_float_column,
    _scan_int_column,
    _scan_string_column,
)
from komira_scan_source.column_stats_hll import HyperLogLog


# ColumnStats kind tag. PRIMITIVE implemented; LIST/STRUCT reserved.
comptime COLSTATS_KIND_PRIMITIVE: UInt8 = 0
comptime COLSTATS_KIND_LIST: UInt8 = 1
comptime COLSTATS_KIND_STRUCT: UInt8 = 2


# =============================================================================
# ColumnStats
# =============================================================================


struct ColumnStats(Movable, Copyable, Deinitable):
    """Per-column statistics for an in-memory relation. See module header.

    Construct via `compute_column_stats(batches, schema)` (the lazy-compute
    entry point) or the `null_only(...)` factory.
    """

    var kind: UInt8                       # COLSTATS_KIND_* (PRIMITIVE impl)
    var min: PrecisionScalar
    var max: PrecisionScalar
    var null_count: Int                   # exact
    var distinct_count: PrecisionScalar   # Int payload; Exact iff true NDV small
    var sum: PrecisionScalar              # numeric only; Absent otherwise
    var avg_size_bytes: Float64
    var hll: Optional[ArcPointer[HyperLogLog]]
    var bloom: Optional[ArcPointer[BloomFilter]]

    def __init__(
        out self,
        kind: UInt8,
        var min: PrecisionScalar,
        var max: PrecisionScalar,
        null_count: Int,
        var distinct_count: PrecisionScalar,
        var sum: PrecisionScalar,
        avg_size_bytes: Float64,
        var hll: Optional[ArcPointer[HyperLogLog]],
        var bloom: Optional[ArcPointer[BloomFilter]],
    ):
        self.kind = kind
        self.min = min^
        self.max = max^
        self.null_count = null_count
        self.distinct_count = distinct_count^
        self.sum = sum^
        self.avg_size_bytes = avg_size_bytes
        self.hll = hll^
        self.bloom = bloom^

    def copy(self) -> Self:
        """Explicit copy. PrecisionScalar fields deep-copy their inner
        ScalarValue; the HLL/Bloom Arcs are refcount-bumped (no byte-copy) —
        `Optional[ArcPointer[T]].copy()` is an Optional-of-Arc refcount bump.
        """
        var hll_copy = self.hll.copy()
        var bloom_copy = self.bloom.copy()
        return ColumnStats(
            self.kind,
            self.min.copy(),
            self.max.copy(),
            self.null_count,
            self.distinct_count.copy(),
            self.sum.copy(),
            self.avg_size_bytes,
            hll_copy^,
            bloom_copy^,
        )

    @staticmethod
    def null_only(null_count: Int, avg_size_bytes: Float64) -> ColumnStats:
        """Stats for a column whose type doesn't support min/max/sum/NDV.
        null_count is exact; everything else Absent."""
        var none_hll: Optional[ArcPointer[HyperLogLog]] = None
        var none_bloom: Optional[ArcPointer[BloomFilter]] = None
        return ColumnStats(
            COLSTATS_KIND_PRIMITIVE,
            PrecisionScalar.absent(),
            PrecisionScalar.absent(),
            null_count,
            PrecisionScalar.absent(),
            PrecisionScalar.absent(),
            avg_size_bytes,
            none_hll^,
            none_bloom^,
        )

    def fingerprint(self) -> UInt64:
        """Stable hash of the *summary* fields (min/max/null/NDV/sum/avg).

        Folds into the resolved-cache `stats_hash`. Does NOT
        include the HLL register state or bloom bits — those are derived
        from the same data the summary fields summarize.
        """
        var h = UInt64(0xCBF29CE484222325)
        comptime prime = UInt64(0x00000100000001B3)
        h = (h ^ UInt64(self.kind)) * prime
        h = (h ^ UInt64(self.null_count)) * prime
        h = (h ^ UInt64(self.min.tag)) * prime
        h = (h ^ UInt64(self.max.tag)) * prime
        h = (h ^ UInt64(self.distinct_count.tag)) * prime
        h = (h ^ UInt64(self.sum.tag)) * prime
        if self.distinct_count.is_present():
            h = (h ^ UInt64(self.distinct_count.value.value().int_val)) * prime
        h = (h ^ UInt64(Int(self.avg_size_bytes * 1000.0))) * prime
        return h

# =============================================================================
# Finalization
# =============================================================================


def _finalize_accum(mut acc: _ColAccum) -> ColumnStats:
    """Build the ColumnStats from a fully-populated accumulator.

    Absent rather than a wrong value:
      - every value statistic (min/max/sum/NDV, sketch, bloom) when any
        non-null value went unscanned;
      - INT: min/max/sum of a UINT64 column holding a value above Int64.MAX
        (it was read as a negative Int64, so `min_i < 0`); the sum when it
        overflowed Int64 at any point;
      - FLOAT: min/max when every value is NaN; max when any value is NaN
        (NaN orders above every value, and a max that leaves it out would
        let `x > c` prune NaN rows); the sum when it is not finite.
    An inexact NDV is capped at the non-null value count.
    """
    # null_count is exact regardless.
    var null_count = acc.null_count

    # avg_size_bytes.
    var avg_size: Float64
    if acc.acc_kind == _ACC_KIND_STRING:
        avg_size = (Float64(acc.total_len_bytes) / Float64(acc.n_values)) if acc.n_values > 0 else 0.0
    else:
        avg_size = Float64(_fixed_width_bytes(acc.arrow_type))

    # Values nobody read: nothing about them is known but the null count.
    if acc.n_unscanned > 0:
        return ColumnStats.null_only(null_count, 0.0 if acc.acc_kind == _ACC_KIND_STRING else avg_size)

    # No values at all (all-null or empty) ⇒ min/max/sum Absent, NDV exact 0.
    if not acc.seen_value:
        var zero_ndv = PrecisionScalar.exact(ScalarValue.from_int(0))
        var none_hll: Optional[ArcPointer[HyperLogLog]] = None
        var none_bloom: Optional[ArcPointer[BloomFilter]] = None
        return ColumnStats(
            COLSTATS_KIND_PRIMITIVE,
            PrecisionScalar.absent(),
            PrecisionScalar.absent(),
            null_count,
            zero_ndv^,
            PrecisionScalar.absent(),
            avg_size,
            none_hll^,
            none_bloom^,
        )

    # min / max / sum.
    var min_ps = PrecisionScalar.absent()
    var max_ps = PrecisionScalar.absent()
    var sum_ps = PrecisionScalar.absent()
    if acc.acc_kind == _ACC_KIND_INT:
        if not (acc.arrow_type == ArrowType.UINT64 and acc.min_i < 0):
            min_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.min_i))
            max_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.max_i))
            if not acc.sum_overflowed:
                sum_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.sum_i))
    elif acc.acc_kind == _ACC_KIND_BOOL:
        # sum over booleans not meaningful
        min_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.min_i))
        max_ps = PrecisionScalar.exact(ScalarValue.from_int64(acc.max_i))
    elif acc.acc_kind == _ACC_KIND_FLOAT:
        if acc.n_nan < acc.n_values:
            min_ps = PrecisionScalar.exact(ScalarValue.from_float(acc.min_f))
            if acc.n_nan == 0:
                max_ps = PrecisionScalar.exact(ScalarValue.from_float(acc.max_f))
        if isfinite(acc.sum_f):
            sum_ps = PrecisionScalar.exact(ScalarValue.from_float(acc.sum_f))
    elif acc.acc_kind == _ACC_KIND_STRING:
        min_ps = PrecisionScalar.exact(ScalarValue.from_string(acc.min_s.copy()))
        max_ps = PrecisionScalar.exact(ScalarValue.from_string(acc.max_s.copy()))

    # distinct_count + HLL/Bloom Arc.
    var ndv_ps: PrecisionScalar
    var hll_arc = Optional(ArcPointer[HyperLogLog](acc.hll.copy()))
    var bloom_arc: Optional[ArcPointer[BloomFilter]]
    if not acc.exact_overflowed:
        # Exact NDV from the small set; the bloom is small, keep it.
        ndv_ps = PrecisionScalar.exact(ScalarValue.from_int(len(acc.exact_set)))
        bloom_arc = Optional(ArcPointer[BloomFilter](acc.bloom.copy()))
    else:
        var est = min(Int(acc.hll.count()), acc.n_values)
        ndv_ps = PrecisionScalar.inexact(ScalarValue.from_int(est))
        # Discard the bloom if the column turned out high-cardinality.
        if est > BLOOM_NDV_CAP:
            bloom_arc = None
        else:
            bloom_arc = Optional(ArcPointer[BloomFilter](acc.bloom.copy()))

    return ColumnStats(
        COLSTATS_KIND_PRIMITIVE,
        min_ps^,
        max_ps^,
        null_count,
        ndv_ps^,
        sum_ps^,
        avg_size,
        hll_arc^,
        bloom_arc^,
    )



def _fixed_width_bytes(at: ArrowType) -> Int:
    """Element byte size for a fixed-width arrow type; 0 if variable-length."""
    if at == ArrowType.INT8 or at == ArrowType.UINT8 or at == ArrowType.BOOL:
        return 1
    if at == ArrowType.INT16 or at == ArrowType.UINT16 or at == ArrowType.FLOAT16:
        return 2
    if (
        at == ArrowType.INT32
        or at == ArrowType.UINT32
        or at == ArrowType.FLOAT32
        or at == ArrowType.DATE32
    ):
        return 4
    if (
        at == ArrowType.INT64
        or at == ArrowType.UINT64
        or at == ArrowType.FLOAT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        return 8
    if at == ArrowType.DECIMAL128:
        return 16
    return 0


# =============================================================================
# compute_column_stats — the lazy-compute entry point
# =============================================================================


def compute_column_stats(
    batches: Slab[RecordBatch], schema: Schema
) raises -> List[ColumnStats]:
    """Single pass over `batches`, producing one ColumnStats per column.

    Per-column dispatch on the schema's arrow type:
      - signed/unsigned int, date32/64, timestamp[*]: min/max/sum (as Int64),
        null_count, NDV, bloom (if low-card), avg_size = dtype size.
      - float32/64                                : min/max/sum (as Float64);
        NaN orders above every value, NaNs count as one distinct value
        and so do -0.0 and +0.0.
      - boolean                                   : min/max as 0/1, NDV (≤2),
        avg_size = 1.
      - string / large_string                     : min/max (lexicographic),
        null_count, NDV over byte hashes, avg_size = mean byte length.
      - everything else (binary, dictionary, ...) : null_count only; min/max/
        sum/NDV Absent, no sketch or bloom. So is a string field with a
        non-null value in a batch whose column has no string offsets.
    `_finalize_accum` lists the other Absent cases.

    Args:
        batches: The relation's RecordBatches (read-only; not consumed).
        schema: The structural schema.

    Returns:
        A `List[ColumnStats]` of length `schema.num_columns()`.
    """
    var ncols = schema.num_columns()
    var est_rows = 0
    for i in range(len(batches)):
        est_rows += batches[i]._num_rows

    # `Slab` (Movable container) — `_ColAccum` is Movable-only (heap fields),
    # so a `List` (which requires `T: Copyable`) won't hold it.
    var accums = Slab[_ColAccum].create(max(ncols, 1))
    for c in range(ncols):
        accums.append(_ColAccum(schema.field_arrow_type(c), est_rows))

    for bi in range(len(batches)):
        ref batch = batches[bi]
        var nrows = batch._num_rows
        if nrows == 0:
            continue
        for c in range(ncols):
            var ak = accums[c].acc_kind
            var at = accums[c].arrow_type
            if ak == _ACC_KIND_INT:
                _scan_int_column(accums[c], batch.column_at(c), at, nrows)
            elif ak == _ACC_KIND_FLOAT:
                _scan_float_column(accums[c], batch.column_at(c), at, nrows)
            elif ak == _ACC_KIND_BOOL:
                _scan_bool_column(accums[c], batch.column_at(c), nrows)
            elif ak == _ACC_KIND_STRING:
                _scan_string_column(accums[c], batch.column_at(c), nrows)
            else:
                accums[c].note_unscanned(batch.column_at(c), nrows)

    var out = List[ColumnStats]()
    for c in range(ncols):
        out.append(_finalize_accum(accums[c]))
    return out^
