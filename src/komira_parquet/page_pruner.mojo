# =============================================================================
# page_pruner — the pages of a row group a filter can skip
# =============================================================================
#
# From a filter `Expr` and the page indexes of the columns it compares,
# `select_pages_for_unit` gives, per column, the data pages that may hold a
# matching row (`PageSelection`), in two layers:
#
#   * `evaluate_page_filter(filter, bundle)`: pure. `bundle` holds the
#     parsed indexes by column name; each column's picks come from a walk
#     of the filter: a `col op literal` leaf on that column (either way
#     round, op one of =, <, <=, >, >=) keeps the pages whose [min, max] can
#     hold a matching value; AND intersects, OR unites; any other node
#     (another column, !=, NOT, a cast, a non-integer literal, ...) keeps
#     every page. A column whose picks are every page is "all pass" (read
#     whole); a column with no pick proves the row group holds no match
#     under the filter (`is_pruned_empty`).
#   * `select_pages_for_unit(cache, reader, path, metadata, rg, filter)`:
#     finds the compared columns (top-level leaves by name, as
#     `rg_pruner` resolves them), reads their indexes through the
#     `ParquetPageIndexCache`, and calls the pure layer.
#
# What may be pruned, and why nothing else is:
#   * INT64 columns only: the parser reads min/max as signed Int64. A
#     UINT_64 column shares the physical type but not the order (a value
#     above Int64.MAX reads negative), and a DECIMAL column's statistics are
#     unscaled integers a literal is not compared in: both are skipped, as
#     are columns without a page index.
#   * A page whose min or max was not written (`ColumnIndex.has_bounds`) is
#     always kept; an all-null page is never kept for a comparison (NULL
#     matches no comparison).
# Skipping a column only ever reads more: an unsupported shape degrades to
# a whole-column read, never to a dropped row.
# =============================================================================

from komira_fs.file_system import FileSystem
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import CONVERTED_TYPE_UINT_64, ParquetType
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

from .file_reader import ParquetFileReader
from .page_index import ColumnIndex, OffsetIndex
from .page_index_cache import ParquetPageIndexCache, get_or_parse_indexes_copy
from .rg_pruner import _converted_type, _is_decimal, _leaf_by_name


struct PageSelection(Copyable, Movable):
    """One column's surviving pages: `picks` ascending, or every page when
    `is_all_pass` (then `picks` is empty and ignored)."""

    var col_name: String
    var col_idx: Int
    var num_pages: Int
    var picks: List[Int]
    var is_all_pass: Bool

    def __init__(
        out self,
        var col_name: String,
        col_idx: Int,
        num_pages: Int,
        var picks: List[Int],
        is_all_pass: Bool,
    ):
        self.col_name = col_name^
        self.col_idx = col_idx
        self.num_pages = num_pages
        self.picks = picks^
        self.is_all_pass = is_all_pass

    @staticmethod
    def all_pass(col_name: String, col_idx: Int, num_pages: Int) -> Self:
        return Self(col_name, col_idx, num_pages, List[Int](), True)

    @staticmethod
    def from_picks(
        col_name: String, col_idx: Int, num_pages: Int, var picks: List[Int]
    ) -> Self:
        return Self(col_name, col_idx, num_pages, picks^, False)


struct PageSelectionSet(Copyable, Movable):
    """The selections of one row group, one per pruned column (a column
    without an entry is read whole). `is_pruned_empty`: some column kept no
    page, so no row of the row group matches."""

    var entries: List[PageSelection]
    var is_pruned_empty: Bool

    def __init__(out self, var entries: List[PageSelection], is_pruned_empty: Bool):
        self.entries = entries^
        self.is_pruned_empty = is_pruned_empty

    def __init__(out self):
        """No pruned column."""
        self.entries = List[PageSelection]()
        self.is_pruned_empty = False

    def find(self, col_name: String) -> Int:
        """The entry of `col_name`, or -1."""
        for i in range(len(self.entries)):
            if self.entries[i].col_name == col_name:
                return i
        return -1


@fieldwise_init
struct _BundleEntry(Copyable, Movable):
    var col_name: String
    var col_idx: Int
    var column_index: ColumnIndex
    var offset_index: OffsetIndex


