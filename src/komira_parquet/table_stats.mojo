# =============================================================================
# table_stats: a Parquet footer's statistics as TableStats and StatsProvider
# =============================================================================
#
# Two surfaces over one parsed footer:
#   1. `collect_table_stats(metadata, schema) -> TableStats`, and
#      `read_parquet_table_stats(path, schema)`: the eager form, every
#      column's statistics folded across row groups at once.
#   2. `ParquetStatsProvider`: the `komira_plan_stats.StatsProvider` trait
#      over a footer parsed once at construction; each call walks the parsed
#      footer in memory (no I/O, no parse), so per-row-group queries are
#      cheap however many a caller makes.
#
# Min/max bytes are decoded by the column's type:
#   INT8 / INT16 / INT32   4 bytes LE, signed, widened to Int64
#   UINT8 / UINT16 / UINT32 4 bytes LE, zero-extended to Int64
#   INT64                  8 bytes LE, signed
#   UINT64                 8 bytes LE; a value above Int64.MAX has no Int64
#                          and gives no bound
#   FLOAT32 / FLOAT64      IEEE 754 LE, as Float64; a NaN bound is no bound
#   anything else          no bound (strings, booleans, DECIMAL: unscaled)
# `min_value` / `max_value` are read; the legacy `min` / `max`, whose sort
# order may be wrong, are not.
# =============================================================================

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_collections.hyperloglog import HLL_NUM_REGISTERS, HyperLogLog
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_parquet_api.metadata import FileMetaData, RowGroup, Statistics
from komira_parquet_api.types import (
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    ParquetType,
)
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.physical_type import PhysicalType
from komira_plan_stats.stats_provider import StatsProvider
from komira_plan_stats.table_stats import ColumnStats, STATS_SOURCE_PARQUET_METADATA, TableStats


# -----------------------------------------------------------------------------
# Statistic bytes to ScalarValue
# -----------------------------------------------------------------------------


@always_inline
def _le(bytes: List[UInt8], width: Int) -> Optional[UInt64]:
    if len(bytes) < width:
        return None
    var u = UInt64(0)
    for i in range(width):
        u = u | (UInt64(bytes[i]) << UInt64(i * 8))
    return u


# The decode kinds `_decode_bound` takes.
comptime _K_NONE = 0
comptime _K_I32 = 1
comptime _K_U32 = 2
comptime _K_I64 = 3
comptime _K_U64 = 4
comptime _K_F32 = 5
comptime _K_F64 = 6


def _decode_bound(bytes: List[UInt8], kind: Int) -> Optional[ScalarValue]:
    """A min/max byte buffer as a ScalarValue, or None for a kind with no
    numeric bound, a buffer too short for its type, or a UINT64 above
    Int64.MAX."""
    if kind == _K_I32 or kind == _K_U32 or kind == _K_F32:
        var u = _le(bytes, 4)
        if not u:
            return None
        var w = UInt32(u.value())
        if kind == _K_I32:
            return ScalarValue.from_int64(Int64(bitcast[DType.int32](w)))
        if kind == _K_U32:
            return ScalarValue.from_int64(Int64(Int(w)))
        var f = Float64(bitcast[DType.float32](w))
        if f != f:
            return None
        return ScalarValue.from_float(f)
    if kind == _K_I64 or kind == _K_U64 or kind == _K_F64:
        var u = _le(bytes, 8)
        if not u:
            return None
        if kind == _K_I64:
            return ScalarValue.from_int64(bitcast[DType.int64](u.value()))
        if kind == _K_U64:
            if u.value() > UInt64(Int(Int64.MAX)):
                return None
            return ScalarValue.from_int64(Int64(Int(u.value())))
        var f = bitcast[DType.float64](u.value())
        if f != f:
            return None
        return ScalarValue.from_float(f)
    return None


