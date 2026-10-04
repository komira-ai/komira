# =============================================================================
# komira_arrow.band_view — the parquet->engine BAND-VIEW contract
# =============================================================================
#
# OWNERSHIP: the engine (the CONSUMER / fold) owns the read-accessor surface,
# because the consumer defines what accessors it needs. The Parquet band
# producer owns the CONSTRUCTION surface it builds against: the
# `__init__(n_rows, n_cols)` + `push_flat_col` / `push_dict_string_col`
# builders + the single-origin model. The near-dense FILTER surface
# (`set_inline_filter_i32_le` / `set_selection_mask`, honored by
# `selection_live`) is band-carried because the generic engine fold is
# plan-agnostic and cannot name the filter col / cutoff. The producer sets
# it; the fold folds only live rows (mask-fold, NO gather).
#
# WHAT IT IS. A `BandView[origin]` is a BORROWED bundle of typed spans
# over ONE residency-sized row-band of the projected columns, decoded into the
# producer's REUSED per-column scratch, plus the per-RG string-dict refs. It is
# the moral analogue of `BatchView[origin]` (a typed borrow, NO UnsafePointer in
# the public surface) but backed by REUSED scratch spans, not a materialized
# `RecordBatch` — so constructing it costs ZERO byte-copies.
#
# THE SINGLE-ORIGIN MODEL (the load-bearing constraint). Every
# span the band exposes carries `Self.origin`. The producer arranges for ALL
# backing storage to live in ONE owner — the per-worker `ColumnDecodeContext`
# (the "ctx") — so every `ByteView`/`Span` the producer derives shares that
# owner's borrow origin. The band is then `BandView[origin_of(ctx)]`.
# `consume_band` receives it by BORROW (read) and must not stash any derived
# span past the method scope (a stash is a compile error — the origin outlives
# its frame). This is what makes reused scratch safe: the fold completes
# synchronously before the producer overwrites the scratch for the next band.
#
#   *** THE BUNDLE ORIGIN IS THE CTX-BORROW ORIGIN, NOT A SINGLE FIELD. ***
# The band does not require every span to physically live in ONE
# `_band_slots` slab. It requires them to be
# TRANSITIVELY OWNED by ONE ctx, whose read-borrow origin (`origin_of(ctx)`) is
# the bundle origin. Two backing regions coexist under that one origin:
#   (1) KEY CODES + per-RG string DICT + the near-dense filter mask live in the
#       ctx's `_band_slots` arena (COPIED once — codes lockstep-filled per band,
#       dict copied once per RG). These are reborrowed under `origin_of(ctx)`.
#   (2) A PLAIN fixed-width AGGREGAND span may be a ZERO-COPY VIEW into the
#       per-column decode CURSOR's decompressed page-window scratch (`_scratch`)
#       — the exact bytes the codec produced, never copied into a band slot
#       (that copy would dominate the column write). The cursor is
#       OWNED BY THE CTX, so its page scratch is transitively ctx-owned; the span
#       reborrows under `origin_of(ctx)` (via `ByteView.reborrow_under(ctx)`) and
#       joins the SAME bundle. `push_flat_col_page_view` is its entry point.
# Because both regions share `origin_of(ctx)`, `consume_band` still sees ONE
# coherent `BandView[o]` — it reads every flat/agg span identically (a typed
# `Span[dt, o]`), oblivious to whether the bytes were copied or are a page view,
# so the fused hash-aggregate inner kernel needs no change for either.
#
# WHY THIS HAS NO STALE-POINTER HAZARD. The origin is a CONCRETE,
# compiler-tracked borrow (`origin_of(ctx)`), never a wildcard
# (`Mut/ImmutAnyOrigin`), so ASAP destruction is preserved and no
# destroy-recreate byte-reuse hazard forms — the
# BandView is a transient stack value that never outlives one `consume_band`
# call, and the ctx it borrows outlives the whole fork-join. The zero-copy
# reborrow does NOT create an owning wildcard field nor a teardown-order
# dependency: the aggregand view is a borrow that lives strictly inside
# one synchronous produce->consume->reuse step, and the cursor's
# `_scratch` (an `OwnedAlignedBuffer`, the byte-backed shape) is freed
# only at worker teardown, AFTER the last band is folded.
#
# THE PAGE-ALIGNMENT INVARIANT (the producer obligation of the zero-copy
# form). A
# zero-copy aggregand view exposes ONE decompressed PAGE window (the cursor's
# current `_scratch` page), so it covers only that page's remaining rows. The
# producer therefore MUST cap the whole band at `band_rows <= min over the
# zero-copy aggregand columns of (their current page's remaining rows)` (and the
# driver key's available rows) — a page-aligned lockstep. Every span in the
# bundle must cover exactly `n_rows` values; the flat accessors debug-assert it.
#
# ENCAPSULATION: NO UnsafePointer in any PUBLIC signature. The
# per-column raw byte spans are stored as `ByteView[origin]` (already a safe
# view: pointer+len behind an origin, no raw pointer surface). The typed-span
# accessors REINTERPRET those bytes into `Span[Scalar[dt], origin]` inside
# private helpers with a `# SAFETY:` comment — identical to how `ColView`
# re-derives its interior pointer inside `load[W]`. This file is under
# `komira_core/collections/`, so the `ByteView._unsafe_ptr` module-private
# escape is in-scope.
# =============================================================================

