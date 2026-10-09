# =============================================================================
# CsvSink — write-side Sink that streams its DataFrame to a .csv file.
# =============================================================================
#
# `CsvSink` is the write-side dual of `read_csv` (`komira_parquet.csv_reader`):
# materializes the feeding DataFrame to an RFC-4180-ish CSV file at `path`,
# writing the header row (column names) on `init_sink` and one CSV line per
# row on each `accept_batch`. Move-only (`Movable`, not `Copyable`) — it owns
# an open `FileHandle`; copying it would mean two handles writing one path =
# corruption. Mirrors `ParquetSink` (komira_parquet):
#   - `init_sink(schema)` — probe existence (so we know whether we created the
#     file → may best-effort `unlink` it on error), open `FileHandle(path,"w")`,
#     write the header iff `header` is set.
#   - `accept_batch(rb)` — debug-assert `rb`'s schema arity matches the
#     `init_sink` schema, then write `rb`'s rows as CSV lines.
#   - `finish()` — close the file handle.
#   - `__del__` — if `finish()` was never reached and we created the file,
#     best-effort `unlink` the partial `.csv` (same rule as the Parquet sink: don't
#     leave a half-written file — a plan that raises mid-write leaves nothing).
#
# Options surface (all keyword-only, sane defaults so the common case stays
# `CsvSink("/x.csv")`):
#   - `delimiter: String = ","`   — column separator.
#   - `header: Bool = True`       — write the column-name row.
#   - `quote: String = "\""`      — the RFC-4180 quote character.
#
# CSV value encoding (DuckDB-ish; matches `komira_arrow.csv_emit`'s
# byte-format DECISIONS, with ONE deliberate divergence: `null` → an EMPTY
# field, not the literal `NULL`; `csv_emit` is the parity-harness emitter and uses `NULL` to match
# DuckDB `.mode csv`; `CsvSink` is a user-facing writer and uses the
# empty-field convention that `read_csv` reads back as a default-valued cell):
#   - NULL:            empty field (nothing between the delimiters).
#   - INT (I8..I64, U8..U64):  Mojo `String(i)`.
#   - FLOAT (F16/F32/F64):     Mojo `String(f)` (shortest-round-trip).
#   - BOOL:            `true` / `false` lowercase.
#   - STRING / LARGE_STRING / DICTIONARY:  RFC-4180 — wrap in `quote` iff the
#     value contains the delimiter, the quote char, `\n`, or `\r`; an embedded
#     quote char is doubled.
#   - DATE32:          the int32 day-count (round-trips as INT64 through
#     `read_csv`, which infers Int64 — `read_csv` has no DATE32 inference).
#   - DECIMAL128:      `String(arr.get_as_float(r))` (lossy for >15 sig.
#     digits, but `read_csv` infers FLOAT64 anyway — exact decimal round-trip
#     needs a `read_csv` DECIMAL128 inference path).
#   - NULL-typed column:  every cell is the empty field.
#   - Any other ArrowType:  raises (mirrors `csv_emit._format_column_cells`).
#
# `tests/test_csv_sink_quoting.mojo` pins the exact bytes written for each
# quoting trigger (delimiter, quote, LF, CR) in the header and in data cells;
# `komira_csv`'s reader parses that quoting back and refuses a field with bytes
# after its closing quote.
#
# Pointer rules: `_handle: Optional[FileHandle]` (no `OwnedPointer` needed —
# `FileHandle` is itself an owning handle; the compiler destroys it on `self`'s
# teardown, which closes the fd); the POSIX `access`/`remove` probes derive a
# `c_string` pointer from an owned local `String` (same pattern as
# `streaming_parquet_writer._path_exists` / `_best_effort_unlink`) — no
# wildcard origin, no `unsafe_from_address`, no `UnsafePointer` crossing a
# module boundary.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_FORMAT_WRITE
from std.io import FileHandle

from komira_fs.local_fs import LocalFs, LocalWriteFile
from komira_fs.file_system import WriteMode
from komira_async.ops.waker_sink import NoopSink
from komira_async.cancellation.token import CancellationToken
from komira_async.runtime.local_dispatcher import LocalDispatcher
from std.ffi import external_call
from std.sys import num_physical_cores

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_async_api.worker_pool_traits import KeepAlive, Segment
# Writes go through LocalFs[NoopSink].write_at (64 MiB chunking
# inside the trait body).
from komira_scan_source.sink import Sink
from komira_row_format.row_sink import RowSink
from komira_row_format.row_output import RowOutput
from komira_row_format.row_block import (
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_STRING,
)


# =============================================================================
# Tunables for the parallel CSV write path.
# =============================================================================
#
# Mirrors the read-side tunables in `komira_csv.parallel_reader`.

# Below this row count, fall back to single-thread emit (partition + concat
# overhead exceeds the parallel speedup on small batches).
comptime _CSV_WRITE_MIN_PARALLEL_ROWS: Int = 16 * 1024  # 16K rows

# Cap on worker count. More than 32 workers rarely pays back the
# per-worker setup cost on a single batch.
comptime _CSV_WRITE_MAX_WORKERS: Int = 32

# Estimated bytes per row for buffer pre-reservation. Conservative starting
# point that grows naturally via List doubling; pre-reserving up-front
# avoids the first 5-7 doublings inside the hot row-emit loop.
comptime _CSV_WRITE_BYTES_PER_ROW_ESTIMATE: Int = 64


# =============================================================================
# POSIX helpers — file-existence probe + best-effort unlink (mirrors
# the Parquet writer so the unlink-on-error story is identical).
# =============================================================================


def _path_exists(path: String) -> Bool:
    """Return True if `path` exists (POSIX `access(path, F_OK)` == 0).

    Used by `CsvSink.init_sink` to decide whether we are *creating* the file
    (so we may unlink it on error) or overwriting a pre-existing one (which the
    user may want preserved — same non-transactional `COPY` semantics)."""
    # `as_c_string_slice()` is a mutating method (appends a NUL) — needs an
    # owned local that outlives the external_call. F_OK == 0.
    var p = path
    var rc = external_call["access", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int32(0)
    )
    return rc == 0


def _best_effort_unlink(path: String):
    """Remove `path`, ignoring any error (POSIX `remove`). Best-effort cleanup
    of a half-written `.csv` (a plan that raised mid-write left a partial
    file)."""
    var p = path
    _ = external_call["remove", Int32](p.as_c_string_slice().unsafe_ptr())


# =============================================================================
# RFC-4180 cell formatting (column-major → transpose, like csv_emit).
#
# Why column-major: `RecordBatch` stores columnar; `column_as_*` reconstructs a
# typed array by copying the column's buffer. Per-cell dispatch inside a row
# loop would call `column_as_*` O(R*C) times (R buffer copies per column);
# pre-materializing once per column is O(C) buffer copies + O(C*R) String
# allocs (one per cell) — the lower bound for a row-major text emit of columnar
# data. (Mojo 1.0.0b1 can't hold heterogeneous typed arrays across a heap
# collection, so this column-major-then-transpose shape keeps the typed-array
# materialization out of the inner loop.)
# =============================================================================


def _needs_quoting(s: String, delimiter: String, quote: String) -> Bool:
    """True if `s` must be RFC-4180 quoted (contains the delimiter, the quote
    char, `\\n`, or `\\r`)."""
    if delimiter.byte_length() > 0 and s.find(delimiter) >= 0:
        return True
    if quote.byte_length() > 0 and s.find(quote) >= 0:
        return True
    if s.find("\n") >= 0:
        return True
    if s.find("\r") >= 0:
        return True
    return False


def _write_string_cell(
    mut sink: String, s: String, delimiter: String, quote: String
):
    """Append `s` to `sink` with RFC-4180 quoting iff needed (embedded quote
    char doubled)."""
    if not _needs_quoting(s, delimiter, quote):
        sink.write(s)
        return
    sink.write(quote)
    if quote.byte_length() > 0:
        sink.write(s.replace(quote, quote + quote))
    else:
        sink.write(s)
    sink.write(quote)


# The CSV sink dispatches on the SCHEMA type
# (`field_arrow_type`), which reports the LOGICAL int/float type for a numeric
# dict column (NOT DICTIONARY). So a numeric-dict column would route into the
# INT64/FLOAT64/etc arm and call `col_ref.as_primitive[...]()`, which RAISES an
# "arrow_type mismatch" (the column tag is DICTIONARY). This helper resolves a
# numeric-dict column to its flat logical column wrapped in a 1-column batch so
# the schema-typed arms apply byte-identically to the resolved values; the
# caller recurses on it. Returns None when the column is not a numeric dict
# (the common path — no extra work).
def _numeric_dict_to_flat_batch(
    batch: RecordBatch, col_index: Int
) raises -> Optional[RecordBatch]:
    ref col_ref = batch.column_at(col_index)
    if not col_ref.is_numeric_dict():
        return None
    var flat = col_ref.resolve_numeric_dict_to_flat()
    var sb = SchemaBuilder()
    sb.add_field(
        Field(
            batch.schema.field_name(col_index),
            flat.arrow_type,
            batch.schema.field_nullable(col_index),
        )
    )
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(flat^)
    return rbb.build(sb.build())


