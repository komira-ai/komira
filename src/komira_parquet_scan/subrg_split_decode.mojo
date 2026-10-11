# =============================================================================
# subrg_split_decode — decode one row range of a row group
# =============================================================================
#
# The morsel source's whole-row-group claim gives one worker a whole row group
# to decode, which makes the row group an indivisible unit and the slowest
# worker's row group the tail of the scan. This module decodes ONE claimed
# range `[row_lo, row_hi)` of a row group through column cursors positioned
# with `seek_to_row`, into a batch equal to those rows of the whole decode
# (every column flat and of its own type, `subrg_columns.build_one_scan_col`).
#
# Row ranges rather than pages: page sizes are the writer's (one page per
# chunk is common), so a page split can give no parallelism; a row range
# chooses its own size, snapping to pages where they are fine
# (`subrg_page_row_boundaries`) and skipping values inside a page where they
# are not.
#
# Scope is the cursor's: INT32, INT64, FLOAT and DOUBLE columns, dictionary or
# PLAIN, V1 pages, no actual null. `subrg_probe_build_plan` checks the first
# row group; a later row group a cursor refuses returns None and the caller
# decodes that range's row group whole.
#
# The shared variant decodes each (row group, column) dictionary once
# (`build_shared_col_dict`, published once through `SubrgBuildLatch`) and every
# range reads only the data pages and resolves against the shared dictionary.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import unsafe_memcpy

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.page_header_parser import _parse_page_header
from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import CompressionCodec, PageType, ParquetType

from .parquet_reader import ParquetReader
from .subrg_agg_plan import resolve_reader_col_idx
from .subrg_columns import build_one_scan_col
from .subrg_cursor_feed import _chunk_is_nullable, open_subrg_cursor, read_column_chunk_bytes
from .subrg_scan_executor import SubrgScanPlan


def resolved_arrow_type(ptype: ParquetType) -> ArrowType:
    """The flat Arrow type a cursor column of physical type `ptype` resolves
    to (dictionary or PLAIN alike)."""
    if ptype == ParquetType.INT32:
        return ArrowType.INT32
    if ptype == ParquetType.INT64:
        return ArrowType.INT64
    if ptype == ParquetType.FLOAT:
        return ArrowType.FLOAT32
    return ArrowType.FLOAT64


def _is_plain_numeric_ptype(ptype: ParquetType) -> Bool:
    return (
        ptype == ParquetType.INT32 or ptype == ParquetType.INT64 or ptype == ParquetType.FLOAT
        or ptype == ParquetType.DOUBLE
    )


def subrg_probe_build_plan[FS: FileSystem](reader: ParquetReader[FS], result_col_names: List[String]) raises -> Optional[SubrgScanPlan]:
    """The read plan of `result_col_names`, or None when a column is absent,
    not INT32 / INT64 / FLOAT / DOUBLE, or refused by a cursor on row group 0
    (a file's row groups share their encodings for the writers in use; a later
    refusal is caught per range)."""
    var n_cols = len(result_col_names)
    if n_cols == 0 or len(reader._meta[].row_groups) == 0:
        return None
    var proj_names = List[String]()
    var reader_col_idx = List[Int]()
    var arrow_types = List[ArrowType]()
    ref rg0 = reader._meta[].row_groups[0]
    for ci in range(n_cols):
        var name = result_col_names[ci]
        var rci = resolve_reader_col_idx(reader, name)
        if rci < 0 or rci >= len(rg0.columns):
            return None
        var ptype = rg0.columns[rci].meta_data.type
        if not _is_plain_numeric_ptype(ptype):
            return None
        proj_names.append(name)
        reader_col_idx.append(rci)
        arrow_types.append(resolved_arrow_type(ptype))
    for ci in range(n_cols):
        if not open_subrg_cursor(reader._file, rg0, reader._meta[].schema, reader_col_idx[ci]).supported():
            return None
    return Optional(SubrgScanPlan(proj_names^, reader_col_idx^, arrow_types^))


def subrg_build_chunk_schema(plan: SubrgScanPlan) raises -> Schema:
    """The chunk batches' schema, in projection order; every field is
    non-nullable (a column with an actual null is refused)."""
    var sb = SchemaBuilder()
    for ci in range(len(plan.proj_names)):
        sb.add_field(Field(plan.proj_names[ci], plan.col_arrow_types[ci], False))
    return sb.build()


def subrg_page_row_boundaries[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_idx: Int,
    driver_reader_col_idx: Int,
) raises -> List[Int]:
    """The driver column's page boundaries in row group `rg_idx`, as
    cumulative rows `[0, n0, n0 + n1, ..., rg_rows]`, from its page headers
    (no body decompressed); `[0, rg_rows]` when the walk does not end at the
    row group's row count."""
    ref rg = reader._meta[].row_groups[rg_idx]
    var rg_rows = Int(rg.num_rows)
    var out = List[Int]()
    out.append(0)
    var chunk = read_column_chunk_bytes(reader._file, rg, driver_reader_col_idx)
    var data_len = len(chunk)
    var offset = 0
    var cum = 0
    while offset < data_len:
        var hdr = _parse_page_header(Span(chunk)[offset:])
        var comp_size = hdr.header.compressed_page_size
        var body_off = offset + hdr.bytes_consumed
        if comp_size < 0 or comp_size > data_len - body_off:
            break
        if hdr.header.type != PageType.DICTIONARY_PAGE:
            cum += hdr.header.num_values
            out.append(cum)
        offset = body_off + comp_size
    if len(out) < 2 or out[len(out) - 1] != rg_rows:
        return [0, rg_rows]
    return out^


