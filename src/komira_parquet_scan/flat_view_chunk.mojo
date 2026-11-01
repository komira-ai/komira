# =============================================================================
# flat_view_chunk — one PLAIN column read a grain at a time, in place in its
# decoded page
# =============================================================================
#
# `FlatViewChunk` owns a `ResumableColumnCursor` over a PLAIN fixed-width
# column chunk. Each `fill_next_grain` exposes the next up to `grain` values
# of the page the cursor has decoded into its own scratch; the reader reads
# them there (`FlatViewChunkView.load`), with no copy into another buffer.
# A grain never crosses a page, so the values stay put until the next pull,
# and each page is decoded once however many grains read it
# (`page_decompress_count`).
#
# The chunk owns the cursor (behind an `OwnedPointer`, at a stable address),
# so the page bytes are the chunk's. A `FlatViewChunkView[origin]` borrows the
# chunk and re-reads through it on every call, so the borrow checker keeps
# the view from outliving the chunk; the generation it was taken at tells a
# view that outlived a pull (`is_valid`).
#
# The cursor refuses what it cannot read in place (a dictionary chunk, a
# DELTA_BINARY_PACKED chunk, an actual null): `supported()` turns False and
# `fill_next_grain` returns 0.
# =============================================================================

from std.memory import OwnedPointer, Pointer

from komira_parquet.subrg_column_cursor import ResumableColumnCursor


struct FlatViewChunk(Movable, Deinitable):
    """One PLAIN column, a grain at a time, in place.

    Fields:
        _cursor: the owned cursor; its scratch holds the decoded page.
        grain: the most rows one pull exposes (at least 1).
        generation: bumped on every pull.
        _cur_n: the rows of the current grain.
    """

    var _cursor: OwnedPointer[ResumableColumnCursor]
    var grain: Int
    var generation: UInt64
    var _cur_n: Int

    def __init__(out self, var cursor: ResumableColumnCursor, grain: Int):
        """Take an opened PLAIN cursor."""
        self._cursor = OwnedPointer(cursor^)
        self.grain = grain if grain > 0 else 1
        self.generation = 0
        self._cur_n = 0

    def fill_next_grain(mut self) raises -> Int:
        """Expose the next grain and return its rows (0 once the column is
        drained or refused). Views taken before are stale afterwards."""
        self.generation += 1
        self._cur_n = self._cursor[].open_next_plain_grain(self.grain)
        return self._cur_n

    @always_inline
    def cur_rows(self) -> Int:
        """The rows of the current grain."""
        return self._cur_n

    @always_inline
    def gen(self) -> UInt64:
        """The current generation."""
        return self.generation

    @always_inline
    def supported(self) -> Bool:
        """False once the cursor refused the chunk or a page."""
        return self._cursor[].supported()

    def num_values(self) -> Int:
        """The column's row count the footer gives this chunk."""
        return self._cursor[].num_values()

    def rows_emitted(self) -> Int:
        """The rows exposed so far. A pull that returns 0 with `supported()`
        and `rows_emitted() < num_values()` is a chunk whose bytes ended
        early, not a drained one."""
        return self._cursor[].rows_emitted()

    def page_decompress_count(self) -> Int:
        """Pages the cursor decoded so far: one per page, not per grain."""
        return self._cursor[].page_decompress_count()

    @always_inline
    def _load[dt: DType, W: Int](self, row_i: Int) -> SIMD[dt, W]:
        return self._cursor[].load_grain[dt, W](row_i)


struct FlatViewChunkView[origin: Origin[mut=False]](Copyable, Movable, ImplicitlyCopyable):
    """A borrow of a `FlatViewChunk`'s current grain, stamped with the
    generation it was taken at."""

    var _chunk: Pointer[FlatViewChunk, Self.origin]
    var _gen: UInt64

    @always_inline
    def __init__(out self, ref [Self.origin] chunk: FlatViewChunk):
        self._chunk = Pointer(to=chunk)
        self._gen = chunk.generation

    @always_inline
    def n_rows(self) -> Int:
        """The rows of the grain."""
        return self._chunk[]._cur_n

    @always_inline
    def is_valid(self) -> Bool:
        """False once the chunk pulled another grain."""
        return self._gen == self._chunk[].generation

    @always_inline
    def load[dt: DType, W: Int](self, row_i: Int) -> SIMD[dt, W]:
        """`W` values of `dt` at grain row `row_i`, read in the decoded page.
        `dt` must have the column's physical width and `row_i + W` must not
        pass the grain."""
        return self._chunk[]._load[dt, W](row_i)

    @always_inline
    def load_f64(self, row_i: Int) -> Float64:
        """The DOUBLE at grain row `row_i`."""
        return self.load[DType.float64, 1](row_i)[0]


@always_inline
def flat_view_over[o: Origin[mut=False]](ref [o] chunk: FlatViewChunk) -> FlatViewChunkView[o]:
    """A view of `chunk`'s current grain."""
    return FlatViewChunkView[o](chunk)