def _format_column_cells(
    batch: RecordBatch, col_index: Int, delimiter: String, quote: String
) raises -> List[String]:
    """Materialize column `col_index` of `batch` into a per-row list of
    rendered (already-RFC-4180-escaped where applicable) cell strings. NULL →
    the empty string."""
    var num_rows = batch.num_rows()
    var out = List[String]()
    out.reserve(num_rows)
    # Numeric-dict columns resolve to flat first (see helper).
    var nd = _numeric_dict_to_flat_batch(batch, col_index)
    if nd:
        return _format_column_cells(nd.value(), 0, delimiter, quote)
    # `Column` is Movable but not ImplicitlyCopyable — bind by `ref` (shares
    # the origin-tracked reference from `RecordBatch.column_at()`).
    ref col_ref = batch.column_at(col_index)
    var at = batch.schema.field_arrow_type(col_index)

    if at == ArrowType.INT64:
        var arr = col_ref.as_primitive[DType.int64]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        var arr = col_ref.as_primitive[DType.int32]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.INT16:
        var arr = col_ref.as_primitive[DType.int16]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.INT8:
        var arr = col_ref.as_primitive[DType.int8]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT64:
        var arr = col_ref.as_primitive[DType.uint64]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT32:
        var arr = col_ref.as_primitive[DType.uint32]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT16:
        var arr = col_ref.as_primitive[DType.uint16]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT8:
        var arr = col_ref.as_primitive[DType.uint8]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.FLOAT64:
        var arr = col_ref.as_primitive[DType.float64]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.FLOAT32:
        var arr = col_ref.as_primitive[DType.float32]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.FLOAT16:
        var arr = col_ref.as_primitive[DType.float16]()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.BOOL:
        var arr = col_ref.as_boolean()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("")
            else:
                out.append("true" if arr.get(r) else "false")
    elif at == ArrowType.LARGE_STRING:
        # ⚠ SPLIT OUT OF THE STRING ARM. The two tags shared one
        # arm whose body called `column_as_string`, which had no int64-offset
        # path — so this sink's own error text advertised LARGE_STRING as
        # supported while `COPY (query) TO 'x.csv'` on a promoted column
        # raised `Column.as_string: arrow_type is large_string`.
        #
        # ⛔ DO NOT RE-MERGE THE ARMS via `column_as_string`. Its int64 path
        # NARROWS, and narrowing is refused above the int32 ceiling — i.e. it
        # refuses precisely the column that caused the promotion (a
        # `large_string` column exists here only because it passed 2 GiB).
        # The wide accessor is the only one whose return type can hold it.
        var arr = batch.column_as_large_string(col_index)
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("")
            else:
                var cell = String()
                _write_string_cell(cell, arr.get(r), delimiter, quote)
                out.append(cell^)
    elif at == ArrowType.STRING:
        var arr = batch.column_as_string(col_index)
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("")
            else:
                var cell = String()
                _write_string_cell(cell, arr.get(r), delimiter, quote)
                out.append(cell^)
    elif at == ArrowType.DICTIONARY:
        var arr = col_ref.as_dictionary()
        for r in range(num_rows):
            if arr.indices.is_null(r):
                out.append("")
            else:
                var cell = String()
                _write_string_cell(cell, arr.get(r), delimiter, quote)
                out.append(cell^)
    elif at == ArrowType.DECIMAL128:
        var arr = col_ref.as_decimal128()
        for r in range(num_rows):
            out.append("" if arr.is_null(r) else String(arr.get_as_float(r)))
    elif at == ArrowType.NULL:
        for _ in range(num_rows):
            out.append("")
    else:
        raise Error(
            "CsvSink: unsupported ArrowType '"
            + String(at)
            + "' at column index "
            + String(col_index)
            + ". Supported: INT8/16/32/64, UINT8/16/32/64, FLOAT16/32/64,"
            + " BOOL, STRING, LARGE_STRING, DICTIONARY, DATE32, DECIMAL128,"
            + " NULL."
        )
    return out^


# =============================================================================
# Packed-bytes column format.
#
# `_format_column_cells_packed` is the BEAT-mode replacement for
# `_format_column_cells` (which returns `List[String]`, one heap-alloc per
# cell). For TPC-H SF1 lineitem (21 cols x 6M rows) the String-per-cell shape
# produces ~126M tiny String allocations and forces a second `as_bytes` pass
# in `_emit_row_range_to_bytes`. The packed shape replaces this with ONE
# large `List[UInt8]` buffer per column plus a `List[Int]` offsets table:
#     cells[r] = bytes[offsets[r] .. offsets[r+1]]
# So each column has 2 heap allocations total (bytes + offsets), not
# num_rows. The downstream `_emit_row_range_to_bytes_packed` copies the
# cell bytes directly out of the column's packed buffer (no per-cell
# String round-trip).
#
# The hot per-cell write also uses `String.write(arr.get(r))` (single-arg
# Writable overload in the stdlib) which calls
# `value.write_to(self)` directly — formats the int/float digits IN-PLACE
# into the growing column buffer with no extra _TotalWritableBytes pass and
# no intermediate String alloc per cell.
#
# `null_count == 0` fast path: when the typed array's
# cached `null_count` field is 0 (e.g. a fully non-nullable table), the
# per-row `is_null(r)` branch is elided in every formatter.
# =============================================================================


struct _PackedCells(Movable, Copyable):
    """Column cells packed into one byte buffer with per-row offsets.

    Layout:
        bytes:   List[UInt8] — concatenated cell bytes, already
                 RFC-4180-escaped where applicable. Empty cells contribute
                 zero bytes.
        offsets: List[Int] of length num_rows+1; cell r occupies
                 bytes[offsets[r] .. offsets[r+1]] (`offsets[r+1] ==
                 offsets[r]` for empty/null cells).
    """

    var bytes: List[UInt8]
    var offsets: List[Int]

    def __init__(out self, num_rows: Int, estimated_bytes_per_cell: Int = 8):
        self.bytes = List[UInt8]()
        if num_rows > 0:
            self.bytes.reserve(num_rows * estimated_bytes_per_cell)
        self.offsets = List[Int]()
        self.offsets.reserve(num_rows + 1)
        self.offsets.append(0)


# =============================================================================
# `_PackedBytesWriter` — conforms to the stdlib `Writer` trait, appending
# bytes directly into a borrowed `List[UInt8]`.
#
# Why:
#   - it eliminates a per-cell scratch `String` allocation
#     (`s = String(capacity=32)`), an allocator alloc+free pair per cell —
#     96M pairs per pass over TPC-H SF1 lineitem.
#   - bypasses the `String.write[Writable]` indirection — numeric formatters
#     emit ASCII digits straight into the column's packed bytes buffer.
#
# The borrowed `Pointer[List[UInt8], O]` carries an EXPLICIT (parametric)
# origin O — no wildcard. Caller binds O to the local `_PackedCells.bytes`
# origin at construction time; the writer is fn-local and shares the
# caller's lifetime. `Movable`-only — a
# duplicate writer pointing at the same byte buffer would silently
# interleave writes.
# =============================================================================


struct _PackedBytesWriter[buf_origin: Origin[mut=True]](Movable, Writer):
    """`Writer`-trait conformer that appends bytes to a borrowed
    `List[UInt8]`. Used as the per-cell write target on the packed-bytes
    column-format hot path; the `Writable.write_to(W)` machinery resolves
    `writer.write_bytes(span)` straight to a single `List.extend(Span)`
    memcpy — no scratch String, no per-cell heap traffic."""

    # SAFETY: `_bytes` borrows a `List[UInt8]` from the caller; the
    # parametric `buf_origin` ties this struct's lifetime to that owner. The
    # writer is constructed and used inside one fn-local scope and never
    # escapes — it stays alive for the duration of one column's format pass.
    var _bytes: Pointer[List[UInt8], Self.buf_origin]

    def __init__(out self, ref [Self.buf_origin] bytes: List[UInt8]):
        self._bytes = Pointer(to=bytes)

    @always_inline
    def write_bytes(mut self, bytes: Span[UInt8, _]):
        """`Writer` trait method — append `bytes` to the target buffer.
        Calls `List.extend(Span)` which dispatches to `uninit_copy_n`
        (memcpy)."""
        self._bytes[].extend(bytes)

    @always_inline
    def write_string(mut self, s: StringSlice[_]):
        """`Writer` trait method — append UTF-8 bytes of `s` to the
        target buffer. Bypasses any String copy; `StringSlice.as_bytes()`
        is an origin-tracked view, not a heap copy."""
        self._bytes[].extend(s.as_bytes())

    @always_inline
    def write[*Ts: Writable](mut self, *args: *Ts):
        """`Writer` trait `write(*args)` — for each Writable arg, call
        `arg.write_to(self)`. Matches stdlib `Writer` convention so
        `arr.get(r).write_to(writer)` AND `String.write[*Writable]` both
        dispatch correctly."""

        comptime for i in range(args.__len__()):
            args[i].write_to(self)