def _fill_and_build(
    mut cur: ResumableColumnCursor,
    mut buf: OwnedAlignedBuffer,
    n: Int,
    is_dict: Bool,
    is_float: Bool,
    ptype: ParquetType,
    dict_i: List[Int64],
    dict_f: List[Float64],
) raises -> Optional[Column[HeapRegion]]:
    """Fill `n` rows of `cur` (codes or flat values) into `buf` and build the
    column; None on a short fill."""
    var v_total = 0
    while v_total < n:
        var nv: Int
        if is_dict:
            nv = cur.fill_next_codes_at(buf, n - v_total, v_total)
        else:
            nv = cur.fill_next_flat(buf, n - v_total, v_total)
        if nv == 0:
            break
        v_total += nv
    if v_total != n:
        return None
    return build_one_scan_col(buf, n, v_total, is_dict, is_float, ptype, dict_i, dict_f)


def decode_subrg_unit[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_idx: Int,
    row_lo: Int,
    row_hi: Int,
    plan: SubrgScanPlan,
    chunk_schema: Schema,
    mut ctx: ColumnDecodeContext,
    meta_schema: List[SchemaElement],
    buf_rows: Int,
) raises -> Optional[RecordBatch]:
    """Rows `[row_lo, row_hi)` of row group `rg_idx`, one batch in projection
    order, or None when a cursor refuses the row group or fills short (the
    caller decodes the row group whole). Each column's dictionary is decoded
    for this range."""
    var n_cols = len(plan.proj_names)
    var n_unit = row_hi - row_lo
    if n_cols == 0 or n_unit <= 0:
        return None
    ref rg = reader._meta[].row_groups[rg_idx]
    var cursors = Slab[ResumableColumnCursor].create(n_cols)
    for ci in range(n_cols):
        cursors.append(open_subrg_cursor(reader._file, rg, meta_schema, plan.reader_col_idx[ci]))
    for ci in range(n_cols):
        if not cursors[ci].supported() or not cursors[ci].seek_to_row(row_lo, row_hi):
            return None
    var need_bytes = (buf_rows + SUBRG_MAX_RUN) * 8
    ctx.ensure_subrg_codes(need_bytes)
    ctx.ensure_subrg_value(need_bytes)
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for ci in range(n_cols):
        var col_dict_i = List[Int64]()
        var col_dict_f = List[Float64]()
        var is_dict = cursors[ci].is_dict()
        var is_float = cursors[ci].value_is_float()
        if is_dict:
            if is_float:
                col_dict_f = cursors[ci].dict_values_f64_copy()
            else:
                col_dict_i = cursors[ci].dict_values_copy()
        # Column 0 fills the codes buffer and every other column the value
        # buffer; each column is built before the next fills.
        var ptype = cursors[ci].value_ptype()
        var col: Optional[Column[HeapRegion]]
        if ci == 0:
            col = _fill_and_build(cursors[ci], ctx.subrg_codes_ref(), n_unit, is_dict, is_float, ptype, col_dict_i, col_dict_f)
        else:
            col = _fill_and_build(cursors[ci], ctx.subrg_value_ref(), n_unit, is_dict, is_float, ptype, col_dict_i, col_dict_f)
        if not col:
            return None
        rbb.add_column(col.take())
    return Optional(rbb.build(chunk_schema.copy()))


struct SubrgBuildLatch:
    """A once-latch per (row group, column): the first worker whose `claim`
    `fetch_add` returns 0 builds the `SharedColDict`, publishes it and then
    sets `done`; the others wait for `done` and borrow it. Lives zero-filled
    in a `Slab` (an atomic does not move)."""

    var claim: AtomicI64
    var done: AtomicI64