def _is_nan_bound(bytes: List[UInt8], kind: Int) -> Bool:
    """True iff `bytes` is a complete FLOAT32 / FLOAT64 NaN. `_decode_bound`
    gives no bound for it, and a fold over row groups must not mistake that
    for a row group without statistics: skipping it would leave a bound that
    does not cover its rows."""
    if kind != _K_F32 and kind != _K_F64:
        return False
    var u = _le(bytes, 4 if kind == _K_F32 else 8)
    if not u:
        return False
    if kind == _K_F32:
        var f = bitcast[DType.float32](UInt32(u.value()))
        return f != f
    var d = bitcast[DType.float64](u.value())
    return d != d


def _kind_for_arrow(at: ArrowType) -> Int:
    if at == ArrowType.INT8 or at == ArrowType.INT16 or at == ArrowType.INT32:
        return _K_I32
    if at == ArrowType.UINT8 or at == ArrowType.UINT16 or at == ArrowType.UINT32:
        return _K_U32
    if at == ArrowType.INT64:
        return _K_I64
    if at == ArrowType.UINT64:
        return _K_U64
    if at == ArrowType.FLOAT32:
        return _K_F32
    if at == ArrowType.FLOAT64:
        return _K_F64
    return _K_NONE


def _kind_for_leaf(pt: ParquetType, converted: Int, is_decimal: Bool) -> Int:
    """The decode kind of a leaf from its physical type and ConvertedType
    annotation (-1 for none). DECIMAL statistics are unscaled: no bound."""
    if is_decimal or converted == CONVERTED_TYPE_DECIMAL:
        return _K_NONE
    if pt == ParquetType.INT32:
        if converted == CONVERTED_TYPE_UINT_8 or converted == CONVERTED_TYPE_UINT_16 or converted == CONVERTED_TYPE_UINT_32:
            return _K_U32
        return _K_I32
    if pt == ParquetType.INT64:
        if converted == CONVERTED_TYPE_UINT_64:
            return _K_U64
        return _K_I64
    if pt == ParquetType.FLOAT:
        return _K_F32
    if pt == ParquetType.DOUBLE:
        return _K_F64
    return _K_NONE


@always_inline
def _scalar_lt(a: ScalarValue, b: ScalarValue) -> Bool:
    """Numeric a < b over the integer and float ScalarValues decoded here."""
    var af = a.dtype == DType.float64 or a.dtype == DType.float32
    var bf = b.dtype == DType.float64 or b.dtype == DType.float32
    if af and bf:
        return a.float_val < b.float_val
    if af:
        return a.float_val < Float64(b.int_val)
    if bf:
        return Float64(a.int_val) < b.float_val
    return a.int_val < b.int_val


def _take_min(var cur: Optional[ScalarValue], var candidate: ScalarValue) -> Optional[ScalarValue]:
    if not cur or _scalar_lt(candidate, cur.value()):
        return candidate^
    return cur^


def _take_max(var cur: Optional[ScalarValue], var candidate: ScalarValue) -> Optional[ScalarValue]:
    if not cur or _scalar_lt(cur.value(), candidate):
        return candidate^
    return cur^


def _chunk_of(rg: RowGroup, name: String) -> Int:
    """The column chunk of the top-level leaf `name` in `rg`, by its
    `path_in_schema`, or -1."""
    for c in range(len(rg.columns)):
        ref path = rg.columns[c].meta_data.path_in_schema
        if len(path) == 1 and path[0] == name:
            return c
    return -1


def _top_level_leaf(metadata: FileMetaData, name: String) -> Int:
    """The schema element index of the top-level leaf `name`, or -1.
    `schema[0]` is the root and the rest is the schema flattened depth
    first; a group, or a leaf inside one, is not a top-level leaf."""
    var n = len(metadata.schema)
    if n == 0:
        return -1
    # Children still to come of each open group, innermost last.
    var open_groups = List[Int]()
    open_groups.append(metadata.schema[0].num_children)
    for i in range(1, n):
        while len(open_groups) > 0 and open_groups[len(open_groups) - 1] <= 0:
            _ = open_groups.pop()
        var depth = len(open_groups)
        if depth > 0:
            open_groups[depth - 1] -= 1
        ref element = metadata.schema[i]
        if element.num_children > 0:
            open_groups.append(element.num_children)
        elif depth == 1 and element.name == name:
            return i
    return -1