def _append_string_to_bytes(mut out: List[UInt8], s: String):
    """Bulk-append `s.as_bytes()` to `out` via stdlib `List.extend(Span)`
    which calls `uninit_copy_n` (memcpy) — much cheaper than the
    per-byte append loop that an earlier version of this helper used.
    """
    out.extend(s.as_bytes())


def _needs_quoting_bytes(s: String, delimiter: String, quote: String) -> Bool:
    """Same as `_needs_quoting` — kept distinct to avoid mixing the
    String-cell and packed-bytes call shapes during code review."""
    if delimiter.byte_length() > 0 and s.find(delimiter) >= 0:
        return True
    if quote.byte_length() > 0 and s.find(quote) >= 0:
        return True
    if s.find("\n") >= 0:
        return True
    if s.find("\r") >= 0:
        return True
    return False


def _write_string_cell_to_bytes(
    mut out: List[UInt8], s: String, delimiter: String, quote: String
):
    """RFC-4180 escape `s` directly into `out` (no intermediate String
    cell allocation). Common path: NO trigger char → bulk-copy bytes."""
    if not _needs_quoting_bytes(s, delimiter, quote):
        _append_string_to_bytes(out, s)
        return
    # Quoted form.
    _append_string_to_bytes(out, quote)
    if quote.byte_length() > 0:
        _append_string_to_bytes(out, s.replace(quote, quote + quote))
    else:
        _append_string_to_bytes(out, s)
    _append_string_to_bytes(out, quote)


def _format_column_cells_packed(
    batch: RecordBatch, col_index: Int, delimiter: String, quote: String
) raises -> _PackedCells:
    """Packed-bytes mirror of `_format_column_cells`: byte-identical
    output, single growing byte buffer + offsets table instead of
    `List[String]`. See `_PackedCells` doc.

    Per-cell hot path uses `_PackedBytesWriter` to dispatch
    `arr.get(r).write_to(writer)` STRAIGHT into `out.bytes` — no per-row
    `String` allocation, no per-cell intermediate memcpy. Each numeric
    arm reuses one `_PackedBytesWriter` borrow on `out.bytes` for all
    `num_rows` cells; the writer is fn-local and shares the column-format
    pass's lifetime.
    """
    var num_rows = batch.num_rows()
    # Numeric-dict columns resolve to flat first (see helper on
    # `_format_column_cells`) — the schema-typed arms below would otherwise call
    # `as_primitive` on a DICTIONARY-tagged column and RAISE a mismatch.
    var nd = _numeric_dict_to_flat_batch(batch, col_index)
    if nd:
        return _format_column_cells_packed(nd.value(), 0, delimiter, quote)
    ref col_ref = batch.column_at(col_index)
    var at = batch.schema.field_arrow_type(col_index)
    # Cell-byte-width estimate seeds the bytes-buffer reserve. Conservative
    # average across narrow ints (4-8 bytes) and short strings (<32) =
    # an 8-byte starting estimate; List doubling absorbs underestimates
    # cheaply.
    var out = _PackedCells(num_rows, 8)

    # `has_nulls` predicate hoisted per arm — `arr.validity is None` means
    # every `is_null(r)` returns False (`PrimitiveArray.is_null`), so the
    # per-row null-guard becomes dead in the non-nullable case. The
    # `_PackedBytesWriter` reuses one borrow on `out.bytes` for every cell
    # — `arr.get(r).write_to(writer)` appends ASCII digits straight into
    # the column buffer.

    if at == ArrowType.INT64:
        var arr = col_ref.as_primitive[DType.int64]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        if has_nulls:
            for r in range(num_rows):
                if arr.is_null(r):
                    out.offsets.append(len(out.bytes))
                else:
                    arr.get(r).write_to(writer)
                    out.offsets.append(len(out.bytes))
        else:
            for r in range(num_rows):
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        var arr = col_ref.as_primitive[DType.int32]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        if has_nulls:
            for r in range(num_rows):
                if arr.is_null(r):
                    out.offsets.append(len(out.bytes))
                else:
                    arr.get(r).write_to(writer)
                    out.offsets.append(len(out.bytes))
        else:
            for r in range(num_rows):
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.INT16:
        var arr = col_ref.as_primitive[DType.int16]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.INT8:
        var arr = col_ref.as_primitive[DType.int8]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.UINT64:
        var arr = col_ref.as_primitive[DType.uint64]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.UINT32:
        var arr = col_ref.as_primitive[DType.uint32]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.UINT16:
        var arr = col_ref.as_primitive[DType.uint16]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.UINT8:
        var arr = col_ref.as_primitive[DType.uint8]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.FLOAT64:
        var arr = col_ref.as_primitive[DType.float64]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        if has_nulls:
            for r in range(num_rows):
                if arr.is_null(r):
                    out.offsets.append(len(out.bytes))
                else:
                    arr.get(r).write_to(writer)
                    out.offsets.append(len(out.bytes))
        else:
            for r in range(num_rows):
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.FLOAT32:
        var arr = col_ref.as_primitive[DType.float32]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.FLOAT16:
        var arr = col_ref.as_primitive[DType.float16]()
        var has_nulls = Bool(arr.validity)
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.BOOL:
        var arr = col_ref.as_boolean()
        # `null_count == 0` is unreliable here — `PrimitiveArray._set_null`
        # in the wider codebase does not increment `null_count`, so a
        # post-builder array with null cells can have `null_count == 0`.
        # The safe predicate is "no validity bitmap" (allocated as
        # non-nullable). When `validity is None` every `is_null(r)`
        # returns False (see `PrimitiveArray.is_null`), so the per-row
        # null-guard is hoistable.
        var has_nulls = Bool(arr.validity)
        for r in range(num_rows):
            if has_nulls and arr.is_null(r):
                out.offsets.append(len(out.bytes))
            elif arr.get(r):
                out.bytes.append(116)  # 't'
                out.bytes.append(114)  # 'r'
                out.bytes.append(117)  # 'u'
                out.bytes.append(101)  # 'e'
                out.offsets.append(len(out.bytes))
            else:
                out.bytes.append(102)  # 'f'
                out.bytes.append(97)   # 'a'
                out.bytes.append(108)  # 'l'
                out.bytes.append(115)  # 's'
                out.bytes.append(101)  # 'e'
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.LARGE_STRING:
        # The int64-offset twin of the STRING arm below, split for the reason
        # given at the same split in `_format_column_cells`: the shared arm
        # named LARGE_STRING but its body could not serve it. Body is
        # otherwise identical, including the `has_nulls` hoist — the null
        # predicate and the escape are width-independent; only the offset
        # width is not.
        var arr = batch.column_as_large_string(col_index)
        var has_nulls_w = Bool(arr.validity)
        if has_nulls_w:
            for r in range(num_rows):
                if arr.is_null(r):
                    out.offsets.append(len(out.bytes))
                else:
                    _write_string_cell_to_bytes(
                        out.bytes, arr.get(r), delimiter, quote
                    )
                    out.offsets.append(len(out.bytes))
        else:
            for r in range(num_rows):
                _write_string_cell_to_bytes(
                    out.bytes, arr.get(r), delimiter, quote
                )
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.STRING:
        var arr = batch.column_as_string(col_index)
        # `null_count == 0` is unreliable here — `PrimitiveArray._set_null`
        # in the wider codebase does not increment `null_count`, so a
        # post-builder array with null cells can have `null_count == 0`.
        # The safe predicate is "no validity bitmap" (allocated as
        # non-nullable). When `validity is None` every `is_null(r)`
        # returns False (see `PrimitiveArray.is_null`), so the per-row
        # null-guard is hoistable.
        var has_nulls = Bool(arr.validity)
        if has_nulls:
            for r in range(num_rows):
                if arr.is_null(r):
                    out.offsets.append(len(out.bytes))
                else:
                    _write_string_cell_to_bytes(
                        out.bytes, arr.get(r), delimiter, quote
                    )
                    out.offsets.append(len(out.bytes))
        else:
            for r in range(num_rows):
                _write_string_cell_to_bytes(
                    out.bytes, arr.get(r), delimiter, quote
                )
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.DICTIONARY:
        var arr = col_ref.as_dictionary()
        var has_nulls = Bool(arr.indices.validity)
        for r in range(num_rows):
            if has_nulls and arr.indices.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                _write_string_cell_to_bytes(
                    out.bytes, arr.get(r), delimiter, quote
                )
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.DECIMAL128:
        var arr = col_ref.as_decimal128()
        var writer = _PackedBytesWriter(out.bytes)
        for r in range(num_rows):
            if arr.is_null(r):
                out.offsets.append(len(out.bytes))
            else:
                arr.get_as_float(r).write_to(writer)
                out.offsets.append(len(out.bytes))
    elif at == ArrowType.NULL:
        # All cells empty; emit num_rows zero-width offsets.
        for _ in range(num_rows):
            out.offsets.append(0)
    else:
        raise Error(
            "CsvSink: unsupported ArrowType '"
            + String(at)
            + "' at column index "
            + String(col_index)
            + ". Supported: INT8/16/32/64, UINT8/16/32/64, FLOAT16/32/64,"
            + " BOOL, STRING, LARGE_STRING, DICTIONARY, DATE32, DECIMAL128,"
            + " NULL."
        )
    return out^


