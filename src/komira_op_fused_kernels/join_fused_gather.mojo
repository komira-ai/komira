# =============================================================================
# join_fused_gather -- single-pass INNER join: probe the chains and write the
# output rows in the same loop
# =============================================================================
#
#   * `assemble_inner_join_fused` -- every column of the left (probe) batch,
#     then every column of the right (build) batch, up to the output schema's
#     width.
#   * `assemble_inner_join_fused_projected` -- only the named output columns,
#     resolved once; the build side may be either batch.
#
# For each probe row: hash the key, walk its chain, and for each build row
# with an equal key write the selected cells of (probe row, build row) at the
# next output row. No index lists, no second gather pass. Output rows come in
# probe-row order, and within one probe row in chain order.
#
# A column is copied `element_size(type)` bytes per row into an output buffer
# that starts at min(probe rows, build rows) rows and doubles when full. The
# output columns carry no validity bitmap, so each kernel raises on an input
# column holding a NULL (see `join_fused_route`). A NULL probe key matches
# nothing: the caller's `ProbeNullMask` flags those rows.
#
# The chain-entry layout (`HashJoinBuilder._fused`, `_bi_elided`) is read once
# per call and tested per chain step, not specialised at compile time: the
# per-column scatter is the large part of this loop, and four copies of it
# would multiply its compile time for a one-branch-per-step saving.
# =============================================================================

from std.memory import unsafe_memcpy, UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import element_size
from komira_join_assembly.compiler_join_assembly import (
    resolve_join_output_cols,
    _JSIDE_PROBE,
)
from komira_op_join_build.join import (
    HashJoinBuilder,
    _hash_join_key,
    _CHAIN_END,
    _PREFETCH_DISTANCE,
)
from komira_op_join_build.join_layout_counter import join_layout_record_probe
from komira_op_join_build.join_probe_null_mask import ProbeNullMask

from .join_fused_route import require_null_free_column


# =============================================================================
# Output buffers shared with `join_chunked_gather`
# =============================================================================


def _fixed_width_buffers(
    elem_sizes: List[Int], rows: Int
) -> Slab[OwnedAlignedBuffer]:
    """One buffer of `rows * elem_sizes[c]` bytes per output column."""
    var bufs = Slab[OwnedAlignedBuffer].create(len(elem_sizes))
    for c in range(len(elem_sizes)):
        bufs.append(OwnedAlignedBuffer(rows * elem_sizes[c]))
    return bufs^


def _grow_fixed_width_buffers(
    mut bufs: Slab[OwnedAlignedBuffer],
    elem_sizes: List[Int],
    rows_kept: Int,
    new_rows: Int,
):
    """Replace each buffer by one of `new_rows` rows holding its first
    `rows_kept` rows. The new buffer's length is its capacity, as a fresh one
    is, so a later grow can read the rows written past the copy."""
    for c in range(len(elem_sizes)):
        var es = elem_sizes[c]
        var old = bufs.replace(c, OwnedAlignedBuffer(new_rows * es))
        bufs[c].copy_from_view(old.view_range_ro(0, rows_kept * es))
        bufs[c].set_length(Int64(new_rows * es))


@always_inline
def _copy_cell[
    so: ImmOrigin
](
    mut dst: OwnedAlignedBuffer,
    dst_row: Int,
    src: UnsafePointer[UInt8, so],
    src_row: Int,
    es: Int,
):
    """Copy cell `src_row` of a column whose values start at `src` into row
    `dst_row` of `dst`, both `es` bytes wide.

    PERF-CRITICAL: the 8- and 4-byte arms are one typed load and store; only
    the other widths take a `memcpy`."""
    var dst_view = dst.view_mut()
    var d = dst_view._unsafe_ptr()
    if es == 8:
        (d.bitcast[Int64]() + dst_row)[] = (src.bitcast[Int64]() + src_row)[]
    elif es == 4:
        (d.bitcast[Int32]() + dst_row)[] = (src.bitcast[Int32]() + src_row)[]
    else:
        unsafe_memcpy(dest=d + dst_row * es, src=src + src_row * es, count=es)