# -----------------------------------------------------------------------------
# The eager surface
# -----------------------------------------------------------------------------


def collect_table_stats(metadata: FileMetaData, schema: Schema) raises -> TableStats:
    """Fold every column's statistics across the row groups of `metadata`.

    For each column of `schema`, by name: the largest per-row-group
    `distinct_count` (a lower bound on the column's), the sum of
    `null_count` (None if no row group has one), and the smallest min and
    largest max, decoded by the column's Arrow type. A row group without
    the column, or without statistics, is skipped.
    """
    var row_count = 0
    for r in range(len(metadata.row_groups)):
        row_count += metadata.row_groups[r].num_rows

    var column_names = List[String]()
    var column_stats = List[ColumnStats]()

    for col_idx in range(schema.num_columns()):
        var col_name = schema.field_name(col_idx)
        var kind = _kind_for_arrow(schema.field_arrow_type(col_idx))

        var overall_distinct: Optional[Int] = None
        var overall_min: Optional[ScalarValue] = None
        var overall_max: Optional[ScalarValue] = None
        var overall_null: Optional[Int] = None
        # A NaN bound in any row group leaves the column's min and max
        # unknown: the other row groups' bounds do not cover its rows.
        var nan_bound = False

        for r in range(len(metadata.row_groups)):
            ref rg = metadata.row_groups[r]
            var c = _chunk_of(rg, col_name)
            if c < 0:
                continue
            ref stats_opt = rg.columns[c].meta_data.statistics
            if not stats_opt:
                continue
            ref stats = stats_opt.value()
            if stats.distinct_count:
                var dc = stats.distinct_count.value()
                if dc > 0 and (not overall_distinct or dc > overall_distinct.value()):
                    overall_distinct = dc
            if stats.null_count:
                var nc = stats.null_count.value()
                overall_null = nc if not overall_null else overall_null.value() + nc
            if stats.min_value:
                var mn = _decode_bound(stats.min_value.value(), kind)
                if mn:
                    overall_min = _take_min(overall_min^, mn.value().copy())
                elif _is_nan_bound(stats.min_value.value(), kind):
                    nan_bound = True
            if stats.max_value:
                var mx = _decode_bound(stats.max_value.value(), kind)
                if mx:
                    overall_max = _take_max(overall_max^, mx.value().copy())
                elif _is_nan_bound(stats.max_value.value(), kind):
                    nan_bound = True

        if nan_bound:
            overall_min = None
            overall_max = None

        column_names.append(col_name)
        column_stats.append(ColumnStats(overall_distinct^, overall_min^, overall_max^, overall_null^))

    return TableStats(row_count, column_names^, column_stats^, STATS_SOURCE_PARQUET_METADATA)


def _read_footer(path: String) raises -> FileMetaData:
    var reader = ParquetFileReader[LocalFs[NoopSink]].open_metadata_only(path)
    return parse_full_metadata(reader.metadata_bytes.view_range_ro(0, reader.metadata_length))


def read_parquet_table_stats(path: String, schema: Schema) raises -> TableStats:
    """Read the footer of the local file `path` (no mapping of its data) and
    `collect_table_stats` over it."""
    return collect_table_stats(_read_footer(path), schema)


# -----------------------------------------------------------------------------
# HLL register merge
# -----------------------------------------------------------------------------


def _max_registers_into(mut dst: List[UInt8], src: List[UInt8]):
    """Register-wise max of `src` into `dst`, both HLL_NUM_REGISTERS long.

    PERF-CRITICAL: a provider answers an NDV query by folding every row
    group's registers (12 columns x 49 row groups is 588 folds of 4096
    bytes); a byte loop there was a measured cost at plan time. 16 bytes per
    step.
    """
    comptime W = 16
    debug_assert(len(dst) == HLL_NUM_REGISTERS and len(src) == HLL_NUM_REGISTERS)
    var d = dst.unsafe_ptr()
    var s = src.unsafe_ptr()
    for j in range(0, HLL_NUM_REGISTERS, W):
        # SAFETY: both lists hold exactly HLL_NUM_REGISTERS (4096) bytes (the
        # callers check `src`; `dst` is made at that length), 4096 is a
        # multiple of W, and both lists outlive this loop.
        (d + j).store(max((d + j).load[width=W](), (s + j).load[width=W]()))


