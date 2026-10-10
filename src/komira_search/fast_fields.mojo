# =============================================================================
# komira_search/fast_fields.mojo
#   The FAST-FIELDS region ("THFF"): per-field columnar STORAGE + the O(1)
#   read accessor + the doc-length fieldnorm.
# =============================================================================
#
# Upstream: the split container (split.mojo — the LSB-first bitpack +
# DocStoreBuilder's dense slot + the footer-reserved fastfields slot).
# Downstream: filters, sort and aggregations consume the FastFieldReader
# accessor without touching the region format.
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE OWNS (PURE, S3-FREE, unit-testable)
# -----------------------------------------------------------------------------
#   * FastFieldSpec — POD classified-column spec (resolved in init_sink).
#   * NumericFastFieldBuilder / KeywordFastFieldBuilder — POD List-backed
#     per-field accumulators (mirror DocStoreBuilder; no owning pointer fields).
#   * serialize_fastfields_region — assembles the "THFF" region bytes from the
#     builders (two-pass sub-directory, same patch discipline as serialize_split).
#   * FastFieldReader — parses the "THFF" sub-directory ONCE at construction;
#     serves O(1) scalar reads (fast_field_i64 / _f64 / _keyword) + a whole-column
#     materializer (fast_field_column). Holds NO Span field — re-derives the
#     region Span per call from the borrowed `view: SplitView` param (the
#     BatchView idiom). Fail-loud bounds-checked over the attacker-influenced
#     split.
#
# -----------------------------------------------------------------------------
# DESIGN POINTS J1–J6 (referenced by label below)
# -----------------------------------------------------------------------------
#   J1  Temporal classification + fail-loud dispatch. Field.dtype is
#       DType.invalid for DATE32/DATE64/TIME*/DURATION*/INTERVAL* (the core packages
#       schema), so ingest+read dispatch is on arrow_type_id -> a STORAGE DType
#       (_storage_dtype_for_arrow_type_id), NOT on Field.dtype. DATE is classified
#       only when arrow_type.is_temporal() AND the arrow_type_id maps to int32/
#       int64 (DATE32->i32, DATE64/TIMESTAMP_*->i64). The dtype ladder RAISES on
#       any unhandled type (never falls through to col_i64).
#   J2  Float codec. The signed Int packer (_pack_bits_lsb_first) raises on
#       negative values; a float bitcast can set the sign bit. So floats are
#       stored LOSSLESSLY via a sibling UNSIGNED packer (_pack_bits_lsb_first_u64)
#       at FULL WIDTH (bits=32 for FLOAT32, bits=64 for FLOAT64; NO frame-of-
#       reference over bit patterns, which would risk residuals > 2^63). Lossless
#       + O(1). A tighter order-preserving float codec is a possible later size
#       lever.
#   J3  Fieldnorm = the reserved-name numeric fast-field "__fieldnorm__" whose
#       per-doc value = AnalyzedField.len() (the token count, captured in
#       add_text_column via the token_counts out-param).
#   J4  Read-back type/null. The numeric/date materializer stamps the logical
#       ArrowType (from_primitive_with_arrow_type) so DATE32 survives as DATE32.
#       Null capture uses BatchView.col_is_null (DType-agnostic).
#   J5  Keyword dict = flat per-field SORTED dictionary. Fieldnorm rides the
#       region (no dedicated footer slot). Floats full-width lossless.
#   J6  The additive gotcha: serialize_split captures + fills the footer slot;
#       SplitView.parse captures it + bounds the region between docstore_end and
#       footer_start WHEN present (in split.mojo).
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner self-audit)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature.
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * The builders are all-POD List substrate (List[Int]/List[Bool]/
#     List[String]). They are IndexCore FIELDS, never byte-slab elements.
#     FastFieldReader is Movable, holds NO Span field. Region Spans are tied to
#     the INNER _bytes field origin on the SplitView accessor; the per-call
#     `view` param is a borrow.
# =============================================================================

from std.memory import bitcast
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_arrow.bitmap import Bitmap
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.byte_buffer import write_uleb128

from .analyzer import (
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
)
from .split import (
    SplitView,
    _min_bit_width,
    _packed_byte_count,
    _pack_bits_lsb_first,
    _unpack_bits_lsb_first,
    _read_uleb128_span,
)


# =============================================================================
# Region constants (FROZEN — the filter / sort / aggregation decode contract).
# =============================================================================

comptime FF_MAGIC_LEN: Int = 4
"""'THFF' region sentinel — appears at region start."""

comptime FF_VERSION: UInt8 = 1
"""Fast-fields region schema version."""

comptime FF_ENC_FOR_BITPACK: UInt8 = 1
"""Encoding: frame-of-reference + LSB-first bitpack (numeric/date)."""

comptime FF_ENC_KEYWORD_DICT: UInt8 = 2
"""Encoding: flat sorted dictionary + bitpacked dict-code array (keyword)."""

comptime FF_ENC_FLOAT_FULL: UInt8 = 3
"""Encoding: full-width lossless unsigned bitpack of IEEE-754 bit patterns
(float — J2; NO frame-of-reference)."""

comptime FIELDNORM_NAME: String = "__fieldnorm__"
"""The reserved-name numeric fast-field carrying the per-doc token count.
init_sink raises if a user column is literally named this."""


# =============================================================================
# Storage-DType resolution (dispatch on arrow_type_id, NOT Field.dtype).
# =============================================================================
#
# Field.dtype is DType.invalid for DATE32/DATE64/TIME*/DURATION*/INTERVAL*
# (the core packages' schema only maps numerics + timestamps to a real DType). So the
# ingest read + the read-back materializer dispatch on arrow_type_id mapped to a
# STORAGE-ALIASABLE DType. This is J1: never read a composite temporal through
# col_i64 (that corrupts the bit pattern).
#
# The storage DType drives WHICH BatchView.col_* accessor reads the cell at
# ingest, and WHICH PrimitiveArray[dtype] the materializer builds. The returned
# DType is one of: int8/16/32/64, uint8/16/32/64, float32/float64, OR
# DType.invalid for "not a fast-field" (the caller skips it).


# =============================================================================
# THE ABSENT-DType SENTINEL IS ONE VALUE, AND IT LIVES IN the core packages.
# =============================================================================
# This package does NOT define its own "not a fast field" sentinel: a second
# sentinel bound to the SAME DType as the core packages' `DTYPE_NONE` would collide
# with it. (This comment does not NAME the type: only the sentinel's own file
# should.)
#
# TWO SENTINELS THAT AGREE ARE WORSE THAN ONE, because the agreement is
# invisible: nothing in the type system says the bytes must stay equal, and the
# day one side moves, a fast-field check starts answering the null question.
#
# THE MEANINGS ARE NOT ACTUALLY DIFFERENT, and that is what makes the merge
# correct rather than merely convenient. `_storage_dtype_for_arrow_type_id`
# returns this value for a column that has NO physical storage DType -- which
# is exactly what `DTYPE_NONE` means ("this value carries no dtype", the
# discriminant that replaced 1.0.0's removed `DType.invalid`). "Not a fast
# field" was a NAME for the absence, not a second concept.
#
# The `Optional[DType]` migration remains the end state and remains open
# (see `komira_arrow/dtype_sentinel.mojo`). What changed here is that there is
# now ONE place to migrate instead of two that must be migrated in lockstep.
comptime _DTYPE_NOT_A_FAST_FIELD: DType = DTYPE_NONE


@always_inline
def _storage_dtype_for_arrow_type_id(arrow_type_id: UInt8) -> DType:
    """Map an Arrow type_id to the physical STORAGE DType used to read/write the
    fast-field. Returns DType.invalid for any type NOT in the fast-field set
    (the caller must skip it). DATE32->int32, DATE64/TIMESTAMP_*->int64."""
    # --- true numerics (Field.dtype IS reliable here, but we map uniformly) ---
    if arrow_type_id == ArrowType.INT8.type_id:
        return DType.int8
    elif arrow_type_id == ArrowType.INT16.type_id:
        return DType.int16
    elif arrow_type_id == ArrowType.INT32.type_id:
        return DType.int32
    elif arrow_type_id == ArrowType.INT64.type_id:
        return DType.int64
    elif arrow_type_id == ArrowType.UINT8.type_id:
        return DType.uint8
    elif arrow_type_id == ArrowType.UINT16.type_id:
        return DType.uint16
    elif arrow_type_id == ArrowType.UINT32.type_id:
        return DType.uint32
    elif arrow_type_id == ArrowType.UINT64.type_id:
        return DType.uint64
    elif arrow_type_id == ArrowType.FLOAT32.type_id:
        return DType.float32
    elif arrow_type_id == ArrowType.FLOAT64.type_id:
        return DType.float64
    # --- storage-aliasable temporals (the J1 narrowing) ---
    elif arrow_type_id == ArrowType.DATE32.type_id:
        return DType.int32  # days since epoch (Int32)
    elif arrow_type_id == ArrowType.DATE64.type_id:
        return DType.int64  # ms since epoch (Int64)
    elif arrow_type_id == ArrowType.TIMESTAMP.type_id:
        return DType.int64
    elif arrow_type_id == ArrowType.TIMESTAMP_S.type_id:
        return DType.int64
    elif arrow_type_id == ArrowType.TIMESTAMP_MS.type_id:
        return DType.int64
    elif arrow_type_id == ArrowType.TIMESTAMP_US.type_id:
        return DType.int64
    elif arrow_type_id == ArrowType.TIMESTAMP_NS.type_id:
        return DType.int64
    # --- everything else (BOOL / BINARY / nested / Interval / Time / Duration /
    #     composite temporals): NOT a fast-field. Caller SKIPS. ---
    return _DTYPE_NOT_A_FAST_FIELD  # PLACEHOLDER — was DType.invalid


@always_inline
def _is_float_dtype(dt: DType) -> Bool:
    return dt == DType.float32 or dt == DType.float64


# =============================================================================
# zig-zag (signed min) + the UNSIGNED bitpack sibling.
# =============================================================================
#
# The numeric/date frame-of-reference stores `min_value` as a SIGNED i64. ULEB128
# is unsigned, so we zig-zag the signed min before write and un-zig-zag on read.
# The residual (value - min_value) is always >= 0 and rides the existing signed
# Int packer (split.mojo:_pack_bits_lsb_first).
#
# Floats are stored LOSSLESSLY as full-width UInt bit patterns. A float
# bitcast can set the sign bit (=> negative as Int), which the signed packer
# rejects, so floats ride a sibling UNSIGNED packer over UInt64 lanes.


@always_inline
def _zigzag_encode(v: Int) -> Int:
    """Map a signed Int to a non-negative Int for ULEB128. 0->0, -1->1, 1->2,
    -2->3, ... (the standard protobuf zig-zag, in 64-bit)."""
    return (v << 1) ^ (v >> 63)


@always_inline
def _zigzag_decode(u: Int) -> Int:
    """Inverse of _zigzag_encode (treats `u` as the non-negative encoding)."""
    return (u >> 1) ^ -(u & 1)


def _pack_bits_lsb_first_u64(
    values: Span[UInt64, _], count: Int, bit_width: Int, mut out: List[UInt8]
) raises:
    """Append the LSB-first bitpacking of `values[0:count]` at `bit_width` bits
    each (treated as UNSIGNED UInt64) to `out`. The unsigned sibling of
    split.mojo:_pack_bits_lsb_first — needed because a float bit pattern with the
    sign bit set is negative as Int (the signed packer raises). width==0 emits
    ZERO bytes."""
    if bit_width == 0:
        return
    if bit_width < 0 or bit_width > 64:
        raise Error(
            "_pack_bits_lsb_first_u64: bit_width "
            + String(bit_width)
            + " out of range [0, 64]"
        )
    var total_bytes = _packed_byte_count(count, bit_width)
    var base = len(out)
    for _ in range(total_bytes):
        out.append(0)
    var bit_pos = 0
    for i in range(count):
        var uv = values[i]
        for b in range(bit_width):
            if (uv >> UInt64(b)) & UInt64(1) != UInt64(0):
                var abs_bit = bit_pos + b
                var byte_idx = base + (abs_bit >> 3)
                var bit_in_byte = abs_bit & 7
                out[byte_idx] = out[byte_idx] | (UInt8(1) << UInt8(bit_in_byte))
        bit_pos += bit_width


def _unpack_bits_lsb_first_u64(
    src: Span[UInt8, _],
    src_off: Int,
    count: Int,
    bit_width: Int,
    mut out: List[UInt64],
) raises:
    """Append `count` values, each `bit_width` bits LSB-first decoded as UNSIGNED
    UInt64, from `src` starting at byte offset `src_off`, to `out`. The exact
    inverse of `_pack_bits_lsb_first_u64`. width==0 appends `count` zeros. Raises
    if the run would read past `src` (fail-loud)."""
    if bit_width == 0:
        for _ in range(count):
            out.append(UInt64(0))
        return
    if bit_width < 0 or bit_width > 64:
        raise Error(
            "_unpack_bits_lsb_first_u64: bit_width "
            + String(bit_width)
            + " out of range [0, 64]"
        )
    var total_bytes = _packed_byte_count(count, bit_width)
    if src_off < 0 or src_off + total_bytes > len(src):
        raise Error(
            "_unpack_bits_lsb_first_u64: packed run ["
            + String(src_off)
            + ", "
            + String(src_off + total_bytes)
            + ") exceeds source length "
            + String(len(src))
            + " (corrupt)"
        )
    var bit_pos = 0
    for _ in range(count):
        var v = UInt64(0)
        for b in range(bit_width):
            var abs_bit = bit_pos + b
            var byte_idx = src_off + (abs_bit >> 3)
            var bit_in_byte = abs_bit & 7
            var bit = (src[byte_idx] >> UInt8(bit_in_byte)) & UInt8(1)
            if bit != UInt8(0):
                v = v | (UInt64(1) << UInt64(b))
        out.append(v)
        bit_pos += bit_width


@always_inline
def _ff_min_u64_bit_width(max_value: UInt64) -> Int:
    """Smallest bit width that can represent `max_value` (unsigned). Returns 0
    for max_value == 0 (an all-zero column needs zero residual bytes)."""
    if max_value == UInt64(0):
        return 0
    var w = 0
    var v = max_value
    while v > UInt64(0):
        w += 1
        v = v >> UInt64(1)
    return w


# =============================================================================
# validity bitmap helpers (LSB-first, ceil(n/8) bytes).
# =============================================================================


def _append_validity_bitmap(is_null: List[Bool], mut out: List[UInt8]):
    """Append a ceil(n/8)-byte LSB-first validity bitmap: bit=1 VALID, bit=0
    NULL (Arrow convention)."""
    var n = len(is_null)
    var nbytes = (n + 7) >> 3
    for _ in range(nbytes):
        out.append(0)
    var base = len(out) - nbytes
    for i in range(n):
        if not is_null[i]:
            var byte_idx = base + (i >> 3)
            var bit = i & 7
            out[byte_idx] = out[byte_idx] | (UInt8(1) << UInt8(bit))


def _read_validity_bit(
    region: Span[UInt8, _], bitmap_off: Int, slot: Int
) -> Bool:
    """Read the validity bit for `slot` (bit=1 -> valid -> returns True). Caller
    must already have bounds-validated [bitmap_off, bitmap_off+ceil(n/8))."""
    var byte_idx = bitmap_off + (slot >> 3)
    var bit = slot & 7
    return ((region[byte_idx] >> UInt8(bit)) & UInt8(1)) == UInt8(1)


# =============================================================================
# FastFieldSpec: one classified fast-field column (POD, resolved at init).
# =============================================================================


@fieldwise_init
struct FastFieldSpec(Copyable, Movable, Deinitable):
    """One classified fast-field column: POD value-spec resolved in init_sink.
    Trivial POD-ish (String + Int + UInt8 + DType). The `name` String is a value,
    not a slab element (it is not ImplicitlyCopyable — use .copy()/ref on read).
    """

    var name: String
    """The column name (the directory key)."""
    var col_idx: Int
    """Source column index in the batch."""
    var field_class: UInt8
    """FIELD_CLASS_NUMERIC / FIELD_CLASS_DATE / FIELD_CLASS_KEYWORD."""
    var arrow_type_id: UInt8
    """Field.arrow_type.type_id (typed read-back via the materializer)."""
    var storage_dtype: DType
    """The physical storage DType (from _storage_dtype_for_arrow_type_id).
    Drives which BatchView.col_* accessor reads the cell at ingest. Unused for
    keyword fields (they read via col_str)."""


# =============================================================================
# Per-field builders (POD List-backed, no owning pointer fields; mirror DocStoreBuilder).
# =============================================================================


struct NumericFastFieldBuilder(Copyable, Movable, Deinitable):
    """Dense per-doc numeric/date column accumulator (slot i = i-th appended doc).
    DATE rides this too (stored as its physical Int). Floats store the IEEE-754
    bit pattern as a UInt64 (full-width lossless, encoding FF_ENC_FLOAT_FULL).

    All-POD List substrate (no heap-owning element, no Slab). The
    dense-ascending invariant (slot == doc_id - min_doc_id) holds because append
    is the only mutator and is called once per doc in arrival order (mirrors
    DocStoreBuilder in split.mojo)."""

    var _values: List[Int]
    """Raw values for int/date (signed). Unused when _is_float (see _fbits)."""
    var _fbits: List[UInt64]
    """IEEE-754 bit patterns for float fields. Unused for int/date."""
    var _is_null: List[Bool]
    """Per-doc null flag (-> validity bitmap at serialize)."""
    var _arrow_type_id: UInt8
    var _storage_dtype: DType
    var _is_float: Bool
    var _num_docs: Int

    def __init__(out self, arrow_type_id: UInt8, storage_dtype: DType):
        self._values = List[Int]()
        self._fbits = List[UInt64]()
        self._is_null = List[Bool]()
        self._arrow_type_id = arrow_type_id
        self._storage_dtype = storage_dtype
        self._is_float = _is_float_dtype(storage_dtype)
        self._num_docs = 0

    @always_inline
    def num_docs(self) -> Int:
        return self._num_docs

    @always_inline
    def is_float(self) -> Bool:
        return self._is_float

    def total_value(self) -> Int:
        """Sum of every NON-NULL int/date cell's raw value (null cells contribute
        nothing — they store a 0 placeholder anyway). Used by the sink to record
        the per-split total token count in the split footer (the "__fieldnorm__"
        builder's total == sum of per-doc token counts), so the BM25 b>0 reader
        gets `avgdl = total / doc_count` in O(1) instead of summing the whole
        column at query time. Undefined for a float builder (token counts are
        always int-stored); returns the int-residual sum, which the caller only
        invokes on the fieldnorm builder."""
        var total = 0
        for i in range(self._num_docs):
            if not self._is_null[i]:
                total += self._values[i]
        return total

    def token_counts(self) -> List[Int]:
        """The dense per-doc int values by slot (slot i = i-th appended doc =
        doc_id - min_doc_id). For the "__fieldnorm__" builder this IS the per-doc
        `dl` (token count) the WAND Phase-2 (BMW) codec needs to compute per-block
        `min_dl`. A null cell reads as its 0 placeholder (the most-favorable dl
        for the upper bound, so the per-block min still rounds up). Undefined for
        a float builder; the sink only invokes this on the int-stored fieldnorm."""
        var out = List[Int](capacity=self._num_docs)
        for i in range(self._num_docs):
            if self._is_null[i]:
                out.append(0)
            else:
                out.append(self._values[i])
        return out^

    def append_int(mut self, value: Int, is_null: Bool):
        """Append one int/date cell. For a null cell `value` is ignored on read;
        we store 0 as the placeholder so the residual stays bitpackable."""
        if is_null:
            self._values.append(0)
        else:
            self._values.append(value)
        self._is_null.append(is_null)
        self._num_docs += 1

    def append_float_bits(mut self, bits: UInt64, is_null: Bool):
        """Append one float cell as its IEEE-754 bit pattern (UInt64). For a null
        cell `bits` is ignored on read; we store 0 as the placeholder."""
        if is_null:
            self._fbits.append(UInt64(0))
        else:
            self._fbits.append(bits)
        self._is_null.append(is_null)
        self._num_docs += 1

    def _any_null(self) -> Bool:
        for i in range(len(self._is_null)):
            if self._is_null[i]:
                return True
        return False

    def serialize(self, mut out: List[UInt8]) raises:
        """Emit the NUMERIC/DATE sub-region (or the FLOAT sub-region)
        into `out`.

        NUMERIC/DATE (FF_ENC_FOR_BITPACK):
          n_docs         : ULEB128
          min_value      : ULEB128 (zig-zag i64 frame-of-reference base)
          bits_per_value : u8      (_min_bit_width(max(value-min)))
          validity_flag  : u8      (0 = all-valid; 1 = bitmap follows)
          [validity bitmap : ceil(n/8) bytes]   present iff validity_flag == 1
          packed values  : ceil(n*bits/8) bytes; packed[i] = value_i - min_value

        FLOAT (FF_ENC_FLOAT_FULL):
          n_docs         : ULEB128
          float_width    : u8      (32 for FLOAT32, 64 for FLOAT64 — full width)
          validity_flag  : u8
          [validity bitmap : ceil(n/8) bytes]
          packed bits    : ceil(n*float_width/8) bytes; full-width LSB-first u64
        """
        var n = self._num_docs
        var any_null = self._any_null()

        if self._is_float:
            write_uleb128(n, out)
            var fw = 32 if self._storage_dtype == DType.float32 else 64
            out.append(UInt8(fw))
            if any_null:
                out.append(1)
                _append_validity_bitmap(self._is_null, out)
            else:
                out.append(0)
            # Full-width unsigned bitpack of the bit patterns.
            _pack_bits_lsb_first_u64(Span(self._fbits), n, fw, out)
            return

        # ---- NUMERIC / DATE: frame-of-reference ----
        # Compute min over the NON-NULL cells (null placeholders are 0; if every
        # cell is null we still pick a coherent min of 0).
        var have_value = False
        var min_v = 0
        for i in range(n):
            if not self._is_null[i]:
                var v = self._values[i]
                if not have_value or v < min_v:
                    min_v = v
                    have_value = True
        if not have_value:
            min_v = 0

        # Residuals (value - min) over the non-null cells; null placeholders -> 0
        # residual (they are masked on read by the validity bitmap).
        var residuals = List[Int]()
        var max_residual = 0
        for i in range(n):
            var r = 0
            if not self._is_null[i]:
                r = self._values[i] - min_v
            residuals.append(r)
            if r > max_residual:
                max_residual = r
        var bits = _min_bit_width(max_residual)

        write_uleb128(n, out)
        write_uleb128(_zigzag_encode(min_v), out)
        out.append(UInt8(bits))
        if any_null:
            out.append(1)
            _append_validity_bitmap(self._is_null, out)
        else:
            out.append(0)
        _pack_bits_lsb_first(Span(residuals), n, bits, out)


struct KeywordFastFieldBuilder(Copyable, Movable, Deinitable):
    """Dense per-doc keyword column accumulator + an in-build dict. All-POD List
    substrate. The dictionary is sorted-ascending at serialize so a
    query-time keyword equality + range are both served by the read accessor."""

    var _dict_terms: List[String]
    """Distinct terms (deduped at append; sorted at serialize)."""
    var _codes: List[Int]
    """Per-doc dict index (build-order; remapped to sorted order at serialize)."""
    var _is_null: List[Bool]
    var _num_docs: Int

    def __init__(out self):
        self._dict_terms = List[String]()
        self._codes = List[Int]()
        self._is_null = List[Bool]()
        self._num_docs = 0

    @always_inline
    def num_docs(self) -> Int:
        return self._num_docs

    def append(mut self, term: String, is_null: Bool):
        """Append one keyword cell. One-copy via the owned String. For a null cell
        the term is ignored; we store code 0 as the placeholder (masked on read)."""
        if is_null:
            self._codes.append(0)
            self._is_null.append(True)
            self._num_docs += 1
            return
        # Dedup: linear scan (per-split keyword cardinality is small).
        var found = -1
        for i in range(len(self._dict_terms)):
            if self._dict_terms[i] == term:
                found = i
                break
        if found < 0:
            found = len(self._dict_terms)
            self._dict_terms.append(term.copy())
        self._codes.append(found)
        self._is_null.append(False)
        self._num_docs += 1

    def _any_null(self) -> Bool:
        for i in range(len(self._is_null)):
            if self._is_null[i]:
                return True
        return False

    def serialize(self, mut out: List[UInt8]) raises:
        """Emit the KEYWORD sub-region into `out`:

          n_docs         : ULEB128
          dict_size      : ULEB128
          DICTIONARY (flat, sorted-ascending by bytes):
            for each entry: term_len ULEB128 ; term_bytes
          code_bits      : u8       (_min_bit_width(dict_size - 1))
          validity_flag  : u8       (0 = all-valid; 1 = bitmap follows)
          [validity bitmap : ceil(n/8) bytes]   present iff validity_flag == 1
          packed codes   : ceil(n*code_bits/8) bytes; LSB-first
        """
        var n = self._num_docs
        var dict_size = len(self._dict_terms)

        # ---- sort the dictionary ascending by bytes, build build->sorted remap.
        var order = List[Int]()
        for i in range(dict_size):
            order.append(i)
        # Insertion sort on `order` by self._dict_terms[order[i]] bytes
        # (small cardinality per split — O(d^2) is fine).
        for i in range(1, dict_size):
            var cur = order[i]
            var j = i - 1
            while j >= 0 and _str_gt(
                self._dict_terms[order[j]], self._dict_terms[cur]
            ):
                order[j + 1] = order[j]
                j -= 1
            order[j + 1] = cur
        # build->sorted: build_to_sorted[build_idx] = sorted position.
        var build_to_sorted = List[Int]()
        for _ in range(dict_size):
            build_to_sorted.append(0)
        for sorted_pos in range(dict_size):
            build_to_sorted[order[sorted_pos]] = sorted_pos

        write_uleb128(n, out)
        write_uleb128(dict_size, out)
        # Dictionary in sorted order.
        for sorted_pos in range(dict_size):
            ref term = self._dict_terms[order[sorted_pos]]
            var tb = term.as_bytes()
            write_uleb128(len(tb), out)
            for k in range(len(tb)):
                out.append(tb[k])

        var code_bits = _min_bit_width(dict_size - 1) if dict_size > 0 else 0
        out.append(UInt8(code_bits))
        var any_null = self._any_null()
        if any_null:
            out.append(1)
            _append_validity_bitmap(self._is_null, out)
        else:
            out.append(0)
        # Remap each per-doc build code to its sorted position, then bitpack.
        var sorted_codes = List[Int]()
        for i in range(n):
            if self._is_null[i] or dict_size == 0:
                sorted_codes.append(0)
            else:
                sorted_codes.append(build_to_sorted[self._codes[i]])
        _pack_bits_lsb_first(Span(sorted_codes), n, code_bits, out)


@always_inline
def _str_gt(a: String, b: String) -> Bool:
    """Lexicographic byte-wise a > b."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var la = len(ab)
    var lb = len(bb)
    var m = la if la < lb else lb
    for i in range(m):
        if ab[i] != bb[i]:
            return ab[i] > bb[i]
    return la > lb


# =============================================================================
# serialize_fastfields_region: assemble the "THFF" region (two-pass dir).
# =============================================================================


def serialize_fastfields_region(
    specs: List[FastFieldSpec],
    num_builders: List[NumericFastFieldBuilder],
    kw_builders: List[KeywordFastFieldBuilder],
    fieldnorm: NumericFastFieldBuilder,
) raises -> List[UInt8]:
    """Build the "THFF" fast-fields region bytes. PURE — no S3.

    The sub-directory carries REL sub-offsets, so we serialize each sub-region
    into a scratch buffer FIRST (computing its length), THEN lay the header +
    sub-directory + the concatenated sub-regions, patching the sub-offsets once
    we know the directory size (same two-pass discipline as serialize_split).

    Field order in the region: every spec (in `specs` order, numeric/keyword by
    field_class) THEN the "__fieldnorm__" numeric field LAST. If there are
    NO fast-field columns AND the fieldnorm has 0 docs, returns an EMPTY region
    (the caller writes fastfields_len == 0 — a split without fast fields).
    """
    var num_idx = 0
    var kw_idx = 0

    # ---- Pass 1: serialize each sub-region into its own scratch buffer. ----
    var names = List[String]()
    var classes = List[UInt8]()
    var atypes = List[UInt8]()
    var encodings = List[UInt8]()
    var sub_bytes = List[List[UInt8]]()

    for s in range(len(specs)):
        ref spec = specs[s]
        var buf = List[UInt8]()
        var enc = FF_ENC_FOR_BITPACK
        if spec.field_class == FIELD_CLASS_KEYWORD:
            kw_builders[kw_idx].serialize(buf)
            kw_idx += 1
            enc = FF_ENC_KEYWORD_DICT
        else:
            # NUMERIC or DATE -> numeric builder.
            ref nb = num_builders[num_idx]
            nb.serialize(buf)
            num_idx += 1
            enc = FF_ENC_FLOAT_FULL if nb.is_float() else FF_ENC_FOR_BITPACK
        names.append(spec.name.copy())
        classes.append(spec.field_class)
        atypes.append(spec.arrow_type_id)
        encodings.append(enc)
        sub_bytes.append(buf^)

    # ---- the fieldnorm field LAST (always numeric, FF_ENC_FOR_BITPACK). ----
    var fn_buf = List[UInt8]()
    fieldnorm.serialize(fn_buf)
    names.append(FIELDNORM_NAME)
    classes.append(FIELD_CLASS_NUMERIC)
    atypes.append(ArrowType.INT64.type_id)
    encodings.append(FF_ENC_FOR_BITPACK)
    sub_bytes.append(fn_buf^)

    var num_fields = len(names)
    # Empty region only when there is genuinely nothing (no specs AND no
    # fieldnorm docs). The fieldnorm always exists once any doc is indexed; an
    # all-empty split (0 docs, 0 specs) -> the fieldnorm sub-region is itself a
    # valid 0-doc numeric region, but to honor the no-fast-fields "absent" contract
    # we treat 0 specs + 0 fieldnorm docs as an empty region.
    if len(specs) == 0 and fieldnorm.num_docs() == 0:
        return List[UInt8]()

    # ---- Pass 2: compute the sub-directory size, then lay everything down. ----
    # First emit the sub-directory with PLACEHOLDER sub-offsets so we learn its
    # byte length, then re-emit with the real region-RELATIVE offsets.
    #
    # The region layout is:
    #   magic(4) + version(1) + num_fields ULEB128 + SUB-DIR + SUB-REGIONS
    # sub_offset is RELATIVE to the region start.

    var lens = List[Int]()
    for f in range(num_fields):
        lens.append(len(sub_bytes[f]))

    # First pass: provisional offsets (all 0) to measure the directory length.
    var provisional = List[Int]()
    for _ in range(num_fields):
        provisional.append(0)
    var sizing = List[UInt8]()
    _emit_ff_directory(
        names, classes, atypes, encodings, provisional, lens, sizing
    )
    # The directory's encoded length CAN change if real offsets need more ULEB
    # bytes than the provisional 0s. Iterate to a fixpoint (offsets monotonically
    # grow, so this converges in a couple of passes).
    var header_len = len(sizing)
    var real_offsets = List[Int]()
    for _ in range(num_fields):
        real_offsets.append(0)
    while True:
        var acc = header_len
        for f in range(num_fields):
            real_offsets[f] = acc
            acc += lens[f]
        var probe = List[UInt8]()
        _emit_ff_directory(
            names, classes, atypes, encodings, real_offsets, lens, probe
        )
        if len(probe) == header_len:
            break
        header_len = len(probe)

    # ---- Final emit: directory (real offsets) + sub-regions contiguously. ----
    var out = List[UInt8]()
    _emit_ff_directory(
        names, classes, atypes, encodings, real_offsets, lens, out
    )
    for f in range(num_fields):
        ref sb = sub_bytes[f]
        for k in range(len(sb)):
            out.append(sb[k])
    return out^


def _emit_ff_directory(
    names: List[String],
    classes: List[UInt8],
    atypes: List[UInt8],
    encodings: List[UInt8],
    offsets: List[Int],
    lens: List[Int],
    mut dst: List[UInt8],
) raises:
    """Emit the THFF header + sub-directory into `dst`. Module-level (NOT a
    captured nested fn — Mojo 1.0.0b1 nested-fn capture of outer vars is the
    hazard). All inputs are parallel-indexed by field position."""
    var num_fields = len(names)
    for c in FF_MAGIC().as_bytes():
        dst.append(c)
    dst.append(FF_VERSION)
    write_uleb128(num_fields, dst)
    for f in range(num_fields):
        ref nm = names[f]
        var nb_bytes = nm.as_bytes()
        write_uleb128(len(nb_bytes), dst)
        for k in range(len(nb_bytes)):
            dst.append(nb_bytes[k])
        dst.append(classes[f])
        dst.append(atypes[f])
        dst.append(encodings[f])
        write_uleb128(offsets[f], dst)
        write_uleb128(lens[f], dst)


@always_inline
def FF_MAGIC() -> String:
    return "THFF"


# =============================================================================
# FastFieldEntry + FastFieldReader (the directory-parsing accessor).
# =============================================================================


@fieldwise_init
struct FastFieldEntry(Copyable, Movable, Deinitable):
    """One parsed sub-directory entry. Trivial POD. `sub_offset` is
    REGION-RELATIVE — it indexes directly into the region Span returned by
    SplitView.fastfields_region() (which already starts at the region origin)."""

    var name: String
    var field_class: UInt8
    var arrow_type_id: UInt8
    var encoding: UInt8
    var sub_offset: Int
    """REGION-RELATIVE offset (index into the fastfields_region() span)."""
    var sub_len: Int


struct FastFieldReader(Movable, Deinitable):
    """Parses the "THFF" sub-directory at construction; serves O(1) per-doc reads
    + whole-column materialization over an immutable SplitView. Movable-only;
    holds NO Span field (Spans are re-derived per call from the borrowed view) so
    it does not pin a borrow — matching SearchCore in source.mojo. N-worker
    safe (read-only over the immutable split).

    Fail-loud bounds-checked decode (the split is attacker-influenced at
    query time). Every decode validates sub_offset+len <= region, the bitpack run
    length, the dict code < dict_size, and the slot in [0, doc_count) BEFORE any
    slice."""

    var _entries: List[FastFieldEntry]
    """The parsed directory (POD list)."""
    var _min_doc_id: Int
    var _doc_count: Int

    def __init__(out self, view: SplitView) raises:
        """Parse the THFF header + sub-directory from view.fastfields_region().
        Fail-loud on bad magic / version / out-of-bounds sub-offset. If the
        region is absent (has_fastfields() False), _entries is empty (every
        lookup raises 'no fast-fields')."""
        self._entries = List[FastFieldEntry]()
        self._min_doc_id = view.min_doc_id()
        self._doc_count = view.doc_count()

        if not view.has_fastfields():
            return

        var region = view.fastfields_region()
        var rlen = len(region)
        if rlen < FF_MAGIC_LEN + 1:
            raise Error("FastFieldReader: region too short for header (corrupt)")
        var magic = FF_MAGIC().as_bytes()
        for i in range(FF_MAGIC_LEN):
            if region[i] != magic[i]:
                raise Error("FastFieldReader: bad region magic (expected 'THFF')")
        if region[FF_MAGIC_LEN] != FF_VERSION:
            raise Error(
                "FastFieldReader: unsupported region version "
                + String(Int(region[FF_MAGIC_LEN]))
            )
        var pos = FF_MAGIC_LEN + 1
        var nf_t = _read_uleb128_span(region, pos, rlen)
        var num_fields = nf_t[0]
        pos = nf_t[1]
        if num_fields < 0 or num_fields > rlen:
            raise Error("FastFieldReader: implausible num_fields (corrupt)")

        for _ in range(num_fields):
            # name_len + name_bytes
            var nl_t = _read_uleb128_span(region, pos, rlen)
            var name_len = nl_t[0]
            pos = nl_t[1]
            if name_len < 0 or name_len > rlen - pos:  # no wrapping sum
                raise Error("FastFieldReader: field name out of bounds (corrupt)")
            var name_buf = List[UInt8](capacity=name_len)
            for k in range(name_len):
                name_buf.append(region[pos + k])
            pos += name_len
            # SAFETY: the name bytes were written from a String by the builder;
            # bounds were checked above, so corrupt bytes cannot read out of range.
            var name = String(StringSlice(unsafe_from_utf8=Span(name_buf)))
            # field_class + arrow_type_id + encoding (3 u8)
            if pos + 3 > rlen:
                raise Error("FastFieldReader: directory entry truncated (corrupt)")
            var field_class = region[pos]
            var arrow_type_id = region[pos + 1]
            var encoding = region[pos + 2]
            pos += 3
            # sub_offset (REL) + sub_len ULEB128
            var so_t = _read_uleb128_span(region, pos, rlen)
            var rel_sub_off = so_t[0]
            pos = so_t[1]
            var sl_t = _read_uleb128_span(region, pos, rlen)
            var sub_len = sl_t[0]
            pos = sl_t[1]
            # A difference of non-negatives, not offset + len: the sum can wrap.
            if rel_sub_off < 0 or sub_len < 0 or sub_len > rlen - rel_sub_off:
                raise Error(
                    "FastFieldReader: sub-region [" + String(rel_sub_off) + ", "
                    + String(rel_sub_off + sub_len) + ") out of region (corrupt)"
                )
            self._entries.append(
                FastFieldEntry(
                    name=name^,
                    field_class=field_class,
                    arrow_type_id=arrow_type_id,
                    encoding=encoding,
                    sub_offset=rel_sub_off,  # REGION-RELATIVE (index into region span)
                    sub_len=sub_len,
                )
            )

    @always_inline
    def num_fields(self) -> Int:
        return len(self._entries)

    def entry_meta_at(self, i: Int) raises -> Tuple[String, UInt8, UInt8]:
        """Public accessor over the parsed directory: the i-th
        entry's (name, field_class, encoding). `_entries` is private; the
        gate builds a `_FastFieldMeta` cache by walking `num_fields()` over this
        accessor (so the gate never re-parses the region per conjunct). Raises if
        `i` is out of range (fail-loud)."""
        if i < 0 or i >= len(self._entries):
            raise Error(
                "FastFieldReader.entry_meta_at: index " + String(i)
                + " out of range [0, " + String(len(self._entries)) + ")"
            )
        ref e = self._entries[i]
        return (e.name.copy(), e.field_class, e.encoding)

    def has_field(self, name: String) -> Bool:
        for i in range(len(self._entries)):
            if self._entries[i].name == name:
                return True
        return False

    def _entry_index(self, name: String) raises -> Int:
        for i in range(len(self._entries)):
            if self._entries[i].name == name:
                return i
        raise Error(
            "FastFieldReader: no fast-field named '" + name + "' in this split"
        )

    def field_class_of(self, name: String) raises -> UInt8:
        return self._entries[self._entry_index(name)].field_class

    @always_inline
    def _slot_for(self, doc_id: Int) raises -> Int:
        var slot = doc_id - self._min_doc_id
        if slot < 0 or slot >= self._doc_count:
            raise Error(
                "FastFieldReader: doc_id " + String(doc_id)
                + " out of range [" + String(self._min_doc_id) + ", "
                + String(self._min_doc_id + self._doc_count) + ")"
            )
        return slot

    # ---- SCALAR point-lookup (filter predicate / sort key) ----

    def fast_field_i64(
        self, view: SplitView, name: String, doc_id: Int
    ) raises -> Optional[Int64]:
        """O(1) numeric/date read at slot = doc_id - min_doc_id. Returns None for
        a null cell. RAISES if the field is absent, is a keyword field, is a float
        field, or doc_id is out of range. Decodes ONE bitpack window + adds the
        zig-zag min."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        if e.field_class == FIELD_CLASS_KEYWORD:
            raise Error(
                "FastFieldReader.fast_field_i64: '" + name + "' is a keyword field"
            )
        if e.encoding == FF_ENC_FLOAT_FULL:
            raise Error(
                "FastFieldReader.fast_field_i64: '" + name
                + "' is a float field (use fast_field_f64)"
            )
        var slot = self._slot_for(doc_id)
        var region = view.fastfields_region()
        return self._decode_numeric_slot(region, e, slot)

    def fast_field_f64(
        self, view: SplitView, name: String, doc_id: Int
    ) raises -> Optional[Float64]:
        """O(1) float read (inverse bitcast of the stored bit pattern).
        Returns None for a null cell. RAISES if the field is absent / not a float
        field / doc_id out of range."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        if e.encoding != FF_ENC_FLOAT_FULL:
            raise Error(
                "FastFieldReader.fast_field_f64: '" + name + "' is not a float field"
            )
        var slot = self._slot_for(doc_id)
        var region = view.fastfields_region()
        return self._decode_float_slot(region, e, slot)

    def fast_field_keyword(
        self, view: SplitView, name: String, doc_id: Int
    ) raises -> Optional[String]:
        """O(1) keyword read: unpack the dict code at the slot, resolve the
        dictionary entry. Returns None for a null cell. RAISES if the field is
        absent / not a keyword field / doc_id out of range / code >= dict_size."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        if e.field_class != FIELD_CLASS_KEYWORD:
            raise Error(
                "FastFieldReader.fast_field_keyword: '" + name
                + "' is not a keyword field"
            )
        var slot = self._slot_for(doc_id)
        var region = view.fastfields_region()
        return self._decode_keyword_slot(region, e, slot)

    # ---- PRE-RESOLVED per-field handles (the per-query header HOIST) ----
    #
    # The scalar accessors above (fast_field_*) re-parse the sub-region header on
    # EVERY call: fast_field_keyword in particular runs _decode_keyword_header,
    # which ALLOCATES a `term_bounds: List[Int]` of size 2*dict_size and walks the
    # whole flat dictionary, PER DOC. Over a 10k-matched-set terms-agg that per-doc
    # alloc+walk takes a large share of the query's time.
    #
    # The resolvers below parse the header ONCE (when the caller resolves a field
    # for the query lifetime — per conjunct / per agg-field / per sort-key) and
    # then serve each matched doc in O(1) via a SINGLE bitpack-window unpack — no
    # per-doc alloc, no per-doc dict-walk. They own their parsed POD descriptor
    # (the keyword resolver owns the term_bounds List[Int]); they hold NO Span
    # field (the region Span is re-derived per call from the borrowed `view`,
    # the BatchView idiom, exactly like FieldnormResolver). Reads
    # are byte-identical to the corresponding fast_field_* accessor.

    def keyword_resolver(
        self, view: SplitView, name: String
    ) raises -> KeywordFastFieldResolver:
        """Resolve the keyword sub-region header for `name` ONCE (parse the dict
        bounds + the packed-codes descriptor) and return a resolver that serves
        per-doc keyword reads in O(1) each (NO per-doc List[Int] alloc, NO per-doc
        dict-walk). RAISES if the field is absent / not a keyword field."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        if e.field_class != FIELD_CLASS_KEYWORD:
            raise Error(
                "FastFieldReader.keyword_resolver: '" + name
                + "' is not a keyword field"
            )
        var region = view.fastfields_region()
        var h = self._decode_keyword_header(region, e)
        return KeywordFastFieldResolver(
            n_docs=h[0],
            dict_size=h[1],
            term_bounds=h[2].copy(),
            code_bits=h[3],
            validity_off=h[4],
            has_validity=h[5],
            packed_off=h[6],
            min_doc_id=self._min_doc_id,
            doc_count=self._doc_count,
        )

    def numeric_resolver(
        self, view: SplitView, name: String
    ) raises -> NumericFastFieldResolver:
        """Resolve the numeric/date sub-region header for `name` ONCE and return a
        resolver that serves per-doc i64 reads in O(1) (unpack one signed window +
        add the frame-of-reference min). RAISES if the field is absent / is a
        keyword field / is a float field."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        if e.field_class == FIELD_CLASS_KEYWORD:
            raise Error(
                "FastFieldReader.numeric_resolver: '" + name
                + "' is a keyword field"
            )
        if e.encoding == FF_ENC_FLOAT_FULL:
            raise Error(
                "FastFieldReader.numeric_resolver: '" + name
                + "' is a float field (use float_resolver)"
            )
        var region = view.fastfields_region()
        var h = self._decode_numeric_header(region, e)
        return NumericFastFieldResolver(
            n_docs=h[0],
            min_value=h[1],
            bits=h[2],
            validity_off=h[3],
            has_validity=h[4],
            packed_off=h[5],
            min_doc_id=self._min_doc_id,
            doc_count=self._doc_count,
        )

    def float_resolver(
        self, view: SplitView, name: String
    ) raises -> FloatFastFieldResolver:
        """Resolve the float sub-region header for `name` ONCE and return a
        resolver that serves per-doc f64 reads in O(1) (unpack one unsigned
        bit-pattern window + inverse bitcast). RAISES if the field is absent / is
        not a float field."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        if e.encoding != FF_ENC_FLOAT_FULL:
            raise Error(
                "FastFieldReader.float_resolver: '" + name
                + "' is not a float field"
            )
        # Parse the float header (n_docs, fw, validity, packed_off) ONCE.
        var region = view.fastfields_region()
        var off = e.sub_offset
        var end = e.sub_offset + e.sub_len
        if off < 0 or end > len(region):
            raise Error("FastFieldReader.float_resolver: float sub-region OOB")
        var n_t = _read_uleb128_span(region, off, end)
        var n_docs = n_t[0]
        off = n_t[1]
        if off >= end:
            raise Error("FastFieldReader.float_resolver: header truncated (width)")
        var fw = Int(region[off])
        off += 1
        if off >= end:
            raise Error(
                "FastFieldReader.float_resolver: header truncated (validity_flag)"
            )
        var vflag = Int(region[off])
        off += 1
        var has_validity = vflag == 1
        var validity_off = off
        if has_validity:
            var vbytes = (n_docs + 7) >> 3
            if off + vbytes > end:
                raise Error(
                    "FastFieldReader.float_resolver: validity bitmap OOB"
                )
            off += vbytes
        return FloatFastFieldResolver(
            n_docs=n_docs,
            float_width=fw,
            validity_off=validity_off,
            has_validity=has_validity,
            packed_off=off,
            min_doc_id=self._min_doc_id,
            doc_count=self._doc_count,
        )

    # ---- decode helpers (fail-loud; re-derive Span from the borrowed view) ----

    def _decode_numeric_header(
        self, region: Span[UInt8, _], e: FastFieldEntry
    ) raises -> Tuple[Int, Int, Int, Int, Bool, Int]:
        """Parse a NUMERIC/DATE sub-region header. Returns
        (n_docs, min_value, bits, validity_off, has_validity, packed_off).
        validity_off is the absolute offset of the bitmap (valid only when
        has_validity)."""
        var off = e.sub_offset
        var end = e.sub_offset + e.sub_len
        if off < 0 or end > len(region):
            raise Error("FastFieldReader: numeric sub-region out of bounds")
        var n_t = _read_uleb128_span(region, off, end)
        var n_docs = n_t[0]
        off = n_t[1]
        var mv_t = _read_uleb128_span(region, off, end)
        var min_value = _zigzag_decode(mv_t[0])
        off = mv_t[1]
        if off >= end:
            raise Error("FastFieldReader: numeric header truncated (bits)")
        var bits = Int(region[off])
        off += 1
        if off >= end:
            raise Error("FastFieldReader: numeric header truncated (validity_flag)")
        var vflag = Int(region[off])
        off += 1
        var has_validity = vflag == 1
        var validity_off = off
        if has_validity:
            var vbytes = (n_docs + 7) >> 3
            if off + vbytes > end:
                raise Error("FastFieldReader: validity bitmap out of bounds")
            off += vbytes
        return (n_docs, min_value, bits, validity_off, has_validity, off)

    def _decode_numeric_slot(
        self, region: Span[UInt8, _], e: FastFieldEntry, slot: Int
    ) raises -> Optional[Int64]:
        var h = self._decode_numeric_header(region, e)
        var n_docs = h[0]
        var min_value = h[1]
        var bits = h[2]
        var validity_off = h[3]
        var has_validity = h[4]
        var packed_off = h[5]
        if slot < 0 or slot >= n_docs:
            raise Error("FastFieldReader: slot out of numeric sub-region range")
        if has_validity and not _read_validity_bit(region, validity_off, slot):
            return Optional[Int64](None)
        # Decode exactly the single window at `slot`.
        var v = _unpack_one_signed(region, packed_off, slot, bits)
        return Optional[Int64](Int64(v + min_value))

    def _decode_float_slot(
        self, region: Span[UInt8, _], e: FastFieldEntry, slot: Int
    ) raises -> Optional[Float64]:
        var off = e.sub_offset
        var end = e.sub_offset + e.sub_len
        if off < 0 or end > len(region):
            raise Error("FastFieldReader: float sub-region out of bounds")
        var n_t = _read_uleb128_span(region, off, end)
        var n_docs = n_t[0]
        off = n_t[1]
        if off >= end:
            raise Error("FastFieldReader: float header truncated (width)")
        var fw = Int(region[off])
        off += 1
        if off >= end:
            raise Error("FastFieldReader: float header truncated (validity_flag)")
        var vflag = Int(region[off])
        off += 1
        var has_validity = vflag == 1
        var validity_off = off
        if has_validity:
            var vbytes = (n_docs + 7) >> 3
            if off + vbytes > end:
                raise Error("FastFieldReader: float validity bitmap out of bounds")
            off += vbytes
        if slot < 0 or slot >= n_docs:
            raise Error("FastFieldReader: slot out of float sub-region range")
        if has_validity and not _read_validity_bit(region, validity_off, slot):
            return Optional[Float64](None)
        var bits = _unpack_one_unsigned(region, off, slot, fw)
        if fw == 32:
            # SAFETY: value bitcast between same-width scalars; no memory is read.
            return Optional[Float64](
                Float64(bitcast[DType.float32](UInt32(bits & UInt64(0xFFFFFFFF))))
            )
        # SAFETY: value bitcast between same-width scalars; no memory is read.
        return Optional[Float64](bitcast[DType.float64](bits))

    def _decode_keyword_header(
        self, region: Span[UInt8, _], e: FastFieldEntry
    ) raises -> Tuple[Int, Int, List[Int], Int, Int, Bool, Int]:
        """Parse a KEYWORD sub-region header. Returns
        (n_docs, dict_size, dict_term_offsets(into region, dict_size+1),
         code_bits, validity_off, has_validity, packed_off)."""
        var off = e.sub_offset
        var end = e.sub_offset + e.sub_len
        if off < 0 or end > len(region):
            raise Error("FastFieldReader: keyword sub-region out of bounds")
        var n_t = _read_uleb128_span(region, off, end)
        var n_docs = n_t[0]
        off = n_t[1]
        var ds_t = _read_uleb128_span(region, off, end)
        var dict_size = ds_t[0]
        off = ds_t[1]
        if dict_size < 0:
            raise Error("FastFieldReader: negative dict_size (corrupt)")
        # Walk the flat dictionary, recording each term's byte slice as an
        # explicit (start, end) pair: term_bounds[2*i] = start of the i-th term's
        # BYTES (AFTER its ULEB128 len prefix), term_bounds[2*i+1] = end.
        var term_bounds = List[Int]()  # 2 * dict_size entries
        for _ in range(dict_size):
            var tl_t = _read_uleb128_span(region, off, end)
            var term_len = tl_t[0]
            off = tl_t[1]  # off now points at the term BYTES start
            if term_len < 0 or term_len > end - off:  # no wrapping sum
                raise Error("FastFieldReader: dict term out of bounds (corrupt)")
            term_bounds.append(off)  # start of term bytes
            off += term_len
            term_bounds.append(off)  # end of term bytes
        if off >= end:
            raise Error("FastFieldReader: keyword header truncated (code_bits)")
        var code_bits = Int(region[off])
        off += 1
        if off >= end:
            raise Error("FastFieldReader: keyword header truncated (validity_flag)")
        var vflag = Int(region[off])
        off += 1
        var has_validity = vflag == 1
        var validity_off = off
        if has_validity:
            var vbytes = (n_docs + 7) >> 3
            if off + vbytes > end:
                raise Error("FastFieldReader: keyword validity bitmap out of bounds")
            off += vbytes
        return (
            n_docs, dict_size, term_bounds^, code_bits, validity_off,
            has_validity, off,
        )

    def _decode_keyword_slot(
        self, region: Span[UInt8, _], e: FastFieldEntry, slot: Int
    ) raises -> Optional[String]:
        var h = self._decode_keyword_header(region, e)
        var n_docs = h[0]
        var dict_size = h[1]
        var term_bounds = h[2].copy()
        var code_bits = h[3]
        var validity_off = h[4]
        var has_validity = h[5]
        var packed_off = h[6]
        if slot < 0 or slot >= n_docs:
            raise Error("FastFieldReader: slot out of keyword sub-region range")
        if has_validity and not _read_validity_bit(region, validity_off, slot):
            return Optional[String](None)
        var code = _unpack_one_unsigned(region, packed_off, slot, code_bits)
        var icode = Int(code)
        if icode < 0 or icode >= dict_size:
            raise Error(
                "FastFieldReader: dict code " + String(icode)
                + " >= dict_size " + String(dict_size) + " (corrupt)"
            )
        var ts = term_bounds[2 * icode]
        var te = term_bounds[2 * icode + 1]
        var buf = List[UInt8](capacity=te - ts)
        for k in range(ts, te):
            buf.append(region[k])
        # SAFETY: dictionary terms were written from Strings by the builder;
        # their bounds were checked when the dictionary was parsed.
        return Optional[String](String(StringSlice(unsafe_from_utf8=Span(buf))))

    # ---- WHOLE-COLUMN materializer (aggregations / vectorized filters) ----

    def fast_field_column(
        self, view: SplitView, name: String
    ) raises -> Column[HeapRegion]:
        """Decode the whole dense column into a core-package Arrow Column (with
        validity). Numeric/date -> Column.from_primitive_with_arrow_type[dtype]
        (DATE32 survives as DATE32); float -> from_primitive_with_arrow_type
        over the reconstructed float; keyword -> from_int64_dict_indices (a
        DICTIONARY column the agg sees natively)."""
        var ei = self._entry_index(name)
        ref e = self._entries[ei]
        var region = view.fastfields_region()
        if e.field_class == FIELD_CLASS_KEYWORD:
            return self._materialize_keyword(region, e)
        if e.encoding == FF_ENC_FLOAT_FULL:
            return self._materialize_float(region, e)
        return self._materialize_numeric(region, e)

    # ---- BM25 b>0 doc-length normalization (J3 fieldnorm consumer) ----

    def fieldnorms(
        self, view: SplitView
    ) raises -> Tuple[List[Int], Float64]:
        """RESOLVE-ONCE decode of the "__fieldnorm__" numeric fast-field for the
        BM25 b>0 doc-length-normalization path. Returns
        `(doc_lengths_by_slot, avgdl)` where:

          * `doc_lengths_by_slot[slot]` == the per-doc token count `dl` (the RAW
            INT64 the indexer wrote (IndexCore in sink.mojo) — NOT a quantized Lucene
            SmallFloat norm; J3 stores the raw `AnalyzedField.len()`), indexed by
            `slot = doc_id - min_doc_id`. Length == doc_count.
          * `avgdl` == the average doc length over the split = sum(dl) / doc_count
            (PER-SHARD stats — composes with multi-split merge, each split scores
            with its OWN avgdl, matching ES per-shard BM25). 0.0 iff doc_count==0.

        This is the RESOLVE-ONCE primitive the scoring loop calls a SINGLE time
        BEFORE the posting walk: ONE numeric-column decode + ONE sum, then the
        loop indexes the returned List[Int] O(1) per posting (no per-posting
        header re-parse, no raise-trap). It decodes the dense bitpacked window in
        one pass (reusing the whole-column unpack path), mirroring how
        sort / aggregations resolve fast-field reads once.

        RAISES if the split has no fast-fields region or no "__fieldnorm__" field
        (a split built without the J3 fieldnorm — the caller degrades to b=0 by
        catching this and leaving avgdl unused). The fieldnorm is always written
        non-null + FF_ENC_FOR_BITPACK numeric, so this never hits the float /
        keyword / validity-null arms — but we still decode defensively."""
        var ei = self._entry_index(FIELDNORM_NAME)
        ref e = self._entries[ei]
        if e.field_class == FIELD_CLASS_KEYWORD or e.encoding == FF_ENC_FLOAT_FULL:
            raise Error(
                "FastFieldReader.fieldnorms: '__fieldnorm__' is not a numeric"
                " bitpacked field (corrupt split)"
            )
        var region = view.fastfields_region()
        var h = self._decode_numeric_header(region, e)
        var n_docs = h[0]
        var min_value = h[1]
        var bits = h[2]
        var validity_off = h[3]
        var has_validity = h[4]
        var packed_off = h[5]
        # Decode every slot once (the dense bitpacked window).
        var raw = List[Int]()
        _unpack_bits_lsb_first(region, packed_off, n_docs, bits, raw)
        var dls = List[Int](capacity=n_docs)
        var total = 0
        for slot in range(n_docs):
            # The fieldnorm is written non-null; a defensively-null cell (or a
            # negative decode) degrades to dl=0 (contributes nothing to the sum,
            # and the b>0 ratio sees dl/avgdl=0 -> norm=1-b, never div-by-zero).
            var dl = 0
            if not has_validity or _read_validity_bit(region, validity_off, slot):
                dl = raw[slot] + min_value
                if dl < 0:
                    dl = 0
            dls.append(dl)
            total += dl
        var avgdl = 0.0
        if self._doc_count > 0:
            avgdl = Float64(total) / Float64(self._doc_count)
        return (dls^, avgdl)

    def fieldnorm_resolver(self) raises -> FieldnormResolver:
        """Resolve the "__fieldnorm__" numeric sub-region header ONCE (O(1) — a
        few ULEB128 reads + a u8, NO whole-column decode) and return a
        FieldnormResolver that serves per-doc `dl` reads in O(1) each. This is the
        O(matched)-cost replacement for `fieldnorms()` (which decodes + sums the
        WHOLE column → O(doc_count)): when the split footer carries the per-split
        total token count, the caller reads `avgdl` from the footer in O(1) and
        the per-doc `dl` ONLY for matched docs via this resolver.

        RAISES if the split has no fast-fields region or no "__fieldnorm__" field
        (a fieldnorm-less split — the caller degrades to b=0). The resolver
        captures only POD scalars (sub-region offsets, bit width, min, validity
        offset) — trivial POD, no Span field."""
        var ei = self._entry_index(FIELDNORM_NAME)
        ref e = self._entries[ei]
        if (
            e.field_class == FIELD_CLASS_KEYWORD
            or e.encoding == FF_ENC_FLOAT_FULL
        ):
            raise Error(
                "FastFieldReader.fieldnorm_resolver: '__fieldnorm__' is not a"
                " numeric bitpacked field (corrupt split)"
            )
        return FieldnormResolver(
            entry=e.copy(),
            min_doc_id=self._min_doc_id,
            doc_count=self._doc_count,
        )

    def _materialize_numeric(
        self, region: Span[UInt8, _], e: FastFieldEntry
    ) raises -> Column[HeapRegion]:
        var h = self._decode_numeric_header(region, e)
        var n_docs = h[0]
        var min_value = h[1]
        var bits = h[2]
        var validity_off = h[3]
        var has_validity = h[4]
        var packed_off = h[5]
        # Decode all slots once.
        var raw = List[Int]()
        _unpack_bits_lsb_first(region, packed_off, n_docs, bits, raw)
        var dt = _storage_dtype_for_arrow_type_id(e.arrow_type_id)
        if dt == DType.int32:
            return _build_primitive_column[DType.int32](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.int64:
            return _build_primitive_column[DType.int64](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.int16:
            return _build_primitive_column[DType.int16](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.int8:
            return _build_primitive_column[DType.int8](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.uint64:
            return _build_primitive_column[DType.uint64](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.uint32:
            return _build_primitive_column[DType.uint32](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.uint16:
            return _build_primitive_column[DType.uint16](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        elif dt == DType.uint8:
            return _build_primitive_column[DType.uint8](
                raw, min_value, n_docs, has_validity, region, validity_off,
                ArrowType(e.arrow_type_id),
            )
        # J1 fail-loud: never fall through to a default reader on an unhandled
        # storage DType (that would corrupt the bit pattern).
        raise Error(
            "FastFieldReader._materialize_numeric: unhandled storage DType for"
            " arrow_type_id " + String(Int(e.arrow_type_id))
        )

    def _materialize_float(
        self, region: Span[UInt8, _], e: FastFieldEntry
    ) raises -> Column[HeapRegion]:
        # Reuse the per-slot float decode to fill a values list, then build the
        # primitive column with explicit nulls.
        var off = e.sub_offset
        var end = e.sub_offset + e.sub_len
        var n_t = _read_uleb128_span(region, off, end)
        var n_docs = n_t[0]
        off = n_t[1]
        var fw = Int(region[off])
        off += 1
        var vflag = Int(region[off])
        off += 1
        var has_validity = vflag == 1
        var validity_off = off
        if has_validity:
            off += (n_docs + 7) >> 3
        var packed_off = off
        var bits_list = List[UInt64]()
        _unpack_bits_lsb_first_u64(region, packed_off, n_docs, fw, bits_list)
        if fw == 32:
            var arr = _build_float_primitive[DType.float32](
                bits_list, n_docs, has_validity, region, validity_off, fw
            )
            return Column.from_primitive_with_arrow_type[DType.float32](
                arr^, ArrowType.FLOAT32
            )
        var arr64 = _build_float_primitive[DType.float64](
            bits_list, n_docs, has_validity, region, validity_off, fw
        )
        return Column.from_primitive_with_arrow_type[DType.float64](
            arr64^, ArrowType.FLOAT64
        )

    def _materialize_keyword(
        self, region: Span[UInt8, _], e: FastFieldEntry
    ) raises -> Column[HeapRegion]:
        var h = self._decode_keyword_header(region, e)
        var n_docs = h[0]
        var dict_size = h[1]
        var term_bounds = h[2].copy()
        var code_bits = h[3]
        var validity_off = h[4]
        var has_validity = h[5]
        var packed_off = h[6]
        # The dictionary values.
        var dict_values = List[String]()
        for d in range(dict_size):
            var ts = term_bounds[2 * d]
            var te = term_bounds[2 * d + 1]
            var buf = List[UInt8](capacity=te - ts)
            for k in range(ts, te):
                buf.append(region[k])
            # SAFETY: as above: builder-written String bytes, bounds checked.
            dict_values.append(String(StringSlice(unsafe_from_utf8=Span(buf))))
        # The per-doc codes -> Int64 indices.
        var codes = List[Int]()
        _unpack_bits_lsb_first(region, packed_off, n_docs, code_bits, codes)
        var indices = List[Int64]()
        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if has_validity:
            var bm = Bitmap.create(n_docs)
            for s in range(n_docs):
                if _read_validity_bit(region, validity_off, s):
                    bm.set(s)
                else:
                    null_count += 1
            validity = bm^
        for s in range(n_docs):
            var c = codes[s]
            # Null rows carry a placeholder code 0; from_int64_dict_indices still
            # validates the index, so clamp a null row to 0 (safe when dict_size>0;
            # for an all-null empty-dict column there are no rows to index).
            if has_validity and not _read_validity_bit(region, validity_off, s):
                indices.append(Int64(0))
            else:
                if c < 0 or c >= dict_size:
                    raise Error(
                        "FastFieldReader._materialize_keyword: code " + String(c)
                        + " >= dict_size " + String(dict_size)
                    )
                indices.append(Int64(c))
        return Column.from_int64_dict_indices(
            indices^, dict_values^, validity^, null_count
        )


# =============================================================================
# FieldnormResolver: O(1)-per-doc "__fieldnorm__" reader (the O(matched)
#       BM25 b>0 doc-length read — replaces the O(doc_count) column-sum when the
#       split footer carries the per-split total token count).
# =============================================================================


struct FieldnormResolver(Movable, Deinitable):
    """Reads ONE doc's "__fieldnorm__" `dl` (token count) in O(1), re-deriving
    the region Span per call from the borrowed `view` (the BatchView
    idiom — holds NO Span field). Built by FastFieldReader.fieldnorm_resolver(),
    which already resolved the "__fieldnorm__" directory entry; this struct
    captures only the POD sub-region descriptor + the slot base.

    The BM25 b>0 scorer reads `avgdl` from the split footer in O(1) and then
    calls `dl_at(view, doc_id)` ONLY for the matched docs (O(matched)) — so query
    latency scales with the match size, not the index size. (The legacy
    FastFieldReader.fieldnorms() path stays as the FALLBACK when the footer does
    NOT carry the total token count.)"""

    var _entry: FastFieldEntry
    """The parsed "__fieldnorm__" directory entry (POD; sub_offset is region-
    relative)."""
    var _min_doc_id: Int
    var _doc_count: Int

    def __init__(
        out self, var entry: FastFieldEntry, min_doc_id: Int, doc_count: Int
    ):
        self._entry = entry^
        self._min_doc_id = min_doc_id
        self._doc_count = doc_count

    def dl_at(self, view: SplitView, doc_id: Int) raises -> Int:
        """The per-doc token count `dl` at `doc_id` (slot = doc_id - min_doc_id),
        in O(1): re-derive the region Span, parse the small numeric header (a few
        ULEB128 reads — O(1), NOT a whole-column decode), then unpack the SINGLE
        bitpack window at the slot. A defensively-null cell (the fieldnorm is
        written non-null, but we decode defensively) or a negative decode -> 0
        (contributes nothing; the scorer's avgdl>0 guard keeps norm=1.0). RAISES
        if the slot is out of range (fail-loud)."""
        var slot = doc_id - self._min_doc_id
        if slot < 0 or slot >= self._doc_count:
            raise Error(
                "FieldnormResolver.dl_at: doc_id " + String(doc_id)
                + " out of range [" + String(self._min_doc_id) + ", "
                + String(self._min_doc_id + self._doc_count) + ")"
            )
        var region = view.fastfields_region()
        var h = _decode_numeric_header_standalone(region, self._entry)
        var n_docs = h[0]
        var min_value = h[1]
        var bits = h[2]
        var validity_off = h[3]
        var has_validity = h[4]
        var packed_off = h[5]
        if slot >= n_docs:
            raise Error(
                "FieldnormResolver.dl_at: slot out of fieldnorm sub-region range"
            )
        if has_validity and not _read_validity_bit(region, validity_off, slot):
            return 0
        var dl = _unpack_one_signed(region, packed_off, slot, bits) + min_value
        if dl < 0:
            dl = 0
        return dl

    def min_dl(self, view: SplitView) raises -> Int:
        """The column-global MINIMUM doc length (`dl`) over the whole fieldnorm
        column, in O(1): the numeric frame-of-reference base `min_value` IS the
        column min. Used by WAND Phase 1 to compute a CONSERVATIVE per-term
        max-impact bound WITHOUT a per-posting dl read: the per-term min_dl is
        always >= this column min, and f (the BM25 tf-saturation factor)
        DECREASES in dl, so f(max_tf, column_min_dl) >= f(max_tf, per_term_min_dl)
        >= the true per-doc max -> still a valid UPPER bound (just looser).
        Clamped to >= 0 (a negative min_value would be a corrupt header). A
        missing cell scores with norm=1.0 in the scorer, which is LESS favorable
        than the column-min norm, so it is already covered by this bound."""
        var region = view.fastfields_region()
        var h = _decode_numeric_header_standalone(region, self._entry)
        var mv = h[1]
        return mv if mv > 0 else 0


def _decode_numeric_header_standalone(
    region: Span[UInt8, _], e: FastFieldEntry
) raises -> Tuple[Int, Int, Int, Int, Bool, Int]:
    """Module-level twin of FastFieldReader._decode_numeric_header (the O(1)
    NUMERIC/DATE sub-region header parse), so FieldnormResolver can decode a
    single slot without a FastFieldReader handle. Returns
    (n_docs, min_value, bits, validity_off, has_validity, packed_off)."""
    var off = e.sub_offset
    var end = e.sub_offset + e.sub_len
    if off < 0 or end > len(region):
        raise Error("FieldnormResolver: numeric sub-region out of bounds")
    var n_t = _read_uleb128_span(region, off, end)
    var n_docs = n_t[0]
    off = n_t[1]
    var mv_t = _read_uleb128_span(region, off, end)
    var min_value = _zigzag_decode(mv_t[0])
    off = mv_t[1]
    if off >= end:
        raise Error("FieldnormResolver: numeric header truncated (bits)")
    var bits = Int(region[off])
    off += 1
    if off >= end:
        raise Error("FieldnormResolver: numeric header truncated (validity_flag)")
    var vflag = Int(region[off])
    off += 1
    var has_validity = vflag == 1
    var validity_off = off
    if has_validity:
        var vbytes = (n_docs + 7) >> 3
        if off + vbytes > end:
            raise Error("FieldnormResolver: validity bitmap out of bounds")
        off += vbytes
    return (n_docs, min_value, bits, validity_off, has_validity, off)


# =============================================================================
# Pre-resolved per-field handles (the per-query header HOIST). Each parses
#       its sub-region header ONCE (built by FastFieldReader.keyword_resolver /
#       numeric_resolver / float_resolver) and serves per-doc reads in O(1):
#       ZERO per-doc alloc, ZERO per-doc dict-walk. They own only POD scalars
#       (+ the keyword resolver's term_bounds List[Int]); they hold NO Span field
#       (the region Span is re-derived per call from the borrowed `view`, the
#       BatchView idiom). Each read is byte-identical to the
#       corresponding FastFieldReader.fast_field_* accessor.
# =============================================================================


struct KeywordFastFieldResolver(Copyable, Movable, Deinitable):
    """O(1)-per-doc keyword reader. Owns the parsed flat-dict `term_bounds`
    (2*dict_size region byte-offsets) so the per-doc path becomes: unpack ONE
    dict-code window + index `term_bounds` + slice the term bytes. No per-doc
    `List[Int]` alloc, no per-doc dict-walk (the per-query hoist).

    `_term_bounds` is a plain List[Int] FIELD on a Movable stack struct
    (never a byte-slab element) — trivial POD. Holds NO Span field; the
    region Span is re-derived per `keyword_at` call from the borrowed `view`."""

    var _n_docs: Int
    var _dict_size: Int
    var _term_bounds: List[Int]
    """2*dict_size REGION-RELATIVE byte offsets: [2*i]=term i start, [2*i+1]=end."""
    var _code_bits: Int
    var _validity_off: Int
    var _has_validity: Bool
    var _packed_off: Int
    var _min_doc_id: Int
    var _doc_count: Int

    def __init__(
        out self,
        n_docs: Int,
        dict_size: Int,
        var term_bounds: List[Int],
        code_bits: Int,
        validity_off: Int,
        has_validity: Bool,
        packed_off: Int,
        min_doc_id: Int,
        doc_count: Int,
    ):
        self._n_docs = n_docs
        self._dict_size = dict_size
        self._term_bounds = term_bounds^
        self._code_bits = code_bits
        self._validity_off = validity_off
        self._has_validity = has_validity
        self._packed_off = packed_off
        self._min_doc_id = min_doc_id
        self._doc_count = doc_count

    def keyword_at(
        self, view: SplitView, doc_id: Int
    ) raises -> Optional[String]:
        """The keyword cell at `doc_id` (slot = doc_id - min_doc_id) in O(1).
        Returns None for a null cell. Byte-identical to
        FastFieldReader.fast_field_keyword(view, name, doc_id). RAISES on an
        out-of-range slot or a corrupt dict code (fail-loud)."""
        var slot = doc_id - self._min_doc_id
        if slot < 0 or slot >= self._doc_count:
            raise Error(
                "KeywordFastFieldResolver.keyword_at: doc_id " + String(doc_id)
                + " out of range [" + String(self._min_doc_id) + ", "
                + String(self._min_doc_id + self._doc_count) + ")"
            )
        if slot >= self._n_docs:
            raise Error(
                "KeywordFastFieldResolver.keyword_at: slot out of keyword"
                " sub-region range"
            )
        var region = view.fastfields_region()
        if self._has_validity and not _read_validity_bit(
            region, self._validity_off, slot
        ):
            return Optional[String](None)
        var code = _unpack_one_unsigned(
            region, self._packed_off, slot, self._code_bits
        )
        var icode = Int(code)
        if icode < 0 or icode >= self._dict_size:
            raise Error(
                "KeywordFastFieldResolver: dict code " + String(icode)
                + " >= dict_size " + String(self._dict_size) + " (corrupt)"
            )
        var ts = self._term_bounds[2 * icode]
        var te = self._term_bounds[2 * icode + 1]
        var buf = List[UInt8](capacity=te - ts)
        for k in range(ts, te):
            buf.append(region[k])
        # SAFETY: dictionary terms were written from Strings by the builder;
        # their bounds were checked when the dictionary was parsed.
        return Optional[String](String(StringSlice(unsafe_from_utf8=Span(buf))))


struct NumericFastFieldResolver(Copyable, Movable, Deinitable):
    """O(1)-per-doc numeric/date (i64) reader. Owns the parsed POD header scalars;
    per-doc path: unpack ONE signed window + add the frame-of-reference min.
    Holds NO Span field (re-derived per call). Byte-identical to
    FastFieldReader.fast_field_i64."""

    var _n_docs: Int
    var _min_value: Int
    var _bits: Int
    var _validity_off: Int
    var _has_validity: Bool
    var _packed_off: Int
    var _min_doc_id: Int
    var _doc_count: Int

    def __init__(
        out self,
        n_docs: Int,
        min_value: Int,
        bits: Int,
        validity_off: Int,
        has_validity: Bool,
        packed_off: Int,
        min_doc_id: Int,
        doc_count: Int,
    ):
        self._n_docs = n_docs
        self._min_value = min_value
        self._bits = bits
        self._validity_off = validity_off
        self._has_validity = has_validity
        self._packed_off = packed_off
        self._min_doc_id = min_doc_id
        self._doc_count = doc_count

    def i64_at(
        self, view: SplitView, doc_id: Int
    ) raises -> Optional[Int64]:
        """The numeric/date cell at `doc_id` in O(1). Returns None for a null
        cell. Byte-identical to FastFieldReader.fast_field_i64."""
        var slot = doc_id - self._min_doc_id
        if slot < 0 or slot >= self._doc_count:
            raise Error(
                "NumericFastFieldResolver.i64_at: doc_id " + String(doc_id)
                + " out of range [" + String(self._min_doc_id) + ", "
                + String(self._min_doc_id + self._doc_count) + ")"
            )
        if slot >= self._n_docs:
            raise Error(
                "NumericFastFieldResolver.i64_at: slot out of numeric"
                " sub-region range"
            )
        var region = view.fastfields_region()
        if self._has_validity and not _read_validity_bit(
            region, self._validity_off, slot
        ):
            return Optional[Int64](None)
        var v = _unpack_one_signed(region, self._packed_off, slot, self._bits)
        return Optional[Int64](Int64(v + self._min_value))


struct FloatFastFieldResolver(Copyable, Movable, Deinitable):
    """O(1)-per-doc float (f64) reader. Owns the parsed POD header scalars;
    per-doc path: unpack ONE unsigned bit-pattern window + inverse bitcast.
    Holds NO Span field (re-derived per call). Byte-identical to
    FastFieldReader.fast_field_f64."""

    var _n_docs: Int
    var _float_width: Int
    var _validity_off: Int
    var _has_validity: Bool
    var _packed_off: Int
    var _min_doc_id: Int
    var _doc_count: Int

    def __init__(
        out self,
        n_docs: Int,
        float_width: Int,
        validity_off: Int,
        has_validity: Bool,
        packed_off: Int,
        min_doc_id: Int,
        doc_count: Int,
    ):
        self._n_docs = n_docs
        self._float_width = float_width
        self._validity_off = validity_off
        self._has_validity = has_validity
        self._packed_off = packed_off
        self._min_doc_id = min_doc_id
        self._doc_count = doc_count

    def f64_at(
        self, view: SplitView, doc_id: Int
    ) raises -> Optional[Float64]:
        """The float cell at `doc_id` in O(1). Returns None for a null cell.
        Byte-identical to FastFieldReader.fast_field_f64."""
        var slot = doc_id - self._min_doc_id
        if slot < 0 or slot >= self._doc_count:
            raise Error(
                "FloatFastFieldResolver.f64_at: doc_id " + String(doc_id)
                + " out of range [" + String(self._min_doc_id) + ", "
                + String(self._min_doc_id + self._doc_count) + ")"
            )
        if slot >= self._n_docs:
            raise Error(
                "FloatFastFieldResolver.f64_at: slot out of float sub-region range"
            )
        var region = view.fastfields_region()
        if self._has_validity and not _read_validity_bit(
            region, self._validity_off, slot
        ):
            return Optional[Float64](None)
        var bits = _unpack_one_unsigned(
            region, self._packed_off, slot, self._float_width
        )
        if self._float_width == 32:
            # SAFETY: value bitcast between same-width scalars; no memory is read.
            return Optional[Float64](
                Float64(bitcast[DType.float32](UInt32(bits & UInt64(0xFFFFFFFF))))
            )
        # SAFETY: value bitcast between same-width scalars; no memory is read.
        return Optional[Float64](bitcast[DType.float64](bits))


# =============================================================================
# single-window unpack + primitive-column builders (decode helpers).
# =============================================================================


def _unpack_one_signed(
    region: Span[UInt8, _], packed_off: Int, slot: Int, bits: Int
) raises -> Int:
    """Decode exactly ONE bits-wide LSB-first window at logical index `slot`
    (used by the O(1) scalar path; signed/non-negative residual)."""
    if bits == 0:
        return 0
    var bit_pos = slot * bits
    var v = UInt64(0)
    for b in range(bits):
        var abs_bit = bit_pos + b
        var byte_idx = packed_off + (abs_bit >> 3)
        if byte_idx < 0 or byte_idx >= len(region):
            raise Error("FastFieldReader: bitpack window out of bounds (corrupt)")
        var bit_in_byte = abs_bit & 7
        var bit = (region[byte_idx] >> UInt8(bit_in_byte)) & UInt8(1)
        if bit != UInt8(0):
            v = v | (UInt64(1) << UInt64(b))
    return Int(v)


def _unpack_one_unsigned(
    region: Span[UInt8, _], packed_off: Int, slot: Int, bits: Int
) raises -> UInt64:
    """Decode exactly ONE bits-wide LSB-first window at logical index `slot`,
    UNSIGNED (used by the float + keyword-code O(1) scalar paths)."""
    if bits == 0:
        return UInt64(0)
    var bit_pos = slot * bits
    var v = UInt64(0)
    for b in range(bits):
        var abs_bit = bit_pos + b
        var byte_idx = packed_off + (abs_bit >> 3)
        if byte_idx < 0 or byte_idx >= len(region):
            raise Error("FastFieldReader: bitpack window out of bounds (corrupt)")
        var bit_in_byte = abs_bit & 7
        var bit = (region[byte_idx] >> UInt8(bit_in_byte)) & UInt8(1)
        if bit != UInt8(0):
            v = v | (UInt64(1) << UInt64(b))
    return v


def _build_primitive_column[
    dtype: DType
](
    raw: List[Int],
    min_value: Int,
    n_docs: Int,
    has_validity: Bool,
    region: Span[UInt8, _],
    validity_off: Int,
    arrow_type: ArrowType,
) raises -> Column[HeapRegion]:
    """Build a non-float numeric/date primitive Column from the decoded residuals.
    Stamps `arrow_type` so DATE32 survives as DATE32."""
    comptime elem_size = size_of[Scalar[dtype]]()
    var data_buf = OwnedAlignedBuffer(max(n_docs * elem_size, 1))
    for i in range(n_docs):
        var v = raw[i] + min_value
        data_buf.set_typed[Scalar[dtype]](i, Scalar[dtype](v))
    data_buf.set_length(Int64(n_docs * elem_size))
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if has_validity:
        var bm = Bitmap.create(n_docs)
        for s in range(n_docs):
            if _read_validity_bit(region, validity_off, s):
                bm.set(s)
            else:
                null_count += 1
        validity = bm^
    var arr = PrimitiveArray[dtype](data_buf^, n_docs, validity^, null_count, 0)
    return Column.from_primitive_with_arrow_type[dtype](arr^, arrow_type)


def _build_float_primitive[
    dtype: DType
](
    bits_list: List[UInt64],
    n_docs: Int,
    has_validity: Bool,
    region: Span[UInt8, _],
    validity_off: Int,
    fw: Int,
) raises -> PrimitiveArray[dtype]:
    """Build a float PrimitiveArray from the decoded IEEE-754 bit patterns."""
    comptime elem_size = size_of[Scalar[dtype]]()
    var data_buf = OwnedAlignedBuffer(max(n_docs * elem_size, 1))
    for i in range(n_docs):
        var b = bits_list[i]
        comptime if dtype == DType.float32:
            # SAFETY: value bitcast between same-width scalars; no memory is read.
            data_buf.set_typed[Scalar[dtype]](
                i, Scalar[dtype](bitcast[DType.float32](UInt32(b & UInt64(0xFFFFFFFF))))
            )
        else:
            data_buf.set_typed[Scalar[dtype]](
                # SAFETY: value bitcast between same-width scalars; no memory is read.
                i, Scalar[dtype](bitcast[DType.float64](b))
            )
    data_buf.set_length(Int64(n_docs * elem_size))
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if has_validity:
        var bm = Bitmap.create(n_docs)
        for s in range(n_docs):
            if _read_validity_bit(region, validity_off, s):
                bm.set(s)
            else:
                null_count += 1
        validity = bm^
    return PrimitiveArray[dtype](data_buf^, n_docs, validity^, null_count, 0)