# =============================================================================
# Per-column packed-format driver — LocalDispatcher.run_with_state dispatch
# =============================================================================
#
# Dispatches through `LocalDispatcher.run_with_state` (library code never
# calls stdlib `parallelize` directly). The canonical State/Task shape:
#   * `_CsvFormatColsState[rb_o]` OWNS the per-dispatch outputs
#     (`columns`, `errors`) + the owned `delimiter` / `quote` copies;
#     BORROWS the caller-owned `rb` read-only via a typed-origin pointer
#     (no MutExternalOrigin).
#   * `_CsvFormatColsTask[rb_o]` carries a single Int32 discriminator and
#     bitcasts to the concrete State at the top of `execute`.
#   * Three entry points per the canonical split:
#     - `_parallel_format_columns_packed` — serial fallback (no dispatcher)
#     - `_parallel_format_columns_packed_with_dispatcher[disp_o]` — parallel
#     - `_parallel_format_columns_packed_impl[has_pool, disp_o]` — shared body
#
# DISPATCH-BOUNDARY SAFETY:
#   * Disjointness: task `tid` writes ONLY `columns[c]` / `errors[c]` for
#     buffer indices `c` with `c % n_workers == tid`; every column maps to
#     exactly one task. Reads of `rb` / `delimiter` / `quote` are read-only.
#   * Liveness: `run_with_state` is a synchronous wake-word barrier; the
#     caller-owned `rb` outlives the helper by stack discipline; State is
#     moved into run_with_state atomically.
#   * No-realloc: `columns` / `errors` are pre-sized to `num_cols` before
#     dispatch; workers ONLY mutate via index assignment.
# =============================================================================


struct _CsvFormatColsState[
    rb_o: ImmOrigin,
](KeepAlive, Movable):
    """State for per-column parallel packed-format dispatch.

    OWNS the per-dispatch `columns` / `errors` outputs + the `delimiter` /
    `quote` copies; BORROWS the caller-owned `rb` read-only via typed-origin
    pointer. ZERO wildcard fields.

    Owned outputs reclaimed via `Optional.take()` at dispatch return
    (never a partial move out of a field).
    """

    # Borrowed read-only input — pinned to caller via `rb_o`.
    # SAFETY: Internal typed pointer — never exposed to public API. The
    # `rb_o: ImmutOrigin` parameter is CONCRETE (not wildcard), so this is
    # the canonical typed-origin-borrow pattern (no stale-pointer hazard across destroy and recreate).
    var rb_ptr: UnsafePointer[RecordBatch, Self.rb_o]
    # OWNED outputs (Optional.take pattern so the State drop sees None
    # placeholders rather than moved-out bits).
    var columns: Optional[List[_PackedCells]]
    var errors: Optional[List[Optional[String]]]
    # OWNED read-only scalars (copied into State; workers read only).
    var delimiter: String
    var quote: String
    var num_cols: Int
    var n_workers: Int

    def __init__(
        out self,
        rb_ptr: UnsafePointer[RecordBatch, Self.rb_o],
        var columns: List[_PackedCells],
        var errors: List[Optional[String]],
        var delimiter: String,
        var quote: String,
        num_cols: Int,
        n_workers: Int,
    ):
        self.rb_ptr = rb_ptr
        self.columns = Optional[List[_PackedCells]](columns^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.delimiter = delimiter^
        self.quote = quote^
        self.num_cols = num_cols
        self.n_workers = n_workers


@fieldwise_init
struct _CsvFormatColsTask[
    rb_o: ImmOrigin,
](Segment):
    """POD Segment for `_CsvFormatColsState` dispatch — n_workers tasks,
    stride-partitioned across [0, num_cols)."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_CsvFormatColsState[rb_o], _CsvFormatColsTask[rb_o]); the bitcast
        # resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _CsvFormatColsState[Self.rb_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var num_cols_local = sp[].num_cols
        var c = tid
        while c < num_cols_local:
            try:
                var cells = _format_column_cells_packed(
                    sp[].rb_ptr[], c, sp[].delimiter, sp[].quote
                )
                sp[].columns.value()[c] = cells^
            except e:
                sp[].errors.value()[c] = Optional[String](String(e))
            c = c + n_workers


def _parallel_format_columns_packed(
    rb: RecordBatch, delimiter: String, quote: String
) raises -> List[_PackedCells]:
    """Serial-fallback wrapper for
    `_parallel_format_columns_packed_with_dispatcher`.

    The dispatcher-less entry point: the per-column work runs serially.
    Callers without a EngineContext-owned dispatcher (e.g. test fixtures,
    the bench harness) hit this entry point.
    """
    return _parallel_format_columns_packed_impl[
        has_pool=False, disp_o=MutAnyOrigin,
    ](
        rb,
        delimiter,
        quote,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def _parallel_format_columns_packed_with_dispatcher[
    disp_o: Origin[mut=True],
](
    rb: RecordBatch,
    delimiter: String,
    quote: String,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> List[_PackedCells]:
    """Dispatcher-aware variant — typed-origin dispatcher required.

    Threads `dispatcher_ptr` + `cancel_token` from the calling
    EngineContext down to `LocalDispatcher.run_with_state` for the parallel
    per-column packed format.
    """
    return _parallel_format_columns_packed_impl[
        has_pool=True, disp_o=disp_o,
    ](
        rb,
        delimiter,
        quote,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _parallel_format_columns_packed_impl[
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    rb: RecordBatch,
    delimiter: String,
    quote: String,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> List[_PackedCells]:
    """Per-column packed-format driver. Dispatches one task per worker via
    LocalDispatcher.run_with_state when `has_pool=True`; otherwise (no
    dispatcher / single column) walks the columns serially.

    Comptime `has_pool` flag prunes the parallel/serial branch — no wildcard
    origin reaches the dispatch in either path (canonical template pattern).
    """
    var num_cols = rb.num_columns()
    var columns = List[_PackedCells]()
    columns.reserve(num_cols)
    var i = 0
    while i < num_cols:
        columns.append(_PackedCells(0))
        i = i + 1
    if num_cols == 0:
        _ = cancel_token^
        return columns^
    if num_cols == 1:
        _ = cancel_token^
        columns[0] = _format_column_cells_packed(rb, 0, delimiter, quote)
        return columns^

    var col_errors = List[Optional[String]]()
    var ce_idx = 0
    while ce_idx < num_cols:
        col_errors.append(Optional[String](None))
        ce_idx = ce_idx + 1

    comptime if has_pool:
        # Resolve effective worker count: cap at min(num_cols, cores).
        var n_workers = num_physical_cores()
        if n_workers > num_cols:
            n_workers = num_cols
        if n_workers < 1:
            n_workers = 1

        # DISPATCH-BOUNDARY: build State + Task; dispatch via
        # LocalDispatcher.run_with_state. typed origins; no
        # MutExternalOrigin wildcards. `rb` is borrowed read-only via a
        # typed-origin pointer anchored on the read-only input's origin
        # (immutable-origin lesson — anchor
        # on the borrowed input, NOT a mutable local).
        comptime rb_o = origin_of(rb)
        var rb_ptr = UnsafePointer(to=rb).unsafe_origin_cast[rb_o]()
        var state = _CsvFormatColsState[rb_o](
            rb_ptr,
            columns^,
            col_errors^,
            delimiter,
            quote,
            num_cols,
            n_workers,
        )
        var task = _CsvFormatColsTask[rb_o](Int32(0))
        var disp = dispatcher_ptr.value()
        _ = disp[].run_with_state[
            _CsvFormatColsState[rb_o],
            _CsvFormatColsTask[rb_o],
        ](state, task^, n_workers, cancel_token^, site_id=SITE_FORMAT_WRITE)
        # Reclaim the outputs from State via Optional.take (never a
        # partial move through UnsafePointer).
        columns = state.columns.take()
        col_errors = state.errors.take()
        _ = state^
    else:
        # has_pool=False: serial per-column loop on the same lists.
        _ = cancel_token^
        var c = 0
        while c < num_cols:
            try:
                columns[c] = _format_column_cells_packed(
                    rb, c, delimiter, quote
                )
            except e:
                col_errors[c] = Optional[String](String(e))
            c = c + 1

    var e_idx = 0
    while e_idx < num_cols:
        if col_errors[e_idx]:
            var msg = col_errors[e_idx].value().copy()
            raise Error(
                String("CsvSink: column ")
                + String(e_idx)
                + String(" format (packed) failed: ")
                + msg
            )
        e_idx = e_idx + 1
    return columns^


def _emit_row_range_to_bytes_packed(
    columns: List[_PackedCells],
    row_lo: Int,
    row_hi: Int,
    delimiter: String,
    estimated_bytes: Int,
) -> List[UInt8]:
    """Packed-bytes mirror of `_emit_row_range_to_bytes`. Reads cell bytes
    directly from each column's packed buffer (no per-cell String round-
    trip), interleaves with `delimiter` between cells and `\\n` at row
    end."""
    var out = List[UInt8]()
    if estimated_bytes > 0:
        out.reserve(estimated_bytes)
    var num_cols = len(columns)
    var delim_bytes = delimiter.as_bytes()
    var nl_byte: UInt8 = 10
    var r = row_lo
    while r < row_hi:
        var c = 0
        while c < num_cols:
            if c > 0:
                # Bulk-copy delimiter bytes (common case: 1 byte).
                out.extend(delim_bytes)
            ref col = columns[c]
            var off_lo = col.offsets[r]
            var off_hi = col.offsets[r + 1]
            if off_hi > off_lo:
                # Bulk-copy cell bytes via Span slice over the column's
                # packed buffer — single memcpy per cell.
                out.extend(Span(col.bytes)[off_lo:off_hi])
            c = c + 1
        out.append(nl_byte)
        r = r + 1
    return out^


# =============================================================================
# Per-row-range packed-emit driver — LocalDispatcher.run_with_state dispatch
# =============================================================================
#
# Mirror of the per-column
# format driver above for the row-range emit stage, on
# `LocalDispatcher.run_with_state`.
#   * `_CsvEmitRowsState[cols_o]` OWNS the per-dispatch `per_worker_bytes`
#     output + the row-partition `row_los` / `row_his` + the `delimiter`
#     copy; BORROWS the caller-owned `columns` read-only via a typed-origin
#     pointer (no MutExternalOrigin).
#   * `_CsvEmitRowsTask[cols_o]` carries a single Int32 discriminator; the
#     task partitioning is one row-range per task_id (n_workers tasks),
#     each writes EXACTLY `per_worker_bytes[tid]`.
#
# DISPATCH-BOUNDARY SAFETY:
#   * Disjointness: task `tid` writes ONLY `per_worker_bytes[tid]` (one
#     row-range buffer). Reads of `columns` / `row_los` / `row_his` /
#     `delimiter` are read-only. Each tid maps to exactly one buffer slot.
#   * Liveness: `run_with_state` is a synchronous wake-word barrier; the
#     caller-owned `columns` outlives the helper by stack discipline.
#   * No-realloc: `per_worker_bytes` is pre-sized to `n_workers` before
#     dispatch; workers ONLY mutate via index assignment.
# =============================================================================


struct _CsvEmitRowsState[
    cols_o: ImmOrigin,
](KeepAlive, Movable):
    """State for per-row-range parallel packed-emit dispatch.

    OWNS the per-dispatch `per_worker_bytes` output + the row-partition
    bounds + the `delimiter` copy; BORROWS the caller-owned `columns`
    read-only via typed-origin pointer. ZERO wildcard fields.

    Owned output reclaimed via `Optional.take()` at dispatch return
    (never a partial move out of a field).
    """

    # Borrowed read-only input — pinned to caller via `cols_o`.
    # SAFETY: Internal typed pointer — never exposed to public API. The
    # `cols_o: ImmutOrigin` parameter is CONCRETE (not wildcard).
    var cols_ptr: UnsafePointer[List[_PackedCells], Self.cols_o]
    # OWNED output (Optional.take pattern).
    var per_worker_bytes: Optional[List[List[UInt8]]]
    # OWNED per-worker row-partition bounds + scalars (workers read only).
    var row_los: Optional[List[Int]]
    var row_his: Optional[List[Int]]
    var delimiter: String
    var avg_row_bytes: Int
    var n_workers: Int

    def __init__(
        out self,
        cols_ptr: UnsafePointer[List[_PackedCells], Self.cols_o],
        var per_worker_bytes: List[List[UInt8]],
        var row_los: List[Int],
        var row_his: List[Int],
        var delimiter: String,
        avg_row_bytes: Int,
        n_workers: Int,
    ):
        self.cols_ptr = cols_ptr
        self.per_worker_bytes = Optional[List[List[UInt8]]](per_worker_bytes^)
        self.row_los = Optional[List[Int]](row_los^)
        self.row_his = Optional[List[Int]](row_his^)
        self.delimiter = delimiter^
        self.avg_row_bytes = avg_row_bytes
        self.n_workers = n_workers


@fieldwise_init
struct _CsvEmitRowsTask[
    cols_o: ImmOrigin,
](Segment):
    """POD Segment for `_CsvEmitRowsState` dispatch — n_workers tasks, one
    row-range per task_id."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_CsvEmitRowsState[cols_o], _CsvEmitRowsTask[cols_o]); the bitcast
        # resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _CsvEmitRowsState[Self.cols_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        # One row-range per task_id; stride is a no-op (n tasks == n ranges).
        var w = tid
        while w < n_workers:
            var lo = sp[].row_los.value()[w]
            var hi = sp[].row_his.value()[w]
            var rows_this_worker = hi - lo
            var est = rows_this_worker * sp[].avg_row_bytes
            var buf = _emit_row_range_to_bytes_packed(
                sp[].cols_ptr[], lo, hi, sp[].delimiter, est
            )
            sp[].per_worker_bytes.value()[w] = buf^
            w = w + n_workers


