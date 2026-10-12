# =============================================================================
# PERF-CRITICAL: row-group statistics pruning for Parquet scans
# =============================================================================
# Regression if removed: every selective filter that can rule out whole row
#                        groups by their min/max statistics (dates, ids,
#                        ranges over a roughly sorted column) decodes and
#                        filters every row group instead.
# Measured impact:       turns "decode and filter every row" into "decode the
#                        few row groups that can match"; on a 1% filter over
#                        a sorted column that is an order of magnitude.
# DuckDB equivalent:     zone-map pruning (ParquetStatisticsUtils).
# Do NOT delete without: a selective-filter benchmark, and the tests that a
#                        row group with no match is pruned and one with a
#                        match is not.
# Conservative false:    the contract below is load-bearing. Any change that
#                        prunes more aggressively can drop correct rows.
# =============================================================================
#
# Contract:
# - `can_prune_row_group` returns True only when the row group's column-chunk
#   statistics prove no row matches the filter. The caller skips the row
#   group.
# - It returns False on any ambiguity: missing statistics, a filter shape or
#   type combination it does not handle, a column it cannot resolve, a
#   DECIMAL column (its statistics are unscaled, the literal's scale is not
#   known here).
# - `rg_all_match_row_group` is the dual: True only when the statistics prove
#   every row matches, so a `count(*) WHERE p` can add the row group's
#   `num_rows` without decoding. It also requires `null_count == 0` (see the
#   ALL-MATCH block). `all_match_row_count` answers that count for a whole
#   file when every row group is decided by statistics alone.
#
# Filter shapes handled:
# - col <op> literal and literal <op> col, op in {EQ, NE, LT, LE, GT, GE},
#   on INT64 (signed, or UINT_64), INT32 (signed, or UINT_32), DOUBLE, FLOAT
#   and BYTE_ARRAY columns (the all-match dual: INT64 and INT32 only)
# - AND(a, b): prune if either side proves unsatisfiable
# - OR(a, b):  prune only if both sides do
# - anything else, NOT included: no prune
#
# A column is resolved by name among the TOP-LEVEL LEAVES of the schema:
# `schema[0]` is the root and the rest is the schema flattened depth first,
# and only leaves have column chunks, in leaf order. A group's name, or the
# name of a leaf inside a group, resolves to nothing.
# =============================================================================

from std.memory import bitcast

from komira_parquet_api.metadata import FileMetaData, RowGroup, Statistics
from komira_parquet_api.types import (
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    ParquetType,
)
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Statistic byte decoders
# =============================================================================
#
# Parquet stores min/max as the plain encoding of the value: little-endian
# bytes in a List[UInt8]. Decoded by index and shift.


@always_inline
def _le_u64(bytes: List[UInt8], width: Int) -> Optional[UInt64]:
    """The first `width` bytes as a little-endian unsigned integer, or None
    when fewer bytes are present."""
    if len(bytes) < width:
        return None
    var u = UInt64(0)
    for i in range(width):
        u = u | (UInt64(bytes[i]) << UInt64(i * 8))
    return u


@always_inline
def _decode_le_i32(bytes: List[UInt8]) -> Optional[Int32]:
    var u = _le_u64(bytes, 4)
    if not u:
        return None
    return bitcast[DType.int32](UInt32(u.value()))


@always_inline
def _decode_le_i64(bytes: List[UInt8]) -> Optional[Int64]:
    var u = _le_u64(bytes, 8)
    if not u:
        return None
    return bitcast[DType.int64](u.value())


@always_inline
def _decode_le_u64(bytes: List[UInt8]) -> Optional[UInt64]:
    """The same eight bytes as `_decode_le_i64`, read unsigned. A chunk
    annotated UINT_64 has its min/max in unsigned sort order (the sort order
    of a column is a property of its logical type), so `max = 2**64 - 1`
    read signed is -1."""
    return _le_u64(bytes, 8)


@always_inline
def _decode_le_f32(bytes: List[UInt8]) -> Optional[Float32]:
    var u = _le_u64(bytes, 4)
    if not u:
        return None
    return bitcast[DType.float32](UInt32(u.value()))


@always_inline
def _decode_le_f64(bytes: List[UInt8]) -> Optional[Float64]:
    var u = _le_u64(bytes, 8)
    if not u:
        return None
    return bitcast[DType.float64](u.value())


