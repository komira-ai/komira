# =============================================================================
# join_chunked_gather -- INNER join for large fan-out: probe into chunks of
# index pairs, then gather each output column per chunk
# =============================================================================
#
# `assemble_inner_join_chunked` produces the same output as
# `assemble_inner_join_fused` (every left column, then every right column,
# rows in probe-row order and within one probe row in build order of the
# flattened bucket), in three phases:
#
#   1. Flatten the chains: copy each bucket's (key, build row) entries into
#      contiguous per-bucket runs of two arrays.
#   2. Probe: for each probe row, scan its bucket's run and append each
#      matching (probe row, build row) pair to a chunk of up to 65,536 pairs
#      (a bucket is never split across chunks, so a chunk may run past).
#   3. Gather: per chunk, copy each output column in its own loop, so one
#      loop touches one source and one destination buffer.
#
# Phase 1 walks every chain once, so the chain-entry layout of the builder
# does not reach the probe loop. Output buffers start at the expected match
# count (probe rows times the mean bucket length, plus 10%) and double as
# needed. As in `join_fused_gather`, output columns carry no validity bitmap,
# so the kernel raises on an input column holding a NULL; a NULL probe key
# matches nothing.
# =============================================================================

from std.memory import unsafe_memcpy, UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_op_join_build.join import HashJoinBuilder, _hash_join_key, _PREFETCH_DISTANCE
from komira_op_join_build.join_layout_counter import join_layout_record_probe
from komira_op_join_build.join_probe_null_mask import ProbeNullMask

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from .join_fused_gather import (
    _column_values,
    _finish_column,
    _fixed_width_buffers,
    _require_same_width,
    _grow_fixed_width_buffers,
)
from .join_fused_route import require_null_free_column


comptime _CHUNK: Int = 65536
"""Pairs collected before a gather pass; 65,536 pairs of two Ints is 1 MiB."""


def _gather_column[
    so: ImmOrigin
](
    mut dst: OwnedAlignedBuffer,
    dst_start: Int,
    src: UnsafePointer[UInt8, so],
    src_rows: List[Int],
    es: Int,
):
    """Copy cell `src_rows[i]` of the column whose values start at `src` into
    row `dst_start + i` of `dst`, for every `i`, all cells `es` bytes wide.

    PERF-CRITICAL: the width test is outside the row loop, so the 8- and
    4-byte loops are one typed load and store per row."""
    var dst_view = dst.view_mut()
    var d = dst_view._unsafe_ptr()
    var n = len(src_rows)
    var r = src_rows.unsafe_ptr()
    if es == 8:
        var d8 = d.bitcast[Int64]() + dst_start
        var s8 = src.bitcast[Int64]()
        for i in range(n):
            (d8 + i)[] = (s8 + (r + i)[])[]
    elif es == 4:
        var d4 = d.bitcast[Int32]() + dst_start
        var s4 = src.bitcast[Int32]()
        for i in range(n):
            (d4 + i)[] = (s4 + (r + i)[])[]
    else:
        for i in range(n):
            unsafe_memcpy(
                dest=d + (dst_start + i) * es, src=src + (r + i)[] * es, count=es
            )


struct _FlatBuckets(Movable):
    """The chains of a `HashJoinBuilder` copied into per-bucket runs: bucket
    `b`'s entries are `keys[start[b] .. start[b] + length[b]]` with their
    build rows at the same positions of `rows`."""

    var start: List[Int]
    var length: List[Int]
    var keys: List[Int64]
    var rows: List[Int]
    var non_empty: Int

    def __init__(out self, join_builder: HashJoinBuilder):
        var cap = join_builder.capacity
        self.length = List[Int](capacity=cap)
        self.non_empty = 0
        for b in range(cap):
            var n = 0
            var chain_idx = join_builder.hash_table[b]
            while chain_idx != -1:
                n += 1
                chain_idx = join_builder.chain_next_at(chain_idx)
            self.length.append(n)
            if n > 0:
                self.non_empty += 1
        self.start = List[Int](capacity=cap + 1)
        self.start.append(0)
        for b in range(cap):
            self.start.append(self.start[b] + self.length[b])
        var total = self.start[cap]
        self.keys = List[Int64](length=total, fill=0)
        self.rows = List[Int](length=total, fill=0)
        for b in range(cap):
            var pos = self.start[b]
            var chain_idx = join_builder.hash_table[b]
            while chain_idx != -1:
                self.keys[pos] = join_builder.chain_key_at(chain_idx)
                self.rows[pos] = join_builder.build_row_at(chain_idx)
                pos += 1
                chain_idx = join_builder.chain_next_at(chain_idx)


