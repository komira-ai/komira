# =============================================================================
# PERF-CRITICAL: Row-group bloom-filter pruning for streaming Parquet scans
# =============================================================================
#
# Regression if removed: every selective EQ predicate with a bloom-eligible
#                        literal-EQ leaf pays a full row group read +
#                        decompress + decode even when the bloom would prove
#                        the row group cannot match.
# DuckDB equivalent:     DuckDB's parquet bloom-filter pushdown (see
#                        ParquetReader::InitializeColumnReaders +
#                        ParquetBloomFilterColumnReader).
#
# Contract:
# - `can_prune_row_group_by_bloom` returns True ONLY when the bloom filter
#   proves the RG cannot contain ANY row matching the pushed filter. The
#   caller skips the RG entirely.
# - Returns False on any ambiguity: no bloom on the column, bloom check
#   returns "possibly present", unsupported predicate shape, unsupported
#   column type. "Conservative false" means "decode the RG and let row-level
#   filter eval decide".
#
# Filter shapes handled:
# - col EQ literal (Int64) on a column with a bloom filter
# - col EQ literal (Int32: the spec hashes its 4 little-endian bytes)
# - col EQ literal (String / BYTE_ARRAY)
# - AND(a, b)  → prune if either child proves unsatisfiable (bloom miss)
# - OR(a, b)   → prune only if both children prove unsatisfiable
# - NOT / NE / LT / LE / GT / GE / arithmetic / other → conservative
#   (bloom filters CANNOT exclude range predicates — they are
#   single-value membership tests)
# =============================================================================

from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily
from komira_parquet.bloom_reader import (
    detect_hash_family,
    detect_hash_family_optional,
    load_bloom_filter,
)
from komira_fs.file_system import FileSystem
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet_api.metadata import (
    ColumnMetaData,
    FileMetaData,
    RowGroup,
)
from komira_parquet_api.types import ParquetType
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_OR,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Column resolution
# =============================================================================


@always_inline
def _col_idx_by_name(ref metadata: FileMetaData, name: String) -> Int:
    """Return the 0-based leaf column index of the top-level leaf named
    ``name``.

    ``schema[0]`` is the root group and the rest is the schema flattened
    depth first, so a group element is followed by its children. Only
    leaves (``num_children == 0``) have column chunks, and a row group's
    chunks are in leaf order. A group, or a leaf inside a group, is not a
    match. Returns -1 when the name is not found (triggers conservative
    fall-through in the caller: "no prune").
    """
    var n = len(metadata.schema)
    if n == 0:
        return -1
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
                return leaf
            leaf += 1
    return -1


# =============================================================================
# Per-column EQ bloom probe
# =============================================================================


def _bloom_can_match_eq[fs_o: FileSystem](
    ref file: ParquetFileReader[fs_o],
    column_meta: ColumnMetaData,
    ref value: ScalarValue,
    hash_family: HashFamily,
) -> Bool:
    """Run the bloom filter probe for `column_meta` against literal `value`.

    Args:
        file: Open parquet file reader.
        column_meta: Column chunk metadata (carries bloom offset + length).
        value: Literal value to probe.
        hash_family: Hash family the writer used (xxHash64, the spec's).

    Returns:
      - True if the bloom says "possibly present" OR the column has no
        bloom, an unsupported type combination, a load error, or the
        bloom is otherwise unusable — caller MUST decode the RG and
        evaluate at row level.
      - False ONLY if the bloom probe definitively says the value is
        not present in the column chunk.

    Lazy-loads the bloom on every call. There is no per-(RG, col)
    cache; bloom byte ranges are ~256B-32KB so one read per probe
    is acceptable.
    """
    var bf_opt: Optional[BloomFilter]
    try:
        bf_opt = load_bloom_filter(file, column_meta, hash_family)
    except _:
        # Corrupt / truncated bloom region: conservative — decode RG.
        return True
    if not bf_opt:
        return True

    # BloomFilter is Movable; we hold it locally for this single probe.
    var bf = bf_opt.value().copy()
    var physical = column_meta.type

    # INT64: direct probe.
    if physical == ParquetType.INT64:
        if not value.is_int():
            return True
        return bf.might_contain_int64(value.int_val)

    # INT32: the spec hashes the value's 4 little-endian bytes (plain
    # encoding), not its 8-byte widening. A literal outside Int32 cannot be
    # in the column, but stays conservative.
    if physical == ParquetType.INT32:
        if not value.is_int():
            return True
        var v = value.int_val
        if v < Int64(Int32.MIN) or v > Int64(Int32.MAX):
            return True
        var le = List[UInt8](capacity=4)
        for i in range(4):
            le.append(UInt8((v >> Int64(8 * i)) & 0xFF))
        return bf.might_contain_bytes(Span(le))

    # BYTE_ARRAY (UTF-8 strings): hash the byte sequence directly.
    if physical == ParquetType.BYTE_ARRAY:
        if not value.is_string():
            return True
        # The literal's UTF-8 bytes, borrowed from `value` for this call.
        return bf.might_contain_bytes(value.string_val.as_bytes())

    # FLOAT / DOUBLE / FLBA / INT96 / BOOLEAN: not supported.
    # parquet-format BloomFilter.md notes that floating-point types
    # should NOT have bloom filters (NaN equality semantics make it
    # ambiguous). BOOLEAN has range [0,1] so RG-stats prune is strictly
    # better. FLBA + INT96 are rare on equality predicates.
    return True


