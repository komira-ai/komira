# =============================================================================
# column_decode_context — reusable per-worker scratch for the column decode
# =============================================================================
#
# A worker that decodes many column chunks (every projected column of every
# row group it is handed) would otherwise allocate its decode buffers fresh per
# chunk. `ColumnDecodeContext` holds them across chunks and row groups so each
# is allocated once per worker and grown to the largest size it meets, never
# shrunk:
#
#   * the decompression scratch a page is decoded into (`ensure_scratch`,
#     `scratch_ref`);
#   * the dictionary-codes buffer of the whole-chunk decode (`ensure_codes`,
#     `codes_ref`), used only when `recycle_codes_enabled` and the output
#     copies the codes (a numeric dictionary column);
#   * the fixed sub-row-group buffers a `ResumableColumnCursor` fills
#     (`ensure_subrg_codes`, `ensure_subrg_value`);
#   * the band slots of a multi-column band decode: for N columns, slot c is
#     column c's values or codes, slot N+c its BYTE_ARRAY dictionary offsets
#     and slot 2N+c its dictionary bytes. All live in one `Slab`, so every
#     view of them shares one origin; the band cursors live in the context
#     too, so a cursor's in-place page view can be re-borrowed under the
#     context's origin (`band_agg_page_view`).
#
# Two decode choices are fields set at construction, never read from the
# environment: `numeric_dict_vec_enabled` (a numeric RLE_DICTIONARY chunk
# decodes to a dictionary column of codes plus values instead of resolved
# values) and `recycle_codes_enabled` (the codes buffer above is reused).
#
# No pointer is in a public signature: buffers are handed out as `ref`s and
# byte views tied to the context.
# =============================================================================

from komira_buffer.byte_view import ByteView
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

from .subrg_column_cursor import ResumableColumnCursor