# =============================================================================
# _can_match_*: could some row in [mn, mx] satisfy `row op v`?
# =============================================================================
#
# True if some value in the range could satisfy the comparison; False only
# when the range proves it cannot.


@always_inline
def _can_match_i64(op: UInt8, v: Int64, mn: Int64, mx: Int64) -> Bool:
    if op == BIN_EQ:
        return mn <= v and v <= mx
    elif op == BIN_NE:
        # Unsatisfiable only when every row equals v.
        return not (mn == v and mx == v)
    elif op == BIN_LT:
        return mn < v
    elif op == BIN_LE:
        return mn <= v
    elif op == BIN_GT:
        return mx > v
    elif op == BIN_GE:
        return mx >= v
    return True


@always_inline
def _can_match_u64(op: UInt8, v: Int64, mn: UInt64, mx: UInt64) -> Bool:
    """`_can_match_i64` over an UNSIGNED range. The literal is an Int64 and
    no single integer type holds both domains, so a negative literal is
    answered on its own terms (every unsigned value is above it) and only a
    non-negative one is converted."""
    if v < 0:
        if op == BIN_EQ or op == BIN_LT or op == BIN_LE:
            return False
        return True
    var u = UInt64(v)
    if op == BIN_EQ:
        return mn <= u and u <= mx
    elif op == BIN_NE:
        return not (mn == u and mx == u)
    elif op == BIN_LT:
        return mn < u
    elif op == BIN_LE:
        return mn <= u
    elif op == BIN_GT:
        return mx > u
    elif op == BIN_GE:
        return mx >= u
    return True


@always_inline
def _can_match_f64(op: UInt8, v: Float64, mn: Float64, mx: Float64) -> Bool:
    """`_can_match_i64` for floating point, with one difference: NE never
    prunes.

    A float min/max bounds the non-NaN values only (parquet.thrift has
    writers exclude NaN from min/max), so the range says nothing about NaN
    rows. For the ordered operators that is harmless: a NaN satisfies
    `<`, `<=`, `>`, `>=` and `==` for no `v`. For `!=` it is not: `NaN != v`
    holds for every `v`, so a chunk whose only non-NaN value is `v` still
    matches if it holds a NaN. This module does not consult `nan_count`.
    """
    if op == BIN_EQ:
        return mn <= v and v <= mx
    elif op == BIN_NE:
        return True
    elif op == BIN_LT:
        return mn < v
    elif op == BIN_LE:
        return mn <= v
    elif op == BIN_GT:
        return mx > v
    elif op == BIN_GE:
        return mx >= v
    return True


def _cmp_bytes(a: Span[UInt8, _], b: Span[UInt8, _]) -> Int:
    """Unsigned lexicographic comparison: -1 if a < b, 0 if equal, 1 if a > b."""
    var la = len(a)
    var lb = len(b)
    var n = la if la < lb else lb
    for i in range(n):
        if a[i] < b[i]:
            return -1
        if a[i] > b[i]:
            return 1
    if la < lb:
        return -1
    if la > lb:
        return 1
    return 0


def _can_match_bytes(op: UInt8, v: Span[UInt8, _], mn: Span[UInt8, _], mx: Span[UInt8, _]) -> Bool:
    """BYTE_ARRAY min/max (unsigned lexicographic order)."""
    var v_vs_mn = _cmp_bytes(v, mn)
    var v_vs_mx = _cmp_bytes(v, mx)
    if op == BIN_EQ:
        return v_vs_mn >= 0 and v_vs_mx <= 0
    elif op == BIN_NE:
        return not (v_vs_mn == 0 and v_vs_mx == 0)
    elif op == BIN_LT:
        return v_vs_mn > 0
    elif op == BIN_LE:
        return v_vs_mn >= 0
    elif op == BIN_GT:
        return v_vs_mx < 0
    elif op == BIN_GE:
        return v_vs_mx <= 0
    return True


# =============================================================================
# Column resolution
# =============================================================================


@fieldwise_init
struct _Leaf(Copyable, Movable, ImplicitlyCopyable):
    """A resolved top-level leaf: its column chunk index and its schema
    element index. `leaf < 0` when the name did not resolve."""

    var leaf: Int
    var element: Int