struct SharedColDict(Copyable, Movable, Deinitable):
    """One (row group, column) decoded once: its dictionary and where its
    data pages are.

    Fields:
        supported: False is the sentinel of a column a cursor refuses (or a
            string dictionary).
        data_off / data_len: the data pages' file offset and byte length.
    """

    var supported: Bool
    var is_dict: Bool
    var is_float: Bool
    var ptype: ParquetType
    var codec: CompressionCodec
    var num_values: Int
    var nullable: Bool
    var data_off: Int
    var data_len: Int
    var dict_i64: List[Int64]
    var dict_f64: List[Float64]

    def __init__(out self, supported: Bool):
        """The sentinel (or an empty supported entry)."""
        self.supported = supported
        self.is_dict = False
        self.is_float = False
        self.ptype = ParquetType.INT64
        self.codec = CompressionCodec.UNCOMPRESSED
        self.num_values = 0
        self.nullable = False
        self.data_off = 0
        self.data_len = 0
        self.dict_i64 = List[Int64]()
        self.dict_f64 = List[Float64]()

    def __init__(
        out self,
        is_dict: Bool,
        is_float: Bool,
        ptype: ParquetType,
        codec: CompressionCodec,
        num_values: Int,
        nullable: Bool,
        data_off: Int,
        data_len: Int,
        var dict_i64: List[Int64],
        var dict_f64: List[Float64],
    ):
        self.supported = True
        self.is_dict = is_dict
        self.is_float = is_float
        self.ptype = ptype
        self.codec = codec
        self.num_values = num_values
        self.nullable = nullable
        self.data_off = data_off
        self.data_len = data_len
        self.dict_i64 = dict_i64^
        self.dict_f64 = dict_f64^


def build_shared_col_dict[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_idx: Int,
    col_idx: Int,
    meta_schema: List[SchemaElement],
) raises -> SharedColDict:
    """Decode the dictionary of (row group, column) once and record its data
    pages' extent; the sentinel for a column a cursor refuses or a string
    dictionary."""
    ref rg = reader._meta[].row_groups[rg_idx]
    ref col_meta = rg.columns[col_idx].meta_data
    var start_offset = col_meta.data_page_offset
    if col_meta.dictionary_page_offset:
        start_offset = min(start_offset, col_meta.dictionary_page_offset.value())
    var cur = open_subrg_cursor(reader._file, rg, meta_schema, col_idx)
    if not cur.supported() or cur.is_string_dict():
        return SharedColDict(False)
    var fdo = cur.first_data_page_offset()
    var di = List[Int64]()
    var df = List[Float64]()
    if cur.is_dict():
        if cur.value_is_float():
            df = cur.dict_values_f64_copy()
        else:
            di = cur.dict_values_copy()
    return SharedColDict(
        cur.is_dict(), cur.value_is_float(), cur.value_ptype(), col_meta.codec, col_meta.num_values,
        _chunk_is_nullable(meta_schema[col_idx + 1]), start_offset + fdo, col_meta.total_compressed_size - fdo,
        di^, df^,
    )


def _read_bytes_range[FS: FileSystem](reader: ParquetFileReader[FS], off: Int, length: Int) raises -> List[UInt8]:
    """`length` bytes of the file from `off`, as an owned list."""
    var out = List[UInt8](capacity=max(length, 1))
    if length <= 0:
        return out^
    var raw = reader.read_bytes(off, length)
    var view = raw.view_range_ro(0, length)
    out.resize(length, UInt8(0))
    # SAFETY: `view` covers `length` bytes (the `read_bytes` contract) and
    # `out` holds `length`; both pointers are used only by this synchronous
    # copy, while `raw` and `out` live.
    unsafe_memcpy(dest=out.unsafe_ptr(), src=view._unsafe_ptr(), count=length)
    _ = raw
    return out^


def decode_subrg_unit_shared[FS: FileSystem](
    reader: ParquetReader[FS],
    row_lo: Int,
    row_hi: Int,
    plan: SubrgScanPlan,
    chunk_schema: Schema,
    mut ctx: ColumnDecodeContext,
    shared: Slab[SharedColDict],
    rg_base: Int,
    buf_rows: Int,
) raises -> Optional[RecordBatch]:
    """`decode_subrg_unit` over the shared dictionaries `shared[rg_base +
    ci]`: each column reads only its data pages and resolves against the
    shared dictionary. None on any refusal."""
    var n_cols = len(plan.proj_names)
    var n_unit = row_hi - row_lo
    if n_cols == 0 or n_unit <= 0:
        return None
    var need_bytes = (buf_rows + SUBRG_MAX_RUN) * 8
    ctx.ensure_subrg_codes(need_bytes)
    ctx.ensure_subrg_value(need_bytes)
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for ci in range(n_cols):
        ref sd = shared[rg_base + ci]
        if not sd.supported:
            return None
        var cur = ResumableColumnCursor.try_open_data_only(
            _read_bytes_range(reader._file, sd.data_off, sd.data_len), sd.ptype, sd.codec, sd.num_values,
            sd.nullable, sd.is_dict,
        )
        if not cur.supported() or not cur.seek_to_row(row_lo, row_hi):
            return None
        var col: Optional[Column[HeapRegion]]
        if ci == 0:
            col = _fill_and_build(cur, ctx.subrg_codes_ref(), n_unit, sd.is_dict, sd.is_float, sd.ptype, sd.dict_i64, sd.dict_f64)
        else:
            col = _fill_and_build(cur, ctx.subrg_value_ref(), n_unit, sd.is_dict, sd.is_float, sd.ptype, sd.dict_i64, sd.dict_f64)
        if not col:
            return None
        rbb.add_column(col.take())
    return Optional(rbb.build(chunk_schema.copy()))
