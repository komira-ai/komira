# =============================================================================
# subrg_column_cursor — a resumable page cursor over one column chunk
# =============================================================================
#
# The whole-chunk column decoder decodes a chunk's pages into one array sized
# to the chunk. `ResumableColumnCursor` decodes the same pages a chunk of rows
# at a time into a caller's fixed buffer, keeping the page walk (byte offset
# into the chunk, the live level / index decoder, the rows left in the current
# page) across calls. A worker that reuses one small buffer for every chunk
# never allocates a row-group-sized one.
#
# What it decodes (anything else is refused, and the caller decodes the whole
# chunk instead):
#
#   * dictionary-encoded INT32, INT64, FLOAT, DOUBLE and BYTE_ARRAY chunks: a
#     DICTIONARY_PAGE, then V1 DATA_PAGEs of RLE_DICTIONARY or
#     PLAIN_DICTIONARY codes. `fill_next_codes` emits the Int32 codes; the
#     dictionary is held as Int64 (INT32 / INT64), Float64 (FLOAT / DOUBLE) or
#     N+1 offsets plus packed bytes (BYTE_ARRAY, so a worker thread builds no
#     string array);
#   * flat INT32, INT64, FLOAT and DOUBLE chunks of V1 PLAIN pages, and INT32
#     and INT64 chunks of V1 DELTA_BINARY_PACKED pages: `fill_next_flat` emits
#     the values. PLAIN pages can also be read in place, without a copy
#     (`open_next_plain_grain` with `load_grain`, or `ensure_plain_page`,
#     `commit_plain_grain` and `grain_view_ro`);
#   * OPTIONAL columns without an actual null: each page's definition levels
#     are decoded and skipped, and a page holding a null refuses mid-decode.
#
# `try_open` refuses an out-of-scope chunk before it emits a row: it reads the
# first data page's encoding and then walks every page header
# (`subrg_cursor_pages._admit_all_pages`). The one refusal left for mid-decode
# is a page holding an actual null. A caller checks `supported()` after each
# fill and `rows_emitted() == num_values()` at the end.
#
# `seek_to_row(lo, hi)` limits a cursor to the rows [lo, hi): whole pages
# before `lo` are skipped by their headers, and the page holding `lo` is
# seeked by byte offset (PLAIN) or decode-skipped (dictionary codes, DBP).
#
# No pointer is in a public signature: destinations are `OwnedAlignedBuffer`s
# and page bytes are read through Spans of the cursor's own buffers.
# =============================================================================

from std.sys import size_of

from komira_buffer.byte_view import ByteView
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    PageType,
    ParquetType,
)

from .def_level_bitmap import decode_def_levels_to_bitmap
from .delta import DeltaDecoder
from .page_header_parser import _parse_page_header
from .rle import RleDecoder
from .subrg_cursor_pages import (
    _admit_all_pages,
    _decode_numeric_dict,
    _decode_string_dict,
    _decompress_page_into,
    _ptype_is_float,
    _ptype_width,
    _zero_code_stream,
)
from .subrg_dbp_trace import (
    add_dbp_values,
    dbp_note_armed,
    incr_dbp_open_admit,
    incr_dbp_open_decline,
    incr_dbp_page,
    incr_dbp_stall,
)
from .subrg_scan_route_trace import incr_scan_open_decline

# The longest run one `fill_next_codes` call may emit past its target: a
# bit-packed run is decoded in whole 8-value groups, and the headroom lets a
# run finish rather than be split. A codes buffer holds `max_rows +
# SUBRG_MAX_RUN` Int32 slots.
comptime SUBRG_MAX_RUN: Int = 1024

# `_row_limit` when no `seek_to_row` capped the cursor: the chunk's own count.
comptime _ROW_LIMIT_NONE: Int = 1 << 62

# Values decode-skipped per step when seeking inside a DBP page, so the skip
# uses a small fixed buffer rather than one sized to the skip.
comptime _SKIP_CHUNK: Int = 4096