def _leaf_by_name(metadata: FileMetaData, name: String) -> _Leaf:
    """The top-level leaf named `name`; see the module header."""
    var n = len(metadata.schema)
    if n == 0:
        return _Leaf(-1, -1)
    # Children still to come of each open group, innermost last.
    var open_groups = List[Int]()
    open_groups.append(metadata.schema[0].num_children)
    var leaf = 0
    for i in range(1, n):
        while len(open_groups) > 0 and open_groups[len(open_groups) - 1] <= 0:
            _ = open_groups.pop()
        var depth = len(open_groups)
        if depth > 0:
            open_groups[depth - 1] -= 1
        ref element = metadata.schema[i]
        if element.num_children > 0:
            open_groups.append(element.num_children)
        else:
            if depth == 1 and element.name == name:
                return _Leaf(leaf, i)
            leaf += 1
    return _Leaf(-1, -1)


def _converted_type(metadata: FileMetaData, element: Int) -> Int:
    """The ConvertedType annotation of schema element `element`, or -1.

    The annotation is the only place a column's signedness is written:
    UINT_64 shares physical INT64 with its signed twin, UINT_32 shares
    INT32. Arrow writers write it beside the LogicalType, and the reader's
    Arrow type mapping keys on it too.
    """
    if element < 0 or element >= len(metadata.schema):
        return -1
    ref elem = metadata.schema[element]
    if not elem.converted_type:
        return -1
    return elem.converted_type.value()


def _is_decimal(metadata: FileMetaData, element: Int) -> Bool:
    """A DECIMAL leaf: its statistics are unscaled integers."""
    if element < 0 or element >= len(metadata.schema):
        return False
    ref elem = metadata.schema[element]
    return _converted_type(metadata, element) == CONVERTED_TYPE_DECIMAL or Bool(elem.scale)


def _stats_of(rg: RowGroup, leaf: Int) -> Optional[Statistics]:
    if leaf < 0 or leaf >= len(rg.columns):
        return None
    ref chunk_meta = rg.columns[leaf].meta_data
    if not chunk_meta.statistics:
        return None
    return chunk_meta.statistics.value().copy()


@always_inline
def _swap_op(op: UInt8) -> UInt8:
    """`lit op col` as `col op' lit`."""
    if op == BIN_LT:
        return BIN_GT
    if op == BIN_LE:
        return BIN_GE
    if op == BIN_GT:
        return BIN_LT
    if op == BIN_GE:
        return BIN_LE
    return op


@always_inline
def _is_comparison(op: UInt8) -> Bool:
    return op == BIN_EQ or op == BIN_NE or op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE


# =============================================================================
# One comparison against one row group's statistics
# =============================================================================


def _eval_comparison_rg(
    rg: RowGroup,
    metadata: FileMetaData,
    col_name: String,
    op: UInt8,
    value: ScalarValue,
) -> Bool:
    """True if the row group might hold a row matching `col op value`."""
    var resolved = _leaf_by_name(metadata, col_name)
    if resolved.leaf < 0 or _is_decimal(metadata, resolved.element):
        return True
    var stats_opt = _stats_of(rg, resolved.leaf)
    if not stats_opt:
        return True
    ref stats = stats_opt.value()
    # min_value/max_value carry the column's sort order; the legacy min/max
    # may not, and are not read.
    if not stats.min_value or not stats.max_value:
        return True

    var physical = rg.columns[resolved.leaf].meta_data.type
    var conv = _converted_type(metadata, resolved.element)

    if physical == ParquetType.INT64:
        if not value.is_int():
            return True
        if conv == CONVERTED_TYPE_UINT_64:
            var umn = _decode_le_u64(stats.min_value.value())
            var umx = _decode_le_u64(stats.max_value.value())
            if not umn or not umx:
                return True
            return _can_match_u64(op, value.int_val, umn.value(), umx.value())
        var mn = _decode_le_i64(stats.min_value.value())
        var mx = _decode_le_i64(stats.max_value.value())
        if not mn or not mx:
            return True
        return _can_match_i64(op, value.int_val, mn.value(), mx.value())

    if physical == ParquetType.INT32:
        if not value.is_int():
            return True
        var mn = _decode_le_i32(stats.min_value.value())
        var mx = _decode_le_i32(stats.max_value.value())
        if not mn or not mx:
            return True
        # UINT_32: zero-extend both bounds; Int64 holds the whole UInt32
        # domain. UINT_8 and UINT_16 cannot reach INT32's sign bit.
        if conv == CONVERTED_TYPE_UINT_32:
            return _can_match_i64(
                op,
                value.int_val,
                Int64(Int(bitcast[DType.uint32](mn.value()))),
                Int64(Int(bitcast[DType.uint32](mx.value()))),
            )
        return _can_match_i64(op, value.int_val, Int64(mn.value()), Int64(mx.value()))

    if physical == ParquetType.DOUBLE:
        if not value.is_float():
            return True
        var mn = _decode_le_f64(stats.min_value.value())
        var mx = _decode_le_f64(stats.max_value.value())
        if not mn or not mx:
            return True
        return _can_match_f64(op, value.float_val, mn.value(), mx.value())

    if physical == ParquetType.FLOAT:
        if not value.is_float():
            return True
        var mn = _decode_le_f32(stats.min_value.value())
        var mx = _decode_le_f32(stats.max_value.value())
        if not mn or not mx:
            return True
        return _can_match_f64(op, value.float_val, Float64(mn.value()), Float64(mx.value()))

    if physical == ParquetType.BYTE_ARRAY:
        if not value.is_string():
            return True
        return _can_match_bytes(
            op,
            value.string_val.as_bytes(),
            Span(stats.min_value.value()),
            Span(stats.max_value.value()),
        )

    return True