def _column_values[
    o: ImmOrigin
](ref [o] batch: RecordBatch, col: Int, es: Int) -> UnsafePointer[UInt8, o]:
    """The address of the first logical value of column `col` of `batch`,
    whose values are `es` bytes wide (the column's slice offset applied).

    SAFETY: restated at `o`, the caller's borrow of `batch`; the column's data
    buffer is reachable only through `batch`, so the pointer is valid while
    that borrow is live. The caller holds it for one kernel call."""
    ref c = batch.column_at(col)
    var v = c._data.view_ro()
    var p = v._unsafe_ptr().unsafe_origin_cast[o]()
    _ = v
    return p + c._offset * es


def _require_same_width(
    source: ArrowType, output: ArrowType, col: Int, who: String
) raises -> Int:
    """The byte width of an output column's cells, which is its source
    column's. Raise when the output type's width differs: the cells are
    copied as they are, so a different width would put cells of one width
    under a type of another."""
    var es = element_size(source)
    if element_size(output) != es:
        raise Error(
            who
            + ": output column "
            + String(col)
            + " has a cell width of "
            + String(element_size(output))
            + " bytes, but its source column's is "
            + String(es)
        )
    return es


@always_inline
def _prefetch_probe_ahead[
    _mut: Bool, o: Origin[mut=_mut], //
](
    join_builder: HashJoinBuilder,
    probe_key_ptr: UnsafePointer[Scalar[DType.int64], o],
    probe_idx: Int,
    num_probe: Int,
    mask: UInt64,
):
    """The two-stage prefetch of the chain walk: the bucket of the row
    `_PREFETCH_DISTANCE` ahead, then the chain head's key of the row half that
    distance ahead."""
    # SAFETY: the builder's lists, read-only for the call.
    var ht_ptr = join_builder.hash_table.unsafe_ptr()
    var bk_ptr = join_builder.build_keys.unsafe_ptr()
    var kn_ptr = join_builder.key_next.unsafe_ptr()
    if probe_idx + _PREFETCH_DISTANCE < num_probe:
        var fk = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
        prefetch[params = PrefetchOptions().for_read().high_locality()](
            (ht_ptr + Int(_hash_join_key(fk) & mask)).bitcast[Scalar[DType.int64]]()
        )
    if probe_idx + _PREFETCH_DISTANCE // 2 < num_probe:
        var mk = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE // 2)[])
        var mc = (ht_ptr + Int(_hash_join_key(mk) & mask))[]
        if mc != _CHAIN_END:
            if join_builder._fused:
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (kn_ptr + 2 * mc).bitcast[Scalar[DType.int64]]()
                )
            else:
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (bk_ptr + mc).bitcast[Scalar[DType.int64]]()
                )


def _finish_column(
    mut bufs: Slab[OwnedAlignedBuffer],
    c: Int,
    es: Int,
    rows: Int,
    at: ArrowType,
) -> Column[HeapRegion]:
    """Take output buffer `c` as a `rows`-row column of type `at` with no
    validity bitmap."""
    var data = bufs.replace(c, OwnedAlignedBuffer(0))
    data.set_length(Int64(rows * es))
    return Column(
        arrow_type=at,
        data=data^,
        offsets=None,
        validity=Optional[Bitmap[HeapRegion]](None),
        length=rows,
        null_count=0,
        offset=0,
    )


# =============================================================================
# Full materialization
# =============================================================================