# -----------------------------------------------------------------------------
# ParquetStatsProvider: the StatsProvider surface
# -----------------------------------------------------------------------------


struct ParquetStatsProvider(StatsProvider, Movable):
    """`StatsProvider` over one file's parsed footer.

    A column is a top-level leaf, found by its `path_in_schema`. The
    per-file folds (`column_min_max`, `column_distinct_count`,
    `column_null_count`, the HLL methods) answer None (or False) when any
    row group lacks the column or the statistic: a bound must cover every
    row group.
    """

    var _metadata: FileMetaData
    var _schema: Schema

    def __init__(out self, var metadata: FileMetaData, var schema: Schema):
        """Over a parsed footer. No I/O."""
        self._metadata = metadata^
        self._schema = schema^

    @staticmethod
    def from_path(path: String, var schema: Schema) raises -> Self:
        """Read and parse the footer of the local file `path`."""
        return Self(_read_footer(path), schema^)

    def cached_metadata(ref self) -> ref [self._metadata] FileMetaData:
        """The parsed footer."""
        return self._metadata

    def _kind(self, rg: RowGroup, c: Int, name: String) -> Int:
        """The decode kind of chunk `c` of `rg`, the top-level leaf `name`."""
        var el = _top_level_leaf(self._metadata, name)
        var converted = -1
        var is_decimal = False
        if el >= 0:
            ref e = self._metadata.schema[el]
            if e.converted_type:
                converted = e.converted_type.value()
            is_decimal = Bool(e.scale)
        return _kind_for_leaf(rg.columns[c].meta_data.type, converted, is_decimal)

    def num_row_groups(self) -> Int:
        return len(self._metadata.row_groups)

    def total_row_count(self) -> Int:
        return self._metadata.num_rows

    def column_physical_type(self, name: String) -> Optional[PhysicalType]:
        var el = _top_level_leaf(self._metadata, name)
        if el < 0 or not self._metadata.schema[el].type:
            return None
        var pq = self._metadata.schema[el].type.value()
        if pq == ParquetType.BOOLEAN:
            return PhysicalType.BOOLEAN
        if pq == ParquetType.INT32:
            return PhysicalType.INT32
        if pq == ParquetType.INT64:
            return PhysicalType.INT64
        if pq == ParquetType.INT96:
            return PhysicalType.INT96
        if pq == ParquetType.FLOAT:
            return PhysicalType.FLOAT
        if pq == ParquetType.DOUBLE:
            return PhysicalType.DOUBLE
        if pq == ParquetType.BYTE_ARRAY:
            return PhysicalType.BYTE_ARRAY
        if pq == ParquetType.FIXED_LEN_BYTE_ARRAY:
            return PhysicalType.FIXED_LEN_BYTE_ARRAY
        return None

    def _rg_bounds(self, rg_idx: Int, name: String) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        ref rg = self._metadata.row_groups[rg_idx]
        var c = _chunk_of(rg, name)
        if c < 0:
            return None
        ref stats_opt = rg.columns[c].meta_data.statistics
        if not stats_opt:
            return None
        ref stats = stats_opt.value()
        if not stats.min_value or not stats.max_value:
            return None
        var kind = self._kind(rg, c, name)
        var mn = _decode_bound(stats.min_value.value(), kind)
        var mx = _decode_bound(stats.max_value.value(), kind)
        if not mn or not mx:
            return None
        return (mn.value().copy(), mx.value().copy())

    def column_rg_min_max(self, name: String, rg_idx: Int) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        if rg_idx < 0 or rg_idx >= len(self._metadata.row_groups):
            return None
        return self._rg_bounds(rg_idx, name)

    def column_min_max(self, name: String) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        """The smallest min and largest max over every row group; None if
        any row group has no decodable bound for the column."""
        var n = len(self._metadata.row_groups)
        if n == 0:
            return None
        var overall_min: Optional[ScalarValue] = None
        var overall_max: Optional[ScalarValue] = None
        for r in range(n):
            var b = self._rg_bounds(r, name)
            if not b:
                return None
            overall_min = _take_min(overall_min^, b.value()[0].copy())
            overall_max = _take_max(overall_max^, b.value()[1].copy())
        return (overall_min.value().copy(), overall_max.value().copy())

    def column_distinct_count(self, name: String) -> Optional[Int]:
        """The SUM of the per-row-group distinct counts (an over-count for a
        value in several row groups); None if any row group lacks one."""
        var n = len(self._metadata.row_groups)
        if n == 0:
            return None
        var total = 0
        for r in range(n):
            ref rg = self._metadata.row_groups[r]
            var c = _chunk_of(rg, name)
            if c < 0:
                return None
            ref stats_opt = rg.columns[c].meta_data.statistics
            if not stats_opt or not stats_opt.value().distinct_count:
                return None
            total += stats_opt.value().distinct_count.value()
        return total

    def column_null_count(self, name: String) -> Optional[Int]:
        var n = len(self._metadata.row_groups)
        if n == 0:
            return None
        var total = 0
        for r in range(n):
            ref rg = self._metadata.row_groups[r]
            var c = _chunk_of(rg, name)
            if c < 0:
                return None
            ref stats_opt = rg.columns[c].meta_data.statistics
            if not stats_opt or not stats_opt.value().null_count:
                return None
            total += stats_opt.value().null_count.value()
        return total

    def _merged_registers(self, name: String) -> Optional[List[UInt8]]:
        """The register-wise max of every row group's HLL registers for the
        column, or None if any row group lacks well-formed registers."""
        var n = len(self._metadata.row_groups)
        if n == 0:
            return None
        var merged = List[UInt8](length=HLL_NUM_REGISTERS, fill=0)
        for r in range(n):
            ref rg = self._metadata.row_groups[r]
            var c = _chunk_of(rg, name)
            if c < 0:
                return None
            ref stats_opt = rg.columns[c].meta_data.statistics
            if not stats_opt or not stats_opt.value().hll_registers:
                return None
            ref regs = stats_opt.value().hll_registers.value()
            if len(regs) != HLL_NUM_REGISTERS:
                return None
            _max_registers_into(merged, regs)
        return merged^

    def column_ndv_estimate(self, name: String) -> Optional[Int]:
        """The HLL estimate of the merged registers when every row group has
        them (a value in several row groups counts once); otherwise
        `column_distinct_count`, the per-row-group sum."""
        var merged = self._merged_registers(name)
        if not merged:
            return self.column_distinct_count(name)
        var sketch = HyperLogLog()
        ref regs = merged.value()
        for j in range(HLL_NUM_REGISTERS):
            sketch.set_register(j, regs[j])
        return sketch.estimate()

    def column_ndv_estimate_from_hll(self, name: String) -> Bool:
        """True iff `column_ndv_estimate` merges HLL registers: every row
        group's chunk of the column carries well-formed ones."""
        var n = len(self._metadata.row_groups)
        if n == 0:
            return False
        for r in range(n):
            ref rg = self._metadata.row_groups[r]
            var c = _chunk_of(rg, name)
            if c < 0:
                return False
            ref stats_opt = rg.columns[c].meta_data.statistics
            if not stats_opt or not stats_opt.value().hll_registers:
                return False
            if len(stats_opt.value().hll_registers.value()) != HLL_NUM_REGISTERS:
                return False
        return True

    def column_merged_hll_registers(self, name: String) -> Optional[List[UInt8]]:
        """The merged registers themselves, for a caller merging across
        files; None when `column_ndv_estimate_from_hll` is False."""
        return self._merged_registers(name)