struct ResumableColumnCursor(Movable, Deinitable):
    """A resumable page cursor over one column chunk; see the module header.

    Fields:
        _chunk: The column chunk's bytes (dictionary page, then data pages).
        _offset: Where the next page header starts in `_chunk`.
        _ptype, _codec: The column's physical type and compression codec.
        _num_values: The chunk's value (row) count.
        _rows_emitted: Rows the decoder has produced so far.
        _supported: False once the chunk, or one of its pages, is refused.
        _is_dict: Dictionary-encoded (codes) or flat (values).
        _is_string_dict: A dictionary-encoded BYTE_ARRAY column.
        _nullable: Pages carry definition levels (V1 OPTIONAL).
        _flat_enc: A flat chunk's page encoding, PLAIN or
            DELTA_BINARY_PACKED, fixed by its first data page.
        _dict_values, _dict_values_f64: The numeric dictionary, widened.
        _str_dict_offsets, _str_dict_bytes: The BYTE_ARRAY dictionary.
        _scratch: The decoded current page, reused across pages.
        _rle: The live dictionary-index decoder of the current page.
        _dbp: The live DELTA_BINARY_PACKED decoder of the current page.
        _page_remaining: Values of the current page not yet emitted.
        _plain_byte_off: The next value's byte offset in a PLAIN page.
        _grain_byte_off: The byte offset of the grain last exposed in place.
        _page_decompress_count: Page bodies decoded into `_scratch`.
        _overflow_codes: Codes produced past a `fill_next_codes_at` cap,
            returned first by the next call, so the cap is exact.
        _pending_rle_value, _pending_rle_remaining: An RLE run cut by a
            call's cap, continued by the next call.
        _row_limit: The row bound `seek_to_row` set.
    """

    var _chunk: List[UInt8]
    var _offset: Int
    var _ptype: ParquetType
    var _codec: CompressionCodec
    var _num_values: Int
    var _rows_emitted: Int
    var _supported: Bool
    var _is_dict: Bool
    var _is_string_dict: Bool
    var _nullable: Bool
    var _flat_enc: Encoding
    var _dict_values: List[Int64]
    var _dict_values_f64: List[Float64]
    var _str_dict_offsets: List[Int32]
    var _str_dict_bytes: List[UInt8]
    var _scratch: OwnedAlignedBuffer
    var _rle: Optional[RleDecoder]
    var _dbp: Optional[DeltaDecoder]
    var _page_remaining: Int
    var _plain_byte_off: Int
    var _grain_byte_off: Int
    var _page_decompress_count: Int
    var _overflow_codes: List[Int32]
    var _pending_rle_value: Int32
    var _pending_rle_remaining: Int
    var _row_limit: Int

    def __init__(out self):
        """An empty, refused cursor (`supported() == False`)."""
        self._chunk = List[UInt8]()
        self._offset = 0
        self._ptype = ParquetType.INT32
        self._codec = CompressionCodec.UNCOMPRESSED
        self._num_values = 0
        self._rows_emitted = 0
        self._supported = False
        self._is_dict = True
        self._is_string_dict = False
        self._nullable = False
        self._flat_enc = Encoding.PLAIN
        self._dict_values = List[Int64]()
        self._dict_values_f64 = List[Float64]()
        self._str_dict_offsets = List[Int32]()
        self._str_dict_bytes = List[UInt8]()
        self._scratch = OwnedAlignedBuffer(1)
        self._rle = None
        self._dbp = None
        self._page_remaining = 0
        self._plain_byte_off = 0
        self._grain_byte_off = 0
        self._page_decompress_count = 0
        self._overflow_codes = List[Int32]()
        self._pending_rle_value = Int32(0)
        self._pending_rle_remaining = 0
        self._row_limit = _ROW_LIMIT_NONE

    # --- Accessors -------------------------------------------------------------

    @always_inline
    def _effective_limit(self) -> Int:
        """The row bound this cursor emits to: `min(num_values, row limit)`."""
        if self._row_limit >= _ROW_LIMIT_NONE:
            return self._num_values
        return min(self._num_values, self._row_limit)

    @always_inline
    def supported(self) -> Bool:
        """False once the chunk, or one of its pages, was refused."""
        return self._supported

    @always_inline
    def num_values(self) -> Int:
        """The chunk's value (row) count."""
        return self._num_values

    @always_inline
    def rows_emitted(self) -> Int:
        """Rows produced so far (including codes held for the next call)."""
        return self._rows_emitted

    @always_inline
    def dict_size(self) -> Int:
        """Entries of the numeric (Int64-widened) dictionary."""
        return len(self._dict_values)

    def dict_values_copy(self) -> List[Int64]:
        """The INT32 / INT64 dictionary, widened to Int64, in code order."""
        return self._dict_values.copy()

    def dict_values_f64_copy(self) -> List[Float64]:
        """The FLOAT / DOUBLE dictionary, widened to Float64, in code order."""
        return self._dict_values_f64.copy()

    @always_inline
    def is_dict(self) -> Bool:
        """True for a dictionary-encoded chunk (`fill_next_codes`), False for
        a flat one (`fill_next_flat`)."""
        return self._is_dict

    @always_inline
    def value_ptype(self) -> ParquetType:
        """The chunk's physical type."""
        return self._ptype

    @always_inline
    def value_is_float(self) -> Bool:
        """True for FLOAT and DOUBLE."""
        return _ptype_is_float(self._ptype)

    @always_inline
    def is_string_dict(self) -> Bool:
        """True for a dictionary-encoded BYTE_ARRAY chunk."""
        return self._is_string_dict

    def str_dict_offsets_copy(self) -> List[Int32]:
        """The BYTE_ARRAY dictionary's N+1 cumulative byte offsets (first 0,
        last the byte total); empty for any other chunk."""
        return self._str_dict_offsets.copy()

    def str_dict_bytes_copy(self) -> List[UInt8]:
        """The BYTE_ARRAY dictionary's packed entry bytes: entry `e` is
        `[offsets[e], offsets[e+1])`."""
        return self._str_dict_bytes.copy()

    @always_inline
    def flat_encoding(self) -> Encoding:
        """A flat chunk's page encoding: PLAIN or DELTA_BINARY_PACKED."""
        return self._flat_enc

    @always_inline
    def is_dbp(self) -> Bool:
        """True for a flat DELTA_BINARY_PACKED chunk, whose pages are decoded
        and cannot be read in place."""
        return (not self._is_dict) and (
            self._flat_enc == Encoding.DELTA_BINARY_PACKED
        )

    @always_inline
    def first_data_page_offset(self) -> Int:
        """Where the first data page starts in the chunk, right after
        `try_open` (past the dictionary page; 0 for a flat chunk). A caller
        that shares one decoded dictionary can reopen the data pages alone
        with `try_open_data_only`."""
        return self._offset

    @always_inline
    def page_decompress_count(self) -> Int:
        """Page bodies decoded into the cursor's scratch so far: one per page,
        however many grains are read from it."""
        return self._page_decompress_count

    # --- Open ------------------------------------------------------------------

    @staticmethod
    def try_open(
        var chunk_bytes: List[UInt8],
        ptype: ParquetType,
        codec: CompressionCodec,
        num_values: Int,
        nullable: Bool,
    ) raises -> ResumableColumnCursor:
        """Open a cursor over a whole column chunk, or return a refused one.

        A chunk that starts with a DICTIONARY_PAGE decodes the dictionary and
        stands at the first data page. One that starts with a V1 DATA_PAGE is
        flat when that page is PLAIN (any of the four numeric types) or
        DELTA_BINARY_PACKED (INT32, INT64); a flat BYTE_ARRAY chunk is
        refused. Then every page header is walked (`_admit_all_pages`).

        Raises:
            Error if the first page header does not parse, or a numeric
            dictionary declares more entries than its page holds.
        """
        if (
            ptype != ParquetType.INT32
            and ptype != ParquetType.INT64
            and ptype != ParquetType.FLOAT
            and ptype != ParquetType.DOUBLE
            and ptype != ParquetType.BYTE_ARRAY
        ):
            return ResumableColumnCursor()

        var self = ResumableColumnCursor()
        self._chunk = chunk_bytes^
        self._ptype = ptype
        self._codec = codec
        self._num_values = num_values
        self._nullable = nullable
        var data_len = len(self._chunk)
        if data_len == 0 or num_values <= 0:
            return self^

        var hdr0 = _parse_page_header(Span(self._chunk))
        if hdr0.header.type != PageType.DICTIONARY_PAGE:
            if ptype == ParquetType.BYTE_ARRAY:
                return self^
            if not self._admit_first_flat_page(
                hdr0.header.type, hdr0.header.encoding
            ):
                return self^
            self._is_dict = False
            self._supported = True
            self._admit_rest()
            return self^

        var dict_hdr_bytes = hdr0.bytes_consumed
        var dict_page_size = hdr0.header.compressed_page_size
        var dict_nv = hdr0.header.num_values
        if dict_page_size < 0 or dict_page_size > data_len - dict_hdr_bytes:
            return self^
        var body_end = dict_hdr_bytes + dict_page_size
        self._page_decompress_count += 1
        _decompress_page_into(
            codec,
            Span(self._chunk)[dict_hdr_bytes:body_end],
            hdr0.header.uncompressed_page_size,
            self._scratch,
        )
        var dict_ok = True
        var page = self._scratch.view_ro().into_span()
        if ptype == ParquetType.BYTE_ARRAY:
            self._is_string_dict = True
            dict_ok = _decode_string_dict(
                page, dict_nv, self._str_dict_offsets, self._str_dict_bytes
            )
        else:
            _decode_numeric_dict(
                ptype, page, dict_nv, self._dict_values, self._dict_values_f64
            )
        self._offset = body_end
        self._supported = dict_ok
        if dict_ok:
            self._admit_rest()
        return self^

    @staticmethod
    def try_open_data_only(
        var data_page_bytes: List[UInt8],
        ptype: ParquetType,
        codec: CompressionCodec,
        num_values: Int,
        nullable: Bool,
        is_dict: Bool,
    ) raises -> ResumableColumnCursor:
        """Open a cursor over the data pages of a chunk alone, starting at its
        first data page; the dictionary page is absent (the caller decoded it
        once and resolves codes against its own copy). A flat chunk's first
        page encoding is checked as in `try_open`; a header that does not
        parse refuses the cursor rather than raising."""
        var self = ResumableColumnCursor()
        self._chunk = data_page_bytes^
        self._ptype = ptype
        self._codec = codec
        self._num_values = num_values
        self._nullable = nullable
        self._is_dict = is_dict
        self._supported = num_values > 0 and len(self._chunk) > 0
        if self._supported and not is_dict:
            try:
                var hdr0 = _parse_page_header(Span(self._chunk))
                self._supported = self._admit_first_flat_page(
                    hdr0.header.type, hdr0.header.encoding
                )
            except:
                self._supported = False
        if self._supported:
            self._admit_rest()
        return self^

    def _admit_first_flat_page(
        mut self, page_type: PageType, enc: Encoding
    ) raises -> Bool:
        """Fix a flat chunk's encoding from its first data page: PLAIN, or
        DELTA_BINARY_PACKED for INT32 / INT64. Anything else is refused and
        counted (`dbp_open_decline_count`)."""
        if page_type != PageType.DATA_PAGE:
            incr_dbp_open_decline()
            return False
        if enc == Encoding.PLAIN:
            self._flat_enc = Encoding.PLAIN
            return True
        if enc == Encoding.DELTA_BINARY_PACKED and (
            self._ptype == ParquetType.INT32 or self._ptype == ParquetType.INT64
        ):
            self._flat_enc = Encoding.DELTA_BINARY_PACKED
            incr_dbp_open_admit()
            dbp_note_armed(_ptype_width(self._ptype))
            return True
        incr_dbp_open_decline()
        return False

    def _admit_rest(mut self) raises:
        """Refuse the cursor now if any page from `_offset` is out of scope,
        counting the refusal (`scan_open_decline_count`)."""
        if not _admit_all_pages(
            Span(self._chunk),
            self._offset,
            self._is_dict,
            self._flat_enc,
            self._num_values,
        ):
            self._supported = False
            incr_scan_open_decline()

    # --- Dictionary codes ----------------------------------------------------

    def fill_next_codes(
        mut self, mut dst: OwnedAlignedBuffer, max_rows: Int
    ) raises -> Int:
        """`fill_next_codes_at(dst, max_rows, 0)`."""
        return self.fill_next_codes_at(dst, max_rows, 0)

    def fill_next_codes_at(
        mut self, mut dst: OwnedAlignedBuffer, max_rows: Int, dst_offset: Int
    ) raises -> Int:
        """Decode the next up to `max_rows` dictionary codes into `dst` as
        Int32, from Int32 slot `dst_offset`, and return how many were written
        (0 once the chunk, or its row limit, is drained).

        Runs are decoded whole; codes a run produced past `max_rows` are held
        and returned first by the next call, so exactly
        `min(max_rows, rows left)` codes come back. Two cursors filled with
        the same `max_rows` therefore stay row-aligned.

        `dst`'s length must hold `dst_offset + max_rows + SUBRG_MAX_RUN`
        Int32 slots: a bit-packed run may write up to a group past the codes
        returned, and those slots are scratch.

        Raises:
            Error if `dst` holds fewer than `dst_offset + min(max_rows, rows
            left)` slots, or a page fails to decode.
        """
        if not self._supported or max_rows <= 0:
            return 0
        var n_overflow = len(self._overflow_codes)
        if self._rows_emitted >= self._effective_limit() and n_overflow == 0:
            return 0
        var remaining = (self._effective_limit() - self._rows_emitted) + n_overflow
        var target = min(max_rows, remaining)
        var slots = dst.len() // 4 - dst_offset
        if dst_offset < 0 or slots < target:
            raise Error(
                "subrg cursor: the codes buffer holds "
                + String(max(slots, 0))
                + " Int32 slots past offset "
                + String(dst_offset)
                + ", fewer than the "
                + String(target)
                + " codes asked for"
            )
        var dv = dst.view_mut()
        # SAFETY: `dst`'s length holds `dst_offset + slots` Int32 slots
        # (checked above); `dv` borrows `dst` for the rest of this call.
        var codes_out = Span[Int32, dv.origin](
            unsafe_ptr=dv._unsafe_ptr().bitcast[Int32]() + dst_offset,
            length=slots,
        )
        var written = 0

        # Codes produced past an earlier call's cap come first. They were
        # counted in `_rows_emitted` when produced.
        if n_overflow > 0:
            var take = min(n_overflow, target)
            for i in range(take):
                codes_out[i] = self._overflow_codes[i]
            written = take
            var rest = List[Int32](capacity=n_overflow - take)
            for i in range(take, n_overflow):
                rest.append(self._overflow_codes[i])
            self._overflow_codes = rest^
            if written >= target:
                return written

        var produced_start = written
        if self._pending_rle_remaining > 0:
            var drained = self._emit_pending_rle(codes_out, written, target)
            written += drained
            self._page_remaining -= drained

        var data_len = len(self._chunk)
        while written < target:
            if not self._rle:
                if self._offset >= data_len:
                    break
                if not self._open_next_data_page():
                    self._supported = False
                    break
            var page_rem = self._page_remaining
            if page_rem <= 0:
                _ = self._rle.take()
                self._pending_rle_remaining = 0
                continue
            # Cap one call at the target plus a run of headroom, and at the
            # page's remaining values; at least 8 (one bit-packed group) so a
            # parked group always advances. Padding written past the page's
            # count is not counted (`real`).
            var room = slots - written
            var call_cap = min(min(room, (target - written) + SUBRG_MAX_RUN), page_rem)
            if call_cap < 8 and room >= 8:
                call_cap = 8
            var res = self._rle.value().decode_run_int32(codes_out[written:slots], call_cap)
            var real = min(res.written, page_rem)
            written += real
            self._page_remaining = page_rem - real
            if res.rle_leftover > 0:
                self._pending_rle_value = res.rle_value
                self._pending_rle_remaining = res.rle_leftover
            if self._page_remaining <= 0:
                # The page's values are out; its stream may hold padding,
                # and a run parked past the page's count is padding too.
                _ = self._rle.take()
                self._pending_rle_remaining = 0
            elif res.exhausted:
                # The stream ended before the page's count: malformed.
                _ = self._rle.take()
                self._supported = False
                break
            elif real == 0 and res.rle_leftover == 0:
                # No progress and nothing parked: refuse rather than spin.
                _ = self._rle.take()
                self._supported = False
                break
        self._rows_emitted += written - produced_start
        if written > target:
            var excess = written - target
            var stash = List[Int32](capacity=excess)
            for i in range(excess):
                stash.append(codes_out[target + i])
            self._overflow_codes = stash^
            return target
        return written

    def _emit_pending_rle[
        o: MutOrigin
    ](mut self, codes_out: Span[Int32, o], at: Int, target: Int) -> Int:
        """Write up to `target - at` values of the parked RLE run at
        `codes_out[at]` and keep the rest parked. Returns the values
        written."""
        # A run never continues past its page's declared count.
        var emit = min(
            min(self._pending_rle_remaining, target - at), self._page_remaining
        )
        if emit <= 0:
            return 0
        var v = self._pending_rle_value
        for i in range(emit):
            codes_out[at + i] = v
        self._pending_rle_remaining -= emit
        return emit

    def _open_next_data_page(mut self) raises -> Bool:
        """Open the dictionary-index page at `_offset`: a V1 DATA_PAGE of
        RLE_DICTIONARY or PLAIN_DICTIONARY. Skips an OPTIONAL page's
        definition levels (refusing a page with a null), then arms an
        `RleDecoder` over the codes after their bit-width byte. Returns False
        to refuse the page."""
        var data_len = len(self._chunk)
        if self._offset >= data_len:
            return False
        var hdr = _parse_page_header(Span(self._chunk)[self._offset:data_len])
        var comp_size = hdr.header.compressed_page_size
        var enc = hdr.header.encoding
        if hdr.header.type != PageType.DATA_PAGE:
            return False
        if enc != Encoding.RLE_DICTIONARY and enc != Encoding.PLAIN_DICTIONARY:
            return False
        var body_off = self._offset + hdr.bytes_consumed
        if comp_size < 0 or comp_size > data_len - body_off:
            return False
        self._page_decompress_count += 1
        _decompress_page_into(
            self._codec,
            Span(self._chunk)[body_off : body_off + comp_size],
            hdr.header.uncompressed_page_size,
            self._scratch,
        )
        self._offset = body_off + comp_size
        var page_nv = hdr.header.num_values
        self._page_remaining = page_nv

        var page = self._scratch.view_ro().into_span()
        var dlen = len(page)
        if dlen <= 0:
            return False
        var start = 0
        if self._nullable:
            var def_res = decode_def_levels_to_bitmap(page, page_nv)
            if not def_res.all_valid:
                return False
            start = def_res.bytes_consumed
            if start < 0 or start >= dlen:
                return False
        var bit_width = Int(page[start])
        if bit_width == 0:
            if page_nv <= 0:
                return False
            var zeros = _zero_code_stream(page_nv)
            self._rle = RleDecoder(Span(zeros), 1)
            return True
        # The decoder copies its bytes, so the next page may reuse `_scratch`.
        self._rle = RleDecoder(page[start + 1 : dlen], bit_width)
        return True

    # --- Flat values -----------------------------------------------------------

    def fill_next_flat(
        mut self, mut dst: OwnedAlignedBuffer, max_rows: Int, dst_offset: Int
    ) raises -> Int:
        """Decode the next up to `max_rows` values of a flat chunk into `dst`,
        from element slot `dst_offset` (each slot the type's width), and
        return how many were written (0 once drained). PLAIN values are
        copied as little-endian bytes; DELTA_BINARY_PACKED values are decoded.

        Raises:
            Error if `dst`'s length holds fewer than `dst_offset + min(max_rows,
            rows left)` slots, or a page fails to decode.
        """
        if not self._supported or max_rows <= 0:
            return 0
        if self._rows_emitted >= self._effective_limit():
            return 0
        var width = _ptype_width(self._ptype)
        var target = min(max_rows, self._effective_limit() - self._rows_emitted)
        if dst_offset < 0 or (dst_offset + target) * width > dst.len():
            raise Error(
                "subrg cursor: the value buffer holds "
                + String(dst.len())
                + " bytes, fewer than "
                + String(target)
                + " values of width "
                + String(width)
                + " at slot "
                + String(dst_offset)
            )
        if self._flat_enc == Encoding.DELTA_BINARY_PACKED:
            return self._fill_next_dbp(dst, target, dst_offset)
        var written = 0
        var data_len = len(self._chunk)
        while written < target:
            if self._page_remaining <= 0:
                if self._offset >= data_len:
                    break
                if not self._open_next_plain_page():
                    self._supported = False
                    break
                if self._page_remaining <= 0:
                    continue
            var emit = min(target - written, self._page_remaining)
            var nbytes = emit * width
            var src = self._scratch.view_range_ro(self._plain_byte_off, nbytes)
            dst.copy_from_span_at((dst_offset + written) * width, src.into_span())
            self._plain_byte_off += nbytes
            self._page_remaining -= emit
            written += emit
        self._rows_emitted += written
        return written

    def _fill_next_dbp(
        mut self, mut dst: OwnedAlignedBuffer, target: Int, dst_offset: Int
    ) raises -> Int:
        """The DELTA_BINARY_PACKED arm of `fill_next_flat`: the live
        `DeltaDecoder` carries the running value across calls, so a strictly
        sequential pull resumes mid-miniblock where the last call stopped.
        Refuses the cursor when the decoder stops short of the page's count."""
        var width = _ptype_width(self._ptype)
        var written = 0
        var data_len = len(self._chunk)
        while written < target:
            if self._page_remaining <= 0:
                if self._offset >= data_len:
                    break
                if not self._open_next_plain_page():
                    self._supported = False
                    break
                if self._page_remaining <= 0:
                    continue
            if not self._dbp:
                self._supported = False
                break
            var emit = min(target - written, self._page_remaining)
            var got: Int
            if width == 8:
                got = self._dbp.value().resume_fill_int64(
                    dst, dst_offset + written, emit
                )
            else:
                got = self._dbp.value().resume_fill_int32(
                    dst, dst_offset + written, emit
                )
            if got <= 0:
                incr_dbp_stall()
                self._supported = False
                break
            self._page_remaining -= got
            written += got
            if self._page_remaining <= 0:
                _ = self._dbp.take()
        self._rows_emitted += written
        if written > 0:
            add_dbp_values(written)
        return written

    def _open_next_plain_page(mut self) raises -> Bool:
        """Open the flat page at `_offset`: a V1 DATA_PAGE in the chunk's
        encoding. Decodes its body into `_scratch`, skips an OPTIONAL page's
        definition levels (refusing a page with a null), and either stands
        the byte cursor at the first PLAIN value or arms the DBP decoder.
        Returns False to refuse the page."""
        var data_len = len(self._chunk)
        if self._offset >= data_len:
            return False
        var hdr = _parse_page_header(Span(self._chunk)[self._offset:data_len])
        var comp_size = hdr.header.compressed_page_size
        if hdr.header.type != PageType.DATA_PAGE:
            return False
        if hdr.header.encoding != self._flat_enc:
            return False
        var body_off = self._offset + hdr.bytes_consumed
        if comp_size < 0 or comp_size > data_len - body_off:
            return False
        self._page_decompress_count += 1
        _decompress_page_into(
            self._codec,
            Span(self._chunk)[body_off : body_off + comp_size],
            hdr.header.uncompressed_page_size,
            self._scratch,
        )
        self._offset = body_off + comp_size
        var page_nv = hdr.header.num_values
        self._page_remaining = page_nv
        self._plain_byte_off = 0
        var dlen = self._scratch.len()
        if self._nullable:
            if dlen <= 0:
                return False
            var def_res = decode_def_levels_to_bitmap(
                self._scratch.view_ro().into_span(), page_nv
            )
            if not def_res.all_valid:
                return False
            var consumed = def_res.bytes_consumed
            if consumed < 0 or consumed >= dlen:
                return False
            self._plain_byte_off = consumed
        if self._flat_enc == Encoding.DELTA_BINARY_PACKED:
            return self._arm_dbp_page(page_nv)
        # A PLAIN page must hold the values it declares.
        if page_nv < 0 or page_nv * _ptype_width(self._ptype) > dlen - self._plain_byte_off:
            return False
        return True

    def _arm_dbp_page(mut self, page_nv: Int) raises -> Bool:
        """Arm a `DeltaDecoder` over the DBP stream of the page in `_scratch`
        (from `_plain_byte_off`). The decoder copies the bytes. Returns False
        for an empty body or a header the resumable path refuses."""
        var dlen = self._scratch.len()
        if dlen - self._plain_byte_off <= 0:
            return False
        var dec = DeltaDecoder(
            self._scratch.view_ro().into_span()[self._plain_byte_off : dlen]
        )
        if not dec.begin_resumable(page_nv):
            return False
        self._dbp = Optional(dec^)
        incr_dbp_page()
        return True

    # --- PLAIN values in place --------------------------------------------------

    def open_next_plain_grain(mut self, grain: Int) raises -> Int:
        """Expose the next up to `grain` values of a PLAIN chunk in place, in
        the decoded page, and return how many (0 once drained). Read them with
        `load_grain` before the next call: the next page overwrites the
        scratch. A grain never crosses a page. A DELTA_BINARY_PACKED chunk is
        refused (its page bytes are not values)."""
        if not self._supported or grain <= 0:
            return 0
        var avail = self.ensure_plain_page()
        if avail <= 0:
            return 0
        var n = min(grain, avail)
        self.commit_plain_grain(n)
        return n

    @always_inline
    def load_grain[dt: DType, W: Int](self, row_i: Int) -> SIMD[dt, W]:
        """`W` values of type `dt` at grain-relative row `row_i`, read in
        place from the decoded page. `row_i + W` must not pass the grain."""
        comptime elem = size_of[Scalar[dt]]()
        return self._scratch.load_simd[dt, W](self._grain_byte_off + row_i * elem)

    @always_inline
    def load_grain_f64[W: Int](self, row_i: Int) -> SIMD[DType.float64, W]:
        """`load_grain[DType.float64, W]`."""
        return self.load_grain[DType.float64, W](row_i)

    @always_inline
    def load_grain_f64_scalar(self, row_i: Int) -> Float64:
        """One Float64 of the grain."""
        return self.load_grain[DType.float64, 1](row_i)[0]

    def ensure_plain_page(mut self) raises -> Int:
        """Make sure a PLAIN page with values left is decoded in the scratch,
        opening the next page when the current one is drained, and return
        the rows available in it (0 once drained or refused). Does not
        advance; `commit_plain_grain` does."""
        if not self._supported or self._rows_emitted >= self._effective_limit():
            return 0
        if self._flat_enc != Encoding.PLAIN or self._is_dict:
            self._supported = False
            return 0
        var data_len = len(self._chunk)
        while self._page_remaining <= 0:
            if self._offset >= data_len:
                return 0
            if not self._open_next_plain_page():
                self._supported = False
                return 0
        return min(self._page_remaining, self._effective_limit() - self._rows_emitted)

    @always_inline
    def commit_plain_grain(mut self, n: Int):
        """Expose the current page's next `n` rows as the grain
        (`grain_view_ro`, `load_grain`) and advance past them. `n` must not
        exceed what `ensure_plain_page` returned."""
        var width = _ptype_width(self._ptype)
        self._grain_byte_off = self._plain_byte_off
        self._plain_byte_off += n * width
        self._page_remaining -= n
        self._rows_emitted += n

    @always_inline
    def grain_view_ro(self, nbytes: Int) -> ByteView[origin_of(self._scratch)]:
        """A read view of the current grain's `nbytes` bytes in the decoded
        page, no copy. Valid until the cursor opens its next page."""
        return self._scratch.view_range_ro(self._grain_byte_off, nbytes)

    # --- Row range ---------------------------------------------------------------

    def seek_to_row(mut self, row_lo: Int, row_hi: Int) raises -> Bool:
        """Limit the cursor to rows `[row_lo, row_hi)`. Call right after
        opening, before any fill.

        Whole pages before `row_lo` are skipped by their headers (no body is
        decoded). In the page holding `row_lo`, a PLAIN page is entered by
        byte offset, and dictionary codes and DBP values are decoded and
        dropped (bounded by one page). Returns False, refusing the cursor,
        on a malformed walk."""
        if not self._supported:
            return False
        self._row_limit = row_hi
        if row_lo <= 0:
            return True
        var data_len = len(self._chunk)
        var cum = 0
        while self._offset < data_len:
            var hdr = _parse_page_header(Span(self._chunk)[self._offset:data_len])
            var nv = hdr.header.num_values
            var comp_size = hdr.header.compressed_page_size
            var body_off = self._offset + hdr.bytes_consumed
            if comp_size < 0 or comp_size > data_len - body_off:
                self._supported = False
                return False
            if cum + nv > row_lo:
                break
            self._offset = body_off + comp_size
            cum += nv
        self._rows_emitted = cum
        var skip_in = row_lo - cum
        if skip_in <= 0:
            return True
        if not self._is_dict:
            if not self._open_next_plain_page() or skip_in > self._page_remaining:
                self._supported = False
                return False
            if self._flat_enc == Encoding.DELTA_BINARY_PACKED:
                return self._skip_dbp(skip_in, row_lo)
            self._plain_byte_off += skip_in * _ptype_width(self._ptype)
            self._page_remaining -= skip_in
            self._rows_emitted = row_lo
            return True
        # Decode and drop the page's first `skip_in` codes with the limit set
        # at `row_lo`; a run's overshoot is held and returned first.
        var saved_limit = self._row_limit
        self._row_limit = row_lo
        var throwaway = OwnedAlignedBuffer((skip_in + SUBRG_MAX_RUN) * 4)
        throwaway.set_length(Int64((skip_in + SUBRG_MAX_RUN) * 4))
        while self._rows_emitted < row_lo:
            var want = row_lo - self._rows_emitted
            if self.fill_next_codes(throwaway, want) == 0:
                self._row_limit = saved_limit
                self._supported = False
                return False
        self._row_limit = saved_limit
        return self._supported

    def _skip_dbp(mut self, skip_in: Int, row_lo: Int) raises -> Bool:
        """Decode and drop `skip_in` values of the open DBP page, a small
        fixed chunk at a time (a running-sum encoding has no byte seek)."""
        if not self._dbp:
            self._supported = False
            return False
        var width = _ptype_width(self._ptype)
        var throwaway = OwnedAlignedBuffer(_SKIP_CHUNK * 8)
        throwaway.set_length(Int64(_SKIP_CHUNK * 8))
        var skipped = 0
        while skipped < skip_in:
            var want = min(_SKIP_CHUNK, skip_in - skipped)
            var n: Int
            if width == 8:
                n = self._dbp.value().resume_fill_int64(throwaway, 0, want)
            else:
                n = self._dbp.value().resume_fill_int32(throwaway, 0, want)
            if n <= 0:
                self._supported = False
                return False
            skipped += n
        self._page_remaining -= skip_in
        self._rows_emitted = row_lo
        return True