def assemble_inner_join_fused(
    left: RecordBatch,
    right: RecordBatch,
    join_builder: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    output_schema: Schema,
    probe_nulls: ProbeNullMask,
) raises -> RecordBatch:
    """INNER join of `left` (probe) and `right` (build) in one pass.

    Output column `c` is left column `c` for `c < left.num_columns()`, then
    right column `c - left.num_columns()`, for `c` below
    min(left + right columns, `output_schema.num_columns()`). Its field is
    the source field (metadata included) renamed to `output_schema`'s field
    name, and its type is `output_schema`'s.

    Args:
        left: The probe batch; row `i` is probe row `i`.
        right: The build batch; `join_builder` indexes its rows.
        join_builder: The table built on `right`'s key.
        probe_keys: The probe key of each row of `left`.
        output_schema: Names and types of the output columns.
        probe_nulls: Which probe rows hold a NULL key, built once by the
            caller from `probe_keys`.

    Raises:
        If an output column holds a NULL, has no fixed byte width, or its
        output type has a different byte width than its source column's.
    """
    var left_ncols = left.num_columns()
    var right_ncols = right.num_columns()
    var total_out = min(left_ncols + right_ncols, output_schema.num_columns())
    var n_left_out = min(left_ncols, total_out)

    var elem_sizes = List[Int](capacity=total_out)
    comptime lo = origin_of(left)
    comptime ro = origin_of(right)
    var left_src = List[UnsafePointer[UInt8, lo]](capacity=n_left_out)
    var right_src = List[UnsafePointer[UInt8, ro]](capacity=total_out - n_left_out)
    for c in range(total_out):
        if c < left_ncols:
            require_null_free_column(left, c, "assemble_inner_join_fused")
            var es = _require_same_width(
                left.schema.field_arrow_type(c),
                output_schema.field_arrow_type(c),
                c,
                "assemble_inner_join_fused",
            )
            elem_sizes.append(es)
            left_src.append(_column_values(left, c, es))
        else:
            var rc = c - left_ncols
            require_null_free_column(right, rc, "assemble_inner_join_fused")
            var es = _require_same_width(
                right.schema.field_arrow_type(rc),
                output_schema.field_arrow_type(c),
                c,
                "assemble_inner_join_fused",
            )
            elem_sizes.append(es)
            right_src.append(_column_values(right, rc, es))

    var num_probe = probe_keys.length
    var buf_rows = max(min(num_probe, join_builder.num_build), 1)
    var bufs = _fixed_width_buffers(elem_sizes, buf_rows)

    var mask = UInt64(join_builder.capacity - 1)
    # `view_ro` starts at the array's own offset, so a sliced key array is
    # read from its first logical key.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    # SAFETY: the builder's lists, read-only for the call; the borrow of
    # `join_builder` keeps them alive.
    var ht_ptr = join_builder.hash_table.unsafe_ptr()
    var bk_ptr = join_builder.build_keys.unsafe_ptr()
    var bi_ptr = join_builder.build_indices.unsafe_ptr()
    var nc_ptr = join_builder.next_chain.unsafe_ptr()
    var kn_ptr = join_builder.key_next.unsafe_ptr()
    var fused_layout = join_builder._fused
    var bi_elided = join_builder._bi_elided
    # A builder built without a bloom filter carries a placeholder with a
    # NULL buffer; every probe-side bloom call is gated on this flag.
    var use_bloom = join_builder._use_bloom
    join_layout_record_probe("join_fused_gather", bi_elided, fused_layout)

    var write_pos = 0
    for probe_idx in range(num_probe):
        _prefetch_probe_ahead(join_builder, probe_key_ptr, probe_idx, num_probe, mask)

        var probe_key = Int64((probe_key_ptr + probe_idx)[])
        if probe_nulls.excludes(probe_idx):
            continue
        var h = _hash_join_key(probe_key)
        if use_bloom and not join_builder.bloom.might_contain_join_key(probe_key, h):
            continue

        var chain_idx = (ht_ptr + Int(h & mask))[]
        while chain_idx != _CHAIN_END:
            var chain_key = (
                (kn_ptr + 2 * chain_idx)[] if fused_layout else (bk_ptr + chain_idx)[]
            )
            if chain_key == probe_key:
                # Under the elided layout the chain index is the build row.
                var build_row = chain_idx if bi_elided else (bi_ptr + chain_idx)[]
                if write_pos >= buf_rows:
                    _grow_fixed_width_buffers(bufs, elem_sizes, write_pos, buf_rows * 2)
                    buf_rows *= 2
                for c in range(n_left_out):
                    _copy_cell(bufs[c], write_pos, left_src[c], probe_idx, elem_sizes[c])
                for c in range(n_left_out, total_out):
                    _copy_cell(
                        bufs[c],
                        write_pos,
                        right_src[c - n_left_out],
                        build_row,
                        elem_sizes[c],
                    )
                write_pos += 1
            chain_idx = (
                Int((kn_ptr + 2 * chain_idx + 1)[]) if fused_layout else (nc_ptr + chain_idx)[]
            )
    _ = probe_key_view

    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder.with_capacity(total_out)
    for c in range(total_out):
        var f: Field
        if c < left_ncols:
            f = left.schema.field_at(c)
        else:
            f = right.schema.field_at(c - left_ncols)
        f.name = output_schema.field_name(c)
        sb.add_field(f^)
        builder.add_column(
            _finish_column(
                bufs, c, elem_sizes[c], write_pos, output_schema.field_arrow_type(c)
            )
        )
    return builder.build(sb.build())


