# =============================================================================
# code_view_chunk — one dictionary column's codes, a grain at a time, in a
# small reused buffer
# =============================================================================
#
# The dictionary sibling of `flat_view_chunk`. RLE_DICTIONARY codes are run
# length / bit packed, so they cannot be read in place: each pull unpacks up
# to `grain` int32 codes into the chunk's own codes buffer (the grain plus
# `SUBRG_MAX_RUN` slots of headroom for a bit-packed run's tail), reused by
# every pull. The reader resolves or hashes the codes against the row group's
# dictionary (`dict_i64_copy`, `dict_f64_copy`), taken once.
#
# Several key columns stay row aligned: the driver pulls a grain
# (`open_next_codes_grain`), every other chunk fills exactly that many codes
# (`fill_codes_at`, looped until it has them) and then exposes them
# (`set_grain_n`).
#
# The chunk owns the cursor and the codes buffer; a `CodeViewChunkView`
# borrows the chunk and carries the generation it was taken at, as
# `FlatViewChunkView` does.
# =============================================================================

from std.memory import OwnedPointer, Pointer

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN


struct CodeViewChunk(Movable, Deinitable):
    """One dictionary column's codes, a grain at a time.

    Fields:
        _cursor: the owned dictionary cursor.
        _codes: the reused codes buffer, `(grain + SUBRG_MAX_RUN) * 4` bytes
            and some slack.
        grain: the most codes one pull exposes (at least 1).
        generation: bumped on every pull and `set_grain_n`.
        _cur_n: the codes of the current grain.
    """

    var _cursor: OwnedPointer[ResumableColumnCursor]
    var _codes: OwnedAlignedBuffer
    var grain: Int
    var generation: UInt64
    var _cur_n: Int

    def __init__(out self, var cursor: ResumableColumnCursor, grain: Int):
        """Take an opened dictionary cursor."""
        self._cursor = OwnedPointer(cursor^)
        self.grain = grain if grain > 0 else 1
        self._codes = OwnedAlignedBuffer((self.grain + SUBRG_MAX_RUN) * 4 + 64)
        self.generation = 0
        self._cur_n = 0

    def open_next_codes_grain(mut self) raises -> Int:
        """Unpack the next up to `grain` codes and return how many (0 once
        drained or refused). Views taken before are stale afterwards."""
        self.generation += 1
        self._cur_n = self._cursor[].fill_next_codes(self._codes, self.grain)
        return self._cur_n

    def fill_codes_at(mut self, n_rows: Int, dst_off: Int) raises -> Int:
        """Unpack up to `n_rows` codes from code slot `dst_off`, for a
        non-driver key; returns how many. `dst_off + n_rows` must not pass
        `grain`."""
        return self._cursor[].fill_next_codes_at(self._codes, n_rows, dst_off)

    @always_inline
    def set_grain_n(mut self, n: Int):
        """Expose the first `n` filled codes as the grain."""
        self.generation += 1
        self._cur_n = n

    @always_inline
    def _load_code[W: Int](self, i: Int) -> SIMD[DType.int32, W]:
        return self._codes.load_simd[DType.int32, W](i * 4)

    @always_inline
    def cur_rows(self) -> Int:
        """The codes of the current grain."""
        return self._cur_n

    @always_inline
    def gen(self) -> UInt64:
        """The current generation."""
        return self.generation

    @always_inline
    def supported(self) -> Bool:
        """False once the cursor refused the chunk or a page."""
        return self._cursor[].supported()

    @always_inline
    def rows_emitted(self) -> Int:
        """Codes the cursor produced so far."""
        return self._cursor[].rows_emitted()

    @always_inline
    def num_values(self) -> Int:
        """The chunk's row count."""
        return self._cursor[].num_values()

    def dict_i64_copy(self) -> List[Int64]:
        """The INT32 / INT64 dictionary, widened to Int64, in code order."""
        return self._cursor[].dict_values_copy()

    def dict_f64_copy(self) -> List[Float64]:
        """The FLOAT / DOUBLE dictionary, widened to Float64, in code order."""
        return self._cursor[].dict_values_f64_copy()


struct CodeViewChunkView[origin: Origin[mut=False]](Copyable, Movable, ImplicitlyCopyable):
    """A borrow of a `CodeViewChunk`'s current grain, stamped with the
    generation it was taken at."""

    var _chunk: Pointer[CodeViewChunk, Self.origin]
    var _gen: UInt64

    @always_inline
    def __init__(out self, ref [Self.origin] chunk: CodeViewChunk):
        self._chunk = Pointer(to=chunk)
        self._gen = chunk.generation

    @always_inline
    def n_rows(self) -> Int:
        """The codes of the grain."""
        return self._chunk[]._cur_n

    @always_inline
    def is_valid(self) -> Bool:
        """False once the chunk pulled or set another grain."""
        return self._gen == self._chunk[].generation

    @always_inline
    def load_code[W: Int](self, i: Int) -> SIMD[DType.int32, W]:
        """`W` codes at grain slot `i`; `i + W` must not pass the grain."""
        return self._chunk[]._load_code[W](i)

    @always_inline
    def load_code_scalar(self, i: Int) -> Int32:
        """The code at grain slot `i`."""
        return self.load_code[1](i)[0]


@always_inline
def code_view_over[o: Origin[mut=False]](ref [o] chunk: CodeViewChunk) -> CodeViewChunkView[o]:
    """A view of `chunk`'s current grain."""
    return CodeViewChunkView[o](chunk)
