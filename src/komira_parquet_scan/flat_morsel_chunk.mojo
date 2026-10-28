# =============================================================================
# flat_morsel_chunk — several PLAIN columns read a row-aligned grain at a
# time, in place in their decoded pages, behind the MorselView seam
# =============================================================================
#
# `FlatMorselChunk` is the multi-column `flat_view_chunk`: it owns one cursor
# per projected column (PLAIN INT32, INT64, FLOAT or DOUBLE chunks of one row
# group) and each `fill_next_grain` exposes the same next rows of every
# column, read in place in each column's decoded page. Its view,
# `FlatMorselChunkView`, conforms to `komira_arrow.morsel_view.MorselView`, so
# any fold written over a `MorselView` (the one a `BatchView` feeds) reads
# the page bytes directly, with no copy into a batch.
#
# A grain never crosses a page in any column. A pull first asks every column
# how many rows its current page still holds (`ensure_plain_page`, which
# opens the next page only when the current one is drained and does not
# advance), takes the smallest of those and of `grain`, and only then
# advances every column by that many rows (`commit_plain_grain`). Columns
# with different page boundaries therefore stay row aligned, and each page
# is decoded once (`page_decompress_count`). When any column is drained or
# refused, the pull returns 0 and advances none: the chunk never exposes a
# grain some columns lack.
#
# Scope: the columns `supported()` admits. A dictionary chunk, a
# DELTA_BINARY_PACKED or other non-PLAIN chunk and an actual null are
# refused by the cursor (`supported()` turns False, the pull returns 0); the
# caller decodes such a row group another way. A null is met only in the page
# that holds it, so the grains of the pages before it have been exposed by
# then: a caller that cannot retract them checks the column's statistics
# first. The cursors a caller opens through `open_subrg_cursor` already refuse
# a timestamp and any annotation that relabels the type, and a caller checks
# `num_values(col)` against the row group's footer row count. A view carries
# no selection mask and no NULL.
#
# A fold must read column `idx` at its physical type (`col_dtype`): the page
# bytes are reinterpreted at whatever width the read names.
# =============================================================================

from std.memory import Pointer

from komira_arrow.morsel_view import MorselView
from komira_collections.slab import Slab
from komira_parquet.subrg_column_cursor import ResumableColumnCursor
from komira_parquet_api.types import ParquetType


def _ptype_dtype(ptype: ParquetType) -> DType:
    """The DType of a PLAIN fixed-width physical type."""
    if ptype == ParquetType.INT64:
        return DType.int64
    if ptype == ParquetType.DOUBLE:
        return DType.float64
    if ptype == ParquetType.FLOAT:
        return DType.float32
    return DType.int32