def assemble_inner_join_chunked(
    left: RecordBatch,
    right: RecordBatch,
    join_builder: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    output_schema: Schema,
    probe_nulls: ProbeNullMask,
) raises -> RecordBatch:
    """INNER join of `left` (probe) and `right` (build), probe then gather per
    chunk; arguments, output and raises as `assemble_inner_join_fused`."""
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
            require_null_free_column(left, c, "assemble_inner_join_chunked")
            var es = _require_same_width(
                left.schema.field_arrow_type(c),
                output_schema.field_arrow_type(c),
                c,
                "assemble_inner_join_chunked",
            )
            elem_sizes.append(es)
            left_src.append(_column_values(left, c, es))
        else:
            var rc = c - left_ncols
            require_null_free_column(right, rc, "assemble_inner_join_chunked")
            var es = _require_same_width(
                right.schema.field_arrow_type(rc),
                output_schema.field_arrow_type(c),
                c,
                "assemble_inner_join_chunked",
            )
            elem_sizes.append(es)
            right_src.append(_column_values(right, rc, es))

    join_layout_record_probe(
        "join_chunked_gather", join_builder._bi_elided, join_builder._fused
    )
    var flat = _FlatBuckets(join_builder)
    var ht_cap = join_builder.capacity
    var mask = UInt64(ht_cap - 1)
    var num_probe = probe_keys.length

    var per_probe = 0
    if flat.non_empty > 0:
        per_probe = len(flat.keys) // flat.non_empty
    var buf_rows = max(Int(Float64(num_probe) * Float64(per_probe) * 1.1), 1024)
    var bufs = _fixed_width_buffers(elem_sizes, buf_rows)

    # The bloom filter is consulted only when the builder has one (a builder
    # built without one carries a placeholder with a NULL buffer) and fewer
    # than a third of the buckets are occupied.
    var use_bloom = join_builder._use_bloom and flat.non_empty * 3 < ht_cap

    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    # SAFETY: pointers into `flat`'s lists, which are not resized below.
    var start_ptr = flat.start.unsafe_ptr()
    var len_ptr = flat.length.unsafe_ptr()
    var keys_ptr = flat.keys.unsafe_ptr()
    var rows_ptr = flat.rows.unsafe_ptr()

    var chunk_probe = List[Int](capacity=_CHUNK + 1024)
    var chunk_build = List[Int](capacity=_CHUNK + 1024)
    var write_pos = 0
    var probe_idx = 0
    while probe_idx < num_probe:
        chunk_probe.clear()
        chunk_build.clear()
        while probe_idx < num_probe:
            if probe_idx + _PREFETCH_DISTANCE < num_probe:
                var fk = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
                var fs = Int(_hash_join_key(fk) & mask)
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (start_ptr + fs).bitcast[Scalar[DType.int64]]()
                )
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (len_ptr + fs).bitcast[Scalar[DType.int64]]()
                )
            if probe_idx + _PREFETCH_DISTANCE // 2 < num_probe:
                var mk = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE // 2)[])
                var ms = Int(_hash_join_key(mk) & mask)
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (keys_ptr + (start_ptr + ms)[]).bitcast[Scalar[DType.int64]]()
                )
            var pk = Int64((probe_key_ptr + probe_idx)[])
            # The cursor is advanced by hand (the loop breaks on a full
            # chunk), so every skip increments it.
            if probe_nulls.excludes(probe_idx):
                probe_idx += 1
                continue
            if use_bloom and not join_builder.bloom.might_contain_int64(pk):
                probe_idx += 1
                continue
            var slot = Int(_hash_join_key(pk) & mask)
            var bstart = (start_ptr + slot)[]
            for j in range((len_ptr + slot)[]):
                if (keys_ptr + bstart + j)[] == pk:
                    chunk_probe.append(probe_idx)
                    chunk_build.append((rows_ptr + bstart + j)[])
            probe_idx += 1
            if len(chunk_probe) >= _CHUNK:
                break

        var n = len(chunk_probe)
        if n == 0:
            break
        if write_pos + n > buf_rows:
            var new_rows = max(buf_rows * 2, write_pos + n + _CHUNK)
            _grow_fixed_width_buffers(bufs, elem_sizes, write_pos, new_rows)
            buf_rows = new_rows
        for c in range(n_left_out):
            _gather_column(bufs[c], write_pos, left_src[c], chunk_probe, elem_sizes[c])
        for c in range(n_left_out, total_out):
            _gather_column(
                bufs[c], write_pos, right_src[c - n_left_out], chunk_build, elem_sizes[c]
            )
        write_pos += n
    _ = probe_key_view
    _ = flat^

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