def _parallel_emit_rows_packed(
    columns: List[_PackedCells],
    num_rows: Int,
    delimiter: String,
    n_workers: Int,
) raises -> List[List[UInt8]]:
    """Serial-fallback wrapper for
    `_parallel_emit_rows_packed_with_dispatcher`.

    The dispatcher-less entry point: the per-row-range work runs serially.
    """
    return _parallel_emit_rows_packed_impl[
        has_pool=False, disp_o=MutAnyOrigin,
    ](
        columns,
        num_rows,
        delimiter,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def _parallel_emit_rows_packed_with_dispatcher[
    disp_o: Origin[mut=True],
](
    columns: List[_PackedCells],
    num_rows: Int,
    delimiter: String,
    n_workers: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> List[List[UInt8]]:
    """Dispatcher-aware variant — typed-origin dispatcher required."""
    return _parallel_emit_rows_packed_impl[
        has_pool=True, disp_o=disp_o,
    ](
        columns,
        num_rows,
        delimiter,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _parallel_emit_rows_packed_impl[
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    columns: List[_PackedCells],
    num_rows: Int,
    delimiter: String,
    n_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> List[List[UInt8]]:
    """Per-row-range packed-emit driver. Dispatches one task per worker via
    LocalDispatcher.run_with_state when `has_pool=True`; otherwise walks the
    row ranges serially. Returns per-worker byte buffers in worker order for
    ordered fan-in.

    Comptime `has_pool` flag prunes the parallel/serial branch.
    """
    var per_worker_bytes = List[List[UInt8]]()
    var idx = 0
    while idx < n_workers:
        per_worker_bytes.append(List[UInt8]())
        idx = idx + 1
    var row_los = List[Int]()
    var row_his = List[Int]()
    var rows_per_worker = num_rows // n_workers
    var w0 = 0
    while w0 < n_workers:
        var lo = w0 * rows_per_worker
        var hi = lo + rows_per_worker
        if w0 == n_workers - 1:
            hi = num_rows
        row_los.append(lo)
        row_his.append(hi)
        w0 = w0 + 1

    # Estimate per-worker buffer bytes from rough cell-size heuristic.
    var num_cols = len(columns)
    var avg_row_bytes = 8 * num_cols + 16
    if avg_row_bytes < _CSV_WRITE_BYTES_PER_ROW_ESTIMATE:
        avg_row_bytes = _CSV_WRITE_BYTES_PER_ROW_ESTIMATE

    comptime if has_pool:
        # DISPATCH-BOUNDARY: build State + Task; dispatch via
        # LocalDispatcher.run_with_state. typed origins; no wildcards.
        # `columns` is borrowed read-only via a typed-origin pointer
        # anchored on the read-only input's immutable origin (immutable-
        # origin lesson — anchor on the borrowed input, NOT a mutable
        # local).
        comptime cols_o = origin_of(columns)
        var cols_ptr = UnsafePointer(to=columns).unsafe_origin_cast[cols_o]()
        var state = _CsvEmitRowsState[cols_o](
            cols_ptr,
            per_worker_bytes^,
            row_los^,
            row_his^,
            delimiter,
            avg_row_bytes,
            n_workers,
        )
        var task = _CsvEmitRowsTask[cols_o](Int32(0))
        var disp = dispatcher_ptr.value()
        _ = disp[].run_with_state[
            _CsvEmitRowsState[cols_o],
            _CsvEmitRowsTask[cols_o],
        ](state, task^, n_workers, cancel_token^, site_id=SITE_FORMAT_WRITE)
        per_worker_bytes = state.per_worker_bytes.take()
        _ = state^
    else:
        # has_pool=False: serial per-row-range loop.
        _ = cancel_token^
        var w = 0
        while w < n_workers:
            var lo = row_los[w]
            var hi = row_his[w]
            var rows_this_worker = hi - lo
            var est = rows_this_worker * avg_row_bytes
            var buf = _emit_row_range_to_bytes_packed(
                columns, lo, hi, delimiter, est
            )
            per_worker_bytes[w] = buf^
            w = w + 1

    return per_worker_bytes^


# =============================================================================
# Row-native CSV emit.
#
# `_emit_row_output_to_bytes` serializes a `RowOutput`'s RowBlocks DIRECTLY to
# CSV text — no row->columnar->row-text bridge. It produces BYTE-IDENTICAL
# output to the columnar `accept_batch` path by reusing the EXACT same cell
# rules:
#   * numeric cells render via `String(value)` (the same shortest-round-trip
#     route `_format_column_cells` uses), appended RAW (no quoting).
#   * STRING cells go through `_write_string_cell` (the same RFC-4180 quoting /
#     escaping the column path applies).
#   * NULL cells render as the EMPTY field (the same convention the column path
#     uses — `is_cell_null` on the RowBlock's internal bit=1==NULL bitmap).
#   * cells are joined by `delimiter`; each row ends in `\n`.
#
# Encapsulation: reads cells via RowBlock's PUBLIC `read_fixed[DT]` /
# `read_var_string_at` / `is_cell_null` (encapsulated pointer arithmetic). No
# raw pointer crosses a boundary; no wildcard origin.
# =============================================================================


def _emit_row_output_to_bytes(
    imm ro: RowOutput, delimiter: String, quote: String
) raises -> List[UInt8]:
    """Serialize every row of `ro` to CSV text bytes, byte-identical to the
    columnar `_emit_row_range_to_bytes_packed` path."""
    var out = List[UInt8]()
    ref layout = ro.layout
    var n_cols = layout.n_cols()
    var has_validity = layout.has_validity
    var vo = layout.validity_offset
    var n_rows = ro.total_rows()
    # Conservative pre-reserve to skip the first List doublings.
    out.reserve(n_rows * (8 * n_cols + 16))
    var delim_bytes = delimiter.as_bytes()
    var nl_byte: UInt8 = 10  # '\n'

    for bi in range(len(ro.blocks)):
        ref blk = ro.blocks[bi]
        for r in range(blk.n_rows):
            var c = 0
            while c < n_cols:
                if c > 0:
                    out.extend(delim_bytes)
                var off = layout.offsets[c]
                var dt = layout.dtype_tags[c]
                var is_null = has_validity and blk.is_cell_null(r, vo, c)
                if is_null:
                    pass  # empty field
                elif dt == DT_I64:
                    var cell = String(blk.read_fixed[DType.int64](r, off))
                    out.extend(cell.as_bytes())
                elif dt == DT_I32:
                    var cell = String(blk.read_fixed[DType.int32](r, off))
                    out.extend(cell.as_bytes())
                elif dt == DT_F64:
                    var cell = String(blk.read_fixed[DType.float64](r, off))
                    out.extend(cell.as_bytes())
                elif dt == DT_F32:
                    var cell = String(blk.read_fixed[DType.float32](r, off))
                    out.extend(cell.as_bytes())
                elif dt == DT_STRING:
                    var raw = blk.read_var_string_at(r, off)
                    var s = String(StringSlice(unsafe_from_utf8=Span(raw)))
                    var cell = String()
                    _write_string_cell(cell, s, delimiter, quote)
                    out.extend(cell.as_bytes())
                else:
                    raise Error(
                        "CsvSink.accept_row_blocks: output DType tag "
                        + String(Int(dt))
                        + " outside the row-streaming supported subset."
                    )
                c = c + 1
            out.append(nl_byte)
    return out^


# =============================================================================
# Parallel pwrite_at fan-out driver — LocalDispatcher.run_with_state dispatch
# =============================================================================
#
# Stage-3 of the CSV write
# path: each per-worker byte buffer is pwrite(2)'d to a DISJOINT file range,
# dispatched through `LocalDispatcher.run_with_state`.
#
#   * `_CsvPwriteState[fd_o]` OWNS the `errors` output + BORROWS (read-only)
#     the caller-owned `LocalWriteFile` fd + the `per_worker_bytes` /
#     `worker_offsets` driver locals via typed-origin pointers. `pwrite_at`
#     takes both `self` and `file` NON-MUT (POSIX disjoint-range concurrent-
#     safe path), so the fd is borrowed through an ImmutOrigin pointer.
#   * `_CsvPwriteTask[fd_o, bufs_o, offs_o]` carries a single Int32
#     discriminator; bitcasts to the concrete State at the top of `execute`.
#
# DISPATCH-BOUNDARY SAFETY:
#   * Disjointness: task `tid` pwrites `per_worker_bytes[tid]` to file range
#     [worker_offsets[tid], worker_offsets[tid]+len). The prefix-sum
#     construction guarantees range tid ends exactly where range tid+1
#     begins; no two tasks' file ranges overlap. POSIX pwrite(2) is atomic
#     per call for regular files and concurrent disjoint-range calls on the
#     same fd do not race. Per-task `errors[tid]` is also disjoint.
#   * Liveness: `run_with_state` is a synchronous wake-word barrier; the
#     caller-owned fd + driver locals outlive the helper by stack discipline.
#   * No-realloc: `errors`, `per_worker_bytes`, `worker_offsets` are all
#     pre-sized before dispatch; workers ONLY read their slot + write
#     `errors[tid]`.
#   * Encapsulation: no UnsafePointer crosses the public signature; the raw
#     fd + ptr arithmetic is confined to `RawWriteFd.pwrite_at`.
# =============================================================================


struct _CsvPwriteState[
    fd_o: ImmOrigin,
    bufs_o: ImmOrigin,
    offs_o: ImmOrigin,
](KeepAlive, Movable):
    """State for the parallel pwrite_at fan-out dispatch.

    OWNS the per-task `errors` slot; BORROWS the caller-owned fd +
    `per_worker_bytes` + `worker_offsets` read-only via typed-origin
    pointers. ZERO wildcard fields.

    `errors` reclaimed via `Optional.take()` post-dispatch for the drain.
    """

    # Borrowed read-only fd — pinned to caller via `fd_o`. pwrite_at takes
    # `file` NON-MUT, so an ImmutOrigin borrow is correct.
    # SAFETY: Internal typed pointer — never exposed to public API.
    var fd_ptr: UnsafePointer[LocalWriteFile, Self.fd_o]
    # Borrowed read-only per-worker byte buffers + offsets.
    # SAFETY: Internal typed pointers — never exposed to public API.
    var bufs_ptr: UnsafePointer[List[List[UInt8]], Self.bufs_o]
    var offs_ptr: UnsafePointer[List[Int], Self.offs_o]
    # OWNED per-task error slot (Optional.take pattern).
    var errors: Optional[List[Optional[String]]]
    var n_workers: Int

    def __init__(
        out self,
        fd_ptr: UnsafePointer[LocalWriteFile, Self.fd_o],
        bufs_ptr: UnsafePointer[List[List[UInt8]], Self.bufs_o],
        offs_ptr: UnsafePointer[List[Int], Self.offs_o],
        var errors: List[Optional[String]],
        n_workers: Int,
    ):
        self.fd_ptr = fd_ptr
        self.bufs_ptr = bufs_ptr
        self.offs_ptr = offs_ptr
        self.errors = Optional[List[Optional[String]]](errors^)
        self.n_workers = n_workers


@fieldwise_init
struct _CsvPwriteTask[
    fd_o: ImmOrigin,
    bufs_o: ImmOrigin,
    offs_o: ImmOrigin,
](Segment):
    """POD Segment for `_CsvPwriteState` dispatch — n_workers tasks, one
    pwrite fan-out per task_id."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_CsvPwriteState[fd_o, bufs_o, offs_o], _CsvPwriteTask[...]); the
        # bitcast resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _CsvPwriteState[Self.fd_o, Self.bufs_o, Self.offs_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var w = tid
        while w < n_workers:
            try:
                var w_off = sp[].offs_ptr[][w]
                var w_buf_span = Span(sp[].bufs_ptr[][w])
                # FFI-BOUNDARY: pwrite_at writes to the disjoint file range
                # owned by task `w`. `LocalFs[NoopSink].new()` is a stateless
                # handle; pwrite_at takes both self + file NON-MUT (the
                # POSIX disjoint-range concurrent-safe path).
                var fs = LocalFs[NoopSink].new()
                _ = fs.pwrite_at(
                    sp[].fd_ptr[], Int64(w_off), w_buf_span
                )
            except e:
                sp[].errors.value()[w] = Optional[String](String(e))  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
            w = w + n_workers


# =============================================================================
# CsvSink
# =============================================================================


struct CsvSink(RowSink, Movable):
    """A write destination that materializes its feeding DataFrame to a CSV
    file at `path`, writing the header on `init_sink` and one line per row on
    each `accept_batch`.

        ctx.run(df^.write_to(CsvSink("/tmp/out.csv")))
        ctx.run(df^.write_to(CsvSink("/tmp/out.tsv", delimiter="\\t")))
        ctx.run(df^.write_to(CsvSink("/tmp/out.csv", header=False)))

    Move-only (`Movable`, not `Copyable`) — owns its output path and (after
    `init_sink`) an open `FileHandle`. `^`-moved into its `WriteSpec` by
    `df^.write_to(CsvSink(...))`.

    Lifecycle (the `Sink` trait): `init_sink(schema)` is called once with the
    feeding df's *output* schema (post-optimize, post-projection/agg), before
    any `accept_batch`; it opens the file and writes the header iff `header`.
    `accept_batch(rb)` debug-asserts `rb`'s column arity matches and writes
    `rb`'s rows. `finish()` closes the file. If `finish()` is never reached
    (the plan raised mid-write) and we created the file, `__del__` best-effort
    `unlink`s the partial `.csv`.

    Examples:
        ```mojo
        from komira_sdk import CsvSink
        # comma CSV with a header; delimiter / header are options
        ctx.run(df^.write_to(CsvSink("/tmp/out.csv")))
        ctx.run(df2^.write_to(CsvSink("/tmp/out.tsv", delimiter="\\t", header=False)))
        ```
    (example not yet doctest-verified)
    """

    var path: String
    var delimiter: String
    var header: Bool
    var quote: String
    # `Optional[LocalWriteFile]`: the wrapping LocalWriteFile owns a
    # RawWriteFd internally; write paths route through
    # `LocalFs[NoopSink].write_at(file, span)` (cursor-advancing).
    var _handle: Optional[LocalWriteFile]
    var _schema: Optional[Schema]
    var _finished: Bool
    var _created: Bool  # init_sink created the file (it did not pre-exist).
    # Running file offset used by
    # the parallel-pwrite path. Initialized to 0 in __init__; bumped to
    # header byte count in init_sink; bumped by per-batch total_bytes after
    # each parallel-pwrite_at fan-out in accept_batch. Required because
    # pwrite_at does NOT advance the kernel file-position pointer (see
    # komira_async's `local_fs`). Also maintained on the serial write_at path
    # to keep the contract clean across mixed batch sizes.
    var _csv_offset: Int

    def __init__(
        out self,
        var path: String,
        *,
        delimiter: String = ",",
        header: Bool = True,
        quote: String = '"',
    ):
        """Construct a CSV sink writing to `path`.

        Args:
            path: Output file path. Consumed.
            delimiter: Column separator (kw-only; default `,`).
            header: Write the column-name row first (kw-only; default True).
            quote: RFC-4180 quote character (kw-only; default `"`).
        """
        self.path = path^
        self.delimiter = delimiter
        self.header = header
        self.quote = quote
        self._handle = Optional[LocalWriteFile](None)
        self._schema = Optional[Schema](None)
        self._finished = False
        self._created = False
        self._csv_offset = 0

    def __deinit__(deinit self):
        """Best-effort remove a partial `.csv` if `finish()` was never reached.

        If `finish()` was never reached and we created the file, best-effort
        `unlink` the partial `.csv` — don't leave a half-written corpse. (The
        `_handle: Optional[FileHandle]` field is destroyed by the compiler as
        part of `self`'s teardown — the OS closes the fd; the unlink covers the
        corpse.)"""
        if not self._finished and self._created:
            _best_effort_unlink(self.path)

    # --- Sink trait conformance ---

    def init_sink(mut self, schema: Schema) raises:
        """Record the feeding df's *output* schema and open the file (writing
        the header row iff `header`)."""
        self._schema = Optional[Schema](schema.copy())
        self._created = not _path_exists(self.path)
        # Open via FileSystem.open_write (CREATE_TRUNCATE
        # matches the previous FileHandle "w" semantics).
        var fs = LocalFs[NoopSink].new()
        var handle = fs.open_write(self.path, WriteMode.create_truncate())
        if self.header:
            var line = String()
            var n = schema.num_columns()
            for i in range(n):
                if i > 0:
                    line.write(self.delimiter)
                _write_string_cell(
                    line, schema.field_name(i), self.delimiter, self.quote
                )
            line.write("\n")
            # Header line is bounded by schema column count (typically a
            # few KB) — fs.write_at takes the sub-64 MiB fast path.
            var header_bytes = line.as_bytes()
            _ = fs.write_at(handle, header_bytes)
            # Seed _csv_offset
            # with the header byte count so the first parallel-pwrite
            # batch starts at the correct offset.
            self._csv_offset = len(header_bytes)
        self._handle = Optional[LocalWriteFile](handle^)

    def accept_batch(mut self, var rb: RecordBatch) raises:
        """Debug-assert `rb`'s column arity matches the `init_sink` schema,
        then write `rb`'s rows as CSV lines.

        Sink-trait entry — NO dispatcher in scope, so it runs the
        serial-fallback (`has_pool=False`) path of `_accept_batch_impl`.
        Callers that have a EngineContext-owned dispatcher reach the
        parallel path via `accept_batch_with_dispatcher[disp_o]` (NOT a
        Sink-trait method — Mojo 1.0.0b1 traits cannot carry origin-
        parameterized methods).
        """
        self._accept_batch_impl[
            has_pool=False, disp_o=MutAnyOrigin,
        ](
            rb^,
            Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
            CancellationToken.never(),
        )

    def accept_batch_with_dispatcher[disp_o: Origin[mut=True]](
        mut self,
        var rb: RecordBatch,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises:
        """Dispatcher-aware sibling of `accept_batch`.

        Threads the EngineContext-owned `dispatcher_ptr` + `cancel_token` down through
        the column-format, row-emit, and pwrite fan-out stages so each runs
        in parallel via `LocalDispatcher.run_with_state`.
        """
        self._accept_batch_impl[
            has_pool=True, disp_o=disp_o,
        ](
            rb^,
            Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](
                dispatcher_ptr
            ),
            cancel_token^,
        )

    def _accept_batch_impl[
        has_pool: Bool,
        disp_o: Origin[mut=True],
    ](
        mut self,
        var rb: RecordBatch,
        dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
        var cancel_token: CancellationToken,
    ) raises:
        """Shared body for `accept_batch` / `accept_batch_with_dispatcher`.

        The format + emit
        + pwrite work is split into three stages. With `has_pool=True` each
        stage dispatches via `LocalDispatcher.run_with_state`; with
        `has_pool=False` each stage runs serially (byte-identical output on
        every row count). Below `_CSV_WRITE_MIN_PARALLEL_ROWS` rows or with
        `num_cols <= 1` the serial single-buffer fast path is taken
        regardless of `has_pool`.

        The file IO uses POSIX pwrite(2) to DISJOINT file ranges — ordered
        by the prefix-sum offsets, so CSV row order is preserved. The
        parallel win is on the CPU formatting work + the disjoint-range
        pwrite fan-out.

        Comptime `has_pool` flag prunes the parallel/serial branch — no
        wildcard origin reaches any dispatch in either path.
        """
        if not self._handle:
            _ = cancel_token^
            raise Error("CsvSink.accept_batch: init_sink was not called")
        if self._schema:
            ref expected = self._schema.value()
            if rb.num_columns() != expected.num_columns():
                _ = cancel_token^
                raise Error(
                    "CsvSink.accept_batch: batch has "
                    + String(rb.num_columns())
                    + " columns, init_sink schema has "
                    + String(expected.num_columns())
                )
        var num_rows = rb.num_rows()
        var num_cols = rb.num_columns()
        if num_cols == 0 or num_rows == 0:
            _ = cancel_token^
            return

        # Stage 1 (PACKED-BYTES):
        # parallel-format columns to `List[_PackedCells]`.
        var columns: List[_PackedCells]
        comptime if has_pool:
            columns = _parallel_format_columns_packed_with_dispatcher[disp_o](
                rb, self.delimiter, self.quote,
                dispatcher_ptr.value(), cancel_token.clone(),
            )
        else:
            columns = _parallel_format_columns_packed(
                rb, self.delimiter, self.quote
            )

        # Resolve effective worker count for the row-emit stage. Below the
        # row threshold OR with num_cols <= 1 the serial path is faster.
        var effective_workers = num_physical_cores()
        if effective_workers > _CSV_WRITE_MAX_WORKERS:
            effective_workers = _CSV_WRITE_MAX_WORKERS
        if effective_workers < 1:
            effective_workers = 1
        if num_rows < _CSV_WRITE_MIN_PARALLEL_ROWS:
            effective_workers = 1
        # Don't dispatch more workers than rows.
        if effective_workers > num_rows:
            effective_workers = num_rows
        # Without a dispatcher the per-stage dispatch is unavailable; clamp
        # to single-worker so the impl's serial-fast-path is taken.
        comptime if not has_pool:
            effective_workers = 1

        if effective_workers == 1:
            # Serial fast path: single-buffer emit, byte-identical to
            # the parallel path. Avoids dispatch overhead on small batches.
            _ = cancel_token^
            var est = num_rows * (8 * num_cols + 16)
            var bytes_one = _emit_row_range_to_bytes_packed(
                columns, 0, num_rows, self.delimiter, est
            )
            if len(bytes_one) > 0:
                # Use pwrite_at
                # on the serial path too. Mixing write_at + pwrite_at on
                # the same fd would desync the kernel file-position
                # pointer (write_at advances it; pwrite_at does not),
                # causing a SUBSEQUENT serial batch to clobber an
                # EARLIER parallel batch. The single load-bearing
                # write_at is the header in init_sink — that runs ONCE
                # before any data batch, so _csv_offset starts at
                # header_bytes and is the authoritative cursor for all
                # data writes.
                #
                # pwrite_at internally absorbs the 64 MiB chunking
                # workaround for the >2 GB single-syscall ceiling
                # (RawWriteFd.pwrite_at; see komira_async's `local_fs`).
                var fs = LocalFs[NoopSink].new()
                _ = fs.pwrite_at(
                    self._handle.value(),
                    Int64(self._csv_offset),
                    Span(bytes_one),
                )
                self._csv_offset = self._csv_offset + len(bytes_one)
            return

        # Stage 2: parallel row-range emit (packed variant). has_pool is
        # True in this branch (the serial-fast-path above handles
        # effective_workers==1, which is the only value reachable when
        # has_pool=False).
        var per_worker_bytes = _parallel_emit_rows_packed_with_dispatcher[
            disp_o
        ](
            columns, num_rows, self.delimiter, effective_workers,
            dispatcher_ptr.value(), cancel_token.clone(),
        )

        # Stage 3: PARALLEL pwrite_at fan-out on
        # LocalDispatcher.run_with_state — prefix-sum
        # per-worker byte counts into per-worker global file offsets,
        # ftruncate to the new EOF to pre-allocate the inode, then issue
        # per-worker pwrite_at to disjoint file ranges.
        #
        # POSIX guarantees (man pwrite(2)):
        #   - pwrite(2) is atomic per call for regular files.
        #   - pwrite(2) does NOT advance the kernel file-position pointer.
        #   - Concurrent pwrite(2) calls on the SAME fd to DISJOINT
        #     [offset, offset+len) ranges do not race.
        var total_bytes = 0
        var t_idx = 0
        while t_idx < effective_workers:
            total_bytes += len(per_worker_bytes[t_idx])
            t_idx = t_idx + 1
        if total_bytes == 0:
            _ = cancel_token^  # cov: unreachable at least 16384 rows each emit a line feed, so the total is never 0
            _ = per_worker_bytes^  # cov: unreachable at least 16384 rows each emit a line feed, so the total is never 0
            return  # cov: unreachable at least 16384 rows each emit a line feed, so the total is never 0

        # Prefix-sum per-worker byte counts into per-worker global file
        # offsets. Cheap; runs on the main thread post-fork-join.
        var worker_offsets = List[Int]()
        worker_offsets.reserve(effective_workers)
        var off_cur = self._csv_offset
        var p_idx = 0
        while p_idx < effective_workers:
            worker_offsets.append(off_cur)
            off_cur = off_cur + len(per_worker_bytes[p_idx])
            p_idx = p_idx + 1
        # off_cur == self._csv_offset + total_bytes by construction.

        # Pre-allocate the inode to the new EOF before launching the
        # parallel pwrites. Reduces fs-level lock contention vs N
        # concurrent inode-extensions racing on the size field.
        self._handle.value().ftruncate_size(off_cur)

        var pwrite_errors = List[Optional[String]]()
        var s2 = 0
        while s2 < effective_workers:
            pwrite_errors.append(Optional[String](None))
            s2 = s2 + 1

        # DISPATCH-BOUNDARY: build the pwrite State + Task; dispatch via
        # LocalDispatcher.run_with_state. The fd (`self._handle.value()`)
        # is borrowed read-only (pwrite_at takes file NON-MUT), and the
        # per-worker buffers + offsets are borrowed read-only — all via
        # typed-origin pointers anchored on the read-only inputs (no
        # wildcards). Origins anchored on the read-only borrows themselves
        # (immutable-origin lesson — NOT on a mutable local).
        ref fd_ref = self._handle.value()
        comptime fd_o = origin_of(fd_ref)
        var fd_ptr = UnsafePointer(to=fd_ref).unsafe_origin_cast[fd_o]()
        comptime bufs_o = origin_of(per_worker_bytes)
        var bufs_ptr = UnsafePointer(
            to=per_worker_bytes
        ).unsafe_origin_cast[bufs_o]()
        comptime offs_o = origin_of(worker_offsets)
        var offs_ptr = UnsafePointer(
            to=worker_offsets
        ).unsafe_origin_cast[offs_o]()
        var pw_state = _CsvPwriteState[fd_o, bufs_o, offs_o](
            fd_ptr,
            bufs_ptr,
            offs_ptr,
            pwrite_errors^,
            effective_workers,
        )
        var pw_task = _CsvPwriteTask[fd_o, bufs_o, offs_o](Int32(0))
        var disp = dispatcher_ptr.value()
        _ = disp[].run_with_state[
            _CsvPwriteState[fd_o, bufs_o, offs_o],
            _CsvPwriteTask[fd_o, bufs_o, offs_o],
        ](pw_state, pw_task^, effective_workers, cancel_token^, site_id=SITE_FORMAT_WRITE)
        pwrite_errors = pw_state.errors.take()
        _ = pw_state^

        # Re-raise the first pwrite failure.
        var pe_idx = 0
        while pe_idx < effective_workers:
            if pwrite_errors[pe_idx]:
                var msg = pwrite_errors[pe_idx].value().copy()  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
                raise Error(  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
                    String("CsvSink.accept_batch: pwrite worker ")  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
                    + String(pe_idx)  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
                    + String(" failed: ")  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
                    + msg  # cov: unreachable a pwrite worker records an error only on an I/O error of the open file
                )
            pe_idx = pe_idx + 1

        # Advance the file-offset tracker for the next batch (if any).
        self._csv_offset = self._csv_offset + total_bytes
        _ = per_worker_bytes^
        _ = worker_offsets^

    def accept_row_blocks(mut self, var ro: RowOutput) raises:
        """Row-native CSV write.

        OVERRIDES the `Sink` trait default (bridge-then-`accept_batch`) to
        serialize the `RowOutput`'s RowBlocks DIRECTLY to CSV text via
        `_emit_row_output_to_bytes` — skipping the row->columnar->row-text
        round-trip the default path pays. The output is BYTE-IDENTICAL to the
        columnar `accept_batch` path (same numeric `String(value)` route, same
        `_write_string_cell` RFC-4180 quoting, same empty-field null
        convention).

        Header + file open already happened in `init_sink` (the schema-driven
        header is identical regardless of row-native vs columnar). The cell
        bytes are written via the SAME `pwrite_at` offset-tracked path
        `accept_batch` uses, so a mixed `accept_row_blocks` / `accept_batch`
        sequence on the same sink stays cursor-consistent."""
        if not self._handle:
            raise Error("CsvSink.accept_row_blocks: init_sink was not called")
        if self._schema:
            ref expected = self._schema.value()
            if ro.layout.n_cols() != expected.num_columns():
                raise Error(
                    "CsvSink.accept_row_blocks: row output has "
                    + String(ro.layout.n_cols())
                    + " columns, init_sink schema has "
                    + String(expected.num_columns())
                )
        if ro.layout.n_cols() == 0 or ro.total_rows() == 0:
            return
        var bytes_one = _emit_row_output_to_bytes(
            ro, self.delimiter, self.quote
        )
        if len(bytes_one) > 0:
            var fs = LocalFs[NoopSink].new()
            _ = fs.pwrite_at(
                self._handle.value(),
                Int64(self._csv_offset),
                Span(bytes_one),
            )
            self._csv_offset = self._csv_offset + len(bytes_one)
        _ = ro^

    def finish(mut self) raises:
        """Flush + close the file handle. Marks the writer finished so `__del__`
        does not `unlink` the (now-complete) file.

        Closes via fs.close_write — surfaces close(2)
        errors to the caller (raises on close failure). Optional.take()
        extracts the LocalWriteFile by move; close_write consumes it.
        """
        if not self._handle:
            raise Error("CsvSink.finish: init_sink was not called")
        var fs = LocalFs[NoopSink].new()
        var f = self._handle.take()
        fs.close_write(f^)
        self._finished = True

    def is_text_output_sink(self) -> Bool:
        """Explicit False — the legacy `CsvSink` (direct, non-parametric)
        runs its own per-column conversions inline. The cast_to_varchar
        insertion rule only fires for the parametric `LocalFormatSink[Csv[*]]`
        family. Marked False explicitly (explicit-by-design)
        rather than relying on the trait default."""
        return False
