# =============================================================================
# Dictionary Page Decoder — Parquet dictionary encoding support
# =============================================================================
#
# Dictionary encoding in Parquet:
#   1. First page is a DICTIONARY_PAGE containing unique values (PLAIN-encoded)
#   2. Subsequent DATA_PAGEs use RLE_DICTIONARY encoding:
#      - First byte is the bit_width of the indices
#      - Remaining bytes are RLE/bit-pack hybrid encoded indices into the dict
#
# For string (BYTE_ARRAY) columns, the dictionary is a StringArray of unique
# values, and the indices point into it. This enables:
#   - Compact storage (repeated strings stored once)
#   - Dict-aware aggregation (use integer indices as group IDs)
#   - StringDictionaryArray passthrough (no string materialization)
#
# The page bytes come in as a `Span[UInt8]`; the gathers read the decoded
# dictionary and code arrays through pointers taken inside the bodies, from
# origin-tied views held live across each loop. A definition-level section
# decodes to a validity bitmap in def_level_bitmap.mojo.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.binary_array import BinaryArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import Bitmap
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


from .decode_arm_trace import (
    dict_resolve_fused_enabled,
    incr_dict_resolve_fused,
    incr_dict_resolve_legacy,
)
from .dict_gather_fused import resolve_gather_fused
from .rle import RleDecoder
from .plain import (
    decode_plain_int32,
    decode_plain_int64,
    decode_plain_float32,
    decode_plain_float64,
    decode_plain_byte_array,
)
from .plain_flba import decode_plain_fixed_len_byte_array
from .dictionary_resolve import _Gathers, _validate_dict_indices


# =============================================================================
# DictionaryDecoder
# =============================================================================


