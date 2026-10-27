# =============================================================================
# RecordBatchScanSource -- Produces morsels from a RecordBatch
# =============================================================================
#
# A scan source that splits a RecordBatch into morsels and yields them one at a
# time. It holds the whole dataset in memory and hands out cache-friendly
# chunks; each yielded morsel owns fresh copies of its column data.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap, copy_bits_aligned_buffer
from komira_buffer.heap_region import HeapRegion
from komira_buffer.constants import DEFAULT_MORSEL_ROWS
from komira_morsel.morsel import Morsel, MorselArray, split_record_batch


struct RecordBatchScanSource(Movable):
    """Produces morsels by splitting a RecordBatch.

    Splits the input RecordBatch into morsel-sized chunks at construction
    time, then yields them one at a time via next_morsel(). Each call to
    next_morsel() reconstructs the morsel from the stored data (copies
    column buffers) so the source can be read multiple times.

    Thread safety: the cursor index is a plain Int, so this source is NOT
    safe for concurrent access. Use one source per worker, or add atomic
    indexing for shared access.

    Fields:
        _morsels: Pre-split morsel array.
        _cursor: Index of the next morsel to yield.
    """

    var _morsels: MorselArray
    var _cursor: Int

    def __init__(out self, var batch: RecordBatch, morsel_size: Int = DEFAULT_MORSEL_ROWS) raises:
        """Create a RecordBatchScanSource from a RecordBatch.

        The batch is split into morsels immediately. The batch is consumed.

        Args:
            batch: The RecordBatch to scan. Ownership is transferred.
            morsel_size: Maximum rows per morsel (default: 64K).
        """
        self._morsels = split_record_batch(batch^, morsel_size)
        self._cursor = 0

    def next_morsel(mut self) raises -> Optional[Morsel]:
        """Yield the next morsel, or None if exhausted.

        Reconstructs a Morsel from the stored data (copies columns) so the
        source remains intact for potential re-reads.

        Returns:
            The next Morsel, or None if all morsels have been yielded.
        """
        if self._cursor >= len(self._morsels):
            return None

        var idx = self._cursor
        var num_rows = self._morsels[idx].num_rows()
        var num_cols = self._morsels[idx].num_columns()
        self._cursor += 1

        if num_rows == 0 or num_cols == 0:
            return Morsel.empty(self._cursor - 1, 0)

        # Reconstruct by copying column data.
        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()
        for c in range(num_cols):
            # The field (name, type, nullability, metadata) is carried over.
            sb.add_field(self._morsels[idx].batch.schema.field_at(c))
            ref col_ptr = self._morsels[idx].batch.column_at(c)
            var at = col_ptr.arrow_type
            var data_buf: OwnedAlignedBuffer
            if at == ArrowType.BOOL:
                # BOOL is bit-packed: copy `num_rows` bits starting at the
                # column's bit offset, not `num_rows * width` bytes.
                var bm_bytes = (num_rows + 7) >> 3
                data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
                data_buf.zero()
                copy_bits_aligned_buffer(
                    data_buf, 0, col_ptr._data, col_ptr._offset, num_rows
                )
                data_buf.set_length(Int64(bm_bytes))
            else:
                var elem_size = _elem_size(at)
                var byte_len = num_rows * elem_size

                data_buf = OwnedAlignedBuffer(max(byte_len, 1))
                var src_byte_offset = col_ptr._offset * elem_size
                if byte_len > 0:
                    data_buf.copy_from_view_at(
                        0,
                        col_ptr._data.view_range_ro(src_byte_offset, byte_len),
                    )
                data_buf.set_length(Int64(byte_len))

            var validity = Optional[Bitmap[HeapRegion]](None)
            var null_count = 0
            if col_ptr._validity:
                var bm = Bitmap.create(num_rows)
                for r in range(num_rows):
                    if not col_ptr._validity.value().test(col_ptr._offset + r):
                        bm.clear(r)
                        null_count += 1
                    else:
                        bm.set(r)
                validity = bm^

            var new_col = Column(
                arrow_type=at,
                data=data_buf^,
                offsets=None,
                validity=validity^,
                length=num_rows,
                null_count=null_count,
                offset=0,
            )
            builder.add_column(new_col^)

        var schema = sb.build()
        var batch = builder.build(schema^)
        return Morsel(batch^, self._cursor - 1, 0)

    @always_inline
    def num_morsels(self) -> Int:
        """Return the total number of morsels in this source.

        Returns:
            The number of morsel chunks the input was split into.
        """
        return len(self._morsels)

    @always_inline
    def total_rows(self) -> Int:
        """Return the total number of rows across all morsels.

        Returns:
            Sum of num_rows() across all morsels.
        """
        return self._morsels.total_rows()


@always_inline
def _elem_size(arrow_type: ArrowType) raises -> Int:
    """Return the byte width of a fixed-byte-width ArrowType; raise otherwise.

    BOOL is bit-packed, so it has no byte width and is handled separately at
    the call site in `next_morsel`.
    """
    return arrow_fixed_byte_width(arrow_type)