struct PageIndexBundle(Movable):
    """Parsed page indexes by column name: the pure layer's input."""

    var _entries: List[_BundleEntry]

    def __init__(out self):
        self._entries = List[_BundleEntry]()

    def add(
        mut self,
        var col_name: String,
        col_idx: Int,
        var column_index: ColumnIndex,
        var offset_index: OffsetIndex,
    ):
        self._entries.append(
            _BundleEntry(col_name^, col_idx, column_index^, offset_index^)
        )

    def find_idx(self, col_name: String) -> Int:
        for i in range(len(self._entries)):
            if self._entries[i].col_name == col_name:
                return i
        return -1

    def size(self) -> Int:
        return len(self._entries)

    def col_idx_at(self, i: Int) -> Int:
        return self._entries[i].col_idx

    def name_at(self, i: Int) -> String:
        return self._entries[i].col_name

    def num_pages_at(self, i: Int) -> Int:
        return self._entries[i].column_index.num_pages


def _select_pages_int64_range(ci: ColumnIndex, lo: Int64, hi: Int64) -> List[Int]:
    """Pages that may hold a value in [lo, hi]: not all-null, and either
    without written bounds or with [min, max] meeting [lo, hi]."""
    var picks = List[Int]()
    for i in range(ci.num_pages):
        if ci.null_pages[i]:
            continue
        if not ci.page_has_bounds(i):
            picks.append(i)
            continue
        if ci.max_values_int64[i] < lo or ci.min_values_int64[i] > hi:
            continue
        picks.append(i)
    return picks^


def _intersect_sorted(a: List[Int], b: List[Int]) -> List[Int]:
    var out = List[Int]()
    var i = 0
    var j = 0
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            out.append(a[i])
            i += 1
            j += 1
        elif a[i] < b[j]:
            i += 1
        else:
            j += 1
    return out^


def _union_sorted(a: List[Int], b: List[Int]) -> List[Int]:
    var out = List[Int]()
    var i = 0
    var j = 0
    while i < len(a) or j < len(b):
        if j >= len(b) or (i < len(a) and a[i] < b[j]):
            out.append(a[i])
            i += 1
        elif i >= len(a) or b[j] < a[i]:
            out.append(b[j])
            j += 1
        else:
            out.append(a[i])
            i += 1
            j += 1
    return out^


def _all_pages(num_pages: Int) -> List[Int]:
    var out = List[Int](capacity=num_pages)
    for i in range(num_pages):
        out.append(i)
    return out^


def _picks_for_int64_compare(ci: ColumnIndex, op: UInt8, lit: Int64) -> List[Int]:
    """The pages a `col op lit` leaf keeps, on an INT64 column."""
    if not ci.has_int64_stats():
        return _all_pages(ci.num_pages)
    if op == BIN_EQ:
        return _select_pages_int64_range(ci, lit, lit)
    if op == BIN_LE:
        return _select_pages_int64_range(ci, Int64.MIN, lit)
    if op == BIN_LT:
        if lit == Int64.MIN:
            return List[Int]()
        return _select_pages_int64_range(ci, Int64.MIN, lit - 1)
    if op == BIN_GE:
        return _select_pages_int64_range(ci, lit, Int64.MAX)
    if op == BIN_GT:
        if lit == Int64.MAX:
            return List[Int]()
        return _select_pages_int64_range(ci, lit + 1, Int64.MAX)
    return _all_pages(ci.num_pages)


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


def _is_comparison(op: UInt8) -> Bool:
    return (
        op == BIN_EQ
        or op == BIN_NE
        or op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
    )


def _picks_for_column_in_expr(
    expr: Expr, col_name: String, entry: Int, bundle: PageIndexBundle
) -> List[Int]:
    """The pages of bundle entry `entry` (column `col_name`) `expr` keeps."""
    var num_pages = bundle.num_pages_at(entry)
    if expr.tag != EXPR_BINARY_OP:
        return _all_pages(num_pages)
    var op = expr.binary_op()
    if op == BIN_AND or op == BIN_OR:
        var l = _picks_for_column_in_expr(expr.binary_left_ref(), col_name, entry, bundle)
        var r = _picks_for_column_in_expr(expr.binary_right_ref(), col_name, entry, bundle)
        if op == BIN_AND:
            return _intersect_sorted(l, r)
        return _union_sorted(l, r)
    if not _is_comparison(op):
        return _all_pages(num_pages)
    ref left = expr.binary_left_ref()
    ref right = expr.binary_right_ref()
    if left.tag == EXPR_COL_REF and right.tag == EXPR_LITERAL:
        if left.col_ref_name() != col_name:
            return _all_pages(num_pages)
        var lit = right.literal_value()
        if not lit.is_int():
            return _all_pages(num_pages)
        return _picks_for_int64_compare(bundle._entries[entry].column_index, op, Int64(lit.int_val))
    if right.tag == EXPR_COL_REF and left.tag == EXPR_LITERAL:
        if right.col_ref_name() != col_name:
            return _all_pages(num_pages)
        var lit = left.literal_value()
        if not lit.is_int():
            return _all_pages(num_pages)
        return _picks_for_int64_compare(
            bundle._entries[entry].column_index, _swap_op(op), Int64(lit.int_val)
        )
    return _all_pages(num_pages)