struct DictionaryDecoder(Movable):
    """Decodes dictionary-encoded Parquet columns.

    First call one of the init_dict_* methods with the DICTIONARY_PAGE data
    to populate the dictionary. Then call decode_indices() for each DATA_PAGE
    to get RLE-decoded integer indices. Finally call resolve_* to map indices
    to actual values, or resolve_as_string_dict to get a StringDictionaryArray.

    Fields:
        dict_values_int32: Dictionary values for INT32 physical type.
        dict_values_int64: Dictionary values for INT64 physical type.
        dict_values_float64: Dictionary values for DOUBLE physical type.
        dict_values_bytes: Dictionary values for BYTE_ARRAY physical type.
        dict_size: Number of unique entries in the dictionary.
        _initialized: Whether a dictionary has been loaded.
    """

    var dict_values_int32: Optional[PrimitiveArray[DType.int32]]
    var dict_values_int64: Optional[PrimitiveArray[DType.int64]]
    var dict_values_float32: Optional[PrimitiveArray[DType.float32]]
    var dict_values_float64: Optional[PrimitiveArray[DType.float64]]
    var dict_values_bytes: Optional[StringArray[HeapRegion]]
    # FIXED_LEN_BYTE_ARRAY dictionary: raw N-bytes-per-value buffer plus width.
    var dict_values_flba: Optional[BinaryArray[HeapRegion]]
    var dict_flba_type_length: Int
    var dict_size: Int
    var _initialized: Bool

    def __init__(out self):
        """Create an empty DictionaryDecoder. Call init_dict_* before use."""
        self.dict_values_int32 = None
        self.dict_values_int64 = None
        self.dict_values_float32 = None
        self.dict_values_float64 = None
        self.dict_values_bytes = None
        self.dict_values_flba = None
        self.dict_flba_type_length = 0
        self.dict_size = 0
        self._initialized = False

    # --- Dictionary-entry readout (numeric-dict-aware count) ---
    #
    # The scan's fused filter+count path evaluates the
    # predicate ONCE per distinct dictionary entry to build a small boolean
    # LUT, then counts code-matches over the narrow int32 codes — it never
    # gathers the full per-row value array. These accessors expose the
    # (small, <= dict_size) entry set as Int64 (widening INT32 dicts) so the
    # LUT can be built without a `resolve_*` materialization.

    @always_inline
    def has_int64_dict(self) -> Bool:
        return self.dict_values_int64.__bool__()

    @always_inline
    def has_int32_dict(self) -> Bool:
        return self.dict_values_int32.__bool__()

    @always_inline
    def _assert_dict_size_decoded(
        self, decoded_len: Int, physical: String
    ) raises:
        """Raise unless the page-declared `dict_size` was actually decoded.

        `dict_size` comes off the wire; `decoded_len` is what the PLAIN
        decoder produced. Any reader that walks `range(self.dict_size)` over
        the decoded array must call this first — see `dict_entries_as_int64`.
        """
        if self.dict_size > decoded_len or self.dict_size < 0:
            raise Error(
                "parquet: corrupt dictionary page: the "
                + physical
                + " DICTIONARY_PAGE declares "
                + String(self.dict_size)
                + " entries but only "
                + String(decoded_len)
                + " were decoded"
            )

    def dict_entries_as_int64(self) raises -> List[Int64]:
        """Return every distinct dictionary entry widened to Int64.

        Supports INT32- and INT64-backed numeric dictionaries (the two
        physical types the fused-count LUT path admits). The result has
        `dict_size` elements in dictionary order; entry `e` is the value a
        code of `e` resolves to. Raises if no numeric dictionary is loaded.

        ROBUSTNESS: the walk is bounded by
        the decoded ARRAY's own length, not by `self.dict_size`. `dict_size`
        is the DICTIONARY_PAGE's declared `num_values` — an attacker-supplied
        number — and `get_typed` below is `debug_assert`-only, so a declared
        count larger than what was actually decoded would walk straight off
        the end of the dictionary buffer and into the LUT that the fused-count
        path then indexes.

        Raises:
            Error if no numeric dictionary is loaded, or if the page declared
            more dictionary entries than were decoded.
        """
        var out = List[Int64](capacity=max(self.dict_size, 0))
        if self.dict_values_int64:
            ref dv = self.dict_values_int64.value()
            self._assert_dict_size_decoded(dv.length, "INT64")
            for e in range(self.dict_size):
                out.append(dv.get_typed[Scalar[DType.int64]](e))
            return out^
        if self.dict_values_int32:
            ref dv32 = self.dict_values_int32.value()
            self._assert_dict_size_decoded(dv32.length, "INT32")
            for e in range(self.dict_size):
                out.append(Int64(Int(dv32.get_typed[Scalar[DType.int32]](e))))
            return out^
        raise Error(
            "DictionaryDecoder.dict_entries_as_int64: no numeric dictionary"
            " loaded"
        )

    # --- Dictionary initialization from DICTIONARY_PAGE data ---

    def init_dict_int32(
        mut self,
        data: Span[UInt8, _],
        num_values: Int,
    ) raises:
        """Initialize the dictionary with PLAIN-encoded Int32 values.

        Decodes num_values Int32 values from the DICTIONARY_PAGE data
        and stores them for later index resolution.

        Args:
            data: The PLAIN-encoded dictionary values (the decoded
                dictionary page); its length bounds the decode.
            num_values: Number of unique dictionary entries.

        Raises:
            Error if the page cannot hold `num_values` encoded values.
        """
        self.dict_values_int32 = decode_plain_int32(data, num_values)
        self.dict_size = num_values
        self._initialized = True

    def init_dict_int64(
        mut self,
        data: Span[UInt8, _],
        num_values: Int,
    ) raises:
        """Initialize the dictionary with PLAIN-encoded Int64 values.

        Args:
            data: The PLAIN-encoded dictionary values (the decoded
                dictionary page); its length bounds the decode.
            num_values: Number of unique dictionary entries.

        Raises:
            Error if the page cannot hold `num_values` encoded values.
        """
        self.dict_values_int64 = decode_plain_int64(data, num_values)
        self.dict_size = num_values
        self._initialized = True

    def init_dict_float32(
        mut self,
        data: Span[UInt8, _],
        num_values: Int,
    ) raises:
        """Initialize the dictionary with PLAIN-encoded Float32 values.

        Args:
            data: The PLAIN-encoded dictionary values (the decoded
                dictionary page); its length bounds the decode.
            num_values: Number of unique dictionary entries.

        Raises:
            Error if the page cannot hold `num_values` encoded values.
        """
        self.dict_values_float32 = decode_plain_float32(data, num_values)
        self.dict_size = num_values
        self._initialized = True

    def init_dict_float64(
        mut self,
        data: Span[UInt8, _],
        num_values: Int,
    ) raises:
        """Initialize the dictionary with PLAIN-encoded Float64 values.

        Args:
            data: The PLAIN-encoded dictionary values (the decoded
                dictionary page); its length bounds the decode.
            num_values: Number of unique dictionary entries.

        Raises:
            Error if the page cannot hold `num_values` encoded values.
        """
        self.dict_values_float64 = decode_plain_float64(data, num_values)
        self.dict_size = num_values
        self._initialized = True

    def init_dict_byte_array(
        mut self,
        data: Span[UInt8, _],
        num_values: Int,
    ) raises:
        """Initialize the dictionary with PLAIN-encoded BYTE_ARRAY values.

        Parquet PLAIN BYTE_ARRAY: [4-byte LE length][bytes] repeated.
        Decoded into a StringArray for later index resolution.

        Args:
            data: The PLAIN-encoded BYTE_ARRAY dictionary values (the decoded
                dictionary page); its length bounds the walk.
            num_values: Number of unique dictionary entries.

        Raises:
            Error if the length-prefixed walk would read past the page.
        """
        self.dict_values_bytes = decode_plain_byte_array(data, num_values)
        self.dict_size = num_values
        self._initialized = True

    def init_dict_fixed_len_byte_array(
        mut self,
        data: Span[UInt8, _],
        num_values: Int,
        type_length: Int,
    ) raises:
        """Initialize the dictionary with PLAIN-encoded FIXED_LEN_BYTE_ARRAY values.

        Parquet PLAIN FIXED_LEN_BYTE_ARRAY: `type_length` bytes per value,
        packed back-to-back with no length prefix. Decoded into a BinaryArray
        so that later resolves can either emit raw bytes or DECIMAL-convert.

        Args:
            data: The PLAIN-encoded FLBA dictionary values; its length bounds
                the decode.
            num_values: Number of unique dictionary entries.
            type_length: Byte width of each FLBA value.

        Raises:
            Error if the page cannot hold `num_values * type_length` bytes.
        """
        self.dict_values_flba = decode_plain_fixed_len_byte_array(
            data, num_values, type_length
        )
        self.dict_flba_type_length = type_length
        self.dict_size = num_values
        self._initialized = True

    # --- Index decoding from DATA_PAGE ---

    @always_inline
    def decode_indices(
        self,
        data: Span[UInt8, _],
        num_values: Int,
    ) raises -> PrimitiveArray[DType.int32]:
        """Decode RLE-encoded dictionary indices from a DATA_PAGE.

        The first byte of data is the bit_width of the indices.
        Remaining bytes are RLE/bit-pack hybrid encoded.

        Allocation-friendly callers should use `decode_indices_into`
        instead — it writes directly into a caller-provided destination
        Span and avoids the PrimitiveArray wrapper allocation.

        Args:
            data: The RLE_DICTIONARY encoded page data.
            num_values: Number of values (indices) to decode.

        Returns:
            A PrimitiveArray[DType.int32] of dictionary indices.

        Raises:
            Error if `num_values` is negative or past the Int32 range of a
            page's value count, or the bit width is past 32.
        """
        _check_index_count("decode_indices", num_values)
        if len(data) == 0 or num_values == 0:
            return PrimitiveArray[DType.int32].allocate(0)

        comptime int32_size = size_of[Scalar[DType.int32]]()
        var buf = OwnedAlignedBuffer(num_values * int32_size)
        buf.set_length(Int64(num_values * int32_size))

        # The writer pointer comes from the origin-tied `view_mut`; the
        # borrow lives across the bit_width branch, RLE decode, and
        # tail memset. `output_ptr` is then a typed Int32* alias into
        # this borrow.
        var buf_view = buf.view_mut()
        var output_ptr = buf_view._unsafe_ptr().bitcast[Int32]()

        # First byte is the bit_width.
        var bit_width = Int(data[0])
        if bit_width == 0:
            # PERF-CRITICAL: bulk memset, not a
            # per-element zero loop. All indices are 0 (single dict entry).
            comptime i32sz = size_of[Int32]()
            unsafe_memset(output_ptr.bitcast[UInt8](), 0, num_values * i32sz)
            return PrimitiveArray[DType.int32](buf^, num_values, None, 0, 0)

        var decoder = RleDecoder(data[1:], bit_width)
        var decoded = decoder.decode_int32(
            num_values,
            Span[Int32, buf_view.origin](unsafe_ptr=output_ptr, length=num_values),
        )
        if decoded < num_values:
            # PERF-CRITICAL: bulk memset trailing zeros.
            comptime i32sz2 = size_of[Int32]()
            unsafe_memset(
                (output_ptr + decoded).bitcast[UInt8](),
                0,
                (num_values - decoded) * i32sz2,
            )

        return PrimitiveArray[DType.int32](buf^, num_values, None, 0, 0)

    def decode_indices_into[
        o: MutOrigin
    ](
        self,
        data: Span[UInt8, _],
        num_values: Int,
        dest: Span[Int32, o],
    ) raises:
        """Decode RLE-encoded dictionary indices directly into `dest`.

        Used by the column decoder's pre-sized index buffer, which holds the
        whole column chunk's indices; each page's indices are written at the
        current write offset, with no per-page allocate-plus-memcpy.

        Args:
            data: The RLE_DICTIONARY encoded page data.
            num_values: Number of indices to decode.
            dest: Destination (caller-owned); at least `num_values` long.

        Raises:
            Error if `num_values` is negative, past the Int32 range of a
            page's value count or longer than `dest`, or the bit width is
            past 32.
        """
        _check_index_count("decode_indices_into", num_values)
        if num_values > len(dest):
            raise Error(
                "DictionaryDecoder.decode_indices_into: "
                + String(num_values)
                + " indices do not fit a destination of "
                + String(len(dest))
            )
        if len(data) == 0 or num_values == 0:
            return
        var bit_width = Int(data[0])
        if bit_width == 0:
            # PERF-CRITICAL: bulk memset, not a scalar zero loop.
            comptime i32sz = size_of[Int32]()
            unsafe_memset(dest.unsafe_ptr().bitcast[UInt8](), 0, num_values * i32sz)
            return
        var decoder = RleDecoder(data[1:], bit_width)
        var decoded = decoder.decode_int32(num_values, dest)
        if decoded < num_values:
            # PERF-CRITICAL: bulk memset trailing zeros.
            comptime i32sz2 = size_of[Int32]()
            unsafe_memset(
                (dest.unsafe_ptr() + decoded).bitcast[UInt8](),
                0,
                (num_values - decoded) * i32sz2,
            )

    # --- Value resolution: indices -> actual values ---

    def resolve_int32(
        self, indices: PrimitiveArray[DType.int32]
    ) raises -> PrimitiveArray[DType.int32]:
        """Resolve dictionary indices to actual Int32 values.

        The comptime SIMD fan-out with `W = simd_width_of[Int32]()` lowers
        to native gather instructions (`vgatherdps` on AVX-512).
        Prefetching `_DICT_PF_INT32` rows ahead hides L2 miss
        latency on the random-access dict-values fetch.

        Each index in the indices array is looked up in the dictionary
        to produce the corresponding value.

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.

        Returns:
            A PrimitiveArray[DType.int32] of resolved values.

        Raises:
            Error if the Int32 dictionary was not initialized.
        """
        if not self.dict_values_int32:
            raise Error(
                "DictionaryDecoder.resolve_int32: no Int32 dictionary loaded"
            )

        # =====================================================================
        # The BLOCKED, BOUNDS-FUSED arm.
        # =====================================================================
        #
        # The legacy arm (dictionary_resolve.mojo) streams the code array TWICE (once for the
        # whole-array `_validate_dict_indices` min/max, once for the gather),
        # prefetches a random dictionary address unconditionally, and builds
        # its output a SIMD lane at a time. `dict_gather_fused` blocks the two
        # passes together at 2,048 codes so the gather's re-read is an L1 hit,
        # makes the prefetch conditional on the dictionary NOT fitting in L2,
        # and gathers with a flat 4x-unrolled scalar loop. The three terms:
        # `dict_gather_fused.mojo`'s header.
        #
        # A `None` RETURN MEANS CORRUPT INPUT, NOT "DECLINED". The fused arm
        # gathers nothing when a block's codes leave `[0, dict_len)`; falling
        # through re-runs `_validate_dict_indices` over the WHOLE array, which
        # raises with the byte-for-byte message a corrupt file has always
        # produced (it names the min and max over the whole code stream). That
        # is why the fall-through is not an error arm here.
        #
        # `set_dict_resolve_fused_enabled(False)` selects the legacy arm, the
        # identical-binary control. Do not delete the legacy body to "simplify".
        if dict_resolve_fused_enabled():
            var _fused = resolve_gather_fused[DType.int32](
                indices, self.dict_values_int32.value()
            )
            if _fused:
                incr_dict_resolve_fused()
                return _fused.take()
        # LEGACY CTRL ARM (or the corrupt-input fall-through above).
        incr_dict_resolve_legacy()
        return _Gathers.resolve_int32_legacy(indices, self.dict_values_int32.value())

    def resolve_int64(
        self, indices: PrimitiveArray[DType.int32]
    ) raises -> PrimitiveArray[DType.int64]:
        """Resolve dictionary indices to actual Int64 values.

        A comptime SIMD fan-out with `W = simd_width_of[Int64]()` and an
        L1 prefetch. On AVX-512 W=8 and LLVM emits `vpgatherqq zmm` (8-lane
        Int64 gather); on AVX2 W=4 → `vpgatherdq ymm`; on NEON W=2.
        Prefetching `_DICT_PF_INT64` rows ahead
        hides L2 miss latency on the random-access dict-values fetch.

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.

        Returns:
            A PrimitiveArray[DType.int64] of resolved values.

        Raises:
            Error if the Int64 dictionary was not initialized.
        """
        if not self.dict_values_int64:
            raise Error(
                "DictionaryDecoder.resolve_int64: no Int64 dictionary loaded"
            )

        # =====================================================================
        # The BLOCKED, BOUNDS-FUSED arm.
        # =====================================================================
        #
        # The legacy arm (dictionary_resolve.mojo) streams the code array TWICE (once for the
        # whole-array `_validate_dict_indices` min/max, once for the gather),
        # prefetches a random dictionary address unconditionally, and builds
        # its output a SIMD lane at a time. `dict_gather_fused` blocks the two
        # passes together at 2,048 codes so the gather's re-read is an L1 hit,
        # makes the prefetch conditional on the dictionary NOT fitting in L2,
        # and gathers with a flat 4x-unrolled scalar loop. The three terms:
        # `dict_gather_fused.mojo`'s header.
        #
        # A `None` RETURN MEANS CORRUPT INPUT, NOT "DECLINED". The fused arm
        # gathers nothing when a block's codes leave `[0, dict_len)`; falling
        # through re-runs `_validate_dict_indices` over the WHOLE array, which
        # raises with the byte-for-byte message a corrupt file has always
        # produced (it names the min and max over the whole code stream). That
        # is why the fall-through is not an error arm here.
        #
        # `set_dict_resolve_fused_enabled(False)` selects the legacy arm, the
        # identical-binary control. Do not delete the legacy body to "simplify".
        if dict_resolve_fused_enabled():
            var _fused = resolve_gather_fused[DType.int64](
                indices, self.dict_values_int64.value()
            )
            if _fused:
                incr_dict_resolve_fused()
                return _fused.take()
        # LEGACY CTRL ARM (or the corrupt-input fall-through above).
        incr_dict_resolve_legacy()
        return _Gathers.resolve_int64_legacy(indices, self.dict_values_int64.value())

    def resolve_float32(
        self, indices: PrimitiveArray[DType.int32]
    ) raises -> PrimitiveArray[DType.float32]:
        """Resolve dictionary indices to actual Float32 values.

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.

        Returns:
            A PrimitiveArray[DType.float32] of resolved values.

        Raises:
            Error if the Float32 dictionary was not initialized.
        """
        if not self.dict_values_float32:
            raise Error(
                "DictionaryDecoder.resolve_float32: no Float32 dictionary loaded"
            )

        # =====================================================================
        # The BLOCKED, BOUNDS-FUSED arm.
        # =====================================================================
        #
        # The legacy arm (dictionary_resolve.mojo) streams the code array TWICE (once for the
        # whole-array `_validate_dict_indices` min/max, once for the gather),
        # prefetches a random dictionary address unconditionally, and builds
        # its output a SIMD lane at a time. `dict_gather_fused` blocks the two
        # passes together at 2,048 codes so the gather's re-read is an L1 hit,
        # makes the prefetch conditional on the dictionary NOT fitting in L2,
        # and gathers with a flat 4x-unrolled scalar loop. The three terms:
        # `dict_gather_fused.mojo`'s header.
        #
        # A `None` RETURN MEANS CORRUPT INPUT, NOT "DECLINED". The fused arm
        # gathers nothing when a block's codes leave `[0, dict_len)`; falling
        # through re-runs `_validate_dict_indices` over the WHOLE array, which
        # raises with the byte-for-byte message a corrupt file has always
        # produced (it names the min and max over the whole code stream). That
        # is why the fall-through is not an error arm here.
        #
        # `set_dict_resolve_fused_enabled(False)` selects the legacy arm, the
        # identical-binary control. Do not delete the legacy body to "simplify".
        if dict_resolve_fused_enabled():
            var _fused = resolve_gather_fused[DType.float32](
                indices, self.dict_values_float32.value()
            )
            if _fused:
                incr_dict_resolve_fused()
                return _fused.take()
        # LEGACY CTRL ARM (or the corrupt-input fall-through above).
        incr_dict_resolve_legacy()
        return _Gathers.resolve_float32_legacy(indices, self.dict_values_float32.value())

    def resolve_float64(
        self, indices: PrimitiveArray[DType.int32]
    ) raises -> PrimitiveArray[DType.float64]:
        """Resolve dictionary indices to actual Float64 values.

        A comptime SIMD fan-out with `W = simd_width_of[Float64]()` and
        an L1 prefetch, as in resolve_int64. On AVX-512 W=8 and LLVM
        emits `vgatherqpd zmm` (8-lane Float64 gather); on AVX2
        W=4 → `vgatherdpd ymm`; on NEON W=2. Prefetching `_DICT_PF_FLOAT64` rows
        ahead hides L2 miss latency on the random-access fetch.

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.

        Returns:
            A PrimitiveArray[DType.float64] of resolved values.

        Raises:
            Error if the Float64 dictionary was not initialized.
        """
        if not self.dict_values_float64:
            raise Error(
                "DictionaryDecoder.resolve_float64: no Float64 dictionary loaded"
            )

        # =====================================================================
        # The BLOCKED, BOUNDS-FUSED arm.
        # =====================================================================
        #
        # The legacy arm (dictionary_resolve.mojo) streams the code array TWICE (once for the
        # whole-array `_validate_dict_indices` min/max, once for the gather),
        # prefetches a random dictionary address unconditionally, and builds
        # its output a SIMD lane at a time. `dict_gather_fused` blocks the two
        # passes together at 2,048 codes so the gather's re-read is an L1 hit,
        # makes the prefetch conditional on the dictionary NOT fitting in L2,
        # and gathers with a flat 4x-unrolled scalar loop. The three terms:
        # `dict_gather_fused.mojo`'s header.
        #
        # A `None` RETURN MEANS CORRUPT INPUT, NOT "DECLINED". The fused arm
        # gathers nothing when a block's codes leave `[0, dict_len)`; falling
        # through re-runs `_validate_dict_indices` over the WHOLE array, which
        # raises with the byte-for-byte message a corrupt file has always
        # produced (it names the min and max over the whole code stream). That
        # is why the fall-through is not an error arm here.
        #
        # `set_dict_resolve_fused_enabled(False)` selects the legacy arm, the
        # identical-binary control. Do not delete the legacy body to "simplify".
        if dict_resolve_fused_enabled():
            var _fused = resolve_gather_fused[DType.float64](
                indices, self.dict_values_float64.value()
            )
            if _fused:
                incr_dict_resolve_fused()
                return _fused.take()
        # LEGACY CTRL ARM (or the corrupt-input fall-through above).
        incr_dict_resolve_legacy()
        return _Gathers.resolve_float64_legacy(indices, self.dict_values_float64.value())

    def resolve_as_string_dict(
        self, indices: PrimitiveArray[DType.int32]
    ) raises -> StringDictionaryArray:
        """Resolve dictionary indices into a StringDictionaryArray.

        Instead of materializing all strings, this produces a dictionary-
        encoded Arrow array where the indices point into the string dictionary.
        This is the zero-copy path for dict-aware aggregation.

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.

        Returns:
            A StringDictionaryArray with the given indices and the loaded
            string dictionary.

        Raises:
            Error if the BYTE_ARRAY dictionary was not initialized, or if any
            code is out of range for the loaded string dictionary.
        """
        if not self.dict_values_bytes:
            raise Error(
                "DictionaryDecoder.resolve_as_string_dict: "
                "no BYTE_ARRAY dictionary loaded"
            )

        # ROBUSTNESS GATE.
        #
        # This is the STRING twin of the six
        # `resolve_*` gathers, and it is dangerous for the opposite reason:
        # it does NOT gather. It hands the raw codes downstream inside a
        # StringDictionaryArray, and the consumer resolves them one at a time
        # via `Column.string_dict_value_at(code)` -> `offsets.get_typed(code)`
        # and `get_typed(code + 1)`, a pair of `debug_assert`-
        # only reads that are inert in a release build. A corrupt code therefore
        # yields an attacker-chosen (start, end) pair over the packed dict
        # bytes, and `ByteView.sub` — whose docstring says PANICS but whose
        # implementation is also a `debug_assert` — hands back a view over
        # arbitrary process memory that the query can then SELECT.
        #
        # Because this arm exists to AVOID materializing, no `resolve_*` gate
        # can ever cover it. Gate it here, at the boundary, once per chunk:
        # the whole dict-vector STRING path (preserve_dict hash-agg /
        # distinct group keys) flows through this one call.
        _validate_dict_indices(
            indices,
            self.dict_values_bytes.value().length,
            "resolve_as_string_dict",
        )

        # Copy the dictionary StringArray (StringDictionaryArray takes ownership).
        var dict_copy = _copy_string_array_from_opt(self.dict_values_bytes)

        # Copy the indices (StringDictionaryArray takes ownership).
        var idx_copy = _copy_int32_array(indices)

        var length = idx_copy.length
        return StringDictionaryArray(idx_copy^, dict_copy^, length)

    def string_dict_column(
        self, var indices: PrimitiveArray[DType.int32]
    ) raises -> Column[HeapRegion]:
        """The DICTIONARY `Column` for a NON-NULL
        chunk's codes, with the codes MOVED in rather than copied twice.

        The route this replaces — `resolve_as_string_dict(indices)` then
        `Column.from_dictionary(dict_arr)` — copies the whole code buffer TWICE
        per chunk (`_copy_int32_array`, then `from_dictionary`'s own memcpy):
        2 x 480 KB per 122,880-row row group. `indices` is taken BY
        VALUE — the caller's freshly decoded code buffer — and its buffer is
        ARC-SHARED into the Column (refcount back to 1 when `indices` dies
        here), the `Column.from_primitive_shared` argument. The dictionary is
        still copied (it is `dict_size` entries, and the decoder keeps it).

        The same robustness gate as `resolve_as_string_dict` runs first: a code
        outside the dictionary is refused here, at the boundary, not resolved
        into a view over arbitrary memory downstream.

        Buffer lengths mirror `from_dictionary`'s exactly (the shared handles
        are truncated to `length * 4` bytes and the dictionary buffers are
        exact copies), so a `deep_copy` / buffer-length reader cannot tell the
        two constructions apart.

        Raises:
            Error if no BYTE_ARRAY dictionary is loaded, a code is out of range,
            the codes carry validity (the NULLABLE arm is not this one), or the
            code buffer is shorter than its header claims.
        """
        if not self.dict_values_bytes:
            raise Error(
                "DictionaryDecoder.string_dict_column: no BYTE_ARRAY dictionary"
                " loaded"
            )
        if indices.validity:
            raise Error(
                "DictionaryDecoder.string_dict_column: nullable codes take the"
                " scatter arm, not this one"
            )
        _validate_dict_indices(
            indices,
            self.dict_values_bytes.value().length,
            "string_dict_column",
        )
        var dict_copy = _copy_string_array_from_opt(self.dict_values_bytes)
        comptime int32_size = size_of[Int32]()
        var n = indices.length
        var code_bytes = (indices.offset + n) * int32_size
        var codes = indices.data.share()
        if code_bytes > Int(codes.len()):
            raise Error(
                "DictionaryDecoder.string_dict_column: code buffer holds "
                + String(Int(codes.len()))
                + " bytes but the array header claims "
                + String(code_bytes)
            )
        codes.set_length(Int64(code_bytes))
        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=codes^,
            offsets=Optional(dict_copy.offsets.share()),
            validity=Optional[Bitmap[HeapRegion]](None),
            length=n,
            null_count=0,
            offset=indices.offset,
        )
        col._dict_data = Optional(dict_copy.data.share())
        col._dict_size = dict_copy.length
        return col^

    def resolve_flba_as_binary(
        self, indices: PrimitiveArray[DType.int32]
    ) raises -> BinaryArray[HeapRegion]:
        """Resolve dict indices to a materialised FIXED_LEN_BYTE_ARRAY column.

        Looks each index up in the FLBA dictionary and copies that value's
        bytes into a new BinaryArray whose elements are all `type_length`
        bytes wide. Used when the caller wants raw FLBA bytes (not DECIMAL).

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.

        Returns:
            A BinaryArray of length `len(indices)`, each element
            `type_length` bytes.

        Raises:
            Error if the FLBA dictionary was not initialized, a code is out of
            range, or the values pass 2^31 - 1 bytes (the Int32 offsets).
        """
        if not self.dict_values_flba:
            raise Error(
                "DictionaryDecoder.resolve_flba_as_binary: "
                "no FIXED_LEN_BYTE_ARRAY dictionary loaded"
            )

        return _Gathers.resolve_flba_as_binary(
            indices, self.dict_values_flba.value(), self.dict_flba_type_length
        )

    def resolve_flba_decimal_to_float64(
        self, indices: PrimitiveArray[DType.int32], scale: Int
    ) raises -> PrimitiveArray[DType.float64]:
        """Resolve FLBA dict indices into Float64 by DECIMAL conversion.

        Each index is looked up in the FLBA dictionary and the N-byte
        big-endian signed integer is converted to Float64 via divide-by-
        10^scale. See `_flba_value_to_int64_be` for truncation semantics
        when precision > 18.

        Args:
            indices: PrimitiveArray[DType.int32] of dictionary indices.
            scale: DECIMAL scale (number of fractional digits).

        Returns:
            A PrimitiveArray[DType.float64] of resolved values.

        Raises:
            Error if the FLBA dictionary was not initialized.
        """
        if not self.dict_values_flba:
            raise Error(
                "DictionaryDecoder.resolve_flba_decimal_to_float64: "
                "no FIXED_LEN_BYTE_ARRAY dictionary loaded"
            )

        return _Gathers.resolve_flba_decimal_to_float64(
            indices, self.dict_values_flba.value(), self.dict_flba_type_length, scale
        )