# =============================================================================
# Projected
# =============================================================================


def _count_inner_matches(
    join_builder: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    probe_nulls: ProbeNullMask,
) raises -> Int:
    """The number of (probe row, build row) pairs with equal keys, NULL probe
    keys excluded."""
    var mask = UInt64(join_builder.capacity - 1)
    var key_view = probe_keys.view_ro()
    var keys = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    # SAFETY: as in `assemble_inner_join_fused`.
    var ht = join_builder.hash_table.unsafe_ptr()
    var bk = join_builder.build_keys.unsafe_ptr()
    var nc = join_builder.next_chain.unsafe_ptr()
    var kn = join_builder.key_next.unsafe_ptr()
    var fused_layout = join_builder._fused
    var use_bloom = join_builder._use_bloom
    var count = 0
    for probe_idx in range(probe_keys.length):
        var probe_key = Int64((keys + probe_idx)[])
        # This count is what an ungrouped `count(*)` over the join reads; a
        # NULL key counted here would inflate it.
        if probe_nulls.excludes(probe_idx):
            continue
        var h = _hash_join_key(probe_key)
        if use_bloom and not join_builder.bloom.might_contain_join_key(probe_key, h):
            continue
        var chain_idx = (ht + Int(h & mask))[]
        while chain_idx != _CHAIN_END:
            var chain_key = (kn + 2 * chain_idx)[] if fused_layout else (bk + chain_idx)[]
            if chain_key == probe_key:
                count += 1
            chain_idx = Int((kn + 2 * chain_idx + 1)[]) if fused_layout else (nc + chain_idx)[]
    _ = key_view
    return count