from std.memory import UnsafePointer
from std.collections import List, Optional
from std.sys import size_of

from komira_buffer.byte_view import ByteView


struct BandView[origin: Origin[mut=False]](Movable):
    """A borrowed, typed, ZERO-COPY view over one residency-sized row-band of the
    projected columns (decoded into the producer's reused per-column scratch) +
    the per-RG string dict refs.

    Column role is known to the consumer (the fold) by PROJECTION INDEX (the
    `SubrgAggPlan`/`HashAggSpec` already carry `key_proj_idx` + agg positions +
    filter col). The band exposes RAW typed span accessors BY INDEX; the fold
    drives them by role. All spans carry `Self.origin` (the producer decode-frame
    origin). NO UnsafePointer in the public surface.

    Fields (all indexed by projection column 0..n_cols):
        _n_rows: rows in THIS band (<= the residency band width; the LAST band of
            an RG is short). Every span below is valid for exactly [0, n_rows).
        _n_cols: projection arity.
        _cols: per-column raw byte span over that column's decoded band buffer
            (n_rows * width(c) bytes). Reinterpreted per accessor dtype.
        _dict_off: per-column string-dict OFFSETS bytes (N+1 cumulative int32);
            an empty view for non-dict-string columns.
        _dict_bytes: per-column packed string-dict UTF-8 bytes; empty for
            non-dict-string columns.
        _filter_col / _filter_cutoff_i32 / _sel_mask: the near-dense filter
            HONORED by `selection_live`; mask-fold, NO gather.
    """

    var _n_rows: Int
    var _n_cols: Int
    var _cols: List[ByteView[Self.origin]]
    var _dict_off: List[ByteView[Self.origin]]
    var _dict_bytes: List[ByteView[Self.origin]]
    # --- near-dense filter — HONORED by `selection_live`; mask-fold, NO
    #     gather. The generic engine fold (`HashAggTable.consume_band`) is
    #     filter-agnostic: it calls `selection_live(row)` uniformly, so the
    #     filter mechanism lives HERE (band-carried) rather than in the fold
    #     (which cannot name the plan's filter col / cutoff). The producer sets
    #     EITHER an inline `<=` filter over one projected i32 column OR a
    #     precomputed bit-packed mask; absent both, every row is live.
    var _filter_col: Int  # projection idx of the filter input, or -1 (inactive)
    var _filter_cutoff_i32: Int32  # `col_i32_span(_filter_col)[row] <= cutoff`
    var _sel_mask: Optional[ByteView[Self.origin]]  # bit-packed LSB-first / None

    # -------------------------------------------------------------------------
    # Construction surface (PRODUCER-driven — the construction contract).
    #   The producer default-constructs `BandView[o](n_rows, n_cols)` at the
    #   consume_band call site (so `o` is the ctx borrow origin that outlives the
    #   fold), then `push_*_col` each projected column IN PROJECTION ORDER. Every
    #   push appends to ALL THREE parallel lists (empty dict views for a flat
    #   col) so `_cols[idx]`/`_dict_off[idx]`/`_dict_bytes[idx]` line up by idx.
    # -------------------------------------------------------------------------

    def __init__(out self, n_rows: Int, n_cols: Int):
        """Construct an empty band of `n_rows` rows / `n_cols` columns; the
        producer pushes each column in projection order."""
        self._n_rows = n_rows
        self._n_cols = n_cols
        self._cols = List[ByteView[Self.origin]](capacity=n_cols)
        self._dict_off = List[ByteView[Self.origin]](capacity=n_cols)
        self._dict_bytes = List[ByteView[Self.origin]](capacity=n_cols)
        self._filter_col = -1
        self._filter_cutoff_i32 = Int32(0)
        self._sel_mask = None

    def set_inline_filter_i32_le(mut self, col_idx: Int, cutoff: Int32):
        """Configure the near-dense filter as an inline `col_i32_span(col_idx)[row]
        <= cutoff` (e.g. `l_shipdate <= cutoff`). `selection_live` then evaluates it
        per row — mask-fold, NO gather; the producer feeds ALL band rows and the
        fold walks only the live ones. The producer MUST call this (or
        `set_selection_mask`) for a filtered scan, else every row is folded."""
        self._filter_col = col_idx
        self._filter_cutoff_i32 = cutoff

    def set_selection_mask(mut self, mask: ByteView[Self.origin]):
        """Configure a precomputed bit-packed (LSB-first, Arrow-validity-style)
        selection mask over [0, n_rows). `selection_live` reads the bit. The
        alternative to `set_inline_filter_i32_le` (the precomputed-mask
        form); either is permitted."""
        self._sel_mask = mask

    def push_flat_col(mut self, bytes: ByteView[Self.origin]):
        """Append ONE fixed-width numeric column's raw byte span (f64 / i64 /
        i32 aggregand or filter). Empty dict views (this is not a dict-string
        column).

        This is the COPIED-into-ctx-slot form: `bytes` is a view over a
        `_band_slots` value buffer the producer decoded into (the path for
        dict-NUMERIC aggregands resolved to flat, and for
        the filter input). `bytes` MUST cover >= `n_rows` values of the column's
        dtype (asserted at read time by the typed accessors). For a PLAIN
        aggregand that can skip the copy, prefer `push_flat_col_page_view`."""
        self._cols.append(bytes)
        self._dict_off.append(ByteView[Self.origin]())
        self._dict_bytes.append(ByteView[Self.origin]())

    def push_flat_col_page_view(
        mut self, bytes: ByteView[Self.origin], elem_width: Int
    ):
        """Append ONE PLAIN fixed-width AGGREGAND column as a
        ZERO-COPY VIEW into the decode cursor's page-window scratch (NOT copied
        into a `_band_slots` value buffer). `bytes` is the cursor's decompressed
        page window at the current decode offset, reborrowed under the ctx origin
        (`cursor.grain_view_ro(...).reborrow_under(ctx)`), so it shares
        `Self.origin` with the key/dict spans and joins the same bundle.

        Functionally IDENTICAL to `push_flat_col` from the fold's view (it stores
        the same `ByteView[Self.origin]` + empty dict views, and `consume_band`
        reads it via the same typed accessor). The DISTINCTION is the producer
        contract this name pins:
          * ZERO-COPY: `bytes` aliases codec output; no per-band aggregand copy.
          * PAGE-ALIGNMENT: the view exposes ONE page, so the producer MUST have
            capped `n_rows` at <= this column's current-page remaining rows. This
            method DEBUG-ASSERTS the coverage (`bytes.len() >= n_rows *
            elem_width`) — a short view means the band spilled a page boundary
            (a producer lockstep bug), caught here rather than as an OOB read in
            the fold.

        Args:
            bytes: The page-window byte view (>= n_rows * elem_width bytes),
                origin-shared with the bundle (reborrowed under the ctx).
            elem_width: The aggregand's fixed element width in bytes (8 for f64/
                i64, 4 for i32) — used only for the page-coverage assertion.
        """
        debug_assert(
            bytes.len() >= self._n_rows * elem_width,
            (
                "BandView.push_flat_col_page_view: page view too short for"
                " n_rows (band spilled a page boundary — cap band_rows at the"
                " min aggregand page remaining)"
            ),
        )
        self._cols.append(bytes)
        self._dict_off.append(ByteView[Self.origin]())
        self._dict_bytes.append(ByteView[Self.origin]())

    def push_dict_string_col(
        mut self,
        codes: ByteView[Self.origin],
        dict_off: ByteView[Self.origin],
        dict_bytes: ByteView[Self.origin],
    ):
        """Append ONE DICTIONARY string key column: `codes` (one Int32 per row,
        over the reused code scratch) + the per-RG string dict (N+1 int32 offsets
        + packed UTF-8 bytes, BORROWED not copied per band)."""
        self._cols.append(codes)
        self._dict_off.append(dict_off)
        self._dict_bytes.append(dict_bytes)

    # -------------------------------------------------------------------------
    # Read surface (CONSUMER-driven — the fold codes to exactly these).
    # -------------------------------------------------------------------------

    @always_inline
    def n_rows(self) -> Int:
        """Row count of THIS band."""
        return self._n_rows

    @always_inline
    def n_cols(self) -> Int:
        """Projection arity."""
        return self._n_cols

    # --- fixed-width numeric aggregand / filter columns ---
    @always_inline
    def col_f64_span(self, idx: Int) -> Span[Scalar[DType.float64], Self.origin]:
        """Typed f64 span over column `idx` (n_rows values)."""
        return self._typed_span[DType.float64](idx)

    @always_inline
    def col_i64_span(self, idx: Int) -> Span[Scalar[DType.int64], Self.origin]:
        """Typed i64 span over column `idx` (n_rows values)."""
        return self._typed_span[DType.int64](idx)

    @always_inline
    def col_i32_span(self, idx: Int) -> Span[Scalar[DType.int32], Self.origin]:
        """Typed i32 span over column `idx` (n_rows values). Also the filter
        INPUT accessor (e.g. `l_shipdate`)."""
        return self._typed_span[DType.int32](idx)

    @always_inline
    def col_scalar[dt: DType](self, idx: Int, row: Int) -> Scalar[dt]:
        """Generic fixed-width scalar read: the `Scalar[dt]` at (`idx`, `row`)
        over the flat column band buffer. The band analogue of
        `BatchView.col_scalar_nonraising[dt]` — the single generic numeric read
        that a NUMERIC group-key column (`DistinctKeyColumn_Typed[dt, col]`)
        drives off the band (its `hash_step_band` / `equals_row_band`), so the
        band fold supports numeric keys, not just dict-string keys. Bit-exact
        over the fixed-width matrix (the accessor reinterprets the raw bytes)."""
        return self._typed_span[dt](idx)[row]

    # --- DICTIONARY string key columns (fold over CODES; resolve per-entry) ---
    @always_inline
    def dict_codes(self, idx: Int) -> Span[Scalar[DType.int32], Self.origin]:
        """Int32 dict-index codes for column `idx`, one per row."""
        return self._typed_span[DType.int32](idx)

    @always_inline
    def dict_offsets(
        self, idx: Int
    ) -> Span[Scalar[DType.int32], Self.origin]:
        """The per-RG string dict's N+1 cumulative int32 offsets (borrowed)."""
        var bv = self._dict_off[idx]
        # SAFETY: `bv` is an origin-tied ByteView over the ctx's dict-offsets
        # buffer; its byte length is a multiple of 4. Reinterpret as int32. This
        # file is under komira_core/collections/, so `_unsafe_ptr` is in-scope.
        # The returned Span carries `Self.origin` — no wildcard.
        var n = bv.len() // 4
        var ptr = bv._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        return Span[Scalar[DType.int32], Self.origin](unsafe_ptr=ptr, length=n)

    @always_inline
    def dict_bytes(self, idx: Int) -> ByteView[Self.origin]:
        """The per-RG string dict's packed UTF-8 bytes (borrowed)."""
        return self._dict_bytes[idx]

    @always_inline
    def resolve_string(self, idx: Int, row: Int) -> ByteView[Self.origin]:
        """DICT_KEYS primitive: code -> ByteView over
        `dict_bytes[offsets[code] : offsets[code+1]]`. Resolve-per-ROW is the
        naive form; the fold caches per-dict-entry (tiny domain), so this is
        called once per distinct code. Byte-identical to
        `BatchView.col_string_dict_value_at`."""
        var codes = self.dict_codes(idx)
        var offs = self.dict_offsets(idx)
        var code = Int(codes[row])
        var lo = Int(offs[code])
        var hi = Int(offs[code + 1])
        var db = self._dict_bytes[idx]
        # SAFETY: `lo`/`hi` come from the cumulative offsets (0 <= lo <= hi <=
        # len); the returned ByteView is a sub-range of the origin-tied dict
        # bytes (`ByteView.sub` bounds-checks). Origin preserved.
        return db.sub(lo, hi - lo)

    @always_inline
    def has_selection_mask(self) -> Bool:
        """True iff a precomputed selection mask is set (vs the inline-`<=` form
        or no filter)."""
        return Bool(self._sel_mask)

    @always_inline
    def selection_live(self, row: Int) -> Bool:
        """Is `row` LIVE under the near-dense filter? The generic engine fold
        (`HashAggTable.consume_band`) calls this uniformly per row and folds ONLY
        live rows — mask-fold, NO gather (the near-dense arm).

        Resolution order: (1) a precomputed bit-packed mask, if set; else (2) the
        inline `col_i32_span(_filter_col)[row] <= _filter_cutoff_i32`, if
        configured; else (3) True (no filter — every row live). This keeps the
        filter mechanism band-carried, so the plan-agnostic generic fold need not
        name the filter col / cutoff."""
        if self._sel_mask:
            ref m = self._sel_mask.value()
            var byte = m.read_u8_at(row >> 3)
            return ((byte >> UInt8(row & 7)) & UInt8(1)) == UInt8(1)
        if self._filter_col >= 0:
            return self.col_i32_span(self._filter_col)[row] <= (
                self._filter_cutoff_i32
            )
        return True

    # -------------------------------------------------------------------------
    # Private — typed-span reinterpretation of a column's raw bytes.
    # -------------------------------------------------------------------------
    @always_inline
    def _typed_span[
        dt: DType
    ](self, idx: Int) -> Span[Scalar[dt], Self.origin]:
        var bv = self._cols[idx]
        # SAFETY: `bv` is an origin-tied ByteView over EITHER the ctx's per-column
        # `_band_slots` value buffer (copied path) OR a cursor page-window scratch
        # span reborrowed under the ctx origin (zero-copy path) —
        # both carry `Self.origin`. It was filled with (or aliases) `_n_rows`
        # values of `dt` (width = size_of[dt]). The debug-assert catches a backing
        # view too short to cover the band (a producer page-alignment / lockstep
        # bug) BEFORE the reinterpret, rather than as a silent OOB read in the
        # fold. Reinterpret the byte pointer as `Scalar[dt]`; length is `_n_rows`.
        # This file is under komira_core/collections/, so `_unsafe_ptr` is
        # in-scope. The returned Span carries `Self.origin` — no wildcard,
        # no raw pointer in the public surface.
        debug_assert(
            bv.len() >= self._n_rows * size_of[Scalar[dt]](),
            "BandView._typed_span: backing view too short for n_rows",
        )
        var ptr = bv._unsafe_ptr().bitcast[Scalar[dt]]()
        return Span[Scalar[dt], Self.origin](unsafe_ptr=ptr, length=self._n_rows)