# =============================================================================
# Recursive Expr walk — the row-group statistics walk, for bloom EQ
# =============================================================================


def _can_match_rg_via_bloom[fs_o: FileSystem](
    ref file: ParquetFileReader[fs_o],
    ref rg: RowGroup,
    ref metadata: FileMetaData,
    ref expr: Expr,
    hash_family: HashFamily,
) -> Bool:
    """Return True if the row group MIGHT contain matching rows under
    bloom-filter evaluation of EQ leaves.

    Mirrors the row-group statistics pruner's walk but only fires on EQ
    leaves with a bloom filter present.
      - AND: skip if EITHER child proves unsatisfiable via bloom
      - OR:  skip only if BOTH children prove unsatisfiable
      - EQ leaf: bloom probe (col vs literal). False => prune.
      - Anything else: conservative (True).

    "Provably unsatisfiable" == this function returns False.
    """
    if expr.tag != EXPR_BINARY_OP:
        # Bloom only meaningful on `col EQ literal` shapes; everything
        # else falls through to caller for normal eval.
        return True

    var op = expr.binary_op()

    if op == BIN_AND:
        var l = _can_match_rg_via_bloom(
            file, rg, metadata, expr.binary_left_ref(), hash_family,
        )
        if not l:
            return False
        return _can_match_rg_via_bloom(
            file, rg, metadata, expr.binary_right_ref(), hash_family,
        )

    if op == BIN_OR:
        var l = _can_match_rg_via_bloom(
            file, rg, metadata, expr.binary_left_ref(), hash_family,
        )
        if l:
            return True
        return _can_match_rg_via_bloom(
            file, rg, metadata, expr.binary_right_ref(), hash_family,
        )

    if op != BIN_EQ:
        # Bloom filters are equality-membership only — they cannot
        # exclude range / inequality predicates.
        return True

    # EQ leaf: accept `col EQ literal` in either order.
    ref left_ref = expr.binary_left_ref()
    ref right_ref = expr.binary_right_ref()
    var left_tag = left_ref.tag
    var right_tag = right_ref.tag

    var col_name: String
    var lit: ScalarValue
    if left_tag == EXPR_COL_REF and right_tag == EXPR_LITERAL:
        col_name = left_ref.col_ref_name()
        lit = right_ref.literal_value()
    elif right_tag == EXPR_COL_REF and left_tag == EXPR_LITERAL:
        col_name = right_ref.col_ref_name()
        lit = left_ref.literal_value()
    else:
        # Non-literal / non-column comparison (e.g. col op col). Bloom
        # cannot prune cross-column equality.
        return True

    var col_idx = _col_idx_by_name(metadata, col_name)
    if col_idx < 0 or col_idx >= len(rg.columns):
        return True

    var column_meta = rg.columns[col_idx].meta_data.copy()
    # Cheap check: column has no bloom => bloom layer says "might match".
    if not column_meta.bloom_filter_offset:
        return True

    return _bloom_can_match_eq(file, column_meta, lit, hash_family)


# =============================================================================
# Public entry point
# =============================================================================


def can_prune_row_group_by_bloom[fs_o: FileSystem](
    ref file: ParquetFileReader[fs_o],
    rg: RowGroup,
    metadata: FileMetaData,
    ref filter: Expr,
    hash_family: HashFamily = HashFamily.xxhash64(),
) -> Bool:
    """Return True if the row group can be skipped entirely based on
    column-chunk bloom filters.

    Conservative: returns False on any ambiguity (missing bloom,
    unsupported filter shape, unknown type, unreadable bloom byte
    range). The caller must short-circuit BEFORE the per-row decode path.

    The bloom hash family is passed by the caller
    (`detect_hash_family(metadata.created_by)`: XXHASH64, the spec's).

    Args:
        file: Open parquet file reader.
        rg: Row group metadata.
        metadata: File metadata (used for schema -> column-index lookup).
        filter: The pushed_predicate (after RG-stats prune). (`rg` and
            `metadata` are READ-borrows rather than `ref` so a caller may
            pass the footer AND one of its own row groups.)
        hash_family: Hash family to use for bloom probes (default
            XXHASH64, spec-canonical).
    """
    return not _can_match_rg_via_bloom(
        file, rg, metadata, filter, hash_family,
    )