# =============================================================================
# The expression walk
# =============================================================================


def _can_match_rg(rg: RowGroup, metadata: FileMetaData, expr: Expr) -> Bool:
    """True if the row group might hold a matching row; False only when the
    statistics prove none does."""
    if expr.tag != EXPR_BINARY_OP:
        return True
    var op = expr.binary_op()
    if op == BIN_AND:
        if not _can_match_rg(rg, metadata, expr.binary_left_ref()):
            return False
        return _can_match_rg(rg, metadata, expr.binary_right_ref())
    if op == BIN_OR:
        if _can_match_rg(rg, metadata, expr.binary_left_ref()):
            return True
        return _can_match_rg(rg, metadata, expr.binary_right_ref())
    if not _is_comparison(op):
        return True
    ref left = expr.binary_left_ref()
    ref right = expr.binary_right_ref()
    if left.tag == EXPR_COL_REF and right.tag == EXPR_LITERAL:
        return _eval_comparison_rg(rg, metadata, left.col_ref_name(), op, right.literal_value())
    if right.tag == EXPR_COL_REF and left.tag == EXPR_LITERAL:
        return _eval_comparison_rg(rg, metadata, right.col_ref_name(), _swap_op(op), left.literal_value())
    return True


def can_prune_row_group(rg: RowGroup, metadata: FileMetaData, filter: Expr) -> Bool:
    """True if the row group's statistics prove no row satisfies `filter`,
    so the caller can skip it; False on any ambiguity. Reads only its
    arguments, so concurrent calls are safe."""
    return not _can_match_rg(rg, metadata, filter)


# =============================================================================
# ALL-MATCH: the dual of the pruner
# =============================================================================
#
# `can_prune_row_group` proves no row matches. The dual proves every row
# matches, so `count(*) WHERE p` can add `num_rows` without decoding.
#
# The null trap: every supported comparison rejects NULL (a NULL satisfies
# none of them), and min/max exclude nulls, so a range that satisfies the
# comparison says nothing about null rows. All-match therefore requires
# `null_count` present and 0, at every comparison leaf.
#
# The safe answer here is False ("cannot prove it; decode"). A wrong True
# miscounts. Types: INT64 and INT32 only. FLOAT and DOUBLE are declined
# (statistics exclude NaN, and NaN fails every comparison); BYTE_ARRAY and
# BOOLEAN are not handled.


@always_inline
def _all_match_i64(op: UInt8, v: Int64, mn: Int64, mx: Int64) -> Bool:
    """Does every value in [mn, mx] satisfy `row op v`?"""
    if op == BIN_EQ:
        return mn == v and mx == v
    elif op == BIN_NE:
        return v < mn or v > mx
    elif op == BIN_LT:
        return mx < v
    elif op == BIN_LE:
        return mx <= v
    elif op == BIN_GT:
        return mn > v
    elif op == BIN_GE:
        return mn >= v
    return False


@always_inline
def _all_match_u64(op: UInt8, v: Int64, mn: UInt64, mx: UInt64) -> Bool:
    """`_all_match_i64` over an UNSIGNED range; a negative literal is below
    every value, as in `_can_match_u64`."""
    if v < 0:
        return op == BIN_NE or op == BIN_GT or op == BIN_GE
    var u = UInt64(v)
    if op == BIN_EQ:
        return mn == u and mx == u
    elif op == BIN_NE:
        return u < mn or u > mx
    elif op == BIN_LT:
        return mx < u
    elif op == BIN_LE:
        return mx <= u
    elif op == BIN_GT:
        return mn > u
    elif op == BIN_GE:
        return mn >= u
    return False