def evaluate_page_filter(filter: Expr, bundle: PageIndexBundle) -> PageSelectionSet:
    """Each bundled column's surviving pages under `filter` (no I/O)."""
    var entries = List[PageSelection]()
    var any_empty = False
    for i in range(bundle.size()):
        var num_pages = bundle.num_pages_at(i)
        if num_pages == 0:
            # No page to judge by: no entry, so the column is read whole
            # and a chunk whose indexes list no pages never prunes the group.
            continue
        var name = bundle.name_at(i)
        var col_idx = bundle.col_idx_at(i)
        var picks = _picks_for_column_in_expr(filter, name, i, bundle)
        if len(picks) == num_pages:
            entries.append(PageSelection.all_pass(name, col_idx, num_pages))
        else:
            if len(picks) == 0:
                any_empty = True
            entries.append(PageSelection.from_picks(name, col_idx, num_pages, picks^))
    return PageSelectionSet(entries^, any_empty)


def _collect_predicate_columns(expr: Expr, mut out: List[String]):
    """The distinct column names of `filter`'s `col op literal` leaves
    under AND / OR."""
    if expr.tag != EXPR_BINARY_OP:
        return
    var op = expr.binary_op()
    if op == BIN_AND or op == BIN_OR:
        _collect_predicate_columns(expr.binary_left_ref(), out)
        _collect_predicate_columns(expr.binary_right_ref(), out)
        return
    if not _is_comparison(op):
        return
    ref l = expr.binary_left_ref()
    ref r = expr.binary_right_ref()
    var name: String
    if l.tag == EXPR_COL_REF and r.tag == EXPR_LITERAL:
        name = l.col_ref_name()
    elif r.tag == EXPR_COL_REF and l.tag == EXPR_LITERAL:
        name = r.col_ref_name()
    else:
        return
    for i in range(len(out)):
        if out[i] == name:
            return
    out.append(name^)


def select_pages_for_unit[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    metadata: FileMetaData,
    rg_idx: Int,
    filter: Expr,
) raises -> PageSelectionSet:
    """The surviving pages of row group `rg_idx` under `filter`, for each
    compared column that can be pruned (see the module header); the page
    indexes are read through `cache`.

    Raises:
        Error if `rg_idx` is out of range or a page index does not parse.
    """
    if rg_idx < 0 or rg_idx >= len(metadata.row_groups):
        raise Error(
            "select_pages_for_unit: row group "
            + String(rg_idx)
            + " is out of range"
        )
    ref rg = metadata.row_groups[rg_idx]
    var pred_cols = List[String]()
    _collect_predicate_columns(filter, pred_cols)
    var bundle = PageIndexBundle()
    for i in range(len(pred_cols)):
        var leaf = _leaf_by_name(metadata, pred_cols[i])
        if leaf.leaf < 0 or leaf.leaf >= len(rg.columns):
            continue
        ref cc = rg.columns[leaf.leaf]
        if (
            not cc.column_index_offset
            or not cc.column_index_length
            or not cc.offset_index_offset
            or not cc.offset_index_length
            or cc.column_index_length.value() <= 0
            or cc.offset_index_length.value() <= 0
        ):
            continue
        if cc.meta_data.type != ParquetType.INT64:
            continue
        if _converted_type(metadata, leaf.element) == CONVERTED_TYPE_UINT_64:
            continue
        if _is_decimal(metadata, leaf.element):
            continue
        var parsed = get_or_parse_indexes_copy(
            cache,
            reader,
            path,
            rg_idx,
            leaf.leaf,
            cc.column_index_offset.value(),
            cc.column_index_length.value(),
            cc.offset_index_offset.value(),
            cc.offset_index_length.value(),
        )
        bundle.add(
            pred_cols[i],
            leaf.leaf,
            parsed.take_column_index(),
            parsed.take_offset_index(),
        )
    return evaluate_page_filter(filter, bundle)
