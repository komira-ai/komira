# =============================================================================
# Contiguous batch slicing — shared helper for LIMIT and TopN
# =============================================================================
#
# Shared by the LIMIT operator and the TopN sink, which both slice a
# contiguous row range out of a batch.
# =============================================================================

from std.memory import UnsafePointer
from std.sys import size_of
from std.math import max

from ..arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from ..arrow.column import Column
from ..arrow.owned_aligned_buffer import OwnedAlignedBuffer
from ..io.heap_region import HeapRegion
from ..arrow.bitmap import Bitmap, copy_bits_aligned_buffer
from ..arrow.arrow_types import ArrowType
# THE fixed-byte-width table — one definition, tree-wide. It REFUSES the
# layouts that have no per-element byte width (see `element_size`'s notes), so
# every branch below that reaches it must already have peeled off the layouts
# it cannot answer for: STRING and BINARY share one Int32-offset arm (see that
# arm's note), DICTIONARY has its own, BOOL — bit-packed, `(n + 7) >> 3`
# bytes — has one, and so do LARGE_STRING / LARGE_BINARY (Int64 offsets).
from ..helpers.compiler_helpers import element_size


def _slice_batch_first_n(batch: RecordBatch, n: Int) raises -> RecordBatch:
    """Slice the first N rows from a batch using contiguous memcpy.

    PERF: This is O(cols * n * elem_size) with contiguous memory access,
    versus _gather_batch which does random-access per element. For LIMIT
    on the first N rows this is a straight memcpy per column.
    """
    var num_cols = batch.num_columns()
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    for c in range(num_cols):
        # ⛔⛔ THE WHOLE FIELD, CLONED — NOT A (name, type, nullable) TRIPLE.
        #
        # Rebuilding the Field from three accessors (and patching back
        # DECIMAL precision/scale by hand) DROPS every OTHER type parameter
        # the schema carries: a TIMESTAMP's timezone, a DICTIONARY's index
        # type, a UNION's type ids, the nested children, the field metadata.
        # A slice changes the ROWS and nothing else, so its output schema is
        # its input schema, field for field.
        #
        # This matters for TOP-N: a TOP-N over a key the bounded heap cannot
        # compare (a TIMESTAMP is not one of its four types) takes the
        # full-sort arm, which is `sort -> _slice_batch_first_n`, so a dropped
        # zone here turns `timestamp[us, tz=UTC]` into `timestamp[us]` at every
        # product surface. Pinned at the kernel by the TOP-N field type
        # parameter test.
        #
        # `field_at_unchecked` is the schema's own METADATA-PRESERVING clone —
        # decimal (p, s), tz, dictionary index type, union ids, flags,
        # metadata and nested children.
        sb.add_field(batch.schema.field_at_unchecked(c))
        ref col_ptr = batch.column_at(c)
        var at = col_ptr.arrow_type

        # Validity bitmap: copy first n bits
        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if col_ptr._validity:
            var bm = Bitmap.create(n)
            for r in range(n):
                if not col_ptr._validity.value().test(col_ptr._offset + r):
                    bm.clear(r)
                    null_count += 1
                else:
                    bm.set(r)
            validity = bm^

        if at == ArrowType.STRING or at == ArrowType.BINARY:
            # ★ THE INT32-OFFSET VAR-LEN ARM, AND IT SERVES **BOTH** NARROW
            # var-len types. BINARY's physical layout is byte-for-byte STRING's
            # -- (Int32 offsets, raw data bytes, optional validity) -- and the
            # only difference is the UTF-8 guarantee, which no byte of this
            # slice reads. `at` is carried onto the rebuilt Column below, so a
            # BINARY input comes out BINARY.
            #
            # ⛔ NOT `== ArrowType.STRING` ALONE: the WIDE arm below serves
            # LARGE_STRING and LARGE_BINARY together, and a plain `binary`
            # column falling through to `element_size(at)` (which REFUSES a
            # var-len layout by design) would make every consumer of this
            # helper refuse it: `ORDER BY <binary col> LIMIT k` (TopN's
            # full-sort+slice arm ends in `_slice_batch_first_n`), bare LIMIT,
            # and -- via `_slice_batch_range` -- the intra-row-group morsel
            # split and the per-row-group encode of the multi-row-group Parquet
            # writers.
            #
            # Regression test: the batch-slice BINARY test (its CONTROL is the
            # STRING path).
            if not col_ptr._offsets:
                raise Error(
                    "_slice_batch_first_n: STRING/BINARY column missing"
                    " offsets"
                )
            comptime int32_size = size_of[Int32]()
            ref src_offsets_buf = col_ptr._offsets.value()
            var data_start = Int(src_offsets_buf.get_typed[Int32](col_ptr._offset))
            var data_end = Int(src_offsets_buf.get_typed[Int32](col_ptr._offset + n))
            var data_len = data_end - data_start

            # Rebase offsets (contiguous copy)
            var new_offsets = OwnedAlignedBuffer((n + 1) * int32_size)
            for r in range(n + 1):
                var orig = Int(src_offsets_buf.get_typed[Int32](col_ptr._offset + r))
                new_offsets.set_typed[Int32](r, Int32(orig - data_start))
            new_offsets.set_length(Int64((n + 1) * int32_size))


            var new_data = OwnedAlignedBuffer(max(data_len, 1))
            if data_len > 0:
                new_data.copy_from_view(col_ptr._data.view_range_ro(data_start, data_len))
            new_data.set_length(Int64(data_len))


            var new_col = Column(
                arrow_type=at, data=new_data^, offsets=new_offsets^,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            builder.add_column(new_col^)
        elif (
            at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY
        ):
            # ★ THE INT64-OFFSET VAR-LEN ARM. Mirror of the STRING
            # arm above at 8-byte offset stride.
            #
            # ⛔ WITHOUT IT A PROMOTED COLUMN COULD NOT BE SLICED AT ALL: the
            # `else` below calls `element_size(at)`, which RAISES for
            # LARGE_STRING by design. Every consumer of this helper — LIMIT,
            # TopN, and (via `_slice_batch_range`) the per-row-group encode of
            # all three multi-row-group Parquet writers — therefore refused a
            # `large_string` column. That was the shape a promoted result
            # ALWAYS has when written: it is millions of rows, so the writer
            # necessarily splits it at `DEFAULT_MAX_ROWS_PER_RG`.
            if not col_ptr._offsets:
                raise Error(
                    "_slice_batch_first_n: LARGE_STRING/LARGE_BINARY column"
                    " missing offsets"
                )
            comptime int64_size = size_of[Int64]()
            ref w_offsets_buf = col_ptr._offsets.value()
            var w_data_start = Int(
                w_offsets_buf.get_typed[Int64](col_ptr._offset)
            )
            var w_data_end = Int(
                w_offsets_buf.get_typed[Int64](col_ptr._offset + n)
            )
            var w_data_len = w_data_end - w_data_start

            var w_new_offsets = OwnedAlignedBuffer((n + 1) * int64_size)
            for r in range(n + 1):
                var w_orig = Int(
                    w_offsets_buf.get_typed[Int64](col_ptr._offset + r)
                )
                w_new_offsets.set_typed[Int64](
                    r, Int64(w_orig - w_data_start)
                )
            w_new_offsets.set_length(Int64((n + 1) * int64_size))

            var w_new_data = OwnedAlignedBuffer(max(w_data_len, 1))
            if w_data_len > 0:
                w_new_data.copy_from_view(
                    col_ptr._data.view_range_ro(w_data_start, w_data_len)
                )
            w_new_data.set_length(Int64(w_data_len))

            var w_new_col = Column(
                arrow_type=at, data=w_new_data^, offsets=w_new_offsets^,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            builder.add_column(w_new_col^)
        elif at == ArrowType.DICTIONARY:
            comptime int32_size = size_of[Int32]()
            var idx_bytes = n * int32_size
            var new_idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
            var src_offset = col_ptr._offset * int32_size
            if idx_bytes > 0:
                new_idx_buf.copy_from_view(col_ptr._data.view_range_ro(src_offset, idx_bytes))
            new_idx_buf.set_length(Int64(idx_bytes))


            # Copy shared dictionary
            var dict_offsets_bytes = (col_ptr._dict_size + 1) * int32_size
            var new_dict_offsets = OwnedAlignedBuffer(dict_offsets_bytes)
            new_dict_offsets.copy_from_view(col_ptr._offsets.value().view_range_ro(0, dict_offsets_bytes))
            new_dict_offsets.set_length(Int64(dict_offsets_bytes))


            var dict_data_len = col_ptr._dict_data.value().len()
            var new_dict_data = OwnedAlignedBuffer(max(dict_data_len, 1))
            if dict_data_len > 0:
                new_dict_data.copy_from_view(col_ptr._dict_data.value().view_range_ro(0, dict_data_len))
            new_dict_data.set_length(Int64(dict_data_len))


            var new_col = Column(
                arrow_type=ArrowType.DICTIONARY, data=new_idx_buf^, offsets=new_dict_offsets^,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            # Bridge MmapAlignedBuffer -> Optional[SAB].
            new_col._set_dict_data_from_oab(new_dict_data^)
            new_col._dict_size = col_ptr._dict_size
            builder.add_column(new_col^)
        elif at == ArrowType.BOOL:
            # BIT-PACKED BOOL ARM.
            #
            # BOOL's data buffer is `(n + 7) >> 3` bytes, so it has NO per-row
            # byte width and the `element_size(at)` in the else-branch below
            # cannot answer for it. An `else: return 8` width would copy
            # `n * 8` bytes out of that buffer (a 64x over-read) and read it
            # from `col_ptr._offset * 8` — a byte address computed from a BIT
            # index, which lands in the wrong byte AND discards the sub-byte
            # bit position; the refusing width table raises instead. Neither is
            # a working LIMIT/TopN over a table that merely CARRIES a bool
            # column.
            #
            # ⚠ `element_size(at)` is evaluated BEFORE the `n *` multiply, so
            # a width-table path breaks at n == 0 too — and `sort_topn_sink`
            # calls `_slice_batch_first_n(batch, 0)` on its empty legs, which
            # would make an EMPTY TopN result unbuildable whenever a bool
            # column rode along.
            #
            # A slice moves a CONTIGUOUS run of rows, so this is
            # `copy_bits_aligned_buffer` — the same primitive `_copy_column`,
            # `scan_source.next_morsel` and `scheduler._build_morsel_for_filter`
            # use. NOT a fifth hand-rolled width ladder; that drift is what the
            # notes at `compiler_helpers.element_size` are about.
            var bm_bytes = (n + 7) >> 3
            var new_data = OwnedAlignedBuffer(max(bm_bytes, 1))
            new_data.zero()
            if n > 0:
                copy_bits_aligned_buffer(
                    new_data, 0, col_ptr._data, col_ptr._offset, n
                )
            new_data.set_length(Int64(bm_bytes))

            var new_col = Column(
                arrow_type=ArrowType.BOOL, data=new_data^, offsets=None,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            builder.add_column(new_col^)
        else:
            # Fixed-width: contiguous memcpy of first n elements
            var elem_size = element_size(at)
            var byte_len = n * elem_size
            var new_data = OwnedAlignedBuffer(max(byte_len, 1))
            var src_offset = col_ptr._offset * elem_size
            if byte_len > 0:
                new_data.copy_from_view(col_ptr._data.view_range_ro(src_offset, byte_len))
            new_data.set_length(Int64(byte_len))

            var new_col = Column(
                arrow_type=at, data=new_data^, offsets=None,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            # DECIMAL128 / DECIMAL256 carry (precision, scale) as Column
            # metadata (see `_slice_batch_range` for the rationale); propagate
            # from the source so a sliced decimal column stays usable.
            new_col._decimal_p = col_ptr._decimal_p
            new_col._decimal_s = col_ptr._decimal_s
            builder.add_column(new_col^)

    var schema = sb.build()
    return builder.build(schema^)


def _slice_batch_range(
    batch: RecordBatch, start: Int, length: Int
) raises -> RecordBatch:
    """Slice rows [start, start+length) from a batch using contiguous memcpy.

    Supports fixed-width, STRING, DICTIONARY column types. Used by the
    intra-RG morsel splitting path.
    """
    var n = length
    var num_cols = batch.num_columns()
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    for c in range(num_cols):
        # ⛔ THE WHOLE FIELD, CLONED — the second copy of the same defect as
        # `_slice_batch_first_n` above (read its note). This one is on the
        # intra-row-group morsel split and the per-row-group encode of the
        # multi-row-group Parquet writers, so a timezone dropped HERE is
        # dropped from a large scan's output and from a WRITTEN file, not
        # only from a TOP-N.
        sb.add_field(batch.schema.field_at_unchecked(c))
        ref col_ptr = batch.column_at(c)
        var at = col_ptr.arrow_type
        var base_offset = col_ptr._offset + start

        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if col_ptr._validity:
            var bm = Bitmap.create(n)
            for r in range(n):
                if not col_ptr._validity.value().test(base_offset + r):
                    bm.clear(r)
                    null_count += 1
                else:
                    bm.set(r)
            validity = bm^

        if at == ArrowType.STRING or at == ArrowType.BINARY:
            # BINARY rides the Int32-offset arm with STRING -- same layout, and
            # the wide pair below is already served together. See the long note
            # on the same arm of `_slice_batch_first_n`; this is the SECOND COPY
            # of that envelope and it had the identical gap.
            if not col_ptr._offsets:
                raise Error(
                    "_slice_batch_range: STRING/BINARY column missing offsets"
                )
            comptime int32_size = size_of[Int32]()
            ref src_offsets_buf = col_ptr._offsets.value()
            var data_start = Int(src_offsets_buf.get_typed[Int32](base_offset))
            var data_end = Int(src_offsets_buf.get_typed[Int32](base_offset + n))
            var data_len = data_end - data_start

            var new_offsets = OwnedAlignedBuffer((n + 1) * int32_size)
            for r in range(n + 1):
                var orig = Int(src_offsets_buf.get_typed[Int32](base_offset + r))
                new_offsets.set_typed[Int32](r, Int32(orig - data_start))
            new_offsets.set_length(Int64((n + 1) * int32_size))


            var new_data = OwnedAlignedBuffer(max(data_len, 1))
            if data_len > 0:
                new_data.copy_from_view(col_ptr._data.view_range_ro(data_start, data_len))
            new_data.set_length(Int64(data_len))


            var new_col = Column(
                arrow_type=at, data=new_data^, offsets=new_offsets^,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            builder.add_column(new_col^)
        elif (
            at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY
        ):
            # ★ THE INT64-OFFSET VAR-LEN ARM, the range twin of
            # the one in `_slice_batch_first_n`. See it for why this is
            # load-bearing rather than completeness: THIS is the function the
            # multi-row-group Parquet writers call once per row group, so
            # without it a promoted result — which by construction has far more
            # rows than `DEFAULT_MAX_ROWS_PER_RG` — could not be written even
            # after the encoders were widened.
            if not col_ptr._offsets:
                raise Error(
                    "_slice_batch_range: LARGE_STRING/LARGE_BINARY column"
                    " missing offsets"
                )
            comptime int64_size = size_of[Int64]()
            ref w_offsets_buf = col_ptr._offsets.value()
            var w_data_start = Int(
                w_offsets_buf.get_typed[Int64](base_offset)
            )
            var w_data_end = Int(
                w_offsets_buf.get_typed[Int64](base_offset + n)
            )
            var w_data_len = w_data_end - w_data_start

            var w_new_offsets = OwnedAlignedBuffer((n + 1) * int64_size)
            for r in range(n + 1):
                var w_orig = Int(
                    w_offsets_buf.get_typed[Int64](base_offset + r)
                )
                w_new_offsets.set_typed[Int64](
                    r, Int64(w_orig - w_data_start)
                )
            w_new_offsets.set_length(Int64((n + 1) * int64_size))

            var w_new_data = OwnedAlignedBuffer(max(w_data_len, 1))
            if w_data_len > 0:
                w_new_data.copy_from_view(
                    col_ptr._data.view_range_ro(w_data_start, w_data_len)
                )
            w_new_data.set_length(Int64(w_data_len))

            var w_new_col = Column(
                arrow_type=at, data=w_new_data^, offsets=w_new_offsets^,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            builder.add_column(w_new_col^)
        elif at == ArrowType.DICTIONARY:
            comptime int32_size = size_of[Int32]()
            var idx_bytes = n * int32_size
            var new_idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
            var src_offset_bytes = base_offset * int32_size
            if idx_bytes > 0:
                new_idx_buf.copy_from_view(col_ptr._data.view_range_ro(src_offset_bytes, idx_bytes))
            new_idx_buf.set_length(Int64(idx_bytes))


            var dict_offsets_bytes = (col_ptr._dict_size + 1) * int32_size
            var new_dict_offsets = OwnedAlignedBuffer(dict_offsets_bytes)
            new_dict_offsets.copy_from_view(col_ptr._offsets.value().view_range_ro(0, dict_offsets_bytes))
            new_dict_offsets.set_length(Int64(dict_offsets_bytes))


            var dict_data_len = col_ptr._dict_data.value().len()
            var new_dict_data = OwnedAlignedBuffer(max(dict_data_len, 1))
            if dict_data_len > 0:
                new_dict_data.copy_from_view(col_ptr._dict_data.value().view_range_ro(0, dict_data_len))
            new_dict_data.set_length(Int64(dict_data_len))


            var new_col = Column(
                arrow_type=ArrowType.DICTIONARY, data=new_idx_buf^, offsets=new_dict_offsets^,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            # Bridge MmapAlignedBuffer -> Optional[SAB].
            new_col._set_dict_data_from_oab(new_dict_data^)
            new_col._dict_size = col_ptr._dict_size
            builder.add_column(new_col^)
        elif at == ArrowType.BOOL:
            # BIT-PACKED BOOL ARM. Same mechanism as
            # `_slice_batch_first_n`'s arm above; see it for the full rationale.
            #
            # ⚠ `base_offset` is `col_ptr._offset + start` and BOTH terms are
            # BIT indices here. That is the whole defect: the else-branch below
            # computes `base_offset * elem_size`, i.e. it treats a bit index as
            # an element index and multiplies it by a byte width. Passing
            # `base_offset` straight through as `src_bit_offset` is what makes
            # a slice-of-a-slice compose.
            #
            # This is the widest of the six sites by consumer count: the
            # intra-row-group morsel split, `paginated_result`,
            # `sort_frame_resolver`, and the per-chunk encode of all three
            # multi-row-group Parquet writers.
            var bm_bytes = (n + 7) >> 3
            var new_data = OwnedAlignedBuffer(max(bm_bytes, 1))
            new_data.zero()
            if n > 0:
                copy_bits_aligned_buffer(
                    new_data, 0, col_ptr._data, base_offset, n
                )
            new_data.set_length(Int64(bm_bytes))

            var new_col = Column(
                arrow_type=ArrowType.BOOL, data=new_data^, offsets=None,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            builder.add_column(new_col^)
        else:
            var elem_size = element_size(at)
            var byte_len = n * elem_size
            var new_data = OwnedAlignedBuffer(max(byte_len, 1))
            var src_byte_offset = base_offset * elem_size
            if byte_len > 0:
                new_data.copy_from_view(col_ptr._data.view_range_ro(src_byte_offset, byte_len))
            new_data.set_length(Int64(byte_len))

            var new_col = Column(
                arrow_type=at, data=new_data^, offsets=None,
                validity=validity^, length=n, null_count=null_count, offset=0,
            )
            # DECIMAL128 / DECIMAL256 carry (precision, scale) as Column
            # metadata, not in the data buffer.  The fixed-width slab copy
            # above moves the 16/32-byte values correctly but the freshly
            # built Column defaults (p, s) to (0, 0); propagate them from the
            # source so `as_decimal128` / `as_decimal256` on the slice (e.g.
            # the multi-row-group Parquet writer's per-chunk encode, or a
            # LIMIT / TopN over a decimal column) does not raise "column
            # carries no precision/scale metadata".
            new_col._decimal_p = col_ptr._decimal_p
            new_col._decimal_s = col_ptr._decimal_s
            builder.add_column(new_col^)

    var schema_r = sb.build()
    return builder.build(schema_r^)


def _split_into_morsel_slots[
    origin: Origin[mut=True]
](
    var batch: RecordBatch,
    morsel_slots: UnsafePointer[RecordBatch, origin],
    write_idx: Int,
    max_slots: Int,
    morsel_size: Int,
) raises -> Int:
    """Split a decoded RecordBatch into morsel-sized sub-batches.

    Moves each sub-batch into ``morsel_slots[write_idx..]``. Returns the
    new write index. When the batch fits in a single morsel, it is moved
    directly (no copy).
    """
    var total_rows = batch.num_rows()
    if total_rows == 0:
        _ = batch^
        return write_idx

    if total_rows <= morsel_size:
        if write_idx < max_slots:
            (morsel_slots + write_idx).unsafe_write(batch^)
            return write_idx + 1
        _ = batch^
        return write_idx

    var idx = write_idx
    var offset = 0
    while offset < total_rows and idx < max_slots:
        var chunk = min(morsel_size, total_rows - offset)
        var sub = _slice_batch_range(batch, offset, chunk)
        (morsel_slots + idx).unsafe_write(sub^)
        idx += 1
        offset += chunk
    _ = batch^
    return idx