def assemble_inner_join_fused_projected(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    join_builder: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    output_names: List[String],
    left: RecordBatch,
    right: RecordBatch,
    probe_is_left: Bool,
    probe_nulls: ProbeNullMask,
) raises -> RecordBatch:
    """INNER join in one pass, emitting only `output_names`.

    `left` and `right` are the join's sides as written, used only to resolve
    `output_names` (see `fused_join_cannot_carry_output`). The probe loop
    scans `probe_batch` by `probe_keys`; `join_builder` indexes the rows of
    `build_batch`. `probe_is_left` says which side the probe batch is: True
    when `probe_batch` is `left`, False when the caller built the table on the
    left and probes with the right.

    With no output names the result is `RecordBatch.count_only` of the match
    count: an ungrouped `count(*)` over the join reads it.

    Args:
        probe_batch: The batch the probe loop scans.
        build_batch: The batch `join_builder` was built on.
        join_builder: The table.
        probe_keys: The probe key of each row of `probe_batch`.
        output_names: The output columns, in order.
        left: The join's left side.
        right: The join's right side.
        probe_is_left: True iff `probe_batch` is `left`.
        probe_nulls: Which probe rows hold a NULL key.

    Raises:
        If a name resolves to neither side, or a selected column holds a NULL
        or has no fixed byte width.
    """
    var num_out = len(output_names)
    if num_out == 0:
        return RecordBatch.count_only(
            _count_inner_matches(join_builder, probe_keys, probe_nulls)
        )

    var resolved = resolve_join_output_cols(left.schema, right.schema, output_names)
    var sides = resolved[0].copy()
    var col_indices = resolved[1].copy()

    # Per output column: whether its cells come from the probe row, its width,
    # its type, and the address of its values in the batch it comes from (an
    # index into `probe_src` or `build_src`).
    comptime po = origin_of(probe_batch)
    comptime bo = origin_of(build_batch)
    var from_probe = List[Bool](capacity=num_out)
    var elem_sizes = List[Int](capacity=num_out)
    var arrow_types = List[ArrowType](capacity=num_out)
    var src_slot = List[Int](capacity=num_out)
    var probe_src = List[UnsafePointer[UInt8, po]]()
    var build_src = List[UnsafePointer[UInt8, bo]]()
    for c in range(num_out):
        var is_left = sides[c] == _JSIDE_PROBE
        var use_probe = is_left if probe_is_left else not is_left
        var col = col_indices[c]
        from_probe.append(use_probe)
        var at: ArrowType
        if use_probe:
            require_null_free_column(
                probe_batch, col, "assemble_inner_join_fused_projected"
            )
            at = probe_batch.schema.field_arrow_type(col)
            src_slot.append(len(probe_src))
            probe_src.append(_column_values(probe_batch, col, element_size(at)))
        else:
            require_null_free_column(
                build_batch, col, "assemble_inner_join_fused_projected"
            )
            at = build_batch.schema.field_arrow_type(col)
            src_slot.append(len(build_src))
            build_src.append(_column_values(build_batch, col, element_size(at)))
        elem_sizes.append(element_size(at))
        arrow_types.append(at)

    var num_probe = probe_keys.length
    var buf_rows = max(min(num_probe, join_builder.num_build), 1)
    var bufs = _fixed_width_buffers(elem_sizes, buf_rows)

    var mask = UInt64(join_builder.capacity - 1)
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    # SAFETY: as in `assemble_inner_join_fused`.
    var ht_ptr = join_builder.hash_table.unsafe_ptr()
    var bk_ptr = join_builder.build_keys.unsafe_ptr()
    var bi_ptr = join_builder.build_indices.unsafe_ptr()
    var nc_ptr = join_builder.next_chain.unsafe_ptr()
    var kn_ptr = join_builder.key_next.unsafe_ptr()
    var fused_layout = join_builder._fused
    var bi_elided = join_builder._bi_elided
    var use_bloom = join_builder._use_bloom
    join_layout_record_probe("join_fused_gather", bi_elided, fused_layout)

    var write_pos = 0
    for probe_idx in range(num_probe):
        _prefetch_probe_ahead(join_builder, probe_key_ptr, probe_idx, num_probe, mask)

        var probe_key = Int64((probe_key_ptr + probe_idx)[])
        if probe_nulls.excludes(probe_idx):
            continue
        var h = _hash_join_key(probe_key)
        if use_bloom and not join_builder.bloom.might_contain_join_key(probe_key, h):
            continue

        var chain_idx = (ht_ptr + Int(h & mask))[]
        while chain_idx != _CHAIN_END:
            var chain_key = (
                (kn_ptr + 2 * chain_idx)[] if fused_layout else (bk_ptr + chain_idx)[]
            )
            if chain_key == probe_key:
                var build_row = chain_idx if bi_elided else (bi_ptr + chain_idx)[]
                if write_pos >= buf_rows:
                    _grow_fixed_width_buffers(bufs, elem_sizes, write_pos, buf_rows * 2)
                    buf_rows *= 2
                for c in range(num_out):
                    if from_probe[c]:
                        _copy_cell(
                            bufs[c], write_pos, probe_src[src_slot[c]], probe_idx, elem_sizes[c]
                        )
                    else:
                        _copy_cell(
                            bufs[c], write_pos, build_src[src_slot[c]], build_row, elem_sizes[c]
                        )
                write_pos += 1
            chain_idx = (
                Int((kn_ptr + 2 * chain_idx + 1)[]) if fused_layout else (nc_ptr + chain_idx)[]
            )
    _ = probe_key_view

    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder.with_capacity(num_out)
    for c in range(num_out):
        var f: Field
        if sides[c] == _JSIDE_PROBE:
            f = left.schema.field_at(col_indices[c])
        else:
            f = right.schema.field_at(col_indices[c])
        f.name = output_names[c]
        sb.add_field(f^)
        builder.add_column(
            _finish_column(bufs, c, elem_sizes[c], write_pos, arrow_types[c])
        )
    return builder.build(sb.build())