struct FlatMorselChunk(Movable, Deinitable):
    """Several PLAIN columns of one row group, a row-aligned grain at a time,
    in place.

    Fields:
        _cursors: the owned cursors, one per column, in projection order.
        _ncols: the column count.
        grain: the most rows one pull exposes (at least 1).
        generation: bumped on every pull that exposes a grain.
        _cur_n: the rows of the current grain.
    """

    var _cursors: Slab[ResumableColumnCursor]
    var _ncols: Int
    var grain: Int
    var generation: UInt64
    var _cur_n: Int

    def __init__(out self, var cursors: Slab[ResumableColumnCursor], grain: Int):
        """Take opened PLAIN cursors, one per column, in projection order."""
        self._ncols = len(cursors)
        self._cursors = cursors^
        self.grain = grain if grain > 0 else 1
        self.generation = 0
        self._cur_n = 0

    def supported(self) -> Bool:
        """True iff there is a column and every column is a supported PLAIN
        (not dictionary) INT32, INT64, FLOAT or DOUBLE chunk."""
        if self._ncols <= 0:
            return False
        for c in range(self._ncols):
            ref cur = self._cursors[c]
            if not cur.supported() or cur.is_dict():
                return False
            var pt = cur.value_ptype()
            if pt != ParquetType.INT32 and pt != ParquetType.INT64 and pt != ParquetType.FLOAT and pt != ParquetType.DOUBLE:
                return False
        return True

    def col_dtype(self, col: Int) -> DType:
        """The DType column `col` must be read at."""
        return _ptype_dtype(self._cursors[col].value_ptype())

    def num_values(self, col: Int) -> Int:
        """Column `col`'s row count in the row group."""
        return self._cursors[col].num_values()

    def rows_emitted(self, col: Int) -> Int:
        """The rows column `col` has exposed so far. A pull that returns 0
        with `supported()` and `rows_emitted(col) < num_values(col)` is a
        chunk whose bytes ended early, not a drained one."""
        return self._cursors[col].rows_emitted()

    def fill_next_grain(mut self) raises -> Int:
        """Expose the next row-aligned grain of every column and return its
        rows; 0, advancing no column, once any column is drained or refused.
        Views taken before a grain is exposed are stale afterwards."""
        if self._ncols <= 0:
            return 0
        var n = self.grain
        for c in range(self._ncols):
            var avail = self._cursors[c].ensure_plain_page()
            if avail <= 0:
                self.generation += 1
                self._cur_n = 0
                return 0
            n = min(n, avail)
        for c in range(self._ncols):
            self._cursors[c].commit_plain_grain(n)
        self.generation += 1
        self._cur_n = n
        return n

    @always_inline
    def cur_rows(self) -> Int:
        """The rows of the current grain."""
        return self._cur_n

    @always_inline
    def num_live_cols(self) -> Int:
        """The column count."""
        return self._ncols

    @always_inline
    def gen(self) -> UInt64:
        """The current generation."""
        return self.generation

    def page_decompress_count(self, col: Int) -> Int:
        """Pages column `col`'s cursor decoded so far: one per page, not per
        grain."""
        return self._cursors[col].page_decompress_count()

    @always_inline
    def _load[dt: DType, W: Int](self, col: Int, row: Int) -> SIMD[dt, W]:
        return self._cursors[col].load_grain[dt, W](row)


struct FlatMorselChunkView[origin: Origin[mut=False]](Copyable, Movable, ImplicitlyCopyable, MorselView):
    """A borrow of a `FlatMorselChunk`'s current grain as a `MorselView`,
    stamped with the generation it was taken at. No selection mask, no
    NULL."""

    var _chunk: Pointer[FlatMorselChunk, Self.origin]
    var _gen: UInt64

    @always_inline
    def __init__(out self, ref [Self.origin] chunk: FlatMorselChunk):
        self._chunk = Pointer(to=chunk)
        self._gen = chunk.generation

    @always_inline
    def is_valid(self) -> Bool:
        """False once the chunk exposed another grain."""
        return self._gen == self._chunk[].generation

    @always_inline
    def generation(self) -> UInt64:
        """The generation this view was taken at."""
        return self._gen

    @always_inline
    def n_rows(self) -> Int:
        return self._chunk[]._cur_n

    @always_inline
    def num_columns(self) -> Int:
        return self._chunk[]._ncols

    @always_inline
    def has_selection_mask(self) -> Bool:
        return False

    @always_inline
    def selection_mask_get(self, row: Int) raises -> Bool:
        return True

    @always_inline
    def col_is_null(self, idx: Int, row: Int) -> Bool:
        return False

    @always_inline
    def col_scalar[dt: DType](self, idx: Int, row: Int) raises -> Scalar[dt]:
        return self._chunk[]._load[dt, 1](idx, row)[0]

    @always_inline
    def col_scalar_nonraising[dt: DType](self, idx: Int, row: Int) -> Scalar[dt]:
        return self._chunk[]._load[dt, 1](idx, row)[0]

    @always_inline
    def col_scalar_simd[dt: DType, W: Int](self, idx: Int, i: Int) -> SIMD[dt, W]:
        return self._chunk[]._load[dt, W](idx, i)


@always_inline
def flat_morsel_view_over[o: Origin[mut=False]](ref [o] chunk: FlatMorselChunk) -> FlatMorselChunkView[o]:
    """A view of `chunk`'s current grain."""
    return FlatMorselChunkView[o](chunk)