struct ColumnDecodeContext(Movable, Deinitable):
    """Reusable per-worker decode buffers; see the module header.

    Fields:
        numeric_dict_vec_enabled: A numeric RLE_DICTIONARY chunk decodes to a
            dictionary column (codes plus values). Default False.
        recycle_codes_enabled: The whole-chunk dictionary codes decode into
            the reused codes buffer. Default False.
    """

    var _decompress_scratch: Optional[OwnedAlignedBuffer]
    var _codes_scratch: Optional[OwnedAlignedBuffer]
    var _subrg_codes_buf: Optional[OwnedAlignedBuffer]
    var _subrg_value_buf: Optional[OwnedAlignedBuffer]
    var _band_slots: Slab[OwnedAlignedBuffer]
    var _band_codes_scratch: Optional[OwnedAlignedBuffer]
    var _band_n_cols: Int
    var _band_cursors: Slab[ResumableColumnCursor]
    var numeric_dict_vec_enabled: Bool
    var recycle_codes_enabled: Bool

    def __init__(
        out self,
        numeric_dict_vec_enabled: Bool = False,
        recycle_codes_enabled: Bool = False,
    ):
        """An empty context: no buffer is allocated until first use."""
        self._decompress_scratch = None
        self._codes_scratch = None
        self._subrg_codes_buf = None
        self._subrg_value_buf = None
        self._band_slots = Slab[OwnedAlignedBuffer]()
        self._band_codes_scratch = None
        self._band_n_cols = 0
        self._band_cursors = Slab[ResumableColumnCursor]()
        self.numeric_dict_vec_enabled = numeric_dict_vec_enabled
        self.recycle_codes_enabled = recycle_codes_enabled

    # --- Decompression scratch -----------------------------------------------

    @always_inline
    def has_scratch(self) -> Bool:
        """True once the decompression scratch is allocated."""
        return Bool(self._decompress_scratch)

    def ensure_scratch(mut self, min_bytes: Int):
        """Allocate the decompression scratch, or grow it, to at least
        `min_bytes` usable bytes."""
        _ensure(self._decompress_scratch, min_bytes)

    @always_inline
    def scratch_ref(
        ref self,
    ) -> ref [self._decompress_scratch._value] OwnedAlignedBuffer:
        """The decompression scratch. `ensure_scratch` must have run."""
        return self._decompress_scratch.value()

    # --- Whole-chunk dictionary codes ----------------------------------------

    @always_inline
    def has_codes(self) -> Bool:
        """True once the codes buffer is allocated."""
        return Bool(self._codes_scratch)

    def ensure_codes(mut self, min_bytes: Int):
        """Allocate the codes buffer, or grow it, to at least `min_bytes`.
        Its contents are overwritten per chunk: the previous chunk's codes
        were already copied into their column."""
        _ensure(self._codes_scratch, min_bytes)

    @always_inline
    def codes_ref(
        ref self,
    ) -> ref [self._codes_scratch._value] OwnedAlignedBuffer:
        """The codes buffer. `ensure_codes` must have run."""
        return self._codes_scratch.value()

    def codes_capacity(self) -> Int:
        """The codes buffer's usable bytes, 0 before it is allocated."""
        if not self._codes_scratch:
            return 0
        return self._codes_scratch.value().capacity()

    def scratch_capacity(self) -> Int:
        """The decompression scratch's usable bytes, 0 before it is
        allocated."""
        if not self._decompress_scratch:
            return 0
        return self._decompress_scratch.value().capacity()

    # --- Sub-row-group buffers -------------------------------------------------

    def ensure_subrg_codes(mut self, min_bytes: Int):
        """Allocate the fixed sub-row-group codes buffer, or grow it, to at
        least `min_bytes`; sized once per worker and overwritten per chunk."""
        _ensure(self._subrg_codes_buf, min_bytes)

    def ensure_subrg_value(mut self, min_bytes: Int):
        """Allocate the fixed sub-row-group value buffer, or grow it, to at
        least `min_bytes`."""
        _ensure(self._subrg_value_buf, min_bytes)

    @always_inline
    def subrg_codes_ref(
        ref self,
    ) -> ref [self._subrg_codes_buf._value] OwnedAlignedBuffer:
        """The sub-row-group codes buffer. `ensure_subrg_codes` must have
        run."""
        return self._subrg_codes_buf.value()

    @always_inline
    def subrg_value_ref(
        ref self,
    ) -> ref [self._subrg_value_buf._value] OwnedAlignedBuffer:
        """The sub-row-group value buffer. `ensure_subrg_value` must have
        run."""
        return self._subrg_value_buf.value()

    # --- Band slots --------------------------------------------------------------

    def ensure_band_slots(mut self, n_cols: Int, value_sizes: List[Int]) raises:
        """Allocate the `3 * n_cols` band slots once (slot c at
        `value_sizes[c]` bytes, the dictionary slots at 1 byte, grown by
        `set_rg_dict`), or grow the value slots on a later call.

        Raises:
            Error if `value_sizes` has fewer than `n_cols` entries, or a
            later call names a different column count.
        """
        if len(value_sizes) < n_cols:
            raise Error(
                "decode context: " + String(len(value_sizes))
                + " value sizes for " + String(n_cols) + " band columns"
            )
        if self._band_slots.len() == 0:
            self._band_n_cols = n_cols
            for c in range(n_cols):
                self._band_slots.append(OwnedAlignedBuffer(max(value_sizes[c], 1)))
            for _ in range(2 * n_cols):
                # Empty until `set_rg_dict` copies a dictionary in, so a
                # non-string column's dictionary views are empty.
                var empty = OwnedAlignedBuffer(1)
                empty.set_length(0)
                self._band_slots.append(empty^)
            return
        if n_cols != self._band_n_cols:
            raise Error(
                "decode context: band slots hold " + String(self._band_n_cols)
                + " columns, asked for " + String(n_cols)
            )
        for c in range(n_cols):
            self._band_slots[c].reserve(max(value_sizes[c], 1))

    def ensure_band_codes(mut self, min_bytes: Int):
        """Allocate the transient codes buffer of a numeric dictionary band
        column, or grow it, to at least `min_bytes`."""
        _ensure(self._band_codes_scratch, min_bytes)

    @always_inline
    def band_n_cols(self) -> Int:
        """The band column count `ensure_band_slots` fixed (0 before)."""
        return self._band_n_cols

    @always_inline
    def band_value_ref(
        ref self, idx: Int
    ) -> ref [self._band_slots._bytes] OwnedAlignedBuffer:
        """Column `idx`'s value or codes slot."""
        return self._band_slots[idx]

    @always_inline
    def band_codes_ref(
        ref self,
    ) -> ref [self._band_codes_scratch._value] OwnedAlignedBuffer:
        """The transient codes buffer. `ensure_band_codes` must have run."""
        return self._band_codes_scratch.value()

    def set_rg_dict(mut self, idx: Int, off: List[Int32], data: List[UInt8]):
        """Copy column `idx`'s BYTE_ARRAY dictionary for this row group (its
        N+1 offsets, as little-endian Int32 bytes, and its packed bytes) into
        its dictionary slots, replacing the previous row group's."""
        var n = self._band_n_cols
        var off_bytes = len(off) * 4
        ref ob = self._band_slots[n + idx]
        ob.reserve(max(off_bytes, 1))
        ob.set_length(Int64(off_bytes))
        for i in range(len(off)):
            ob.set_typed[Int32](i, off[i])
        ref bb = self._band_slots[2 * n + idx]
        bb.reserve(max(len(data), 1))
        bb.copy_from_span_at(0, Span(data))
        bb.set_length(Int64(len(data)))

    @always_inline
    def band_value_view_ro(
        self, idx: Int, length: Int
    ) -> ByteView[origin_of(self._band_slots._bytes)]:
        """The first `length` bytes of column `idx`'s value slot."""
        return self._band_slots[idx].view_range_ro(0, length)

    @always_inline
    def band_dict_off_view_ro(
        self, idx: Int
    ) -> ByteView[origin_of(self._band_slots._bytes)]:
        """Column `idx`'s dictionary offsets (empty for a non-string column)."""
        ref b = self._band_slots[self._band_n_cols + idx]
        return b.view_range_ro(0, b.len())

    @always_inline
    def band_dict_bytes_view_ro(
        self, idx: Int
    ) -> ByteView[origin_of(self._band_slots._bytes)]:
        """Column `idx`'s dictionary bytes (empty for a non-string column)."""
        ref b = self._band_slots[2 * self._band_n_cols + idx]
        return b.view_range_ro(0, b.len())

    def band_resolve_dict_f64(
        mut self, col_idx: Int, n_band: Int, dict: List[Float64]
    ) raises:
        """Resolve `n_band` codes of the transient codes buffer through `dict`
        into column `col_idx`'s value slot as Float64.

        Raises:
            Error if a code is outside `dict`.
        """
        ref codes = self._band_codes_scratch.value()
        ref slot = self._band_slots[col_idx]
        slot.set_length(Int64(n_band * 8))
        for r in range(n_band):
            var code = Int(codes.get_typed[Int32](r))
            _check_code(code, len(dict))
            slot.set_typed[Float64](r, dict[code])

    def band_resolve_dict_int(
        mut self,
        col_idx: Int,
        n_band: Int,
        out_width: Int,
        dict: List[Int64],
    ) raises:
        """Resolve `n_band` codes through `dict` into column `col_idx`'s value
        slot as Int64 (`out_width == 8`) or Int32 (`out_width == 4`).

        Raises:
            Error if a code is outside `dict`.
        """
        ref codes = self._band_codes_scratch.value()
        ref slot = self._band_slots[col_idx]
        slot.set_length(Int64(n_band * out_width))
        for r in range(n_band):
            var code = Int(codes.get_typed[Int32](r))
            _check_code(code, len(dict))
            if out_width == 8:
                slot.set_typed[Int64](r, dict[code])
            else:
                slot.set_typed[Int32](r, Int32(dict[code]))

    # --- Band cursors ------------------------------------------------------------

    def set_band_cursors(mut self, var cursors: Slab[ResumableColumnCursor]):
        """Take this row group's band cursors, replacing the last ones."""
        self._band_cursors = cursors^

    @always_inline
    def band_cursor_read(
        self, c: Int
    ) -> ref [self._band_cursors._bytes] ResumableColumnCursor:
        """Band cursor `c`, read-only."""
        return self._band_cursors[c]

    def band_fill_driver_codes(
        mut self, driver_ci: Int, band_rows: Int
    ) raises -> Int:
        """Fill up to `band_rows` codes of the driving key column into its
        value slot."""
        return self._band_cursors[driver_ci].fill_next_codes(
            self._band_slots[driver_ci], band_rows
        )

    def band_fill_codes_at(
        mut self, c: Int, max_rows: Int, tot: Int, into_value_slot: Bool
    ) raises -> Int:
        """Fill column `c`'s next codes from slot `tot`, into its value slot
        (a string key) or the transient codes buffer (a numeric dictionary,
        resolved afterwards)."""
        if into_value_slot:
            return self._band_cursors[c].fill_next_codes_at(
                self._band_slots[c], max_rows, tot
            )
        return self._band_cursors[c].fill_next_codes_at(
            self._band_codes_scratch.value(), max_rows, tot
        )

    def band_fill_flat(mut self, c: Int, max_rows: Int, tot: Int) raises -> Int:
        """Fill column `c`'s next PLAIN values from slot `tot` into its value
        slot."""
        return self._band_cursors[c].fill_next_flat(
            self._band_slots[c], max_rows, tot
        )

    def band_ensure_page(mut self, c: Int) raises -> Int:
        """`ensure_plain_page` of band cursor `c`."""
        return self._band_cursors[c].ensure_plain_page()

    @always_inline
    def band_commit_grain(mut self, c: Int, n: Int):
        """`commit_plain_grain(n)` of band cursor `c`."""
        self._band_cursors[c].commit_plain_grain(n)

    @always_inline
    def band_agg_page_view[
        o: Origin[mut=False]
    ](ref [o] self, c: Int, nbytes: Int) -> ByteView[o]:
        """Band cursor `c`'s current grain, in place, re-borrowed under the
        context's origin. The context owns the cursor and so its page
        scratch, which is the containment `reborrow_under` requires."""
        return self._band_cursors[c].grain_view_ro(nbytes).reborrow_under(self)

    @always_inline
    def band_col_view[
        o: Origin[mut=False]
    ](ref [o] self, c: Int, length: Int) -> ByteView[o]:
        """Column `c`'s value slot, re-borrowed under the context's origin."""
        return self._band_slots[c].view_range_ro(0, length).reborrow_under(self)

    @always_inline
    def band_dict_off_view2[
        o: Origin[mut=False]
    ](ref [o] self, c: Int) -> ByteView[o]:
        """Column `c`'s dictionary offsets, re-borrowed under the context's
        origin."""
        ref b = self._band_slots[self._band_n_cols + c]
        return b.view_range_ro(0, b.len()).reborrow_under(self)

    @always_inline
    def band_dict_bytes_view2[
        o: Origin[mut=False]
    ](ref [o] self, c: Int) -> ByteView[o]:
        """Column `c`'s dictionary bytes, re-borrowed under the context's
        origin."""
        ref b = self._band_slots[2 * self._band_n_cols + c]
        return b.view_range_ro(0, b.len()).reborrow_under(self)


def _ensure(mut buf: Optional[OwnedAlignedBuffer], min_bytes: Int):
    """Allocate `buf` at `min_bytes` (at least 1), or grow it."""
    if not buf:
        buf = OwnedAlignedBuffer(max(min_bytes, 1))
    else:
        buf.value().reserve(max(min_bytes, 1))


@always_inline
def _check_code(code: Int, dict_size: Int) raises:
    if code < 0 or code >= dict_size:
        raise Error(
            "decode context: dictionary code " + String(code)
            + " outside a dictionary of " + String(dict_size)
        )