def _eval_all_match_comparison_rg(
    rg: RowGroup,
    metadata: FileMetaData,
    col_name: String,
    op: UInt8,
    value: ScalarValue,
) -> Bool:
    """True iff the statistics prove every row satisfies `col op value`."""
    var resolved = _leaf_by_name(metadata, col_name)
    if resolved.leaf < 0 or _is_decimal(metadata, resolved.element):
        return False
    var stats_opt = _stats_of(rg, resolved.leaf)
    if not stats_opt:
        return False
    ref stats = stats_opt.value()
    if not stats.null_count or stats.null_count.value() != 0:
        return False
    if not stats.min_value or not stats.max_value:
        return False
    if not value.is_int():
        return False

    var physical = rg.columns[resolved.leaf].meta_data.type
    var conv = _converted_type(metadata, resolved.element)

    if physical == ParquetType.INT64:
        if conv == CONVERTED_TYPE_UINT_64:
            var umn = _decode_le_u64(stats.min_value.value())
            var umx = _decode_le_u64(stats.max_value.value())
            if not umn or not umx:
                return False
            return _all_match_u64(op, value.int_val, umn.value(), umx.value())
        var mn = _decode_le_i64(stats.min_value.value())
        var mx = _decode_le_i64(stats.max_value.value())
        if not mn or not mx:
            return False
        return _all_match_i64(op, value.int_val, mn.value(), mx.value())

    if physical == ParquetType.INT32:
        var mn = _decode_le_i32(stats.min_value.value())
        var mx = _decode_le_i32(stats.max_value.value())
        if not mn or not mx:
            return False
        if conv == CONVERTED_TYPE_UINT_32:
            return _all_match_i64(
                op,
                value.int_val,
                Int64(Int(bitcast[DType.uint32](mn.value()))),
                Int64(Int(bitcast[DType.uint32](mx.value()))),
            )
        return _all_match_i64(op, value.int_val, Int64(mn.value()), Int64(mx.value()))

    return False


def _all_match_rg(rg: RowGroup, metadata: FileMetaData, expr: Expr) -> Bool:
    """True iff the statistics prove `expr` is true for every row.

    AND: both sides all-match. OR: either side all-match (sound, not
    complete). Anything else, NOT included: False.
    """
    if expr.tag != EXPR_BINARY_OP:
        return False
    var op = expr.binary_op()
    if op == BIN_AND:
        if not _all_match_rg(rg, metadata, expr.binary_left_ref()):
            return False
        return _all_match_rg(rg, metadata, expr.binary_right_ref())
    if op == BIN_OR:
        if _all_match_rg(rg, metadata, expr.binary_left_ref()):
            return True
        return _all_match_rg(rg, metadata, expr.binary_right_ref())
    if not _is_comparison(op):
        return False
    ref left = expr.binary_left_ref()
    ref right = expr.binary_right_ref()
    if left.tag == EXPR_COL_REF and right.tag == EXPR_LITERAL:
        return _eval_all_match_comparison_rg(rg, metadata, left.col_ref_name(), op, right.literal_value())
    if right.tag == EXPR_COL_REF and left.tag == EXPR_LITERAL:
        return _eval_all_match_comparison_rg(rg, metadata, right.col_ref_name(), _swap_op(op), left.literal_value())
    return False


def rg_all_match_row_group(rg: RowGroup, metadata: FileMetaData, filter: Expr) -> Bool:
    """True iff the row group's statistics prove every row satisfies
    `filter`; False on any ambiguity (a wrong True would miscount). Reads
    only its arguments, so concurrent calls are safe."""
    return _all_match_rg(rg, metadata, filter)


def all_match_row_count(metadata: FileMetaData, filter: Expr) -> Optional[Int]:
    """`count(*) WHERE filter` from statistics alone, when every row group is
    decided: each one is either all-match (adds `num_rows`) or pruned (adds
    0). None if any row group is neither, and must be decoded to count."""
    var total = 0
    for r in range(len(metadata.row_groups)):
        ref rg = metadata.row_groups[r]
        if rg_all_match_row_group(rg, metadata, filter):
            total += rg.num_rows
        elif not can_prune_row_group(rg, metadata, filter):
            return None
    return total