# =============================================================================
# Internal helpers
# =============================================================================


def _check_index_count(what: String, num_values: Int) raises:
    """Refuse a page value count that is negative or past Int32 (a page
    header's count is an i32), so `num_values * 4` cannot wrap."""
    if num_values < 0 or num_values > 2147483647:
        raise Error(
            "DictionaryDecoder."
            + what
            + ": a page cannot hold "
            + String(num_values)
            + " dictionary indices"
        )


def _copy_string_array_from_opt(
    src: Optional[StringArray[HeapRegion]],
) raises -> StringArray[HeapRegion]:
    """Create an owned copy of a StringArray from an Optional."""
    if not src:
        raise Error("_copy_string_array_from_opt: no StringArray to copy")

    comptime int32_size = size_of[Int32]()

    var length = src.value().length
    var data_length = src.value().data_length
    var offsets_bytes = (length + 1) * int32_size
    # src/dst via origin-tied views.
    var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
    var src_off_view = src.value().offsets.view_range_ro(0, offsets_bytes)
    var dst_off_view = offsets_buf.view_range_mut(0, offsets_bytes)
    unsafe_memcpy(
        dest=dst_off_view._unsafe_ptr(),
        src=src_off_view._unsafe_ptr(),
        count=offsets_bytes,
    )
    offsets_buf.set_length(Int64(offsets_bytes))


    var data_buf = OwnedAlignedBuffer(max(data_length, 1))
    if data_length > 0:
        var src_data_view = src.value().data.view_range_ro(0, data_length)
        var dst_data_view = data_buf.view_range_mut(0, data_length)
        unsafe_memcpy(
            dest=dst_data_view._unsafe_ptr(),
            src=src_data_view._unsafe_ptr(),
            count=data_length,
        )
    data_buf.set_length(Int64(data_length))


    return StringArray[HeapRegion](
        offsets=offsets_buf^,
        data=data_buf^,
        validity=None,
        length=length,
        data_length=data_length,
        null_count=0,
    )


def _copy_int32_array(
    src: PrimitiveArray[DType.int32],
) raises -> PrimitiveArray[DType.int32]:
    """Create an owned copy of a PrimitiveArray[DType.int32].

    Preserves the source validity bitmap + null_count so that a nullable
    indices array survives the copy. This is load-bearing for the
    preserve_dict=True DICTIONARY-typed nullable-STRING read path: the
    null positions live in the indices' validity bitmap, and dropping
    them here would silently lose the nulls.
    """
    comptime int32_size = size_of[Scalar[DType.int32]]()
    var byte_count = src.length * int32_size
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    if byte_count > 0:
        # src/dst via origin-tied views on the AlignedBuffers.
        var src_view = src.data.view_range_ro(0, byte_count)
        var dst_view = buf.view_range_mut(0, byte_count)
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=src_view._unsafe_ptr(),
            count=byte_count,
        )
    buf.set_length(Int64(byte_count))

    var validity = Optional[Bitmap[HeapRegion]](None)
    if src.validity:
        validity = Bitmap.copy_slice_from(
            src.validity.value(), 0, src.length
        )

    return PrimitiveArray[DType.int32](
        buf^, src.length, validity^, src.null_count, 0
    )
